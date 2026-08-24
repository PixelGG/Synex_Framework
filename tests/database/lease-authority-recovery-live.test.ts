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

interface LocalLeaseRow extends RowDataPacket {
  fencing_token: string;
  lease_name: string;
  owner_id: string;
  lease_authority_kind: string | null;
}

interface CapacitySnapshot {
  global: number;
  admission: number;
  other: number;
  session: number;
}

type LocalLeaseRecoveryResult =
  | { status: 'committed'; selected: number; retired: number }
  | { status: 'mismatch'; selected: number; retired: number }
  | { status: 'residual'; selected: number; retired: number }
  | { status: 'over-bound'; selected: number; retired: 0 };

async function recoverLocalConnectionLeases(
  connection: Connection,
  instanceId: string,
  bootId: string,
  maximumConnectionLeases: number,
  afterSelection: (() => Promise<void>) | undefined = undefined,
): Promise<LocalLeaseRecoveryResult> {
  const ownerLowerBound = `${instanceId}:`;
  const ownerUpperBound = `${instanceId};`;
  await connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.beginTransaction();
  try {
    const [authority] = await connection.query<RowDataPacket[]>(
      `SELECT boot_id FROM synex_instance_boots
       WHERE instance_id = ? AND boot_id = ? FOR UPDATE`,
      [instanceId, bootId],
    );
    assert.equal(authority.length, 1);
    const leaseRows: LocalLeaseRow[] = [];
    const seen = new Set<string>();
    for (const kind of ['admission', 'session'] as const) {
      const remaining = maximumConnectionLeases + 1 - leaseRows.length;
      const [kindRows] = await connection.query<LocalLeaseRow[]>(
        `SELECT lease_name, owner_id, CAST(fencing_token AS CHAR) AS fencing_token,
                lease_authority_kind
         FROM synex_cluster_leases
           FORCE INDEX (idx_cluster_leases_authority_owner)
         WHERE lease_authority_kind = ? AND terminal_compaction_at IS NULL
           AND owner_id >= ? AND owner_id < ?
         ORDER BY owner_id ASC, lease_name ASC
         LIMIT ? FOR UPDATE`,
        [kind, ownerLowerBound, ownerUpperBound, remaining],
      );
      assert.ok(kindRows.length <= remaining);
      leaseRows.push(...kindRows);
      if (leaseRows.length > maximumConnectionLeases) {
        await connection.rollback();
        return { status: 'over-bound', selected: leaseRows.length, retired: 0 };
      }
    }
    for (const lease of leaseRows) {
      assert.ok(lease.owner_id >= ownerLowerBound && lease.owner_id < ownerUpperBound);
      assert.ok(lease.lease_authority_kind === 'session'
        || lease.lease_authority_kind === 'admission');
      assert.match(lease.lease_name, new RegExp(`^${lease.lease_authority_kind}:`, 'u'));
      assert.match(String(lease.fencing_token), /^[1-9][0-9]{0,19}$/u);
      if (String(lease.fencing_token).length === 20) {
        assert.ok(String(lease.fencing_token) <= '18446744073709551615');
      }
      assert.equal(seen.has(lease.lease_name), false);
      seen.add(lease.lease_name);
    }
    if (afterSelection) await afterSelection();
    let retiredCount = 0;
    if (leaseRows.length > 0) {
      const placeholders = leaseRows.map(() => '?').join(',');
      const [retired] = await connection.query<ResultSetHeader>(
        `UPDATE synex_cluster_leases FORCE INDEX (PRIMARY)
         SET owner_id = 'retired',
             fencing_token = CASE
               WHEN fencing_token < 18446744073709551615 THEN fencing_token + 1
               ELSE fencing_token
             END,
             expires_at = CURRENT_TIMESTAMP(6),
             terminal_compaction_at = CURRENT_TIMESTAMP(6)
         WHERE terminal_compaction_at IS NULL
           AND lease_name IN (${placeholders})`,
        leaseRows.map((row) => row.lease_name),
      );
      retiredCount = retired.affectedRows;
      if (retiredCount > maximumConnectionLeases || retiredCount !== leaseRows.length) {
        await connection.rollback();
        return {
          status: 'mismatch',
          selected: leaseRows.length,
          retired: retiredCount,
        };
      }
    }
    for (const kind of ['admission', 'session'] as const) {
      const [residual] = await connection.query<RowDataPacket[]>(
        `SELECT lease_name FROM synex_cluster_leases
           FORCE INDEX (idx_cluster_leases_authority_owner)
         WHERE lease_authority_kind = ? AND terminal_compaction_at IS NULL
           AND owner_id >= ? AND owner_id < ?
         ORDER BY owner_id ASC, lease_name ASC LIMIT 1 FOR UPDATE`,
        [kind, ownerLowerBound, ownerUpperBound],
      );
      assert.ok(residual.length <= 1);
      if (residual.length > 0) {
        await connection.rollback();
        return {
          status: 'residual',
          selected: leaseRows.length,
          retired: retiredCount,
        };
      }
    }
    await connection.commit();
    return {
      status: 'committed',
      selected: leaseRows.length,
      retired: retiredCount,
    };
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function capacitySnapshot(connection: Connection): Promise<CapacitySnapshot> {
  const [globalRows] = await connection.query<RowDataPacket[]>(
    `SELECT entry_count FROM synex_cluster_lease_capacity
     WHERE singleton_id = 1`,
  );
  const [kindRows] = await connection.query<RowDataPacket[]>(
    `SELECT lease_capacity_kind, entry_count
     FROM synex_cluster_lease_kind_capacity
     WHERE lease_capacity_kind IN ('session', 'admission', 'other')`,
  );
  assert.equal(globalRows.length, 1);
  const byKind = new Map(kindRows.map((row) => [
    String(row.lease_capacity_kind), Number(row.entry_count),
  ]));
  assert.equal(byKind.size, 3);
  return {
    global: Number(globalRows[0]?.entry_count),
    admission: byKind.get('admission') ?? -1,
    other: byKind.get('other') ?? -1,
    session: byKind.get('session') ?? -1,
  };
}

async function compactTerminalFixtures(
  connection: Connection,
  leaseNames: readonly [string, string],
): Promise<void> {
  await connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.beginTransaction();
  try {
    const [rows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name, lease_capacity_kind
       FROM synex_cluster_leases
         FORCE INDEX (idx_cluster_leases_terminal_compaction)
       WHERE lease_name IN (?, ?)
         AND terminal_compaction_at <= CURRENT_TIMESTAMP(6)
         AND lease_capacity_kind IS NOT NULL
       ORDER BY terminal_compaction_at ASC, lease_name ASC FOR UPDATE`,
      [...leaseNames],
    );
    assert.equal(rows.length, 2);
    const releaseByKind = new Map<string, number>();
    for (const row of rows) {
      const kind = String(row.lease_capacity_kind);
      assert.ok(kind === 'session' || kind === 'admission');
      releaseByKind.set(kind, (releaseByKind.get(kind) ?? 0) + 1);
    }
    const [globalRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1 FOR UPDATE`,
    );
    assert.equal(globalRows.length, 1);
    const globalCount = Number(globalRows[0]?.entry_count);
    assert.ok(globalCount >= rows.length);
    const kindCounts = new Map<string, number>();
    for (const kind of [...releaseByKind.keys()].sort()) {
      const [kindRows] = await connection.query<RowDataPacket[]>(
        `SELECT entry_count FROM synex_cluster_lease_kind_capacity
         WHERE lease_capacity_kind = ? FOR UPDATE`,
        [kind],
      );
      assert.equal(kindRows.length, 1);
      const count = Number(kindRows[0]?.entry_count);
      assert.ok(count >= (releaseByKind.get(kind) ?? 0));
      kindCounts.set(kind, count);
    }
    const [deleted] = await connection.query<ResultSetHeader>(
      `DELETE FROM synex_cluster_leases
       WHERE lease_name IN (?, ?)
         AND terminal_compaction_at <= CURRENT_TIMESTAMP(6)
         AND lease_capacity_kind IS NOT NULL`,
      [...leaseNames],
    );
    assert.equal(deleted.affectedRows, rows.length);
    const [globalReleased] = await connection.query<ResultSetHeader>(
      `UPDATE synex_cluster_lease_capacity
       SET entry_count = entry_count - ?
       WHERE singleton_id = 1 AND entry_count = ? AND entry_count >= ?`,
      [rows.length, globalCount, rows.length],
    );
    assert.equal(globalReleased.affectedRows, 1);
    for (const [kind, releaseCount] of releaseByKind) {
      const [kindReleased] = await connection.query<ResultSetHeader>(
        `UPDATE synex_cluster_lease_kind_capacity
         SET entry_count = entry_count - ?
         WHERE lease_capacity_kind = ? AND entry_count = ? AND entry_count >= ?`,
        [releaseCount, kind, kindCounts.get(kind), releaseCount],
      );
      assert.equal(kindReleased.affectedRows, 1);
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

test('live migration 023 proves bounded authority retirement and stale-session index use', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const suffix = randomUUID();
  const leaseNames = {
    session: `session:${suffix}:expired`,
    admission: `admission:${suffix}`,
    active: `session:${suffix}:active`,
    reacquired: `admission:${suffix}:reacquired`,
    generic: `generic:${suffix}`,
  };
  const userId = randomUUID();
  const instanceId = randomUUID();
  const sessionId = randomUUID();
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    const migration = migrations.find(
      (entry) => entry.file === '023_lease_authority_recovery.sql',
    );
    assert.ok(migration);
    await applyMigrations(connection, [migration]);

    const [columns] = await connection.query<RowDataPacket[]>(
      `SELECT data_type, character_maximum_length, character_set_name, collation_name,
              is_nullable, extra, generation_expression
       FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
         AND column_name = 'lease_authority_kind'`,
    );
    assert.equal(columns.length, 1);
    const column = columns[0];
    assert.equal(String(column?.data_type).toLowerCase(), 'varchar');
    assert.equal(Number(column?.character_maximum_length), 10);
    assert.equal(String(column?.character_set_name), 'ascii');
    assert.equal(String(column?.collation_name), 'ascii_bin');
    assert.equal(String(column?.is_nullable), 'YES');
    assert.match(String(column?.extra), /STORED GENERATED/iu);
    const generation = String(column?.generation_expression).toLowerCase()
      .replaceAll('`', '').replaceAll(' ', '').replaceAll('(', '').replaceAll(')', '')
      .replace(/_(?:utf8mb4|utf8mb3|utf8|ascii|latin1)/gu, '');
    const expectedGeneration = "casewhenleftlease_name,8='session:'then'session'"
      + "whenleftlease_name,10='admission:'then'admission'elsenullend";
    assert.equal(generation, expectedGeneration);

    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_expiry',
    );
    try {
      await connection.query(
        `ALTER TABLE synex_cluster_leases
         MODIFY COLUMN lease_authority_kind VARCHAR(10)
           CHARACTER SET ascii COLLATE ascii_bin
           GENERATED ALWAYS AS (
             CASE
               WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
               WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
               WHEN LEFT(lease_name, 8) = 'generic:' THEN 'session'
               ELSE NULL
             END
           ) STORED`,
      );
      await assert.rejects(
        applyMigrations(connection, [migration]),
        /lease authority definition verification failed/iu,
      );
    } finally {
      await connection.query(
        `ALTER TABLE synex_cluster_leases
         MODIFY COLUMN lease_authority_kind VARCHAR(10)
           CHARACTER SET ascii COLLATE ascii_bin
           GENERATED ALWAYS AS (
             CASE
               WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
               WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
               ELSE NULL
             END
           ) STORED`,
      );
      await applyMigrations(connection, [migration]);
    }

    const expectedIndexes = new Map<string, string[]>([
      ['idx_cluster_leases_authority_expiry', [
        'lease_authority_kind', 'terminal_compaction_at', 'expires_at', 'lease_name',
      ]],
      ['idx_sessions_open_heartbeat_expiry', [
        'closed_at', 'last_seen_at', 'id', 'server_instance_id',
      ]],
    ]);
    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT index_name, seq_in_index, column_name, non_unique, index_type,
              sub_part, collation
       FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND index_name IN ('idx_cluster_leases_authority_expiry',
                            'idx_sessions_open_heartbeat_expiry')
       ORDER BY index_name, seq_in_index`,
    );
    for (const [indexName, names] of expectedIndexes) {
      const rows = indexes.filter((row) => row.index_name === indexName);
      assert.deepEqual(rows.map((row) => String(row.column_name)), names);
      assert.ok(rows.every((row) => Number(row.non_unique) === 1));
      assert.ok(rows.every((row) => String(row.index_type).toUpperCase() === 'BTREE'));
      assert.ok(rows.every((row) => row.sub_part === null && row.collation === 'A'));
    }

    await connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
       VALUES
         (?, 'old-session', 1, TIMESTAMPADD(SECOND, -30, CURRENT_TIMESTAMP(6)), NULL),
         (?, 'old-admission', 1, TIMESTAMPADD(SECOND, -20, CURRENT_TIMESTAMP(6)), NULL),
         (?, 'live-session', 2, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, 'reacquired-admission', 3, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, 'generic-owner', 4, TIMESTAMPADD(SECOND, -60, CURRENT_TIMESTAMP(6)), NULL)`,
      [leaseNames.session, leaseNames.admission, leaseNames.active,
        leaseNames.reacquired, leaseNames.generic],
    );

    for (const kind of ['session', 'admission']) {
      await connection.beginTransaction();
      try {
        const [candidates] = await connection.query<RowDataPacket[]>(
          `SELECT lease_name FROM synex_cluster_leases
           FORCE INDEX (idx_cluster_leases_authority_expiry)
           WHERE lease_authority_kind = ? AND terminal_compaction_at IS NULL
             AND expires_at <= CURRENT_TIMESTAMP(6)
           ORDER BY expires_at ASC, lease_name ASC LIMIT 1 FOR UPDATE`,
          [kind],
        );
        assert.equal(candidates.length, 1);
        const candidate = String(candidates[0]?.lease_name);
        const [retired] = await connection.query<ResultSetHeader>(
          `UPDATE synex_cluster_leases
           SET owner_id = 'retired', fencing_token = fencing_token + 1,
               terminal_compaction_at = CURRENT_TIMESTAMP(6)
           WHERE lease_authority_kind = ? AND terminal_compaction_at IS NULL
             AND expires_at <= CURRENT_TIMESTAMP(6) AND lease_name = ?`,
          [kind, candidate],
        );
        assert.equal(retired.affectedRows, 1);
        await connection.commit();
      } catch (error) {
        await connection.rollback();
        throw error;
      }
    }
    const [leaseRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name, owner_id, terminal_compaction_at
       FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?) ORDER BY lease_name`,
      [leaseNames.session, leaseNames.admission, leaseNames.active,
        leaseNames.reacquired, leaseNames.generic],
    );
    const byName = new Map(leaseRows.map((row) => [String(row.lease_name), row]));
    assert.equal(String(byName.get(leaseNames.session)?.owner_id), 'retired');
    assert.equal(String(byName.get(leaseNames.admission)?.owner_id), 'retired');
    assert.notEqual(byName.get(leaseNames.session)?.terminal_compaction_at, null);
    assert.notEqual(byName.get(leaseNames.admission)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.active)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.reacquired)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.generic)?.terminal_compaction_at, null);

    const [compacted] = await connection.query<ResultSetHeader>(
      `DELETE FROM synex_cluster_leases
       WHERE terminal_compaction_at <= CURRENT_TIMESTAMP(6)
       ORDER BY terminal_compaction_at ASC, lease_name ASC LIMIT 1`,
    );
    assert.equal(compacted.affectedRows, 1);
    const [survivors] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name FROM synex_cluster_leases WHERE lease_name IN (?, ?, ?)`,
      [leaseNames.active, leaseNames.reacquired, leaseNames.generic],
    );
    assert.equal(survivors.length, 3);

    await connection.query(
      `INSERT INTO synex_users (id, metadata_json) VALUES (?, '{}')`,
      [userId],
    );
    await connection.query(
      `INSERT INTO synex_instances
       (instance_id, name, started_at, heartbeat_at, status, version)
       VALUES (?, 'lease-023-live', TIMESTAMPADD(MINUTE, -10, CURRENT_TIMESTAMP(6)),
               TIMESTAMPADD(MINUTE, -10, CURRENT_TIMESTAMP(6)), 'stale', 1)`,
      [instanceId],
    );
    await connection.query(
      `INSERT INTO synex_sessions
       (id, user_id, server_instance_id, source_value, source_generation, state,
        connected_at, last_seen_at, version)
       VALUES (?, ?, ?, 23023, 1, 'SELECTING_CHARACTER',
               TIMESTAMPADD(MINUTE, -10, CURRENT_TIMESTAMP(6)),
               TIMESTAMPADD(MINUTE, -10, CURRENT_TIMESTAMP(6)), 1)`,
      [sessionId, userId, instanceId],
    );
    const [plan] = await connection.query<RowDataPacket[]>(
      `EXPLAIN SELECT stale_session.id
       FROM synex_sessions AS stale_session
         FORCE INDEX (idx_sessions_open_heartbeat_expiry)
       INNER JOIN synex_instances AS stale_instance
         ON stale_instance.instance_id = stale_session.server_instance_id
       WHERE stale_session.closed_at IS NULL AND stale_instance.status = 'stale'
         AND stale_session.last_seen_at < TIMESTAMPADD(SECOND, -30, CURRENT_TIMESTAMP(6))
       ORDER BY stale_session.last_seen_at ASC, stale_session.id ASC
       LIMIT 32 FOR UPDATE`,
    );
    const sessionPlan = plan.find((row) => String(row.table) === 'stale_session');
    assert.ok(sessionPlan);
    assert.equal(String(sessionPlan.key), 'idx_sessions_open_heartbeat_expiry');

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_023_lease_authority_recovery'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    await connection.query('DELETE FROM synex_sessions WHERE id = ?', [sessionId]);
    await connection.query('DELETE FROM synex_instances WHERE instance_id = ?', [instanceId]);
    await connection.query('DELETE FROM synex_users WHERE id = ?', [userId]);
    await connection.query(
      'DELETE FROM synex_cluster_leases WHERE lease_name IN (?, ?, ?, ?, ?)',
      [leaseNames.session, leaseNames.admission, leaseNames.active,
        leaseNames.reacquired, leaseNames.generic],
    );
    await connection.end();
  }
});

test('live migration 026 installs the exact bounded local authority queue index', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const suffix = randomUUID().replaceAll('-', '');
  const instanceId = `plan_${suffix.slice(0, 20)}`;
  const leaseNames = [
    `admission:${suffix}:plan`,
    `session:${suffix}:plan`,
  ] as const;
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let authorityMigration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let authorityDefinitionNeedsRestore = false;
  let indexUsabilityRestoreSql: string | undefined;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    authorityMigration = migrations.find(
      (entry) => entry.file === '023_lease_authority_recovery.sql',
    );
    migration = migrations.find(
      (entry) => entry.file === '026_lease_authority_owner_index.sql',
    );
    assert.ok(authorityMigration);
    assert.ok(migration);
    await applyMigrations(connection, [migration]);

    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT seq_in_index, column_name, non_unique, index_type, sub_part, collation
       FROM information_schema.statistics
       WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
         AND index_name = 'idx_cluster_leases_authority_owner'
       ORDER BY seq_in_index`,
    );
    assert.deepEqual(
      indexes.map((row) => String(row.column_name)),
      ['lease_authority_kind', 'terminal_compaction_at', 'owner_id', 'lease_name'],
    );
    assert.ok(indexes.every((row) => Number(row.non_unique) === 1));
    assert.ok(indexes.every((row) => String(row.index_type).toUpperCase() === 'BTREE'));
    assert.ok(indexes.every((row) => row.sub_part === null && row.collation === 'A'));

    const [usabilityColumns] = await connection.query<RowDataPacket[]>(
      `SELECT UPPER(column_name) AS column_name
       FROM information_schema.columns
       WHERE LOWER(table_schema) = 'information_schema'
         AND UPPER(table_name) = 'STATISTICS'
         AND UPPER(column_name) IN ('IGNORED', 'IS_VISIBLE')`,
    );
    const usabilityNames = new Set(
      usabilityColumns.map((row) => String(row.column_name).toUpperCase()),
    );
    let indexUsabilityColumn: 'IGNORED' | 'IS_VISIBLE';
    let indexUsabilityExpected: 'NO' | 'YES';
    let makeIndexUnusableSql: string;
    if (usabilityNames.has('IGNORED')) {
      indexUsabilityColumn = 'IGNORED';
      indexUsabilityExpected = 'NO';
      makeIndexUnusableSql =
        'ALTER TABLE synex_cluster_leases ALTER INDEX idx_cluster_leases_authority_owner IGNORED';
      indexUsabilityRestoreSql =
        'ALTER TABLE synex_cluster_leases ALTER INDEX idx_cluster_leases_authority_owner NOT IGNORED';
    } else if (usabilityNames.has('IS_VISIBLE')) {
      indexUsabilityColumn = 'IS_VISIBLE';
      indexUsabilityExpected = 'YES';
      makeIndexUnusableSql =
        'ALTER TABLE synex_cluster_leases ALTER INDEX idx_cluster_leases_authority_owner INVISIBLE';
      indexUsabilityRestoreSql =
        'ALTER TABLE synex_cluster_leases ALTER INDEX idx_cluster_leases_authority_owner VISIBLE';
    } else {
      assert.fail('supported database exposes neither IGNORED nor IS_VISIBLE index metadata');
    }

    await connection.query(makeIndexUnusableSql);
    await assert.rejects(connection.query(
      `SELECT lease_name FROM synex_cluster_leases
         FORCE INDEX (idx_cluster_leases_authority_owner)
       WHERE lease_authority_kind = 'session' LIMIT 1`,
    ));
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /lease authority owner index usability verification failed/iu,
    );
    await connection.query(indexUsabilityRestoreSql);
    indexUsabilityRestoreSql = undefined;
    await applyMigrations(connection, [migration]);
    const [usableIndexes] = await connection.query<RowDataPacket[]>(
      `SELECT DISTINCT UPPER(${indexUsabilityColumn}) AS usability
       FROM information_schema.statistics
       WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
         AND index_name = 'idx_cluster_leases_authority_owner'`,
    );
    assert.deepEqual(
      usableIndexes.map((row) => String(row.usability).toUpperCase()),
      [indexUsabilityExpected],
    );

    await connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
       VALUES
         (?, ?, 1, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 1, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL)`,
      [leaseNames[0], `${instanceId}:admission`, leaseNames[1], `${instanceId}:session`],
    );
    for (const kind of ['admission', 'session']) {
      const [plan] = await connection.query<RowDataPacket[]>(
        `EXPLAIN SELECT lease_name, owner_id, CAST(fencing_token AS CHAR) AS fencing_token,
                        lease_authority_kind
         FROM synex_cluster_leases FORCE INDEX (idx_cluster_leases_authority_owner)
         WHERE lease_authority_kind = ? AND terminal_compaction_at IS NULL
           AND owner_id >= ? AND owner_id < ?
         ORDER BY owner_id ASC, lease_name ASC LIMIT 3 FOR UPDATE`,
        [kind, `${instanceId}:`, `${instanceId};`],
      );
      assert.equal(plan.length, 1);
      assert.equal(String(plan[0]?.key), 'idx_cluster_leases_authority_owner');
      assert.equal(String(plan[0]?.type).toLowerCase(), 'range');
      assert.doesNotMatch(String(plan[0]?.Extra ?? ''), /filesort/iu);
    }

    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_owner',
    );
    await connection.query(
      `ALTER TABLE synex_cluster_leases
       ADD KEY idx_cluster_leases_authority_owner
         (lease_authority_kind, terminal_compaction_at, lease_name, owner_id)`,
    );
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /lease authority owner index verification failed/iu,
    );
    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_owner',
    );
    await applyMigrations(connection, [migration]);

    authorityDefinitionNeedsRestore = true;
    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_owner',
    );
    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_expiry',
    );
    await connection.query(
      `ALTER TABLE synex_cluster_leases
       MODIFY COLUMN lease_authority_kind VARCHAR(10)
         CHARACTER SET ascii COLLATE ascii_bin
         GENERATED ALWAYS AS (
           CASE
             WHEN LEFT(lease_name, 8) = 'session:' THEN NULL
             WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
             ELSE NULL
           END
         ) STORED`,
    );
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /lease authority definition verification failed/iu,
    );
    await connection.query(
      `ALTER TABLE synex_cluster_leases
       MODIFY COLUMN lease_authority_kind VARCHAR(10)
         CHARACTER SET ascii COLLATE ascii_bin
         GENERATED ALWAYS AS (
           CASE
             WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
             WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
             ELSE NULL
           END
         ) STORED`,
    );
    await applyMigrations(connection, [authorityMigration, migration]);
    authorityDefinitionNeedsRestore = false;

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_026_lease_authority_owner_index'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    if (indexUsabilityRestoreSql) {
      await connection.query(indexUsabilityRestoreSql);
      indexUsabilityRestoreSql = undefined;
    }
    await connection.query(
      'DELETE FROM synex_cluster_leases WHERE lease_name IN (?, ?)',
      [...leaseNames],
    );
    if (authorityDefinitionNeedsRestore && authorityMigration && migration) {
      const [indexes] = await connection.query<RowDataPacket[]>(
        `SELECT DISTINCT index_name FROM information_schema.statistics
         WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
           AND index_name IN (
             'idx_cluster_leases_authority_owner',
             'idx_cluster_leases_authority_expiry'
           )`,
      );
      for (const index of indexes) {
        const name = String(index.index_name);
        if (name === 'idx_cluster_leases_authority_owner') {
          await connection.query(
            'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_owner',
          );
        } else if (name === 'idx_cluster_leases_authority_expiry') {
          await connection.query(
            'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_expiry',
          );
        } else {
          assert.fail('unexpected authority index in migration 026 cleanup');
        }
      }
      await connection.query(
        `ALTER TABLE synex_cluster_leases
         MODIFY COLUMN lease_authority_kind VARCHAR(10)
           CHARACTER SET ascii COLLATE ascii_bin
           GENERATED ALWAYS AS (
             CASE
               WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
               WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
               ELSE NULL
             END
           ) STORED`,
      );
      await applyMigrations(connection, [authorityMigration, migration]);
      authorityDefinitionNeedsRestore = false;
    }
    if (migration) {
      const [indexes] = await connection.query<RowDataPacket[]>(
        `SELECT column_name FROM information_schema.statistics
         WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
           AND index_name = 'idx_cluster_leases_authority_owner'
         ORDER BY seq_in_index`,
      );
      const correct = indexes.map((row) => String(row.column_name)).join(',')
        === 'lease_authority_kind,terminal_compaction_at,owner_id,lease_name';
      if (!correct) {
        if (indexes.length > 0) {
          await connection.query(
            'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_authority_owner',
          );
        }
        await applyMigrations(connection, [migration]);
      }
    }
    await connection.end();
  }
});

test('live READ COMMITTED recovery terminalizes only local sessionless authority and compacts its capacity', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const blocker = await openLiveDatabase();
  const suffix = randomUUID().replaceAll('-', '');
  const instanceId = `recovery_${suffix.slice(0, 20)}`;
  const zeroInstanceId = `zero_${suffix.slice(0, 20)}`;
  const foreignInstanceId = `foreign_${suffix.slice(0, 20)}`;
  const bootId = randomUUID();
  const zeroBootId = randomUUID();
  const leaseNames = {
    localSession: `session:${suffix}:local`,
    localAdmission: `admission:${suffix}:local`,
    similarPrefix: `session:${suffix}:similar`,
    foreign: `admission:${suffix}:foreign`,
    localGeneric: `generic:${suffix}:local`,
    localSaga: `saga:${suffix}:local`,
    localCharacter: `character-delete:${suffix}:local`,
    localOther: `other:${suffix}:local`,
  };
  let capacityMigration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    capacityMigration = migrations.find(
      (entry) => entry.file === '025_cluster_lease_capacity.sql',
    );
    assert.ok(capacityMigration);
    await connection.query(
      `INSERT INTO synex_instances
       (instance_id, name, started_at, heartbeat_at, status, version)
       VALUES
         (?, 'Owner recovery live', CURRENT_TIMESTAMP(6),
           CURRENT_TIMESTAMP(6), 'starting', 1),
         (?, 'Zero owner recovery live', CURRENT_TIMESTAMP(6),
           CURRENT_TIMESTAMP(6), 'starting', 1)`,
      [instanceId, zeroInstanceId],
    );
    await connection.query(
      `INSERT INTO synex_instance_boots (instance_id, boot_id, registered_at)
       VALUES (?, ?, CURRENT_TIMESTAMP(6)), (?, ?, CURRENT_TIMESTAMP(6))`,
      [instanceId, bootId, zeroInstanceId, zeroBootId],
    );
    await connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
       VALUES
         (?, ?, 7, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 18446744073709551615,
           TIMESTAMPADD(SECOND, -30, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 11, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 13, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 17, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 19, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 23, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 29, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL)`,
      [
        leaseNames.localSession, `${instanceId}:pending-session`,
        leaseNames.localAdmission, `${instanceId}:pending-admission`,
        leaseNames.similarPrefix, `${instanceId}2:pending-session`,
        leaseNames.foreign, `${foreignInstanceId}:pending-admission`,
        leaseNames.localGeneric, `${instanceId}:generic`,
        leaseNames.localSaga, `${instanceId}:saga`,
        leaseNames.localCharacter, `${instanceId}:character`,
        leaseNames.localOther, `${instanceId}:other`,
      ],
    );
    await applyMigrations(connection, [capacityMigration]);

    assert.deepEqual(
      await recoverLocalConnectionLeases(connection, zeroInstanceId, zeroBootId, 4),
      { status: 'committed', selected: 0, retired: 0 },
    );

    const [sessions] = await connection.query<RowDataPacket[]>(
      `SELECT id FROM synex_sessions
       WHERE server_instance_id = ? AND closed_at IS NULL`,
      [instanceId],
    );
    assert.equal(sessions.length, 0, 'the connection leases must not depend on a session row');
    const capacityBefore = await capacitySnapshot(connection);
    await blocker.connection.query('SET SESSION innodb_lock_wait_timeout = 2');
    await blocker.connection.beginTransaction();
    const [lockedGeneric] = await blocker.connection.query<RowDataPacket[]>(
      `SELECT lease_name FROM synex_cluster_leases
       WHERE lease_name = ? FOR UPDATE`,
      [leaseNames.localGeneric],
    );
    assert.equal(lockedGeneric.length, 1);
    await connection.query('SET SESSION innodb_lock_wait_timeout = 2');
    const recovered = await recoverLocalConnectionLeases(
      connection, instanceId, bootId, 2,
    );
    await blocker.connection.rollback();
    assert.deepEqual(recovered, { status: 'committed', selected: 2, retired: 2 });
    const [isolationRows] = await connection.query<RowDataPacket[]>(
      'SELECT @@tx_isolation AS isolation_level',
    );
    assert.equal(String(isolationRows[0]?.isolation_level), 'READ-COMMITTED');

    const [leaseRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name, owner_id, CAST(fencing_token AS CHAR) AS fencing_token,
              expires_at <= CURRENT_TIMESTAMP(6) AS expired, terminal_compaction_at
       FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?, ?, ?, ?) ORDER BY lease_name`,
      [
        leaseNames.localSession, leaseNames.localAdmission, leaseNames.similarPrefix,
        leaseNames.foreign, leaseNames.localGeneric, leaseNames.localSaga,
        leaseNames.localCharacter, leaseNames.localOther,
      ],
    );
    const byName = new Map(leaseRows.map((row) => [String(row.lease_name), row]));
    assert.equal(byName.size, 8);
    assert.equal(byName.get(leaseNames.localSession)?.owner_id, 'retired');
    assert.equal(byName.get(leaseNames.localSession)?.fencing_token, '8');
    assert.equal(Number(byName.get(leaseNames.localSession)?.expired), 1);
    assert.ok(byName.get(leaseNames.localSession)?.terminal_compaction_at);
    assert.equal(byName.get(leaseNames.localAdmission)?.owner_id, 'retired');
    assert.equal(
      byName.get(leaseNames.localAdmission)?.fencing_token,
      '18446744073709551615',
    );
    assert.equal(Number(byName.get(leaseNames.localAdmission)?.expired), 1);
    assert.ok(byName.get(leaseNames.localAdmission)?.terminal_compaction_at);
    assert.equal(
      byName.get(leaseNames.similarPrefix)?.owner_id,
      `${instanceId}2:pending-session`,
    );
    assert.equal(byName.get(leaseNames.similarPrefix)?.terminal_compaction_at, null);
    assert.equal(
      byName.get(leaseNames.foreign)?.owner_id,
      `${foreignInstanceId}:pending-admission`,
    );
    assert.equal(byName.get(leaseNames.foreign)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.localGeneric)?.owner_id, `${instanceId}:generic`);
    assert.equal(byName.get(leaseNames.localGeneric)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.localSaga)?.owner_id, `${instanceId}:saga`);
    assert.equal(byName.get(leaseNames.localSaga)?.terminal_compaction_at, null);
    assert.equal(
      byName.get(leaseNames.localCharacter)?.owner_id,
      `${instanceId}:character`,
    );
    assert.equal(byName.get(leaseNames.localCharacter)?.terminal_compaction_at, null);
    assert.equal(byName.get(leaseNames.localOther)?.owner_id, `${instanceId}:other`);
    assert.equal(byName.get(leaseNames.localOther)?.terminal_compaction_at, null);
    assert.deepEqual(await capacitySnapshot(connection), capacityBefore,
      'terminalization must retain capacity until compaction deletes the rows');

    await compactTerminalFixtures(
      connection,
      [leaseNames.localSession, leaseNames.localAdmission],
    );
    const capacityAfterCompaction = await capacitySnapshot(connection);
    assert.deepEqual(capacityAfterCompaction, {
      global: capacityBefore.global - 2,
      admission: capacityBefore.admission - 1,
      other: capacityBefore.other,
      session: capacityBefore.session - 1,
    });
    const [survivors] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?, ?, ?, ?) ORDER BY lease_name`,
      [
        leaseNames.localSession, leaseNames.localAdmission, leaseNames.similarPrefix,
        leaseNames.foreign, leaseNames.localGeneric, leaseNames.localSaga,
        leaseNames.localCharacter, leaseNames.localOther,
      ],
    );
    assert.deepEqual(
      survivors.map((row) => String(row.lease_name)).sort(),
      [
        leaseNames.similarPrefix, leaseNames.foreign, leaseNames.localGeneric,
        leaseNames.localSaga, leaseNames.localCharacter, leaseNames.localOther,
      ].sort(),
    );
  } finally {
    await blocker.connection.rollback();
    await connection.query(
      `DELETE FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        leaseNames.localSession, leaseNames.localAdmission, leaseNames.similarPrefix,
        leaseNames.foreign, leaseNames.localGeneric, leaseNames.localSaga,
        leaseNames.localCharacter, leaseNames.localOther,
      ],
    );
    await connection.query(
      'DELETE FROM synex_instance_boots WHERE instance_id IN (?, ?)',
      [instanceId, zeroInstanceId],
    );
    await connection.query(
      'DELETE FROM synex_instances WHERE instance_id IN (?, ?)',
      [instanceId, zeroInstanceId],
    );
    if (capacityMigration) await applyMigrations(connection, [capacityMigration]);
    await Promise.all([connection.end(), blocker.connection.end()]);
  }
});

test('live READ COMMITTED recovery rolls back over-bound and residual phantom authority', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const injector = await openLiveDatabase();
  const suffix = randomUUID().replaceAll('-', '');
  const overBoundInstanceId = `over_${suffix.slice(0, 20)}`;
  const mismatchInstanceId = `mismatch_${suffix.slice(0, 20)}`;
  const overBoundBootId = randomUUID();
  const mismatchBootId = randomUUID();
  const leaseNames = {
    overSessionA: `session:${suffix}:over-a`,
    overAdmission: `admission:${suffix}:over`,
    overSessionB: `session:${suffix}:over-b`,
    mismatchInitial: `session:${suffix}:mismatch-initial`,
    mismatchPhantom: `admission:${suffix}:mismatch-phantom`,
  };
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    await primary.connection.query(
      `INSERT INTO synex_instances
       (instance_id, name, started_at, heartbeat_at, status, version)
       VALUES
         (?, 'Over-bound recovery live', CURRENT_TIMESTAMP(6),
           CURRENT_TIMESTAMP(6), 'starting', 1),
         (?, 'Mismatch recovery live', CURRENT_TIMESTAMP(6),
           CURRENT_TIMESTAMP(6), 'starting', 1)`,
      [overBoundInstanceId, mismatchInstanceId],
    );
    await primary.connection.query(
      `INSERT INTO synex_instance_boots (instance_id, boot_id, registered_at)
       VALUES (?, ?, CURRENT_TIMESTAMP(6)), (?, ?, CURRENT_TIMESTAMP(6))`,
      [overBoundInstanceId, overBoundBootId, mismatchInstanceId, mismatchBootId],
    );
    await primary.connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
       VALUES
         (?, ?, 21, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 22, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 23, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL),
         (?, ?, 31, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL)`,
      [
        leaseNames.overSessionA, `${overBoundInstanceId}:session-a`,
        leaseNames.overAdmission, `${overBoundInstanceId}:admission`,
        leaseNames.overSessionB, `${overBoundInstanceId}:session-b`,
        leaseNames.mismatchInitial, `${mismatchInstanceId}:initial`,
      ],
    );

    const overBound = await recoverLocalConnectionLeases(
      primary.connection, overBoundInstanceId, overBoundBootId, 2,
    );
    assert.deepEqual(overBound, { status: 'over-bound', selected: 3, retired: 0 });
    const [overBoundRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT owner_id, terminal_compaction_at FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?) ORDER BY lease_name`,
      [leaseNames.overSessionA, leaseNames.overAdmission, leaseNames.overSessionB],
    );
    assert.equal(overBoundRows.length, 3);
    assert.ok(overBoundRows.every((row) => row.owner_id !== 'retired'
      && row.terminal_compaction_at === null));

    await injector.connection.query('SET SESSION innodb_lock_wait_timeout = 3');
    const mismatch = await recoverLocalConnectionLeases(
      primary.connection,
      mismatchInstanceId,
      mismatchBootId,
      4,
      async () => {
        await injector.connection.query(
          `INSERT INTO synex_cluster_leases
           (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
           VALUES (?, ?, 32, TIMESTAMPADD(SECOND, 120, CURRENT_TIMESTAMP(6)), NULL)`,
          [leaseNames.mismatchPhantom, `${mismatchInstanceId}:phantom`],
        );
      },
    );
    assert.deepEqual(mismatch, { status: 'residual', selected: 1, retired: 1 });
    const [mismatchRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT lease_name, owner_id, CAST(fencing_token AS CHAR) AS fencing_token,
              terminal_compaction_at
       FROM synex_cluster_leases
       WHERE lease_name IN (?, ?) ORDER BY lease_name`,
      [leaseNames.mismatchInitial, leaseNames.mismatchPhantom],
    );
    assert.equal(mismatchRows.length, 2);
    const mismatchByName = new Map(
      mismatchRows.map((row) => [String(row.lease_name), row]),
    );
    assert.equal(
      mismatchByName.get(leaseNames.mismatchInitial)?.owner_id,
      `${mismatchInstanceId}:initial`,
    );
    assert.equal(mismatchByName.get(leaseNames.mismatchInitial)?.fencing_token, '31');
    assert.equal(
      mismatchByName.get(leaseNames.mismatchPhantom)?.owner_id,
      `${mismatchInstanceId}:phantom`,
    );
    assert.equal(mismatchByName.get(leaseNames.mismatchPhantom)?.fencing_token, '32');
    assert.ok(mismatchRows.every((row) => row.terminal_compaction_at === null));
    const [isolationRows] = await primary.connection.query<RowDataPacket[]>(
      'SELECT @@tx_isolation AS isolation_level',
    );
    assert.equal(String(isolationRows[0]?.isolation_level), 'READ-COMMITTED');
  } finally {
    await primary.connection.query(
      `DELETE FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?)`,
      [
        leaseNames.overSessionA, leaseNames.overAdmission, leaseNames.overSessionB,
        leaseNames.mismatchInitial, leaseNames.mismatchPhantom,
      ],
    );
    await primary.connection.query(
      'DELETE FROM synex_instance_boots WHERE instance_id IN (?, ?)',
      [overBoundInstanceId, mismatchInstanceId],
    );
    await primary.connection.query(
      'DELETE FROM synex_instances WHERE instance_id IN (?, ?)',
      [overBoundInstanceId, mismatchInstanceId],
    );
    await Promise.all([primary.connection.end(), injector.connection.end()]);
  }
});
