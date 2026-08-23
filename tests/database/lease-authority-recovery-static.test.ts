import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const source = (relativePath: string) => readFile(path.join(root, relativePath), 'utf8');

test('migration 023 installs fail-closed authority and stale-session queue metadata', async () => {
  const migration = await source(
    'core/synex_core/migrations/023_lease_authority_recovery.sql',
  );
  assert.match(
    migration,
    /ADD COLUMN `lease_authority_kind` VARCHAR\(10\)[\s\S]*?CHARACTER SET ascii COLLATE ascii_bin[\s\S]*?GENERATED ALWAYS AS[\s\S]*?LEFT\(`lease_name`, 8\) = 'session:'[\s\S]*?LEFT\(`lease_name`, 10\) = 'admission:'[\s\S]*?ELSE NULL[\s\S]*?STORED AFTER `lease_domain_kind`/u,
  );
  assert.match(
    migration,
    /`COLUMN_NAME` = 'lease_authority_kind'[\s\S]*?LOWER\(`DATA_TYPE`\) = 'varchar'[\s\S]*?`CHARACTER_MAXIMUM_LENGTH` = 10[\s\S]*?`CHARACTER_SET_NAME` = 'ascii'[\s\S]*?`COLLATION_NAME` = 'ascii_bin'[\s\S]*?`IS_NULLABLE` = 'YES'[\s\S]*?STORED GENERATED/u,
  );
  assert.match(
    migration,
    /DECLARE `expected_generation` LONGTEXT DEFAULT\s*'casewhenleftlease_name,8=''session:''then''session''whenleftlease_name,10=''admission:''then''admission''elsenullend'/u,
  );
  assert.match(
    migration,
    /IF `normalized_generation` IS NULL\s*OR `normalized_generation` <> `expected_generation` THEN/u,
  );
  assert.doesNotMatch(migration, /`normalized_generation` NOT LIKE/u);
  const exactExpression = "casewhenleftlease_name,8='session:'then'session'"
    + "whenleftlease_name,10='admission:'then'admission'elsenullend";
  const semanticallyExtendedExpression = exactExpression.replace(
    'elsenullend',
    "whenleftlease_name,8='generic:'then'session'elsenullend",
  );
  assert.notEqual(semanticallyExtendedExpression, exactExpression);
  assert.doesNotMatch(
    migration.match(/DECLARE `expected_generation`[\s\S]*?;/u)?.[0] ?? '',
    /generic:/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_cluster_leases_authority_expiry`\s*\(`lease_authority_kind`, `terminal_compaction_at`, `expires_at`, `lease_name`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_sessions_open_heartbeat_expiry`\s*\(`closed_at`, `last_seen_at`, `id`, `server_instance_id`\)/u,
  );
  for (const [indexName, columns] of [
    ['idx_cluster_leases_authority_expiry', [
      'lease_authority_kind', 'terminal_compaction_at', 'expires_at', 'lease_name',
    ]],
    ['idx_sessions_open_heartbeat_expiry', [
      'closed_at', 'last_seen_at', 'id', 'server_instance_id',
    ]],
  ] as const) {
    columns.forEach((column, offset) => {
      assert.match(
        migration,
        new RegExp(
          `INDEX_NAME\` = '${indexName}'[\\s\\S]*?SEQ_IN_INDEX\` = ${offset + 1}`
          + `[\\s\\S]*?COLUMN_NAME\` = '${column}'[\\s\\S]*?SUB_PART\` IS NULL`
          + `[\\s\\S]*?COLLATION\` = 'A'`,
          'u',
        ),
      );
    });
  }
  assert.equal((migration.match(/SIGNAL SQLSTATE '45000'/gu) ?? []).length, 4);
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
});

test('expired authority retirement scans only one indexed bounded domain queue', async () => {
  const [persistence, lifecycle] = await Promise.all([
    source('core/synex_core/server/persistence.lua'),
    source('core/synex_core/server/bootstrap_lifecycle.lua'),
  ]);
  const retirement = persistence.match(
    /function leases:retireExpiredAuthority\(maximum\)([\s\S]*?)\n    end\n    function leases:compactTerminal/u,
  )?.[1];
  assert.ok(retirement);
  assert.match(retirement, /FORCE INDEX \(`idx_cluster_leases_authority_expiry`\)/u);
  assert.match(
    retirement,
    /WHERE `lease_authority_kind` = \? AND `terminal_compaction_at` IS NULL[\s\S]*?`expires_at` <= CURRENT_TIMESTAMP\(6\)[\s\S]*?ORDER BY `expires_at` ASC, `lease_name` ASC LIMIT \? FOR UPDATE/u,
  );
  assert.match(
    retirement,
    /SET `owner_id` = 'retired',[\s\S]*?`fencing_token` = CASE[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)[\s\S]*?WHERE `lease_authority_kind` = \?[\s\S]*?`terminal_compaction_at` IS NULL[\s\S]*?`expires_at` <= CURRENT_TIMESTAMP\(6\)[\s\S]*?`lease_name` IN/u,
  );
  assert.match(retirement, /retired ~= selected[\s\S]*?return false/u);
  assert.match(
    retirement,
    /if not committed then return nil,[\s\S]*?nextAuthorityRecoveryKind = kind == 'session' and 'admission' or 'session'/u,
  );
  assert.doesNotMatch(retirement, /lease_domain_kind|schema_migrations|synex_sagas|character-delete/iu);
  assert.match(
    lifecycle,
    /scheduleEvery\(5000,[\s\S]*?retireExpiredAuthority\(250\)[\s\S]*?if retirementError then return nil, retirementError end[\s\S]*?compactTerminal\(250\)[\s\S]*?'core\.leases\.compact_terminal'/u,
  );
});

test('runtime closure and crash cleanup retire only exact session authority', async () => {
  const [runtime, fencing, maintenance] = await Promise.all([
    source('core/synex_core/server/runtime_persistence_instances.lua'),
    source('core/synex_core/server/identity_session_fencing.lua'),
    source('core/synex_core/server/identity_connection_maintenance.lua'),
  ]);
  assert.match(
    runtime,
    /function instances:terminateLocalSessions[\s\S]*?INNER JOIN `synex_sessions`[\s\S]*?`lease`.`owner_id`\s*= CONCAT\(`session`.`server_instance_id`, ':', `session`.`id`\)[\s\S]*?CONCAT\('session:', `session`.`user_id`\)[\s\S]*?CONCAT\('session:', `session`.`user_id`, ':', `session`.`id`\)[\s\S]*?`lease`.`terminal_compaction_at` IS NULL/u,
  );
  const localTermination = runtime.match(
    /function instances:terminateLocalSessions[\s\S]*?\n    end/u,
  )?.[0];
  assert.ok(localTermination);
  assert.doesNotMatch(localTermination, /`lease`.`expires_at`\s*>/u);
  assert.match(
    runtime,
    /FORCE INDEX \(`idx_sessions_open_heartbeat_expiry`\)[\s\S]*?`closed_at` IS NULL[\s\S]*?ORDER BY `stale_session`.`last_seen_at` ASC,\s*`stale_session`.`id` ASC LIMIT \? FOR UPDATE/u,
  );
  assert.match(
    fencing,
    /function repository:close\(session, reason\)[\s\S]*?FROM `synex_sessions` WHERE `id` = \? FOR UPDATE[\s\S]*?`source_generation` = \?[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)[\s\S]*?`lease_name` = \? AND `owner_id` = \? AND `fencing_token` = \?[\s\S]*?if not committed then return nil/u,
  );
  assert.match(
    maintenance,
    /function maintenance:closeOrDefer[\s\S]*?players:detachSource[\s\S]*?sessionRepository\.close[\s\S]*?deferClosure/u,
  );
  assert.match(
    maintenance,
    /stored\.userId == candidate\.userId[\s\S]*?stored\.serverInstanceId == expectedInstanceId[\s\S]*?stored\.sourceGeneration[\s\S]*?stored\.source/u,
  );
});

test('the core manifest registers migration 023 after idempotency capacity', async () => {
  const manifest = JSON.parse(await source('core/synex_core/synex.resource.json')) as {
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
  };
  const offset = manifest.migrations.findIndex(
    (entry) => entry.id === '023_lease_authority_recovery',
  );
  assert.ok(offset > 0);
  assert.equal(manifest.migrations[offset - 1]?.id, '022_idempotency_capacity');
  assert.deepEqual(manifest.migrations[offset], {
    id: '023_lease_authority_recovery',
    path: 'migrations/023_lease_authority_recovery.sql',
    transactional: false,
  });
});
