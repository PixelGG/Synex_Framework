import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import type { Connection, ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';

const gate = liveDatabaseGate();
const domainDeletionTables = [
  'synex_domain_deletion_actions',
  'synex_domain_deletion_plans',
  'synex_domain_deletion_providers',
  'synex_domain_deletion_domains',
  'synex_domain_deletion_plan_owner_capacity',
  'synex_domain_deletion_plan_capacity',
] as const;

interface Fixture {
  domain: string;
  owner: string;
  providerOwner: string;
  providerName: string;
  requestHash: string;
  subjectId: string;
}

type ClaimResult =
  | { outcome: 'created'; planId: string }
  | { outcome: 'replay'; planId: string }
  | { outcome: 'capacity' };

function isSqlNullDefault(value: unknown): boolean {
  return value === null || String(value).toUpperCase() === 'NULL';
}

function normalizedSql(value: unknown): string {
  return String(value ?? '')
    .toLowerCase()
    .replaceAll('`', '')
    .replaceAll(/[\s()]/gu, '');
}

async function dropDomainDeletionTables(
  connection: Connection,
  expectedDatabaseName: string,
): Promise<void> {
  const [databaseRows] = await connection.query<RowDataPacket[]>(
    'SELECT DATABASE() AS database_name',
  );
  assert.equal(databaseRows.length, 1);
  assert.equal(String(databaseRows[0]?.database_name), expectedDatabaseName);
  assert.match(expectedDatabaseName, /^synex_test_[a-z0-9_]+$/u);
  for (const table of domainDeletionTables) {
    await connection.query(`DROP TABLE IF EXISTS \`${table}\``);
  }
}

async function claimPlan(
  connection: Connection,
  fixture: Fixture,
  idempotencyKey: string,
  candidatePlanId: string,
): Promise<ClaimResult> {
  await connection.beginTransaction();
  try {
    const [candidate] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_domain_deletion_plans
       (plan_id, domain_name, subject_id, requester_owner, idempotency_key,
        request_hash, request_context_json, reason, state)
       VALUES (?, ?, ?, ?, ?, ?, '{}', 'domain deletion live capacity fixture', 'pending')`,
      [
        candidatePlanId,
        fixture.domain,
        fixture.subjectId,
        fixture.owner,
        idempotencyKey,
        fixture.requestHash,
      ],
    );
    if (candidate.affectedRows === 0) {
      const [existingRows] = await connection.query<RowDataPacket[]>(
        `SELECT plan_id, request_hash FROM synex_domain_deletion_plans
         WHERE requester_owner = ? AND domain_name = ? AND idempotency_key = ?
         LIMIT 1 FOR UPDATE`,
        [fixture.owner, fixture.domain, idempotencyKey],
      );
      assert.equal(existingRows.length, 1);
      assert.equal(String(existingRows[0]?.request_hash), fixture.requestHash);
      const planId = String(existingRows[0]?.plan_id);
      await connection.commit();
      return { outcome: 'replay', planId };
    }
    assert.equal(candidate.affectedRows, 1);

    const [globalRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit, owner_limit
       FROM synex_domain_deletion_plan_capacity
       WHERE singleton_id = 1 FOR UPDATE`,
    );
    assert.equal(globalRows.length, 1);
    const globalCount = Number(globalRows[0]?.entry_count);
    const globalLimit = Number(globalRows[0]?.global_limit);
    const ownerLimit = Number(globalRows[0]?.owner_limit);
    await connection.query(
      `INSERT IGNORE INTO synex_domain_deletion_plan_owner_capacity
       (requester_owner, entry_count) VALUES (?, 0)`,
      [fixture.owner],
    );
    const [ownerRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count FROM synex_domain_deletion_plan_owner_capacity
       WHERE requester_owner = ? FOR UPDATE`,
      [fixture.owner],
    );
    assert.equal(ownerRows.length, 1);
    const ownerCount = Number(ownerRows[0]?.entry_count);
    assert.ok(Number.isSafeInteger(globalCount) && globalCount >= 0);
    assert.ok(Number.isSafeInteger(ownerCount) && ownerCount >= 0);
    if (globalCount >= globalLimit || ownerCount >= ownerLimit) {
      await connection.rollback();
      return { outcome: 'capacity' };
    }

    const [globalReserved] = await connection.query<ResultSetHeader>(
      `UPDATE synex_domain_deletion_plan_capacity
       SET entry_count = entry_count + 1
       WHERE singleton_id = 1 AND entry_count = ?
         AND entry_count < global_limit AND entry_count < 4294967295`,
      [globalCount],
    );
    const [ownerReserved] = await connection.query<ResultSetHeader>(
      `UPDATE synex_domain_deletion_plan_owner_capacity
       SET entry_count = entry_count + 1
       WHERE requester_owner = ? AND entry_count = ?
         AND entry_count < ? AND entry_count < 4294967295`,
      [fixture.owner, ownerCount, ownerLimit],
    );
    assert.equal(globalReserved.affectedRows, 1);
    assert.equal(ownerReserved.affectedRows, 1);
    await connection.commit();
    return { outcome: 'created', planId: candidatePlanId };
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function assertExactIndex(
  connection: Connection,
  tableName: string,
  indexName: string,
  expectedColumns: string[],
): Promise<void> {
  const [rows] = await connection.query<RowDataPacket[]>(
    `SELECT seq_in_index, column_name, non_unique, index_type, sub_part, collation
     FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?
     ORDER BY seq_in_index`,
    [tableName, indexName],
  );
  assert.deepEqual(rows.map((row) => String(row.column_name)), expectedColumns);
  assert.ok(rows.every((row) => Number(row.non_unique) === 1
    && String(row.index_type).toUpperCase() === 'BTREE'
    && row.sub_part === null && row.collation === 'A'));
}

test('live migration 027 owns bounded retained deletion plans under real concurrency', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const [primary, contender] = await Promise.all([
    openLiveDatabase(),
    openLiveDatabase(),
  ]);
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const fixture: Fixture = {
    domain: `domain_${suffix}`,
    owner: `synex_deletion_${suffix}`,
    providerOwner: `synex_provider_${suffix}`,
    providerName: 'records.v1',
    requestHash: 'a'.repeat(64),
    subjectId: `subject:${suffix}`,
  };
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let lockAcquired = false;
  try {
    assert.equal(primary.databaseName, contender.databaseName);
    assert.match(primary.databaseName, /^synex_test_[a-z0-9_]+$/u);
    const [lockRows] = await primary.connection.query<RowDataPacket[]>(
      "SELECT GET_LOCK(CONCAT('synex:test:domain-deletion-capacity:', DATABASE()), 60) AS acquired",
    );
    assert.equal(Number(lockRows[0]?.acquired), 1);
    lockAcquired = true;

    const migrations = await loadMigrations();
    migration = migrations.find((entry) =>
      entry.directory === 'core/synex_core/migrations'
        && entry.file === '027_domain_primitives.sql'
    );
    assert.ok(migration);
    await applyMigrations(primary.connection, migrations);
    await dropDomainDeletionTables(primary.connection, primary.databaseName);
    await applyMigrations(primary.connection, [migration]);

    const [freshTables] = await primary.connection.query<RowDataPacket[]>(
      `SELECT table_name, engine, table_collation
       FROM information_schema.tables
       WHERE table_schema = DATABASE() AND table_name IN (?, ?, ?, ?, ?, ?)
       ORDER BY table_name`,
      [...domainDeletionTables],
    );
    assert.deepEqual(
      freshTables.map((row) => String(row.table_name)).sort(),
      [...domainDeletionTables].sort(),
    );
    assert.ok(freshTables.every((row) =>
      String(row.engine).toUpperCase() === 'INNODB'
        && row.table_collation === 'utf8mb4_unicode_ci'
    ));

    await primary.connection.query(
      'ALTER TABLE synex_domain_deletion_plans DROP INDEX idx_domain_deletion_retention',
    );
    await primary.connection.query(
      `ALTER TABLE synex_domain_deletion_plans
       DROP CONSTRAINT chk_domain_deletion_plan_terminal`,
    );
    await primary.connection.query(
      'ALTER TABLE synex_domain_deletion_plans DROP COLUMN purge_after',
    );
    const legacyPlanId = randomUUID();
    await primary.connection.query(
      `INSERT INTO synex_domain_deletion_plans
       (plan_id, domain_name, subject_id, requester_owner, idempotency_key,
        request_hash, request_context_json, reason, state, completed_at)
       VALUES (?, ?, ?, ?, ?, ?, '{}', 'legacy terminal retention fixture', 'completed',
         TIMESTAMPADD(DAY, -31, CURRENT_TIMESTAMP(6)))`,
      [
        legacyPlanId,
        fixture.domain,
        fixture.subjectId,
        fixture.owner,
        randomUUID(),
        fixture.requestHash,
      ],
    );
    await primary.connection.query(
      `INSERT INTO synex_domain_deletion_actions
       (plan_id, action_index, provider_owner, provider_name,
        provider_schema_version, decision, metadata_json, state, completed_at)
       VALUES (?, 1, ?, ?, 1, 'retain', '{}', 'completed', CURRENT_TIMESTAMP(6))`,
      [legacyPlanId, fixture.providerOwner, fixture.providerName],
    );

    await applyMigrations(primary.connection, [migration]);

    const [capacityColumns] = await primary.connection.query<RowDataPacket[]>(
      `SELECT table_name, ordinal_position, column_name, data_type, column_type,
              character_maximum_length, character_set_name, collation_name,
              datetime_precision, is_nullable, column_default, extra
       FROM information_schema.columns
       WHERE table_schema = DATABASE()
         AND table_name IN (
           'synex_domain_deletion_plan_capacity',
           'synex_domain_deletion_plan_owner_capacity'
         )
       ORDER BY table_name, ordinal_position`,
    );
    const globalColumns = capacityColumns.filter((row) =>
      row.table_name === 'synex_domain_deletion_plan_capacity'
    );
    const ownerColumns = capacityColumns.filter((row) =>
      row.table_name === 'synex_domain_deletion_plan_owner_capacity'
    );
    assert.deepEqual(globalColumns.map((row) => String(row.column_name)), [
      'singleton_id', 'entry_count', 'global_limit', 'owner_limit', 'updated_at',
    ]);
    assert.deepEqual(ownerColumns.map((row) => String(row.column_name)), [
      'requester_owner', 'entry_count', 'created_at', 'updated_at',
    ]);
    assert.equal(String(globalColumns[0]?.data_type).toLowerCase(), 'tinyint');
    assert.match(String(globalColumns[0]?.column_type).toLowerCase(), /unsigned/u);
    assert.equal(globalColumns[0]?.is_nullable, 'NO');
    assert.ok(isSqlNullDefault(globalColumns[0]?.column_default));
    for (const [index, expectedDefault] of [[1, 0], [2, 10000], [3, 1000]] as const) {
      assert.equal(String(globalColumns[index]?.data_type).toLowerCase(), 'int');
      assert.match(String(globalColumns[index]?.column_type).toLowerCase(), /unsigned/u);
      assert.equal(globalColumns[index]?.is_nullable, 'NO');
      assert.equal(Number(globalColumns[index]?.column_default), expectedDefault);
    }
    assert.equal(String(globalColumns[4]?.data_type).toLowerCase(), 'datetime');
    assert.equal(Number(globalColumns[4]?.datetime_precision), 6);
    assert.equal(globalColumns[4]?.is_nullable, 'NO');
    assert.equal(normalizedSql(globalColumns[4]?.column_default), 'current_timestamp6');
    assert.equal(normalizedSql(globalColumns[4]?.extra), 'onupdatecurrent_timestamp6');
    assert.equal(String(ownerColumns[0]?.data_type).toLowerCase(), 'varchar');
    assert.equal(Number(ownerColumns[0]?.character_maximum_length), 64);
    assert.equal(ownerColumns[0]?.character_set_name, 'ascii');
    assert.equal(ownerColumns[0]?.collation_name, 'ascii_bin');
    assert.equal(ownerColumns[0]?.is_nullable, 'NO');
    assert.ok(isSqlNullDefault(ownerColumns[0]?.column_default));
    assert.equal(String(ownerColumns[1]?.data_type).toLowerCase(), 'int');
    assert.match(String(ownerColumns[1]?.column_type).toLowerCase(), /unsigned/u);
    assert.equal(Number(ownerColumns[1]?.column_default), 0);
    for (const index of [2, 3]) {
      assert.equal(String(ownerColumns[index]?.data_type).toLowerCase(), 'datetime');
      assert.equal(Number(ownerColumns[index]?.datetime_precision), 6);
      assert.equal(normalizedSql(ownerColumns[index]?.column_default), 'current_timestamp6');
    }
    assert.equal(String(ownerColumns[2]?.extra ?? ''), '');
    assert.equal(normalizedSql(ownerColumns[3]?.extra), 'onupdatecurrent_timestamp6');

    const [primaryKeys] = await primary.connection.query<RowDataPacket[]>(
      `SELECT table_name, column_name, seq_in_index, non_unique, index_type
       FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND table_name IN (
           'synex_domain_deletion_plan_capacity',
           'synex_domain_deletion_plan_owner_capacity'
         ) AND index_name = 'PRIMARY'
       ORDER BY table_name, seq_in_index`,
    );
    assert.deepEqual(primaryKeys.map((row) => [row.table_name, row.column_name]), [
      ['synex_domain_deletion_plan_capacity', 'singleton_id'],
      ['synex_domain_deletion_plan_owner_capacity', 'requester_owner'],
    ]);
    assert.ok(primaryKeys.every((row) => Number(row.non_unique) === 0
      && String(row.index_type).toUpperCase() === 'BTREE'));

    const [checks] = await primary.connection.query<RowDataPacket[]>(
      `SELECT constraint_name, check_clause
       FROM information_schema.check_constraints
       WHERE constraint_schema = DATABASE() AND constraint_name IN (
         'chk_domain_deletion_capacity_singleton',
         'chk_domain_deletion_capacity_limits',
         'chk_domain_deletion_owner_capacity_owner',
         'chk_domain_deletion_owner_capacity_count'
       ) ORDER BY constraint_name`,
    );
    assert.deepEqual(checks.map((row) => String(row.constraint_name)), [
      'chk_domain_deletion_capacity_limits',
      'chk_domain_deletion_capacity_singleton',
      'chk_domain_deletion_owner_capacity_count',
      'chk_domain_deletion_owner_capacity_owner',
    ]);
    const checkClauses = new Map(checks.map((row) => [
      String(row.constraint_name), normalizedSql(row.check_clause),
    ]));
    assert.match(checkClauses.get('chk_domain_deletion_capacity_singleton') ?? '', /singleton_id=1/u);
    const limitsCheck = checkClauses.get('chk_domain_deletion_capacity_limits') ?? '';
    assert.match(limitsCheck, /global_limitbetween1and10000/u);
    assert.match(limitsCheck, /owner_limitbetween1and1000/u);
    assert.match(limitsCheck, /owner_limit<=global_limit/u);
    assert.match(limitsCheck, /entry_count<=global_limit/u);
    assert.match(
      checkClauses.get('chk_domain_deletion_owner_capacity_count') ?? '',
      /entry_count<=1000/u,
    );
    assert.match(
      checkClauses.get('chk_domain_deletion_owner_capacity_owner') ?? '',
      /requester_ownerregexp/u,
    );

    const [purgeColumns] = await primary.connection.query<RowDataPacket[]>(
      `SELECT data_type, datetime_precision, is_nullable, column_default, extra
       FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'synex_domain_deletion_plans'
         AND column_name = 'purge_after'`,
    );
    assert.equal(purgeColumns.length, 1);
    assert.equal(String(purgeColumns[0]?.data_type).toLowerCase(), 'datetime');
    assert.equal(Number(purgeColumns[0]?.datetime_precision), 6);
    assert.equal(purgeColumns[0]?.is_nullable, 'YES');
    assert.ok(isSqlNullDefault(purgeColumns[0]?.column_default));
    assert.equal(String(purgeColumns[0]?.extra ?? ''), '');
    await assertExactIndex(
      primary.connection,
      'synex_domain_deletion_plans',
      'idx_domain_deletion_retention',
      ['purge_after', 'plan_id'],
    );
    await assertExactIndex(
      primary.connection,
      'synex_domain_deletion_actions',
      'idx_domain_deletion_action_provider_schema',
      [
        'provider_owner', 'provider_name', 'state', 'provider_schema_version',
        'plan_id', 'action_index',
      ],
    );

    const [retentionRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT TIMESTAMPDIFF(SECOND, completed_at, purge_after) AS retention_seconds,
              purge_after < CURRENT_TIMESTAMP(6) AS purge_due
       FROM synex_domain_deletion_plans WHERE plan_id = ?`,
      [legacyPlanId],
    );
    assert.equal(retentionRows.length, 1);
    assert.equal(Number(retentionRows[0]?.retention_seconds), 30 * 24 * 60 * 60);
    assert.equal(Number(retentionRows[0]?.purge_due), 1);
    const [backfilledCapacity] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT entry_count FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS global_count,
         (SELECT global_limit FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS global_limit,
         (SELECT owner_limit FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS owner_limit,
         (SELECT entry_count FROM synex_domain_deletion_plan_owner_capacity
          WHERE requester_owner = ?) AS owner_count`,
      [fixture.owner],
    );
    assert.equal(Number(backfilledCapacity[0]?.global_count), 1);
    assert.equal(Number(backfilledCapacity[0]?.owner_count), 1);
    assert.equal(Number(backfilledCapacity[0]?.global_limit), 10000);
    assert.equal(Number(backfilledCapacity[0]?.owner_limit), 1000);

    await primary.connection.beginTransaction();
    try {
      const [eligible] = await primary.connection.query<RowDataPacket[]>(
        `SELECT plan_id, requester_owner FROM synex_domain_deletion_plans
         FORCE INDEX (idx_domain_deletion_retention)
         WHERE purge_after IS NOT NULL AND purge_after <= CURRENT_TIMESTAMP(6)
           AND state IN ('completed', 'blocked', 'failed') AND plan_id = ?
         FOR UPDATE`,
        [legacyPlanId],
      );
      assert.equal(eligible.length, 1);
      const [globalRows] = await primary.connection.query<RowDataPacket[]>(
        `SELECT entry_count FROM synex_domain_deletion_plan_capacity
         WHERE singleton_id = 1 FOR UPDATE`,
      );
      const [ownerRows] = await primary.connection.query<RowDataPacket[]>(
        `SELECT entry_count FROM synex_domain_deletion_plan_owner_capacity
         WHERE requester_owner = ? FOR UPDATE`,
        [fixture.owner],
      );
      assert.equal(Number(globalRows[0]?.entry_count), 1);
      assert.equal(Number(ownerRows[0]?.entry_count), 1);
      const [purged] = await primary.connection.query<ResultSetHeader>(
        `DELETE FROM synex_domain_deletion_plans
         WHERE plan_id = ? AND purge_after IS NOT NULL
           AND purge_after <= CURRENT_TIMESTAMP(6)
           AND state IN ('completed', 'blocked', 'failed')`,
        [legacyPlanId],
      );
      const [globalReleased] = await primary.connection.query<ResultSetHeader>(
        `UPDATE synex_domain_deletion_plan_capacity SET entry_count = entry_count - 1
         WHERE singleton_id = 1 AND entry_count = 1`,
      );
      const [ownerReleased] = await primary.connection.query<ResultSetHeader>(
        `UPDATE synex_domain_deletion_plan_owner_capacity SET entry_count = entry_count - 1
         WHERE requester_owner = ? AND entry_count = 1`,
        [fixture.owner],
      );
      const [ownerRemoved] = await primary.connection.query<ResultSetHeader>(
        `DELETE FROM synex_domain_deletion_plan_owner_capacity
         WHERE requester_owner = ? AND entry_count = 0`,
        [fixture.owner],
      );
      assert.equal(purged.affectedRows, 1);
      assert.equal(globalReleased.affectedRows, 1);
      assert.equal(ownerReleased.affectedRows, 1);
      assert.equal(ownerRemoved.affectedRows, 1);
      await primary.connection.commit();
    } catch (error) {
      await primary.connection.rollback();
      throw error;
    }
    const [purgeResult] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_domain_deletion_plans WHERE plan_id = ?) AS plans,
         (SELECT COUNT(*) FROM synex_domain_deletion_actions WHERE plan_id = ?) AS actions,
         (SELECT entry_count FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS global_count,
         (SELECT COUNT(*) FROM synex_domain_deletion_plan_owner_capacity
          WHERE requester_owner = ?) AS owner_counters`,
      [legacyPlanId, legacyPlanId, fixture.owner],
    );
    assert.deepEqual([
      Number(purgeResult[0]?.plans),
      Number(purgeResult[0]?.actions),
      Number(purgeResult[0]?.global_count),
      Number(purgeResult[0]?.owner_counters),
    ], [0, 0, 0, 0]);

    await primary.connection.query(
      `UPDATE synex_domain_deletion_plan_capacity
       SET global_limit = 2, owner_limit = 2 WHERE singleton_id = 1`,
    );
    await Promise.all([
      primary.connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED'),
      contender.connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED'),
    ]);
    const replayKey = randomUUID();
    const sameKeyResults = await Promise.all([
      claimPlan(primary.connection, fixture, replayKey, randomUUID()),
      claimPlan(contender.connection, fixture, replayKey, randomUUID()),
    ]);
    assert.deepEqual(sameKeyResults.map((result) => result.outcome).sort(), [
      'created', 'replay',
    ]);
    const createdReplay = sameKeyResults.find((result) => result.outcome === 'created');
    const replayed = sameKeyResults.find((result) => result.outcome === 'replay');
    assert.ok(createdReplay && replayed);
    assert.equal(replayed.planId, createdReplay.planId);
    const [afterReplay] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_domain_deletion_plans
          WHERE requester_owner = ? AND domain_name = ? AND idempotency_key = ?) AS plans,
         (SELECT entry_count FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS global_count,
         (SELECT entry_count FROM synex_domain_deletion_plan_owner_capacity
          WHERE requester_owner = ?) AS owner_count`,
      [fixture.owner, fixture.domain, replayKey, fixture.owner],
    );
    assert.deepEqual([
      Number(afterReplay[0]?.plans),
      Number(afterReplay[0]?.global_count),
      Number(afterReplay[0]?.owner_count),
    ], [1, 1, 1]);

    const distinctResults = await Promise.all([
      claimPlan(primary.connection, fixture, randomUUID(), randomUUID()),
      claimPlan(contender.connection, fixture, randomUUID(), randomUUID()),
    ]);
    assert.deepEqual(distinctResults.map((result) => result.outcome).sort(), [
      'capacity', 'created',
    ]);
    const distinctWinner = distinctResults.find((result) => result.outcome === 'created');
    assert.ok(distinctWinner);
    const [afterDistinctRace] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_domain_deletion_plans
          WHERE requester_owner = ?) AS plans,
         (SELECT entry_count FROM synex_domain_deletion_plan_capacity
          WHERE singleton_id = 1) AS global_count,
         (SELECT entry_count FROM synex_domain_deletion_plan_owner_capacity
          WHERE requester_owner = ?) AS owner_count`,
      [fixture.owner, fixture.owner],
    );
    assert.deepEqual([
      Number(afterDistinctRace[0]?.plans),
      Number(afterDistinctRace[0]?.global_count),
      Number(afterDistinctRace[0]?.owner_count),
    ], [2, 2, 2]);

    await primary.connection.query(
      `INSERT INTO synex_domain_deletion_actions
       (plan_id, action_index, provider_owner, provider_name,
        provider_schema_version, decision, metadata_json, state)
       VALUES (?, 1, ?, ?, 1, 'delete', '{}', 'pending')`,
      [distinctWinner.planId, fixture.providerOwner, fixture.providerName],
    );
    const [explainRows] = await primary.connection.query<RowDataPacket[]>(
      `EXPLAIN SELECT action.plan_id, action.provider_schema_version
       FROM synex_domain_deletion_actions AS action
       FORCE INDEX (idx_domain_deletion_action_provider_schema)
       INNER JOIN synex_domain_deletion_plans AS plan ON plan.plan_id = action.plan_id
       WHERE plan.domain_name = ? AND action.provider_owner = ?
         AND action.provider_name = ? AND action.state = 'pending'
         AND plan.state IN ('pending', 'executing')
         AND action.provider_schema_version <> ?
       ORDER BY action.plan_id, action.action_index LIMIT 1`,
      [fixture.domain, fixture.providerOwner, fixture.providerName, 2],
    );
    const actionExplain = explainRows.find((row) => String(row.table) === 'action');
    assert.ok(actionExplain);
    assert.equal(actionExplain.key, 'idx_domain_deletion_action_provider_schema');
    assert.match(String(actionExplain.possible_keys), /idx_domain_deletion_action_provider_schema/u);
    assert.notEqual(String(actionExplain.type).toUpperCase(), 'ALL');
    assert.ok(Number(actionExplain.key_len) > 0);

    const [routines] = await primary.connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_027_domain_deletion_capacity'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    try {
      if (migration && lockAcquired) {
        await dropDomainDeletionTables(primary.connection, primary.databaseName);
        await applyMigrations(primary.connection, [migration]);
      }
    } finally {
      try {
        if (lockAcquired) {
          await primary.connection.query(
            "SELECT RELEASE_LOCK(CONCAT('synex:test:domain-deletion-capacity:', DATABASE()))",
          );
        }
      } finally {
        await Promise.allSettled([
          contender.connection.end(),
          primary.connection.end(),
        ]);
      }
    }
  }
});
