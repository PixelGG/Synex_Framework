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

interface LeaseRow extends RowDataPacket {
  authority_token: string;
  instance_id: string;
  lease_generation: string | number;
  lease_live: string | number;
  resource_epoch: string | number;
  version: string | number;
}

interface StoredLeaseRow extends RowDataPacket {
  authority_token: string;
  instance_id: string;
  lease_generation: string | number;
  resource_epoch: string | number;
}

interface VersionRow extends RowDataPacket {
  version: string;
}

interface EntityClaimRow extends RowDataPacket {
  entity_id: string;
  generation: string | number;
  resource_owner: string;
  server_scope: string;
  status: string;
  version: string | number;
}

interface StoredEntityRow extends RowDataPacket {
  bucket_id: string | number;
  generation: string | number;
  status: string;
}

interface AuthorityCandidate {
  instanceId: string;
  resourceEpoch: number;
  token: string;
  traceId: string;
}

interface LeaseClaim {
  entityGeneration: number;
  instanceId: string;
  leaseGeneration: number;
  resourceEpoch: number;
  token: string;
}

const gate = liveDatabaseGate();
const resourceOwner = 'synex_entities_live_test';

function databaseCode(error: unknown): string | undefined {
  if (!error || typeof error !== 'object' || !('code' in error)) return undefined;
  return typeof error.code === 'string' ? error.code : undefined;
}

function placeholders(values: readonly unknown[]): string {
  assert.ok(values.length > 0);
  return values.map(() => '?').join(', ');
}

async function configureConnection(connection: Connection): Promise<void> {
  await connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.query('SET SESSION innodb_lock_wait_timeout = 10');
}

async function insertEntity(
  connection: Connection,
  entityId: string,
  persistentKey: string,
  status: 'active' | 'dormant' = 'dormant',
): Promise<number> {
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_entities
     (entity_id, generation, persistent_key, entity_type, vehicle_type, model,
      position_x, position_y, position_z, heading, ped_type, door_flag,
      owner_type, owner_id, resource_owner, bucket_id, status, version,
      persistence_policy, recovery_policy, server_scope, last_reason_code, last_trace_id)
     VALUES (?, 1, ?, 'object', NULL, 1, 0, 0, 0, 0, NULL, 0,
             'resource', ?, ?, 0, ?, 1,
             'persistent', 'automatic', 'default',
             'synex.entities.live_test', ?)`,
    [
      entityId,
      persistentKey,
      resourceOwner,
      resourceOwner,
      status,
      `entity-live:${entityId}`,
    ],
  );
  return result.affectedRows;
}

function assertSingleUniqueWinner(
  results: readonly PromiseSettledResult<number>[],
  operation: string,
): void {
  const winners = results.filter(
    (result): result is PromiseFulfilledResult<number> => result.status === 'fulfilled',
  );
  const losers = results.filter(
    (result): result is PromiseRejectedResult => result.status === 'rejected',
  );
  assert.equal(winners.length, 1, `${operation} must commit exactly one winner`);
  assert.equal(winners[0]?.value, 1);
  assert.equal(losers.length, 1, `${operation} must reject exactly one contender`);
  assert.equal(databaseCode(losers[0]?.reason), 'ER_DUP_ENTRY');
}

async function claimAuthority(
  connection: Connection,
  entityId: string,
  candidate: AuthorityCandidate,
): Promise<LeaseClaim | null> {
  let transactionOpen = false;
  try {
    await connection.beginTransaction();
    transactionOpen = true;

    const [entities] = await connection.query<EntityClaimRow[]>(
      `SELECT entity_id, generation, resource_owner, server_scope, status, version
       FROM synex_entities
       WHERE entity_id = ? AND deleted_at IS NULL FOR UPDATE`,
      [entityId],
    );
    assert.equal(entities.length, 1);
    const entity = entities[0]!;
    assert.equal(entity.resource_owner, resourceOwner);
    assert.equal(entity.server_scope, 'default');
    if (!['dormant', 'orphaned', 'failed'].includes(entity.status)) {
      await connection.rollback();
      transactionOpen = false;
      return null;
    }

    const [leases] = await connection.query<LeaseRow[]>(
      `SELECT instance_id, authority_token, resource_epoch, lease_generation, version,
              (lease_state = 'active' AND lease_until > CURRENT_TIMESTAMP(6)) AS lease_live
       FROM synex_entity_authority_leases
       WHERE entity_id = ? FOR UPDATE`,
      [entityId],
    );
    const lease = leases[0];
    const sameAuthority = lease?.instance_id === candidate.instanceId
      && lease.authority_token === candidate.token
      && Number(lease.resource_epoch) === candidate.resourceEpoch;
    if (lease && Number(lease.lease_live) === 1 && !sameAuthority) {
      await connection.rollback();
      transactionOpen = false;
      return null;
    }

    const leaseGeneration = lease ? Number(lease.lease_generation) + 1 : 1;
    let affected: number;
    if (lease) {
      const [result] = await connection.query<ResultSetHeader>(
        `UPDATE synex_entity_authority_leases
         SET server_scope = 'default', instance_id = ?, authority_token = ?,
             resource_epoch = ?, lease_generation = ?, lease_state = 'active',
             claimed_at = CURRENT_TIMESTAMP(6), heartbeat_at = CURRENT_TIMESTAMP(6),
             lease_until = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
             released_at = NULL, last_trace_id = ?, version = version + 1
         WHERE entity_id = ? AND version = ?`,
        [
          candidate.instanceId,
          candidate.token,
          candidate.resourceEpoch,
          leaseGeneration,
          candidate.traceId,
          entityId,
          Number(lease.version),
        ],
      );
      affected = result.affectedRows;
    } else {
      const [result] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_entity_authority_leases
         (entity_id, server_scope, instance_id, authority_token, resource_epoch,
          lease_generation, lease_state, claimed_at, heartbeat_at, lease_until,
          last_trace_id, version)
         VALUES (?, 'default', ?, ?, ?, 1, 'active', CURRENT_TIMESTAMP(6),
                 CURRENT_TIMESTAMP(6), TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)), ?, 1)`,
        [
          entityId,
          candidate.instanceId,
          candidate.token,
          candidate.resourceEpoch,
          candidate.traceId,
        ],
      );
      affected = result.affectedRows;
    }
    assert.equal(affected, 1);

    const entityGeneration = Number(entity.generation) + 1;
    const [entityUpdate] = await connection.query<ResultSetHeader>(
      `UPDATE synex_entities
       SET generation = ?, status = 'spawning', bucket_id = 0,
           last_reason_code = 'synex.entities.materialize', last_trace_id = ?,
           version = version + 1
       WHERE entity_id = ? AND version = ? AND status = ?`,
      [
        entityGeneration,
        candidate.traceId,
        entityId,
        Number(entity.version),
        entity.status,
      ],
    );
    assert.equal(entityUpdate.affectedRows, 1);
    await connection.commit();
    transactionOpen = false;
    return {
      entityGeneration,
      instanceId: candidate.instanceId,
      leaseGeneration,
      resourceEpoch: candidate.resourceEpoch,
      token: candidate.token,
    };
  } catch (error) {
    if (transactionOpen) await connection.rollback();
    throw error;
  }
}

test('live MariaDB fences Synex entity identities, bindings, and authority takeover', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  let firstContender: Connection | undefined;
  let secondContender: Connection | undefined;
  let migrationsApplied = false;
  const suffix = randomUUID().replaceAll('-', '');
  const entityIds = {
    persistentLeft: `entities_live_pk_a_${suffix}`,
    persistentRight: `entities_live_pk_b_${suffix}`,
    bindingLeft: `entities_live_bind_a_${suffix}`,
    bindingRight: `entities_live_bind_b_${suffix}`,
    authority: `entities_live_lease_${suffix}`,
  } as const;
  const allEntityIds = Object.values(entityIds);

  try {
    firstContender = (await openLiveDatabase()).connection;
    secondContender = (await openLiveDatabase()).connection;
    await applyMigrations(primary.connection, await loadMigrations());
    migrationsApplied = true;
    await Promise.all([
      configureConnection(primary.connection),
      configureConnection(firstContender),
      configureConnection(secondContender),
    ]);

    const [versions] = await primary.connection.query<VersionRow[]>(
      'SELECT VERSION() AS version',
    );
    assert.match(String(versions[0]?.version ?? ''), /mariadb/iu);

    const sharedPersistentKey = `live_entities:${suffix}:persistent`;
    const persistentRace = await Promise.allSettled([
      insertEntity(
        firstContender,
        entityIds.persistentLeft,
        sharedPersistentKey,
      ),
      insertEntity(
        secondContender,
        entityIds.persistentRight,
        sharedPersistentKey,
      ),
    ]);
    assertSingleUniqueWinner(persistentRace, 'persistent-key reservation');
    const [persistentRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT entity_id FROM synex_entities
       WHERE resource_owner = ? AND persistent_key = ?`,
      [resourceOwner, sharedPersistentKey],
    );
    assert.equal(persistentRows.length, 1);

    await insertEntity(
      primary.connection,
      entityIds.bindingLeft,
      `live_entities:${suffix}:binding_a`,
    );
    await insertEntity(
      primary.connection,
      entityIds.bindingRight,
      `live_entities:${suffix}:binding_b`,
    );
    const bindingNamespace = 'synex.live_entity_binding';
    const bindingReference = `binding:${suffix}`;
    const bindingRace = await Promise.allSettled([
      firstContender.query<ResultSetHeader>(
        `INSERT INTO synex_entity_bindings
         (entity_id, binding_namespace, binding_ref, owner_resource)
         VALUES (?, ?, ?, ?)`,
        [entityIds.bindingLeft, bindingNamespace, bindingReference, resourceOwner],
      ).then(([result]) => result.affectedRows),
      secondContender.query<ResultSetHeader>(
        `INSERT INTO synex_entity_bindings
         (entity_id, binding_namespace, binding_ref, owner_resource)
         VALUES (?, ?, ?, ?)`,
        [entityIds.bindingRight, bindingNamespace, bindingReference, resourceOwner],
      ).then(([result]) => result.affectedRows),
    ]);
    assertSingleUniqueWinner(bindingRace, 'binding reservation');
    const [bindingRows] = await primary.connection.query<RowDataPacket[]>(
      `SELECT entity_id FROM synex_entity_bindings
       WHERE binding_namespace = ? AND binding_ref = ? AND released_at IS NULL`,
      [bindingNamespace, bindingReference],
    );
    assert.equal(bindingRows.length, 1);

    await insertEntity(
      primary.connection,
      entityIds.authority,
      `live_entities:${suffix}:authority`,
    );
    const initialCandidates: readonly AuthorityCandidate[] = [
      {
        instanceId: `entity_instance_a_${suffix.slice(0, 12)}`,
        token: `entity_authority_a_${suffix}`,
        resourceEpoch: 11,
        traceId: `entity-live-initial-a:${suffix}`,
      },
      {
        instanceId: `entity_instance_b_${suffix.slice(0, 12)}`,
        token: `entity_authority_b_${suffix}`,
        resourceEpoch: 12,
        traceId: `entity-live-initial-b:${suffix}`,
      },
    ];
    const initialClaims = await Promise.all([
      claimAuthority(firstContender, entityIds.authority, initialCandidates[0]!),
      claimAuthority(secondContender, entityIds.authority, initialCandidates[1]!),
    ]);
    const initialWinners = initialClaims.filter(
      (claim): claim is LeaseClaim => claim !== null,
    );
    assert.equal(initialWinners.length, 1, 'initial authority claim must have one winner');
    assert.equal(initialWinners[0]?.leaseGeneration, 1);
    assert.equal(initialWinners[0]?.entityGeneration, 2);
    const oldAuthority = initialWinners[0]!;

    await primary.connection.beginTransaction();
    try {
      const [expiredLease] = await primary.connection.query<ResultSetHeader>(
        `UPDATE synex_entity_authority_leases
         SET claimed_at = TIMESTAMPADD(SECOND, -3, CURRENT_TIMESTAMP(6)),
             heartbeat_at = TIMESTAMPADD(SECOND, -2, CURRENT_TIMESTAMP(6)),
             lease_until = TIMESTAMPADD(SECOND, -1, CURRENT_TIMESTAMP(6))
         WHERE entity_id = ?`,
        [entityIds.authority],
      );
      assert.equal(expiredLease.affectedRows, 1);
      const [dematerialized] = await primary.connection.query<ResultSetHeader>(
        `UPDATE synex_entities
         SET status = 'dormant', last_reason_code = 'synex.entities.live_handoff',
             last_trace_id = ?, version = version + 1
         WHERE entity_id = ? AND generation = ? AND status = 'spawning'`,
        [
          `entity-live-handoff:${suffix}`,
          entityIds.authority,
          oldAuthority.entityGeneration,
        ],
      );
      assert.equal(dematerialized.affectedRows, 1);
      await primary.connection.commit();
    } catch (error) {
      await primary.connection.rollback();
      throw error;
    }
    const takeoverCandidates: readonly AuthorityCandidate[] = [
      {
        instanceId: `entity_instance_c_${suffix.slice(0, 12)}`,
        token: `entity_authority_c_${suffix}`,
        resourceEpoch: 21,
        traceId: `entity-live-takeover-c:${suffix}`,
      },
      {
        instanceId: `entity_instance_d_${suffix.slice(0, 12)}`,
        token: `entity_authority_d_${suffix}`,
        resourceEpoch: 22,
        traceId: `entity-live-takeover-d:${suffix}`,
      },
    ];
    const takeoverClaims = await Promise.all([
      claimAuthority(firstContender, entityIds.authority, takeoverCandidates[0]!),
      claimAuthority(secondContender, entityIds.authority, takeoverCandidates[1]!),
    ]);
    const takeoverWinners = takeoverClaims.filter(
      (claim): claim is LeaseClaim => claim !== null,
    );
    assert.equal(takeoverWinners.length, 1, 'expired authority takeover must have one winner');
    assert.equal(takeoverWinners[0]?.leaseGeneration, 2);
    assert.equal(takeoverWinners[0]?.entityGeneration, 3);
    const currentAuthority = takeoverWinners[0]!;

    const [activated] = await primary.connection.query<ResultSetHeader>(
      `UPDATE synex_entities
       SET status = 'active', last_materialized_at = CURRENT_TIMESTAMP(6),
           last_reason_code = 'synex.entities.materialized', last_trace_id = ?,
           version = version + 1
       WHERE entity_id = ? AND generation = ? AND status = 'spawning'`,
      [
        `entity-live-activated:${suffix}`,
        entityIds.authority,
        currentAuthority.entityGeneration,
      ],
    );
    assert.equal(activated.affectedRows, 1);

    const [storedLeases] = await primary.connection.query<StoredLeaseRow[]>(
      `SELECT instance_id, authority_token, resource_epoch, lease_generation
       FROM synex_entity_authority_leases WHERE entity_id = ?`,
      [entityIds.authority],
    );
    assert.equal(storedLeases.length, 1);
    assert.equal(storedLeases[0]?.instance_id, currentAuthority.instanceId);
    assert.equal(storedLeases[0]?.authority_token, currentAuthority.token);
    assert.equal(Number(storedLeases[0]?.resource_epoch), currentAuthority.resourceEpoch);
    assert.equal(Number(storedLeases[0]?.lease_generation), currentAuthority.leaseGeneration);
    const [storedEntities] = await primary.connection.query<StoredEntityRow[]>(
      `SELECT bucket_id, generation, status FROM synex_entities WHERE entity_id = ?`,
      [entityIds.authority],
    );
    assert.equal(storedEntities.length, 1);
    assert.equal(Number(storedEntities[0]?.generation), currentAuthority.entityGeneration);
    assert.equal(storedEntities[0]?.status, 'active');

    const [staleMutation] = await primary.connection.query<ResultSetHeader>(
      `UPDATE synex_entities AS e
       INNER JOIN synex_entity_authority_leases AS l ON l.entity_id = e.entity_id
       SET e.bucket_id = 41, e.last_reason_code = 'synex.entities.live_stale',
           e.last_trace_id = ?, e.version = e.version + 1
       WHERE e.entity_id = ? AND e.generation = ?
         AND e.resource_owner = ? AND e.status = 'active'
         AND l.server_scope = 'default' AND l.instance_id = ?
         AND l.authority_token = ? AND l.resource_epoch = ?
         AND l.lease_generation = ? AND l.lease_state = 'active'
         AND l.lease_until > CURRENT_TIMESTAMP(6)`,
      [
        `entity-live-stale:${suffix}`,
        entityIds.authority,
        oldAuthority.entityGeneration,
        resourceOwner,
        oldAuthority.instanceId,
        oldAuthority.token,
        oldAuthority.resourceEpoch,
        oldAuthority.leaseGeneration,
      ],
    );
    assert.equal(staleMutation.affectedRows, 0, 'stale authority must be fenced out');

    const [currentMutation] = await primary.connection.query<ResultSetHeader>(
      `UPDATE synex_entities AS e
       INNER JOIN synex_entity_authority_leases AS l ON l.entity_id = e.entity_id
       SET e.bucket_id = 42, e.last_reason_code = 'synex.entities.live_current',
           e.last_trace_id = ?, e.version = e.version + 1
       WHERE e.entity_id = ? AND e.generation = ?
         AND e.resource_owner = ? AND e.status = 'active'
         AND l.server_scope = 'default' AND l.instance_id = ?
         AND l.authority_token = ? AND l.resource_epoch = ?
         AND l.lease_generation = ? AND l.lease_state = 'active'
         AND l.lease_until > CURRENT_TIMESTAMP(6)`,
      [
        `entity-live-current:${suffix}`,
        entityIds.authority,
        currentAuthority.entityGeneration,
        resourceOwner,
        currentAuthority.instanceId,
        currentAuthority.token,
        currentAuthority.resourceEpoch,
        currentAuthority.leaseGeneration,
      ],
    );
    assert.equal(currentMutation.affectedRows, 1, 'current authority is the positive control');
    const [mutatedEntities] = await primary.connection.query<RowDataPacket[]>(
      `SELECT bucket_id FROM synex_entities WHERE entity_id = ?`,
      [entityIds.authority],
    );
    assert.equal(Number(mutatedEntities[0]?.bucket_id), 42);
  } finally {
    try {
      if (migrationsApplied) {
        const entityPlaceholders = placeholders(allEntityIds);
        await primary.connection.query(
          `DELETE FROM synex_entity_bindings WHERE entity_id IN (${entityPlaceholders})`,
          allEntityIds,
        );
        await primary.connection.query(
          `DELETE FROM synex_entity_authority_leases WHERE entity_id IN (${entityPlaceholders})`,
          allEntityIds,
        );
        await primary.connection.query(
          `DELETE FROM synex_entities WHERE entity_id IN (${entityPlaceholders})`,
          allEntityIds,
        );
      }
    } finally {
      await Promise.allSettled([
        primary.connection.end(),
        firstContender?.end(),
        secondContender?.end(),
      ]);
    }
  }
});
