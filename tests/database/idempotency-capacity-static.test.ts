import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

test('migration 022 creates exact persistent capacity authority and backfills every key', async () => {
  const migration = await readFile(path.join(
    root,
    'core/synex_core/migrations/022_idempotency_capacity.sql',
  ), 'utf8');
  for (const table of [
    'synex_idempotency_capacity',
    'synex_idempotency_owner_capacity',
    'synex_idempotency_namespace_capacity',
  ]) {
    assert.match(migration, new RegExp(`CREATE TABLE IF NOT EXISTS \x60${table}\x60`, 'u'));
    assert.match(
      migration,
      new RegExp(`TABLE_NAME\x60 = '${table}'`, 'u'),
      `${table} must be metadata verified`,
    );
  }
  assert.match(migration, /`global_limit` INT UNSIGNED NOT NULL DEFAULT 1000000/u);
  assert.match(migration, /`owner_limit` INT UNSIGNED NOT NULL DEFAULT 100000/u);
  assert.match(migration, /`namespace_limit` INT UNSIGNED NOT NULL DEFAULT 10000/u);
  assert.equal(
    (migration.match(/TRIM\(REPLACE\(LOWER\(COALESCE\(`EXTRA`, ''\)\),\s*'default_generated', ''\)\) = 'on update current_timestamp\(6\)'/gu) ?? []).length,
    3,
  );
  assert.equal(
    (migration.match(/LOWER\(`DATA_TYPE`\) = '(?:tinyint|int)'\s+AND LOCATE\('unsigned', LOWER\(`COLUMN_TYPE`\)\) > 0\s+AND LOCATE\('zerofill', LOWER\(`COLUMN_TYPE`\)\) = 0/gu) ?? []).length,
    7,
  );
  assert.doesNotMatch(
    migration,
    /LOWER\(`COLUMN_TYPE`\) = '(?:tinyint|int) unsigned'/u,
  );
  assert.match(migration, /CHECK \(`singleton_id` = 1\)/u);
  assert.match(migration, /CHECK \(`owner_limit` > 0 AND `owner_limit` <= `global_limit`\)/u);
  assert.match(migration, /CHECK \(`namespace_limit` > 0 AND `namespace_limit` <= `owner_limit`\)/u);
  assert.match(migration, /= 'singleton_id=1'/u);
  assert.match(migration, /= 'global_limit>0'/u);
  assert.match(migration, /= 'owner_limit>0andowner_limit<=global_limit'/u);
  assert.match(migration, /= 'namespace_limit>0andnamespace_limit<=owner_limit'/u);
  assert.match(
    migration,
    /LOWER\(`TABLE_SCHEMA`\) = 'information_schema'[\s\S]*?UPPER\(`TABLE_NAME`\) = 'TABLE_CONSTRAINTS'[\s\S]*?UPPER\(`COLUMN_NAME`\) = 'ENFORCED'/u,
  );
  assert.match(
    migration,
    /PREPARE `synex_migrate_022_enforced_statement`[\s\S]*?EXECUTE `synex_migrate_022_enforced_statement`[\s\S]*?DEALLOCATE PREPARE `synex_migrate_022_enforced_statement`/u,
  );
  assert.match(migration, /UPPER\(COALESCE\(ENFORCED, ''NO''\)\) = ''YES''/u);
  assert.match(migration, /COALESCE\(@synex_migrate_022_enforced_checks, 0\) <> 4/u);
  assert.match(migration, /capacity checks are not enforced/u);
  assert.match(
    migration,
    /FOREIGN KEY \(`owner_resource`\)[\s\S]*?REFERENCES `synex_idempotency_owner_capacity` \(`owner_resource`\)[\s\S]*?ON UPDATE RESTRICT ON DELETE RESTRICT/u,
  );
  assert.match(
    migration,
    /SELECT COUNT\(\*\) FROM `information_schema`\.`KEY_COLUMN_USAGE`[\s\S]*?`CONSTRAINT_NAME` = 'fk_idempotency_namespace_capacity_owner'[\s\S]*?\) <> 1/u,
  );
  assert.match(migration, /`reference`\.`UNIQUE_CONSTRAINT_SCHEMA` = DATABASE\(\)/u);
  assert.match(migration, /`usage`\.`REFERENCED_TABLE_SCHEMA` = DATABASE\(\)/u);
  assert.match(migration, /`usage`\.`ORDINAL_POSITION` = 1/u);
  assert.match(
    migration,
    /ON DUPLICATE KEY UPDATE `singleton_id` = VALUES\(`singleton_id`\)/u,
  );
  assert.doesNotMatch(
    migration,
    /ON DUPLICATE KEY UPDATE[\s\S]{0,180}(?:global_limit|owner_limit|namespace_limit)\s*=/u,
  );
  assert.match(migration, /SELECT COUNT\(\*\) INTO v_key_count FROM `synex_idempotency_keys`/u);
  assert.equal((migration.match(/FROM `synex_idempotency_keys`/gu) ?? []).length >= 6, true);
  assert.doesNotMatch(migration, /FROM `synex_idempotency_keys`\s+WHERE `state`/u);
  assert.doesNotMatch(migration, /DELETE FROM `synex_idempotency_keys`/u);
  assert.match(migration, /v_key_count > 4294967295/u);
  assert.match(migration, /SUM\(`entry_count`\)[\s\S]*?<> v_key_count/u);
  assert.match(migration, /capacity backfill verification failed/u);
  assert.equal((migration.match(/SIGNAL SQLSTATE '45000'/gu) ?? []).length >= 8, true);
});

test('idempotency claims lock and increment capacity in one bounded transaction', async () => {
  const reliability = await readFile(path.join(
    root,
    'core/synex_core/server/reliability.lua',
  ), 'utf8');
  const claim = reliability.slice(
    reliability.indexOf('function idempotency:run'),
    reliability.indexOf('function idempotency:compactExpired'),
  );
  assert.ok(claim.length > 0);
  const globalLock = claim.indexOf('FROM `synex_idempotency_capacity`');
  const ownerLock = claim.indexOf('FROM `synex_idempotency_owner_capacity`');
  const namespaceLock = claim.indexOf('FROM `synex_idempotency_namespace_capacity`');
  const keyLock = claim.indexOf('FROM `synex_idempotency_keys`');
  const globalIncrement = claim.indexOf('UPDATE `synex_idempotency_capacity`');
  const ownerIncrement = claim.indexOf('UPDATE `synex_idempotency_owner_capacity`');
  const namespaceIncrement = claim.indexOf('UPDATE `synex_idempotency_namespace_capacity`');
  const keyInsert = claim.indexOf('INSERT INTO `synex_idempotency_keys`');
  assert.ok(
    globalLock >= 0 && ownerLock > globalLock && namespaceLock > ownerLock
      && keyLock > namespaceLock && globalIncrement > keyLock
      && ownerIncrement > globalIncrement && namespaceIncrement > ownerIncrement
      && keyInsert > namespaceIncrement,
  );
  const capacityTransaction = claim.slice(
    claim.indexOf('database:withTransaction'),
    claim.indexOf('local ok, value, operationError'),
  );
  assert.equal((capacityTransaction.match(/FOR UPDATE/gu) ?? []).length, 4);
  assert.equal((capacityTransaction.match(/affectedRows\([^)]*\) ~= 1/gu) ?? []).length, 4);
  assert.match(claim, /globalCount >= globalLimit and 'global'/u);
  assert.match(claim, /ownerCount >= ownerLimit and 'owner'/u);
  assert.match(claim, /namespaceCount >= namespaceLimit and 'namespace'/u);
  assert.match(claim, /if claimRecord then[\s\S]*?return true/u);
  assert.match(claim, /IDEMPOTENCY_CAPACITY_EXCEEDED/u);
  assert.match(claim, /IDEMPOTENCY_CAPACITY_INVALID/u);
  assert.match(claim, /synex_idempotency_capacity_utilization_high_watermark/u);
  assert.match(claim, /synex_idempotency_capacity_denials_total/u);
  assert.doesNotMatch(claim, /COUNT\s*\(/iu);
  assert.doesNotMatch(claim, /DELETE\s+FROM/iu);
  assert.doesNotMatch(claim, /scope\s*=\s*(?:owner|namespace)\b/u);
});

test('core manifest orders migration 022 and owns all capacity tables', async () => {
  const manifest = JSON.parse(await readFile(path.join(
    root,
    'core/synex_core/synex.resource.json',
  ), 'utf8')) as {
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
    dataOwnership: { tables: string[] };
  };
  const offset = manifest.migrations.findIndex((entry) => entry.id === '022_idempotency_capacity');
  assert.ok(offset > 0);
  assert.equal(manifest.migrations[offset - 1]?.id, '021_worker_queue_scalability');
  assert.deepEqual(manifest.migrations[offset], {
    id: '022_idempotency_capacity',
    path: 'migrations/022_idempotency_capacity.sql',
    transactional: false,
  });
  for (const table of [
    'synex_idempotency_capacity',
    'synex_idempotency_owner_capacity',
    'synex_idempotency_namespace_capacity',
  ]) assert.ok(manifest.dataOwnership.tables.includes(table));
});
