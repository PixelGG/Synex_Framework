import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('entity contracts remain server-only and capability-gated', async () => {
  const collection = JSON.parse(
    await source('resources/synex_entities/contracts/entities.contracts.json'),
  ) as {
    contracts: Array<{ capability?: string | null; name: string; network: string }>;
  };

  assert.ok(collection.contracts.length > 0);
  for (const contract of collection.contracts) {
    assert.equal(contract.network, 'none', `${contract.name} must not be client-callable`);
    assert.match(contract.capability ?? '', /^synex\.entities\./);
  }
});

test('entity persistence owns one table and never stores runtime handles or network IDs', async () => {
  const migration = await source('resources/synex_entities/migrations/001_entities.sql');
  assert.match(migration, /CREATE TABLE IF NOT EXISTS `synex_entities`/);
  assert.doesNotMatch(migration, /`(?:handle|net_id)`/i);
  assert.match(migration, /PRIMARY KEY \(`entity_id`\)/);
  assert.match(migration, /UNIQUE KEY `uq_synex_entities_persistent_key`/);
});

test('entity runtime modules stay cohesive and every executable file is manifest-listed', async () => {
  const serverDirectory = path.join(root, 'resources', 'synex_entities', 'server');
  const serverFiles = (await readdir(serverDirectory))
    .filter((name) => name.endsWith('.lua'))
    .sort();
  const manifest = await source('resources/synex_entities/fxmanifest.lua');
  const modules = await Promise.all(
    serverFiles.map(async (name) => ({
      name,
      text: await source(`resources/synex_entities/server/${name}`),
    })),
  );

  for (const module of modules) {
    assert.ok(
      manifest.includes(`'server/${module.name}'`),
      `${module.name} must be explicitly listed in fxmanifest.lua`,
    );
    assert.ok(
      module.text.split(/\r?\n/).length <= 700,
      `${module.name} exceeds the cohesive module ceiling`,
    );
  }

  const composition = modules.find((module) => module.name === 'server.lua');
  assert.ok(composition);
  assert.ok(composition.text.split(/\r?\n/).length <= 250);
  assert.doesNotMatch(
    modules.map((module) => module.text).join('\n'),
    /\b(?:load|loadstring|dofile|require)\s*\(/,
  );
});

test('runtime facade binds every declared entity contract without public API drift', async () => {
  const collection = JSON.parse(
    await source('resources/synex_entities/contracts/entities.contracts.json'),
  ) as { contracts: Array<{ name: string }> };
  const facade = await source('resources/synex_entities/server/service.lua');
  const bound = [...facade.matchAll(/\['(synex\.entities\.[^']+)'\]\s*=/g)]
    .map((match) => match[1])
    .sort();
  const declared = collection.contracts.map((contract) => contract.name).sort();

  assert.deepEqual(bound, declared);
});

test('durable entity writes retain optimistic versions and reconcile before rehydration', async () => {
  const [repository, service] = await Promise.all([
    source('resources/synex_entities/server/repository.lua'),
    source('resources/synex_entities/server/service.lua'),
  ]);

  assert.match(repository, /WHERE entity_id = \? AND version = \?/);
  assert.match(repository, /status = 'deleting'[\s\S]*version = version \+ 1/);
  assert.match(repository, /status = 'orphaned'[\s\S]*version = version \+ 1/);
  assert.ok(
    service.indexOf('repository.reconcileDeleting()')
      < service.indexOf('repository.listForRehydrate('),
  );
});

test('closed control NUI is empty, transparent, and non-interactive', async () => {
  const [manifest, html, css, script] = await Promise.all([
    source('resources/synex_control/fxmanifest.lua'),
    source('resources/synex_control/web/index.html'),
    source('resources/synex_control/web/styles.css'),
    source('resources/synex_control/web/app.js'),
  ]);

  assert.match(manifest, /nui_callback_strict_mode 'true'/);
  assert.match(html, /<div id="root"><\/div>/);
  assert.match(html, /Content-Security-Policy/);
  assert.match(css, /html,\s*body,\s*#root\s*\{[\s\S]*background:\s*transparent !important;[\s\S]*pointer-events:\s*none;/);
  assert.match(script, /root\.replaceChildren\(\)/);
  assert.match(script, /delete document\.body\.dataset\.open/);
  assert.match(script, /messageOrigins\.has\(event\.origin\)/);
  assert.doesNotMatch(script, /innerHTML/);
});

test('control plane exposes no mutating NUI callback', async () => {
  const client = await source('resources/synex_control/client/client.lua');
  const callbacks = [...client.matchAll(/RegisterNUICallback\('([^']+)'/g)].map((match) => match[1]);
  assert.deepEqual(callbacks.sort(), ['close', 'refresh', 'search']);
});

test('control diagnostic search capability is both declared and granted', async () => {
  const [descriptor, policy] = await Promise.all([
    source('resources/synex_control/synex.resource.json'),
    source('core/synex_core/config/capabilities.json'),
  ]);
  const control = JSON.parse(descriptor) as {
    capabilities: { request: string[] };
  };
  const capabilities = JSON.parse(policy) as {
    resources: { synex_control: { allow: string[] } };
  };

  assert.ok(control.capabilities.request.includes('synex.audit.summary'));
  assert.ok(capabilities.resources.synex_control.allow.includes('synex.audit.summary'));
});

test('entity drift and character retention are scheduled, audited, and domain-owned', async () => {
  const [runtime, service, repository, descriptor] = await Promise.all([
    source('resources/synex_entities/server/runtime.lua'),
    source('resources/synex_entities/server/service.lua'),
    source('resources/synex_entities/server/repository.lua'),
    source('resources/synex_entities/synex.resource.json'),
  ]);

  assert.match(runtime, /registerLifecycleParticipant/);
  assert.match(runtime, /Scheduler\.every/);
  assert.match(service, /entities\.drift_detected/);
  assert.match(service, /api\.Audit\.append/);
  assert.match(repository, /owner_type = 'system'/);
  assert.match(repository, /status = 'orphaned'/);
  assert.match(descriptor, /"synex\.audit\.append"/);
});

test('control plane has every read-only section with ACE, masking, and payload bounds', async () => {
  const [server, limits, client] = await Promise.all([
    source('resources/synex_control/server/server.lua'),
    source('resources/synex_control/shared/limits.lua'),
    source('resources/synex_control/client/client.lua'),
  ]);
  for (const section of [
    'overview', 'runtime', 'resources', 'dependencies', 'contracts', 'capabilities',
    'rpc', 'hooks', 'database', 'migrations', 'sessions', 'characters', 'groups',
    'accounts', 'ledger', 'entities', 'audit', 'tracing', 'performance', 'security',
    'compatibility',
  ]) {
    assert.match(server, new RegExp(`['"]${section}['"]`, 'u'));
  }
  assert.match(server, /IsPlayerAceAllowed/);
  assert.match(server, /maskIdentifier/);
  assert.match(server, /maximumSnapshotBytes/);
  assert.match(server, /validateSearch/);
  assert.match(limits, /maximumSnapshotBytes\s*=\s*32768/);
  assert.match(client, /source ~= 65535/);
  assert.doesNotMatch(client, /RegisterNUICallback\(['"](?:delete|write|mutate|update)/);
});
