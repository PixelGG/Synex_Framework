import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const applicationFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/foundation.lua',
  'server/runtime.lua',
] as const;

const restartApplicationFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/geometry.lua',
  'server/graph.lua',
  'server/spatial_index.lua',
  'server/compiler.lua',
  'server/registry.lua',
  'server/foundation.lua',
  'server/runtime.lua',
] as const;

const harness = String.raw`
  function NewWorldApplicationHarness(validAfter, shared, registry)
    shared = shared or { idempotencyRecords = {}, nextId = 0 }
    local events, scheduled, threads = {}, {}, {}
    local acquireCalls, workerCalls, contractCalls, idempotencyRuns = 0, 0, 0, 0
    local idempotencyRecords, idempotencyOperations = shared.idempotencyRecords, {}
    local playerCleanup = { slices = 0, presence = 0, instances = 0 }
    local ownerCleanup = { bundles = 0, instances = 0, callers = 0, maps = 0, slices = 0 }
    local closeCalls = {}
    local fail = {}

    local function record(value) events[#events + 1] = value end
    local api = { ownerEpoch = shared.ownerEpoch or 7 }
    api.Runtime = { getSnapshot = function() return {} end }
    api.Services = {
      provide = function()
        record('service.provide')
        return 'service_token'
      end,
      setHealth = function(_, _, status)
        record('service.health.' .. status)
        return true
      end,
      call = function() return true end,
    }
    api.RPC = {
      registerServer = function(definition, handler)
        record('rpc.' .. definition.name)
        api.registeredHandlers = api.registeredHandlers or {}
        api.registeredHandlers[definition.name] = handler
        return 'rpc_' .. definition.name
      end,
      call = function() return true end,
    }
    api.Scheduler = {
      after = function() return 'after_token' end,
      every = function(_, handler, options)
        record('worker.' .. options.name)
        scheduled[options.name] = scheduled[options.name] or {}
        scheduled[options.name][#scheduled[options.name] + 1] = handler
        handler()
        return 'worker_' .. options.name .. '_' .. #scheduled[options.name]
      end,
      cancel = function() return true end,
    }
    local function stable(value)
      if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
      local keys, result = {}, {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      for index, key in ipairs(keys) do result[index] = tostring(key) .. '=' .. stable(value[key]) end
      return '{' .. table.concat(result, ',') .. '}'
    end
    api.Idempotency = { run = function(operation, key, request, handler)
      idempotencyRuns = idempotencyRuns + 1
      idempotencyOperations[#idempotencyOperations + 1] = operation .. ':' .. key
      local identity, fingerprint = operation .. '\0' .. key, stable(request)
      local existing = idempotencyRecords[identity]
      if existing then
        if existing.fingerprint ~= fingerprint then
          return nil, { code = 'IDEMPOTENCY_CONFLICT', retryable = false }
        end
        return SynexWorldValidation.copy(existing.value), nil, { replayed = true }
      end
      local value, operationError = handler()
      if not value then return nil, operationError end
      idempotencyRecords[identity] = { fingerprint = fingerprint,
        value = SynexWorldValidation.copy(value) }
      return SynexWorldValidation.copy(value), nil, { replayed = false }
    end }
    api.Ids = { next = function(namespace)
      shared.nextId = shared.nextId + 1
      return ('%s_%08d'):format(namespace, shared.nextId)
    end }
    api.Players = { getBySource = function() return nil end }
    api.Capabilities = { checkResource = function() return true end }
    api.Events = {
      publish = function() return true end,
      publishOutbox = function() return true end,
    }
    api.Metrics = { increment = function() return true end }
    api.Audit = { append = function() return true end }
    api.ControlProviders = { register = function() return 'provider_token' end }
    api.Database = {
      null = function() return {} end,
      read = function() return {} end,
      write = function() return true end,
      transaction = function() return true end,
      maintenance = function() return true end,
    }

    local coreRef = {}
    local health = { state = 'STARTING', reasons = {}, persistence = 'STARTING',
      service = 'UNREGISTERED' }
    local foundation, healthObserver = {}, nil
    function foundation.protect(_, handler)
      local values = table.pack(pcall(handler))
      if not values[1] then
        return nil, { code = 'CAUGHT_FAILURE', message = tostring(values[2]), retryable = true }
      end
      return table.unpack(values, 2, values.n)
    end
    function foundation.publicError(operationError) return operationError end
    function foundation.copy(value) return SynexWorldValidation.copy(value) end
    function foundation.setHealth(state, code, message)
      health.state = state
      if code then health.reasons[code] = { code = code, message = message } end
      record('local.health.' .. state .. '.' .. tostring(code or 'none'))
      if healthObserver then healthObserver(state) end
    end
    function foundation.clearHealth(code)
      if health.reasons[code] == nil then return false end
      health.reasons[code] = nil
      if next(health.reasons) == nil and health.state ~= 'STOPPING' then
        health.state = 'READY'
      end
      record('local.clear.' .. code)
      if healthObserver then healthObserver(health.state) end
      return true
    end
    function foundation.onHealthChanged(handler)
      healthObserver = handler
      if healthObserver then healthObserver(health.state) end
      return true
    end

    local service, serviceSubscriptions = {}, {}
    function service.serviceDefinition()
      return { name = 'synex.world', version = '1.0.0', methods = {}, capabilities = {} }
    end
    function service.contractHandlers()
      return {
        ['synex.world.alpha'] = function() return { ok = true } end,
        ['synex.world.beta'] = function() return { ok = true } end,
        ['synex.world.state.set'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.door.set_state'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.instance.create'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.portal.transition'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.instance.join'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.instance.leave'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
        ['synex.world.instance.close'] = function(request)
          contractCalls = contractCalls + 1
          return { ok = true, marker = request.marker }
        end,
      }
    end
    function service.seedSubscription(owner, token)
      serviceSubscriptions[owner] = token
    end
    function service.subscriptionCount()
      local count = 0
      for _ in pairs(serviceSubscriptions) do count = count + 1 end
      return count
    end
    function service.subscription(owner) return serviceSubscriptions[owner] end
    function service.removeCaller(owner)
      ownerCleanup.callers = ownerCleanup.callers + 1
      if fail.ownerCaller then error('caller cleanup failed') end
      serviceSubscriptions[owner] = nil
    end

    local bundleLoader = {}
    function bundleLoader.discoverAll()
      record('bundles.discover')
      if fail.discovery then
        return nil, { code = 'WORLD_BUNDLE_INVALID', retryable = false }
      end
      return { resources = {}, unresolved = fail.unresolved and { 'synex_dependent' } or {} }
    end
    function bundleLoader.discoverResource()
      record('bundles.discover_resource')
      if fail.hotMissing then
        return nil, { code = 'WORLD_DEPENDENCY_MISSING', retryable = true }
      end
      if fail.hotDiscoveryError then
        return nil, { code = 'WORLD_BUNDLE_INVALID', retryable = false }
      end
      return { loaded = fail.hotFailures and 0 or 1,
        failures = fail.hotFailures and { { code = 'WORLD_BUNDLE_INVALID' } } or {} }
    end
    function bundleLoader.ownerStopped()
      ownerCleanup.bundles = ownerCleanup.bundles + 1
      if fail.ownerBundles then error('bundle cleanup failed') end
      return { count = 1, dependents = fail.ownerDependents or 0, removed = {} }
    end

    local mapRegistry = {}
    function mapRegistry.summary()
      return { generation = 1,
        requiredUnavailable = fail.mapUnavailable and 1 or 0 }
    end
    function mapRegistry.refresh()
      ownerCleanup.maps = ownerCleanup.maps + 1
      record('maps.refresh')
      if fail.ownerMaps then error('map cleanup failed') end
      return mapRegistry.summary()
    end
    function mapRegistry.objectAvailability()
      return { available = fail.mapUnavailable ~= true }
    end

    local slices, sliceClients = {}, {}
    function slices.seed(source, revision)
      sliceClients[source] = { revision = revision }
    end
    function slices.summary()
      local clients = 0
      for _ in pairs(sliceClients) do clients = clients + 1 end
      return { clients = clients }
    end
    function slices.invalidateAll()
      ownerCleanup.slices = ownerCleanup.slices + 1
      record('slices.invalidate')
      if fail.ownerSlices then error('slice invalidation failed') end
      for source in pairs(sliceClients) do sliceClients[source] = nil end
    end
    function slices.updateAll()
      workerCalls = workerCalls + 1
      if fail.sliceWorker then
        return nil, { code = 'SLICE_WORKER_FAILED', retryable = true }
      end
      return true
    end
    function slices.remove(source)
      playerCleanup.slices = playerCleanup.slices + 1
      if fail.playerSlices then error('player slice cleanup failed') end
      sliceClients[source] = nil
    end

    local presence = {}
    function presence.remove()
      playerCleanup.presence = playerCleanup.presence + 1
      if fail.playerPresence then error('player presence cleanup failed') end
    end

    local instances, instanceRecords = {}, {}
    function instances.seed(instanceId, owner)
      instanceRecords[instanceId] = {
        instanceId = instanceId, ownerResource = owner, state = 'READY',
      }
    end
    function instances.playerDropped()
      playerCleanup.instances = playerCleanup.instances + 1
      if fail.playerInstances then error('player instance cleanup failed') end
    end
    function instances.ownerStopped()
      ownerCleanup.instances = ownerCleanup.instances + 1
      if fail.ownerInstances then error('instance cleanup failed') end
      local removed = 0
      for instanceId in pairs(instanceRecords) do
        instanceRecords[instanceId], removed = nil, removed + 1
      end
      return removed
    end
    function instances.expire() return 0 end
    function instances.retryClosedCleanup()
      if fail.closedCleanup then
        return { attempted = 1, completed = 0, failures = 1, pending = 1 }
      end
      return { attempted = 1, completed = 1, failures = 0, pending = 0 }
    end
    function instances.retryBucketRecovery()
      if fail.bucketRecovery then
        return { attempted = 1, completed = 0, failures = 1, pending = 1 }
      end
      return { attempted = 1, completed = 1, failures = 0, pending = 0 }
    end
    function instances.reconcileTemplateAvailability()
      ownerCleanup.templateAvailability = (ownerCleanup.templateAvailability or 0) + 1
      if fail.templateCleanup then
        return { checked = 1, matched = 1, closed = 0, failures = 1, pending = 1 }
      end
      return { checked = fail.mapUnavailable and 1 or 0,
        matched = fail.mapUnavailable and 1 or 0,
        closed = fail.mapUnavailable and 1 or 0, failures = 0, pending = 0 }
    end
    function instances.list()
      if fail.selfRecords then
        local secondId = fail.maximumSelfId and string.rep('x', 64)
          or 'world_instance_0002'
        return {
          { instanceId = 'world_instance_0001', state = 'READY' },
          { instanceId = secondId, state = 'ACTIVE' },
        }, nil
      end
      local result = {}
      for _, record in pairs(instanceRecords) do result[#result + 1] = record end
      table.sort(result, function(left, right) return left.instanceId < right.instanceId end)
      return result, nil
    end
    function instances.close(request)
      if fail.selfRecords then assert(request.idempotencyKey == nil) end
      closeCalls[#closeCalls + 1] = request.instanceId
      if fail.closeFirst and request.instanceId == 'world_instance_0001' then
        return nil, { code = 'INSTANCE_BUCKET_UNAVAILABLE', retryable = true }
      end
      instanceRecords[request.instanceId] = nil
      return { state = 'CLOSED' }
    end
    function instances.summary()
      local total = 0
      for _ in pairs(instanceRecords) do total = total + 1 end
      return { total = total }
    end

    local outbox = {}
    function outbox.dispatchBatch()
      workerCalls = workerCalls + 1
      if fail.outboxWorker then
        return nil, { code = 'OUTBOX_WORKER_FAILED', retryable = true }
      end
      return true
    end
    local portals = { expire = function() return 0 end }
    local diagnostics = { doctor = function() return { status = 'READY' } end }
    local observability = { runtimeGauges = function() return true end }
    local controlProvider = {}
    function controlProvider.register()
      record('provider.register')
      if fail.provider then
        return nil, { code = 'PROVIDER_INVALID', retryable = false }
      end
      return 'provider_token'
    end

    local application = SynexWorldApplication.create({
      resourceName = 'synex_world', coreResource = 'synex_core', coreRange = '^1.0.0',
      coreRef = coreRef, foundation = foundation, health = health,
      service = service, controlProvider = controlProvider, bundleLoader = bundleLoader,
      mapRegistry = mapRegistry, slices = slices, presence = presence,
      instances = instances, portals = portals, outbox = outbox,
      diagnostics = diagnostics, observability = observability, registry = registry or {},
      loadResourceFile = function() return 'contracts' end,
      decode = function()
        if fail.idempotentContracts then
          return { contracts = {
            { name = 'synex.world.state.set', version = '1.0.0', idempotent = true },
            { name = 'synex.world.door.set_state', version = '1.0.0', idempotent = true },
            { name = 'synex.world.portal.transition', version = '1.0.0', idempotent = true },
            { name = 'synex.world.instance.create', version = '1.0.0', idempotent = true },
            { name = 'synex.world.instance.join', version = '1.0.0', idempotent = true },
            { name = 'synex.world.instance.leave', version = '1.0.0', idempotent = true },
            { name = 'synex.world.instance.close', version = '1.0.0', idempotent = true },
          } }
        end
        return { contracts = {
          { name = 'synex.world.alpha', version = '1.0.0' },
          { name = 'synex.world.beta', version = '1.0.0' },
        } }
      end,
      acquireApi = function()
        acquireCalls = acquireCalls + 1
        if acquireCalls < validAfter then return { ownerEpoch = 7 } end
        return api
      end,
      wait = function(delay) coroutine.yield(delay) end,
      createThread = function(handler)
        threads[#threads + 1] = coroutine.create(handler)
      end,
    })

    return {
      api = api, application = application, coreRef = coreRef, health = health,
      shared = shared,
      foundation = foundation, registry = registry,
      service = service, slices = slices, instances = instances,
      events = events, scheduled = scheduled, threads = threads, fail = fail,
      playerCleanup = playerCleanup, ownerCleanup = ownerCleanup, closeCalls = closeCalls,
      acquireCalls = function() return acquireCalls end,
      workerCalls = function() return workerCalls end,
      contractCalls = function() return contractCalls end,
      idempotencyRuns = function() return idempotencyRuns end,
      idempotencyOperations = idempotencyOperations,
      resume = function(index)
        local ok, yielded = coroutine.resume(threads[index])
        assert(ok, tostring(yielded))
        return coroutine.status(threads[index]), yielded
      end,
    }
  end
`;

test('application retries an incomplete Core, stages discovery before public readiness, and fences workers', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(42)
    assert(runtime.application.start() == true)
    for attempt = 1, 42 do runtime.resume(1) end
    assert(runtime.acquireCalls() == 42)
    assert(runtime.health.state == 'READY' and runtime.health.service == 'REGISTERED',
      runtime.health.state .. ':' .. runtime.health.service)
    assert(runtime.health.reasons.CORE_UNAVAILABLE == nil)

    local positions = {}
    for index, event in ipairs(runtime.events) do positions[event] = positions[event] or index end
    assert(positions['service.provide'] < positions['service.health.UNHEALTHY'],
      table.concat(runtime.events, ','))
    assert(positions['service.health.UNHEALTHY'] < positions['bundles.discover'],
      table.concat(runtime.events, ','))
    assert(positions['bundles.discover'] < positions['rpc.synex.world.alpha'],
      table.concat(runtime.events, ','))
    assert(positions['rpc.synex.world.beta'] < positions['provider.register'],
      table.concat(runtime.events, ','))
    assert(positions['provider.register'] < positions['worker.synex_world.outbox'],
      table.concat(runtime.events, ','))
    assert(positions['worker.synex_world.doctor'] < positions['service.health.HEALTHY'],
      table.concat(runtime.events, ','))
    assert(runtime.workerCalls() == 0, 'bootstrap worker calls=' .. runtime.workerCalls())

    local firstOutbox = runtime.scheduled['synex_world.outbox'][1]
    assert(firstOutbox() == nil and runtime.workerCalls() == 1,
      'ready outbox calls=' .. runtime.workerCalls())
    assert(runtime.application.resourceStopped('synex_core') == true, 'core stop failed')
    assert(runtime.coreRef.value == nil and runtime.health.service == 'UNREGISTERED',
      'core stop binding remained')
    firstOutbox()
    assert(runtime.workerCalls() == 1, 'stale worker was not fenced')

    runtime.application.resourceStarted('synex_core')
    runtime.resume(2)
    assert(runtime.health.state == 'READY' and runtime.health.service == 'REGISTERED',
      'rebind health=' .. runtime.health.state .. ':' .. runtime.health.service)
    local secondOutbox = runtime.scheduled['synex_world.outbox'][2]
    firstOutbox()
    assert(runtime.workerCalls() == 1, 'old generation worker was not fenced')
    assert(secondOutbox() == nil and runtime.workerCalls() == 2,
      'new generation worker did not run')
    return table.concat({ runtime.acquireCalls(), runtime.health.state,
      runtime.health.service, runtime.workerCalls() }, ':')
  `, applicationFiles);

  assert.equal(result, '43:READY:REGISTERED:2');
});

test('fresh World runtime restart has no duplicate definitions, stale authority, slices, or instances', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local shared = { idempotencyRecords = {}, nextId = 0, ownerEpoch = 7 }
    local function bundle()
      return {
        schema = 1, key = 'synex_restart_fixture:bundle', version = '1.0.0',
        dependencies = {}, objects = {
          { kind = 'region', key = 'synex_restart_fixture:region',
            geometry = { type = 'sphere',
              center = { x = 0, y = 0, z = 0 }, radius = 25 } },
        },
      }
    end

    local firstRegistry = SynexWorldRegistry.create({})
    local first = NewWorldApplicationHarness(1, shared, firstRegistry)
    assert(first.application.start() == true)
    first.resume(1)
    local firstBundle = assert(firstRegistry.registerBundle(
      bundle(), 'synex_restart_fixture', 1))
    local oldRef = firstRegistry.ref(assert(firstRegistry.get(
      'synex_restart_fixture:region')))
    first.service.seedSubscription('synex_restart_fixture', 'old_subscription')
    first.slices.seed(42, 11)
    first.instances.seed('world_instance_restart_0001', 'synex_restart_fixture')
    assert(firstRegistry.objectCount() == 1 and firstRegistry.bundleCount() == 1)
    assert(first.service.subscriptionCount() == 1
      and first.slices.summary().clients == 1 and first.instances.summary().total == 1)
    local oldHandler = first.api.registeredHandlers['synex.world.alpha']
    local oldWorker = first.scheduled['synex_world.outbox'][1]
    oldWorker()
    local callsBeforeStop = first.workerCalls()

    assert(first.application.resourceStopped('synex_world') == true)
    assert(first.health.state == 'STOPPING' and first.instances.summary().total == 0)
    oldWorker()
    assert(first.workerCalls() == callsBeforeStop)

    shared.ownerEpoch = 8
    local secondRegistry = SynexWorldRegistry.create({})
    local second = NewWorldApplicationHarness(1, shared, secondRegistry)
    assert(second.application.start() == true)
    second.resume(1)
    local secondBundle = assert(secondRegistry.registerBundle(
      bundle(), 'synex_restart_fixture', 2))

    assert(secondRegistry.objectCount() == 1 and secondRegistry.bundleCount() == 1)
    assert(second.service.subscriptionCount() == 0)
    assert(second.slices.summary().clients == 0)
    assert(second.instances.summary().total == 0)
    assert(second.api.registeredHandlers['synex.world.alpha'] ~= oldHandler)
    local stale, staleError = secondRegistry.resolve(oldRef)
    assert(stale == nil and staleError.code == 'STALE_WORLD_REF')
    local current = secondRegistry.ref(assert(secondRegistry.get(
      'synex_restart_fixture:region')))
    assert(current.revision ~= oldRef.revision
      and firstBundle.revision == 393217 and secondBundle.revision == 458753)

    second.service.seedSubscription('synex_restart_fixture', 'new_subscription')
    assert(second.service.subscriptionCount() == 1
      and second.service.subscription('synex_restart_fixture') == 'new_subscription')
    return table.concat({ firstBundle.revision, secondBundle.revision,
      secondRegistry.objectCount(), second.service.subscriptionCount(),
      second.slices.summary().clients, second.instances.summary().total,
      staleError.code, second.health.state }, ':')
  `, restartApplicationFiles);

  assert.equal(result, '393217:458753:1:1:0:0:STALE_WORLD_REF:READY');
});

test('contract boundary uses collision-free bounded caller idempotency namespaces', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    runtime.fail.idempotentContracts = true
    assert(runtime.application.start() == true)
    runtime.resume(1)
    local state = runtime.api.registeredHandlers['synex.world.state.set']
    local door = runtime.api.registeredHandlers['synex.world.door.set_state']
    local context = { caller = 'synex_consumer', callerEpoch = 2,
      traceId = 'trace_idempotency_0001' }
    local first = assert(state({ idempotencyKey = 'world_retry_0001', marker = 'first' }, context))
    local replay = assert(state({ idempotencyKey = 'world_retry_0001', marker = 'first' }, context))
    assert(first.marker == 'first' and first.replayed == false
      and replay.marker == 'first' and replay.replayed == true
      and runtime.contractCalls() == 1)
    local conflict, conflictError = state({ idempotencyKey = 'world_retry_0001',
      marker = 'changed' }, context)
    assert(conflict == nil and conflictError.code == 'CONCURRENT_MODIFICATION'
      and conflictError.retryable == false and runtime.contractCalls() == 1)
    assert(door({ idempotencyKey = 'world_retry_0001', marker = 'door' }, context))
    local foreign = assert(state({ idempotencyKey = 'world_retry_0001', marker = 'first' }, {
      caller = 'synex_other', callerEpoch = 1, traceId = 'trace_idempotency_0002' }))
    assert(foreign.replayed == false and foreign.marker == 'first')
    local longCaller = 'synex_' .. string.rep('a', 27) .. '__' .. string.rep('b', 29)
    assert(#longCaller == 64)
    assert(state({ idempotencyKey = 'long_caller_0001', marker = 'long' }, {
      caller = longCaller, callerEpoch = 1, traceId = 'trace_idempotency_0003' }))
    local underscoreCaller = 'synex_' .. string.rep('_', 58)
    assert(#underscoreCaller == 64)
    assert(state({ idempotencyKey = 'underscore_0001', marker = 'underscore' }, {
      caller = underscoreCaller, callerEpoch = 1, traceId = 'trace_idempotency_0004' }))
    local zCaller = 'synex_' .. string.rep('z', 58)
    assert(#zCaller == 64)
    assert(state({ idempotencyKey = 'maximum_z_0001', marker = 'maximum-z' }, {
      caller = zCaller, callerEpoch = 1, traceId = 'trace_idempotency_0005' }))
    local alphabet, seenOperations = 'abcdefghijklmnopqrstuvwxyz0123456789_', {}
    for index = 1, #alphabet do
      local suffix = alphabet:sub(index, index)
      local value = assert(state({ idempotencyKey = ('alphabet_%04d'):format(index),
        marker = suffix }, { caller = 'synex_' .. suffix, callerEpoch = 1,
        traceId = 'trace_idempotency_property' }))
      assert(value.marker == suffix and value.replayed == false)
      local operation = runtime.idempotencyOperations[8 + index]:match('^([^:]+):')
      assert(operation:match('^a%.[a-z0-9]+$') ~= nil and #operation <= 64
        and seenOperations[operation] == nil)
      seenOperations[operation] = true
    end
    local invalid, invalidError = state({ idempotencyKey = string.rep('x', 37),
      marker = 'invalid' }, context)
    assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
    assert(runtime.contractCalls() == 43 and runtime.idempotencyRuns() == 45)
    local firstOperation = runtime.idempotencyOperations[1]:match('^([^:]+):')
    local doorOperation = runtime.idempotencyOperations[4]:match('^([^:]+):')
    local otherOperation = runtime.idempotencyOperations[5]:match('^([^:]+):')
    local longOperation = runtime.idempotencyOperations[6]:match('^([^:]+):')
    local underscoreOperation = runtime.idempotencyOperations[7]:match('^([^:]+):')
    local zOperation = runtime.idempotencyOperations[8]:match('^([^:]+):')
    assert(firstOperation == runtime.idempotencyOperations[2]:match('^([^:]+):')
      and firstOperation == runtime.idempotencyOperations[3]:match('^([^:]+):')
      and firstOperation:match('^a%.[a-z0-9]+$') ~= nil
      and doorOperation:match('^b%.[a-z0-9]+$') ~= nil
      and otherOperation ~= firstOperation
      and #longOperation <= 64 and longOperation:match('^a%.[a-z0-9]+$') ~= nil
      and #underscoreOperation <= 64
      and underscoreOperation:match('^a%.[a-z0-9]+$') ~= nil
      and #zOperation <= 64 and zOperation:match('^a%.[a-z0-9]+$') ~= nil
      and underscoreOperation ~= longOperation and zOperation ~= underscoreOperation)
    return table.concat({ runtime.contractCalls(), runtime.idempotencyRuns(),
      conflictError.code, invalidError.code }, ':')
  `, applicationFiles);
  assert.equal(result,
    '43:45:CONCURRENT_MODIFICATION:INVALID_ARGUMENT');
});

test('all mutation receipts are scoped to one World process incarnation', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local shared = { idempotencyRecords = {}, nextId = 0 }
    local firstRuntime = NewWorldApplicationHarness(1, shared)
    firstRuntime.fail.idempotentContracts = true
    assert(firstRuntime.application.start() == true)
    firstRuntime.resume(1)
    local context = { caller = 'synex_consumer', callerEpoch = 2,
      traceId = 'trace_instance_restart_1' }
    local mutations = {
      'synex.world.state.set', 'synex.world.door.set_state',
      'synex.world.portal.transition', 'synex.world.instance.create',
      'synex.world.instance.join', 'synex.world.instance.leave',
      'synex.world.instance.close',
    }
    for index, name in ipairs(mutations) do
      local handler = firstRuntime.api.registeredHandlers[name]
      local request = { idempotencyKey = ('restart_%02d_0001'):format(index),
        marker = name }
      local first = assert(handler(request, context))
      local replay = assert(handler(request, context))
      assert(first.replayed == false and replay.replayed == true
        and replay.marker == name)
    end
    assert(firstRuntime.contractCalls() == #mutations)

    -- A new World application shares Core's durable receipt store, but gets a
    -- fresh incarnation. The exact retry must fail closed instead of replaying
    -- process-local instance/bucket success from the earlier application.
    local secondRuntime = NewWorldApplicationHarness(1, shared)
    secondRuntime.fail.idempotentContracts = true
    assert(secondRuntime.application.start() == true)
    secondRuntime.resume(1)
    for index, name in ipairs(mutations) do
      local handler = secondRuntime.api.registeredHandlers[name]
      local request = { idempotencyKey = ('restart_%02d_0001'):format(index),
        marker = name }
      local stale, staleError = handler(request, context)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION'
        and staleError.retryable == false)
    end
    assert(secondRuntime.contractCalls() == 0)
    return table.concat({ #mutations, firstRuntime.contractCalls(),
      secondRuntime.contractCalls(), 'CONCURRENT_MODIFICATION' }, ':')
  `, applicationFiles);

  assert.equal(result, '7:7:0:CONCURRENT_MODIFICATION');
});

test('non-retryable bootstrap failures stay fenced and clear only after a successful new binding', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    runtime.fail.provider = true
    assert(runtime.application.start() == true)
    runtime.resume(1)
    assert(runtime.health.state == 'UNHEALTHY')
    assert(runtime.health.reasons.WORLD_BOOTSTRAP_FAILED ~= nil)
    assert(runtime.api.registeredHandlers ~= nil)
    local value, operationError = runtime.api.registeredHandlers['synex.world.alpha']({}, {})
    assert(value == nil and operationError.code == 'STALE_RESOURCE')
    assert(runtime.scheduled['synex_world.outbox'] == nil)
    assert(runtime.coreRef.value == runtime.api)
    runtime.fail.provider = false
    runtime.application.resourceStarted('synex_core')
    runtime.resume(2)
    assert(runtime.health.state == 'READY'
      and runtime.health.reasons.WORLD_BOOTSTRAP_FAILED == nil)
    local recovered = assert(runtime.api.registeredHandlers['synex.world.alpha']({}, {}))
    assert(recovered.ok == true)
    return table.concat({ runtime.health.state, operationError.code,
      runtime.health.reasons.WORLD_BOOTSTRAP_FAILED == nil and 'CLEARED' or 'STALE' }, ':')
  `, applicationFiles);

  assert.equal(result, 'READY:STALE_RESOURCE:CLEARED');
});

test('worker health recovers only after every previously failing worker succeeds', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    assert(runtime.application.start() == true)
    runtime.resume(1)
    local outbox = runtime.scheduled['synex_world.outbox'][1]
    local slices = runtime.scheduled['synex_world.slices'][1]
    runtime.fail.outboxWorker, runtime.fail.sliceWorker = true, true
    outbox()
    slices()
    assert(runtime.health.reasons.WORLD_WORKER_FAILURE ~= nil)
    runtime.fail.outboxWorker = false
    outbox()
    assert(runtime.health.reasons.WORLD_WORKER_FAILURE ~= nil)
    runtime.fail.sliceWorker = false
    slices()
    assert(runtime.health.reasons.WORLD_WORKER_FAILURE == nil)
    local lastService
    for _, event in ipairs(runtime.events) do
      if event:find('service.health.', 1, true) == 1 then lastService = event end
    end
    assert(lastService == 'service.health.HEALTHY')
    return runtime.health.state .. ':' .. runtime.workerCalls() .. ':' .. lastService
  `, applicationFiles);

  assert.equal(result, 'READY:4:service.health.HEALTHY');
});

test('instance cleanup workers retain degraded health until state and bucket queues clear', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    assert(runtime.application.start() == true)
    runtime.resume(1)
    local expiry = runtime.scheduled['synex_world.instance_expiry'][1]
    runtime.foundation.setHealth('DEGRADED', 'INSTANCE_STATE_CLEANUP_FAILED',
      'state cleanup failed')
    runtime.fail.closedCleanup, runtime.fail.bucketRecovery = true, true
    expiry()
    assert(runtime.health.state == 'DEGRADED'
      and runtime.health.reasons.INSTANCE_STATE_CLEANUP_FAILED ~= nil
      and runtime.health.reasons.INSTANCE_BUCKET_RECOVERY_FAILED ~= nil)
    runtime.fail.closedCleanup = false
    expiry()
    assert(runtime.health.state == 'DEGRADED'
      and runtime.health.reasons.INSTANCE_STATE_CLEANUP_FAILED == nil
      and runtime.health.reasons.INSTANCE_BUCKET_RECOVERY_FAILED ~= nil)
    runtime.fail.bucketRecovery = false
    expiry()
    assert(runtime.health.state == 'READY'
      and runtime.health.reasons.INSTANCE_STATE_CLEANUP_FAILED == nil
      and runtime.health.reasons.INSTANCE_BUCKET_RECOVERY_FAILED == nil)
    local lastService
    for _, event in ipairs(runtime.events) do
      if event:find('service.health.', 1, true) == 1 then lastService = event end
    end
    assert(lastService == 'service.health.HEALTHY')
    return runtime.health.state .. ':' .. lastService
  `, applicationFiles);

  assert.equal(result, 'READY:service.health.HEALTHY');
});

test('required map outage degrades service health, drains templates, and recovers without reviving them', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    assert(runtime.application.start() == true)
    runtime.resume(1)

    runtime.fail.mapUnavailable = true
    assert(runtime.application.resourceStopped('synex_required_map') == true)
    assert(runtime.health.state == 'DEGRADED'
      and runtime.health.reasons.MAP_PACKAGE_UNAVAILABLE ~= nil)
    assert(runtime.ownerCleanup.templateAvailability >= 2)
    local degraded, healthy = 0, 0
    for _, event in ipairs(runtime.events) do
      if event == 'service.health.DEGRADED' then degraded = degraded + 1 end
      if event == 'service.health.HEALTHY' then healthy = healthy + 1 end
    end
    assert(degraded > 0)

    runtime.fail.mapUnavailable = false
    runtime.application.resourceStarted('synex_required_map')
    runtime.resume(2)
    runtime.resume(2)
    assert(runtime.health.state == 'READY'
      and runtime.health.reasons.MAP_PACKAGE_UNAVAILABLE == nil)
    local lastService
    for _, event in ipairs(runtime.events) do
      if event:find('service.health.', 1, true) == 1 then lastService = event end
    end
    assert(lastService == 'service.health.HEALTHY')
    return table.concat({ degraded, runtime.health.state,
      runtime.ownerCleanup.templateAvailability, lastService }, ':')
  `, applicationFiles);

  assert.match(result, /^[1-9][0-9]*:READY:[2-9][0-9]*:service\.health\.HEALTHY$/);
});

test('foundation health observer is bounded, fail-safe, and reports state transitions', async () => {
  const result = await runWorldLua<string>(String.raw`
    local health = { state = 'STARTING', reasons = {}, persistence = 'STARTING',
      service = 'UNREGISTERED' }
    local observed = {}
    local foundation = SynexWorldFoundation.create({ health = health,
      encode = function() return '{}' end, now = function() return 1 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
      resourceName = 'synex_world' })
    foundation.onHealthChanged(function(state)
      observed[#observed + 1] = state
      if #observed > 3 then error('observer must remain bounded') end
    end)
    foundation.setHealth('DEGRADED', 'TEST_REASON', 'test')
    assert(foundation.clearHealth('TEST_REASON') == true)
    assert(foundation.clearHealth('TEST_REASON') == false)
    assert(table.concat(observed, ',') == 'STARTING,DEGRADED,READY')
    return health.state .. ':' .. #observed
  `, applicationFiles);

  assert.equal(result, 'READY:3');
});

test('owner dependency loss and hot-discovery failures remain degraded until full reconciliation', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    assert(runtime.application.start() == true)
    runtime.resume(1)

    runtime.fail.hotMissing = true
    runtime.application.resourceStarted('unrelated_resource')
    runtime.resume(2)
    runtime.resume(2)
    runtime.fail.hotMissing = false
    assert(runtime.health.reasons.WORLD_DEPENDENCY_MISSING == nil)

    assert(runtime.application.resourceStopped('synex_isolated') == true)
    assert(runtime.health.reasons.WORLD_DEPENDENCY_MISSING == nil)
    runtime.fail.ownerDependents = 2
    assert(runtime.application.resourceStopped('synex_dependency') == true)
    assert(runtime.health.state == 'DEGRADED'
      and runtime.health.reasons.WORLD_DEPENDENCY_MISSING ~= nil)

    runtime.fail.hotFailures, runtime.fail.unresolved = true, true
    runtime.application.resourceStarted('synex_dependency')
    runtime.resume(3)
    runtime.resume(3)
    assert(runtime.health.state == 'DEGRADED'
      and runtime.health.reasons.WORLD_DEPENDENCY_MISSING ~= nil)

    runtime.fail.hotFailures, runtime.fail.unresolved = false, false
    runtime.application.resourceStarted('synex_dependency')
    runtime.resume(4)
    runtime.resume(4)
    assert(runtime.health.state == 'READY'
      and runtime.health.reasons.WORLD_DEPENDENCY_MISSING == nil)
    return table.concat({ runtime.ownerCleanup.bundles,
      runtime.health.state, runtime.health.service }, ':')
  `, applicationFiles);

  assert.equal(result, '2:READY:REGISTERED');
});

test('player, owner, and self-stop cleanup stages are isolated and exhaustive', async () => {
  const result = await runWorldLua<string>(harness + String.raw`
    local runtime = NewWorldApplicationHarness(1)
    assert(runtime.application.start() == true)
    runtime.resume(1)
    local outboxWorker = runtime.scheduled['synex_world.outbox'][1]

    runtime.fail.playerSlices = true
    assert(runtime.application.playerDropped(71) == false)
    assert(runtime.playerCleanup.slices == 1 and runtime.playerCleanup.presence == 1
      and runtime.playerCleanup.instances == 1)
    assert(runtime.health.reasons.WORLD_PLAYER_CLEANUP_FAILED ~= nil)

    runtime.fail.ownerBundles = true
    runtime.fail.ownerMaps = true
    assert(runtime.application.resourceStopped('synex_companion') == false)
    assert(runtime.ownerCleanup.bundles == 1 and runtime.ownerCleanup.instances == 1
      and runtime.ownerCleanup.callers == 1 and runtime.ownerCleanup.maps >= 2
      and runtime.ownerCleanup.slices >= 2)
    assert(runtime.health.reasons.WORLD_OWNER_CLEANUP_FAILED ~= nil)

    runtime.fail.selfRecords, runtime.fail.maximumSelfId = true, true
    runtime.fail.closeFirst = true
    local beforeStopWorkerCalls = runtime.workerCalls()
    assert(runtime.application.resourceStopped('synex_world') == false)
    assert(#runtime.closeCalls == 2 and runtime.closeCalls[1] == 'world_instance_0001'
      and #runtime.closeCalls[2] == 64)
    assert(runtime.coreRef.value == nil and runtime.health.state == 'STOPPING'
      and runtime.health.service == 'UNREGISTERED')
    outboxWorker()
    assert(runtime.workerCalls() == beforeStopWorkerCalls)
    return table.concat({ runtime.playerCleanup.slices, runtime.playerCleanup.presence,
      runtime.playerCleanup.instances, runtime.ownerCleanup.bundles,
      runtime.ownerCleanup.instances, #runtime.closeCalls, runtime.health.state }, ':')
  `, applicationFiles);

  assert.equal(result, '1:1:1:1:1:2:STOPPING');
});
