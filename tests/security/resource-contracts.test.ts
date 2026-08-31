import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const resourceRoot = path.join(root, 'resources', 'synex_security');

type Contract = {
  name: string;
  version: string;
  provider: string;
  capability?: string;
  network?: string;
  sessionStates?: string[];
  input: { required?: string[]; properties?: Record<string, unknown> };
  errors: string[];
};

type ResourceDescriptor = {
  name: string;
  capabilities: { request: string[] };
  contracts: { provide: string[]; consume: string[] };
  services: { provide: string[]; require: string[]; optional: string[] };
  events: { publish: string[]; subscribe: string[] };
  migrations: Array<{ id: string; path: string; transactional: boolean }>;
  dataOwnership: { tables: string[] };
  controlProvider: {
    operations: string[];
    views: Array<Record<string, unknown> & { operation: string }>;
  };
};

async function json<T>(relativePath: string): Promise<T> {
  return JSON.parse(await readFile(path.join(root, relativePath), 'utf8')) as T;
}

function quotedEntries(source: string, directive: string): string[] {
  const block = source.match(new RegExp(`${directive}\\s*\\{([\\s\\S]*?)\\}`, 'u'))?.[1] ?? '';
  return [...block.matchAll(/'([^']+)'/gu)].map((match) => match[1] as string);
}

test('Security descriptor, contract bundle, and fxmanifest expose one consistent bounded surface', async () => {
  const [descriptor, bundle, manifest, config] = await Promise.all([
    json<ResourceDescriptor>('resources/synex_security/synex.resource.json'),
    json<{ schema: number; domain: string; contracts: Contract[] }>(
      'resources/synex_security/contracts/security.contracts.json'),
    readFile(path.join(resourceRoot, 'fxmanifest.lua'), 'utf8'),
    json<{ detectors: Record<string, string> }>(
      'resources/synex_security/config/default.json'),
  ]);

  assert.equal(descriptor.name, 'synex_security');
  assert.equal(bundle.schema, 1);
  assert.equal(bundle.domain, 'synex.security');
  assert.deepEqual(
    [...descriptor.contracts.provide].sort(),
    bundle.contracts.map((contract) => contract.name).sort(),
  );
  assert.deepEqual(descriptor.contracts.consume, []);
  assert.deepEqual(descriptor.services.provide, ['synex.security@1']);
  assert.deepEqual(descriptor.services.require, ['synex.runtime@1']);
  assert.deepEqual(descriptor.services.optional, []);

  const clientContracts = bundle.contracts.filter(
    (contract) => contract.network === 'client-to-server',
  );
  assert.deepEqual(clientContracts.map((contract) => contract.name), [
    'synex.security.sentinel.report',
  ]);
  assert.deepEqual(clientContracts[0]?.sessionStates, ['ACTIVE']);
  for (const contract of bundle.contracts) {
    assert.equal(contract.provider, 'synex_security');
    assert.equal(contract.version, '1.0.0');
    if (contract.name !== 'synex.security.sentinel.report') {
      assert.equal(contract.network, 'none');
    }
  }

  const serverScripts = quotedEntries(manifest, 'server_scripts');
  const sharedScripts = quotedEntries(manifest, 'shared_scripts');
  const clientScripts = quotedEntries(manifest, 'client_scripts');
  const singleClientScript = manifest.match(/\bclient_script\s+'([^']+)'/u)?.[1];
  if (singleClientScript !== undefined) clientScripts.push(singleClientScript);
  assert.deepEqual(clientScripts, ['client/sentinel.lua']);
  assert.doesNotMatch(manifest, /\bui_page\b/u);
  assert.match(manifest, /dependencies\s*\{[\s\S]*'\/onesync'[\s\S]*'synex_core'/u);
  assert.match(manifest, /synex_manifest\s+'synex\.resource\.json'/u);
  assert.match(manifest, /synex_contracts\s+'contracts\/security\.contracts\.json'/u);

  for (const relativePath of [...sharedScripts, ...serverScripts, ...clientScripts]) {
    await access(path.join(resourceRoot, relativePath));
  }
  for (const migration of descriptor.migrations) {
    await access(path.join(resourceRoot, migration.path));
  }

  assert.deepEqual(Object.keys(config.detectors).sort(), [
    'combat_analytics',
    'domain_abuse',
    'entity_guard',
    'game_events',
    'movement',
    'player_integrity',
    'sentinel',
    'transport',
    'weapon_integrity',
  ]);
});

test('Security Control runtime metadata exactly matches its descriptor', async () => {
  const descriptor = await json<ResourceDescriptor>(
    'resources/synex_security/synex.resource.json');
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'resources/synex_security/shared/limits.lua',
      'resources/synex_security/shared/validation.lua',
      'resources/synex_security/server/foundation.lua',
      'resources/synex_security/server/control_provider.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const runtimeViews = await engine.doString(`
      return SynexSecurityControlProvider.create({ diagnostics = {} }).views
    `) as Array<Record<string, unknown>>;
    assert.deepEqual(runtimeViews, descriptor.controlProvider.views);
  } finally {
    engine.global.close();
  }
});

test('Security capabilities are least-privilege and enforcement is not granted to gameplay resources', async () => {
  const [descriptor, bundle, policy] = await Promise.all([
    json<ResourceDescriptor>('resources/synex_security/synex.resource.json'),
    json<{ contracts: Contract[] }>(
      'resources/synex_security/contracts/security.contracts.json'),
    json<{ resources: Record<string, { allow: string[]; deny: string[] }> }>(
      'core/synex_core/config/capabilities.json'),
  ]);
  const requested = new Set(descriptor.capabilities.request);
  const contractCapabilities = new Set(
    bundle.contracts.flatMap((contract) => contract.capability ? [contract.capability] : []),
  );
  for (const capability of contractCapabilities) {
    assert.equal(requested.has(capability), true, `${capability} is not declared by synex_security`);
  }
  assert.deepEqual([...contractCapabilities].sort(), [
    'synex.security.case.read',
    'synex.security.diagnostics.read',
    'synex.security.expectation.manage',
    'synex.security.signal.emit',
  ]);
  assert.equal(requested.has('synex.security.enforce'), false);

  const enforcementGrants = Object.entries(policy.resources)
    .filter(([, value]) => value.allow.includes('synex.security.enforce'))
    .map(([name]) => name);
  assert.deepEqual(enforcementGrants, []);
  const expectationGrants = Object.entries(policy.resources)
    .filter(([, value]) => value.allow.includes('synex.security.expectation.manage'))
    .map(([name]) => name)
    .sort();
  assert.deepEqual(expectationGrants, ['synex_security', 'synex_world']);
  for (const domain of ['synex_accounts', 'synex_entities', 'synex_interact']) {
    assert.equal(
      policy.resources[domain]?.allow.includes('synex.security.signal.emit'),
      true,
      `${domain} cannot report bounded abuse signals`,
    );
  }
  assert.equal(
    policy.resources.synex_world?.allow.includes('synex.security.signal.emit'),
    false,
  );
  assert.equal(policy.resources.synex_control?.allow.includes('synex.security.enforce'), false);
});

test('Security persistence owns cases only and delegates bans to Core Access', async () => {
  const [descriptor, migration, enforcement, server] = await Promise.all([
    json<ResourceDescriptor>('resources/synex_security/synex.resource.json'),
    readFile(path.join(resourceRoot, 'migrations', '001_security.sql'), 'utf8'),
    readFile(path.join(resourceRoot, 'server', 'enforcement.lua'), 'utf8'),
    readFile(path.join(resourceRoot, 'server', 'server.lua'), 'utf8'),
  ]);
  const createdTables = [...migration.matchAll(/CREATE TABLE IF NOT EXISTS\s+`([^`]+)`/gu)]
    .map((match) => match[1] as string)
    .sort();
  assert.deepEqual(createdTables, [...descriptor.dataOwnership.tables].sort());
  assert.equal(createdTables.some((name) => /ban|access/iu.test(name)), false);
  assert.match(enforcement, /local accessBan = Validation\.isCallable\(options\.accessBan\)/u);
  assert.match(enforcement, /pcall\(accessBan, request\)/u);
  assert.match(server, /accessBan\s*=\s*function\(request\)\s+return coreMethod\('Access',\s*'ban',\s*request\)\s+end/u);

  const mutatingControlOperations = new Set([
    'create', 'update', 'delete', 'apply', 'enforce', 'kick', 'ban', 'revoke',
  ]);
  assert.equal(
    descriptor.controlProvider.operations.some((operation) =>
      mutatingControlOperations.has(operation)),
    false,
  );
  assert.equal(
    descriptor.controlProvider.views.some((view) =>
      mutatingControlOperations.has(view.operation)),
    false,
  );
});

test('Generated runtime contracts preserve Security network, capability, and error boundaries', async () => {
  const [bundle, generated] = await Promise.all([
    json<{ contracts: Contract[] }>(
      'resources/synex_security/contracts/security.contracts.json'),
    json<{ contracts: Contract[] }>(
      'packages/contracts/generated/runtime/contracts.json'),
  ]);
  const generatedByName = new Map(
    generated.contracts.map((contract) => [contract.name, contract]),
  );
  for (const canonical of bundle.contracts) {
    const emitted = generatedByName.get(canonical.name);
    assert.ok(emitted, `${canonical.name} is missing from generated runtime contracts`);
    assert.equal(emitted.provider, canonical.provider);
    assert.equal(emitted.version, canonical.version);
    assert.equal(emitted.network, canonical.network);
    assert.equal(emitted.capability, canonical.capability);
    assert.deepEqual(emitted.errors, canonical.errors);
    assert.deepEqual(emitted.input.required, canonical.input.required);
  }
});
