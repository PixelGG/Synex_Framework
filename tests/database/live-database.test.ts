import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import test from 'node:test';
import type { Connection, ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import { importReviewedMigrationPlan, type ImportDatabase } from '../../tools/migrator/src/importer.js';
import {
  buildMigrationPlan,
  validateMapping,
  validateSource,
} from '../../tools/migrator/src/migrator.js';
import {
  loadCompatibilityAccountCatalog,
  ownerScopedCompatibilityAccountKey,
} from '../../tools/migrator/src/compatibility-accounts.js';
import { validateCompatibilityGroupCatalog } from '../../tools/migrator/src/compatibility-groups.js';
import { loadCompatibilityMetadataCatalog } from '../../tools/migrator/src/compatibility-metadata.js';
import { applyMigrations, liveDatabaseGate, loadMigrations, openLiveDatabase } from './harness.js';

const migrationAccountCatalog = await loadCompatibilityAccountCatalog();
const migrationMetadataCatalog = await loadCompatibilityMetadataCatalog();

interface EngineRow extends RowDataPacket {
  table_name: string;
  engine: string;
}

interface ConstraintRow extends RowDataPacket {
  constraint_name: string;
}

interface OperationRow extends RowDataPacket {
  operation_name: string;
  request_fingerprint: string;
  state: string;
  response_json: string | null;
}

interface BalanceRow extends RowDataPacket {
  public_id: string;
  sequence_no: string | number;
  booked_minor: string | number;
  reserved_minor: string | number;
  snapshot_count: string | number;
  minimum_booked_minor: string | number;
}

interface PostingRow extends RowDataPacket {
  debit_account_id: string;
  credit_account_id: string;
  debit_minor: string | number;
  credit_minor: string | number;
}

interface AggregateRow extends RowDataPacket {
  transaction_count: string | number;
  posting_count: string | number;
  operation_count: string | number;
  audit_count: string | number;
  outbox_count: string | number;
}

interface LeaseRow extends RowDataPacket {
  owner_id: string;
  fencing_token: string | number;
  currently_valid: string | number;
}

interface TransferInput {
  idempotencyKey: string;
  fingerprint: string;
  sourceAccountId: string;
  destinationAccountId: string;
  amountMinor: number;
  transactionId: string;
  postingId: string;
  debitEntryId: string;
  creditEntryId: string;
  eventId: string;
}

interface Fixture {
  currencyInternalId: number;
  firstAccountId: string;
  secondAccountId: string;
}

function asNumber(value: string | number): number {
  return typeof value === 'number' ? value : Number.parseInt(value, 10);
}

function isRetryableTransactionError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null || !('code' in error)) return false;
  return error.code === 'ER_LOCK_DEADLOCK' || error.code === 'ER_LOCK_WAIT_TIMEOUT';
}

async function retryTransaction<T>(operation: () => Promise<T>): Promise<T> {
  const maximumAttempts = 5;
  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      if (!isRetryableTransactionError(error) || attempt === maximumAttempts) throw error;
      await new Promise<void>((resolve) => setTimeout(resolve, attempt));
    }
  }
  throw new Error('transaction retry bound exhausted');
}

function importDatabase(connection: Connection): ImportDatabase {
  return {
    begin: async () => connection.beginTransaction(),
    commit: async () => connection.commit(),
    rollback: async () => connection.rollback(),
    close: async () => undefined,
    execute: async (sql, parameters = []) => {
      const [raw] = await connection.execute(sql, [...parameters]);
      if (Array.isArray(raw)) {
        return {
          rows: raw.map((row) => ({ ...(row as RowDataPacket) })),
          insertId: 0,
          affectedRows: raw.length,
        };
      }
      const header = raw as ResultSetHeader;
      return { rows: [], insertId: header.insertId, affectedRows: header.affectedRows };
    },
  };
}

async function completedTransfer(connection: Connection, input: TransferInput): Promise<string | undefined> {
  const [rows] = await connection.query<OperationRow[]>(
    `SELECT operation_name, request_fingerprint, state, response_json
     FROM synex_account_operations WHERE idempotency_key = ?
       AND caller_resource = 'synex_live_test' AND caller_principal_kind = 'resource'
       AND caller_principal_ref = 'synex_live_test' AND operation_name = 'transfer'`,
    [input.idempotencyKey],
  );
  const operation = rows[0];
  if (!operation) return undefined;
  assert.equal(operation.operation_name, 'transfer');
  assert.equal(operation.request_fingerprint, input.fingerprint);
  assert.equal(operation.state, 'completed');
  if (typeof operation.response_json !== 'string') {
    throw new Error('completed operation has no response');
  }
  const response = JSON.parse(operation.response_json) as unknown;
  assert.ok(response && typeof response === 'object');
  const transactionId = (response as Record<string, unknown>).transaction_id;
  if (typeof transactionId !== 'string') {
    throw new Error('completed operation response has no transaction_id');
  }
  return transactionId;
}

async function assertOneRow(
  connection: Connection,
  sql: string,
  parameters: readonly unknown[],
  message: string,
): Promise<void> {
  const [result] = await connection.query<ResultSetHeader>(sql, [...parameters]);
  assert.equal(result.affectedRows, 1, message);
}

async function transferAtomicallyOnce(connection: Connection, input: TransferInput): Promise<string> {
  const replayed = await completedTransfer(connection, input);
  if (replayed) return replayed;

  const responseJson = JSON.stringify({
    transaction_id: input.transactionId,
    posting_id: input.postingId,
    transaction_kind: 'transfer',
    debit_account_id: input.sourceAccountId,
    credit_account_id: input.destinationAccountId,
    debit_minor: input.amountMinor,
    credit_minor: input.amountMinor,
  });

  await connection.query('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.beginTransaction();
  try {
    await assertOneRow(
      connection,
      `INSERT INTO synex_account_operations
       (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref, trace_id,
         operation_name, request_fingerprint, state)
       VALUES (?, 'synex_live_test', 'resource', 'synex_live_test', ?, 'transfer', ?, 'pending')`,
      [input.idempotencyKey, input.idempotencyKey, input.fingerprint],
      'the operation claim must be unique',
    );

    const lockOrder = [input.sourceAccountId, input.destinationAccountId].sort();
    for (const accountId of lockOrder) {
      const [accounts] = await connection.query<RowDataPacket[]>(
        'SELECT id FROM synex_accounts WHERE public_id = ? FOR UPDATE',
        [accountId],
      );
      assert.equal(accounts.length, 1, 'the locked account must exist');
    }
    for (const accountId of lockOrder) {
      const [snapshots] = await connection.query<RowDataPacket[]>(
        `SELECT snapshot.id FROM synex_account_balance_snapshots AS snapshot
         INNER JOIN synex_accounts AS account ON account.id = snapshot.account_id
         WHERE account.public_id = ?
           AND snapshot.sequence_no = (
             SELECT MAX(latest.sequence_no) FROM synex_account_balance_snapshots AS latest
             WHERE latest.account_id = account.id
           )
         FOR UPDATE`,
        [accountId],
      );
      assert.equal(snapshots.length, 1, 'the latest snapshot must exist');
    }

    await assertOneRow(
      connection,
      `INSERT INTO synex_ledger_transactions
       (public_id, operation_id, currency_id, posting_model, entry_count, transaction_kind,
         reason_code, source_resource, trace_id, actor_kind, actor_ref, reference_text,
         metadata_json, status, posted_at)
       SELECT ?, operation.id, source.currency_id, 'multi_leg', 2, 'transfer',
         'synex_accounts.legacy.transfer', 'synex_live_test', ?, 'resource',
         'synex_live_test', NULL, '{}', 'posted', CURRENT_TIMESTAMP(6)
       FROM synex_accounts AS source
       INNER JOIN synex_accounts AS destination
         ON destination.public_id = ?
        AND destination.currency_id = source.currency_id
        AND destination.status = 'active'
        AND destination.account_role = 'asset'
       INNER JOIN synex_account_operations AS operation ON operation.idempotency_key = ?
         AND operation.caller_resource = 'synex_live_test'
         AND operation.caller_principal_kind = 'resource'
         AND operation.caller_principal_ref = 'synex_live_test'
         AND operation.operation_name = 'transfer'
       INNER JOIN synex_account_balance_snapshots AS balance
         ON balance.account_id = source.id
        AND balance.sequence_no = (
          SELECT MAX(latest.sequence_no) FROM synex_account_balance_snapshots AS latest
          WHERE latest.account_id = source.id
        )
       WHERE source.public_id = ?
         AND source.status = 'active'
         AND source.account_role = 'asset'
         AND (source.allow_negative = 1 OR balance.booked_minor - balance.reserved_minor >= ?)`,
      [
        input.transactionId,
        input.idempotencyKey,
        input.destinationAccountId,
        input.idempotencyKey,
        input.sourceAccountId,
        input.amountMinor,
      ],
      'the locked source must have sufficient funds',
    );

    await assertOneRow(
      connection,
      `INSERT INTO synex_ledger_entries
       (public_id, transaction_id, account_id, sequence_no, amount_minor, metadata_json)
       SELECT ?, ledger_transaction.id, account.id, 1, ?, '{}'
       FROM synex_ledger_transactions ledger_transaction, synex_accounts account
       WHERE ledger_transaction.public_id = ? AND account.public_id = ?`,
      [input.debitEntryId, -input.amountMinor, input.transactionId, input.sourceAccountId],
      'the signed debit entry must be appended',
    );
    await assertOneRow(
      connection,
      `INSERT INTO synex_ledger_entries
       (public_id, transaction_id, account_id, sequence_no, amount_minor, metadata_json)
       SELECT ?, ledger_transaction.id, account.id, 2, ?, '{}'
       FROM synex_ledger_transactions ledger_transaction, synex_accounts account
       WHERE ledger_transaction.public_id = ? AND account.public_id = ?`,
      [input.creditEntryId, input.amountMinor, input.transactionId, input.destinationAccountId],
      'the signed credit entry must be appended',
    );

    await assertOneRow(
      connection,
      `INSERT INTO synex_ledger_postings
       (public_id, transaction_id, debit_account_id, credit_account_id, debit_minor, credit_minor)
       VALUES (
         ?,
         (SELECT id FROM synex_ledger_transactions WHERE public_id = ?),
         (SELECT id FROM synex_accounts WHERE public_id = ?),
         (SELECT id FROM synex_accounts WHERE public_id = ?),
         ?,
         ?
       )`,
      [
        input.postingId,
        input.transactionId,
        input.sourceAccountId,
        input.destinationAccountId,
        input.amountMinor,
        input.amountMinor,
      ],
      'one balanced posting must be appended',
    );

    await assertOneRow(
      connection,
      `INSERT INTO synex_account_balance_snapshots
       (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
       SELECT account.id, previous.sequence_no + 1, 'ledger', ?,
              previous.booked_minor - ?, previous.reserved_minor
       FROM synex_accounts AS account
       INNER JOIN synex_account_balance_snapshots AS previous
         ON previous.account_id = account.id
        AND previous.sequence_no = (
          SELECT MAX(latest.sequence_no) FROM synex_account_balance_snapshots AS latest
          WHERE latest.account_id = account.id
        )
       WHERE account.public_id = ?
         AND (account.allow_negative = 1 OR previous.booked_minor - previous.reserved_minor >= ?)`,
      [input.transactionId, input.amountMinor, input.sourceAccountId, input.amountMinor],
      'the debit snapshot must advance once without going negative',
    );

    await assertOneRow(
      connection,
      `INSERT INTO synex_account_balance_snapshots
       (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
       SELECT account.id, previous.sequence_no + 1, 'ledger', ?,
              previous.booked_minor + ?, previous.reserved_minor
       FROM synex_accounts AS account
       INNER JOIN synex_account_balance_snapshots AS previous
         ON previous.account_id = account.id
        AND previous.sequence_no = (
          SELECT MAX(latest.sequence_no) FROM synex_account_balance_snapshots AS latest
          WHERE latest.account_id = account.id
        )
       WHERE account.public_id = ?`,
      [input.transactionId, input.amountMinor, input.destinationAccountId],
      'the credit snapshot must advance once',
    );

    await assertOneRow(
      connection,
      `INSERT INTO synex_account_audit
       (event_id, operation_id, event_type, aggregate_id, source_resource, trace_id,
         actor_kind, actor_ref, snapshot_json)
       VALUES (
         ?,
         (SELECT id FROM synex_account_operations WHERE idempotency_key = ?
           AND caller_resource = 'synex_live_test' AND caller_principal_kind = 'resource'
           AND caller_principal_ref = 'synex_live_test' AND operation_name = 'transfer'),
         'synex.accounts.transfer',
         ?,
         'synex_live_test',
         ?,
         'resource',
         'synex_live_test',
         ?
       )`,
      [input.eventId, input.idempotencyKey, input.transactionId, input.idempotencyKey, responseJson],
      'the audit record must be atomic with the transfer',
    );
    await assertOneRow(
      connection,
      `INSERT INTO synex_account_outbox
       (event_id, aggregate_id, event_type, schema_version, trace_id, payload_json)
       VALUES (?, ?, 'synex.accounts.transfer', 1, ?, ?)`,
      [input.eventId, input.transactionId, input.idempotencyKey, responseJson],
      'the outbox record must be atomic with the transfer',
    );
    await assertOneRow(
      connection,
      `UPDATE synex_account_operations
       SET state = 'completed', response_json = ?, completed_at = CURRENT_TIMESTAMP(6)
       WHERE idempotency_key = ? AND caller_resource = 'synex_live_test'
         AND caller_principal_kind = 'resource' AND caller_principal_ref = 'synex_live_test'
         AND operation_name = 'transfer' AND state = 'pending'`,
      [responseJson, input.idempotencyKey],
      'the idempotent response must complete atomically',
    );

    await connection.commit();
    return input.transactionId;
  } catch (error) {
    try {
      await connection.rollback();
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], 'transfer and rollback both failed');
    }
    const winner = await completedTransfer(connection, input);
    if (winner) return winner;
    throw error;
  }
}

async function transferAtomically(connection: Connection, input: TransferInput): Promise<string> {
  return retryTransaction(() => transferAtomicallyOnce(connection, input));
}

function transferInput(
  sourceAccountId: string,
  destinationAccountId: string,
  amountMinor: number,
  idempotencyKey = randomUUID(),
): TransferInput {
  return {
    idempotencyKey,
    fingerprint: JSON.stringify({ sourceAccountId, destinationAccountId, amountMinor }),
    sourceAccountId,
    destinationAccountId,
    amountMinor,
    transactionId: randomUUID(),
    postingId: randomUUID(),
    debitEntryId: randomUUID(),
    creditEntryId: randomUUID(),
    eventId: randomUUID(),
  };
}

async function createTransferFixture(
  connection: Connection,
  firstOpeningBalance = 1000,
  secondOpeningBalance = 1000,
): Promise<Fixture> {
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const currencyCode = `t${suffix}`;
  const currencyPublicId = randomUUID();
  const [currency] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_currencies
     (public_id, currency_code, display_name, minor_unit, status)
     VALUES (?, ?, 'Live concurrency token', 0, 'active')`,
    [currencyPublicId, currencyCode],
  );

  const firstAccountId = randomUUID();
  const secondAccountId = randomUUID();
  const internalIds: number[] = [];
  for (const [publicId, accountKey, openingBalance] of [
    [firstAccountId, `live_a_${suffix}`, firstOpeningBalance],
    [secondAccountId, `live_b_${suffix}`, secondOpeningBalance],
  ] as const) {
    const [account] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_accounts
       (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json)
       VALUES (?, ?, ?, 'asset', 0, 'active', '{}')`,
      [publicId, currency.insertId, accountKey],
    );
    internalIds.push(account.insertId);
    await connection.query(
      `INSERT INTO synex_account_owners (account_id, owner_kind, owner_ref)
       VALUES (?, 'system', 'synex_live_test')`,
      [account.insertId],
    );
    await connection.query(
      `INSERT INTO synex_account_balance_snapshots
       (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
       VALUES (?, 0, 'opening', ?, ?, 0)`,
      [account.insertId, randomUUID(), openingBalance],
    );
  }
  assert.equal(internalIds.length, 2);
  return { currencyInternalId: currency.insertId, firstAccountId, secondAccountId };
}

async function createHoldAtomicallyOnce(
  connection: Connection,
  sourceAccountId: string,
  captureAccountId: string,
  amountMinor: number,
): Promise<string> {
  const operationId = randomUUID();
  const holdId = randomUUID();
  const legacyEventId = randomUUID();
  const holdEventId = randomUUID();
  const domainEventId = randomUUID();
  const responseJson = JSON.stringify({ hold_id: holdId, amount_minor: amountMinor, state: 'active' });
  await connection.query('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.beginTransaction();
  try {
    await assertOneRow(connection,
      `INSERT INTO synex_account_operations
       (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref, trace_id,
         operation_name, request_fingerprint, state)
       VALUES (?, 'synex_live_test', 'resource', 'synex_live_test', ?, 'hold_create', ?, 'pending')`,
      [operationId, operationId, JSON.stringify({ sourceAccountId, captureAccountId, amountMinor })],
      'the hold operation claim must be unique');
    const lockOrder = [sourceAccountId, captureAccountId].sort();
    for (const accountId of lockOrder) {
      const [accounts] = await connection.query<RowDataPacket[]>(
        `SELECT account.id FROM synex_accounts account WHERE account.public_id = ?
         AND account.status = 'active' AND account.account_role = 'asset' FOR UPDATE`,
        [accountId],
      );
      assert.equal(accounts.length, 1, 'the hold account must be an active asset account');
    }
    const [snapshots] = await connection.query<RowDataPacket[]>(
      `SELECT account.id AS account_id, snapshot.sequence_no, snapshot.booked_minor,
        snapshot.reserved_minor
       FROM synex_accounts account
       INNER JOIN synex_account_balance_snapshots snapshot ON snapshot.account_id = account.id
        AND snapshot.sequence_no = (SELECT MAX(latest.sequence_no)
          FROM synex_account_balance_snapshots latest WHERE latest.account_id = account.id)
       WHERE account.public_id = ? FOR UPDATE`,
      [sourceAccountId],
    );
    const snapshot = snapshots[0];
    assert.ok(snapshot);
    const booked = asNumber(snapshot.booked_minor as string | number);
    const reserved = asNumber(snapshot.reserved_minor as string | number);
    if (booked - reserved < amountMinor) throw new Error('insufficient funds for concurrent hold');
    await assertOneRow(connection,
      `INSERT INTO synex_account_holds
       (public_id, operation_id, account_id, capture_account_id, amount_minor, capture_policy,
         state, captured_minor, released_minor, remaining_minor, reason_code, source_resource,
         trace_id, actor_kind, actor_ref, metadata_json, expires_at, version)
       SELECT ?, operation.id, source.id, destination.id, ?, 'multiple', 'active', 0, 0, ?,
         'synex_accounts.hold', 'synex_live_test', ?, 'resource', 'synex_live_test', '{}',
         TIMESTAMPADD(HOUR, 1, CURRENT_TIMESTAMP(6)), 1
       FROM synex_account_operations operation, synex_accounts source, synex_accounts destination
       WHERE operation.idempotency_key = ? AND operation.caller_resource = 'synex_live_test'
         AND operation.caller_principal_kind = 'resource'
         AND operation.caller_principal_ref = 'synex_live_test'
         AND operation.operation_name = 'hold_create'
         AND source.public_id = ? AND destination.public_id = ?
         AND source.currency_id = destination.currency_id`,
      [holdId, amountMinor, amountMinor, operationId, operationId, sourceAccountId, captureAccountId],
      'the active hold must be persisted');
    await assertOneRow(connection,
      `INSERT INTO synex_account_hold_events
       (event_id, hold_id, sequence_no, event_type, terminal_marker,
         ledger_transaction_id, actor_ref, snapshot_json)
       SELECT ?, id, 1, 'created', NULL, NULL, 'synex_live_test', ?
       FROM synex_account_holds WHERE public_id = ?`,
      [legacyEventId, responseJson, holdId], 'the legacy-compatible hold event must be persisted');
    await assertOneRow(connection,
      `INSERT INTO synex_account_hold_events_v2
       (event_id, hold_id, operation_id, sequence_no, event_type, amount_minor,
         remaining_after_minor, ledger_transaction_id, reason_code, source_resource,
         trace_id, actor_kind, actor_ref, snapshot_json)
       SELECT ?, hold_record.id, operation.id, 1, 'created', 0, ?, NULL,
         'synex_accounts.hold', 'synex_live_test', ?, 'resource', 'synex_live_test', ?
       FROM synex_account_holds hold_record, synex_account_operations operation
       WHERE hold_record.public_id = ? AND operation.idempotency_key = ?
         AND operation.caller_resource = 'synex_live_test'
         AND operation.caller_principal_kind = 'resource'
         AND operation.caller_principal_ref = 'synex_live_test'
         AND operation.operation_name = 'hold_create'`,
      [holdEventId, amountMinor, operationId, responseJson, holdId, operationId],
      'the current hold event must be persisted');
    await assertOneRow(connection,
      `INSERT INTO synex_account_balance_snapshots
       (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
       VALUES (?, ?, 'hold', ?, ?, ?)`,
      [Number(snapshot.account_id), asNumber(snapshot.sequence_no as string | number) + 1,
        holdId, booked, reserved + amountMinor],
      'the reservation snapshot must advance atomically');
    await assertOneRow(connection,
      `INSERT INTO synex_account_audit
       (event_id, operation_id, event_type, aggregate_id, source_resource, trace_id,
         actor_kind, actor_ref, snapshot_json)
       SELECT ?, id, 'synex.accounts.hold.created', ?, 'synex_live_test', ?,
         'resource', 'synex_live_test', ? FROM synex_account_operations
       WHERE idempotency_key = ? AND caller_resource = 'synex_live_test'
         AND caller_principal_kind = 'resource' AND caller_principal_ref = 'synex_live_test'
         AND operation_name = 'hold_create'`,
      [domainEventId, holdId, operationId, responseJson, operationId],
      'the hold audit record must commit atomically');
    await assertOneRow(connection,
      `INSERT INTO synex_account_outbox
       (event_id, aggregate_id, event_type, schema_version, trace_id, payload_json)
       VALUES (?, ?, 'synex.accounts.hold.created', 1, ?, ?)`,
      [domainEventId, holdId, operationId, responseJson],
      'the hold outbox record must commit atomically');
    await assertOneRow(connection,
      `UPDATE synex_account_operations SET state = 'completed', response_json = ?,
         completed_at = CURRENT_TIMESTAMP(6)
       WHERE idempotency_key = ? AND caller_resource = 'synex_live_test'
         AND caller_principal_kind = 'resource' AND caller_principal_ref = 'synex_live_test'
         AND operation_name = 'hold_create' AND state = 'pending'`,
      [responseJson, operationId], 'the hold operation must complete atomically');
    await connection.commit();
    return holdId;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function createHoldAtomically(
  connection: Connection,
  sourceAccountId: string,
  captureAccountId: string,
  amountMinor: number,
): Promise<string> {
  return retryTransaction(() => createHoldAtomicallyOnce(
    connection,
    sourceAccountId,
    captureAccountId,
    amountMinor,
  ));
}

const gate = liveDatabaseGate();

test('live MariaDB/MySQL applies every migration and exposes enforced account constraints', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection, databaseName } = await openLiveDatabase();
  try {
    const migrations = await loadMigrations();
    await applyMigrations(connection, migrations);
    const slotMigration = migrations.find(
      (migration) => migration.file === '018_character_slot_reuse.sql',
    );
    assert.ok(slotMigration, 'character slot reuse migration is missing');
    await connection.query(
      'ALTER TABLE synex_characters DROP INDEX uq_characters_user_slot_active',
    );
    await connection.query(
      'ALTER TABLE synex_characters DROP COLUMN active_slot_marker',
    );
    await connection.query(
      `ALTER TABLE synex_characters
       ADD COLUMN active_slot_marker TINYINT UNSIGNED
       GENERATED ALWAYS AS (CASE WHEN deleted_at IS NOT NULL THEN 1 ELSE NULL END) STORED`,
    );
    await connection.query(
      'ALTER TABLE synex_characters ADD INDEX uq_characters_user_slot (user_id, slot)',
    );
    try {
      await assert.rejects(
        applyMigrations(connection, [slotMigration]),
        /active slot marker definition verification failed/iu,
      );
      const [failedSlotIndexes] = await connection.query<RowDataPacket[]>(
        `SELECT index_name FROM information_schema.statistics
         WHERE table_schema = ? AND table_name = 'synex_characters'
           AND index_name IN ('uq_characters_user_slot', 'uq_characters_user_slot_active')`,
        [databaseName],
      );
      assert.equal(
        failedSlotIndexes.some((row) => row.index_name === 'uq_characters_user_slot'),
        true,
      );
      assert.equal(
        failedSlotIndexes.some((row) => row.index_name === 'uq_characters_user_slot_active'),
        false,
      );
    } finally {
      await connection.query('DROP PROCEDURE IF EXISTS synex_migrate_018_character_slot_reuse');
      const [cleanupIndexes] = await connection.query<RowDataPacket[]>(
        `SELECT DISTINCT index_name FROM information_schema.statistics
         WHERE table_schema = ? AND table_name = 'synex_characters'
           AND index_name IN ('uq_characters_user_slot', 'uq_characters_user_slot_active')`,
        [databaseName],
      );
      if (cleanupIndexes.some((row) => row.index_name === 'uq_characters_user_slot')) {
        await connection.query('ALTER TABLE synex_characters DROP INDEX uq_characters_user_slot');
      }
      if (cleanupIndexes.some((row) => row.index_name === 'uq_characters_user_slot_active')) {
        await connection.query('ALTER TABLE synex_characters DROP INDEX uq_characters_user_slot_active');
      }
      await connection.query('ALTER TABLE synex_characters DROP COLUMN active_slot_marker');
      await applyMigrations(connection, [slotMigration]);
    }
    const [engines] = await connection.query<EngineRow[]>(
      `SELECT table_name, engine FROM information_schema.tables
       WHERE table_schema = ? AND table_name LIKE 'synex\\_%' ESCAPE '\\\\'`,
      [databaseName],
    );
    assert.ok(engines.length >= 47);
    assert.ok(engines.every((row) => row.engine.toLowerCase() === 'innodb'));

    const [checks] = await connection.query<ConstraintRow[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE table_schema = ? AND table_name = 'synex_ledger_postings' AND constraint_type = 'CHECK'`,
      [databaseName],
    );
    const names = new Set(checks.map((row) => row.constraint_name));
    assert.ok(names.has('chk_ledger_postings_balanced'));
    assert.ok(names.has('chk_ledger_postings_accounts'));

    const [foreignKeys] = await connection.query<ConstraintRow[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE table_schema = ? AND table_name = 'synex_account_hold_events'
         AND constraint_type = 'FOREIGN KEY'`,
      [databaseName],
    );
    assert.ok(foreignKeys.length >= 2);

    const [foundationChecks] = await connection.query<ConstraintRow[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE table_schema = ? AND constraint_name IN (
         'chk_group_grade_capability_effect',
         'chk_account_access_permissions_key',
         'chk_economy_anomaly_findings_severity',
         'chk_economy_integrity_status'
       ) AND constraint_type = 'CHECK'`,
      [databaseName],
    );
    assert.deepEqual(
      new Set(foundationChecks.map((row) => row.constraint_name)),
      new Set([
        'chk_group_grade_capability_effect',
        'chk_account_access_permissions_key',
        'chk_economy_anomaly_findings_severity',
        'chk_economy_integrity_status',
      ]),
    );

    const [reversalForeignKeys] = await connection.query<ConstraintRow[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE table_schema = ? AND table_name = 'synex_ledger_reversals'
         AND constraint_type = 'FOREIGN KEY'`,
      [databaseName],
    );
    assert.equal(reversalForeignKeys.length, 2);

    const [scalabilityIndexes] = await connection.query<RowDataPacket[]>(
      `SELECT table_name, index_name, seq_in_index, column_name
       FROM information_schema.statistics
       WHERE table_schema = ? AND index_name IN (
         'idx_sessions_instance_generation',
         'idx_sessions_instance_open',
         'idx_session_control_requester_pending',
         'idx_session_control_target_pending',
         'idx_session_control_state_scan',
         'idx_cluster_leases_owner_expiry',
         'idx_cluster_leases_domain_expiry',
         'idx_cluster_leases_terminal_compaction',
         'idx_sessions_character_open',
         'idx_sessions_user_open',
         'idx_audit_log_archive_queue'
       ) ORDER BY table_name, index_name, seq_in_index`,
      [databaseName],
    );
    const indexShapes = new Map<string, string[]>();
    for (const row of scalabilityIndexes) {
      const name = String(row.index_name);
      const columns = indexShapes.get(name) ?? [];
      columns.push(String(row.column_name));
      indexShapes.set(name, columns);
    }
    assert.deepEqual(indexShapes.get('idx_sessions_instance_generation'), [
      'server_instance_id', 'source_generation',
    ]);
    assert.deepEqual(indexShapes.get('idx_sessions_instance_open'), [
      'server_instance_id', 'closed_at', 'id',
    ]);
    assert.deepEqual(indexShapes.get('idx_session_control_requester_pending'), [
      'requested_by_instance_id', 'state', 'created_at', 'request_id',
    ]);
    assert.deepEqual(indexShapes.get('idx_session_control_target_pending'), [
      'target_instance_id', 'state', 'expires_at', 'created_at', 'request_id',
    ]);
    assert.deepEqual(indexShapes.get('idx_session_control_state_scan'), [
      'state', 'request_id',
    ]);
    assert.deepEqual(indexShapes.get('idx_cluster_leases_owner_expiry'), [
      'owner_id', 'expires_at', 'lease_name',
    ]);
    assert.deepEqual(indexShapes.get('idx_cluster_leases_domain_expiry'), [
      'lease_domain_kind', 'expires_at', 'lease_name',
    ]);
    assert.deepEqual(indexShapes.get('idx_cluster_leases_terminal_compaction'), [
      'terminal_compaction_at', 'lease_name',
    ]);
    assert.deepEqual(indexShapes.get('idx_sessions_character_open'), [
      'character_id', 'closed_at', 'id',
    ]);
    assert.deepEqual(indexShapes.get('idx_sessions_user_open'), [
      'user_id', 'closed_at', 'connected_at', 'id',
    ]);
    assert.deepEqual(indexShapes.get('idx_audit_log_archive_queue'), [
      'archive_recorded_at', 'occurred_at', 'id',
    ]);

    const [scalabilityColumns] = await connection.query<RowDataPacket[]>(
      `SELECT table_name, column_name, data_type, character_maximum_length,
              datetime_precision, is_nullable, extra
       FROM information_schema.columns
       WHERE table_schema = ? AND (
         (table_name = 'synex_cluster_leases' AND column_name = 'lease_domain_kind')
         OR (table_name = 'synex_cluster_leases' AND column_name = 'terminal_compaction_at')
         OR (table_name = 'synex_audit_log' AND column_name = 'archive_recorded_at')
         OR (table_name = 'synex_session_control_requests' AND column_name = 'target_instance_id')
       ) ORDER BY table_name, column_name`,
      [databaseName],
    );
    assert.equal(scalabilityColumns.length, 4);
    const leaseDomain = scalabilityColumns.find((row) => row.column_name === 'lease_domain_kind');
    const terminalCompaction = scalabilityColumns.find(
      (row) => row.column_name === 'terminal_compaction_at',
    );
    const archiveCheckpoint = scalabilityColumns.find((row) => row.column_name === 'archive_recorded_at');
    const controlTarget = scalabilityColumns.find((row) => row.column_name === 'target_instance_id');
    assert.match(String(leaseDomain?.extra ?? ''), /STORED GENERATED/iu);
    assert.equal(String(terminalCompaction?.data_type).toLowerCase(), 'datetime');
    assert.equal(Number(terminalCompaction?.datetime_precision), 6);
    assert.equal(String(terminalCompaction?.is_nullable), 'YES');
    assert.equal(String(terminalCompaction?.extra ?? ''), '');
    assert.equal(String(archiveCheckpoint?.is_nullable), 'YES');
    assert.equal(String(controlTarget?.data_type).toLowerCase(), 'char');
    assert.equal(Number(controlTarget?.character_maximum_length), 36);
    assert.equal(String(controlTarget?.is_nullable), 'NO');

    const [slotMarkerColumns] = await connection.query<RowDataPacket[]>(
      `SELECT column_name, data_type, column_type, is_nullable, extra, generation_expression
       FROM information_schema.columns
       WHERE table_schema = ? AND table_name = 'synex_characters'
         AND column_name = 'active_slot_marker'`,
      [databaseName],
    );
    assert.equal(slotMarkerColumns.length, 1);
    assert.equal(String(slotMarkerColumns[0]?.data_type).toLowerCase(), 'tinyint');
    assert.match(String(slotMarkerColumns[0]?.column_type ?? ''), /^tinyint(?:\(\d+\))? unsigned$/iu);
    assert.equal(String(slotMarkerColumns[0]?.is_nullable), 'YES');
    assert.match(String(slotMarkerColumns[0]?.extra ?? ''), /STORED GENERATED/iu);
    const slotExpression = String(
      slotMarkerColumns[0]?.generation_expression ?? '',
    ).replaceAll('`', '').replace(/[\s()]/gu, '').toLowerCase();
    assert.ok(new Set([
      'casewhendeleted_atisnullthen1elsenullend',
      'casewhenisnulldeleted_atthen1elsenullend',
      'ifdeleted_atisnull,1,null',
      'ifisnulldeleted_at,1,null',
    ]).has(slotExpression), `unexpected active_slot_marker expression: ${slotExpression}`);

    const [slotIndexes] = await connection.query<RowDataPacket[]>(
      `SELECT index_name, seq_in_index, column_name, non_unique
       FROM information_schema.statistics
       WHERE table_schema = ? AND table_name = 'synex_characters'
         AND index_name IN ('uq_characters_user_slot', 'uq_characters_user_slot_active')
       ORDER BY index_name, seq_in_index`,
      [databaseName],
    );
    assert.equal(slotIndexes.some((row) => row.index_name === 'uq_characters_user_slot'), false);
    const activeSlotIndex = slotIndexes.filter(
      (row) => row.index_name === 'uq_characters_user_slot_active',
    );
    assert.deepEqual(
      activeSlotIndex.map((row) => String(row.column_name)),
      ['user_id', 'slot', 'active_slot_marker'],
    );
    assert.ok(activeSlotIndex.every((row) => Number(row.non_unique) === 0));

    const slotUserId = randomUUID();
    const deletedCharacterId = randomUUID();
    const activeCharacterId = randomUUID();
    await connection.query(
      `INSERT INTO synex_users (id, metadata_json) VALUES (?, '{}')`,
      [slotUserId],
    );
    await connection.query(
      `INSERT INTO synex_character_slots (user_id, slot_limit) VALUES (?, 1)`,
      [slotUserId],
    );
    await connection.query(
      `INSERT INTO synex_characters
       (id, user_id, slot, status, first_name, last_name, metadata_json, deleted_at)
       VALUES (?, ?, 1, 'deleted', 'Deleted', 'Character', '{}', CURRENT_TIMESTAMP(6))`,
      [deletedCharacterId, slotUserId],
    );
    await connection.query(
      `INSERT INTO synex_characters
       (id, user_id, slot, status, first_name, last_name, metadata_json)
       VALUES (?, ?, 1, 'active', 'Live', 'Character', '{}')`,
      [activeCharacterId, slotUserId],
    );
    await assert.rejects(
      connection.query(
        `INSERT INTO synex_characters
         (id, user_id, slot, status, first_name, last_name, metadata_json)
         VALUES (?, ?, 1, 'active', 'Duplicate', 'Character', '{}')`,
        [randomUUID(), slotUserId],
      ),
      (error: unknown) => typeof error === 'object' && error !== null
        && 'code' in error && error.code === 'ER_DUP_ENTRY',
    );
    const [slotRows] = await connection.query<RowDataPacket[]>(
      `SELECT id, active_slot_marker FROM synex_characters
       WHERE user_id = ? AND slot = 1 ORDER BY id`,
      [slotUserId],
    );
    assert.equal(slotRows.length, 2);
    const deletedSlot = slotRows.find((row) => row.id === deletedCharacterId);
    const activeSlot = slotRows.find((row) => row.id === activeCharacterId);
    assert.equal(deletedSlot?.active_slot_marker, null);
    assert.equal(Number(activeSlot?.active_slot_marker), 1);
  } finally {
    await connection.end();
  }
});

test('live database serializes opposite transfers, deduplicates writes, and fences one lease owner', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const firstWorker = await openLiveDatabase();
  const secondWorker = await openLiveDatabase();
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    const fixture = await createTransferFixture(primary.connection);

    const firstDirection = transferInput(fixture.firstAccountId, fixture.secondAccountId, 250);
    const secondDirection = transferInput(fixture.secondAccountId, fixture.firstAccountId, 400);
    const oppositeResults = await Promise.all([
      transferAtomically(firstWorker.connection, firstDirection),
      transferAtomically(secondWorker.connection, secondDirection),
    ]);
    assert.deepEqual(
      new Set(oppositeResults),
      new Set([firstDirection.transactionId, secondDirection.transactionId]),
    );

    const duplicateKey = randomUUID();
    const duplicateWinner = transferInput(
      fixture.firstAccountId,
      fixture.secondAccountId,
      75,
      duplicateKey,
    );
    const duplicateContender = transferInput(
      fixture.firstAccountId,
      fixture.secondAccountId,
      75,
      duplicateKey,
    );
    const duplicateResults = await Promise.all([
      transferAtomically(firstWorker.connection, duplicateWinner),
      transferAtomically(secondWorker.connection, duplicateContender),
    ]);
    assert.equal(duplicateResults[0], duplicateResults[1], 'duplicate requests must replay one committed response');

    const [balances] = await primary.connection.query<BalanceRow[]>(
      `SELECT account.public_id,
              latest.sequence_no,
              latest.booked_minor,
              latest.reserved_minor,
              history.snapshot_count,
              history.minimum_booked_minor
       FROM synex_accounts AS account
       INNER JOIN synex_account_balance_snapshots AS latest
         ON latest.account_id = account.id
        AND latest.sequence_no = (
          SELECT MAX(candidate.sequence_no) FROM synex_account_balance_snapshots AS candidate
          WHERE candidate.account_id = account.id
        )
       INNER JOIN (
         SELECT account_id, COUNT(*) AS snapshot_count, MIN(booked_minor) AS minimum_booked_minor
         FROM synex_account_balance_snapshots GROUP BY account_id
       ) AS history ON history.account_id = account.id
       WHERE account.public_id IN (?, ?)
       ORDER BY account.public_id`,
      [fixture.firstAccountId, fixture.secondAccountId],
    );
    assert.equal(balances.length, 2);
    const latestByAccount = new Map(balances.map((row) => [row.public_id, row]));
    const firstBalance = latestByAccount.get(fixture.firstAccountId);
    const secondBalance = latestByAccount.get(fixture.secondAccountId);
    assert.ok(firstBalance);
    assert.ok(secondBalance);
    assert.equal(asNumber(firstBalance.booked_minor), 1075);
    assert.equal(asNumber(secondBalance.booked_minor), 925);
    for (const balance of balances) {
      assert.equal(asNumber(balance.sequence_no), 3, 'each committed transfer advances each account once');
      assert.equal(asNumber(balance.snapshot_count), 4, 'opening plus three immutable snapshots are retained');
      assert.equal(asNumber(balance.reserved_minor), 0);
      assert.ok(asNumber(balance.minimum_booked_minor) >= 0, 'no asset snapshot may become negative');
    }
    assert.equal(
      balances.reduce((sum, balance) => sum + asNumber(balance.booked_minor), 0),
      2000,
      'the fixture currency supply must be conserved',
    );

    const [postings] = await primary.connection.query<PostingRow[]>(
      `SELECT debit.public_id AS debit_account_id,
              credit.public_id AS credit_account_id,
              posting.debit_minor,
              posting.credit_minor
       FROM synex_ledger_postings AS posting
       INNER JOIN synex_ledger_transactions AS ledger_transaction
         ON ledger_transaction.id = posting.transaction_id
       INNER JOIN synex_accounts AS debit ON debit.id = posting.debit_account_id
       INNER JOIN synex_accounts AS credit ON credit.id = posting.credit_account_id
       WHERE ledger_transaction.currency_id = ?`,
      [fixture.currencyInternalId],
    );
    assert.equal(postings.length, 3, 'the duplicate request must not append a second posting');
    const reconstructed = new Map<string, number>([
      [fixture.firstAccountId, 1000],
      [fixture.secondAccountId, 1000],
    ]);
    for (const posting of postings) {
      const debit = asNumber(posting.debit_minor);
      const credit = asNumber(posting.credit_minor);
      assert.equal(debit, credit, 'every committed posting must remain balanced');
      reconstructed.set(
        posting.debit_account_id,
        (reconstructed.get(posting.debit_account_id) ?? 0) - debit,
      );
      reconstructed.set(
        posting.credit_account_id,
        (reconstructed.get(posting.credit_account_id) ?? 0) + credit,
      );
    }
    assert.equal(reconstructed.get(fixture.firstAccountId), asNumber(firstBalance.booked_minor));
    assert.equal(reconstructed.get(fixture.secondAccountId), asNumber(secondBalance.booked_minor));

    const [aggregates] = await primary.connection.query<AggregateRow[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_ledger_transactions WHERE currency_id = ?) AS transaction_count,
         (SELECT COUNT(*) FROM synex_ledger_postings AS posting
            INNER JOIN synex_ledger_transactions AS ledger_transaction
              ON ledger_transaction.id = posting.transaction_id
            WHERE ledger_transaction.currency_id = ?) AS posting_count,
         (SELECT COUNT(*) FROM synex_account_operations
            WHERE idempotency_key IN (?, ?, ?) AND state = 'completed') AS operation_count,
         (SELECT COUNT(*) FROM synex_account_audit AS audit
            INNER JOIN synex_account_operations AS operation ON operation.id = audit.operation_id
            WHERE operation.idempotency_key IN (?, ?, ?)) AS audit_count,
         (SELECT COUNT(*) FROM synex_account_outbox AS outbox
            INNER JOIN synex_ledger_transactions AS ledger_transaction
              ON ledger_transaction.public_id = outbox.aggregate_id
            WHERE ledger_transaction.currency_id = ?) AS outbox_count`,
      [
        fixture.currencyInternalId,
        fixture.currencyInternalId,
        firstDirection.idempotencyKey,
        secondDirection.idempotencyKey,
        duplicateKey,
        firstDirection.idempotencyKey,
        secondDirection.idempotencyKey,
        duplicateKey,
        fixture.currencyInternalId,
      ],
    );
    const aggregate = aggregates[0];
    assert.ok(aggregate);
    assert.equal(asNumber(aggregate.transaction_count), 3);
    assert.equal(asNumber(aggregate.posting_count), 3);
    assert.equal(asNumber(aggregate.operation_count), 3);
    assert.equal(asNumber(aggregate.audit_count), 3);
    assert.equal(asNumber(aggregate.outbox_count), 3);

    const leaseName = `live-test-${randomUUID()}`;
    await primary.connection.query(
      `INSERT INTO synex_cluster_leases
       (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, 'expired-owner', 1, TIMESTAMPADD(SECOND, -1, CURRENT_TIMESTAMP(6)))`,
      [leaseName],
    );
    const owners = [`worker-a-${randomUUID()}`, `worker-b-${randomUUID()}`] as const;
    const claim = async (connection: Connection, ownerId: string): Promise<number> => {
      const [result] = await connection.query<ResultSetHeader>(
        `UPDATE synex_cluster_leases
         SET owner_id = ?, fencing_token = fencing_token + 1,
             expires_at = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6))
         WHERE lease_name = ? AND expires_at <= CURRENT_TIMESTAMP(6)`,
        [ownerId, leaseName],
      );
      return result.affectedRows;
    };
    const claims = await Promise.all([
      claim(firstWorker.connection, owners[0]),
      claim(secondWorker.connection, owners[1]),
    ]);
    assert.equal(claims[0] + claims[1], 1, 'exactly one cluster worker may claim an expired lease');
    const winningOwner = claims[0] === 1 ? owners[0] : owners[1];
    const [leases] = await primary.connection.query<LeaseRow[]>(
      `SELECT owner_id, fencing_token, expires_at > CURRENT_TIMESTAMP(6) AS currently_valid
       FROM synex_cluster_leases WHERE lease_name = ?`,
      [leaseName],
    );
    assert.equal(leases.length, 1);
    assert.equal(leases[0]?.owner_id, winningOwner);
    assert.equal(asNumber(leases[0]?.fencing_token ?? 0), 2);
    assert.equal(asNumber(leases[0]?.currently_valid ?? 0), 1);
  } finally {
    await Promise.all([
      primary.connection.end(),
      firstWorker.connection.end(),
      secondWorker.connection.end(),
    ]);
  }
});

test('live Accounts ledger permits exactly 20 of 100 concurrent 500-unit spends from 10000', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const workers = await Promise.all(Array.from({ length: 20 }, () => openLiveDatabase()));
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    const fixture = await createTransferFixture(primary.connection, 10_000, 0);
    const requests = Array.from({ length: 100 }, () =>
      transferInput(fixture.firstAccountId, fixture.secondAccountId, 500));
    let cursor = 0;
    const outcomes: Array<'committed' | 'rejected'> = [];
    await Promise.all(workers.map(async ({ connection }) => {
      while (cursor < requests.length) {
        const request = requests[cursor];
        cursor += 1;
        if (!request) break;
        try {
          await transferAtomically(connection, request);
          outcomes.push('committed');
        } catch {
          outcomes.push('rejected');
        }
      }
    }));

    assert.equal(outcomes.filter((outcome) => outcome === 'committed').length, 20);
    assert.equal(outcomes.filter((outcome) => outcome === 'rejected').length, 80);
    const [state] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
        (SELECT snapshot.booked_minor FROM synex_account_balance_snapshots snapshot
          INNER JOIN synex_accounts account ON account.id = snapshot.account_id
          WHERE account.public_id = ? ORDER BY snapshot.sequence_no DESC LIMIT 1) AS source_balance,
        (SELECT snapshot.booked_minor FROM synex_account_balance_snapshots snapshot
          INNER JOIN synex_accounts account ON account.id = snapshot.account_id
          WHERE account.public_id = ? ORDER BY snapshot.sequence_no DESC LIMIT 1) AS destination_balance,
        (SELECT MIN(snapshot.booked_minor) FROM synex_account_balance_snapshots snapshot
          INNER JOIN synex_accounts account ON account.id = snapshot.account_id
          WHERE account.public_id = ?) AS minimum_source_balance,
        (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
          WHERE ledger_transaction.currency_id = ?) AS transaction_count,
        (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
          WHERE ledger_transaction.currency_id = ? AND
            (ledger_transaction.posting_model <> 'multi_leg' OR ledger_transaction.entry_count <> 2
              OR (SELECT COUNT(*) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id) <> 2
              OR (SELECT SUM(entry.amount_minor) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id) <> 0)) AS invalid_transaction_count,
        (SELECT COUNT(*) FROM synex_account_operations operation
          WHERE operation.caller_resource = 'synex_live_test' AND operation.state = 'pending')
          AS pending_operation_count`,
      [fixture.firstAccountId, fixture.secondAccountId, fixture.firstAccountId,
        fixture.currencyInternalId, fixture.currencyInternalId],
    );
    const row = state[0];
    assert.ok(row);
    assert.equal(asNumber(row.source_balance as string | number), 0);
    assert.equal(asNumber(row.destination_balance as string | number), 10_000);
    assert.equal(asNumber(row.minimum_source_balance as string | number), 0);
    assert.equal(asNumber(row.transaction_count as string | number), 20);
    assert.equal(asNumber(row.invalid_transaction_count as string | number), 0);
    assert.equal(asNumber(row.pending_operation_count as string | number), 0);
  } finally {
    await Promise.all([primary.connection.end(), ...workers.map(({ connection }) => connection.end())]);
  }
});

test('live Accounts holds never reserve more than the concurrently available balance', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const workers = await Promise.all(Array.from({ length: 20 }, () => openLiveDatabase()));
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    const fixture = await createTransferFixture(primary.connection, 10_000, 0);
    let cursor = 0;
    const outcomes: Array<'committed' | 'rejected'> = [];
    await Promise.all(workers.map(async ({ connection }) => {
      while (cursor < 100) {
        cursor += 1;
        try {
          await createHoldAtomically(
            connection, fixture.firstAccountId, fixture.secondAccountId, 500,
          );
          outcomes.push('committed');
        } catch {
          outcomes.push('rejected');
        }
      }
    }));
    assert.equal(outcomes.filter((outcome) => outcome === 'committed').length, 20);
    assert.equal(outcomes.filter((outcome) => outcome === 'rejected').length, 80);
    const [state] = await primary.connection.query<RowDataPacket[]>(
      `SELECT latest.booked_minor, latest.reserved_minor,
        (SELECT MIN(history.booked_minor - history.reserved_minor)
          FROM synex_account_balance_snapshots history WHERE history.account_id = account.id)
          AS minimum_available_minor,
        (SELECT COUNT(*) FROM synex_account_holds hold_record
          WHERE hold_record.account_id = account.id AND hold_record.state = 'active') AS active_hold_count,
        (SELECT COALESCE(SUM(hold_record.remaining_minor), 0) FROM synex_account_holds hold_record
          WHERE hold_record.account_id = account.id AND hold_record.state = 'active')
          AS active_held_minor,
        (SELECT COUNT(*) FROM synex_account_operations operation
          WHERE operation.caller_resource = 'synex_live_test'
            AND operation.operation_name = 'hold_create' AND operation.state = 'pending')
          AS pending_operation_count
       FROM synex_accounts account
       INNER JOIN synex_account_balance_snapshots latest ON latest.account_id = account.id
         AND latest.sequence_no = (SELECT MAX(candidate.sequence_no)
           FROM synex_account_balance_snapshots candidate WHERE candidate.account_id = account.id)
       WHERE account.public_id = ?`,
      [fixture.firstAccountId],
    );
    const row = state[0];
    assert.ok(row);
    assert.equal(asNumber(row.booked_minor as string | number), 10_000);
    assert.equal(asNumber(row.reserved_minor as string | number), 10_000);
    assert.equal(asNumber(row.minimum_available_minor as string | number), 0);
    assert.equal(asNumber(row.active_hold_count as string | number), 20);
    assert.equal(asNumber(row.active_held_minor as string | number), 10_000);
    assert.equal(asNumber(row.pending_operation_count as string | number), 0);
  } finally {
    await Promise.all([primary.connection.end(), ...workers.map(({ connection }) => connection.end())]);
  }
});

test('live Accounts serializes randomized transfers across one shared account set', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const workers = await Promise.all(Array.from({ length: 12 }, () => openLiveDatabase()));
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    const openingBalance = 1_000_000;
    const fixture = await createTransferFixture(primary.connection, openingBalance, openingBalance);
    const accountIds = [fixture.firstAccountId, fixture.secondAccountId];
    const suffix = randomUUID().replaceAll('-', '').slice(0, 10);
    for (let index = 2; index < 6; index += 1) {
      const publicId = randomUUID();
      const [account] = await primary.connection.query<ResultSetHeader>(
        `INSERT INTO synex_accounts
         (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json)
         VALUES (?, ?, ?, 'asset', 0, 'active', '{}')`,
        [publicId, fixture.currencyInternalId, `random_${suffix}_${index}`],
      );
      await primary.connection.query(
        `INSERT INTO synex_account_owners (account_id, owner_kind, owner_ref)
         VALUES (?, 'system', 'synex_live_test')`,
        [account.insertId],
      );
      await primary.connection.query(
        `INSERT INTO synex_account_balance_snapshots
         (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
         VALUES (?, 0, 'opening', ?, ?, 0)`,
        [account.insertId, randomUUID(), openingBalance],
      );
      accountIds.push(publicId);
    }

    let randomState = 0x51f15e5d;
    const nextRandom = (): number => {
      randomState = (Math.imul(randomState, 1_664_525) + 1_013_904_223) >>> 0;
      return randomState;
    };
    const expected = new Map(accountIds.map((accountId) => [accountId, openingBalance]));
    const requests = Array.from({ length: 240 }, () => {
      const sourceIndex = nextRandom() % accountIds.length;
      let destinationIndex = nextRandom() % accountIds.length;
      if (destinationIndex === sourceIndex) destinationIndex = (destinationIndex + 1) % accountIds.length;
      const source = accountIds[sourceIndex];
      const destination = accountIds[destinationIndex];
      assert.ok(source);
      assert.ok(destination);
      const amount = (nextRandom() % 1000) + 1;
      expected.set(source, (expected.get(source) ?? 0) - amount);
      expected.set(destination, (expected.get(destination) ?? 0) + amount);
      return transferInput(source, destination, amount);
    });
    let cursor = 0;
    await Promise.all(workers.map(async ({ connection }) => {
      while (cursor < requests.length) {
        const request = requests[cursor];
        cursor += 1;
        if (request) await transferAtomically(connection, request);
      }
    }));

    const placeholders = accountIds.map(() => '?').join(', ');
    const [balances] = await primary.connection.query<RowDataPacket[]>(
      `SELECT account.public_id, latest.booked_minor,
        (SELECT MIN(history.booked_minor) FROM synex_account_balance_snapshots history
          WHERE history.account_id = account.id) AS minimum_booked_minor,
        COALESCE((SELECT SUM(entry.amount_minor) FROM synex_ledger_entries entry
          WHERE entry.account_id = account.id), 0) AS ledger_delta_minor
       FROM synex_accounts account
       INNER JOIN synex_account_balance_snapshots latest ON latest.account_id = account.id
        AND latest.sequence_no = (SELECT MAX(candidate.sequence_no)
          FROM synex_account_balance_snapshots candidate WHERE candidate.account_id = account.id)
       WHERE account.public_id IN (${placeholders})`,
      accountIds,
    );
    assert.equal(balances.length, accountIds.length);
    for (const row of balances) {
      const publicId = String(row.public_id);
      const booked = asNumber(row.booked_minor as string | number);
      const delta = asNumber(row.ledger_delta_minor as string | number);
      assert.equal(booked, expected.get(publicId));
      assert.equal(booked, openingBalance + delta, 'snapshot truth must equal opening plus signed ledger entries');
      assert.ok(asNumber(row.minimum_booked_minor as string | number) >= 0);
    }
    const [integrity] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS transaction_count,
        SUM(CASE WHEN ledger_transaction.posting_model <> 'multi_leg'
          OR ledger_transaction.entry_count <> 2
          OR (SELECT COUNT(*) FROM synex_ledger_entries entry
            WHERE entry.transaction_id = ledger_transaction.id) <> 2
          OR (SELECT SUM(entry.amount_minor) FROM synex_ledger_entries entry
            WHERE entry.transaction_id = ledger_transaction.id) <> 0 THEN 1 ELSE 0 END)
          AS invalid_transaction_count
       FROM synex_ledger_transactions ledger_transaction
       WHERE ledger_transaction.currency_id = ?`,
      [fixture.currencyInternalId],
    );
    assert.equal(asNumber(integrity[0]?.transaction_count as string | number), requests.length);
    assert.equal(asNumber(integrity[0]?.invalid_transaction_count as string | number), 0);
  } finally {
    await Promise.all([primary.connection.end(), ...workers.map(({ connection }) => connection.end())]);
  }
});

test('live Accounts outbox survives a process stop after financial commit and publishes after restart', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const setup = await openLiveDatabase();
  const producer = await openLiveDatabase();
  const firstRestartedWorker = await openLiveDatabase();
  const secondRestartedWorker = await openLiveDatabase();
  try {
    await applyMigrations(setup.connection, await loadMigrations());
    const fixture = await createTransferFixture(setup.connection, 1000, 0);
    const transfer = transferInput(fixture.firstAccountId, fixture.secondAccountId, 250);
    await transferAtomically(producer.connection, transfer);
    await producer.connection.end();

    const [committed] = await setup.connection.query<RowDataPacket[]>(
      `SELECT ledger_transaction.public_id, outbox.event_id, outbox.state, outbox.payload_json
       FROM synex_ledger_transactions ledger_transaction
       INNER JOIN synex_account_outbox outbox ON outbox.aggregate_id = ledger_transaction.public_id
       WHERE ledger_transaction.public_id = ?`,
      [transfer.transactionId],
    );
    assert.equal(committed.length, 1);
    assert.equal(committed[0]?.state, 'pending');
    assert.equal(String(committed[0]?.event_id), transfer.eventId);
    assert.doesNotThrow(() => JSON.parse(String(committed[0]?.payload_json)) as unknown);

    const claim = async (connection: Connection, workerId: string): Promise<number> => {
      const [result] = await connection.query<ResultSetHeader>(
        `UPDATE synex_account_outbox SET state = 'publishing', locked_by = ?,
          locked_until = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
          updated_at = CURRENT_TIMESTAMP(6)
         WHERE event_id = ? AND state = 'pending' AND available_at <= CURRENT_TIMESTAMP(6)
           AND (locked_until IS NULL OR locked_until <= CURRENT_TIMESTAMP(6))`,
        [workerId, transfer.eventId],
      );
      return result.affectedRows;
    };
    const workerIds = [`accounts-restart-a-${randomUUID()}`, `accounts-restart-b-${randomUUID()}`];
    const claims = await Promise.all([
      claim(firstRestartedWorker.connection, workerIds[0] ?? ''),
      claim(secondRestartedWorker.connection, workerIds[1] ?? ''),
    ]);
    assert.equal(claims[0] + claims[1], 1);
    const winner = claims[0] === 1 ? firstRestartedWorker.connection : secondRestartedWorker.connection;
    const winnerId = claims[0] === 1 ? workerIds[0] : workerIds[1];
    const [published] = await winner.query<ResultSetHeader>(
      `UPDATE synex_account_outbox SET state = 'published', attempts = attempts + 1,
        last_attempt_at = CURRENT_TIMESTAMP(6), published_at = CURRENT_TIMESTAMP(6),
        locked_by = NULL, locked_until = NULL, updated_at = CURRENT_TIMESTAMP(6)
       WHERE event_id = ? AND state = 'publishing' AND locked_by = ?`,
      [transfer.eventId, winnerId],
    );
    assert.equal(published.affectedRows, 1);
    assert.equal(await claim(setup.connection, `late-worker-${randomUUID()}`), 0);
    const [finalRows] = await setup.connection.query<RowDataPacket[]>(
      `SELECT state, attempts, published_at, last_attempt_at, dead_at
       FROM synex_account_outbox WHERE event_id = ?`,
      [transfer.eventId],
    );
    assert.equal(finalRows.length, 1);
    assert.equal(finalRows[0]?.state, 'published');
    assert.equal(asNumber(finalRows[0]?.attempts as string | number), 1);
    assert.ok(finalRows[0]?.published_at);
    assert.ok(finalRows[0]?.last_attempt_at);
    assert.equal(finalRows[0]?.dead_at, null);
  } finally {
    await Promise.allSettled([
      setup.connection.end(), producer.connection.end(), firstRestartedWorker.connection.end(),
      secondRestartedWorker.connection.end(),
    ]);
  }
});

test('live restart waits for an in-flight prior-boot insert, then closes it and preserves its generation floor', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const setup = await openLiveDatabase();
  const writer = await openLiveDatabase();
  const restarter = await openLiveDatabase();
  try {
    await applyMigrations(setup.connection, await loadMigrations());
    const instanceId = randomUUID();
    const userId = randomUUID();
    const bootA = randomUUID();
    const bootB = randomUUID();
    const sessionId = randomUUID();
    const leaseName = `session:${userId}`;
    const leaseOwner = `${instanceId}:${sessionId}`;
    await setup.connection.query(
      `INSERT INTO synex_users (id, status, locale, metadata_json, version)
       VALUES (?, 'active', 'en', '{}', 1)`,
      [userId],
    );
    await setup.connection.query(
      `INSERT INTO synex_instances
       (instance_id, name, started_at, heartbeat_at, status, version)
       VALUES (?, 'Live boot fence', CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 'ready', 1)`,
      [instanceId],
    );
    await setup.connection.query(
      `INSERT INTO synex_instance_boots (instance_id, boot_id, registered_at)
       VALUES (?, ?, CURRENT_TIMESTAMP(6))`,
      [instanceId, bootA],
    );
    await setup.connection.query(
      `INSERT INTO synex_cluster_leases (lease_name, owner_id, fencing_token, expires_at)
       VALUES (?, ?, 1, TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)))`,
      [leaseName, leaseOwner],
    );

    await writer.connection.beginTransaction();
    const [requester] = await writer.connection.query<RowDataPacket[]>(
      `SELECT status FROM synex_instances
       WHERE instance_id = ? AND status = 'ready' FOR UPDATE`,
      [instanceId],
    );
    assert.equal(requester.length, 1);
    const [bootClaim] = await writer.connection.query<RowDataPacket[]>(
      `SELECT boot_id FROM synex_instance_boots
       WHERE instance_id = ? AND boot_id = ? FOR UPDATE`,
      [instanceId, bootA],
    );
    assert.equal(bootClaim.length, 1);
    const [leaseClaim] = await writer.connection.query<RowDataPacket[]>(
      `SELECT owner_id, fencing_token FROM synex_cluster_leases
       WHERE lease_name = ? AND owner_id = ? AND fencing_token = 1
         AND expires_at > CURRENT_TIMESTAMP(6) FOR UPDATE`,
      [leaseName, leaseOwner],
    );
    assert.equal(leaseClaim.length, 1);
    await writer.connection.query(
      `INSERT INTO synex_sessions
       (id, user_id, server_instance_id, source_value, source_generation, state,
        character_id, connected_at, last_seen_at, version)
       VALUES (?, ?, ?, 42, 38, 'SELECTING_CHARACTER', NULL,
               CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 1)`,
      [sessionId, userId, instanceId],
    );

    let restartRegistered = false;
    let signalRestartQuery!: () => void;
    const restartQueryStarted = new Promise<void>((resolve) => { signalRestartQuery = resolve; });
    const restart = (async () => {
      await restarter.connection.beginTransaction();
      signalRestartQuery();
      await restarter.connection.query(
        `INSERT INTO synex_instances
         (instance_id, name, started_at, heartbeat_at, status, version)
         VALUES (?, 'Live boot fence B', CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 'starting', 1)
         ON DUPLICATE KEY UPDATE name = VALUES(name), started_at = CURRENT_TIMESTAMP(6),
           heartbeat_at = CURRENT_TIMESTAMP(6), status = 'starting', version = version + 1`,
        [instanceId],
      );
      await restarter.connection.query(
        `INSERT INTO synex_instance_boots (instance_id, boot_id, registered_at)
         VALUES (?, ?, CURRENT_TIMESTAMP(6))
         ON DUPLICATE KEY UPDATE boot_id = VALUES(boot_id), registered_at = CURRENT_TIMESTAMP(6)`,
        [instanceId, bootB],
      );
      await restarter.connection.commit();
      restartRegistered = true;

      await restarter.connection.beginTransaction();
      const [authority] = await restarter.connection.query<RowDataPacket[]>(
        `SELECT boot_id FROM synex_instance_boots
         WHERE instance_id = ? AND boot_id = ? FOR UPDATE`,
        [instanceId, bootB],
      );
      assert.equal(authority.length, 1);
      await restarter.connection.query(
        `UPDATE synex_cluster_leases AS lease
         INNER JOIN synex_sessions AS session
           ON session.server_instance_id = ?
          AND session.closed_at IS NULL
          AND lease.owner_id = CONCAT(session.server_instance_id, ':', session.id)
         SET lease.expires_at = CURRENT_TIMESTAMP(6)
         WHERE LEFT(lease.lease_name, 8) = 'session:'
           AND lease.expires_at > CURRENT_TIMESTAMP(6)`,
        [instanceId],
      );
      await restarter.connection.query(
        `UPDATE synex_sessions
         SET state = 'CLOSED', closed_at = CURRENT_TIMESTAMP(6),
             close_reason = 'synex_core restarted', version = version + 1
         WHERE server_instance_id = ? AND closed_at IS NULL`,
        [instanceId],
      );
      await restarter.connection.commit();
    })();

    await restartQueryStarted;
    await new Promise<void>((resolve) => { setTimeout(resolve, 50); });
    assert.equal(restartRegistered, false, 'restart registration must wait on the prior boot authority lock');
    await writer.connection.commit();
    await restart;

    const [sessions] = await setup.connection.query<RowDataPacket[]>(
      `SELECT state, closed_at FROM synex_sessions WHERE id = ?`,
      [sessionId],
    );
    assert.equal(sessions.length, 1);
    assert.equal(sessions[0]?.state, 'CLOSED');
    assert.ok(sessions[0]?.closed_at);
    const [floor] = await setup.connection.query<RowDataPacket[]>(
      `SELECT COALESCE((
         SELECT session.source_generation
         FROM synex_sessions AS session
         WHERE session.server_instance_id = boot.instance_id
         ORDER BY session.source_generation DESC LIMIT 1
       ), 0) AS source_generation_floor
       FROM synex_instance_boots AS boot
       WHERE boot.instance_id = ? AND boot.boot_id = ? LIMIT 1`,
      [instanceId, bootB],
    );
    assert.equal(asNumber(floor[0]?.source_generation_floor as string | number), 38);
  } finally {
    await Promise.all([
      setup.connection.end(),
      writer.connection.end(),
      restarter.connection.end(),
    ]);
  }
});

test('live legacy import writes a reconciled native model and replays without writes', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  try {
    await applyMigrations(connection, await loadMigrations());
    const suffix = randomUUID().replaceAll('-', '').slice(0, 16);
    const jobType = `job_${suffix}`;
    const gangType = `gang_${suffix}`;
    const jobSlug = `job_${suffix}`;
    const gangSlug = `gang_${suffix}`;
    const jobGrade = 'grade_2';
    const gangGrade = 'grade_1';
    const groupCatalog = validateCompatibilityGroupCatalog({
      schema: 1,
      kind: 'synex-compatibility-mappings',
      groups: [{
        id: `qbx.job.live_${suffix}`,
        version: '1.0.0',
        provider: 'qbx',
        legacyType: 'job',
        legacyName: `job_${suffix}`,
        nativeGroupKey: jobSlug,
        nativeGroupType: jobType,
        grades: [{ legacyGrade: 2, gradeKey: jobGrade }],
        bossRoles: [],
        dutySupported: false,
        status: 'PARTIAL',
      }, {
        id: `qbx.gang.live_${suffix}`,
        version: '1.0.0',
        provider: 'qbx',
        legacyType: 'gang',
        legacyName: `group_${suffix}`,
        nativeGroupKey: gangSlug,
        nativeGroupType: gangType,
        grades: [{ legacyGrade: 1, gradeKey: gangGrade }],
        bossRoles: [],
        dutySupported: false,
        status: 'PARTIAL',
      }],
    });
    const groupTargets = [{
      type: jobType,
      slug: jobSlug,
      grade: jobGrade,
      label: 'Live imported job target',
    }, {
      type: gangType,
      slug: gangSlug,
      grade: gangGrade,
      label: 'Live imported gang target',
    }];
    for (const target of groupTargets) {
      const typePublicId = `gtype_${randomUUID().replaceAll('-', '').slice(0, 32)}`;
      const groupPublicId = `group_${randomUUID().replaceAll('-', '').slice(0, 32)}`;
      const gradePublicId = `ggrade_${randomUUID().replaceAll('-', '').slice(0, 32)}`;
      const [typeResult] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_group_types
         (public_id, type_key, owner_resource, display_name, creation_mode,
          primary_policy, membership_limit, active_membership_limit, create_permission,
          required_approvals, approval_permission, hierarchy_enabled, relationships_enabled,
          status, version, schema_version, dynamic_creation, metadata_json)
         VALUES (?, ?, 'synex_groups', ?, 'dynamic', 'optional', 64, 64, ?, 0, ?,
                 1, 1, 'active', 1, 1, 1, '{}')`,
        [typePublicId, target.type, target.label,
          `synex.groups.create.${target.type}`,
          `synex.groups.create.approve.${target.type}`],
      );
      const groupTypeId = asNumber(typeResult.insertId);
      await connection.query(
        `INSERT INTO synex_group_slug_reservations
         (slug, owner_kind, owner_public_id, version) VALUES (?, 'group', ?, 1)`,
        [target.slug, groupPublicId],
      );
      const [groupResult] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_groups
         (public_id, group_key, display_name, group_type, status, metadata_json, version)
         VALUES (?, ?, ?, ?, 'active', '{}', 1)`,
        [groupPublicId, target.slug, target.label, target.type],
      );
      const groupId = asNumber(groupResult.insertId);
      await connection.query(
        `INSERT INTO synex_group_organization_profiles
         (group_id, group_type_id, slug, visibility, creation_source, lifecycle_state,
          lifecycle_reason_code, definition_key, definition_digest, suspended_at,
          archived_at, deleted_at, version, name, label, description, dynamic, metadata_json)
         VALUES (?, ?, ?, 'internal', 'dynamic', 'ACTIVE', 'live_test_created',
                 NULL, NULL, NULL, NULL, NULL, 1, ?, ?, NULL, 1, '{}')`,
        [groupId, groupTypeId, target.slug, target.label, target.label],
      );
      await connection.query(
        `INSERT INTO synex_group_hierarchy_closure
         (ancestor_group_id, descendant_group_id, depth) VALUES (?, ?, 0)`,
        [groupId, groupId],
      );
      await connection.query(
        `INSERT INTO synex_group_read_model_versions
         (group_id, model_version, invalidated_at) VALUES (?, 1, CURRENT_TIMESTAMP(6))`,
        [groupId],
      );
      const [gradeResult] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_group_grades
         (public_id, group_id, grade_key, display_name, rank_value, status, version)
         VALUES (?, ?, ?, ?, 1, 'active', 1)`,
        [gradePublicId, groupId, target.grade, target.grade],
      );
      await connection.query(
        `INSERT INTO synex_group_grade_controls
         (grade_id, member_limit, promotion_requires_approval, version)
         VALUES (?, 64, 0, 1)`,
        [asNumber(gradeResult.insertId)],
      );
    }
    const source = validateSource({
      schema: 1,
      framework: 'qbx',
      records: [{
        license: `license:live-license-${suffix}`,
        citizenid: `QBX-LIVE-${suffix}`,
        charinfo: { firstname: 'Live', lastname: 'Import' },
        money: { cash: 400, bank: 1600 },
        job: { name: `job_${suffix}`, grade: { level: 2 } },
        gang: { name: `group_${suffix}`, grade: { level: 1 } },
      }],
    });
    const mapping = validateMapping({
      schema: 1,
      framework: 'qbx',
      fields: {
        userId: 'license',
        characterId: 'citizenid',
        firstName: 'charinfo.firstname',
        lastName: 'charinfo.lastname',
        money: { cash: 'money.cash', bank: 'money.bank' },
        job: { name: 'job.name', grade: 'job.grade.level' },
        group: { name: 'gang.name', grade: 'gang.grade.level' },
      },
      compatibilityGroups: {
        catalogDigest: groupCatalog.digest,
        mappingIds: groupCatalog.definitions.map((definition) => definition.id),
      },
    }, migrationMetadataCatalog, migrationAccountCatalog, groupCatalog);
    const plan = buildMigrationPlan(source, mapping, `live-source-${suffix}`);
    const database = importDatabase(connection);
    const first = await importReviewedMigrationPlan(plan, database, false);
    assert.equal(first.alreadyApplied, false);
    assert.deepEqual(first.counts, {
      users: 1,
      characters: 1,
      identifiers: 1,
      accounts: 2,
      ledgerTransactions: 2,
      groups: 2,
      memberships: 2,
      metadata: 0,
    });

    const userId = plan.bundle.users[0]?.id;
    const characterId = plan.bundle.characters[0]?.id;
    assert.ok(userId);
    assert.ok(characterId);
    const [journal] = await connection.query<RowDataPacket[]>(
      `SELECT public_id, state, imported_user_count, imported_character_count
       FROM synex_legacy_imports WHERE report_digest = ?`,
      [plan.report.reportDigest],
    );
    assert.equal(journal.length, 1);
    assert.equal(journal[0]?.state, 'completed');
    assert.equal(asNumber(journal[0]?.imported_user_count as string | number), 1);
    assert.equal(asNumber(journal[0]?.imported_character_count as string | number), 1);
    const importId = String(journal[0]?.public_id);
    const qbxCash = migrationAccountCatalog.byProviderAlias.get('qbx:cash');
    const qbxBank = migrationAccountCatalog.byProviderAlias.get('qbx:bank');
    assert.ok(qbxCash);
    assert.ok(qbxBank);
    const expectedAccountKeys = [
      ownerScopedCompatibilityAccountKey(qbxCash, characterId),
      ownerScopedCompatibilityAccountKey(qbxBank, characterId),
    ];

    const [identity] = await connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_users WHERE id = ?) AS user_count,
         (SELECT COUNT(*) FROM synex_characters WHERE id = ? AND user_id = ? AND slot = 1) AS character_count,
         (SELECT COUNT(*) FROM synex_legacy_id_mappings mapping
            INNER JOIN synex_legacy_imports legacy_import ON legacy_import.id = mapping.import_id
            WHERE legacy_import.report_digest = ?
              AND mapping.legacy_id_hash REGEXP '^[0-9a-f]{64}$') AS mapping_count`,
      [userId, characterId, userId, plan.report.reportDigest],
    );
    assert.equal(asNumber(identity[0]?.user_count as string | number), 1);
    assert.equal(asNumber(identity[0]?.character_count as string | number), 1);
    assert.equal(asNumber(identity[0]?.mapping_count as string | number), 2);
    const [identifiers] = await connection.query<RowDataPacket[]>(
      `SELECT identifier_type, identifier_value FROM synex_identifiers WHERE user_id = ?`,
      [userId],
    );
    assert.equal(identifiers.length, 1);
    assert.equal(identifiers[0]?.identifier_type, 'license');
    assert.equal(identifiers[0]?.identifier_value, `live-license-${suffix}`);

    const [domain] = await connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_account_owners owner
            INNER JOIN synex_accounts account ON account.id = owner.account_id
            INNER JOIN synex_currencies currency ON currency.id = account.currency_id
             WHERE owner.owner_kind = 'character' AND owner.owner_ref = ?
               AND account.account_role = 'asset'
               AND currency.currency_code = 'usd'
               AND account.account_key IN (?, ?)) AS account_count,
         (SELECT COUNT(*) FROM synex_group_memberships
            WHERE subject_kind = 'character' AND subject_ref = ? AND status = 'active') AS membership_count,
          (SELECT COUNT(*) FROM synex_account_operations operation
             INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.operation_id = operation.id
             INNER JOIN (SELECT transaction_id, COUNT(*) AS actual_entry_count,
                  SUM(amount_minor) AS entry_sum
                FROM synex_ledger_entries GROUP BY transaction_id) entries
               ON entries.transaction_id = ledger_transaction.id
             WHERE operation.operation_name = 'legacy_opening_balance'
               AND operation.caller_resource = 'synex_migrator'
               AND operation.caller_principal_kind = 'migration'
               AND operation.caller_principal_ref = 'legacy_migration:qbx'
               AND ledger_transaction.posting_model = 'multi_leg'
               AND ledger_transaction.transaction_kind = 'opening_balance'
               AND ledger_transaction.reason_code = 'synex_accounts.opening_balance'
               AND ledger_transaction.status = 'posted'
               AND ledger_transaction.entry_count = 2
               AND entries.actual_entry_count = 2 AND entries.entry_sum = 0) AS balanced_opening_count,
          (SELECT COUNT(*) FROM synex_currency_system_topology topology
             INNER JOIN synex_currencies currency ON currency.id = topology.currency_id
             INNER JOIN synex_accounts mint ON mint.id = topology.mint_account_id
             INNER JOIN synex_accounts burn ON burn.id = topology.burn_account_id
               WHERE currency.currency_code = 'usd'
                AND topology.topology_state = 'ready'
                AND mint.account_role = 'mint' AND burn.account_role = 'burn') AS topology_count`,
      [characterId, ...expectedAccountKeys, characterId],
    );
    assert.equal(asNumber(domain[0]?.account_count as string | number), 2);
    assert.equal(asNumber(domain[0]?.membership_count as string | number), 2);
    assert.equal(asNumber(domain[0]?.balanced_opening_count as string | number), 2);
    assert.equal(asNumber(domain[0]?.topology_count as string | number), 1);

    const [reconciliation] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS run_count
       FROM synex_economy_reconciliation_runs reconciliation
       INNER JOIN synex_account_operations operation ON operation.id = reconciliation.operation_id
       WHERE reconciliation.requested_by_ref = 'legacy_migration:qbx'
         AND operation.operation_name = 'legacy_reconciliation'
          AND operation.request_fingerprint = ?
          AND reconciliation.status = 'healthy' AND reconciliation.finding_count = 0
          AND reconciliation.total_debit_minor = reconciliation.total_credit_minor
          AND reconciliation.total_entry_sum_minor = 0
          AND reconciliation.transaction_sum_violation_count = 0
          AND reconciliation.snapshot_drift_count = 0
          AND reconciliation.invalid_topology_count = 0`,
      [createHash('sha256').update(`${importId}:usd`, 'utf8').digest('hex')],
    );
    // The read model is authoritative per currency; both account aliases share the reviewed USD topology.
    const [integrity] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS healthy_count
       FROM synex_economy_integrity_read_models model
       INNER JOIN synex_currencies currency ON currency.id = model.currency_id
         WHERE currency.currency_code = 'usd'
          AND model.status = 'healthy' AND model.finding_count = 0
          AND model.total_debit_minor = model.total_credit_minor
          AND model.total_entry_sum_minor = 0
          AND model.transaction_sum_violation_count = 0
          AND model.snapshot_drift_count = 0 AND model.invalid_topology_count = 0`,
    );
    assert.equal(asNumber(integrity[0]?.healthy_count as string | number), 1);
    assert.equal(asNumber(reconciliation[0]?.run_count as string | number), 1);

    const replay = await importReviewedMigrationPlan(plan, database, false);
    assert.equal(replay.alreadyApplied, true);
    const [afterReplay] = await connection.query<RowDataPacket[]>(
      'SELECT COUNT(*) AS import_count FROM synex_legacy_imports WHERE report_digest = ?',
      [plan.report.reportDigest],
    );
    assert.equal(asNumber(afterReplay[0]?.import_count as string | number), 1);
  } finally {
    await connection.end();
  }
});
