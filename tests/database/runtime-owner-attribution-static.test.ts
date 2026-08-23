import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { extractDatabaseShape } from '../../tools/cli/src/database-doctor.js';

const root = process.cwd();

test('runtime owner attribution migration fences saga and generic outbox ownership', async () => {
  const sagaBase = await readFile(
    path.join(root, 'core', 'synex_core', 'migrations', '005_sagas.sql'),
    'utf8',
  );
  const outboxBase = await readFile(
    path.join(root, 'core', 'synex_core', 'migrations', '003_reliability.sql'),
    'utf8',
  );
  const migration = await readFile(
    path.join(root, 'core', 'synex_core', 'migrations', '014_runtime_owner_attribution.sql'),
    'utf8',
  );
  const manifest = JSON.parse(await readFile(
    path.join(root, 'core', 'synex_core', 'synex.resource.json'),
    'utf8',
  )) as { migrations: Array<{ id: string; path: string; transactional: boolean }> };

  const shape = extractDatabaseShape(`${outboxBase}\n${sagaBase}\n${migration}`);
  assert.ok(shape.synex_sagas?.columns.includes('owner_resource'));
  assert.ok(shape.synex_sagas?.indexes.includes('uq_sagas_owner_type_correlation'));
  assert.equal(shape.synex_sagas?.indexes.includes('uq_sagas_type_correlation'), false);
  assert.ok(shape.synex_outbox?.columns.includes('producer_resource'));
  assert.ok(shape.synex_outbox?.columns.includes('last_error_code'));
  assert.ok(shape.synex_outbox?.columns.includes('payload_compacted_at'));
  assert.ok(shape.synex_outbox?.indexes.includes('idx_outbox_terminal_compaction'));
  assert.deepEqual(manifest.migrations.find(
    (entry) => entry.id === '014_runtime_owner_attribution',
  ), {
    id: '014_runtime_owner_attribution',
    path: 'migrations/014_runtime_owner_attribution.sql',
    transactional: false,
  });
  assert.match(migration, /information_schema`.`COLUMNS[\s\S]*owner_resource/u);
  assert.match(migration, /information_schema`.`COLUMNS[\s\S]*producer_resource/u);
  assert.match(migration, /DROP INDEX `uq_sagas_type_correlation`/u);
  assert.match(migration, /ADD UNIQUE KEY `uq_sagas_owner_type_correlation`/u);
  assert.ok(
    migration.indexOf('ADD UNIQUE KEY `uq_sagas_owner_type_correlation`')
      < migration.indexOf('DROP INDEX `uq_sagas_type_correlation`'),
    'the owner-scoped unique key must exist before the legacy key is removed',
  );
  assert.match(migration, /SIGNAL SQLSTATE '45000'[\s\S]*uniqueness verification failed/u);
});

test('generic outbox code persists and dispatches the original producer without a Core fallback', async () => {
  const reliability = await readFile(
    path.join(root, 'core', 'synex_core', 'server', 'reliability.lua'),
    'utf8',
  );
  const lifecycle = await readFile(
    path.join(root, 'core', 'synex_core', 'server', 'bootstrap_lifecycle.lua'),
    'utf8',
  );
  assert.match(reliability, /`event_id`, `producer_resource`/u);
  assert.match(reliability, /producerResource = row\.producer_resource/u);
  assert.match(lifecycle, /type\(event\.producerResource\) ~= 'string'/u);
  assert.match(lifecycle, /event\.producerResource, producerEpoch, event\.eventType/u);
  assert.match(lifecycle, /core\.idempotency\.compact_expired/u);
  assert.match(lifecycle, /core\.outbox\.compact_terminal/u);
  assert.doesNotMatch(
    lifecycle,
    /publishOutbox\(\s*coreResource,\s*coreEpoch,\s*event\.eventType/u,
  );
});
