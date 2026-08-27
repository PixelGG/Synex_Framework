import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const providerPath = join(process.cwd(), "libraries", "synex_bridge", "control_provider.lua");

test("bridge control exposes bounded read-only catalog, adapter, error, and latency views", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local fixture = {
        ['compatibility/profiles.json'] = {
          schema = 1, kind = 'synex-compatibility-profiles', profiles = {{
            id = 'qb.fixture', version = '1.0.0', provider = 'qb', mode = 'strict',
            status = 'PARTIAL', failurePolicy = 'fail_start',
            providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
            script = { name = 'fixture', testedVersion = '1.2.3' },
            requiredSurfaces = {{ name = 'qb.server.player_lookup' }},
            requiredAdapters = {}, requiredCatalogs = {},
          }},
        },
        ['compatibility/consumers.json'] = {
          schema = 1, kind = 'synex-compatibility-consumers', defaultMode = 'strict',
          consumers = {{ resource = 'fixture_consumer', provider = 'qb',
            profileId = 'qb.fixture', failurePolicy = 'fail_start', enabled = true }},
        },
        ['compatibility/mappings.json'] = {
          schema = 1, kind = 'synex-compatibility-mappings',
          identity = {{ id = 'qb.identity', provider = 'qb', status = 'PARTIAL',
            legacyId = 'legacy-identity-value', nativeId = 'native-identity-value' }},
          accounts = {{ id = 'qb.cash', provider = 'qb', status = 'PARTIAL',
            alias = 'cash', currencyCode = 'usd', accountKey = 'cash',
            accountRole = 'asset', minorUnit = 0 }}, groups = {}, metadata = {},
        },
      }
      json = { decode = function(path) return fixture[path] end }
      GetCurrentResourceName = function() return 'synex_bridge' end
      LoadResourceFile = function(_, path) return fixture[path] and path or nil end
    `);
    await engine.doString(await readFile(providerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local usage = {
        availableAdapters = 1, unavailableAdapters = 2, totalCalls = 4,
        totalSuccess = 2, totalDenied = 1, totalUnsupported = 0,
        totalDeprecated = 4, totalErrors = 1, totalTimeouts = 0,
        totalRateLimited = 0, totalLatencyMs = 20, maximumLatencyMs = 8,
        truncated = false,
        adapters = {
          qb = { available = true, state = 'started', status = 'READY', calls = 4,
            entries = 1, truncated = false },
          qbx = { available = false, state = 'stopped', status = 'UNAVAILABLE',
            calls = 0, entries = 0, truncated = false, code = 'RESOURCE_UNAVAILABLE' },
          esx = { available = false, state = 'stopped', status = 'UNAVAILABLE',
            calls = 0, entries = 0, truncated = false, code = 'RESOURCE_UNAVAILABLE' },
        },
        items = {{
          id = 'qb:001:fixture_consumer:player.read', framework = 'qb',
          adapterResource = 'synex_bridge_qb', consumerResource = 'fixture_consumer',
          operation = 'player.read', calls = 4, denied = 1, unsupported = 0,
          errors = 1, timeouts = 0, rateLimited = 0,
          latency = { samples = 4, totalMs = 20, averageMs = 5, maximumMs = 8 },
        }},
      }
      local instance = SynexBridgeControlProvider.create({
        matrix = {
          apiVersion = '1.0.0', deprecated = true, preferredPath = 'native',
          isolation = 'delegated', qb = { ['qb.server.player_lookup'] = 'partial' },
          qbx = {}, esx = {}, unsupported = { 'direct-sql' },
        },
        readUsage = function() return usage, nil end,
        readCatalogUsage = function()
          return {
            registeredCatalogs = 1, totalCalls = 2, totalSuccess = 1,
            totalDenied = 1, totalUnsupported = 0, totalDeprecated = 0,
            totalErrors = 0, totalTimeouts = 0, totalRateLimited = 0,
            totalLatencyMs = 6, maximumLatencyMs = 4, truncated = false,
            items = {{
              id = 'catalog:qb:fixture_consumer:invoke', provider = 'qb',
              consumerResource = 'fixture_consumer', operation = 'catalog.invoke',
              calls = 2, success = 1, denied = 1, unsupported = 0,
              deprecatedCalls = 0, errors = 0, timeouts = 0, rateLimited = 0,
              latency = { samples = 2, totalMs = 6, averageMs = 3, maximumMs = 4 },
            }},
          }, nil
        end,
      })
      local definition
      assert(instance:register({ ControlProviders = { register = function(value)
        definition = value return { namespace = value.namespace }, nil
      end } }))
      local function listed(view)
        return assert(definition.operations.list({
          view = view, limit = 25, filters = {}, sort = {},
        }))
      end
      local consumers = listed('consumers')
      local profiles = listed('profiles')
      local mappings = listed('mappings')
      local adapters = listed('adapters')
      local lifecycle = listed('unsupported_deprecated')
      local catalogUsage = listed('catalog_usage')
      local errors = listed('errors')
      local latency = listed('latency')
      assert(#consumers.items == 1 and consumers.items[1].resource == 'fixture_consumer')
      assert(#profiles.items == 1 and profiles.items[1].providerVersion == '0.1.0')
      assert(profiles.items[1].targetFrameworkApiRange == '^7.0.0')
      assert(profiles.items[1].requiredCatalogs == 0)
      assert(#mappings.items == 2)
      for _, item in ipairs(mappings.items) do
        if item.category == 'identity' then
          assert(item.identityValuesRedacted == true and item.source == nil and item.target == nil)
        elseif item.category == 'accounts' then
          assert(item.source == 'cash' and item.currencyCode == 'usd'
            and item.accountKey == 'cash' and item.accountRole == 'asset'
            and item.minorUnit == 0 and item.target == 'usd:cash:asset:0')
        end
      end
      assert(#adapters.items == 3 and adapters.items[1].id == 'adapter:qb')
      assert(#lifecycle.items >= 2)
      assert(#catalogUsage.items == 1 and catalogUsage.registeredCatalogs == 1
        and catalogUsage.observedCalls == 2
        and catalogUsage.items[1].consumerResource == 'fixture_consumer')
      assert(#errors.items == 1 and errors.items[1].errors == 1)
      assert(#latency.items == 1 and latency.items[1].averageMs == 5)
      local overview = assert(definition.operations.summary({ view = 'overview', limit = 25 }))
      assert(overview.catalogStatus == 'AVAILABLE' and overview.configuredProfiles == 1
        and overview.configuredConsumers == 1 and overview.configuredMappings == 2
        and overview.catalogUsageStatus == 'AVAILABLE'
        and overview.registeredRuntimeCatalogs == 1
        and overview.observedCatalogCalls == 2
        and overview.observedCatalogDenied == 1)
      return 'control-operations-pass'
    `);
    assert.equal(result, "control-operations-pass");
  } finally {
    engine.global.close();
  }
});
