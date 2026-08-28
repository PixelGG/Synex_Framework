import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/control_provider.lua',
] as const;

test('World control operations validate malformed bounds and report exact graph truncation', async () => {
  const result = await runWorldLua<string>(String.raw`
    SynexWorldFoundation = { isCallable = function(value) return type(value) == 'function' end }
    local parent = { kind = 'location', key = 'synex_test:control_parent',
      revision = 1, label = 'Parent' }
    local children = {
      { kind = 'anchor', key = 'synex_test:control_a', revision = 1, label = 'A' },
      { kind = 'anchor', key = 'synex_test:control_b', revision = 1, label = 'B' },
    }
    local registry = {
      get = function(key) return key == parent.key and parent or nil end,
      objects = function() return { [parent.key] = parent } end,
      children = function(_, _, limit)
        local result = {}
        for index = 1, math.min(#children, limit) do result[index] = children[index] end
        return result
      end,
      listObjects = function() return {}, nil end,
      listBundles = function() return {}, nil end,
    }
    local doctorCalls = 0
    local provider = SynexWorldControlProvider.create({
      foundation = {}, registry = registry, mapRegistry = {},
      instances = { list = function() return {}, nil end },
      diagnostics = { doctor = function(request)
        doctorCalls = doctorCalls + 1
        return { items = {}, requested = request.limit }
      end, summary = function() return { spatial = {}, slices = {}, counts = {} } end },
      contextResolver = { resolve = function() return {} end,
        queryNearby = function() return {} end },
      project = function(object) return { kind = object.kind, key = object.key } end,
    })
    local malformed = {
      function() return provider.operations.inspect({ view = 'point',
        filters = { x = 0, y = 0, z = 0 }, limit = '64' }) end,
      function() return provider.operations.inspect({ view = 'world_graph',
        id = parent.key, limit = -1 }) end,
      function() return provider.operations.findings({ view = 'findings', limit = '50' }) end,
      function() return provider.operations.inspect({ view = 'world_object',
        id = parent.key, limit = 1 }) end,
      function() return provider.operations.search({ query = { kind = 'world_object',
        value = parent.key, mode = 'exact' }, limit = 101 }) end,
    }
    for _, operation in ipairs(malformed) do
      local value, operationError = operation()
      assert(value == nil and operationError.code == 'INVALID_ARGUMENT')
    end
    assert(doctorCalls == 0)
    local exact = assert(provider.operations.inspect({ view = 'world_graph',
      id = parent.key, limit = 2 }))
    assert(#exact.edges == 2 and exact.truncated == false)
    children[3] = { kind = 'anchor', key = 'synex_test:control_c',
      revision = 1, label = 'C' }
    local overflow = assert(provider.operations.inspect({ view = 'world_graph',
      id = parent.key, limit = 2 }))
    assert(#overflow.edges == 2 and overflow.truncated == true)
    return table.concat({ #malformed, tostring(exact.truncated),
      tostring(overflow.truncated), doctorCalls }, ':')
  `, files);
  assert.equal(result, '5:false:true:0');
});

test('map-package control pages bound cold impact scans and expose deferred rows', async () => {
  const result = await runWorldLua<string>(String.raw`
    SynexWorldFoundation = { isCallable = function(value) return type(value) == 'function' end }
    local packages = {}
    for index = 1, 6 do
      packages[index] = { kind = 'map_package',
        key = ('synex_test:map_%02d'):format(index), revision = 1 }
    end
    local coldCalls, cachedCalls = 0, 0
    local provider = SynexWorldControlProvider.create({
      foundation = {},
      registry = {
        listObjects = function(kind) return kind == 'map_package' and packages or {}, nil end,
        listBundles = function() return {}, nil end,
      },
      mapRegistry = {
        get = function() return { available = false } end,
        cachedImpact = function(key)
          cachedCalls = cachedCalls + 1
          if key == packages[5].key then return { packageKey = key } end
          return nil
        end,
        impact = function(key)
          coldCalls = coldCalls + 1
          return { packageKey = key }
        end,
      },
      instances = { list = function() return {}, nil end },
      diagnostics = { summary = function() return {} end, health = function() return {} end },
      contextResolver = {},
      project = function(object) return { key = object.key } end,
    })
    local page = assert(provider.operations.list({ view = 'map_packages', limit = 100 }))
    assert(coldCalls == 2 and cachedCalls == 6 and page.coldImpactAnalyses == 2)
    assert(page.impactComplete == false)
    assert(page.items[1].impact.packageKey == packages[1].key
      and page.items[2].impact.packageKey == packages[2].key)
    assert(page.items[3].impact == nil and page.items[3].impactPending == true)
    assert(page.items[5].impact.packageKey == packages[5].key
      and page.items[5].impactPending == false)
    return table.concat({ coldCalls, cachedCalls, tostring(page.impactComplete),
      tostring(page.items[3].impactPending), page.items[5].impact.packageKey }, ':')
  `, files);
  assert.equal(result, '2:6:false:true:synex_test:map_05');
});
