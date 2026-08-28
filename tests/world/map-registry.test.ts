import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/map_registry.lua',
] as const;

test('IPL requirements respect global, context, and instance scope', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      ['synex_map:global'] = { kind = 'ipl_bundle', key = 'synex_map:global',
        scope = 'global', ipls = { 'global_ipl' }, interiorSets = {} },
      ['synex_map:context'] = { kind = 'ipl_bundle', key = 'synex_map:context',
        scope = 'context', ipls = { 'context_ipl' }, interiorSets = {} },
      ['synex_map:instance'] = { kind = 'ipl_bundle', key = 'synex_map:instance',
        scope = 'instance', ipls = { 'instance_ipl' }, interiorSets = {} },
    }
    local registry = {
      objects = function() return objects end,
      get = function(key, kind)
        local value = objects[key]
        if value and (kind == nil or value.kind == kind) then return value end
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'started' end })
    local referenced = { { iplBundles = {
      'synex_map:context', 'synex_map:instance' } } }
    local outside = maps.clientRequirements(referenced, nil)
    assert(#outside == 2 and outside[1].name == 'context_ipl'
      and outside[1].refCount == 1 and outside[2].name == 'global_ipl'
      and outside[2].refCount == 1)
    local inside = maps.clientRequirements(referenced, { instanceId = 'world_instance_1' })
    assert(#inside == 3 and inside[1].name == 'context_ipl'
      and inside[2].name == 'global_ipl' and inside[3].name == 'instance_ipl')
    local names = {}
    for index, requirement in ipairs(inside) do names[index] = requirement.name end
    return table.concat(names, ',')
  `, files);
  assert.equal(result, 'context_ipl,global_ipl,instance_ipl');
});

test('shared IPL and interior-set requirements carry exact 2 to 1 to 0 reference counts', async () => {
  const result = await runWorldLua<string>(String.raw`
    local sharedSet = { interiorId = 17, name = 'shared_set', color = 3 }
    local objects = {
      ['synex_map:first'] = { kind = 'ipl_bundle', key = 'synex_map:first',
        scope = 'context', ipls = { 'shared_ipl' }, interiorSets = { sharedSet } },
      ['synex_map:second'] = { kind = 'ipl_bundle', key = 'synex_map:second',
        scope = 'context', ipls = { 'shared_ipl' }, interiorSets = { sharedSet } },
    }
    local registry = {
      objects = function() return objects end,
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'started' end })
    local bothIpls, bothSets = assert(maps.clientRequirements({ { iplBundles = {
      'synex_map:first', 'synex_map:second' } } }, nil))
    assert(#bothIpls == 1 and bothIpls[1].name == 'shared_ipl'
      and bothIpls[1].refCount == 2)
    assert(#bothSets == 1 and bothSets[1].interiorId == 17
      and bothSets[1].name == 'shared_set' and bothSets[1].color == 3
      and bothSets[1].refCount == 2)
    local oneIpls, oneSets = assert(maps.clientRequirements({
      { iplBundles = { 'synex_map:first' } } }, nil))
    assert(oneIpls[1].refCount == 1 and oneSets[1].refCount == 1)
    local noneIpls, noneSets = assert(maps.clientRequirements({}, nil))
    assert(#noneIpls == 0 and #noneSets == 0)
    return table.concat({ bothIpls[1].refCount, oneIpls[1].refCount,
      #noneIpls, bothSets[1].refCount, oneSets[1].refCount, #noneSets }, ':')
  `, files);
  assert.equal(result, '2:1:0:2:1:0');
});

test('client requirement aggregation fails closed above the 255 reference bound', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {}
    for index = 1, SynexWorldLimits.maximumClientRequirementRefCount + 1 do
      local key = ('synex_map:global_%03d'):format(index)
      objects[key] = { kind = 'ipl_bundle', key = key, scope = 'global',
        ipls = { 'shared_ipl' }, interiorSets = {} }
    end
    local registry = {
      objects = function() return objects end,
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'started' end })
    local ipls, sets, clientError = maps.clientRequirements({}, nil)
    assert(ipls == nil and sets == nil and clientError.code == 'QUERY_LIMIT_EXCEEDED')
    return clientError.code
  `, files);
  assert.equal(result, 'QUERY_LIMIT_EXCEEDED');
});

test('map availability generation changes only when resource lifecycle changes', async () => {
  const result = await runWorldLua<string>(String.raw`
    local states = { synex_map_asset = 'missing', synex_map_dependency = 'started' }
    local package = { kind = 'map_package', key = 'synex_test:map',
      resourceName = 'synex_map_asset', expectedResourceState = 'started', required = true,
      dependencies = { 'synex_map_dependency' } }
    local registry = {
      objects = function() return { [package.key] = package } end,
      get = function(key, kind)
        return key == package.key and kind == 'map_package' and package or nil
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function(name) return states[name] or 'missing' end })
    local first = maps.refresh()
    assert(first.generation == 1 and first.requiredUnavailable == 1)
    local unchanged = maps.refresh()
    assert(unchanged.generation == 1)
    states.synex_map_asset = 'started'
    local started = maps.refresh()
    assert(started.generation == 2 and started.available == 1)
    assert(maps.objectAvailability({ mapPackages = { package.key } }).available == true)
    states.synex_map_dependency = 'stopped'
    local dependencyStopped = maps.refresh()
    local availability = maps.objectAvailability({ mapPackages = { package.key } })
    assert(dependencyStopped.generation == 3 and dependencyStopped.requiredUnavailable == 1)
    assert(availability.available == false
      and availability.reasons[1].resource == 'synex_map_dependency')
    states.synex_map_dependency = 'started'
    local recovered = maps.refresh()
    assert(recovered.generation == 4 and recovered.available == 1
      and recovered.requiredUnavailable == 0)
    return table.concat({ first.generation, unchanged.generation,
      started.generation, dependencyStopped.generation,
      availability.reasons[1].state, recovered.generation }, ':')
  `, files);
  assert.equal(result, '1:1:2:3:stopped:4');
});

test('map availability propagates through containment and refreshes by registry revision', async () => {
  const result = await runWorldLua<string>(String.raw`
    local revision = 21
    local states = { synex_map_asset = 'started' }
    local package = { kind = 'map_package', key = 'synex_test:map',
      resourceName = 'synex_map_asset', expectedResourceState = 'started', required = true,
      locations = { 'synex_test:location' } }
    local location = { kind = 'location', key = 'synex_test:location' }
    local interior = { kind = 'interior', key = 'synex_test:interior',
      parent = location.key }
    local room = { kind = 'room', key = 'synex_test:room', parent = interior.key }
    local anchor = { kind = 'anchor', key = 'synex_test:anchor', parent = room.key }
    local door = { kind = 'door', key = 'synex_test:door', parent = room.key }
    local portal = { kind = 'portal', key = 'synex_test:portal', parent = room.key }
    local objects = { [package.key] = package, [location.key] = location,
      [interior.key] = interior, [room.key] = room, [anchor.key] = anchor,
      [door.key] = door, [portal.key] = portal }
    local registry = {
      objects = function() return objects end,
      currentRevision = function() return revision end,
      get = function(key, kind)
        local value = objects[key]
        if value and (kind == nil or value.kind == kind) then return value end
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'missing')
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function(name) return states[name] or 'missing' end })
    assert(maps.refresh().available == 1)
    for _, object in ipairs({ location, interior, room, anchor, door, portal }) do
      assert(maps.objectAvailability(object).available == true, object.kind)
    end

    states.synex_map_asset = 'stopped'
    assert(maps.refresh().requiredUnavailable == 1)
    for _, object in ipairs({ location, interior, room, anchor, door, portal }) do
      local availability = maps.objectAvailability(object)
      assert(availability.available == false, object.kind)
      assert(availability.reasons[1].resource == 'synex_map_asset', object.kind)
    end

    package.locations = {}
    revision = revision + 1
    assert(maps.objectAvailability(room).available == true)
    door.mapPackages = { package.key }
    revision = revision + 1
    assert(maps.objectAvailability(door).available == false)
    assert(maps.objectAvailability(portal).available == true)
    return table.concat({ maps.summary().generation, revision,
      maps.objectAvailability(door).reasons[1].state }, ':')
  `, files);
  assert.equal(result, '2:23:stopped');
});

test('map package impact is deterministic, graph-aware, and sample bounded', async () => {
  const result = await runWorldLua<string>(String.raw`
    local package = { kind = 'map_package', key = 'synex_test:map',
      resourceName = 'synex_map_asset', expectedResourceState = 'started', required = true,
      locations = { 'synex_test:location_a' }, bundleKey = 'synex_test:maps' }
    local objects = {
      [package.key] = package,
      ['synex_test:location_a'] = { kind = 'location', key = 'synex_test:location_a',
        bundleKey = 'synex_test:semantic' },
      ['synex_test:anchor_a'] = { kind = 'anchor', key = 'synex_test:anchor_a',
        parent = 'synex_test:location_a', bundleKey = 'synex_test:semantic' },
      ['synex_test:door_a'] = { kind = 'door', key = 'synex_test:door_a',
        parent = 'synex_test:location_a', bundleKey = 'synex_test:doors' },
      ['synex_test:location_b'] = { kind = 'location', key = 'synex_test:location_b',
        mapPackages = { package.key }, bundleKey = 'synex_test:extension' },
      ['synex_test:anchor_b'] = { kind = 'anchor', key = 'synex_test:anchor_b',
        parent = 'synex_test:location_b', bundleKey = 'synex_test:extension' },
      ['synex_test:portal'] = { kind = 'portal', key = 'synex_test:portal',
        mapPackages = { package.key }, bundleKey = 'synex_test:travel' },
    }
    local registry = {
      objects = function() return objects end,
      graph = function() return { children = {
        ['synex_test:location_a'] = { 'synex_test:anchor_a', 'synex_test:door_a' },
        ['synex_test:location_b'] = { 'synex_test:anchor_b' },
      } } end,
      currentRevision = function() return 17 end,
      get = function(key, kind)
        local value = objects[key]
        if value and (kind == nil or value.kind == kind) then return value end
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'missing')
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'started' end })
    local impact = assert(maps.impact(package.key, 1))
    assert(impact.revision == 17 and impact.scannedObjects == 7)
    assert(impact.bundles.count == 5 and #impact.bundles.samples == 1
      and impact.bundles.samples[1] == 'synex_test:doors' and impact.bundles.truncated)
    assert(impact.locations.count == 2 and impact.anchors.count == 2
      and impact.doors.count == 1)
    assert(impact.locations.samples[1] == 'synex_test:location_a'
      and impact.anchors.samples[1] == 'synex_test:anchor_a')
    assert(impact.truncated and not impact.traversalTruncated)
    local invalid, invalidError = maps.impact(package.key, 33)
    assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
    return table.concat({ impact.bundles.count, impact.locations.count,
      impact.anchors.count, impact.doors.count, impact.traversedObjects }, ':')
  `, files);
  assert.equal(result, '5:2:2:1:6');
});

test('map availability shares inherited failure reasons across large descendant chains', async () => {
  const result = await runWorldLua<string>(String.raw`
    local revision, copyCalls = 1, 0
    local package = { kind = 'map_package', key = 'synex_scale:map',
      resourceName = 'synex_scale_asset', expectedResourceState = 'started', required = true,
      locations = { 'synex_scale:node_0001' } }
    local objects = { [package.key] = package }
    local parent
    for index = 1, 4096 do
      local key = ('synex_scale:node_%04d'):format(index)
      objects[key] = { kind = index == 1 and 'location' or 'zone', key = key,
        parent = parent }
      parent = key
    end
    local registry = {
      objects = function() return objects end,
      currentRevision = function() return revision end,
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
    }
    local originalCopy = SynexWorldValidation.copy
    SynexWorldValidation.copy = function(value)
      copyCalls = copyCalls + 1
      return originalCopy(value)
    end
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'stopped' end })
    assert(maps.refresh().requiredUnavailable == 1)
    copyCalls = 0
    local availability = maps.objectAvailability(objects[parent])
    assert(availability.available == false and #availability.reasons == 1)
    assert(availability.reasons[1].resource == 'synex_scale_asset')
    assert(copyCalls <= 16, ('availability copied inherited reasons %d times'):format(copyCalls))
    return table.concat({ #availability.reasons, copyCalls, availability.truncated and 1 or 0 }, ':')
  `, files);
  const [reasons = Number.NaN, copies = Number.NaN, truncated = Number.NaN] = result.split(':').map(Number);
  assert.equal(reasons, 1);
  assert.ok(copies <= 16);
  assert.equal(truncated, 0);
});

test('map impact cache evicts least-recent entries at a fixed bound', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects, scans = {}, 0
    for index = 1, 257 do
      local key = ('synex_scale:map_%03d'):format(index)
      objects[key] = { kind = 'map_package', key = key,
        resourceName = ('synex_scale_asset_%03d'):format(index),
        expectedResourceState = 'started', required = false, locations = {} }
    end
    local registry = {
      objects = function() scans = scans + 1; return objects end,
      graph = function() return { children = {} } end,
      currentRevision = function() return 1 end,
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function() return 'started' end })
    for index = 1, 257 do
      assert(maps.impact(('synex_scale:map_%03d'):format(index), 1))
    end
    local before = scans
    assert(maps.impact('synex_scale:map_001', 1))
    assert(scans == before + 1)
    local cached = scans
    assert(maps.impact('synex_scale:map_001', 1))
    assert(scans == cached)
    return table.concat({ before, scans, cached }, ':')
  `, files);
  const [before = Number.NaN, scans = Number.NaN, cached = Number.NaN] = result.split(':').map(Number);
  assert.equal(scans, before + 1);
  assert.equal(cached, scans);
});
