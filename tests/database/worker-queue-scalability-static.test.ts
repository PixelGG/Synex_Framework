import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('migration 021 installs and exactly verifies every worker queue index', async () => {
  const migration = await source(
    'core/synex_core/migrations/021_worker_queue_scalability.sql',
  );
  assert.match(
    migration,
    /ADD COLUMN `response_compaction_at` DATETIME\(6\) NULL AFTER `completed_at`/u,
  );
  assert.match(
    migration,
    /`COLUMN_NAME` = 'response_compaction_at'[\s\S]*?LOWER\(`DATA_TYPE`\) = 'datetime'[\s\S]*?`DATETIME_PRECISION` = 6[\s\S]*?`IS_NULLABLE` = 'YES'[\s\S]*?`COLUMN_DEFAULT` IS NULL[\s\S]*?COALESCE\(`EXTRA`, ''\) = ''/u,
  );
  assert.match(
    migration,
    /SET `response_compaction_at` = COALESCE\(`completed_at`, `expires_at`\)[\s\S]*?WHERE `state` = 'completed' AND `response_json` IS NULL[\s\S]*?AND `response_compaction_at` IS NULL/u,
  );

  const expected = new Map<string, { table: string; columns: string[] }>([
    ['idx_idempotency_response_compaction', {
      table: 'synex_idempotency_keys',
      columns: ['state', 'response_compaction_at', 'expires_at', 'namespace', 'idempotency_key'],
    }],
    ['idx_sagas_state_updated', {
      table: 'synex_sagas', columns: ['state', 'updated_at', 'id'],
    }],
    ['idx_outbox_compact_published', {
      table: 'synex_outbox', columns: ['state', 'payload_compacted_at', 'published_at', 'id'],
    }],
    ['idx_outbox_compact_dead', {
      table: 'synex_outbox', columns: ['state', 'payload_compacted_at', 'available_at', 'id'],
    }],
  ]);
  for (const [indexName, definition] of expected) {
    const escapedColumns = definition.columns
      .map((column) => `\x60${column}\x60`)
      .join(',\\s*');
    assert.match(
      migration,
      new RegExp(
        `ALTER TABLE \\x60${definition.table}\\x60[\\s\\S]*?ADD KEY \\x60${indexName}\\x60\\s*\\(${escapedColumns}\\)`,
        'u',
      ),
    );
    assert.match(
      migration,
      new RegExp(
        `INDEX_NAME\\x60 = '${indexName}'[\\s\\S]*?\\) <> ${definition.columns.length}`,
        'u',
      ),
    );
    for (const [offset, column] of definition.columns.entries()) {
      assert.match(
        migration,
        new RegExp(
          `INDEX_NAME\\x60 = '${indexName}'[\\s\\S]*?SEQ_IN_INDEX\\x60 = ${offset + 1} AND \\x60COLUMN_NAME\\x60 = '${column}'`,
          'u',
        ),
      );
    }
  }
  assert.equal((migration.match(/UPPER\(`INDEX_TYPE`\) <> 'BTREE'/gu) ?? []).length, 4);
  assert.equal((migration.match(/`SUB_PART` IS NOT NULL/gu) ?? []).length, 4);
  assert.equal((migration.match(/COALESCE\(`COLLATION`, ''\) <> 'A'/gu) ?? []).length, 4);
  assert.equal((migration.match(/SIGNAL SQLSTATE '45000'/gu) ?? []).length, 5);
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
  assert.equal((migration.match(/CALL `synex_migrate_021_worker_queue_scalability`\(\)/gu) ?? []).length, 1);
});

test('saga recovery uses bounded state cycles, exact keyset ranges, and Lua selector filtering', async () => {
  const reliability = await source('core/synex_core/server/reliability.lua');
  const candidatePath = reliability.slice(
    reliability.indexOf('function sagas:candidates'),
    reliability.indexOf('function sagas:load'),
  );
  assert.ok(candidatePath.length > 0);
  assert.match(candidatePath, /sagaCandidateScanMaximum/u);
  assert.match(candidatePath, /FORCE INDEX \(`idx_sagas_state_updated`\)/u);
  assert.match(
    candidatePath,
    /ORDER BY `updated_at` DESC, `id` DESC LIMIT 1/u,
  );
  assert.match(
    candidatePath,
    /`updated_at` > \?\s*OR \(`updated_at` = \? AND `id` > \?\)/u,
  );
  assert.match(
    candidatePath,
    /`updated_at` < \?\s*OR \(`updated_at` = \? AND `id` <= \?\)/u,
  );
  assert.match(candidatePath, /ORDER BY `updated_at` ASC, `id` ASC LIMIT \?/u);
  assert.match(candidatePath, /selectorLookup\[selector\.ownerResource/u);
  assert.doesNotMatch(candidatePath, /`owner_resource` = \?/u);
  assert.doesNotMatch(candidatePath, /`saga_type` = \?/u);
  assert.doesNotMatch(candidatePath, /`state` IN \('pending'/u);
  assert.match(candidatePath, /boundedRowCount\(rows, sagaCandidateScanMaximum\) == nil/u);
  assert.match(candidatePath, /lastTraversed = row/u);
  assert.match(candidatePath, /cycle\.cursor = \{\s*updatedAt = lastTraversed\.updated_at/u);
  assert.match(candidatePath, /cycle\.highWatermark = nil/u);
  assert.match(candidatePath, /sagaCandidateTurn = \(sagaCandidateTurn % #sagaCandidateStates\) \+ 1/u);
});

test('terminal outbox compaction uses two fair exact range updates under one budget', async () => {
  const reliability = await source('core/synex_core/server/reliability.lua');
  const compactPath = reliability.slice(
    reliability.indexOf('function outbox:compactTerminal'),
    reliability.indexOf('local sagas = {}'),
  );
  assert.ok(compactPath.length > 0);
  assert.equal((compactPath.match(/UPDATE `synex_outbox`/gu) ?? []).length, 2);
  assert.match(compactPath, /FORCE INDEX \(`idx_outbox_compact_published`\)/u);
  assert.match(compactPath, /FORCE INDEX \(`idx_outbox_compact_dead`\)/u);
  assert.match(
    compactPath,
    /WHERE `state` = 'published' AND `payload_compacted_at` IS NULL[\s\S]*?ORDER BY `payload_compacted_at` ASC, `published_at` ASC, `id` ASC[\s\S]*?LIMIT \?/u,
  );
  assert.match(
    compactPath,
    /WHERE `state` = 'dead' AND `payload_compacted_at` IS NULL[\s\S]*?ORDER BY `payload_compacted_at` ASC, `available_at` ASC, `id` ASC[\s\S]*?LIMIT \?/u,
  );
  assert.doesNotMatch(compactPath, /COALESCE\(`published_at`/u);
  assert.doesNotMatch(compactPath, /\(`state` = 'published'[\s\S]*?\bOR\b[\s\S]*?`state` = 'dead'/u);
  assert.match(compactPath, /outboxCompactionTurn = outboxCompactionTurn == 1 and 2 or 1/u);
  assert.match(compactPath, /local remaining = maximum - report\.compacted/u);
  assert.match(compactPath, /count > remaining/u);
  assert.match(compactPath, /report\.compacted = report\.compacted \+ count/u);
  assert.doesNotMatch(compactPath, /`last_error_code`\s*=/u);
});

test('idempotency response compaction reads only its explicit eligibility queue', async () => {
  const reliability = await source('core/synex_core/server/reliability.lua');
  const compactPath = reliability.slice(
    reliability.indexOf('function idempotency:compactExpired'),
    reliability.indexOf('local function validEventTopic'),
  );
  assert.ok(compactPath.length > 0);
  assert.match(compactPath, /FORCE INDEX \(`idx_idempotency_response_compaction`\)/u);
  assert.match(
    compactPath,
    /SET `response_json` = NULL, `response_compaction_at` = CURRENT_TIMESTAMP\(6\)/u,
  );
  assert.match(
    compactPath,
    /WHERE `state` = 'completed' AND `response_compaction_at` IS NULL[\s\S]*?AND `expires_at` < CURRENT_TIMESTAMP\(6\)/u,
  );
  assert.match(
    compactPath,
    /ORDER BY `response_compaction_at` ASC, `expires_at` ASC,\s*`namespace` ASC, `idempotency_key` ASC\s*LIMIT \?/u,
  );
  assert.doesNotMatch(compactPath, /`response_json` IS NOT NULL/u);
  assert.match(compactPath, /count > maximum[\s\S]*?math\.type\(count\) ~= 'integer'/u);
  assert.match(
    reliability,
    /SET `state` = 'completed', `response_json` = \?, `completed_at` = CURRENT_TIMESTAMP\(6\),[\s\S]*?`response_compaction_at` = NULL/u,
  );
});

test('both saga writers enforce the readable history ceiling before inserting', async () => {
  const reliability = await source('core/synex_core/server/reliability.lua');
  for (const [start, end] of [
    ['function sagas:record', 'function sagas:candidates'],
    ['function sagas:appendRuntimeEvent', 'function sagas:snapshot'],
  ] as const) {
    const writer = reliability.slice(reliability.indexOf(start), reliability.indexOf(end));
    const guardAt = writer.indexOf('currentStep >= 2048');
    const errorAt = writer.indexOf("foundation.error('SAGA_HISTORY_LIMIT'");
    const insertAt = writer.indexOf('INSERT INTO `synex_saga_steps`');
    assert.ok(guardAt >= 0 && errorAt > guardAt && insertAt > errorAt, start);
  }
});
