import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('QB online lookup and enumeration return detached fenced player facades', async () => {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    path.join(root, 'resources', 'synex_bridge_qb', 'server.lua'),
    'utf8',
  );
  try {
    await engine.doString(String.raw`
      invoking = 'legacy_consumer'
      registered = {}

      local function snapshot(playerSource)
        return {
          source = playerSource,
          identity = { identifier = 'CID' .. playerSource },
          character = {
            id = 'character_' .. playerSource, slot = playerSource,
            firstName = 'Ada', lastName = 'Lovelace',
            dateOfBirth = '1815-12-10',
          },
          money = { cash = playerSource, bank = playerSource * 10 },
          fence = {
            sessionId = 'session_' .. playerSource, sourceGeneration = 1,
            characterId = 'character_' .. playerSource,
          },
          metadata = { hunger = 40 }, metadataVersions = { hunger = 1 },
          groups = { items = {}, truncated = false },
        }
      end

      local adapter = {}
      function adapter:authorize()
        return { traceId = 'trace_qb_surface' }, nil
      end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer(_, playerSource)
        return snapshot(assert(tonumber(playerSource))), nil
      end
      function adapter:readPlayerFenced(_, playerSource, fence)
        assert(fence.sessionId == 'session_' .. playerSource)
        return snapshot(playerSource), nil
      end
      adapter.readMoneyFenced = adapter.readPlayerFenced
      adapter.readGroupsFenced = adapter.readPlayerFenced
      function adapter:readPlayerByIdentifier(_, citizenId)
        if citizenId == 'CID10' then return snapshot(10), nil end
        return false, nil
      end
      function adapter:listPlayerSources() return { 10, 20 }, nil end
      function adapter:registerLifecycle() return 'qb-lifecycle', nil end
      function adapter:registerCallback() return true, nil end
      function adapter:usageSnapshot() return { framework = 'qb' } end
      function adapter:unsupported(_, operation)
        return nil, { code = 'COMPAT_API_UNSUPPORTED', operation = operation }
      end

      SynexBridgeNative = {
        create = function() return adapter end,
      }
      exports = setmetatable({
        synex_bridge = {
          ResolveCompatibilityCatalog = function() return false, nil end,
          InvokeCompatibilityCatalog = function() return false, nil end,
        },
      }, { __call = function(_, name, handler) registered[name] = handler end })
      GetInvokingResource = function() return invoking end
      GetPlayerName = function(playerSource) return 'Cfx Player ' .. playerSource end
      AddEventHandler = function() end
    `);
    await engine.doString(source);
    const result = await engine.doString(String.raw`
      local core = assert(registered.GetCoreObject())
      local byIdentifier = assert(core.Functions.GetPlayerByCitizenId('CID10'))
      assert(byIdentifier.PlayerData.source == 10)
      assert(byIdentifier.PlayerData.citizenid == 'CID10')
      assert(byIdentifier.PlayerData.name == 'Cfx Player 10')

      local missing, missingError = core.Functions.GetPlayerByCitizenId('missing')
      assert(missing == nil and missingError == nil)

      local sources = assert(core.Functions.GetPlayers())
      assert(#sources == 2 and sources[1] == 10 and sources[2] == 20)
      sources[1] = 999
      local freshSources = assert(core.Functions.GetPlayers())
      assert(freshSources[1] == 10)

      local players = assert(core.Functions.GetQBPlayers())
      assert(players[10].PlayerData.citizenid == 'CID10')
      assert(players[20].PlayerData.citizenid == 'CID20')
      local refreshed = assert(players[10].Functions.GetPlayerData())
      refreshed.money.cash = 999
      assert(players[10].Functions.GetPlayerData().money.cash == 10)

      assert(registered.GetPlayerByCitizenId('CID10').PlayerData.source == 10)
      invoking = 'qb-core'
      assert(registered.GetPlayerByCitizenIdForConsumer(
        'legacy_consumer', 'CID10').PlayerData.source == 10)
      invoking = 'attacker'
      local denied, deniedError = registered.GetPlayerByCitizenIdForConsumer(
        'victim', 'CID10')
      assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('QB client player data and callback forms reuse the bounded native transport', async () => {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    path.join(root, 'resources', 'synex_bridge_qb', 'client.lua'),
    'utf8',
  );
  try {
    await engine.doString(String.raw`
      registered, handlers, transportCalls = {}, {}, 0
      local transport = {}
      function transport:triggerCallback(consumer, name, callback, ...)
        assert(consumer == 'legacy_consumer' and name == 'fixture:callback')
        transportCalls = transportCalls + 1
        callback('response', ...)
        return true
      end
      SynexBridgeClient = { create = function() return transport end }
      exports = setmetatable({}, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      GetInvokingResource = function() return 'legacy_consumer' end
      source = 65535
      promise = { new = function()
        local deferred = {}
        function deferred:resolve(value) self.value = value end
        return deferred
      end }
      Citizen = { Await = function(deferred) return deferred.value end }
    `);
    await engine.doString(source);
    const result = await engine.doString(String.raw`
      handlers['synex_bridge_qb:client:projection']('replace', {
        source = 10, money = { cash = 50 }, metadata = { hunger = 40 },
      }, { playerData = { 'legacy_consumer' }, callbacks = { 'legacy_consumer' } })
      local core = assert(registered.GetCoreObject())
      local first = core.Functions.GetPlayerData()
      first.money.cash = 999
      assert(core.Functions.GetPlayerData().money.cash == 50)

      local callbackCash
      assert(core.Functions.GetPlayerData(function(data)
        callbackCash = data.money.cash
      end) == nil)
      assert(callbackCash == 50)

      local response, argument = core.Functions.TriggerCallback(
        'fixture:callback', 7)
      assert(response == 'response' and argument == 7)

      local callbackResponse, callbackArgument
      local cfxCallable = setmetatable({}, { __call = function(_, value, extra)
        callbackResponse, callbackArgument = value, extra
      end })
      assert(core.Functions.TriggerCallback(
        'fixture:callback', cfxCallable, 8) == true)
      assert(callbackResponse == 'response' and callbackArgument == 8)
      assert(transportCalls == 2)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('QB historical facade forwards citizen lookup with the actual caller', async () => {
  const facade = await readFile(
    path.join(root, 'compat', 'facades', 'qb-core', 'server.lua'),
    'utf8',
  );
  assert.match(facade, /exports\('GetPlayerByCitizenId'/u);
  assert.match(facade, /GetPlayerByCitizenIdForConsumer\(\s*caller, citizenId\)/u);
});
