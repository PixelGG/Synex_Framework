import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_MIGRATION_ARTIFACT_BYTES, MAX_MIGRATION_MEMBERSHIPS } from "./limits.ts";
import { pathContainsSymbolicLink } from "./path-safety.ts";

export type CompatibilityGroupProvider = "qb" | "qbx" | "esx";
export type CompatibilityLegacyGroupType = "job" | "gang";

export interface CompatibilityGroupGradeDefinition {
  legacyGrade: number;
  gradeKey: string;
}

export interface CompatibilityGroupDefinition {
  id: string;
  version: string;
  provider: CompatibilityGroupProvider;
  legacyType: CompatibilityLegacyGroupType;
  legacyName: string;
  nativeGroupKey: string;
  nativeGroupType: string;
  grades: CompatibilityGroupGradeDefinition[];
  bossRoles: string[];
  dutySupported: boolean;
  dutyState: string | null;
  status: "CERTIFIED" | "COMPATIBLE" | "PARTIAL" | "UNSUPPORTED" | "UNKNOWN";
}

export interface CompatibilityGroupCatalog {
  digest: string;
  definitions: CompatibilityGroupDefinition[];
  byId: ReadonlyMap<string, CompatibilityGroupDefinition>;
  byProviderLegacy: ReadonlyMap<string, CompatibilityGroupDefinition>;
}

const PROVIDERS = new Set<CompatibilityGroupProvider>(["qb", "qbx", "esx"]);
const LEGACY_TYPES = new Set<CompatibilityLegacyGroupType>(["job", "gang"]);
const STATUSES = new Set<CompatibilityGroupDefinition["status"]>([
  "CERTIFIED", "COMPATIBLE", "PARTIAL", "UNSUPPORTED", "UNKNOWN",
]);
const ID_PATTERN = /^[a-z][a-z0-9_.:-]{0,95}$/u;
const VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/u;
const LEGACY_NAME_PATTERN = /^[a-z][a-z0-9_.-]{0,63}$/u;
const NATIVE_KEY_PATTERN = /^[a-z][a-z0-9_.:-]{0,63}$/u;
const DUTY_STATE_PATTERN = /^[a-z][a-z0-9_-]{1,31}$/u;
const ALLOWED_FIELDS = new Set([
  "id", "version", "provider", "legacyType", "legacyName", "nativeGroupKey",
  "nativeGroupType", "grades", "bossRoles", "dutySupported", "dutyState", "status",
]);
const REQUIRED_FIELDS = [
  "id", "version", "provider", "legacyType", "legacyName", "nativeGroupKey",
  "nativeGroupType", "grades", "dutySupported", "status",
] as const;

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

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function validateCompatibilityGroupCatalog(value: unknown): CompatibilityGroupCatalog {
  if (!isRecord(value) || value.schema !== 1 || value.kind !== "synex-compatibility-mappings"
    || !Array.isArray(value.groups) || value.groups.length > MAX_MIGRATION_MEMBERSHIPS) {
    throw new Error("The checked-in compatibility group catalog has an invalid envelope.");
  }
  const definitions: CompatibilityGroupDefinition[] = [];
  const ids = new Set<string>();
  const legacyMappings = new Set<string>();
  for (const [index, raw] of value.groups.entries()) {
    if (!isRecord(raw) || Object.keys(raw).some((field) => !ALLOWED_FIELDS.has(field))
      || REQUIRED_FIELDS.some((field) => !Object.hasOwn(raw, field))
      || typeof raw.id !== "string" || !ID_PATTERN.test(raw.id)
      || typeof raw.version !== "string" || !VERSION_PATTERN.test(raw.version)
      || typeof raw.provider !== "string" || !PROVIDERS.has(raw.provider as CompatibilityGroupProvider)
      || typeof raw.legacyType !== "string"
      || !LEGACY_TYPES.has(raw.legacyType as CompatibilityLegacyGroupType)
      || typeof raw.legacyName !== "string" || !LEGACY_NAME_PATTERN.test(raw.legacyName)
      || typeof raw.nativeGroupKey !== "string" || !NATIVE_KEY_PATTERN.test(raw.nativeGroupKey)
      || typeof raw.nativeGroupType !== "string" || !NATIVE_KEY_PATTERN.test(raw.nativeGroupType)
      || !Array.isArray(raw.grades) || raw.grades.length < 1 || raw.grades.length > 128
      || typeof raw.dutySupported !== "boolean"
      || typeof raw.status !== "string"
      || !STATUSES.has(raw.status as CompatibilityGroupDefinition["status"])) {
      throw new Error(`Compatibility group mapping ${index} is invalid.`);
    }
    const grades: CompatibilityGroupGradeDefinition[] = [];
    const legacyGrades = new Set<number>();
    const gradeKeys = new Set<string>();
    for (const grade of raw.grades) {
      if (!isRecord(grade) || Object.keys(grade).length !== 2
        || !Object.hasOwn(grade, "legacyGrade") || !Object.hasOwn(grade, "gradeKey")
        || typeof grade.legacyGrade !== "number" || !Number.isSafeInteger(grade.legacyGrade)
        || grade.legacyGrade < 0 || grade.legacyGrade > 65_535
        || typeof grade.gradeKey !== "string" || !NATIVE_KEY_PATTERN.test(grade.gradeKey)
        || legacyGrades.has(grade.legacyGrade) || gradeKeys.has(grade.gradeKey)) {
        throw new Error(`Compatibility group mapping ${raw.id} has invalid or ambiguous grades.`);
      }
      legacyGrades.add(grade.legacyGrade);
      gradeKeys.add(grade.gradeKey);
      grades.push({ legacyGrade: grade.legacyGrade, gradeKey: grade.gradeKey });
    }
    grades.sort((left, right) => left.legacyGrade - right.legacyGrade);
    const bossRoles = raw.bossRoles ?? [];
    if (!Array.isArray(bossRoles) || bossRoles.length > 32
      || bossRoles.some((role) => typeof role !== "string" || !NATIVE_KEY_PATTERN.test(role))
      || new Set(bossRoles).size !== bossRoles.length) {
      throw new Error(`Compatibility group mapping ${raw.id} has invalid boss roles.`);
    }
    const dutyState: string | null = typeof raw.dutyState === "string" ? raw.dutyState : null;
    if (raw.dutySupported === true
      ? typeof dutyState !== "string" || !DUTY_STATE_PATTERN.test(dutyState)
      : dutyState !== null) {
      throw new Error(`Compatibility group mapping ${raw.id} has an invalid duty mapping.`);
    }
    const provider = raw.provider as CompatibilityGroupProvider;
    const legacyType = raw.legacyType as CompatibilityLegacyGroupType;
    const legacyIdentity = `${provider}:${legacyType}:${raw.legacyName}`;
    if (ids.has(raw.id) || legacyMappings.has(legacyIdentity)) {
      throw new Error(`Compatibility group mapping ${raw.id} is ambiguous.`);
    }
    ids.add(raw.id);
    legacyMappings.add(legacyIdentity);
    definitions.push({
      id: raw.id,
      version: raw.version,
      provider,
      legacyType,
      legacyName: raw.legacyName,
      nativeGroupKey: raw.nativeGroupKey,
      nativeGroupType: raw.nativeGroupType,
      grades,
      bossRoles: [...bossRoles] as string[],
      dutySupported: raw.dutySupported,
      dutyState,
      status: raw.status as CompatibilityGroupDefinition["status"],
    });
  }
  definitions.sort((left, right) => compareText(left.id, right.id));
  return {
    digest: digest(canonicalJson({
      schema: 1,
      kind: "synex-compatibility-group-bindings",
      definitions,
    })),
    definitions,
    byId: new Map(definitions.map((definition) => [definition.id, definition])),
    byProviderLegacy: new Map(definitions.map((definition) => [
      `${definition.provider}:${definition.legacyType}:${definition.legacyName}`,
      definition,
    ])),
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

export async function loadCompatibilityGroupCatalog(
  path = defaultCatalogPath(),
): Promise<CompatibilityGroupCatalog> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || await pathContainsSymbolicLink(path)
    || metadata.size > MAX_MIGRATION_ARTIFACT_BYTES) {
    throw new Error("The checked-in compatibility group catalog must be a bounded non-symlink file.");
  }
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8")) as unknown;
  } catch {
    throw new Error("The checked-in compatibility group catalog is not valid JSON.");
  }
  return validateCompatibilityGroupCatalog(value);
}

export function selectCompatibilityGroupDefinitions(
  catalog: CompatibilityGroupCatalog,
  provider: CompatibilityGroupProvider,
  mappingIds: unknown,
): CompatibilityGroupDefinition[] {
  if (!Array.isArray(mappingIds) || mappingIds.length < 1
    || mappingIds.length > MAX_MIGRATION_MEMBERSHIPS) {
    throw new Error("compatibilityGroups.mappingIds must contain a bounded non-empty array.");
  }
  const selected: CompatibilityGroupDefinition[] = [];
  const seen = new Set<string>();
  for (const [index, mappingId] of mappingIds.entries()) {
    if (typeof mappingId !== "string" || !ID_PATTERN.test(mappingId) || seen.has(mappingId)) {
      throw new Error(`compatibilityGroups.mappingIds[${index}] is invalid or duplicated.`);
    }
    const definition = catalog.byId.get(mappingId);
    if (!definition || definition.provider !== provider
      || definition.status === "UNSUPPORTED" || definition.status === "UNKNOWN") {
      throw new Error(`Compatibility group mapping ${mappingId} is unavailable for ${provider}.`);
    }
    seen.add(mappingId);
    selected.push(definition);
  }
  return selected.sort((left, right) => compareText(left.id, right.id));
}
