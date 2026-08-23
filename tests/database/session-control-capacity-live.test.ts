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

function normalizeCheck(value: unknown): string {
  return String(value ?? '').toLowerCase().replaceAll(/[`\s()]/gu, '');
}

test('live migration 024 backfills every session-control state and enforces exact metadata', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const requesterId = `control-requester-${suffix}`;
  const targetId = `control-target-${suffix}`;
  const userId = randomUUID();
  const requestIds = [randomUUID(), randomUUID(), randomUUID()];
  const terminalSiblingIds = Array.from({ length: 64 }, () => randomUUID());
  const sessionIds = [randomUUID(), randomUUID(), randomUUID()];
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let originalGlobalLimit: number | undefined;
  let originalRequesterLimit: number | undefined;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '024_session_control_capacity.sql');
    assert.ok(migration);
    const [originalRows] = await connection.query<RowDataPacket[]>(
      `SELECT global_limit, requester_limit FROM synex_session_control_capacity
       WHERE singleton_id = 1`,
    );
    assert.equal(originalRows.length, 1);
    originalGlobalLimit = Number(originalRows[0]?.global_limit);
    originalRequesterLimit = Number(originalRows[0]?.requester_limit);

    await connection.query(
      `INSERT INTO synex_instances
       (instance_id, name, started_at, heartbeat_at, status, version)
       VALUES (?, 'Control requester fixture', CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 'ready', 1),
              (?, 'Control target fixture', CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 'ready', 1)`,
      [requesterId, targetId],
    );
    await connection.query(
      `INSERT INTO synex_users (id, status, locale, metadata_json, version)
       VALUES (?, 'active', 'en', '{}', 1)`,
      [userId],
    );
    for (const [index, sessionId] of sessionIds.entries()) {
      await connection.query(
        `INSERT INTO synex_sessions
         (id, user_id, server_instance_id, source_value, source_generation, state,
          connected_at, last_seen_at, closed_at, close_reason, version)
         VALUES (?, ?, ?, ?, 1, 'CLOSED',
           TIMESTAMPADD(DAY, -40, CURRENT_TIMESTAMP(6)),
           TIMESTAMPADD(DAY, -40, CURRENT_TIMESTAMP(6)),
           TIMESTAMPADD(DAY, -39, CURRENT_TIMESTAMP(6)), 'fixture', 1)`,
        [sessionId, userId, targetId, index + 1],
      );
    }
    const states = ['pending', 'completed', 'expired'] as const;
    for (const [index, state] of states.entries()) {
      await connection.query(
        `INSERT INTO synex_session_control_requests
         (request_id, target_session_id, target_instance_id, requested_by_instance_id,
          action, state, reason, created_at, expires_at, completed_at)
         VALUES (?, ?, ?, ?, 'kick', ?, 'fixture',
           TIMESTAMPADD(DAY, -38, CURRENT_TIMESTAMP(6)),
           TIMESTAMPADD(DAY, -37, CURRENT_TIMESTAMP(6)),
           IF(? = 'pending', NULL, TIMESTAMPADD(DAY, -36, CURRENT_TIMESTAMP(6))))`,
        [requestIds[index], sessionIds[index], targetId, requesterId, state, state],
      );
      if (index !== 2) {
        await connection.query(
          `INSERT INTO synex_session_control_authority
           (request_id, requester_boot_id, recorded_at)
           VALUES (?, ?, CURRENT_TIMESTAMP(6))`,
          [requestIds[index], `boot-${suffix}`],
        );
      }
    }
    for (const siblingId of terminalSiblingIds) {
      await connection.query(
        `INSERT INTO synex_session_control_requests
         (request_id, target_session_id, target_instance_id, requested_by_instance_id,
          action, state, reason, created_at, expires_at, completed_at)
         VALUES (?, ?, ?, ?, 'kick', 'completed', 'terminal sibling fixture',
           TIMESTAMPADD(DAY, -38, CURRENT_TIMESTAMP(6)),
           TIMESTAMPADD(DAY, -37, CURRENT_TIMESTAMP(6)),
           TIMESTAMPADD(DAY, -36, CURRENT_TIMESTAMP(6)))`,
        [siblingId, sessionIds[0], targetId, requesterId],
      );
    }
    await connection.query(
      `UPDATE synex_session_control_capacity SET requester_limit = 1
       WHERE singleton_id = 1`,
    );
    await applyMigrations(connection, [migration]);

    const [capacityRows] = await connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT entry_count FROM synex_session_control_capacity WHERE singleton_id = 1)
           AS global_count,
         (SELECT requester_limit FROM synex_session_control_capacity WHERE singleton_id = 1)
           AS requester_limit,
         (SELECT entry_count FROM synex_session_control_requester_capacity
          WHERE requested_by_instance_id = ?) AS requester_count`,
      [requesterId],
    );
    assert.ok(Number(capacityRows[0]?.global_count) >= 3 + terminalSiblingIds.length);
    assert.equal(Number(capacityRows[0]?.requester_limit), 1);
    assert.equal(Number(capacityRows[0]?.requester_count), 3 + terminalSiblingIds.length);

    const [pendingPlan] = await connection.query<RowDataPacket[]>(
      `EXPLAIN SELECT request_id
       FROM synex_session_control_requests FORCE INDEX (uq_session_control_active)
       WHERE target_session_id = ? AND action = 'kick'
         AND active_marker = 1 AND state = 'pending'
       LIMIT 2 FOR UPDATE`,
      [sessionIds[0]],
    );
    assert.equal(pendingPlan.length, 1);
    assert.equal(pendingPlan[0]?.key, 'uq_session_control_active');
    assert.ok(Number(pendingPlan[0]?.rows) <= 2);

    const terminalSiblingPlaceholders = terminalSiblingIds.map(() => '?').join(', ');
    const [siblingsRemoved] = await connection.query<ResultSetHeader>(
      `DELETE FROM synex_session_control_requests
       WHERE request_id IN (${terminalSiblingPlaceholders})`,
      terminalSiblingIds,
    );
    assert.equal(siblingsRemoved.affectedRows, terminalSiblingIds.length);
    await applyMigrations(connection, [migration]);

    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT seq_in_index, column_name, non_unique, index_type, sub_part, collation
       FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND table_name = 'synex_session_control_requests'
         AND index_name = 'idx_session_control_terminal_retention'
       ORDER BY seq_in_index`,
    );
    assert.deepEqual(indexes.map((row) => String(row.column_name)), [
      'state', 'completed_at', 'request_id',
    ]);
    assert.ok(indexes.every((row) => Number(row.non_unique) === 1
      && String(row.index_type).toUpperCase() === 'BTREE'
      && row.sub_part === null && row.collation === 'A'));

    const [checks] = await connection.query<RowDataPacket[]>(
      `SELECT constraint_name, check_clause FROM information_schema.check_constraints
       WHERE constraint_schema = DATABASE()
         AND constraint_name IN (
           'chk_session_control_capacity_singleton',
           'chk_session_control_capacity_global_limit',
           'chk_session_control_capacity_requester_limit'
         )`,
    );
    const normalized = new Map(checks.map((row) => [
      String(row.constraint_name), normalizeCheck(row.check_clause),
    ]));
    assert.equal(normalized.get('chk_session_control_capacity_singleton'), 'singleton_id=1');
    assert.equal(normalized.get('chk_session_control_capacity_global_limit'), 'global_limit>0');
    assert.equal(
      normalized.get('chk_session_control_capacity_requester_limit'),
      'requester_limit>0andrequester_limit<=global_limit',
    );
    assert.notEqual(
      normalizeCheck('requester_limit > 0 AND (requester_limit <= global_limit OR 1 = 1)'),
      normalized.get('chk_session_control_capacity_requester_limit'),
    );

    let maliciousCheckInstalled = false;
    try {
      await connection.query(
        `ALTER TABLE synex_session_control_capacity
         DROP CHECK chk_session_control_capacity_requester_limit,
         ADD CONSTRAINT chk_session_control_capacity_requester_limit
           CHECK (requester_limit > 0 AND (requester_limit <= global_limit OR 1 = 1))`,
      );
      maliciousCheckInstalled = true;
      await assert.rejects(
        applyMigrations(connection, [migration]),
        /capacity constraint verification failed/u,
      );
    } finally {
      if (maliciousCheckInstalled) {
        await connection.query(
          `ALTER TABLE synex_session_control_capacity
           DROP CHECK chk_session_control_capacity_requester_limit,
           ADD CONSTRAINT chk_session_control_capacity_requester_limit
             CHECK (requester_limit > 0 AND requester_limit <= global_limit)`,
        );
      }
    }
    await applyMigrations(connection, [migration]);

    const [foreignKeys] = await connection.query<RowDataPacket[]>(
      `SELECT usage.ordinal_position, usage.column_name, usage.referenced_table_schema,
              usage.referenced_table_name, usage.referenced_column_name,
              reference.update_rule, reference.delete_rule
       FROM information_schema.key_column_usage AS usage
       INNER JOIN information_schema.referential_constraints AS reference
         ON reference.constraint_schema = usage.constraint_schema
        AND reference.table_name = usage.table_name
        AND reference.constraint_name = usage.constraint_name
       WHERE usage.constraint_schema = DATABASE()
         AND usage.table_name = 'synex_session_control_requester_capacity'
         AND usage.constraint_name = 'fk_session_control_requester_capacity_instance'`,
    );
    assert.equal(foreignKeys.length, 1);
    assert.equal(Number(foreignKeys[0]?.ordinal_position), 1);
    assert.equal(foreignKeys[0]?.column_name, 'requested_by_instance_id');
    assert.equal(foreignKeys[0]?.referenced_table_name, 'synex_instances');
    assert.equal(foreignKeys[0]?.referenced_column_name, 'instance_id');
    assert.equal(foreignKeys[0]?.update_rule, 'RESTRICT');
    assert.equal(foreignKeys[0]?.delete_rule, 'RESTRICT');

    await connection.beginTransaction();
    try {
      await connection.query(
        `SELECT request_id FROM synex_session_control_requests
         FORCE INDEX (idx_session_control_terminal_retention)
         WHERE state = 'completed' AND completed_at IS NOT NULL
           AND completed_at <= TIMESTAMPADD(DAY, -30, CURRENT_TIMESTAMP(6))
           AND request_id = ? FOR UPDATE`,
        [requestIds[1]],
      );
      const [globalRows] = await connection.query<RowDataPacket[]>(
        `SELECT entry_count FROM synex_session_control_capacity
         WHERE singleton_id = 1 FOR UPDATE`,
      );
      const [requesterRows] = await connection.query<RowDataPacket[]>(
        `SELECT entry_count FROM synex_session_control_requester_capacity
         WHERE requested_by_instance_id = ? FOR UPDATE`,
        [requesterId],
      );
      const globalCount = Number(globalRows[0]?.entry_count);
      const requesterCount = Number(requesterRows[0]?.entry_count);
      const [child] = await connection.query<ResultSetHeader>(
        'DELETE FROM synex_session_control_authority WHERE request_id = ?',
        [requestIds[1]],
      );
      const [parent] = await connection.query<ResultSetHeader>(
        `DELETE FROM synex_session_control_requests
         WHERE request_id = ? AND state = 'completed' AND completed_at IS NOT NULL
           AND completed_at <= TIMESTAMPADD(DAY, -30, CURRENT_TIMESTAMP(6))`,
        [requestIds[1]],
      );
      const [globalReleased] = await connection.query<ResultSetHeader>(
        `UPDATE synex_session_control_capacity SET entry_count = entry_count - 1
         WHERE singleton_id = 1 AND entry_count = ? AND entry_count >= 1`,
        [globalCount],
      );
      const [requesterReleased] = await connection.query<ResultSetHeader>(
        `UPDATE synex_session_control_requester_capacity SET entry_count = entry_count - 1
         WHERE requested_by_instance_id = ? AND entry_count = ? AND entry_count >= 1`,
        [requesterId, requesterCount],
      );
      assert.equal(child.affectedRows, 1);
      assert.equal(parent.affectedRows, 1);
      assert.equal(globalReleased.affectedRows, 1);
      assert.equal(requesterReleased.affectedRows, 1);
      await connection.commit();
    } catch (error) {
      await connection.rollback();
      throw error;
    }

    const [remaining] = await connection.query<RowDataPacket[]>(
      `SELECT state, COUNT(*) AS row_count FROM synex_session_control_requests
       WHERE requested_by_instance_id = ? GROUP BY state ORDER BY state`,
      [requesterId],
    );
    assert.deepEqual(remaining.map((row) => [row.state, Number(row.row_count)]), [
      ['expired', 1], ['pending', 1],
    ]);
    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_024_session_control_capacity'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    await connection.query(
      `DELETE authority FROM synex_session_control_authority AS authority
       INNER JOIN synex_session_control_requests AS request
         ON request.request_id = authority.request_id
       WHERE request.requested_by_instance_id = ?`,
      [requesterId],
    );
    await connection.query(
      'DELETE FROM synex_session_control_requests WHERE requested_by_instance_id = ?',
      [requesterId],
    );
    if (migration) await applyMigrations(connection, [migration]);
    if (originalGlobalLimit !== undefined && originalRequesterLimit !== undefined) {
      await connection.query(
        `UPDATE synex_session_control_capacity
         SET global_limit = ?, requester_limit = ? WHERE singleton_id = 1`,
        [originalGlobalLimit, originalRequesterLimit],
      );
    }
    await connection.query(
      'DELETE FROM synex_sessions WHERE id IN (?, ?, ?)',
      sessionIds,
    );
    await connection.query('DELETE FROM synex_users WHERE id = ?', [userId]);
    await connection.query(
      'DELETE FROM synex_instances WHERE instance_id IN (?, ?)',
      [requesterId, targetId],
    );
    await connection.end();
  }
});

test('live migration 024 rejects a named MySQL capacity check that is not enforced', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let enforcementDisabled = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '024_session_control_capacity.sql');
    assert.ok(migration);
    const [metadata] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS supported FROM information_schema.columns
       WHERE LOWER(table_schema) = 'information_schema'
         AND UPPER(table_name) = 'TABLE_CONSTRAINTS'
         AND UPPER(column_name) = 'ENFORCED'`,
    );
    if (Number(metadata[0]?.supported) === 0) return;

    await connection.query(
      `ALTER TABLE synex_session_control_capacity
       ALTER CHECK chk_session_control_capacity_global_limit NOT ENFORCED`,
    );
    enforcementDisabled = true;
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /capacity checks are not enforced/iu,
    );
  } finally {
    if (enforcementDisabled) {
      await connection.query(
        `ALTER TABLE synex_session_control_capacity
         ALTER CHECK chk_session_control_capacity_global_limit ENFORCED`,
      );
    }
    if (migration) await applyMigrations(connection, [migration]);
    await connection.end();
  }
});
