import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

function canonicalSql(value: string): string {
  return value.replaceAll(/\s+/gu, ' ').trim().replace(/;$/u, '');
}

test('migration fence bootstrap and forward migration use the same owned schema', async () => {
  const persistence = await readFile(
    path.join(root, 'core', 'synex_core', 'server', 'persistence.lua'),
    'utf8',
  );
  const migration = await readFile(
    path.join(root, 'core', 'synex_core', 'migrations', '013_migration_fencing.sql'),
    'utf8',
  );
  const manifest = JSON.parse(await readFile(
    path.join(root, 'core', 'synex_core', 'synex.resource.json'),
    'utf8',
  )) as {
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
    dataOwnership: { tables: string[] };
  };
  const bootstrap = persistence.match(
    /\[\[(CREATE TABLE IF NOT EXISTS `synex_schema_migration_fences`[\s\S]*?)\]\],/u,
  )?.[1];
  assert.ok(bootstrap);
  assert.equal(canonicalSql(bootstrap), canonicalSql(migration));
  assert.deepEqual(manifest.migrations.find((entry) => entry.id === '013_migration_fencing'), {
    id: '013_migration_fencing',
    path: 'migrations/013_migration_fencing.sql',
    transactional: false,
  });
  assert.ok(manifest.dataOwnership.tables.includes('synex_schema_migration_fences'));
  assert.doesNotMatch(persistence, /\b(?:GET_LOCK|RELEASE_LOCK)\s*\(/iu);
  assert.match(persistence, /platform\.createThread\(function\(\)[\s\S]*manager:renewLease\(\)/u);
  assert.match(
    persistence,
    /FROM `synex_cluster_leases`[\s\S]*?FOR UPDATE[\s\S]*?FROM `synex_schema_migration_fences`[\s\S]*?FOR UPDATE/u,
  );
  assert.match(persistence, /MIGRATION_INDETERMINATE/u);
  assert.match(
    persistence,
    /FROM `synex_schema_migration_attempts`[\s\S]*ORDER BY `resource_name`, `migration_id` LIMIT \?/u,
  );
  assert.match(
    persistence,
    /FROM `synex_schema_migration_fences`[\s\S]*ORDER BY `resource_name`, `migration_id` LIMIT \?/u,
  );
  assert.match(
    persistence,
    /for index = 1, math\.min\(#fenceRows, recordMaximum\) do[\s\S]*effective\[entry\.key\] = entry/u,
  );
  assert.match(
    persistence,
    /recordsTruncated = #attemptRows > recordMaximum or #fenceRows > recordMaximum/u,
  );
  assert.doesNotMatch(
    persistence,
    /SET `owner_id` = \?, `fencing_token` = \?, `state` = 'applying'[\s\S]*`state` = 'failed'/u,
  );
});
