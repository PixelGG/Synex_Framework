import assert from 'node:assert/strict';
import test from 'node:test';

import { runInteractLua } from './helpers.js';

test('graph acknowledgements fail closed across execution, session, actor, node, and sequence fences', async () => {
  const result = await runInteractLua<{
    forgedExecution: string;
    forgedSession: string;
    foreignActor: string;
    staleGeneration: string;
    forgedNode: string;
    forgedSequence: string;
    accepted: boolean;
    duplicate: boolean;
    finalState: string;
    active: number;
    locks: number;
  }>(`
    local clock, tasks, finalState = 1000, {}, nil
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local function wait(ms) clock = clock + math.max(1, ms); coroutine.yield() end
    local function pump(rounds)
      for _ = 1, rounds do
        local before = #tasks
        for index = before, 1, -1 do
          local task = tasks[index]
          if coroutine.status(task) == 'dead' then table.remove(tasks, index)
          else
            local ok, operationError = coroutine.resume(task)
            assert(ok, operationError)
          end
        end
        for index = #tasks, 1, -1 do
          if coroutine.status(tasks[index]) == 'dead' then table.remove(tasks, index) end
        end
        if #tasks == 0 then break end
      end
    end
    local graphDefinition = { key = 'fixture:ack_graph', entry = 'progress', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        progress = { key = 'progress', type = 'progress', durationMs = 200,
          presentation = { label = 'Working' }, next = 'complete' },
        complete = { key = 'complete', type = 'complete' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:2'] = { source = 10, sourceGeneration = 2,
        role = 'operator' } } },
    } }
    local locks = SynexInteractActorLocks.create()
    local sessions = {
      get = function(id) if id == session.id then return session end end,
      setExecution = function(_, id)
        session.executionId, session.state = id, 'RUNNING'; return session
      end,
      finish = function(_, state) finalState = state; return true end,
      remove = function() return session end,
    }
    local graph = SynexInteractActionGraph.create({
      registry = { resolveIntent = function() return resolved end },
      now = function() return clock end, wait = wait, spawn = spawn,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      slots = { cleanupSession = function() return 0 end }, locks = locks,
      sessions = sessions,
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    pump(1)

    local function acknowledgement(overrides, context)
      local request = { executionId = 'execution-0001', sessionId = 'session-0001',
        nodeKey = 'progress', sequence = 1, result = 'completed' }
      for key, value in pairs(overrides or {}) do request[key] = value end
      return graph.ack(request, context or { source = 10, sourceGeneration = 2 })
    end
    local _, forgedExecution = acknowledgement({ executionId = 'execution-forged' })
    local _, forgedSession = acknowledgement({ sessionId = 'session-forged' })
    local _, foreignActor = acknowledgement(nil, { source = 11, sourceGeneration = 2 })
    local _, staleGeneration = acknowledgement(nil, { source = 10, sourceGeneration = 1 })
    local _, forgedNode = acknowledgement({ nodeKey = 'complete' })
    local _, forgedSequence = acknowledgement({ sequence = 2 })
    local accepted = assert(acknowledgement())
    local duplicate = assert(acknowledgement())
    pump(20)
    return { forgedExecution = forgedExecution.code, forgedSession = forgedSession.code,
      foreignActor = foreignActor.code, staleGeneration = staleGeneration.code,
      forgedNode = forgedNode.code, forgedSequence = forgedSequence.code,
      accepted = accepted.accepted, duplicate = duplicate.duplicate,
      finalState = finalState, active = graph.snapshot().active,
      locks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    forgedExecution: 'INTERACT_SESSION_NOT_FOUND',
    forgedSession: 'INTERACT_SESSION_NOT_FOUND',
    foreignActor: 'INTERACT_LEASE_STALE',
    staleGeneration: 'INTERACT_LEASE_STALE',
    forgedNode: 'INTERACT_GRAPH_INVALID',
    forgedSequence: 'INTERACT_GRAPH_INVALID',
    accepted: true,
    duplicate: true,
    finalState: 'COMPLETED',
    active: 0,
    locks: 0,
  });
});

test('sequence, branch, parallel, race, and participant barrier complete through bounded scheduling', async () => {
  const result = await runInteractLua<{
    finalState: string;
    active: number;
    locks: number;
    branchChecks: number;
    barrierChecks: number;
    sequence: number;
    branch: number;
    parallel: number;
    race: number;
    barrier: number;
    participantBarrier: number;
  }>(`
    local clock, tasks, finalState = 100, {}, nil
    local visits, branchChecks, barrierChecks = {}, 0, 0
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local function wait(ms) clock = clock + math.max(1, ms); coroutine.yield() end
    local function pump(rounds)
      for _ = 1, rounds do
        local before = #tasks
        for index = before, 1, -1 do
          local task = tasks[index]
          if coroutine.status(task) == 'dead' then table.remove(tasks, index)
          else
            local ok, operationError = coroutine.resume(task)
            assert(ok, operationError)
          end
        end
        for index = #tasks, 1, -1 do
          if coroutine.status(tasks[index]) == 'dead' then table.remove(tasks, index) end
        end
        if #tasks == 0 then break end
      end
    end
    local graphDefinition = { key = 'fixture:control_graph', entry = 'root', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        root = { key = 'root', type = 'sequence',
          children = { 'choose', 'parallel_work', 'barrier_check', 'participants' },
          next = 'race_work' },
        choose = { key = 'choose', type = 'branch', thenNode = 'chosen', elseNode = 'rejected' },
        chosen = { key = 'chosen', type = 'wait', durationMs = 10 },
        rejected = { key = 'rejected', type = 'fail', code = 'WRONG_BRANCH' },
        parallel_work = { key = 'parallel_work', type = 'parallel',
          children = { 'parallel_a', 'parallel_b' } },
        parallel_a = { key = 'parallel_a', type = 'wait', durationMs = 20 },
        parallel_b = { key = 'parallel_b', type = 'wait', durationMs = 30 },
        barrier_check = { key = 'barrier_check', type = 'barrier' },
        participants = { key = 'participants', type = 'participantBarrier' },
        race_work = { key = 'race_work', type = 'race',
          children = { 'race_fast', 'race_slow' }, next = 'complete' },
        race_fast = { key = 'race_fast', type = 'wait', durationMs = 10 },
        race_slow = { key = 'race_slow', type = 'wait', durationMs = 500 },
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
      registry = { resolveIntent = function() return resolved end },
      now = function() return clock end, wait = wait, spawn = spawn,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      verify = function(kind)
        if kind == 'condition' then branchChecks = branchChecks + 1; return true end
        if kind == 'barrier' then barrierChecks = barrierChecks + 1; return true end
        return true
      end,
      slots = { cleanupSession = function() return 0 end }, locks = locks,
      sessions = {
        get = function() return session end,
        setExecution = function(_, id)
          session.executionId, session.state = id, 'RUNNING'; return session
        end,
        finish = function(_, state) finalState = state; return true end,
        remove = function() return session end,
      },
      observability = {
        trace = function(_, frame)
          if frame.phase == 'node' then visits[frame.category] = (visits[frame.category] or 0) + 1 end
        end,
        increment = function() end, observe = function() end,
      },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    pump(100)
    return { finalState = finalState, active = graph.snapshot().active,
      locks = locks.snapshot().active, branchChecks = branchChecks,
      barrierChecks = barrierChecks, sequence = visits.sequence or 0,
      branch = visits.branch or 0, parallel = visits.parallel or 0,
      race = visits.race or 0, barrier = visits.barrier or 0,
      participantBarrier = visits.participantBarrier or 0,
    }
  `);

  assert.deepEqual(result, {
    finalState: 'COMPLETED',
    active: 0,
    locks: 0,
    branchChecks: 1,
    barrierChecks: 2,
    sequence: 1,
    branch: 1,
    parallel: 1,
    race: 1,
    barrier: 1,
    participantBarrier: 1,
  });
});

test('nested complete propagates through every control node and suppresses later side effects', async () => {
  const result = await runInteractLua<{
    finalState: string;
    finalReason: string;
    adapterCalls: string[];
    active: number;
  }>(`
    local finalState, finalReason, adapterCalls = nil, nil, {}
    local graphDefinition = { key = 'fixture:terminal_graph', entry = 'root', timeoutMs = 5000,
      nodes = {
        root = { key = 'root', type = 'sequence',
          children = { 'before', 'choose', 'sequence_after' }, next = 'root_after' },
        before = { key = 'before', type = 'serviceCall', adapter = 'fixture:domain' },
        choose = { key = 'choose', type = 'branch', thenNode = 'retry_work', elseNode = 'failed' },
        retry_work = { key = 'retry_work', type = 'retry', maxAttempts = 2,
          children = { 'timeout_work' }, next = 'retry_after' },
        timeout_work = { key = 'timeout_work', type = 'timeout', timeoutMs = 100,
          children = { 'parallel_work' }, next = 'timeout_after' },
        parallel_work = { key = 'parallel_work', type = 'parallel',
          children = { 'race_work', 'parallel_after' }, next = 'parallel_next' },
        race_work = { key = 'race_work', type = 'race',
          children = { 'complete', 'race_after' }, next = 'race_next' },
        complete = { key = 'complete', type = 'complete' },
        failed = { key = 'failed', type = 'fail', code = 'WRONG_BRANCH' },
        race_after = { key = 'race_after', type = 'serviceCall', adapter = 'fixture:domain' },
        race_next = { key = 'race_next', type = 'serviceCall', adapter = 'fixture:domain' },
        parallel_after = { key = 'parallel_after', type = 'serviceCall', adapter = 'fixture:domain' },
        parallel_next = { key = 'parallel_next', type = 'serviceCall', adapter = 'fixture:domain' },
        timeout_after = { key = 'timeout_after', type = 'serviceCall', adapter = 'fixture:domain' },
        retry_after = { key = 'retry_after', type = 'serviceCall', adapter = 'fixture:domain' },
        sequence_after = { key = 'sequence_after', type = 'serviceCall', adapter = 'fixture:domain' },
        root_after = { key = 'root_after', type = 'serviceCall', adapter = 'fixture:domain' },
      } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator' } } },
    } }
    local graph = SynexInteractActionGraph.create({
      registry = {
        resolveIntent = function() return resolved end,
        getAdapter = function()
          return { owner = 'fixture', epoch = 1, handler = function(request)
            adapterCalls[#adapterCalls + 1] = request.nodeKey
            return { accepted = true }
          end }
        end,
      },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      verify = function(kind) if kind == 'condition' then return true end; return true end,
      slots = { cleanupSession = function() return 0 end },
      locks = SynexInteractActorLocks.create(),
      sessions = {
        get = function() return session end,
        setExecution = function(_, id) session.executionId = id; return session end,
        finish = function(_, state, reason)
          finalState, finalReason = state, reason; return true
        end,
        remove = function() return session end,
      },
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    return { finalState = finalState, finalReason = finalReason or 'NONE',
      adapterCalls = adapterCalls, active = graph.snapshot().active }
  `);

  assert.deepEqual(result, {
    finalState: 'COMPLETED',
    finalReason: 'NONE',
    adapterCalls: ['before'],
    active: 0,
  });
});

test('runtime fails closed when an uncompiled root returns without complete', async () => {
  const result = await runInteractLua<{
    finalState: string;
    finalReason: string;
    active: number;
  }>(`
    local finalState, finalReason = nil, nil
    local graphDefinition = { key = 'fixture:invalid_graph', entry = 'work', timeoutMs = 5000,
      nodes = { work = { key = 'work', type = 'wait', durationMs = 0 } } }
    local resolved = { bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      intent = { key = 'fixture:intent', executionPolicy = { lockChannels = {} } },
      graph = graphDefinition }
    local session = { id = 'session-0001', state = 'READY', roles = {
      operator = { members = { ['10:1'] = { source = 10, sourceGeneration = 1,
        role = 'operator' } } },
    } }
    local graph = SynexInteractActionGraph.create({
      registry = { resolveIntent = function() return resolved end },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      slots = { cleanupSession = function() return 0 end },
      locks = SynexInteractActorLocks.create(),
      sessions = {
        get = function() return session end,
        setExecution = function(_, id) session.executionId = id; return session end,
        finish = function(_, state, reason)
          finalState, finalReason = state, reason; return true
        end,
        remove = function() return session end,
      },
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    return { finalState = finalState, finalReason = finalReason,
      active = graph.snapshot().active }
  `);

  assert.deepEqual(result, {
    finalState: 'FAILED',
    finalReason: 'INTERACT_GRAPH_INVALID',
    active: 0,
  });
});

test('node timeout runs declared cleanup and terminal cleanup exactly once', async () => {
  const result = await runInteractLua<{
    finalState: string;
    finalReason: string;
    cleanupAdapterCalls: number;
    leaseReleases: number;
    slotCleanups: number;
    clientCleanups: number;
    active: number;
    locks: number;
  }>(`
    local clock, tasks = 100, {}
    local finalState, finalReason, cleanupAdapterCalls = nil, nil, 0
    local leaseReleases, slotCleanups, clientCleanups = 0, 0, 0
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local function wait(ms) clock = clock + math.max(1, ms); coroutine.yield() end
    local function pump(rounds)
      for _ = 1, rounds do
        local before = #tasks
        for index = before, 1, -1 do
          local task = tasks[index]
          if coroutine.status(task) == 'dead' then table.remove(tasks, index)
          else
            local ok, operationError = coroutine.resume(task)
            assert(ok, operationError)
          end
        end
        for index = #tasks, 1, -1 do
          if coroutine.status(tasks[index]) == 'dead' then table.remove(tasks, index) end
        end
        if #tasks == 0 then break end
      end
    end
    local graphDefinition = { key = 'fixture:timeout_graph', entry = 'bounded', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        bounded = { key = 'bounded', type = 'timeout', children = { 'slow' },
          timeoutMs = 100, cleanup = 'cleanup' },
        slow = { key = 'slow', type = 'wait', durationMs = 1000 },
        cleanup = { key = 'cleanup', type = 'removeTemporaryEntity',
          adapter = 'fixture:cleanup' },
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
        getAdapter = function()
          return { owner = 'fixture', epoch = 1, kind = 'adapter', handler = function(request)
            assert(request.phase == 'CLEANUP_TEMPORARY')
            cleanupAdapterCalls = cleanupAdapterCalls + 1
            return { removed = true }
          end }
        end },
      now = function() return clock end, wait = wait, spawn = spawn,
      nextId = function() return 'execution-0001' end,
      emit = function(_, payload)
        if payload.type == 'cleanup' then clientCleanups = clientCleanups + 1 end
        return true
      end,
      slots = { cleanupSession = function() slotCleanups = slotCleanups + 1; return 1 end },
      locks = locks,
      sessions = {
        get = function() return session end,
        setExecution = function(_, id)
          session.executionId, session.state = id, 'RUNNING'; return session
        end,
        finish = function(_, state, reason)
          finalState, finalReason = state, reason; return true
        end,
        remove = function() return session end,
      },
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
      releaseLease = function()
        leaseReleases = leaseReleases + 1
        return { released = 1 }
      end,
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    pump(100)
    return { finalState = finalState, finalReason = finalReason,
      cleanupAdapterCalls = cleanupAdapterCalls, leaseReleases = leaseReleases,
      slotCleanups = slotCleanups, clientCleanups = clientCleanups,
      active = graph.snapshot().active, locks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    finalState: 'TIMED_OUT',
    finalReason: 'INTERACT_TIMEOUT',
    cleanupAdapterCalls: 1,
    leaseReleases: 1,
    slotCleanups: 1,
    clientCleanups: 1,
    active: 0,
    locks: 0,
  });
});

test('non-retryable domain failure executes declared cleanup and releases authority state', async () => {
  const result = await runInteractLua<{
    finalState: string;
    finalReason: string;
    executeCalls: number;
    cleanupCalls: number;
    leaseReleases: number;
    active: number;
    locks: number;
  }>(`
    local finalState, finalReason, executeCalls, cleanupCalls, leaseReleases = nil, nil, 0, 0, 0
    local graphDefinition = { key = 'fixture:domain_graph', entry = 'domain', timeoutMs = 5000,
      locks = { 'actor.hands' }, nodes = {
        domain = { key = 'domain', type = 'serviceCall', adapter = 'fixture:domain',
          service = 'synex.fixture', version = '1.0.0', method = 'deny', request = {},
          cleanup = 'cleanup', next = 'complete' },
        cleanup = { key = 'cleanup', type = 'removeTemporaryEntity', adapter = 'fixture:domain' },
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
        getAdapter = function()
          return { owner = 'fixture', epoch = 1, kind = 'adapter', handler = function(request)
            if request.phase == 'EXECUTE' then
              executeCalls = executeCalls + 1
              return nil, { code = 'DOMAIN_DENIED', message = 'Denied.', retryable = false }
            end
            assert(request.phase == 'CLEANUP_TEMPORARY')
            cleanupCalls = cleanupCalls + 1
            return { removed = true }
          end }
        end },
      now = function() return 100 end, wait = function() end,
      spawn = function(handler) handler() end,
      nextId = function() return 'execution-0001' end,
      emit = function() return true end,
      slots = { cleanupSession = function() return 1 end }, locks = locks,
      sessions = {
        get = function() return session end,
        setExecution = function(_, id)
          session.executionId, session.state = id, 'RUNNING'; return session
        end,
        finish = function(_, state, reason)
          finalState, finalReason = state, reason; return true
        end,
        remove = function() return session end,
      },
      observability = { trace = function() end, increment = function() end,
        observe = function() end },
      releaseLease = function()
        leaseReleases = leaseReleases + 1
        return { released = 1 }
      end,
    })
    assert(graph.start(session, resolved, { id = 'lease-0001',
      target = { kind = 'static', bindingKey = 'fixture:target' } },
      { traceId = 'trace-0001' }))
    return { finalState = finalState, finalReason = finalReason,
      executeCalls = executeCalls, cleanupCalls = cleanupCalls,
      leaseReleases = leaseReleases, active = graph.snapshot().active,
      locks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    finalState: 'FAILED',
    finalReason: 'DOMAIN_DENIED',
    executeCalls: 1,
    cleanupCalls: 1,
    leaseReleases: 1,
    active: 0,
    locks: 0,
  });
});
