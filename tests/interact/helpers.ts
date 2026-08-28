import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { LuaFactory } from 'wasmoon';

const interactRoot = path.join(process.cwd(), 'resources', 'synex_interact');

export const interactFoundationFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/registry.lua',
  'server/lease_engine.lua',
  'server/action_graph.lua',
] as const;

export async function runInteractLua<T>(
  source: string,
  files: readonly string[] = interactFoundationFiles,
): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of files) {
      await engine.doString(await readFile(path.join(interactRoot, relative), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}
