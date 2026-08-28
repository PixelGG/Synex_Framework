import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { walkFiles } from '../../tools/cli/src/filesystem.js';
import { loadMigrations, migrationDirectories, repositoryRoot } from './harness.js';

test('database harness covers every manifest-declared migration directory', async () => {
  const manifestFiles = await walkFiles(
    repositoryRoot,
    (file) => path.basename(file) === 'synex.resource.json',
    { skipTopLevelTests: true },
  );
  assert.ok(manifestFiles.length > 0, 'No Synex resource manifests were discovered.');

  const declaredDirectories = new Set<string>();
  const declaredPaths = new Set<string>();
  for (const manifestFile of manifestFiles) {
    const relativeManifest = path.relative(repositoryRoot, manifestFile).split(path.sep).join('/');
    const manifest = JSON.parse(await readFile(manifestFile, 'utf8')) as { migrations?: unknown };
    assert.ok(Array.isArray(manifest.migrations), `${relativeManifest} must declare a migrations array.`);

    for (const [index, migration] of manifest.migrations.entries()) {
      assert.ok(
        migration !== null && typeof migration === 'object' && !Array.isArray(migration),
        `${relativeManifest} migration ${index} must be an object.`,
      );
      const migrationPath = (migration as Record<string, unknown>).path;
      assert.ok(
        typeof migrationPath === 'string' && migrationPath.length > 0,
        `${relativeManifest} migration ${index} must declare a path.`,
      );

      const absoluteMigration = path.resolve(path.dirname(manifestFile), migrationPath);
      const relativeDirectory = path.relative(repositoryRoot, path.dirname(absoluteMigration));
      assert.equal(
        relativeDirectory === '..'
          || relativeDirectory.startsWith(`..${path.sep}`)
          || path.isAbsolute(relativeDirectory),
        false,
        `${relativeManifest} migration ${index} escapes the repository.`,
      );
      declaredDirectories.add(relativeDirectory.split(path.sep).join('/'));
      declaredPaths.add(path.relative(repositoryRoot, absoluteMigration).split(path.sep).join('/'));
    }
  }

  const harnessDirectories = migrationDirectories.map((directory) => directory.replaceAll('\\', '/'));
  assert.equal(
    new Set(harnessDirectories).size,
    harnessDirectories.length,
    'Database harness migration directories must be unique.',
  );
  assert.deepEqual(
    [...harnessDirectories].sort(),
    [...declaredDirectories].sort(),
    'Database harness migration directories must exactly match resource manifests.',
  );
  const loadedPaths = (await loadMigrations()).map((migration) => migration.relativePath);
  assert.equal(new Set(loadedPaths).size, loadedPaths.length, 'Loaded migration paths must be unique.');
  assert.deepEqual(
    [...loadedPaths].sort(),
    [...declaredPaths].sort(),
    'Database harness migration files must exactly match resource manifests.',
  );
});
