import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { accountsRoot } from './helpers.js';

const migrationRoot = path.join(accountsRoot, 'migrations');
const legacyDigests = new Map([
  ['001_accounts.sql', '5a43f0cd7f5793492b4ea45fc9d275e785fef07b381c7cb66421db7e333b08fe'],
  ['002_ledger.sql', 'eb576992ada26c21acfea79b076351f4032ee6d7d34ad864208882a8b8c33eb3'],
  ['003_holds.sql', '7a9e87a40b7ec0cec3d7ec12cf3340041612776bb022b02d0200a07851d6edab'],
  ['004_access_integrity.sql', 'ada8c35cc94ea61ace9f5a06dd5f133f9a810480c427dd5694ee5e631d79e5b7'],
  ['005_character_lifecycle.sql', 'fda0fc2f6696f6c7ed66ab447461f9c24932c1cb5ae5d060e4e743efdce7dced'],
  ['006_financial_archive.sql', '5be2f9836f782581564a3f918aaf24a47558dd50ea3ddce26f5788b5c649cbe4'],
]);
const additiveFiles = [
  '007_operation_scope_and_provenance.sql',
  '008_reason_currency_topology.sql',
  '009_multileg_ledger.sql',
  '010_refunds.sql',
  '011_hold_lifecycle_v2.sql',
  '012_access_policies.sql',
  '013_group_deletion_journal.sql',
  '014_integrity_outbox_control.sql',
  '015_financial_archive_v2.sql',
  '016_financial_entry_bounds.sql',
  '017_idempotency_principal_scope.sql',
] as const;

async function migration(file: string): Promise<string> {
  return readFile(path.join(migrationRoot, file), 'utf8');
}

test('published migrations remain immutable and the Financial Engine is strictly additive through 017', async () => {
  const files = (await readdir(migrationRoot))
    .filter((file) => /^\d{3}_[a-z0-9_]+\.sql$/u.test(file))
    .sort((left, right) => left.localeCompare(right, 'en'));
  assert.deepEqual(files, [...legacyDigests.keys(), ...additiveFiles]);

  for (const [file, expected] of legacyDigests) {
    const bytes = await readFile(path.join(migrationRoot, file));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), expected, file);
  }

  for (const file of additiveFiles) {
    const contents = await migration(file);
    assert.equal(contents.includes('\r'), false, file);
    assert.doesNotMatch(contents, /\b(?:DROP\s+(?:TABLE|COLUMN)|TRUNCATE|RENAME\s+TABLE|DELETE\s+FROM)\b/iu, file);
    assert.match(contents, /INSERT INTO `synex_account_migration_assertions`/u, file);
    assert.match(contents, new RegExp(`['"]${file.slice(0, -4)}['"]`, 'u'), file);
  }
});

test('migration guards encode scoped idempotency, provenance, and currency topology', async () => {
  const operation = await migration('007_operation_scope_and_provenance.sql');
  assert.match(
    operation,
    /CREATE UNIQUE INDEX IF NOT EXISTS `uq_account_operations_scope`[\s\S]*?\(`caller_resource`, `operation_name`, `idempotency_key`\)/u,
  );
  for (const field of [
    'caller_principal_kind',
    'caller_principal_ref',
    'trace_id',
    'source_resource',
    'reference_type',
    'reference_id',
    'actor_kind',
  ]) assert.ok(operation.includes(`\`${field}\``), field);

  const principalScope = await migration('017_idempotency_principal_scope.sql');
  assert.match(
    principalScope,
    /CREATE UNIQUE INDEX IF NOT EXISTS `uq_account_operations_principal_scope`[\s\S]*?\(`caller_resource`, `caller_principal_kind`, `caller_principal_ref`,[\s\S]*?`operation_name`, `idempotency_key`\)/u,
  );
  assert.match(principalScope, /MODIFY COLUMN `caller_principal_kind`[\s\S]*?NOT NULL/u);
  assert.match(principalScope, /MODIFY COLUMN `caller_principal_ref`[\s\S]*?NOT NULL/u);
  assert.match(
    principalScope,
    /WHERE `caller_principal_kind` IS NULL\s+OR `caller_principal_ref` IS NULL/u,
  );

  const currency = await migration('008_reason_currency_topology.sql');
  assert.match(currency, /CREATE TABLE IF NOT EXISTS `synex_account_reason_codes`/u);
  assert.match(currency, /CREATE TABLE IF NOT EXISTS `synex_currency_system_topology`/u);
  assert.match(currency, /`mint_account_id`[\s\S]*?`burn_account_id`/u);
  assert.match(currency, /`precision_locked_at` IS NULL[\s\S]*?`precision_lock_transaction_id` IS NULL/u);
  assert.match(currency, /`mint_account_id` IS NULL OR `burn_account_id` IS NULL[\s\S]*?`mint_account_id` <> `burn_account_id`/u);
});

test('the additive ledger and refund schema preserves signed zero-sum and refund caps', async () => {
  const ledger = await migration('009_multileg_ledger.sql');
  assert.match(ledger, /CREATE TABLE IF NOT EXISTS `synex_ledger_entries`/u);
  assert.match(ledger, /UNIQUE KEY `uq_ledger_entries_transaction_sequence` \(`transaction_id`, `sequence_no`\)/u);
  assert.match(ledger, /UNIQUE KEY `uq_ledger_entries_transaction_account` \(`transaction_id`, `account_id`\)/u);
  assert.match(ledger, /`amount_minor` BETWEEN -9007199254740991 AND 9007199254740991[\s\S]*?`amount_minor` <> 0/u);
  assert.match(ledger, /HAVING COUNT\(`entry`.`id`\) <> `transaction`.`entry_count`[\s\S]*?SUM\(`entry`.`amount_minor`\), 1\) <> 0[\s\S]*?`account`.`currency_id` <> `transaction`.`currency_id`/u);

  const refunds = await migration('010_refunds.sql');
  assert.match(refunds, /CREATE TABLE IF NOT EXISTS `synex_ledger_refund_anchors`/u);
  assert.match(refunds, /CREATE TABLE IF NOT EXISTS `synex_ledger_refunds`/u);
  assert.match(refunds, /`refunded_minor` <= `refundable_minor`/u);
  assert.match(refunds, /UNIQUE KEY `uq_ledger_refunds_transaction` \(`refund_transaction_id`\)/u);
  assert.match(refunds, /UNIQUE KEY `uq_ledger_refunds_anchor_sequence`[\s\S]*?\(`anchor_transaction_id`, `sequence_no`\)/u);
  assert.match(refunds, /`cumulative_refunded_minor` BETWEEN `amount_minor` AND 9007199254740991/u);
});

test('holds, access, restrictions, and policies have explicit terminal and concurrency invariants', async () => {
  const holds = await migration('011_hold_lifecycle_v2.sql');
  assert.match(holds, /`capture_policy` IN \('single', 'multiple'\)/u);
  assert.match(holds, /`captured_minor` \+ `released_minor` \+ `remaining_minor` = `amount_minor`/u);
  assert.match(holds, /`state` IN \('active', 'partially_captured'\)[\s\S]*?`terminal_at` IS NULL/u);
  assert.match(holds, /`state` IN \('captured', 'released', 'expired'\)[\s\S]*?`terminal_at` IS NOT NULL/u);
  assert.match(holds, /UNIQUE KEY `uq_account_hold_events_v2_sequence`[\s\S]*?\(`hold_id`, `sequence_no`\)/u);

  const access = await migration('012_access_policies.sql');
  assert.match(access, /`valid_until` IS NULL OR `valid_until` > `valid_from`/u);
  assert.match(access, /UNIQUE KEY `uq_account_restrictions_active`[\s\S]*?\(`account_id`, `restriction_kind`, `active_marker`\)/u);
  assert.match(access, /`restriction_kind` IN[\s\S]*?'outgoing_blocked'[\s\S]*?'incoming_blocked'[\s\S]*?'all_blocked'/u);
  assert.match(access, /`minimum_balance_minor` <= `maximum_balance_minor`/u);
  assert.match(access, /PRIMARY KEY \(`account_id`, `usage_date`\)/u);
  assert.match(access, /`outgoing_minor` <= 9007199254740991/u);
});

test('group lifecycle journaling is local, fail-closed, and has no cross-domain foreign key', async () => {
  const lifecycle = await migration('013_group_deletion_journal.sql');
  assert.match(lifecycle, /CREATE TABLE IF NOT EXISTS `synex_account_group_deletions`/u);
  assert.match(lifecycle, /UNIQUE KEY `uq_account_group_deletions_action` \(`action_id`\)/u);
  assert.match(lifecycle, /`state` <> 'completed' OR `decision` = 'retain'[\s\S]*?`nonzero_account_count` = 0[\s\S]*?`nonterminal_hold_count` = 0[\s\S]*?`booked_minor_total` = 0/u);
  assert.doesNotMatch(lifecycle, /FOREIGN KEY/iu);
  assert.doesNotMatch(lifecycle, /`synex_groups`|`synex_group_[a-z0-9_]+`/u);
});

test('integrity, outbox, and archive migrations keep evidence append-only and bounded', async () => {
  const integrity = await migration('014_integrity_outbox_control.sql');
  assert.match(integrity, /CREATE TABLE IF NOT EXISTS `synex_account_outbox_attempts`/u);
  assert.match(integrity, /UNIQUE KEY `uq_account_outbox_attempts_sequence` \(`outbox_id`, `attempt_no`\)/u);
  assert.match(integrity, /CREATE TABLE IF NOT EXISTS `synex_account_outbox_retry_requests`/u);
  assert.match(integrity, /UNIQUE KEY `uq_account_outbox_retry_requests_scope`[\s\S]*?\(`requested_by_resource`, `idempotency_key`\)/u);
  assert.match(integrity, /`outcome` IN \('retry', 'dead'\)[\s\S]*?`error_code` IS NOT NULL/u);

  const archive = await migration('015_financial_archive_v2.sql');
  assert.match(archive, /UNIQUE KEY `uq_financial_archive_v2_source` \(`source_transaction_id`\)/u);
  assert.match(archive, /UNIQUE KEY `uq_financial_entry_archive_v2_source` \(`source_entry_id`\)/u);
  assert.match(archive, /`posting_model` IN \('legacy_pair', 'multi_leg'\)/u);
  assert.match(archive, /`amount_minor` <> 0[\s\S]*?BETWEEN -9007199254740991 AND 9007199254740991/u);
  assert.doesNotMatch(archive, /DELETE\s+FROM|TRUNCATE|DROP\s+TABLE/iu);

  const bounds = await migration('016_financial_entry_bounds.sql');
  assert.match(bounds, /`entry_count` BETWEEN 2 AND 16/u);
  assert.match(bounds, /`sequence_no` BETWEEN 1 AND 16/u);
  assert.match(bounds, /`synex_financial_transaction_archive_v2`/u);
  assert.match(bounds, /`synex_financial_entry_archive_v2`/u);
});
