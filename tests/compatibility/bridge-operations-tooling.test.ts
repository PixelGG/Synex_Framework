import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  certifyCompatibilityProfile,
  checkCompatibilityReviewLock,
  doctorCompatibility,
  executeCompatibilityProfile,
  loadCompatibilityCatalog,
  loadCompatibilityRuntimeEvidence,
  observeCompatibility,
} from "../../tools/cli/src/compatibility.js";
import { runCli } from "../../tools/cli/src/dispatcher.js";
import { canonicalJson, sha256 } from "../../tools/cli/src/filesystem.js";

const repositoryRoot = process.cwd();
const compatibilitySource = join(repositoryRoot, "libraries", "synex_bridge", "compatibility");

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function createFixtureRoot(): Promise<{
  root: string;
  evidencePath: string;
  runtimeEvidence: Record<string, unknown>;
}> {
  const root = await mkdtemp(join(tmpdir(), "synex-bridge-operations-"));
  await cp(compatibilitySource, join(root, "libraries", "synex_bridge", "compatibility"), {
    recursive: true,
  });
  await mkdir(join(root, "schemas"), { recursive: true });
  await writeFile(join(root, "package.json"), "{}\n", "utf8");
  await writeFile(join(root, "schemas", "resource.schema.json"), "{}\n", "utf8");
  await mkdir(join(root, "fixture_resource"), { recursive: true });
  await writeFile(
    join(root, "fixture_resource", "server.lua"),
    "local QBCore = exports['qb-core']:GetCoreObject()\nQBCore.Functions.GetPlayer(source)\n",
    "utf8",
  );
  const testPath = "tests/compatibility/certification-fixture.test.mjs";
  const testContents = [
    "import assert from 'node:assert/strict';",
    "import test from 'node:test';",
    "test('repository-owned certification flow', () => assert.equal(2 + 2, 4));",
    "",
  ].join("\n");
  await mkdir(join(root, "tests", "compatibility"), { recursive: true });
  await writeFile(join(root, testPath), testContents, "utf8");

  const qbCatalogPath = join(root, "libraries", "synex_bridge", "compatibility", "surfaces", "qb.json");
  const qbCatalog = JSON.parse(await readFile(qbCatalogPath, "utf8")) as {
    providerVersion: string;
    targetFrameworkApiRange: string | null;
    upstream: { evidenceUrls: string[] };
    surfaces: Array<{ name: string; status: string; tests: string[] }>;
  };
  const surface = qbCatalog.surfaces[0];
  assert.ok(surface);
  qbCatalog.targetFrameworkApiRange = "^7.0.0";
  surface.tests = [testPath];
  await writeJson(qbCatalogPath, qbCatalog);
  const mappingCatalogPath = join(
    root, "libraries", "synex_bridge", "compatibility", "mappings.json",
  );
  const mappingCatalog = JSON.parse(await readFile(mappingCatalogPath, "utf8")) as {
    groups: Array<Record<string, unknown>>;
  };
  mappingCatalog.groups.push({
    id: "qb.fixture_group",
    version: "1.0.0",
    provider: "qb",
    legacyType: "job",
    legacyName: "fixture",
    nativeGroupKey: "fixture",
    nativeGroupType: "job",
    grades: [{ legacyGrade: 0, gradeKey: "member" }],
    bossRoles: [],
    dutySupported: true,
    dutyState: "on_duty",
    status: "PARTIAL",
  });
  await writeJson(mappingCatalogPath, mappingCatalog);
  const reviewLockPath = join(
    root, "libraries", "synex_bridge", "compatibility", "review-lock.json",
  );
  const reviewLock = JSON.parse(await readFile(reviewLockPath, "utf8")) as {
    mappingCatalog: { catalogSha256: string };
    consumerCatalog: { catalogSha256: string };
    moneyPolicyCatalog: { catalogSha256: string };
    entries: Array<{
      provider: string;
      providerVersion: string;
      targetFrameworkApiRange: string | null;
      catalogSha256: string;
    }>;
  };
  const qbReview = reviewLock.entries.find((entry) => entry.provider === "qb");
  assert.ok(qbReview);
  qbReview.providerVersion = qbCatalog.providerVersion;
  qbReview.targetFrameworkApiRange = qbCatalog.targetFrameworkApiRange;
  qbReview.catalogSha256 = sha256(await readFile(qbCatalogPath, "utf8"));
  reviewLock.mappingCatalog.catalogSha256 = sha256(
    await readFile(mappingCatalogPath, "utf8"),
  );
  await writeJson(reviewLockPath, reviewLock);
  await writeJson(join(root, "libraries", "synex_bridge", "compatibility", "profiles.json"), {
    $schema: "./schemas/profiles.schema.json",
    schema: 1,
    kind: "synex-compatibility-profiles",
    profiles: [{
      id: "qb.fixture",
      version: "1.0.0",
      script: { name: "fixture-script", testedVersion: "1.2.3" },
      provider: "qb",
      mode: "compat",
      status: "CERTIFIED",
      failurePolicy: "fail_start",
      providerVersion: "0.1.0",
      targetFrameworkApiRange: "^7.0.0",
      certificationArtifact: "compatibility/certifications/qb.fixture.json",
      requiredSurfaces: [{ name: surface.name, acceptedStatuses: [surface.status] }],
      requiredAdapters: [],
      evidence: { tests: [testPath], sourceUrls: qbCatalog.upstream.evidenceUrls },
    }],
  });
  await writeJson(join(root, "libraries", "synex_bridge", "compatibility", "consumers.json"), {
    $schema: "./schemas/consumers.schema.json",
    schema: 1,
    kind: "synex-compatibility-consumers",
    defaultMode: "strict",
    consumers: [{
      resource: "fixture_consumer",
      provider: "qb",
      profileId: "qb.fixture",
      mode: "compat",
      enabled: true,
      failurePolicy: "fail_start",
    }],
  });
  await writeJson(join(root, "libraries", "synex_bridge", "compatibility", "money-policies.json"), {
    $schema: "./schemas/money-policies.schema.json",
    schema: 1,
    kind: "synex-compatibility-money-policies",
    policies: [{
      id: "qb.fixture.cash.add",
      version: "1.0.0",
      provider: "qb",
      consumer: "fixture_consumer",
      moneyAlias: "cash",
      direction: "add",
      legacyReason: "fixture",
      action: "transfer",
      accountId: "11111111-1111-4111-8111-111111111111",
      nativeReasonCode: "compat.qb.fixture_consumer.fixture",
      status: "ACTIVE",
    }],
  });
  reviewLock.consumerCatalog.catalogSha256 = sha256(await readFile(
    join(root, "libraries", "synex_bridge", "compatibility", "consumers.json"), "utf8",
  ));
  reviewLock.moneyPolicyCatalog.catalogSha256 = sha256(await readFile(
    join(root, "libraries", "synex_bridge", "compatibility", "money-policies.json"), "utf8",
  ));
  await writeJson(reviewLockPath, reviewLock);
  const runtimeEvidence = {
    schema: 1,
    kind: "synex-compatibility-runtime-evidence",
    source: "operator",
    complete: true,
    expectedProviders: ["qb"],
    providers: [{
      provider: "qb",
      resource: "synex_bridge_qb",
      version: "0.1.0",
      state: "started",
      health: {
        status: "READY", reasons: [], callbackPending: 0, callbackCapacity: 512,
        callbackRegistrations: 0, callbackRegistrationCapacity: 256,
      },
      capabilities: [{ name: "synex.compat.qb.read", required: true, granted: true }],
      conflicts: [],
      telemetry: {
        truncated: false,
        entries: [{
          consumer: "fixture_consumer",
          operation: "player.read",
          calls: 2,
          outcomes: {
            success: 2, denied: 0, unsupported: 0, error: 0,
            timeout: 0, rateLimited: 0, deprecated: 2,
          },
          latency: { samples: 2, totalMs: 4, maximumMs: 3 },
        }],
      },
    }],
    consumers: [{ consumer: "fixture_consumer", provider: "qb", active: true }],
    mappings: { ambiguous: 0, missing: 0, forbidden: 0 },
    certifications: [{
      profileId: "qb.fixture",
      profileVersion: "1.0.0",
      provider: "qb",
      providerVersion: "0.1.0",
      targetFrameworkApiRange: "^7.0.0",
      script: { name: "fixture-script", version: "1.2.3" },
      tests: [{ path: testPath, sha256: sha256(testContents), status: "PASS" }],
    }],
  };
  const evidencePath = join(root, "runtime-evidence.json");
  await writeJson(evidencePath, runtimeEvidence);
  const initialized = spawnSync("git", ["init", "--quiet"], { cwd: root, windowsHide: true });
  assert.equal(initialized.status, 0);
  const staged = spawnSync("git", ["add", "."], { cwd: root, windowsHide: true });
  assert.equal(staged.status, 0);
  return { root, evidencePath, runtimeEvidence };
}

async function configureUpstreamFixture(root: string): Promise<Map<string, string>> {
  const bodies = new Map<string, string>();
  const lockPath = join(root, "libraries", "synex_bridge", "compatibility", "review-lock.json");
  const lock = JSON.parse(await readFile(lockPath, "utf8")) as {
    entries: Array<{
      provider: string;
      catalogSha256: string;
      upstream: { repository: string; branch: "main"; revision: string; pinSha256: string };
    }>;
  };
  for (const provider of ["qb", "qbx", "esx"] as const) {
    const catalogPath = join(
      root, "libraries", "synex_bridge", "compatibility", "surfaces", `${provider}.json`,
    );
    const catalog = JSON.parse(await readFile(catalogPath, "utf8")) as {
      upstream: {
        repository: string;
        branch: "main";
        revision: string;
        sources: Array<{ id: string; path: string; bytes: number; sha256: string }>;
      };
    };
    const body = `fixture-${provider}-upstream\n`;
    catalog.upstream.revision = ({ qb: "a", qbx: "b", esx: "c" } as const)[provider].repeat(40);
    catalog.upstream.sources = [{
      id: `${provider}.fixture.source`, path: "fixture/source.lua",
      bytes: Buffer.byteLength(body, "utf8"), sha256: sha256(body),
    }];
    await writeJson(catalogPath, catalog);
    const entry = lock.entries.find((candidate) => candidate.provider === provider);
    assert.ok(entry);
    entry.catalogSha256 = sha256(await readFile(catalogPath, "utf8"));
    entry.upstream.repository = catalog.upstream.repository;
    entry.upstream.branch = catalog.upstream.branch;
    entry.upstream.revision = catalog.upstream.revision;
    entry.upstream.pinSha256 = sha256(canonicalJson({
      repository: catalog.upstream.repository,
      branch: catalog.upstream.branch,
      revision: catalog.upstream.revision,
      sources: catalog.upstream.sources,
    }));
    const repositoryPath = new URL(catalog.upstream.repository).pathname.replace(/^\//u, "");
    bodies.set(
      `https://raw.githubusercontent.com/${repositoryPath}/main/fixture/source.lua`, body,
    );
  }
  await writeJson(lockPath, lock);
  return bodies;
}

test("compatibility observe and doctor separate static facts from bounded operator evidence", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const catalog = await loadCompatibilityCatalog(fixture.root);
  assert.equal(catalog.diagnostics.length, 0, JSON.stringify(catalog.diagnostics));
  assert.equal(catalog.moneyPolicies.length, 1);
  assert.equal(catalog.moneyPolicies[0]?.action, "transfer");
  const evidence = await loadCompatibilityRuntimeEvidence(fixture.root, fixture.evidencePath);
  const observation = await observeCompatibility(
    fixture.root, join(fixture.root, "fixture_resource"), catalog, evidence,
  );
  assert.equal(observation.static.artifactKind, "synex-compatibility-scan");
  assert.equal(observation.runtime?.source, "operator");
  assert.equal(observation.runtime?.telemetryCalls, 2);
  assert.notEqual(observation.status, "CERTIFIED");
  assert.match(observation.disclaimer, /does not connect to FXServer/u);

  const withoutRuntime = await observeCompatibility(
    fixture.root, join(fixture.root, "fixture_resource"), catalog,
  );
  assert.equal(withoutRuntime.runtime, null);
  assert.equal(withoutRuntime.status, "UNKNOWN");
  const doctor = await doctorCompatibility(fixture.root, catalog);
  assert.equal(doctor.checked.runtime.provided, false);
  assert.equal(doctor.findings.some((entry) => entry.code === "RUNTIME_EVIDENCE_UNAVAILABLE"), true);
});

test("compatibility certification is deterministic and fails closed on any exact-evidence drift", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const catalog = await loadCompatibilityCatalog(fixture.root);
  const evidence = await loadCompatibilityRuntimeEvidence(fixture.root, fixture.evidencePath);
  const unexecuted = await certifyCompatibilityProfile(fixture.root, catalog, "qb.fixture", evidence);
  assert.equal(unexecuted.certified, false);
  assert.equal(unexecuted.checks.some((entry) =>
    entry.id === "tests.exact-set" && entry.status === "FAIL"), true);
  const execution = await executeCompatibilityProfile(fixture.root, catalog, "qb.fixture");
  assert.equal(execution.status, "PASS", JSON.stringify(execution));
  assert.equal(execution.flows[0]?.status, "PASS");
  assert.deepEqual(execution.flows[0]?.assertions, {
    tests: 1,
    passed: 1,
    failed: 0,
    skipped: 0,
    cancelled: 0,
    todo: 0,
  });
  const first = await certifyCompatibilityProfile(fixture.root, catalog, "qb.fixture", evidence, execution);
  const second = await certifyCompatibilityProfile(fixture.root, catalog, "qb.fixture", evidence, execution);
  assert.equal(first.status, "CERTIFIED");
  assert.equal(first.certified, true);
  assert.ok(first.certificate?.fingerprint);
  assert.equal(first.certificate?.providerVersion, "0.1.0");
  assert.equal(first.certificate?.targetFrameworkApiRange, "^7.0.0");
  assert.deepEqual(first.certificate?.tests.map((entry) => ({
    status: entry.status, tracked: entry.tracked,
  })), [{ status: "PASS", tracked: true }]);
  assert.equal(first.certificate?.bindings.schemas.length, 8);
  assert.equal(first.certificate?.bindings.profileCatalog.tracked, true);
  assert.equal(first.certificate?.bindings.consumerCatalog.tracked, true);
  assert.equal(first.certificate?.bindings.moneyPolicyCatalog.tracked, true);
  assert.equal(first.certificate?.fingerprint, second.certificate?.fingerprint);

  const tamperedExecution = structuredClone(execution);
  tamperedExecution.flows[0]!.testSha256 = "0".repeat(64);
  const executionRejected = await certifyCompatibilityProfile(
    fixture.root, catalog, "qb.fixture", evidence, tamperedExecution,
  );
  assert.equal(executionRejected.certified, false);
  assert.equal(executionRejected.checks.some((entry) =>
    entry.id === `test:${tamperedExecution.flows[0]!.testPath}` && entry.status === "FAIL"), true);

  const drifted = structuredClone(evidence);
  drifted.certifications[0]!.targetFrameworkApiRange = "^8.0.0";
  const rejected = await certifyCompatibilityProfile(fixture.root, catalog, "qb.fixture", drifted, execution);
  assert.equal(rejected.certified, false);
  assert.equal(rejected.status, "UNKNOWN");
  assert.equal(rejected.certificate, null);
  assert.equal(rejected.checks.some((entry) =>
    entry.id === "target-framework-api.range-exact" && entry.status === "FAIL"), true);
});

test("compatibility execution keeps skipped repository flows unknown", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  await writeFile(join(
    fixture.root, "tests", "compatibility", "certification-fixture.test.mjs",
  ), [
    "import test from 'node:test';",
    "test('environment-bound flow', { skip: 'fixture dependency unavailable' }, () => {});",
    "",
  ].join("\n"), "utf8");
  const catalog = await loadCompatibilityCatalog(fixture.root);
  const execution = await executeCompatibilityProfile(fixture.root, catalog, "qb.fixture");
  assert.equal(execution.status, "UNKNOWN");
  assert.equal(execution.complete, false);
  assert.equal(execution.flows[0]?.status, "SKIP");
  assert.deepEqual(execution.flows[0]?.assertions, {
    tests: 1,
    passed: 0,
    failed: 0,
    skipped: 1,
    cancelled: 0,
    todo: 0,
  });
});

test("runtime schema rejects unknown data and the offline review lock reports upstream as unknown", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const invalid = { ...fixture.runtimeEvidence, unexpected: true };
  const invalidPath = join(fixture.root, "runtime-invalid.json");
  await writeJson(invalidPath, invalid);
  await assert.rejects(
    loadCompatibilityRuntimeEvidence(fixture.root, invalidPath),
    /does not satisfy its closed schema/u,
  );

  const accepted = await checkCompatibilityReviewLock(fixture.root);
  assert.equal(accepted.status, "PASS");
  assert.equal(accepted.networkAccess, false);
  assert.equal(accepted.upstreamStatus, "UNKNOWN");
  assert.equal(accepted.mappingCatalog.id, "central.compatibility-mappings");
  assert.equal(accepted.mappingCatalog.hashMatches, true);
  assert.equal(accepted.consumerCatalog.id, "central.compatibility-consumers");
  assert.equal(accepted.consumerCatalog.hashMatches, true);
  assert.equal(accepted.moneyPolicyCatalog.id, "central.money-policies");
  assert.equal(accepted.moneyPolicyCatalog.hashMatches, true);
  assert.match(accepted.disclaimer, /upstream API drift therefore remains UNKNOWN/u);
  const qbPath = join(fixture.root, "libraries", "synex_bridge", "compatibility", "surfaces", "qb.json");
  await writeFile(qbPath, `${await readFile(qbPath, "utf8")}\n`, "utf8");
  const drifted = await checkCompatibilityReviewLock(fixture.root);
  assert.equal(drifted.status, "FAIL");
  assert.equal(drifted.findings.some((entry) => entry.code === "LOCAL_CATALOG_HASH_DRIFT"), true);
});

test("opt-in upstream drift checks are bounded and never turn network failures into PASS", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const bodies = await configureUpstreamFixture(fixture.root);
  const matchingFetcher: typeof fetch = async (input) => {
    const body = bodies.get(String(input));
    return body === undefined
      ? new Response(null, { status: 404 })
      : new Response(body, { status: 200, headers: { "content-length": String(Buffer.byteLength(body)) } });
  };
  const matching = await checkCompatibilityReviewLock(fixture.root, {
    online: true, timeoutMs: 1_000, fetcher: matchingFetcher,
  });
  assert.equal(matching.status, "PASS");
  assert.equal(matching.localStatus, "PASS");
  assert.equal(matching.upstreamStatus, "MATCH");
  assert.equal(matching.networkAccess, true);
  assert.equal(matching.upstreamSources.length, 3);
  assert.equal(matching.upstreamSources.every((source) => source.status === "MATCH"), true);

  let calls = 0;
  const drifted = await checkCompatibilityReviewLock(fixture.root, {
    online: true,
    fetcher: async (input) => {
      calls += 1;
      const body = calls === 1 ? "changed\n" : bodies.get(String(input)) ?? "";
      return new Response(body, { status: 200 });
    },
  });
  assert.equal(drifted.status, "FAIL");
  assert.equal(drifted.upstreamStatus, "DRIFT");
  assert.equal(drifted.findings.some((entry) => entry.code === "UPSTREAM_SOURCE_DRIFT"), true);

  const unavailable = await checkCompatibilityReviewLock(fixture.root, {
    online: true,
    fetcher: async () => { throw new TypeError("network unavailable"); },
  });
  assert.equal(unavailable.status, "UNKNOWN");
  assert.equal(unavailable.upstreamStatus, "UNKNOWN");
  assert.equal(unavailable.findings.some((entry) => entry.code === "UPSTREAM_SOURCE_UNKNOWN"), true);

  const oversized = await checkCompatibilityReviewLock(fixture.root, {
    online: true,
    fetcher: async () => new Response("x", {
      status: 200, headers: { "content-length": "262145" },
    }),
  });
  assert.equal(oversized.status, "UNKNOWN");
  assert.equal(oversized.upstreamSources.every((source) => source.status === "UNKNOWN"), true);
  await assert.rejects(
    checkCompatibilityReviewLock(fixture.root, { online: true, timeoutMs: 1 }),
    /timeout must be an integer between 500 and 30000/u,
  );
});

test("offline review lock rejects central compatibility-mapping drift", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const mappingPath = join(
    fixture.root, "libraries", "synex_bridge", "compatibility", "mappings.json",
  );
  await writeFile(mappingPath, `${await readFile(mappingPath, "utf8")}\n`, "utf8");
  const drifted = await checkCompatibilityReviewLock(fixture.root);
  assert.equal(drifted.status, "FAIL");
  assert.equal(drifted.mappingCatalog.hashMatches, false);
  assert.equal(drifted.findings.some((entry) =>
    entry.code === "LOCAL_MAPPING_CATALOG_HASH_DRIFT"), true);
});

test("offline review lock rejects consumer-authorization and money-policy drift", async (context) => {
  for (const expected of [
    {
      file: "consumers.json", field: "consumerCatalog" as const,
      code: "LOCAL_CONSUMER_CATALOG_HASH_DRIFT",
    },
    {
      file: "money-policies.json", field: "moneyPolicyCatalog" as const,
      code: "LOCAL_MONEY_POLICY_CATALOG_HASH_DRIFT",
    },
  ]) {
    const fixture = await createFixtureRoot();
    context.after(async () => rm(fixture.root, { recursive: true, force: true }));
    const artifactPath = join(
      fixture.root, "libraries", "synex_bridge", "compatibility", expected.file,
    );
    await writeFile(artifactPath, `${await readFile(artifactPath, "utf8")}\n`, "utf8");
    const drifted = await checkCompatibilityReviewLock(fixture.root);
    assert.equal(drifted.status, "FAIL");
    assert.equal(drifted[expected.field].hashMatches, false);
    assert.equal(drifted.findings.some((entry) => entry.code === expected.code), true);
  }
});

test("compatibility CLI exposes observe, doctor, certification, and offline drift JSON", async (context) => {
  const fixture = await createFixtureRoot();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));
  const executionErrors: string[] = [];
  assert.equal(await runCli([
    "--root", fixture.root, "compat", "execute", "qb.fixture",
    "--output", "artifacts/compatibility/qb.fixture.execution.json", "--json",
  ], { log: () => undefined, error: (message) => executionErrors.push(message) }), 0, executionErrors.join("\n"));
  for (const arguments_ of [
    ["compat", "observe", "fixture_resource", "--runtime-evidence", "runtime-evidence.json", "--json"],
    ["compat", "doctor", "--runtime-evidence", "runtime-evidence.json", "--json"],
    ["compat", "certify", "qb.fixture", "--runtime-evidence", "runtime-evidence.json",
      "--execution-evidence", "artifacts/compatibility/qb.fixture.execution.json",
      "--output", "libraries/synex_bridge/compatibility/certifications/qb.fixture.json", "--json"],
    ["compat", "drift", "--json"],
  ]) {
    const output: string[] = [];
    const errors: string[] = [];
    const exitCode = await runCli(
      ["--root", fixture.root, ...arguments_],
      { log: (message) => output.push(message), error: (message) => errors.push(message) },
    );
    assert.equal(exitCode, 0, errors.join("\n"));
    assert.equal(output.length, 1);
    assert.doesNotThrow(() => JSON.parse(output[0] ?? ""));
  }
  const artifact = JSON.parse(await readFile(join(
    fixture.root,
    "libraries/synex_bridge/compatibility/certifications/qb.fixture.json",
  ), "utf8")) as { status: string; certified: boolean; certificate: { fingerprint: string } };
  assert.equal(artifact.status, "CERTIFIED");
  assert.equal(artifact.certified, true);
  assert.match(artifact.certificate.fingerprint, /^[0-9a-f]{64}$/u);

  const errors: string[] = [];
  assert.equal(await runCli([
    "--root", fixture.root, "compat", "certify", "qb.fixture",
    "--runtime-evidence", "runtime-evidence.json",
    "--execution-evidence", "artifacts/compatibility/qb.fixture.execution.json",
    "--output", "arbitrary.json",
  ], { log: () => undefined, error: (message) => errors.push(message) }), 2);
  assert.match(errors.join("\n"), /declared certificationArtifact path/u);
});
