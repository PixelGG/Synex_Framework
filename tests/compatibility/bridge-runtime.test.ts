import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const nativeServerPath = join(process.cwd(), "libraries", "synex_bridge", "native_server.lua");
const nativeClientPath = join(process.cwd(), "libraries", "synex_bridge", "native_client.lua");
const esxServerPath = join(process.cwd(), "resources", "synex_bridge_esx", "server.lua");

test("native callback bridge binds owners, rejects spoofed sources, and fences source reuse", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local now = 1000
      source = 0
      handlers, responses, timeouts = {}, {}, {}
      delegated = {}
      session = { id = 'session-a', state = 'ACTIVE', sourceGeneration = 1, characterId = 'char-a' }
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name) return name == 'consumer_fixture' and 'started' or 'missing' end
      GetPlayerName = function(playerSource) return tonumber(playerSource) == 10 and 'Fixture' or nil end
      GetConvar = function(_, fallback) return fallback end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(_, handler) timeouts[#timeouts + 1] = handler end
      TriggerEvent = function() end
      TriggerClientEvent = function(...)
        responses[#responses + 1] = table.pack(...)
      end
      exports = {
        synex_core = {
          GetAPI = function()
            return {
              Capabilities = {
                checkResource = function(target, capability, operation)
                  delegated[#delegated + 1] = { target = target, capability = capability, operation = operation }
                  return true, nil
                end
              },
              Players = { getBySource = function() return session, nil end },
              Characters = {}, Services = {}, RPC = {}
            }, nil
          end
        }
      }
    `);
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        counterpartyConvars = {}
      })
      assert(adapter:registerCallback('consumer_fixture', 'fixture.echo', function(playerSource, respond, value)
        assert(playerSource == 10)
        respond(value)
      end))

      source = 10
      handlers['fixture:request']('request_00000001', 'fixture.echo', { n = 1, 'hello' })
      assert(#responses == 1)
      assert(responses[1][1] == 'fixture:response' and responses[1][2] == 10)
      assert(responses[1][3] == 'request_00000001' and responses[1][4] == true)
      assert(delegated[1].target == 'consumer_fixture')
      assert(delegated[1].capability == 'synex.compat.qb.callbacks')

      source = 65535
      handlers['fixture:request']('request_00000002', 'fixture.echo', { n = 0 })
      assert(#responses == 1)

      local delayed
      assert(adapter:registerCallback('consumer_fixture', 'fixture.async', function(_, respond)
        delayed = respond
      end))
      source = 10
      handlers['fixture:request']('request_00000003', 'fixture.async', { n = 0 })
      assert(type(delayed) == 'function' and #responses == 1)
      session = { id = 'session-b', state = 'ACTIVE', sourceGeneration = 2, characterId = 'char-b' }
      delayed('stale')
      assert(#responses == 1)
      return table.concat({#delegated, #responses, #timeouts}, ':')
    `);
    assert.equal(result, "4:1:2");
  } finally {
    engine.global.close();
  }
});

test("native server callbacks accept genuine Cfx callables and reject marker-only values", async () => {
  const engine = await new LuaFactory().createEngine();
  await engine.global.set("cfxServerHandler", {});
  try {
    await engine.doString(String.raw`
      local now = 1000
      source = 0
      handlers, responses = {}, {}
      session = { id = 'session-a', state = 'ACTIVE', sourceGeneration = 1, characterId = 'char-a' }
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_esx' end
      GetResourceState = function(name) return name == 'consumer_fixture' and 'started' or 'missing' end
      GetPlayerName = function(playerSource) return tonumber(playerSource) == 10 and 'Fixture' or nil end
      GetConvar = function(_, fallback) return fallback end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function(...) responses[#responses + 1] = table.pack(...) end
      exports = {
        synex_core = {
          GetAPI = function()
            return {
              Capabilities = { checkResource = function() return true, nil end },
              Players = { getBySource = function() return session, nil end },
              Characters = {}, Services = {}, RPC = {}
            }, nil
          end
        }
      }
    `);
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'esx', capabilityPrefix = 'synex.compat.esx',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        counterpartyConvars = {}
      })
      local markerAccepted, markerError = adapter:registerCallback(
        'consumer_fixture', 'fixture.marker', { __cfx_functionReference = 'marker-only' })
      assert(markerAccepted == nil and markerError.code == 'INVALID_CALLBACK')
      local inheritedAccepted, inheritedError = adapter:registerCallback(
        'consumer_fixture', 'fixture.inherited',
        setmetatable({}, { __index = { __call = function() end } }))
      assert(inheritedAccepted == nil and inheritedError.code == 'INVALID_CALLBACK')

      local tableCalls, userdataCalls = 0, 0
      local tableHandler = setmetatable({ __cfx_functionReference = 'table-handler' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, playerSource, respond, value)
          assert(playerSource == 10 and value == 'table')
          tableCalls = tableCalls + 1
          respond('table-ok')
        end
      })
      debug.setmetatable(cfxServerHandler, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, playerSource, respond, value)
          assert(playerSource == 10 and value == 'userdata')
          userdataCalls = userdataCalls + 1
          respond('userdata-ok')
        end
      })
      assert(type(cfxServerHandler) == 'userdata')
      assert(adapter:registerCallback('consumer_fixture', 'fixture.table', tableHandler))
      assert(adapter:registerCallback('consumer_fixture', 'fixture.userdata', cfxServerHandler))

      source = 10
      handlers['fixture:request']('request_00000001', 'fixture.table', { n = 1, 'table' })
      handlers['fixture:request']('request_00000002', 'fixture.userdata', { n = 1, 'userdata' })
      assert(tableCalls == 1 and userdataCalls == 1 and #responses == 2)
      assert(responses[1][4] == true and responses[2][4] == true)
      return table.concat({tableCalls, userdataCalls, #responses}, ':')
    `);
    assert.equal(result, "1:1:2");
  } finally {
    engine.global.close();
  }
});

test("native client callbacks accept Cfx callables and contain stale funcref failures", async () => {
  const engine = await new LuaFactory().createEngine();
  await engine.global.set("cfxClientCallback", {});
  await engine.global.set("cfxStaleCallback", {});
  try {
    await engine.doString(String.raw`
      source = 65535
      handlers, requests, timeouts = {}, {}, {}
      local now = 1000
      GetGameTimer = function() now = now + 1 return now end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      SetTimeout = function(_, handler) timeouts[#timeouts + 1] = handler end
      TriggerServerEvent = function(...) requests[#requests + 1] = table.pack(...) end
    `);
    await engine.doString(await readFile(nativeClientPath, "utf8"));
    const result = await engine.doString(String.raw`
      local client = SynexBridgeClient.create({
        requestEvent = 'fixture:request', responseEvent = 'fixture:response'
      })
      assert(client:triggerCallback('fixture.marker', {
        __cfx_functionReference = 'marker-only'
      }) == false)
      assert(client:triggerCallback('fixture.inherited',
        setmetatable({}, { __index = { __call = function() end } })) == false)

      local tableValue, userdataValue = nil, nil
      local tableCallback = setmetatable({ __cfx_functionReference = 'table-callback' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, value) tableValue = value end
      })
      debug.setmetatable(cfxClientCallback, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, value) userdataValue = value end
      })
      assert(client:triggerCallback('fixture.table', tableCallback))
      handlers['fixture:response'](requests[1][2], true, { n = 1, 'table-ok' })
      assert(client:triggerCallback('fixture.userdata', cfxClientCallback))
      handlers['fixture:response'](requests[2][2], true, { n = 1, 'userdata-ok' })
      assert(tableValue == 'table-ok' and userdataValue == 'userdata-ok')

      debug.setmetatable(cfxStaleCallback, {
        __metatable = 'protected-cfx-funcref',
        __call = function() error('private stale funcref detail') end
      })
      assert(client:triggerCallback('fixture.stale', cfxStaleCallback))
      local staleHandled, staleError = pcall(
        handlers['fixture:response'], requests[3][2], false,
        { code = 'CALLBACK_FAILED', message = 'sanitized' })
      assert(staleHandled == true and staleError == nil)

      local removedCalls = 0
      local removedCallback = setmetatable({}, {
        __call = function() removedCalls = removedCalls + 1 end
      })
      assert(client:triggerCallback('fixture.removed', removedCallback))
      setmetatable(removedCallback, {})
      local removedHandled = pcall(
        handlers['fixture:response'], requests[4][2], true, { n = 0 })
      assert(removedHandled == true and removedCalls == 0)
      return table.concat({#requests, #timeouts, tableValue, userdataValue}, ':')
    `);
    assert.equal(result, "4:4:table-ok:userdata-ok");
  } finally {
    engine.global.close();
  }
});

test("ESX shared-object event accepts Cfx callables without exposing callback failures", async () => {
  const engine = await new LuaFactory().createEngine();
  await engine.global.set("cfxSharedObjectCallback", {});
  try {
    await engine.doString(String.raw`
      local now = 1000
      source = 0
      handlers, exported = {}, {}
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_esx' end
      GetInvokingResource = function() return 'consumer_fixture' end
      GetResourceState = function(name) return name == 'consumer_fixture' and 'started' or 'missing' end
      GetPlayerName = function() return nil end
      GetConvar = function(_, fallback) return fallback end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      local api = {
        Capabilities = { checkResource = function() return true, nil end },
        Players = {}, Services = {}, RPC = {},
        Characters = {
          registerLifecycleParticipant = function() return 'fixture-token', nil end
        }
      }
      exports = setmetatable({
        synex_core = { GetAPI = function() return api, nil end }
      }, {
        __call = function(_, name, handler) exported[name] = handler end
      })
    `);
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    await engine.doString(await readFile(esxServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local event = handlers['esx:getSharedObject']
      assert(type(event) == 'function')
      local markerCalls = 0
      event({ __cfx_functionReference = 'marker-only', called = markerCalls })

      local tableCalls, userdataCalls = 0, 0
      local tableCallback = setmetatable({ __cfx_functionReference = 'table-callback' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, object)
          assert(object.Compatibility.framework == 'esx')
          tableCalls = tableCalls + 1
        end
      })
      debug.setmetatable(cfxSharedObjectCallback, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, object)
          assert(object.Compatibility.framework == 'esx')
          userdataCalls = userdataCalls + 1
        end
      })
      event(tableCallback)
      event(cfxSharedObjectCallback)
      local staleCallback = setmetatable({}, {
        __call = function() error('private shared-object callback detail') end
      })
      local staleHandled, staleError = pcall(event, staleCallback)
      assert(staleHandled == true and staleError == nil)
      assert(tableCalls == 1 and userdataCalls == 1)
      return table.concat({tableCalls, userdataCalls, type(cfxSharedObjectCallback)}, ':')
    `);
    assert.equal(result, "1:1:userdata");
  } finally {
    engine.global.close();
  }
});
