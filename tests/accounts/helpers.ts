import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import type { LuaEngine } from 'wasmoon';

export const root = process.cwd();
export const accountsRoot = path.join(root, 'resources', 'synex_accounts');

export async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

export async function preload(
  engine: LuaEngine,
  name: string,
  relativePath: string,
): Promise<void> {
  const contents = await source(relativePath);
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(contents)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

export async function bootstrapDomain(engine: LuaEngine): Promise<void> {
  await preload(
    engine,
    'server.foundation',
    'resources/synex_accounts/server/foundation.lua',
  );
  await preload(
    engine,
    'server.domain',
    'resources/synex_accounts/server/domain.lua',
  );
  await engine.doString(`
    Foundation = require 'server.foundation'
    Domain = require('server.domain')(Foundation)
  `);
}

export async function accountRuntimeSources(): Promise<Array<{
  relativePath: string;
  contents: string;
}>> {
  const serverRoot = path.join(accountsRoot, 'server');
  const files: string[] = [];

  async function visit(directory: string): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) await visit(absolute);
      else if (entry.isFile() && entry.name.endsWith('.lua')) files.push(absolute);
    }
  }

  await visit(serverRoot);
  files.sort((left, right) => left.localeCompare(right, 'en'));
  return Promise.all(files.map(async (absolute) => ({
    relativePath: path.relative(accountsRoot, absolute).replaceAll('\\', '/'),
    contents: await readFile(absolute, 'utf8'),
  })));
}
