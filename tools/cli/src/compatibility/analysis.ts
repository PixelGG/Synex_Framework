import { lstat } from "node:fs/promises";
import { join } from "node:path";

import { isRecord } from "../filesystem.ts";
import {
  inspectRuntimeEvidence,
  RUNTIME_DEPRECATED_WARNING_BASIS_POINTS,
  RUNTIME_RATE_MINIMUM_CALLS,
  RUNTIME_UNSUPPORTED_WARNING_BASIS_POINTS,
  type RuntimeCompatibilityEvidence,
} from "./evidence.ts";
import type {
  CompatibilityCatalog,
  CompatibilityDoctorCheck,
  CompatibilityDoctorFinding,
  CompatibilityDoctorReport,
  CompatibilityProfile,
  CompatibilityProvider,
  CompatibilityReport,
  CompatibilityStatus,
  CompatibilitySurface,
} from "./types.ts";

const COMPATIBILITY_PROVIDERS = ["qb", "qbx", "esx"] as const;

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function aggregateStatuses(statuses: CompatibilityStatus[]): CompatibilityStatus {
  if (statuses.length === 0) return "UNKNOWN";
  if (statuses.includes("PARTIAL")) return "PARTIAL";
  if (statuses.includes("COMPATIBLE")) return "COMPATIBLE";
  if (statuses.every((status) => status === "CERTIFIED")) return "CERTIFIED";
  if (statuses.includes("UNKNOWN")) return "UNKNOWN";
  return "UNSUPPORTED";
}

function normalizedSurface(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/gu, "");
}

function surfaceCandidates(
  catalog: CompatibilityCatalog,
  provider: CompatibilityProvider,
  requested: string,
): CompatibilitySurface[] {
  const needle = normalizedSurface(requested);
  return catalog.surfaces.filter((surface) => {
    if (surface.provider !== provider) return false;
    const candidate = normalizedSurface(surface.name);
    return candidate === needle || candidate.endsWith(needle) || needle.endsWith(candidate);
  });
}

export interface CompatibilityMatrixReport {
  schema: 1;
  artifactKind: "synex-compatibility-matrix";
  status: CompatibilityStatus;
  catalogAvailable: boolean;
  rows: Array<{
    provider: CompatibilityProvider;
    providerVersion: string;
    targetFrameworkApiRange: string | null;
    name: string;
    scope: string;
    type: string;
    status: CompatibilityStatus;
    legacyVersionRange: string | null;
    nativeMapping: string | null;
    requiredCapability: string | null;
    requiredAdapter: string | null;
    adapterOperations: Array<{ name: string; nativeCapabilities: string[] }>;
    requiredCatalog: string | null;
    catalogOperations: Array<{ name: string; nativeCapabilities: string[] }>;
    modes: string[];
    deprecated: boolean;
    evidenceTests: string[];
  }>;
  disclaimer: string;
}

export function buildCompatibilityMatrix(catalog: CompatibilityCatalog): CompatibilityMatrixReport {
  const rows = catalog.surfaces.map((surface) => ({
    provider: surface.provider,
    providerVersion: surface.providerVersion,
    targetFrameworkApiRange: surface.targetFrameworkApiRange,
    name: surface.name,
    scope: surface.scope,
    type: surface.type,
    status: surface.status,
    legacyVersionRange: surface.legacyVersionRange,
    nativeMapping: surface.nativeMapping,
    requiredCapability: surface.requiredCapability,
    requiredAdapter: surface.requiredAdapter,
    adapterOperations: surface.adapterOperations.map((operation) => ({
      name: operation.name,
      nativeCapabilities: [...operation.nativeCapabilities],
    })),
    requiredCatalog: surface.requiredCatalog,
    catalogOperations: surface.catalogOperations.map((operation) => ({
      name: operation.name,
      nativeCapabilities: [...operation.nativeCapabilities],
    })),
    modes: [...surface.modes],
    deprecated: surface.deprecated,
    evidenceTests: [...surface.tests],
  })).sort((left, right) => compareText(left.provider, right.provider)
    || compareText(left.name, right.name) || compareText(left.scope, right.scope));
  return {
    schema: 1,
    artifactKind: "synex-compatibility-matrix",
    status: aggregateStatuses(rows.map((row) => row.status)),
    catalogAvailable: catalog.available,
    rows,
    disclaimer: "Catalog status applies only to the named provider version, target-framework API range, surface, mode, and checked-in evidence.",
  };
}

export interface CompatibilityStatusReport {
  schema: 1;
  artifactKind: "synex-compatibility-status";
  status: CompatibilityStatus;
  catalogAvailable: boolean;
  providers: Array<{
    provider: CompatibilityProvider;
    status: CompatibilityStatus;
    counts: Record<CompatibilityStatus, number>;
  }>;
  counts: {
    surfaces: number;
    profiles: number;
    consumers: number;
    moneyPolicies: number;
    mappings: number;
    catalogDiagnostics: number;
  };
  disclaimer: string;
}

function emptyStatusCounts(): Record<CompatibilityStatus, number> {
  return { CERTIFIED: 0, COMPATIBLE: 0, PARTIAL: 0, UNSUPPORTED: 0, UNKNOWN: 0 };
}

export function buildCompatibilityStatus(catalog: CompatibilityCatalog): CompatibilityStatusReport {
  const providers = (["qb", "qbx", "esx"] as const).map((provider) => {
    const statuses = catalog.surfaces
      .filter((surface) => surface.provider === provider)
      .map((surface) => surface.status);
    const counts = emptyStatusCounts();
    for (const status of statuses) counts[status] += 1;
    return { provider, status: aggregateStatuses(statuses), counts };
  });
  return {
    schema: 1,
    artifactKind: "synex-compatibility-status",
    status: aggregateStatuses(providers.map((provider) => provider.status)),
    catalogAvailable: catalog.available,
    providers,
    counts: {
      surfaces: catalog.surfaces.length,
      profiles: catalog.profiles.length,
      consumers: catalog.consumers.length,
      moneyPolicies: catalog.moneyPolicies.length,
      mappings: catalog.mappings.length,
      catalogDiagnostics: catalog.diagnostics.length,
    },
    disclaimer: "Status is catalog-derived and does not certify a deployment, consumer, or untested upstream version.",
  };
}

export interface CompatibilityExplanationReport {
  schema: 1;
  artifactKind: "synex-compatibility-explanation";
  status: CompatibilityStatus;
  scan: CompatibilityReport;
  resolved: Array<{
    file: string;
    line: number;
    provider: CompatibilityProvider;
    requestedSurface: string;
    matches: Array<{
      name: string;
      status: CompatibilityStatus;
      legacyVersionRange: string | null;
      nativeMapping: string | null;
      requiredAdapter: string | null;
    }>;
  }>;
  unresolved: Array<{ file: string; line: number; signal: string; reason: string }>;
  disclaimer: string;
}

export function explainCompatibility(
  scan: CompatibilityReport,
  catalog: CompatibilityCatalog,
): CompatibilityExplanationReport {
  const resolved: CompatibilityExplanationReport["resolved"] = [];
  const unresolved: CompatibilityExplanationReport["unresolved"] = [];
  const matchedStatuses: CompatibilityStatus[] = [];
  for (const finding of scan.findings) {
    if (finding.category !== "surface" || !finding.surface || !finding.provider) continue;
    const matches = surfaceCandidates(catalog, finding.provider, finding.surface);
    if (matches.length === 0) {
      unresolved.push({
        file: finding.file,
        line: finding.line,
        signal: finding.surface,
        reason: "No exact cataloged surface match; manual review is required.",
      });
      continue;
    }
    matchedStatuses.push(...matches.map((surface) => surface.status));
    resolved.push({
      file: finding.file,
      line: finding.line,
      provider: finding.provider,
      requestedSurface: finding.surface,
      matches: matches.map((surface) => ({
        name: surface.name,
        status: surface.status,
        legacyVersionRange: surface.legacyVersionRange,
        nativeMapping: surface.nativeMapping,
        requiredAdapter: surface.requiredAdapter,
      })).sort((left, right) => compareText(left.name, right.name)),
    });
  }
  unresolved.sort((left, right) => compareText(left.file, right.file)
    || left.line - right.line || compareText(left.signal, right.signal));
  resolved.sort((left, right) => compareText(left.file, right.file)
    || left.line - right.line || compareText(left.requestedSurface, right.requestedSurface));

  let status = aggregateStatuses(matchedStatuses);
  if (scan.directLegacySql > 0) status = "UNSUPPORTED";
  else if (unresolved.length > 0 || !catalog.available) status = "UNKNOWN";
  else if (resolved.length === 0) status = scan.status;
  if (status === "CERTIFIED") status = "COMPATIBLE";
  return {
    schema: 1,
    artifactKind: "synex-compatibility-explanation",
    status,
    scan,
    resolved,
    unresolved,
    disclaimer: "Static explanation maps signatures to catalog entries; only separate runtime evidence can support certification.",
  };
}

export interface CompatibilityProfileReport {
  schema: 1;
  artifactKind: "synex-compatibility-profile";
  status: CompatibilityStatus;
  found: boolean;
  profile: CompatibilityProfile | null;
  disclaimer: string;
}

export function inspectCompatibilityProfile(
  catalog: CompatibilityCatalog,
  requestedId: string,
): CompatibilityProfileReport {
  const profile = catalog.profiles.find((entry) => entry.id === requestedId) ?? null;
  return {
    schema: 1,
    artifactKind: "synex-compatibility-profile",
    status: profile?.effectiveStatus ?? "UNKNOWN",
    found: profile !== null,
    profile,
    disclaimer: "A profile is CERTIFIED only with exact tested-version evidence and accepted cataloged surfaces.",
  };
}

export interface CompatibilityAdapterReport {
  schema: 1;
  artifactKind: "synex-compatibility-adapters";
  status: CompatibilityStatus;
  adapters: Array<{
    name: string;
    referencedBy: string[];
    installed: boolean;
    safe: boolean;
  }>;
  disclaimer: string;
}

function adapterResourceName(adapter: string): string | null {
  if (!/^[a-z0-9_]{2,64}$/u.test(adapter)) return null;
  return adapter.startsWith("synex_bridge_") ? adapter : `synex_bridge_${adapter}`;
}

async function inspectAdapter(repositoryRoot: string, adapter: string): Promise<{ installed: boolean; safe: boolean }> {
  const resourceName = adapterResourceName(adapter);
  if (!resourceName) return { installed: false, safe: false };
  const directory = join(repositoryRoot, "resources", resourceName);
  try {
    const directoryMetadata = await lstat(directory);
    const manifestMetadata = await lstat(join(directory, "fxmanifest.lua"));
    const safe = directoryMetadata.isDirectory() && !directoryMetadata.isSymbolicLink()
      && manifestMetadata.isFile() && !manifestMetadata.isSymbolicLink();
    return { installed: safe, safe };
  } catch {
    return { installed: false, safe: true };
  }
}

export async function listCompatibilityAdapters(
  repositoryRoot: string,
  catalog: CompatibilityCatalog,
): Promise<CompatibilityAdapterReport> {
  const references = new Map<string, Set<string>>();
  for (const surface of catalog.surfaces) {
    if (!surface.requiredAdapter) continue;
    const owners = references.get(surface.requiredAdapter) ?? new Set<string>();
    owners.add(`surface:${surface.provider}:${surface.name}`);
    references.set(surface.requiredAdapter, owners);
  }
  for (const profile of catalog.profiles) {
    for (const adapter of profile.requiredAdapters) {
      const owners = references.get(adapter) ?? new Set<string>();
      owners.add(`profile:${profile.id}`);
      references.set(adapter, owners);
    }
  }
  const adapters: CompatibilityAdapterReport["adapters"] = [];
  for (const name of [...references.keys()].sort(compareText)) {
    const inspected = await inspectAdapter(repositoryRoot, name);
    adapters.push({
      name,
      referencedBy: [...(references.get(name) ?? [])].sort(compareText),
      installed: inspected.installed,
      safe: inspected.safe,
    });
  }
  return {
    schema: 1,
    artifactKind: "synex-compatibility-adapters",
    status: adapters.some((adapter) => !adapter.installed || !adapter.safe) ? "UNSUPPORTED"
      : adapters.length > 0 ? "COMPATIBLE" : "UNKNOWN",
    adapters,
    disclaimer: "Installed means a non-symlink resource and manifest exist; it does not certify adapter behavior.",
  };
}

function mappingSurfaceRequired(
  catalog: CompatibilityCatalog,
  provider: CompatibilityProvider,
  category: "accounts" | "groups",
): boolean {
  const signal = category === "accounts" ? /(?:account|money)/u : /(?:duty|gang|group|job)/u;
  return catalog.surfaces.some((surface) => surface.provider === provider
    && surface.status !== "UNSUPPORTED" && surface.status !== "UNKNOWN"
    && signal.test(`${surface.name} ${surface.nativeMapping ?? ""}`.toLowerCase()));
}

function mappingRawString(mapping: CompatibilityCatalog["mappings"][number], field: string): string | null {
  const value = mapping.raw[field];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function doctorCheck(
  findings: CompatibilityDoctorFinding[],
  id: string,
  subject: string,
  codes: Set<string>,
  subjectMatches: ((finding: CompatibilityDoctorFinding) => boolean) | null,
  provable: boolean,
  evidence: CompatibilityDoctorCheck["evidence"],
  passMessage: string,
  unknownMessage: string,
): CompatibilityDoctorCheck {
  const related = findings.filter((finding) => codes.has(finding.code)
    && (subjectMatches === null || subjectMatches(finding)));
  const status = related.some((finding) => finding.severity === "error") ? "FAIL"
    : related.length > 0 ? "WARNING"
      : provable ? "PASS" : "UNKNOWN";
  return {
    id, status, subject,
    evidence: status === "UNKNOWN" ? "deferred" : evidence,
    message: related.length > 0
      ? `${related.length} evidence-backed finding(s) affect this check.`
      : provable ? passMessage : unknownMessage,
  };
}

export async function doctorCompatibility(
  repositoryRoot: string,
  catalog: CompatibilityCatalog,
  runtimeEvidence?: RuntimeCompatibilityEvidence,
): Promise<CompatibilityDoctorReport> {
  const findings: CompatibilityDoctorFinding[] = catalog.diagnostics.map((diagnostic) => ({
    severity: diagnostic.severity,
    code: diagnostic.code,
    subject: diagnostic.path,
    message: diagnostic.message,
  }));

  const mappingsByLegacy = new Map<string, typeof catalog.mappings>();
  for (const mapping of catalog.mappings) {
    const legacy = mapping.category === "identity" ? mapping.legacy : mapping.legacy.toLowerCase();
    const identityScope = mapping.category === "identity"
      ? `:${mappingRawString(mapping, "entityKind") ?? "unknown"}` : "";
    const key = `${mapping.category}:${mapping.provider ?? "all"}${identityScope}:${legacy}`;
    const entries = mappingsByLegacy.get(key) ?? [];
    entries.push(mapping);
    mappingsByLegacy.set(key, entries);
  }
  for (const [key, mappings] of mappingsByLegacy) {
    const nativeTargets = new Set(mappings.map((mapping) => mapping.native ?? "<none>"));
    if (mappings.length > 1 && (nativeTargets.size > 1 || new Set(mappings.map((mapping) => mapping.id)).size > 1)) {
      findings.push({
        severity: "error", code: "MAPPING_AMBIGUOUS", subject: key,
        message: `Legacy mapping resolves through ${mappings.length} competing entries.`,
      });
    }
  }

  const deployedProviders = new Set<CompatibilityProvider>(runtimeEvidence?.expectedProviders ?? []);
  const validMappings = new Map<string, number>();
  const activeAccountMappings = new Set<string>();
  for (const mapping of catalog.mappings) {
    if (mapping.provider && mapping.native !== null
      && mapping.status !== "UNSUPPORTED" && mapping.status !== "UNKNOWN") {
      const key = `${mapping.category}:${mapping.provider}`;
      validMappings.set(key, (validMappings.get(key) ?? 0) + 1);
      if (mapping.category === "accounts") {
        activeAccountMappings.add(`${mapping.provider}:${mapping.legacy.toLowerCase()}`);
      }
    }
    if ((mapping.category === "accounts" || mapping.category === "groups")
      && mapping.status !== "UNSUPPORTED" && mapping.status !== "UNKNOWN"
      && mapping.native === null) findings.push({
      severity: "error",
      code: mapping.category === "accounts" ? "ACCOUNT_MAPPING_INVALID" : "GROUP_MAPPING_INVALID",
      subject: mapping.id,
      message: "An enabled mapping has no complete native target.",
    });
  }

  for (const mapping of catalog.mappings.filter((entry) => entry.category === "groups"
    && entry.status !== "UNSUPPORTED" && entry.status !== "UNKNOWN")) {
    const grades = mapping.raw.grades;
    if (!Array.isArray(grades) || grades.length === 0) {
      findings.push({
        severity: "error", code: "GROUP_GRADE_MAPPING_MISSING", subject: mapping.id,
        message: "An enabled group mapping must define at least one explicit legacy-grade mapping.",
      });
      continue;
    }
    const legacyGrades = new Set<number>();
    const gradeKeys = new Set<string>();
    for (const grade of grades) {
      if (!isRecord(grade) || typeof grade.legacyGrade !== "number"
        || !Number.isSafeInteger(grade.legacyGrade) || typeof grade.gradeKey !== "string") {
        findings.push({
          severity: "error", code: "GROUP_GRADE_MAPPING_INVALID", subject: mapping.id,
          message: "A group grade mapping is not a typed legacy-grade to grade-key pair.",
        });
        continue;
      }
      if (legacyGrades.has(grade.legacyGrade) || gradeKeys.has(grade.gradeKey)) findings.push({
        severity: "error", code: "GROUP_GRADE_MAPPING_AMBIGUOUS", subject: mapping.id,
        message: `Grade ${String(grade.legacyGrade)} or target ${grade.gradeKey} is mapped more than once.`,
      });
      legacyGrades.add(grade.legacyGrade);
      gradeKeys.add(grade.gradeKey);
    }
  }

  const identityMappings = catalog.mappings.filter((mapping) => mapping.category === "identity"
    && mapping.status !== "UNSUPPORTED" && mapping.status !== "UNKNOWN");
  const identityByLegacy = new Map<string, typeof identityMappings>();
  const identityByNative = new Map<string, typeof identityMappings>();
  for (const mapping of identityMappings) {
    const entityKind = mappingRawString(mapping, "entityKind") ?? "unknown";
    for (const [key, index] of [
      [`${mapping.provider ?? "all"}:${entityKind}:${mapping.legacy}`, identityByLegacy],
      [`${mapping.provider ?? "all"}:${entityKind}:${mapping.native ?? "<none>"}`, identityByNative],
    ] as const) {
      const entries = index.get(key) ?? [];
      entries.push(mapping);
      index.set(key, entries);
    }
  }
  for (const [key, mappings] of identityByLegacy) {
    if (mappings.length > 1) findings.push({
      severity: "error", code: "LEGACY_ID_COLLISION", subject: key,
      message: `${mappings.length} catalog entries claim the same provider-scoped legacy identifier.`,
    });
  }
  for (const [key, mappings] of identityByNative) {
    if (mappings.length > 1) findings.push({
      severity: "error", code: "LEGACY_ID_NATIVE_COLLISION", subject: key,
      message: `${mappings.length} legacy identifiers claim the same provider-scoped native identity.`,
    });
  }

  const enabledConsumers = catalog.consumers.filter((consumer) => consumer.enabled);
  const consumersById = new Map<string, typeof enabledConsumers>();
  for (const consumer of enabledConsumers) {
    if (consumer.provider) deployedProviders.add(consumer.provider);
    const entries = consumersById.get(consumer.id) ?? [];
    entries.push(consumer);
    consumersById.set(consumer.id, entries);
  }

  const activePolicies = catalog.moneyPolicies.filter((policy) => policy.status === "ACTIVE");
  const policyIds = new Set<string>();
  const policiesByMatch = new Map<string, typeof activePolicies>();
  const enabledConsumerKeys = new Set(enabledConsumers.flatMap((consumer) => consumer.provider
    ? [`${consumer.provider}:${consumer.id}`] : []));
  for (const policy of activePolicies) {
    if (policyIds.has(policy.id)) findings.push({
      severity: "error", code: "MONEY_POLICY_ID_DUPLICATE", subject: policy.id,
      message: "An active money-policy id is declared more than once.",
    });
    policyIds.add(policy.id);
    const key = [
      policy.provider, policy.consumer, policy.moneyAlias.toLowerCase(),
      policy.direction, policy.legacyReason.toLowerCase(),
    ].join(":");
    const matching = policiesByMatch.get(key) ?? [];
    matching.push(policy);
    policiesByMatch.set(key, matching);
    if (!activeAccountMappings.has(`${policy.provider}:${policy.moneyAlias.toLowerCase()}`)) {
      findings.push({
        severity: "error", code: "MONEY_POLICY_MAPPING_MISSING", subject: policy.id,
        message: "An active money policy references no enabled account mapping for its provider and alias.",
      });
    }
    if (!enabledConsumerKeys.has(`${policy.provider}:${policy.consumer}`)) findings.push({
      severity: "error", code: "MONEY_POLICY_CONSUMER_MISSING", subject: policy.id,
      message: "An active money policy references no enabled consumer for its provider.",
    });
  }
  for (const [key, policies] of policiesByMatch) {
    if (policies.length > 1) findings.push({
      severity: "error", code: "MONEY_POLICY_AMBIGUOUS", subject: key,
      message: `${policies.length} active policies claim the same provider, consumer, alias, direction, and legacy reason.`,
    });
  }

  for (const provider of COMPATIBILITY_PROVIDERS) {
    if (!deployedProviders.has(provider)) continue;
    if (mappingSurfaceRequired(catalog, provider, "accounts")
      && (validMappings.get(`accounts:${provider}`) ?? 0) === 0) findings.push({
      severity: "error", code: "ACCOUNT_MAPPING_MISSING", subject: provider,
      message: "A deployed provider exposes account surfaces but has no enabled account mapping.",
    });
    if (mappingSurfaceRequired(catalog, provider, "groups")
      && (validMappings.get(`groups:${provider}`) ?? 0) === 0) findings.push({
      severity: "error", code: "GROUP_MAPPING_MISSING", subject: provider,
      message: "A deployed provider exposes group/job/duty surfaces but has no enabled group mapping.",
    });
  }
  for (const [id, consumers] of consumersById) {
    const providers = new Set(consumers.map((consumer) => consumer.provider ?? "unknown"));
    if (providers.size > 1) findings.push({
      severity: "error", code: "PROVIDER_CONFLICT", subject: id,
      message: `Enabled consumer selects multiple providers: ${[...providers].sort(compareText).join(", ")}.`,
    });
  }

  const profiles = new Map(catalog.profiles.map((profile) => [profile.id, profile]));
  let moneyPolicyDemand = 0;
  for (const consumer of enabledConsumers) {
    const profile = consumer.profile ? profiles.get(consumer.profile) : undefined;
    if (!profile) {
      findings.push({
        severity: "error", code: "PROFILE_MISSING", subject: consumer.id,
        message: `Enabled consumer references missing profile ${consumer.profile ?? "<none>"}.`,
      });
    } else if (consumer.provider !== profile.provider) {
      findings.push({
        severity: "error", code: "PROFILE_PROVIDER_DRIFT", subject: consumer.id,
        message: `Consumer provider ${consumer.provider ?? "unknown"} differs from profile ${profile.provider ?? "unknown"}.`,
      });
    }
    if (profile && consumer.provider) {
      const requiresMoney = profile.surfaces.some((name) => {
        const surface = catalog.surfaces.find((entry) =>
          entry.provider === consumer.provider && entry.name === name);
        return surface !== undefined && surface.status !== "UNSUPPORTED"
          && /(?:money|account)/u.test(surface.name);
      });
      if (requiresMoney) {
        moneyPolicyDemand += 1;
        if (!activePolicies.some((policy) => policy.provider === consumer.provider
          && policy.consumer === consumer.id)) findings.push({
          severity: "warning", code: "MONEY_POLICY_MISSING", subject: consumer.id,
          message: "The selected profile requires a money surface, but the consumer has no active funding or sink policy and will be denied.",
        });
      }
    }
  }

  for (const profile of catalog.profiles) {
    if (profile.status === "CERTIFIED" && profile.effectiveStatus !== "CERTIFIED") {
      findings.push({
        severity: "error", code: "PROFILE_CERTIFICATION_EVIDENCE_MISSING", subject: profile.id,
        message: "Authored CERTIFIED status lacks checked exact-version evidence or an accepted required surface.",
      });
    }
    const requiredSurfaces = Array.isArray(profile.raw.requiredSurfaces) ? profile.raw.requiredSurfaces : [];
    for (const requirement of requiredSurfaces) {
      if (!isRecord(requirement) || typeof requirement.name !== "string" || !profile.provider) continue;
      const surface = catalog.surfaces.find((entry) =>
        entry.provider === profile.provider && entry.name === requirement.name);
      if (!surface) {
        findings.push({
          severity: "error", code: "PROFILE_SURFACE_MISSING", subject: profile.id,
          message: `Required surface ${requirement.name} is absent from provider ${profile.provider}.`,
        });
        continue;
      }
      const accepted = Array.isArray(requirement.acceptedStatuses)
        ? requirement.acceptedStatuses.filter((entry): entry is string => typeof entry === "string")
        : [];
      if (accepted.length === 0 || !accepted.includes(surface.status)) findings.push({
        severity: "error", code: "PROFILE_SURFACE_DRIFT", subject: profile.id,
        message: `Surface ${surface.name} has ${surface.status}, outside the profile's accepted statuses.`,
      });
      if (surface.requiredCatalog
        && !profile.requiredCatalogs.includes(surface.requiredCatalog)) findings.push({
        severity: "error", code: "PROFILE_CATALOG_MISSING", subject: profile.id,
        message: `Surface ${surface.name} requires catalog ${surface.requiredCatalog}, but the profile does not bind it.`,
      });
    }
  }

  const adapters = await listCompatibilityAdapters(repositoryRoot, catalog);
  for (const adapter of adapters.adapters) {
    if (!adapter.safe || !adapter.installed) findings.push({
      severity: "error", code: "ADAPTER_MISSING", subject: adapter.name,
      message: "A referenced adapter resource or non-symlink manifest is missing.",
    });
  }
  if (runtimeEvidence) {
    findings.push(...inspectRuntimeEvidence(runtimeEvidence).findings);
    const enabledConsumerKeys = new Set(enabledConsumers.flatMap((consumer) => consumer.provider
      ? [`${consumer.provider}:${consumer.id}`] : []));
    for (const consumer of runtimeEvidence.consumers.filter((entry) => entry.active)) {
      if (!enabledConsumerKeys.has(`${consumer.provider}:${consumer.consumer}`)) findings.push({
        severity: "error", code: "RUNTIME_STALE_CONSUMER_BINDING", subject: consumer.consumer,
        message: `Active runtime binding ${consumer.provider} is absent from the enabled consumer catalog.`,
      });
    }

    const providerCatalogs = new Map(catalog.providerCatalogs.map((entry) => [entry.provider, entry]));
    for (const provider of runtimeEvidence.providers) {
      const expectedProvider = providerCatalogs.get(provider.provider);
      if (expectedProvider && provider.version !== expectedProvider.providerVersion) findings.push({
        severity: "error", code: "RUNTIME_PROVIDER_VERSION_MISMATCH", subject: provider.provider,
        message: `Runtime provider ${provider.version} differs from catalog ${expectedProvider.providerVersion}.`,
      });
    }

    const certifications = new Map<string, number>();
    for (const certification of runtimeEvidence.certifications) {
      certifications.set(certification.profileId,
        (certifications.get(certification.profileId) ?? 0) + 1);
      const profile = profiles.get(certification.profileId);
      if (!profile) {
        findings.push({
          severity: "error", code: "RUNTIME_PROFILE_MISSING", subject: certification.profileId,
          message: "Runtime certification evidence references an unknown profile.",
        });
        continue;
      }
      if (certification.profileVersion !== profile.version) findings.push({
        severity: "error", code: "RUNTIME_PROFILE_VERSION_MISMATCH", subject: profile.id,
        message: `Runtime profile ${certification.profileVersion} differs from catalog ${profile.version}.`,
      });
      if (certification.provider !== profile.provider
        || certification.providerVersion !== profile.providerVersion
        || certification.targetFrameworkApiRange !== profile.targetFrameworkApiRange) findings.push({
        severity: "error", code: "RUNTIME_PROFILE_BINDING_MISMATCH", subject: profile.id,
        message: "Runtime profile provider/version/API-range evidence differs from the catalog binding.",
      });
    }
    for (const [profileId, count] of certifications) {
      if (count > 1) findings.push({
        severity: "error", code: "RUNTIME_PROFILE_EVIDENCE_DUPLICATE", subject: profileId,
        message: `${count} runtime certification records claim the same profile.`,
      });
    }
  } else findings.push({
    severity: "warning",
    code: "RUNTIME_EVIDENCE_UNAVAILABLE",
    subject: "runtime",
    message: "No operator-supplied runtime evidence was provided; FXServer state was not inspected.",
  });

  findings.sort((left, right) => compareText(left.subject, right.subject)
    || compareText(left.code, right.code));
  const runtimeComplete = runtimeEvidence?.complete === true;
  const callbackTelemetryProviders = runtimeEvidence?.providers.filter((provider) => [
    provider.health.callbackPending,
    provider.health.callbackCapacity,
    provider.health.callbackRegistrations,
    provider.health.callbackRegistrationCapacity,
  ].every((value) => value !== undefined)).length ?? 0;
  const rateSamples = runtimeEvidence?.providers.reduce((sum, provider) => sum
    + provider.telemetry.entries.filter((entry) => {
      const terminal = entry.outcomes.success + entry.outcomes.denied + entry.outcomes.unsupported
        + entry.outcomes.error + entry.outcomes.timeout + entry.outcomes.rateLimited;
      return !provider.telemetry.truncated && entry.calls >= RUNTIME_RATE_MINIMUM_CALLS
        && terminal === entry.calls && entry.outcomes.deprecated <= entry.calls;
    }).length, 0) ?? 0;
  const completeProviderSet = runtimeComplete && runtimeEvidence.expectedProviders.every((provider) =>
    runtimeEvidence.providers.some((entry) => entry.provider === provider));
  const catalogMappingIntegrity = catalog.available
    && !catalog.diagnostics.some((diagnostic) => diagnostic.code.includes("MAPPING"));
  const moneyPolicyIntegrity = catalog.available
    && !catalog.diagnostics.some((diagnostic) => diagnostic.code.includes("MONEY_POLICY"));
  const accountCoverageProvable = catalogMappingIntegrity && deployedProviders.size > 0;
  const groupCoverageProvable = catalogMappingIntegrity && deployedProviders.size > 0;
  const checks: CompatibilityDoctorCheck[] = [
    doctorCheck(findings, "mappings.accounts.integrity", "accounts",
      new Set(["MAPPING_AMBIGUOUS", "ACCOUNT_MAPPING_INVALID"]),
      (finding) => finding.subject.startsWith("accounts:") || finding.code === "ACCOUNT_MAPPING_INVALID",
      catalogMappingIntegrity, "catalog", "Account mappings are typed and unambiguous.",
      "The account mapping catalog is unavailable or structurally invalid."),
    doctorCheck(findings, "mappings.accounts.coverage", "accounts",
      new Set(["ACCOUNT_MAPPING_MISSING"]), null, accountCoverageProvable,
      "catalog+runtime", "Every deployed account-capable provider has an enabled mapping.",
      "No enabled consumer or expected runtime provider establishes account-mapping demand."),
    doctorCheck(findings, "mappings.groups.integrity", "groups",
      new Set(["MAPPING_AMBIGUOUS", "GROUP_MAPPING_INVALID", "GROUP_GRADE_MAPPING_MISSING",
        "GROUP_GRADE_MAPPING_INVALID", "GROUP_GRADE_MAPPING_AMBIGUOUS"]),
      (finding) => finding.subject.startsWith("groups:") || finding.code.startsWith("GROUP_"),
      catalogMappingIntegrity, "catalog", "Group mappings and grade maps are typed and unambiguous.",
      "The group mapping catalog is unavailable or structurally invalid."),
    doctorCheck(findings, "mappings.groups.coverage", "groups",
      new Set(["GROUP_MAPPING_MISSING"]), null, groupCoverageProvable,
      "catalog+runtime", "Every deployed group-capable provider has an enabled mapping.",
      "No enabled consumer or expected runtime provider establishes group-mapping demand."),
    doctorCheck(findings, "money-policies.integrity", "accounts",
      new Set(["MONEY_POLICY_ID_DUPLICATE", "MONEY_POLICY_AMBIGUOUS",
        "MONEY_POLICY_MAPPING_MISSING", "MONEY_POLICY_CONSUMER_MISSING"]), null,
      moneyPolicyIntegrity, "catalog",
      "Active money policies are typed, uniquely matched, and reference enabled mappings and consumers.",
      "The money-policy catalog is unavailable or structurally invalid."),
    doctorCheck(findings, "money-policies.coverage", "accounts",
      new Set(["MONEY_POLICY_MISSING"]), null, moneyPolicyIntegrity && moneyPolicyDemand > 0,
      "catalog", "Every profile-selected money consumer has an active reviewed policy.",
      "No enabled profile-selected money surface establishes policy demand; missing policies continue to deny mutations."),
    doctorCheck(findings, "identity.legacy-collisions", "identity",
      new Set(["LEGACY_ID_COLLISION", "LEGACY_ID_NATIVE_COLLISION"]), null,
      catalogMappingIntegrity && identityMappings.length > 0, "catalog",
      "Provider- and entity-scoped legacy identities are one-to-one.",
      "No static identity mapping exists; persistent runtime identity collisions are not represented."),
    doctorCheck(findings, "runtime.consumer-cleanup", "consumers",
      new Set(["RUNTIME_CONSUMER_BINDING_DUPLICATE", "RUNTIME_CONSUMER_PROVIDER_CONFLICT",
        "RUNTIME_STALE_CONSUMER_BINDING", "RUNTIME_STALE_CONSUMER_TELEMETRY"]), null,
      runtimeComplete, "catalog+runtime", "Active consumers and telemetry match the enabled catalog.",
      "Complete runtime consumer and telemetry evidence was not supplied."),
    doctorCheck(findings, "runtime.callback-cleanup", "callbacks",
      new Set(["RUNTIME_CALLBACK_TELEMETRY_INCOMPLETE", "RUNTIME_CALLBACK_TELEMETRY_INVALID",
        "RUNTIME_STALE_CALLBACK_PENDING", "RUNTIME_STALE_CALLBACK_REGISTRATION"]), null,
      runtimeComplete && callbackTelemetryProviders === runtimeEvidence?.providers.length
        && callbackTelemetryProviders > 0,
      "runtime", "Callback pending/registration counters contain no stale state.",
      "Callback counters are absent; stale callbacks and callback-registration leaks remain deferred."),
    doctorCheck(findings, "runtime.unsupported-rate", "telemetry",
      new Set(["RUNTIME_UNSUPPORTED_RATE_HIGH"]), null,
      runtimeComplete && rateSamples > 0
        && !runtimeEvidence?.providers.some((provider) => provider.telemetry.truncated),
      "runtime", `Unsupported rates remain below ${String(RUNTIME_UNSUPPORTED_WARNING_BASIS_POINTS / 100)}% across samples of at least ${String(RUNTIME_RATE_MINIMUM_CALLS)} calls.`,
      `No complete untruncated sample reaches ${String(RUNTIME_RATE_MINIMUM_CALLS)} calls.`),
    doctorCheck(findings, "runtime.deprecated-rate", "telemetry",
      new Set(["RUNTIME_DEPRECATED_RATE_HIGH"]), null,
      runtimeComplete && rateSamples > 0
        && !runtimeEvidence?.providers.some((provider) => provider.telemetry.truncated),
      "runtime", `Deprecated rates remain below ${String(RUNTIME_DEPRECATED_WARNING_BASIS_POINTS / 100)}% across samples of at least ${String(RUNTIME_RATE_MINIMUM_CALLS)} calls.`,
      `No complete untruncated sample reaches ${String(RUNTIME_RATE_MINIMUM_CALLS)} calls.`),
    doctorCheck(findings, "runtime.facade-framework-conflicts", "providers",
      new Set(["RUNTIME_FRAMEWORK_RESOURCE_CONFLICT"]), null, completeProviderSet,
      "runtime", "No historical-facade/framework-resource conflict is active.",
      "Complete provider-conflict evidence was not supplied."),
    doctorCheck(findings, "runtime.profile-versions", "profiles",
      new Set(["PROFILE_PROVIDER_DRIFT", "RUNTIME_PROVIDER_VERSION_MISMATCH",
        "RUNTIME_PROFILE_MISSING", "RUNTIME_PROFILE_VERSION_MISMATCH",
        "RUNTIME_PROFILE_BINDING_MISMATCH", "RUNTIME_PROFILE_EVIDENCE_DUPLICATE"]), null,
      runtimeComplete && runtimeEvidence.certifications.length > 0, "catalog+runtime",
      "Runtime profile and provider versions match their exact catalog bindings.",
      "No complete runtime profile-version evidence was supplied."),
  ].sort((left, right) => compareText(left.id, right.id));
  const hasFailedCheck = checks.some((check) => check.status === "FAIL");
  const hasIncompleteCheck = checks.some((check) => check.status === "WARNING"
    || check.status === "UNKNOWN");
  return {
    schema: 1,
    artifactKind: "synex-compatibility-doctor",
    status: findings.some((finding) => finding.severity === "error") || hasFailedCheck
      ? "UNSUPPORTED"
      : findings.length > 0 || hasIncompleteCheck ? "PARTIAL"
        : buildCompatibilityStatus(catalog).status,
    catalogAvailable: catalog.available,
    checks,
    findings,
    checked: {
      surfaces: catalog.surfaces.length,
      profiles: catalog.profiles.length,
      consumers: catalog.consumers.length,
      moneyPolicies: catalog.moneyPolicies.length,
      mappings: catalog.mappings.length,
      adapters: adapters.adapters.length,
      runtime: {
        provided: runtimeEvidence !== undefined,
        complete: runtimeEvidence?.complete ?? null,
        expectedProviders: runtimeEvidence?.expectedProviders.length ?? 0,
        providers: runtimeEvidence?.providers.length ?? 0,
        capabilities: runtimeEvidence?.providers.reduce(
          (sum, provider) => sum + provider.capabilities.length, 0,
        ) ?? 0,
        conflicts: runtimeEvidence?.providers.reduce(
          (sum, provider) => sum + provider.conflicts.length, 0,
        ) ?? 0,
        consumerBindings: runtimeEvidence?.consumers.length ?? 0,
        telemetryEntries: runtimeEvidence?.providers.reduce(
          (sum, provider) => sum + provider.telemetry.entries.length, 0,
        ) ?? 0,
        certifications: runtimeEvidence?.certifications.length ?? 0,
        callbackTelemetryProviders,
      },
    },
    disclaimer: "Doctor validates catalog consistency and operator-supplied bounded runtime evidence; it never connects to FXServer, grants capabilities, or certifies behavior.",
  };
}
