import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const foundationPath = join(
  process.cwd(), "libraries", "synex_bridge", "kernel", "foundation.lua",
);
const nativeServerPath = join(
  process.cwd(), "libraries", "synex_bridge", "native_server.lua",
);

test("compatibility DTO boundary rejects hostile scalar and container values without executing them", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(foundationPath, "utf8"));
    const result = await engine.doString(String.raw`
      local foundation = SynexBridgeKernel.Foundation
      local cases = {}
      cases[#cases + 1] = { value = 0 / 0, code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = math.huge, code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = -math.huge, code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = 9007199254740992, code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = function() error('must never execute') end,
        code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = coroutine.create(function() end),
        code = 'COMPAT_DTO_INVALID' }
      cases[#cases + 1] = { value = string.rep('x', 4097), code = 'COMPAT_DTO_LIMIT' }

      local cyclic = {}
      cyclic.self = cyclic
      cases[#cases + 1] = { value = cyclic, code = 'COMPAT_DTO_CYCLE' }

      local deep = {}
      local cursor = deep
      for index = 1, 10 do
        cursor.child = {}
        cursor = cursor.child
      end
      cases[#cases + 1] = { value = deep, code = 'COMPAT_DTO_LIMIT' }

      local hugeArray = {}
      for index = 1, 129 do hugeArray[index] = index end
      cases[#cases + 1] = { value = hugeArray, code = 'COMPAT_DTO_INVALID' }

      local hostileMetadata = setmetatable({ safe = true }, {
        __index = function() error('must never execute') end,
        __pairs = function() error('must never execute') end,
        __call = function() error('must never execute') end,
      })
      cases[#cases + 1] = { value = hostileMetadata, code = 'COMPAT_DTO_INVALID' }

      for index, fixture in ipairs(cases) do
        local completed, copied, copyError = pcall(foundation.copyDto, fixture.value)
        assert(completed, ('case %d escaped the boundary'):format(index))
        assert(copied == nil and type(copyError) == 'table'
          and copyError.code == fixture.code,
          ('case %d returned %s'):format(index,
            type(copyError) == 'table' and tostring(copyError.code) or type(copyError)))
      end

      local polluted = { __proto__ = { privileged = true }, constructor = 'hostile' }
      local detached = assert(foundation.copyDto(polluted, { root = 'object' }))
      assert(detached ~= polluted and detached.__proto__ ~= polluted.__proto__)
      detached.__proto__.privileged = false
      assert(polluted.__proto__.privileged == true)
      return #cases
    `);
    assert.equal(result, 11);
  } finally {
    engine.global.close();
  }
});

test("shared legacy provider boundary rejects malformed money and callback traffic", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      source = 0
      handlers, responses, callbackCalls, capabilityChecks = {}, {}, 0, 0
      json = {
        encode = function() return '{}' end,
        decode = function() return {} end,
      }
      print = function() end
      GetGameTimer = function() return 1000 end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return name == 'hostile_consumer' and 'started' or 'missing'
      end
      GetPlayerName = function(playerSource)
        return tonumber(playerSource) == 10 and 'Fixture' or nil
      end
      GetResourceMetadata = function() return nil end
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
            Capabilities = { checkResource = function(resource, capability)
              capabilityChecks = capabilityChecks + 1
              assert(resource == 'hostile_consumer')
              assert(type(capability) == 'string' and (
                capability:match('^synex%.compat%.qb%.')
                or capability == 'synex.identity.read'
                or capability == 'synex.accounts.read'
                or capability == 'synex.accounts.transfer'))
              return true
            end },
            Players = { getBySource = function()
              return { id = 'session-a', state = 'ACTIVE', sourceGeneration = 1,
                characterId = 'character-a' }, nil
            end },
            Characters = { getActive = function()
              return { id = 'character-a', firstName = 'Test', lastName = 'Player' }, nil
            end },
            Services = {}, RPC = {}, Metrics = {},
          }, nil
        end },
        synex_bridge = {
          AuthorizeCompatibilityConsumer = function()
            return { authority = 'operator_registry', mode = 'compat',
              traceId = 'trace-security-fuzz' }, nil
          end,
        },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fuzz:request', responseEvent = 'fuzz:response',
      })

      local hostileAmounts = { -1, 0, 1.5, 0 / 0, math.huge, -math.huge,
        9007199254740992, '1', {}, false }
      for index, amount in ipairs(hostileAmounts) do
        local completed, changed, changeError = pcall(function()
          return adapter:changeMoney(
            'hostile_consumer', 10, 'cash', 'add', amount, 'fuzz')
        end)
        assert(completed, ('money fuzz case %d escaped'):format(index))
        assert(changed == nil and type(changeError) == 'table'
          and changeError.code == 'INVALID_MONEY_OPERATION')
      end
      local _, badDirection = adapter:changeMoney(
        'hostile_consumer', 10, 'cash', 'set', 1, 'fuzz')
      assert(badDirection.code == 'INVALID_MONEY_OPERATION')
      local _, badAlias = adapter:changeMoney(
        'hostile_consumer', 10, '../cash', 'add', 1, 'fuzz')
      assert(badAlias.code == 'INVALID_MONEY_OPERATION')

      assert(adapter:registerCallback('hostile_consumer', 'fuzz.echo', function()
        callbackCalls = callbackCalls + 1
      end))

      local deep = {}
      local cursor = deep
      for index = 1, 9 do cursor.child = {}; cursor = cursor.child end
      local cyclic = {}; cyclic.self = cyclic
      local huge = {}; for index = 1, 17 do huge[index] = index end
      local malformed = {
        { value = nil }, { value = false }, { value = 'arguments' },
        { value = { n = -1 } }, { value = { n = 17 } },
        { value = { n = 1 } }, { value = { n = 1, [2] = 'sparse' } },
        { value = { n = 1, [1] = deep } },
        { value = { n = 1, [1] = cyclic } },
        { value = { n = 1, [1] = string.rep('x', 1025) } },
        { value = { n = 1,
          [1] = function() error('must never execute') end } },
        { value = huge },
      }
      for index = 1, #malformed do
        source = 10
        local completed = pcall(handlers['fuzz:request'],
          ('request_%08d'):format(index), 'fuzz.echo', malformed[index].value)
        assert(completed, ('callback fuzz case %d escaped'):format(index))
      end
      source = 65535
      assert(pcall(handlers['fuzz:request'], 'request_invalid_source',
        'fuzz.echo', { n = 0 }))
      source = 10
      assert(pcall(handlers['fuzz:request'], 'short', 'fuzz.echo', { n = 0 }))
      assert(pcall(handlers['fuzz:request'], 'request_bad_name',
        string.rep('n', 129), { n = 0 }))

      assert(callbackCalls == 0 and #responses == 0)
      assert(capabilityChecks >= #hostileAmounts + 3)
      return table.concat({ #hostileAmounts, callbackCalls, #responses }, ':')
    `);
    assert.equal(result, "10:0:0");
  } finally {
    engine.global.close();
  }
});
