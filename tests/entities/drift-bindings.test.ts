import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const serverRoot = path.join(process.cwd(), 'resources', 'synex_entities', 'server');

test('bounded drift reads include exactly the active binding projection', async () => {
  const repository = await readFile(path.join(serverRoot, 'repository.lua'), 'utf8');
  const driftQueries = repository.slice(
    repository.indexOf('local SELECT_PERSISTENT_FOR_DRIFT'),
    repository.indexOf('function repository.insertPersistent'),
  );
  assert.equal((driftQueries.match(/LEFT JOIN synex_entity_bindings b/gu) ?? []).length, 2);
  assert.equal((driftQueries.match(/b\.released_at IS NULL/gu) ?? []).length, 2);
  assert.equal((driftQueries.match(/b\.binding_namespace, b\.binding_ref/gu) ?? []).length, 2);
  assert.match(driftQueries, /ORDER BY e\.entity_id[\s\S]*LIMIT \?/u);
  assert.match(driftQueries, /entity_id IN \(\]\][\s\S]*table\.concat\(placeholders/u);
});

test('drift detection counts missing, unexpected and different runtime bindings', async () => {
  const service = await readFile(path.join(serverRoot, 'service.lua'), 'utf8');
  assert.match(service, /local wrongBindings = 0/u);
  assert.match(service, /storedHasBinding ~= runtimeHasBinding/u);
  assert.match(service, /persisted\.binding_namespace ~= record\.binding\.namespace/u);
  assert.match(service, /persisted\.binding_ref ~= record\.binding\.ref/u);
  assert.match(service, /wrongBindings = wrongBindings \+ 1/u);
  assert.match(service, /wrongBindings = wrongBindings,/u);
  assert.match(service, /previousDrift\.wrongBindings ~= wrongBindings/u);
});
