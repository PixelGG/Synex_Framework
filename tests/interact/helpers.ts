import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

export const interactFoundationFiles = [
  'resources/synex_interact/shared/limits.lua',
  'resources/synex_interact/shared/validation.lua',
  'resources/synex_interact/server/foundation.lua',
] as const;

export const interactServerFiles = [
  ...interactFoundationFiles,
  'resources/synex_interact/server/target_selector.lua',
  'resources/synex_interact/server/world_authority.lua',
  'resources/synex_interact/server/compiler.lua',
  'resources/synex_interact/server/registry.lua',
  'resources/synex_interact/server/slots.lua',
  'resources/synex_interact/server/actor_locks.lua',
  'resources/synex_interact/server/sessions.lua',
  'resources/synex_interact/server/action_graph.lua',
  'resources/synex_interact/server/authority.lua',
  'resources/synex_interact/server/compatibility.lua',
] as const;

export async function createInteractLua(
  files: readonly string[] = interactServerFiles,
): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of files) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  await engine.doString(`
    if SynexInteractAuthority then
      local createAuthority = SynexInteractAuthority.create
      SynexInteractAuthority.create = function(options)
        options = options or {}
        options.validateActorViability = options.validateActorViability
          or function() return true end
        return createAuthority(options)
      end
    end
  `);
  return engine;
}

export async function runInteractLua<T>(
  source: string,
  files: readonly string[] = interactServerFiles,
): Promise<T> {
  const engine = await createInteractLua(files);
  try {
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

export const interactBundleFactory = `
  function __interactBundle(graph)
    return {
      schemaVersion = 1,
      key = 'fixture:terminal',
      revision = 1,
      smartObjects = {{
        key = 'fixture:terminal',
        binding = { type = 'staticTransform', position = { x = 10, y = 20, z = 30 },
          tags = { 'fixture.object.terminal' } },
        slots = {{ key = 'operator', capacity = 1, interactionRadius = 2.0,
          facingTolerance = 90, tags = { 'fixture.slot.operator' } }},
        activities = { 'fixture:inspect' },
        tags = { 'fixture.object.terminal' },
      }},
      intents = {{
        key = 'fixture:inspect', smartObjectKey = 'fixture:terminal',
        verb = 'inspect', label = 'Inspect terminal', basePriority = 10,
        specificity = 2, trigger = 'primary', slotSelector = 'operator',
        visibilityConditions = {}, executionPolicy = {
          maximumDistance = 2.0, leaseTtlMs = 2500,
          maximumLifetimeMs = 10000, lockChannels = { 'actor.hands' },
        },
        actionGraphRef = 'fixture:inspect_graph', presentation = {},
        participants = {{ role = 'operator', required = true,
          slotKey = 'operator', capacity = 1, lossPolicy = 'ABORT' }},
      }},
      graphs = { graph or {
        key = 'fixture:inspect_graph', entry = 'verify', timeoutMs = 10000,
        nodes = {
          { key = 'verify', type = 'verifyLease', next = 'complete' },
          { key = 'complete', type = 'complete' },
        },
      }},
    }
  end
`;
