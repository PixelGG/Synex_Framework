import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua, worldFoundationFiles } from './helpers.ts';

test('context resolution is deterministic across hierarchy, overlap, and insertion order', async () => {
  const result = await runWorldLua<string>(String.raw`
    local registry = SynexWorldRegistry.create({})
    local objects = {
      { kind = 'room', key = 'synex_world_example:room', parent = 'synex_world_example:interior',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 5 } },
      { kind = 'region', key = 'synex_world_example:region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'zone', key = 'synex_world_example:zone', parent = 'synex_world_example:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 3 } },
      { kind = 'location', key = 'synex_world_example:location', parent = 'synex_world_example:region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 } },
      { kind = 'interior', key = 'synex_world_example:interior', parent = 'synex_world_example:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 20 } }
    }
    assert(registry.registerBundle({ schema = 1, key = 'synex_world_example:context',
      version = '1.0.0', dependencies = {}, objects = objects }, 'synex_world_example', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local first = assert(context.resolve({ x = 0, y = 0, z = 0 }))
    local second = assert(context.resolve({ x = 0, y = 0, z = 0 }))
    assert(first.location.key == 'synex_world_example:location')
    assert(first.interior.key == 'synex_world_example:interior')
    assert(first.room.key == 'synex_world_example:room')
    assert(first.zones[1].key == 'synex_world_example:zone')
    assert(first.location.key == second.location.key and first.room.key == second.room.key)
    return first.region.key .. ':' .. first.location.key .. ':' .. first.room.key
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 'synex_world_example:region:synex_world_example:location:synex_world_example:room');
});

test('context resolution fails closed when overlapping semantics exceed its bound', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      { kind = 'location', key = 'synex_world_overlap:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 20 } },
    }
    for index = 1, 129 do
      objects[#objects + 1] = {
        kind = 'zone', key = ('synex_world_overlap:zone.%03d'):format(index),
        parent = 'synex_world_overlap:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 },
      }
    end
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_world_overlap:bundle',
      version = '1.0.0', dependencies = {}, objects = objects },
      'synex_world_overlap', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local resolved, resolveError = context.resolve({ x = 0, y = 0, z = 0 })
    assert(resolved == nil and resolveError.code == 'QUERY_LIMIT_EXCEEDED')
    assert(resolveError.retryable == true and resolveError.details.candidates == 130)
    return resolveError.code .. ':' .. resolveError.details.candidates
  `, [...worldFoundationFiles, 'server/context.lua']);

  assert.equal(result, 'QUERY_LIMIT_EXCEEDED:130');
});

test('context applies semantic priority and distance before bounded top-N trimming', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      { kind = 'region', key = 'synex_world_topn:a_region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 200 } },
      { kind = 'location', key = 'synex_world_topn:location',
        parent = 'synex_world_topn:a_region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'zone', key = 'synex_world_topn:z_priority',
        parent = 'synex_world_topn:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 } },
      { kind = 'zone', key = 'synex_world_topn:a_far',
        parent = 'synex_world_topn:location',
        geometry = { type = 'sphere', center = { x = 30, y = 0, z = 0 }, radius = 1 } },
      { kind = 'zone', key = 'synex_world_topn:z_near',
        parent = 'synex_world_topn:location',
        geometry = { type = 'sphere', center = { x = 20, y = 0, z = 0 }, radius = 1 } },
    }
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_world_topn:bundle',
      version = '1.0.0', dependencies = {}, objects = objects },
      'synex_world_topn', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local at, atMetadata = assert(context.queryAt({ x = 0, y = 0, z = 0 }, {}, 1))
    assert(#at == 1 and at[1].key == 'synex_world_topn:z_priority'
      and atMetadata.truncated == true and atMetadata.matches == 3)
    local nearby, nearbyMetadata = context.queryNearby(
      { x = 20, y = 0, z = 0 }, 50, { kind = 'zone' }, 1)
    assert(nearby, nearbyMetadata and nearbyMetadata.code)
    assert(#nearby == 1 and nearby[1].object.key == 'synex_world_topn:z_near'
      and nearbyMetadata.truncated == true and nearbyMetadata.matches == 3)
    return at[1].key .. ':' .. nearby[1].object.key
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 'synex_world_topn:z_priority:synex_world_topn:z_near');
});

test('context exact overlap limit is complete rather than falsely truncated', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = { { kind = 'location', key = 'synex_world_exact:location',
      geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 20 } } }
    for index = 1, 127 do
      objects[#objects + 1] = { kind = 'zone',
        key = ('synex_world_exact:zone.%03d'):format(index),
        parent = 'synex_world_exact:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 } }
    end
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_world_exact:bundle',
      version = '1.0.0', dependencies = {}, objects = objects },
      'synex_world_exact', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local resolved = assert(context.resolve({ x = 0, y = 0, z = 0 }))
    assert(#resolved.zones == 127 and resolved.location.key == 'synex_world_exact:location')
    return #resolved.zones
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 127);
});

test('context selects one coherent primary hierarchy across overlapping branches', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      { kind = 'region', key = 'synex_overlap:a.region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'region', key = 'synex_overlap:z.region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'location', key = 'synex_overlap:a.location', parent = 'synex_overlap:a.region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 } },
      { kind = 'location', key = 'synex_overlap:z.location', parent = 'synex_overlap:z.region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 } },
      { kind = 'interior', key = 'synex_overlap:a.interior', parent = 'synex_overlap:a.location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 25 } },
      { kind = 'interior', key = 'synex_overlap:z.interior', parent = 'synex_overlap:z.location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 25 } },
      { kind = 'room', key = 'synex_overlap:a.room', parent = 'synex_overlap:z.interior',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 } },
      { kind = 'room', key = 'synex_overlap:z.room', parent = 'synex_overlap:a.interior',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 } },
    }
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_overlap:bundle',
      version = '1.0.0', dependencies = {}, objects = objects }, 'synex_overlap', 1))
    local resolved = assert(SynexWorldContext.create({ registry = registry })
      .resolve({ x = 0, y = 0, z = 0 }))
    assert(resolved.room.key == 'synex_overlap:a.room')
    assert(resolved.interior.key == 'synex_overlap:z.interior')
    assert(resolved.location.key == 'synex_overlap:z.location')
    assert(resolved.region.key == 'synex_overlap:z.region')
    assert(#resolved.regions == 2 and resolved.regions[1].key == 'synex_overlap:a.region'
      and resolved.regions[2].key == 'synex_overlap:z.region')
    return table.concat({ resolved.region.key, resolved.location.key,
      resolved.interior.key, resolved.room.key }, ':')
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 'synex_overlap:z.region:synex_overlap:z.location:'
    + 'synex_overlap:z.interior:synex_overlap:a.room');
});

test('context selects the most specific nested region with and without a primary location', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      { kind = 'region', key = 'synex_nested:a.root',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'region', key = 'synex_nested:z.child', parent = 'synex_nested:a.root',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 20 } },
      { kind = 'location', key = 'synex_nested:location', parent = 'synex_nested:z.child',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 5 } },
    }
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_nested:bundle',
      version = '1.0.0', dependencies = {}, objects = objects }, 'synex_nested', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local insideLocation = assert(context.resolve({ x = 0, y = 0, z = 0 }))
    local regionsOnly = assert(context.resolve({ x = 10, y = 0, z = 0 }))
    assert(insideLocation.location.key == 'synex_nested:location')
    assert(insideLocation.region.key == 'synex_nested:z.child')
    assert(regionsOnly.location == nil and regionsOnly.region.key == 'synex_nested:z.child')
    assert(#regionsOnly.regions == 2
      and regionsOnly.regions[1].key == 'synex_nested:a.root'
      and regionsOnly.regions[2].key == 'synex_nested:z.child')
    return insideLocation.region.key .. ':' .. regionsOnly.region.key
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 'synex_nested:z.child:synex_nested:z.child');
});

test('context verification compares complete bounded region, zone and instance identity', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      { kind = 'region', key = 'synex_verify:region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      { kind = 'region', key = 'synex_verify:other_region',
        geometry = { type = 'sphere', center = { x = 500, y = 0, z = 0 }, radius = 10 } },
      { kind = 'location', key = 'synex_verify:location', parent = 'synex_verify:region',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 } },
      { kind = 'zone', key = 'synex_verify:zone', parent = 'synex_verify:location',
        geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 5 } },
      { kind = 'zone', key = 'synex_verify:other_zone', parent = 'synex_verify:location',
        geometry = { type = 'sphere', center = { x = 20, y = 0, z = 0 }, radius = 2 } },
    }
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle({ schema = 1, key = 'synex_verify:bundle',
      version = '1.0.0', dependencies = {}, objects = objects }, 'synex_verify', 1))
    local context = SynexWorldContext.create({ registry = registry })
    local instance = { instanceId = 'world_instance_00000001', revision = 7,
      template = { kind = 'instance_template', key = 'synex_verify:template', revision = 3 },
      state = 'ACTIVE', ownerResource = 'synex_verify', ownerEpoch = 4,
      capacity = 8, members = 1, createdAt = '2026-08-28T12:00:00Z',
      cleanupPolicy = 'manual', bucketRef = { bucket = 41, generation = 2 } }
    local point = { x = 0, y = 0, z = 0 }
    local expected = assert(context.resolve(point, instance))
    assert(expected.instance.state == 'ACTIVE'
      and expected.instance.ownerResource == nil and expected.instance.bucketRef == nil)
    assert(assert(context.verify(expected, point, instance)).valid == true)

    local wrongZone = SynexWorldValidation.copy(expected)
    wrongZone.zones = { registry.ref(assert(registry.get('synex_verify:other_zone'))) }
    local _, zoneError = context.verify(wrongZone, point, instance)
    local wrongRegions = SynexWorldValidation.copy(expected)
    wrongRegions.regions = { registry.ref(assert(registry.get('synex_verify:other_region'))) }
    local _, regionError = context.verify(wrongRegions, point, instance)
    local wrongInstance = SynexWorldValidation.copy(expected)
    wrongInstance.instance.instanceId = 'world_instance_00000002'
    local _, instanceError = context.verify(wrongInstance, point, instance)
    local wrongState = SynexWorldValidation.copy(expected)
    wrongState.instance.state = 'READY'
    local _, stateError = context.verify(wrongState, point, instance)
    local extra = SynexWorldValidation.copy(expected)
    extra.untrusted = true
    local _, shapeError = context.verify(extra, point, instance)
    assert(zoneError.code == 'OUT_OF_CONTEXT' and zoneError.details.field == 'zones')
    assert(regionError.code == 'OUT_OF_CONTEXT' and regionError.details.field == 'regions')
    assert(instanceError.code == 'OUT_OF_CONTEXT'
      and instanceError.details.field == 'instance')
    assert(stateError.code == 'OUT_OF_CONTEXT'
      and stateError.details.field == 'instance')
    assert(shapeError.code == 'OUT_OF_CONTEXT')
    return table.concat({ zoneError.code, regionError.code,
      instanceError.code, shapeError.code }, ':')
  `, [...worldFoundationFiles, 'server/context.lua']);
  assert.equal(result, 'OUT_OF_CONTEXT:OUT_OF_CONTEXT:OUT_OF_CONTEXT:OUT_OF_CONTEXT');
});
