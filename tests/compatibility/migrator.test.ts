import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildMigrationPlan,
  canonicalJson,
  loadMigrationPlan,
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
import {
  loadCompatibilityMetadataCatalog,
} from "../../tools/migrator/src/compatibility-metadata.js";
import {
  loadCompatibilityAccountCatalog,
} from "../../tools/migrator/src/compatibility-accounts.js";
import {
  validateCompatibilityGroupCatalog,
} from "../../tools/migrator/src/compatibility-groups.js";

const fixtureRoot = join(process.cwd(), "tests", "compatibility", "fixtures");
const metadataCatalog = await loadCompatibilityMetadataCatalog();
const accountCatalog = await loadCompatibilityAccountCatalog();

async function fixture(name: string): Promise<unknown> {
  return JSON.parse(await readFile(join(fixtureRoot, name), "utf8")) as unknown;
}

for (const framework of ["qb", "qbx", "esx"] as const) {
  test(`${framework} fixture produces deterministic IDs and conserved opening balances`, async () => {
    const source = validateSource(await fixture(`${framework}-source.json`));
    const mapping = validateMapping(
      await fixture(`${framework}-mapping.json`),
      metadataCatalog,
      accountCatalog,
    );
    const first = buildMigrationPlan(source, mapping, "fixture-source-digest");
    const second = buildMigrationPlan(source, mapping, "fixture-source-digest");

    assert.equal(canonicalJson(first), canonicalJson(second));
    assert.equal(first.report.economy.conserved, true);
    assert.equal(first.report.counts.characters, 1);
    assert.equal(first.bundle.openingBalances.length, 2);
    assert.equal(first.bundle.characters[0]?.slot, 1);
    assert.match(first.idMap.characters[0]?.synexId ?? "", /^[0-9a-f-]{36}$/u);
    assert.deepEqual(first.bundle.metadata, [{
      characterId: first.bundle.characters[0]?.id,
      mappingId: `${framework}.hunger`,
      mappingVersion: "1.0.0",
      metadataKey: "needs.hunger",
      value: framework === "qb" ? 35 : framework === "qbx" ? 62 : 77,
    }]);
    assert.equal(first.report.metadata.catalogDigest, metadataCatalog.digest);
    assert.deepEqual(first.report.metadata.mappingIds, [`${framework}.hunger`]);
    assert.equal(first.report.metadata.sourceEntries, 1);
    assert.equal(first.report.metadata.transformedEntries, 1);
    assert.equal(first.report.metadata.omittedEntries, 0);
    assert.equal(first.report.metadata.rejectedEntries, 0);
    assert.equal(first.report.metadata.valuesInReport, false);
    assert.equal(first.report.metadata.blobCopied, false);
    assert.equal(first.report.metadata.credentialsCaptured, false);
  });
}

test("compatibility metadata mappings are catalog-bound, provider-bound, typed, and privacy preserving", async () => {
  const rawMapping = await fixture("qb-mapping.json") as Record<string, unknown>;
  const staleMapping = structuredClone(rawMapping);
  (staleMapping.compatibilityMetadata as Record<string, unknown>).catalogDigest = "0".repeat(64);
  assert.throws(
    () => validateMapping(staleMapping, metadataCatalog, accountCatalog),
    /exact compatibilityMetadata catalog digest/u,
  );

  const wrongProviderMapping = structuredClone(rawMapping);
  (wrongProviderMapping.compatibilityMetadata as Record<string, unknown>).mappingIds = ["esx.hunger"];
  assert.throws(
    () => validateMapping(wrongProviderMapping, metadataCatalog, accountCatalog),
    /unavailable for qb/u,
  );

  const source = validateSource({
    schema: 1,
    framework: "qb",
    records: [{
      license: "license:metadata-privacy",
      citizenid: "QB-METADATA-PRIVACY",
      charinfo: { firstname: "Meta", lastname: "Data" },
      money: { cash: 0, bank: 0 },
      job: { name: "mechanic", grade: { level: 0 } },
      gang: { name: "none", grade: { level: 0 } },
      metadata: { hunger: 50, password: "must-never-leave-source" },
    }],
  });
  const mapping = validateMapping(rawMapping, metadataCatalog, accountCatalog);
  const plan = buildMigrationPlan(source, mapping);
  assert.equal(plan.report.counts.conflicts, 0);
  assert.equal(plan.report.counts.unsupported, 1);
  assert.equal(plan.report.metadata.sourceEntries, 2);
  assert.equal(plan.report.metadata.transformedEntries, 1);
  assert.equal(plan.report.metadata.omittedEntries, 1);
  assert.equal(plan.report.metadata.rejectedEntries, 0);
  assert.deepEqual(plan.bundle.metadata.map((entry) => ({
    mappingId: entry.mappingId,
    metadataKey: entry.metadataKey,
    value: entry.value,
  })), [{ mappingId: "qb.hunger", metadataKey: "needs.hunger", value: 50 }]);
  assert.equal(plan.report.unsupported.some((issue) =>
    issue.field === "metadata" && issue.reason === "unmapped_or_forbidden_fields_omitted"), true);
  assert.doesNotMatch(canonicalJson(plan.report), /must-never-leave-source|password/u);

  const invalidSource = validateSource({
    schema: 1,
    framework: "qb",
    records: [{
      license: "license:metadata-invalid",
      citizenid: "QB-METADATA-INVALID",
      charinfo: { firstname: "Invalid", lastname: "Bounds" },
      money: { cash: 0, bank: 0 },
      job: { name: "mechanic", grade: { level: 0 } },
      gang: { name: "none", grade: { level: 0 } },
      metadata: { hunger: 101, inventory: { item: "private" } },
    }],
  });
  const invalidPlan = buildMigrationPlan(invalidSource, mapping);
  assert.equal(invalidPlan.bundle.metadata.length, 0);
  assert.equal(invalidPlan.report.metadata.sourceEntries, 2);
  assert.equal(invalidPlan.report.metadata.transformedEntries, 0);
  assert.equal(invalidPlan.report.metadata.omittedEntries, 1);
  assert.equal(invalidPlan.report.metadata.rejectedEntries, 1);
  assert.equal(invalidPlan.report.conflicts.some((issue) =>
    issue.field === "metadata.hunger" && issue.reason === "invalid_mapped_metadata_value"), true);
  assert.doesNotMatch(canonicalJson(invalidPlan.report), /inventory|private/u);
});

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
  }, metadataCatalog, accountCatalog);
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

test("ESX money mappings use the same catalog-bound cash and bank account aliases as runtime", () => {
  const source = validateSource({
    schema: 1,
    framework: "esx",
    records: [{
      identifier: "license:configurable-esx-money",
      character: "ESX-CONFIG-001",
      firstname: "Mira",
      lastname: "Stone",
      accounts: JSON.stringify({ money: 900, bank: 4100, black_money: 275, token: 8 }),
    }],
  });
  const mapping = validateMapping({
    schema: 1,
    framework: "esx",
    fields: {
      userId: "identifier",
      characterId: "character",
      firstName: "firstname",
      lastName: "lastname",
      money: {
        cash: "accounts.money",
        bank: "accounts.bank",
      },
    },
  }, metadataCatalog, accountCatalog);
  const plan = buildMigrationPlan(source, mapping, "configurable-esx-source");

  assert.deepEqual(Object.keys(mapping.fields.money), ["bank", "cash"]);
  assert.deepEqual(
    plan.bundle.openingBalances.map((entry) => [
      entry.alias, entry.currency, entry.accountKey, entry.amount,
    ]),
    [
      ["bank", "usd", `bank_${plan.bundle.characters[0]?.id.replaceAll("-", "")}`, 4100],
      ["cash", "usd", `cash_${plan.bundle.characters[0]?.id.replaceAll("-", "")}`, 900],
    ],
  );
  assert.deepEqual(plan.report.economy.source, {
    bank: "4100", cash: "900",
  });
  assert.deepEqual(plan.report.economy.transformed, plan.report.economy.source);
  assert.equal(plan.report.economy.conserved, true);
  assert.deepEqual(plan.report.accounts.mappingIds, ["esx.bank", "esx.cash"]);
  assert.equal(plan.report.accounts.catalogDigest, accountCatalog.digest);
  assert.equal(plan.report.accounts.ownerScopedKeys, true);
  assert.equal(plan.report.accounts.directBalanceWrites, false);
});

test("money mappings reject aliases that are absent from the checked-in account catalog", () => {
  assert.throws(() => validateMapping({
    schema: 1,
    framework: "esx",
    fields: {
      userId: "identifier",
      characterId: "character",
      firstName: "firstname",
      lastName: "lastname",
      money: { "Black Money": "accounts.black_money" },
    },
  }, metadataCatalog, accountCatalog), /fields\.money alias|unavailable/u);
});

test("reviewed bundle loading requires the exact report digest and rejects tampering", async (context) => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(
    await fixture("qbx-mapping.json"), metadataCatalog, accountCatalog,
  );
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
  const metadata = (changed.metadata as Array<Record<string, unknown>>)[0];
  assert.ok(metadata);
  metadata.value = 99;
  await writeFile(bundlePath, canonicalJson(changed), "utf8");
  await assert.rejects(
    loadReviewedMigrationPlan(target, plan.report.reportDigest),
    /compatibility metadata evidence digest is invalid/u,
  );

  const original = plan.bundle as unknown as Record<string, unknown>;
  await writeFile(bundlePath, canonicalJson(original), "utf8");
  const openingChanged = JSON.parse(await readFile(bundlePath, "utf8")) as Record<string, unknown>;
  const opening = (openingChanged.openingBalances as Array<Record<string, unknown>>)[0];
  assert.ok(opening);
  opening.amount = 999999;
  await writeFile(bundlePath, canonicalJson(openingChanged), "utf8");
  await assert.rejects(
    loadReviewedMigrationPlan(target, plan.report.reportDigest),
    /Opening balance totals do not match/u,
  );
});

test("database import is idempotent by reviewed digest and performs no writes on replay", async () => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(
    await fixture("qbx-mapping.json"), metadataCatalog, accountCatalog,
  );
  const plan = buildMigrationPlan(source, mapping);
  let began = false;
  const statements: string[] = [];
  const database: ImportDatabase = {
    begin: async () => { began = true; },
    commit: async () => undefined,
    rollback: async () => undefined,
    close: async () => undefined,
    execute: async (sql, parameters = []) => {
      assert.equal((sql.match(/\?/gu) ?? []).length, parameters.length, sql);
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
  assert.equal(result.counts.metadata, 1);
  assert.equal(began, false);
  assert.equal(statements.length, 2);
});

test("database import emits principal-scoped current multi-leg ledger and currency topology writes", async () => {
  const source = validateSource({
    schema: 1,
    framework: "esx",
    records: [{
      identifier: "license:current-schema-import",
      character: "ESX-CURRENT-001",
      firstname: "Current",
      lastname: "Schema",
      accounts: { money: 100, bank: 200 },
      metadata: { hunger: 45 },
    }],
  });
  const mapping = validateMapping({
    schema: 1,
    framework: "esx",
    fields: {
      userId: "identifier",
      characterId: "character",
      firstName: "firstname",
      lastName: "lastname",
      money: {
        cash: "accounts.money",
        bank: "accounts.bank",
      },
      metadata: "metadata",
    },
    compatibilityMetadata: {
      catalogDigest: metadataCatalog.digest,
      mappingIds: ["esx.hunger"],
    },
  }, metadataCatalog, accountCatalog);
  const plan = buildMigrationPlan(source, mapping);
  const statements: string[] = [];
  const metadataParameters: Array<readonly unknown[]> = [];
  let transactionActive = false;
  let committed = false;
  const database: ImportDatabase = {
    begin: async () => { transactionActive = true; },
    commit: async () => { committed = true; transactionActive = false; },
    rollback: async () => { transactionActive = false; },
    close: async () => undefined,
    execute: async (sql, parameters = []) => {
      assert.equal((sql.match(/\?/gu) ?? []).length, parameters.length, sql);
      statements.push(sql);
      if (sql.includes("INSERT INTO synex_compatibility_metadata")) {
        assert.equal(transactionActive, true);
        assert.equal(committed, false);
        metadataParameters.push(parameters);
      }
      if (sql.includes("information_schema.tables")) {
        return {
          rows: parameters.map((table) => ({ table_name: table })),
          insertId: 0,
          affectedRows: parameters.length,
        };
      }
      if (sql.includes("SELECT state FROM synex_legacy_imports")) {
        return { rows: [], insertId: 0, affectedRows: 0 };
      }
      if (sql.includes("SELECT public_id, minor_unit, status FROM synex_currencies")) {
        return { rows: [], insertId: 0, affectedRows: 0 };
      }
      if (sql.includes("SELECT account.public_id, account.account_role")) {
        return { rows: [{}], insertId: 0, affectedRows: 1 };
      }
      if (sql.includes("AS cutoff_transaction_id") && sql.includes("model.model_version")) {
        return {
          rows: [{
            currency_id: "1", model_version: 1, cutoff_transaction_id: "1", cutoff_entry_id: "2",
            transaction_count: "1", entry_count: "2", account_count: "3",
            total_entry_sum_minor: "0", total_debit_minor: "1", total_credit_minor: "1",
            minted_minor: "0", burned_minor: "0", total_booked_minor: "1", active_held_minor: "0",
            transaction_sum_violation_count: "0", snapshot_drift_count: "0",
            negative_asset_count: "0", reserved_exceeds_booked_count: "0", invalid_hold_count: "0",
            refund_limit_violation_count: "0", invalid_reversal_count: "0",
            invalid_topology_count: "0", outbox_problem_count: "0", grant_problem_count: "0",
            orphan_transaction_count: "0", sequence_problem_count: "0", idempotency_problem_count: "0",
          }],
          insertId: 0,
          affectedRows: 1,
        };
      }
      return { rows: [], insertId: 1, affectedRows: 1 };
    },
  };

  const result = await importReviewedMigrationPlan(plan, database, false);
  const sql = statements.join("\n");
  assert.equal(result.counts.accounts, 2);
  assert.equal(result.counts.ledgerTransactions, 2);
  assert.equal(result.counts.metadata, 1);
  assert.equal(committed, true);
  assert.deepEqual(metadataParameters, [[
    "esx",
    plan.bundle.characters[0]?.id,
    "needs.hunger",
    "45",
  ]]);
  assert.match(sql, /caller_principal_kind, caller_principal_ref/u);
  assert.match(sql, /reason_code, source_resource/u);
  assert.match(sql, /'synex_accounts\.opening_balance'/u);
  assert.match(sql, /INSERT INTO synex_ledger_entries/u);
  assert.match(sql, /'multi_leg', 2, 'opening_balance'/u);
  assert.match(sql, /INSERT INTO synex_currency_system_topology/u);
  assert.match(sql, /SELECT \?, id, \?, \?, 0, 'active'/u);
  assert.match(sql, /mint_account_id/u);
  assert.match(sql, /burn_account_id/u);
});

test("database import rejects non-MySQL and database-less connection URLs before connecting", async () => {
  await assert.rejects(connectImportDatabase("https://db.example.invalid/synex"), /must use mysql/u);
  await assert.rejects(connectImportDatabase("mysql://user:secret@db.example.invalid"), /target database/u);
  await assert.rejects(
    connectImportDatabase("mysql://user:secret@db.example.invalid/synex?multipleStatements=true"),
    /must not override multipleStatements/u,
  );
});

test("group importer resolves existing native targets and never invents organizations or grades", async () => {
  const importer = await readFile(
    join(process.cwd(), "tools", "migrator", "src", "importer.ts"),
    "utf8",
  );
  assert.match(importer, /FROM synex_group_types AS group_type/u);
  assert.match(importer, /INNER JOIN synex_group_organization_profiles AS organization/u);
  assert.match(importer, /INNER JOIN synex_group_grades AS grade/u);
  assert.match(importer, /INSERT INTO synex_group_membership_profiles/u);
  assert.match(importer, /INSERT INTO synex_group_primary_memberships_by_type/u);
  assert.doesNotMatch(importer, /INSERT INTO synex_groups\b/u);
  assert.doesNotMatch(importer, /INSERT INTO synex_group_grades\b/u);
  assert.doesNotMatch(importer, /`grade_\$\{membership\.grade\}`/u);
});

test("apply requires exact target confirmation, never overwrites, and emits three bounded artifacts", async (context) => {
  const source = validateSource(await fixture("qbx-source.json"));
  const mapping = validateMapping(
    await fixture("qbx-mapping.json"), metadataCatalog, accountCatalog,
  );
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
  assert.match(output.join("\n"), /"identityEvidence"/u);
  assert.doesNotMatch(output.join("\n"), /fixture-license-b/u);
  assert.deepEqual(errors, []);
});

test("planner and importer share bounded capacity and planner inputs reject symlinks", async (context) => {
  assert.throws(() => validateSource({
    schema: 1,
    framework: "qb",
    records: Array.from({ length: 10_001 }, () => ({})),
  }), /at most 10000 entries/u);

  const root = await mkdtemp(join(tmpdir(), "synex-migration-symlink-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const source = join(root, "source.json");
  const mapping = join(root, "mapping.json");
  const linked = join(root, "linked-source.json");
  await writeFile(source, await readFile(join(fixtureRoot, "qbx-source.json"), "utf8"), "utf8");
  await writeFile(mapping, await readFile(join(fixtureRoot, "qbx-mapping.json"), "utf8"), "utf8");
  try {
    await symlink(source, linked, "file");
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? error.code : "";
    if (code === "EPERM") {
      context.skip("File symlinks require Windows developer mode on this runner.");
      return;
    }
    throw error;
  }
  await assert.rejects(loadMigrationPlan(linked, mapping, "qbx"), /non-symlink file/u);
});

test("source digest is semantic and identity evidence exposes no raw legacy identifier", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-migration-semantic-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const sourceValue = await fixture("qbx-source.json");
  const mappingPath = join(root, "mapping.json");
  const sourceA = join(root, "source-a.json");
  const sourceB = join(root, "source-b.json");
  await writeFile(mappingPath, await readFile(join(fixtureRoot, "qbx-mapping.json"), "utf8"), "utf8");
  await writeFile(sourceA, JSON.stringify(sourceValue), "utf8");
  await writeFile(sourceB, canonicalJson(sourceValue), "utf8");

  const first = await loadMigrationPlan(sourceA, mappingPath, "qbx");
  const second = await loadMigrationPlan(sourceB, mappingPath, "qbx");
  assert.equal(first.report.sourceDigest, second.report.sourceDigest);
  assert.equal("credentialsCaptured" in first.report.identity, false);
  assert.equal(first.report.identity.preservationPlan.credentialsCaptured, false);
  assert.doesNotMatch(canonicalJson(first.report), /fixture-license-b/u);
  assert.match(first.report.identity.evidenceDigest, /^[0-9a-f]{64}$/u);
});

test("group migration is bound to reviewed runtime mappings and unknown jobs, gangs, and grades block apply", () => {
  const source = validateSource({
    schema: 1,
    framework: "qb",
    records: [{
      license: "license:groups-one", citizenid: "GROUPS-ONE", first: "One", last: "Test",
      cash: 0, bank: 0, job: { name: "police", grade: 1 }, gang: { name: "ballas", grade: 1 },
    }, {
      license: "license:groups-two", citizenid: "GROUPS-TWO", first: "Two", last: "Test",
      cash: 0, bank: 0, job: { name: "ambulance", grade: 1 }, gang: { name: "vagos", grade: 1 },
    }],
  });
  const baseMapping = {
    schema: 1,
    framework: "qb",
    fields: {
      userId: "license", characterId: "citizenid", firstName: "first", lastName: "last",
      money: { cash: "cash", bank: "bank" },
      job: { name: "job.name", grade: "job.grade" },
      group: { name: "gang.name", grade: "gang.grade" },
    },
  };
  const groupCatalog = validateCompatibilityGroupCatalog({
    schema: 1,
    kind: "synex-compatibility-mappings",
    groups: [{
      id: "qb.job.police",
      version: "1.0.0",
      provider: "qb",
      legacyType: "job",
      legacyName: "police",
      nativeGroupKey: "public_safety",
      nativeGroupType: "job",
      grades: [{ legacyGrade: 1, gradeKey: "officer" }],
      bossRoles: [],
      dutySupported: true,
      dutyState: "active",
      status: "PARTIAL",
    }, {
      id: "qb.gang.ballas",
      version: "1.0.0",
      provider: "qb",
      legacyType: "gang",
      legacyName: "ballas",
      nativeGroupKey: "ballas",
      nativeGroupType: "gang",
      grades: [{ legacyGrade: 1, gradeKey: "member" }],
      bossRoles: [],
      dutySupported: false,
      status: "PARTIAL",
    }],
  });
  const reviewedMapping = {
    ...baseMapping,
    compatibilityGroups: {
      catalogDigest: groupCatalog.digest,
      mappingIds: ["qb.gang.ballas", "qb.job.police"],
    },
  };
  const unknown = buildMigrationPlan(
    source,
    validateMapping(reviewedMapping, metadataCatalog, accountCatalog, groupCatalog),
  );
  assert.equal(unknown.report.conflicts.some((issue) => issue.reason === "unknown_job_mapping"), true);
  assert.equal(unknown.report.conflicts.some((issue) => issue.reason === "unknown_gang_mapping"), true);
  assert.deepEqual(unknown.bundle.groups.map((entry) => ({
    mappingId: entry.mappingId,
    legacyType: entry.legacyType,
    legacyGrade: entry.legacyGrade,
    nativeGroupType: entry.nativeGroupType,
    nativeGroupKey: entry.nativeGroupKey,
    gradeKey: entry.gradeKey,
    primary: entry.primary,
  })), [{
    mappingId: "qb.gang.ballas",
    legacyType: "gang",
    legacyGrade: 1,
    nativeGroupType: "gang",
    nativeGroupKey: "ballas",
    gradeKey: "member",
    primary: true,
  }, {
    mappingId: "qb.job.police",
    legacyType: "job",
    legacyGrade: 1,
    nativeGroupType: "job",
    nativeGroupKey: "public_safety",
    gradeKey: "officer",
    primary: true,
  }]);
  assert.equal(unknown.report.groups.catalogDigest, groupCatalog.digest);
  assert.equal(unknown.report.groups.createsGroups, false);
  assert.equal(unknown.report.groups.createsGrades, false);

  const invalidGradeSource = validateSource({
    schema: 1,
    framework: "qb",
    records: [{
      license: "license:invalid-grade", citizenid: "INVALID-GRADE", first: "Grade", last: "Test",
      cash: 0, bank: 0, job: { name: "police", grade: 99 },
    }],
  });
  const invalidGrade = buildMigrationPlan(
    invalidGradeSource,
    validateMapping(reviewedMapping, metadataCatalog, accountCatalog, groupCatalog),
  );
  assert.equal(
    invalidGrade.report.conflicts.some((issue) => issue.reason === "unknown_grade_mapping"),
    true,
  );
  assert.equal(invalidGrade.bundle.groups.length, 0);
});
