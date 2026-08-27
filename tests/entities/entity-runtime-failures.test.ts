import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');
const runtimeModules = [
  ['shared', 'validation.lua'],
  ['server', 'ordered_index.lua'],
  ['server', 'spatial_index.lua'],
  ['server', 'registry.lua'],
  ['server', 'cleanup_queue.lua'],
  ['server', 'entity_runtime.lua'],
] as const;

const fixture = String.raw`
  local clock = 1000
  local nextHandle = 1000
  local worlds = {}
  local calls = {}
  local health = {}
  local healthState = { state = 'READY', reason = 'Entity foundation is ready' }
  local spawnOptions = {}

  local foundation = {
    currentOwnerCycle = function() return 7 end,
    failure = function(code, message, retryable, context)
      return nil, {
        code = code, message = message, retryable = retryable == true,
        traceId = context and context.traceId or nil,
      }
    end,
    isCallable = function(value) return type(value) == 'function' end,
    protect = function(_, handler)
      local values = table.pack(pcall(handler))
      if not values[1] then return false, values[2] end
      return true, table.unpack(values, 2, values.n)
    end,
    setHealth = function(state, reason)
      healthState.state, healthState.reason = state, reason
      health[#health + 1] = { state = state, reason = reason }
    end,
  }

  local function allocate(entityType, model)
    if spawnOptions.zeroHandle then return 0 end
    nextHandle = nextHandle + 1
    worlds[nextHandle] = {
      bucket = 0,
      deleteStuck = spawnOptions.deleteStuck == true,
      entityType = entityType,
      exists = spawnOptions.neverExists ~= true,
      inspectionBucket = spawnOptions.inspectionBucket,
      inspectionModel = spawnOptions.inspectionModel,
      inspectionNetId = spawnOptions.inspectionNetId,
      inspectionType = spawnOptions.inspectionType,
      model = model,
      netId = spawnOptions.netId or (nextHandle + 5000),
      networkReads = 0,
    }
    return nextHandle
  end

  local ports = {
    createVehicleServerSetter = function(model, vehicleType, x, y, z, heading)
      calls[#calls + 1] = { kind = 'vehicle', vehicleType = vehicleType,
        model = model, x = x, y = y, z = z, heading = heading }
      return allocate(2, model)
    end,
    createPed = function(pedType, model, x, y, z, heading, networked, mission)
      calls[#calls + 1] = { kind = 'ped', pedType = pedType, model = model,
        x = x, y = y, z = z, heading = heading,
        networked = networked, mission = mission }
      return allocate(1, model)
    end,
    createObjectNoOffset = function(model, x, y, z, networked, mission, doorFlag)
      calls[#calls + 1] = { kind = 'object', model = model,
        x = x, y = y, z = z, networked = networked,
        mission = mission, doorFlag = doorFlag }
      return allocate(3, model)
    end,
    deleteEntity = function(handle)
      calls[#calls + 1] = { kind = 'delete', handle = handle }
      local world = worlds[handle]
      if world and not world.deleteStuck then world.exists = false end
    end,
    doesEntityExist = function(handle)
      local world = worlds[handle]
      return world ~= nil and world.exists == true
    end,
    getEntityModel = function(handle)
      local world = assert(worlds[handle])
      return world.inspectionModel or world.model
    end,
    getEntityRoutingBucket = function(handle)
      local world = assert(worlds[handle])
      return world.inspectionBucket == nil and world.bucket or world.inspectionBucket
    end,
    getEntityType = function(handle)
      local world = assert(worlds[handle])
      return world.inspectionType or world.entityType
    end,
    getGameTimer = function() return clock end,
    networkGetEntityOwner = function() return 17 end,
    networkGetNetworkIdFromEntity = function(handle)
      local world = assert(worlds[handle])
      world.networkReads = world.networkReads + 1
      if world.networkReads > 1 and world.inspectionNetId ~= nil then
        return world.inspectionNetId
      end
      return world.netId
    end,
    setEntityOrphanMode = function(handle, mode)
      worlds[handle].orphanMode = mode
    end,
    setEntityRoutingBucket = function(handle, bucket)
      if spawnOptions.policyFailure then error('injected routing policy failure') end
      worlds[handle].bucket = bucket
    end,
    wait = function(milliseconds)
      clock = clock + milliseconds
    end,
  }

  local function normalized(entityType, overrides)
    local value = {
      bucket = 0,
      doorFlag = false,
      entityType = entityType,
      heading = 90,
      model = 12345,
      owner = { type = 'resource', id = 'synex_world' },
      pedType = entityType == 'ped' and 4 or nil,
      persistencePolicy = 'temporary',
      persistent = false,
      position = { x = 10, y = 20, z = 30 },
      recoveryPolicy = 'none',
      tags = {},
      vehicleType = entityType == 'vehicle' and 'automobile' or nil,
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
  end

  local function createRuntime(cleanupEntity)
    local state = SynexEntityRegistry.newState({ spatial = {
      cellSize = 32, maximumEntries = 128, maximumCandidates = 128,
    } })
    local cleanupQueue = SynexEntityCleanupQueue.create({
      config = { maxEntities = 128, recoveryBatchSize = 8 },
      foundation = foundation,
      health = healthState,
      observability = {
        audit = function() return true end,
        gauge = function() return true end,
        increment = function() return true end,
      },
      ports = ports,
    })
    local runtime = SynexEntityRuntime.create({
      cleanupEntity = cleanupEntity,
      cleanupQueue = cleanupQueue,
      config = { deleteTimeoutMs = 30, spawnTimeoutMs = 30, waitStepMs = 10 },
      foundation = foundation,
      ports = ports,
      registry = state.entities,
      state = state,
      validation = SynexEntityValidation,
    })
    return runtime, state.entities, cleanupQueue
  end
`;

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [directory, filename] of runtimeModules) {
      await engine.doString(await readFile(path.join(root, directory, filename), 'utf8'));
    }
    return await engine.doString(`${fixture}\n${assertions}`) as T;
  } finally {
    engine.global.close();
  }
}

test('server-native adapters create and validate vehicle, ped, and object entities', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, registry = createRuntime()
    local kinds = { 'vehicle', 'ped', 'object' }
    for index, kind in ipairs(kinds) do
      spawnOptions = {}
      local record, inspection = assert(runtime.create(
        normalized(kind, { persistent = kind == 'vehicle',
          persistencePolicy = kind == 'vehicle' and 'persistent' or 'temporary' }),
        ('entity_native_%02d'):format(index), 1, 'synex_world', 7
      ))
      assert(record.entityType == kind and record.handle > 0 and record.netId > 0)
      assert(inspection.entityType == ({ vehicle = 2, ped = 1, object = 3 })[kind])
      assert(worlds[record.handle].orphanMode == (kind == 'vehicle' and 2 or 0))
      assert(registry.byNetId(record.netId, {
        entityId = record.entityId, generation = record.generation,
      }) == record)
    end
    assert(calls[1].kind == 'vehicle' and calls[1].vehicleType == 'automobile')
    assert(calls[2].kind == 'ped' and calls[2].pedType == 4
      and calls[2].networked and calls[2].mission)
    assert(calls[3].kind == 'object' and calls[3].doorFlag == false
      and calls[3].networked and calls[3].mission)
    return calls[1].kind .. ':' .. calls[2].kind .. ':' .. calls[3].kind
  `);
  assert.equal(result, 'vehicle:ped:object');
});

test('invalid handles, spawn timeout, policy failure, and invalid NetID fail closed', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, registry = createRuntime()
    local codes = {}

    spawnOptions = { zeroHandle = true }
    local zero, zeroError = runtime.create(normalized('vehicle'),
      'entity_failure_zero', 1, 'synex_world', 7)
    assert(zero == nil and zeroError.code == 'SPAWN_FAILED')
    codes[#codes + 1] = zeroError.code

    spawnOptions = { neverExists = true }
    local timeout, timeoutError = runtime.create(normalized('ped'),
      'entity_failure_timeout', 1, 'synex_world', 7)
    assert(timeout == nil and timeoutError.code == 'SPAWN_TIMEOUT')
    codes[#codes + 1] = timeoutError.code

    spawnOptions = { policyFailure = true }
    local policy, policyError = runtime.create(normalized('object'),
      'entity_failure_policy', 1, 'synex_world', 7)
    assert(policy == nil and policyError.code == 'SPAWN_FAILED')
    codes[#codes + 1] = policyError.code

    spawnOptions = { netId = 0 }
    local networked, networkError = runtime.create(normalized('vehicle'),
      'entity_failure_netid', 1, 'synex_world', 7)
    assert(networked == nil and networkError.code == 'SPAWN_FAILED')
    codes[#codes + 1] = networkError.code

    assert(registry.count() == 0)
    local deleteCalls = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCalls = deleteCalls + 1 end
    end
    assert(deleteCalls == 2)
    return table.concat(codes, ':')
  `);
  assert.equal(result, 'SPAWN_FAILED:SPAWN_TIMEOUT:SPAWN_FAILED:SPAWN_FAILED');
});

test('post-spawn type, model, bucket, and NetID mismatches are compensated', async () => {
  const result = await runLua<string>(String.raw`
    local scenarios = {
      { entityType = 'vehicle', options = { inspectionType = 1 } },
      { entityType = 'ped', options = { inspectionModel = 54321 } },
      { entityType = 'object', options = { inspectionBucket = 9 } },
      { entityType = 'vehicle', options = { netId = 7001, inspectionNetId = 7002 } },
    }
    local compensated = 0
    for index, scenario in ipairs(scenarios) do
      local runtime, registry = createRuntime()
      spawnOptions = scenario.options
      local value, operationError = runtime.create(normalized(scenario.entityType),
        ('entity_mismatch_%02d'):format(index), 1, 'synex_world', 7)
      assert(value == nil and operationError.code == 'STALE_ENTITY')
      assert(registry.count() == 0 and registry.spatial().count() == 0)
      compensated = compensated + 1
    end
    local deleteCalls = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCalls = deleteCalls + 1 end
    end
    -- The immediate rollback still owns every handle returned by the spawn native.
    assert(deleteCalls == 4)
    return tostring(compensated)
  `);
  assert.equal(result, '4');
});

test('delete timeout preserves the mapping and a later verified retry cleans it', async () => {
  const result = await runLua<string>(String.raw`
    local cleanupModes = {}
    local runtime, registry = createRuntime(function(entityId, generation, mode)
      cleanupModes[#cleanupModes + 1] = entityId .. ':' .. generation .. ':' .. mode
      return true
    end)
    spawnOptions = { deleteStuck = true }
    local record = assert(runtime.create(normalized('vehicle'),
      'entity_delete_retry', 1, 'synex_world', 7))
    local deleted, deleteError = runtime.delete(record)
    assert(deleted == nil and deleteError.code == 'DELETE_FAILED')
    assert(record.deletionRequested == nil and registry.count() == 1)
    assert(registry.byHandle(record.handle, {
      entityId = record.entityId, generation = record.generation,
    }) == record)

    worlds[record.handle].deleteStuck = false
    assert(runtime.delete(record, nil, 'cleanup_retry'))
    assert(registry.count() == 0 and #cleanupModes == 1)
    assert(cleanupModes[1] == 'entity_delete_retry:1:cleanup_retry')
    return deleteError.code
  `);
  assert.equal(result, 'DELETE_FAILED');
});

test('a recycled runtime handle is detached without deleting the unrelated occupant', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, registry = createRuntime()
    spawnOptions = {}
    local record = assert(runtime.create(normalized('object'),
      'entity_handle_reuse', 1, 'synex_world', 7))
    worlds[record.handle].inspectionModel = record.model + 1
    local deleteCallsBefore = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCallsBefore = deleteCallsBefore + 1 end
    end
    assert(runtime.delete(record, nil, 'stale_handle'))
    local deleteCallsAfter = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCallsAfter = deleteCallsAfter + 1 end
    end
    assert(deleteCallsAfter == deleteCallsBefore)
    assert(worlds[record.handle].exists == true and registry.count() == 0)
    return tostring(deleteCallsAfter)
  `);
  assert.equal(result, '0');
});

test('NetID reuse evicts only a stale EntityRef and preserves the new mapping', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, registry = createRuntime()
    spawnOptions = { netId = 9001 }
    local old = assert(runtime.create(normalized('vehicle'),
      'entity_net_old', 1, 'synex_world', 7))
    local oldRef = assert(registry.entityRef(old))
    worlds[old.handle].exists = false

    spawnOptions = { netId = 9001 }
    local replacement = assert(runtime.create(normalized('vehicle'),
      'entity_net_new', 1, 'synex_world', 7))
    assert(registry.count() == 1 and registry.byNetId(9001) == replacement)
    local stale, staleError = registry.byNetId(9001, oldRef)
    assert(stale == nil and staleError.code == 'STALE_ENTITY')
    assert(#health == 1 and health[1].state == 'DEGRADED')
    return replacement.entityId .. ':' .. staleError.code
  `);
  assert.equal(result, 'entity_net_new:STALE_ENTITY');
});

test('failed exact-identity compensation enters the bounded queue and retries safely', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, registry, cleanupQueue = createRuntime()
    spawnOptions = { deleteStuck = true, policyFailure = true }
    local value, operationError = runtime.create(normalized('vehicle'),
      'entity_cleanup_queue', 1, 'synex_world', 7)
    assert(value == nil and operationError.code == 'SPAWN_FAILED')
    assert(registry.count() == 0)
    local queued = cleanupQueue.snapshot(10)
    assert(queued.count == 1 and #queued.findings == 1)
    assert(healthState.state == 'DEGRADED'
      and healthState.reason == 'ENTITY_CLEANUP_PENDING')
    assert(queued.findings[1].operation == 'entity.delete_after_policy_failure')
    assert(queued.findings[1].entityId == nil)
    worlds[nextHandle].deleteStuck = false
    local processed = cleanupQueue.process({ traceId = 'trace_cleanup_retry' })
    assert(processed.attempted == 1 and processed.resolved == 1 and processed.pending == 0)
    assert(worlds[nextHandle].exists == false and cleanupQueue.snapshot(10).count == 0)
    assert(healthState.state == 'READY'
      and healthState.reason == 'Entity cleanup queue is empty')
    return operationError.code .. ':' .. processed.resolved
  `);
  assert.equal(result, 'SPAWN_FAILED:1');
});

test('queued compensation never deletes a recycled handle', async () => {
  const result = await runLua<string>(String.raw`
    local runtime, _, cleanupQueue = createRuntime()
    spawnOptions = { deleteStuck = true, policyFailure = true, netId = 9101 }
    local value, operationError = runtime.create(normalized('vehicle'),
      'entity_cleanup_reuse', 1, 'synex_world', 7)
    assert(value == nil and operationError.code == 'SPAWN_FAILED')
    assert(cleanupQueue.snapshot(10).count == 1)
    local handle = nextHandle
    local deleteCalls = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCalls = deleteCalls + 1 end
    end
    assert(deleteCalls == 1 and worlds[handle].exists == true)

    -- Model a Cfx handle reuse before the delayed cleanup retry.
    worlds[handle].deleteStuck = false
    worlds[handle].inspectionModel = 99999
    worlds[handle].inspectionNetId = 9202
    worlds[handle].networkReads = 1
    local processed = cleanupQueue.process({ traceId = 'trace_cleanup_reuse' })
    assert(processed.attempted == 1 and processed.resolved == 1 and processed.pending == 0)
    local deleteCallsAfter = 0
    for _, call in ipairs(calls) do
      if call.kind == 'delete' then deleteCallsAfter = deleteCallsAfter + 1 end
    end
    assert(deleteCallsAfter == deleteCalls and worlds[handle].exists == true)
    return tostring(deleteCallsAfter)
  `);
  assert.equal(result, '1');
});

test('cleanup queue capacity, deduplication, and retry batch are bounded', async () => {
  const result = await runLua<string>(String.raw`
    local queue = SynexEntityCleanupQueue.create({
      config = { maxEntities = 1, recoveryBatchSize = 2 },
      foundation = foundation,
      observability = {
        audit = function() return true end,
        gauge = function() return true end,
        increment = function() return true end,
      },
      ports = ports,
    })
    local function unresolved()
      return nil, { code = 'DELETE_FAILED', retryable = true }
    end
    for index = 1, 64 do
      assert(queue.enqueue({
        entityId = ('entity_cleanup_%04d'):format(index), generation = 1,
        entityType = 'object', operation = 'entity.cleanup_test',
      }, unresolved))
    end
    local duplicate = assert(queue.enqueue({
      entityId = 'entity_cleanup_0001', generation = 1,
      entityType = 'object', operation = 'entity.cleanup_duplicate',
    }, unresolved))
    assert(duplicate.duplicate and queue.snapshot(64).count == 64)
    local overflow, overflowError = queue.enqueue({
      entityId = 'entity_cleanup_0065', generation = 1,
      entityType = 'object', operation = 'entity.cleanup_overflow',
    }, unresolved)
    assert(overflow == nil and overflowError.code == 'REGISTRY_LIMIT')
    local processed = queue.process({ traceId = 'trace_cleanup_bounded' })
    assert(processed.attempted == 2 and processed.resolved == 0 and processed.pending == 64)
    assert(queue.snapshot(10).truncated == true)
    return overflowError.code .. ':' .. processed.attempted
  `);
  assert.equal(result, 'REGISTRY_LIMIT:2');
});

test('activation and hydration failures compensate runtime entities and persist failure state', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      _capturedAuthorityLifecycle = nil
      SynexEntityAuthorityLifecycle = {
        attach = function(_, options) _capturedAuthorityLifecycle = options end,
      }
    `);
    await engine.doString(await readFile(
      path.join(root, 'server', 'authority_service.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local mode = 'hydration'
      local deletes, failures, queued, increments = 0, 0, 0, 0
      local record = {
        bucket = 0, entityId = 'entity_activation_failure', entityType = 'vehicle',
        generation = 1, model = 12345, netId = 91, persistent = true,
        resourceOwner = 'synex_world',
      }
      local service = SynexEntityAuthorityService.create({
        archetypes = {}, checkpointGuard = {}, config = {}, coreRef = {},
        extensionRegistry = {}, health = {}, lanes = {}, logicalOwner = {},
        legacyOperations = {}, ports = {}, registry = {}, resourceName = 'synex_entities',
        spawnAdmission = {}, validation = {}, extensionRepository = {},
        authorityRepository = {
          activate = function()
            if mode == 'activation' then
              return nil, { code = 'CONCURRENT_MODIFICATION', retryable = true }
            end
            error('activate must not run during hydration failure')
          end,
          markFailed = function(_, _, _, code)
            failures = failures + 1
            assert(code == (mode == 'hydration' and 'HYDRATION_FAILED'
              or 'CONCURRENT_MODIFICATION'))
            return true
          end,
        },
        entityRuntime = {
          create = function() return record, { networkOwner = 17 } end,
          delete = function(_, _, cleanupMode)
            deletes = deletes + 1
            if mode == 'hydration' then
              assert(cleanupMode == 'activation_failed')
              return true
            end
            return nil, { code = 'DELETE_FAILED', retryable = true }
          end,
          queueCleanup = function(queuedRecord, operation, cleanupError, context)
            queued = queued + 1
            assert(queuedRecord == record)
            assert(operation == 'entity.cleanup_after_activation_failure')
            assert(cleanupError.code == 'DELETE_FAILED')
            assert(context.traceId == 'trace_activation_failure')
            return { queued = true }
          end,
        },
        extensionOperations = {
          hydrate = function()
            if mode == 'hydration' then
              return nil, { code = 'HYDRATION_FAILED', retryable = true }
            end
            return true
          end,
        },
        foundation = {
          currentOwnerCycle = function() return 8 end,
          failure = function(code, message, retryable)
            return nil, { code = code, message = message, retryable = retryable }
          end,
          getCaller = function() return 'synex_world' end,
          isCallable = function(value) return type(value) == 'function' end,
          protect = function(_, handler)
            local values = table.pack(pcall(handler))
            if not values[1] then return false, values[2] end
            return true, table.unpack(values, 2, values.n)
          end,
          setHealth = function() end,
        },
        observability = {
          increment = function() increments = increments + 1 end,
        },
      })
      local captured = assert(_capturedAuthorityLifecycle)
      assert(type(service) == 'table' and type(captured.activateReserved) == 'function')
      captured.setAuthority({ token = 'authority_0001' })
      local reservation = {
        entityId = record.entityId, generation = 1, leaseGeneration = 1, version = 1,
      }
      local hydrated, hydrationError = captured.activateReserved(
        {}, reservation, 'synex_world', { traceId = 'trace_hydration_failure' }, false)
      assert(hydrated == nil and hydrationError.code == 'HYDRATION_FAILED')
      assert(deletes == 1 and failures == 1 and increments == 1 and queued == 0)

      mode = 'activation'
      local activated, activationError = captured.activateReserved(
        {}, reservation, 'synex_world', { traceId = 'trace_activation_failure' }, false)
      assert(activated == nil and activationError.code == 'CONCURRENT_MODIFICATION')
      assert(deletes == 2 and failures == 2 and queued == 1)
      return hydrationError.code .. ':' .. activationError.code
    `) as string;
    assert.equal(result, 'HYDRATION_FAILED:CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});
