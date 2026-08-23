import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import mysql, { type Connection, type ResultSetHeader, type RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';

const gate = liveDatabaseGate();

interface Limits {
  globalLimit: number;
  ownerLimit: number;
  namespaceLimit: number;
}

async function claimNewKey(
  connection: Connection,
  owner: string,
  namespace: string,
  key: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [globalRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit, owner_limit, namespace_limit
       FROM synex_idempotency_capacity WHERE singleton_id = 1 FOR UPDATE`,
    );
    const global = globalRows[0];
    assert.ok(global);
    await connection.query(
      `INSERT IGNORE INTO synex_idempotency_owner_capacity (owner_resource, entry_count)
       VALUES (?, 0)`,
      [owner],
    );
    const [ownerRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count FROM synex_idempotency_owner_capacity
       WHERE owner_resource = ? FOR UPDATE`,
      [owner],
    );
    const ownerRow = ownerRows[0];
    assert.ok(ownerRow);
    await connection.query(
      `INSERT IGNORE INTO synex_idempotency_namespace_capacity
       (namespace, owner_resource, entry_count) VALUES (?, ?, 0)`,
      [namespace, owner],
    );
    const [namespaceRows] = await connection.query<RowDataPacket[]>(
      `SELECT owner_resource, entry_count FROM synex_idempotency_namespace_capacity
       WHERE namespace = ? FOR UPDATE`,
      [namespace],
    );
    const namespaceRow = namespaceRows[0];
    assert.ok(namespaceRow);
    const [existingRows] = await connection.query<RowDataPacket[]>(
      `SELECT request_hash FROM synex_idempotency_keys
       WHERE namespace = ? AND idempotency_key = ? LIMIT 1 FOR UPDATE`,
      [namespace, key],
    );
    if (existingRows.length > 0) {
      await connection.commit();
      return false;
    }
    const globalCount = Number(global.entry_count);
    const ownerCount = Number(ownerRow.entry_count);
    const namespaceCount = Number(namespaceRow.entry_count);
    if (globalCount >= Number(global.global_limit)
      || ownerCount >= Number(global.owner_limit)
      || namespaceCount >= Number(global.namespace_limit)) {
      await connection.rollback();
      return false;
    }
    const [globalUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_idempotency_capacity SET entry_count = entry_count + 1
       WHERE singleton_id = 1 AND entry_count = ?
         AND entry_count < global_limit AND entry_count < 4294967295`,
      [globalCount],
    );
    const [ownerUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_idempotency_owner_capacity SET entry_count = entry_count + 1
       WHERE owner_resource = ? AND entry_count = ? AND entry_count < 4294967295`,
      [owner, ownerCount],
    );
    const [namespaceUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_idempotency_namespace_capacity SET entry_count = entry_count + 1
       WHERE namespace = ? AND owner_resource = ? AND entry_count = ?
         AND entry_count < 4294967295`,
      [namespace, owner, namespaceCount],
    );
    assert.equal(globalUpdated.affectedRows, 1);
    assert.equal(ownerUpdated.affectedRows, 1);
    assert.equal(namespaceUpdated.affectedRows, 1);
    const [inserted] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_idempotency_keys
       (namespace, idempotency_key, request_hash, state, response_json, owner_token,
        locked_until, expires_at)
       VALUES (?, ?, REPEAT('a', 64), 'pending', NULL, ?,
         TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
         TIMESTAMPADD(DAY, 1, CURRENT_TIMESTAMP(6)))`,
      [namespace, key, randomUUID()],
    );
    assert.equal(inserted.affectedRows, 1);
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

test('live migration 022 exactly backfills permanent keys and admits one concurrent key at quota', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const secondary = await mysql.createConnection(gate.enabled ? gate.url : '');
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const ownerA = `synex_capacity_a_${suffix}`;
  const ownerB = `synex_capacity_b_${suffix}`;
  const ownerRace = `synex_capacity_r_${suffix}`;
  const namespaceA = `${ownerA}:fixture.write`;
  const namespaceB = `${ownerB}:fixture.write`;
  const namespaceRace = `${ownerRace}:fixture.write`;
  const fixtureNamespaces = [namespaceA, namespaceB, namespaceRace];
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let originalLimits: Limits | undefined;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(primary.connection, migrations);
    migration = migrations.find((entry) => entry.file === '022_idempotency_capacity.sql');
    assert.ok(migration);

    const [limitRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT global_limit, owner_limit, namespace_limit
       FROM synex_idempotency_capacity WHERE singleton_id = 1`,
    );
    const limitRow = limitRows[0];
    assert.ok(limitRow);
    originalLimits = {
      globalLimit: Number(limitRow.global_limit),
      ownerLimit: Number(limitRow.owner_limit),
      namespaceLimit: Number(limitRow.namespace_limit),
    };

    const [columns] = await primary.connection.query<RowDataPacket[]>(
      `SELECT table_name, column_name, column_type, is_nullable,
              character_set_name, collation_name
       FROM information_schema.columns
       WHERE table_schema = DATABASE()
         AND table_name IN (
           'synex_idempotency_capacity',
           'synex_idempotency_owner_capacity',
           'synex_idempotency_namespace_capacity'
         )`,
    );
    assert.equal(columns.length, 13);
    assert.ok(columns.filter((row) => row.column_name === 'entry_count').every(
      (row) => /^int(?:\(\d+\))? unsigned$/u.test(String(row.column_type).toLowerCase())
        && row.is_nullable === 'NO',
    ));
    assert.ok(columns.filter((row) => ['owner_resource', 'namespace'].includes(
      String(row.column_name),
    )).every((row) => row.character_set_name === 'ascii' && row.collation_name === 'ascii_bin'));

    const [foreignKeys] = await primary.connection.query<RowDataPacket[]>(
      `SELECT referenced_table_name, update_rule, delete_rule
       FROM information_schema.referential_constraints
       WHERE constraint_schema = DATABASE()
         AND table_name = 'synex_idempotency_namespace_capacity'
         AND constraint_name = 'fk_idempotency_namespace_capacity_owner'`,
    );
    assert.equal(foreignKeys.length, 1);
    assert.equal(foreignKeys[0]?.referenced_table_name, 'synex_idempotency_owner_capacity');
    assert.equal(foreignKeys[0]?.update_rule, 'RESTRICT');
    assert.equal(foreignKeys[0]?.delete_rule, 'RESTRICT');

    const states = ['pending', 'completed', 'failed', 'completed'] as const;
    for (const [index, state] of states.entries()) {
      await primary.connection.query(
        `INSERT INTO synex_idempotency_keys
         (namespace, idempotency_key, request_hash, state, response_json, owner_token,
          locked_until, expires_at, completed_at, response_compaction_at)
         VALUES (?, ?, REPEAT('b', 64), ?, ?, ?,
           CURRENT_TIMESTAMP(6), TIMESTAMPADD(DAY, 1, CURRENT_TIMESTAMP(6)),
           IF(? = 'completed', CURRENT_TIMESTAMP(6), NULL),
           IF(? = 'completed' AND ? IS NULL, CURRENT_TIMESTAMP(6), NULL))`,
        [
          index < 3 ? namespaceA : namespaceB,
          randomUUID(),
          state,
          state === 'completed' && index !== 3 ? '{"ok":true}' : null,
          randomUUID(),
          state,
          state,
          state === 'completed' && index !== 3 ? '{"ok":true}' : null,
        ],
      );
    }
    await primary.connection.query(
      `UPDATE synex_idempotency_capacity SET namespace_limit = 1
       WHERE singleton_id = 1`,
    );
    await applyMigrations(primary.connection, [migration]);

    const [counts] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT entry_count FROM synex_idempotency_capacity WHERE singleton_id = 1)
           AS global_count,
         (SELECT entry_count FROM synex_idempotency_owner_capacity WHERE owner_resource = ?)
           AS owner_a_count,
         (SELECT entry_count FROM synex_idempotency_namespace_capacity WHERE namespace = ?)
           AS namespace_a_count,
         (SELECT namespace_limit FROM synex_idempotency_capacity WHERE singleton_id = 1)
           AS namespace_limit`,
      [ownerA, namespaceA],
    );
    assert.ok(Number(counts[0]?.global_count) >= 4);
    assert.equal(Number(counts[0]?.owner_a_count), 3);
    assert.equal(Number(counts[0]?.namespace_a_count), 3);
    assert.equal(Number(counts[0]?.namespace_limit), 1);

    const winners = await Promise.all([
      claimNewKey(primary.connection, ownerRace, namespaceRace, randomUUID()),
      claimNewKey(secondary, ownerRace, namespaceRace, randomUUID()),
    ]);
    assert.equal(winners.filter(Boolean).length, 1);
    const [raceRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_idempotency_keys WHERE namespace = ?) AS key_count,
         (SELECT entry_count FROM synex_idempotency_namespace_capacity WHERE namespace = ?)
           AS counter_count`,
      [namespaceRace, namespaceRace],
    );
    assert.equal(Number(raceRows[0]?.key_count), 1);
    assert.equal(Number(raceRows[0]?.counter_count), 1);

    const [routines] = await primary.connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_022_idempotency_capacity'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    await primary.connection.query(
      `DELETE FROM synex_idempotency_keys
       WHERE namespace IN (?, ?, ?)`,
      fixtureNamespaces,
    );
    if (originalLimits) {
      await primary.connection.query(
        `UPDATE synex_idempotency_capacity
         SET global_limit = ?, owner_limit = ?, namespace_limit = ?
         WHERE singleton_id = 1`,
        [originalLimits.globalLimit, originalLimits.ownerLimit, originalLimits.namespaceLimit],
      );
    }
    if (migration) await applyMigrations(primary.connection, [migration]);
    await secondary.end();
    await primary.connection.end();
  }
});

test('live migration 022 rejects changed and unenforced named capacity checks', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let maliciousCheckInstalled = false;
  let enforcementDisabled = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '022_idempotency_capacity.sql');
    assert.ok(migration);

    await connection.query(
      `ALTER TABLE synex_idempotency_capacity
       DROP CHECK chk_idempotency_capacity_owner_limit,
       ADD CONSTRAINT chk_idempotency_capacity_owner_limit
         CHECK (owner_limit > 0 AND (owner_limit <= global_limit OR 1 = 1))`,
    );
    maliciousCheckInstalled = true;
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /capacity check verification failed/iu,
    );
    await connection.query(
      `ALTER TABLE synex_idempotency_capacity
       DROP CHECK chk_idempotency_capacity_owner_limit,
       ADD CONSTRAINT chk_idempotency_capacity_owner_limit
         CHECK (owner_limit > 0 AND owner_limit <= global_limit)`,
    );
    maliciousCheckInstalled = false;
    await applyMigrations(connection, [migration]);

    const [metadata] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS supported FROM information_schema.columns
       WHERE LOWER(table_schema) = 'information_schema'
         AND UPPER(table_name) = 'TABLE_CONSTRAINTS'
         AND UPPER(column_name) = 'ENFORCED'`,
    );
    if (Number(metadata[0]?.supported) === 1) {
      await connection.query(
        `ALTER TABLE synex_idempotency_capacity
         ALTER CHECK chk_idempotency_capacity_global_limit NOT ENFORCED`,
      );
      enforcementDisabled = true;
      await assert.rejects(
        applyMigrations(connection, [migration]),
        /capacity checks are not enforced/iu,
      );
    }
  } finally {
    if (maliciousCheckInstalled) {
      await connection.query(
        `ALTER TABLE synex_idempotency_capacity
         DROP CHECK chk_idempotency_capacity_owner_limit,
         ADD CONSTRAINT chk_idempotency_capacity_owner_limit
           CHECK (owner_limit > 0 AND owner_limit <= global_limit)`,
      );
    }
    if (enforcementDisabled) {
      await connection.query(
        `ALTER TABLE synex_idempotency_capacity
         ALTER CHECK chk_idempotency_capacity_global_limit ENFORCED`,
      );
    }
    if (migration) await applyMigrations(connection, [migration]);
    await connection.end();
  }
});
