import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const core = path.join(root, 'core', 'synex_core');
const modules = [
  'server/identity_common.lua',
  'server/identity_repository.lua',
  'server/identity_characters.lua',
  'server/identity_connections.lua',
  'server/identity.lua',
  'server/runtime_persistence.lua',
  'server/runtime_configuration.lua',
  'server/retention.lua',
  'server/saga_runtime.lua',
  'server/commands.lua',
  'server/bootstrap_discovery.lua',
  'server/bootstrap_api.lua',
  'server/bootstrap_diagnostics.lua',
  'server/bootstrap_lifecycle.lua',
  'server/bootstrap.lua',
] as const;

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(core, relativePath), 'utf8');
}

test('identity and bootstrap use cohesive fixed manifest-listed modules', async () => {
  const manifest = await source('fxmanifest.lua');
  for (const relativePath of modules) {
    const contents = await source(relativePath);
    const lines = contents.split(/\r?\n/u).length;
    assert.ok(lines <= 700, `${relativePath} exceeds 700 lines`);
    assert.ok(manifest.includes(`'${relativePath}'`), `${relativePath} is not explicitly manifest-listed`);
    assert.doesNotMatch(
      contents,
      /(?<![A-Za-z0-9_.:])(?:load|loadstring|dofile|require)\s*\(/u,
      `${relativePath} dynamically loads executable code`,
    );
  }
  assert.ok((await source('server/identity.lua')).split(/\r?\n/u).length <= 100);
  assert.ok((await source('server/bootstrap.lua')).split(/\r?\n/u).length <= 250);
});

test('GetAPI facade categories and kernel exports preserve their public surface', async () => {
  const api = await source('server/bootstrap_api.lua');
  const lifecycle = await source('server/bootstrap_lifecycle.lua');
  assert.match(
    api,
    /getRetentionPolicy\s*=\s*function\(\)[\s\S]*?'synex\.runtime\.read'[\s\S]*?foundation\.copy/u,
  );
  const categories = [...api.matchAll(/facade\.([A-Za-z]+)\s*=\s*\{/gu)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(categories, [
    'Access',
    'Audit',
    'Capabilities',
    'Characters',
    'Connections',
    'Diagnostics',
    'Events',
    'Hooks',
    'Idempotency',
    'Ids',
    'Metrics',
    'Outbox',
    'Permissions',
    'Players',
    'RPC',
    'Runtime',
    'Sagas',
    'Scheduler',
    'Services',
    'States',
  ]);
  const exports = [...lifecycle.matchAll(/platform\.export\('([^']+)'/gu)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(exports, ['GetAPI', 'GetRuntimeStatus', 'Invoke']);
  const contracts = [...api.matchAll(/\['(synex\.[^']+)'\]\s*=\s*function/gu)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(contracts, [
    'synex.identity.characters.create',
    'synex.identity.characters.delete',
    'synex.identity.characters.list',
    'synex.identity.characters.select',
    'synex.identity.session.by_source',
    'synex.runtime.status',
  ]);
});

test('client RPC responses are accepted only from the server sentinel source', async () => {
  const client = await source('client/client.lua');
  const handler = client.match(/RegisterNetEvent\(protocol\.events\.response,[\s\S]*?\nend\)/u)?.[0] ?? '';
  assert.ok(handler.length > 0);
  assert.match(handler, /if source ~= 65535 then return end/u);
  assert.ok(
    handler.indexOf('source ~= 65535') < handler.indexOf('pending[response.requestId]'),
    'response authenticity must be checked before pending state is accessed',
  );
});

test('boot validates UTC and fail-closes named recurring worker registration', async () => {
  const lifecycle = await source('server/bootstrap_lifecycle.lua');
  const discovery = await source('server/bootstrap_discovery.lua');
  const connections = await source('server/identity_connections.lua');
  const utcValidation = lifecycle.indexOf('persistence.database:validateUtcSession()');
  const migrationBootstrap = lifecycle.indexOf('persistence.migrations:bootstrap()');
  assert.ok(utcValidation >= 0 && utcValidation < migrationBootstrap);
  assert.match(
    lifecycle,
    /local function scheduleEvery[\s\S]*?if not token then error\(scheduleError\.message\) end/u,
  );
  assert.match(
    lifecycle,
    /scheduleEvery\(5000,[\s\S]*?refreshDependencyHealth\(\)[\s\S]*?'core\.runtime\.dependency_health'/u,
  );
  assert.match(
    lifecycle,
    /reconcileUnloads\(10\)[\s\S]*?'core\.characters\.unload_reconciliation'/u,
  );
  const enforceCritical = lifecycle.indexOf('enforceCriticalResources = true');
  const finalTransition = lifecycle.indexOf("postBootCritical > 0 and 'DEGRADED' or 'READY'");
  assert.ok(enforceCritical >= 0 && finalTransition > enforceCritical);
  assert.match(
    discovery,
    /not active and includeInactiveCritical == true and manifest\.critical == true/u,
  );
  assert.match(connections, /if not lifecycle\.core:canAdmitPlayers\(\) then/u);
  assert.doesNotMatch(connections, /if not lifecycle\.core:isOperational\(\) then/u);
});

test('kernel persistence does not silently discard direct database calls', async () => {
  for (const relativePath of ['server/persistence.lua', 'server/reliability.lua']) {
    assert.doesNotMatch(
      await source(relativePath),
      /^\s*database:(?:query|scalar|insert|update)\s*\(/mu,
      `${relativePath} discards a database result`,
    );
  }
});
