import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildMigrationPlan,
  canonicalJson,
  materializeMigrationPlan,
  runMigratorCli,
  validateMapping,
  validateSource,
} from "../../tools/migrator/src/migrator.js";
import {
  connectImportDatabase,
  importReviewedMigrationPlan,
  loadReviewedMigrationPlan,
  type ImportDatabase,
} from "../../tools/migrator/src/importer.js";

const fixtureRoot = join(process.cwd(), "tests", "compatibility", "fixtures");

async function fixture(name: string): Promise<unknown> {
  return JSON.parse(await readFile(join(fixtureRoot, name), "utf8")) as unknown;
}

for (const framework of ["qb", "qbx", "esx"] as const) {
  test(`${framework} fixture produces deterministic IDs and conserved opening balances`, async () => {
    const source = validateSource(await fixture(`${framework}-source.json`));
    const mapping = validateMapping(await fixture(`${framework}-mapping.json`));
    const first = buildMigrationPlan(source, mapping, "fixture-source-digest");
    const second = buildMigrationPlan(source, mapping, "fixture-source-digest");

    assert.equal(canonicalJson(first), canonicalJson(second));
    assert.equal(first.report.economy.conserved, true);
    assert.equal(first.report.counts.characters, 1);
    assert.equal(first.bundle.openingBalances.length, 2);
    assert.equal(first.bundle.characters[0]?.slot, 1);
    assert.match(first.idMap.characters[0]?.synexId ?? "", /^[0-9a-f-]{36}$/u);
  });
}

test("invalid money and duplicate character IDs block conservation and apply", async (context) => {
  const source = validateSource({
    schema: 1,
    framework: "qb",
    records: [
      { uid: "u1", cid: "c1", first: "A", last: "B", cash: 5, bank: 10 },
      { uid: "u1", cid: "c1", first: "A", last: "B", cash: -1, bank: 10 },
    ],
  });
  const mapping = validateMapping({
    schema: 1,
    framework: "qb",
    fields: {
      userId: "uid",
      characterId: "cid",
      firstName: "first",
      lastName: "last",
      money: { cash: "cash", bank: "bank" },
    },
  });
  const plan = buildMigrationPlan(source, mapping);
  assert.equal(plan.report.counts.conflicts > 0, true);
  assert.ok(plan.report.conflicts.some((issue) =>
    issue.field === "userId" && issue.reason === "unsupported_platform_identifier"));
  assert.equal(plan.report.economy.conserved, false);

  const root = await mkdtemp(join(tmpdir(), "synex-migration-blocked-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const target = join(root, "target");
  await assert.rejects(
    materializeMigrationPlan(plan, target, target, [], false),
    /conflicts exist or economy conservation fails/u,
  );
});

test("reviewed bundle loading requires the exact report digest and rejects tampering", async (context) => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(await fixture("qbx-mapping.json"));
  const plan = buildMigrationPlan(source, mapping);
  const root = await mkdtemp(join(tmpdir(), "synex-reviewed-import-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const target = join(root, "bundle");
  await materializeMigrationPlan(plan, target, target, [], false);

  const loaded = await loadReviewedMigrationPlan(target, plan.report.reportDigest);
  assert.equal(loaded.report.reportDigest, plan.report.reportDigest);
  await assert.rejects(
    loadReviewedMigrationPlan(target, "0".repeat(64)),
    /confirmed report digest does not match/u,
  );

  const bundlePath = join(target, "migration-bundle.json");
  const changed = JSON.parse(await readFile(bundlePath, "utf8")) as Record<string, unknown>;
  const opening = (changed.openingBalances as Array<Record<string, unknown>>)[0];
  assert.ok(opening);
  opening.amount = 999999;
  await writeFile(bundlePath, canonicalJson(changed), "utf8");
  await assert.rejects(
    loadReviewedMigrationPlan(target, plan.report.reportDigest),
    /Opening balance totals do not match/u,
  );
});

test("database import is idempotent by reviewed digest and performs no writes on replay", async () => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(await fixture("qbx-mapping.json"));
  const plan = buildMigrationPlan(source, mapping);
  let began = false;
  const statements: string[] = [];
  const database: ImportDatabase = {
    begin: async () => { began = true; },
    commit: async () => undefined,
    rollback: async () => undefined,
    close: async () => undefined,
    execute: async (sql, parameters = []) => {
      statements.push(sql);
      if (sql.includes("information_schema.tables")) {
        return {
          rows: parameters.map((table) => ({ table_name: table })),
          insertId: 0,
          affectedRows: parameters.length,
        };
      }
      if (sql.includes("FROM synex_legacy_imports")) {
        return { rows: [{ state: "completed" }], insertId: 0, affectedRows: 1 };
      }
      throw new Error("unexpected write during replay");
    },
  };
  const result = await importReviewedMigrationPlan(plan, database, false);
  assert.equal(result.alreadyApplied, true);
  assert.equal(began, false);
  assert.equal(statements.length, 2);
});

test("database import rejects non-MySQL and database-less connection URLs before connecting", async () => {
  await assert.rejects(connectImportDatabase("https://db.example.invalid/synex"), /must use mysql/u);
  await assert.rejects(connectImportDatabase("mysql://user:secret@db.example.invalid"), /target database/u);
  await assert.rejects(
    connectImportDatabase("mysql://user:secret@db.example.invalid/synex?multipleStatements=true"),
    /must not override multipleStatements/u,
  );
});

test("apply requires exact target confirmation, never overwrites, and emits three bounded artifacts", async (context) => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(await fixture("qbx-mapping.json"));
  const plan = buildMigrationPlan(source, mapping);
  const root = await mkdtemp(join(tmpdir(), "synex-migration-apply-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const target = join(root, "bundle");

  await assert.rejects(
    materializeMigrationPlan(plan, target, join(root, "other"), [], false),
    /confirm-target/u,
  );
  const written = await materializeMigrationPlan(plan, target, target, [], false);
  assert.deepEqual(written, ["migration-report.json", "id-map.json", "migration-bundle.json"]);
  assert.equal((await stat(join(target, "migration-report.json"))).isFile(), true);
  await assert.rejects(
    materializeMigrationPlan(plan, target, target, [], false),
    /must not already exist/u,
  );
});

test("CLI defaults to dry-run and leaves source bytes unchanged", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-migration-cli-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const source = join(root, "source.json");
  const mapping = join(root, "mapping.json");
  await writeFile(source, await readFile(join(fixtureRoot, "qbx-source.json"), "utf8"), "utf8");
  await writeFile(mapping, await readFile(join(fixtureRoot, "qbx-mapping.json"), "utf8"), "utf8");
  const before = await readFile(source, "utf8");
  const output: string[] = [];
  const errors: string[] = [];

  const exitCode = await runMigratorCli(
    ["--framework", "qbx", "--source", source, "--mapping", mapping],
    { log: (message) => output.push(message), error: (message) => errors.push(message) },
  );
  assert.equal(exitCode, 0);
  assert.equal(await readFile(source, "utf8"), before);
  assert.match(output.join("\n"), /synex-legacy-migration-plan/u);
  assert.match(output.join("\n"), /"idMap"/u);
  assert.deepEqual(errors, []);
});
