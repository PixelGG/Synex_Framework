import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('migration 020 installs exact terminal eligibility and bounded open-session indexes', async () => {
  const migration = await source(
    'core/synex_core/migrations/020_terminal_lease_eligibility.sql',
  );
  assert.match(
    migration,
    /ADD COLUMN `terminal_compaction_at` DATETIME\(6\) NULL AFTER `expires_at`/u,
  );
  assert.match(
    migration,
    /`COLUMN_NAME` = 'terminal_compaction_at'[\s\S]*?LOWER\(`DATA_TYPE`\) = 'datetime'[\s\S]*?`DATETIME_PRECISION` = 6[\s\S]*?`IS_NULLABLE` = 'YES'[\s\S]*?COALESCE\(`EXTRA`, ''\) = ''/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_cluster_leases_terminal_compaction`\s*\(`terminal_compaction_at`, `lease_name`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_sessions_character_open` \(`character_id`, `closed_at`, `id`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_sessions_user_open`\s*\(`user_id`, `closed_at`, `connected_at`, `id`\)/u,
  );
  for (const [indexName, columns] of [
    ['idx_cluster_leases_terminal_compaction', ['terminal_compaction_at', 'lease_name']],
    ['idx_sessions_character_open', ['character_id', 'closed_at', 'id']],
    ['idx_sessions_user_open', ['user_id', 'closed_at', 'connected_at', 'id']],
  ] as const) {
    columns.forEach((column, offset) => {
      assert.match(
        migration,
        new RegExp(
          'INDEX_NAME` = \'' + indexName + '\'[\\s\\S]*?SEQ_IN_INDEX` = '
          + String(offset + 1) + '[\\s\\S]*?COLUMN_NAME` = \'' + column + '\'',
          'u',
        ),
      );
    });
  }
  assert.equal(
    (migration.match(/`SUB_PART` IS NULL AND `COLLATION` = 'A'/gu) ?? []).length,
    9,
  );
  assert.match(
    migration,
    /INNER JOIN `synex_sagas`[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)[\s\S]*?`saga`.`state` IN \('completed', 'failed', 'cancelled'\)/u,
  );
  assert.match(
    migration,
    /INNER JOIN `synex_character_deletion_plans`[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)[\s\S]*?`deletion`.`state` IN \('completed', 'failed', 'cancelled'\)/u,
  );
  assert.match(
    migration,
    /SET `owner_id` = 'retired',[\s\S]*?`fencing_token` = CASE[\s\S]*?`terminal_compaction_at` = `expires_at`[\s\S]*?`expires_at` <= CURRENT_TIMESTAMP\(6\)[\s\S]*?`lease_name` LIKE 'session:%'[\s\S]*?`lease_name` LIKE 'admission:%'/u,
  );
});

test('terminal transitions mark only fenced leases and the compactor never scans domain backlogs', async () => {
  const [persistence, reliability, deletion] = await Promise.all([
    source('core/synex_core/server/persistence.lua'),
    source('core/synex_core/server/reliability.lua'),
    source('core/synex_core/server/identity_character_deletion_reconciliation.lua'),
  ]);
  const compactor = persistence.match(
    /function leases:compactTerminal\(maximum\)([\s\S]*?)\n    end/u,
  )?.[1];
  assert.ok(compactor);
  assert.match(compactor, /FORCE INDEX \(`idx_cluster_leases_terminal_compaction`\)/u);
  assert.match(compactor, /WHERE `terminal_compaction_at` <= CURRENT_TIMESTAMP\(6\)/u);
  assert.match(
    compactor,
    /ORDER BY `terminal_compaction_at` ASC,\s*`lease_name` ASC\s*LIMIT \? FOR UPDATE/u,
  );
  assert.doesNotMatch(compactor, /synex_sagas|synex_character_deletion_plans|UNION|JOIN/iu);
  assert.doesNotMatch(compactor, /`expires_at`|lease_domain_kind/iu);
  assert.match(compactor, /`lease_capacity_kind` IS NOT NULL/u);
  assert.match(compactor, /`lease_name` <> 'schema_migrations'/u);
  assert.match(compactor, /DELETE FROM `synex_cluster_leases`/u);
  assert.match(compactor, /UPDATE `synex_cluster_lease_capacity`/u);
  assert.match(compactor, /UPDATE `synex_cluster_lease_kind_capacity`/u);

  for (const runtime of [reliability, deletion]) {
    assert.match(
      runtime,
      /SET `owner_id` = 'terminal',[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)/u,
    );
    assert.match(
      runtime,
      /WHERE `lease_name` = \? AND `owner_id` = \? AND `fencing_token` = \?[\s\S]*?`expires_at` > CURRENT_TIMESTAMP\(6\)[\s\S]*?`terminal_compaction_at` IS NULL/u,
    );
  }
  assert.match(
    reliability,
    /affectedRows\(updated\) ~= 1[\s\S]*?SAGA_LEASE_LOST/u,
  );
  assert.match(
    deletion,
    /affectedRows\(updated\) ~= 1[\s\S]*?DELETE_LEASE_LOST/u,
  );
  assert.match(
    reliability,
    /UPDATE `synex_sagas`[\s\S]*?if nextStateTerminal then[\s\S]*?retireSagaLease\(query, command\.publicId, lease\)/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_character_deletion_plans`[\s\S]*?retireLease\(query, planId, lease\)/u,
  );
});

test('character session locking uses bounded exact locks in character-first order', async () => {
  const [fencing, runtimeInstances, runtimeControl] = await Promise.all([
    source('core/synex_core/server/identity_session_fencing.lua'),
    source('core/synex_core/server/runtime_persistence_instances.lua'),
    source('core/synex_core/server/runtime_persistence_control.lua'),
  ]);
  const runtimePersistence = `${runtimeInstances}\n${runtimeControl}`;
  const lockFunction = fencing.match(
    /function repository:lockCharacterSessions\([\s\S]*?\n    end/u,
  )?.[0];
  assert.ok(lockFunction);
  assert.match(
    lockFunction,
    /FROM `synex_sessions` WHERE `id` = \? FOR UPDATE/u,
  );
  assert.match(
    lockFunction,
    /FORCE INDEX \(`idx_sessions_character_open`\)[\s\S]*?WHERE `character_id` = \? AND `closed_at` IS NULL AND `id` <> \?[\s\S]*?ORDER BY `id` ASC LIMIT 1 FOR UPDATE/u,
  );
  assert.doesNotMatch(lockFunction, /\bOR\b/u);
  assert.match(
    runtimePersistence,
    /FROM `synex_sessions`\s*FORCE INDEX \(`idx_sessions_user_open`\)\s*WHERE `user_id` = \? AND `server_instance_id` <> \? AND `closed_at` IS NULL\s*ORDER BY `connected_at` ASC, `id` ASC LIMIT 32/u,
  );
  assert.match(
    runtimePersistence,
    /function instances:hasOpenUserSessions[\s\S]*?FORCE INDEX \(`idx_sessions_user_open`\)[\s\S]*?ORDER BY `connected_at` ASC, `id` ASC LIMIT 1 FOR UPDATE/u,
  );
  assert.match(
    runtimePersistence,
    /function instances:requestRemoteKicks[\s\S]*?lockAdmissionGate\(query, gate, authorityGuard\)[\s\S]*?LIMIT 32 FOR UPDATE/u,
  );
  assert.match(
    fencing,
    /function repository:create\(session\)[\s\S]*?lockAdmissionGate\(query, admission\)[\s\S]*?INSERT INTO `synex_sessions`[\s\S]*?`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)[\s\S]*?affectedRows\(retired\) ~= 1/u,
  );
});

test('session and admission lease retirement is exact and reacquire is ABA-safe', async () => {
  const persistence = await source('core/synex_core/server/persistence.lua');
  assert.match(
    persistence,
    /`terminal_compaction_at` = IF\(\s*\(\? = 1 OR \? = 1\), NULL, `terminal_compaction_at`\)/u,
  );
  assert.match(
    persistence,
    /local sessionLease = name:sub\(1, 8\) == 'session:'[\s\S]*?local admissionLease = name:sub\(1, 10\) == 'admission:'/u,
  );
  assert.match(
    persistence,
    /SET `owner_id` = 'retired',[\s\S]*?`fencing_token` = CASE[\s\S]*?`expires_at` = CURRENT_TIMESTAMP\(6\),\s*`terminal_compaction_at` = CURRENT_TIMESTAMP\(6\)\s*WHERE `lease_name` = \? AND `owner_id` = \? AND `fencing_token` = \?/u,
  );
  assert.match(
    persistence,
    /compactable and tonumber\(affected\) ~= 1[\s\S]*?'LEASE_LOST'/u,
  );
});
