import assert from 'node:assert/strict';
import test from 'node:test';

import {
  interactBundleFactory,
  interactServerFiles,
  runInteractLua,
} from './helpers.js';

const operationsFiles = [
  ...interactServerFiles,
  'resources/synex_interact/server/observability.lua',
  'resources/synex_interact/server/diagnostics.lua',
  'resources/synex_interact/server/control_provider.lua',
] as const;

const bundleDiagnosticsFiles = [
  ...operationsFiles,
  'resources/synex_interact/server/bundle_loader.lua',
] as const;

test('client telemetry emits monotonic deltas and rejects high-cardinality labels', async () => {
  const result = await runInteractLua<{
    acceptedDelta: number;
    deltaCount: number;
    total: number;
    rejectedLabel: boolean;
    rollback: string;
    sources: number;
    candidateGauge: number;
    sensorDuration: number;
    providerDuration: number;
    intentDuration: number;
    providerTimeouts: number;
    providerFailure: boolean;
    clientProviderAdvisory: boolean;
    leaseGranted: number;
    leaseDenied: number;
    slotBusy: number;
  }>(`
    local clock, calls = 100, {}
    local metrics = {
      increment = function(name, labels, amount)
        calls[#calls + 1] = { name = name, labels = labels, amount = amount }
        return true
      end,
      gauge = function() return true end,
      observe = function() return true end,
    }
    local observability = SynexInteractObservability.create({
      coreRef = { value = { Metrics = metrics } },
      foundation = SynexInteractFoundation,
      now = function() return clock end,
    })
    local context = { source = 10, sourceGeneration = 2,
      session = { id = 'session-0001', state = 'ACTIVE',
        source = 10, sourceGeneration = 2 } }
    assert(observability.reportClient({ clientEpoch = 1, sequence = 1,
      counters = { sensorTicks = 10, candidatesSeen = 20, expensiveChecks = 3,
        intentChanges = 2, promptsShown = 1, bloomOpened = 0,
        leaseRequests = 1, transportFailures = 0, providerTimeouts = 2 },
      gauges = { candidateCount = 2, sensorIntervalMs = 75,
        expensiveCandidateCount = 1, sensorDurationMs = 4.5,
        providerDurationMs = 2.5, intentScoringDurationMs = 1.5 } }, context))
    clock = 5100
    assert(observability.reportClient({ clientEpoch = 1, sequence = 2,
      counters = { sensorTicks = 15, candidatesSeen = 25, expensiveChecks = 4,
        intentChanges = 3, promptsShown = 1, bloomOpened = 0,
        leaseRequests = 1, transportFailures = 0, providerTimeouts = 3 },
      gauges = { candidateCount = 1, sensorIntervalMs = 200,
        expensiveCandidateCount = 0, sensorDurationMs = 5.5,
        providerDurationMs = 3.5, intentScoringDurationMs = 2.5 } }, context))
    clock = 10100
    local _, rollback = observability.reportClient({ clientEpoch = 1, sequence = 3,
      counters = { sensorTicks = 14, candidatesSeen = 25, expensiveChecks = 4,
        intentChanges = 3, promptsShown = 1, bloomOpened = 0,
        leaseRequests = 1, transportFailures = 0, providerTimeouts = 2 },
      gauges = { candidateCount = 1, sensorIntervalMs = 200,
        expensiveCandidateCount = 0, sensorDurationMs = 5.5,
        providerDurationMs = 3.5, intentScoringDurationMs = 2.5 } }, context)
    local rejected = observability.increment('custom_total', { playerId = '10' }, 1)
    observability.increment('lease_total', { outcome = 'issued' }, 2)
    observability.denied('lease.request', { code = 'INTERACT_SLOT_BUSY' })
    local deltas = {}
    for _, call in ipairs(calls) do
      if call.name == 'synex_interact_sensor_ticks' then
        deltas[#deltas + 1] = call.amount
      end
      assert(call.labels.playerId == nil)
      assert(call.labels.intentKey == nil)
      assert(call.labels.entityId == nil)
      assert(call.labels.leaseId == nil)
    end
    local snapshot = observability.snapshot()
    return { acceptedDelta = deltas[1], deltaCount = #deltas,
      total = snapshot.counters.sensor_ticks,
      rejectedLabel = rejected == false, rollback = rollback.code,
      sources = snapshot.clientMetricSources,
      candidateGauge = snapshot.gauges.candidate_count,
      sensorDuration = snapshot.gauges.sensor_duration_ms,
      providerDuration = snapshot.gauges.client_provider_duration_ms,
      intentDuration = snapshot.gauges.intent_scoring_duration_ms,
      providerTimeouts = snapshot.counters.client_provider_timeout_total,
      providerFailure = observability.healthSignals().providerFailure == true,
      clientProviderAdvisory = observability.clientAdvisorySignals().providerFailure == true,
      leaseGranted = snapshot.counters.lease_granted_total,
      leaseDenied = snapshot.counters.lease_denied_total,
      slotBusy = snapshot.counters.slot_busy_total }
  `, operationsFiles);

  assert.deepEqual(result, {
    acceptedDelta: 5,
    deltaCount: 1,
    total: 5,
    rejectedLabel: true,
    rollback: 'INTERACT_INVALID_REQUEST',
    sources: 1,
    candidateGauge: 1,
    sensorDuration: 5.5,
    providerDuration: 3.5,
    intentDuration: 2.5,
    providerTimeouts: 1,
    providerFailure: false,
    clientProviderAdvisory: true,
    leaseGranted: 2,
    leaseDenied: 1,
    slotBusy: 1,
  });
});

test('client telemetry treats every new epoch as a baseline and bounds accepted deltas', async () => {
  const result = await runInteractLua<{
    baselineSignal: boolean;
    inflated: string;
    acceptedDelta: number;
  }>(`
    local clock, acceptedDelta = 100, 0
    local observability = SynexInteractObservability.create({
      coreRef = { value = { Metrics = {
        increment = function(name, _, amount)
          if name == 'synex_interact_sensor_ticks' then
            acceptedDelta = acceptedDelta + amount
          end
          return true
        end,
        gauge = function() return true end,
        observe = function() return true end,
      } } },
      foundation = SynexInteractFoundation,
      now = function() return clock end,
    })
    local context = { source = 10, sourceGeneration = 2,
      session = { id = 'session-0001', state = 'ACTIVE',
        source = 10, sourceGeneration = 2 } }
    local function report(epoch, sequence, ticks, failures)
      return observability.reportClient({ clientEpoch = epoch, sequence = sequence,
        counters = { sensorTicks = ticks, candidatesSeen = ticks,
          expensiveChecks = 0, intentChanges = 0, promptsShown = 0,
          bloomOpened = 0, leaseRequests = 0,
          transportFailures = failures, providerTimeouts = 0 },
        gauges = { candidateCount = 0, sensorIntervalMs = 500,
          expensiveCandidateCount = 0, sensorDurationMs = 1,
          providerDurationMs = 0, intentScoringDurationMs = 0 } }, context)
    end
    assert(report(1, 1, 900000000000, 900000000000))
    local baselineSignal = observability.clientAdvisorySignals().sensorDegraded == true
    clock = 5100
    assert(report(2, 1, 900000000000, 900000000000))
    clock = 10100
    local _, inflated = report(2, 2, 900002000000, 900000000000)
    clock = 15100
    assert(report(2, 3, 900000000005, 900000000000))
    return { baselineSignal = baselineSignal, inflated = inflated.code,
      acceptedDelta = acceptedDelta }
  `, operationsFiles);

  assert.deepEqual(result, {
    baselineSignal: false,
    inflated: 'INTERACT_INVALID_REQUEST',
    acceptedDelta: 5,
  });
});

test('client telemetry remains advisory and cannot degrade server health by itself', async () => {
  const result = await runInteractLua<{
    health: string;
    doctor: string;
    advisory: boolean;
  }>(`
    local clock = 100
    local observability = SynexInteractObservability.create({
      coreRef = { value = {} }, foundation = SynexInteractFoundation,
      now = function() return clock end,
    })
    local context = { source = 10, sourceGeneration = 2,
      session = { id = 'session-0001', state = 'ACTIVE',
        source = 10, sourceGeneration = 2 } }
    local function report(sequence, failures)
      return observability.reportClient({ clientEpoch = 1, sequence = sequence,
        counters = { sensorTicks = sequence, candidatesSeen = 0,
          expensiveChecks = 0, intentChanges = 0, promptsShown = 0,
          bloomOpened = 0, leaseRequests = 0,
          transportFailures = failures, providerTimeouts = failures },
        gauges = { candidateCount = 0, sensorIntervalMs = 500,
          expensiveCandidateCount = 0, sensorDurationMs = 1,
          providerDurationMs = 0, intentScoringDurationMs = 0 } }, context)
    end
    assert(report(1, 0))
    clock = 5100
    assert(report(2, 1))
    local empty = { snapshot = function() return { activeLeases = 0,
        maximumActiveLeases = 100, active = 0 } end,
      listLeases = function() return { items = {}, hasMore = false } end,
      list = function() return { items = {}, hasMore = false } end }
    local diagnostics = SynexInteractDiagnostics.create({
      registry = { snapshot = function() return { bundles = 0, providers = 0 } end,
        list = empty.list, inspect = function() return nil end,
        getProvider = function() return nil end,
        getAdapter = function() return nil end },
      authority = empty,
      slots = { snapshot = function() return { slots = 0, reservations = 0 } end,
        listReservations = empty.list },
      sessions = { snapshot = function() return { active = 0 } end,
        list = empty.list },
      graph = { snapshot = function() return { active = 0 } end,
        list = empty.list },
      locks = { snapshot = function() return { active = 0 } end },
      observability = observability,
      getResourceState = function() return 'started' end,
    })
    local health = diagnostics.health()
    local doctor = diagnostics.doctor({ limit = 50 })
    local advisory = false
    for _, finding in ipairs(doctor.findings) do
      if finding.code == 'INTERACT_CLIENT_PROVIDER_ADVISORY' then
        advisory = finding.severity == 'INFO'
      end
    end
    return { health = health.status, doctor = doctor.status, advisory = advisory }
  `, operationsFiles);

  assert.deepEqual(result, { health: 'READY', doctor: 'READY', advisory: true });
});

test('development traces use a capacity and retention bounded replay buffer', async () => {
  const result = await runInteractLua<{
    frames: number;
    total: number;
    retained: number;
    firstSequence: number;
    hasMore: boolean;
    expired: number;
    invalid: string;
  }>(`
    local clock = 100
    local observability = SynexInteractObservability.create({
      coreRef = { value = {} }, foundation = SynexInteractFoundation,
      now = function() return clock end, traceEnabled = true,
    })
    for index = 1, SynexInteractLimits.maximumTraceFrames + 1 do
      assert(observability.trace('trace-0001', { phase = 'context', frame = index }))
    end
    local snapshot = observability.snapshot()
    local replay = assert(observability.replay('trace-0001', 100))
    local _, invalid = observability.replay('bad', 10)
    clock = clock + SynexInteractLimits.traceRetentionMs + 1
    local expired = observability.snapshot().traceFrames
    return { frames = snapshot.traceFrames, total = replay.total,
      retained = replay.retained, firstSequence = replay.frames[1].recordSequence,
      hasMore = replay.hasMore, expired = expired, invalid = invalid.code }
  `, operationsFiles);

  assert.deepEqual(result, {
    frames: 256,
    total: 256,
    retained: 100,
    firstSequence: 2,
    hasMore: true,
    expired: 0,
    invalid: 'INTERACT_INVALID_REQUEST',
  });
});

test('doctor reports dependency, extension, session, lock, and performance health precisely', async () => {
  const result = await runInteractLua<{
    health: string;
    dependencyHealth: string;
    worldReason: boolean;
    doctor: string;
    severitiesUppercase: boolean;
    adapterMissing: boolean;
    orphanSession: boolean;
    actorLockLeak: boolean;
    slowEvaluator: boolean;
    providerFailure: boolean;
    worldReferenceMissing: boolean;
    resolvedWorldKind: string;
  }>(`${interactBundleFactory}
    local clock = 100
    local observability = SynexInteractObservability.create({
      coreRef = { value = {} }, foundation = SynexInteractFoundation,
      now = function() return clock end,
    })
    observability.observe('evaluator_duration_ms',
      { provider_kind = 'condition', outcome = 'success' }, 9)
    observability.observe('provider_duration_ms',
      { provider_kind = 'dynamic', outcome = 'failure' }, 17)
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    local bundle = __interactBundle({ key = 'fixture:inspect_graph', entry = 'call', nodes = {
      { key = 'call', type = 'serviceCall', adapter = 'fixture:domain',
        service = 'synex.accounts', version = '1.0.0', method = 'inspect',
        request = {}, next = 'complete' },
      { key = 'complete', type = 'complete' },
    } })
    bundle.smartObjects[1].binding = {
      type = 'worldRef', kind = 'door', key = 'fixture:door',
    }
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    slots.reconcile(registry.slotDefinitions())
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local session = assert(sessions.create({ sessionId = 'session-0001',
      ownerResource = 'fixture', ownerEpoch = 1, bundleKey = 'fixture:terminal',
      bundleRevision = 1, intentKey = 'fixture:inspect',
      target = { kind = 'static', bindingKey = 'fixture:target' }, expiresAt = 5000,
      roles = {{ role = 'operator', required = true, capacity = 1, lossPolicy = 'ABORT' }},
    }))
    assert(sessions.join(session.id, { source = 10, sourceGeneration = 1,
      sessionIdentity = 'identity-0001' }, 'operator', 'lease-0001', 'reservation-0001'))
    assert(sessions.markReady(session.id, '10:1'))
    assert(sessions.setExecution(session.id, 'execution-0001'))
    local locks = SynexInteractActorLocks.create()
    assert(locks.claim('10:1', { 'actor.hands' }, session.id, 'execution-0001'))
    local graph = { snapshot = function() return { active = 0 } end,
      list = function() return { items = {}, hasMore = false, truncated = false } end }
    local authority = { snapshot = function() return { activeLeases = 0,
        actorsWithLeases = 0, maximumActiveLeases = SynexInteractLimits.maximumActiveLeases } end,
      listLeases = function() return { items = {}, hasMore = false, truncated = false } end }
    local states, resolvedWorldKind = {}, 'NONE'
    local diagnostics = SynexInteractDiagnostics.create({ registry = registry,
      authority = authority, slots = slots, sessions = sessions, graph = graph,
      locks = locks, observability = observability,
      getResourceState = function(resource) return states[resource] or 'started' end,
      resolveWorldReference = function(kind, key)
        resolvedWorldKind = kind .. '/' .. key
        return nil
      end })
    local health = diagnostics.health()
    states.synex_world = 'stopped'
    local dependencyHealth = diagnostics.health()
    states.synex_world = nil
    local report = diagnostics.doctor({ limit = 50 })
    local codes, uppercase = {}, true
    for _, finding in ipairs(report.findings) do
      codes[finding.code] = true
      uppercase = uppercase and finding.severity == string.upper(finding.severity)
    end
    local worldReason = false
    for _, reason in ipairs(dependencyHealth.reasons) do
      if reason == 'WORLD_PROVIDER_UNAVAILABLE' then worldReason = true end
    end
    return { health = health.status, dependencyHealth = dependencyHealth.status,
      worldReason = worldReason, doctor = report.status,
      severitiesUppercase = uppercase,
      adapterMissing = codes.INTERACT_ACTION_ADAPTER_MISSING == true,
      orphanSession = codes.INTERACT_ORPHAN_SESSION == true,
      actorLockLeak = codes.INTERACT_ACTOR_LOCK_LEAK == true,
      slowEvaluator = codes.INTERACT_SLOW_EVALUATOR == true,
      providerFailure = codes.INTERACT_PROVIDER_FAILURE == true,
      worldReferenceMissing = codes.INTERACT_WORLD_REFERENCE_MISSING == true,
      resolvedWorldKind = resolvedWorldKind }
  `, operationsFiles);

  assert.deepEqual(result, {
    health: 'DEGRADED',
    dependencyHealth: 'UNHEALTHY',
    worldReason: true,
    doctor: 'UNHEALTHY',
    severitiesUppercase: true,
    adapterMissing: true,
    orphanSession: true,
    actorLockLeak: true,
    slowEvaluator: true,
    providerFailure: true,
    worldReferenceMissing: true,
    resolvedWorldKind: 'door/fixture:door',
  });
});

test('rejected declared bundles remain diagnosable until a clean atomic activation', async () => {
  const result = await runInteractLua<{
    firstCode: string;
    doctorCode: boolean;
    unhealthy: string;
    remaining: number;
    activeBundles: number;
  }>(`${interactBundleFactory}
    local payload = __interactBundle({
      key = 'fixture:inspect_graph', entry = 'first', nodes = {
        { key = 'first', type = 'verifyLease', next = 'second' },
        { key = 'second', type = 'verifyTarget', next = 'first' },
      },
    })
    local record = { name = 'fixture', state = 'STARTED', epoch = 1,
      manifest = { interactionBundles = { 'interactions/fixture.interact.json' } } }
    local observability = SynexInteractObservability.create({
      coreRef = { value = {} }, foundation = SynexInteractFoundation,
      now = function() return 100 end,
    })
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    local loader = SynexInteractBundleLoader.create({ registry = registry,
      getRuntimeSnapshot = function() return { resources = { record } } end,
      checkCapability = function() return true end,
      loadResourceFile = function() return '{}' end,
      decode = function() return payload end,
      getResourceState = function() return 'started' end,
      resourceName = 'synex_interact', observability = observability })
    local report = assert(loader.discoverResource('fixture', {}))
    assert(#report.failures == 1)
    local failurePage = assert(loader.failures(10))

    local slots = SynexInteractSlots.create({ now = function() return 100 end })
    local sessions = SynexInteractSessions.create({ now = function() return 100 end })
    local locks = SynexInteractActorLocks.create()
    local graph = { snapshot = function() return { active = 0 } end,
      list = function() return { items = {}, hasMore = false } end }
    local authority = { snapshot = function() return { activeLeases = 0,
        maximumActiveLeases = SynexInteractLimits.maximumActiveLeases } end,
      listLeases = function() return { items = {}, hasMore = false } end }
    local diagnostics = SynexInteractDiagnostics.create({ registry = registry,
      authority = authority, slots = slots, sessions = sessions, graph = graph,
      locks = locks, observability = observability,
      getResourceState = function() return 'started' end,
      getBundleFailures = loader.failures })
    local doctor = diagnostics.doctor({ limit = 50 })
    local doctorCode = false
    for _, finding in ipairs(doctor.findings) do
      if finding.code == 'INTERACT_GRAPH_CYCLE' then doctorCode = true end
    end

    payload = __interactBundle()
    assert(loader.discoverResource('fixture', {}))
    local cleanPage = assert(loader.failures(10))
    return { firstCode = failurePage.items[1].code,
      doctorCode = doctorCode, unhealthy = doctor.status,
      remaining = cleanPage.total, activeBundles = registry.snapshot().bundles }
  `, bundleDiagnosticsFiles);

  assert.deepEqual(result, {
    firstCode: 'INTERACT_GRAPH_CYCLE',
    doctorCode: true,
    unhealthy: 'UNHEALTHY',
    remaining: 0,
    activeBundles: 1,
  });
});

test('control provider returns Core-compatible graph, page, health, and finding shapes', async () => {
  const result = await runInteractLua<{
    status: string;
    nodes: number;
    edges: number;
    active: number;
    committed: number;
    current: number;
    elapsed: number;
    participants: number;
    locks: number;
    leaseState: string;
    objectActors: number;
    objectLeases: number;
    objectIdentityLeaked: boolean;
    cursor: string;
    findingItems: number;
    traceItems: number;
    publicError: string;
    views: number;
  }>(`
    local definition = { key = 'fixture:graph', entry = 'verify', timeoutMs = 1000,
      nodeOrder = { 'complete', 'verify' }, nodes = {
        verify = { key = 'verify', type = 'verifyLease', next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local registry = {
      inspect = function(kind, key)
        if kind == 'graph' and key == definition.key then
          return SynexInteractValidation.copy(definition)
        end
        if kind == 'smart_object' and key == 'fixture:object' then
          return { key = key, slotOrder = { 'operator' }, binding = {
            type = 'staticTransform', position = { x = 1, y = 2, z = 3 } } }
        end
        return nil, { code = 'INTERACT_INTENT_NOT_FOUND', message = 'missing' }
      end,
      list = function(_, cursor)
        assert(cursor == 1)
        return { items = {{ key = 'fixture:bundle' }}, nextCursor = 2,
          hasMore = true, truncated = true }
      end,
    }
    local graph = {
      snapshot = function() return { active = 1 } end,
      list = function() return { items = {{ executionId = 'execution-0001',
        sessionId = 'session-0001', graph = 'fixture:graph', intent = 'fixture:intent',
        currentNode = 'verify', committed = true, state = 'RUNNING',
        startedAt = 10, deadlineAt = 1000, elapsedMs = 90,
        participantCount = 2,
        participantRoles = {{ role = 'operator', count = 1 },
          { role = 'assistant', count = 1 }},
        lockChannels = { 'actor.hands', 'actor.movement' }, leaseReleased = false }},
        hasMore = false, truncated = false } end,
    }
    local authority = { snapshot = function() return { activeLeases = 1,
        actorsWithLeases = 1, maximumActiveLeases = 100 } end,
      listLeases = function() return { items = {}, hasMore = false } end }
    authority.inspectSessionLeases = function(sessionId)
      assert(sessionId == 'session-0001')
      return { state = 'ACTIVE', activeLeaseCount = 2,
        leaseStates = {{ state = 'ACTIVE', count = 2 }}, scanComplete = true }
    end
    authority.inspectObject = function(objectKey)
      assert(objectKey == 'fixture:object')
      return { activeLeaseCount = 2, activeActorCount = 1,
        leaseStates = {{ state = 'ACTIVE', count = 2 }},
        roles = {{ role = 'operator', count = 2 }}, scanComplete = true }
    end
    local slots = { snapshot = function() return { slots = 1, reservations = 0,
        occupied = 0, reserved = 0, disabled = 0 } end,
      list = function() return { items = {}, hasMore = false } end }
    slots.inspectObject = function(objectKey, slotKeys)
      assert(objectKey == 'fixture:object' and slotKeys[1] == 'operator')
      return { items = {{ key = 'operator', state = 'OCCUPIED' }},
        hasMore = false, truncated = false }
    end
    local sessions = { list = function() return { items = {}, hasMore = false } end }
    local diagnostics = {
      health = function() return { status = 'READY', state = 'READY', reasons = {},
        dependencies = { synex_core = 'started' } } end,
      summary = function() return { bundles = 1 } end,
      doctor = function() return { status = 'DEGRADED', findings = {{
        code = 'INTERACT_PROVIDER_FAILURE', title = 'INTERACT_PROVIDER_FAILURE',
        severity = 'WARNING', message = 'Provider failed.', summary = 'Provider failed.',
      }}, hasMore = false, truncated = false } end,
    }
    local observability = { snapshot = function() return { counters = {} } end,
      denials = function() return { items = {}, hasMore = false } end,
      replay = function(traceId, limit)
        assert(traceId == 'trace-fixture-0001' and limit == 10)
        return { frames = {{ phase = 'lease_issued', at = 10 }}, total = 1,
          hasMore = false, truncated = false }
      end }
    local provider = SynexInteractControlProvider.create({ registry = registry,
      authority = authority, slots = slots, sessions = sessions, graph = graph,
      diagnostics = diagnostics, observability = observability })
    local inspected = assert(provider.operations.inspect({ view = 'graph', id = 'fixture:graph' }))
    local object = assert(provider.operations.inspect({ view = 'object', id = 'fixture:object' }))
    local listed = assert(provider.operations.list({ view = 'bundles', cursor = '1',
      limit = 1, filters = {}, sort = {} }))
    local health = assert(provider.operations.health({ view = 'health' }))
    local findings = assert(provider.operations.findings({ view = 'findings',
      limit = 10, filters = {}, sort = {} }))
    local trace = assert(provider.operations.list({ view = 'trace', limit = 10,
      filters = { trace_id = 'trace-fixture-0001' }, sort = {} }))
    local registered
    assert(provider.register({ ControlProviders = { register = function(value)
      registered = value
      return { unregister = function() end }
    end } }))
    local _, publicError = registered.operations.health({ view = 'wrong' })
    return { status = health.status, nodes = #inspected.nodes, edges = #inspected.edges,
      active = inspected.runtime.active, committed = inspected.runtime.committed,
      current = inspected.runtime.currentNodes.verify, cursor = listed.nextCursor,
      elapsed = inspected.runtime.executions[1].elapsedMs,
      participants = inspected.runtime.executions[1].participants.count,
      locks = inspected.runtime.executions[1].locks.count,
      leaseState = inspected.runtime.executions[1].lease.state,
      objectActors = object.runtime.activeActorCount,
      objectLeases = object.runtime.activeLeaseCount,
      objectIdentityLeaked = object.runtime.actorKey ~= nil
        or object.runtime.source ~= nil or object.runtime.actors ~= nil,
      findingItems = #findings.items, publicError = publicError.code,
      traceItems = #trace.items, views = #provider.views }
  `, operationsFiles);

  assert.deepEqual(result, {
    status: 'READY',
    nodes: 2,
    edges: 1,
    active: 1,
    committed: 1,
    current: 1,
    elapsed: 90,
    participants: 2,
    locks: 2,
    leaseState: 'ACTIVE',
    objectActors: 1,
    objectLeases: 2,
    objectIdentityLeaked: false,
    cursor: '2',
    findingItems: 1,
    traceItems: 1,
    publicError: 'INVALID_ARGUMENT',
    views: 15,
  });
});
