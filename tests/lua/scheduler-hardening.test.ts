import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) {
    await load(engine, `core/synex_core/server/${module}.lua`);
  }
  return engine;
}

test('central monotonic time survives signed and unsigned Cfx timer wrap', async () => {
  const engine = await coreEngine(['foundation']);
  try {
    const result = await engine.doString(`
      local unsignedRaw = 4294967290
      local unsigned = SynexCoreFactories.foundation({
        platform = {
          nowGame = function() return unsignedRaw end,
          random = function() return 1 end,
          print = function() end,
          jsonEncode = function() return '{}' end
        }
      })
      local first = unsigned.monotonicMs()
      unsignedRaw = 4294967295
      local second = unsigned.monotonicMs()
      unsignedRaw = 3
      local third = unsigned.monotonicMs()
      unsignedRaw = 2
      local clamped = unsigned.monotonicMs()
      unsignedRaw = 4
      local recovered = unsigned.monotonicMs()

      local signedRaw = 2147483646
      local signed = SynexCoreFactories.foundation({
        platform = {
          nowGame = function() return signedRaw end,
          random = function() return 1 end,
          print = function() end,
          jsonEncode = function() return '{}' end
        }
      })
      local signedFirst = signed.monotonicMs()
      signedRaw = 2147483647
      local signedSecond = signed.monotonicMs()
      signedRaw = -2147483648
      local signedThird = signed.monotonicMs()
      signedRaw = -2147483647
      local signedFourth = signed.monotonicMs()

      assert(second - first == 5 and third - second == 4)
      assert(clamped == third and recovered - clamped == 1)
      assert(signedSecond - signedFirst == 1 and signedThird - signedSecond == 1
        and signedFourth - signedThird == 1)
      return table.concat({second - first, third - second, recovered - clamped,
        signedFourth - signedFirst}, ':')
    `);
    assert.equal(result, '5:4:1:3');
  } finally {
    engine.global.close();
  }
});

test('deadline heap arms exact waits across wrap and bounds native timer rearms', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local raw, timers, runs = 1000, {}, {}
      local platform = {
        nowGame = function() return raw end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(delay, callback)
          timers[#timers + 1] = { delay = delay, callback = callback }
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('deadline-heap')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform,
        foundation = foundation,
        owners = registries.owners,
        maximumPendingTimers = 2
      })

      local later = assert(lifecycle.scheduler:after('synex_fixture', epoch, 1000,
        function() runs[#runs + 1] = 'later' return true end))
      local earlier = assert(lifecycle.scheduler:after('synex_fixture', epoch, 500,
        function() runs[#runs + 1] = 'earlier' return true end))
      local rejected, rejectedError = lifecycle.scheduler:after('synex_fixture', epoch, 250,
        function() error('must not run') end)
      assert(rejected == nil and rejectedError.code == 'SCHEDULER_TIMER_LIMIT')
      assert(#timers == 2 and timers[1].delay == 1000 and timers[2].delay == 500)
      assert(lifecycle.scheduler:count() == 2)

      raw = 1500
      timers[2].callback()
      assert(runs[1] == 'earlier' and #timers == 3 and timers[3].delay == 500)
      raw = 2000
      timers[1].callback()
      assert(#runs == 1, 'the invalidated native timer must be inert')
      timers[3].callback()
      assert(runs[2] == 'later' and lifecycle.scheduler:count() == 0)

      local wrapRaw, wrapTimers, wrapRuns = 4294967280, {}, 0
      local wrapPlatform = {
        nowGame = function() return wrapRaw end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(delay, callback)
          wrapTimers[#wrapTimers + 1] = { delay = delay, callback = callback }
        end
      }
      local wrapFoundation = SynexCoreFactories.foundation({ platform = wrapPlatform })
      wrapFoundation.configureIds('deadline-wrap')
      local wrapRegistries = SynexCoreFactories.registries({ foundation = wrapFoundation })
      local wrapEpoch = wrapRegistries.owners:activate('synex_wrap')
      local wrapLifecycle = SynexCoreFactories.lifecycle({
        platform = wrapPlatform, foundation = wrapFoundation, owners = wrapRegistries.owners
      })
      assert(wrapLifecycle.scheduler:after('synex_wrap', wrapEpoch, 32,
        function() wrapRuns = wrapRuns + 1 return true end))
      assert(#wrapTimers == 1 and wrapTimers[1].delay == 32)
      wrapRaw = 16
      wrapTimers[1].callback()
      assert(wrapRuns == 1 and wrapLifecycle.scheduler:count() == 0)

      return table.concat({rejectedError.code, timers[1].delay, timers[2].delay,
        table.concat(runs, ','), wrapTimers[1].delay, wrapRuns}, ':')
    `);
    assert.equal(result, 'SCHEDULER_TIMER_LIMIT:1000:500:earlier,later:32:1');
  } finally {
    engine.global.close();
  }
});

test('cancelled detached handlers remain globally accounted until they return', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local now, timers, threads, contexts, cancellationCodes = 1000, {}, {}, {}, {}
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(delay, callback)
          timers[#timers + 1] = { delay = delay, callback = callback }
        end,
        createThread = function(handler)
          threads[#threads + 1] = coroutine.create(handler)
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('detached-handlers')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform,
        foundation = foundation,
        owners = registries.owners,
        maximumRunningHandlers = 2,
        maximumSchedules = 16,
        maximumSchedulesPerOwner = 16
      })
      local function blockingHandler(token, cancellation)
        contexts[token] = cancellation
        coroutine.yield('blocked')
        local ok, cancellationError = cancellation:checkpoint()
        cancellationCodes[token] = ok and 'NONE' or cancellationError.code
        return true
      end
      local first = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 50, blockingHandler, { name = 'fixture.first' }))
      local second = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 50, blockingHandler, { name = 'fixture.second' }))
      assert(lifecycle.scheduler:after('synex_fixture', epoch, 50,
        function() return true end, { name = 'fixture.queued' }))
      now = 1050
      timers[1].callback()
      assert(#threads == 2)
      assert(coroutine.resume(threads[1]) and coroutine.resume(threads[2]))
      assert(lifecycle.scheduler:cancel('synex_fixture', first))
      assert(lifecycle.scheduler:cancel('synex_fixture', second))
      local detached = lifecycle.scheduler:capacity()
      assert(detached.schedules == 1 and detached.queuedSchedules == 1)
      assert(detached.runningHandlers == 2 and detached.detachedRunningHandlers == 2)
      assert(contexts[first].cancelled and contexts[second].cancelled)
      assert(contexts[first].reason == 'schedule cancelled')
      local immutable = pcall(function() contexts[first].cancelled = false end)
      assert(not immutable)

      for index = 1, 8 do
        local churn = assert(lifecycle.scheduler:after('synex_fixture', epoch, 0,
          function() error('detached cap bypass') end))
        assert(lifecycle.scheduler:cancel('synex_fixture', churn))
      end
      assert(#threads == 2 and lifecycle.scheduler:capacity().runningHandlers == 2)

      assert(coroutine.resume(threads[1]))
      assert(cancellationCodes[first] == 'SCHEDULE_CANCELLED')
      assert(#timers == 2 and timers[2].delay == 1)
      assert(coroutine.resume(threads[2]))
      assert(cancellationCodes[second] == 'SCHEDULE_CANCELLED' and #timers == 2,
        'parallel completions must share the already armed wake-up')
      now = 1051
      timers[2].callback()
      assert(#threads == 3, 'one released running slot must admit exactly one queued handler')
      assert(coroutine.resume(threads[3]))
      local finished = lifecycle.scheduler:capacity()
      assert(finished.runningHandlers == 0 and finished.detachedRunningHandlers == 0)
      assert(lifecycle.scheduler:count() == 0)
      return table.concat({detached.runningHandlers, detached.detachedRunningHandlers,
        cancellationCodes[first], cancellationCodes[second], #threads,
        finished.runningHandlers}, ':')
    `);
    assert.equal(result, '2:2:SCHEDULE_CANCELLED:SCHEDULE_CANCELLED:3:0');
  } finally {
    engine.global.close();
  }
});

test('quiesce aborts scheduler context without claiming a detached coroutine stopped', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local now, timer, thread, cancellation, cancellationCode = 1000, nil, nil, nil, nil
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(_, callback) timer = callback end,
        createThread = function(handler) thread = coroutine.create(handler) end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('quiesce-handler')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners,
        maximumRunningHandlers = 1
      })
      assert(lifecycle.scheduler:after('synex_fixture', epoch, 50,
        function(_, context)
          cancellation = context
          coroutine.yield('blocked')
          local ok, contextError = context:checkpoint()
          cancellationCode = ok and 'NONE' or contextError.code
          return true
        end))
      now = 1050
      timer()
      assert(coroutine.resume(thread))
      local report = assert(lifecycle.reload:quiesce('synex_fixture', epoch, {
        timeoutMs = 0, reason = 'fixture quiesce'
      }))
      local detached = lifecycle.scheduler:capacity()
      assert(report.drained == false and report.timedOut == true and report.aborted == 1)
      assert(cancellation.cancelled and cancellation.reason == 'fixture quiesce')
      assert(detached.schedules == 0 and detached.runningHandlers == 1
        and detached.detachedRunningHandlers == 1)
      assert(coroutine.resume(thread))
      local finished = lifecycle.scheduler:capacity()
      assert(cancellationCode == 'SCHEDULE_CANCELLED')
      assert(finished.runningHandlers == 0 and finished.detachedRunningHandlers == 0)
      return table.concat({tostring(report.drained), tostring(report.timedOut), report.aborted,
        cancellationCode, detached.runningHandlers, finished.runningHandlers}, ':')
    `);
    assert.equal(result, 'false:true:1:SCHEDULE_CANCELLED:1:0');
  } finally {
    engine.global.close();
  }
});
