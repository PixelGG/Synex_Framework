import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import test from 'node:test';
import type { ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';

const gate = liveDatabaseGate();

test('live Accounts migrations accept semantic hold dual-writes and default omitted grant validity', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    const holdLifecycle = migrations.find(
      (migration) => migration.relativePath
        === 'resources/synex_accounts/migrations/011_hold_lifecycle_v2.sql',
    );
    const accessGrantDefault = migrations.find(
      (migration) => migration.relativePath
        === 'resources/synex_accounts/migrations/018_access_grant_valid_from_default.sql',
    );
    assert.ok(holdLifecycle);
    assert.ok(accessGrantDefault);

    const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
    const [currency] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_currencies
       (public_id, currency_code, display_name, minor_unit, status)
       VALUES (?, ?, 'Migration portability token', 0, 'active')`,
      [randomUUID(), `m${suffix}`],
    );
    const accountIds: number[] = [];
    for (const accountKey of [`migration_source_${suffix}`, `migration_capture_${suffix}`]) {
      const [account] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_accounts
         (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json)
         VALUES (?, ?, ?, 'asset', 0, 'active', '{}')`,
        [randomUUID(), currency.insertId, accountKey],
      );
      accountIds.push(account.insertId);
    }
    const sourceAccountId = accountIds[0];
    const captureAccountId = accountIds[1];
    assert.ok(sourceAccountId);
    assert.ok(captureAccountId);

    const operationId = randomUUID();
    const traceId = randomUUID();
    const [operation] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_operations
       (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref,
        trace_id, operation_name, request_fingerprint, state, response_json, completed_at)
       VALUES (?, 'synex_live_test', 'resource', 'synex_live_test', ?,
         'hold_create', '{}', 'completed', '{}', CURRENT_TIMESTAMP(6))`,
      [operationId, traceId],
    );
    const holdPublicId = randomUUID();
    const [hold] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_holds
       (public_id, operation_id, account_id, capture_account_id, amount_minor,
        capture_policy, state, captured_minor, released_minor, remaining_minor,
        reason_code, source_resource, trace_id, actor_kind, actor_ref, metadata_json,
        expires_at, version)
       VALUES (?, ?, ?, ?, 500, 'multiple', 'active', 0, 0, 500,
         'synex_accounts.hold', 'synex_live_test', ?, 'resource', 'synex_live_test', '{}',
         TIMESTAMPADD(HOUR, 1, CURRENT_TIMESTAMP(6)), 1)`,
      [holdPublicId, operation.insertId, sourceAccountId, captureAccountId, traceId],
    );
    const legacyEventId = randomUUID();
    const runtimeEventId = randomUUID();
    assert.notEqual(runtimeEventId, legacyEventId);
    const [legacyEvent] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_hold_events
       (event_id, hold_id, sequence_no, event_type, terminal_marker,
        ledger_transaction_id, actor_ref, snapshot_json)
       VALUES (?, ?, 1, 'created', NULL, NULL, 'synex_live_test', '{}')`,
      [legacyEventId, hold.insertId],
    );
    const deterministicDigest = createHash('md5')
      .update(`synex-hold-event-v2:${legacyEvent.insertId}`, 'utf8')
      .digest('hex');
    const deterministicEventId = [
      deterministicDigest.slice(0, 8),
      deterministicDigest.slice(8, 12),
      deterministicDigest.slice(12, 16),
      deterministicDigest.slice(16, 20),
      deterministicDigest.slice(20, 32),
    ].join('-');
    assert.notEqual(runtimeEventId, deterministicEventId);
    await connection.query(
      `INSERT INTO synex_account_hold_events_v2
       (event_id, hold_id, operation_id, sequence_no, event_type, amount_minor,
        remaining_after_minor, ledger_transaction_id, reason_code, source_resource,
        trace_id, actor_kind, actor_ref, snapshot_json)
       VALUES (?, ?, ?, 1, 'created', 0, 500, NULL, 'synex_accounts.hold',
         'synex_live_test', ?, 'resource', 'synex_live_test', '{}')`,
      [runtimeEventId, hold.insertId, operation.insertId, traceId],
    );

    const legacyOperationId = randomUUID();
    const [legacyOperation] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_operations
       (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref,
        trace_id, operation_name, request_fingerprint, state, response_json, completed_at)
       VALUES (?, 'synex_live_test', 'resource', 'synex_live_test', ?,
         'hold_create', '{}', 'completed', '{}', CURRENT_TIMESTAMP(6))`,
      [legacyOperationId, randomUUID()],
    );
    const [legacyHold] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_holds
       (public_id, operation_id, account_id, capture_account_id, amount_minor,
        capture_policy, state, captured_minor, released_minor, remaining_minor,
        reason_code, source_resource, metadata_json, expires_at, version)
       VALUES (?, ?, ?, ?, 300, 'single', 'active', 0, 0, 300,
         'synex_accounts.hold', 'legacy', '{}',
         TIMESTAMPADD(HOUR, 1, CURRENT_TIMESTAMP(6)), 1)`,
      [randomUUID(), legacyOperation.insertId, sourceAccountId, captureAccountId],
    );
    await connection.query(
      `INSERT INTO synex_account_hold_events
       (event_id, hold_id, sequence_no, event_type, terminal_marker,
        ledger_transaction_id, actor_ref, snapshot_json)
       VALUES (?, ?, 1, 'created', NULL, NULL, NULL, '{}'),
         (?, ?, 2, 'released', 1, NULL, NULL, '{}')`,
      [randomUUID(), legacyHold.insertId, randomUUID(), legacyHold.insertId],
    );

    await connection.query(
      `INSERT INTO synex_account_balance_snapshots
       (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
       VALUES (?, 1, 'opening', ?, 1000, 200)`,
      [sourceAccountId, randomUUID()],
    );
    const expiredOperationId = randomUUID();
    const [expiredOperation] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_operations
       (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref,
        trace_id, operation_name, request_fingerprint, state, response_json, completed_at)
       VALUES (?, 'synex_live_test', 'resource', 'synex_live_test', ?,
         'hold_create', '{}', 'completed', '{}', CURRENT_TIMESTAMP(6))`,
      [expiredOperationId, randomUUID()],
    );
    const [expiredHold] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_holds
       (public_id, operation_id, account_id, capture_account_id, amount_minor,
        capture_policy, state, captured_minor, released_minor, remaining_minor,
        reason_code, source_resource, metadata_json, expires_at, created_at, version)
       VALUES (?, ?, ?, ?, 200, 'single', 'active', 0, 0, 200,
         'synex_accounts.hold', 'legacy', '{}',
         TIMESTAMPADD(HOUR, -1, CURRENT_TIMESTAMP(6)),
         TIMESTAMPADD(HOUR, -2, CURRENT_TIMESTAMP(6)), 1)`,
      [randomUUID(), expiredOperation.insertId, sourceAccountId, captureAccountId],
    );
    await connection.query(
      `INSERT INTO synex_account_hold_events
       (event_id, hold_id, sequence_no, event_type, terminal_marker,
        ledger_transaction_id, actor_ref, snapshot_json)
       VALUES (?, ?, 1, 'created', NULL, NULL, NULL, '{}')`,
      [randomUUID(), expiredHold.insertId],
    );

    await applyMigrations(connection, [holdLifecycle]);
    await applyMigrations(connection, [holdLifecycle]);
    const [assertionRows] = await connection.query<RowDataPacket[]>(
      `SELECT violation_count FROM synex_account_migration_assertions
       WHERE migration_id = '011_hold_lifecycle_v2'`,
    );
    assert.equal(Number(assertionRows[0]?.violation_count), 0);
    const [eventRows] = await connection.query<RowDataPacket[]>(
      `SELECT event_id FROM synex_account_hold_events_v2
       WHERE hold_id = ? AND sequence_no = 1 AND event_type = 'created'`,
      [hold.insertId],
    );
    assert.deepEqual(eventRows.map((row) => row.event_id), [runtimeEventId]);
    const [runtimeHoldRows] = await connection.query<RowDataPacket[]>(
      `SELECT capture_policy, state, CAST(captured_minor AS CHAR) AS captured_minor,
        CAST(released_minor AS CHAR) AS released_minor,
        CAST(remaining_minor AS CHAR) AS remaining_minor, reason_code, source_resource,
        trace_id, actor_kind, actor_ref, CAST(version AS CHAR) AS version
       FROM synex_account_holds WHERE id = ?`,
      [hold.insertId],
    );
    assert.deepEqual(runtimeHoldRows.map((row) => ({
      capturePolicy: row.capture_policy,
      state: row.state,
      capturedMinor: row.captured_minor,
      releasedMinor: row.released_minor,
      remainingMinor: row.remaining_minor,
      reasonCode: row.reason_code,
      sourceResource: row.source_resource,
      traceId: row.trace_id,
      actorKind: row.actor_kind,
      actorRef: row.actor_ref,
      version: row.version,
    })), [{
      capturePolicy: 'multiple',
      state: 'active',
      capturedMinor: '0',
      releasedMinor: '0',
      remainingMinor: '500',
      reasonCode: 'synex_accounts.hold',
      sourceResource: 'synex_live_test',
      traceId,
      actorKind: 'resource',
      actorRef: 'synex_live_test',
      version: '1',
    }]);
    const [legacyHoldRows] = await connection.query<RowDataPacket[]>(
      `SELECT capture_policy, state, CAST(captured_minor AS CHAR) AS captured_minor,
        CAST(released_minor AS CHAR) AS released_minor,
        CAST(remaining_minor AS CHAR) AS remaining_minor, source_resource, terminal_at
       FROM synex_account_holds WHERE id = ?`,
      [legacyHold.insertId],
    );
    assert.equal(legacyHoldRows[0]?.capture_policy, 'single');
    assert.equal(legacyHoldRows[0]?.state, 'released');
    assert.equal(legacyHoldRows[0]?.captured_minor, '0');
    assert.equal(legacyHoldRows[0]?.released_minor, '300');
    assert.equal(legacyHoldRows[0]?.remaining_minor, '0');
    assert.equal(legacyHoldRows[0]?.source_resource, 'legacy');
    assert.ok(legacyHoldRows[0]?.terminal_at);
    const [expiryRows] = await connection.query<RowDataPacket[]>(
      `SELECT
        (SELECT COUNT(*) FROM synex_account_hold_events_v2
          WHERE hold_id = ? AND event_type = 'expired'
            AND source_resource = 'migration') AS event_count,
        (SELECT COUNT(*) FROM synex_account_balance_snapshots
          WHERE account_id = ? AND source_kind = 'hold') AS snapshot_count,
        (SELECT reserved_minor FROM synex_account_balance_snapshots
          WHERE account_id = ? AND source_kind = 'hold' ORDER BY sequence_no DESC LIMIT 1)
          AS corrected_reserved_minor,
        (SELECT violation_count FROM synex_account_migration_assertions
          WHERE migration_id = '011_hold_expiry_precondition') AS precondition_violations`,
      [expiredHold.insertId, sourceAccountId, sourceAccountId],
    );
    assert.equal(Number(expiryRows[0]?.event_count), 1);
    assert.equal(Number(expiryRows[0]?.snapshot_count), 1);
    assert.equal(Number(expiryRows[0]?.corrected_reserved_minor), 0);
    assert.equal(Number(expiryRows[0]?.precondition_violations), 0);

    await applyMigrations(connection, [accessGrantDefault]);
    const [metadataRows] = await connection.query<RowDataPacket[]>(
      `SELECT LOWER(DATA_TYPE) AS data_type, DATETIME_PRECISION AS datetime_precision,
        IS_NULLABLE AS is_nullable,
        LOWER(REPLACE(CAST(COLUMN_DEFAULT AS CHAR), ' ', '')) AS column_default
       FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'synex_account_access_grants'
         AND COLUMN_NAME = 'valid_from'`,
    );
    assert.deepEqual(metadataRows.map((row) => ({
      dataType: row.data_type,
      datetimePrecision: Number(row.datetime_precision),
      isNullable: row.is_nullable,
      columnDefault: row.column_default,
    })), [{
      dataType: 'datetime',
      datetimePrecision: 6,
      isNullable: 'NO',
      columnDefault: 'current_timestamp(6)',
    }]);

    const [role] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_account_access_roles
       (public_id, account_id, role_key, display_name, version)
       VALUES (?, ?, 'migration_probe', 'Migration probe', 1)`,
      [randomUUID(), sourceAccountId],
    );
    const grantId = randomUUID();
    await connection.query(
      `INSERT INTO synex_account_access_grants
       (public_id, account_id, role_id, principal_kind, principal_ref)
       VALUES (?, ?, ?, 'resource', ?)`,
      [grantId, sourceAccountId, role.insertId, `migration_probe:${suffix}`],
    );
    const [grantRows] = await connection.query<RowDataPacket[]>(
      `SELECT valid_from,
        ABS(TIMESTAMPDIFF(MICROSECOND, valid_from, CURRENT_TIMESTAMP(6))) AS age_microseconds
       FROM synex_account_access_grants WHERE public_id = ?`,
      [grantId],
    );
    assert.ok(grantRows[0]?.valid_from);
    assert.ok(Number(grantRows[0]?.age_microseconds) < 5_000_000);
  } finally {
    await connection.end();
  }
});
