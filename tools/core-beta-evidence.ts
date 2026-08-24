import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { realpathSync, statSync } from "node:fs";
import { lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { arch, platform, release } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const DATABASE_NAME_PATTERN = /^synex_test_[a-z0-9_]+$/u;
const GIT_OBJECT_PATTERN = /^[0-9a-f]{40,64}$/u;
const WARNING_NAME_PATTERN = /^[a-z0-9:_\/-]{1,128}$/u;
const MAX_COMMAND_OUTPUT_BYTES = 32 * 1024 * 1024;
const MAX_CERTIFICATION_OUTPUT_BYTES = 4 * 1024 * 1024;
const MAX_EVIDENCE_BYTES = 64 * 1024;

export const ALLOWED_CERTIFICATION_WARNINGS = [
  "capability-policy",
  "dependency-graph",
  "schema-and-manifest-validation",
] as const;

type GateCommandId = "check" | "test-live-database" | "security" | "certify" | "audit";
type GateStatus = "PASS" | "FAIL";

interface GateCommandSpec {
  id: GateCommandId;
  display: string;
  runner: "npm" | "synex-cli";
  arguments: string[];
  liveDatabase: boolean;
  captureStdout: boolean;
  timeoutMs: number;
}

export interface GateCommandRequest {
  id: GateCommandId;
  executable: string;
  arguments: string[];
  cwd: string;
  environment: NodeJS.ProcessEnv;
  captureStdout: boolean;
  timeoutMs: number;
}

export interface GateCommandResult {
  exitCode: number | null;
  errorCode: string | null;
  outputSha256: string;
  outputBytes: number;
  capturedStdout: string | null;
}

export type GateCommandRunner = (request: GateCommandRequest) => Promise<GateCommandResult>;

export interface CoreBetaEvidenceOptions {
  repositoryRoot?: string;
  output?: string;
  environment?: NodeJS.ProcessEnv;
}

export interface CoreBetaEvidenceDependencies {
  runCommand?: GateCommandRunner;
  now?: () => Date;
  system?: () => { platform: NodeJS.Platform; release: string; architecture: string; node: string };
}

interface CertificationSummary {
  reportedStatus: "PASS" | "WARN" | "FAIL" | "INVALID";
  policyStatus: GateStatus;
  revisionMatches: boolean;
  coreIncluded: boolean;
  checkHash: string | null;
  warnings: string[];
  allowedWarnings: string[];
  unknownWarnings: string[];
  warningPolicyViolations: string[];
}

interface CommandEvidence {
  id: GateCommandId;
  command: string;
  status: GateStatus;
  exitCode: number | null;
  failure: "NONE" | "NONZERO_EXIT" | "LAUNCH_FAILED" | "CERTIFICATION_POLICY";
  durationMs: number;
  output: {
    stored: false;
    sha256: string;
    bytes: number;
  };
}

export interface CoreBetaEvidence {
  schema: 1;
  artifactKind: "synex-core-production-beta-evidence";
  generatedAt: string;
  status: GateStatus;
  releaseReady: false;
  releaseDecision: "NOT_ASSERTED_MANUAL_GATES_REQUIRED";
  scope: {
    included: ["synex_core"];
    profile: "single-instance-mariadb";
    outOfScope: Array<{
      item: "multi-instance-kick-old" | "mysql-server" | "downstream-resources";
      reason: string;
    }>;
  };
  revision: {
    head: string;
    branch: string | null;
    cleanAtStart: true;
    cleanAtEnd: boolean;
    headUnchanged: boolean;
    core: {
      path: "core/synex_core";
      gitTreeObject: string;
      trackedTreeSha256: string;
    };
    packageLockSha256: string;
  };
  environment: {
    platform: NodeJS.Platform;
    release: string;
    architecture: string;
    node: string;
    databaseGate: {
      live: true;
      variable: "SYNEX_TEST_DATABASE_URL";
      protocol: "mysql:";
      requiredServer: "MariaDB";
      namePattern: "synex_test_[a-z0-9_]+";
      credentialsStored: false;
    };
  };
  commands: CommandEvidence[];
  certification: CertificationSummary;
  manualGates: Array<{
    name: string;
    status: "NOT_RUN";
  }>;
  integrity: {
    algorithm: "sha256";
    payloadSha256: string;
  };
}

interface ValidatedDatabaseEnvironment {
  url: string;
  childValues: {
    SYNEX_TEST_DATABASE_LIVE: "1";
    SYNEX_TEST_DATABASE_URL: string;
  };
}

const COMMANDS: readonly GateCommandSpec[] = [
  {
    id: "check",
    display: "npm run check",
    runner: "npm",
    arguments: ["run", "check"],
    liveDatabase: false,
    captureStdout: false,
    timeoutMs: 10 * 60 * 1_000,
  },
  {
    id: "test-live-database",
    display: "npm test (live database gate)",
    runner: "npm",
    arguments: ["test"],
    liveDatabase: true,
    captureStdout: false,
    timeoutMs: 20 * 60 * 1_000,
  },
  {
    id: "security",
    display: "npm run security",
    runner: "npm",
    arguments: ["run", "security"],
    liveDatabase: false,
    captureStdout: false,
    timeoutMs: 10 * 60 * 1_000,
  },
  {
    id: "certify",
    display: "node --experimental-strip-types tools/cli/src/bin.ts certify repository --json",
    runner: "synex-cli",
    arguments: ["certify", "repository", "--json"],
    liveDatabase: true,
    captureStdout: true,
    timeoutMs: 25 * 60 * 1_000,
  },
  {
    id: "audit",
    display: "npm audit --audit-level=high",
    runner: "npm",
    arguments: ["audit", "--audit-level=high"],
    liveDatabase: false,
    captureStdout: false,
    timeoutMs: 10 * 60 * 1_000,
  },
];

const MANUAL_GATES = [
  "exact-revision-fxserver-startup",
  "fresh-install",
  "backup-restore-and-25-to-26-upgrade",
  "prepared-core-restart-and-recovery",
  "unprepared-core-restart-and-recovery",
  "full-fxserver-process-crash-and-recovery",
  "database-outage-and-recovery",
  "client-join-disconnect-reconnect",
  "bounded-soak-and-load",
] as const;

const OUT_OF_SCOPE = [
  {
    item: "multi-instance-kick-old",
    reason: "The first Core production-beta profile supports one Synex Core instance only.",
  },
  {
    item: "mysql-server",
    reason: "The first Core production-beta database profile is MariaDB; mysql: is connector URL syntax only.",
  },
  {
    item: "downstream-resources",
    reason: "synex_entities, synex_accounts, synex_groups, and all later resources are rework snapshots.",
  },
] as const;

function sha256(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function safeErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object" || !("code" in error) || typeof error.code !== "string") return null;
  return error.code.replace(/[^A-Z0-9_]/giu, "").slice(0, 64) || "SPAWN_FAILED";
}

export function summarizeCommandOutput(stdout: string, stderr: string): {
  outputSha256: string;
  outputBytes: number;
} {
  const stdoutHash = sha256(stdout);
  const stderrHash = sha256(stderr);
  return {
    outputSha256: sha256(`stdout:${stdoutHash}\nstderr:${stderrHash}\n`),
    outputBytes: Buffer.byteLength(stdout, "utf8") + Buffer.byteLength(stderr, "utf8"),
  };
}

async function defaultRunCommand(request: GateCommandRequest): Promise<GateCommandResult> {
  const result = spawnSync(request.executable, request.arguments, {
    cwd: request.cwd,
    encoding: "utf8",
    env: request.environment,
    maxBuffer: MAX_COMMAND_OUTPUT_BYTES,
    timeout: request.timeoutMs,
    windowsHide: true,
    shell: false,
  });
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const summary = summarizeCommandOutput(stdout, stderr);
  const capturedStdout = request.captureStdout && Buffer.byteLength(stdout, "utf8") <= MAX_CERTIFICATION_OUTPUT_BYTES
    ? stdout
    : null;
  return {
    exitCode: result.status,
    errorCode: safeErrorCode(result.error),
    ...summary,
    capturedStdout,
  };
}

function npmInvocation(environment: NodeJS.ProcessEnv): { executable: string; argumentPrefix: string[] } {
  const candidates = [
    environment.npm_execpath,
    process.env.npm_execpath,
    join(dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"),
    join(dirname(dirname(process.execPath)), "lib", "node_modules", "npm", "bin", "npm-cli.js"),
  ];
  const visited = new Set<string>();
  for (const candidate of candidates) {
    if (typeof candidate !== "string" || !isAbsolute(candidate)) continue;
    try {
      const resolved = realpathSync(candidate);
      if (visited.has(resolved)) continue;
      visited.add(resolved);
      if (!["npm-cli.js", "npm-cli.cjs"].includes(basename(resolved).toLowerCase())
        || !statSync(resolved).isFile()) continue;
      return { executable: process.execPath, argumentPrefix: [resolved] };
    } catch {
      // Try the next fixed npm CLI location without exposing local paths.
    }
  }
  throw new Error("The npm CLI entry point could not be resolved safely.");
}

function gitText(repositoryRoot: string, arguments_: string[], allowNonzero = false): string | null {
  const result = spawnSync("git", arguments_, {
    cwd: repositoryRoot,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 30_000,
    windowsHide: true,
    shell: false,
  });
  if (result.status !== 0) {
    if (allowNonzero) return null;
    throw new Error("Git repository inspection failed.");
  }
  return result.stdout.trim();
}

function gitBytes(repositoryRoot: string, arguments_: string[]): Buffer {
  const result = spawnSync("git", arguments_, {
    cwd: repositoryRoot,
    encoding: "buffer",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 30_000,
    windowsHide: true,
    shell: false,
  });
  if (result.status !== 0 || !Buffer.isBuffer(result.stdout)) {
    throw new Error("Git tree inspection failed.");
  }
  return result.stdout;
}

function normalizePathForComparison(path: string): string {
  const normalized = resolve(path).replace(/[\\/]+$/u, "");
  return process.platform === "win32" ? normalized.toLocaleLowerCase("en-US") : normalized;
}

function containsPath(parent: string, child: string): boolean {
  const relativePath = relative(parent, child);
  return relativePath === "" || (!relativePath.startsWith(`..${sep}`) && relativePath !== ".." && !isAbsolute(relativePath));
}

async function requireRepositoryRoot(requestedRoot: string): Promise<string> {
  const repositoryRoot = await realpath(resolve(requestedRoot));
  const reportedRoot = gitText(repositoryRoot, ["rev-parse", "--show-toplevel"]);
  if (!reportedRoot || normalizePathForComparison(reportedRoot) !== normalizePathForComparison(repositoryRoot)) {
    throw new Error("--root must reference the Git repository root.");
  }
  return repositoryRoot;
}

function requireCleanRevision(repositoryRoot: string): {
  head: string;
  branch: string | null;
  coreTreeObject: string;
  coreTrackedTreeSha256: string;
} {
  const dirty = gitText(repositoryRoot, ["status", "--porcelain=v1", "--untracked-files=all"]);
  if (dirty !== "") throw new Error("Core beta evidence requires a clean Git revision; no commands were run.");
  const head = gitText(repositoryRoot, ["rev-parse", "--verify", "HEAD^{commit}"]);
  const coreTreeObject = gitText(repositoryRoot, ["rev-parse", "HEAD:core/synex_core"]);
  if (!head || !coreTreeObject || !GIT_OBJECT_PATTERN.test(head) || !GIT_OBJECT_PATTERN.test(coreTreeObject)) {
    throw new Error("The exact Git revision or synex_core tree could not be resolved.");
  }
  const branch = gitText(repositoryRoot, ["symbolic-ref", "--quiet", "--short", "HEAD"], true);
  const treeListing = gitBytes(repositoryRoot, ["ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", "core/synex_core"]);
  if (treeListing.length === 0) throw new Error("The tracked synex_core tree is empty.");
  return {
    head,
    branch: branch || null,
    coreTreeObject,
    coreTrackedTreeSha256: sha256(treeListing),
  };
}

export function validateLiveDatabaseEnvironment(environment: NodeJS.ProcessEnv): ValidatedDatabaseEnvironment {
  if (environment.SYNEX_TEST_DATABASE_LIVE !== "1") {
    throw new Error("SYNEX_TEST_DATABASE_LIVE=1 is required for core beta evidence.");
  }
  const rawUrl = environment.SYNEX_TEST_DATABASE_URL;
  if (!rawUrl) throw new Error("SYNEX_TEST_DATABASE_URL is required for core beta evidence.");
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error("SYNEX_TEST_DATABASE_URL is invalid.");
  }
  if (parsed.protocol !== "mysql:") throw new Error("SYNEX_TEST_DATABASE_URL must use mysql://.");
  let databaseName: string;
  try {
    databaseName = decodeURIComponent(parsed.pathname.replace(/^\//u, ""));
  } catch {
    throw new Error("SYNEX_TEST_DATABASE_URL contains an invalid database name.");
  }
  if (!DATABASE_NAME_PATTERN.test(databaseName)) {
    throw new Error("The live database name must match synex_test_[a-z0-9_]+.");
  }
  return {
    url: rawUrl,
    childValues: {
      SYNEX_TEST_DATABASE_LIVE: "1",
      SYNEX_TEST_DATABASE_URL: rawUrl,
    },
  };
}

async function rejectSymbolicPath(repositoryRoot: string, outputPath: string): Promise<void> {
  const pathParts = relative(repositoryRoot, dirname(outputPath)).split(sep).filter(Boolean);
  let current = repositoryRoot;
  for (const part of pathParts) {
    current = join(current, part);
    const metadata = await lstat(current).catch((error: unknown) => {
      if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") return null;
      throw error;
    });
    if (!metadata) break;
    if (metadata.isSymbolicLink()) throw new Error("Evidence output must not traverse symbolic links.");
  }
}

async function resolveEvidenceOutput(repositoryRoot: string, requested: string | undefined, head: string, now: Date): Promise<string> {
  if (requested && isAbsolute(requested)) throw new Error("--output must be repository-relative.");
  const timestamp = now.toISOString().replace(/[:.]/gu, "-");
  const relativeOutput = requested ?? join(
    ".temp",
    "core-beta-evidence",
    `synex-core-beta-${head.slice(0, 12)}-${timestamp}.json`,
  );
  const outputPath = resolve(repositoryRoot, relativeOutput);
  const tempRoot = resolve(repositoryRoot, ".temp");
  const artifactsRoot = resolve(repositoryRoot, "artifacts");
  const belowAllowedRoot = (containsPath(tempRoot, outputPath) && outputPath !== tempRoot)
    || (containsPath(artifactsRoot, outputPath) && outputPath !== artifactsRoot);
  if (!belowAllowedRoot || !outputPath.endsWith(".json") || basename(outputPath) === ".json") {
    throw new Error("Evidence output must be a .json file below ignored .temp/ or artifacts/.");
  }
  await rejectSymbolicPath(repositoryRoot, outputPath);
  const repositoryRelative = relative(repositoryRoot, outputPath).replaceAll("\\", "/");
  const ignored = gitText(repositoryRoot, ["check-ignore", "--quiet", "--no-index", "--", repositoryRelative], true);
  if (ignored === null) throw new Error("Evidence output is not ignored by Git.");
  return outputPath;
}

function childEnvironment(
  base: NodeJS.ProcessEnv,
  database: ValidatedDatabaseEnvironment,
  includeLiveDatabase: boolean,
): NodeJS.ProcessEnv {
  const environment = { ...base };
  delete environment.SYNEX_TEST_DATABASE_LIVE;
  delete environment.SYNEX_TEST_DATABASE_URL;
  if (includeLiveDatabase) Object.assign(environment, database.childValues);
  return environment;
}

function parseCertification(stdout: string | null, expectedHead: string): CertificationSummary {
  const invalid: CertificationSummary = {
    reportedStatus: "INVALID",
    policyStatus: "FAIL",
    revisionMatches: false,
    coreIncluded: false,
    checkHash: null,
    warnings: [],
    allowedWarnings: [...ALLOWED_CERTIFICATION_WARNINGS],
    unknownWarnings: [],
    warningPolicyViolations: [],
  };
  if (stdout === null || Buffer.byteLength(stdout, "utf8") > MAX_CERTIFICATION_OUTPUT_BYTES) return invalid;
  let value: unknown;
  try {
    value = JSON.parse(stdout);
  } catch {
    return invalid;
  }
  if (!value || typeof value !== "object" || !("status" in value) || !("checks" in value)
    || !("artifactKind" in value) || value.artifactKind !== "synex-certification"
    || !("schema" in value) || value.schema !== 1
    || !("revision" in value) || !value.revision || typeof value.revision !== "object"
    || !("commit" in value.revision) || !("dirty" in value.revision)
    || !("target" in value) || !value.target || typeof value.target !== "object"
    || !("resources" in value.target) || !Array.isArray(value.target.resources)
    || !("checkHash" in value) || typeof value.checkHash !== "string"
    || !/^[0-9a-f]{64}$/u.test(value.checkHash)) return invalid;
  const status = value.status;
  const checks = value.checks;
  if ((status !== "PASS" && status !== "WARN" && status !== "FAIL") || !Array.isArray(checks) || checks.length > 1_000) {
    return invalid;
  }
  const warnings: string[] = [];
  const warningDetails = new Map<string, string>();
  let containsFailure = false;
  for (const check of checks) {
    if (!check || typeof check !== "object" || !("name" in check) || !("status" in check)
      || typeof check.name !== "string" || !WARNING_NAME_PATTERN.test(check.name)
      || !("detail" in check) || typeof check.detail !== "string" || check.detail.length > 4_096
      || (check.status !== "PASS" && check.status !== "WARN" && check.status !== "FAIL")) {
      return invalid;
    }
    if (check.status === "WARN") {
      warnings.push(check.name);
      warningDetails.set(check.name, check.detail);
    }
    if (check.status === "FAIL") containsFailure = true;
  }
  const uniqueWarnings = [...new Set(warnings)].sort((left, right) => left.localeCompare(right, "en"));
  const allowed = new Set<string>(ALLOWED_CERTIFICATION_WARNINGS);
  const unknownWarnings = uniqueWarnings.filter((warning) => !allowed.has(warning));
  const warningPolicyViolations: string[] = [];
  const schemaDetail = warningDetails.get("schema-and-manifest-validation");
  if (schemaDetail !== undefined) {
    const match = /^0 error\(s\), ([1-9][0-9]*) warning\(s\)\.$/u.exec(schemaDetail);
    if (!match || !("validation" in value) || !value.validation || typeof value.validation !== "object"
      || !("diagnostics" in value.validation) || !Array.isArray(value.validation.diagnostics)) {
      warningPolicyViolations.push("schema-and-manifest-validation");
    } else {
      const warningDiagnostics = value.validation.diagnostics.filter((diagnostic: unknown) =>
        diagnostic !== null && typeof diagnostic === "object" && "level" in diagnostic && diagnostic.level === "warning"
      );
      const allowedDiagnostics = warningDiagnostics.every((diagnostic: unknown) =>
        diagnostic !== null && typeof diagnostic === "object" && "rule" in diagnostic
        && diagnostic.rule === "resource-dependency-runtime-unverified"
      );
      if (!allowedDiagnostics || warningDiagnostics.length !== Number(match[1])) {
        warningPolicyViolations.push("schema-and-manifest-validation");
      }
    }
  }
  const dependencyDetail = warningDetails.get("dependency-graph");
  if (dependencyDetail !== undefined
    && !/^0 cycle\(s\), 0 unresolved required declaration\(s\), 0 incompatible required version\(s\), [1-9][0-9]* optional\/runtime version warning\(s\)\.$/u.test(dependencyDetail)) {
    warningPolicyViolations.push("dependency-graph");
  }
  const capabilityDetail = warningDetails.get("capability-policy");
  if (capabilityDetail !== undefined
    && !/^0 error\(s\), [1-9][0-9]* warning\(s\), 0 requested but denied\/ungranted capability declaration\(s\)\.$/u.test(capabilityDetail)) {
    warningPolicyViolations.push("capability-policy");
  }
  const revisionMatches = value.revision.commit === expectedHead && value.revision.dirty === false;
  const coreIncluded = value.target.resources.some((resource: unknown) =>
    resource !== null && typeof resource === "object" && "name" in resource && resource.name === "synex_core"
  );
  const consistent = (status === "PASS" && uniqueWarnings.length === 0 && !containsFailure)
    || (status === "WARN" && uniqueWarnings.length > 0 && !containsFailure)
    || (status === "FAIL" && containsFailure);
  return {
    reportedStatus: status,
    policyStatus: consistent && status !== "FAIL" && unknownWarnings.length === 0
      && warningPolicyViolations.length === 0
      && revisionMatches && coreIncluded ? "PASS" : "FAIL",
    revisionMatches,
    coreIncluded,
    checkHash: value.checkHash,
    warnings: uniqueWarnings,
    allowedWarnings: [...ALLOWED_CERTIFICATION_WARNINGS],
    unknownWarnings,
    warningPolicyViolations,
  };
}

function parseArguments(arguments_: string[]): { help: boolean; root: string; output?: string } {
  let help = false;
  let root = process.cwd();
  let output: string | undefined;
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--help" || argument === "-h") {
      help = true;
      continue;
    }
    if (argument === "--root" || argument === "--output") {
      const value = arguments_[index + 1];
      if (!value || value.startsWith("-")) throw new Error(`${argument} requires a value.`);
      if (argument === "--root") root = value;
      else output = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${argument}`);
  }
  return output === undefined ? { help, root } : { help, root, output };
}

function helpText(): string {
  return `Synex Core production-beta evidence gate

Usage:
  npm run evidence:core-beta
  node --experimental-strip-types tools/core-beta-evidence.ts [--root <repository>] [--output <.temp-or-artifacts.json>]

Required environment:
  SYNEX_TEST_DATABASE_LIVE=1
  SYNEX_TEST_DATABASE_URL=mysql://.../synex_test_<name>

The gate requires a clean Git revision, stores no command output or database credentials,
and never marks the required FXServer, recovery, client, or soak gates as completed.
Multi-instance/kick_old, MySQL Server, and downstream resources are explicitly out of scope.`;
}

export async function runCoreBetaEvidence(
  options: CoreBetaEvidenceOptions = {},
  dependencies: CoreBetaEvidenceDependencies = {},
): Promise<{ report: CoreBetaEvidence; output: string }> {
  const environment = options.environment ?? process.env;
  const runCommand = dependencies.runCommand ?? defaultRunCommand;
  const now = dependencies.now ?? (() => new Date());
  const system = dependencies.system ?? (() => ({
    platform: platform(),
    release: release(),
    architecture: arch(),
    node: process.version,
  }));
  const repositoryRoot = await requireRepositoryRoot(options.repositoryRoot ?? process.cwd());
  const revision = requireCleanRevision(repositoryRoot);
  const database = validateLiveDatabaseEnvironment(environment);
  const npm = npmInvocation(environment);
  const startedAt = now();
  const output = await resolveEvidenceOutput(repositoryRoot, options.output, revision.head, startedAt);
  const packageLock = await readFile(join(repositoryRoot, "package-lock.json"));
  const commandEvidence: CommandEvidence[] = [];
  let certification: CertificationSummary = {
    reportedStatus: "INVALID",
    policyStatus: "FAIL",
    revisionMatches: false,
    coreIncluded: false,
    checkHash: null,
    warnings: [],
    allowedWarnings: [...ALLOWED_CERTIFICATION_WARNINGS],
    unknownWarnings: [],
    warningPolicyViolations: [],
  };

  for (const command of COMMANDS) {
    const commandStarted = now();
    const invocation = command.runner === "npm"
      ? { executable: npm.executable, arguments: [...npm.argumentPrefix, ...command.arguments] }
      : {
          executable: process.execPath,
          arguments: [
            "--experimental-strip-types",
            join(repositoryRoot, "tools", "cli", "src", "bin.ts"),
            ...command.arguments,
          ],
        };
    const result = await runCommand({
      id: command.id,
      executable: invocation.executable,
      arguments: invocation.arguments,
      cwd: repositoryRoot,
      environment: childEnvironment(environment, database, command.liveDatabase),
      captureStdout: command.captureStdout,
      timeoutMs: command.timeoutMs,
    });
    if (!Number.isSafeInteger(result.outputBytes) || result.outputBytes < 0
      || !/^[0-9a-f]{64}$/u.test(result.outputSha256)) {
      throw new Error("The command runner returned invalid bounded-output metadata.");
    }
    let status: GateStatus = result.exitCode === 0 && result.errorCode === null ? "PASS" : "FAIL";
    let failure: CommandEvidence["failure"] = result.errorCode !== null
      ? "LAUNCH_FAILED"
      : result.exitCode === 0 ? "NONE" : "NONZERO_EXIT";
    if (command.id === "certify" && status === "PASS") {
      certification = parseCertification(result.capturedStdout, revision.head);
      if (certification.policyStatus === "FAIL") {
        status = "FAIL";
        failure = "CERTIFICATION_POLICY";
      }
    }
    commandEvidence.push({
      id: command.id,
      command: command.display,
      status,
      exitCode: result.exitCode,
      failure,
      durationMs: Math.max(0, now().getTime() - commandStarted.getTime()),
      output: {
        stored: false,
        sha256: result.outputSha256,
        bytes: result.outputBytes,
      },
    });
  }

  const endingHead = gitText(repositoryRoot, ["rev-parse", "--verify", "HEAD^{commit}"]);
  const endingDirty = gitText(repositoryRoot, ["status", "--porcelain=v1", "--untracked-files=all"]);
  const headUnchanged = endingHead === revision.head;
  const cleanAtEnd = endingDirty === "";
  const automatedStatus: GateStatus = commandEvidence.every((entry) => entry.status === "PASS")
    && headUnchanged && cleanAtEnd ? "PASS" : "FAIL";
  const completedAt = now();
  const machine = system();
  const withoutIntegrity = {
    schema: 1 as const,
    artifactKind: "synex-core-production-beta-evidence" as const,
    generatedAt: completedAt.toISOString(),
    status: automatedStatus,
    releaseReady: false as const,
    releaseDecision: "NOT_ASSERTED_MANUAL_GATES_REQUIRED" as const,
    scope: {
      included: ["synex_core"] as ["synex_core"],
      profile: "single-instance-mariadb" as const,
      outOfScope: OUT_OF_SCOPE.map((entry) => ({ ...entry })),
    },
    revision: {
      head: revision.head,
      branch: revision.branch,
      cleanAtStart: true as const,
      cleanAtEnd,
      headUnchanged,
      core: {
        path: "core/synex_core" as const,
        gitTreeObject: revision.coreTreeObject,
        trackedTreeSha256: revision.coreTrackedTreeSha256,
      },
      packageLockSha256: sha256(packageLock),
    },
    environment: {
      platform: machine.platform,
      release: machine.release,
      architecture: machine.architecture,
      node: machine.node,
      databaseGate: {
        live: true as const,
        variable: "SYNEX_TEST_DATABASE_URL" as const,
        protocol: "mysql:" as const,
        requiredServer: "MariaDB" as const,
        namePattern: "synex_test_[a-z0-9_]+" as const,
        credentialsStored: false as const,
      },
    },
    commands: commandEvidence,
    certification,
    manualGates: MANUAL_GATES.map((name) => ({ name, status: "NOT_RUN" as const })),
  };
  const report: CoreBetaEvidence = {
    ...withoutIntegrity,
    integrity: {
      algorithm: "sha256",
      payloadSha256: sha256(JSON.stringify(withoutIntegrity)),
    },
  };
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (Buffer.byteLength(serialized, "utf8") > MAX_EVIDENCE_BYTES) {
    throw new Error("Bounded evidence limit exceeded; no artifact was written.");
  }
  await mkdir(dirname(output), { recursive: true });
  await rejectSymbolicPath(repositoryRoot, output);
  await writeFile(output, serialized, { encoding: "utf8", flag: "wx" });
  return { report, output: relative(repositoryRoot, output).replaceAll("\\", "/") };
}

async function main(arguments_: string[]): Promise<number> {
  const parsed = parseArguments(arguments_);
  if (parsed.help) {
    process.stdout.write(`${helpText()}\n`);
    return 0;
  }
  const options: CoreBetaEvidenceOptions = { repositoryRoot: parsed.root };
  if (parsed.output !== undefined) options.output = parsed.output;
  const result = await runCoreBetaEvidence(options);
  process.stdout.write(`Core beta automated gate: ${result.report.status}.\nEvidence: ${result.output}\n`);
  process.stdout.write("Release readiness: NOT ASSERTED; all listed manual gates remain NOT_RUN.\n");
  return result.report.status === "PASS" ? 0 : 1;
}

const invokedPath = process.argv[1];
if (invokedPath !== undefined && import.meta.url === pathToFileURL(invokedPath).href) {
  main(process.argv.slice(2)).then(
    (exitCode) => {
      process.exitCode = exitCode;
    },
    (error: unknown) => {
      process.stderr.write(`${error instanceof Error ? error.message : "Core beta evidence gate failed."}\n`);
      process.exitCode = 1;
    },
  );
}
