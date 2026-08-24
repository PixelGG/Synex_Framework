import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function engineWith(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await engine.doString(await readFile(path.join(
    root,
    'core/synex_core/server/factories.lua',
  ), 'utf8'));
  for (const module of modules) {
    await engine.doString(await readFile(path.join(
      root,
      `core/synex_core/server/${module}.lua`,
    ), 'utf8'));
  }
  return engine;
}

test('persistence activity gate spans complete adapter calls and exposes only coroutine-local control work', async () => {
  const engine = await engineWith(['foundation', 'persistence']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 7 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + delay end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = nil
      local adapterCalls = 0

      local function activeKind(kind)
        local snapshot = database:activity()
        assert(snapshot.active == 1 and snapshot.kinds[kind] == 1)
        adapterCalls = adapterCalls + 1
      end

      local adapter = {
        query = function()
          activeKind('query')
          return {}
        end,
        scalar = function()
          activeKind('scalar')
          return 7
        end,
        insert = function()
          activeKind('insert')
          return 11
        end,
        update = function()
          activeKind('update')
          return 1
        end,
        transaction = function()
          activeKind('batch')
          return true
        end,
        startTransaction = function(handler)
          activeKind('interactive')
          local fence = assert(database:beginDrain())
          assert(fence.draining == true and fence.active == 1)
          local blocked, blockedError = database:update('UPDATE blocked', {})
          assert(blocked == nil and blockedError.code == 'DATABASE_DRAINING')
          local drained, drainError = database:waitForDrain(20, 5)
          assert(drained == nil and drainError.code == 'RESTART_DATABASE_DRAIN_TIMEOUT')
          local transactionCalls = 0
          local completed = handler(function()
            transactionCalls = transactionCalls + 1
            return { affectedRows = 1 }
          end)
          assert(completed == true and transactionCalls == 1)
          return true
        end
      }

      local persistence = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        db = adapter,
        instanceId = 'database-drain-test',
        config = { deadlockRetries = 0, queryWarnMs = 1000 }
      })
      database = persistence.database

      assert(database:query('SELECT fixture', {}))
      assert(database:scalar('SELECT scalar', {}) == 7)
      assert(database:insert('INSERT fixture', {}) == 11)
      assert(database:update('UPDATE fixture', {}) == 1)
      assert(database:transaction({ { query = 'UPDATE fixture', values = {} } }))
      assert(database:withTransaction(function(query)
        assert(query('UPDATE transaction', {}).affectedRows == 1)
        return true
      end))

      local snapshot = database:activity()
      assert(snapshot.draining == true and snapshot.active == 0 and next(snapshot.kinds) == nil)
      local blocked, blockedError = database:transaction({ { query = 'SELECT 1', values = {} } })
      assert(blocked == nil and blockedError.code == 'DATABASE_DRAINING')

      local foreignError = nil
      local controlled = assert(database:withControl(function()
        local foreign = coroutine.create(function()
          local foreignResult
          foreignResult, foreignError = database:update('UPDATE foreign coroutine', {})
          assert(foreignResult == nil)
        end)
        assert(coroutine.resume(foreign))
        assert(foreignError.code == 'DATABASE_DRAINING')
        return database:update('UPDATE shutdown control', {})
      end))
      assert(controlled == 1)
      local raised, controlError = database:withControl(function()
        error('fixture control exception')
      end)
      assert(raised == nil and controlError.code == 'DATABASE_CONTROL_FAILED')
      local denied, deniedError = database:query('SELECT denied', {})
      assert(denied == nil and deniedError.code == 'DATABASE_DRAINING')
      assert(database:activity().active == 0)
      return table.concat({adapterCalls, snapshot.active, blockedError.code,
        foreignError.code, controlError.code, deniedError.code}, ':')
    `);
    assert.equal(
      result,
      '7:0:DATABASE_DRAINING:DATABASE_DRAINING:DATABASE_CONTROL_FAILED:DATABASE_DRAINING',
    );
  } finally {
    engine.global.close();
  }
});

test('restart preparation drains database work and rejects unsafe timeout, owner, or scheduler evidence', async () => {
  const engine = await engineWith(['foundation', 'bootstrap_restart']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 9 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })

      local function fixture(options)
        options = options or {}
        local calls, statuses = {}, {}
        local state, controlDepth, draining = 'READY', 0, false
        local databaseWaitCompleted = false
        local ownerPresent = true
        local database = {}
        function database:beginDrain()
          calls[#calls + 1] = 'database:begin'
          draining = true
          return { draining = true, active = options.activeAtFence or 0, kinds = {} }, nil
        end
        function database:waitForDrain()
          calls[#calls + 1] = 'database:wait'
          if options.drainTimeout then
            return nil, foundation.error('RESTART_DATABASE_DRAIN_TIMEOUT',
              'fixture database drain timeout', { retryable = true })
          end
          databaseWaitCompleted = true
          return { draining = true, active = 0, kinds = {}, durationMs = 5, polls = 1 }, nil
        end
        function database:withControl(handler)
          calls[#calls + 1] = 'database:control'
          controlDepth = controlDepth + 1
          local packed = table.pack(pcall(handler))
          controlDepth = controlDepth - 1
          if not packed[1] then error(packed[2], 0) end
          return table.unpack(packed, 2, packed.n)
        end
        function database:activity()
          calls[#calls + 1] = 'database:activity'
          return { draining = draining, active = options.finalActive or 0, kinds = {} }
        end

        local lifecycle = {
          core = {
            get = function() return state end,
            setCriticalFoundationsValidated = function() end,
            transition = function(_, target)
              state = target
              calls[#calls + 1] = 'state:' .. target
              return 1, nil
            end
          },
          reload = {
            quiesce = function()
              assert(controlDepth == 0, 'owner cleanup must not inherit database control authority')
              assert(databaseWaitCompleted,
                'pre-existing database activity must drain before owner evidence is collected')
              calls[#calls + 1] = 'owner:quiesce'
              ownerPresent = false
              return {
                timedOut = options.ownerTimedOut == true,
                pendingAtStart = options.ownerTimedOut and 1 or 0,
                aborted = options.ownerTimedOut and 1 or 0,
                abortErrors = {}, cleanup = { errors = {} }
              }, nil
            end
          },
          scheduler = {
            capacity = function()
              calls[#calls + 1] = 'scheduler:capacity'
              return {
                runningHandlers = options.schedulerRunning or 0,
                detachedRunningHandlers = options.schedulerDetached or 0
              }
            end
          }
        }
        if options.schedulerUnavailable then lifecycle.scheduler = nil end
        local instances = {
          setStatus = function(_, status)
            assert(controlDepth == 1)
            statuses[#statuses + 1] = status
            calls[#calls + 1] = 'status:' .. status
            return true, nil
          end,
          terminateLocalSessions = function()
            assert(controlDepth == 1)
            calls[#calls + 1] = 'sessions:terminate'
            return true, nil
          end
        }
        local controller = SynexCoreFactories.bootstrapRestart({
          foundation = foundation,
          runtimeGate = { stop = function() calls[#calls + 1] = 'gate:stop' end },
          lifecycle = lifecycle,
          identity = { connections = {
            quiesce = function()
              calls[#calls + 1] = 'connections:quiesce'
              return { removedPending = 0 }, nil
            end,
            releaseQuiescedLeases = function()
              assert(controlDepth == 1)
              calls[#calls + 1] = 'connections:release'
              return { leaseReleaseFailures = 0 }, nil
            end
          } },
          persistence = { database = database, instances = instances },
          registries = { owners = { list = function()
            if not ownerPresent then return {} end
            return { { resource = 'synex_fixture', epoch = 1 } }
          end } },
          facadeCache = { fixture = true },
          coreResource = 'synex_core',
          evictConnectedPlayers = function()
            calls[#calls + 1] = 'players:evict'
            return 0, nil
          end,
          drainQuiescedTerminals = function()
            calls[#calls + 1] = 'deferrals:drain'
            return { completed = 0, failures = 0 }, nil
          end,
          databaseDrainTimeoutMs = 20,
          databaseDrainPollMs = 5
        })
        return controller, calls, statuses, function() return state end
      end

      local preparedController, preparedCalls, preparedStatuses, preparedState = fixture()
      local prepared, preparedError = preparedController:prepare()
      assert(prepared and preparedError == nil and prepared.state == 'prepared')
      assert(prepared.restartCommand == 'restart synex_core')
      assert(prepared.databaseDrain.active == 0 and prepared.databaseActivity.active == 0)
      assert(prepared.scheduler.runningHandlers == 0
        and prepared.scheduler.detachedRunningHandlers == 0)
      assert(table.concat(preparedStatuses, ',') == 'stopping,stopped')
      assert(preparedState() == 'STOPPED')
      local preparedOrder = table.concat(preparedCalls, '|')
      assert(preparedOrder:find(
        'players:evict|database:begin|deferrals:drain|database:wait|owner:quiesce',
        1, true))
      assert(preparedOrder:find('owner:quiesce|database:control|status:stopping', 1, true))

      local timeoutOptions = { drainTimeout = true }
      local timeoutController, timeoutCalls, timeoutStatuses, timeoutState = fixture(timeoutOptions)
      local timeoutReport, timeoutError = timeoutController:prepare()
      assert(timeoutReport == nil and timeoutError.code == 'RESTART_DATABASE_DRAIN_TIMEOUT')
      assert(#timeoutStatuses == 0 and timeoutState() == 'STOPPING')
      local timeoutOrder = table.concat(timeoutCalls, '|')
      assert(not timeoutOrder:find('database:control', 1, true)
        and not timeoutOrder:find('owner:quiesce', 1, true))
      timeoutOptions.drainTimeout = false
      local timeoutRetry, timeoutRetryError = timeoutController:prepare()
      assert(timeoutRetry and timeoutRetryError == nil and timeoutRetry.state == 'prepared')
      assert(timeoutRetry.restartCommand == 'restart synex_core')

      local ownerController, ownerCalls, ownerStatuses, ownerState = fixture({ ownerTimedOut = true })
      local ownerReport, ownerError = ownerController:prepare()
      assert(ownerReport == nil and ownerError.code == 'RESTART_PREPARATION_FAILED'
        and ownerError.retryable == false)
      assert(table.concat(ownerStatuses, ',') == 'stopping' and ownerState() == 'STOPPING')
      local ownerCallCount = #ownerCalls
      local ownerRetry, ownerRetryError = ownerController:prepare()
      assert(ownerRetry == nil
        and ownerRetryError.code == 'RESTART_PREPARATION_RETRY_UNSAFE'
        and ownerRetryError.retryable == false)
      assert(#ownerCalls == ownerCallCount)

      local schedulerController, _, schedulerStatuses, schedulerState = fixture({
        schedulerRunning = 1, schedulerDetached = 1
      })
      local schedulerReport, schedulerError = schedulerController:prepare()
      assert(schedulerReport == nil and schedulerError.code == 'RESTART_PREPARATION_FAILED')
      assert(table.concat(schedulerStatuses, ',') == 'stopping'
        and schedulerState() == 'STOPPING')

      local missingSchedulerController, _, missingSchedulerStatuses, missingSchedulerState =
        fixture({ schedulerUnavailable = true })
      local missingSchedulerReport, missingSchedulerError = missingSchedulerController:prepare()
      assert(missingSchedulerReport == nil
        and missingSchedulerError.code == 'RESTART_PREPARATION_FAILED')
      assert(table.concat(missingSchedulerStatuses, ',') == 'stopping'
        and missingSchedulerState() == 'STOPPING')

      return table.concat({prepared.state, timeoutError.code, timeoutRetry.state,
        ownerError.code, ownerRetryError.code, schedulerError.code,
        missingSchedulerError.code}, ':')
    `);
    assert.equal(
      result,
      'prepared:RESTART_DATABASE_DRAIN_TIMEOUT:prepared:RESTART_PREPARATION_FAILED:'
      + 'RESTART_PREPARATION_RETRY_UNSAFE:RESTART_PREPARATION_FAILED:'
      + 'RESTART_PREPARATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});
