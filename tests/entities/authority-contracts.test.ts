import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

type JsonSchema = {
  additionalProperties?: boolean;
  items?: JsonSchema;
  maxItems?: number;
  maxLength?: number;
  maximum?: number;
  oneOf?: JsonSchema[];
  properties?: Record<string, JsonSchema>;
  type?: string;
};

type Contract = {
  capability?: string | null;
  errors: string[];
  idempotent?: boolean;
  input: JsonSchema;
  name: string;
  network: string;
  output: JsonSchema;
  provider: string;
  rateLimit?: { capacity: number; refillPerSecond: number };
  stability: string;
  version: string;
};

const existingV1 = [
  'synex.entities.spawn',
  'synex.entities.get',
  'synex.entities.resolve_persistent',
  'synex.entities.delete',
  'synex.entities.bucket.create',
  'synex.entities.bucket.destroy',
  'synex.entities.bucket.move_entity',
  'synex.entities.bucket.move_player',
  'synex.entities.health',
];

const authorityCapabilities = new Map<string, string>([
  ['synex.entities.materialize', 'synex.entities.materialize'],
  ['synex.entities.dematerialize', 'synex.entities.dematerialize'],
  ['synex.entities.checkpoint', 'synex.entities.checkpoint'],
  ['synex.entities.binding.get', 'synex.entities.query'],
  ['synex.entities.owner.set', 'synex.entities.owner.change'],
  ['synex.entities.archetype.register', 'synex.entities.archetype.register'],
  ['synex.entities.component.schema.register', 'synex.entities.component.schema.register'],
  ['synex.entities.component.get', 'synex.entities.component.read'],
  ['synex.entities.component.set', 'synex.entities.component.write'],
  ['synex.entities.component.remove', 'synex.entities.component.write'],
  ['synex.entities.state.schema.register', 'synex.entities.state.schema.register'],
  ['synex.entities.state.get', 'synex.entities.state.read'],
  ['synex.entities.state.set', 'synex.entities.state.write'],
  ['synex.entities.tags.add', 'synex.entities.tags.write'],
  ['synex.entities.tags.remove', 'synex.entities.tags.write'],
  ['synex.entities.query.by_net_id', 'synex.entities.query'],
  ['synex.entities.query.by_owner', 'synex.entities.query'],
  ['synex.entities.query.by_resource', 'synex.entities.query'],
  ['synex.entities.query.by_binding', 'synex.entities.query'],
  ['synex.entities.query.by_bucket', 'synex.entities.query'],
  ['synex.entities.query.nearby', 'synex.entities.query'],
  ['synex.entities.bucket.get', 'synex.entities.bucket.read'],
  ['synex.entities.context.validate', 'synex.entities.context.validate'],
]);

async function contracts(): Promise<Contract[]> {
  const source = await readFile(
    path.join(root, 'resources/synex_entities/contracts/entities.contracts.json'),
    'utf8',
  );
  return (JSON.parse(source) as { contracts: Contract[] }).contracts;
}

function assertBoundedClosedSchema(schema: JsonSchema, location: string): void {
  if (schema.type === 'object') {
    assert.equal(schema.additionalProperties, false, `${location} must reject unknown keys`);
    for (const [name, property] of Object.entries(schema.properties ?? {})) {
      assertBoundedClosedSchema(property, `${location}.properties.${name}`);
    }
  }
  if (schema.type === 'array') {
    assert.ok(Number.isInteger(schema.maxItems) && (schema.maxItems ?? 0) <= 64,
      `${location} must have a bounded maxItems`);
    assert.ok(schema.items, `${location} must define bounded array items`);
    assertBoundedClosedSchema(schema.items!, `${location}.items`);
  }
  if (schema.type === 'string') {
    assert.ok(Number.isInteger(schema.maxLength) && (schema.maxLength ?? 0) <= 32768,
      `${location} must have a bounded maxLength`);
  }
  if (schema.type === 'integer' || schema.type === 'number') {
    assert.equal(typeof schema.maximum, 'number', `${location} must have a maximum`);
  }
  for (const [index, branch] of (schema.oneOf ?? []).entries()) {
    assertBoundedClosedSchema(branch, `${location}.oneOf.${index}`);
  }
}

test('authority contract slice preserves the nine existing v1 definitions', async () => {
  const definitions = await contracts();
  assert.deepEqual(
    definitions
      .filter(({ name, version }) => version === '1.0.0' && existingV1.includes(name))
      .map(({ name, version }) => ({ name, version })),
    existingV1.map((name) => ({ name, version: '1.0.0' })),
  );
});

test('authority contract slice is complete, server-only, bounded, and capability-gated', async () => {
  const definitions = await contracts();
  const authority = definitions.filter(({ name }) => authorityCapabilities.has(name));

  assert.deepEqual(authority.map(({ name }) => name), [...authorityCapabilities.keys()]);
  for (const definition of authority) {
    assert.equal(definition.provider, 'synex_entities');
    assert.equal(definition.network, 'none', `${definition.name} must remain server-only`);
    assert.equal(definition.stability, 'experimental',
      `${definition.name} must not claim runtime acceptance before implementation`);
    assert.equal(definition.capability, authorityCapabilities.get(definition.name));
    assert.equal(definition.idempotent, true);
    assert.ok(definition.rateLimit);
    assert.ok((definition.rateLimit?.capacity ?? 0) <= 80);
    assert.ok((definition.rateLimit?.refillPerSecond ?? 0) <= 25);
    for (const code of ['FORBIDDEN', 'INVALID_ARGUMENT', 'RATE_LIMITED', 'UNAVAILABLE']) {
      assert.ok(definition.errors.includes(code), `${definition.name} lacks ${code}`);
    }
    assertBoundedClosedSchema(definition.input, `${definition.name}.input`);
    assertBoundedClosedSchema(definition.output, `${definition.name}.output`);
  }
});

test('authority mutations require safe reasons and optimistic or idempotent guards', async () => {
  const definitions = await contracts();
  const byName = new Map(definitions.map((definition) => [definition.name, definition]));
  const mutationNames = [
    'synex.entities.materialize', 'synex.entities.dematerialize',
    'synex.entities.checkpoint', 'synex.entities.owner.set',
    'synex.entities.component.set', 'synex.entities.component.remove',
    'synex.entities.state.set', 'synex.entities.tags.add', 'synex.entities.tags.remove',
  ];
  for (const name of mutationNames) {
    const definition = byName.get(name);
    assert.ok(definition);
    assert.ok(definition.input.properties?.reasonCode, `${name} lacks reasonCode`);
    assert.ok(definition.input.properties?.idempotencyKey, `${name} lacks idempotencyKey`);
  }
  assert.ok(byName.get('synex.entities.materialize')?.errors.includes('ENTITY_QUOTA_EXCEEDED'));
  assert.ok(byName.get('synex.entities.materialize')?.errors.includes('AUTHORITY_LEASE_CONFLICT'));
  assert.ok(byName.get('synex.entities.context.validate')?.errors.includes('BUCKET_MISMATCH'));
  assert.ok(byName.get('synex.entities.context.validate')?.errors.includes('DISTANCE_INVALID'));
});

test('public Entity mutation contracts declare their reachable domain failures', async () => {
  const definitions = await contracts();
  const byName = new Map(definitions.map((definition) => [definition.name, definition]));
  const expected = new Map<string, string[]>([
    ['synex.entities.spawn', [
      'AUTHORITY_LEASE_CONFLICT', 'BINDING_CONFLICT', 'CONCURRENT_MODIFICATION',
      'ENTITY_QUOTA_EXCEEDED', 'FOREIGN_RESOURCE_OWNER', 'HOOK_REJECTED',
      'SPAWN_FAILED', 'SPAWN_RATE_LIMITED', 'SPAWN_TIMEOUT',
    ]],
    ['synex.entities.delete', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION', 'DELETE_FAILED',
      'ENTITY_NOT_FOUND', 'HOOK_REJECTED',
    ]],
    ['synex.entities.materialize', [
      'AUTHORITY_LEASE_CONFLICT', 'COMPONENT_SCHEMA_MISMATCH',
      'COMPONENT_SCHEMA_NOT_FOUND', 'CONCURRENT_MODIFICATION', 'ENTITY_NOT_FOUND',
      'FOREIGN_RESOURCE_OWNER', 'HOOK_REJECTED', 'SPAWN_FAILED', 'SPAWN_TIMEOUT',
      'STATE_SCHEMA_MISMATCH', 'STATE_SCHEMA_NOT_FOUND',
    ]],
    ['synex.entities.dematerialize', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION', 'DELETE_FAILED',
      'ENTITY_NOT_MATERIALIZED', 'HOOK_REJECTED', 'INVALID_POSITION',
    ]],
    ['synex.entities.checkpoint', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION',
      'ENTITY_NOT_MATERIALIZED', 'HOOK_REJECTED', 'INVALID_POSITION',
    ]],
    ['synex.entities.owner.set', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION',
      'FOREIGN_RESOURCE_OWNER', 'HOOK_REJECTED', 'INVALID_LOGICAL_OWNER',
    ]],
    ['synex.entities.component.set', [
      'AUTHORITY_LEASE_CONFLICT', 'COMPONENT_SCHEMA_MISMATCH',
      'COMPONENT_SCHEMA_NOT_FOUND', 'CONCURRENT_MODIFICATION', 'ENTITY_NOT_FOUND',
    ]],
    ['synex.entities.component.remove', [
      'AUTHORITY_LEASE_CONFLICT', 'COMPONENT_SCHEMA_NOT_FOUND',
      'CONCURRENT_MODIFICATION', 'ENTITY_NOT_FOUND',
    ]],
    ['synex.entities.state.set', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION',
      'ENTITY_NOT_FOUND', 'STATE_SCHEMA_MISMATCH', 'STATE_SCHEMA_NOT_FOUND',
    ]],
    ['synex.entities.tags.add', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION', 'ENTITY_NOT_FOUND',
    ]],
    ['synex.entities.tags.remove', [
      'AUTHORITY_LEASE_CONFLICT', 'CONCURRENT_MODIFICATION', 'ENTITY_NOT_FOUND',
    ]],
  ]);
  for (const [name, codes] of expected) {
    const definition = byName.get(name);
    assert.ok(definition, `${name} is missing`);
    for (const code of codes) {
      assert.ok(definition.errors.includes(code), `${name} lacks reachable ${code}`);
    }
  }
});

test('operator and compatibility resources receive no new mutating entity grants', async () => {
  const source = await readFile(
    path.join(root, 'core/synex_core/config/capabilities.json'),
    'utf8',
  );
  const policy = JSON.parse(source) as {
    resources: Record<string, { allow: string[] }>;
  };
  const externalResources = [
    'synex_control', 'synex_bridge_qb', 'synex_bridge_qbx', 'synex_bridge_esx',
  ];
  for (const resource of externalResources) {
    const grants = policy.resources[resource]?.allow ?? [];
    assert.ok(!grants.includes('synex.entities.*'), `${resource} has a broad entity grant`);
    assert.ok(!grants.some((grant) => grant.startsWith('synex.entities.')
      && /(?:materialize|dematerialize|checkpoint|owner\.change|\.write|\.register)$/u.test(grant)),
      `${resource} has an authority mutation grant`);
  }
});
