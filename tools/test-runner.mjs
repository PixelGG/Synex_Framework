import { mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const TEST_MODULES_PER_WRAPPER = 24;

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

// Certification consumes the summary, so keep it machine-readable across Node releases.
const testArguments = [
  '--test',
  '--test-reporter=tap',
  '--test-reporter-destination=stdout',
];
if (scope === 'database'
  || (scope === undefined && process.env.SYNEX_TEST_DATABASE_LIVE === '1')) {
  testArguments.push('--test-concurrency=1');
}
const wrapperRoot = mkdtempSync(path.join(tmpdir(), 'synex-test-runner-'));
const wrappers = [];
for (let offset = 0; offset < files.length; offset += TEST_MODULES_PER_WRAPPER) {
  const wrapper = path.join(wrapperRoot, `batch-${wrappers.length.toString().padStart(4, '0')}.mjs`);
  const modules = files.slice(offset, offset + TEST_MODULES_PER_WRAPPER);
  writeFileSync(wrapper, `${modules.map((file) =>
    `await import(${JSON.stringify(pathToFileURL(file).href)});`).join('\n')}\n`, 'utf8');
  wrappers.push(wrapper);
}
testArguments.push(...wrappers);

let result;
try {
  result = spawnSync(process.execPath, testArguments, {
    cwd: process.cwd(),
    env: process.env,
    stdio: 'inherit',
    windowsHide: true,
  });
} finally {
  rmSync(wrapperRoot, { recursive: true, force: true });
}

if (result.error) {
  throw result.error;
}

process.exit(result.status ?? 1);
