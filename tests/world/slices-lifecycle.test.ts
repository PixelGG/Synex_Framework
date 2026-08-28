import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const sliceFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/presence.lua',
  'server/slices.lua',
] as const;

const contextSliceFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/geometry.lua',
  'server/context.lua',
  'server/presence.lua',
  'server/slices.lua',
] as const;

test('real WorldContext projects a full ACTIVE instance snapshot into a bounded client slice', async () => {
  const result = await runWorldLua<string>(String.raw`
    local index = {
      queryAt = function() return {}, { candidates = 0, truncated = false } end,
    }
    local registry = {
      spatial = function() return index end,
      currentRevision = function() return 9 end,
      objects = function() return {} end,
      get = function() return nil end,
      kindObjects = function() return {} end,
      bundles = function() return {} end,
    }
    local resolver = SynexWorldContext.create({ registry = registry })
    resolver.queryNearby = function() return {}, { candidates = 0, truncated = false } end
    local instance = {
      instanceId = 'world_instance_00000091', revision = 5, state = 'ACTIVE',
      template = { kind = 'instance_template', key = 'synex_test:template', revision = 3 },
      ownerResource = 'synex_test', ownerEpoch = 7, capacity = 8, members = 1,
      createdAt = '2026-08-28T12:00:00Z', cleanupPolicy = 'manual',
      bucketRef = { bucket = 91, generation = 4 },
    }
    local payload
    local slices = SynexWorldSlices.create({
      registry = registry, contextResolver = resolver,
      mapRegistry = {
        summary = function() return { generation = 2 } end,
        clientRequirements = function() return {}, {} end,
      },
      getDoorState = function() return nil end,
      getState = function() return nil end,
      getPlayers = function() return { '91' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_00000091',
        characterId = 'character_00000091', sourceGeneration = 2 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return instance end,
      triggerClient = function(_, _, value) payload = value end,
      encode = function() return '{}' end,
    })
    assert(slices.updateSource(91, true))
    local projected = assert(payload.context.instance)
    assert(projected.instanceId == instance.instanceId and projected.state == 'ACTIVE'
      and projected.revision == 5 and projected.template.key == 'synex_test:template')
    assert(projected.ownerResource == nil and projected.bucketRef == nil
      and projected.capacity == nil and projected.members == nil)
    return table.concat({ projected.instanceId, projected.state, projected.revision }, ':')
  `, contextSliceFiles);

  assert.equal(result, 'world_instance_00000091:ACTIVE:5');
});

test('server slices invalidate on definition/map generation and preserve definition revisions', async () => {
  const result = await runWorldLua<string>(String.raw`
    local registryRevision, mapGeneration = 20, 3
    local location = { kind = 'location', key = 'synex_test:station', revision = 12,
      bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
    local door = { kind = 'door', key = 'synex_test:station.door', revision = 17,
      bundleKey = 'synex_test:bundle', parent = location.key,
      position = { x = 1, y = 0, z = 0 }, label = 'Door', tags = {},
      defaultState = 'LOCKED', leaves = {
        { id = 'front', model = 1234, doorHash = 4321,
          position = { x = 1, y = 0, z = 0 } },
      } }
    local template = { kind = 'instance_template', key = 'synex_test:template', revision = 19,
      iplBundles = { 'synex_test:instance.ipls' } }
    local objects = { [location.key] = location, [door.key] = door,
      [template.key] = template }
    local registry = {
      currentRevision = function() return registryRevision end,
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
      kindObjects = function() return {} end,
      bundles = function() return {
        ['synex_test:bundle'] = { revision = 29 },
      } end,
    }
    local contextResolver = {
      resolve = function(_, instance)
        return { location = { kind = 'location', key = location.key,
          revision = location.revision }, instance = instance }
      end,
      queryNearby = function()
        return { { object = location, distance = 0 }, { object = door, distance = 1 } }
      end,
    }
    local transported, mapInputs = {}, {}
    local mapRegistry = {
      summary = function() return { generation = mapGeneration } end,
      clientRequirements = function(values, instance)
        mapInputs[#mapInputs + 1] = { values = values, instance = instance }
        return { { name = 'global_ipl', refCount = 1 },
          { name = 'instance_ipl', refCount = 1 } }, {
          { interiorId = 7, name = 'fixture_set', refCount = 1 },
        }
      end,
    }
    local instance = { instanceId = 'world_instance_00000001',
      template = { kind = 'instance_template', key = template.key, revision = template.revision },
      state = 'READY', revision = 4, ownerResource = 'synex_test', ownerEpoch = 7,
      capacity = 32, bucketRef = { bucket = 17, generation = 'bucket_generation_17' } }
    local slices = SynexWorldSlices.create({
      registry = registry,
      contextResolver = contextResolver,
      mapRegistry = mapRegistry,
      getDoorState = function() return { state = 'UNLOCKED', version = 6,
        definitionRevision = door.revision } end,
      getState = function()
        return SynexWorldValidation.failure('WORLD_STATE_NOT_FOUND', 'not materialized')
      end,
      getPlayers = function() return { '41' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_00000041',
        characterId = 'character_00000041',
        sourceGeneration = 2 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return instance end,
      triggerClient = function(source, event, payload)
        transported[#transported + 1] = { source = source, event = event, payload = payload }
      end,
      encode = function() return '{}' end,
    })

    local first = assert(slices.updateSource(41, true))
    local firstPayload = transported[1].payload
    assert(first.revision == 1 and firstPayload.revision == 1)
    assert(firstPayload.context.instance.instanceId == instance.instanceId
      and firstPayload.context.instance.template.kind == 'instance_template'
      and firstPayload.context.instance.state == 'READY'
      and firstPayload.context.instance.revision == 4
      and firstPayload.context.instance.bucketRef == nil
      and firstPayload.context.instance.ownerEpoch == nil
      and firstPayload.context.instance.capacity == nil)
    assert(firstPayload.doors[1].revision == 17
      and firstPayload.doors[1].revision > firstPayload.revision)
    assert(firstPayload.doors[1].state == 'UNLOCKED'
      and firstPayload.doors[1].stateVersion == 6)
    assert(firstPayload.bundleRevisions['synex_test:bundle'] == 29)
    assert(#firstPayload.ipls == 2 and firstPayload.ipls[2].name == 'instance_ipl'
      and firstPayload.ipls[2].refCount == 1)
    local sawTemplate = false
    for _, value in ipairs(mapInputs[1].values) do
      if value and value.key == template.key then sawTemplate = true end
    end
    assert(sawTemplate and mapInputs[1].instance.instanceId == instance.instanceId)

    assert(slices.updateSource(41, false) == false and #transported == 1)
    slices.invalidateAll()
    assert(slices.updateSource(41, false).revision == 2 and #transported == 2)
    mapGeneration = 4
    assert(slices.updateSource(41, false).revision == 3 and #transported == 3)
    registryRevision = 21
    assert(slices.updateSource(41, false).revision == 4 and #transported == 4)

    local delivered = slices.doorChanged(door.key, { state = 'LOCKED', version = 7,
      definitionRevision = door.revision })
    assert(delivered == 1 and #transported == 5)
    local delta = transported[5].payload
    assert(delta.revision == 5 and delta.definitionRevision == 17
      and delta.stateVersion == 7 and delta.state == 'LOCKED')
    slices.remove(41)
    assert(slices.doorChanged(door.key, { state = 'UNLOCKED', version = 8,
      definitionRevision = door.revision }) == 0)
    return table.concat({ firstPayload.revision, firstPayload.doors[1].revision,
      transported[2].payload.revision, transported[3].payload.revision,
      transported[4].payload.revision,
      delta.revision, delivered }, ':')
  `, sliceFiles);

  assert.equal(result, '1:17:2:3:4:5:1');
});

test('server context and presence advance across boundaries inside one spatial cell', async () => {
  const result = await runWorldLua<string>(String.raw`
    local clock, position = 0, { x = 1, y = 1, z = 1 }
    local resolveCalls, nearbyCalls, transported, events = 0, 0, {}, {}
    local alpha = { kind = 'location', key = 'synex_test:alpha', revision = 4,
      bundleKey = 'synex_test:bundle', position = { x = 1, y = 1, z = 1 }, tags = {} }
    local beta = { kind = 'location', key = 'synex_test:beta', revision = 4,
      bundleKey = 'synex_test:bundle', position = { x = 10, y = 1, z = 1 }, tags = {} }
    local objects = { [alpha.key] = alpha, [beta.key] = beta }
    local function activeLocation() return position.x < 5 and alpha or beta end
    local registry = {
      currentRevision = function() return 4 end,
      get = function(key) return objects[key] end,
      kindObjects = function() return {} end,
      bundles = function() return { ['synex_test:bundle'] = { revision = 4 } } end,
    }
    local contextResolver = {
      resolve = function()
        resolveCalls = resolveCalls + 1
        local location = activeLocation()
        return { schemaVersion = 1, authority = 'VERIFIED', revision = 4,
          regions = {}, zones = {},
          location = { kind = 'location', key = location.key, revision = 4 } }
      end,
      queryNearby = function()
        nearbyCalls = nearbyCalls + 1
        return { { object = activeLocation(), distance = 0 } }
      end,
    }
    local presence = SynexWorldPresence.create({
      now = function() return clock end,
      debounceMs = 500,
      minimumDwellMs = 0,
      emit = function(name, payload)
        events[#events + 1] = { name = name, ref = payload.ref }
      end,
    })
    local slices = SynexWorldSlices.create({
      registry = registry, contextResolver = contextResolver,
      mapRegistry = {
        summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end,
      },
      getDoorState = function() return nil end,
      getState = function() return SynexWorldValidation.failure(
        'WORLD_STATE_NOT_FOUND', 'not materialized') end,
      getPlayers = function() return { '41' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_41',
        characterId = 'character_00000041', sourceGeneration = 2 } end,
      getPosition = function() return position end,
      getInstance = function() return nil end,
      triggerClient = function(_, event, payload)
        transported[#transported + 1] = { event = event, payload = payload }
      end,
      encode = function() return '{}' end,
      presence = presence,
    })

    assert(slices.updateSource(41, false).revision == 1)
    clock = 600
    assert(slices.updateSource(41, false) == false)
    assert(#events == 1 and events[1].name == 'synex.world.location.entered'
      and events[1].ref == alpha.key)

    position = { x = 10, y = 1, z = 1 }
    clock = 700
    assert(math.floor(position.x / SynexWorldLimits.fineCellSize) == 0)
    assert(slices.updateSource(41, false).revision == 2)
    clock = 1200
    assert(slices.updateSource(41, false) == false)
    assert(#events == 3 and events[2].name == 'synex.world.location.left'
      and events[2].ref == alpha.key
      and events[3].name == 'synex.world.location.entered'
      and events[3].ref == beta.key)
    assert(#transported == 2 and resolveCalls == 6 and nearbyCalls == 2)
    return table.concat({ #transported, resolveCalls, nearbyCalls,
      #events, transported[2].payload.context.location.key }, ':')
  `, sliceFiles);

  assert.equal(result, '2:6:2:3:synex_test:beta');
});

test('server slices refresh bounded nearby content after same-cell movement', async () => {
  const result = await runWorldLua<string>(String.raw`
    local position = { x = 1, y = 1, z = 1 }
    local nearbyCalls, transported, radii = 0, {}, {}
    local alpha = { kind = 'anchor', key = 'synex_test:alpha', revision = 3,
      bundleKey = 'synex_test:bundle', position = { x = 2, y = 1, z = 1 },
      radius = 0, tags = {} }
    local beta = { kind = 'anchor', key = 'synex_test:beta', revision = 3,
      bundleKey = 'synex_test:bundle', position = { x = 12, y = 1, z = 1 },
      radius = 0, tags = {} }
    local registry = {
      currentRevision = function() return 3 end,
      get = function(key) return key == alpha.key and alpha or key == beta.key and beta or nil end,
      kindObjects = function() return {} end,
      bundles = function() return { ['synex_test:bundle'] = { revision = 3 } } end,
    }
    local contextResolver = {
      resolve = function() return { schemaVersion = 1, authority = 'VERIFIED',
        revision = 3, regions = {}, zones = {} } end,
      queryNearby = function(_, radius)
        nearbyCalls = nearbyCalls + 1
        radii[#radii + 1] = radius
        local object = position.x < 8 and alpha or beta
        return { { object = object, distance = math.abs(object.position.x - position.x) } }
      end,
    }
    local slices = SynexWorldSlices.create({
      registry = registry, contextResolver = contextResolver,
      mapRegistry = {
        summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end,
      },
      getDoorState = function() return nil end,
      getState = function() return SynexWorldValidation.failure(
        'WORLD_STATE_NOT_FOUND', 'not materialized') end,
      getPlayers = function() return { '41' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_41',
        characterId = 'character_00000041', sourceGeneration = 2 } end,
      getPosition = function() return position end,
      getInstance = function() return nil end,
      triggerClient = function(_, _, payload) transported[#transported + 1] = payload end,
      encode = function() return '{}' end,
    })

    assert(slices.updateSource(41, false).revision == 1)
    position = { x = 3, y = 1, z = 1 }
    assert(slices.updateSource(41, false) == false)
    position = { x = 10, y = 1, z = 1 }
    assert(math.floor(position.x / SynexWorldLimits.fineCellSize) == 0)
    assert(slices.updateSource(41, false).revision == 2)
    assert(#transported == 2 and nearbyCalls == 2)
    assert(transported[1].anchors[1].key == alpha.key
      and transported[2].anchors[1].key == beta.key)
    assert(transported[2].anchors[1].distance == 2)
    assert(radii[1] == SynexWorldLimits.sliceQueryRadius
      + SynexWorldLimits.sliceMovementThreshold and radii[2] == radii[1])
    return table.concat({ #transported, nearbyCalls,
      transported[2].anchors[1].key, transported[2].anchors[1].distance }, ':')
  `, sliceFiles);

  assert.equal(result, '2:2:synex_test:beta:2');
});

test('client slice replacement across cells A, B, and C removes old data and preserves bounds', async () => {
  const result = await runWorldLua<string>(String.raw`
    local position = { x = 1, y = 0, z = 0 }
    local transported, encodedSizes = {}, {}
    local anchors = {
      { kind = 'anchor', key = 'synex_test:cell_a', revision = 7,
        bundleKey = 'synex_test:bundle', position = { x = 1, y = 0, z = 0 },
        radius = 1, tags = {} },
      { kind = 'anchor', key = 'synex_test:cell_b', revision = 7,
        bundleKey = 'synex_test:bundle', position = { x = 40, y = 0, z = 0 },
        radius = 1, tags = {} },
      { kind = 'anchor', key = 'synex_test:cell_c', revision = 7,
        bundleKey = 'synex_test:bundle', position = { x = 70, y = 0, z = 0 },
        radius = 1, tags = {} },
    }
    local byKey = {}
    for _, anchor in ipairs(anchors) do byKey[anchor.key] = anchor end
    local function selected()
      if position.x < 32 then return anchors[1] end
      if position.x < 64 then return anchors[2] end
      return anchors[3]
    end
    local slices = SynexWorldSlices.create({
      registry = {
        currentRevision = function() return 7 end,
        get = function(key) return byKey[key] end,
        kindObjects = function() return {} end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 7 } } end,
      },
      contextResolver = {
        resolve = function() return { schemaVersion = 1, authority = 'VERIFIED',
          revision = 7, regions = {}, zones = {} } end,
        queryNearby = function()
          local anchor = selected()
          return { { object = anchor, distance = 0 },
            { object = anchor, distance = 0 } }
        end,
      },
      mapRegistry = {
        summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end,
      },
      getDoorState = function() return nil end,
      getState = function() return nil end,
      getPlayers = function() return { '94' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_00000094',
        characterId = 'character_00000094', sourceGeneration = 1 } end,
      getPosition = function() return position end,
      getInstance = function() return nil end,
      triggerClient = function(_, _, payload) transported[#transported + 1] = payload end,
      encode = function()
        local encoded = string.rep('x', 256)
        encodedSizes[#encodedSizes + 1] = #encoded
        return encoded
      end,
    })
    assert(slices.updateSource(94, true).revision == 1)
    position = { x = 40, y = 0, z = 0 }
    assert(slices.updateSource(94, false).revision == 2)
    position = { x = 70, y = 0, z = 0 }
    assert(slices.updateSource(94, false).revision == 3)
    local expected = { 'synex_test:cell_a', 'synex_test:cell_b', 'synex_test:cell_c' }
    for index, payload in ipairs(transported) do
      assert(payload.revision == index and #payload.anchors == 1
        and payload.anchors[1].key == expected[index])
      assert(encodedSizes[index] <= SynexWorldLimits.maximumSliceBytes)
    end
    return table.concat({ #transported, transported[1].anchors[1].key,
      transported[2].anchors[1].key, transported[3].anchors[1].key,
      transported[3].revision, encodedSizes[3] }, ':')
  `, sliceFiles);

  assert.equal(result, '3:synex_test:cell_a:synex_test:cell_b:synex_test:cell_c:3:256');
});

test('server slice delivery is fenced against source reuse during state reads', async () => {
  const result = await runWorldLua<string>(String.raw`
    local reused, transported = false, 0
    local location = { kind = 'location', key = 'synex_test:location', revision = 5,
      bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
    local stateDefinition = { kind = 'world_state_definition',
      key = 'synex_test:lights', revision = 5, scope = 'global' }
    local objects = { [location.key] = location, [stateDefinition.key] = stateDefinition }
    local slices = SynexWorldSlices.create({
      registry = {
        currentRevision = function() return 5 end,
        get = function(key) return objects[key] end,
        kindObjects = function(kind)
          return kind == 'world_state_definition' and { stateDefinition } or {}
        end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 5 } } end,
      },
      contextResolver = {
        resolve = function() return { schemaVersion = 1, authority = 'VERIFIED',
          revision = 5, regions = {}, zones = {},
          location = { kind = 'location', key = location.key, revision = 5 } } end,
        queryNearby = function() return { { object = location, distance = 0 } } end,
      },
      mapRegistry = {
        summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end,
      },
      getDoorState = function() return nil end,
      getState = function()
        reused = true
        return { key = stateDefinition.key,
          scope = { type = 'global', ref = 'global' }, valueType = 'boolean',
          value = true, version = 1, definitionRevision = 5, persistent = true }
      end,
      getPlayers = function() return { '41' } end,
      getPlayer = function()
        if reused then return { state = 'ACTIVE', id = 'session_new',
          characterId = 'character_new', sourceGeneration = 8 } end
        return { state = 'ACTIVE', id = 'session_old',
          characterId = 'character_old', sourceGeneration = 7 }
      end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function() transported = transported + 1 end,
      encode = function() return '{}' end,
    })
    local delivered, deliveryError = slices.updateSource(41, false)
    assert(delivered == nil and deliveryError.code == 'STALE_RESOURCE')
    assert(transported == 0 and slices.summary().clients == 0)
    return deliveryError.code .. ':' .. transported
  `, sliceFiles);

  assert.equal(result, 'STALE_RESOURCE:0');
});

test('slice State index and scope invalidation stay proportional to relevant subscriptions', async () => {
  const result = await runWorldLua<string>(String.raw`
    local locations = {
      [71] = { kind = 'location', key = 'synex_test:alpha', revision = 9,
        bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} },
      [72] = { kind = 'location', key = 'synex_test:beta', revision = 9,
        bundleKey = 'synex_test:bundle', position = { x = 64, y = 0, z = 0 }, tags = {} },
    }
    local definitions = {
      { kind = 'world_state_definition', key = 'synex_test:weather', revision = 9,
        scope = 'location' },
      { kind = 'world_state_definition', key = 'synex_test:alpha_lights', revision = 9,
        scope = 'location', parent = locations[71].key },
      { kind = 'world_state_definition', key = 'synex_test:beta_lights', revision = 9,
        scope = 'location', parent = locations[72].key },
    }
    for index = 1, 500 do
      definitions[#definitions + 1] = { kind = 'world_state_definition',
        key = ('synex_test:irrelevant_%03d'):format(index), revision = 9,
        scope = 'location', parent = ('synex_test:other_%03d'):format(index) }
    end
    local indexCalls, stateCalls, sends = 0, 0, 0
    local slices = SynexWorldSlices.create({
      registry = {
        currentRevision = function() return 9 end,
        kindObjects = function(kind)
          indexCalls = indexCalls + 1
          return kind == 'world_state_definition' and definitions or {}
        end,
        get = function(key)
          for _, location in pairs(locations) do if key == location.key then return location end end
        end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 9 } } end,
      },
      contextResolver = {
        resolve = function(position)
          local location = position.x < 32 and locations[71] or locations[72]
          return { schemaVersion = 1, authority = 'VERIFIED', revision = 9,
            regions = {}, zones = {}, location = { kind = location.kind,
              key = location.key, revision = location.revision } }
        end,
        queryNearby = function(position)
          local location = position.x < 32 and locations[71] or locations[72]
          return { { object = location, distance = 0 } }
        end,
      },
      mapRegistry = { summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end },
      getDoorState = function() return nil end,
      getState = function(request)
        stateCalls = stateCalls + 1
        return { key = request.key, scope = { type = 'location', ref = request.scopeRef },
          valueType = 'boolean', value = true, version = 1,
          definitionRevision = 9, persistent = true }
      end,
      getPlayers = function() return { '71', '72' } end,
      getPlayer = function(source) return { state = 'ACTIVE', id = 'session_' .. source,
        characterId = 'character_' .. source, sourceGeneration = 1 } end,
      getPosition = function(source) return source == 71 and { x = 0, y = 0, z = 0 }
        or { x = 64, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function() sends = sends + 1 end,
      encode = function() return '{}' end,
    })
    assert(slices.updateSource(71, false) and slices.updateSource(72, false))
    assert(indexCalls == 1 and stateCalls == 4 and sends == 2)
    assert(slices.stateChanged({ scope = { type = 'location', ref = locations[71].key } }) == 1)
    assert(slices.updateSource(71, false) and slices.updateSource(72, false) == false)
    assert(indexCalls == 1 and stateCalls == 6 and sends == 3)
    assert(slices.stateChanged({ scope = { type = 'global', ref = 'global' } }) == 2)
    assert(slices.updateAll(false).updated == 2)
    assert(indexCalls == 1 and stateCalls == 10 and sends == 5)
    return table.concat({ indexCalls, stateCalls, sends }, ':')
  `, sliceFiles);
  assert.equal(result, '1:10:5');
});

test('slice state selection follows the primary hierarchy and tracks missing projected scopes', async () => {
  const result = await runWorldLua<string>(String.raw`
    local regionA = { kind = 'region', key = 'synex_test:region_a', revision = 1,
      bundleKey = 'synex_test:bundle', tags = {} }
    local regionB = { kind = 'region', key = 'synex_test:region_b', revision = 1,
      bundleKey = 'synex_test:bundle', tags = {} }
    local locationB = { kind = 'location', key = 'synex_test:location_b', revision = 1,
      bundleKey = 'synex_test:bundle', parent = regionB.key,
      position = { x = 0, y = 0, z = 0 }, tags = {} }
    local foreign = { kind = 'world_state_definition', key = 'synex_test:foreign',
      revision = 1, scope = 'location', parent = regionA.key }
    local missing = { kind = 'world_state_definition', key = 'synex_test:missing',
      revision = 1, scope = 'location', parent = locationB.key }
    local objects = { [regionA.key] = regionA, [regionB.key] = regionB,
      [locationB.key] = locationB }
    local materialized, stateCalls, foreignCalls, sends = false, 0, 0, 0
    local context = { schemaVersion = 1, authority = 'VERIFIED', revision = 1,
      region = { kind = 'region', key = regionB.key, revision = 1 },
      location = { kind = 'location', key = locationB.key, revision = 1 },
      regions = {
        { kind = 'region', key = regionB.key, revision = 1 },
        { kind = 'region', key = regionA.key, revision = 1 },
      }, zones = {} }
    local slices = SynexWorldSlices.create({
      registry = {
        currentRevision = function() return 1 end,
        kindObjects = function(kind)
          return kind == 'world_state_definition' and { foreign, missing } or {}
        end,
        get = function(key) return objects[key] end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end,
      },
      contextResolver = {
        resolve = function() return context end,
        queryNearby = function() return { { object = locationB, distance = 0 } } end,
      },
      mapRegistry = { summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end },
      getDoorState = function() return nil end,
      getState = function(request)
        if request.key == foreign.key then
          foreignCalls = foreignCalls + 1
          return SynexWorldValidation.failure('WORLD_REFERENCE_INVALID', 'foreign branch')
        end
        stateCalls = stateCalls + 1
        if not materialized then
          return SynexWorldValidation.failure('WORLD_STATE_NOT_FOUND', 'missing')
        end
        return { key = missing.key, scope = { type = 'location', ref = locationB.key },
          valueType = 'boolean', value = true, version = 1,
          definitionRevision = 1, persistent = false }
      end,
      getPlayers = function() return { '82' } end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_82',
        characterId = 'character_82', sourceGeneration = 1 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function() sends = sends + 1 end,
      encode = function() return '{}' end,
    })
    assert(slices.updateSource(82, false) and sends == 1 and stateCalls == 1
      and foreignCalls == 0)
    assert(slices.updateSource(82, false) == false)
    assert(slices.stateChanged({ scope = { type = 'location', ref = regionA.key } }) == 0)
    assert(slices.stateChanged({ scope = { type = 'location', ref = locationB.key } }) == 1)
    materialized = true
    assert(slices.updateSource(82, false) and sends == 2 and stateCalls == 2
      and foreignCalls == 0)
    return table.concat({ sends, stateCalls, foreignCalls }, ':')
  `, sliceFiles);
  assert.equal(result, '2:2:0');
});

test('region state projection includes each bounded overlapping region without crossing other scopes', async () => {
  const result = await runWorldLua<string>(String.raw`
    local regionA = { kind = 'region', key = 'synex_test:overlap_a', revision = 1,
      bundleKey = 'synex_test:bundle', tags = {} }
    local regionB = { kind = 'region', key = 'synex_test:overlap_b', revision = 1,
      bundleKey = 'synex_test:bundle', tags = {} }
    local location = { kind = 'location', key = 'synex_test:overlap_location', revision = 1,
      bundleKey = 'synex_test:bundle', parent = regionB.key,
      position = { x = 0, y = 0, z = 0 }, tags = {} }
    local shared = { kind = 'world_state_definition', key = 'synex_test:region_shared',
      revision = 1, scope = 'region' }
    local onlyA = { kind = 'world_state_definition', key = 'synex_test:region_a_only',
      revision = 1, scope = 'region', parent = regionA.key }
    local objects = { [regionA.key] = regionA, [regionB.key] = regionB,
      [location.key] = location }
    local reads, sends, lastPayload = {}, 0, nil
    local context = { schemaVersion = 1, authority = 'VERIFIED', revision = 1,
      region = { kind = 'region', key = regionB.key, revision = 1 },
      location = { kind = 'location', key = location.key, revision = 1 },
      regions = {
        { kind = 'region', key = regionB.key, revision = 1 },
        { kind = 'region', key = regionA.key, revision = 1 },
      }, zones = {} }
    local slices = SynexWorldSlices.create({
      registry = { currentRevision = function() return 1 end,
        kindObjects = function(kind)
          return kind == 'world_state_definition' and { shared, onlyA } or {}
        end,
        get = function(key) return objects[key] end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end },
      contextResolver = { resolve = function() return context end,
        queryNearby = function() return { { object = location, distance = 0 } } end },
      mapRegistry = { summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end },
      getDoorState = function() return nil end,
      getState = function(request)
        local identity = request.key .. '@' .. tostring(request.scopeRef)
        reads[identity] = (reads[identity] or 0) + 1
        return { key = request.key, scope = { type = 'region', ref = request.scopeRef },
          valueType = 'boolean', value = true, version = 1,
          definitionRevision = 1, persistent = false }
      end,
      getPlayers = function() return {} end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_region',
        characterId = 'character_region', sourceGeneration = 1 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function(_, _, payload) sends, lastPayload = sends + 1, payload end,
      encode = function() return '{}' end,
    })
    assert(slices.updateSource(86, false) and #lastPayload.state == 3 and sends == 1)
    assert(reads[shared.key .. '@' .. regionA.key] == 1
      and reads[shared.key .. '@' .. regionB.key] == 1
      and reads[onlyA.key .. '@' .. regionA.key] == 1
      and reads[onlyA.key .. '@' .. regionB.key] == nil)
    assert(slices.stateChanged({ scope = { type = 'region', ref = 'synex_test:other' } }) == 0)
    assert(slices.stateChanged({ scope = { type = 'region', ref = regionA.key } }) == 1)
    assert(slices.updateSource(86, false) and sends == 2)
    return table.concat({ #lastPayload.state, sends,
      reads[shared.key .. '@' .. regionA.key], reads[shared.key .. '@' .. regionB.key] }, ':')
  `, sliceFiles);
  assert.equal(result, '3:2:2:2');
});

test('door projection errors preserve old client truth instead of sending defaults', async () => {
  const result = await runWorldLua<string>(String.raw`
    local location = { kind = 'location', key = 'synex_test:door_location', revision = 1,
      bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
    local door = { kind = 'door', key = 'synex_test:failing_door', revision = 1,
      bundleKey = 'synex_test:bundle', parent = location.key, tags = {},
      position = { x = 0, y = 0, z = 0 }, defaultState = 'UNLOCKED', leaves = {} }
    local objects, failureCode, sends = { [location.key] = location, [door.key] = door },
      'DATABASE_UNAVAILABLE', 0
    local slices = SynexWorldSlices.create({
      registry = { currentRevision = function() return 1 end,
        kindObjects = function() return {} end,
        get = function(key) return objects[key] end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end },
      contextResolver = { resolve = function() return { regions = {}, zones = {},
          location = { kind = location.kind, key = location.key, revision = 1 } } end,
        queryNearby = function() return {
          { object = location, distance = 0 }, { object = door, distance = 0 },
        } end },
      mapRegistry = { summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end },
      getDoorState = function()
        return SynexWorldValidation.failure(failureCode, 'fixture persistence failure', true)
      end,
      getState = function() return nil end, getPlayers = function() return {} end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_83',
        characterId = 'character_83', sourceGeneration = 1 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function() sends = sends + 1 end,
      encode = function() return '{}' end,
    })
    local value, databaseError = slices.updateSource(83, true)
    assert(value == nil and databaseError.code == 'DATABASE_UNAVAILABLE' and sends == 0)
    failureCode = 'STATE_SCHEMA_MISMATCH'
    value, databaseError = slices.updateSource(83, true)
    assert(value == nil and databaseError.code == 'STATE_SCHEMA_MISMATCH' and sends == 0)
    assert(slices.summary().clients == 0)
    return databaseError.code .. ':' .. sends
  `, sliceFiles);
  assert.equal(result, 'STATE_SCHEMA_MISMATCH:0');
});

test('slice delivery discards mixed registry, map, instance and position generations', async () => {
  const result = await runWorldLua<string>(String.raw`
    local failures = {}
    for _, mode in ipairs({ 'registry', 'map', 'instance', 'position' }) do
      local registryRevision, mapGeneration, sent = 1, 1, 0
      local position = { x = 0, y = 0, z = 0 }
      local instance = { instanceId = 'world_instance_00000084', revision = 1, state = 'READY' }
      local locationA = { kind = 'location', key = 'synex_test:slice_a', revision = 1,
        bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
      local locationB = { kind = 'location', key = 'synex_test:slice_b', revision = 1,
        bundleKey = 'synex_test:bundle', position = { x = 64, y = 0, z = 0 }, tags = {} }
      local definition = { kind = 'world_state_definition', key = 'synex_test:slice_state',
        revision = 1, scope = 'global' }
      local objects = { [locationA.key] = locationA, [locationB.key] = locationB }
      local slices = SynexWorldSlices.create({
        registry = { currentRevision = function() return registryRevision end,
          kindObjects = function(kind)
            return kind == 'world_state_definition' and { definition } or {}
          end,
          get = function(key) return objects[key] end,
          bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end },
        contextResolver = { resolve = function(currentPosition)
            local location = currentPosition.x < 32 and locationA or locationB
            return { regions = {}, zones = {}, location = {
              kind = location.kind, key = location.key, revision = location.revision } }
          end,
          queryNearby = function() return { { object = locationA, distance = 0 } } end },
        mapRegistry = { summary = function() return { generation = mapGeneration } end,
          clientRequirements = function() return {}, {} end },
        getDoorState = function() return nil end,
        getState = function()
          if mode == 'registry' then registryRevision = 2
          elseif mode == 'map' then mapGeneration = 2
          elseif mode == 'instance' then
            instance = { instanceId = instance.instanceId, revision = 2, state = 'READY' }
          else position = { x = 64, y = 0, z = 0 } end
          return { key = definition.key, scope = { type = 'global', ref = 'global' },
            valueType = 'boolean', value = true, version = 1,
            definitionRevision = 1, persistent = false }
        end,
        getPlayers = function() return {} end,
        getPlayer = function() return { state = 'ACTIVE', id = 'session_84',
          characterId = 'character_84', sourceGeneration = 1 } end,
        getPosition = function() return position end,
        getInstance = function() return instance end,
        triggerClient = function() sent = sent + 1 end,
        encode = function() return '{}' end,
      })
      local value, staleError = slices.updateSource(84, true)
      assert(value == nil and staleError.code == 'STALE_RESOURCE' and sent == 0, mode)
      failures[#failures + 1] = staleError.code
    end
    return table.concat(failures, ':')
  `, sliceFiles);
  assert.equal(result, Array(4).fill('STALE_RESOURCE').join(':'));
});

test('slice delivery cannot overwrite state or door mutations that occur during its build', async () => {
  const result = await runWorldLua<string>(String.raw`
    local outcomes = {}
    for _, mode in ipairs({ 'state', 'door' }) do
      local location = { kind = 'location', key = 'synex_test:authority_location', revision = 1,
        bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
      local door = { kind = 'door', key = 'synex_test:authority_door', revision = 1,
        bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {},
        defaultState = 'LOCKED', leaves = {} }
      local definition = { kind = 'world_state_definition',
        key = 'synex_test:authority_state', revision = 1, scope = 'global' }
      local objects = { [location.key] = location, [door.key] = door }
      local sent, changed, slices = 0, false, nil
      slices = SynexWorldSlices.create({
        registry = { currentRevision = function() return 1 end,
          kindObjects = function(kind)
            return kind == 'world_state_definition' and { definition } or {}
          end,
          get = function(key) return objects[key] end,
          bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end },
        contextResolver = { resolve = function() return { regions = {}, zones = {},
            location = { kind = location.kind, key = location.key, revision = 1 } } end,
          queryNearby = function() return {
            { object = location, distance = 0 }, { object = door, distance = 0 },
          } end },
        mapRegistry = { summary = function() return { generation = 1 } end,
          clientRequirements = function() return {}, {} end },
        getDoorState = function()
          if mode == 'door' and not changed then
            changed = true
            slices.doorChanged(door.key, { state = 'UNLOCKED', version = 2,
              definitionRevision = door.revision })
          end
          return { state = 'LOCKED', version = 1, definitionRevision = door.revision }
        end,
        getState = function()
          if mode == 'state' and not changed then
            changed = true
            slices.stateChanged({ scope = { type = 'global', ref = 'global' } })
          end
          return { key = definition.key, scope = { type = 'global', ref = 'global' },
            valueType = 'boolean', value = false, version = 1,
            definitionRevision = definition.revision, persistent = false }
        end,
        getPlayers = function() return {} end,
        getPlayer = function() return { state = 'ACTIVE', id = 'session_authority',
          characterId = 'character_authority', sourceGeneration = 1 } end,
        getPosition = function() return { x = 0, y = 0, z = 0 } end,
        getInstance = function() return nil end,
        triggerClient = function() sent = sent + 1 end,
        encode = function() return '{}' end,
      })
      local value, staleError = slices.updateSource(85, true)
      assert(value == nil and staleError.code == 'STALE_RESOURCE' and sent == 0, mode)
      outcomes[#outcomes + 1] = staleError.code
    end
    return table.concat(outcomes, ':')
  `, sliceFiles);
  assert.equal(result, 'STALE_RESOURCE:STALE_RESOURCE');
});

test('slice transport rejects payloads above the single-event byte budget', async () => {
  const result = await runWorldLua<string>(String.raw`
    local location = { kind = 'location', key = 'synex_test:budget', revision = 1,
      bundleKey = 'synex_test:bundle', position = { x = 0, y = 0, z = 0 }, tags = {} }
    local sent = 0
    local slices = SynexWorldSlices.create({
      registry = { currentRevision = function() return 1 end,
        kindObjects = function() return {} end,
        get = function() return location end,
        bundles = function() return { ['synex_test:bundle'] = { revision = 1 } } end },
      contextResolver = { resolve = function() return { regions = {}, zones = {},
          location = { kind = 'location', key = location.key, revision = 1 } } end,
        queryNearby = function() return { { object = location, distance = 0 } } end },
      mapRegistry = { summary = function() return { generation = 1 } end,
        clientRequirements = function() return {}, {} end },
      getDoorState = function() return nil end, getState = function() return nil end,
      getPlayers = function() return {} end,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_budget',
        characterId = 'character_budget', sourceGeneration = 1 } end,
      getPosition = function() return { x = 0, y = 0, z = 0 } end,
      getInstance = function() return nil end,
      triggerClient = function() sent = sent + 1 end,
      encode = function() return string.rep('x', SynexWorldLimits.maximumSliceBytes + 1) end,
    })
    local value, budgetError = slices.updateSource(81, true)
    assert(value == nil and budgetError.code == 'QUERY_LIMIT_EXCEEDED' and sent == 0)
    assert(SynexWorldLimits.maximumSliceBytes <= 64 * 1024)
    return budgetError.code .. ':' .. SynexWorldLimits.maximumSliceBytes
  `, sliceFiles);
  assert.equal(result, 'QUERY_LIMIT_EXCEEDED:49152');
});
