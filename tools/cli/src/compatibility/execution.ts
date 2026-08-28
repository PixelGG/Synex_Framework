import { spawnSync } from "node:child_process";
import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { Ajv2020, type AnySchema } from "ajv/dist/2020.js";

import { CliError } from "../errors.ts";
import { isRecord, sha256 } from "../filesystem.ts";
import type {
  CompatibilityCatalog,
  CompatibilityProfile,
  CompatibilityProvider,
} from "./types.ts";

const EXECUTION_SCHEMA = join(
  "libraries", "synex_bridge", "compatibility", "schemas", "certification-execution.schema.json",
);
const MAX_EVIDENCE_BYTES = 1024 * 1024;
const MAX_TEST_BYTES = 4 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const FLOW_TIMEOUT_MS = 120_000;

export type CompatibilityFlowStatus = "PASS" | "FAIL" | "SKIP" | "UNKNOWN";

export interface CompatibilityFlowExecution {
  id: string;
  testPath: string;
  testSha256: string;
  status: CompatibilityFlowStatus;
  exitCode: number | null;
  signal: string | null;
  durationMs: number;
  assertions: {
    tests: number;
    passed: number;
    failed: number;
    skipped: number;
    cancelled: number;
    todo: number;
  };
  outputBytes: number;
  outputSha256: string;
  message: string;
}

export interface CompatibilityExecutionEvidence {
  schema: 1;
  artifactKind: "synex-compatibility-certification-execution";
  status: "PASS" | "FAIL" | "UNKNOWN";
  complete: boolean;
  profileId: string;
  profileVersion: string;
  provider: CompatibilityProvider;
  providerVersion: string;
  script: { name: string; version: string };
  runner: { kind: "repository-node-test"; nodeVersion: string; timeoutMs: number };
  flows: CompatibilityFlowExecution[];
  summary: { total: number; passed: number; failed: number; skipped: number; unknown: number };
  disclaimer: string;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function expectedExecutionOutput(profileId: string): string {
  const file = profileId.replaceAll(":", "_");
  return `artifacts/compatibility/${file}.execution.json`;
}

export function compatibilityExecutionOutputPath(profileId: string): string {
  return expectedExecutionOutput(profileId);
}

async function checkedRelativePath(
  repositoryRoot: string,
  requested: string,
  maximumBytes: number,
): Promise<{ absolute: string; relative: string; bytes: number } | null> {
  if (isAbsolute(requested)) return null;
  const absolute = resolve(repositoryRoot, requested);
  const rel = relative(resolve(repositoryRoot), absolute);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
  let current = resolve(repositoryRoot);
  try {
    for (const segment of rel.split(sep).filter(Boolean)) {
      current = join(current, segment);
      if ((await lstat(current)).isSymbolicLink()) return null;
    }
    const metadata = await lstat(absolute);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > maximumBytes) return null;
    return { absolute, relative: rel.split(sep).join("/"), bytes: metadata.size };
  } catch {
    return null;
  }
}

function isTracked(repositoryRoot: string, requested: string): boolean {
  const result = spawnSync("git", ["ls-files", "--error-unmatch", "--", requested], {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: "ignore",
    timeout: 5_000,
    windowsHide: true,
  });
  return result.status === 0 && result.error === undefined;
}

function profileTests(profile: CompatibilityProfile): string[] {
  const evidence = isRecord(profile.raw.evidence) ? profile.raw.evidence : null;
  if (!evidence || !Array.isArray(evidence.tests)) return [];
  return evidence.tests.filter((entry): entry is string => typeof entry === "string")
    .sort(compareText);
}

function parseTapSummary(output: string): CompatibilityFlowExecution["assertions"] {
  const values = { tests: 0, passed: 0, failed: 0, skipped: 0, cancelled: 0, todo: 0 };
  const keys = new Map([
    ["tests", "tests"], ["pass", "passed"], ["fail", "failed"],
    ["skipped", "skipped"], ["cancelled", "cancelled"], ["todo", "todo"],
  ] as const);
  for (const match of output.matchAll(/^# (tests|pass|fail|skipped|cancelled|todo) (\d+)\s*$/gmu)) {
    const target = keys.get(match[1] as "tests" | "pass" | "fail" | "skipped" | "cancelled" | "todo");
    const count = Number(match[2]);
    if (target && Number.isSafeInteger(count) && count >= 0) values[target] = count;
  }
  return values;
}

async function executableTestPath(repositoryRoot: string, testPath: string): Promise<{
  source: { absolute: string; relative: string; bytes: number };
  executable: string | null;
  unavailableReason: string | null;
}> {
  if (!/^tests\/compatibility\/[A-Za-z0-9_./-]+\.test\.(?:ts|mjs)$/u.test(testPath)
    || testPath.includes("//") || testPath.split("/").some((part) => part === "." || part === "..")) {
    throw new CliError("Certification flow tests must be bounded tests/compatibility/*.test.ts or *.test.mjs paths.", 2);
  }
  const source = await checkedRelativePath(repositoryRoot, testPath, MAX_TEST_BYTES);
  if (!source || !isTracked(repositoryRoot, source.relative)) {
    throw new CliError(`Certification flow test is missing, unsafe, unbounded, or untracked: ${testPath}.`, 2);
  }
  if (testPath.endsWith(".mjs")) return { source, executable: source.absolute, unavailableReason: null };
  const compiledPath = `.build/${testPath.slice(0, -3)}.js`;
  const compiled = await checkedRelativePath(repositoryRoot, compiledPath, MAX_TEST_BYTES);
  return compiled
    ? { source, executable: compiled.absolute, unavailableReason: null }
    : {
      source,
      executable: null,
      unavailableReason: `Compiled test unavailable; run npm run build before executing ${testPath}.`,
    };
}

async function executeFlow(
  repositoryRoot: string,
  testPath: string,
): Promise<CompatibilityFlowExecution> {
  const resolved = await executableTestPath(repositoryRoot, testPath);
  const testSha256 = sha256(await readFile(resolved.source.absolute, "utf8"));
  if (!resolved.executable) return {
    id: testPath,
    testPath,
    testSha256,
    status: "UNKNOWN",
    exitCode: null,
    signal: null,
    durationMs: 0,
    assertions: { tests: 0, passed: 0, failed: 0, skipped: 0, cancelled: 0, todo: 0 },
    outputBytes: 0,
    outputSha256: sha256(""),
    message: resolved.unavailableReason ?? "The repository-owned test runner is unavailable.",
  };

  const started = process.hrtime.bigint();
  const childEnvironment = { ...process.env };
  delete childEnvironment.NODE_TEST_CONTEXT;
  const child = spawnSync(process.execPath, [
    "--test",
    "--test-reporter=tap",
    "--test-reporter-destination=stdout",
    resolved.executable,
  ], {
    cwd: repositoryRoot,
    env: childEnvironment,
    encoding: "utf8",
    maxBuffer: MAX_OUTPUT_BYTES,
    timeout: FLOW_TIMEOUT_MS,
    windowsHide: true,
  });
  const durationMs = Math.min(
    Number((process.hrtime.bigint() - started) / 1_000_000n),
    Number.MAX_SAFE_INTEGER,
  );
  const stdout = typeof child.stdout === "string" ? child.stdout : "";
  const stderr = typeof child.stderr === "string" ? child.stderr : "";
  const output = `${stdout}\n${stderr}`;
  const assertions = parseTapSummary(stdout);
  let status: CompatibilityFlowStatus;
  let message: string;
  if (child.error) {
    const timedOut = isRecord(child.error) && child.error.code === "ETIMEDOUT";
    status = timedOut ? "FAIL" : "UNKNOWN";
    message = timedOut
      ? `Repository-owned flow exceeded the ${FLOW_TIMEOUT_MS} ms limit.`
      : "The fixed Node test runner could not be executed.";
  } else if (child.status !== 0 || assertions.failed > 0 || assertions.cancelled > 0) {
    status = "FAIL";
    message = `Repository-owned flow failed with exit code ${String(child.status)}.`;
  } else if (assertions.tests === 0) {
    status = "UNKNOWN";
    message = "The test runner reported no assertions.";
  } else if (assertions.skipped > 0 || assertions.todo > 0) {
    status = assertions.passed === 0 ? "SKIP" : "UNKNOWN";
    message = assertions.passed === 0
      ? "The flow was skipped because its test environment was unavailable."
      : "The flow was only partially executed because assertions were skipped or pending.";
  } else {
    status = "PASS";
    message = "The repository-owned flow completed without failed or skipped assertions.";
  }
  return {
    id: testPath,
    testPath,
    testSha256,
    status,
    exitCode: child.status,
    signal: child.signal,
    durationMs,
    assertions,
    outputBytes: Math.min(Buffer.byteLength(output, "utf8"), MAX_OUTPUT_BYTES),
    outputSha256: sha256(output),
    message,
  };
}

export async function executeCompatibilityProfile(
  repositoryRoot: string,
  catalog: CompatibilityCatalog,
  profileId: string,
): Promise<CompatibilityExecutionEvidence> {
  const profile = catalog.profiles.find((entry) => entry.id === profileId);
  if (!profile || !profile.provider || !profile.providerVersion || !profile.testedVersion) {
    throw new CliError("Compatibility execution requires an exact version-bound profile.", 2);
  }
  const tests = profileTests(profile);
  if (tests.length === 0 || new Set(tests).size !== tests.length) {
    throw new CliError("Compatibility execution requires a non-empty unique profile evidence.tests set.", 2);
  }
  const flows: CompatibilityFlowExecution[] = [];
  for (const testPath of tests) flows.push(await executeFlow(repositoryRoot, testPath));
  const summary = {
    total: flows.length,
    passed: flows.filter((entry) => entry.status === "PASS").length,
    failed: flows.filter((entry) => entry.status === "FAIL").length,
    skipped: flows.filter((entry) => entry.status === "SKIP").length,
    unknown: flows.filter((entry) => entry.status === "UNKNOWN").length,
  };
  const status = summary.failed > 0 ? "FAIL"
    : summary.passed === summary.total ? "PASS"
      : "UNKNOWN";
  return {
    schema: 1,
    artifactKind: "synex-compatibility-certification-execution",
    status,
    complete: status === "PASS",
    profileId: profile.id,
    profileVersion: profile.version,
    provider: profile.provider,
    providerVersion: profile.providerVersion,
    script: { name: profile.script, version: profile.testedVersion },
    runner: { kind: "repository-node-test", nodeVersion: process.version, timeoutMs: FLOW_TIMEOUT_MS },
    flows,
    summary,
    disclaimer: "This bounded harness executes only tracked repository-owned Node test files named by the exact profile. SKIP and unavailable build/runtime conditions remain UNKNOWN and cannot certify a profile. It does not launch or inspect FXServer.",
  };
}

async function readBoundedJson(repositoryRoot: string, path: string, label: string): Promise<unknown> {
  const checked = await checkedRelativePath(
    repositoryRoot,
    relative(resolve(repositoryRoot), resolve(path)),
    MAX_EVIDENCE_BYTES,
  );
  if (!checked) throw new CliError(`${label} must be a bounded non-symlink file inside the repository.`, 2);
  try {
    return JSON.parse(await readFile(checked.absolute, "utf8")) as unknown;
  } catch {
    throw new CliError(`${label} is not valid JSON.`, 2);
  }
}

export async function loadCompatibilityExecutionEvidence(
  repositoryRoot: string,
  evidencePath: string,
): Promise<CompatibilityExecutionEvidence> {
  const [schema, evidence] = await Promise.all([
    readBoundedJson(repositoryRoot, resolve(repositoryRoot, EXECUTION_SCHEMA), "Execution-evidence schema"),
    readBoundedJson(repositoryRoot, evidencePath, "Execution evidence"),
  ]);
  if (!isRecord(schema)) throw new CliError("Execution-evidence schema is invalid.", 2);
  let validator;
  try {
    validator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false })
      .compile(schema as AnySchema);
  } catch {
    throw new CliError("Execution-evidence schema could not be compiled.", 2);
  }
  if (!validator(evidence)) {
    throw new CliError(
      `Execution evidence does not satisfy its closed schema (${validator.errors?.length ?? 0} error(s)).`,
      2,
    );
  }
  return evidence as CompatibilityExecutionEvidence;
}

export function executionEvidenceMatchesProfile(
  profile: CompatibilityProfile,
  evidence: CompatibilityExecutionEvidence | undefined,
  expectedTests: string[],
): boolean {
  if (!evidence || evidence.status !== "PASS" || !evidence.complete
    || evidence.profileId !== profile.id || evidence.profileVersion !== profile.version
    || evidence.provider !== profile.provider || evidence.providerVersion !== profile.providerVersion
    || evidence.script.name !== profile.script || evidence.script.version !== profile.testedVersion
    || evidence.runner.kind !== "repository-node-test"
    || evidence.runner.nodeVersion !== process.version || evidence.runner.timeoutMs !== FLOW_TIMEOUT_MS
    || evidence.flows.length !== expectedTests.length) return false;
  const flows = [...evidence.flows].sort((left, right) => compareText(left.testPath, right.testPath));
  const passed = flows.filter((flow) => flow.status === "PASS").length;
  return evidence.summary.total === flows.length && evidence.summary.passed === passed
    && evidence.summary.failed === 0 && evidence.summary.skipped === 0
    && evidence.summary.unknown === 0
    && flows.every((flow, index) => flow.testPath === expectedTests[index]
      && flow.id === flow.testPath && flow.status === "PASS");
}
