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
const capacityKinds = ['session', 'admission', 'saga', 'character', 'other'] as const;

interface StoredLimits {
  global: number;
  byKind: Map<string, number>;
}

async function tryClaimNewLease(
  connection: Connection,
  leaseName: string,
  kind: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [existingRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name FROM synex_cluster_leases
       WHERE lease_name = ? LIMIT 1 FOR UPDATE`,
      [leaseName],
    );
    assert.equal(existingRows.length, 0);
    const [candidate] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, 'lease-capacity-live', 1,
         TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)))`,
      [leaseName],
    );
    assert.equal(candidate.affectedRows, 1);
    const [globalRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1 FOR UPDATE`,
    );
    const [kindRows] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count, kind_limit FROM synex_cluster_lease_kind_capacity
       WHERE lease_capacity_kind = ? FOR UPDATE`,
      [kind],
    );
    const global = globalRows[0];
    const kindRow = kindRows[0];
    assert.ok(global && kindRow);
    if (Number(global.entry_count) >= Number(global.global_limit)
      || Number(kindRow.entry_count) >= Number(kindRow.kind_limit)) {
      await connection.rollback();
      return false;
    }
    const [globalReserved] = await connection.query<ResultSetHeader>(
      `UPDATE synex_cluster_lease_capacity SET entry_count = entry_count + 1
       WHERE singleton_id = 1 AND entry_count = ?
         AND entry_count < global_limit AND entry_count < 4294967295`,
      [Number(global.entry_count)],
    );
    const [kindReserved] = await connection.query<ResultSetHeader>(
      `UPDATE synex_cluster_lease_kind_capacity SET entry_count = entry_count + 1
       WHERE lease_capacity_kind = ? AND entry_count = ?
         AND entry_count < kind_limit AND entry_count < 4294967295`,
      [kind, Number(kindRow.entry_count)],
    );
    assert.equal(globalReserved.affectedRows, 1);
    assert.equal(kindReserved.affectedRows, 1);
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

test('live migration 025 exactly classifies and backfills retained leases above policy limits', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const suffix = randomUUID();
  const leaseNames = [
    `session:${suffix}`,
    `admission:${suffix}`,
    `saga:${suffix}`,
    `character-delete:${suffix}`,
    `custom:${suffix}`,
  ];
  const blockedLeaseName = `blocked:${suffix}`;
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let originalLimits: StoredLimits | undefined;
  let insertedMigrationLease = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '025_cluster_lease_capacity.sql');
    assert.ok(migration);

    const [globalRows] = await connection.query<RowDataPacket[]>(
      `SELECT global_limit FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1`,
    );
    const [kindRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_capacity_kind, kind_limit
       FROM synex_cluster_lease_kind_capacity`,
    );
    assert.equal(globalRows.length, 1);
    originalLimits = {
      global: Number(globalRows[0]?.global_limit),
      byKind: new Map(kindRows.map((row) => [
        String(row.lease_capacity_kind), Number(row.kind_limit),
      ])),
    };

    const [migrationLease] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES ('schema_migrations', 'lease-capacity-live', 1,
         TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)))`,
    );
    insertedMigrationLease = migrationLease.affectedRows === 1;
    for (const leaseName of leaseNames) {
      await connection.query(
        `INSERT INTO synex_cluster_leases
         (lease_name, owner_id, fencing_token, expires_at, terminal_compaction_at)
         VALUES (?, 'lease-capacity-live', 1,
           TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
           IF(LEFT(?, 5) = 'saga:', CURRENT_TIMESTAMP(6), NULL))`,
        [leaseName, leaseName],
      );
    }

    await connection.query(
      'UPDATE synex_cluster_lease_kind_capacity SET kind_limit = 1',
    );
    await connection.query(
      'UPDATE synex_cluster_lease_capacity SET global_limit = 1 WHERE singleton_id = 1',
    );
    await applyMigrations(connection, [migration]);

    const [classified] = await connection.query<RowDataPacket[]>(
      `SELECT lease_name, lease_capacity_kind
       FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?, 'schema_migrations')
       ORDER BY lease_name`,
      leaseNames,
    );
    const classification = new Map(classified.map((row) => [
      String(row.lease_name), row.lease_capacity_kind,
    ]));
    assert.equal(classification.get(leaseNames[0]!), 'session');
    assert.equal(classification.get(leaseNames[1]!), 'admission');
    assert.equal(classification.get(leaseNames[2]!), 'saga');
    assert.equal(classification.get(leaseNames[3]!), 'character');
    assert.equal(classification.get(leaseNames[4]!), 'other');
    assert.equal(classification.get('schema_migrations'), null);

    const [actualRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_capacity_kind, COUNT(*) AS entry_count
       FROM synex_cluster_leases WHERE lease_capacity_kind IS NOT NULL
       GROUP BY lease_capacity_kind`,
    );
    const actual = new Map<string, number>(
      capacityKinds.map((kind): [string, number] => [kind, 0]),
    );
    for (const row of actualRows) {
      actual.set(String(row.lease_capacity_kind), Number(row.entry_count));
    }
    const [capacityRows] = await connection.query<RowDataPacket[]>(
      `SELECT lease_capacity_kind, entry_count, kind_limit
       FROM synex_cluster_lease_kind_capacity ORDER BY lease_capacity_kind`,
    );
    assert.equal(capacityRows.length, 5);
    assert.deepEqual(
      capacityRows.map((row) => String(row.lease_capacity_kind)).sort(),
      [...capacityKinds].sort(),
    );
    for (const row of capacityRows) {
      assert.equal(Number(row.entry_count), actual.get(String(row.lease_capacity_kind)));
      assert.equal(Number(row.kind_limit), 1);
    }
    const [totals] = await connection.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1`,
    );
    const actualTotal = [...actual.values()].reduce((sum, count) => sum + count, 0);
    assert.equal(Number(totals[0]?.entry_count), actualTotal);
    assert.equal(Number(totals[0]?.global_limit), 1);
    assert.ok(Number(totals[0]?.entry_count) > Number(totals[0]?.global_limit));

    assert.equal(await tryClaimNewLease(connection, blockedLeaseName, 'other'), false);
    const [blockedRows] = await connection.query<RowDataPacket[]>(
      'SELECT lease_name FROM synex_cluster_leases WHERE lease_name = ?',
      [blockedLeaseName],
    );
    assert.equal(blockedRows.length, 0);

    const [columns] = await connection.query<RowDataPacket[]>(
      `SELECT data_type, character_maximum_length, character_set_name, collation_name,
              is_nullable, extra, generation_expression
       FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
         AND column_name = 'lease_capacity_kind'`,
    );
    assert.equal(columns.length, 1);
    assert.equal(String(columns[0]?.data_type).toLowerCase(), 'varchar');
    assert.equal(Number(columns[0]?.character_maximum_length), 9);
    assert.equal(columns[0]?.character_set_name, 'ascii');
    assert.equal(columns[0]?.collation_name, 'ascii_bin');
    assert.equal(columns[0]?.is_nullable, 'YES');
    assert.match(String(columns[0]?.extra), /STORED GENERATED/iu);
    const generation = String(columns[0]?.generation_expression).toLowerCase()
      .replaceAll('`', '').replaceAll(/\s/gu, '')
      .replaceAll('(', '').replaceAll(')', '')
      .replace(/_(?:utf8mb4|utf8mb3|utf8|ascii|latin1)/gu, '');
    const expectedGeneration = "casewhenlease_name='schema_migrations'thennull"
      + "whenleftlease_name,8='session:'then'session'"
      + "whenleftlease_name,10='admission:'then'admission'"
      + "whenleftlease_name,5='saga:'then'saga'"
      + "whenleftlease_name,17='character-delete:'then'character'else'other'end";
    assert.equal(generation, expectedGeneration);

    const [indexes] = await connection.query<RowDataPacket[]>(
      `SELECT seq_in_index, column_name, non_unique, index_type, sub_part, collation
       FROM information_schema.statistics
       WHERE table_schema = DATABASE() AND table_name = 'synex_cluster_leases'
         AND index_name = 'idx_cluster_leases_capacity_kind'
       ORDER BY seq_in_index`,
    );
    assert.deepEqual(indexes.map((row) => String(row.column_name)), [
      'lease_capacity_kind', 'lease_name',
    ]);
    assert.ok(indexes.every((row) => Number(row.non_unique) === 1
      && String(row.index_type).toUpperCase() === 'BTREE'
      && row.sub_part === null && row.collation === 'A'));

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = DATABASE()
         AND routine_name = 'synex_migrate_025_cluster_lease_capacity'`,
    );
    assert.equal(routines.length, 0);
  } finally {
    await connection.query(
      `DELETE FROM synex_cluster_leases
       WHERE lease_name IN (?, ?, ?, ?, ?, ?)`,
      [...leaseNames, blockedLeaseName],
    );
    if (insertedMigrationLease) {
      await connection.query(
        `DELETE FROM synex_cluster_leases
         WHERE lease_name = 'schema_migrations' AND owner_id = 'lease-capacity-live'`,
      );
    }
    if (originalLimits) {
      await connection.query(
        `UPDATE synex_cluster_lease_capacity
         SET global_limit = ? WHERE singleton_id = 1`,
        [originalLimits.global],
      );
      for (const [kind, limit] of originalLimits.byKind) {
        await connection.query(
          `UPDATE synex_cluster_lease_kind_capacity
           SET kind_limit = ? WHERE lease_capacity_kind = ?`,
          [limit, kind],
        );
      }
    }
    if (migration) await applyMigrations(connection, [migration]);
    await connection.end();
  }
});

test('live migration 025 rejects a preexisting weakened capacity classification', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let indexDropped = false;
  let classificationChanged = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '025_cluster_lease_capacity.sql');
    assert.ok(migration);

    await connection.query(
      'ALTER TABLE synex_cluster_leases DROP INDEX idx_cluster_leases_capacity_kind',
    );
    indexDropped = true;
    await connection.query(
      `ALTER TABLE synex_cluster_leases
       MODIFY COLUMN lease_capacity_kind VARCHAR(9)
         CHARACTER SET ascii COLLATE ascii_bin
         GENERATED ALWAYS AS (
           CASE
             WHEN lease_name = 'schema_migrations' THEN NULL
             WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
             WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
             WHEN LEFT(lease_name, 5) = 'saga:' THEN 'saga'
             WHEN LEFT(lease_name, 17) = 'character-delete:' THEN 'character'
             WHEN LEFT(lease_name, 7) = 'custom:' THEN 'session'
             ELSE 'other'
           END
         ) STORED`,
    );
    classificationChanged = true;
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /lease capacity classification verification failed/iu,
    );
  } finally {
    if (classificationChanged) {
      await connection.query(
        `ALTER TABLE synex_cluster_leases
         MODIFY COLUMN lease_capacity_kind VARCHAR(9)
           CHARACTER SET ascii COLLATE ascii_bin
           GENERATED ALWAYS AS (
             CASE
               WHEN lease_name = 'schema_migrations' THEN NULL
               WHEN LEFT(lease_name, 8) = 'session:' THEN 'session'
               WHEN LEFT(lease_name, 10) = 'admission:' THEN 'admission'
               WHEN LEFT(lease_name, 5) = 'saga:' THEN 'saga'
               WHEN LEFT(lease_name, 17) = 'character-delete:' THEN 'character'
               ELSE 'other'
             END
           ) STORED`,
      );
    }
    if (migration && indexDropped) await applyMigrations(connection, [migration]);
    await connection.end();
  }
});

test('live READ COMMITTED same-name contenders charge retained capacity exactly once', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const [{ connection: winner }, { connection: loser }] = await Promise.all([
    openLiveDatabase(),
    openLiveDatabase(),
  ]);
  const leaseName = `custom:lease-capacity-race:${randomUUID()}`;
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let originalGlobalLimit: number | undefined;
  let originalKindLimit: number | undefined;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(winner, migrations);
    migration = migrations.find((entry) => entry.file === '025_cluster_lease_capacity.sql');
    assert.ok(migration);
    const [globalBefore] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1`,
    );
    const [kindBefore] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count, kind_limit FROM synex_cluster_lease_kind_capacity
       WHERE lease_capacity_kind = 'other'`,
    );
    assert.equal(globalBefore.length, 1);
    assert.equal(kindBefore.length, 1);
    const globalCount = Number(globalBefore[0]?.entry_count);
    const kindCount = Number(kindBefore[0]?.entry_count);
    originalGlobalLimit = Number(globalBefore[0]?.global_limit);
    originalKindLimit = Number(kindBefore[0]?.kind_limit);
    const testGlobalLimit = Math.max(originalGlobalLimit, originalKindLimit, globalCount + 10);
    const testKindLimit = Math.max(originalKindLimit, kindCount + 10);
    await winner.query(
      `UPDATE synex_cluster_lease_capacity SET global_limit = ?
       WHERE singleton_id = 1`,
      [testGlobalLimit],
    );
    await winner.query(
      `UPDATE synex_cluster_lease_kind_capacity SET kind_limit = ?
       WHERE lease_capacity_kind = 'other'`,
      [testKindLimit],
    );
    await Promise.all([
      winner.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED'),
      loser.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED'),
    ]);
    await Promise.all([winner.beginTransaction(), loser.beginTransaction()]);
    const [winnerMiss, loserMiss] = await Promise.all([
      winner.query<RowDataPacket[]>(
        `SELECT lease_name FROM synex_cluster_leases
         WHERE lease_name = ? FOR UPDATE`,
        [leaseName],
      ),
      loser.query<RowDataPacket[]>(
        `SELECT lease_name FROM synex_cluster_leases
         WHERE lease_name = ? FOR UPDATE`,
        [leaseName],
      ),
    ]);
    assert.equal(winnerMiss[0].length, 0);
    assert.equal(loserMiss[0].length, 0);

    const [winnerCandidate] = await winner.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, 'lease-capacity-winner', 1,
         TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)))`,
      [leaseName],
    );
    assert.equal(winnerCandidate.affectedRows, 1);
    const [lockedGlobal] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count, global_limit FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1 FOR UPDATE`,
    );
    const [lockedKind] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count, kind_limit FROM synex_cluster_lease_kind_capacity
       WHERE lease_capacity_kind = 'other' FOR UPDATE`,
    );
    assert.equal(Number(lockedGlobal[0]?.entry_count), globalCount);
    assert.equal(Number(lockedKind[0]?.entry_count), kindCount);
    const [reservedGlobal] = await winner.query<ResultSetHeader>(
      `UPDATE synex_cluster_lease_capacity SET entry_count = entry_count + 1
       WHERE singleton_id = 1 AND entry_count = ? AND entry_count < global_limit`,
      [globalCount],
    );
    const [reservedKind] = await winner.query<ResultSetHeader>(
      `UPDATE synex_cluster_lease_kind_capacity SET entry_count = entry_count + 1
       WHERE lease_capacity_kind = 'other' AND entry_count = ? AND entry_count < kind_limit`,
      [kindCount],
    );
    assert.equal(reservedGlobal.affectedRows, 1);
    assert.equal(reservedKind.affectedRows, 1);

    const loserCandidatePromise = loser.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, 'lease-capacity-loser', 1,
         TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)))`,
      [leaseName],
    );
    await new Promise((resolve) => setTimeout(resolve, 25));
    await winner.commit();
    const [loserCandidate] = await loserCandidatePromise;
    assert.equal(loserCandidate.affectedRows, 0);
    const [winnerRow] = await loser.query<RowDataPacket[]>(
      `SELECT owner_id, lease_capacity_kind FROM synex_cluster_leases
       WHERE lease_name = ? FOR UPDATE`,
      [leaseName],
    );
    assert.equal(winnerRow.length, 1);
    assert.equal(winnerRow[0]?.owner_id, 'lease-capacity-winner');
    assert.equal(winnerRow[0]?.lease_capacity_kind, 'other');
    await loser.rollback();

    const [globalAfter] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count FROM synex_cluster_lease_capacity
       WHERE singleton_id = 1`,
    );
    const [kindAfter] = await winner.query<RowDataPacket[]>(
      `SELECT entry_count FROM synex_cluster_lease_kind_capacity
       WHERE lease_capacity_kind = 'other'`,
    );
    assert.equal(Number(globalAfter[0]?.entry_count), globalCount + 1);
    assert.equal(Number(kindAfter[0]?.entry_count), kindCount + 1);
  } finally {
    await Promise.allSettled([winner.rollback(), loser.rollback()]);
    await winner.query('DELETE FROM synex_cluster_leases WHERE lease_name = ?', [leaseName]);
    if (originalGlobalLimit !== undefined) {
      await winner.query(
        `UPDATE synex_cluster_lease_capacity SET global_limit = ?
         WHERE singleton_id = 1`,
        [originalGlobalLimit],
      );
    }
    if (originalKindLimit !== undefined) {
      await winner.query(
        `UPDATE synex_cluster_lease_kind_capacity SET kind_limit = ?
         WHERE lease_capacity_kind = 'other'`,
        [originalKindLimit],
      );
    }
    if (migration) await applyMigrations(winner, [migration]);
    await Promise.all([winner.end(), loser.end()]);
  }
});

test('live migration 025 rejects a named MySQL check that is not enforced', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  let migration: Awaited<ReturnType<typeof loadMigrations>>[number] | undefined;
  let enforcementDisabled = false;
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    migration = migrations.find((entry) => entry.file === '025_cluster_lease_capacity.sql');
    assert.ok(migration);
    const [metadata] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS supported FROM information_schema.columns
       WHERE LOWER(table_schema) = 'information_schema'
         AND UPPER(table_name) = 'TABLE_CONSTRAINTS'
         AND UPPER(column_name) = 'ENFORCED'`,
    );
    if (Number(metadata[0]?.supported) === 0) return;

    await connection.query(
      `ALTER TABLE synex_cluster_lease_capacity
       ALTER CHECK chk_cluster_lease_capacity_global_limit NOT ENFORCED`,
    );
    enforcementDisabled = true;
    await assert.rejects(
      applyMigrations(connection, [migration]),
      /capacity checks are not enforced/iu,
    );
  } finally {
    if (enforcementDisabled) {
      await connection.query(
        `ALTER TABLE synex_cluster_lease_capacity
         ALTER CHECK chk_cluster_lease_capacity_global_limit ENFORCED`,
      );
    }
    if (migration) await applyMigrations(connection, [migration]);
    await connection.end();
  }
});
