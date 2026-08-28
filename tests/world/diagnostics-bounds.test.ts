import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/diagnostics.lua',
] as const;

test('Doctor rotates over fixed static and authority budgets without catalog scans', async () => {
  const result = await runWorldLua<string>(String.raw`
    local packages, anchors, bundles = {}, {}, {}
    for index = 1, 300 do
      packages[index] = { kind = 'map_package',
        key = ('synex_scale:map_%03d'):format(index),
        resourceName = ('synex_scale_asset_%03d'):format(index), required = true }
    end
    for index = 1, 300 do
      anchors[index] = { kind = 'anchor', key = ('synex_scale:anchor_%03d'):format(index),
        entityRef = { id = ('entity_%03d'):format(index) } }
    end
    local registry = {
      currentRevision = function() return 7 end,
      bundles = function() return bundles end,
      kindObjects = function(kind)
        if kind == 'map_package' then return packages end
        if kind == 'anchor' then return anchors end
        return {}
      end,
      objects = function() error('Doctor must use bounded kind indexes') end,
      spatial = function() return { diagnostics = function()
        return { maximumCandidates = 0 }
      end } end,
    }
    local statusKeys, impactCalls, resolvedKeys = {}, 0, {}
    local mapRegistry = {
      get = function(key)
        statusKeys[#statusKeys + 1] = key
        return { available = false, state = 'stopped' }
      end,
      impact = function(key)
        impactCalls = impactCalls + 1
        return { packageKey = key, bundles = { count = 0, samples = {} },
          locations = { count = 0, samples = {} },
          anchors = { count = 0, samples = {} }, doors = { count = 0, samples = {} } }
      end,
      summary = function() return {} end,
    }
    local diagnostics = SynexWorldDiagnostics.create({
      foundation = {
        healthSnapshot = function() return { state = 'READY' } end,
        utc = function() return '2026-08-27T00:00:00Z' end,
      }, registry = registry, mapRegistry = mapRegistry,
      instances = {
        list = function() return {}, nil end,
        summary = function() return { total = 0 } end,
      },
      slices = { summary = function() return { bytes = 0, clients = 0 } end },
      outbox = { status = function() return { dead = 0 } end },
      database = {}, getResourceState = function() return 'started' end,
      resolveEntity = function(reference)
        resolvedKeys[#resolvedKeys + 1] = reference.id
        return nil, { code = 'NOT_FOUND' }
      end,
    })
    local first = assert(diagnostics.doctor({ limit = 250, includePersistence = false }))
    assert(first.staticChecks == 64 and first.mapImpactsAnalyzed == 2)
    assert(first.authorityObjectsScanned == 32 and first.entityBindingsChecked == 32)
    assert(first.staticComplete == false and first.authorityComplete == false)
    assert(first.truncated == true and first.hasMore == true)
    assert(#statusKeys == 64 and statusKeys[1] == 'synex_scale:map_001'
      and statusKeys[64] == 'synex_scale:map_064')
    assert(impactCalls == 2 and #resolvedKeys == 32
      and resolvedKeys[1] == 'entity_001' and resolvedKeys[32] == 'entity_032')

    statusKeys, resolvedKeys = {}, {}
    local second = assert(diagnostics.doctor({ limit = 250, includePersistence = false }))
    assert(#statusKeys == 64 and statusKeys[1] == 'synex_scale:map_065'
      and statusKeys[64] == 'synex_scale:map_128')
    assert(#resolvedKeys == 32 and resolvedKeys[1] == 'entity_033'
      and resolvedKeys[32] == 'entity_064')
    assert(impactCalls == 4 and second.staticChecks == 64
      and second.authorityObjectsScanned == 32)
    return table.concat({ first.staticChecks, first.authorityObjectsScanned,
      first.mapImpactsAnalyzed, second.staticChecks, impactCalls }, ':')
  `, files);

  assert.equal(result, '64:32:2:64:4');
});

test('Doctor rejects unknown and ill-typed bounds before any authority or persistence work', async () => {
  const result = await runWorldLua<string>(String.raw`
    local touched = 0
    local diagnostics = SynexWorldDiagnostics.create({
      foundation = { healthSnapshot = function() return { state = 'READY' } end,
        utc = function() return '2026-08-27T00:00:00Z' end },
      registry = { currentRevision = function() touched = touched + 1; return 1 end,
        bundles = function() return {} end, kindObjects = function() return {} end,
        objects = function() return {} end, bundleCount = function() return 0 end,
        objectCount = function() return 0 end,
        spatial = function() return { diagnostics = function() return {
          maximumCandidates = 0 } end } end },
      mapRegistry = { summary = function() return {} end },
      instances = { list = function() return {}, nil end,
        summary = function() return { total = 0 } end },
      slices = { summary = function() return { bytes = 0, clients = 0 } end },
      outbox = { status = function() return { dead = 0 } end },
      database = { read = function() error('must not read') end },
      getResourceState = function() return 'started' end,
    })
    for _, request in ipairs({ { unknown = true }, { limit = '10' },
        { includePersistence = 'yes' }, { limit = 251 } }) do
      local report, reportError = diagnostics.doctor(request)
      assert(report == nil and reportError.code == 'INVALID_ARGUMENT')
    end
    assert(touched == 0)
    return 'INVALID_ARGUMENT:' .. touched
  `, files);
  assert.equal(result, 'INVALID_ARGUMENT:0');
});

test('Doctor advances bounded keyset cursors across persistent state and door rows', async () => {
  const result = await runWorldLua<string>(String.raw`
    local stateRows = {
      { state_key = 'synex_scale:state_a', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
      { state_key = 'synex_scale:state_b', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
      { state_key = 'synex_scale:state_c', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
    }
    local doorRows = {
      { door_key = 'synex_scale:door_a', schema_version = 1, state = 'LOCKED', version = 1 },
      { door_key = 'synex_scale:door_b', schema_version = 1, state = 'LOCKED', version = 1 },
      { door_key = 'synex_scale:door_c', schema_version = 1, state = 'LOCKED', version = 1 },
    }
    local objects = {
      ['synex_scale:state_a'] = { kind = 'world_state_definition', scope = 'global',
        stateType = 'boolean', schemaVersion = 1 },
      ['synex_scale:state_b'] = { kind = 'world_state_definition', scope = 'global',
        stateType = 'boolean', schemaVersion = 1 },
      ['synex_scale:door_a'] = { kind = 'door' },
      ['synex_scale:door_b'] = { kind = 'door' },
    }
    local stateCursors, doorCursors, requestedLimits = {}, {}, {}
    local function afterState(row, key, scopeType, scopeRef)
      return row.state_key > key
        or row.state_key == key and row.scope_type > scopeType
        or row.state_key == key and row.scope_type == scopeType and row.scope_ref > scopeRef
    end
    local database = { read = function(_, query, parameters, options)
      local rows, result = nil, {}
      if query:find('synex_world_state', 1, true) then
        stateCursors[#stateCursors + 1] = parameters[1] .. '|' .. parameters[3]
          .. '|' .. parameters[6]
        requestedLimits[#requestedLimits + 1] = parameters[7]
        rows = stateRows
        for _, row in ipairs(rows) do
          if afterState(row, parameters[1], parameters[3], parameters[6]) then
            result[#result + 1] = row
            if #result >= parameters[7] then break end
          end
        end
      else
        doorCursors[#doorCursors + 1] = parameters[1]
        requestedLimits[#requestedLimits + 1] = parameters[2]
        rows = doorRows
        for _, row in ipairs(rows) do
          if row.door_key > parameters[1] then
            result[#result + 1] = row
            if #result >= parameters[2] then break end
          end
        end
      end
      assert(#result <= options.maximumRows)
      return result
    end }
    local diagnostics = SynexWorldDiagnostics.create({
      foundation = { healthSnapshot = function() return { state = 'READY' } end,
        utc = function() return '2026-08-27T00:00:00Z' end },
      registry = { currentRevision = function() return 1 end,
        bundles = function() return {} end, kindObjects = function() return {} end,
        objects = function() return objects end,
        spatial = function() return { diagnostics = function() return {
          maximumCandidates = 0 } end } end },
      mapRegistry = { summary = function() return {} end },
      instances = { get = function() return nil end,
        list = function() return {}, nil end, summary = function() return { total = 0 } end },
      slices = { summary = function() return { bytes = 0, clients = 0 } end },
      outbox = { status = function() return { dead = 0 } end },
      database = database, getResourceState = function() return 'started' end,
    })
    local first = assert(diagnostics.doctor({ limit = 2 }))
    assert(first.persistenceChecks == 2 and first.persistenceComplete == false
      and first.hasMore == true and #first.items == 0)
    local second = assert(diagnostics.doctor({ limit = 2 }))
    assert(second.persistenceChecks == 2 and second.persistenceComplete == false
      and second.hasMore == true and #second.items == 1
      and second.items[1].code == 'STALE_PERSISTENT_STATE')
    local third = assert(diagnostics.doctor({ limit = 2 }))
    assert(third.persistenceChecks == 2 and third.persistenceComplete == true
      and third.hasMore == false and #third.items == 1
      and third.items[1].code == 'STALE_PERSISTENT_DOOR_STATE')
    assert(stateCursors[1] == '||' and stateCursors[2] == 'synex_scale:state_b|global|global')
    assert(doorCursors[1] == '' and doorCursors[2] == 'synex_scale:door_a')
    for _, requested in ipairs(requestedLimits) do assert(requested <= 3) end
    return table.concat({ first.persistenceChecks, second.items[1].code,
      third.items[1].code, #stateCursors, #doorCursors }, ':')
  `, files);

  assert.equal(result,
    '2:STALE_PERSISTENT_STATE:STALE_PERSISTENT_DOOR_STATE:2:2');
});

test('Doctor retains actionable cycle status until a complete clean rescan', async () => {
  const result = await runWorldLua<string>(String.raw`
    local rows = {
      { state_key = 'synex_scale:bad', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
      { state_key = 'synex_scale:clean_b', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
      { state_key = 'synex_scale:clean_c', scope_type = 'global', scope_ref = 'global',
        schema_version = 1, value_type = 'boolean', version = 1 },
    }
    local objects = {
      ['synex_scale:clean_b'] = { kind = 'world_state_definition', scope = 'global',
        stateType = 'boolean', schemaVersion = 1 },
      ['synex_scale:clean_c'] = { kind = 'world_state_definition', scope = 'global',
        stateType = 'boolean', schemaVersion = 1 },
    }
    local database = { read = function(_, query, parameters)
      if query:find('synex_world_door_states', 1, true) then return {} end
      local result = {}
      for _, row in ipairs(rows) do
        local after = row.state_key > parameters[1]
          or row.state_key == parameters[1] and row.scope_type > parameters[3]
          or row.state_key == parameters[1] and row.scope_type == parameters[3]
            and row.scope_ref > parameters[6]
        if after then
          result[#result + 1] = row
          if #result >= parameters[7] then break end
        end
      end
      return result
    end }
    local diagnostics = SynexWorldDiagnostics.create({
      foundation = { healthSnapshot = function() return { state = 'READY' } end,
        utc = function() return '2026-08-27T00:00:00Z' end },
      registry = { currentRevision = function() return 1 end,
        bundles = function() return {} end, kindObjects = function() return {} end,
        objects = function() return objects end,
        spatial = function() return { diagnostics = function() return {
          maximumCandidates = 0 } end } end },
      mapRegistry = { summary = function() return {} end },
      instances = { get = function() return nil end,
        list = function() return {}, nil end, summary = function() return {} end },
      slices = { summary = function() return { bytes = 0, clients = 0 } end },
      outbox = { status = function() return { dead = 0 } end },
      database = database, getResourceState = function() return 'started' end,
    })
    local first = assert(diagnostics.doctor({ limit = 1 }))
    assert(first.status == 'DEGRADED' and first.retainedActionable == true
      and first.items[1].code == 'STALE_PERSISTENT_STATE')
    local second = assert(diagnostics.doctor({ limit = 1 }))
    assert(second.status == 'DEGRADED' and #second.items == 0
      and second.retainedActionable == true and second.persistenceComplete == false)
    assert(diagnostics.doctor({ limit = 1 }).status == 'DEGRADED')
    local completedBad = assert(diagnostics.doctor({ limit = 1 }))
    assert(completedBad.persistenceComplete == true and completedBad.status == 'DEGRADED'
      and completedBad.scanCoverage.persistence == true)

    objects['synex_scale:bad'] = { kind = 'world_state_definition', scope = 'global',
      stateType = 'boolean', schemaVersion = 1 }
    for _ = 1, 3 do
      local partial = assert(diagnostics.doctor({ limit = 1 }))
      assert(partial.status == 'DEGRADED' and partial.retainedActionable == true)
    end
    local completedClean = assert(diagnostics.doctor({ limit = 1 }))
    assert(completedClean.persistenceComplete == true and completedClean.status == 'READY'
      and completedClean.retainedActionable == false)
    local health = diagnostics.health()
    assert(health.state == 'READY' and health.lastDoctor.status == 'READY')
    return table.concat({ first.status, second.status, completedBad.status,
      completedClean.status }, ':')
  `, files);
  assert.equal(result, 'DEGRADED:DEGRADED:DEGRADED:READY');
});
