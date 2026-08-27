import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();
const foundationPath = join(root, "libraries", "synex_bridge", "kernel", "foundation.lua");
const telemetryPath = join(root, "libraries", "synex_bridge", "kernel", "telemetry.lua");
const nativeServerPath = join(root, "libraries", "synex_bridge", "native_server.lua");

test("native projection cache has deterministic TTL, capacity, invalidation, and restart bounds", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      now, serviceCalls = 1000, 0
      handlers, subscriptions, metricIncrements = {}, {}, {}

      json = {
        encode = function() return '{}' end,
        decode = function() return {} end,
      }
      print = function() end
      GetGameTimer = function() return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetInvokingResource = function() return 'consumer_fixture' end
      GetResourceState = function(name)
        if name == 'consumer_fixture' or name == 'synex_core' then return 'started' end
        return 'missing'
      end
      GetPlayerName = function(playerSource)
        local numeric = tonumber(playerSource)
        if numeric and numeric >= 1 and numeric <= 300 then return 'Fixture ' .. numeric end
        return nil
      end
      RegisterNetEvent = function() end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end

      local function characterId(playerSource)
        return ('character_%d'):format(playerSource)
      end

      local api = {
        Tracing = { run = function(context, handler)
          return handler(context.traceId)
        end },
        Capabilities = {
          checkResource = function(resource, capability)
            assert(resource == 'consumer_fixture')
            assert(type(capability) == 'string')
            return true, nil
          end,
        },
        Players = {
          getBySource = function(playerSource)
            return {
              id = ('session_%d'):format(playerSource), state = 'ACTIVE',
              source = playerSource, sourceGeneration = 1,
              characterId = characterId(playerSource),
            }, nil
          end,
        },
        Characters = {
          getActive = function(playerSource)
            return {
              id = characterId(playerSource), slot = 1,
              firstName = 'Cache', lastName = ('Fixture%d'):format(playerSource),
            }, nil
          end,
        },
        Events = {
          subscribe = function(topic, handler)
            subscriptions[topic] = handler
            return 'subscription:' .. topic, nil
          end,
        },
        Services = {
          call = function(name, _, method, request)
            serviceCalls = serviceCalls + 1
            if name == 'synex.accounts' and method == 'list_by_owner' then
              local scoped = request.owner_ref:gsub('%-', '')
              return { items = {
                {
                  account_id = '11111111-1111-4111-8111-111111111111',
                  currency_code = 'usd', account_key = 'cash_' .. scoped,
                  minor_unit = 0, account_role = 'asset',
                  owner_kind = 'character', owner_ref = request.owner_ref,
                  status = 'active', booked_minor = 100, sequence = 1,
                },
                {
                  account_id = '22222222-2222-4222-8222-222222222222',
                  currency_code = 'usd', account_key = 'bank_' .. scoped,
                  minor_unit = 0, account_role = 'asset',
                  owner_kind = 'character', owner_ref = request.owner_ref,
                  status = 'active', booked_minor = 500, sequence = 1,
                },
              } }, nil
            end
            assert(name == 'synex.groups' and method == 'compatibility_snapshot')
            return { items = {}, truncated = false }, nil
          end,
        },
        Metrics = {
          increment = function(name, _, amount)
            metricIncrements[name] = (metricIncrements[name] or 0) + amount
            return true, nil
          end,
          observe = function() return true, nil end,
        },
      }

      local core = {}
      function core:GetAPI() return api, nil end

      local function lastArgument(...)
        local arguments = table.pack(...)
        return arguments[arguments.n]
      end

      local bridge = {}
      bridge.AuthorizeCompatibilityConsumer = function()
        return {
          authority = 'operator_registry', mode = 'compat',
          traceId = 'trace-cache-bounds',
        }, nil
      end
      bridge.ResolveCompatibilityAccountMapping = function(...)
        local request = lastArgument(...)
        return {
          id = 'qb.' .. request.alias, version = '2.0.0',
          alias = request.alias, currencyCode = 'usd',
          accountKey = request.alias, accountRole = 'asset',
          minorUnit = 0, status = 'PARTIAL',
        }, nil
      end
      bridge.ProjectCompatibilityGroups = function()
        return { items = {}, truncated = false }, nil
      end
      bridge.ResolveCompatibilityIdentity = function(...)
        local request = lastArgument(...)
        return {
          identifier = request.characterId,
          identifierType = 'citizenid', importSource = 'cache-fixture',
        }, nil
      end
      bridge.GetCompatibilityMetadata = function()
        return { values = {}, versions = {} }, nil
      end

      exports = setmetatable({ synex_core = core, synex_bridge = bridge }, {
        __call = function() end,
      })
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));

    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        moneyAliases = { 'cash', 'bank' },
      })

      local first = assert(adapter:readPlayer('consumer_fixture', 1))
      assert(first.money.cash == 100 and serviceCalls == 2)
      first.money.cash = 999
      local detached = assert(adapter:readPlayer('consumer_fixture', 1))
      assert(detached.money.cash == 100 and serviceCalls == 2)

      now = 1500
      assert(adapter:readPlayer('consumer_fixture', 1))
      assert(serviceCalls == 2, 'the inclusive 500ms TTL boundary must hit')
      now = 1501
      assert(adapter:readPlayer('consumer_fixture', 1))
      assert(serviceCalls == 4, 'the first tick beyond TTL must miss')

      assert(subscriptions['synex.accounts.transaction.posted']({}, {}) == true)
      assert(adapter:readPlayer('consumer_fixture', 1))
      assert(serviceCalls == 6)

      for playerSource = 2, 256 do
        assert(adapter:readPlayer('consumer_fixture', playerSource))
      end
      local full = adapter:usageSnapshot('consumer_fixture')
      assert(full.health.projectionEntries == 256
        and full.health.projectionCapacity == 256)
      assert(serviceCalls == 516)

      assert(adapter:readPlayer('consumer_fixture', 257))
      local flushed = adapter:usageSnapshot('consumer_fixture')
      assert(flushed.health.projectionEntries == 1,
        'the bounded cache must flush before inserting entry 257')
      assert(serviceCalls == 518)

      assert(adapter:readPlayer('consumer_fixture', 2))
      assert(serviceCalls == 520,
        'an entry from before the bounded flush must be recomputed')
      local cachedAgain = assert(adapter:readPlayer('consumer_fixture', 2))
      assert(cachedAgain.money.cash == 100 and serviceCalls == 520)

      handlers.onResourceStop('synex_core')
      assert(adapter:usageSnapshot().health.projectionEntries == 0)
      assert(adapter:readPlayer('consumer_fixture', 2))
      assert(serviceCalls == 522,
        'Core restart cleanup must force an authoritative recomputation')

      local usage = adapter:usageSnapshot('consumer_fixture')
      assert(#usage.entries == 1 and usage.entries[1].operation == 'player.read')
      assert(usage.entries[1].calls == 264
        and usage.entries[1].outcomes.success == 264)
      assert(usage.health.projectionEntries == 1
        and usage.health.projectionCapacity == 256)

      local prefix = 'synex_bridge_qb_'
      assert(metricIncrements[prefix .. 'compat_projection_cache_hit'] == 3)
      assert(metricIncrements[prefix .. 'compat_projection_cache_miss'] == 261)
      assert(metricIncrements[prefix .. 'compat_projection_invalidations_total'] == 1)
      assert(metricIncrements[prefix .. 'compat_calls_total'] == 264)
      return table.concat({ serviceCalls, usage.entries[1].calls,
        usage.health.projectionEntries }, ':')
    `);
    assert.equal(result, "522:264:1");
  } finally {
    engine.global.close();
  }
});

test("kernel telemetry has exact series, warning, ordering, cleanup, and timer bounds", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(telemetryPath, "utf8"));
    const result = await engine.doString(String.raw`
      local tick, timerEpoch, warnings = 10, 'boot-a', 0
      local telemetry = SynexBridgeKernel.Telemetry.create({
        timerModulus = 32,
        maximumOwners = 2,
        maximumSeries = 3,
        maximumSeriesPerOwner = 2,
        maximumWarningKeys = 2,
        clock = function() return tick end,
        clockEpoch = function() return timerEpoch end,
        warningSink = function() warnings = warnings + 1 end,
      })

      assert(telemetry:record('owner_b', 2, 'Surface.B', 'error', 7))
      assert(telemetry:record('owner_a', 1, 'Surface.Z', 'success', 3))
      assert(telemetry:record('owner_a', 1, 'Surface.A', 'timeout', 5))
      assert(telemetry:record('owner_a', 1, 'Surface.A', 'success', 2))

      local ordered = assert(telemetry:snapshot())
      assert(ordered.count == 3 and ordered.truncated == false)
      assert(ordered.series[1].owner == 'owner_a'
        and ordered.series[1].surface == 'Surface.A')
      assert(ordered.series[2].owner == 'owner_a'
        and ordered.series[2].surface == 'Surface.Z')
      assert(ordered.series[3].owner == 'owner_b'
        and ordered.series[3].surface == 'Surface.B')
      assert(ordered.series[1].count == 2
        and ordered.series[1].latency.totalMs == 7
        and ordered.series[1].latency.maximumMs == 5
        and ordered.series[1].outcomes.timeout == 1
        and ordered.series[1].outcomes.success == 1)

      local _, seriesLimit = telemetry:record(
        'owner_b', 2, 'Surface.C', 'success', 1)
      assert(seriesLimit.code == 'COMPAT_REGISTRY_LIMIT')
      assert(telemetry:snapshot().truncated == true)

      assert(telemetry:warnOnce('owner_a', 1, 'warning.one',
        'COMPAT_API_DEPRECATED') == true)
      assert(telemetry:warnOnce('owner_a', 1, 'warning.one',
        'COMPAT_API_DEPRECATED') == false)
      assert(telemetry:warnOnce('owner_b', 2, 'warning.two',
        'COMPAT_API_DEPRECATED') == true)
      local _, warningLimit = telemetry:warnOnce(
        'owner_b', 2, 'warning.three', 'COMPAT_API_DEPRECATED')
      assert(warningLimit.code == 'COMPAT_REGISTRY_LIMIT' and warnings == 2)

      tick = 31
      local wrapped = assert(telemetry:start('owner_b', 2, 'Surface.B'))
      tick = 2
      assert(telemetry:finish(wrapped, 'success') == 3)
      local ownerB = assert(telemetry:snapshot('owner_b', 2))
      assert(ownerB.count == 1 and ownerB.series[1].count == 2
        and ownerB.series[1].latency.totalMs == 10
        and ownerB.series[1].latency.maximumMs == 7)

      assert(telemetry:cleanup('owner_a', 1) == 3)
      assert(telemetry:record('owner_c', 3, 'Surface.C', 'success', 1))
      assert(telemetry:record('owner_c', 3, 'Surface.D', 'denied', 2))
      local recovered = assert(telemetry:snapshot())
      assert(recovered.count == 3 and recovered.truncated == true)
      assert(recovered.series[1].owner == 'owner_b')
      assert(recovered.series[2].owner == 'owner_c'
        and recovered.series[2].surface == 'Surface.C')
      assert(recovered.series[3].owner == 'owner_c'
        and recovered.series[3].surface == 'Surface.D')
      return table.concat({ recovered.count, warnings,
        recovered.series[1].count }, ':')
    `);
    assert.equal(result, "3:2:2");
  } finally {
    engine.global.close();
  }
});
