import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const migrationRoot = path.join(root, 'resources', 'synex_entities', 'migrations');

async function migration(name: string): Promise<string> {
  return readFile(path.join(migrationRoot, name), 'utf8');
}

test('entity schema keeps migration 001 immutable and namespaces durable tombstones forward-only', async () => {
  const legacyBytes = await readFile(path.join(migrationRoot, '001_entities.sql'));
  const lifecycle = await migration('002_entity_lifecycle_authority.sql');

  assert.equal(
    createHash('sha256').update(legacyBytes).digest('hex'),
    '23b4e8da34370c0d6d56b69e6815f8750007f0a9f33b88ccab61f452102c83dd',
    '001_entities.sql is an applied migration boundary and must remain byte-identical',
  );
  assert.match(lifecycle, /ADD COLUMN IF NOT EXISTS `persistence_policy`/u);
  assert.match(lifecycle, /ADD COLUMN IF NOT EXISTS `recovery_policy`/u);
  assert.match(lifecycle, /ADD COLUMN IF NOT EXISTS `server_scope`/u);
  assert.match(lifecycle, /MODIFY COLUMN `persistent_key` VARCHAR\(128\) NULL/u);
  assert.match(lifecycle, /'character', 'group', 'resource', 'system', 'user'/u);
  for (const state of [
    'defined', 'spawning', 'active', 'orphaned', 'recovering',
    'dormant', 'deleting', 'deleted', 'failed',
  ]) {
    assert.match(lifecycle, new RegExp(`'${state}'`, 'u'));
  }
  for (const policy of ['temporary', 'persistent', 'session', 'owner_lifetime']) {
    assert.match(lifecycle, new RegExp(`'${policy}'`, 'u'));
  }
  for (const policy of ['none', 'manual', 'on_demand', 'automatic']) {
    assert.match(lifecycle, new RegExp(`'${policy}'`, 'u'));
  }
  assert.match(
    lifecycle,
    /`status` = 'deleted' AND `deleted_at` IS NOT NULL[\s\S]*?`status` <> 'deleted' AND `deleted_at` IS NULL/u,
  );

  const namespacedIndex = lifecycle.indexOf(
    'CREATE UNIQUE INDEX IF NOT EXISTS `uq_synex_entities_resource_persistent_key`',
  );
  const legacyIndexRemoval = lifecycle.indexOf(
    'DROP INDEX IF EXISTS `uq_synex_entities_persistent_key`',
  );
  assert.ok(namespacedIndex >= 0 && namespacedIndex < legacyIndexRemoval);
  assert.match(
    lifecycle,
    /`uq_synex_entities_resource_persistent_key`[\s\S]*?\(`resource_owner`, `persistent_key`\)/u,
  );
  assert.match(
    lifecycle,
    /`persistence_policy` IN \('temporary', 'session'\)[\s\S]*?`persistent_key` IS NULL/u,
  );
  assert.match(
    lifecycle,
    /`persistence_policy` IN \('persistent', 'owner_lifetime'\)[\s\S]*?`persistent_key` IS NOT NULL[\s\S]*?`persistent_key` = LOWER\(`persistent_key`\)/u,
  );
  assert.match(
    lifecycle,
    /`recovery_policy` <> 'automatic'[\s\S]*?`persistence_policy` IN \('persistent', 'owner_lifetime'\)/u,
  );
  assert.match(
    lifecycle,
    /`archetype_namespace` IS NOT NULL[\s\S]*?`archetype_schema_version` IS NOT NULL[\s\S]*?`archetype_descriptor_json` IS NOT NULL/u,
  );
  assert.doesNotMatch(
    lifecycle,
    /\b(?:DROP\s+(?:TABLE|COLUMN)|TRUNCATE|RENAME\s+TABLE|DELETE\s+FROM)\b/iu,
  );
  assert.equal(
    (lifecycle.match(/DROP INDEX IF EXISTS/gu) ?? []).length,
    1,
    'only the superseded global key index may be removed',
  );
});

test('entity extensions enforce active binding uniqueness and bounded schema-owned JSON', async () => {
  const extensions = await migration('003_entity_extensions.sql');
  const tables = [...extensions.matchAll(/CREATE TABLE IF NOT EXISTS `([^`]+)`/gu)]
    .map((match) => match[1]);
  assert.deepEqual(tables, [
    'synex_entity_bindings',
    'synex_entity_components',
    'synex_entity_states',
    'synex_entity_tags',
    'synex_entity_checkpoints',
  ]);

  assert.match(
    extensions,
    /`active_marker` TINYINT UNSIGNED GENERATED ALWAYS AS \([\s\S]*?`released_at` IS NULL[\s\S]*?\) STORED/u,
  );
  assert.match(
    extensions,
    /UNIQUE KEY `uq_synex_entity_bindings_active_ref`\s*\(`binding_namespace`, `binding_ref`, `active_marker`\)/u,
  );
  assert.match(
    extensions,
    /UNIQUE KEY `uq_synex_entity_bindings_active_entity`\s*\(`entity_id`, `active_marker`\)/u,
  );
  assert.match(
    extensions,
    /`released_at` IS NULL AND `release_reason_code` IS NULL[\s\S]*?`released_at` IS NOT NULL/u,
  );

  assert.match(
    extensions,
    /ck_synex_entity_components_payload`[\s\S]*?JSON_VALID\(`payload_json`\)[\s\S]*?OCTET_LENGTH\(`payload_json`\) BETWEEN 2 AND 32768/u,
  );
  assert.match(
    extensions,
    /ck_synex_entity_states_value`[\s\S]*?JSON_VALID\(`value_json`\)[\s\S]*?OCTET_LENGTH\(`value_json`\) BETWEEN 1 AND 8192/u,
  );
  assert.match(
    extensions,
    /ck_synex_entity_checkpoints_state`[\s\S]*?JSON_VALID\(`generic_state_json`\)[\s\S]*?OCTET_LENGTH\(`generic_state_json`\) BETWEEN 2 AND 16384/u,
  );
  assert.match(extensions, /`authority_mode` IN \('server', 'client_observed'\)/u);
  assert.match(extensions, /`replication_mode` IN \('none', 'scoped'\)/u);
  assert.equal((extensions.match(/ON DELETE RESTRICT/gu) ?? []).length, 5);
  assert.doesNotMatch(
    extensions,
    /`(?:velocity|angular_velocity|animation|wheel_rotation|door_angle)`/iu,
  );
});

test('entity authority and recovery tables are fenced, database-timed, and retention-indexed', async () => {
  const cluster = await migration('004_entity_cluster_recovery.sql');
  const tables = [...cluster.matchAll(/CREATE TABLE IF NOT EXISTS `([^`]+)`/gu)]
    .map((match) => match[1]);
  assert.deepEqual(tables, [
    'synex_entity_authority_leases',
    'synex_entity_recovery_history',
  ]);

  for (const column of [
    'instance_id', 'authority_token', 'resource_epoch', 'lease_generation',
    'lease_state', 'claimed_at', 'heartbeat_at', 'lease_until', 'released_at', 'version',
  ]) {
    assert.match(cluster, new RegExp('`' + column + '`', 'u'));
  }
  assert.match(cluster, /`authority_token` VARCHAR\(96\)[\s\S]*?ascii_bin NOT NULL/u);
  assert.match(cluster, /`resource_epoch` BIGINT UNSIGNED NOT NULL/u);
  assert.match(cluster, /`resource_epoch` BETWEEN 1 AND 9007199254740991/u);
  assert.match(cluster, /CHAR_LENGTH\(`authority_token`\) BETWEEN 8 AND 96/u);
  assert.match(cluster, /`claimed_at` DATETIME\(6\) NOT NULL/u);
  assert.match(cluster, /`heartbeat_at` DATETIME\(6\) NOT NULL/u);
  assert.match(cluster, /`lease_until` DATETIME\(6\) NOT NULL/u);
  assert.match(cluster, /`lease_state` = 'active'[\s\S]*?`lease_until` > `heartbeat_at`/u);
  assert.match(cluster, /`heartbeat_at` >= `claimed_at`[\s\S]*?`lease_until` >= `heartbeat_at`/u);
  assert.match(cluster, /PRIMARY KEY \(`entity_id`\)/u);
  assert.match(cluster, /idx_synex_entity_authority_expiry/u);
  assert.match(cluster, /idx_synex_entity_authority_instance/u);
  assert.match(
    cluster,
    /idx_synex_entity_authority_token`[\s\S]*?\(`authority_token`, `resource_epoch`, `lease_state`, `entity_id`\)/u,
  );
  assert.match(cluster, /idx_synex_entity_authority_scope/u);

  assert.match(cluster, /`retain_until` DATETIME\(6\) NOT NULL/u);
  assert.match(cluster, /idx_synex_entity_recovery_retention/u);
  assert.match(cluster, /`retain_until` > `occurred_at`/u);
  assert.match(
    cluster,
    /ck_synex_entity_recovery_details`[\s\S]*?JSON_VALID\(`details_json`\)[\s\S]*?OCTET_LENGTH\(`details_json`\) BETWEEN 2 AND 8192/u,
  );
  assert.match(cluster, /`attempt_number` BETWEEN 1 AND 1000/u);
  assert.match(cluster, /'scheduled', 'started', 'recovered', 'failed', 'paused', 'cancelled'/u);
  assert.equal((cluster.match(/ON DELETE RESTRICT/gu) ?? []).length, 2);
  assert.doesNotMatch(cluster, /`(?:handle|net_id|network_owner)`/iu);
});
