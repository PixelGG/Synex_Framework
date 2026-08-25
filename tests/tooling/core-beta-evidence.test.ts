import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import test, { type TestContext } from "node:test";

import {
  runCoreBetaEvidence,
  summarizeCommandOutput,
  validateLiveDatabaseEnvironment,
  type GateCommandRequest,
  type GateCommandResult,
} from "../../tools/core-beta-evidence.js";

const DATABASE_URL = "mysql://synex_user:private-test-password@127.0.0.1:3306/synex_test_beta_gate";

function git(repository: string, arguments_: string[]): string {
  const result = spawnSync("git", arguments_, {
    cwd: repository,
    encoding: "utf8",
    timeout: 30_000,
    windowsHide: true,
    shell: false,
  });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  return result.stdout.trim();
}

async function removeFixture(path: string): Promise<void> {
  const temporaryRoot = `${resolve(tmpdir())}${sep}`;
  assert.ok(resolve(path).startsWith(temporaryRoot));
  await rm(path, { recursive: true, force: true });
}

async function createRepositoryFixture(context: TestContext): Promise<string> {
  const repository = await mkdtemp(join(tmpdir(), "synex-core-beta-evidence-"));
  context.after(() => removeFixture(repository));
  await mkdir(join(repository, "core", "synex_core"), { recursive: true });
  await Promise.all([
    writeFile(join(repository, ".gitignore"), ".temp/\nartifacts/\n", "utf8"),
    writeFile(join(repository, "package-lock.json"), "{}\n", "utf8"),
    writeFile(join(repository, "core", "synex_core", "fxmanifest.lua"), "fx_version 'cerulean'\n", "utf8"),
  ]);
  git(repository, ["-c", "init.defaultBranch=main", "init"]);
  git(repository, ["add", "."]);
  git(repository, [
    "-c",
    "user.name=Synex Test",
    "-c",
    "user.email=synex-test@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "test: create core beta evidence fixture",
  ]);
  return repository;
}

function result(stdout: string, exitCode = 0): GateCommandResult {
  return {
    exitCode,
    errorCode: null,
    ...summarizeCommandOutput(stdout, ""),
    capturedStdout: stdout,
  };
}

function certification(head: string, warnings: string[] = [
  "schema-and-manifest-validation",
  "dependency-graph",
  "capability-policy",
]): string {
  return JSON.stringify({
    schema: 1,
    artifactKind: "synex-certification",
    status: "WARN",
    revision: { commit: head, dirty: false },
    target: { resources: [{ name: "synex_core", version: "0.1.0" }] },
    checkHash: "a".repeat(64),
    checks: [
      ...warnings.map((name) => ({
        name,
        status: "WARN",
        detail: name === "schema-and-manifest-validation"
          ? "0 error(s), 1 warning(s)."
          : name === "dependency-graph"
            ? "0 cycle(s), 0 unresolved required declaration(s), 0 incompatible required version(s), 1 optional/runtime version warning(s)."
            : name === "capability-policy"
              ? "0 error(s), 1 warning(s), 0 requested but denied/ungranted capability declaration(s)."
              : "unreviewed warning detail",
      })),
      { name: "repository-test-command", status: "PASS", detail: "Tests passed." },
      {
        name: "nui-closed-state:resources/synex_control",
        status: "PASS",
        detail: "Closed-state verification passed.",
      },
    ],
    validation: {
      diagnostics: warnings.includes("schema-and-manifest-validation")
        ? [{
            file: "core/synex_core/fxmanifest.lua",
            level: "warning",
            message: "Runtime dependency version must be verified against the deployment.",
            rule: "resource-dependency-runtime-unverified",
          }]
        : [],
    },
  });
}

function liveEnvironment(): NodeJS.ProcessEnv {
  return {
    PATH: process.env.PATH,
    SYNEX_TEST_DATABASE_LIVE: "1",
    SYNEX_TEST_DATABASE_URL: DATABASE_URL,
  };
}

test("core beta evidence runs exact gates, keeps credentials out of bounded evidence, and leaves manual gates open", async (context) => {
  const repository = await createRepositoryFixture(context);
  const head = git(repository, ["rev-parse", "HEAD"]);
  const requests: GateCommandRequest[] = [];
  let tick = 0;
  const execution = await runCoreBetaEvidence(
    {
      repositoryRoot: repository,
      output: ".temp/evidence/pass.json",
      environment: liveEnvironment(),
    },
    {
      now: () => new Date(Date.UTC(2026, 7, 24, 12, 0, 0, tick++ * 10)),
      system: () => ({ platform: "linux", release: "test", architecture: "x64", node: "v22.12.0" }),
      runCommand: async (request) => {
        requests.push(request);
        return result(request.id === "certify" ? certification(head) : `${request.id} completed`);
      },
    },
  );

  assert.equal(execution.report.status, "PASS");
  assert.equal(execution.report.releaseReady, false);
  assert.equal(execution.report.releaseDecision, "NOT_ASSERTED_MANUAL_GATES_REQUIRED");
  assert.equal(execution.report.certification.revisionMatches, true);
  assert.equal(execution.report.certification.coreIncluded, true);
  assert.deepEqual(execution.report.scope.included, ["synex_core"]);
  assert.equal(execution.report.scope.profile, "single-instance-mariadb");
  assert.deepEqual(execution.report.scope.outOfScope.map((entry) => entry.item), [
    "multi-instance-kick-old",
    "mysql-server",
    "downstream-resources",
  ]);
  assert.equal(execution.report.manualGates.every((gate) => gate.status === "NOT_RUN"), true);
  assert.deepEqual(execution.report.manualGates.map((gate) => gate.name), [
    "exact-revision-fxserver-startup",
    "fresh-install",
    "prepared-core-restart-and-recovery",
    "unprepared-core-restart-and-recovery",
    "full-fxserver-process-crash-and-recovery",
    "database-outage-and-recovery",
    "client-join-disconnect-reconnect",
  ]);
  assert.equal(execution.report.manualGates.some((gate) => gate.name.includes("multi-instance")), false);
  assert.equal(execution.report.environment.databaseGate.requiredServer, "MariaDB");
  assert.deepEqual(requests.map((request) => request.id), [
    "check",
    "test-live-database",
    "security",
    "certify",
    "audit",
  ]);
  const npmCli = requests[0]?.arguments[0];
  assert.equal(requests.every((request) => request.executable === process.execPath), true);
  assert.match(npmCli ?? "", /npm-cli\.(?:c?js)$/iu);
  assert.equal(requests.filter((request) => request.id !== "certify")
    .every((request) => request.arguments[0] === npmCli), true);
  assert.deepEqual(requests[0]?.arguments.slice(1), ["run", "check"]);
  assert.deepEqual(requests[1]?.arguments.slice(1), ["test"]);
  assert.deepEqual(requests[2]?.arguments.slice(1), ["run", "security"]);
  assert.equal(requests[3]?.arguments[0], "--experimental-strip-types");
  assert.match(requests[3]?.arguments[1] ?? "", /tools[\\/]cli[\\/]src[\\/]bin\.ts$/u);
  assert.deepEqual(requests[3]?.arguments.slice(2), ["certify", "repository", "--json"]);
  assert.deepEqual(requests[4]?.arguments.slice(1), ["audit", "--audit-level=high"]);
  for (const request of requests) {
    const shouldReceiveLiveDatabase = request.id === "test-live-database" || request.id === "certify";
    assert.equal(request.environment.SYNEX_TEST_DATABASE_LIVE, shouldReceiveLiveDatabase ? "1" : undefined);
    assert.equal(request.environment.SYNEX_TEST_DATABASE_URL, shouldReceiveLiveDatabase ? DATABASE_URL : undefined);
  }

  const artifact = await readFile(join(repository, execution.output), "utf8");
  assert.equal(artifact.includes("private-test-password"), false);
  assert.equal(artifact.includes(DATABASE_URL), false);
  assert.equal(artifact.includes("completed"), false);
  assert.equal(execution.report.commands.every((command) => command.output.stored === false), true);
  assert.match(execution.report.revision.head, /^[0-9a-f]{40,64}$/u);
  assert.match(execution.report.revision.core.gitTreeObject, /^[0-9a-f]{40,64}$/u);
  assert.match(execution.report.revision.core.trackedTreeSha256, /^[0-9a-f]{64}$/u);
  assert.match(execution.report.integrity.payloadSha256, /^[0-9a-f]{64}$/u);
  assert.equal(git(repository, ["status", "--porcelain=v1", "--untracked-files=all"]), "");
});

test("core beta evidence fails closed for unknown certification warnings and nonzero commands", async (context) => {
  const repository = await createRepositoryFixture(context);
  const head = git(repository, ["rev-parse", "HEAD"]);
  const execution = await runCoreBetaEvidence(
    {
      repositoryRoot: repository,
      output: "artifacts/core-beta/fail.json",
      environment: liveEnvironment(),
    },
    {
      runCommand: async (request) => {
        if (request.id === "certify") return result(certification(head, ["new-unreviewed-warning"]));
        if (request.id === "security") return result("security failed", 2);
        return result(`${request.id} completed`);
      },
    },
  );

  assert.equal(execution.report.status, "FAIL");
  assert.deepEqual(execution.report.certification.unknownWarnings, ["new-unreviewed-warning"]);
  assert.equal(execution.report.commands.find((command) => command.id === "certify")?.failure, "CERTIFICATION_POLICY");
  assert.equal(execution.report.commands.find((command) => command.id === "security")?.failure, "NONZERO_EXIT");

  const badCapabilityDetail = certification(head, ["capability-policy"]).replace(
    "0 error(s), 1 warning(s), 0 requested but denied/ungranted capability declaration(s).",
    "1 error(s), 1 warning(s), 1 requested but denied/ungranted capability declaration(s).",
  );
  const detailExecution = await runCoreBetaEvidence(
    {
      repositoryRoot: repository,
      output: "artifacts/core-beta/fail-detail.json",
      environment: liveEnvironment(),
    },
    {
      runCommand: async (request) => result(request.id === "certify" ? badCapabilityDetail : "completed"),
    },
  );
  assert.equal(detailExecution.report.status, "FAIL");
  assert.deepEqual(detailExecution.report.certification.unknownWarnings, []);
  assert.deepEqual(detailExecution.report.certification.warningPolicyViolations, ["capability-policy"]);
});

test("core beta evidence refuses dirty revisions and output paths outside ignored evidence roots", async (context) => {
  const repository = await createRepositoryFixture(context);
  let calls = 0;
  const runner = async (): Promise<GateCommandResult> => {
    calls += 1;
    return result("not expected");
  };

  await assert.rejects(
    runCoreBetaEvidence({
      repositoryRoot: repository,
      output: "docs/evidence.json",
      environment: liveEnvironment(),
    }, { runCommand: runner }),
    /below ignored \.temp\/ or artifacts\//u,
  );
  assert.equal(calls, 0);

  await writeFile(join(repository, "dirty.txt"), "dirty\n", "utf8");
  await assert.rejects(
    runCoreBetaEvidence({
      repositoryRoot: repository,
      output: ".temp/evidence/dirty.json",
      environment: liveEnvironment(),
    }, { runCommand: runner }),
    /clean Git revision/u,
  );
  assert.equal(calls, 0);
  await assert.rejects(access(join(repository, ".temp", "evidence", "dirty.json")), /ENOENT/u);
});

test("live database validation is fail-closed and never repeats credentials", () => {
  assert.throws(
    () => validateLiveDatabaseEnvironment({
      SYNEX_TEST_DATABASE_LIVE: "1",
      SYNEX_TEST_DATABASE_URL: "mysql://admin:do-not-repeat@example.invalid/production",
    }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.equal(error.message.includes("do-not-repeat"), false);
      assert.equal(error.message.includes("production"), false);
      assert.match(error.message, /synex_test_/u);
      return true;
    },
  );
  assert.throws(
    () => validateLiveDatabaseEnvironment({
      SYNEX_TEST_DATABASE_LIVE: "0",
      SYNEX_TEST_DATABASE_URL: DATABASE_URL,
    }),
    /SYNEX_TEST_DATABASE_LIVE=1/u,
  );
  assert.doesNotThrow(() => validateLiveDatabaseEnvironment(liveEnvironment()));
});
