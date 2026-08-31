import assert from 'node:assert/strict';
import test from 'node:test';

import { runInteractLua } from './helpers.js';

test('action graph commits once, treats acknowledgements as telemetry, and releases all locks', async () => {
  const result = await runInteractLua<{
    calls: number;
    emitted: number;
    activeExecutions: number;
    activeLocks: number;
    finalState: string;
    lateAck: string;
    graphStarted: number;
    graphCompleted: number;
    nodeDurations: number;
  }>(`
    local clock, calls, emitted, finalState = 1000, 0, 0, nil
    local metrics, nodeDurations = {}, 0
    local adapter = { owner = 'fixture', epoch = 1, kind = 'adapter',
      handler = function(request)
        calls = calls + 1
        assert(request.phase == 'COMMIT')
        assert(request.idempotencyKey == 'execution-0001:domain_commit')
        return { committed = true }
      end }
    local graphDefinition = { key = 'fixture:graph', entry = 'progress', timeoutMs = 10000,
      locks = { 'actor.hands' }, nodes = {
        progress = { key = 'progress', type = 'progress', durationMs = 100,
          presentation = { label = 'Working' }, next = 'commit' },
        commit = { key = 'commit', type = 'commit', adapter = 'fixture:adapter',
          commitKey = 'domain_commit', next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local registry = {
      resolveIntent = function() return resolved end,
      getAdapter = function(key) if key == 'fixture:adapter' then return adapter end end,
    }
    local locks = SynexInteractActorLocks.create()
    local slots = { cleanupSession = function() return 0 end }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:2'] = { source = 10, sourceGeneration = 2,
        role = 'operator' } } },
    } }
    local sessions = {
      get = function(id) if id == session.id then return session end end,
      setExecution = function(_, id) session.executionId, session.state = id, 'RUNNING'; return session end,
      finish = function(_, state) session.state, finalState = state, state; return true end,
    }
    local graph = SynexInteractActionGraph.create({ registry = registry,
      now = function() return clock end,
      wait = function(ms) clock = clock + math.max(1, ms) end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function(_, payload) emitted = emitted + 1; return payload end,
      verify = function() return true end, slots = slots, locks = locks,
      sessions = sessions,
      observability = { trace = function() end,
        increment = function(name) metrics[name] = (metrics[name] or 0) + 1 end,
        observe = function(name) if name == 'graph_node_duration' then
          nodeDurations = nodeDurations + 1 end end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    local _, lateAck = graph.ack({ executionId = 'execution-0001',
      sessionId = 'session-0001', nodeKey = 'progress', sequence = 1,
      result = 'completed' }, { source = 10, sourceGeneration = 2 })
    return { calls = calls, emitted = emitted,
      activeExecutions = graph.snapshot().active, activeLocks = locks.snapshot().active,
      finalState = finalState, lateAck = lateAck.code,
      graphStarted = metrics.graph_started_total or 0,
      graphCompleted = metrics.graph_completed_total or 0,
      nodeDurations = nodeDurations }
  `);

  assert.deepEqual(result, {
    calls: 1,
    emitted: 2,
    activeExecutions: 0,
    activeLocks: 0,
    finalState: 'COMPLETED',
    lateAck: 'INTERACT_SESSION_NOT_FOUND',
    graphStarted: 1,
    graphCompleted: 1,
    nodeDurations: 3,
  });
});

test('action graph contains adapter exceptions and performs idempotent cleanup', async () => {
  const result = await runInteractLua<{
    state: string;
    active: number;
    locks: number;
    cleanupSignals: number;
    failedMetric: number;
  }>(`
    local state, cleanupSignals, failedMetric = nil, 0, 0
    local graphDefinition = { key = 'fixture:graph', entry = 'call', timeoutMs = 1000,
      locks = { 'actor.hands' }, nodes = {
        call = { key = 'call', type = 'serviceCall', adapter = 'fixture:adapter',
          service = 'synex.accounts', version = '1.0.0', method = 'withdraw',
          request = {}, next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator' } } },
    } }
    local locks = SynexInteractActorLocks.create()
    local graph = SynexInteractActionGraph.create({
      registry = { resolveIntent = function() return resolved end,
        getAdapter = function() return { owner = 'fixture', epoch = 1,
          kind = 'adapter', handler = function() error('private failure') end } end },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function(_, payload) if payload.type == 'cleanup' then
        cleanupSignals = cleanupSignals + 1
        error('transport unavailable')
      end return true end,
      slots = { cleanupSession = function() return 0 end }, locks = locks,
      sessions = { get = function() return session end,
        setExecution = function(_, id) session.executionId, session.state = id, 'RUNNING'; return session end,
        finish = function(_, nextState) state = nextState; return true end },
      observability = { trace = function() end, increment = function(name)
          if name == 'graph_failed_total' then failedMetric = failedMetric + 1 end
        end,
        observe = function() end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    return { state = state, active = graph.snapshot().active,
      locks = locks.snapshot().active, cleanupSignals = cleanupSignals,
      failedMetric = failedMetric }
  `);

  assert.deepEqual(result, {
    state: 'FAILED',
    active: 0,
    locks: 0,
    cleanupSignals: 1,
    failedMetric: 1,
  });
});

test('action graph retries only declared failures, commits once, and releases its lease once', async () => {
  const result = await runInteractLua<{
    calls: number;
    leaseReleases: number;
    finalState: string;
    active: number;
  }>(`
    local calls, leaseReleases, finalState = 0, 0, nil
    local graphDefinition = { key = 'fixture:graph', entry = 'retry', timeoutMs = 5000,
      nodes = {
        retry = { key = 'retry', type = 'retry', children = { 'commit' },
          maxAttempts = 3, backoffMs = 1, retryableErrors = { 'TRANSIENT' },
          next = 'release' },
        commit = { key = 'commit', type = 'commit', adapter = 'fixture:adapter',
          commitKey = 'domain_commit' },
        release = { key = 'release', type = 'releaseLease', next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator' } } },
    } }
    local sessions = {
      get = function() return session end,
      setExecution = function(_, id) session.executionId, session.state = id, 'RUNNING'; return session end,
      finish = function(_, state) finalState = state; return true end,
      remove = function() return session end,
    }
    local graph = SynexInteractActionGraph.create({
      registry = {
        resolveIntent = function() return resolved end,
        getAdapter = function() return { owner = 'fixture', epoch = 1, kind = 'adapter',
          handler = function(request)
            calls = calls + 1
            assert(request.idempotencyKey == 'execution-0001:domain_commit')
            if calls == 1 then return nil, { code = 'TRANSIENT', message = 'retry', retryable = true } end
            return { committed = true }
          end }
        end,
      },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      slots = { cleanupSession = function() return 0 end },
      locks = SynexInteractActorLocks.create(), sessions = sessions,
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
      releaseLease = function(sessionId, leaseId)
        assert(sessionId == 'session-0001' and leaseId == 'lease-0001')
        leaseReleases = leaseReleases + 1
        return { released = 1 }
      end,
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    return { calls = calls, leaseReleases = leaseReleases,
      finalState = finalState, active = graph.snapshot().active }
  `);

  assert.deepEqual(result, {
    calls: 2,
    leaseReleases: 1,
    finalState: 'COMPLETED',
    active: 0,
  });
});

test('mandatory pre-commit authority failure prevents every domain side effect', async () => {
  const result = await runInteractLua<{
    adapterCalls: number;
    commitChecks: number;
    finalState: string;
    activeLocks: number;
  }>(`
    local adapterCalls, commitChecks, finalState = 0, 0, nil
    local graphDefinition = { key = 'fixture:graph', entry = 'commit', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        commit = { key = 'commit', type = 'commit', adapter = 'fixture:adapter',
          commitKey = 'domain_commit', next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator', ready = true } } },
    } }
    local sessions = {
      get = function() return session end,
      setExecution = function(_, id)
        session.executionId, session.state = id, 'RUNNING'; return session
      end,
      finish = function(_, state) finalState = state; return true end,
      remove = function() return session end,
    }
    local locks = SynexInteractActorLocks.create()
    local graph = SynexInteractActionGraph.create({
      registry = {
        resolveIntent = function() return resolved end,
        getAdapter = function() return { owner = 'fixture', epoch = 1,
          definition = { timeoutMs = 1000 }, kind = 'adapter',
          handler = function() adapterCalls = adapterCalls + 1; return true end }
        end,
      },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      verify = function(kind)
        if kind == 'commit' then
          commitChecks = commitChecks + 1
          return nil, { code = 'INTERACT_TARGET_STALE',
            message = 'target changed', retryable = false }
        end
        return true
      end,
      slots = { cleanupSession = function() return 0 end },
      locks = locks, sessions = sessions,
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
      releaseLease = function() return true end,
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:terminal' } },
      { traceId = 'trace-0001' }))
    return { adapterCalls = adapterCalls, commitChecks = commitChecks,
      finalState = finalState, activeLocks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    adapterCalls: 0,
    commitChecks: 1,
    finalState: 'FAILED',
    activeLocks: 0,
  });
});

test('replacement participants pause and resume the same graph execution without stale locks', async () => {
  const result = await runInteractLua<{
    pausedState: string;
    resumed: boolean;
    lateJoin: string;
    finalState: string;
    locks: number;
  }>(`
    local clock, tasks, finalState = 100, {}, nil
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local function wait(ms) clock = clock + math.max(1, ms); coroutine.yield() end
    local function pump(rounds)
      for _ = 1, rounds do
        for index = #tasks, 1, -1 do
          if coroutine.status(tasks[index]) == 'dead' then table.remove(tasks, index)
          else assert(coroutine.resume(tasks[index])) end
        end
        if #tasks == 0 then break end
      end
    end
    local graphDefinition = { key = 'fixture:graph', entry = 'wait', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        wait = { key = 'wait', type = 'wait', durationMs = 200, next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local session = assert(sessions.create({ sessionId = 'session-0001',
      ownerResource = 'fixture', ownerEpoch = 1, bundleKey = 'fixture:bundle',
      bundleRevision = 1, intentKey = 'fixture:intent',
      target = { kind = 'static', bindingKey = 'fixture:target' }, expiresAt = 5000,
      roles = {{ role = 'operator', required = true, capacity = 1, lossPolicy = 'REPLACE' }},
    }))
    assert(sessions.join(session.id, { source = 10, sourceGeneration = 1,
      sessionIdentity = 'identity-0001' }, 'operator', 'lease-0001', 'reservation-0001'))
    assert(sessions.markReady(session.id, '10:1'))
    local locks = SynexInteractActorLocks.create()
    local graph = SynexInteractActionGraph.create({
      registry = { resolveIntent = function() return resolved end },
      now = function() return clock end, wait = wait, spawn = spawn,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      slots = { cleanupSession = function() return 0 end }, locks = locks,
      sessions = sessions,
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
      onFinished = function(_, state) finalState = state end,
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    pump(1)
    local left = assert(sessions.leave(session.id, '10:1', 'PARTICIPANT_LOST'))
    assert(graph.participantLeft(session.id, '10:1', left.policy, nil, 'PARTICIPANT_LOST'))
    pump(1)
    local pausedState = graph.list(0, 10).items[1].state
    assert(sessions.join(session.id, { source = 11, sourceGeneration = 1,
      sessionIdentity = 'identity-0002' }, 'operator', 'lease-0002', 'reservation-0001'))
    assert(sessions.markReady(session.id, '11:1'))
    local resumed = assert(graph.resume(session, resolved, { id = 'lease-0002' }))
    local _, lateJoin = sessions.join(session.id, { source = 12, sourceGeneration = 1,
      sessionIdentity = 'identity-0003' }, 'operator', 'lease-0003', 'reservation-0003')
    pump(20)
    return { pausedState = pausedState, resumed = resumed.resumed,
      lateJoin = lateJoin.code, finalState = finalState, locks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    pausedState: 'PREPARING',
    resumed: true,
    lateJoin: 'INTERACT_PARTICIPANT_DENIED',
    finalState: 'COMPLETED',
    locks: 0,
  });
});

test('action graph cancellation preserves the reason and emits one cancelled terminal metric', async () => {
  const result = await runInteractLua<{
    finalState: string;
    reason: string;
    cancelledMetric: number;
    active: number;
  }>(`
    local tasks, finalState, reason, cancelledMetric = {}, nil, nil, 0
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local graphDefinition = { key = 'fixture:graph', entry = 'wait', timeoutMs = 5000,
      nodes = {
        wait = { key = 'wait', type = 'wait', durationMs = 1000, next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator' } } },
    } }
    local graph = SynexInteractActionGraph.create({
      registry = { resolveIntent = function() return resolved end },
      now = function() return 100 end,
      wait = function() coroutine.yield() end, spawn = spawn,
      nextId = function() return 'execution-0001' end,
      emit = function(_, payload) if payload.type == 'cleanup' then reason = payload.reason end
        return true end,
      slots = { cleanupSession = function() return 0 end },
      locks = SynexInteractActorLocks.create(),
      sessions = {
        get = function() return session end,
        setExecution = function(_, id) session.executionId, session.state = id, 'RUNNING'; return session end,
        finish = function(_, state) finalState = state; return true end,
        remove = function() return session end,
      },
      observability = { trace = function() end, increment = function(name)
          if name == 'graph_cancelled_total' then cancelledMetric = cancelledMetric + 1 end
        end, observe = function() end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    assert(graph.cancel(session.id, 'ACTOR_DIED'))
    assert(graph.cancel(session.id, 'ACTOR_DIED'))
    for _, task in ipairs(tasks) do assert(coroutine.resume(task)) end
    return { finalState = finalState, reason = reason,
      cancelledMetric = cancelledMetric, active = graph.snapshot().active }
  `);

  assert.deepEqual(result, {
    finalState: 'ABORTED',
    reason: 'ACTOR_DIED',
    cancelledMetric: 1,
    active: 0,
  });
});
