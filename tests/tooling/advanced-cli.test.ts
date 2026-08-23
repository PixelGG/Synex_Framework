import assert from "node:assert/strict";
import { cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import test from "node:test";
import { tmpdir } from "node:os";

import {
  buildResourceGraph,
  createDiagnosticBundle,
  redactDiagnosticValue,
  runBenchmark,
  runCli,
  runManagedReload,
  upgradeCheck,
  validateRepository,
} from "../../tools/cli/src/cli.js";
import {
  compareAppliedMigrations,
  compareDatabaseShape,
  deriveExpectedDatabaseShape,
  extractDatabaseShape,
} from "../../tools/cli/src/database-doctor.js";

function fixtureManifest(
  name: string,
  required: string[] = [],
  migrationContents = false,
  snapshotSupported = false,
): Record<string, unknown> {
  return {
    $schema: "../../schemas/resource.schema.json",
    schema: 1,
    name,
    version: "0.1.0",
    synex: "^1.0.0",
    critical: false,
    capabilities: { request: [] },
    services: { provide: [], require: [], optional: [] },
    contracts: { provide: [], consume: [] },
    events: { publish: [], subscribe: [] },
    hooks: { register: [], run: [] },
    dependencies: {
      required: required.map((dependency) => ({ name: dependency, version: ">=0.1.0" })),
      optional: [],
      development: [],
    },
    migrations: migrationContents ? [{ id: "001_init", path: "migrations/001_init.sql", transactional: true }] : [],
    dataOwnership: { tables: [], characterDelete: "none" },
    stateSnapshot: { supported: snapshotSupported, schemaVersion: 1 },
  };
}

async function removeFixture(path: string): Promise<void> {
  const temporaryRoot = `${resolve(tmpdir())}${sep}`;
  assert.ok(resolve(path).startsWith(temporaryRoot));
  await rm(path, { recursive: true, force: true });
}

async function writeFixtureResource(
  repository: string,
  name: string,
  manifest: Record<string, unknown>,
  migration?: string,
): Promise<string> {
  const directory = join(repository, "resources", name);
  await mkdir(join(directory, "migrations"), { recursive: true });
  await writeFile(join(directory, "synex.resource.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  const version = typeof manifest.version === "string" ? manifest.version : "0.1.0";
  await writeFile(
    join(directory, "fxmanifest.lua"),
    `fx_version 'cerulean'\ngame 'gta5'\nversion '${version}'\n`,
    "utf8",
  );
  if (migration !== undefined) await writeFile(join(directory, "migrations", "001_init.sql"), migration, "utf8");
  return directory;
}

test("resource graph resolves required edges and reports static API usage", async () => {
  const graph = await buildResourceGraph(process.cwd());
  assert.ok(graph.nodes.some((node) => node.name === "synex_core" && !node.external));
  assert.ok(graph.edges.some((edge) => edge.kind === "dependency-required"));
  assert.equal(Array.isArray(graph.usage.contracts), true);
  assert.equal(typeof graph.usage.disclaimer, "string");
});

test("resource graph identifies a real required-dependency cycle", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-graph-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    await writeFixtureResource(repository, "synex_a", fixtureManifest("synex_a", ["synex_b"]));
    await writeFixtureResource(repository, "synex_b", fixtureManifest("synex_b", ["synex_a"]));
    const graph = await buildResourceGraph(repository);
    assert.deepEqual(graph.cycles, [["synex_a", "synex_b"]]);
    assert.equal(graph.topologicalOrder, null);
  } finally {
    await removeFixture(repository);
  }
});

test("validation and graph enforce dependency versions while deferring unvendored externals to runtime", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-dependency-versions-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    await writeFixtureResource(repository, "synex_required_provider", fixtureManifest("synex_required_provider"));
    await writeFixtureResource(repository, "synex_optional_provider", fixtureManifest("synex_optional_provider"));
    const consumer = fixtureManifest("synex_consumer");
    consumer.dependencies = {
      required: [
        { name: "synex_required_provider", version: ">=1.0.0" },
        { name: "oxmysql", version: ">=2.14.1 <3.0.0" },
      ],
      optional: [{ name: "synex_optional_provider", version: "^1.0.0" }],
      development: [],
    };
    await writeFixtureResource(repository, "synex_consumer", consumer);

    const validation = await validateRepository(repository);
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-version"
      && diagnostic.level === "error"
      && diagnostic.message.includes("synex_required_provider")
    ));
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-version"
      && diagnostic.level === "warning"
      && diagnostic.message.includes("synex_optional_provider")
    ));
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-runtime-unverified"
      && diagnostic.level === "warning"
      && diagnostic.message.includes("oxmysql@>=2.14.1 <3.0.0")
    ));

    const graph = await buildResourceGraph(repository);
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.dependency === "synex_required_provider"
      && finding.actualVersion === "0.1.0"
      && finding.status === "incompatible"
      && finding.severity === "error"
    ));
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.dependency === "synex_optional_provider"
      && finding.status === "incompatible"
      && finding.severity === "warning"
    ));
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.dependency === "oxmysql"
      && finding.status === "runtime-unverified"
      && finding.severity === "warning"
    ));
  } finally {
    await removeFixture(repository);
  }
});

test("required dependency fxmanifest metadata is fail-closed and optional metadata is a warning", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-dependency-metadata-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    const requiredDirectory = await writeFixtureResource(
      repository,
      "synex_required_provider",
      fixtureManifest("synex_required_provider"),
    );
    const optionalDirectory = await writeFixtureResource(
      repository,
      "synex_optional_provider",
      fixtureManifest("synex_optional_provider"),
    );
    await writeFile(
      join(requiredDirectory, "fxmanifest.lua"),
      "fx_version 'cerulean'\ngame 'gta5'\n",
      "utf8",
    );
    await writeFile(
      join(optionalDirectory, "fxmanifest.lua"),
      "fx_version 'cerulean'\ngame 'gta5'\nversion 'not-semver'\n",
      "utf8",
    );
    const consumer = fixtureManifest("synex_consumer");
    consumer.dependencies = {
      required: [{ name: "synex_required_provider", version: ">=0.1.0" }],
      optional: [{ name: "synex_optional_provider", version: ">=0.1.0" }],
      development: [],
    };
    await writeFixtureResource(repository, "synex_consumer", consumer);

    const validation = await validateRepository(repository);
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-metadata"
      && diagnostic.level === "error"
      && diagnostic.message.includes("synex_required_provider")
    ));
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-metadata"
      && diagnostic.level === "warning"
      && diagnostic.message.includes("synex_optional_provider")
    ));
    const graph = await buildResourceGraph(repository);
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.dependency === "synex_required_provider"
      && finding.status === "metadata-missing"
      && finding.severity === "error"
    ));
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.dependency === "synex_optional_provider"
      && finding.status === "metadata-invalid"
      && finding.severity === "warning"
    ));
  } finally {
    await removeFixture(repository);
  }
});

test("vendored oxmysql must satisfy the entities upper version bound", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-oxmysql-version-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    const oxmysql = join(repository, "external", "oxmysql");
    await mkdir(oxmysql, { recursive: true });
    await writeFile(
      join(oxmysql, "fxmanifest.lua"),
      "fx_version 'cerulean'\ngame 'gta5'\nversion '3.0.0'\n",
      "utf8",
    );
    const entities = fixtureManifest("synex_entities");
    entities.dependencies = {
      required: [{ name: "oxmysql", version: ">=2.14.1 <3.0.0" }],
      optional: [],
      development: [],
    };
    await writeFixtureResource(repository, "synex_entities", entities);

    const validation = await validateRepository(repository);
    assert.ok(validation.diagnostics.some((diagnostic) =>
      diagnostic.rule === "resource-dependency-version"
      && diagnostic.level === "error"
      && diagnostic.message.includes("oxmysql requires >=2.14.1 <3.0.0")
      && diagnostic.message.includes("3.0.0")
    ));
    const graph = await buildResourceGraph(repository);
    assert.ok(graph.dependencyVersions.some((finding) =>
      finding.resource === "synex_entities"
      && finding.dependency === "oxmysql"
      && finding.requiredRange === ">=2.14.1 <3.0.0"
      && finding.actualVersion === "3.0.0"
      && finding.status === "incompatible"
      && finding.severity === "error"
    ));
  } finally {
    await removeFixture(repository);
  }
});

test("diagnostic redaction removes keyed and embedded secrets", () => {
  const result = redactDiagnosticValue({
    token: "super-secret-token",
    nested: {
      endpoint: "mysql://operator:password@localhost/synex",
      accessToken: "another-secret-value",
      callback: "https://example.invalid/reload?api_key=query-secret",
    },
  });
  const serialized = JSON.stringify(result.value);
  assert.doesNotMatch(serialized, /super-secret|another-secret|query-secret|operator|password/u);
  assert.ok(result.redactedFields > 0);
  assert.ok(result.redactedValues > 0);
});

test("doctor bundle includes hashed repository diagnostics without environment or bearer secrets", async () => {
  const bundle = await createDiagnosticBundle(process.cwd(), process.cwd(), {
    status: "WARN",
    checks: [{ name: "fixture", status: "WARN", detail: "Bearer diagnostic-secret-value" }],
  });
  const serialized = JSON.stringify(bundle);
  assert.equal((bundle.redaction as { environmentIncluded: boolean }).environmentIncluded, false);
  assert.match(String(bundle.sha256), /^[0-9a-f]{64}$/u);
  assert.doesNotMatch(serialized, /diagnostic-secret-value/u);
  assert.match(serialized, /\[REDACTED\]/u);
});

test("database doctor derives expected columns and indexes from repository migrations", async () => {
  const shape = await deriveExpectedDatabaseShape(process.cwd());
  assert.ok(Object.keys(shape.migrations).length >= 18);
  assert.ok(shape.tables.synex_sessions?.columns.includes("source_generation"));
  assert.ok(shape.tables.synex_sessions?.indexes.includes("uq_sessions_instance_source_generation"));
  assert.ok(shape.tables.synex_schema_migrations?.indexes.includes("PRIMARY"));
});

test("database shape comparison detects missing columns, indexes, and unknown applied migrations", () => {
  const expectedTables = extractDatabaseShape(`
CREATE TABLE IF NOT EXISTS \`synex_probe\` (
  \`id\` BIGINT NOT NULL,
  PRIMARY KEY (\`id\`)
);
ALTER TABLE \`synex_probe\`
  ADD COLUMN \`payload\` VARCHAR(64) NOT NULL,
  ADD UNIQUE KEY \`uq_synex_probe_payload\` (\`payload\`);
`);
  const schemaDelta = compareDatabaseShape(
    expectedTables,
    ["synex_probe"],
    ["synex_probe:id"],
    ["synex_probe:PRIMARY"],
  );
  assert.deepEqual(schemaDelta.missingTables, []);
  assert.deepEqual(schemaDelta.missingColumns, ["synex_probe.payload"]);
  assert.deepEqual(schemaDelta.missingIndexes, ["synex_probe.uq_synex_probe_payload"]);

  const migrationDelta = compareAppliedMigrations(
    { "synex_core:001": "expected-checksum" },
    [
      ["synex_core:001", "expected-checksum"],
      ["synex_core:999_unknown", "unknown-checksum"],
    ],
  );
  assert.deepEqual(migrationDelta.pending, []);
  assert.deepEqual(migrationDelta.checksumMismatches, []);
  assert.deepEqual(migrationDelta.unknownApplied, ["synex_core:999_unknown"]);
});

test("benchmark baseline comparison emits reproducible regression warnings", () => {
  const baseline = runBenchmark(20);
  for (const measurement of Object.values(baseline.benchmarks)) measurement.operationsPerSecond *= 100;
  const compared = runBenchmark(20, baseline);
  assert.equal(compared.baseline.compared, true);
  assert.equal(compared.status, "WARN");
  assert.ok(compared.regressions.length > 0);
  assert.equal(Object.hasOwn(compared.benchmarks, "ledger_operation"), true);
  assert.equal(Object.hasOwn(compared.benchmarks, "contract_validation"), true);
});

test("managed reload produces a non-executing state-aware plan by default", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-reload-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    await writeFixtureResource(repository, "synex_reload", fixtureManifest("synex_reload", [], false, true));
    const report = await runManagedReload(repository, "synex_reload", "plan");
    assert.equal(report.executed, false);
    assert.equal(report.stateful, true);
    assert.ok(report.actions.some((action) => action.stage === "QUIESCE"));
    assert.ok(report.actions.some((action) => action.stage === "RESTORE"));
  } finally {
    await removeFixture(repository);
  }
});

test("managed reload rejects unresolved dependencies anywhere in the impacted closure", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-reload-unresolved-"));
  try {
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    await writeFixtureResource(repository, "synex_target", fixtureManifest("synex_target", [], false, true));
    await writeFixtureResource(
      repository,
      "synex_dependent",
      fixtureManifest("synex_dependent", ["synex_target", "synex_missing"], false, true),
    );
    await assert.rejects(
      runManagedReload(repository, "synex_target", "plan"),
      /unresolved required dependencies in the impacted set: synex_dependent:synex_missing/u,
    );
  } finally {
    await removeFixture(repository);
  }
});

test("targeted upgrade checks compare only the matching baseline resource and hash migrations", async () => {
  const repository = await mkdtemp(join(tmpdir(), "synex-upgrade-current-"));
  const baseline = await mkdtemp(join(tmpdir(), "synex-upgrade-baseline-"));
  try {
    const packageMetadata = JSON.stringify({
      name: "synex-fixture",
      version: "0.1.0",
      synex: { apiVersion: "1.0.0" },
    }, null, 2);
    await cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true });
    await writeFile(join(repository, "package.json"), `${packageMetadata}\n`, "utf8");
    await writeFile(join(baseline, "package.json"), `${packageMetadata}\n`, "utf8");
    const currentTarget = await writeFixtureResource(
      repository,
      "synex_a",
      fixtureManifest("synex_a", [], true),
      "SELECT 2;\n",
    );
    await writeFixtureResource(repository, "synex_b", fixtureManifest("synex_b"));
    await writeFixtureResource(baseline, "synex_a", fixtureManifest("synex_a", [], true), "SELECT 1;\n");
    await writeFixtureResource(baseline, "synex_b", fixtureManifest("synex_b"));

    const report = await upgradeCheck(repository, currentTarget, baseline);
    assert.ok(report.blockers.some((blocker) => /synex_a migration 001_init changed checksum/u.test(blocker)));
    assert.equal(report.deltas.resources.some((delta) => /synex_b/u.test(delta)), false);
  } finally {
    await removeFixture(repository);
    await removeFixture(baseline);
  }
});

test("main dispatcher wires legacy migration dry-runs", async () => {
  const output: string[] = [];
  const errors: string[] = [];
  const exitCode = await runCli([
    "migrate",
    "qb",
    "--dry-run",
    "--source",
    "tests/compatibility/fixtures/qb-source.json",
    "--mapping",
    "tests/compatibility/fixtures/qb-mapping.json",
  ], { log: (message) => output.push(message), error: (message) => errors.push(message) });
  assert.equal(exitCode, 0);
  assert.deepEqual(errors, []);
  assert.match(output.join("\n"), /synex-legacy-migration-plan/u);
});
