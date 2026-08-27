import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

type Descriptor = {
  capabilities: { request: string[] };
  controlProvider?: {
    namespace: string;
    operations: string[];
    schemaVersion: number;
    views: Array<{ id: string; operation: string; presentation: string }>;
  };
  dataOwnership: { tables: string[] };
  dependencies: {
    development: Array<{ name: string }>;
    optional: Array<{ name: string }>;
    required: Array<{ name: string }>;
  };
  migrations: unknown[];
  name: string;
};

const providerResources = ['synex_accounts', 'synex_groups', 'synex_entities'] as const;
const safeOperations = new Set([
  'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings', 'simulate',
]);
const safePresentations = new Set([
  'metrics', 'key-value', 'table', 'detail', 'timeline', 'graph', 'findings',
]);

test('official providers publish unique bounded metadata and depend on Core, never Control', async () => {
  const namespaces = new Set<string>();
  for (const resource of providerResources) {
    const [descriptorSource, manifest, provider] = await Promise.all([
      source(`resources/${resource}/synex.resource.json`),
      source(`resources/${resource}/fxmanifest.lua`),
      source(`resources/${resource}/server/control_provider.lua`),
    ]);
    const descriptor = JSON.parse(descriptorSource) as Descriptor;
    const metadata = descriptor.controlProvider;
    assert.ok(metadata, `${resource} must declare its Control provider`);
    assert.equal(metadata.schemaVersion, 1);
    assert.equal(namespaces.has(metadata.namespace), false, metadata.namespace);
    namespaces.add(metadata.namespace);
    assert.ok(descriptor.capabilities.request.includes('synex.control.provider.register'));
    assert.ok(descriptor.dependencies.required.some((entry) => entry.name === 'synex_core'));
    const dependencies = [
      ...descriptor.dependencies.required,
      ...descriptor.dependencies.optional,
      ...descriptor.dependencies.development,
    ];
    assert.ok(!dependencies.some((entry) => entry.name === 'synex_control'));
    assert.match(manifest, /'server\/control_provider\.lua'/u);
    assert.match(provider, /ControlProviders\.register/u);

    const operations = new Set(metadata.operations);
    assert.equal(operations.size, metadata.operations.length);
    for (const operation of operations) assert.ok(safeOperations.has(operation), operation);
    for (const view of metadata.views) {
      assert.ok(operations.has(view.operation), `${metadata.namespace}.${view.id}`);
      assert.ok(safePresentations.has(view.presentation), view.presentation);
    }
  }
  assert.deepEqual([...namespaces].sort(), ['accounts', 'entities', 'groups']);
});

test('Control descriptor is read-only, migration-free, and depends only on Core', async () => {
  const descriptor = JSON.parse(
    await source('resources/synex_control/synex.resource.json'),
  ) as Descriptor;
  assert.deepEqual(descriptor.capabilities.request.sort(), [
    'synex.control.provider.read', 'synex.control.provider.register',
  ]);
  assert.deepEqual(descriptor.dataOwnership.tables, []);
  assert.deepEqual(descriptor.migrations, []);
  assert.deepEqual(descriptor.dependencies.required.map((entry) => entry.name), ['synex_core']);
  assert.deepEqual(descriptor.dependencies.optional, []);
  assert.deepEqual(descriptor.dependencies.development, []);
});

test('repository certification validates provider uniqueness, registration capability, and dependency direction', async () => {
  const [schema, runtimeValidator, repositoryValidator, manifest] = await Promise.all([
    source('schemas/resource.schema.json'),
    source('core/synex_core/server/resource_manifest.lua'),
    source('tools/cli/src/validation.ts'),
    source('resources/synex_control/fxmanifest.lua'),
  ]);

  assert.match(schema, /"controlProvider"/u);
  assert.match(schema, /"metrics",\s*"key-value",\s*"table",\s*"detail",\s*"timeline",\s*"graph",\s*"findings"/u);
  assert.match(runtimeValidator, /controlProviderOperations/u);
  assert.match(runtimeValidator, /controlProviderPresentations/u);
  assert.match(repositoryValidator, /control-provider-namespace-unique/u);
  assert.match(repositoryValidator, /control-provider-registration-capability/u);
  assert.match(repositoryValidator, /control-provider-dependency-direction/u);
  assert.match(repositoryValidator, /control-provider-health-contract/u);
  assert.ok(
    manifest.indexOf("'server/sanitizer.lua'")
      < manifest.indexOf("'server/request_protocol.lua'"),
  );
  assert.ok(
    manifest.indexOf("'server/request_protocol.lua'")
      < manifest.indexOf("'server/server.lua'"),
  );
});
