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
const esxFacadeServerPath = join(
  process.cwd(), "compat", "facades", "es_extended", "server.lua",
);

test("native provider requires compatibility and native consumer gates before domain access", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers = {}
      compatibilityAllowed, nativeAllowed = true, false
      capabilityChecks, coordinatorCalls = 0, 0
      playerReads, domainServiceCalls, domainRpcCalls = 0, 0, 0
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() return 1000 end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return name == 'consumer_fixture' and 'started' or 'missing'
      end
      GetPlayerName = function() return 'Fixture' end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      exports = {
        synex_core = { GetAPI = function()
          return {
            Capabilities = { checkResource = function(resource, capability)
              capabilityChecks = capabilityChecks + 1
              assert(resource == 'consumer_fixture')
              if capability:match('^synex%.compat%.qb%.') then
                if compatibilityAllowed then return true end
              elseif capability == 'synex.identity.read'
                or capability == 'synex.accounts.read'
                or capability == 'synex.accounts.transfer' then
                if nativeAllowed then return true end
              else
                error('unexpected capability: ' .. tostring(capability))
              end
              return nil, { code = 'CAPABILITY_DENIED', retryable = false }
            end },
            Players = { getBySource = function()
              playerReads = playerReads + 1
              return nil, { code = 'SHOULD_NOT_RUN' }
            end },
            Characters = {},
            Services = { call = function()
              domainServiceCalls = domainServiceCalls + 1
              return nil, { code = 'SHOULD_NOT_RUN' }
            end },
            RPC = { call = function()
              domainRpcCalls = domainRpcCalls + 1
              return nil, { code = 'SHOULD_NOT_RUN' }
            end },
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function()
          coordinatorCalls = coordinatorCalls + 1
          return { authority = 'core', mode = 'compat', traceId = 'trace-two-gate' }, nil
        end },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        moneyAliases = { 'cash' },
      })

      local nativeDenied, nativeError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 1, 'fixture')
      assert(nativeDenied == nil and nativeError.code == 'CAPABILITY_DENIED')
      assert(playerReads == 0 and domainServiceCalls == 0 and domainRpcCalls == 0)

      compatibilityAllowed, nativeAllowed = false, true
      local compatDenied, compatError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 1, 'fixture')
      assert(compatDenied == nil and compatError.code == 'CAPABILITY_DENIED')
      assert(playerReads == 0 and domainServiceCalls == 0 and domainRpcCalls == 0)

      local unknown, unknownError = adapter:authorize(
        'consumer_fixture', 'read', 'unknown.operation')
      assert(unknown == nil and unknownError.code == 'COMPAT_API_UNSUPPORTED')
      assert(coordinatorCalls == 2 and capabilityChecks == 3)
      assert(playerReads == 0 and domainServiceCalls == 0 and domainRpcCalls == 0)
      return table.concat({ coordinatorCalls, capabilityChecks, domainRpcCalls }, ':')
    `);
    assert.equal(result, "2:3:0");
  } finally {
    engine.global.close();
  }
});

test("native read surfaces enforce least-privilege capabilities and record unsupported usage", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers, capabilityChecks = {}, {}
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() return 1000 end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return name == 'consumer_fixture' and 'started' or 'missing'
      end
      GetPlayerName = function() return 'Fixture' end
      RegisterNetEvent = function() end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      exports = {
        synex_core = { GetAPI = function()
          return {
            Capabilities = { checkResource = function(resource, capability)
              assert(resource == 'consumer_fixture')
              capabilityChecks[#capabilityChecks + 1] = capability
              return true, nil
            end },
            Events = { subscribe = function() return 'fixture-token', nil end },
            Players = {}, Characters = {}, Services = {}, RPC = {},
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function(request)
          assert(request.consumer == 'consumer_fixture' and request.provider == 'qb')
          return {
            authority = 'operator_registry', mode = 'compat',
            traceId = 'trace-read-surface',
          }, nil
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
      assert(adapter:authorize('consumer_fixture', 'read', 'money.read'))
      assert(#capabilityChecks == 3)
      assert(capabilityChecks[1] == 'synex.compat.qb.read')
      assert(capabilityChecks[2] == 'synex.identity.read')
      assert(capabilityChecks[3] == 'synex.accounts.read')

      assert(adapter:authorize('consumer_fixture', 'read', 'groups.read'))
      assert(#capabilityChecks == 6)
      assert(capabilityChecks[4] == 'synex.compat.qb.read')
      assert(capabilityChecks[5] == 'synex.identity.read')
      assert(capabilityChecks[6] == 'synex.groups.read')

      assert(adapter:authorize('consumer_fixture', 'read', 'metadata.read'))
      assert(#capabilityChecks == 8)
      assert(capabilityChecks[7] == 'synex.compat.qb.read')
      assert(capabilityChecks[8] == 'synex.identity.read')

      assert(adapter:authorize('consumer_fixture', 'write', 'metadata.set'))
      assert(#capabilityChecks == 10)
      assert(capabilityChecks[9] == 'synex.compat.qb.write')
      assert(capabilityChecks[10] == 'synex.identity.read')

      assert(adapter:authorize('consumer_fixture', 'write', 'groups.set_job'))
      assert(#capabilityChecks == 14)
      assert(capabilityChecks[11] == 'synex.compat.qb.write')
      assert(capabilityChecks[12] == 'synex.identity.read')
      assert(capabilityChecks[13] == 'synex.groups.read')
      assert(capabilityChecks[14]
        == 'synex.groups.compatibility.set_primary_grade')

      assert(adapter:authorize('consumer_fixture', 'write', 'groups.set_gang'))
      assert(#capabilityChecks == 18)
      assert(capabilityChecks[15] == 'synex.compat.qb.write')
      assert(capabilityChecks[16] == 'synex.identity.read')
      assert(capabilityChecks[17] == 'synex.groups.read')
      assert(capabilityChecks[18]
        == 'synex.groups.compatibility.set_primary_grade')

      assert(adapter:authorize('consumer_fixture', 'write', 'groups.set_duty'))
      assert(#capabilityChecks == 22)
      assert(capabilityChecks[19] == 'synex.compat.qb.write')
      assert(capabilityChecks[20] == 'synex.identity.read')
      assert(capabilityChecks[21] == 'synex.groups.read')
      assert(capabilityChecks[22] == 'synex.groups.duty')

      for index = 4, 22 do
        assert(capabilityChecks[index] ~= 'synex.accounts.read')
      end

      assert(adapter:authorize(
        'consumer_fixture', 'read', 'accounts.custom_read'))
      assert(#capabilityChecks == 25)
      assert(capabilityChecks[23] == 'synex.compat.qb.read')
      assert(capabilityChecks[24] == 'synex.identity.read')
      assert(capabilityChecks[25] == 'synex.accounts.read')

      local unsupported, unsupportedError = adapter:unsupported(
        'consumer_fixture', 'qb.server.identifier_player_lookup',
        'Identifier lookup is unavailable.')
      assert(unsupported == nil and unsupportedError.code == 'COMPAT_API_UNSUPPORTED')
      local usage
      for _, entry in ipairs(adapter:usageSnapshot('consumer_fixture').entries) do
        if entry.operation == 'qb.server.identifier_player_lookup' then usage = entry end
      end
      assert(usage and usage.calls == 1 and usage.outcomes.unsupported == 1)

      local invalid, invalidError = adapter:unsupported(
        'consumer_fixture', 'invalid operation', 'Unavailable.')
      assert(invalid == nil and invalidError.code == 'COMPAT_INVALID_ARGUMENT')
      return table.concat({ #capabilityChecks, usage.calls,
        usage.outcomes.unsupported }, ':')
    `);
    assert.equal(result, "25:1:1");
  } finally {
    engine.global.close();
  }
});

test("native provider generic adapter calls are bounded and visible in provider usage", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local now = 1000
      handlers, metricWrites, bridgeCalls = {}, {}, 0
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        return name == 'consumer_fixture' and 'started' or 'missing'
      end
      GetPlayerName = function() return 'Fixture' end
      RegisterNetEvent = function() end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      exports = {
        synex_core = { GetAPI = function()
          return {
            Metrics = {
              increment = function(name, labels, value)
                metricWrites[#metricWrites + 1] = { name = name, labels = labels, value = value }
              end,
              observe = function(name, labels, value)
                metricWrites[#metricWrites + 1] = { name = name, labels = labels, value = value }
              end,
            },
            Capabilities = {}, Players = {}, Characters = {}, Services = {}, RPC = {},
          }, nil
        end },
        synex_bridge = { InvokeCompatibilityAdapter = function(consumer, request)
          bridgeCalls = bridgeCalls + 1
          assert(consumer == 'consumer_fixture' and request.surface == 'qb.inventory.item_lookup')
          if request.operation == 'item.get' then return { item = request.payload.item }, nil end
          if request.operation == 'item.fail' then
            return nil, { code = 'COMPAT_ADAPTER_MISSING', retryable = true }
          end
          if request.operation == 'item.false' then return false, nil end
          if request.operation == 'item.callable' then return { leak = function() end }, nil end
          error('unexpected operation')
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
      local request = {
        surface = 'qb.inventory.item_lookup', operation = 'item.get',
        payload = { item = 'water' },
      }
      local value, valueError = adapter:invokeCompatibilityAdapter(
        'consumer_fixture', request)
      assert(value and value.item == 'water' and valueError == nil)
      value.item = 'mutated'

      local failed, failedError = adapter:invokeCompatibilityAdapter(
        'consumer_fixture', {
          surface = request.surface, operation = 'item.fail', payload = {},
        })
      assert(failed == nil and failedError.code == 'COMPAT_ADAPTER_MISSING')
      local falseValue, falseError = adapter:invokeCompatibilityAdapter(
        'consumer_fixture', {
          surface = request.surface, operation = 'item.false', payload = {},
        })
      assert(falseValue == nil and falseError.code == 'COMPAT_RESOLUTION_FAILED')
      local callable, callableError = adapter:invokeCompatibilityAdapter(
        'consumer_fixture', {
          surface = request.surface, operation = 'item.callable', payload = {},
        })
      assert(callable == nil and callableError.code == 'COMPAT_DTO_INVALID')
      local invalid, invalidError = adapter:invokeCompatibilityAdapter(
        'consumer_fixture', { operation = function() end })
      assert(invalid == nil and invalidError.code == 'COMPAT_INVALID_ARGUMENT')

      local byOperation = {}
      for _, entry in ipairs(adapter:usageSnapshot('consumer_fixture').entries) do
        byOperation[entry.operation] = entry
      end
      assert(byOperation['item.get'].calls == 1
        and byOperation['item.get'].outcomes.success == 1)
      assert(byOperation['item.fail'].outcomes.unsupported == 1)
      assert(byOperation['item.false'].outcomes.error == 1)
      assert(byOperation['item.callable'].outcomes.error == 1)
      assert(#metricWrites >= 12 and bridgeCalls == 4)
      handlers.onResourceStop('consumer_fixture')
      assert(#adapter:usageSnapshot('consumer_fixture').entries == 0)
      return table.concat({ bridgeCalls, failedError.code, falseError.code,
        callableError.code }, ':')
    `);
    assert.equal(
      result,
      "4:COMPAT_ADAPTER_MISSING:COMPAT_RESOLUTION_FAILED:COMPAT_DTO_INVALID",
    );
  } finally {
    engine.global.close();
  }
});

test("native providers reject real legacy frameworks but accept marked historical facades", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers, authorizations = {}, 0
      capabilityAllowed = true
      legacyStarted, facadeMarker = true, nil
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() return 1000 end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name)
        if name == 'consumer_fixture' then return 'started' end
        if name == 'qb-core' and legacyStarted then return 'started' end
        return 'stopped'
      end
      GetResourceMetadata = function(name, key, index)
        assert(name == 'qb-core' and key == 'synex_compatibility_facade' and index == 0)
        return facadeMarker
      end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      RegisterNetEvent = function() end
      exports = {
        synex_core = { GetAPI = function()
          return { Capabilities = { checkResource = function()
            if capabilityAllowed then return true end
            return nil, { code = 'CAPABILITY_DENIED', retryable = false }
          end } }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function()
          authorizations = authorizations + 1
          return { authority = 'operator_registry', mode = 'compat', traceId = 'trace-fixture' }, nil
        end },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        historicalResource = 'qb-core',
      })
      local denied, deniedError = adapter:authorize('consumer_fixture', 'read', 'player.read')
      assert(denied == nil and deniedError.code == 'COMPAT_FRAMEWORK_CONFLICT')
      assert(authorizations == 0)

      legacyStarted, facadeMarker = false, nil
      handlers.onResourceStop('qb-core')
      local allowed = assert(adapter:authorize('consumer_fixture', 'read', 'player.read'))
      assert(allowed.mode == 'compat' and authorizations == 1)

      legacyStarted, facadeMarker = true, 'true'
      handlers.onResourceStart('qb-core')
      assert(adapter:authorize('consumer_fixture', 'read', 'player.read'))
      assert(authorizations == 2)
      capabilityAllowed = false
      local bypassed, capabilityError = adapter:authorize(
        'consumer_fixture', 'read', 'player.read')
      assert(bypassed == nil and capabilityError.code == 'CAPABILITY_DENIED')
      assert(authorizations == 3)
      return deniedError.code
    `);
    assert.equal(result, "COMPAT_FRAMEWORK_CONFLICT");
  } finally {
    engine.global.close();
  }
});

test("native callback bridge binds owners, rejects spoofed sources, and fences source reuse", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local now = 1000
      source = 0
      handlers, responses, timeouts, traceContexts = {}, {}, {}, {}
      authorizations = {}
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
              Tracing = { run = function(context, handler)
                traceContexts[#traceContexts + 1] = context
                return handler(context.traceId)
              end },
              Capabilities = {
                checkResource = function() return true end,
              },
              Players = { getBySource = function() return session, nil end },
              Characters = {}, Services = {}, RPC = {}
            }, nil
          end
        },
        synex_bridge = {
          AuthorizeCompatibilityConsumer = function(request)
            authorizations[#authorizations + 1] = request
            assert(request.provider == 'qb'
              and request.providerResource == 'synex_bridge_qb'
              and request.consumer == 'consumer_fixture')
            return {
              authority = 'operator_registry', mode = 'compat',
              traceId = ('fixture-trace-%d'):format(#authorizations),
            }, nil
          end,
        },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
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
      handlers['fixture:request'](
        'request_00000001', 'consumer_fixture', 'fixture.echo', { n = 1, 'hello' })
      assert(#responses == 1)
      assert(responses[1][1] == 'fixture:response' and responses[1][2] == 10)
      assert(responses[1][3] == 'request_00000001' and responses[1][4] == true)
      assert(authorizations[1].consumer == 'consumer_fixture')
      assert(authorizations[1].capability == 'synex.compat.qb.callbacks')
      assert(#traceContexts == 2
        and traceContexts[1].operation == 'compat.qb.RegisterCallback'
        and traceContexts[2].operation == 'compat.qb.TriggerCallback'
        and traceContexts[2].traceId == 'fixture-trace-2'
        and traceContexts[2].consumer == 'consumer_fixture')

      source = 65535
      handlers['fixture:request'](
        'request_00000002', 'consumer_fixture', 'fixture.echo', { n = 0 })
      assert(#responses == 1)

      local delayed
      assert(adapter:registerCallback('consumer_fixture', 'fixture.async', function(_, respond)
        delayed = respond
      end))
      source = 10
      handlers['fixture:request'](
        'request_00000003', 'consumer_fixture', 'fixture.async', { n = 0 })
      assert(type(delayed) == 'function' and #responses == 1,
        table.concat({ type(delayed), #responses, #authorizations }, ':'))
      session = { id = 'session-b', state = 'ACTIVE', sourceGeneration = 2, characterId = 'char-b' }
      delayed('stale')
      assert(#responses == 1)
      local invokeUsage
      for _, entry in ipairs(adapter:usageSnapshot('consumer_fixture').entries) do
        if entry.operation == 'callback.invoke' then invokeUsage = entry end
      end
      assert(invokeUsage.calls == 2 and invokeUsage.outcomes.success == 1
        and invokeUsage.outcomes.denied == 1
        and invokeUsage.outcomes.deprecated == 2
        and invokeUsage.latency.samples == 2)
      assert(#traceContexts == 4
        and traceContexts[3].operation == 'compat.qb.RegisterCallback'
        and traceContexts[4].operation == 'compat.qb.TriggerCallback')
      return table.concat({#authorizations, #responses, #timeouts}, ':')
    `);
    assert.equal(result, "4:1:2");
  } finally {
    engine.global.close();
  }
});

test("native player projection binds Accounts reads to the active character and fails closed on incomplete projections", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local now = 1000
      source = 0
      handlers, serviceCalls, rpcCalls, subscriptions = {}, {}, {}, {}
      traceContexts = {}
      authorizations, projectionCalls, policyCalls, groupMutations = {}, {}, {}, {}
      rpcRetryFailures, ambiguousAliasMapping = 0, false
      deniedNativeCapability = nil
      resolvedDutySession, resolvedDutyState, resolvedDutyVersion = false, nil, nil
      mappedDutyState = 'active'
      session = {
        id = 'session-fixture', state = 'ACTIVE', source = 10,
        sourceGeneration = 7, characterId = 'character_fixture_0001', userId = 'user_fixture_0001'
      }
      character = {
        id = 'character_fixture_0001', firstName = 'Bridge', lastName = 'Fixture', slot = 1
      }
      accountPage = {
        items = {{
          account_id = '11111111-1111-4111-8111-111111111111',
          currency_code = 'usd', account_key = 'cash_character_fixture_0001', minor_unit = 0,
          account_role = 'asset',
          owner_kind = 'character', owner_ref = 'character_fixture_0001',
          status = 'active', booked_minor = 125, reserved_minor = 0,
          available_minor = 125, sequence = 1, version = 1,
          snapshot_created_at = '2026-08-26T10:00:00.000000Z'
        }, {
          account_id = '55555555-5555-4555-8555-555555555555',
          currency_code = 'usd', account_key = 'bank_character_fixture_0001', minor_unit = 0,
          account_role = 'asset',
          owner_kind = 'character', owner_ref = 'character_fixture_0001',
          status = 'active', booked_minor = 900, reserved_minor = 0,
          available_minor = 900, sequence = 2, version = 1,
          snapshot_created_at = '2026-08-26T10:00:30.000000Z'
        }, {
          account_id = '44444444-4444-4444-8444-444444444444',
          currency_code = 'usd', account_key = 'archived_cash', minor_unit = 0,
          account_role = 'asset',
          owner_kind = 'character', owner_ref = 'character_fixture_0001',
          status = 'closed', booked_minor = 0, reserved_minor = 0,
          available_minor = 0, sequence = 3, version = 2,
          snapshot_created_at = '2026-08-26T10:01:00.000000Z'
        }}
      }
      groupPage = {
        items = {{
          membership_id = 'membership_fixture_0001', status = 'ACTIVE',
          is_primary = true, roles = {}, roles_truncated = false,
          group = {
            group_id = 'group_fixture_0001', key = 'police', type = 'job',
            name = 'Police', label = 'Police Department',
          },
          grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
          duty = { counts_as_on_duty = true },
        }},
        truncated = false,
      }
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetResourceState = function(name) return name == 'consumer_fixture' and 'started' or 'missing' end
      GetPlayerName = function(playerSource) return tonumber(playerSource) == 10 and 'Fixture' or nil end
      GetConvar = function(name, fallback)
        if name == 'fixture_cash_counterparty' then
          return '22222222-2222-4222-8222-222222222222'
        end
        return fallback
      end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      exports = {
        synex_core = {
          GetAPI = function()
            return {
              Tracing = { run = function(context, handler)
                traceContexts[#traceContexts + 1] = context
                assert(context.payload == nil and context.request == nil
                  and context.response == nil and context.metadata == nil)
                return handler(context.traceId)
              end },
              Capabilities = { checkResource = function(_, capability)
                if capability == deniedNativeCapability then
                  return nil, { code = 'CAPABILITY_DENIED', retryable = false }
                end
                return true
              end },
              Players = { getBySource = function(playerSource)
                assert(playerSource == 10)
                return session, nil
              end },
              Characters = { getActive = function(playerSource)
                assert(playerSource == 10)
                return character, nil
              end },
              Services = { call = function(name, range, method, request, context)
                serviceCalls[#serviceCalls + 1] = {
                  name = name, range = range, method = method,
                  request = request, context = context
                }
                 assert(range == '^1.0.0')
                 if name == 'synex.accounts' then
                   assert(type(context) == 'table'
                     and context.traceId == traceContexts[#traceContexts].traceId)
                   assert(method == 'list_by_owner')
                  assert(request.owner_kind == 'character'
                    and request.owner_ref == session.characterId)
                  assert(request.actor_kind == 'character'
                    and request.actor_ref == session.characterId)
                  assert(request.limit == 50 and request.cursor == nil)
                  return accountPage, nil
                end
                 assert(name == 'synex.groups')
                 if method == 'compatibility_snapshot' then
                   assert(type(context) == 'table'
                     and context.traceId == traceContexts[#traceContexts].traceId)
                   assert(request.actor_character_id == session.characterId
                     and request.limit == 8)
                   return groupPage, nil
                 end
                 assert(type(context) == 'table'
                   and type(context.metadata) == 'table'
                   and context.metadata.compatibility.provider == 'qb'
                   and context.metadata.compatibility.consumer == 'consumer_fixture')
                 if method == 'compatibility_resolve_target' then
                   assert(request.actor_character_id == session.characterId
                     and request.group_type == 'job'
                     and request.group_key == 'police'
                     and request.grade_key == 'sergeant')
                   local target = {
                     group_id = 'group_fixture_0001',
                     grade_id = 'grade_fixture_0001',
                     membership_id = 'membership_fixture_0001',
                     membership_status = 'ACTIVE', membership_version = 4,
                     primary_state = 'selected', primary_version = 3,
                   }
                   if resolvedDutySession then
                     target.duty_session_id = 'duty_fixture_0001'
                     target.duty_state = resolvedDutyState
                     target.duty_version = resolvedDutyVersion
                   end
                   return target, nil
                 end
                 groupMutations[#groupMutations + 1] = {
                   method = method, request = request, context = context,
                 }
                 if method == 'compatibility_set_primary_grade' then
                   assert(request.actor_character_id == session.characterId
                     and request.membership_id == 'membership_fixture_0001'
                     and request.grade_id == 'grade_fixture_0001'
                     and request.expected_version == 4
                     and request.group_type == 'job'
                     and request.expected_primary_version == 3)
                   return {
                     membership_id = request.membership_id,
                     membership_version = 5,
                     grade_id = request.grade_id,
                     primary_id = 'primary_fixture_0001',
                     primary_version = 4,
                     replayed = false,
                   }, nil
                 end
                 if method == 'duty_start' then
                   assert(request.actor_character_id == session.characterId
                     and request.membership_id == 'membership_fixture_0001'
                     and request.state == mappedDutyState)
                 elseif method == 'duty_stop' then
                   assert(request.actor_character_id == session.characterId
                     and request.duty_session_id == 'duty_fixture_0001'
                     and request.expected_version == resolvedDutyVersion
                     and request.reason == 'compatibility_mapping')
                 elseif method == 'duty_update' then
                   assert(request.actor_character_id == session.characterId
                     and request.duty_session_id == 'duty_fixture_0001'
                     and request.expected_version == resolvedDutyVersion
                     and request.state == mappedDutyState)
                 else
                   error('unexpected Groups mutation method: ' .. tostring(method))
                 end
                 return {
                   entity_id = 'duty_fixture_0001', version = resolvedDutyVersion or 1,
                 }, nil
              end },
              Events = { subscribe = function(topic, handler)
                assert(type(topic) == 'string' and type(handler) == 'function')
                subscriptions[topic] = handler
                return 'subscription:' .. topic, nil
              end },
              RPC = { call = function(name, version, request, options)
                rpcCalls[#rpcCalls + 1] = {
                  name = name, version = version, request = request, options = options
                }
                assert((name == 'synex.accounts.transfer_v2'
                  or name == 'synex.accounts.mint_v2'
                  or name == 'synex.accounts.burn_v2') and version == '2.0.0')
                if rpcRetryFailures > 0 then
                  rpcRetryFailures = rpcRetryFailures - 1
                  return nil, {
                    code = 'PROVIDER_UNAVAILABLE', retryable = true,
                  }
                end
                return { transaction_id = '33333333-3333-4333-8333-333333333333' }, nil
              end }
            }, nil
          end
        },
        synex_bridge = {
          AuthorizeCompatibilityConsumer = function(request)
            authorizations[#authorizations + 1] = request
            assert(request.provider == 'qb'
              and request.providerResource == 'synex_bridge_qb'
              and request.consumer == 'consumer_fixture')
            return {
              authority = 'operator_registry', mode = 'compat',
              traceId = ('fixture-trace-%d'):format(#authorizations),
            }, nil
          end,
          ResolveCompatibilityIdentity = function(request)
            assert(request.provider == 'qb'
              and request.characterId == session.characterId)
            return {
              identifier = 'QB-CITIZEN-42', identifierType = 'citizenid',
              importSource = 'fixture_registry',
            }, nil
          end,
          GetCompatibilityMetadata = function(request)
            assert(request.provider == 'qb'
              and request.characterId == session.characterId)
            return { values = { hunger = 40 }, versions = { hunger = 2 } }, nil
          end,
           ResolveCompatibilityAccountMapping = function(request)
            assert(request.provider == 'qb'
              and (request.alias == 'cash' or request.alias == 'bank'))
            return {
              id = 'qb.' .. request.alias, version = '2.0.0', alias = request.alias,
              currencyCode = 'usd',
              accountKey = ambiguousAliasMapping and 'cash' or request.alias,
              accountRole = 'asset', minorUnit = 0, status = 'PARTIAL',
            }, nil
           end,
           ResolveCompatibilityGroupMapping = function(request)
             assert(request.provider == 'qb' and request.legacyType == 'job'
               and request.legacyName == 'police' and request.legacyGrade == 3)
             return {
               id = 'qb.job.police.3', version = '1.0.0',
               legacyType = 'job', legacyName = 'police', legacyGrade = 3,
               nativeGroupType = 'job', nativeGroupKey = 'police',
               gradeKey = 'sergeant', bossRoles = {},
               dutySupported = true, dutyState = mappedDutyState, status = 'PARTIAL',
             }, nil
           end,
          ProjectCompatibilityGroups = function(request)
            projectionCalls[#projectionCalls + 1] = request
            assert(request.provider == 'qb' and request.groups == groupPage)
            if groupPage.truncated then
              return nil, { code = 'COMPAT_PROJECTION_UNAVAILABLE' }
            end
            return { items = groupPage.items, truncated = false }, nil
          end,
          ResolveMoneyPolicy = function(request)
            policyCalls[#policyCalls + 1] = request
            assert(request.provider == 'qb' and request.consumer == 'consumer_fixture'
              and request.moneyAlias == 'cash')
            if request.legacyReason == 'explicit_mint'
              or request.legacyReason == 'explicit_mint_denied' then
              assert(request.direction == 'add')
              return {
                action = 'mint', reasonCode = 'compat.fixture.mint',
                policyId = 'qb.fixture.cash.mint', policyVersion = '1.0.0',
              }, nil
            end
            if request.legacyReason == 'explicit_burn' then
              assert(request.direction == 'remove')
              return {
                action = 'burn', reasonCode = 'compat.fixture.burn',
                policyId = 'qb.fixture.cash.burn', policyVersion = '1.0.0',
              }, nil
            end
            return {
              action = 'transfer',
              accountId = '22222222-2222-4222-8222-222222222222',
              reasonCode = 'compat.fixture',
              policyId = 'qb.fixture.cash.add', policyVersion = '1.0.0',
            }, nil
          end,
        },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        counterpartyConvars = {},
        moneyAliases = { 'cash', 'bank' }
      })

      local full = assert(adapter:readPlayer('consumer_fixture', 10))
      assert(#traceContexts == 1
        and traceContexts[1].operation == 'compat.qb.GetPlayer'
        and traceContexts[1].compatProvider == 'qb'
        and traceContexts[1].consumer == 'consumer_fixture'
        and traceContexts[1].legacyApi == 'GetPlayer')
      assert(full.identity.identifier == 'QB-CITIZEN-42')
      assert(full.money.cash == 125 and full.money.bank == 900
        and full.accountIds == nil)
      assert(full.groups.items[1].group.key == 'police'
        and full.groups.items[1].grade.rank == 3)
      assert(full.metadata.hunger == 40 and full.metadataVersions.hunger == 2)
      assert(#serviceCalls == 2 and #projectionCalls == 1 and #rpcCalls == 0)

      groupPage.truncated = true
      handlers.onResourceStop('synex_core')
      local incompleteGroups, groupError = adapter:readPlayer('consumer_fixture', 10)
      assert(incompleteGroups == nil
        and groupError.code == 'COMPAT_PROJECTION_UNAVAILABLE')
      assert(#serviceCalls == 4 and #rpcCalls == 0)
      groupPage.truncated = false

      local changed, changeError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 25, 'fixture', full.fence)
      assert(changed == true and changeError == nil,
        type(changeError) == 'table' and changeError.code or tostring(changeError))
      assert(#serviceCalls == 5 and #rpcCalls == 1 and #policyCalls == 1)
      assert(rpcCalls[1].name == 'synex.accounts.transfer_v2'
        and rpcCalls[1].version == '2.0.0'
        and rpcCalls[1].request.destination_account_id == accountPage.items[1].account_id)
      assert(rpcCalls[1].request.actor_kind == 'resource'
        and rpcCalls[1].request.actor_ref == 'consumer_fixture')
      assert(traceContexts[3].operation == 'compat.qb.AddMoney'
        and rpcCalls[1].options.traceId == traceContexts[3].traceId)

      accountPage.next_cursor = '50'
      local incomplete, incompleteError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'remove', 1, 'fixture', full.fence)
      assert(incomplete == nil and incompleteError.code == 'ACCOUNT_PROJECTION_TRUNCATED')
      assert(#serviceCalls == 6 and #rpcCalls == 1)

      accountPage.next_cursor = nil
      accountPage.items[1].owner_ref = 'character_attacker_0001'
      local crossed, crossedError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'remove', 1, 'fixture', full.fence)
      assert(crossed == nil and crossedError.code == 'INVALID_ACCOUNT_SNAPSHOT')
      assert(#serviceCalls == 7 and #rpcCalls == 1)

      accountPage.items[1].owner_ref = session.characterId
      character.id = 'character_attacker_0001'
      local mismatched, mismatchError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'remove', 1, 'fixture', full.fence)
      assert(mismatched == nil and mismatchError.code == 'INVALID_CHARACTER_SNAPSHOT')
      assert(#serviceCalls == 7 and #rpcCalls == 1)

      character.id = session.characterId
      local projected = assert(adapter:readPlayer('consumer_fixture', 10))
      assert(projected.money.cash == 125
        and projected.groups.items[1].duty.counts_as_on_duty == true)
      assert(#serviceCalls == 9)
      accountPage.items[1].booked_minor = 175
      groupPage.items[1].duty.counts_as_on_duty = false
      local cached = assert(adapter:readPlayer('consumer_fixture', 10))
      assert(cached.money.cash == 125
        and cached.groups.items[1].duty.counts_as_on_duty == true)
      assert(#serviceCalls == 9)
      assert(subscriptions['synex.accounts.transaction.posted']({}, {}) == true)
      local accountInvalidated = assert(adapter:readPlayer('consumer_fixture', 10))
      assert(accountInvalidated.money.cash == 175
        and accountInvalidated.groups.items[1].duty.counts_as_on_duty == false)
      assert(#serviceCalls == 11)
      groupPage.items[1].duty.counts_as_on_duty = true
      assert(subscriptions['synex.groups.duty.updated']({}, {}) == true)
      local dutyInvalidated = assert(adapter:readPlayer('consumer_fixture', 10))
      assert(dutyInvalidated.groups.items[1].duty.counts_as_on_duty == true)
      assert(#serviceCalls == 13)

      local independent = assert(adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 25, 'fixture', full.fence))
      assert(independent == true and #rpcCalls == 2)
      assert(rpcCalls[2].request.idempotency_key
        ~= rpcCalls[1].request.idempotency_key)

      rpcRetryFailures = 1
      local retried = assert(adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 25, 'fixture', full.fence))
      assert(retried == true and #rpcCalls == 4)
      assert(rpcCalls[3].request.idempotency_key
        == rpcCalls[4].request.idempotency_key)
      assert(rpcCalls[3].request.reference_id
        == rpcCalls[4].request.reference_id)
      assert(rpcCalls[3].options.idempotencyKey
        == rpcCalls[4].options.idempotencyKey)
      assert(rpcCalls[3].options.traceId == rpcCalls[4].options.traceId)
      assert(rpcCalls[3].request.idempotency_key
        ~= rpcCalls[2].request.idempotency_key)
      assert(#serviceCalls == 15)
      ambiguousAliasMapping = true
      local ambiguous, ambiguousError = adapter:changeMoney(
        'consumer_fixture', 10, 'cash', 'add', 1, 'fixture', full.fence)
       assert(ambiguous == nil and ambiguousError.code == 'COMPAT_MAPPING_AMBIGUOUS')
       assert(#serviceCalls == 15 and #rpcCalls == 4)
       ambiguousAliasMapping = false

       local setHigher = assert(adapter:setMoney(
         'consumer_fixture', 10, 'cash', 200, 'fixture', full.fence))
       assert(setHigher == true and #serviceCalls == 16 and #rpcCalls == 5,
         ('setHigher:%s:%d:%d'):format(tostring(setHigher), #serviceCalls, #rpcCalls))
       assert(rpcCalls[5].request.amount_minor == 25
         and rpcCalls[5].request.expected_destination_sequence == 1
         and rpcCalls[5].request.expected_source_sequence == nil)
       local noOp = assert(adapter:setMoney(
         'consumer_fixture', 10, 'cash', 175, 'fixture', full.fence))
       assert(noOp == true and #serviceCalls == 17 and #rpcCalls == 5,
         ('noOp:%s:%d:%d'):format(tostring(noOp), #serviceCalls, #rpcCalls))
       local setLower = assert(adapter:setMoney(
         'consumer_fixture', 10, 'cash', 150, 'fixture', full.fence))
       assert(setLower == true and #serviceCalls == 18 and #rpcCalls == 6,
         ('setLower:%s:%d:%d'):format(tostring(setLower), #serviceCalls, #rpcCalls))
       assert(rpcCalls[6].request.amount_minor == 25
         and rpcCalls[6].request.expected_source_sequence == 1
         and rpcCalls[6].request.expected_destination_sequence == nil)

       local jobSet = assert(adapter:setGroup(
         'consumer_fixture', 10, 'job', 'police', 3,
         'compatibility_mapping', full.fence))
       assert(jobSet == true and #serviceCalls == 20 and #groupMutations == 1,
         ('jobSet:%s:%d:%d'):format(tostring(jobSet), #serviceCalls, #groupMutations))
       assert(groupMutations[1].method == 'compatibility_set_primary_grade')
       local dutySet = assert(adapter:setDuty(
         'consumer_fixture', 10, true, 'compatibility_mapping', full.fence))
       assert(dutySet == true and #serviceCalls == 23 and #groupMutations == 2,
         ('dutySet:%s:%d:%d'):format(tostring(dutySet), #serviceCalls, #groupMutations))
       assert(groupMutations[2].method == 'duty_start')

       resolvedDutySession, resolvedDutyState, resolvedDutyVersion = true, 'active', 1
       local dutyStopped = assert(adapter:setDuty(
         'consumer_fixture', 10, false, 'compatibility_mapping', full.fence))
       assert(dutyStopped == true and #serviceCalls == 26 and #groupMutations == 3)
       assert(groupMutations[3].method == 'duty_stop')

       mappedDutyState = 'standby'
       local dutyUpdated = assert(adapter:setDuty(
         'consumer_fixture', 10, true, 'compatibility_mapping', full.fence))
       assert(dutyUpdated == true and #serviceCalls == 29 and #groupMutations == 4)
       assert(groupMutations[4].method == 'duty_update')

       resolvedDutyState, resolvedDutyVersion = 'standby', 2
       local dutyNoOp = assert(adapter:setDuty(
         'consumer_fixture', 10, true, 'compatibility_mapping', full.fence))
       assert(dutyNoOp == true and #serviceCalls == 31 and #groupMutations == 4)

       local minted = assert(adapter:changeMoney(
         'consumer_fixture', 10, 'cash', 'add', 10, 'explicit_mint', full.fence))
       assert(minted == true and #serviceCalls == 32 and #rpcCalls == 7)
       assert(rpcCalls[7].name == 'synex.accounts.mint_v2'
         and rpcCalls[7].request.account_id == accountPage.items[1].account_id
         and rpcCalls[7].request.source_account_id == nil
         and rpcCalls[7].request.destination_account_id == nil)

       local burned = assert(adapter:changeMoney(
         'consumer_fixture', 10, 'cash', 'remove', 5, 'explicit_burn', full.fence))
       assert(burned == true and #serviceCalls == 33 and #rpcCalls == 8)
       assert(rpcCalls[8].name == 'synex.accounts.burn_v2'
         and rpcCalls[8].request.account_id == accountPage.items[1].account_id)

       deniedNativeCapability = 'synex.accounts.mint'
       local deniedMint, deniedMintError = adapter:changeMoney(
         'consumer_fixture', 10, 'cash', 'add', 1,
         'explicit_mint_denied', full.fence)
       assert(deniedMint == nil and deniedMintError.code == 'CAPABILITY_DENIED'
         and #serviceCalls == 34 and #rpcCalls == 8)

       deniedNativeCapability = nil
       local primarySet = assert(adapter:setPrimaryGroup(
         'consumer_fixture', 10, 'job', 'police'))
       assert(primarySet == true and #serviceCalls == 37
         and #groupMutations == 5)
       assert(groupMutations[5].method == 'compatibility_set_primary_grade')
       assert(groupMutations[5].context.metadata.compatibility.legacyApi
         == 'SetPlayerPrimaryJob')

       for _, context in ipairs(traceContexts) do
         local keys = 0
         for key in pairs(context) do
           keys = keys + 1
           assert(key == 'operation' or key == 'traceId'
             or key == 'compatProvider' or key == 'consumer'
             or key == 'legacyApi')
         end
         assert(keys == 5)
       end

       return table.concat({#serviceCalls, #rpcCalls, #groupMutations, groupError.code,
         incompleteError.code, crossedError.code, mismatchError.code,
         ambiguousError.code, deniedMintError.code}, ':')
    `);
    assert.equal(
      result,
      "37:8:5:COMPAT_PROJECTION_UNAVAILABLE:ACCOUNT_PROJECTION_TRUNCATED:INVALID_ACCOUNT_SNAPSHOT:INVALID_CHARACTER_SNAPSHOT:COMPAT_MAPPING_AMBIGUOUS:CAPABILITY_DENIED",
    );
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
      handlers, responses, authorizations = {}, {}, {}
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
              Tracing = { run = function(context, handler)
                return handler(context.traceId)
              end },
              Capabilities = { checkResource = function()
                return true
              end },
              Players = { getBySource = function() return session, nil end },
              Characters = {}, Services = {}, RPC = {}
            }, nil
          end
        },
        synex_bridge = {
          AuthorizeCompatibilityConsumer = function(request)
            authorizations[#authorizations + 1] = request
            assert(request.provider == 'esx'
              and request.providerResource == 'synex_bridge_esx'
              and request.consumer == 'consumer_fixture')
            return {
              authority = 'operator_registry', mode = 'compat',
              traceId = ('fixture-trace-%d'):format(#authorizations),
            }, nil
          end,
        },
      }
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
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
      handlers['fixture:request'](
        'request_00000001', 'consumer_fixture', 'fixture.table', { n = 1, 'table' })
      handlers['fixture:request'](
        'request_00000002', 'consumer_fixture', 'fixture.userdata', { n = 1, 'userdata' })
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
      json = { encode = function() return '[]' end }
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
      assert(client:triggerCallback('consumer_fixture', 'fixture.marker', {
        __cfx_functionReference = 'marker-only'
      }) == false)
      assert(client:triggerCallback('consumer_fixture', 'fixture.inherited',
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
      assert(client:triggerCallback('consumer_fixture', 'fixture.table', tableCallback))
      handlers['fixture:response'](requests[1][2], true, { n = 1, 'table-ok' })
      assert(client:triggerCallback('consumer_fixture', 'fixture.userdata', cfxClientCallback))
      handlers['fixture:response'](requests[2][2], true, { n = 1, 'userdata-ok' })
      assert(tableValue == 'table-ok' and userdataValue == 'userdata-ok')

      debug.setmetatable(cfxStaleCallback, {
        __metatable = 'protected-cfx-funcref',
        __call = function() error('private stale funcref detail') end
      })
      assert(client:triggerCallback('consumer_fixture', 'fixture.stale', cfxStaleCallback))
      local staleHandled, staleError = pcall(
        handlers['fixture:response'], requests[3][2], false,
        { code = 'CALLBACK_FAILED', message = 'sanitized' })
      assert(staleHandled == true and staleError == nil)

      local removedCalls = 0
      local removedCallback = setmetatable({}, {
        __call = function() removedCalls = removedCalls + 1 end
      })
      assert(client:triggerCallback('consumer_fixture', 'fixture.removed', removedCallback))
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

test("ESX facade shared-object event preserves the real caller and contains funcref failures", async () => {
  const engine = await new LuaFactory().createEngine();
  await engine.global.set("cfxSharedObjectCallback", {});
  try {
    await engine.doString(String.raw`
      handlers, exported, providerCalls = {}, {}, {}
      invokingResource = 'consumer_fixture'
      local sharedObject = {
        GetPlayerFromId = function() end,
        RegisterServerCallback = function() end,
      }
      local provider = {}
      function provider:GetSharedObjectForConsumer(consumer)
        providerCalls[#providerCalls + 1] = consumer
        return sharedObject, nil
      end
      GetInvokingResource = function() return invokingResource end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      exports = setmetatable({ synex_bridge_esx = provider }, {
        __call = function(_, name, handler) exported[name] = handler end,
      })
    `);
    await engine.doString(await readFile(esxFacadeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local event = handlers['esx:getSharedObject']
      assert(type(event) == 'function')
      event({ __cfx_functionReference = 'marker-only' })
      assert(#providerCalls == 0)

      local tableCalls, userdataCalls = 0, 0
      local tableCallback = setmetatable({ __cfx_functionReference = 'table-callback' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, object)
          assert(type(object.GetPlayerFromId) == 'function'
            and object.Compatibility == nil)
          tableCalls = tableCalls + 1
        end,
      })
      debug.setmetatable(cfxSharedObjectCallback, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, object)
          assert(type(object.RegisterServerCallback) == 'function'
            and object.Compatibility == nil)
          userdataCalls = userdataCalls + 1
        end,
      })
      event(tableCallback)
      event(cfxSharedObjectCallback)
      assert(providerCalls[1] == 'consumer_fixture'
        and providerCalls[2] == 'consumer_fixture')

      local staleCallback = setmetatable({}, {
        __call = function() error('private shared-object callback detail') end,
      })
      local staleHandled, staleError = pcall(event, staleCallback)
      assert(staleHandled == true and staleError == nil)
      assert(tableCalls == 1 and userdataCalls == 1)

      invokingResource = 'x'
      event(tableCallback)
      assert(#providerCalls == 3 and tableCalls == 1)
      return table.concat({tableCalls, userdataCalls,
        type(cfxSharedObjectCallback), providerCalls[1]}, ':')
    `);
    assert.equal(result, "1:1:userdata:consumer_fixture");
  } finally {
    engine.global.close();
  }
});
