import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import type { RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';

const gate = liveDatabaseGate();

test('live owner attribution migration is repeatable and isolates saga owners', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const sagaIds = [randomUUID(), randomUUID(), randomUUID()];
  const outboxIds = [randomUUID(), randomUUID()];
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    const migration = migrations.find((entry) => entry.file === '014_runtime_owner_attribution.sql');
    assert.ok(migration);
    await applyMigrations(connection, [migration]);

    const [columns] = await connection.query<RowDataPacket[]>(
      `SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE()
         AND ((TABLE_NAME = 'synex_sagas' AND COLUMN_NAME = 'owner_resource')
           OR (TABLE_NAME = 'synex_outbox'
             AND COLUMN_NAME IN ('producer_resource', 'last_error_code', 'payload_compacted_at')))`,
    );
    assert.equal(columns.length, 4);
    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'synex_sagas'
         AND INDEX_NAME IN ('uq_sagas_type_correlation', 'uq_sagas_owner_type_correlation')`,
    );
    assert.deepEqual(indexes.map((row) => String(row.INDEX_NAME)), [
      'uq_sagas_owner_type_correlation',
    ]);

    const correlation = `owner-attribution-${randomUUID()}`;
    await connection.query(
      `INSERT INTO synex_sagas
       (public_id, owner_resource, saga_type, correlation_id, state, context_json)
       VALUES (?, 'synex_fixture_a', 'fixture.workflow', ?, 'pending', '{}'),
              (?, 'synex_fixture_b', 'fixture.workflow', ?, 'pending', '{}')`,
      [sagaIds[0], correlation, sagaIds[1], correlation],
    );
    await assert.rejects(connection.query(
      `INSERT INTO synex_sagas
       (public_id, owner_resource, saga_type, correlation_id, state, context_json)
       VALUES (?, 'synex_fixture_a', 'fixture.workflow', ?, 'pending', '{}')`,
      [sagaIds[2], correlation],
    ));

    await connection.query(
      `INSERT INTO synex_outbox
       (event_id, producer_resource, aggregate_type, aggregate_id, event_type,
        schema_version, payload_json, headers_json)
       VALUES (?, 'synex_fixture_a', 'fixture', 'aggregate-a', 'synex.fixture_a.changed', 1, '{}', '{}'),
              (?, NULL, 'legacy', 'aggregate-b', 'synex.legacy.changed', 1, '{}', '{}')`,
      outboxIds,
    );
    const [outbox] = await connection.query<RowDataPacket[]>(
      `SELECT event_id, producer_resource FROM synex_outbox
       WHERE event_id IN (?, ?) ORDER BY event_id`,
      outboxIds,
    );
    assert.equal(outbox.length, 2);
    assert.equal(outbox.some((row) => row.producer_resource === 'synex_fixture_a'), true);
    assert.equal(outbox.some((row) => row.producer_resource === null), true);

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT ROUTINE_NAME FROM information_schema.ROUTINES
       WHERE ROUTINE_SCHEMA = DATABASE()
         AND ROUTINE_NAME = 'synex_migrate_014_runtime_owner_attribution'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    await connection.query('DELETE FROM synex_outbox WHERE event_id IN (?, ?)', outboxIds);
    await connection.query('DELETE FROM synex_sagas WHERE public_id IN (?, ?, ?)', sagaIds);
    await connection.end();
  }
});
