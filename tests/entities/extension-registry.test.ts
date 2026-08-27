import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const extensionRegistryPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'extension_registry.lua',
);

async function runLua<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(extensionRegistryPath, 'utf8'));
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('extension definitions are namespace-owned, epoch-bound and isolated copies', async () => {
  const result = await runLua<number>(String.raw`
    local registry = SynexEntityExtensionRegistry.create()
    assert(registry.beginOwner('synex_vehicles', 4))
    local archetype = {
      namespace = 'synex_vehicles.standard', version = 7,
      entityType = 'vehicle', allowedModels = { 100, 200 },
      policies = { persistence = 'persistent', recovery = 'on_demand' }
    }
    local registered = assert(registry.registerArchetype('synex_vehicles', 4, archetype))
    assert(registered.schemaVersion == 7 and registered.version == 7)
    archetype.allowedModels[1] = 999
    local fetched = assert(registry.getArchetype('synex_vehicles.standard'))
    assert(fetched.allowedModels[1] == 100)
    fetched.allowedModels[1] = 777
    assert(registry.getArchetype('synex_vehicles.standard').allowedModels[1] == 100)

    assert(registry.registerComponentSchema('synex_vehicles', 4, {
      namespace = 'synex_vehicles.runtime', schemaVersion = 2,
      persistenceMode = 'runtime', schema = { type = 'object' }
    }))
    assert(registry.registerStateSchema('synex_vehicles', 4, {
      namespace = 'synex_vehicles.locked', schemaVersion = 1,
      authority = 'server', replication = 'scoped', valueType = 'boolean'
    }))
    local foreign, foreignError = registry.registerArchetype('synex_vehicles', 4, {
      namespace = 'synex_police.evidence', schemaVersion = 1
    })
    assert(foreign == nil and foreignError.code == 'FOREIGN_NAMESPACE')
    local stale, staleError = registry.registerArchetype('synex_vehicles', 3, {
      namespace = 'synex_vehicles.stale', schemaVersion = 1
    })
    assert(stale == nil and staleError.code == 'STALE_RESOURCE')
    local duplicate, duplicateError = registry.registerArchetype('synex_vehicles', 4, {
      namespace = 'synex_vehicles.standard', schemaVersion = 8
    })
    assert(duplicate == nil and duplicateError.code == 'CONFLICT')
    local snapshot = registry.snapshot()
    assert(snapshot.archetypes == 1 and snapshot.components == 1)
    assert(snapshot.states == 1 and snapshot.total == 3)
    return snapshot.total
  `);
  assert.equal(result, 3);
});

test('resource restart cleanup cannot remove registrations from a newer epoch', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityExtensionRegistry.create()
    assert(registry.beginOwner('synex_world', 10))
    assert(registry.registerArchetype('synex_world', 10, {
      namespace = 'synex_world.atm', schemaVersion = 1
    }))
    assert(registry.registerComponentSchema('synex_world', 10, {
      namespace = 'synex_world.anchor', schemaVersion = 1
    }))
    assert(registry.registerStateSchema('synex_world', 10, {
      namespace = 'synex_world.enabled', schemaVersion = 1
    }))

    local restarted = assert(registry.beginOwner('synex_world', 11))
    assert(restarted.replaced == 3 and registry.snapshot().total == 0)
    assert(registry.registerArchetype('synex_world', 11, {
      namespace = 'synex_world.atm', schemaVersion = 2
    }))
    local delayed, delayedError = registry.beginOwner('synex_world', 10)
    assert(delayed == nil and delayedError.code == 'STALE_RESOURCE')
    assert(registry.cleanup('synex_world', 10) == 0)
    local current = assert(registry.getArchetype('synex_world.atm'))
    assert(current.ownerEpoch == 11 and current.schemaVersion == 2)
    assert(registry.cleanup('synex_world', 11) == 1)
    local missing, missingError = registry.getArchetype('synex_world.atm')
    assert(missing == nil and missingError.code == 'NOT_FOUND')
    return missingError.code
  `);
  assert.equal(result, 'NOT_FOUND');
});

test('extension definitions reject cycles, metatables and oversized data', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityExtensionRegistry.create({
      maximumDefinitionBytes = 1024, maximumStringBytes = 1024
    })
    assert(registry.beginOwner('synex_world', 1))
    local cyclic = { namespace = 'synex_world.cyclic', schemaVersion = 1 }
    cyclic.schema = cyclic
    local cycleResult, cycleError = registry.registerArchetype('synex_world', 1, cyclic)
    assert(cycleResult == nil and cycleError.code == 'INVALID_DEFINITION')

    local decorated = setmetatable({
      namespace = 'synex_world.decorated', schemaVersion = 1
    }, {})
    local decoratedResult, decoratedError = registry.registerArchetype(
      'synex_world', 1, decorated
    )
    assert(decoratedResult == nil and decoratedError.code == 'INVALID_DEFINITION')
    local hugeResult, hugeError = registry.registerArchetype('synex_world', 1, {
      namespace = 'synex_world.huge', schemaVersion = 1, schema = string.rep('x', 1000)
    })
    assert(hugeResult == nil and hugeError.code == 'DEFINITION_TOO_LARGE')
    assert(registry.snapshot().total == 0)
    return hugeError.code
  `);
  assert.equal(result, 'DEFINITION_TOO_LARGE');
});

test('extension list and owner quotas are deterministic and bounded', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityExtensionRegistry.create({
      maximumDefinitions = 4, maximumDefinitionsPerOwner = 2, maximumListResults = 1
    })
    assert(registry.beginOwner('synex_world', 1))
    assert(registry.registerArchetype('synex_world', 1, {
      namespace = 'synex_world.zeta', schemaVersion = 1
    }))
    assert(registry.registerArchetype('synex_world', 1, {
      namespace = 'synex_world.alpha', schemaVersion = 1
    }))
    local listed, detail = registry.list('archetype', 'synex_world', 1)
    assert(#listed == 1 and listed[1].namespace == 'synex_world.alpha')
    assert(detail.truncated)
    local overflow, overflowError = registry.registerStateSchema('synex_world', 1, {
      namespace = 'synex_world.overflow', schemaVersion = 1
    })
    assert(overflow == nil and overflowError.code == 'REGISTRY_LIMIT')
    assert(registry.snapshot().total == 2)
    return overflowError.code
  `);
  assert.equal(result, 'REGISTRY_LIMIT');
});
