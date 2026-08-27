import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { accountsRoot } from './helpers.js';

interface Schema {
  type?: string;
  const?: unknown;
  enum?: string[];
  minimum?: number;
  maximum?: number;
  minLength?: number;
  maxLength?: number;
  pattern?: string;
  minItems?: number;
  maxItems?: number;
  additionalProperties?: boolean;
  properties?: Record<string, Schema>;
  items?: Schema;
  oneOf?: Schema[];
  required?: string[];
}

interface Contract {
  name: string;
  version: string;
  kind: string;
  provider: string;
  network: string;
  capability?: string;
  input: Schema;
  output: Schema;
  errors: string[];
  idempotent?: boolean;
}

interface Catalog {
  schema: number;
  domain: string;
  contracts: Contract[];
}

const legacyContractCount = 19;
const safeInteger = Number.MAX_SAFE_INTEGER;

async function catalog(): Promise<Catalog> {
  return JSON.parse(await readFile(
    path.join(accountsRoot, 'accounts.contracts.json'),
    'utf8',
  )) as Catalog;
}

function walkSchema(
  schema: Schema,
  pathName: string,
  visit: (candidate: Schema, currentPath: string) => void,
): void {
  visit(schema, pathName);
  for (const [key, child] of Object.entries(schema.properties ?? {})) {
    walkSchema(child, `${pathName}.${key}`, visit);
  }
  if (schema.items) walkSchema(schema.items, `${pathName}[]`, visit);
  for (const [index, child] of (schema.oneOf ?? []).entries()) {
    walkSchema(child, `${pathName}.oneOf[${index}]`, visit);
  }
}

test('the canonical Accounts surface is unique, server-only, capability-gated, and closed', async () => {
  const source = await catalog();
  assert.equal(source.schema, 1);
  assert.equal(source.domain, 'synex.accounts');
  assert.equal(source.contracts.length, 59);
  assert.equal(new Set(source.contracts.map((contract) => contract.name)).size, 59);

  for (const contract of source.contracts) {
    assert.match(contract.name, /^synex\.accounts\.[a-z0-9_.]+$/u);
    assert.match(contract.version, /^[12]\.0\.0$/u, contract.name);
    assert.equal(contract.kind, 'rpc', contract.name);
    assert.equal(contract.provider, 'synex_accounts', contract.name);
    assert.equal(contract.network, 'none', contract.name);
    assert.match(contract.capability ?? '', /^synex\.accounts\.[a-z0-9_.]+$/u, contract.name);
    assert.equal(contract.input.additionalProperties, false, `${contract.name} input`);
  }

  for (const contract of source.contracts.slice(legacyContractCount)) {
    assert.equal(contract.output.additionalProperties, false, `${contract.name} output`);
  }
  for (const name of [
    'synex.accounts.transfer_v2',
    'synex.accounts.mint_v2',
    'synex.accounts.burn_v2',
  ]) {
    assert.equal(source.contracts.find((contract) => contract.name === name)?.version, '2.0.0');
  }
});

test('every canonical mutation is idempotent and exposes conflict and in-progress errors', async () => {
  const source = await catalog();
  for (const contract of source.contracts.slice(legacyContractCount)) {
    const mutation = contract.input.required?.includes('idempotency_key') === true;
    if (!mutation) {
      assert.notEqual(contract.idempotent, true, contract.name);
      continue;
    }
    assert.equal(contract.idempotent, true, contract.name);
    assert.ok(contract.errors.includes('IDEMPOTENCY_CONFLICT'), contract.name);
    assert.ok(contract.errors.includes('OPERATION_IN_PROGRESS'), contract.name);
    const key = contract.input.properties?.idempotency_key;
    assert.equal(key?.type, 'string', contract.name);
    assert.equal(key?.minLength, 36, contract.name);
    assert.equal(key?.maxLength, 36, contract.name);
    assert.equal(
      key?.pattern,
      '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      contract.name,
    );
  }
});

test('transfer_v2 exposes optional safe sequence guards for atomic compare-and-adjust', async () => {
  const source = await catalog();
  const transfer = source.contracts.find(
    (contract) => contract.name === 'synex.accounts.transfer_v2',
  );
  assert.ok(transfer);
  assert.equal(transfer.version, '2.0.0');
  assert.ok(transfer.errors.includes('WRITE_CONFLICT'));
  for (const field of [
    'expected_source_sequence',
    'expected_destination_sequence',
  ]) {
    assert.equal(transfer.input.required?.includes(field), false, field);
    assert.deepEqual(transfer.input.properties?.[field], {
      type: 'integer',
      minimum: 0,
      maximum: safeInteger,
    });
  }
});

test('canonical numeric fields stay within the JavaScript-safe integer range', async () => {
  const source = await catalog();
  let checked = 0;
  for (const contract of source.contracts.slice(legacyContractCount)) {
    for (const [side, schema] of [['input', contract.input], ['output', contract.output]] as const) {
      walkSchema(schema, `${contract.name}.${side}`, (candidate, currentPath) => {
        if (candidate.type !== 'integer') return;
        checked += 1;
        assert.equal(Number.isSafeInteger(candidate.minimum), true, `${currentPath} minimum`);
        assert.equal(Number.isSafeInteger(candidate.maximum), true, `${currentPath} maximum`);
        assert.ok((candidate.minimum ?? -Infinity) >= -safeInteger, currentPath);
        assert.ok((candidate.maximum ?? Infinity) <= safeInteger, currentPath);
      });
    }
  }
  assert.ok(checked > 100);
});

test('multi-leg postings are bounded signed entries and integrity aggregates are decimal strings', async () => {
  const source = await catalog();
  const byName = new Map(source.contracts.map((contract) => [contract.name, contract]));
  const post = byName.get('synex.accounts.post');
  assert.ok(post);
  const postings = post.input.properties?.postings;
  assert.equal(postings?.type, 'array');
  assert.equal(postings?.minItems, 2);
  assert.equal(postings?.maxItems, 16);
  assert.equal(postings?.items?.additionalProperties, false);
  assert.deepEqual(postings?.items?.required, ['account_id', 'amount_minor']);
  const amount = postings?.items?.properties?.amount_minor;
  assert.deepEqual(amount?.oneOf, [
    { type: 'integer', minimum: -safeInteger, maximum: -1 },
    { type: 'integer', minimum: 1, maximum: safeInteger },
  ]);

  const integrity = byName.get('synex.accounts.integrity.get');
  assert.ok(integrity);
  for (const property of [
    'transaction_count',
    'entry_count',
    'account_count',
    'total_entry_sum_minor',
    'minted_minor',
    'burned_minor',
    'net_supply_minor',
    'total_booked_minor',
    'active_held_minor',
    'transaction_sum_violation_count',
    'snapshot_drift_count',
    'finding_count',
  ]) {
    const propertySchema: Schema | undefined = integrity.output.properties?.[property];
    assert.equal(propertySchema?.type, 'string', property);
  }
});

test('privileged financial operations have distinct capabilities and authoritative actor input', async () => {
  const source = await catalog();
  const byName = new Map(source.contracts.map((contract) => [contract.name, contract]));
  const expected = new Map([
    ['synex.accounts.post', 'synex.accounts.post'],
    ['synex.accounts.mint_v2', 'synex.accounts.mint'],
    ['synex.accounts.burn_v2', 'synex.accounts.burn'],
    ['synex.accounts.transaction.refund', 'synex.accounts.refund'],
    ['synex.accounts.integrity.reconcile', 'synex.accounts.integrity.run'],
    ['synex.accounts.outbox.retry', 'synex.accounts.outbox.retry'],
    ['synex.accounts.access.grant', 'synex.accounts.access.manage'],
    ['synex.accounts.restriction.create', 'synex.accounts.configure'],
  ]);
  for (const [name, capability] of expected) {
    const contract = byName.get(name);
    assert.ok(contract, name);
    assert.equal(contract.capability, capability, name);
  }

  for (const name of [
    'synex.accounts.post',
    'synex.accounts.mint_v2',
    'synex.accounts.burn_v2',
    'synex.accounts.transaction.refund',
    'synex.accounts.hold.create',
  ]) {
    const required = byName.get(name)?.input.required ?? [];
    assert.ok(required.includes('actor_kind'), name);
    assert.ok(required.includes('actor_ref'), name);
  }
});

test('access explanation and closed-account mutation errors match the runtime preflight', async () => {
  const source = await catalog();
  const byName = new Map(source.contracts.map((contract) => [contract.name, contract]));
  const explain = byName.get('synex.accounts.access.explain');
  assert.ok(explain);
  assert.deepEqual(explain.input.properties?.direction?.enum, ['incoming', 'outgoing']);
  assert.equal(explain.input.properties?.amount_minor?.minimum, 1);
  assert.equal(explain.input.properties?.amount_minor?.maximum, safeInteger);
  for (const operation of [
    'balance.read', 'history.read', 'deposit', 'withdraw', 'transfer', 'post',
    'mint', 'burn', 'reversal', 'refund', 'hold.create', 'hold.capture',
    'hold.release', 'access.read', 'access.manage', 'settings.manage', 'close',
  ]) {
    assert.ok(explain.input.properties?.operation?.enum?.includes(operation), operation);
  }
  for (const name of [
    'synex.accounts.create_access_role',
    'synex.accounts.grant_access',
    'synex.accounts.revoke_access',
    'synex.accounts.access.role.create',
    'synex.accounts.access.grant',
    'synex.accounts.access.revoke',
    'synex.accounts.policy.set',
    'synex.accounts.restriction.create',
    'synex.accounts.restriction.revoke',
  ]) {
    assert.ok(byName.get(name)?.errors.includes('ACCOUNT_CLOSED'), name);
  }
  assert.ok(byName.get('synex.accounts.close')?.errors.includes('ACCOUNT_LIFECYCLE_BLOCKED'));
});
