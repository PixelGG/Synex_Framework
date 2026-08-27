import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";
import { validateRepository } from "../../tools/cli/src/cli.js";

const bridgeRoot = join(process.cwd(), "libraries", "synex_bridge");
const providerPath = join(bridgeRoot, "control_provider.lua");
const serverPath = join(bridgeRoot, "server.lua");
const nativeServerPath = join(bridgeRoot, "native_server.lua");
const descriptorPath = join(bridgeRoot, "synex.resource.json");
const kernelModulePaths = [
  join(bridgeRoot, "kernel", "foundation.lua"),
  join(bridgeRoot, "kernel", "certification.lua"),
  join(bridgeRoot, "kernel", "catalogs.lua"),
  join(bridgeRoot, "kernel", "mappings.lua"),
  join(bridgeRoot, "kernel", "telemetry.lua"),
  join(bridgeRoot, "kernel", "resolver.lua"),
  join(bridgeRoot, "kernel", "runtime.lua"),
  providerPath,
  join(bridgeRoot, "identity_store.lua"),
];

type ControlView = {
  id: string;
  label: string;
  operation: string;
  presentation: string;
  accessClass: string;
  order: number;
  description: string;
};

type BridgeDescriptor = {
  capabilities: { request: string[] };
  controlProvider: {
    namespace: string;
    operations: string[];
    views: ControlView[];
  };
};

function viewProjection(view: ControlView): string {
  return [view.id, view.label, view.operation, view.presentation, view.accessClass,
    String(view.order), view.description].join("\u001f");
}

test("compatibility provider descriptor is valid, optional, bounded, and read-only", async () => {
  const [descriptorText, manifest, provider, server, nativeServer] = await Promise.all([
    readFile(descriptorPath, "utf8"),
    readFile(join(bridgeRoot, "fxmanifest.lua"), "utf8"),
    readFile(providerPath, "utf8"),
    readFile(serverPath, "utf8"),
    readFile(nativeServerPath, "utf8"),
  ]);
  const descriptor = JSON.parse(descriptorText) as BridgeDescriptor;
  const report = await validateRepository(process.cwd(), bridgeRoot);
  assert.deepEqual(report.diagnostics.filter((item) => item.level === "error"), []);

  assert.equal(descriptor.controlProvider.namespace, "compatibility");
  assert.deepEqual(descriptor.controlProvider.operations, ["summary", "health", "list", "findings"]);
  assert.ok(descriptor.controlProvider.views.every((view) => view.accessClass === "general"));
  assert.ok(descriptor.capabilities.request.includes("synex.control.provider.register"));
  assert.ok(manifest.indexOf("'control_provider.lua'") < manifest.indexOf("'server.lua'"));
  assert.doesNotMatch(`${manifest}\n${descriptorText}\n${provider}\n${server}`, /synex_control/u);
  assert.doesNotMatch(provider, /\b(?:inspect|simulate|outbox_retry|reconcile|mutate|delete|write)\b/iu);
  assert.doesNotMatch(provider, /RegisterNetEvent|TriggerClientEvent|MySQL\.|oxmysql|\b(?:SELECT|INSERT|UPDATE|DELETE)\b/iu);
  assert.match(nativeServer, /GetControlCompatibilityUsage/u);
  assert.match(provider, /value >= 1 and value <= 25/u);
  assert.match(server, /usageEntries = 512/u);
});

test("compatibility provider runtime metadata matches its descriptor exactly", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(providerPath, "utf8"));
    const runtime = String(await engine.doString(String.raw`
      local matrix = {
        apiVersion = '1.0.0', deprecated = true, preferredPath = 'native', isolation = 'delegated',
        qb = { callbacks = 'bounded' }, qbx = { exports = 'partial' },
        esx = { sharedObject = 'partial' }, unsupported = { 'direct-sql' },
      }
      local instance = SynexBridgeControlProvider.create({
        matrix = matrix,
        readUsage = function()
          return { items = {}, adapters = {}, availableAdapters = 0,
            unavailableAdapters = 3, totalCalls = 0, truncated = false }
        end,
        readCatalogUsage = function()
          return { items = {}, registeredCatalogs = 0, totalCalls = 0,
            totalSuccess = 0, totalDenied = 0, totalUnsupported = 0,
            totalDeprecated = 0, totalErrors = 0, totalTimeouts = 0,
            totalRateLimited = 0, totalLatencyMs = 0,
            maximumLatencyMs = 0, truncated = false }, nil
        end,
      })
      local definition
      assert(instance:register({ ControlProviders = {
        register = function(value) definition = value return { namespace = value.namespace }, nil end,
      } }))
      local views = {}
      for _, view in ipairs(definition.views) do
        views[#views + 1] = table.concat({ view.id, view.label, view.operation,
          view.presentation, view.accessClass, tostring(view.order), view.description }, '\31')
      end
      local operations = {}
      for operation in pairs(definition.operations) do operations[#operations + 1] = operation end
      table.sort(operations)
      return table.concat(views, '\30') .. '\29' .. table.concat(operations, ',')
    `));
    const [viewData, operationData] = runtime.split("\u001d");
    const descriptor = JSON.parse(await readFile(descriptorPath, "utf8")) as BridgeDescriptor;
    assert.deepEqual(viewData?.split("\u001e"), descriptor.controlProvider.views.map(viewProjection));
    assert.equal(operationData, [...descriptor.controlProvider.operations].sort().join(","));
  } finally {
    engine.global.close();
  }
});

test("compatibility matrix and legacy usage use strict bounded cursor pages", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(providerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local matrix = {
        apiVersion = '1.0.0', deprecated = true, preferredPath = 'native', isolation = 'delegated',
        qb = { a = 'one', b = 'two', c = 'three', d = 'four' },
        qbx = { a = 'one', b = 'two' }, esx = { a = 'one', b = 'two' },
        unsupported = { 'direct-sql', 'inventory' },
      }
      local usageItems = {}
      for index = 1, 6 do
        usageItems[index] = {
          id = ('qb:01:%03d:consumer:operation'):format(index), framework = 'qb',
          adapterResource = 'synex_bridge_qb', consumerResource = 'consumer',
          operation = 'operation.' .. index, calls = index,
          firstSeenMs = index, lastSeenMs = index + 1, deprecated = true,
        }
      end
      local usage = {
        items = usageItems, availableAdapters = 1, unavailableAdapters = 2,
        totalCalls = 21, truncated = false,
        adapters = {
          qb = { available = true, calls = 21, entries = 6, truncated = false },
          qbx = { available = false, calls = 0, entries = 0, truncated = false },
          esx = { available = false, calls = 0, entries = 0, truncated = false },
        },
      }
      local instance = SynexBridgeControlProvider.create({
        matrix = matrix, readUsage = function() return usage, nil end,
        readCatalogUsage = function()
          return {
            registeredCatalogs = 1, totalCalls = 3, totalSuccess = 2,
            totalDenied = 1, totalUnsupported = 0, totalDeprecated = 0,
            totalErrors = 0, totalTimeouts = 0, totalRateLimited = 0,
            totalLatencyMs = 9, maximumLatencyMs = 5, truncated = true,
            items = {{
              id = 'catalog:qb:consumer:invoke', provider = 'qb',
              consumerResource = 'consumer', operation = 'catalog.invoke',
              calls = 3, success = 2, denied = 1, unsupported = 0,
              deprecatedCalls = 0, errors = 0, timeouts = 0, rateLimited = 0,
              latency = { samples = 3, totalMs = 9, averageMs = 3, maximumMs = 5 },
            }},
          }, nil
        end,
      })
      local definition
      assert(instance:register({ ControlProviders = {
        register = function(value) definition = value return { namespace = value.namespace }, nil end,
      } }))

      local first = assert(definition.operations.list({
        view = 'compatibility_matrix', limit = 3, filters = {}, sort = {},
      }))
      assert(#first.items == 3 and first.hasMore == true and first.truncated == true)
      local second = assert(definition.operations.list({
        view = 'compatibility_matrix', cursor = first.nextCursor, limit = 3,
        filters = {}, sort = {},
      }))
      assert(#second.items == 3 and second.items[1].id ~= first.items[1].id)
      local stale, staleError = definition.operations.list({
        view = 'compatibility_matrix', cursor = 'stale', limit = 3,
        filters = {}, sort = {},
      })
      assert(stale == false and staleError.code == 'INVALID_CURSOR')

      local usageFirst = assert(definition.operations.list({
        view = 'legacy_usage', limit = 2, filters = {}, sort = {},
      }))
      assert(#usageFirst.items == 2 and usageFirst.hasMore == true)
      local usageSecond = assert(definition.operations.list({
        view = 'legacy_usage', cursor = usageFirst.nextCursor, limit = 2,
        filters = {}, sort = {},
      }))
      assert(#usageSecond.items == 2 and usageSecond.items[1].id == usageItems[3].id)
      local catalogUsage = assert(definition.operations.list({
        view = 'catalog_usage', limit = 2, filters = {}, sort = {},
      }))
      assert(#catalogUsage.items == 1 and catalogUsage.registeredCatalogs == 1
        and catalogUsage.observedCalls == 3
        and catalogUsage.evidenceTruncated == true
        and catalogUsage.items[1].operation == 'catalog.invoke')
      local rejected, rejection = definition.operations.list({
        view = 'legacy_usage', limit = 26, filters = {}, sort = {},
      })
      assert(rejected == false and rejection.code == 'VALIDATION_FAILED')
      local unknown, unknownError = definition.operations.list({
        view = 'legacy_usage', limit = 2, filters = {}, sort = {}, secret = true,
      })
      assert(unknown == false and unknownError.code == 'VALIDATION_FAILED')

      local findings = assert(definition.operations.findings({
        view = 'migration_readiness', limit = 2, filters = {}, sort = {},
      }))
      assert(#findings.items == 2 and findings.hasMore == true)
      assert(findings.items[1].code == 'LEGACY_USAGE_OBSERVED')
      assert(findings.items[2].severity == 'UNAVAILABLE')
      return 'bounded-pages-pass'
    `);
    assert.equal(result, "bounded-pages-pass");
  } finally {
    engine.global.close();
  }
});

test("unavailable adapter telemetry is explicit and never presented as migration readiness", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(providerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local instance = SynexBridgeControlProvider.create({
        matrix = {
          apiVersion = '1.0.0', deprecated = true, preferredPath = 'native', isolation = 'delegated',
          qb = {}, qbx = {}, esx = {}, unsupported = {},
        },
        readUsage = function()
          return {
            items = {}, availableAdapters = 0, unavailableAdapters = 3,
            totalCalls = 0, truncated = false, adapters = {},
          }, nil
        end,
        readCatalogUsage = function()
          return { items = {}, registeredCatalogs = 0, totalCalls = 0,
            totalSuccess = 0, totalDenied = 0, totalUnsupported = 0,
            totalDeprecated = 0, totalErrors = 0, totalTimeouts = 0,
            totalRateLimited = 0, totalLatencyMs = 0,
            maximumLatencyMs = 0, truncated = false }, nil
        end,
      })
      local definition
      assert(instance:register({ ControlProviders = {
        register = function(value) definition = value return value, nil end,
      } }))
      local overview = assert(definition.operations.summary({ view = 'overview', limit = 10 }))
      assert(overview.status == 'WARNING' and overview.lifecycle == 'DEPRECATED')
      assert(overview.usageStatus == 'UNAVAILABLE' and overview.observedLegacyCalls == 0)
      local rows, unavailable = definition.operations.list({
        view = 'legacy_usage', limit = 10, filters = {}, sort = {},
      })
      assert(rows == false and unavailable.code == 'VIEW_UNAVAILABLE')
      local findings = assert(definition.operations.findings({
        view = 'migration_readiness', limit = 10, filters = {}, sort = {},
      }))
      assert(#findings.items == 3 and findings.hasMore == false)
      for _, finding in ipairs(findings.items) do
        assert(finding.code == 'LEGACY_USAGE_UNAVAILABLE' and finding.severity == 'UNAVAILABLE')
      end
      return 'explicit-unavailable-pass'
    `);
    assert.equal(result, "explicit-unavailable-pass");
  } finally {
    engine.global.close();
  }
});

test("native bridge publishes only its real bounded usage snapshot", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      local now = 1000
      invokingResource = 'synex_bridge'
      handlers, exported, metricWrites = {}, {}, {}
      json = { encode = function() return '{}' end, decode = function() return {} end }
      print = function() end
      GetGameTimer = function() now = now + 1 return now end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetInvokingResource = function() return invokingResource end
      GetResourceState = function(name)
        return type(name) == 'string' and name:match('^consumer_') and 'started' or 'missing'
      end
      GetPlayerName = function() return nil end
      GetConvar = function(_, fallback) return fallback end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
      exports = setmetatable({
        synex_core = { GetAPI = function()
          return {
            Capabilities = { checkResource = function()
              return true
            end },
            Metrics = {
              increment = function(name, labels, value)
                metricWrites[#metricWrites + 1] = { kind = 'increment',
                  name = name, labels = labels, value = value }
                return true
              end,
              observe = function(name, labels, value)
                metricWrites[#metricWrites + 1] = { kind = 'observe',
                  name = name, labels = labels, value = value }
                return true
              end,
            },
          }, nil
        end },
        synex_bridge = { AuthorizeCompatibilityConsumer = function(request)
          assert(request.provider == 'qb'
            and request.providerResource == 'synex_bridge_qb'
            and type(request.consumer) == 'string')
          if request.consumer == 'consumer_denied' then
            return nil, { code = 'COMPAT_CONSUMER_DENIED', retryable = false }
          end
          return {
            authority = 'operator_registry', mode = 'compat', traceId = 'fixture-trace',
          }, nil
        end },
      }, { __call = function(_, name, handler) exported[name] = handler end })
    `);
    await engine.doString(await readFile(kernelModulePaths[0]!, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    const result = await engine.doString(String.raw`
      local adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      })
      local rejected, rejection = adapter:authorize(
        'consumer_denied', 'read', 'player.read')
      assert(rejected == nil and rejection.code == 'COMPAT_CONSUMER_DENIED')
      for index = 1, 520 do
        assert(adapter:authorize(
          ('consumer_fixture_%03d'):format(index), 'read', 'player.read'))
      end
      assert(type(exported.GetControlCompatibilityUsage) == 'function')
      invokingResource = 'untrusted_resource'
      local denied, deniedError = exported.GetControlCompatibilityUsage()
      assert(denied == nil and deniedError.code == 'CALLER_INVALID')
      invokingResource = 'synex_bridge'
      local bundle = exported.GetControlCompatibilityUsage()
      assert(bundle.schemaVersion == 1 and bundle.truncated == false)
      assert(#bundle.snapshots == 1 and bundle.snapshots[1].framework == 'qb')
      assert(bundle.snapshots[1].deprecated == true and bundle.snapshots[1].truncated == true)
      assert(bundle.snapshots[1].health.status == 'READY'
        and bundle.snapshots[1].health.callbackCapacity == 512
        and #bundle.snapshots[1].health.reasons == 0)
      assert(#bundle.snapshots[1].entries == 512)
      assert(type(bundle.snapshots[1].entries[1].resource) == 'string')
      local deniedEntry, successEntry
      for _, entry in ipairs(bundle.snapshots[1].entries) do
        if entry.resource == 'consumer_denied' then deniedEntry = entry end
        if entry.resource == 'consumer_fixture_001' then successEntry = entry end
      end
      assert(deniedEntry.calls == 1 and deniedEntry.outcomes.denied == 1
        and deniedEntry.outcomes.deprecated == 1 and deniedEntry.latency.samples == 1)
      assert(successEntry.calls == 1 and successEntry.outcomes.success == 1
        and successEntry.outcomes.deprecated == 1
        and successEntry.latency.maximumMs >= 1)
      local metricNames = {}
      for _, sample in ipairs(metricWrites) do metricNames[sample.name] = true end
      assert(metricNames.synex_bridge_qb_compat_calls_total == true
        and metricNames.synex_bridge_qb_compat_deprecated_total == true
        and metricNames.synex_bridge_qb_compat_operation_duration_ms == true)
      return #bundle.snapshots[1].entries
    `);
    assert.equal(result, 512);
  } finally {
    engine.global.close();
  }
});

test("bridge registers once per Core epoch and reads active adapter evidence", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers, exported, registrations, lifecycleRegistrations = {}, {}, {}, 0
      invokingResource = 'synex_bridge'
      local usageBundle = {
        schemaVersion = 1, truncated = false,
        snapshots = {{
          framework = 'qb', deprecated = true, truncated = false,
          health = { status = 'READY', reasons = {}, callbackPending = 0,
            callbackCapacity = 512, callbackRegistrations = 1,
            callbackRegistrationCapacity = 256, projectionEntries = 0,
            projectionCapacity = 256, usageEntries = 1, usageCapacity = 512 },
          entries = {{ resource = 'consumer_fixture', operation = 'player.read',
            calls = 4, firstSeenMs = 10, lastSeenMs = 20,
            outcomes = { success = 2, denied = 1, unsupported = 1,
              deprecated = 4, error = 0, timeout = 0, rate_limited = 0 },
            latency = { samples = 4, totalMs = 20, maximumMs = 8 } }},
        }},
      }
      fixtureConfig = {
        ['compatibility/profiles.json'] = {
          schema = 1, kind = 'synex-compatibility-profiles', profiles = {},
        },
        ['compatibility/consumers.json'] = {
          schema = 1, kind = 'synex-compatibility-consumers',
          defaultMode = 'strict', consumers = {},
        },
        ['compatibility/mappings.json'] = {
          schema = 1, kind = 'synex-compatibility-mappings',
          identity = {}, accounts = {}, groups = {}, metadata = {},
        },
        ['compatibility/money-policies.json'] = {
          schema = 1, kind = 'synex-compatibility-money-policies', policies = {},
        },
        ['compatibility/surfaces/qb.json'] = {
          schema = 1, kind = 'synex-compatibility-surfaces', provider = 'qb',
          providerResource = 'synex_bridge_qb', providerVersion = '0.1.0',
          surfaces = {{
            name = 'qb.server.callback_registration', status = 'PARTIAL',
            modes = { 'compat', 'silent' }, deprecated = true,
            adapterOperations = {},
          }},
        },
        ['compatibility/surfaces/qbx.json'] = {
          schema = 1, kind = 'synex-compatibility-surfaces', provider = 'qbx',
          providerResource = 'synex_bridge_qbx', providerVersion = '0.1.0',
          surfaces = {},
        },
        ['compatibility/surfaces/esx.json'] = {
          schema = 1, kind = 'synex-compatibility-surfaces', provider = 'esx',
          providerResource = 'synex_bridge_esx', providerVersion = '0.1.0',
          surfaces = {},
        },
      }
      print = function() end
      json = {
        decode = function(value) return fixtureConfig[value] end,
        encode = function() return '{}' end,
      }
      GetCurrentResourceName = function() return 'synex_bridge' end
      GetInvokingResource = function() return invokingResource end
      GetGameTimer = function() return 1000 end
      GetResourceState = function(name)
        if name == 'synex_bridge_qb' then return 'started' end
        return 'stopped'
      end
      LoadResourceFile = function(_, resourcePath)
        if fixtureConfig[resourcePath] then return resourcePath end
        return nil
      end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(_, handler) handler() end
      exports = setmetatable({
        synex_core = { GetAPI = function()
          return {
            ControlProviders = { register = function(definition)
              registrations[#registrations + 1] = definition
              return { namespace = definition.namespace }, nil
            end },
            Characters = { registerLifecycleParticipant = function()
              lifecycleRegistrations = lifecycleRegistrations + 1
              return ('lifecycle-%d'):format(lifecycleRegistrations), nil
            end },
          }, nil
        end },
        synex_bridge_qb = { GetControlCompatibilityUsage = function()
          return usageBundle
        end },
      }, { __call = function(_, name, handler) exported[name] = handler end })
    `);
    for (const modulePath of kernelModulePaths) {
      await engine.doString(await readFile(modulePath, "utf8"));
    }
    await engine.doString(await readFile(serverPath, "utf8"));
    const result = await engine.doString(String.raw`
      assert(#registrations == 1 and lifecycleRegistrations == 1
        and registrations[1].namespace == 'compatibility')
      assert(type(exported.GetCompatibilityMatrix) == 'function')
      local overview = assert(registrations[1].operations.summary({ view = 'overview', limit = 10 }))
      assert(overview.usageStatus == 'PARTIAL' and overview.availableAdapters == 1)
      assert(overview.unavailableAdapters == 2 and overview.observedLegacyCalls == 4)
      assert(overview.degradedAdapters == 0 and overview.observedSuccess == 2
        and overview.observedDenied == 1 and overview.observedUnsupported == 1
        and overview.observedDeprecated == 4 and overview.averageLatencyMs == 5
        and overview.maximumLatencyMs == 8)
      assert(overview.providers.qb.status == 'READY'
        and overview.providers.qbx.status == 'UNAVAILABLE')
      local page = assert(registrations[1].operations.list({
        view = 'legacy_usage', limit = 10, filters = {}, sort = {},
      }))
      assert(#page.items == 1 and page.items[1].consumerResource == 'consumer_fixture')
      assert(page.items[1].calls == 4 and page.items[1].deprecated == true)
      assert(page.items[1].success == 2 and page.items[1].denied == 1
        and page.items[1].unsupported == 1 and page.items[1].deprecatedCalls == 4)
      assert(page.items[1].latency.samples == 4
        and page.items[1].latency.averageMs == 5
        and page.items[1].latency.maximumMs == 8)
      handlers.onResourceStop('synex_core')
      handlers.onResourceStart('synex_core')
      assert(#registrations == 2 and lifecycleRegistrations == 2)
      local matrix = exported.GetCompatibilityMatrix()
      assert(matrix.deprecated == true
        and matrix.qb['qb.server.callback_registration'] == 'partial')
      return 'restart-registration-pass'
    `);
    assert.equal(result, "restart-registration-pass");
  } finally {
    engine.global.close();
  }
});
