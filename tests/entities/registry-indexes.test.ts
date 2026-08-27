import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resourceRoot = path.join(process.cwd(), 'resources', 'synex_entities');
const validationPath = path.join(resourceRoot, 'shared', 'validation.lua');
const orderedIndexPath = path.join(resourceRoot, 'server', 'ordered_index.lua');
const spatialPath = path.join(resourceRoot, 'server', 'spatial_index.lua');
const registryPath = path.join(resourceRoot, 'server', 'registry.lua');

async function runLua<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of [validationPath, orderedIndexPath, spatialPath, registryPath]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('registry maintains resource, bucket, logical-owner, binding, net and handle indexes', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityRegistry.new({ spatial = { cellSize = 32 } })
    local vehicle = assert(registry.insert({
      entityId = 'entity_index_0001', generation = 1, netId = 101, handle = 1001,
      resourceOwner = 'synex_vehicles', persistentKey = 'vehicle:primary', bucket = 7,
      position = { x = 5, y = 6, z = 0 },
      owner = { type = 'group', id = 'group_lspd' },
      binding = { namespace = 'synex_vehicles.vehicle', ref = 'VEH-0001' }
    }))
    local object = assert(registry.insert({
      entityId = 'entity_index_0002', generation = 3, netId = 102, handle = 1002,
      resourceOwner = 'synex_world', persistentKey = 'vehicle:primary', bucket = 8,
      position = { x = 50, y = 50, z = 0 },
      owner = { type = 'resource', id = 'synex_world' }
    }))

    assert(registry.byEntityId(vehicle.entityId, 1) == vehicle)
    local staleEntity, staleEntityError = registry.byEntityId(vehicle.entityId, 2)
    assert(staleEntity == nil and staleEntityError.code == 'STALE_ENTITY')
    assert(registry.byNetId(101, { entityId = vehicle.entityId, generation = 1 }) == vehicle)
    assert(registry.byHandle(1001, { entityId = vehicle.entityId, generation = 1 }) == vehicle)
    assert(registry.byBinding('synex_vehicles.vehicle', 'VEH-0001') == vehicle)
    assert(registry.byPersistentKey('vehicle:primary', 'synex_vehicles') == vehicle)
    assert(registry.byPersistentKey('vehicle:primary', 'synex_world') == object)

    local ambiguous, ambiguousError = registry.byPersistentKey('vehicle:primary')
    assert(ambiguous == nil and ambiguousError.code == 'CONFLICT')
    assert(#registry.forResource('synex_vehicles') == 1)
    assert(#registry.forBucket(7) == 1)
    local owned = registry.forLogicalOwner('group', 'group_lspd')
    assert(#owned == 1 and owned[1] == vehicle)

    local ref = assert(registry.entityRef(vehicle))
    assert(ref.entityId == vehicle.entityId and ref.generation == 1)
    assert(registry.resolveRef(ref, 'synex_vehicles') == vehicle)
    local foreignBinding, foreignBindingError = registry.insert({
      entityId = 'entity_index_0003', generation = 1, netId = 103,
      resourceOwner = 'synex_jobs',
      binding = { namespace = 'synex_vehicles.vehicle', ref = 'VEH-0003' }
    })
    assert(foreignBinding == nil and foreignBindingError.code == 'FORBIDDEN')
    return ambiguousError.code
  `);
  assert.equal(result, 'CONFLICT');
});

test('registry mutations update every query index and cleanup atomically', async () => {
  const result = await runLua<number>(String.raw`
    local registry = SynexEntityRegistry.new({ spatial = { cellSize = 16 } })
    local first = assert(registry.insert({
      entityId = 'entity_mutation_001', generation = 1, netId = 201, handle = 2001,
      resourceOwner = 'synex_world', bucket = 1, position = { x = 0, y = 0, z = 0 },
      owner = { type = 'group', id = 'group_alpha' },
      binding = { namespace = 'synex_world.object', ref = 'OBJECT-A' }
    }))
    local second = assert(registry.insert({
      entityId = 'entity_mutation_002', generation = 1, netId = 202, handle = 2002,
      resourceOwner = 'synex_world', bucket = 1, position = { x = 100, y = 0, z = 0 }
    }))

    local nearOld = assert(registry.nearby({ x = 0, y = 0, z = 0 }, 10, 1, 8))
    assert(#nearOld == 1 and nearOld[1].record == first)
    assert(registry.move(first.entityId, 1, 2, { x = 100, y = 0, z = 0 }) == first)
    assert(#registry.forBucket(1) == 1 and registry.forBucket(1)[1] == second)
    assert(#registry.forBucket(2) == 1 and registry.forBucket(2)[1] == first)
    assert(#assert(registry.nearby({ x = 0, y = 0, z = 0 }, 10, 1, 8)) == 0)
    local nearNew = assert(registry.nearby({ x = 100, y = 0, z = 0 }, 10, 2, 8))
    assert(#nearNew == 1 and nearNew[1].record == first)

    assert(registry.update(first.entityId, 1, {
      owner = { type = 'group', id = 'group_beta' }, status = 'active', version = 4
    }) == first)
    assert(#registry.forLogicalOwner('group', 'group_alpha') == 0)
    assert(registry.forLogicalOwner('group', 'group_beta')[1] == first)
    assert(registry.rebind(first.entityId, 1, {
      namespace = 'synex_world.object', ref = 'OBJECT-B'
    }) == first)
    local oldBinding, oldBindingError = registry.byBinding('synex_world.object', 'OBJECT-A')
    assert(oldBinding == nil and oldBindingError.code == 'NOT_FOUND')
    local conflict, conflictError = registry.rebind(second.entityId, 1, {
      namespace = 'synex_world.object', ref = 'OBJECT-B'
    })
    assert(conflict == nil and conflictError.code == 'BINDING_CONFLICT')

    assert(registry.remove(first.entityId, 1) == first)
    assert(registry.count() == 1)
    assert(registry.spatial().get(first.entityId) == nil)
    local missingNet, netError = registry.byNetId(201)
    local missingHandle, handleError = registry.byHandle(2001)
    local missingBinding, bindingError = registry.byBinding('synex_world.object', 'OBJECT-B')
    assert(missingNet == nil and netError.code == 'NOT_FOUND')
    assert(missingHandle == nil and handleError.code == 'NOT_FOUND')
    assert(missingBinding == nil and bindingError.code == 'NOT_FOUND')
    return registry.count()
  `);
  assert.equal(result, 1);
});

test('EntityRef checks make NetID and runtime-handle reuse explicit', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityRegistry.new({ spatial = { cellSize = 32 } })
    local first = assert(registry.insert({
      entityId = 'entity_reuse_0001', generation = 1, netId = 301, handle = 3001,
      resourceOwner = 'synex_world', position = { x = 0, y = 0, z = 0 }
    }))
    local staleRef = assert(registry.entityRef(first))
    assert(registry.reincarnate(first.entityId, 1, {
      generation = 2, netId = 302, handle = 3002, resourceCycle = 2,
      position = { x = 1, y = 0, z = 0 }
    }) == first)
    local stale, staleError = registry.resolveRef(staleRef)
    assert(stale == nil and staleError.code == 'STALE_ENTITY')
    local oldNet, oldNetError = registry.byNetId(301)
    local oldHandle, oldHandleError = registry.byHandle(3001)
    assert(oldNet == nil and oldNetError.code == 'NOT_FOUND')
    assert(oldHandle == nil and oldHandleError.code == 'NOT_FOUND')

    assert(registry.remove(first.entityId, 2) == first)
    local replacement = assert(registry.insert({
      entityId = 'entity_reuse_0002', generation = 1, netId = 301, handle = 3001,
      resourceOwner = 'synex_world', position = { x = 2, y = 0, z = 0 }
    }))
    assert(registry.byNetId(301) == replacement)
    assert(registry.byHandle(3001) == replacement)
    local wrongNet, wrongNetError = registry.byNetId(301, staleRef)
    local wrongHandle, wrongHandleError = registry.byHandle(3001, staleRef)
    assert(wrongNet == nil and wrongNetError.code == 'STALE_ENTITY')
    assert(wrongHandle == nil and wrongHandleError.code == 'STALE_ENTITY')
    return wrongNetError.code
  `);
  assert.equal(result, 'STALE_ENTITY');
});

test('spatial hash isolates routing buckets and enforces query budgets', async () => {
  const result = await runLua<string>(String.raw`
    local spatial = SynexEntitySpatialIndex.create({
      cellSize = 64, maximumEntries = 8, maximumRadius = 256,
      maximumResults = 2, maximumScannedCells = 9, maximumCandidates = 3
    })
    assert(spatial.insert('entity_spatial_b', { x = 4, y = 0, z = 0 }, 0))
    assert(spatial.insert('entity_spatial_a', { x = -4, y = 0, z = 0 }, 0))
    assert(spatial.insert('entity_spatial_c', { x = 6, y = 0, z = 0 }, 0))
    assert(spatial.insert('entity_spatial_d', { x = 1, y = 0, z = 0 }, 9))
    local nearest, detail = assert(spatial.nearby({ x = 0, y = 0, z = 0 }, 64, 0, 2))
    assert(#nearest == 2 and nearest[1].entityId == 'entity_spatial_a')
    assert(nearest[2].entityId == 'entity_spatial_b' and detail.truncated)
    local isolated = assert(spatial.nearby({ x = 0, y = 0, z = 0 }, 64, 9, 2))
    assert(#isolated == 1 and isolated[1].entityId == 'entity_spatial_d')
    local oversized, oversizedError = spatial.nearby({ x = 0, y = 0, z = 0 }, 65, 0, 2)
    assert(oversized == nil and oversizedError.code == 'QUERY_BUDGET_EXCEEDED')

    assert(spatial.insert('entity_spatial_e', { x = 2, y = 2, z = 0 }, 0))
    local crowded, crowdedError = spatial.nearby({ x = 0, y = 0, z = 0 }, 64, 0, 2)
    assert(crowded == nil and crowdedError.code == 'QUERY_BUDGET_EXCEEDED')
    return crowdedError.code
  `);
  assert.equal(result, 'QUERY_BUDGET_EXCEEDED');
});
