import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');

async function runLua<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of [
      'shared/validation.lua',
      'server/ordered_index.lua',
      'server/spatial_index.lua',
      'server/registry.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relative), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('deterministic randomized insert, move, remove, reinsert sequences preserve every index', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityRegistry.new({ spatial = {
      cellSize = 32, maximumEntries = 64, maximumCandidates = 64,
      maximumRadius = 256, maximumResults = 64,
    } })
    local slots, generations, active, staleRefs = 16, {}, {}, {}
    local randomState = 2463534242

    local function random(maximum)
      randomState = (1103515245 * randomState + 12345) % 2147483648
      return randomState % maximum
    end

    local function identity(slot, generation)
      return {
        entityId = ('entity_property_%02d'):format(slot),
        handle = 30000 + slot * 100 + generation,
        netId = 10000 + slot * 100 + generation,
      }
    end

    local function contains(records, expected)
      for _, record in ipairs(records) do
        if record == expected then return true end
      end
      return false
    end

    local function verify(step)
      local expectedCount = 0
      local bucketCounts = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
      local ownerCounts = { group_alpha = 0, group_beta = 0 }
      for slot = 1, slots do
        local record = active[slot]
        local entityId = ('entity_property_%02d'):format(slot)
        if record then
          expectedCount = expectedCount + 1
          bucketCounts[record.bucket] = bucketCounts[record.bucket] + 1
          ownerCounts[record.owner.id] = ownerCounts[record.owner.id] + 1
          assert(registry.byEntityId(entityId, record.generation) == record,
            'byEntityId failed at step ' .. step)
          local expectedRef = { entityId = entityId, generation = record.generation }
          assert(registry.byNetId(record.netId, expectedRef) == record,
            'net index failed at step ' .. step)
          assert(registry.byHandle(record.handle, expectedRef) == record,
            'handle index failed at step ' .. step)
          assert(registry.byPersistentKey(record.persistentKey, 'synex_world') == record,
            'persistent index failed at step ' .. step)
          assert(registry.byBinding(
            record.binding.namespace, record.binding.ref, 'synex_world') == record,
            'binding index failed at step ' .. step)
          local spatial = assert(registry.spatial().get(entityId))
          assert(spatial.bucket == record.bucket
            and spatial.position.x == record.position.x
            and spatial.position.y == record.position.y,
            'spatial index failed at step ' .. step)
          assert(contains(registry.forBucket(record.bucket), record),
            'bucket membership failed at step ' .. step)
          assert(contains(registry.forLogicalOwner('group', record.owner.id), record),
            'logical owner membership failed at step ' .. step)
          if staleRefs[slot] then
            local stale, staleError = registry.byNetId(record.netId, staleRefs[slot])
            assert(stale == nil and staleError.code == 'STALE_ENTITY',
              'stale reference escaped at step ' .. step)
          end
        else
          local missing, missingError = registry.byEntityId(entityId)
          assert(missing == nil and missingError.code == 'NOT_FOUND',
            'removed entity remained indexed at step ' .. step)
          assert(registry.spatial().get(entityId) == nil,
            'removed entity remained spatially indexed at step ' .. step)
        end
      end
      assert(registry.count() == expectedCount and registry.spatial().count() == expectedCount,
        'registry counts diverged at step ' .. step)
      assert(#registry.forResource('synex_world') == expectedCount,
        'resource index diverged at step ' .. step)
      for bucket = 0, 3 do
        assert(#registry.forBucket(bucket) == bucketCounts[bucket],
          'bucket count diverged at step ' .. step)
      end
      for ownerId, count in pairs(ownerCounts) do
        assert(#registry.forLogicalOwner('group', ownerId) == count,
          'owner count diverged at step ' .. step)
      end
    end

    for step = 1, 600 do
      local slot = random(slots) + 1
      local record = active[slot]
      if not record then
        generations[slot] = (generations[slot] or 0) + 1
        local generation = generations[slot]
        local runtime = identity(slot, generation)
        record = assert(registry.insert({
          binding = {
            namespace = 'synex_world.object',
            ref = ('OBJECT-%02d-%04d'):format(slot, generation),
          },
          bucket = random(4),
          entityId = runtime.entityId,
          entityType = 'object',
          generation = generation,
          handle = runtime.handle,
          netId = runtime.netId,
          owner = {
            type = 'group',
            id = random(2) == 0 and 'group_alpha' or 'group_beta',
          },
          persistent = true,
          persistentKey = ('property:%02d'):format(slot),
          position = { x = slot * 10, y = generation, z = 0 },
          resourceOwner = 'synex_world',
          status = 'active',
          tags = {},
        }))
        active[slot] = record
      else
        local operation = random(5)
        if operation == 0 then
          assert(registry.move(record.entityId, record.generation, random(4), {
            x = random(1000) / 10,
            y = random(1000) / 10,
            z = random(100) / 10,
          }))
        elseif operation == 1 then
          assert(registry.update(record.entityId, record.generation, {
            owner = {
              type = 'group',
              id = record.owner.id == 'group_alpha' and 'group_beta' or 'group_alpha',
            },
            position = {
              x = random(1000) / 10,
              y = random(1000) / 10,
              z = random(100) / 10,
            },
            tags = { 'property_checked' },
            version = (record.version or 1) + 1,
          }))
        elseif operation == 2 then
          staleRefs[slot] = assert(registry.entityRef(record))
          assert(registry.remove(record.entityId, record.generation) == record)
          active[slot] = nil
        elseif operation == 3 then
          local previousRef = assert(registry.entityRef(record))
          local previousNetId = record.netId
          generations[slot] = record.generation + 1
          local runtime = identity(slot, generations[slot])
          assert(registry.reincarnate(record.entityId, record.generation, {
            bucket = random(4), generation = generations[slot],
            handle = runtime.handle, netId = runtime.netId,
            position = { x = random(1000) / 10, y = random(1000) / 10, z = 0 },
            resourceCycle = generations[slot],
          }) == record)
          local oldNet, oldNetError = registry.byNetId(previousNetId)
          assert(oldNet == nil and oldNetError.code == 'NOT_FOUND')
          staleRefs[slot] = previousRef
        else
          assert(registry.rebind(record.entityId, record.generation, {
            namespace = 'synex_world.object',
            ref = ('OBJECT-%02d-R%04d'):format(slot, step),
          }) == record)
        end
      end
      verify(step)
    end
    return registry.count() .. ':' .. registry.spatial().count() .. ':600'
  `);
  assert.match(result, /^\d+:\d+:600$/u);
  const [registryCount, spatialCount] = result.split(':');
  assert.equal(registryCount, spatialCount);
});
