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
      module.text.trimEnd().split(/\r?\n/).length <= 700,
      `${module.name} exceeds the cohesive module ceiling`,
    );
  }

  const composition = modules.find((module) => module.name === 'server.lua');
  assert.ok(composition);
  assert.ok(composition.text.trimEnd().split(/\r?\n/).length <= 250);
  assert.doesNotMatch(
    modules.map((module) => module.text).join('\n'),
    /\b(?:load|loadstring|dofile|require)\s*\(/,
  );
});

test('entity descriptor publishes every defined contract and the runtime facade does not drift', async () => {
  const [collectionSource, descriptorSource] = await Promise.all([
    source('resources/synex_entities/contracts/entities.contracts.json'),
    source('resources/synex_entities/synex.resource.json'),
  ]);
  const collection = JSON.parse(collectionSource) as { contracts: Array<{ name: string }> };
  const descriptor = JSON.parse(descriptorSource) as { contracts: { provide: string[] } };
  const facade = await source('resources/synex_entities/server/service.lua');
  const bound = [...facade.matchAll(/\['(synex\.entities\.[^']+)'\]\s*=/g)]
    .map((match) => match[1]!)
    .sort();
  const defined = [...new Set(collection.contracts.map((contract) => contract.name))].sort();
  const published = [...descriptor.contracts.provide].sort();

  assert.deepEqual(published, defined);
  for (const name of bound) assert.ok(published.includes(name), `${name} is not descriptor-published`);
  for (const name of [
    'synex.entities.bucket.create',
    'synex.entities.bucket.destroy',
    'synex.entities.bucket.move_entity',
    'synex.entities.bucket.move_player',
    'synex.entities.delete',
    'synex.entities.get',
    'synex.entities.health',
    'synex.entities.resolve_persistent',
    'synex.entities.spawn',
  ]) assert.ok(bound.includes(name), `${name} lost its stable v1 runtime binding`);
});

test('entity manifest and descriptor cover modules, schema ownership, Core ports, and policy surfaces', async () => {
  const [manifest, descriptorSource, capabilitySource] = await Promise.all([
    source('resources/synex_entities/fxmanifest.lua'),
    source('resources/synex_entities/synex.resource.json'),
    source('core/synex_core/config/capabilities.json'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    capabilities: { request: string[] };
    dataOwnership: { tables: string[] };
    events: { publish: string[]; subscribe: string[] };
    hooks: { register: string[]; run: string[] };
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
    services: { optional: string[]; provide: string[]; require: string[] };
  };
  const policy = JSON.parse(capabilitySource) as {
    resources: { synex_entities: { allow: string[]; deny: string[] } };
  };
  const migrationFiles = [
    '001_entities.sql',
    '002_entity_lifecycle_authority.sql',
    '003_entity_extensions.sql',
    '004_entity_cluster_recovery.sql',
  ];
  const ownedTables = new Set<string>();
  for (const name of migrationFiles) {
    assert.ok(manifest.includes(`'migrations/${name}'`), `${name} is absent from fxmanifest.lua`);
    const sql = await source(`resources/synex_entities/migrations/${name}`);
    for (const match of sql.matchAll(/CREATE TABLE IF NOT EXISTS `([^`]+)`/gu)) {
      ownedTables.add(match[1]!);
    }
  }
  assert.deepEqual(
    descriptor.migrations.map((entry) => entry.path),
    migrationFiles.map((name) => `migrations/${name}`),
  );
  assert.ok(descriptor.migrations.every((entry) => entry.transactional === false));
  assert.deepEqual([...descriptor.dataOwnership.tables].sort(), [...ownedTables].sort());

  const requiredCapabilities = [
    'synex.audit.append',
    'synex.capabilities.delegate',
    'synex.control.provider.register',
    'synex.database.maintenance',
    'synex.database.read',
    'synex.database.transaction',
    'synex.database.write',
    'synex.deletions.provider',
    'synex.groups.read',
    'synex.identity.read',
    'synex.metrics.write',
    'synex.runtime.read',
  ];
  assert.deepEqual([...descriptor.capabilities.request].sort(), requiredCapabilities.sort());
  const grants = policy.resources.synex_entities.allow;
  for (const capability of requiredCapabilities) {
    assert.ok(grants.includes(capability), `${capability} is requested but not policy-granted`);
  }
  assert.ok(policy.resources.synex_entities.deny.includes('synex.entities.delete_persistent'));

  assert.deepEqual(descriptor.services, {
    provide: ['synex.entities@1'],
    require: ['synex.runtime@1'],
    optional: ['synex.groups@1'],
  });
  assert.deepEqual(descriptor.events, {
    publish: [
      'synex.entities.created',
      'synex.entities.materialized',
      'synex.entities.dematerialized',
      'synex.entities.orphaned',
      'synex.entities.recovered',
      'synex.entities.owner.changed',
      'synex.entities.bucket.changed',
      'synex.entities.deleted',
    ],
    subscribe: [],
  });
  assert.deepEqual(descriptor.hooks, {
    register: [],
    run: [
      'synex.entities.before_entity_spawn',
      'synex.entities.before_entity_delete',
      'synex.entities.before_entity_checkpoint',
      'synex.entities.before_entity_owner_change',
      'synex.entities.before_entity_bucket_move',
      'synex.entities.before_entity_recovery',
    ],
  });
});

test('durable entity writes retain optimistic versions and reconcile before recovery', async () => {
  const [repository, lifecycle] = await Promise.all([
    source('resources/synex_entities/server/repository.lua'),
    source('resources/synex_entities/server/authority_lifecycle.lua'),
  ]);

  assert.match(repository, /WHERE entity_id = \? AND version = \?/);
  assert.match(repository, /status = 'deleting'[\s\S]*version = version \+ 1/);
  assert.match(repository, /status = 'orphaned'[\s\S]*version = version \+ 1/);
  assert.ok(
    lifecycle.indexOf('authorityRepository.reconcileBootAuthority(')
      < lifecycle.indexOf('authorityRepository.listRecoverable('),
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
  const callbacks = [...client.matchAll(/RegisterNuiCallback\('([^']+)'/g)].map((match) => match[1]);
  assert.deepEqual(callbacks.sort(), ['close', 'ready', 'reportError', 'request']);
  assert.doesNotMatch(client, /RegisterNuiCallback\(['"](?:create|delete|mutate|update|write)/u);
});

test('control provider registry capabilities are both declared and granted', async () => {
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

  assert.ok(control.capabilities.request.includes('synex.control.provider.read'));
  assert.ok(control.capabilities.request.includes('synex.control.provider.register'));
  assert.ok(capabilities.resources.synex_control.allow.includes('synex.control.provider.read'));
  assert.ok(capabilities.resources.synex_control.allow.includes('synex.control.provider.register'));
});

test('control consumes provider metadata instead of Entity domain contracts', async () => {
  const [controlSource, entitySource, server, provider, script] = await Promise.all([
    source('resources/synex_control/synex.resource.json'),
    source('resources/synex_entities/synex.resource.json'),
    source('resources/synex_control/server/server.lua'),
    source('resources/synex_entities/server/control_provider.lua'),
    source('resources/synex_control/web/app.js'),
  ]);
  const control = JSON.parse(controlSource) as {
    capabilities: { request: string[] };
    contracts: { consume: string[] };
  };
  const entities = JSON.parse(entitySource) as {
    controlProvider: { namespace: string; operations: string[]; views: Array<{ id: string }> };
  };

  assert.equal(entities.controlProvider.namespace, 'entities');
  assert.ok(entities.controlProvider.operations.includes('list'));
  assert.ok(entities.controlProvider.operations.includes('inspect'));
  assert.ok(entities.controlProvider.operations.includes('search'));
  assert.ok(entities.controlProvider.views.some((view) => view.id === 'entities'));
  assert.equal(control.contracts.consume.length, 0);
  assert.match(server, /ControlProviders/u);
  assert.match(provider, /ControlProviders\.register/u);
  assert.match(script, /snapshot\.providers/u);
  assert.doesNotMatch(script, /innerHTML/u);

  for (const mutation of [
    'synex.entities.spawn',
    'synex.entities.materialize',
    'synex.entities.dematerialize',
    'synex.entities.delete',
    'synex.entities.owner.set',
    'synex.entities.bucket.move_entity',
    'synex.entities.bucket.move_player',
  ]) {
    assert.ok(!server.includes(mutation), `control must not call ${mutation}`);
    assert.ok(!control.contracts.consume.includes(mutation), `control must not consume ${mutation}`);
  }
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

test('official Core API consumers accept only genuine Cfx-callable exports', async () => {
  const [accountsFoundation, accountsMain, accountsCoreBootstrap,
    groupsFoundation, groupsMain, groupsCoreBootstrap,
    entityFoundation, entityBuckets, entityOperations, entityRuntime, entityService,
    control] = await Promise.all([
    source('resources/synex_accounts/server/foundation.lua'),
    source('resources/synex_accounts/server/main.lua'),
    source('resources/synex_accounts/server/core_bootstrap.lua'),
    source('resources/synex_groups/server/foundation.lua'),
    source('resources/synex_groups/server/main.lua'),
    source('resources/synex_groups/server/core_bootstrap.lua'),
    source('resources/synex_entities/server/foundation.lua'),
    source('resources/synex_entities/server/bucket_service.lua'),
    source('resources/synex_entities/server/entity_service.lua'),
    source('resources/synex_entities/server/runtime.lua'),
    source('resources/synex_entities/server/service.lua'),
    source('resources/synex_control/server/server.lua'),
  ]);

  for (const helper of [accountsFoundation, groupsFoundation, entityFoundation]) {
    assert.match(helper, /valueType == 'function'/u);
    assert.match(helper, /valueType ~= 'table' and valueType ~= 'userdata'/u);
    assert.match(helper, /pcall\(debug\.getmetatable, value\)/u);
    assert.match(helper, /type\(rawget\(metatable, '__call'\)\) == 'function'/u);
    assert.doesNotMatch(helper, /__cfx_functionReference/u);
  }

  const accountsRuntime = `${accountsMain}\n${accountsCoreBootstrap}`;
  assert.match(accountsRuntime, /callable\(api\.Runtime, 'getRetentionPolicy'\)/u);
  assert.match(accountsRuntime, /callable\(api\.Ids, 'next'\)/u);
  assert.match(accountsRuntime, /callable\(api\.Events, 'publishOutbox'\)/u);
  assert.match(accountsRuntime, /callable\(api\.Scheduler, 'every'\)/u);
  const groupsRuntime = `${groupsMain}\n${groupsCoreBootstrap}`;
  assert.match(groupsRuntime, /Foundation\.isCallable\(api\.Ids\.next\)/u);
  assert.match(groupsRuntime, /Foundation\.isCallable\(api\.Events\.publishOutbox\)/u);
  assert.match(groupsRuntime, /Foundation\.isCallable\(api\.Scheduler\.every\)/u);
  assert.match(entityBuckets, /foundation\.isCallable\(api\.Ids\.next\)/u);
  assert.match(entityOperations, /foundation\.isCallable\(api\.Ids\.next\)/u);
  for (const method of [
    'api.Services.provide',
    'api.RPC.registerServer',
    'api.Characters.registerLifecycleParticipant',
    'api.Scheduler.every',
  ]) {
    assert.ok(entityRuntime.includes(`foundation.isCallable(${method})`));
  }
  assert.match(entityService, /foundation\.isCallable\(api\.Audit\.append\)/u);
  assert.match(control, /local function callable\(value\)/u);
  assert.match(control, /if not callable\(handler\)/u);
  assert.match(control, /pcall\(debug\.getmetatable, value\)/u);
  assert.match(control, /type\(rawget\(mt, '__call'\)\) == 'function'/u);
});

test('control plane has bounded routes, granular ACEs, and a server-only response channel', async () => {
  const [server, limits, client] = await Promise.all([
    source('resources/synex_control/server/server.lua'),
    source('resources/synex_control/shared/limits.lua'),
    source('resources/synex_control/client/client.lua'),
  ]);
  for (const operation of ['overview', 'providers', 'section', 'page', 'inspect', 'search']) {
    assert.ok(`${server}\n${client}`.includes(`${operation} = true`), operation);
  }
  for (const ace of [
    'synex.control.view', 'synex.control.audit', 'synex.control.security',
    'synex.control.financial', 'synex.control.identifiers',
  ]) assert.ok(server.includes(`'${ace}'`), ace);
  assert.match(server, /IsPlayerAceAllowed/u);
  assert.match(server, /SynexControlSanitizer\.encode/u);
  assert.match(limits, /maximumRequestBytes\s*=\s*4096/u);
  assert.match(limits, /maximumResponseBytes\s*=\s*32768/u);
  assert.equal((client.match(/source ~= 65535/gu) ?? []).length, 4);
  assert.match(client, /synex_control:invalidate/u);
  assert.doesNotMatch(client, /RegisterNuiCallback\(['"](?:delete|write|mutate|update)/u);
});
