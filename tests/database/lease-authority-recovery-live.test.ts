import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import type { ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';

const gate = liveDatabaseGate();

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
