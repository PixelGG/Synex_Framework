import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildCompatibilityMatrix,
  doctorCompatibility,
  explainCompatibility,
  inspectCompatibilityProfile,
  loadCompatibilityCatalog,
  scanCompatibility,
} from "../../tools/cli/src/compatibility.js";
import { certificationSurfaceEvidenceSatisfied } from "../../tools/cli/src/compatibility/catalog.js";
import type {
  CompatibilityProfile,
  CompatibilityStatus,
  CompatibilitySurface,
} from "../../tools/cli/src/compatibility/types.js";
import { runCli } from "../../tools/cli/src/dispatcher.js";
import { renderCompatibilityMatrixMarkdown } from "../../tools/codegen/generate-compatibility-matrix.js";

async function writeJson(path: string, value: unknown): Promise<void> {
  await mkdir(join(path, ".."), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function createCatalog(root: string): Promise<void> {
  const catalog = join(root, "libraries", "synex_bridge", "compatibility");
  await mkdir(join(catalog, "surfaces"), { recursive: true });
  const surface = (
    name: string,
    status: "PARTIAL" | "UNSUPPORTED",
    requiredAdapter: string | null = null,
  ) => ({
    name,
    scope: "server",
    type: "method",
    status,
    legacyVersionRange: null,
    nativeMapping: status === "PARTIAL" ? "synex.test.mapping" : null,
    requiredCapability: status === "PARTIAL" ? "synex.test.read" : null,
    requiredAdapter,
    adapterOperations: [],
    requiredCatalog: null,
    catalogOperations: [],
    modes: ["strict"],
    deprecated: true,
    tests: ["tests/compatibility/compatibility-cli.test.ts"],
  });
  for (const [provider, surfaces] of [
    ["qb", [{
      ...surface("qb.server.player_lookup", "PARTIAL"),
      requiredCatalog: "identity.players",
      catalogOperations: [{
        name: "player.lookup",
        nativeCapabilities: ["synex.identity.read"],
      }],
    }]],
    ["qbx", [surface("qbx.server.groups_read", "UNSUPPORTED")]],
    ["esx", []],
  ] as const) {
    await writeJson(join(catalog, "surfaces", `${provider}.json`), {
      $schema: "../schemas/surfaces.schema.json",
      schema: 1,
      kind: "synex-compatibility-surfaces",
      provider,
      providerResource: `synex_bridge_${provider}`,
      providerVersion: "0.1.0",
      targetFrameworkApiRange: null,
      upstream: {
        name: provider,
        repository: ({
          qb: "https://github.com/qbcore-framework/qb-core",
          qbx: "https://github.com/Qbox-project/qbx_core",
          esx: "https://github.com/esx-framework/esx_core",
        } as const)[provider],
        branch: "main",
        revision: ({ qb: "a", qbx: "b", esx: "c" } as const)[provider].repeat(40),
        sources: [{
          id: `${provider}.fixture`, path: "fixture.lua", bytes: 1, sha256: "d".repeat(64),
        }],
        evidenceUrls: ["https://example.invalid/upstream"],
      },
      surfaces,
    });
  }
  await writeJson(join(catalog, "profiles.json"), {
    $schema: "./schemas/profiles.schema.json",
    schema: 1,
    kind: "synex-compatibility-profiles",
    profiles: [{
      id: "qb.unproven",
      version: "1.0.0",
      script: { name: "fixture", testedVersion: null },
      provider: "qb",
      mode: "strict",
      status: "CERTIFIED",
      failurePolicy: "fail_start",
      providerVersion: "0.1.0",
      targetFrameworkApiRange: "^7.0.0",
      certificationArtifact: "compatibility/certifications/qb.unproven.json",
      requiredSurfaces: [{ name: "qb.server.player_lookup", acceptedStatuses: ["PARTIAL"] }],
      requiredAdapters: [{ name: "missing_adapter", versionRange: null }],
      requiredCatalogs: [{
        name: "identity.players", versionRange: "^1.0.0",
        domain: "identity", revision: 4,
      }],
      evidence: {
        tests: ["tests/compatibility/compatibility-cli.test.ts"],
        sourceUrls: ["https://example.invalid/source"],
      },
    }],
  });
  await writeJson(join(catalog, "consumers.json"), {
    $schema: "./schemas/consumers.schema.json",
    schema: 1,
    kind: "synex-compatibility-consumers",
    defaultMode: "strict",
    consumers: [{
      resource: "fixture_consumer", provider: "qb", profileId: "qb.unproven",
      failurePolicy: "fail_start", enabled: true,
    }, {
      resource: "fixture_consumer", provider: "qbx", profileId: "qb.unproven",
      failurePolicy: "fail_start", enabled: true,
    }],
  });
  await writeJson(join(catalog, "mappings.json"), {
    $schema: "./schemas/mappings.schema.json",
    schema: 1,
    kind: "synex-compatibility-mappings",
    identity: [],
    accounts: [{
      id: "qb.cash.one", version: "2.0.0", provider: "qb", alias: "cash",
      currencyCode: "usd", accountKey: "cash", accountRole: "asset", minorUnit: 0,
      status: "PARTIAL",
      fundingPolicy: { kind: "deny", accountRef: null },
      sinkPolicy: { kind: "deny", accountRef: null },
    }, {
      id: "qb.cash.two", version: "2.0.0", provider: "qb", alias: "cash",
      currencyCode: "usd", accountKey: "bank", accountRole: "asset", minorUnit: 0,
      status: "PARTIAL",
      fundingPolicy: { kind: "deny", accountRef: null },
      sinkPolicy: { kind: "deny", accountRef: null },
    }],
    groups: [],
    metadata: [],
    forbiddenMetadataFields: ["money"],
  });
}

test("certification binds the deduplicated required-surface test union and rejects unsafe statuses", () => {
  const testA = "tests/compatibility/surface-a.test.ts";
  const testB = "tests/compatibility/surface-b.test.ts";
  const sharedTest = "tests/compatibility/shared.test.ts";
  const surface = (
    name: string,
    status: CompatibilityStatus,
    tests: string[],
  ): CompatibilitySurface => ({
    provider: "qb",
    providerVersion: "0.1.0",
    targetFrameworkApiRange: "^7.0.0",
    name,
    scope: "server",
    type: "method",
    status,
    legacyVersionRange: null,
    nativeMapping: null,
    requiredCapability: null,
    requiredAdapter: null,
    adapterOperations: [],
    requiredCatalog: null,
    catalogOperations: [],
    modes: ["compat"],
    deprecated: true,
    tests,
  });
  const profile = (
    tests: string[],
    acceptedStatuses: CompatibilityStatus[] = ["PARTIAL"],
  ): CompatibilityProfile => ({
    id: "qb.bound-evidence",
    version: "1.0.0",
    script: "fixture",
    provider: "qb",
    mode: "compat",
    status: "CERTIFIED",
    effectiveStatus: "CERTIFIED",
    testedVersion: "2.0.0",
    providerVersion: "0.1.0",
    targetFrameworkApiRange: "^7.0.0",
    certificationArtifact: "compatibility/certifications/qb.bound-evidence.json",
    requiredAdapters: [],
    requiredCatalogs: [],
    surfaces: ["qb.surface.a", "qb.surface.b"],
    evidence: tests,
    failurePolicy: "fail_start",
    raw: {
      requiredSurfaces: [
        { name: "qb.surface.a", acceptedStatuses },
        { name: "qb.surface.b", acceptedStatuses },
      ],
      evidence: { tests, sourceUrls: ["https://example.invalid/evidence"] },
    },
  });
  const completeSurfaces = [
    surface("qb.surface.a", "PARTIAL", [testA, sharedTest]),
    surface("qb.surface.b", "PARTIAL", [sharedTest, testB]),
  ];

  assert.equal(
    certificationSurfaceEvidenceSatisfied(
      profile([testA, testB, sharedTest]),
      completeSurfaces,
    ),
    true,
  );
  assert.equal(
    certificationSurfaceEvidenceSatisfied(
      profile(["tests/compatibility/unrelated.test.ts"]),
      completeSurfaces,
    ),
    false,
  );
  for (const rejectedStatus of ["UNSUPPORTED", "UNKNOWN"] as const) {
    assert.equal(
      certificationSurfaceEvidenceSatisfied(
        profile([testA, testB, sharedTest], [rejectedStatus]),
        completeSurfaces.map((entry) => ({ ...entry, status: rejectedStatus })),
      ),
      false,
    );
    assert.equal(
      certificationSurfaceEvidenceSatisfied(
        profile([testA, testB, sharedTest], ["PARTIAL", rejectedStatus]),
        completeSurfaces,
      ),
      false,
    );
  }
});

test("compatibility scanner covers Lua/JS/TS/manifests, ignores comments, and never follows symlinks", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-compat-scan-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resource");
  await mkdir(resource, { recursive: true });
  await writeFile(join(resource, "fxmanifest.lua"), [
    "fx_version 'cerulean'",
    "dependency 'qb-core'",
    "-- dependency 'es_extended'",
  ].join("\n"), "utf8");
  await writeFile(join(resource, "server.lua"), [
    "local QBCore = exports['qb-core']:GetCoreObject()",
    "local player = QBCore.Functions.GetPlayer(source)",
    "-- ESX.GetPlayerFromId(source)",
    "MySQL.query([[",
    "  SELECT *",
    "  FROM players WHERE citizenid = ?",
    "]], { citizenid })",
  ].join("\n"), "utf8");
  await writeFile(join(resource, "client.ts"), [
    "// const core = 'qbx_core';",
    "const inventory = 'ox_inventory';",
  ].join("\n"), "utf8");
  await writeFile(join(resource, "client.js"), "/* ESX */\nconst target = 'ox_target';\n", "utf8");
  const outside = join(root, "outside.lua");
  await writeFile(outside, "ESX.GetPlayerFromId(source)\n", "utf8");
  try {
    await symlink(outside, join(resource, "linked.lua"), "file");
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? error.code : "";
    if (code !== "EPERM") throw error;
  }

  const report = await scanCompatibility(root, resource);
  assert.equal(report.filesScanned, 4);
  assert.equal(report.filesByLanguage.lua, 2);
  assert.equal(report.filesByLanguage.javascript, 1);
  assert.equal(report.filesByLanguage.typescript, 1);
  assert.equal(report.signatureCounts.esx, 0);
  assert.equal(report.signatureCounts.qbcore > 0, true);
  assert.equal(report.directLegacySql, 1);
  assert.equal(report.status, "UNSUPPORTED");
  assert.deepEqual(report.domainDependencies, ["entities", "identity", "inventory"]);
  assert.equal(report.findings.some((finding) => finding.surface === "qb.server.player_lookup"), true);
});

test("catalog matrix is deterministic and authored certification is downgraded without tested-version evidence", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-compat-catalog-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  await createCatalog(root);

  const catalog = await loadCompatibilityCatalog(root);
  assert.deepEqual(catalog.mappings.map((mapping) => mapping.native), [
    "usd:cash:asset:0",
    "usd:bank:asset:0",
  ]);
  const first = buildCompatibilityMatrix(catalog);
  const second = buildCompatibilityMatrix(catalog);
  assert.deepEqual(first, second);
  assert.deepEqual(first.rows.map((row) => `${row.provider}:${row.name}`), [
    "qb:qb.server.player_lookup",
    "qbx:qbx.server.groups_read",
  ]);
  assert.equal(first.rows[0]?.requiredCatalog, "identity.players");
  assert.deepEqual(first.rows[0]?.catalogOperations, [{
    name: "player.lookup",
    nativeCapabilities: ["synex.identity.read"],
  }]);
  const profile = inspectCompatibilityProfile(catalog, "qb.unproven");
  assert.equal(profile.found, true);
  assert.equal(profile.profile?.status, "CERTIFIED");
  assert.deepEqual(profile.profile?.requiredCatalogs, ["identity.players"]);
  assert.notEqual(profile.status, "CERTIFIED");

  const doctor = await doctorCompatibility(root, catalog);
  assert.equal(doctor.status, "UNSUPPORTED");
  assert.equal(doctor.findings.some((finding) => finding.code === "MAPPING_AMBIGUOUS"), true);
  assert.equal(doctor.findings.some((finding) => finding.code === "PROVIDER_CONFLICT"), true);
  assert.equal(doctor.findings.some((finding) => finding.code === "ADAPTER_MISSING"), true);
  assert.equal(doctor.findings.some((finding) => finding.code === "PROFILE_CERTIFICATION_EVIDENCE_MISSING"), true);

  const resource = join(root, "consumer");
  await mkdir(resource, { recursive: true });
  await writeFile(join(resource, "server.lua"), [
    "local QBCore = exports['qb-core']:GetCoreObject()",
    "local player = QBCore.Functions.GetPlayer(source)",
  ].join("\n"), "utf8");
  const explanation = explainCompatibility(await scanCompatibility(root, resource), catalog);
  assert.equal(explanation.resolved.some((entry) =>
    entry.matches.some((match) => match.name === "qb.server.player_lookup")), true);
});

test("dispatcher exposes all compatibility catalog commands with stable JSON output", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-compat-dispatch-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  await createCatalog(root);
  await mkdir(join(root, "schemas"), { recursive: true });
  await writeFile(join(root, "package.json"), "{}\n", "utf8");
  await writeFile(join(root, "schemas", "resource.schema.json"), "{}\n", "utf8");

  for (const arguments_ of [
    ["compat", "status", "--json"],
    ["compat", "matrix", "--json"],
    ["compat", "profile", "qb.unproven", "--json"],
    ["compat", "adapters", "--json"],
  ]) {
    const output: string[] = [];
    const errors: string[] = [];
    const exitCode = await runCli(
      ["--root", root, ...arguments_],
      { log: (message) => output.push(message), error: (message) => errors.push(message) },
    );
    assert.equal(exitCode, 0, errors.join("\n"));
    assert.equal(output.length, 1);
    assert.doesNotThrow(() => JSON.parse(output[0] ?? ""));
  }
});

test("checked-in compatibility matrix is generated deterministically from the catalog", async () => {
  const root = process.cwd();
  const catalog = await loadCompatibilityCatalog(root);
  assert.equal(catalog.available, true);
  assert.equal(catalog.diagnostics.length, 0);
  assert.equal(
    await readFile(join(root, "docs", "compatibility", "matrix.md"), "utf8"),
    renderCompatibilityMatrixMarkdown(catalog),
  );
});
