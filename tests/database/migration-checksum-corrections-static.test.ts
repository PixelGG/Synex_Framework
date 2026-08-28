import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { MIGRATION_CHECKSUM_CORRECTIONS } from '../../tools/cli/src/migration-compatibility.js';

const root = process.cwd();
const corrections = [
  {
    identity: 'synex_core:021_worker_queue_scalability',
    migration: 'core/synex_core/migrations/021_worker_queue_scalability.sql',
    previous: '6d314f977f47fa39125c9597172e75fa05d80bfbd310aaf6be4c5584f6823b59',
    current: '5add0fed6935b83e7fd0905c188c1e534a6636d5d935fea1a28a145f7b533b7c',
  },
  {
    identity: 'synex_accounts:011_hold_lifecycle_v2',
    migration: 'resources/synex_accounts/migrations/011_hold_lifecycle_v2.sql',
    previous: '03fdb945f64e134f4e0e5c6dd8808702c497d2cb89d3f3cd6b162977e6d8c536',
    current: '8da0db6df52c57aa4ea2eebaba0524d6d9e3a537a2cd53e83bf8a9e0ead0ff53',
  },
  {
    identity: 'synex_accounts:015_financial_archive_v2',
    migration: 'resources/synex_accounts/migrations/015_financial_archive_v2.sql',
    previous: '05afc56dff22982f0e30cab204fd6e3215a9653bcd3275760b7e4a1a337972c2',
    current: '7c0be6f831823316fada3122edb36e63c49535f0e6088edcdbd26ef73bdb5d64',
  },
  {
    identity: 'synex_entities:002_entity_lifecycle_authority',
    migration: 'resources/synex_entities/migrations/002_entity_lifecycle_authority.sql',
    previous: 'cffdd0b9b456e2d32c40a399cfd46aebb1d606167873c5c518ec6bd463571c5e',
    current: '4bc9d239f42008fec43aa2e86e376cf0e9b5d97a7786ce0bb1642efe598c354f',
  },
] as const;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

test('registered migration checksum corrections match exact current LF-normalized files', async () => {
  const expected = Object.fromEntries(corrections.map(({ identity, previous, current }) => [
    identity,
    { previous, current },
  ]));
  assert.deepEqual(MIGRATION_CHECKSUM_CORRECTIONS, expected);

  const runtime = await readFile(path.join(root, 'core/synex_core/server/persistence.lua'), 'utf8');
  for (const correction of corrections) {
    const contents = await readFile(path.join(root, correction.migration), 'utf8');
    const digest = createHash('sha256')
      .update(contents.replace(/\r\n?/gu, '\n'))
      .digest('hex');
    assert.equal(digest, correction.current, correction.identity);
    assert.match(
      runtime,
      new RegExp(
        `\\['${escapeRegExp(correction.identity)}'\\]\\s*=\\s*\\{`
          + `[\\s\\S]*?previous\\s*=\\s*'${correction.previous}'`
          + `[\\s\\S]*?current\\s*=\\s*'${correction.current}'[\\s\\S]*?\\}`,
        'u',
      ),
      `${correction.identity} runtime correction pairing`,
    );
  }
});
