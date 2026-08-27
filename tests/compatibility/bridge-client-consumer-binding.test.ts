import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const nativeServerPath = path.join(root, 'libraries', 'synex_bridge', 'native_server.lua');
const foundationPath = path.join(
  root, 'libraries', 'synex_bridge', 'kernel', 'foundation.lua',
);

async function clientSource(provider: 'qb' | 'qbx' | 'esx'): Promise<string> {
  return readFile(path.join(root, 'resources', `synex_bridge_${provider}`, 'client.lua'), 'utf8');
}

test('QB client projections and callbacks remain bound to authorized consumers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      invoking, source = 'authorized_a', 65535
      registered, handlers, callbackRequests = {}, {}, {}
      local transport = {}
      function transport:triggerCallback(consumer, name, callback, ...)
        callbackRequests[#callbackRequests + 1] = {
          consumer = consumer, name = name, arguments = table.pack(...),
        }
        callback('ok')
        return true
      end
      SynexBridgeClient = { create = function() return transport end }
      exports = setmetatable({}, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      GetInvokingResource = function() return invoking end
    `);
    await engine.doString(await clientSource('qb'));
    const result = await engine.doString(String.raw`
      local projection = handlers['synex_bridge_qb:client:projection']
      projection('replace', { money = { cash = 10 } }, {
        playerData = {}, callbacks = { 'authorized_a' },
      })
      assert(registered.GetPlayerData() == nil and registered.GetCoreObject() == nil)

      projection('replace', { money = { cash = 10 } }, {
        playerData = { 'authorized_a' }, callbacks = { 'authorized_a' },
      })
      local callbackOnly = assert(registered.GetCoreObject())
      assert(type(callbackOnly.Functions.GetPlayerData) == 'function')
      assert(type(callbackOnly.Functions.TriggerCallback) == 'function')
      local callbackValue
      assert(callbackOnly.Functions.TriggerCallback('fixture.secure',
        function(value) callbackValue = value end) == true)
      assert(callbackValue == 'ok' and callbackRequests[1].consumer == 'authorized_a')

      invoking = 'denied_b'
      assert(registered.GetCoreObject() == nil and registered.GetPlayerData() == nil)
      invoking = 'qb-core'
      assert(registered.GetCoreObjectForConsumer('authorized_a'))
      assert(registered.GetCoreObjectForConsumer('denied_b') == nil)
      invoking = 'denied_b'
      assert(registered.GetCoreObjectForConsumer('authorized_a') == nil)

      invoking = 'authorized_a'
      projection('replace', { money = { cash = 25 } }, {
        playerData = { 'authorized_a' }, callbacks = { 'authorized_a' },
      })
      local full = assert(registered.GetCoreObject())
      local retainedGetter = full.Functions.GetPlayerData
      local detached = assert(retainedGetter())
      detached.money.cash = 999
      assert(retainedGetter().money.cash == 25)

      source = 1
      projection('clear')
      source = 65535
      assert(retainedGetter().money.cash == 25)
      projection('clear')
      assert(retainedGetter() == nil and registered.GetCoreObject() == nil)

      projection('replace', { money = { cash = 40 } }, {
        playerData = { 'authorized_a' }, callbacks = { 'authorized_a' },
      })
      assert(registered.GetPlayerData().money.cash == 40)
      projection('replace', { money = { cash = 50 } }, {
        playerData = { 'authorized_a', 'authorized_a' }, callbacks = {},
      })
      assert(registered.GetPlayerData() == nil)
      return table.concat({ #callbackRequests, callbackRequests[1].consumer,
        callbackRequests[1].name }, ':')
    `);
    assert.equal(result, '1:authorized_a:fixture.secure');
  } finally {
    engine.global.close();
  }
});

test('QBX player projections reject foreign, forged, stale, and malformed reads', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      invoking, source = 'authorized_a', 65535
      registered, handlers = {}, {}
      exports = setmetatable({}, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      GetInvokingResource = function() return invoking end
    `);
    await engine.doString(await clientSource('qbx'));
    const result = await engine.doString(String.raw`
      local projection = handlers['synex_bridge_qbx:client:projection']
      projection('replace', { groups = { police = 3 } }, {
        playerData = {}, callbacks = {},
      })
      assert(registered.GetPlayerData() == nil and registered.GetGroups() == nil)

      projection('replace', { source = 10, groups = { police = 3 } }, {
        playerData = { 'authorized_a' }, callbacks = {},
      })
      local data = assert(registered.GetPlayerData())
      assert(data.source == 10 and registered.GetGroups().police == 3)
      data.source = 999
      assert(registered.GetPlayerData().source == 10)

      invoking = 'denied_b'
      assert(registered.GetPlayerData() == nil and registered.GetGroups() == nil)
      assert(registered.GetPlayerDataForConsumer('authorized_a') == nil)
      invoking = 'qbx_core'
      assert(registered.GetPlayerDataForConsumer('authorized_a').source == 10)
      assert(registered.GetPlayerDataForConsumer('denied_b') == nil)

      invoking = 'authorized_a'
      projection('clear')
      assert(registered.GetPlayerData() == nil)
      projection('replace', { source = 20 }, {
        playerData = { 'z_consumer', 'authorized_a' }, callbacks = {},
      })
      assert(registered.GetPlayerData() == nil)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('ESX client player data and callback methods are independently consumer-bound', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      invoking, source = 'authorized_a', 65535
      registered, handlers, callbackRequests = {}, {}, {}
      local transport = {}
      function transport:triggerCallback(consumer, name, callback, ...)
        callbackRequests[#callbackRequests + 1] = {
          consumer = consumer, name = name, arguments = table.pack(...),
        }
        callback('ok')
        return true
      end
      SynexBridgeClient = { create = function() return transport end }
      exports = setmetatable({}, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      GetInvokingResource = function() return invoking end
    `);
    await engine.doString(await clientSource('esx'));
    const result = await engine.doString(String.raw`
      local projection = handlers['synex_bridge_esx:client:projection']
      projection('replace', { accounts = {} }, {
        playerData = {}, callbacks = { 'authorized_a' },
      })
      assert(registered.GetPlayerData() == nil and registered.getSharedObject() == nil)

      projection('replace', { accounts = {} }, {
        playerData = { 'authorized_a' }, callbacks = { 'authorized_a' },
      })
      local callbackOnly = assert(registered.getSharedObject())
      assert(type(callbackOnly.GetPlayerData) == 'function')
      assert(type(callbackOnly.TriggerServerCallback) == 'function')
      local callbackValue
      assert(callbackOnly.TriggerServerCallback('fixture.secure',
        function(value) callbackValue = value end) == true)
      assert(callbackValue == 'ok' and callbackRequests[1].consumer == 'authorized_a')

      projection('replace', { identifier = 'char-a', accounts = {} }, {
        playerData = { 'authorized_a' }, callbacks = { 'authorized_a' },
      })
      local shared = assert(registered.getSharedObject())
      assert(shared.GetPlayerData().identifier == 'char-a')
      invoking = 'denied_b'
      assert(registered.getSharedObject() == nil and registered.GetPlayerData() == nil)
      invoking = 'es_extended'
      assert(registered.GetSharedObjectForConsumer('authorized_a'))
      assert(registered.GetSharedObjectForConsumer('denied_b') == nil)
      invoking = 'denied_b'
      assert(registered.GetSharedObjectForConsumer('authorized_a') == nil)

      invoking = 'authorized_a'
      projection('clear')
      assert(shared.GetPlayerData() == nil)
      assert(shared.TriggerServerCallback('fixture.stale', function() end) == false)
      projection('replace', { identifier = 'char-b' }, {
        playerData = { [2] = 'authorized_a' }, callbacks = {},
      })
      assert(registered.GetPlayerData() == nil)
      return table.concat({ #callbackRequests, callbackRequests[1].consumer,
        callbackRequests[1].name }, ':')
    `);
    assert.equal(result, '1:authorized_a:fixture.secure');
  } finally {
    engine.global.close();
  }
});

test('callback consumer routing rejects mismatched tuples but is not a client security principal', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      source = 0
      handlers, responses, handlerCalls = {}, {}, 0
      local now = 1000
      local session = { id = 'session-a', state = 'ACTIVE',
        sourceGeneration = 1, characterId = 'character-a' }
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return name == 'owner_a' and 'started' or 'missing'
      end
      GetPlayerName = function(playerSource)
        return tonumber(playerSource) == 42 and 'Fixture' or nil
      end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
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
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function(request)
          assert(request.consumer == 'owner_a')
          return { authority = 'operator_registry', mode = 'compat',
            traceId = 'trace-owner-a' }, nil
        end },
      }
    `);
    await engine.doString(await readFile(foundationPath, 'utf8'));
    await engine.doString(await readFile(nativeServerPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      assert(adapter:registerCallback('owner_a', 'fixture.public',
        function(playerSource, respond, intent)
          assert(playerSource == 42)
          handlerCalls = handlerCalls + 1
          if intent ~= 'safe' then
            respond(nil, { code = 'INTENT_DENIED' })
            return
          end
          respond('ok')
        end))

      source = 42
      handlers['fixture:request'](
        'request_forged_01', 'owner_b', 'fixture.public', { n = 1, 'safe' })
      assert(handlerCalls == 0 and #responses == 1
        and responses[1][5].code == 'CALLBACK_DENIED')

      handlers['fixture:request'](
        'request_missing_01', 'fixture.public', { n = 1, 'safe' })
      assert(handlerCalls == 0 and #responses == 1)

      -- A raw client can repeat the public routing tuple. The server therefore
      -- authorizes the registered owner and the handler must still validate source/intent.
      handlers['fixture:request'](
        'request_public_01', 'owner_a', 'fixture.public', { n = 1, 'safe' })
      assert(handlerCalls == 1 and #responses == 2
        and responses[2][4] == true and responses[2][5][1] == 'ok')
      return table.concat({ handlerCalls, #responses,
        responses[1][5].code, responses[2][5][1] }, ':')
    `);
    assert.equal(result, '1:2:CALLBACK_DENIED:ok');
  } finally {
    engine.global.close();
  }
});
