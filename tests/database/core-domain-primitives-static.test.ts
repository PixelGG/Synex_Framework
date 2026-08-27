import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationPath = 'core/synex_core/migrations/027_domain_primitives.sql';

test('Core domain primitive migration owns bounded receipts and generic deletion state', async () => {
  const [migration, manifestText] = await Promise.all([
    readFile(migrationPath, 'utf8'),
    readFile('core/synex_core/synex.resource.json', 'utf8'),
  ]);
  const manifest = JSON.parse(manifestText) as {
    migrations: Array<{ id: string; path: string }>;
    dataOwnership: { tables: string[] };
  };
  const tables = [
    'synex_domain_operation_receipts',
    'synex_domain_receipt_capacity',
    'synex_domain_receipt_owner_capacity',
    'synex_domain_deletion_plan_capacity',
    'synex_domain_deletion_plan_owner_capacity',
    'synex_domain_deletion_domains',
    'synex_domain_deletion_providers',
    'synex_domain_deletion_plans',
    'synex_domain_deletion_actions',
  ];
  for (const table of tables) {
    assert.match(migration, new RegExp(`CREATE TABLE IF NOT EXISTS \`${table}\``, 'u'));
    assert.ok(manifest.dataOwnership.tables.includes(table), table);
  }
  assert.ok(manifest.migrations.some((item) =>
    item.id === '027_domain_primitives' && item.path === 'migrations/027_domain_primitives.sql'
  ));
  assert.equal((migration.match(/-- synex:statement/gu) ?? []).length, 14);
  assert.match(migration, /PRIMARY KEY \(`owner_resource`, `operation_name`, `idempotency_key`\)/u);
  assert.match(migration, /CHECK \(`state` IN \('pending', 'completed'\)\)/u);
  assert.match(migration, /`global_limit`[\s\S]*?`owner_limit`[\s\S]*?`entry_count` <= `global_limit`/u);
  assert.match(migration, /UNIQUE KEY `uq_domain_deletion_request`/u);
  assert.match(migration, /CHECK \(`decision` IN \('allow', 'block', 'delete', 'anonymize', 'retain'\)\)/u);
  assert.match(migration, /FOREIGN KEY \(`plan_id`\) REFERENCES `synex_domain_deletion_plans`/u);
  assert.match(migration, /FOREIGN KEY \(`domain_name`\) REFERENCES `synex_domain_deletion_domains`/u);
  assert.match(migration, /KEY `idx_domain_deletion_due`/u);
  assert.match(migration,
    /KEY `idx_domain_deletion_retention` \(`purge_after`, `plan_id`\)/u);
  assert.match(migration,
    /KEY `idx_domain_deletion_action_provider_schema`[\s\S]*?`provider_owner`[\s\S]*?`provider_name`[\s\S]*?`state`[\s\S]*?`provider_schema_version`[\s\S]*?`plan_id`[\s\S]*?`action_index`/u);
  assert.match(migration, /`global_limit` INT UNSIGNED NOT NULL DEFAULT 10000/u);
  assert.match(migration, /`owner_limit` INT UNSIGNED NOT NULL DEFAULT 1000/u);
  assert.match(migration,
    /`state` IN \('completed', 'blocked', 'failed'\)[\s\S]*?`purge_after` IS NOT NULL/u);
  assert.match(migration, /TIMESTAMPADD\(DAY, 30, `completed_at`\)/u);
  assert.match(migration, /CREATE PROCEDURE `synex_migrate_027_domain_deletion_capacity`/u);
  assert.match(migration,
    /INSERT INTO `synex_domain_deletion_plan_owner_capacity`[\s\S]*?GROUP BY `requester_owner`/u);
  assert.match(migration,
    /UPDATE `synex_domain_deletion_plan_capacity`[\s\S]*?CAST\(v_plan_count AS UNSIGNED\)/u);
  assert.match(migration, /KEY `idx_domain_receipts_expiry`/u);
});

test('Core data port is capability gated, owner fenced, table confined, and atomically receipts commits', async () => {
  const [port, api, bootstrap, lifecycle, manifest] = await Promise.all([
    readFile('core/synex_core/server/data_port.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap_api.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap_lifecycle.lua', 'utf8'),
    readFile('core/synex_core/fxmanifest.lua', 'utf8'),
  ]);
  assert.match(api, /facade\.Database = \{/u);
  for (const capability of [
    'synex.database.read',
    'synex.database.write',
    'synex.database.transaction',
    'synex.database.maintenance',
  ]) assert.match(api, new RegExp(`'${capability.replaceAll('.', '\\.')}''?`, 'u'));
  assert.match(port, /manifest\.dataOwnership[\s\S]*?tables/u);
  assert.match(port, /DATABASE_TABLE_NOT_OWNED/u);
  assert.match(port, /DATABASE_PARAMETER_MISMATCH/u);
  assert.match(port, /maximumTransactionStatements = 65535/u);
  assert.match(port, /maximumRows = 8192/u);
  assert.match(port, /maximumResultBytes = 4194304/u);
  assert.match(port, /maximumRequestBytes = 8388608/u);
  assert.match(port, /__synex_database_null/u);
  assert.match(port, /WITH statements are supported/u);
  assert.match(port, /safe allowlist/u);
  assert.match(port, /local function cteReference/u);
  assert.match(port, /function port:maintenance\(owner, epoch, request, handler\)/u);
  assert.match(port, /maximumRequestBytes/u);
  assert.match(port, /owners:isCurrent\(owner, epoch\)/u);
  assert.match(port, /DATABASE_DEADLINE_EXCEEDED/u);
  const capacityLock = port.match(
    /local function lockReceiptCapacity[\s\S]*?local port = \{\}/u,
  )?.[0] ?? '';
  const transaction = port.match(
    /function port:transaction[\s\S]*?function port:maintenance/u,
  )?.[0] ?? '';
  const compaction = port.match(/function port:compactExpired[\s\S]*?return port/u)?.[0] ?? '';
  assert.match(transaction, /INSERT IGNORE INTO\s+`synex_domain_operation_receipts`/u);
  assert.match(transaction, /UPDATE `synex_domain_operation_receipts`[\s\S]*?`state` = 'completed'/u);
  assert.match(transaction, /database:withTransaction\(function\(query\)/u);
  const claimAt = transaction.indexOf('INSERT IGNORE INTO');
  const handlerAt = transaction.indexOf('foundation.safeCall(handler, transaction)');
  const reserveAt = transaction.lastIndexOf('lockReceiptCapacity(query, owner)');
  const completeAt = transaction.indexOf("SET `state` = 'completed'");
  assert.ok(claimAt >= 0 && claimAt < handlerAt);
  assert.ok(handlerAt < reserveAt && reserveAt < completeAt);
  assert.ok(
    capacityLock.indexOf('FROM `synex_domain_receipt_capacity`')
      < capacityLock.indexOf('FROM `synex_domain_receipt_owner_capacity`'),
  );
  assert.ok(
    compaction.indexOf('FORCE INDEX (`idx_domain_receipts_expiry`)')
      < compaction.indexOf('FROM `synex_domain_receipt_capacity`'),
  );
  assert.ok(
    compaction.indexOf('FROM `synex_domain_receipt_capacity`')
      < compaction.indexOf('FROM `synex_domain_receipt_owner_capacity`'),
  );
  assert.ok(
    transaction.indexOf('owners:isCurrent(owner, epoch)')
      < transaction.lastIndexOf("`state` = 'completed'"),
  );
  assert.match(bootstrap, /factories\.dataPort\(/u);
  assert.match(lifecycle, /core\.domain_receipts\.compact_expired/u);
  assert.match(manifest, /'server\/data_port\.lua'/u);
});

test('generic deletion coordinator durably catalogs providers and retries through CAS-fenced plans', async () => {
  const [coordinator, api, bootstrap, lifecycle, manifest] = await Promise.all([
    readFile('core/synex_core/server/domain_deletion.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap_api.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap.lua', 'utf8'),
    readFile('core/synex_core/server/bootstrap_lifecycle.lua', 'utf8'),
    readFile('core/synex_core/fxmanifest.lua', 'utf8'),
  ]);
  assert.match(api, /facade\.DomainDeletions = \{/u);
  for (const capability of [
    'synex.deletions.provider',
    'synex.deletions.manage',
    'synex.deletions.read',
  ]) assert.match(api, new RegExp(capability.replaceAll('.', '\\.'), 'u'));
  assert.match(coordinator, /owners:track\(owner, epoch, 'domain-deletion-provider'/u);
  assert.match(coordinator, /owners:beginOperation\(/u);
  assert.match(coordinator, /owners:finishOperation\(/u);
  assert.match(coordinator, /AND `requester_owner` = \?/u);
  assert.match(coordinator, /function service:get\(owner, epoch, planId\)/u);
  assert.match(coordinator, /function service:process\(owner, epoch, planId\)/u);
  assert.match(api, /domainDeletion:get\(caller, epoch, planId\)/u);
  assert.match(api, /domainDeletion:process\(caller, epoch, planId\)/u);
  assert.match(coordinator, /INSERT INTO `synex_domain_deletion_providers`/u);
  assert.match(coordinator, /provider_schema_version/u);
  assert.match(coordinator, /decisions = \{ allow = true, block = true, delete = true, anonymize = true, retain = true \}/u);
  assert.match(coordinator, /leases:acquire\('domain-delete:' \.\. plan\.planId/u);
  assert.match(coordinator, /`lease_fencing_token` = \?/u);
  assert.match(coordinator, /WHERE `plan_id` = \? AND `version` = \?/u);
  assert.match(coordinator, /`next_attempt_at` = TIMESTAMPADD\(SECOND, 5/u);
  assert.match(coordinator, /DELETION_PROVIDER_UNAVAILABLE/u);
  assert.match(coordinator, /function service:reconcile\(limit\)/u);
  assert.match(coordinator, /maximumRetainedPlans = 10000/u);
  assert.match(coordinator, /maximumPlansPerOwner = 1000/u);
  assert.match(coordinator, /terminalRetentionDays = 30/u);
  assert.match(coordinator, /DELETION_PLAN_CAPACITY_EXCEEDED/u);
  assert.doesNotMatch(coordinator, /COUNT\s*\(/iu);
  const planning = coordinator.match(
    /local planId = foundation\.nextId\('dplan'\)[\s\S]*?if not committed then/u,
  )?.[0] ?? '';
  const claimAt = planning.indexOf('INSERT IGNORE INTO');
  const planLockAt = planning.indexOf('FROM `synex_domain_deletion_plans`', claimAt);
  const providerLockAt = planning.indexOf('FROM `synex_domain_deletion_providers`', planLockAt);
  const capacityLockAt = planning.indexOf('lockPlanCapacity(query, owner)', providerLockAt);
  const globalReserveAt = planning.indexOf(
    '`synex_domain_deletion_plan_capacity`', capacityLockAt,
  );
  const ownerReserveAt = planning.indexOf(
    '`synex_domain_deletion_plan_owner_capacity`', globalReserveAt,
  );
  assert.ok(claimAt >= 0 && claimAt < planLockAt);
  assert.ok(planLockAt < providerLockAt && providerLockAt < capacityLockAt);
  assert.ok(capacityLockAt < globalReserveAt && globalReserveAt < ownerReserveAt);
  const capacityLock = coordinator.match(
    /local function lockPlanCapacity[\s\S]*?local function canonical/u,
  )?.[0] ?? '';
  assert.ok(
    capacityLock.indexOf('FROM `synex_domain_deletion_plan_capacity`')
      < capacityLock.indexOf('FROM `synex_domain_deletion_plan_owner_capacity`'),
  );
  const registration = coordinator.match(
    /function service:registerProvider[\s\S]*?local function invoke/u,
  )?.[0] ?? '';
  const schemaChangeAt = registration.indexOf(
    'if persistedSchema and persistedSchema ~= definition.schemaVersion then',
  );
  const schemaGuardQueryAt = registration.indexOf(
    'FROM `synex_domain_deletion_actions` AS `action`',
  );
  assert.ok(schemaChangeAt >= 0 && schemaChangeAt < schemaGuardQueryAt);
  assert.doesNotMatch(
    registration.slice(schemaGuardQueryAt, registration.indexOf('end\n            local affected')),
    /FOR UPDATE/u,
  );
  const reconcile = coordinator.match(
    /function service:reconcile\(limit\)[\s\S]*?function service:snapshot/u,
  )?.[0] ?? '';
  const retentionAt = reconcile.indexOf('FORCE INDEX (`idx_domain_deletion_retention`)');
  const retentionGlobalAt = reconcile.indexOf('FROM `synex_domain_deletion_plan_capacity`');
  const retentionOwnerAt = reconcile.indexOf('FROM `synex_domain_deletion_plan_owner_capacity`');
  assert.ok(retentionAt >= 0 && retentionAt < retentionGlobalAt);
  assert.ok(retentionGlobalAt < retentionOwnerAt);
  assert.match(reconcile, /LIMIT \? FOR UPDATE/u);
  assert.match(reconcile, /AND `purge_after` <= CURRENT_TIMESTAMP\(6\)/u);
  assert.match(reconcile, /DELETE FROM `synex_domain_deletion_plans`/u);
  assert.match(coordinator,
    /`purge_after` = TIMESTAMPADD\(DAY, \?, CURRENT_TIMESTAMP\(6\)\)/u);
  assert.match(bootstrap, /factories\.domainDeletion\(/u);
  assert.match(lifecycle, /core\.domain_deletions\.reconciliation/u);
  assert.match(manifest, /'server\/domain_deletion\.lua'/u);
});
