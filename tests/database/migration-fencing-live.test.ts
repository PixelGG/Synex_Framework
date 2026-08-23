import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import test from 'node:test';
import type { ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import { applyMigrations, liveDatabaseGate, loadMigrations, openLiveDatabase } from './harness.js';

interface FenceRow extends RowDataPacket {
  owner_id: string;
  fencing_token: string | number;
  state: string;
  completed_statements: string | number;
}

const gate = liveDatabaseGate();

test('live migration fence rejects takeover markers while a statement outlives its lease', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const setup = await openLiveDatabase();
  const firstBoot = await openLiveDatabase();
  const secondBoot = await openLiveDatabase();
  try {
    await applyMigrations(setup.connection, await loadMigrations());
    const suffix = randomUUID().replaceAll('-', '');
    const leaseName = `migration-live:${suffix}`;
    const resourceName = 'synex_live_migration';
    const migrationId = `900_long_${suffix}`;
    const checksum = createHash('sha256').update(`DO SLEEP(2):${suffix}`, 'utf8').digest('hex');
    const firstOwner = `first:${suffix}`;
    const secondOwner = `second:${suffix}`;

    await setup.connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, ?, 1, TIMESTAMPADD(SECOND, 1, CURRENT_TIMESTAMP(6)))`,
      [leaseName, firstOwner],
    );
    await firstBoot.connection.beginTransaction();
    const [leaseClaim] = await firstBoot.connection.query<RowDataPacket[]>(
      `SELECT owner_id, fencing_token FROM synex_cluster_leases
       WHERE lease_name = ? AND owner_id = ? AND fencing_token = 1
         AND expires_at > CURRENT_TIMESTAMP(6) FOR UPDATE`,
      [leaseName, firstOwner],
    );
    assert.equal(leaseClaim.length, 1);
    await firstBoot.connection.query(
      `INSERT INTO synex_schema_migration_attempts
       (resource_name, migration_id, checksum_sha256, state, attempts,
        last_error_code, started_at, finished_at)
       VALUES (?, ?, ?, 'applying', 1, NULL, CURRENT_TIMESTAMP(6), NULL)`,
      [resourceName, migrationId, checksum],
    );
    await firstBoot.connection.query(
      `INSERT INTO synex_schema_migration_fences
       (resource_name, migration_id, checksum_sha256, owner_id, fencing_token,
        state, statement_count, completed_statements, last_error_code, started_at, finished_at)
       VALUES (?, ?, ?, ?, 1, 'applying', 1, 0, NULL, CURRENT_TIMESTAMP(6), NULL)`,
      [resourceName, migrationId, checksum, firstOwner],
    );
    await firstBoot.connection.commit();

    let firstStatementExecutions = 0;
    const longStatement = (async () => {
      firstStatementExecutions += 1;
      await firstBoot.connection.query('DO SLEEP(2)');
    })();
    await new Promise<void>((resolve) => { setTimeout(resolve, 1200); });

    const [takeover] = await secondBoot.connection.query<ResultSetHeader>(
      `UPDATE synex_cluster_leases
       SET owner_id = ?, fencing_token = fencing_token + 1,
           expires_at = TIMESTAMPADD(SECOND, 10, CURRENT_TIMESTAMP(6))
       WHERE lease_name = ? AND expires_at <= CURRENT_TIMESTAMP(6)`,
      [secondOwner, leaseName],
    );
    assert.equal(takeover.affectedRows, 1);
    await secondBoot.connection.beginTransaction();
    const [contended] = await secondBoot.connection.query<FenceRow[]>(
      `SELECT owner_id, fencing_token, state, completed_statements
       FROM synex_schema_migration_fences
       WHERE resource_name = ? AND migration_id = ? FOR UPDATE`,
      [resourceName, migrationId],
    );
    assert.equal(contended.length, 1);
    assert.equal(contended[0]?.owner_id, firstOwner);
    assert.equal(Number(contended[0]?.fencing_token), 1);
    assert.equal(contended[0]?.state, 'applying');
    await secondBoot.connection.rollback();
    await longStatement;

    const [staleProgress] = await firstBoot.connection.query<ResultSetHeader>(
      `UPDATE synex_schema_migration_fences AS migration_fence
       INNER JOIN synex_cluster_leases AS lease ON lease.lease_name = ?
       SET migration_fence.completed_statements = 1
       WHERE migration_fence.resource_name = ? AND migration_fence.migration_id = ?
         AND migration_fence.owner_id = ? AND migration_fence.fencing_token = 1
         AND migration_fence.state = 'applying' AND migration_fence.completed_statements = 0
         AND lease.owner_id = ? AND lease.fencing_token = 1
         AND lease.expires_at > CURRENT_TIMESTAMP(6)`,
      [leaseName, resourceName, migrationId, firstOwner, firstOwner],
    );
    assert.equal(staleProgress.affectedRows, 0);

    const [staleApplied] = await firstBoot.connection.query<ResultSetHeader>(
      `INSERT INTO synex_schema_migrations
       (migration_id, resource_name, checksum_sha256, duration_ms, instance_id)
       SELECT ?, ?, ?, 2000, ? FROM synex_cluster_leases
       WHERE lease_name = ? AND owner_id = ? AND fencing_token = 1
         AND expires_at > CURRENT_TIMESTAMP(6)`,
      [migrationId, resourceName, checksum, firstOwner, leaseName, firstOwner],
    );
    assert.equal(staleApplied.affectedRows, 0);

    for (const terminalState of ['applied', 'failed'] as const) {
      const [foreignMarker] = await secondBoot.connection.query<ResultSetHeader>(
        `UPDATE synex_schema_migration_fences
         SET state = ?, finished_at = CURRENT_TIMESTAMP(6)
         WHERE resource_name = ? AND migration_id = ? AND owner_id = ?
           AND fencing_token = 2 AND state = 'applying'`,
        [terminalState, resourceName, migrationId, secondOwner],
      );
      assert.equal(foreignMarker.affectedRows, 0);
    }

    const [finalFence] = await setup.connection.query<FenceRow[]>(
      `SELECT owner_id, fencing_token, state, completed_statements
       FROM synex_schema_migration_fences
       WHERE resource_name = ? AND migration_id = ?`,
      [resourceName, migrationId],
    );
    const [appliedMarkers] = await setup.connection.query<RowDataPacket[]>(
      `SELECT instance_id FROM synex_schema_migrations
       WHERE resource_name = ? AND migration_id = ?`,
      [resourceName, migrationId],
    );
    assert.equal(firstStatementExecutions, 1);
    assert.equal(appliedMarkers.length, 0);
    assert.equal(finalFence.length, 1);
    assert.equal(finalFence[0]?.owner_id, firstOwner);
    assert.equal(Number(finalFence[0]?.fencing_token), 1);
    assert.equal(finalFence[0]?.state, 'applying');
    assert.equal(Number(finalFence[0]?.completed_statements), 0);
  } finally {
    await Promise.all([
      setup.connection.end(),
      firstBoot.connection.end(),
      secondBoot.connection.end(),
    ]);
  }
});
