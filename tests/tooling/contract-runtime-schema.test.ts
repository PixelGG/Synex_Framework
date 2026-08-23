import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadContractSources } from '../../tools/cli/src/contracts.js';

function collection(input: Record<string, unknown>): Record<string, unknown> {
  return {
    schema: 1,
    domain: 'synex.fixture',
    contracts: [{
      name: 'synex.fixture.echo',
      version: '1.0.0',
      kind: 'rpc',
      provider: 'synex_fixture',
      stability: 'experimental',
      network: 'none',
      input,
      output: { type: 'object', additionalProperties: false },
      errors: [],
    }],
  };
}

test('contract discovery rejects regex and schema assertions outside the Core runtime subset', async (context) => {
  const fixture = await mkdtemp(path.join(tmpdir(), 'synex-contract-subset-'));
  context.after(async () => rm(fixture, { recursive: true, force: true }));
  await mkdir(path.join(fixture, 'contracts'), { recursive: true });
  const oversizedDefault = Object.fromEntries(
    Array.from({ length: 2050 }, (_, index) => [`key_${index}`, index]),
  );
  await writeFile(
    path.join(fixture, 'contracts', 'unsupported.contracts.json'),
    `${JSON.stringify(collection({
      type: 'object',
      properties: {
        value: { type: 'string', pattern: '^(foo|bar)$' },
        unanchored: { type: 'string', pattern: 'aaaaaaaaaaaaaaaaa' },
        loops: { type: 'string', pattern: '^a*a*a*a*a*a*a*a*a*$' },
        nested: { allOf: [{ type: 'string', minLength: 1 }] },
        extras: { type: 'object', additionalProperties: { type: 'string' } },
        unboundedUnique: { type: 'array', uniqueItems: true, items: { type: 'string' } },
        oversized: { default: oversizedDefault },
      },
    }), null, 2)}\n`,
    'utf8',
  );

  const loaded = await loadContractSources(process.cwd(), undefined, path.join(fixture, 'contracts'));
  assert.equal(loaded.sources.length, 0);
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-pattern-subset' && entry.message.includes('properties.value.pattern')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-pattern-subset' && entry.message.includes('properties.unanchored.pattern')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-pattern-subset' && entry.message.includes('properties.loops.pattern')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-runtime-schema-subset' && entry.message.includes('properties.nested.allOf')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-runtime-schema-subset'
      && entry.message.includes('properties.extras.additionalProperties')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-runtime-schema-subset'
      && entry.message.includes('properties.unboundedUnique.uniqueItems')
  ));
  assert.ok(loaded.diagnostics.some((entry) =>
    entry.rule === 'contract-runtime-schema-subset' && entry.message.includes('too many entries')
  ));
});

test('all repository contract schemas stay within the executable Core subset', async () => {
  const loaded = await loadContractSources(process.cwd());
  assert.deepEqual(loaded.diagnostics, []);
  assert.ok(loaded.sources.length > 0);
});
