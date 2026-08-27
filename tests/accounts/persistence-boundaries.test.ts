import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { accountRuntimeSources, accountsRoot } from './helpers.js';

test('Accounts remains a server-only Foundation resource with no direct Groups persistence access', async () => {
  const sources = await accountRuntimeSources();
  const runtime = sources.map((entry) => entry.contents).join('\n');
  const manifest = await readFile(path.join(accountsRoot, 'fxmanifest.lua'), 'utf8');
  const metadata = JSON.parse(await readFile(
    path.join(accountsRoot, 'synex.resource.json'),
    'utf8',
  )) as { contracts: { consume: string[] }; dependencies: { required: Array<{ name: string }> } };

  assert.doesNotMatch(runtime, /\bRegisterNetEvent\b|\bRegisterNUICallback\b|\bRegisterNuiCallback\b/u);
  assert.doesNotMatch(runtime, /\bTriggerClientEvent\b|\bSendNUIMessage\b|\bSetNuiFocus\b/u);
  assert.match(manifest, /server_only 'yes'/u);
  assert.doesNotMatch(manifest, /client_scripts?|ui_page/u);
  assert.doesNotMatch(runtime, /`synex_groups`|`synex_group_[a-z0-9_]+`/u);
  assert.deepEqual(metadata.contracts.consume, []);
  assert.equal(metadata.dependencies.required.some((dependency) => dependency.name === 'synex_groups'), false);
});

test('financial truth is append-only while privacy lifecycle changes only bounded provenance', async () => {
  const runtime = (await accountRuntimeSources()).map((entry) => entry.contents).join('\n');
  assert.doesNotMatch(runtime, /DELETE\s+FROM\s+`synex_(?:ledger_transactions|ledger_entries|ledger_postings|account_balance_snapshots)`/iu);
  assert.doesNotMatch(runtime, /UPDATE\s+`synex_ledger_entries`/iu);
  assert.doesNotMatch(runtime, /UPDATE\s+`synex_ledger_postings`/iu);
  assert.doesNotMatch(
    runtime,
    /UPDATE\s+`synex_ledger_transactions`[\s\S]{0,240}`(?:currency_id|transaction_kind|posting_model|entry_count|reason_code|status|posted_at)`\s*=/iu,
  );
  assert.match(runtime, /INSERT INTO `synex_ledger_transactions`/u);
  assert.match(runtime, /INSERT INTO `synex_ledger_entries`/u);
  assert.match(runtime, /INSERT INTO `synex_account_balance_snapshots`/u);
});

test('transaction persistence enforces currency, roles, restrictions, policies, and deterministic locks', async () => {
  const transactions = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'transactions.lua'),
    'utf8',
  );
  const engine = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'engine_shared.lua'),
    'utf8',
  );
  assert.match(engine, /table\.sort\(sorted\)/u);
  assert.match(engine, /ORDER BY `account`.`id` ASC FOR UPDATE/u);
  assert.match(engine, /WHERE `caller_resource` = \?[\s\S]*?`caller_principal_kind` = \?[\s\S]*?`caller_principal_ref` = \?[\s\S]*?`operation_name` = \?[\s\S]*?`idempotency_key` = \?[\s\S]*?FOR UPDATE/u);
  assert.match(engine, /existing\.request_fingerprint ~= command\.fingerprint/u);
  assert.match(transactions, /if currencyId and tostring\(currencyId\) ~= tostring\(account\.currency_id\)/u);
  assert.match(transactions, /domainError\('CURRENCY_MISMATCH'/u);
  assert.match(transactions, /account_role ~= 'asset'/u);
  assert.match(transactions, /domainError\('INVALID_LEDGER_ROLE'/u);
  assert.match(transactions, /Engine:evaluateAccountOperation/u);
  const accountLock = transactions.indexOf('self:loadAccounts(query, publicIds)');
  const sequenceGuard = transactions.indexOf('validateExpectedSequences(\n        accounts, publicIds');
  const ledgerInsert = transactions.indexOf('INSERT INTO `synex_ledger_transactions`');
  assert.ok(accountLock >= 0);
  assert.ok(sequenceGuard > accountLock);
  assert.ok(ledgerInsert > sequenceGuard);
  assert.match(transactions, /accounts\[accountId\]\.sequence_no ~= expected[\s\S]*?domainError\('WRITE_CONFLICT'/u);
  assert.match(transactions, /expectedSequences = command\.expectedSequences/u);
  assert.match(engine, /SELECT `restriction_kind`[\s\S]*?FROM `synex_account_restrictions`/u);
  assert.match(engine, /domainError\('ACCOUNT_RESTRICTED'/u);
  assert.match(engine, /FROM `synex_account_policies` WHERE `account_id` = \?/u);
  for (const errorCode of [
    'MINIMUM_BALANCE_VIOLATION',
    'MAXIMUM_BALANCE_VIOLATION',
    'TRANSFER_LIMIT_EXCEEDED',
    'DAILY_LIMIT_EXCEEDED',
    'OPERATION_NOT_ALLOWED',
  ]) {
    assert.match(engine, new RegExp(`domainError\\('${errorCode}'`, 'u'));
  }
  assert.match(engine, /SUM\(`remaining_minor`\)[\s\S]*?`expires_at` > CURRENT_TIMESTAMP\(6\)/u);
});

test('closed account mutations are fenced and open refund lifecycles block close', async () => {
  const [engine, accounts, access, restrictions] = await Promise.all([
    readFile(path.join(accountsRoot, 'server', 'persistence', 'engine_shared.lua'), 'utf8'),
    readFile(path.join(accountsRoot, 'server', 'persistence', 'accounts_v2.lua'), 'utf8'),
    readFile(path.join(accountsRoot, 'server', 'persistence', 'access_v2.lua'), 'utf8'),
    readFile(path.join(accountsRoot, 'server', 'persistence', 'restrictions_v2.lua'), 'utf8'),
  ]);
  assert.match(engine, /function Engine:requireMutableAccount/u);
  assert.match(engine, /domainError\('ACCOUNT_CLOSED'/u);
  assert.equal((access.match(/Engine:requireMutableAccount\(/gu) ?? []).length, 3);
  assert.equal((restrictions.match(/Engine:requireMutableAccount\(/gu) ?? []).length, 2);
  assert.equal((accounts.match(/Engine:requireMutableAccount\(/gu) ?? []).length, 1);
  assert.match(accounts, /Engine:evaluateAccountClosure/u);
  assert.match(engine, /FROM `synex_ledger_refund_anchors` AS `anchor`[\s\S]*?`anchor`.`state` = 'open'/u);
  assert.match(engine, /NOT EXISTS \(SELECT 1 FROM `synex_ledger_reversals` AS `reversal`/u);
  assert.match(engine, /domainError\('ACCOUNT_LIFECYCLE_BLOCKED'/u);
  assert.match(engine, /lifecycle = 'open_refund'/u);
});

test('refunds and reversals are separate immutable relationships with cumulative caps', async () => {
  const transactions = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'transactions.lua'),
    'utf8',
  );
  assert.match(transactions, /function port:reverseTransaction/u);
  assert.match(transactions, /TRANSACTION_ALREADY_REVERSED/u);
  assert.match(transactions, /REVERSAL_OF_REVERSAL/u);
  assert.match(transactions, /INSERT INTO `synex_ledger_reversals`/u);
  assert.match(transactions, /function port:refundTransaction/u);
  assert.match(transactions, /Domain\.validateRefund/u);
  assert.match(transactions, /tonumber\(anchor\.refunded_minor\) \+ command\.amountMinor > tonumber\(anchor\.refundable_minor\)/u);
  assert.match(transactions, /INSERT INTO `synex_ledger_refunds`/u);
  assert.match(transactions, /`cumulative_refunded_minor`/u);
  assert.doesNotMatch(transactions, /UPDATE `synex_ledger_transactions`/u);
});

test('holds and restrictions use version fences and semantic expiry instead of cleanup-only truth', async () => {
  const holds = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'holds_v2.lua'),
    'utf8',
  );
  const restrictions = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'restrictions_v2.lua'),
    'utf8',
  );
  assert.match(holds, /\(`hold`\.`expires_at` <= CURRENT_TIMESTAMP\(6\)\) AS `is_expired`/u);
  assert.match(holds, /command\.expectedVersion and tonumber\(hold\.version\) ~= command\.expectedVersion/u);
  assert.match(holds, /WHERE `id` = \? AND `version` = \?/u);
  assert.match(holds, /reservationReleaseByAccount/u);
  assert.match(holds, /'partially_captured'/u);
  assert.match(holds, /'expired'/u);
  assert.match(restrictions, /Engine:requireAccess\(query,[\s\S]*?'settings\.manage'/u);
  assert.match(restrictions, /WHERE `id` = \? AND `status` = 'active' AND `version` = \?/u);
  assert.match(restrictions, /valid_until` <= CURRENT_TIMESTAMP\(6\)/u);
  assert.match(restrictions, /SET `status` = 'expired', `active_marker` = NULL/u);
});

test('list reads are bounded and transaction history is account-scoped', async () => {
  const transactionReads = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'transaction_reads.lua'),
    'utf8',
  );
  const restrictions = await readFile(
    path.join(accountsRoot, 'server', 'persistence', 'restrictions_v2.lua'),
    'utf8',
  );
  assert.match(transactionReads, /An account scope is required for transaction history access/u);
  assert.match(transactionReads, /EXISTS \(SELECT 1 FROM `synex_ledger_entries` AS `scope_entry`/u);
  assert.match(transactionReads, /math\.min\(tonumber\(filter\.limit\) or 50, 50\)/u);
  assert.match(transactionReads, /ORDER BY `transaction`.`id` DESC LIMIT \?/u);
  assert.match(restrictions, /math\.min\(tonumber\(limit\) or 50, 50\)/u);
  assert.match(restrictions, /ORDER BY `restriction`.`id` ASC LIMIT \?/u);
});
