import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

test('migration 024 installs exact retained session-control capacity and retention metadata', async () => {
  const migration = await readFile(path.join(
    root,
    'core/synex_core/migrations/024_session_control_capacity.sql',
  ), 'utf8');
  for (const table of [
    'synex_session_control_capacity',
    'synex_session_control_requester_capacity',
  ]) assert.match(migration, new RegExp(`CREATE TABLE IF NOT EXISTS \`${table}\``, 'u'));
  assert.match(migration, /`global_limit` INT UNSIGNED NOT NULL DEFAULT 100000/u);
  assert.match(migration, /`requester_limit` INT UNSIGNED NOT NULL DEFAULT 10000/u);
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
  assert.doesNotMatch(migration, /CHECK\s*\([^)]*`entry_count`\s*<=/u);
  assert.match(
    migration,
    /ADD KEY `idx_session_control_terminal_retention`\s*\(`state`, `completed_at`, `request_id`\)/u,
  );
  assert.match(migration, /information_schema`.`CHECK_CONSTRAINTS`/u);
  assert.match(migration, /= 'singleton_id=1'/u);
  assert.match(migration, /= 'global_limit>0'/u);
  assert.match(
    migration,
    /= 'requester_limit>0andrequester_limit<=global_limit'/u,
  );
  assert.match(
    migration,
    /LOWER\(`TABLE_SCHEMA`\) = 'information_schema'[\s\S]*?UPPER\(`TABLE_NAME`\) = 'TABLE_CONSTRAINTS'[\s\S]*?UPPER\(`COLUMN_NAME`\) = 'ENFORCED'/u,
  );
  assert.match(
    migration,
    /PREPARE `synex_migrate_024_enforced_statement`[\s\S]*?EXECUTE `synex_migrate_024_enforced_statement`[\s\S]*?DEALLOCATE PREPARE `synex_migrate_024_enforced_statement`/u,
  );
  assert.match(migration, /UPPER\(COALESCE\(ENFORCED, ''NO''\)\) = ''YES''/u);
  assert.match(migration, /COALESCE\(@synex_migrate_024_enforced_checks, 0\) <> 3/u);
  assert.match(migration, /capacity checks are not enforced/u);
  assert.match(
    migration,
    /SELECT COUNT\(\*\) FROM `information_schema`.`KEY_COLUMN_USAGE`[\s\S]*?\) <> 1/u,
  );
  assert.match(migration, /`usage`.`REFERENCED_TABLE_SCHEMA` = DATABASE\(\)/u);
  assert.match(migration, /`usage`.`ORDINAL_POSITION` = 1/u);
  assert.match(migration, /SELECT COUNT\(\*\) INTO v_request_count FROM `synex_session_control_requests`/u);
  assert.match(
    migration,
    /SELECT `requested_by_instance_id`, CAST\(COUNT\(\*\) AS UNSIGNED\)[\s\S]*?FROM `synex_session_control_requests`[\s\S]*?GROUP BY `requested_by_instance_id`/u,
  );
  assert.doesNotMatch(
    migration.slice(
      migration.indexOf('SELECT COUNT(*) INTO v_request_count'),
      migration.indexOf('capacity backfill verification failed'),
    ),
    /WHERE\s+`state`/u,
  );
  assert.match(migration, /existing request count exceeds counter range/u);
  assert.match(migration, /requester count exceeds counter range/u);
  assert.match(migration, /capacity backfill verification failed/u);
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
});

test('session-control issue and compaction paths preserve capacity and authority invariants', async () => {
  const runtime = (await Promise.all([
    'core/synex_core/server/runtime_persistence_control.lua',
    'core/synex_core/server/runtime_persistence_control_retention.lua',
    'core/synex_core/server/runtime_persistence_instances.lua',
    'core/synex_core/server/runtime_persistence.lua',
  ].map((relativePath) => readFile(path.join(root, relativePath), 'utf8')))).join('\n');
  const issue = runtime.slice(
    runtime.indexOf('function instances:requestRemoteKicks'),
    runtime.indexOf('function instances:pendingLocalControls'),
  );
  const gateLock = issue.indexOf('lockAdmissionGate(query');
  const targetLock = issue.indexOf('WHERE `id` = ? AND `closed_at` IS NULL FOR UPDATE');
  const pendingLock = issue.indexOf('LIMIT 2 FOR UPDATE');
  const globalLock = issue.indexOf('FROM `synex_session_control_capacity`');
  const requesterLock = issue.indexOf('FROM `synex_session_control_requester_capacity`');
  assert.ok(gateLock >= 0 && gateLock < targetLock);
  assert.ok(targetLock < pendingLock && pendingLock < globalLock && globalLock < requesterLock);
  assert.match(issue, /FORCE INDEX \(`uq_session_control_active`\)[\s\S]*?`request`\.`active_marker` = 1[\s\S]*?`request`\.`state` = 'pending'[\s\S]*?LIMIT 2 FOR UPDATE/u);
  assert.match(issue, /table\.sort\(requesterIds\)[\s\S]*?for _, requesterId in ipairs\(requesterIds\)/u);
  assert.match(issue, /validForeignPending[\s\S]*?issuedRequestId = pending\.request_id[\s\S]*?return true/u);
  assert.match(issue, /issuedRequestId and ownedIssuedRequest/u);
  assert.match(issue, /SESSION_CONTROL_CAPACITY_EXCEEDED/u);
  assert.match(issue, /globalCount >= globalLimit and 'global'/u);
  assert.match(issue, /requesterCount >= requesterLimit and 'requester'/u);
  assert.match(issue, /affectedRows\(globalUpdated\) ~= 1/u);
  assert.match(issue, /affectedRows\(requesterUpdated\) ~= 1/u);
  assert.match(issue, /affectedRows\(insertedRequest\) ~= 1/u);
  assert.match(issue, /affectedRows\(insertedAuthority\) ~= 1/u);
  const globalIncrement = issue.indexOf('SET `entry_count` = `entry_count` + 1');
  const parentInsert = issue.indexOf('INSERT INTO `synex_session_control_requests`');
  const childInsert = issue.indexOf('INSERT INTO\n                        `synex_session_control_authority`');
  assert.ok(globalIncrement >= 0 && globalIncrement < parentInsert && parentInsert < childInsert);

  const compact = runtime.slice(
    runtime.indexOf('function instances:compactTerminalControls'),
    runtime.indexOf('function instances:snapshot'),
  );
  assert.match(compact, /idx_session_control_terminal_retention/u);
  assert.match(compact, /`request`.`state` = \?/u);
  assert.match(compact, /`request`.`completed_at` IS NOT NULL/u);
  assert.match(compact, /`request`.`completed_at`[\s\S]*?<= TIMESTAMPADD\(DAY, -\?, CURRENT_TIMESTAMP\(6\)\)/u);
  assert.doesNotMatch(compact.slice(0, compact.indexOf('LIMIT ? FOR UPDATE')), /expires_at/u);
  const candidateLock = compact.indexOf('LIMIT ? FOR UPDATE');
  const compactGlobalLock = compact.indexOf('FROM `synex_session_control_capacity`');
  const compactRequesterLock = compact.indexOf('FROM `synex_session_control_requester_capacity`');
  const childDelete = compact.indexOf('DELETE `authority`');
  const parentDelete = compact.indexOf('DELETE FROM `synex_session_control_requests`');
  const globalRelease = compact.indexOf('SET `entry_count` = `entry_count` - ?');
  assert.ok(candidateLock < compactGlobalLock && compactGlobalLock < compactRequesterLock);
  assert.ok(compactRequesterLock < childDelete && childDelete < parentDelete && parentDelete < globalRelease);
  assert.match(compact, /legacyWithoutAuthority = #rows - expectedAuthorityRows/u);
  assert.match(compact, /affectedRows\(authorityDeleted\) ~= expectedAuthorityRows/u);
  assert.match(compact, /affectedRows\(requestsDeleted\) ~= #rows/u);
  assert.match(compact, /controlCompactionState = state == 'completed' and 'expired' or 'completed'/u);
  assert.match(compact, /synex_session_control_compaction_runs_total/u);
  assert.match(runtime, /synex_session_control_capacity_utilization_high_watermark/u);
  assert.match(runtime, /synex_session_control_capacity_denials_total/u);
});

test('session-control capacity migration, configuration, and worker are repository-owned', async () => {
  const manifest = JSON.parse(await readFile(path.join(
    root,
    'core/synex_core/synex.resource.json',
  ), 'utf8')) as {
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
    dataOwnership: { tables: string[] };
  };
  const sessionControlMigration = manifest.migrations.find(
    (migration) => migration.id === '024_session_control_capacity',
  );
  assert.deepEqual(sessionControlMigration, {
    id: '024_session_control_capacity',
    path: 'migrations/024_session_control_capacity.sql',
    transactional: false,
  });
  assert.ok(
    manifest.migrations.indexOf(sessionControlMigration!)
      < manifest.migrations.findIndex((migration) => migration.id === '025_cluster_lease_capacity'),
  );
  for (const table of [
    'synex_session_control_capacity',
    'synex_session_control_requester_capacity',
  ]) assert.ok(manifest.dataOwnership.tables.includes(table));

  const defaults = JSON.parse(await readFile(path.join(
    root,
    'core/synex_core/config/default.json',
  ), 'utf8')) as { retention: { sessionControlAfterDays: number; batchSize: number } };
  assert.equal(defaults.retention.sessionControlAfterDays, 30);
  assert.ok(defaults.retention.batchSize >= 1 && defaults.retention.batchSize <= 1000);
  const schema = await readFile(path.join(root, 'schemas/config.schema.json'), 'utf8');
  assert.match(schema, /"sessionControlAfterDays": \{ "type": "integer", "minimum": 1, "maximum": 36500 \}/u);
  const configuration = await readFile(path.join(
    root,
    'core/synex_core/server/configuration.lua',
  ), 'utf8');
  assert.match(configuration, /config\.retention\.sessionControlAfterDays,[\s\S]*?1, 36500/u);
  const lifecycle = await readFile(path.join(
    root,
    'core/synex_core/server/bootstrap_lifecycle.lua',
  ), 'utf8');
  assert.match(
    lifecycle,
    /scheduleEvery\(defaultConfig\.retention\.workerIntervalMs,[\s\S]*?compactTerminalControls[\s\S]*?'core\.session_controls\.compact_terminal'/u,
  );
});
