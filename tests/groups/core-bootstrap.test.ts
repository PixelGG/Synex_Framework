import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('Groups bootstrap retries only transient Core states and fences stale retries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [foundationSource, bootstrapSource] = await Promise.all([
      readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
      readFile(path.join(root, 'resources/synex_groups/server/core_bootstrap.lua'), 'utf8'),
    ]);
    await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)}, '@server/foundation.lua'))()
      local CoreBootstrap = assert(load(${JSON.stringify(bootstrapSource)}, '@server/core_bootstrap.lua'))()(Foundation)
      local queue, attempts, ready, failures = {}, 0, 0, 0
      local current = true
      local function schedule(delay, handler)
        assert(delay == 0 or delay == 200 or delay == 5000)
        queue[#queue + 1] = { delay = delay, handler = handler }
      end
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        isCurrent = function() return current end,
        acquire = function()
          attempts = attempts + 1
          if attempts < 3 then
            return nil, Foundation.domainError('CORE_NOT_READY', 'fixture', true)
          end
          return { ownerEpoch = 1 }, nil
        end,
        onReady = function(api)
          assert(api.ownerEpoch == 1)
          ready = ready + 1
          return true
        end,
        onFailure = function() failures = failures + 1 end
      })
      while #queue > 0 do local scheduled = table.remove(queue, 1) scheduled.handler() end
      assert(attempts == 3 and ready == 1 and failures == 0)

      attempts, queue = 0, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        isCurrent = function() return current end,
        acquire = function()
          attempts = attempts + 1
          return nil, Foundation.domainError('CORE_NOT_READY', 'fixture', true)
        end,
        onReady = function() ready = ready + 1 end,
        onFailure = function() failures = failures + 1 end
      })
      local first = table.remove(queue, 1)
      first.handler()
      current = false
      local stale = table.remove(queue, 1)
      stale.handler()
      assert(attempts == 1 and ready == 1 and failures == 0 and #queue == 0)

      current, queue = true, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        acquire = function()
          return nil, Foundation.domainError('CORE_FAILED', 'fixture', false)
        end,
        onReady = function() ready = ready + 1 end,
        onFailure = function(code)
          assert(code == 'CORE_STARTUP_TIMEOUT')
          failures = failures + 1
        end
      })
      table.remove(queue, 1).handler()
      assert(ready == 1 and failures == 1 and #queue == 0)

      local bindAttempts = 0
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        maximumAttempts = 3,
        acquire = function() return { ownerEpoch = 1 }, nil end,
        onReady = function()
          bindAttempts = bindAttempts + 1
          if bindAttempts < 3 then
            return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
          end
          return true, nil
        end,
        onFailure = function() failures = failures + 1 end
      })
      while #queue > 0 do table.remove(queue, 1).handler() end
      assert(bindAttempts == 3 and failures == 1)

      current, queue = true, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        acquire = function() return { ownerEpoch = 1 }, nil end,
        isCurrent = function() return current end,
        onReady = function()
          current = false
          return nil, Foundation.domainError('STALE_RESOURCE', 'fixture', true)
        end,
        onFailure = function() failures = failures + 1 end
      })
      table.remove(queue, 1).handler()
      assert(#queue == 0 and failures == 1)

      current, queue = true, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        maximumAttempts = 1,
        acquire = function() return { ownerEpoch = 1 }, nil end,
        onReady = function() return nil, nil end,
        onFailure = function(code, failure)
          assert(code == 'GROUPS_STARTUP_FAILED')
          assert(failure.code == 'GROUPS_READY_HANDLER_INVALID')
          failures = failures + 1
        end
      })
      table.remove(queue, 1).handler()
      assert(failures == 2 and #queue == 0)

      local recoveryAttempts, journalWrites, recovered = 0, 0, 0
      current, queue = true, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        maximumAttempts = 2,
        recoveryDelayMs = 5000,
        isCurrent = function() return current end,
        acquire = function() return { ownerEpoch = 1 }, nil end,
        onReady = function()
          recoveryAttempts = recoveryAttempts + 1
          if journalWrites == 0 then journalWrites = journalWrites + 1 end
          if recoveryAttempts < 3 then
            return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
          end
          recovered = recovered + 1
          return true, nil
        end,
        onFailure = function(code, failure)
          assert(code == 'GROUPS_STARTUP_FAILED' and failure.retryable == true)
          failures = failures + 1
        end
      })
      local recoveryInitial = table.remove(queue, 1)
      assert(recoveryInitial.delay == 0)
      recoveryInitial.handler()
      local retry = table.remove(queue, 1)
      assert(retry.delay == 200)
      retry.handler()
      local recovery = table.remove(queue, 1)
      assert(recovery.delay == 5000 and failures == 3)
      recovery.handler()
      assert(recoveryAttempts == 3 and journalWrites == 1 and recovered == 1 and #queue == 0)

      recoveryAttempts, current, queue = 0, true, {}
      CoreBootstrap.runWhenReady({
        schedule = schedule,
        maximumAttempts = 1,
        recoveryDelayMs = 5000,
        isCurrent = function() return current end,
        acquire = function() return { ownerEpoch = 1 }, nil end,
        onReady = function()
          recoveryAttempts = recoveryAttempts + 1
          return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
        end,
        onFailure = function() failures = failures + 1 end
      })
      table.remove(queue, 1).handler()
      local staleRecovery = table.remove(queue, 1)
      assert(staleRecovery.delay == 5000 and failures == 4)
      current = false
      staleRecovery.handler()
      assert(recoveryAttempts == 1 and failures == 4 and #queue == 0)
    `);
  } finally {
    engine.global.close();
  }
});

test('Groups registration resumes every failed stage without duplicate bindings', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [foundationSource, bootstrapSource] = await Promise.all([
      readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
      readFile(path.join(root, 'resources/synex_groups/server/core_bootstrap.lua'), 'utf8'),
    ]);
    await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)}, '@server/foundation.lua'))()
      local CoreBootstrap = assert(load(${JSON.stringify(bootstrapSource)}, '@server/core_bootstrap.lua'))()(Foundation)
      local failureStages = {
        'prepare', 'provider', 'participant', 'rebuild', 'service',
        'service_unhealthy', 'rpc', 'workers', 'service_healthy'
      }

      local function fixture(failureStage)
        local generation, failed = 1, false
        local counts, health, captured, registeredBinding = {}, {}, {}, nil
        local function step(name, value)
          counts[name] = (counts[name] or 0) + 1
          if failureStage == name and not failed then
            failed = true
            return nil, Foundation.domainError('OWNER_QUIESCING', 'fixture', true)
          end
          return value or (name .. '_token'), nil
        end
        local api = {
          ownerEpoch = 7,
          Ids = { next = function() return 'id' end },
          Events = { publishOutbox = function() return true end },
          Scheduler = {
            every = function() return 'worker' end,
            cancel = function() return true end
          },
          Characters = {
            get = function() return {} end,
            getActive = function() return nil, { code = 'SESSION_NOT_FOUND' } end,
            registerLifecycleParticipant = function(definition)
              captured.participant = definition.prepare
              return step('participant')
            end
          },
          Hooks = { run = function() return {} end },
          Audit = { append = function() return true end },
          Permissions = {
            check = function() return true end,
            evaluateRules = function() return true end
          },
          Database = {
            null = function() return {} end,
            read = function() return {} end,
            write = function() return {} end,
            transaction = function() return true end,
            maintenance = function() return true end
          },
          DomainDeletions = {
            registerProvider = function(definition)
              captured.provider = definition.preflight
              return step('provider')
            end,
            plan = function() return {} end,
            get = function() return {} end,
            process = function() return {} end
          },
          Services = {
            provide = function(definition)
              captured.service = definition.methods.read
              return step('service')
            end,
            setHealth = function(_, _, state)
              health[#health + 1] = state
              return step(state == 'HEALTHY' and 'service_healthy' or 'service_unhealthy', true)
            end
          },
          RPC = {
            registerServer = function(definition, handler)
              captured[definition.name] = handler
              return step('rpc')
            end,
            registerNetwork = function(definition, handler)
              captured[definition.name] = handler
              return step('rpc')
            end
          }
        }
        local registration
        registration = CoreBootstrap.createRegistration({
          serviceName = 'synex.groups', serviceVersion = '1.0.0',
          isGenerationCurrent = function(value) return value == generation end,
          prepare = function() return step('prepare', true) end,
          deletionProvider = function(binding)
            registeredBinding = binding
            return {
              preflight = registration:guard(binding, function() return 'provider_ok' end),
              execute = registration:guard(binding, function() return 'execute_ok' end)
            }
          end,
          characterParticipant = function(binding)
            return {
              prepare = registration:guard(binding, function() return 'participant_ok' end)
            }
          end,
          rebuild = function() return step('rebuild', true) end,
          serviceDefinition = function(binding)
            return {
              methods = {
                read = registration:guard(binding, function() return 'service_ok' end)
              }
            }
          end,
          contracts = {
            { name = 'synex.groups.first', version = '1.0.0', network = 'none' },
            { name = 'synex.groups.second', version = '1.0.0', network = 'client-to-server' }
          },
          contractHandler = function(definition, binding)
            return registration:guard(binding, function() return definition.name end, 'DATABASE_ERROR')
          end,
          scheduleWorkers = function(_, _, tokens, pendingCancellations)
            assert(type(tokens) == 'table' and type(pendingCancellations) == 'table')
            return step('workers', true)
          end
        })
        return {
          api = api, registration = registration, counts = counts,
          health = health, captured = captured,
          binding = function() return registeredBinding end,
          advanceGeneration = function() generation = generation + 1 end
        }
      end

      for _, failureStage in ipairs(failureStages) do
        local state = fixture(failureStage)
        local bound, bindError = state.registration:bind(state.api, 1)
        assert(bound == nil and bindError.code == 'OWNER_QUIESCING',
          failureStage .. ':first:' .. tostring(bound) .. ':' .. tostring(bindError and bindError.code))
        for _, handler in pairs(state.captured) do
          local value, handlerError = handler({})
          assert(value == nil and type(handlerError) == 'table')
        end
        local completed, completionError = state.registration:bind(state.api, 1)
        assert(completed == true and completionError == nil,
          failureStage .. ':resume:' .. tostring(completionError and completionError.code))
        assert(state.counts[failureStage] == (failureStage == 'rpc' and 3 or 2))
        for stage, count in pairs(state.counts) do
          local expected = stage == failureStage and 2 or 1
          if stage == 'rpc' and failureStage ~= 'rpc' then expected = 2 end
          if stage == 'rpc' and failureStage == 'rpc' then expected = 3 end
          assert(count == expected, failureStage .. ':' .. stage .. ':' .. tostring(count))
        end
        assert(state.health[#state.health] == 'HEALTHY')
        for _, handler in pairs(state.captured) do assert(handler({}) ~= nil) end
        local rpcCount = state.counts.rpc
        assert(state.registration:bind(state.api, 1) == true)
        assert(state.counts.rpc == rpcCount)
        local oldHandler = state.captured['synex.groups.first']
        local cleanupObserved = false
        state.api.Services.setHealth = function()
          cleanupObserved = true
          assert(not state.registration:isCurrent(state.binding()))
          return true, nil
        end
        state.registration:invalidate()
        assert(cleanupObserved)
        state.advanceGeneration()
        local oldValue, oldError = oldHandler({})
        assert(oldValue == nil and oldError.code == 'DATABASE_ERROR')
      end
    `);
  } finally {
    engine.global.close();
  }
});
