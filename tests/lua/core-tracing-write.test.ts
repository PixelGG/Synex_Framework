import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of [
    'foundation',
    'registries',
    'security',
    'bootstrap_api_validation',
    'bootstrap_api_tracing',
    'bootstrap_api',
  ]) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    function CreateTracingFixture()
      local now = 1000
      local resourceStates = { legacy_consumer = 'started' }
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 29) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        loadResourceFile = function() return nil end,
        setTimeout = function(_, callback) callback() end,
        resourceState = function(name) return resourceStates[name] or 'missing' end
      }
      local foundation = SynexCoreFactories.foundation({
        platform = platform,
        maximumTraceSpans = 32
      })
      foundation.configureIds('compatibility-tracing-facade')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local security = SynexCoreFactories.security({
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = {
            synex_bridge = { allow = {'synex.tracing.write'}, deny = {} },
            synex_bridge_qb = { allow = {'synex.tracing.write'}, deny = {} },
            synex_bridge_qbx = { allow = {}, deny = {} },
            synex_bridge_esx = { allow = {'synex.tracing.write'}, deny = {} },
            forged_provider = { allow = {'synex.tracing.write'}, deny = {} }
          }
        }
      })
      local function ensureOwner(resource)
        local epoch = registries.owners:epoch(resource)
        if epoch > 0 then return epoch, nil end
        return registries.owners:activate(resource), nil
      end
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform,
        foundation = foundation,
        registries = registries,
        security = security,
        identity = { connections = {}, characters = {} },
        contractSystem = {},
        messaging = { gateway = {}, events = {}, hooks = {}, services = {} },
        coreResource = 'synex_core',
        runtime = {},
        stateService = {},
        lifecycle = { core = { snapshot = function() return {} end } },
        reliability = {},
        sagaRuntime = {},
        facadeCache = {},
        runtimeGate = { requireAvailable = function() return true, nil end },
        ensureOwner = ensureOwner,
        defaultConfig = {}
      })
      return {
        api = api,
        foundation = foundation,
        owners = registries.owners,
        security = security,
        resourceStates = resourceStates
      }
    end
  `);
  return engine;
}

test('compatibility tracing is provider-owned, capability-gated, correlated, and payload-free', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = CreateTracingFixture()
      for resource, capabilities in pairs({
        synex_bridge = {'synex.tracing.write'},
        synex_bridge_qb = {'synex.tracing.write'},
        synex_bridge_qbx = {'synex.tracing.write'},
        synex_bridge_esx = {},
        forged_provider = {'synex.tracing.write'}
      }) do
        assert(fixture.security.capabilities:registerManifest(resource, {
          capabilities = { request = capabilities }
        }))
      end
      assert(fixture.security.capabilities:class('synex.tracing.write') == 'sensitive')
      assert(fixture.owners:epoch('legacy_consumer') == 0)

      local facade = assert(fixture.api.getAPIForCaller('synex_bridge_qb', '^1.0.0'))
      local marker = 'payload-must-not-be-retained'
      local traceId = 'compat_trace_00000001'
      local output, outputError = facade.Tracing.run({
        operation = 'compat.qb.AddMoney',
        traceId = traceId,
        compatProvider = 'qb',
        consumer = 'legacy_consumer',
        legacyApi = 'AddMoney'
      }, function(receivedTraceId)
        assert(receivedTraceId == traceId)
        return fixture.foundation.withContext({
          traceId = receivedTraceId,
          caller = 'synex_bridge_qb',
          service = 'synex.accounts',
          operation = 'transfer'
        }, function()
          return { privatePayload = marker }, nil
        end)
      end)
      assert(type(output) == 'table' and output.privatePayload == marker
        and outputError == nil)

      local detail = assert(fixture.foundation.tracing:detail(traceId, { limit = 10 }))
      assert(detail.payloadsExposed == false and detail.retainedSpans == 2)
      local parent, child
      for _, span in ipairs(detail.items) do
        if span.operation == 'compat.qb.AddMoney' then parent = span end
        if span.operation == 'synex.accounts' then child = span end
        assert(span.payload == nil and span.request == nil and span.response == nil
          and span.metadata == nil and span.context == nil)
        for key, value in pairs(span) do
          assert(key ~= 'privatePayload' and value ~= marker)
        end
      end
      assert(parent and child and child.parentSpanId == parent.spanId)
      assert(parent.traceId == traceId and child.traceId == traceId)
      assert(parent.compatProvider == 'qb'
        and parent.consumer == 'legacy_consumer'
        and parent.legacyApi == 'AddMoney')
      assert(child.compatProvider == nil and child.consumer == nil
        and child.legacyApi == nil)

      local coordinator = assert(fixture.api.getAPIForCaller('synex_bridge', '^1.0.0'))
      local coordinated = assert(coordinator.Tracing.run({
        operation = 'compat.qb.InvokeAdapter', traceId = 'compat_trace_00000013',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'InvokeAdapter'
      }, function() return { handled = true }, nil end))
      assert(coordinated.handled == true)
      local coordinatorDetail = assert(fixture.foundation.tracing:detail(
        'compat_trace_00000013', { limit = 10 }))
      assert(coordinatorDetail.retainedSpans == 1)
      local coordinatorSpan = coordinatorDetail.items[1]
      assert(coordinatorSpan.operation == 'compat.qb.InvokeAdapter'
        and coordinatorSpan.resource == 'synex_bridge'
        and coordinatorSpan.compatProvider == 'qb'
        and coordinatorSpan.consumer == 'legacy_consumer'
        and coordinatorSpan.legacyApi == 'InvokeAdapter')

      local centralNative, centralNativeError = coordinator.Tracing.run({
        operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000014',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(centralNative == false and centralNativeError.code == 'CAPABILITY_DENIED')
      local providerCoordinator, providerCoordinatorError = facade.Tracing.run({
        operation = 'compat.qb.InvokeAdapter', traceId = 'compat_trace_00000015',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'InvokeAdapter'
      }, function() return true end)
      assert(providerCoordinator == false
        and providerCoordinatorError.code == 'CAPABILITY_DENIED')

      local coreObject = assert(facade.Tracing.run({
        operation = 'compat.qb.GetCoreObject', traceId = 'compat_trace_00000016',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetCoreObject'
      }, function() return { Functions = {} }, nil end))
      assert(type(coreObject.Functions) == 'table')

      local qbx = assert(fixture.api.getAPIForCaller('synex_bridge_qbx', '^1.0.0'))
      local denied, deniedError = qbx.Tracing.run({
        operation = 'compat.qbx.GetPlayer', traceId = 'compat_trace_00000002',
        compatProvider = 'qbx', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(denied == false and deniedError.code == 'CAPABILITY_DENIED')

      local esx = assert(fixture.api.getAPIForCaller('synex_bridge_esx', '^1.0.0'))
      local undeclared, undeclaredError = esx.Tracing.run({
        operation = 'compat.esx.GetPlayer', traceId = 'compat_trace_00000003',
        compatProvider = 'esx', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(undeclared == false and undeclaredError.code == 'CAPABILITY_UNDECLARED')

      local forged = assert(fixture.api.getAPIForCaller('forged_provider', '^1.0.0'))
      local spoofed, spoofedError = forged.Tracing.run({
        operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000004',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(spoofed == false and spoofedError.code == 'CAPABILITY_DENIED')

      fixture.resourceStates.legacy_consumer = 'missing'
      local inactive, inactiveError = facade.Tracing.run({
        operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000005',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(inactive == false and inactiveError.code == 'CALLER_INVALID')
      fixture.resourceStates.legacy_consumer = 'started'

      local invoked = 0
      for _, context in ipairs({
        { operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000006',
          compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer', extra = true },
        { operation = 'compat.qb.GetMoney', traceId = 'compat_trace_00000007',
          compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer' },
        { operation = 'compat.qb.GetPlayer', traceId = 'secret_trace_00000008',
          compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer' },
        { operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000009',
          compatProvider = 'qb', consumer = 'bad consumer', legacyApi = 'GetPlayer' },
        { operation = 'compat.qb.ArbitraryCall', traceId = 'compat_trace_00000012',
          compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'ArbitraryCall' }
      }) do
        local invalid, invalidError = facade.Tracing.run(context, function()
          invoked = invoked + 1
          return true
        end)
        assert(invalid == false and invalidError.code == 'INVALID_ARGUMENT')
      end
      local notCallable, notCallableError = facade.Tracing.run({
        operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000010',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, {})
      assert(notCallable == false and notCallableError.code == 'INVALID_ARGUMENT'
        and invoked == 0)

      local epoch = facade.ownerEpoch
      assert(fixture.owners:purge('synex_bridge_qb', epoch, 'fixture restart'))
      local stale, staleError = facade.Tracing.run({
        operation = 'compat.qb.GetPlayer', traceId = 'compat_trace_00000011',
        compatProvider = 'qb', consumer = 'legacy_consumer', legacyApi = 'GetPlayer'
      }, function() return true end)
      assert(stale == false and staleError.code == 'STALE_RESOURCE')

      return table.concat({
        detail.retainedSpans,
        parent.compatProvider,
        deniedError.code,
        undeclaredError.code,
        spoofedError.code,
        inactiveError.code,
        staleError.code
      }, ':')
    `);
    assert.equal(
      result,
      '2:qb:CAPABILITY_DENIED:CAPABILITY_UNDECLARED:CAPABILITY_DENIED:CALLER_INVALID:STALE_RESOURCE',
    );
  } finally {
    engine.global.close();
  }
});
