import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('Groups worker registration rolls back batches and resumes uncertain tokens safely', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [foundationSource, schedulerSource] = await Promise.all([
      readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
      readFile(path.join(root, 'resources/synex_groups/server/scheduler.lua'), 'utf8'),
    ]);
    await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)}, '@server/foundation.lua'))()
      local scheduleWorkers = assert(load(${JSON.stringify(schedulerSource)}, '@server/scheduler.lua'))()(Foundation)
      local ready, current, failAt, staleAt, calls = false, true, 3, -1, 0
      local handlers, scheduledByName, cancelled, tokens = {}, {}, {}, {}
      local effects = { outbox = 0, audit = 0, maintenance = 0, creation = 0, deletion = 0 }
      local api = {
        Ids = { next = function() return 'claim' end },
        Events = { publishOutbox = function() return true end },
        Audit = { append = function() return true end },
        Scheduler = {
          every = function(_, handler, options)
            calls = calls + 1
            scheduledByName[options.name] = (scheduledByName[options.name] or 0) + 1
            if failAt == calls then
              return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
            end
            local token = options.name .. ':' .. tostring(calls)
            handlers[token] = handler
            if staleAt == calls then current = false end
            return token, nil
          end,
          cancel = function(token)
            cancelled[#cancelled + 1] = token
            handlers[token] = nil
            return true, nil
          end
        }
      }
      local dependencies = {
        outboxDispatcher = {
          dispatchBatch = function(_, _, publish)
            effects.outbox = effects.outbox + 1
            return publish('topic', {}, {})
          end
        },
        database = {
          dispatchAuditBatch = function()
            effects.audit = effects.audit + 1
            return true, nil
          end,
          maintain = function()
            effects.maintenance = effects.maintenance + 1
            return { assignments = 0 }, nil
          end
        },
        runtimeIndex = { refreshAll = function() return true end },
        loadRuntimeCharacter = function() return {} end,
        groupCreationApprovals = {
          reconcile = function()
            effects.creation = effects.creation + 1
            return true, nil
          end
        },
        groupDeletions = {
          reconcile = function()
            effects.deletion = effects.deletion + 1
            return true, nil
          end
        }
      }
      local options = {
        tokens = tokens,
        pendingCancellations = {},
        isCurrent = function() return current end,
        isReady = function() return ready end
      }

      local registered, registrationError = scheduleWorkers(api, dependencies, options)
      assert(registered == nil and registrationError.code == 'OWNER_QUIESCING')
      assert(#cancelled == 2 and next(tokens) == nil and next(handlers) == nil)

      failAt = -1
      assert(scheduleWorkers(api, dependencies, options) == true)
      local tokenCount = 0
      for _, handler in pairs(handlers) do handler(); tokenCount = tokenCount + 1 end
      assert(tokenCount == 5)
      for _, value in pairs(effects) do assert(value == 0) end
      ready = true
      for _, handler in pairs(handlers) do handler() end
      for _, value in pairs(effects) do assert(value == 1) end
      current = false
      for _, handler in pairs(handlers) do handler() end
      for _, value in pairs(effects) do assert(value == 1) end

      ready, current, failAt, staleAt, calls = false, true, -1, 1, 0
      handlers, scheduledByName, cancelled, tokens = {}, {}, {}, {}
      options.tokens = tokens
      options.pendingCancellations = {}
      registered, registrationError = scheduleWorkers(api, dependencies, options)
      assert(registered == nil and registrationError.code == 'STALE_RESOURCE')
      assert(next(tokens) == nil and next(handlers) == nil)

      ready, current, failAt, staleAt, calls = false, true, 3, -1, 0
      handlers, scheduledByName, cancelled, tokens = {}, {}, {}, {}
      options.tokens = tokens
      options.pendingCancellations = {}
      local firstCancellation = true
      api.Scheduler.cancel = function(token)
        cancelled[#cancelled + 1] = token
        if firstCancellation then
          firstCancellation = false
          return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
        end
        handlers[token] = nil
        return true, nil
      end
      registered, registrationError = scheduleWorkers(api, dependencies, options)
      assert(registered == nil and registrationError.code == 'WORKER_CANCELLATION_FAILED')
      local residualName
      for name in pairs(tokens) do
        assert(residualName == nil)
        residualName = name
      end
      assert(type(residualName) == 'string')
      failAt = -1
      assert(scheduleWorkers(api, dependencies, options) == true)
      assert(scheduledByName[residualName] == 2)
      local finalCount = 0
      for _ in pairs(tokens) do finalCount = finalCount + 1 end
      assert(finalCount == 5)
    `);
  } finally {
    engine.global.close();
  }
});
