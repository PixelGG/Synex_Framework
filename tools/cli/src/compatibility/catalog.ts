import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { Ajv2020, type AnySchema } from "ajv/dist/2020.js";

import { isRecord } from "../filesystem.ts";
import type {
  CompatibilityCatalog,
  CompatibilityCatalogDiagnostic,
  CompatibilityConsumer,
  CompatibilityMapping,
  CompatibilityMoneyPolicy,
  CompatibilityProfile,
  CompatibilityProvider,
  CompatibilityProviderCatalog,
  CompatibilityStatus,
  CompatibilitySurface,
} from "./types.ts";

const CATALOG_DIRECTORY = join("libraries", "synex_bridge", "compatibility");
const MAX_CATALOG_FILE_BYTES = 1024 * 1024;
const MAX_CATALOG_BYTES = 8 * 1024 * 1024;
const PROVIDERS = new Set<CompatibilityProvider>(["qb", "qbx", "esx"]);
const STATUSES = new Set<CompatibilityStatus>([
  "CERTIFIED", "COMPATIBLE", "PARTIAL", "UNSUPPORTED", "UNKNOWN",
]);
const CATALOG_DATA_FILES = [
  join("surfaces", "qb.json"),
  join("surfaces", "qbx.json"),
  join("surfaces", "esx.json"),
  "profiles.json",
  "consumers.json",
  "money-policies.json",
  "mappings.json",
] as const;
const EXPECTED_FILES = [
  join("schemas", "certification-execution.schema.json"),
  join("schemas", "surfaces.schema.json"),
  join("schemas", "profiles.schema.json"),
  join("schemas", "consumers.schema.json"),
  join("schemas", "money-policies.schema.json"),
  join("schemas", "mappings.schema.json"),
  ...CATALOG_DATA_FILES,
] as const;

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function catalogPath(path: string): string {
  return path.split(sep).join("/");
}

function stringValue(value: unknown, maximum = 256): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximum ? trimmed : null;
}

function nullableString(value: unknown, maximum = 256): string | null {
  return value === null || value === undefined ? null : stringValue(value, maximum);
}

function stringArray(value: unknown, maximumEntries = 256): string[] {
  if (!Array.isArray(value) || value.length > maximumEntries) return [];
  const output = value
    .map((entry) => stringValue(entry, 512))
    .filter((entry): entry is string => entry !== null);
  return [...new Set(output)].sort(compareText);
}

function objectNameArray(value: unknown, key: string, maximumEntries = 256): string[] {
  if (!Array.isArray(value) || value.length > maximumEntries) return [];
  return [...new Set(value.flatMap((entry) => {
    if (!isRecord(entry)) return [];
    const name = stringValue(entry[key], 256);
    return name ? [name] : [];
  }))].sort(compareText);
}

function adapterOperations(value: unknown): CompatibilitySurface["adapterOperations"] {
  if (!Array.isArray(value) || value.length > 32) return [];
  return value.flatMap((entry) => {
    if (!isRecord(entry)) return [];
    const name = stringValue(entry.name, 128);
    const nativeCapabilities = stringArray(entry.nativeCapabilities, 16);
    return name && nativeCapabilities.length > 0 ? [{ name, nativeCapabilities }] : [];
  }).sort((left, right) => compareText(left.name, right.name));
}

function catalogOperations(value: unknown): CompatibilitySurface["catalogOperations"] {
  return adapterOperations(value);
}

function providerValue(value: unknown): CompatibilityProvider | null {
  return typeof value === "string" && PROVIDERS.has(value as CompatibilityProvider)
    ? value as CompatibilityProvider
    : null;
}

function statusValue(value: unknown): CompatibilityStatus {
  return typeof value === "string" && STATUSES.has(value as CompatibilityStatus)
    ? value as CompatibilityStatus
    : "UNKNOWN";
}

function statusAllowed(mode: string, status: CompatibilityStatus): boolean {
  if (status === "UNSUPPORTED" || status === "UNKNOWN") return false;
  if (mode === "strict") return status === "CERTIFIED" || status === "COMPATIBLE";
  if (mode === "compat" || mode === "silent") {
    return status === "CERTIFIED" || status === "COMPATIBLE" || status === "PARTIAL";
  }
  return false;
}

export function certificationSurfaceEvidenceSatisfied(
  profile: CompatibilityProfile,
  surfaces: CompatibilitySurface[],
): boolean {
  if (profile.status !== "CERTIFIED" || profile.provider === null) return false;
  const requirements = Array.isArray(profile.raw.requiredSurfaces)
    ? profile.raw.requiredSurfaces
    : [];
  const evidence = isRecord(profile.raw.evidence) ? profile.raw.evidence : null;
  if (requirements.length === 0 || !evidence || !Array.isArray(evidence.tests)) return false;

  const profileTests = stringArray(evidence.tests, 32);
  if (profileTests.length !== evidence.tests.length) return false;
  const requiredTests = new Set<string>();
  const requiredNames = new Set<string>();
  for (const requirement of requirements) {
    if (!isRecord(requirement)) return false;
    const name = stringValue(requirement.name, 128);
    if (!name || requiredNames.has(name) || !Array.isArray(requirement.acceptedStatuses)
      || requirement.acceptedStatuses.length === 0) return false;
    requiredNames.add(name);

    const acceptedStatuses = requirement.acceptedStatuses.map(statusValue);
    if (new Set(acceptedStatuses).size !== acceptedStatuses.length
      || acceptedStatuses.some((status) => !statusAllowed(profile.mode, status))) return false;
    const matchingSurfaces = surfaces.filter((surface) =>
      surface.provider === profile.provider && surface.name === name);
    if (matchingSurfaces.length !== 1) return false;
    const surface = matchingSurfaces[0];
    if (!surface || !statusAllowed(profile.mode, surface.status)
      || !acceptedStatuses.includes(surface.status) || surface.tests.length === 0) return false;
    for (const testPath of surface.tests) requiredTests.add(testPath);
  }
  const evidenceSet = new Set(profileTests);
  return requiredTests.size > 0
    && [...requiredTests].every((testPath) => evidenceSet.has(testPath));
}

function profileEvidence(value: Record<string, unknown>): string[] {
  const evidence = isRecord(value.evidence) ? value.evidence : {};
  return [...new Set([
    ...stringArray(evidence.tests),
    ...stringArray(evidence.sourceUrls),
  ])].sort(compareText);
}

function profileTestedVersion(value: Record<string, unknown>): string | null {
  const script = isRecord(value.script) ? value.script : {};
  return stringValue(script.testedVersion, 128);
}

function profileUpstream(
  value: Record<string, unknown>,
): { repository: string; revision: string } | null {
  if (!isRecord(value.upstream)) return null;
  const repository = stringValue(value.upstream.repository, 512);
  const revision = stringValue(value.upstream.revision, 40);
  return repository && revision ? { repository, revision } : null;
}

function profileObjectKeys(
  value: unknown,
  keys: string[],
  maximumEntries = 128,
): string[] {
  if (!Array.isArray(value) || value.length > maximumEntries) return [];
  return [...new Set(value.flatMap((entry) => {
    if (!isRecord(entry)) return [];
    const parts = keys.map((key) => stringValue(entry[key], 256));
    return parts.every((part) => part !== null) ? [parts.join(":")] : [];
  }))].sort(compareText);
}

function profileEffectiveStatus(
  authored: CompatibilityStatus,
  value: Record<string, unknown>,
  evidence: string[],
  testedVersion: string | null,
): CompatibilityStatus {
  if (authored !== "CERTIFIED") return authored;
  const script = isRecord(value.script) ? value.script : null;
  const evidenceObject = isRecord(value.evidence) ? value.evidence : null;
  const tests = evidenceObject ? stringArray(evidenceObject.tests) : [];
  const declaredTestedVersion = script ? stringValue(script.testedVersion, 128) : null;
  const providerVersion = stringValue(value.providerVersion, 64);
  const targetFrameworkApiRange = stringValue(value.targetFrameworkApiRange, 64);
  const certificationArtifact = stringValue(value.certificationArtifact, 192);
  if (!script || tests.length === 0 || evidence.length === 0 || !testedVersion
    || declaredTestedVersion !== testedVersion || !providerVersion
    || !targetFrameworkApiRange || !certificationArtifact) {
    return "UNKNOWN";
  }
  return "CERTIFIED";
}

function normalizeProfile(
  value: Record<string, unknown>,
  index: number,
  diagnostics: CompatibilityCatalogDiagnostic[],
): CompatibilityProfile | null {
  const id = stringValue(value.id, 128) ?? stringValue(value.name, 128);
  if (!id) {
    diagnostics.push({
      severity: "error",
      code: "PROFILE_INVALID",
      path: `profiles.json#/profiles/${index}`,
      message: "Profile entries require a bounded id.",
    });
    return null;
  }
  const status = statusValue(value.status);
  const evidence = profileEvidence(value);
  const testedVersion = profileTestedVersion(value);
  const requiredAdapters = objectNameArray(value.requiredAdapters, "name");
  const requiredCatalogs = objectNameArray(value.requiredCatalogs, "name", 32);
  const surfaces = objectNameArray(value.requiredSurfaces, "name");
  const script = isRecord(value.script) ? stringValue(value.script.name, 128) : null;
  const version = stringValue(value.version, 64) ?? "0.0.0";
  return {
    id,
    version,
    script: script ?? "unknown",
    provider: providerValue(value.provider),
    mode: stringValue(value.mode, 64) ?? "strict",
    status,
    effectiveStatus: profileEffectiveStatus(status, value, evidence, testedVersion),
    testedVersion,
    providerVersion: stringValue(value.providerVersion, 64),
    targetFrameworkApiRange: stringValue(value.targetFrameworkApiRange, 64),
    vendor: nullableString(value.vendor, 96),
    upstream: profileUpstream(value),
    requiredDomains: stringArray(value.requiredDomains, 16),
    requiredExports: profileObjectKeys(value.requiredExports, ["side", "resource", "name"]),
    requiredEvents: profileObjectKeys(value.requiredEvents, ["direction", "name"]),
    directSql: profileObjectKeys(value.directSql, ["mode", "table"], 64),
    knownLimitations: stringArray(value.knownLimitations, 64),
    testedFlows: profileObjectKeys(value.testedFlows, ["status", "name"], 64),
    certificationArtifact: stringValue(value.certificationArtifact, 192),
    requiredAdapters,
    requiredCatalogs,
    surfaces,
    evidence,
    failurePolicy: stringValue(value.failurePolicy, 64) ?? "unknown",
    raw: value,
  };
}

function normalizeConsumer(
  value: Record<string, unknown>,
  index: number,
  defaultMode: string,
  diagnostics: CompatibilityCatalogDiagnostic[],
): CompatibilityConsumer | null {
  const id = stringValue(value.id, 128)
    ?? stringValue(value.resource, 128)
    ?? stringValue(value.name, 128);
  if (!id) {
    diagnostics.push({
      severity: "error",
      code: "CONSUMER_INVALID",
      path: `consumers.json#/consumers/${index}`,
      message: "Consumer entries require a bounded id or resource name.",
    });
    return null;
  }
  return {
    id,
    provider: providerValue(value.provider),
    profile: nullableString(value.profileId, 128),
    mode: nullableString(value.mode, 64) ?? defaultMode,
    enabled: value.enabled === true,
    failurePolicy: nullableString(value.failurePolicy, 64),
    raw: value,
  };
}

function normalizeMoneyPolicy(
  value: Record<string, unknown>,
  index: number,
  diagnostics: CompatibilityCatalogDiagnostic[],
): CompatibilityMoneyPolicy | null {
  const id = stringValue(value.id, 96);
  const version = stringValue(value.version, 32);
  const provider = providerValue(value.provider);
  const consumer = stringValue(value.consumer, 64);
  const moneyAlias = stringValue(value.moneyAlias, 32);
  const legacyReason = stringValue(value.legacyReason, 128);
  const nativeReasonCode = stringValue(value.nativeReasonCode, 96);
  const direction = value.direction === "add" || value.direction === "remove"
    ? value.direction
    : null;
  const action = value.action === "transfer" || value.action === "mint" || value.action === "burn"
    ? value.action
    : null;
  const status = value.status === "ACTIVE" || value.status === "DISABLED" ? value.status : null;
  if (!id || !version || !provider || !consumer || !moneyAlias || !legacyReason
    || !nativeReasonCode || !direction || !action || !status) {
    diagnostics.push({
      severity: "error",
      code: "MONEY_POLICY_INVALID",
      path: `money-policies.json#/policies/${index}`,
      message: "Money policies require complete bounded provider, consumer, alias, reason, action, and status fields.",
    });
    return null;
  }
  return {
    id,
    version,
    provider,
    consumer,
    moneyAlias,
    direction,
    legacyReason,
    action,
    accountId: nullableString(value.accountId, 36),
    nativeReasonCode,
    status,
    raw: value,
  };
}

function normalizeMapping(
  category: CompatibilityMapping["category"],
  value: Record<string, unknown>,
  index: number,
  diagnostics: CompatibilityCatalogDiagnostic[],
): CompatibilityMapping | null {
  const id = stringValue(value.id, 128);
  const legacy = category === "identity"
    ? stringValue(value.legacyId, 256)
    : category === "accounts"
      ? stringValue(value.alias, 256)
      : category === "groups"
        ? [stringValue(value.legacyType, 64), stringValue(value.legacyName, 256)].filter(Boolean).join(":")
        : category === "permissions"
          ? stringValue(value.legacyGroup, 256)
          : stringValue(value.key, 256);
  if (!legacy) {
    diagnostics.push({
      severity: "error",
      code: "MAPPING_INVALID",
      path: `mappings.json#/${category}/${index}`,
      message: "Mapping entries require a bounded legacy/source value.",
    });
    return null;
  }
  if (!id) {
    diagnostics.push({
      severity: "error",
      code: "MAPPING_INVALID",
      path: `mappings.json#/${category}/${index}`,
      message: "Mapping entries require a bounded id.",
    });
    return null;
  }
  const native = category === "identity"
    ? stringValue(value.nativeId, 256)
    : category === "accounts"
      ? [
        stringValue(value.currencyCode, 16),
        stringValue(value.accountKey, 64),
        stringValue(value.accountRole, 16),
        typeof value.minorUnit === "number" && Number.isSafeInteger(value.minorUnit)
          ? String(value.minorUnit)
          : null,
      ].every((entry) => entry !== null)
        ? [value.currencyCode, value.accountKey, value.accountRole, value.minorUnit].join(":")
        : null
      : category === "groups"
        ? stringValue(value.nativeGroupKey, 256)
        : category === "permissions"
          ? stringValue(value.nativePermission, 256)
          : stringValue(value.storageKey, 256);
  return {
    id,
    category,
    provider: providerValue(value.provider),
    legacy,
    native,
    adapter: nullableString(value.adapter, 128) ?? nullableString(value.requiredAdapter, 128),
    status: statusValue(value.status),
    raw: value,
  };
}

async function readCatalogFile(
  root: string,
  relativePath: string,
  diagnostics: CompatibilityCatalogDiagnostic[],
): Promise<{ value: unknown; bytes: number } | null> {
  const path = join(root, relativePath);
  let metadata;
  try {
    metadata = await lstat(path);
  } catch (error) {
    const code = isRecord(error) && typeof error.code === "string" ? error.code : "READ_FAILED";
    diagnostics.push({
      severity: "warning",
      code: "CATALOG_FILE_MISSING",
      path: catalogPath(relativePath),
      message: `Catalog artifact is unavailable (${code}).`,
    });
    return null;
  }
  if (metadata.isSymbolicLink() || !metadata.isFile() || metadata.size > MAX_CATALOG_FILE_BYTES) {
    diagnostics.push({
      severity: "error",
      code: "CATALOG_FILE_UNSAFE",
      path: catalogPath(relativePath),
      message: `Catalog artifacts must be regular non-symlink files no larger than ${MAX_CATALOG_FILE_BYTES} bytes.`,
    });
    return null;
  }
  try {
    return { value: JSON.parse(await readFile(path, "utf8")) as unknown, bytes: metadata.size };
  } catch {
    diagnostics.push({
      severity: "error",
      code: "CATALOG_JSON_INVALID",
      path: catalogPath(relativePath),
      message: "Catalog artifact is not valid JSON.",
    });
    return null;
  }
}

async function relativePathContainsSymlink(repositoryRoot: string, relativePath: string): Promise<boolean> {
  let current = resolve(repositoryRoot);
  for (const segment of relativePath.split(sep).filter(Boolean)) {
    current = join(current, segment);
    try {
      if ((await lstat(current)).isSymbolicLink()) return true;
    } catch {
      return false;
    }
  }
  return false;
}

async function catalogPathContainsSymlink(repositoryRoot: string): Promise<boolean> {
  return relativePathContainsSymlink(repositoryRoot, CATALOG_DIRECTORY);
}

async function profileEvidenceExists(
  repositoryRoot: string,
  profile: CompatibilityProfile,
): Promise<boolean> {
  const evidence = isRecord(profile.raw.evidence) ? profile.raw.evidence : null;
  const tests = evidence ? stringArray(evidence.tests, 32) : [];
  const sourceUrls = evidence ? stringArray(evidence.sourceUrls, 16) : [];
  if (tests.length === 0 || sourceUrls.length === 0
    || sourceUrls.some((url) => !url.startsWith("https://"))) return false;
  for (const test of tests) {
    if (isAbsolute(test)) return false;
    const path = resolve(repositoryRoot, test);
    const value = relative(repositoryRoot, path);
    if (value === ".." || value.startsWith(`..${sep}`) || isAbsolute(value)) return false;
    if (await relativePathContainsSymlink(repositoryRoot, value)) return false;
    try {
      const metadata = await lstat(path);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    } catch {
      return false;
    }
  }
  return true;
}

function validateCatalogArtifact(
  artifact: unknown,
  schema: unknown,
  path: string,
  diagnostics: CompatibilityCatalogDiagnostic[],
): boolean {
  if (schema === undefined) return true;
  if (!isRecord(schema)) {
    diagnostics.push({
      severity: "error", code: "CATALOG_SCHEMA_INVALID", path,
      message: "The catalog schema artifact is not an object.",
    });
    return false;
  }
  try {
    const validator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false })
      .compile(schema as AnySchema);
    if (validator(artifact)) return true;
    diagnostics.push({
      severity: "error", code: "CATALOG_SCHEMA_MISMATCH", path,
      message: `Catalog artifact does not satisfy its schema (${validator.errors?.length ?? 0} error(s)).`,
    });
    return false;
  } catch {
    diagnostics.push({
      severity: "error", code: "CATALOG_SCHEMA_INVALID", path,
      message: "The catalog schema could not be compiled.",
    });
    return false;
  }
}

export async function loadCompatibilityCatalog(repositoryRoot: string): Promise<CompatibilityCatalog> {
  const root = resolve(repositoryRoot, CATALOG_DIRECTORY);
  const diagnostics: CompatibilityCatalogDiagnostic[] = [];
  if (await catalogPathContainsSymlink(repositoryRoot)) {
    return {
      schema: 1,
      root: catalogPath(relative(repositoryRoot, root)),
      available: false,
      files: [], providerCatalogs: [], surfaces: [], profiles: [], consumers: [], moneyPolicies: [], mappings: [],
      forbiddenMetadataFields: [],
      diagnostics: [{
        severity: "error",
        code: "CATALOG_ROOT_UNSAFE",
        path: catalogPath(relative(repositoryRoot, root)),
        message: "The compatibility catalog path must not traverse symbolic links.",
      }],
    };
  }
  let rootMetadata;
  try {
    rootMetadata = await lstat(root);
  } catch {
    return {
      schema: 1,
      root: catalogPath(relative(repositoryRoot, root)),
      available: false,
      files: [], providerCatalogs: [], surfaces: [], profiles: [], consumers: [], moneyPolicies: [], mappings: [],
      forbiddenMetadataFields: [],
      diagnostics: [{
        severity: "warning",
        code: "CATALOG_UNAVAILABLE",
        path: catalogPath(relative(repositoryRoot, root)),
        message: "The checked-in compatibility catalog is not available in this snapshot.",
      }],
    };
  }
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    return {
      schema: 1,
      root: catalogPath(relative(repositoryRoot, root)),
      available: false,
      files: [], providerCatalogs: [], surfaces: [], profiles: [], consumers: [], moneyPolicies: [], mappings: [],
      forbiddenMetadataFields: [],
      diagnostics: [{
        severity: "error",
        code: "CATALOG_ROOT_UNSAFE",
        path: catalogPath(relative(repositoryRoot, root)),
        message: "The compatibility catalog root must be a real directory, not a symlink.",
      }],
    };
  }

  const loaded = new Map<string, unknown>();
  const files: string[] = [];
  let totalBytes = 0;
  for (const relativePath of EXPECTED_FILES) {
    const artifact = await readCatalogFile(root, relativePath, diagnostics);
    if (!artifact) continue;
    totalBytes += artifact.bytes;
    if (totalBytes > MAX_CATALOG_BYTES) {
      diagnostics.push({
        severity: "error",
        code: "CATALOG_TOTAL_LIMIT_EXCEEDED",
        path: catalogPath(relativePath),
        message: `Catalog artifacts exceed the ${MAX_CATALOG_BYTES} byte aggregate limit.`,
      });
      break;
    }
    loaded.set(catalogPath(relativePath), artifact.value);
    files.push(catalogPath(relativePath));
  }

  const providerCatalogs: CompatibilityProviderCatalog[] = [];
  const surfaces: CompatibilitySurface[] = [];
  for (const provider of ["qb", "qbx", "esx"] as const) {
    const path = `surfaces/${provider}.json`;
    const artifact = loaded.get(path);
    if (!validateCatalogArtifact(
      artifact,
      loaded.get("schemas/surfaces.schema.json"),
      path,
      diagnostics,
    )) continue;
    if (!isRecord(artifact) || artifact.schema !== 1
      || artifact.kind !== "synex-compatibility-surfaces"
      || artifact.provider !== provider || !Array.isArray(artifact.surfaces)) {
      if (artifact !== undefined) diagnostics.push({
        severity: "error", code: "SURFACE_CATALOG_INVALID", path,
        message: "Surface catalog header, provider, or entries are invalid.",
      });
      continue;
    }
    const providerResource = stringValue(artifact.providerResource, 64);
    const providerVersion = stringValue(artifact.providerVersion, 64);
    const targetFrameworkApiRange = nullableString(artifact.targetFrameworkApiRange, 64);
    if (providerResource !== `synex_bridge_${provider}` || !providerVersion) {
      diagnostics.push({
        severity: "error", code: "SURFACE_PROVIDER_BINDING_INVALID", path,
        message: "Surface catalog provider resource or provider version is invalid.",
      });
      continue;
    }
    providerCatalogs.push({
      provider, providerResource, providerVersion, targetFrameworkApiRange,
    });
    artifact.surfaces.forEach((entry, index) => {
      if (!isRecord(entry)) {
        diagnostics.push({
          severity: "error", code: "SURFACE_INVALID", path: `${path}#/surfaces/${index}`,
          message: "Surface entries must be objects.",
        });
        return;
      }
      const name = stringValue(entry.name, 256);
      const scope = stringValue(entry.scope, 64);
      const type = stringValue(entry.type, 64);
      if (!name || !scope || !type) {
        diagnostics.push({
          severity: "error", code: "SURFACE_INVALID", path: `${path}#/surfaces/${index}`,
          message: "Surface entries require bounded name, scope, and type values.",
        });
        return;
      }
      surfaces.push({
        provider,
        providerVersion,
        targetFrameworkApiRange,
        name,
        scope,
        type,
        status: statusValue(entry.status),
        legacyVersionRange: nullableString(entry.legacyVersionRange, 128),
        nativeMapping: nullableString(entry.nativeMapping, 512),
        requiredCapability: nullableString(entry.requiredCapability, 256),
        requiredAdapter: nullableString(entry.requiredAdapter, 128),
        adapterOperations: adapterOperations(entry.adapterOperations),
        requiredCatalog: nullableString(entry.requiredCatalog, 128),
        catalogOperations: catalogOperations(entry.catalogOperations),
        modes: stringArray(entry.modes, 16),
        deprecated: entry.deprecated === true,
        tests: stringArray(entry.tests),
      });
    });
  }

  const profiles: CompatibilityProfile[] = [];
  const profileArtifact = loaded.get("profiles.json");
  const profileSchemaValid = validateCatalogArtifact(
    profileArtifact,
    loaded.get("schemas/profiles.schema.json"),
    "profiles.json",
    diagnostics,
  );
  if (profileSchemaValid && isRecord(profileArtifact) && profileArtifact.schema === 1
    && profileArtifact.kind === "synex-compatibility-profiles"
    && Array.isArray(profileArtifact.profiles)) {
    profileArtifact.profiles.forEach((entry, index) => {
      if (!isRecord(entry)) {
        diagnostics.push({
          severity: "error", code: "PROFILE_INVALID", path: `profiles.json#/profiles/${index}`,
          message: "Profile entries must be objects.",
        });
        return;
      }
      const profile = normalizeProfile(entry, index, diagnostics);
      if (profile) profiles.push(profile);
    });
  } else if (profileArtifact !== undefined) {
    diagnostics.push({
      severity: "error", code: "PROFILE_CATALOG_INVALID", path: "profiles.json",
      message: "Profile catalog header or entries are invalid.",
    });
  }

  const consumers: CompatibilityConsumer[] = [];
  const consumerArtifact = loaded.get("consumers.json");
  const consumerSchemaValid = validateCatalogArtifact(
    consumerArtifact,
    loaded.get("schemas/consumers.schema.json"),
    "consumers.json",
    diagnostics,
  );
  if (consumerSchemaValid && isRecord(consumerArtifact) && consumerArtifact.schema === 1
    && consumerArtifact.kind === "synex-compatibility-consumers"
    && Array.isArray(consumerArtifact.consumers)) {
    const defaultMode = stringValue(consumerArtifact.defaultMode, 64) ?? "strict";
    consumerArtifact.consumers.forEach((entry, index) => {
      if (!isRecord(entry)) {
        diagnostics.push({
          severity: "error", code: "CONSUMER_INVALID", path: `consumers.json#/consumers/${index}`,
          message: "Consumer entries must be objects.",
        });
        return;
      }
      const consumer = normalizeConsumer(entry, index, defaultMode, diagnostics);
      if (consumer) consumers.push(consumer);
    });
  } else if (consumerArtifact !== undefined) {
    diagnostics.push({
      severity: "error", code: "CONSUMER_CATALOG_INVALID", path: "consumers.json",
      message: "Consumer catalog header or entries are invalid.",
    });
  }

  const moneyPolicies: CompatibilityMoneyPolicy[] = [];
  const moneyPolicyArtifact = loaded.get("money-policies.json");
  const moneyPolicySchemaValid = validateCatalogArtifact(
    moneyPolicyArtifact,
    loaded.get("schemas/money-policies.schema.json"),
    "money-policies.json",
    diagnostics,
  );
  if (moneyPolicySchemaValid && isRecord(moneyPolicyArtifact) && moneyPolicyArtifact.schema === 1
    && moneyPolicyArtifact.kind === "synex-compatibility-money-policies"
    && Array.isArray(moneyPolicyArtifact.policies)) {
    moneyPolicyArtifact.policies.forEach((entry, index) => {
      if (!isRecord(entry)) {
        diagnostics.push({
          severity: "error", code: "MONEY_POLICY_INVALID",
          path: `money-policies.json#/policies/${index}`,
          message: "Money policy entries must be objects.",
        });
        return;
      }
      const policy = normalizeMoneyPolicy(entry, index, diagnostics);
      if (policy) moneyPolicies.push(policy);
    });
  } else if (moneyPolicyArtifact !== undefined) {
    diagnostics.push({
      severity: "error", code: "MONEY_POLICY_CATALOG_INVALID", path: "money-policies.json",
      message: "Money policy catalog header or entries are invalid.",
    });
  }

  const mappings: CompatibilityMapping[] = [];
  let forbiddenMetadataFields: string[] = [];
  const mappingArtifact = loaded.get("mappings.json");
  const mappingSchemaValid = validateCatalogArtifact(
    mappingArtifact,
    loaded.get("schemas/mappings.schema.json"),
    "mappings.json",
    diagnostics,
  );
  if (mappingSchemaValid && isRecord(mappingArtifact) && mappingArtifact.schema === 1
    && mappingArtifact.kind === "synex-compatibility-mappings") {
    for (const category of ["identity", "accounts", "groups", "metadata", "permissions"] as const) {
      const entries = mappingArtifact[category];
      if (!Array.isArray(entries)) {
        diagnostics.push({
          severity: "error", code: "MAPPING_CATEGORY_INVALID", path: `mappings.json#/${category}`,
          message: "Mapping categories must be arrays.",
        });
        continue;
      }
      entries.forEach((entry, index) => {
        if (!isRecord(entry)) {
          diagnostics.push({
            severity: "error", code: "MAPPING_INVALID", path: `mappings.json#/${category}/${index}`,
            message: "Mapping entries must be objects.",
          });
          return;
        }
        const mapping = normalizeMapping(category, entry, index, diagnostics);
        if (mapping) mappings.push(mapping);
      });
    }
    forbiddenMetadataFields = stringArray(mappingArtifact.forbiddenMetadataFields);
  } else if (mappingArtifact !== undefined) {
    diagnostics.push({
      severity: "error", code: "MAPPING_CATALOG_INVALID", path: "mappings.json",
      message: "Mapping catalog header is invalid.",
    });
  }

  for (const profile of profiles) {
    if (profile.effectiveStatus !== "CERTIFIED") continue;
    const providerCatalog = providerCatalogs.find((entry) => entry.provider === profile.provider);
    if (profile.surfaces.length === 0 || profile.provider === null
      || providerCatalog === undefined
      || profile.providerVersion !== providerCatalog.providerVersion
      || profile.targetFrameworkApiRange !== providerCatalog.targetFrameworkApiRange
      || !(await profileEvidenceExists(repositoryRoot, profile))) {
      profile.effectiveStatus = "UNKNOWN";
      continue;
    }
    if (!certificationSurfaceEvidenceSatisfied(profile, surfaces)) {
      profile.effectiveStatus = "UNKNOWN";
    }
  }

  surfaces.sort((left, right) => compareText(left.provider, right.provider)
    || compareText(left.name, right.name));
  profiles.sort((left, right) => compareText(left.id, right.id));
  consumers.sort((left, right) => compareText(left.id, right.id));
  moneyPolicies.sort((left, right) => compareText(left.provider, right.provider)
    || compareText(left.consumer, right.consumer) || compareText(left.moneyAlias, right.moneyAlias)
    || compareText(left.direction, right.direction) || compareText(left.legacyReason, right.legacyReason)
    || compareText(left.id, right.id));
  mappings.sort((left, right) => compareText(left.category, right.category)
    || compareText(left.provider ?? "", right.provider ?? "")
    || compareText(left.legacy, right.legacy));
  diagnostics.sort((left, right) => compareText(left.path, right.path)
    || compareText(left.code, right.code));

  return {
    schema: 1,
    root: catalogPath(relative(repositoryRoot, root)),
    available: CATALOG_DATA_FILES.some((path) => loaded.has(catalogPath(path))),
    files: files.sort(compareText),
    providerCatalogs: providerCatalogs.sort((left, right) =>
      compareText(left.provider, right.provider)),
    surfaces, profiles, consumers, moneyPolicies, mappings, forbiddenMetadataFields, diagnostics,
  };
}
