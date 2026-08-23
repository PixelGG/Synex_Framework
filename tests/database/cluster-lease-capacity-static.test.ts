import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

test('migration 025 installs exact retained cluster-lease capacity authority', async () => {
  const migration = await readFile(path.join(
    root,
    'core/synex_core/migrations/025_cluster_lease_capacity.sql',
  ), 'utf8');

  for (const table of [
    'synex_cluster_lease_capacity',
    'synex_cluster_lease_kind_capacity',
  ]) {
    assert.match(migration, new RegExp(`CREATE TABLE IF NOT EXISTS \\x60${table}\\x60`, 'u'));
    assert.match(migration, new RegExp(`TABLE_NAME\\x60 = '${table}'`, 'u'));
  }
  assert.match(migration, /`global_limit` INT UNSIGNED NOT NULL DEFAULT 1000000/u);
  assert.match(migration, /\('session', 0, 500000\)/u);
  assert.match(migration, /\('admission', 0, 250000\)/u);
  assert.match(migration, /\('saga', 0, 250000\)/u);
  assert.match(migration, /\('character', 0, 100000\)/u);
  assert.match(migration, /\('other', 0, 100000\)/u);
  assert.doesNotMatch(migration, /CHECK\s*\([^)]*`entry_count`\s*<=/u);
  assert.equal(
    (migration.match(/TRIM\(REPLACE\(LOWER\(COALESCE\(`EXTRA`, ''\)\),\s*'default_generated', ''\)\) = 'on update current_timestamp\(6\)'/gu) ?? []).length,
    2,
  );
  assert.equal(
    (migration.match(/LOWER\(`DATA_TYPE`\) = '(?:tinyint|int)'\s+AND LOCATE\('unsigned', LOWER\(`COLUMN_TYPE`\)\) > 0\s+AND LOCATE\('zerofill', LOWER\(`COLUMN_TYPE`\)\) = 0/gu) ?? []).length,
    5,
  );
  assert.doesNotMatch(
    migration,
    /LOWER\(`COLUMN_TYPE`\) = '(?:tinyint|int) unsigned'/u,
  );
  for (const introducer of ['_utf8mb4', '_utf8mb3', '_utf8', '_ascii', '_latin1']) {
    assert.equal(
      (migration.match(new RegExp(`'${introducer}', ''`, 'gu')) ?? []).length,
      2,
      `${introducer} must be normalized only for the exact CHECK and generated expression`,
    );
  }

  assert.match(
    migration,
    /ADD COLUMN `lease_capacity_kind` VARCHAR\(9\)[\s\S]*?GENERATED ALWAYS AS[\s\S]*?STORED AFTER `lease_authority_kind`/u,
  );
  assert.match(migration, /WHEN `lease_name` = 'schema_migrations' THEN NULL/u);
  assert.match(migration, /WHEN LEFT\(`lease_name`, 8\) = 'session:' THEN 'session'/u);
  assert.match(migration, /WHEN LEFT\(`lease_name`, 10\) = 'admission:' THEN 'admission'/u);
  assert.match(migration, /WHEN LEFT\(`lease_name`, 5\) = 'saga:' THEN 'saga'/u);
  assert.match(
    migration,
    /WHEN LEFT\(`lease_name`, 17\) = 'character-delete:' THEN 'character'/u,
  );
  assert.match(migration, /ELSE 'other'/u);
  assert.match(
    migration,
    /ADD KEY `idx_cluster_leases_capacity_kind`\s*\(`lease_capacity_kind`, `lease_name`\)/u,
  );
  assert.match(migration, /lease capacity classification verification failed/u);

  assert.match(migration, /= 'singleton_id=1'/u);
  assert.match(migration, /= 'global_limit>0'/u);
  assert.match(
    migration,
    /= 'lease_capacity_kindin''session'',''admission'',''saga'',''character'',''other'''/u,
  );
  assert.match(migration, /= 'kind_limit>0'/u);
  assert.match(
    migration,
    /LOWER\(`TABLE_SCHEMA`\) = 'information_schema'[\s\S]*?UPPER\(`TABLE_NAME`\) = 'TABLE_CONSTRAINTS'[\s\S]*?UPPER\(`COLUMN_NAME`\) = 'ENFORCED'/u,
  );
  assert.match(
    migration,
    /PREPARE `synex_migrate_025_enforced_statement`[\s\S]*?EXECUTE `synex_migrate_025_enforced_statement`[\s\S]*?DEALLOCATE PREPARE `synex_migrate_025_enforced_statement`/u,
  );
  assert.match(migration, /UPPER\(COALESCE\(ENFORCED, ''NO''\)\) = ''YES''/u);
  assert.match(migration, /COALESCE\(@`synex_migrate_025_enforced_checks`, 0\) <> 4/u);
  assert.match(migration, /capacity checks are not enforced/u);
  assert.match(
    migration,
    /`kind_capacity`\.`kind_limit` > `global_capacity`\.`global_limit`/u,
  );

  const backfill = migration.slice(
    migration.indexOf('SELECT COUNT(*) INTO `v_lease_count`'),
    migration.indexOf('capacity backfill verification failed'),
  );
  assert.match(backfill, /WHERE `lease_capacity_kind` IS NOT NULL/u);
  assert.doesNotMatch(backfill, /WHERE\s+`terminal_compaction_at`\s+IS\s+NULL/iu);
  assert.doesNotMatch(backfill, /WHERE\s+`expires_at`/iu);
  assert.match(backfill, /`v_lease_count` > 4294967295/u);
  assert.match(backfill, /HAVING COUNT\(\*\) > 4294967295/u);
  assert.match(
    backfill,
    /UPDATE `synex_cluster_lease_kind_capacity` AS `counter`[\s\S]*?GROUP BY `lease_capacity_kind`/u,
  );
  assert.match(
    backfill,
    /UPDATE `synex_cluster_lease_capacity`[\s\S]*?SET `entry_count` = CAST\(`v_lease_count` AS UNSIGNED\)/u,
  );
  assert.match(migration, /lease classification consistency failed/u);
  assert.match(migration, /capacity backfill verification failed/u);
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
});

test('migration 025 preserves stored operator limits during idempotent backfill', async () => {
  const migration = await readFile(path.join(
    root,
    'core/synex_core/migrations/025_cluster_lease_capacity.sql',
  ), 'utf8');
  assert.match(
    migration,
    /ON DUPLICATE KEY UPDATE `singleton_id` = VALUES\(`singleton_id`\)/u,
  );
  assert.match(
    migration,
    /ON DUPLICATE KEY UPDATE\s*`lease_capacity_kind` = VALUES\(`lease_capacity_kind`\)/u,
  );
  for (const limitColumn of ['global_limit', 'kind_limit']) {
    assert.doesNotMatch(
      migration,
      new RegExp(`ON DUPLICATE KEY UPDATE[\\s\\S]{0,160}\\x60${limitColumn}\\x60\\s*=`, 'u'),
    );
  }
});
