import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const nativeServerPath = join(process.cwd(), "libraries", "synex_bridge", "native_server.lua");

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
