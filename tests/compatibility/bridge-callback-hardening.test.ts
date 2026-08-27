import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const nativeServerPath = join(process.cwd(), "libraries", "synex_bridge", "native_server.lua");
const nativeClientPath = join(process.cwd(), "libraries", "synex_bridge", "native_client.lua");
const foundationPath = join(
  process.cwd(), "libraries", "synex_bridge", "kernel", "foundation.lua",
);

test("callback ownership, source generations, duplicate completion, and owner cleanup fail closed", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      source = 0
      handlers, responses, timeouts, metrics = {}, {}, {}, {}
      local now = 1000
      session = { id = 'session-a', state = 'ACTIVE', sourceGeneration = 7,
        characterId = 'character-a' }
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return (name == 'owner_a' or name == 'owner_b') and 'started' or 'missing'
      end
      GetPlayerName = function(playerSource)
        return tonumber(playerSource) == 42 and 'Fixture' or nil
      end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(delay, handler)
        timeouts[#timeouts + 1] = { delay = delay, handler = handler }
      end
      TriggerEvent = function() end
      TriggerClientEvent = function(...)
        responses[#responses + 1] = table.pack(...)
      end
      exports = {
        synex_core = { GetAPI = function()
          return {
            Tracing = { run = function(context, handler)
              return handler(context.traceId)
            end },
            Capabilities = { checkResource = function() return true end },
            Players = { getBySource = function() return session, nil end },
            Characters = {}, Services = {}, RPC = {},
            Metrics = { increment = function(name, labels, value)
              metrics[#metrics + 1] = { name = name, labels = labels, value = value }
            end, observe = function() end },
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function(request)
          return { authority = 'operator_registry', mode = 'compat',
            traceId = 'trace-callback-owner' }, nil
        end },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      local responders = {}
      assert(adapter:registerCallback('owner_a', 'fixture.secure',
        function(_, respond, value)
          responders[#responders + 1] = respond
          if value == 'sync' then respond('ok') end
        end))
      local stolen, collision = adapter:registerCallback(
        'owner_b', 'fixture.secure', function() error('must not run') end)
      assert(stolen == nil and collision.code == 'CALLBACK_NAME_CONFLICT')

      source = 42
      handlers['fixture:request'](
        'request_sync_0001', 'owner_a', 'fixture.secure', { n = 1, 'sync' })
      assert(#responses == 1 and responses[1][4] == true and responses[1][5][1] == 'ok')
      responders[1]('duplicate')
      assert(#responses == 1)
      assert(adapter:registerCallback('owner_a', 'fixture.invalid', function(_, respond)
        respond(function() error('must not execute') end)
      end))
      handlers['fixture:request'](
        'request_invalid_01', 'owner_a', 'fixture.invalid', { n = 0 })
      assert(#responses == 2 and responses[2][4] == false
        and responses[2][5].code == 'CALLBACK_RESPONSE_INVALID')

      handlers['fixture:request'](
        'request_async_001', 'owner_a', 'fixture.secure', { n = 1, 'async' })
      assert(adapter:usageSnapshot().health.callbackPending == 1)
      session.characterId = 'character-b'
      responders[2]('stale-character')
      assert(#responses == 2 and adapter:usageSnapshot().health.callbackPending == 0,
        ('stale character response count=%d pending=%d'):format(
          #responses, adapter:usageSnapshot().health.callbackPending))
      session.characterId = 'character-a'

      handlers['fixture:request'](
        'request_async_002', 'owner_a', 'fixture.secure', { n = 1, 'async' })
      assert(adapter:usageSnapshot().health.callbackPending == 1)
      handlers.playerDropped()
      assert(adapter:usageSnapshot().health.callbackPending == 0)
      session = { id = 'session-b', state = 'ACTIVE', sourceGeneration = 8,
        characterId = 'character-b' }
      responders[3]('stale')
      assert(#responses == 2)

      handlers['fixture:request'](
        'request_async_001', 'owner_a', 'fixture.secure', { n = 1, 'async' })
      responders[4]('fresh')
      responders[4]('duplicate')
      assert(#responses == 3 and responses[3][4] == true
        and responses[3][5][1] == 'fresh')

      handlers['fixture:request'](
        'request_stop_0001', 'owner_a', 'fixture.secure', { n = 1, 'async' })
      assert(adapter:usageSnapshot().health.callbackPending == 1)
      handlers.onResourceStop('owner_a')
      assert(adapter:usageSnapshot().health.callbackPending == 0)
      assert(adapter:usageSnapshot().health.callbackRegistrations == 0)
      assert(#adapter:usageSnapshot('owner_a').entries == 0)
      assert(responses[#responses][4] == false
        and responses[#responses][5].code == 'COMPAT_CALLBACK_OWNER_STOPPED')
      assert(adapter:registerCallback('owner_b', 'fixture.secure', function(_, respond)
        responders[#responders + 1] = respond
      end))

      handlers['fixture:request'](
        'request_stop_0001', 'owner_b', 'fixture.secure', { n = 0 })
      responders[5]('stale-owner')
      assert(#responses == 4)
      responders[6]('new-owner')
      assert(responses[#responses][4] == true and responses[#responses][5][1] == 'new-owner')
      handlers.onResourceStop('synex_bridge_qb')
      local health = adapter:usageSnapshot().health
      assert(health.callbackPending == 0 and health.callbackRegistrations == 0
        and health.usageEntries == 0)
      return table.concat({ #responses, #timeouts, health.callbackPending,
        health.callbackRegistrations }, ':')
    `);
    assert.equal(result, "5:7:0:0");
  } finally {
    engine.global.close();
  }
});

test("callback timeout, per-source/global admission, and token pressure stay bounded and observable", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      source = 0
      handlers, responses, timeouts, metrics = {}, {}, {}, {}
      local now = 2000
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() return now end
      GetCurrentResourceName = function() return 'synex_bridge_esx' end
      GetResourceState = function(name) return name == 'owner_a' and 'started' or 'missing' end
      GetPlayerName = function(playerSource)
        local numeric = tonumber(playerSource)
        return numeric and numeric >= 1 and numeric <= 66 and 'Fixture' or nil
      end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(delay, handler)
        timeouts[#timeouts + 1] = { delay = delay, handler = handler }
      end
      TriggerEvent = function() end
      TriggerClientEvent = function(...)
        responses[#responses + 1] = table.pack(...)
      end
      exports = {
        synex_core = { GetAPI = function()
          return {
            Tracing = { run = function(context, handler)
              return handler(context.traceId)
            end },
            Capabilities = { checkResource = function() return true end },
            Players = { getBySource = function(playerSource)
              return { id = ('session-%d'):format(playerSource), state = 'ACTIVE',
                sourceGeneration = 1,
                characterId = ('character-%d'):format(playerSource) }, nil
            end },
            Characters = {}, Services = {}, RPC = {},
            Metrics = {
              increment = function(name, labels, value)
                metrics[#metrics + 1] = { name = name, labels = labels, value = value }
              end,
              observe = function() end,
            },
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function()
          return { authority = 'operator_registry', mode = 'compat',
            traceId = 'trace-callback-limits' }, nil
        end },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'esx', capabilityPrefix = 'synex.compat.esx',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      assert(adapter:registerCallback('owner_a', 'fixture.pending', function() end))

      source = 1
      for index = 1, 8 do
        handlers['fixture:request'](('source1_%08d'):format(index),
          'owner_a', 'fixture.pending', { n = 0 })
      end
      assert(adapter:usageSnapshot().health.callbackPending == 8)
      handlers['fixture:request'](
        'source1_limit_01', 'owner_a', 'fixture.pending', { n = 0 })
      assert(adapter:usageSnapshot().health.callbackPending == 8)

      for playerSource = 2, 64 do
        source = playerSource
        for index = 1, 8 do
          handlers['fixture:request'](('source%d_%08d'):format(playerSource, index),
            'owner_a', 'fixture.pending', { n = 0 })
        end
      end
      assert(adapter:usageSnapshot().health.callbackPending == 512)

      source = 65
      handlers['fixture:request'](
        'global_limit_0001', 'owner_a', 'fixture.pending', { n = 0 })
      assert(adapter:usageSnapshot().health.callbackPending == 512)

      source = 66
      for index = 1, 17 do
        handlers['fixture:request'](('token_limit_%08d'):format(index),
          'owner_a', 'fixture.pending', { n = 0 })
      end
      assert(adapter:usageSnapshot().health.callbackPending == 512)

      assert(#timeouts == 512 and timeouts[1].delay == 10000)
      timeouts[1].handler()
      timeouts[1].handler()
      assert(#responses == 1 and responses[1][4] == false
        and responses[1][5].code == 'CALLBACK_TIMEOUT')
      assert(adapter:usageSnapshot().health.callbackPending == 511)

      local callbackTimeouts, callbackRateLimits, callbackTotals = 0, 0, 0
      for _, metric in ipairs(metrics) do
        if metric.name == 'synex_bridge_esx_compat_callback_timeout_total' then
          callbackTimeouts = callbackTimeouts + metric.value
        elseif metric.name == 'synex_bridge_esx_compat_callback_rate_limit_total' then
          callbackRateLimits = callbackRateLimits + metric.value
        elseif metric.name == 'synex_bridge_esx_compat_callbacks_total' then
          callbackTotals = callbackTotals + metric.value
          assert(metric.labels.outcome == 'success' or metric.labels.outcome == 'denied'
            or metric.labels.outcome == 'unsupported' or metric.labels.outcome == 'error'
            or metric.labels.outcome == 'timeout' or metric.labels.outcome == 'rate_limited')
        end
      end
      assert(callbackTimeouts == 1 and callbackRateLimits == 19
        and callbackTotals == 20)

      handlers.onResourceStop('synex_bridge_esx')
      local health = adapter:usageSnapshot().health
      assert(health.callbackPending == 0 and health.callbackRegistrations == 0
        and health.usageEntries == 0)
      return table.concat({ #timeouts, #responses, callbackTimeouts,
        callbackRateLimits, callbackTotals }, ':')
    `);
    assert.equal(result, "512:1:1:19:20");
  } finally {
    engine.global.close();
  }
});

test("native client rejects hostile payloads and clears pending calls across provider restart", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      source = 65535
      handlers, requests, timeouts, callbackResults = {}, {}, {}, {}
      local now = 3000
      json = { encode = function() return '[]' end }
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(delay, handler)
        timeouts[#timeouts + 1] = { delay = delay, handler = handler }
      end
      TriggerServerEvent = function(...)
        requests[#requests + 1] = table.pack(...)
      end
    `);
    await engine.doString(await readFile(nativeClientPath, "utf8"));
    const result = await engine.doString(String.raw`
      local function record(name)
        return function(value, operationError)
          callbackResults[#callbackResults + 1] = {
            name = name, value = value, operationError = operationError,
          }
        end
      end
      local client = SynexBridgeClient.create({
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      local deep, cursor = {}, nil
      cursor = deep
      for _ = 1, 8 do cursor.child = {}; cursor = cursor.child end
      local cyclic = {}; cyclic.self = cyclic
      local metamethodCalls = 0
      local hostile = setmetatable({}, {
        __len = function() metamethodCalls = metamethodCalls + 1 return 1 end,
        __pairs = function() metamethodCalls = metamethodCalls + 1 return next, {}, nil end,
      })
      local tooMany = {}
      for index = 1, 17 do tooMany[index] = index end
      assert(client:triggerCallback('owner_a', 'fixture.deep', record('deep'), deep) == false)
      assert(client:triggerCallback('owner_a', 'fixture.cyclic', record('cyclic'), cyclic) == false)
      assert(client:triggerCallback('owner_a', 'fixture.meta', record('meta'), hostile) == false)
      assert(metamethodCalls == 0)
      assert(client:triggerCallback('owner_a', 'fixture.nan', record('nan'), 0 / 0) == false)
      assert(client:triggerCallback('owner_a', 'fixture.string', record('string'),
        string.rep('x', 1025)) == false)
      assert(client:triggerCallback('owner_a', 'fixture.count', record('count'),
        table.unpack(tooMany)) == false)

      for index = 1, 8 do
        assert(client:triggerCallback('owner_a', ('fixture.pending%d'):format(index),
          record(('pending%d'):format(index)), index))
      end
      assert(client:triggerCallback(
        'owner_a', 'fixture.overflow', record('overflow')) == false)
      assert(#requests == 8 and #timeouts == 8)

      handlers['fixture:response'](requests[1][2], true, { n = 1, 'first' })
      handlers['fixture:response'](requests[1][2], true, { n = 1, 'duplicate' })
      assert(#callbackResults == 1 and callbackResults[1].value == 'first')

      handlers['fixture:response'](requests[2][2], false,
        { code = function() error('must not execute') end })
      assert(#callbackResults == 2 and callbackResults[2].value == nil
        and callbackResults[2].operationError.code == 'CALLBACK_RESPONSE_INVALID')

      source = 1
      handlers['fixture:response'](requests[3][2], true, { n = 1, 'spoofed' })
      assert(#callbackResults == 2)
      source = 65535
      handlers['fixture:response'](requests[3][2], true, { n = 1, 'server' })
      assert(#callbackResults == 3 and callbackResults[3].value == 'server')

      timeouts[4].handler()
      handlers['fixture:response'](requests[4][2], true, { n = 1, 'late' })
      assert(#callbackResults == 4
        and callbackResults[4].operationError.code == 'CALLBACK_TIMEOUT')

      handlers.onClientResourceStop('synex_bridge_qb')
      handlers['fixture:response'](requests[5][2], true, { n = 1, 'stale' })
      assert(#callbackResults == 4)
      assert(client:triggerCallback(
        'owner_a', 'fixture.stopped', record('stopped')) == false)

      local restarted = SynexBridgeClient.create({
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      assert(restarted:triggerCallback(
        'owner_a', 'fixture.restart', record('restart')))
      handlers['fixture:response'](requests[9][2], true, { n = 1, 'fresh' })
      assert(#callbackResults == 5 and callbackResults[5].name == 'restart'
        and callbackResults[5].value == 'fresh')
      return table.concat({ #requests, #timeouts, #callbackResults,
        callbackResults[4].operationError.code }, ':')
    `);
    assert.equal(result, "9:9:5:CALLBACK_TIMEOUT");
  } finally {
    engine.global.close();
  }
});
