import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { runNotifyLua } from './helpers.js';
import { validateRepository } from '../../tools/cli/src/cli.js';

const root = process.cwd();
const notifyRoot = path.join(root, 'resources', 'synex_notify');

test('synex_notify manifest is valid, Core-only at startup, and has no separate NUI or persistence', async () => {
  const [report, manifest, descriptor] = await Promise.all([
    validateRepository(root, notifyRoot),
    readFile(path.join(notifyRoot, 'fxmanifest.lua'), 'utf8'),
    readFile(path.join(notifyRoot, 'synex.resource.json'), 'utf8').then((value) => JSON.parse(value) as {
      dependencies: {
        required: Array<{ name: string }>;
        optional: Array<{ name: string }>;
      };
      migrations: unknown[];
      dataOwnership: { tables: string[]; characterDelete: string };
      stateSnapshot: { supported: boolean };
      controlProvider: { namespace: string; operations: string[]; views: Array<{ id: string }> };
    }),
  ]);
  assert.deepEqual(
    report.diagnostics.filter((diagnostic) => diagnostic.level === 'error'),
    [],
  );
  assert.match(manifest, /dependency 'synex_core'/u);
  assert.doesNotMatch(manifest, /dependency '(?:synex_ui|synex_bridge)'/u);
  assert.doesNotMatch(manifest, /ui_page|server_only/u);
  assert.match(manifest, /synex_manifest 'synex\.resource\.json'/u);
  assert.match(manifest, /synex_contracts 'contracts\/notify\.contracts\.json'/u);
  assert.ok(manifest.indexOf("'shared/limits.lua'") < manifest.indexOf("'shared/validation.lua'"));
  assert.ok(manifest.indexOf("'server/foundation.lua'") < manifest.indexOf("'server/runtime.lua'"));
  assert.deepEqual(descriptor.dependencies.required.map(({ name }) => name), ['synex_core']);
  assert.deepEqual(
    descriptor.dependencies.optional.map(({ name }) => name).sort(),
    ['synex_bridge', 'synex_ui'],
  );
  assert.deepEqual(descriptor.migrations, []);
  assert.deepEqual(descriptor.dataOwnership, { tables: [], characterDelete: 'none' });
  assert.equal(descriptor.stateSnapshot.supported, false);
  assert.equal(descriptor.controlProvider.namespace, 'notify');
  assert.deepEqual(descriptor.controlProvider.operations, [
    'summary', 'health', 'list', 'metrics', 'findings', 'simulate',
  ]);
  assert.deepEqual(
    descriptor.controlProvider.views.map(({ id }) => id),
    [
      'overview', 'health', 'owners', 'budgets', 'rate_limits', 'activity',
      'queue', 'deduplication', 'grouping', 'suppression', 'progress', 'actions',
      'performance', 'findings', 'policy',
    ],
  );
});

test('notify contracts expose three server mutations and three ACTIVE-session endpoints', async () => {
  const bundle = JSON.parse(await readFile(
    path.join(notifyRoot, 'contracts', 'notify.contracts.json'),
    'utf8',
  )) as {
    schema: number;
    domain: string;
    contracts: Array<{
      name: string;
      version: string;
      network: string;
      stability: string;
      capability?: string;
      sessionStates?: string[];
      errors: string[];
      idempotent?: boolean;
      rateLimit?: { capacity: number; refillPerSecond: number };
      input: { type: string; additionalProperties: boolean; properties: Record<string, unknown> };
    }>;
  };
  assert.equal(bundle.schema, 1);
  assert.equal(bundle.domain, 'synex.notify');
  assert.equal(bundle.contracts.length, 6);
  assert.deepEqual(bundle.contracts.map(({ name }) => name).sort(), [
    'synex.notify.action.invoke',
    'synex.notify.command.pull',
    'synex.notify.dismiss',
    'synex.notify.metrics.report',
    'synex.notify.send',
    'synex.notify.update',
  ]);
  for (const contract of bundle.contracts) {
    assert.equal(contract.version, '1.0.0');
    assert.equal(contract.stability,
      contract.name === 'synex.notify.command.pull'
        || contract.name === 'synex.notify.metrics.report'
        ? 'internal' : 'experimental');
    assert.equal(contract.input.type, 'object');
    assert.equal(contract.input.additionalProperties, false);
  }
  const serverOnly = bundle.contracts.filter(({ network }) => network === 'none');
  assert.equal(serverOnly.length, 3);
  assert.deepEqual(
    serverOnly.map(({ capability }) => capability).sort(),
    ['synex.notify.send', 'synex.notify.update', 'synex.notify.update'],
  );
  const action = bundle.contracts.find(({ name }) => name === 'synex.notify.action.invoke');
  assert.ok(action);
  assert.equal(action.network, 'client-to-server');
  assert.deepEqual(action.sessionStates, ['ACTIVE']);
  assert.deepEqual(Object.keys(action.input.properties).sort(), [
    'notificationId', 'revision', 'token',
  ]);
  const pull = bundle.contracts.find(({ name }) => name === 'synex.notify.command.pull');
  assert.ok(pull);
  assert.equal(pull.network, 'client-to-server');
  assert.deepEqual(pull.sessionStates, ['ACTIVE']);
  assert.deepEqual(Object.keys(pull.input.properties), ['commandId']);
  assert.equal(pull.capability, undefined);
  assert.equal(pull.idempotent, false);
  assert.deepEqual(pull.rateLimit, { capacity: 32, refillPerSecond: 16 });
  assert.deepEqual(pull.errors, [
    'NOTIFY_INVALID_REQUEST', 'NOTIFY_COMMAND_NOT_FOUND', 'NOTIFY_TARGET_STALE',
    'NOTIFY_UNAVAILABLE',
  ]);
  const metrics = bundle.contracts.find(({ name }) => name === 'synex.notify.metrics.report');
  assert.ok(metrics);
  assert.equal(metrics.network, 'client-to-server');
  assert.equal(metrics.stability, 'internal');
  assert.deepEqual(metrics.sessionStates, ['ACTIVE']);
  assert.equal(metrics.capability, undefined);
  assert.equal(metrics.idempotent, true);
  assert.deepEqual(metrics.rateLimit, { capacity: 2, refillPerSecond: 0.2 });
  assert.deepEqual(Object.keys(metrics.input.properties).sort(), [
    'clientEpoch', 'counters', 'gauges', 'sequence',
  ]);
  const send = bundle.contracts.find(({ name }) => name === 'synex.notify.send');
  assert.ok(send);
  const payload = send.input.properties.payload as {
    properties: { iconKey: { enum: string[] } };
  };
  const runtimeIconKeys = await runNotifyLua<string>(`
    local keys = {}
    for key in pairs(SynexNotifyLimits.iconKeys) do keys[#keys + 1] = key end
    table.sort(keys)
    return table.concat(keys, ',')
  `);
  assert.equal([...payload.properties.iconKey.enum].sort().join(','), runtimeIconKeys);
});

test('operator policy grants only internal Notify infrastructure and CLI routes use the service boundary', async () => {
  const [descriptor, policy, commands] = await Promise.all([
    readFile(path.join(notifyRoot, 'synex.resource.json'), 'utf8').then((value) => JSON.parse(value) as {
      capabilities: { request: string[] };
    }),
    readFile(path.join(root, 'core', 'synex_core', 'config', 'capabilities.json'), 'utf8')
      .then((value) => JSON.parse(value) as {
        resources: Record<string, { allow: string[]; deny: string[] }>;
      }),
    readFile(path.join(root, 'core', 'synex_core', 'server', 'commands.lua'), 'utf8'),
  ]);
  const expected = [
    'synex.audit.append',
    'synex.capabilities.delegate',
    'synex.compat.adapter.register',
    'synex.control.provider.register',
    'synex.identity.read',
    'synex.metrics.write',
  ];
  assert.deepEqual([...descriptor.capabilities.request].sort(), expected);
  assert.deepEqual([...policy.resources.synex_notify!.allow].sort(), expected);
  assert.deepEqual(policy.resources.synex_notify!.deny, []);
  assert.equal(expected.some((capability) => capability.startsWith('synex.notify.')), false);
  assert.match(commands, /serviceSummary\('synex\.notify', 'get_control_summary', 'synex_notify'\)/u);
  assert.match(commands, /serviceSummary\('synex\.notify', 'doctor', 'synex_notify'\)/u);
  assert.match(commands, /usage: synex notify <status\|doctor>/u);
  assert.match(commands,
    /usage: synex doctor \[groups\|accounts\|entities\|notify\|interact\|security\]/u);
});

test('compatibility integration is explicitly partial, bounded to send, and never becomes a framework façade', async () => {
  const [runtime, registry] = await Promise.all([
    readFile(path.join(notifyRoot, 'server', 'runtime.lua'), 'utf8'),
    readFile(path.join(notifyRoot, 'server', 'registry.lua'), 'utf8'),
  ]);
  assert.match(runtime, /domain = 'notifications', status = 'PARTIAL', operations = \{ 'send' \}/u);
  assert.match(runtime, /context\.consumer/u);
  assert.match(runtime, /Validation\.exactObject\(payload, \{ target = true, notification = true \}\)/u);
  assert.match(runtime, /registry\.send\(context\.consumer, epoch, payload\.target/u);
  assert.doesNotMatch(runtime, /QBCore|QBX|qbx_core|ESX|es_extended/u);
  assert.doesNotMatch(runtime, /broadcast\s*=\s*function/u);
  assert.doesNotMatch(runtime, /gauge\('queue_depth',\s*0\)/u);
  assert.match(runtime, /gauge\('pending_commands', snapshot\.pendingCommands\)/u);
  assert.doesNotMatch(registry, /increment\('displayed'\)/u);
  assert.match(registry, /increment\('wakeDispatched'\)/u);
  assert.match(registry, /maximumBroadcastTargets/u);
  assert.match(registry, /target\.source/u);
  assert.doesNotMatch(registry, /triggerClient\(\s*-1/u);
});
