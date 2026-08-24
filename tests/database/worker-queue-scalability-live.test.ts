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

test('live migration 021 verifies exact queue metadata and fences historical compacted responses', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const namespace = `worker021:${randomUUID()}`;
  const owner = 'worker021';
  const sagaType = `cursor:${randomUUID()}`;
  let capacityTablesReady = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    capacityTablesReady = true;
    const migration = migrations.find(
      (entry) => entry.file === '021_worker_queue_scalability.sql',
    );
    assert.ok(migration);
    await applyMigrations(connection, [migration]);

    const [columns] = await connection.query<RowDataPacket[]>(
      `SELECT data_type, datetime_precision, is_nullable, column_default, extra,
              (column_default IS NULL
                OR CAST(column_default AS BINARY) = CAST('NULL' AS BINARY)) AS default_is_null
       FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'synex_idempotency_keys'
         AND column_name = 'response_compaction_at'`,
    );
    assert.equal(columns.length, 1);
    assert.equal(String(columns[0]?.data_type).toLowerCase(), 'datetime');
    assert.equal(Number(columns[0]?.datetime_precision), 6);
    assert.equal(String(columns[0]?.is_nullable), 'YES');
    const columnDefault = columns[0]?.column_default;
    assert.ok(
      columnDefault === null || columnDefault === 'NULL',
      `unexpected response_compaction_at default metadata: ${String(columnDefault)}`,
    );
    assert.equal(Number(columns[0]?.default_is_null), 1);
    assert.equal(String(columns[0]?.extra ?? ''), '');

    const [defaultPredicate] = await connection.query<RowDataPacket[]>(
      `SELECT
         (? IS NULL OR CAST(? AS BINARY) = CAST('NULL' AS BINARY)) AS sql_null,
         (? IS NULL OR CAST(? AS BINARY) = CAST('NULL' AS BINARY)) AS mariadb_null,
         (? IS NULL OR CAST(? AS BINARY) = CAST('NULL' AS BINARY)) AS quoted_literal`,
      [null, null, 'NULL', 'NULL', "'NULL'", "'NULL'"],
    );
    assert.equal(Number(defaultPredicate[0]?.sql_null), 1);
    assert.equal(Number(defaultPredicate[0]?.mariadb_null), 1);
    assert.equal(Number(defaultPredicate[0]?.quoted_literal), 0);

    const expected = new Map<string, string[]>([
      ['idx_idempotency_response_compaction', [
        'state', 'response_compaction_at', 'expires_at', 'namespace', 'idempotency_key',
      ]],
      ['idx_sagas_state_updated', ['state', 'updated_at', 'id']],
      ['idx_outbox_compact_published', [
        'state', 'payload_compacted_at', 'published_at', 'id',
      ]],
      ['idx_outbox_compact_dead', [
        'state', 'payload_compacted_at', 'available_at', 'id',
      ]],
    ]);
    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT table_name, index_name, seq_in_index, column_name, non_unique,
              index_type, sub_part, collation
       FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND index_name IN (
           'idx_idempotency_response_compaction',
           'idx_sagas_state_updated',
           'idx_outbox_compact_published',
           'idx_outbox_compact_dead'
         )
       ORDER BY index_name, seq_in_index`,
    );
    for (const [indexName, columnNames] of expected) {
      const rows = indexes.filter((row) => row.index_name === indexName);
      assert.deepEqual(rows.map((row) => String(row.column_name)), columnNames);
      assert.ok(rows.every((row) => Number(row.non_unique) === 1));
      assert.ok(rows.every((row) => String(row.index_type).toUpperCase() === 'BTREE'));
      assert.ok(rows.every((row) => row.sub_part === null));
      assert.ok(rows.every((row) => row.collation === 'A'));
    }
    assert.equal(indexes.length, [...expected.values()].reduce(
      (total, columnsForIndex) => total + columnsForIndex.length,
      0,
    ));

    const sagaTimestamps = [
      '2026-08-24 00:00:00.123001',
      '2026-08-24 00:00:00.123002',
      '2026-08-24 00:00:00.123999',
    ];
    for (const timestamp of sagaTimestamps) {
      await connection.query(
        `INSERT INTO synex_sagas
         (public_id, owner_resource, saga_type, correlation_id, state,
          current_step, version, context_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'pending', 0, 1, '{}', ?, ?)`,
        [randomUUID(), owner, sagaType, randomUUID(), timestamp, timestamp],
      );
    }

    const seenCursors: string[] = [];
    let cursorAt: string | undefined;
    let cursorId: number | undefined;
    for (let page = 0; page < sagaTimestamps.length; page += 1) {
      const [rows] = cursorAt === undefined
        ? await connection.query<RowDataPacket[]>(
          `SELECT id,
                  DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i:%s.%f') AS updated_at_cursor
           FROM synex_sagas FORCE INDEX (idx_sagas_state_updated)
           WHERE state = 'pending' AND saga_type = ?
           ORDER BY updated_at ASC, id ASC LIMIT 1`,
          [sagaType],
        )
        : await connection.query<RowDataPacket[]>(
          `SELECT id,
                  DATE_FORMAT(updated_at, '%Y-%m-%d %H:%i:%s.%f') AS updated_at_cursor
           FROM synex_sagas FORCE INDEX (idx_sagas_state_updated)
           WHERE state = 'pending' AND saga_type = ?
             AND (updated_at > ? OR (updated_at = ? AND id > ?))
           ORDER BY updated_at ASC, id ASC LIMIT 1`,
          [sagaType, cursorAt, cursorAt, cursorId],
        );
      assert.equal(rows.length, 1);
      assert.equal(typeof rows[0]?.updated_at_cursor, 'string');
      cursorAt = String(rows[0]?.updated_at_cursor);
      cursorId = Number(rows[0]?.id);
      seenCursors.push(cursorAt);
    }
    assert.deepEqual(seenCursors, sagaTimestamps);
    const [exhausted] = await connection.query<RowDataPacket[]>(
      `SELECT id FROM synex_sagas FORCE INDEX (idx_sagas_state_updated)
       WHERE state = 'pending' AND saga_type = ?
         AND (updated_at > ? OR (updated_at = ? AND id > ?))
       ORDER BY updated_at ASC, id ASC LIMIT 1`,
      [sagaType, cursorAt, cursorAt, cursorId],
    );
    assert.equal(exhausted.length, 0);

    const placeholders: string[] = [];
    const values: Array<string | null> = [];
    for (let index = 0; index < 65; index += 1) {
      placeholders.push(`(
        ?, ?, REPEAT('a', 64), 'completed', ?, ?,
        TIMESTAMPADD(DAY, -2, CURRENT_TIMESTAMP(6)),
        TIMESTAMPADD(DAY, -1, CURRENT_TIMESTAMP(6)),
        TIMESTAMPADD(DAY, -3, CURRENT_TIMESTAMP(6)),
        TIMESTAMPADD(DAY, -2, CURRENT_TIMESTAMP(6)), NULL
      )`);
      values.push(
        namespace,
        randomUUID(),
        index === 64 ? '{"eligible":true}' : null,
        randomUUID(),
      );
    }
    await connection.beginTransaction();
    try {
      await connection.query(
        `SELECT entry_count FROM synex_idempotency_capacity
         WHERE singleton_id = 1 FOR UPDATE`,
      );
      await connection.query(
        `INSERT IGNORE INTO synex_idempotency_owner_capacity
         (owner_resource, entry_count) VALUES (?, 0)`,
        [owner],
      );
      await connection.query(
        `SELECT entry_count FROM synex_idempotency_owner_capacity
         WHERE owner_resource = ? FOR UPDATE`,
        [owner],
      );
      await connection.query(
        `INSERT IGNORE INTO synex_idempotency_namespace_capacity
         (namespace, owner_resource, entry_count) VALUES (?, ?, 0)`,
        [namespace, owner],
      );
      await connection.query(
        `SELECT entry_count FROM synex_idempotency_namespace_capacity
         WHERE namespace = ? FOR UPDATE`,
        [namespace],
      );
      const [globalCharged] = await connection.query<ResultSetHeader>(
        `UPDATE synex_idempotency_capacity SET entry_count = entry_count + 65
         WHERE singleton_id = 1 AND entry_count <= 4294967230`,
      );
      const [ownerCharged] = await connection.query<ResultSetHeader>(
        `UPDATE synex_idempotency_owner_capacity SET entry_count = entry_count + 65
         WHERE owner_resource = ? AND entry_count <= 4294967230`,
        [owner],
      );
      const [namespaceCharged] = await connection.query<ResultSetHeader>(
        `UPDATE synex_idempotency_namespace_capacity SET entry_count = entry_count + 65
         WHERE namespace = ? AND owner_resource = ? AND entry_count <= 4294967230`,
        [namespace, owner],
      );
      assert.equal(globalCharged.affectedRows, 1);
      assert.equal(ownerCharged.affectedRows, 1);
      assert.equal(namespaceCharged.affectedRows, 1);
      await connection.query(
        `INSERT INTO synex_idempotency_keys
         (namespace, idempotency_key, request_hash, state, response_json, owner_token,
          locked_until, expires_at, created_at, completed_at, response_compaction_at)
         VALUES ${placeholders.join(',')}`,
        values,
      );
      await connection.commit();
    } catch (error) {
      await connection.rollback();
      throw error;
    }

    await applyMigrations(connection, [migration]);
    const [before] = await connection.query<RowDataPacket[]>(
      `SELECT
         SUM(response_json IS NULL AND response_compaction_at IS NOT NULL) AS historical,
         SUM(response_json IS NOT NULL AND response_compaction_at IS NULL) AS eligible
       FROM synex_idempotency_keys WHERE namespace = ?`,
      [namespace],
    );
    assert.equal(Number(before[0]?.historical), 64);
    assert.equal(Number(before[0]?.eligible), 1);

    const [compacted] = await connection.query<ResultSetHeader>(
      `UPDATE synex_idempotency_keys
       FORCE INDEX (idx_idempotency_response_compaction)
       SET response_json = NULL, response_compaction_at = CURRENT_TIMESTAMP(6)
       WHERE state = 'completed' AND response_compaction_at IS NULL
         AND expires_at < CURRENT_TIMESTAMP(6)
       ORDER BY response_compaction_at ASC, expires_at ASC,
         namespace ASC, idempotency_key ASC
       LIMIT 1`,
    );
    assert.equal(Number(compacted.affectedRows), 1);
    const [after] = await connection.query<RowDataPacket[]>(
      `SELECT
         SUM(response_json IS NULL AND response_compaction_at IS NOT NULL) AS compacted,
         SUM(response_compaction_at IS NULL) AS still_eligible
       FROM synex_idempotency_keys WHERE namespace = ?`,
      [namespace],
    );
    assert.equal(Number(after[0]?.compacted), 65);
    assert.equal(Number(after[0]?.still_eligible), 0);

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_021_worker_queue_scalability'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    try {
      if (capacityTablesReady) {
        await connection.query('DELETE FROM synex_sagas WHERE saga_type = ?', [sagaType]);
        await connection.beginTransaction();
        try {
          await connection.query(
            `SELECT entry_count FROM synex_idempotency_capacity
             WHERE singleton_id = 1 FOR UPDATE`,
          );
          await connection.query(
            `SELECT entry_count FROM synex_idempotency_owner_capacity
             WHERE owner_resource = ? FOR UPDATE`,
            [owner],
          );
          await connection.query(
            `SELECT entry_count FROM synex_idempotency_namespace_capacity
             WHERE namespace = ? FOR UPDATE`,
            [namespace],
          );
          const [removed] = await connection.query<ResultSetHeader>(
            'DELETE FROM synex_idempotency_keys WHERE namespace = ?',
            [namespace],
          );
          if (removed.affectedRows > 0) {
            const [globalReleased] = await connection.query<ResultSetHeader>(
              `UPDATE synex_idempotency_capacity SET entry_count = entry_count - ?
               WHERE singleton_id = 1 AND entry_count >= ?`,
              [removed.affectedRows, removed.affectedRows],
            );
            const [ownerReleased] = await connection.query<ResultSetHeader>(
              `UPDATE synex_idempotency_owner_capacity SET entry_count = entry_count - ?
               WHERE owner_resource = ? AND entry_count >= ?`,
              [removed.affectedRows, owner, removed.affectedRows],
            );
            const [namespaceReleased] = await connection.query<ResultSetHeader>(
              `UPDATE synex_idempotency_namespace_capacity SET entry_count = entry_count - ?
               WHERE namespace = ? AND owner_resource = ? AND entry_count >= ?`,
              [removed.affectedRows, namespace, owner, removed.affectedRows],
            );
            assert.equal(globalReleased.affectedRows, 1);
            assert.equal(ownerReleased.affectedRows, 1);
            assert.equal(namespaceReleased.affectedRows, 1);
          }
          await connection.query(
            `DELETE FROM synex_idempotency_namespace_capacity
             WHERE namespace = ? AND entry_count = 0`,
            [namespace],
          );
          await connection.query(
            `DELETE FROM synex_idempotency_owner_capacity
             WHERE owner_resource = ? AND entry_count = 0`,
            [owner],
          );
          await connection.commit();
        } catch (error) {
          await connection.rollback();
          throw error;
        }
      }
    } finally {
      await connection.end();
    }
  }
});
