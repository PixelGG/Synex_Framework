import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationPath = 'resources/synex_world/migrations/001_world.sql';

function statements(sql: string): string[] {
  return sql
    .split(/^-- synex:statement\s*$/mu)
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

test('World migration is MariaDB-compatible, ordered, and owns exactly three domain tables', async () => {
  const sql = await readFile(migrationPath, 'utf8');
  assert.equal(sql.includes('\r'), false);
  assert.equal(statements(sql).length, 3);
  assert.deepEqual(
    [...sql.matchAll(/CREATE TABLE IF NOT EXISTS `([a-z0-9_]+)`/gu)]
      .map((match) => match[1]),
    ['synex_world_state', 'synex_world_door_states', 'synex_world_outbox'],
  );
  for (const statement of statements(sql)) {
    assert.match(statement, /^CREATE TABLE IF NOT EXISTS `synex_world_/u);
    assert.match(statement, /ENGINE=InnoDB/u);
  }
  assert.doesNotMatch(sql, /\b(?:DROP|TRUNCATE|REPLACE|DELETE)\b/iu);
  assert.doesNotMatch(sql, /\b(?:SERIAL|JSONB|TIMESTAMPTZ|RETURNING|CREATE EXTENSION)\b/iu);
  assert.doesNotMatch(sql, /\b(?:REFERENCES|FOREIGN KEY)\b/iu);
  for (const match of sql.matchAll(/CONSTRAINT `([^`]+)`/gu)) {
    assert.ok((match[1] ?? '').length <= 64, `${match[1]} exceeds MariaDB identifier limits`);
  }
});

test('World state and door tables preserve schema version, provenance, and OCC without physics state', async () => {
  const sql = await readFile(migrationPath, 'utf8');
  const state = sql.match(
    /CREATE TABLE IF NOT EXISTS `synex_world_state` \(([\s\S]*?)\n\) ENGINE=InnoDB/u,
  )?.[1] ?? '';
  const doors = sql.match(
    /CREATE TABLE IF NOT EXISTS `synex_world_door_states` \(([\s\S]*?)\n\) ENGINE=InnoDB/u,
  )?.[1] ?? '';
  for (const body of [state, doors]) {
    assert.match(body, /`schema_version` INT UNSIGNED NOT NULL/u);
    assert.match(body, /`version` BIGINT UNSIGNED NOT NULL DEFAULT 1/u);
    assert.match(body, /`updated_by_type`/u);
    assert.match(body, /`updated_by_ref`/u);
    assert.match(body, /`source_resource`/u);
    assert.match(body, /`reason_code`/u);
    assert.match(body, /`trace_id`/u);
    assert.match(body, /`updated_at` DATETIME\(6\)/u);
  }
  assert.match(state, /PRIMARY KEY \(`state_key`, `scope_type`, `scope_ref`\)/u);
  assert.match(state,
    /`value_type` IN \('boolean', 'integer', 'number', 'string', 'enum', 'structured'\)/u);
  assert.match(state, /CHECK \(JSON_VALID\(`value_json`\)\)/u);
  assert.match(doors, /PRIMARY KEY \(`door_key`\)/u);
  assert.match(doors, /`state` IN \('LOCKED', 'UNLOCKED', 'DISABLED'\)/u);
  assert.doesNotMatch(doors, /(?:ratio|angle|hinge|velocity|physics)/iu);
});

test('World outbox schema and repository retain an atomic, domain-confined delivery boundary', async () => {
  const [sql, repository, adapter] = await Promise.all([
    readFile(migrationPath, 'utf8'),
    readFile('resources/synex_world/server/repository.lua', 'utf8'),
    readFile('resources/synex_world/server/database_adapter.lua', 'utf8'),
  ]);
  const outbox = sql.match(
    /CREATE TABLE IF NOT EXISTS `synex_world_outbox` \(([\s\S]*?)\n\) ENGINE=InnoDB/u,
  )?.[1] ?? '';
  assert.match(outbox, /UNIQUE KEY `uq_world_outbox_event_id` \(`event_id`\)/u);
  assert.match(outbox, /KEY `idx_world_outbox_dispatch` \(`state`, `available_at`, `id`\)/u);
  assert.match(outbox, /KEY `idx_world_outbox_lock` \(`locked_until`, `id`\)/u);
  assert.match(outbox, /`attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0/u);
  assert.match(outbox, /`state` IN \('pending', 'publishing', 'published', 'dead'\)/u);
  assert.match(outbox, /CHECK \(JSON_VALID\(`payload_json`\)\)/u);

  assert.match(repository, /database:transaction\(/u);
  assert.match(repository, /INSERT INTO `synex_world_outbox`/u);
  assert.match(repository, /INSERT IGNORE INTO `synex_world_state`/u);
  assert.match(repository, /INSERT IGNORE INTO `synex_world_door_states`/u);
  const referencedTables = [...repository.matchAll(
    /(?:FROM|INTO|UPDATE) `([a-z0-9_]+)`/gu,
  )].map((match) => match[1] ?? '');
  assert.ok(referencedTables.length >= 6);
  for (const table of referencedTables) {
    assert.ok([
      'synex_world_state', 'synex_world_door_states', 'synex_world_outbox',
    ].includes(table), `cross-domain SQL reference: ${table}`);
  }
  assert.match(adapter, /options\.dataPort/u);
  assert.match(adapter, /dataPort\.transaction/u);
  assert.match(adapter, /dataPort\.maintenance/u);
  assert.doesNotMatch(adapter, /(?:exports\.oxmysql|MySQL\.|require\(['"]mysql)/u);
});
