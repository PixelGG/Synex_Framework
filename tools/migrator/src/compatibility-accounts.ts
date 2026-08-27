import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_MIGRATION_ARTIFACT_BYTES, MAX_MIGRATION_CURRENCIES } from "./limits.ts";
import { pathContainsSymbolicLink } from "./path-safety.ts";

export type CompatibilityAccountProvider = "qb" | "qbx" | "esx";

export interface CompatibilityAccountDefinition {
  id: string;
  version: string;
  provider: CompatibilityAccountProvider;
  alias: string;
  currencyCode: string;
  accountKey: string;
  accountRole: "asset";
  minorUnit: number;
  legacyName: string;
  label: string;
  round: boolean;
  status: "CERTIFIED" | "COMPATIBLE" | "PARTIAL" | "UNSUPPORTED" | "UNKNOWN";
}

export interface CompatibilityAccountCatalog {
  digest: string;
  definitions: CompatibilityAccountDefinition[];
  byId: ReadonlyMap<string, CompatibilityAccountDefinition>;
  byProviderAlias: ReadonlyMap<string, CompatibilityAccountDefinition>;
}

const PROVIDERS = new Set<CompatibilityAccountProvider>(["qb", "qbx", "esx"]);
const STATUSES = new Set<CompatibilityAccountDefinition["status"]>([
  "CERTIFIED", "COMPATIBLE", "PARTIAL", "UNSUPPORTED", "UNKNOWN",
]);
const ID_PATTERN = /^[a-z][a-z0-9_.:-]{0,95}$/u;
const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/u;
const ALIAS_PATTERN = /^[a-z][a-z0-9_.-]{0,31}$/u;
const CURRENCY_PATTERN = /^[a-z][a-z0-9_]{1,15}$/u;
// Owner-scoped keys append "_" plus the 32 hexadecimal character ID.
const ACCOUNT_KEY_PREFIX_PATTERN = /^[a-z][a-z0-9_]{2,30}$/u;
const LABEL_PATTERN = /^[^\u0000-\u001f\u007f]+$/u;
const DEFINITION_FIELDS = new Set([
  "id", "version", "provider", "alias", "currencyCode", "accountKey",
  "accountRole", "minorUnit", "legacyName", "label", "round", "status",
  "fundingPolicy", "sinkPolicy",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function stableValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.keys(value).sort(compareText).map((key) => [key, stableValue(value[key])]),
  );
}

function canonicalJson(value: unknown): string {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function validateCompatibilityAccountCatalog(value: unknown): CompatibilityAccountCatalog {
  if (!isRecord(value) || value.schema !== 1 || value.kind !== "synex-compatibility-mappings"
    || !Array.isArray(value.accounts) || value.accounts.length > 256) {
    throw new Error("The checked-in compatibility account catalog has an invalid envelope.");
  }

  const definitions: CompatibilityAccountDefinition[] = [];
  const ids = new Set<string>();
  const aliases = new Set<string>();
  const targets = new Set<string>();
  for (const [index, raw] of value.accounts.entries()) {
    if (!isRecord(raw) || Object.keys(raw).some((field) => !DEFINITION_FIELDS.has(field))
      || Object.keys(raw).length !== DEFINITION_FIELDS.size
      || typeof raw.id !== "string" || !ID_PATTERN.test(raw.id)
      || typeof raw.version !== "string" || !VERSION_PATTERN.test(raw.version)
      || typeof raw.provider !== "string" || !PROVIDERS.has(raw.provider as CompatibilityAccountProvider)
      || typeof raw.alias !== "string" || !ALIAS_PATTERN.test(raw.alias)
      || typeof raw.currencyCode !== "string" || !CURRENCY_PATTERN.test(raw.currencyCode)
      || typeof raw.accountKey !== "string" || !ACCOUNT_KEY_PREFIX_PATTERN.test(raw.accountKey)
      || raw.accountRole !== "asset"
      || typeof raw.minorUnit !== "number" || !Number.isSafeInteger(raw.minorUnit)
      || raw.minorUnit < 0 || raw.minorUnit > 6
      || typeof raw.legacyName !== "string" || !ALIAS_PATTERN.test(raw.legacyName)
      || typeof raw.label !== "string" || raw.label.length < 1 || raw.label.length > 64
      || !LABEL_PATTERN.test(raw.label) || typeof raw.round !== "boolean"
      || typeof raw.status !== "string"
      || !STATUSES.has(raw.status as CompatibilityAccountDefinition["status"])) {
      throw new Error(`Compatibility account mapping ${index} is invalid.`);
    }
    const provider = raw.provider as CompatibilityAccountProvider;
    const aliasIdentity = `${provider}:${raw.alias}`;
    const targetIdentity = [
      provider, raw.currencyCode, raw.accountKey, raw.accountRole, String(raw.minorUnit),
    ].join(":");
    if (ids.has(raw.id) || aliases.has(aliasIdentity) || targets.has(targetIdentity)) {
      throw new Error(`Compatibility account mapping ${raw.id} is ambiguous.`);
    }
    ids.add(raw.id);
    aliases.add(aliasIdentity);
    targets.add(targetIdentity);
    definitions.push({
      id: raw.id,
      version: raw.version,
      provider,
      alias: raw.alias,
      currencyCode: raw.currencyCode,
      accountKey: raw.accountKey,
      accountRole: "asset",
      minorUnit: raw.minorUnit,
      legacyName: raw.legacyName,
      label: raw.label,
      round: raw.round,
      status: raw.status as CompatibilityAccountDefinition["status"],
    });
  }
  definitions.sort((left, right) => compareText(left.id, right.id));
  return {
    digest: sha256(canonicalJson({
      schema: 1,
      kind: "synex-compatibility-account-bindings",
      definitions,
    })),
    definitions,
    byId: new Map(definitions.map((definition) => [definition.id, definition])),
    byProviderAlias: new Map(
      definitions.map((definition) => [`${definition.provider}:${definition.alias}`, definition]),
    ),
  };
}

export function selectCompatibilityAccountDefinitionsById(
  catalog: CompatibilityAccountCatalog,
  provider: CompatibilityAccountProvider,
  mappingIds: readonly unknown[],
): CompatibilityAccountDefinition[] {
  if (mappingIds.length < 1 || mappingIds.length > MAX_MIGRATION_CURRENCIES) {
    throw new Error(
      `Compatibility account mapping IDs must contain between 1 and ${MAX_MIGRATION_CURRENCIES} entries.`,
    );
  }
  const selected: CompatibilityAccountDefinition[] = [];
  const seen = new Set<string>();
  for (const [index, mappingId] of mappingIds.entries()) {
    if (typeof mappingId !== "string" || !ID_PATTERN.test(mappingId) || seen.has(mappingId)) {
      throw new Error(`Compatibility account mapping ID ${index} is invalid or duplicated.`);
    }
    const definition = catalog.byId.get(mappingId);
    if (!definition || definition.provider !== provider
      || definition.status === "UNSUPPORTED" || definition.status === "UNKNOWN") {
      throw new Error(`Compatibility account mapping ${mappingId} is unavailable for ${provider}.`);
    }
    seen.add(mappingId);
    selected.push(definition);
  }
  return selected.sort((left, right) => compareText(left.alias, right.alias));
}

function defaultCatalogPath(): string {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const repositoryRoot = resolve(
    moduleDirectory,
    import.meta.url.endsWith(".ts") ? "../../.." : "../../../..",
  );
  return join(repositoryRoot, "libraries", "synex_bridge", "compatibility", "mappings.json");
}

export async function loadCompatibilityAccountCatalog(
  path = defaultCatalogPath(),
): Promise<CompatibilityAccountCatalog> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || await pathContainsSymbolicLink(path)
    || metadata.size > MAX_MIGRATION_ARTIFACT_BYTES) {
    throw new Error("The checked-in compatibility account catalog must be a bounded non-symlink file.");
  }
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8")) as unknown;
  } catch {
    throw new Error("The checked-in compatibility account catalog is not valid JSON.");
  }
  return validateCompatibilityAccountCatalog(value);
}

export function selectCompatibilityAccountDefinitions(
  catalog: CompatibilityAccountCatalog,
  provider: CompatibilityAccountProvider,
  aliases: readonly string[],
): CompatibilityAccountDefinition[] {
  if (aliases.length < 1 || aliases.length > MAX_MIGRATION_CURRENCIES) {
    throw new Error(
      `fields.money must contain between 1 and ${MAX_MIGRATION_CURRENCIES} mapped account aliases.`,
    );
  }
  const selected: CompatibilityAccountDefinition[] = [];
  const seen = new Set<string>();
  for (const [index, alias] of aliases.entries()) {
    if (!ALIAS_PATTERN.test(alias) || seen.has(alias)) {
      throw new Error(`fields.money alias ${index} is invalid or duplicated.`);
    }
    const definition = catalog.byProviderAlias.get(`${provider}:${alias}`);
    if (!definition || definition.status === "UNSUPPORTED" || definition.status === "UNKNOWN") {
      throw new Error(`Compatibility account alias ${alias} is unavailable for ${provider}.`);
    }
    seen.add(alias);
    selected.push(definition);
  }
  return selected.sort((left, right) => compareText(left.alias, right.alias));
}

export function ownerScopedCompatibilityAccountKey(
  definition: Pick<CompatibilityAccountDefinition, "accountKey">,
  characterId: string,
): string {
  const compactCharacterId = characterId.replaceAll("-", "");
  if (!/^[0-9a-f]{32}$/u.test(compactCharacterId)) {
    throw new Error("A compatibility account key requires a canonical lowercase character UUID.");
  }
  return `${definition.accountKey}_${compactCharacterId}`;
}
