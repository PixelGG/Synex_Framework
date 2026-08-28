import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { LuaFactory } from 'wasmoon';

const worldRoot = path.join(process.cwd(), 'resources', 'synex_world');

export const worldFoundationFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/geometry.lua',
  'server/graph.lua',
  'server/spatial_index.lua',
  'server/compiler.lua',
  'server/registry.lua',
] as const;

export async function runWorldLua<T>(
  source: string,
  files: readonly string[] = worldFoundationFiles,
): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of files) {
      await engine.doString(await readFile(path.join(worldRoot, relative), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}
