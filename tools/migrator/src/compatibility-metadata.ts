import { lstat, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import {
  MAX_MIGRATION_ARTIFACT_BYTES,
  MAX_MIGRATION_METADATA_MAPPINGS,
} from "./limits.ts";
import { pathContainsSymbolicLink } from "./path-safety.ts";

export type CompatibilityMetadataProvider = "qb" | "qbx" | "esx";
export type CompatibilityMetadataValueType = "boolean" | "integer" | "number" | "string";

export interface CompatibilityMetadataDefinition {
  id: string;
  version: string;
  provider: CompatibilityMetadataProvider;
  key: string;
  valueType: CompatibilityMetadataValueType;
  minimum: number | null;
  maximum: number | null;
  maxLength: number | null;
  storageKey: string;
  status: "CERTIFIED" | "COMPATIBLE" | "PARTIAL" | "UNSUPPORTED" | "UNKNOWN";
  sensitive: false;
}

export interface CompatibilityMetadataCatalog {
  digest: string;
  definitions: CompatibilityMetadataDefinition[];
  byId: ReadonlyMap<string, CompatibilityMetadataDefinition>;
  forbiddenFields: ReadonlySet<string>;
}

const PROVIDERS = new Set<CompatibilityMetadataProvider>(["qb", "qbx", "esx"]);
const VALUE_TYPES = new Set<CompatibilityMetadataValueType>([
  "boolean", "integer", "number", "string",
]);
const STATUSES = new Set<CompatibilityMetadataDefinition["status"]>([
  "CERTIFIED", "COMPATIBLE", "PARTIAL", "UNSUPPORTED", "UNKNOWN",
]);
const DEFINITION_FIELDS = new Set([
  "id", "version", "provider", "key", "valueType", "minimum", "maximum",
  "maxLength", "storageKey", "status", "sensitive",
]);
const ID_PATTERN = /^[a-z][a-z0-9_.:-]{0,95}$/u;
const KEY_PATTERN = /^[a-z][a-z0-9_.:-]{0,63}$/u;
const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/u;

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

function nullableFiniteNumber(value: unknown): value is number | null {
  return value === null || typeof value === "number" && Number.isFinite(value);
}

function nullableLength(value: unknown): value is number | null {
  return value === null || typeof value === "number" && Number.isSafeInteger(value)
    && value >= 1 && value <= 4_096;
}

export function validateCompatibilityMetadataCatalog(value: unknown): CompatibilityMetadataCatalog {
  if (!isRecord(value) || value.schema !== 1 || value.kind !== "synex-compatibility-mappings"
    || !Array.isArray(value.metadata) || value.metadata.length > 512
    || !Array.isArray(value.forbiddenMetadataFields)
    || value.forbiddenMetadataFields.length < 1 || value.forbiddenMetadataFields.length > 64) {
    throw new Error("The checked-in compatibility metadata catalog has an invalid envelope.");
  }

  const forbidden = new Set<string>();
  for (const field of value.forbiddenMetadataFields) {
    if (typeof field !== "string" || !KEY_PATTERN.test(field) || forbidden.has(field)) {
      throw new Error("The checked-in compatibility metadata forbidden-field catalog is invalid.");
    }
    forbidden.add(field);
  }

  const definitions: CompatibilityMetadataDefinition[] = [];
  const ids = new Set<string>();
  const legacyKeys = new Set<string>();
  const storageKeys = new Set<string>();
  for (const [index, raw] of value.metadata.entries()) {
    if (!isRecord(raw) || Object.keys(raw).some((field) => !DEFINITION_FIELDS.has(field))
      || Object.keys(raw).length !== DEFINITION_FIELDS.size
      || typeof raw.id !== "string" || !ID_PATTERN.test(raw.id)
      || typeof raw.version !== "string" || raw.version.length > 64
      || !VERSION_PATTERN.test(raw.version)
      || typeof raw.provider !== "string" || !PROVIDERS.has(raw.provider as CompatibilityMetadataProvider)
      || typeof raw.key !== "string" || !KEY_PATTERN.test(raw.key)
      || typeof raw.valueType !== "string" || !VALUE_TYPES.has(raw.valueType as CompatibilityMetadataValueType)
      || !nullableFiniteNumber(raw.minimum) || !nullableFiniteNumber(raw.maximum)
      || !nullableLength(raw.maxLength)
      || typeof raw.storageKey !== "string" || !ID_PATTERN.test(raw.storageKey)
      || typeof raw.status !== "string" || !STATUSES.has(raw.status as CompatibilityMetadataDefinition["status"])
      || raw.sensitive !== false) {
      throw new Error(`Compatibility metadata mapping ${index} is invalid.`);
    }
    if (raw.minimum !== null && raw.maximum !== null && raw.minimum > raw.maximum) {
      throw new Error(`Compatibility metadata mapping ${raw.id} has inverted numeric bounds.`);
    }
    const provider = raw.provider as CompatibilityMetadataProvider;
    const legacyIdentity = `${provider}:${raw.key}`;
    const storageIdentity = `${provider}:${raw.storageKey}`;
    if (ids.has(raw.id) || legacyKeys.has(legacyIdentity) || storageKeys.has(storageIdentity)) {
      throw new Error(`Compatibility metadata mapping ${raw.id} is ambiguous.`);
    }
    if (forbidden.has(raw.key.toLowerCase()) || forbidden.has(raw.storageKey.toLowerCase())) {
      throw new Error(`Compatibility metadata mapping ${raw.id} targets a forbidden field.`);
    }
    ids.add(raw.id);
    legacyKeys.add(legacyIdentity);
    storageKeys.add(storageIdentity);
    definitions.push({
      id: raw.id,
      version: raw.version,
      provider,
      key: raw.key,
      valueType: raw.valueType as CompatibilityMetadataValueType,
      minimum: raw.minimum,
      maximum: raw.maximum,
      maxLength: raw.maxLength,
      storageKey: raw.storageKey,
      status: raw.status as CompatibilityMetadataDefinition["status"],
      sensitive: false,
    });
  }
  definitions.sort((left, right) => compareText(left.id, right.id));
  const digest = sha256(canonicalJson({
    schema: 1,
    kind: "synex-compatibility-metadata-bindings",
    definitions,
    forbiddenMetadataFields: [...forbidden].sort(compareText),
  }));
  return {
    digest,
    definitions,
    byId: new Map(definitions.map((definition) => [definition.id, definition])),
    forbiddenFields: forbidden,
  };
}

function defaultCatalogPath(): string {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const repositoryRoot = resolve(
    moduleDirectory,
    import.meta.url.endsWith(".ts") ? "../../.." : "../../../..",
  );
  return join(repositoryRoot, "libraries", "synex_bridge", "compatibility", "mappings.json");
}

export async function loadCompatibilityMetadataCatalog(
  path = defaultCatalogPath(),
): Promise<CompatibilityMetadataCatalog> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || await pathContainsSymbolicLink(path)
    || metadata.size > MAX_MIGRATION_ARTIFACT_BYTES) {
    throw new Error("The checked-in compatibility metadata catalog must be a bounded non-symlink file.");
  }
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8")) as unknown;
  } catch {
    throw new Error("The checked-in compatibility metadata catalog is not valid JSON.");
  }
  return validateCompatibilityMetadataCatalog(value);
}

export function selectCompatibilityMetadataDefinitions(
  catalog: CompatibilityMetadataCatalog,
  provider: CompatibilityMetadataProvider,
  mappingIds: unknown,
): CompatibilityMetadataDefinition[] {
  if (!Array.isArray(mappingIds) || mappingIds.length < 1
    || mappingIds.length > MAX_MIGRATION_METADATA_MAPPINGS) {
    throw new Error(
      `compatibilityMetadata.mappingIds must contain between 1 and ${MAX_MIGRATION_METADATA_MAPPINGS} entries.`,
    );
  }
  const selected: CompatibilityMetadataDefinition[] = [];
  const seen = new Set<string>();
  for (const [index, mappingId] of mappingIds.entries()) {
    if (typeof mappingId !== "string" || !ID_PATTERN.test(mappingId) || seen.has(mappingId)) {
      throw new Error(`compatibilityMetadata.mappingIds[${index}] is invalid or duplicated.`);
    }
    const definition = catalog.byId.get(mappingId);
    if (!definition || definition.provider !== provider
      || definition.status === "UNSUPPORTED" || definition.status === "UNKNOWN") {
      throw new Error(`Compatibility metadata mapping ${mappingId} is unavailable for ${provider}.`);
    }
    if (definition.valueType === "string" && definition.maxLength === null
      || (definition.valueType === "integer" || definition.valueType === "number")
        && (definition.minimum === null || definition.maximum === null)) {
      throw new Error(`Compatibility metadata mapping ${mappingId} is not explicitly bounded.`);
    }
    seen.add(mappingId);
    selected.push(definition);
  }
  return selected.sort((left, right) => compareText(left.id, right.id));
}

export function compatibilityMetadataValueIsValid(
  definition: CompatibilityMetadataDefinition,
  value: unknown,
): boolean {
  if (definition.valueType === "boolean") return typeof value === "boolean";
  if (definition.valueType === "string") {
    return typeof value === "string" && definition.maxLength !== null
      && value.length <= definition.maxLength;
  }
  if (typeof value !== "number" || !Number.isFinite(value)
    || definition.valueType === "integer" && !Number.isSafeInteger(value)) return false;
  return (definition.minimum === null || value >= definition.minimum)
    && (definition.maximum === null || value <= definition.maximum);
}
