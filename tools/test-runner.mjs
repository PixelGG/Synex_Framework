import { readdirSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const scope = process.argv[2];
const testRoot = path.resolve('.build', 'tests', scope ?? '');
const files = [];

function collect(directory) {
  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') {
      return;
    }
    throw error;
  }
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collect(absolute);
    } else if (entry.isFile() && entry.name.endsWith('.test.js')) {
      files.push(absolute);
    }
  }
}

collect(testRoot);
files.sort((left, right) => left.localeCompare(right, 'en'));

if (files.length === 0) {
  process.stderr.write(`No compiled tests found below ${testRoot}. Run npm run build first.\n`);
  process.exit(1);
}

const result = spawnSync(process.execPath, ['--test', ...files], {
  cwd: process.cwd(),
  env: process.env,
  stdio: 'inherit',
  windowsHide: true,
});

if (result.error) {
  throw result.error;
}

process.exit(result.status ?? 1);
