import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const core = path.join(root, 'core', 'synex_core');
const modules = [
  'server/identity_common.lua',
  'server/identity_session_fencing.lua',
  'server/identity_repository.lua',
  'server/identity_character_deletion_reconciliation.lua',
  'server/identity_character_unloads.lua',
  'server/identity_characters.lua',
  'server/identity_connection_replacement.lua',
  'server/identity_connection_claims.lua',
  'server/identity_connection_authority.lua',
  'server/identity_connection_ingress.lua',
  'server/identity_connection_terminals.lua',
  'server/identity_connection_join.lua',
  'server/identity_connection_connecting.lua',
  'server/identity_connection_heartbeat.lua',
  'server/identity_connection_maintenance.lua',
  'server/identity_connections.lua',
  'server/identity.lua',
  'server/runtime_persistence_instances.lua',
  'server/runtime_persistence_control.lua',
  'server/runtime_persistence_control_retention.lua',
  'server/runtime_persistence_rbac.lua',
  'server/runtime_persistence.lua',
  'server/runtime_configuration.lua',
  'server/runtime_gate.lua',
  'server/retention.lua',
  'server/saga_runtime.lua',
  'server/commands.lua',
  'server/bootstrap_discovery.lua',
  'server/bootstrap_api.lua',
  'server/bootstrap_diagnostics.lua',
  'server/bootstrap_restart.lua',
  'server/bootstrap_resource_events.lua',
  'server/runtime_database_health.lua',
  'server/bootstrap_lifecycle.lua',
  'server/bootstrap.lua',
] as const;

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(core, relativePath), 'utf8');
}

test('identity, runtime persistence, and bootstrap use cohesive fixed manifest-listed modules', async () => {
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
  let previousRuntimeOffset = -1;
  for (const relativePath of [
    'server/runtime_persistence_instances.lua',
    'server/runtime_persistence_control.lua',
    'server/runtime_persistence_control_retention.lua',
    'server/runtime_persistence_rbac.lua',
    'server/runtime_persistence.lua',
  ]) {
    const offset = manifest.indexOf(`'${relativePath}'`);
    assert.ok(offset > previousRuntimeOffset, `${relativePath} has an invalid manifest load order`);
    previousRuntimeOffset = offset;
  }
  assert.ok((await source('server/identity.lua')).split(/\r?\n/u).length <= 100);
  assert.ok((await source('server/bootstrap.lua')).split(/\r?\n/u).length <= 250);
});

test('GetAPI facade categories and kernel exports preserve their public surface', async () => {
  const api = await source('server/bootstrap_api.lua');
  const resourceEvents = await source('server/bootstrap_resource_events.lua');
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
  const exports = [...resourceEvents.matchAll(/platform\.export\('([^']+)'/gu)]
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
  const connecting = await source('server/identity_connection_connecting.lua');
  const utcValidation = lifecycle.indexOf('persistence.database:validateUtcSession()');
  const migrationBootstrap = lifecycle.indexOf('persistence.migrations:bootstrap()');
  assert.ok(utcValidation >= 0 && utcValidation < migrationBootstrap);
  assert.match(
    lifecycle,
    /if not manifests\[coreResource\] then[\s\S]*?'CORE_MANIFEST_UNAVAILABLE'/u,
  );
  const instanceRegistration = lifecycle.indexOf('persistence.instances:register(defaultConfig.instanceName)');
  const authorityCleanup = lifecycle.indexOf("persistence.instances:terminateLocalSessions('synex_core restarted')");
  const sourceGenerationFloor = lifecycle.indexOf('persistence.instances:sourceGenerationFloor()');
  const sourceGenerationSeed = lifecycle.indexOf('registries.players:seedSourceGeneration(sourceGenerationFloor)');
  const serviceRegistration = lifecycle.indexOf('registerCoreContracts()');
  assert.ok(instanceRegistration > migrationBootstrap && authorityCleanup > instanceRegistration);
  assert.ok(sourceGenerationFloor > authorityCleanup && sourceGenerationSeed > sourceGenerationFloor);
  assert.ok(serviceRegistration > sourceGenerationSeed);
  assert.match(
    lifecycle,
    /local function scheduleEvery[\s\S]*?if not token then raiseBootFailure\(scheduleError, 'SCHEDULER_REGISTRATION_FAILED'\) end/u,
  );
  assert.match(
    lifecycle,
    /scheduleDatabaseEvery\(5000,[\s\S]*?refreshDependencyHealth\(\)[\s\S]*?'core\.runtime\.dependency_health'/u,
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
  assert.match(connecting, /if not lifecycle\.core:canAdmitPlayers\(\) then/u);
  assert.doesNotMatch(connecting, /if not lifecycle\.core:isOperational\(\) then/u);
});

test('the core stop event is synchronous and durable cleanup belongs to explicit restart preparation', async () => {
  const resourceEvents = await source('server/bootstrap_resource_events.lua');
  const restart = await source('server/bootstrap_restart.lua');
  const stopStart = resourceEvents.indexOf("platform.addEventHandler('onResourceStop'");
  const nonCoreStart = resourceEvents.indexOf(
    '            local epoch = registries.owners:epoch(resource)',
    stopStart,
  );
  assert.ok(stopStart >= 0 && nonCoreStart > stopStart, 'the Core stop boundary must be discoverable');
  const coreStop = resourceEvents.slice(stopStart, nonCoreStart);
  assert.doesNotMatch(
    coreStop,
    /(?:platform\.(?:defer|wait)|drainQuiescedTerminals|persistence\.|releaseQuiescedLeases|lifecycle\.reload[:.]quiesce)/u,
    'the stopping resource cannot depend on a yielded or database-backed continuation',
  );
  assert.match(coreStop, /restartController:handleRawStop/u);
  const rawStart = restart.indexOf('function controller:handleRawStop()');
  const rawEnd = restart.indexOf('    return controller', rawStart);
  assert.ok(rawStart >= 0 && rawEnd > rawStart, 'the raw-stop controller must be discoverable');
  const rawStop = restart.slice(rawStart, rawEnd);
  assert.doesNotMatch(
    rawStop,
    /(?:platform\.(?:defer|wait)|drainQuiescedTerminals|persistence\.|releaseQuiescedLeases|lifecycle\.reload[:.]quiesce)/u,
  );
  assert.match(rawStop, /flushReadyQuiescedTerminals/u);
  assert.match(restart, /function controller:prepare\(\)[\s\S]*?drainQuiescedTerminals/u);
  assert.match(restart, /function controller:prepare\(\)[\s\S]*?terminateLocalSessions/u);
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
