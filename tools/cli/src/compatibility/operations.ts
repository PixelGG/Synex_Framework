import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";
import { Ajv2020, type AnySchema } from "ajv/dist/2020.js";

import { CliError } from "../errors.ts";
import { canonicalJson, isRecord, sha256 } from "../filesystem.ts";
import {
  doctorCompatibility,
  explainCompatibility,
  listCompatibilityAdapters,
} from "./analysis.ts";
import { certificationSurfaceEvidenceSatisfied } from "./catalog.ts";
import { inspectRuntimeEvidence } from "./evidence.ts";
import type { RuntimeCompatibilityEvidence } from "./evidence.ts";
import { executionEvidenceMatchesProfile } from "./execution.ts";
import type { CompatibilityExecutionEvidence } from "./execution.ts";
import { scanCompatibility } from "./scanner.ts";
import type {
  CompatibilityCatalog,
  CompatibilityDoctorFinding,
  CompatibilityProfile,
  CompatibilityProvider,
  CompatibilityReport,
  CompatibilityStatus,
} from "./types.ts";

const COMPATIBILITY_ROOT = "libraries/synex_bridge/compatibility";
const REVIEW_LOCK = `${COMPATIBILITY_ROOT}/review-lock.json`;
const REVIEW_LOCK_SCHEMA = `${COMPATIBILITY_ROOT}/schemas/review-lock.schema.json`;
const CONSUMER_CATALOG = `${COMPATIBILITY_ROOT}/consumers.json`;
const MONEY_POLICY_CATALOG = `${COMPATIBILITY_ROOT}/money-policies.json`;
const EXECUTION_SCHEMA = `${COMPATIBILITY_ROOT}/schemas/certification-execution.schema.json`;
const CERTIFICATION_SCHEMAS = [
  `${COMPATIBILITY_ROOT}/schemas/certification.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/consumers.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/mappings.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/money-policies.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/profiles.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/review-lock.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/runtime-evidence.schema.json`,
  `${COMPATIBILITY_ROOT}/schemas/surfaces.schema.json`,
] as const;
const MAX_ARTIFACT_BYTES = 1024 * 1024;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 5_000;
const MIN_UPSTREAM_TIMEOUT_MS = 500;
const MAX_UPSTREAM_TIMEOUT_MS = 30_000;
const MAX_UPSTREAM_SOURCE_BYTES = 256 * 1024;
const PROVIDER_RESOURCES = {
  qb: "synex_bridge_qb",
  qbx: "synex_bridge_qbx",
  esx: "synex_bridge_esx",
} as const;
const UPSTREAM_REPOSITORIES: Record<CompatibilityProvider, string> = {
  qb: "https://github.com/qbcore-framework/qb-core",
  qbx: "https://github.com/Qbox-project/qbx_core",
  esx: "https://github.com/esx-framework/esx_core",
};

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

export interface CompatibilityObservationReport {
  schema: 1;
  artifactKind: "synex-compatibility-observation";
  status: CompatibilityStatus;
  target: string;
  static: CompatibilityReport;
  runtime: ReturnType<typeof inspectRuntimeEvidence>["summary"] | null;
  findings: CompatibilityDoctorFinding[];
  disclaimer: string;
}

export async function observeCompatibility(
  repositoryRoot: string,
  target: string,
  catalog: CompatibilityCatalog,
  runtimeEvidence?: RuntimeCompatibilityEvidence,
): Promise<CompatibilityObservationReport> {
  const scan = await scanCompatibility(repositoryRoot, target);
  const explanation = explainCompatibility(scan, catalog);
  const doctor = await doctorCompatibility(repositoryRoot, catalog, runtimeEvidence);
  const runtime = runtimeEvidence ? inspectRuntimeEvidence(runtimeEvidence).summary : null;
  let status: CompatibilityStatus;
  if (scan.status === "UNSUPPORTED" || doctor.status === "UNSUPPORTED") status = "UNSUPPORTED";
  else if (!runtimeEvidence) status = "UNKNOWN";
  else if (!runtimeEvidence.complete || doctor.findings.length > 0) status = "PARTIAL";
  else status = explanation.status === "CERTIFIED" ? "COMPATIBLE" : explanation.status;
  return {
    schema: 1,
    artifactKind: "synex-compatibility-observation",
    status,
    target: scan.target,
    static: scan,
    runtime,
    findings: doctor.findings,
    disclaimer: "This report combines a static repository scan with optional operator-supplied bounded evidence. It does not connect to FXServer and is not a certification.",
  };
}

export interface CompatibilityCertificationCheck {
  id: string;
  status: "PASS" | "FAIL";
  message: string;
}

export interface CompatibilityCertificationReport {
  schema: 1;
  artifactKind: "synex-compatibility-certification";
  status: "CERTIFIED" | "UNKNOWN";
  certified: boolean;
  profileId: string;
  checks: CompatibilityCertificationCheck[];
  certificate: {
    schema: 1;
    kind: "synex-compatibility-certificate";
    profileId: string;
    profileVersion: string;
    provider: CompatibilityProvider;
    providerResource: string;
    providerVersion: string;
    targetFrameworkApiRange: string;
    script: { name: string; version: string };
    tests: Array<{ path: string; sha256: string; status: "PASS"; tracked: true }>;
    sourceUrls: string[];
    bindings: {
      profileCatalog: CertificationBinding;
      surfaceCatalog: CertificationBinding;
      consumerCatalog: CertificationBinding;
      moneyPolicyCatalog: CertificationBinding;
      reviewLock: CertificationBinding;
      schemas: CertificationBinding[];
    };
    fingerprint: string;
  } | null;
  disclaimer: string;
}

interface CertificationBinding {
  path: string;
  sha256: string;
  tracked: true;
}

type CertificatePayload = Omit<
  NonNullable<CompatibilityCertificationReport["certificate"]>,
  "fingerprint"
>;

function certificateFingerprint(payload: CertificatePayload, checks: CompatibilityCertificationCheck[]): string {
  const values = [
    "synex-compatibility-certificate-v1",
    String(payload.schema), payload.kind, payload.profileId, payload.profileVersion,
    payload.provider, payload.providerResource, payload.providerVersion,
    payload.targetFrameworkApiRange, payload.script.name, payload.script.version,
  ];
  for (const test of [...payload.tests].sort((left, right) => compareText(left.path, right.path))) {
    values.push("test", test.path, test.sha256, test.status, String(test.tracked));
  }
  for (const sourceUrl of [...payload.sourceUrls].sort(compareText)) values.push("source", sourceUrl);
  for (const name of [
    "profileCatalog", "surfaceCatalog", "consumerCatalog", "moneyPolicyCatalog", "reviewLock",
  ] as const) {
    const binding = payload.bindings[name];
    values.push("binding", name, binding.path, binding.sha256, String(binding.tracked));
  }
  for (const binding of [...payload.bindings.schemas].sort((left, right) =>
    compareText(left.path, right.path))) {
    values.push("schema", binding.path, binding.sha256, String(binding.tracked));
  }
  for (const check of [...checks].sort((left, right) => compareText(left.id, right.id))) {
    values.push("check", check.id, check.status);
  }
  return sha256(values.map((value) => `${Buffer.byteLength(value, "utf8")}:${value}`).join(""));
}

function addCheck(
  checks: CompatibilityCertificationCheck[],
  id: string,
  passed: boolean,
  passMessage: string,
  failMessage: string,
): void {
  checks.push({ id, status: passed ? "PASS" : "FAIL", message: passed ? passMessage : failMessage });
}

function profileSourceUrls(profile: CompatibilityProfile): string[] {
  if (!isRecord(profile.raw.evidence) || !Array.isArray(profile.raw.evidence.sourceUrls)) return [];
  return profile.raw.evidence.sourceUrls.filter((entry): entry is string => typeof entry === "string")
    .sort(compareText);
}

async function safeTestHash(repositoryRoot: string, requested: string): Promise<string | null> {
  if (isAbsolute(requested)) return null;
  const path = resolve(repositoryRoot, requested);
  const rel = relative(resolve(repositoryRoot), path);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  let current = resolve(repositoryRoot);
  for (const segment of rel.split(sep).filter(Boolean)) {
    current = join(current, segment);
    try {
      if ((await lstat(current)).isSymbolicLink()) return null;
    } catch {
      return null;
    }
  }
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > MAX_ARTIFACT_BYTES) return null;
  return sha256(await readFile(path, "utf8"));
}

function isTrackedFile(repositoryRoot: string, requested: string): boolean {
  if (isAbsolute(requested)) return false;
  const result = spawnSync("git", ["ls-files", "--error-unmatch", "--", requested], {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: "ignore",
    timeout: 5_000,
    windowsHide: true,
  });
  return result.status === 0 && result.error === undefined;
}

async function certificationBinding(
  repositoryRoot: string,
  requested: string,
): Promise<CertificationBinding | null> {
  if (!isTrackedFile(repositoryRoot, requested)) return null;
  try {
    const artifact = await readCheckedArtifact(repositoryRoot, requested);
    return { path: requested, sha256: sha256(artifact.text), tracked: true };
  } catch {
    return null;
  }
}

export async function certifyCompatibilityProfile(
  repositoryRoot: string,
  catalog: CompatibilityCatalog,
  profileId: string,
  runtimeEvidence?: RuntimeCompatibilityEvidence,
  executionEvidence?: CompatibilityExecutionEvidence,
): Promise<CompatibilityCertificationReport> {
  const checks: CompatibilityCertificationCheck[] = [];
  const profile = catalog.profiles.find((entry) => entry.id === profileId) ?? null;
  addCheck(checks, "profile.exists", profile !== null,
    "The exact profile exists.", "The requested profile does not exist.");
  addCheck(checks, "runtime.provided", runtimeEvidence !== undefined,
    "Operator runtime evidence was supplied.", "Operator runtime evidence is required.");
  if (!profile || !runtimeEvidence) return {
    schema: 1, artifactKind: "synex-compatibility-certification", status: "UNKNOWN",
    certified: false, profileId, checks, certificate: null,
    disclaimer: "Certification is fail-closed and binds only the exact profile, provider, script version, reviewed consumer and money-policy catalogs, checked-in test hashes, and supplied operator evidence. It does not run or inspect FXServer itself.",
  };

  addCheck(checks, "profile.effective-status",
    profile.effectiveStatus === "CERTIFIED"
      && certificationSurfaceEvidenceSatisfied(profile, catalog.surfaces),
    "The catalog profile has complete checked-in certification prerequisites.",
    `The catalog profile effective status is ${profile.effectiveStatus}, or required-surface test evidence is incomplete.`);
  addCheck(checks, "runtime.complete", runtimeEvidence.complete,
    "The operator marked the runtime evidence complete.",
    "The operator marked the runtime evidence incomplete.");
  const profileCatalogPath = `${COMPATIBILITY_ROOT}/profiles.json`;
  const surfaceCatalogPath = profile.provider === null ? null
    : `${COMPATIBILITY_ROOT}/surfaces/${profile.provider}.json`;
  addCheck(checks, "catalog.profile-tracked",
    isTrackedFile(repositoryRoot, profileCatalogPath),
    "The profile catalog is tracked in the repository.",
    "The profile catalog is not tracked in the repository.");
  addCheck(checks, "catalog.surface-tracked",
    profile.provider !== null && isTrackedFile(
      repositoryRoot,
      surfaceCatalogPath ?? "",
    ),
    "The exact provider surface catalog is tracked in the repository.",
    "The exact provider surface catalog is not tracked in the repository.");
  addCheck(checks, "catalog.consumers-tracked",
    isTrackedFile(repositoryRoot, CONSUMER_CATALOG),
    "The exact compatibility consumer authorization catalog is tracked in the repository.",
    "The compatibility consumer authorization catalog is not tracked in the repository.");
  addCheck(checks, "catalog.money-policies-tracked",
    isTrackedFile(repositoryRoot, MONEY_POLICY_CATALOG),
    "The exact compatibility money-policy catalog is tracked in the repository.",
    "The compatibility money-policy catalog is not tracked in the repository.");
  addCheck(checks, "catalog.schemas-tracked",
    CERTIFICATION_SCHEMAS.every((path) => isTrackedFile(repositoryRoot, path))
      && isTrackedFile(repositoryRoot, EXECUTION_SCHEMA),
    "Certification, execution, profile, and surface schemas are tracked in the repository.",
    "One or more certification, execution, profile, or surface schemas are not tracked.");
  let reviewLockAccepted = false;
  try {
    const reviewLock = await checkCompatibilityReviewLock(repositoryRoot);
    reviewLockAccepted = reviewLock.status === "PASS"
      && isTrackedFile(repositoryRoot, REVIEW_LOCK)
      && isTrackedFile(repositoryRoot, REVIEW_LOCK_SCHEMA);
  } catch {
    reviewLockAccepted = false;
  }
  addCheck(checks, "catalog.review-lock", reviewLockAccepted,
    "Tracked local review-lock hashes and evidence URL sets match.",
    "The tracked local review lock is missing, invalid, or does not match.");

  const candidates = runtimeEvidence.certifications.filter((entry) => entry.profileId === profileId);
  addCheck(checks, "evidence.unique", candidates.length === 1,
    "Exactly one certification evidence record matches the profile.",
    `Expected one matching certification evidence record; found ${candidates.length}.`);
  const candidate = candidates.length === 1 ? candidates[0] : undefined;
  const providerCatalog = catalog.providerCatalogs.find((entry) =>
    entry.provider === profile.provider);
  if (candidate) {
    addCheck(checks, "profile.version", candidate.profileVersion === profile.version,
      "Profile version matches exactly.", "Profile version does not match exactly.");
    addCheck(checks, "provider.exact", candidate.provider === profile.provider,
      "Provider matches exactly.", "Provider does not match exactly.");
    addCheck(checks, "provider.version-exact",
      candidate.providerVersion === profile.providerVersion,
      "Provider version matches the profile exactly.",
      "Provider version does not match the profile exactly.");
    addCheck(checks, "target-framework-api.range-exact",
      candidate.targetFrameworkApiRange === profile.targetFrameworkApiRange,
      "Target-framework API range matches the profile exactly.",
      "Target-framework API range does not match the profile exactly.");
    addCheck(checks, "script.name", candidate.script.name === profile.script,
      "Script name matches exactly.", "Script name does not match exactly.");
    addCheck(checks, "script.version", candidate.script.version === profile.testedVersion,
      "Script version matches the tested version exactly.",
      "Script version does not match the tested version exactly.");
  }
  addCheck(checks, "target-framework-api.range-reviewed",
    providerCatalog !== undefined && providerCatalog.targetFrameworkApiRange !== null
      && providerCatalog.providerVersion === profile.providerVersion
      && providerCatalog.targetFrameworkApiRange === profile.targetFrameworkApiRange,
    "Provider version and target-framework API range match the reviewed surface catalog.",
    "Provider version or target-framework API range is absent from or differs from the reviewed surface catalog.");

  const runtimeInspection = inspectRuntimeEvidence(runtimeEvidence);
  addCheck(checks, "runtime.health", runtimeInspection.findings.length === 0,
    "Runtime health, capabilities, providers, conflicts, mappings, and telemetry are internally consistent.",
    `Runtime evidence contains ${runtimeInspection.findings.length} health or consistency finding(s).`);
  const runtimeProvider = runtimeEvidence.providers.find((entry) =>
    entry.provider === profile.provider);
  addCheck(checks, "runtime.provider-version",
    runtimeProvider !== undefined && runtimeProvider.version === profile.providerVersion,
    "The running compatibility provider version matches the profile exactly.",
    "The running compatibility provider version does not match the profile exactly.");

  const adapters = await listCompatibilityAdapters(repositoryRoot, catalog);
  const requiredAdapters = new Set(profile.requiredAdapters);
  const missingAdapters = adapters.adapters.filter((entry) =>
    requiredAdapters.has(entry.name) && (!entry.installed || !entry.safe));
  addCheck(checks, "adapters.exact", missingAdapters.length === 0,
    "Every required adapter is a checked non-symlink resource.",
    `${missingAdapters.length} required adapter(s) are missing or unsafe.`);

  const expectedTests = isRecord(profile.raw.evidence) && Array.isArray(profile.raw.evidence.tests)
    ? profile.raw.evidence.tests.filter((entry): entry is string => typeof entry === "string").sort(compareText)
    : [];
  const candidateTests = candidate ? [...candidate.tests].sort((left, right) => compareText(left.path, right.path)) : [];
  const executionMatches = executionEvidenceMatchesProfile(profile, executionEvidence, expectedTests);
  addCheck(checks, "tests.exact-set",
    candidateTests.length === expectedTests.length
      && candidateTests.every((entry, index) => entry.path === expectedTests[index])
      && executionMatches,
    "Runtime and execution evidence name exactly the profile's checked-in tests.",
    "Runtime or execution evidence does not prove the profile's exact checked-in test set.");

  const verifiedTests: Array<{
    path: string; sha256: string; status: "PASS"; tracked: true;
  }> = [];
  for (const expectedPath of expectedTests) {
    const evidenceTest = candidateTests.find((entry) => entry.path === expectedPath);
    const executedFlow = executionEvidence?.flows.find((entry) => entry.testPath === expectedPath);
    const actualHash = await safeTestHash(repositoryRoot, expectedPath);
    const passed = evidenceTest?.status === "PASS" && actualHash !== null
      && evidenceTest.sha256 === actualHash && executionMatches
      && executedFlow?.status === "PASS" && executedFlow.testSha256 === actualHash
      && isTrackedFile(repositoryRoot, expectedPath);
    addCheck(checks, `test:${expectedPath}`, passed,
      "The repository-owned flow and runtime test passed with the exact checked-in file hash.",
      "The flow was not executed successfully or its checked-in file hash does not match.");
    if (passed && actualHash) verifiedTests.push({
      path: expectedPath, sha256: actualHash, status: "PASS", tracked: true,
    });
  }

  const [profileCatalogBinding, surfaceCatalogBinding, consumerCatalogBinding,
    moneyPolicyCatalogBinding, reviewLockBinding, ...schemaBindings] =
    await Promise.all([
      certificationBinding(repositoryRoot, profileCatalogPath),
      surfaceCatalogPath ? certificationBinding(repositoryRoot, surfaceCatalogPath) : null,
      certificationBinding(repositoryRoot, CONSUMER_CATALOG),
      certificationBinding(repositoryRoot, MONEY_POLICY_CATALOG),
      certificationBinding(repositoryRoot, REVIEW_LOCK),
      ...CERTIFICATION_SCHEMAS.map((path) => certificationBinding(repositoryRoot, path)),
    ]);
  const bindingsComplete = profileCatalogBinding !== null
    && surfaceCatalogBinding !== null && consumerCatalogBinding !== null
    && moneyPolicyCatalogBinding !== null && reviewLockBinding !== null
    && schemaBindings.length === CERTIFICATION_SCHEMAS.length
    && schemaBindings.every((entry) => entry !== null);

  const certified = checks.every((check) => check.status === "PASS") && candidate !== undefined
    && profile.provider !== null && profile.testedVersion !== null
    && profile.providerVersion !== null && profile.targetFrameworkApiRange !== null
    && providerCatalog !== undefined && bindingsComplete;
  let certificate: CompatibilityCertificationReport["certificate"] = null;
  if (certified && candidate && profile.provider && profile.testedVersion
    && profile.providerVersion && profile.targetFrameworkApiRange
    && profileCatalogBinding && surfaceCatalogBinding && consumerCatalogBinding
    && moneyPolicyCatalogBinding && reviewLockBinding) {
    const payload: CertificatePayload = {
      schema: 1 as const,
      kind: "synex-compatibility-certificate",
      profileId,
      profileVersion: profile.version,
      provider: profile.provider,
      providerResource: PROVIDER_RESOURCES[profile.provider],
      providerVersion: profile.providerVersion,
      targetFrameworkApiRange: profile.targetFrameworkApiRange,
      script: { name: profile.script, version: profile.testedVersion },
      tests: verifiedTests.sort((left, right) => compareText(left.path, right.path)),
      sourceUrls: profileSourceUrls(profile),
      bindings: {
        profileCatalog: profileCatalogBinding,
        surfaceCatalog: surfaceCatalogBinding,
        consumerCatalog: consumerCatalogBinding,
        moneyPolicyCatalog: moneyPolicyCatalogBinding,
        reviewLock: reviewLockBinding,
        schemas: schemaBindings.filter((entry): entry is CertificationBinding => entry !== null)
          .sort((left, right) => compareText(left.path, right.path)),
      },
    };
    certificate = { ...payload, fingerprint: certificateFingerprint(payload, checks) };
  }
  return {
    schema: 1,
    artifactKind: "synex-compatibility-certification",
    status: certified ? "CERTIFIED" : "UNKNOWN",
    certified,
    profileId,
    checks,
    certificate,
    disclaimer: "Certification is fail-closed and binds only the exact profile, provider, script version, reviewed consumer and money-policy catalogs, checked-in test hashes, and supplied operator evidence. It does not run or inspect FXServer itself.",
  };
}

interface ReviewLockEntry {
  id: string;
  provider: CompatibilityProvider;
  providerVersion: string;
  targetFrameworkApiRange: string | null;
  catalogPath: string;
  catalogSha256: string;
  upstream: {
    repository: string;
    branch: "main";
    revision: string;
    pinSha256: string;
  };
  evidenceUrls: string[];
}

interface UpstreamSourcePin {
  id: string;
  path: string;
  bytes: number;
  sha256: string;
}

interface UpstreamCatalogPin {
  repository: string;
  branch: "main";
  revision: string;
  sources: UpstreamSourcePin[];
}

interface ReviewLockCatalog {
  id: string;
  catalogPath: string;
  catalogSha256: string;
}

interface ReviewLock {
  $schema: string;
  schema: 1;
  kind: "synex-compatibility-review-lock";
  algorithm: "sha256";
  mappingCatalog: ReviewLockCatalog;
  consumerCatalog: ReviewLockCatalog;
  moneyPolicyCatalog: ReviewLockCatalog;
  entries: ReviewLockEntry[];
}

interface ReviewLockCatalogReport {
  id: string;
  catalogPath: string;
  expectedSha256: string;
  actualSha256: string | null;
  hashMatches: boolean;
}

export interface CompatibilityReviewLockReport {
  schema: 1;
  artifactKind: "synex-compatibility-review-lock";
  status: "PASS" | "FAIL" | "UNKNOWN";
  localStatus: "PASS" | "FAIL";
  upstreamStatus: "MATCH" | "DRIFT" | "UNKNOWN";
  networkAccess: boolean;
  limits: {
    timeoutMs: number;
    maximumSourceBytes: number;
  };
  mappingCatalog: ReviewLockCatalogReport;
  consumerCatalog: ReviewLockCatalogReport;
  moneyPolicyCatalog: ReviewLockCatalogReport;
  entries: Array<{
    id: string;
    provider: CompatibilityProvider;
    providerVersionMatches: boolean;
    targetFrameworkApiRangeMatches: boolean;
    catalogPath: string;
    expectedSha256: string;
    actualSha256: string | null;
    hashMatches: boolean;
    evidenceMatches: boolean;
    upstreamPinMatches: boolean;
  }>;
  upstreamSources: Array<{
    id: string;
    provider: CompatibilityProvider;
    path: string;
    baselineRevision: string;
    expectedBytes: number;
    actualBytes: number | null;
    expectedSha256: string;
    actualSha256: string | null;
    immutableUrl: string;
    watchUrl: string;
    status: "MATCH" | "DRIFT" | "UNKNOWN";
    message: string;
  }>;
  findings: Array<{ code: string; subject: string; message: string }>;
  disclaimer: string;
}

export interface CompatibilityReviewLockOptions {
  online?: boolean;
  timeoutMs?: number;
  fetcher?: typeof fetch;
}

async function readCheckedArtifact(repositoryRoot: string, relativePath: string): Promise<{
  text: string;
  value: unknown;
}> {
  if (isAbsolute(relativePath)) throw new CliError("Compatibility evidence paths must be relative.", 2);
  const path = resolve(repositoryRoot, relativePath);
  const rel = relative(resolve(repositoryRoot), path);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new CliError("Compatibility evidence paths must remain inside the repository root.", 2);
  }
  let current = resolve(repositoryRoot);
  for (const segment of rel.split(sep).filter(Boolean)) {
    current = join(current, segment);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink()) throw new CliError("Compatibility evidence cannot traverse symlinks.", 2);
  }
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.size > MAX_ARTIFACT_BYTES) {
    throw new CliError("Compatibility evidence must be a bounded regular file.", 2);
  }
  const text = await readFile(path, "utf8");
  try {
    return { text, value: JSON.parse(text) as unknown };
  } catch {
    throw new CliError("Compatibility evidence is not valid JSON.", 2);
  }
}

function readUpstreamCatalogPin(value: unknown): UpstreamCatalogPin | null {
  if (!isRecord(value) || !isRecord(value.upstream)) return null;
  const upstream = value.upstream;
  if (typeof upstream.repository !== "string" || upstream.branch !== "main"
    || typeof upstream.revision !== "string" || !/^[0-9a-f]{40}$/u.test(upstream.revision)
    || !Array.isArray(upstream.sources) || upstream.sources.length === 0) return null;
  const sources: UpstreamSourcePin[] = [];
  for (const source of upstream.sources) {
    if (!isRecord(source) || typeof source.id !== "string"
      || !/^[a-z][a-z0-9_.:-]{0,95}$/u.test(source.id) || typeof source.path !== "string"
      || typeof source.bytes !== "number" || !Number.isSafeInteger(source.bytes)
      || source.bytes < 1 || source.bytes > MAX_UPSTREAM_SOURCE_BYTES
      || typeof source.sha256 !== "string" || !/^[0-9a-f]{64}$/u.test(source.sha256)) return null;
    sources.push({ id: source.id, path: source.path, bytes: source.bytes, sha256: source.sha256 });
  }
  return {
    repository: upstream.repository,
    branch: "main",
    revision: upstream.revision,
    sources,
  };
}

function upstreamPinHash(pin: UpstreamCatalogPin): string {
  return sha256(canonicalJson(pin));
}

function isSafeUpstreamPath(path: string): boolean {
  if (path.length === 0 || path.startsWith("/") || path.includes("\\")) return false;
  return path.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}

function rawGithubUrl(repository: string, revision: string, path: string): string {
  const parsed = new URL(repository);
  const repositoryPath = parsed.pathname.split("/").filter(Boolean).map(encodeURIComponent).join("/");
  const sourcePath = path.split("/").map(encodeURIComponent).join("/");
  return `https://raw.githubusercontent.com/${repositoryPath}/${revision}/${sourcePath}`;
}

async function readBoundedUpstreamResponse(response: Response): Promise<Uint8Array> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null && /^\d+$/u.test(contentLength)
    && Number(contentLength) > MAX_UPSTREAM_SOURCE_BYTES) throw new Error("SOURCE_TOO_LARGE");
  if (!response.body) throw new Error("SOURCE_BODY_MISSING");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    total += chunk.value.byteLength;
    if (total > MAX_UPSTREAM_SOURCE_BYTES) {
      await reader.cancel();
      throw new Error("SOURCE_TOO_LARGE");
    }
    chunks.push(chunk.value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

async function inspectUpstreamSource(
  provider: CompatibilityProvider,
  pin: UpstreamCatalogPin,
  source: UpstreamSourcePin,
  timeoutMs: number,
  fetcher: typeof fetch,
): Promise<CompatibilityReviewLockReport["upstreamSources"][number]> {
  const immutableUrl = rawGithubUrl(pin.repository, pin.revision, source.path);
  const watchUrl = rawGithubUrl(pin.repository, pin.branch, source.path);
  const base = {
    id: source.id,
    provider,
    path: source.path,
    baselineRevision: pin.revision,
    expectedBytes: source.bytes,
    expectedSha256: source.sha256,
    immutableUrl,
    watchUrl,
  };
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetcher(watchUrl, {
      headers: { accept: "text/plain" },
      redirect: "error",
      signal: controller.signal,
    });
    if (!response.ok) return {
      ...base, actualBytes: null, actualSha256: null, status: "UNKNOWN",
      message: `The official source returned HTTP ${response.status}.`,
    };
    if (response.url) {
      const finalUrl = new URL(response.url);
      if (finalUrl.protocol !== "https:" || finalUrl.hostname !== "raw.githubusercontent.com"
        || response.url !== watchUrl) return {
        ...base, actualBytes: null, actualSha256: null, status: "UNKNOWN",
        message: "The official source response did not retain the exact allowlisted URL.",
      };
    }
    const body = await readBoundedUpstreamResponse(response);
    const actualSha256 = createHash("sha256").update(body).digest("hex");
    const matches = body.byteLength === source.bytes && actualSha256 === source.sha256;
    return {
      ...base,
      actualBytes: body.byteLength,
      actualSha256,
      status: matches ? "MATCH" : "DRIFT",
      message: matches
        ? "The watched main-branch source matches the commit-pinned baseline."
        : "The watched main-branch source differs from the commit-pinned baseline.",
    };
  } catch (error) {
    const oversized = error instanceof Error && error.message === "SOURCE_TOO_LARGE";
    return {
      ...base, actualBytes: null, actualSha256: null, status: "UNKNOWN",
      message: oversized
        ? `The official source exceeded the ${MAX_UPSTREAM_SOURCE_BYTES}-byte safety limit.`
        : "The official source could not be read before the bounded request completed.",
    };
  } finally {
    clearTimeout(timeout);
  }
}

export async function checkCompatibilityReviewLock(
  repositoryRoot: string,
  options: CompatibilityReviewLockOptions = {},
): Promise<CompatibilityReviewLockReport> {
  const online = options.online === true;
  const timeoutMs = options.timeoutMs ?? DEFAULT_UPSTREAM_TIMEOUT_MS;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < MIN_UPSTREAM_TIMEOUT_MS
    || timeoutMs > MAX_UPSTREAM_TIMEOUT_MS) {
    throw new CliError(
      `Compatibility upstream timeout must be an integer between ${MIN_UPSTREAM_TIMEOUT_MS} and ${MAX_UPSTREAM_TIMEOUT_MS} milliseconds.`,
      2,
    );
  }
  const [schemaArtifact, lockArtifact] = await Promise.all([
    readCheckedArtifact(repositoryRoot, REVIEW_LOCK_SCHEMA),
    readCheckedArtifact(repositoryRoot, REVIEW_LOCK),
  ]);
  if (!isRecord(schemaArtifact.value)) throw new CliError("Compatibility review-lock schema is invalid.", 2);
  const validator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false })
    .compile(schemaArtifact.value as AnySchema);
  if (!validator(lockArtifact.value)) {
    throw new CliError(`Compatibility review lock does not satisfy its schema (${validator.errors?.length ?? 0} error(s)).`, 2);
  }
  const lock = lockArtifact.value as unknown as ReviewLock;
  const findings: CompatibilityReviewLockReport["findings"] = [];
  const providerCounts = new Map<CompatibilityProvider, number>();
  const ids = new Set<string>();
  const paths = new Set<string>();
  const entries: CompatibilityReviewLockReport["entries"] = [];
  const catalogPins: Array<{ provider: CompatibilityProvider; pin: UpstreamCatalogPin }> = [];
  const lockedCatalogs = [
    {
      key: "mappingCatalog", lock: lock.mappingCatalog,
      code: "LOCAL_MAPPING_CATALOG_HASH_DRIFT",
      message: "The checked-in mapping catalog no longer matches its reviewed lock hash.",
    },
    {
      key: "consumerCatalog", lock: lock.consumerCatalog,
      code: "LOCAL_CONSUMER_CATALOG_HASH_DRIFT",
      message: "The checked-in consumer authorization catalog no longer matches its reviewed lock hash.",
    },
    {
      key: "moneyPolicyCatalog", lock: lock.moneyPolicyCatalog,
      code: "LOCAL_MONEY_POLICY_CATALOG_HASH_DRIFT",
      message: "The checked-in money-policy catalog no longer matches its reviewed lock hash.",
    },
  ] as const;
  const lockedCatalogReports = new Map<string, ReviewLockCatalogReport>();
  for (const locked of lockedCatalogs) {
    if (ids.has(locked.lock.id) || paths.has(locked.lock.catalogPath)) findings.push({
      code: "REVIEW_LOCK_DUPLICATE", subject: locked.lock.id,
      message: "The compatibility review lock contains a duplicate id or catalog path.",
    });
    ids.add(locked.lock.id);
    paths.add(locked.lock.catalogPath);
    const artifact = await readCheckedArtifact(repositoryRoot, locked.lock.catalogPath);
    const actualSha256 = sha256(artifact.text);
    const hashMatches = actualSha256 === locked.lock.catalogSha256;
    if (!hashMatches) findings.push({
      code: locked.code, subject: locked.lock.id, message: locked.message,
    });
    lockedCatalogReports.set(locked.key, {
      id: locked.lock.id,
      catalogPath: locked.lock.catalogPath,
      expectedSha256: locked.lock.catalogSha256,
      actualSha256,
      hashMatches,
    });
  }
  for (const entry of [...lock.entries].sort((left, right) => compareText(left.id, right.id))) {
    providerCounts.set(entry.provider, (providerCounts.get(entry.provider) ?? 0) + 1);
    if (ids.has(entry.id) || paths.has(entry.catalogPath)) findings.push({
      code: "REVIEW_LOCK_DUPLICATE", subject: entry.id,
      message: "The compatibility review lock contains a duplicate id or catalog path.",
    });
    ids.add(entry.id);
    paths.add(entry.catalogPath);
    const catalog = await readCheckedArtifact(repositoryRoot, entry.catalogPath);
    const actualSha256 = sha256(catalog.text);
    let evidenceMatches = false;
    let providerVersionMatches = false;
    let targetFrameworkApiRangeMatches = false;
    const catalogPin = readUpstreamCatalogPin(catalog.value);
    let upstreamPinMatches = false;
    if (isRecord(catalog.value) && isRecord(catalog.value.upstream)
      && Array.isArray(catalog.value.upstream.evidenceUrls)) {
      const urls = catalog.value.upstream.evidenceUrls
        .filter((value): value is string => typeof value === "string");
      evidenceMatches = canonicalJson(urls) === canonicalJson(entry.evidenceUrls);
      providerVersionMatches = catalog.value.providerVersion === entry.providerVersion;
      targetFrameworkApiRangeMatches =
        (typeof catalog.value.targetFrameworkApiRange === "string"
          || catalog.value.targetFrameworkApiRange === null)
        && catalog.value.targetFrameworkApiRange === entry.targetFrameworkApiRange;
    }
    if (catalogPin) {
      const sourceIds = new Set<string>();
      const sourcePaths = new Set<string>();
      let sourceSetValid = catalogPin.sources.length > 0;
      for (const source of catalogPin.sources) {
        if (sourceIds.has(source.id) || sourcePaths.has(source.path)
          || !isSafeUpstreamPath(source.path)) sourceSetValid = false;
        sourceIds.add(source.id);
        sourcePaths.add(source.path);
      }
      const repositoryMatches = catalogPin.repository === UPSTREAM_REPOSITORIES[entry.provider];
      upstreamPinMatches = sourceSetValid && repositoryMatches
        && catalogPin.repository === entry.upstream.repository
        && catalogPin.branch === entry.upstream.branch
        && catalogPin.revision === entry.upstream.revision
        && upstreamPinHash(catalogPin) === entry.upstream.pinSha256;
      if (sourceSetValid && repositoryMatches) catalogPins.push({ provider: entry.provider, pin: catalogPin });
    }
    const hashMatches = actualSha256 === entry.catalogSha256;
    if (!hashMatches) findings.push({
      code: "LOCAL_CATALOG_HASH_DRIFT", subject: entry.id,
      message: "The checked-in surface catalog no longer matches its reviewed lock hash.",
    });
    if (!evidenceMatches) findings.push({
      code: "LOCAL_EVIDENCE_SET_DRIFT", subject: entry.id,
      message: "The catalog evidence URL set no longer matches the reviewed lock entry.",
    });
    if (!providerVersionMatches) findings.push({
      code: "LOCAL_PROVIDER_VERSION_DRIFT", subject: entry.id,
      message: "The catalog provider version no longer matches the reviewed lock entry.",
    });
    if (!targetFrameworkApiRangeMatches) findings.push({
      code: "LOCAL_TARGET_API_RANGE_DRIFT", subject: entry.id,
      message: "The catalog target-framework API range no longer matches the reviewed lock entry.",
    });
    if (!upstreamPinMatches) findings.push({
      code: "LOCAL_UPSTREAM_PIN_DRIFT", subject: entry.id,
      message: "The official repository, branch, revision, source set, or source hashes no longer match the reviewed upstream pin.",
    });
    entries.push({
      id: entry.id,
      provider: entry.provider,
      providerVersionMatches,
      targetFrameworkApiRangeMatches,
      catalogPath: entry.catalogPath,
      expectedSha256: entry.catalogSha256,
      actualSha256,
      hashMatches,
      evidenceMatches,
      upstreamPinMatches,
    });
  }
  for (const provider of ["qb", "qbx", "esx"] as const) {
    if (providerCounts.get(provider) !== 1) findings.push({
      code: "REVIEW_PROVIDER_LOCK_INVALID", subject: provider,
      message: "The compatibility review lock must contain exactly one entry for this provider.",
    });
  }
  const localStatus = findings.length === 0 ? "PASS" : "FAIL";
  let upstreamSources: CompatibilityReviewLockReport["upstreamSources"] = [];
  if (online && localStatus === "PASS") {
    const fetcher = options.fetcher ?? fetch;
    upstreamSources = await Promise.all(catalogPins.flatMap(({ provider, pin }) =>
      pin.sources.map((source) => inspectUpstreamSource(provider, pin, source, timeoutMs, fetcher))));
    upstreamSources.sort((left, right) => compareText(left.provider, right.provider)
      || compareText(left.id, right.id));
    for (const source of upstreamSources) {
      if (source.status === "DRIFT") findings.push({
        code: "UPSTREAM_SOURCE_DRIFT", subject: source.id,
        message: "The official main-branch source differs from the reviewed commit-pinned baseline.",
      });
      if (source.status === "UNKNOWN") findings.push({
        code: "UPSTREAM_SOURCE_UNKNOWN", subject: source.id,
        message: "The official source could not be verified; upstream status remains UNKNOWN.",
      });
    }
  }
  const upstreamStatus: CompatibilityReviewLockReport["upstreamStatus"] = !online
    || localStatus === "FAIL" || upstreamSources.some((source) => source.status === "UNKNOWN")
    ? "UNKNOWN"
    : upstreamSources.some((source) => source.status === "DRIFT") ? "DRIFT" : "MATCH";
  const status: CompatibilityReviewLockReport["status"] = localStatus === "FAIL"
    || upstreamStatus === "DRIFT" ? "FAIL" : online && upstreamStatus === "UNKNOWN" ? "UNKNOWN" : "PASS";
  findings.sort((left, right) => compareText(left.subject, right.subject)
    || compareText(left.code, right.code));
  return {
    schema: 1,
    artifactKind: "synex-compatibility-review-lock",
    status,
    localStatus,
    upstreamStatus,
    networkAccess: online,
    limits: { timeoutMs, maximumSourceBytes: MAX_UPSTREAM_SOURCE_BYTES },
    mappingCatalog: lockedCatalogReports.get("mappingCatalog")!,
    consumerCatalog: lockedCatalogReports.get("consumerCatalog")!,
    moneyPolicyCatalog: lockedCatalogReports.get("moneyPolicyCatalog")!,
    entries,
    upstreamSources,
    findings,
    disclaimer: online
      ? "The opt-in network check compares bounded official main-branch source bytes with commit-pinned SHA-256 baselines. Any timeout, HTTP error, redirect, or size violation remains UNKNOWN and is never reported as PASS. A matching source set does not create a framework API version range or certify a compatibility surface."
      : "This deterministic check detects local catalog and commit-pinned source-lock drift without network access; upstream API drift therefore remains UNKNOWN until compat drift --online is explicitly requested.",
  };
}
