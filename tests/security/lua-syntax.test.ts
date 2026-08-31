import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

async function collectLuaFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) return collectLuaFiles(absolute);
    return entry.isFile() && entry.name.endsWith('.lua') ? [absolute] : [];
  }));
  return nested.flat().sort((left, right) => left.localeCompare(right, 'en'));
}

test('every synex_security Lua source parses before it can be packaged', async () => {
  const resourceRoot = path.join(process.cwd(), 'resources', 'synex_security');
  const files = await collectLuaFiles(resourceRoot);
  assert.ok(files.length > 0, 'the Security resource must contain Lua sources');

  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      const source = await readFile(file, 'utf8');
      const chunkName = `@${path.relative(process.cwd(), file).replaceAll('\\', '/')}`;
      await engine.doString(`assert(load(${JSON.stringify(source)}, ${JSON.stringify(chunkName)}))`);
    }
  } finally {
    engine.global.close();
  }
});
