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
    'bootstrap_api_diagnostics',
    'bootstrap_api',
  ]) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    function CreateMetricsFixture(policy, maximumMetricSeries)
      local now = 1000
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 31) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        loadResourceFile = function() return nil end,
        setTimeout = function(_, callback) callback() end
      }
      local foundation = SynexCoreFactories.foundation({
        platform = platform,
        maximumMetricSeries = maximumMetricSeries
      })
      foundation.configureIds('metrics-write-facade')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local security = SynexCoreFactories.security({
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = policy
      })
      local runtimeGate = {
        requireAvailable = function() return true, nil end
      }
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
        runtimeGate = runtimeGate,
        ensureOwner = ensureOwner,
        defaultConfig = {}
      })
      return {
        api = api,
        foundation = foundation,
        owners = registries.owners,
        security = security
      }
    end
  `);
  return engine;
}

test('metric writers require the write capability, enforce ownership, and fail closed', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = CreateMetricsFixture({
        default = { allow = {}, deny = {} },
        resources = {
          synex_accounts = { allow = {'synex.metrics.write'}, deny = {} },
          synex_metrics_denied = { allow = {}, deny = {} },
          synex_metrics_undeclared = { allow = {'synex.metrics.write'}, deny = {} }
        }
      })
      assert(fixture.security.capabilities:registerManifest('synex_accounts', {
        capabilities = { request = {'synex.metrics.write'} }
      }))
      assert(fixture.security.capabilities:registerManifest('synex_metrics_denied', {
        capabilities = { request = {'synex.metrics.write'} }
      }))
      assert(fixture.security.capabilities:registerManifest('synex_metrics_undeclared', {
        capabilities = { request = {} }
      }))

      local accounts = assert(fixture.api.getAPIForCaller('synex_accounts', '^1.0.0'))
      local incremented, incrementError = accounts.Metrics.increment(
        'synex_accounts_transactions_total', { outcome = 'committed' }, 1)
      assert(incremented, incrementError and incrementError.code)
      local gauged, gaugeError = accounts.Metrics.gauge(
        'synex_accounts_outbox_depth', { queue = 'financial' }, 4)
      assert(gauged, gaugeError and gaugeError.code)
      local observed, observeError = accounts.Metrics.observe(
        'synex_accounts_transaction_duration_ms', { operation = 'post' }, 12)
      assert(observed, observeError and observeError.code)

      local foreign, foreignError = accounts.Metrics.increment(
        'synex_groups_transactions_total', {}, 1)
      assert(foreign == false and type(foreignError) == 'table'
        and foreignError.code == 'METRIC_NAMESPACE_FORBIDDEN'
        and type(foreignError.message) == 'string' and foreignError.retryable == false)

      local invalid, invalidError = accounts.Metrics.gauge(
        'synex_accounts_invalid_sample', {}, 0 / 0)
      assert(invalid == false and type(invalidError) == 'table'
        and invalidError.code == 'INVALID_METRIC_SAMPLE'
        and type(invalidError.message) == 'string' and invalidError.retryable == false)

      local denied = assert(fixture.api.getAPIForCaller('synex_metrics_denied', '^1.0.0'))
      for _, invocation in ipairs({
        function() return denied.Metrics.increment('synex_metrics_denied_total', {}, 1) end,
        function() return denied.Metrics.gauge('synex_metrics_denied_value', {}, 1) end,
        function() return denied.Metrics.observe('synex_metrics_denied_duration', {}, 1) end
      }) do
        local value, failure = invocation()
        assert(value == false and failure.code == 'CAPABILITY_DENIED')
      end

      local undeclared = assert(fixture.api.getAPIForCaller(
        'synex_metrics_undeclared', '^1.0.0'))
      local undeclaredValue, undeclaredError = undeclared.Metrics.increment(
        'synex_metrics_undeclared_total', {}, 1)
      assert(undeclaredValue == false and undeclaredError.code == 'CAPABILITY_UNDECLARED')

      local accountsEpoch = accounts.ownerEpoch
      local purge = fixture.owners:purge('synex_accounts', accountsEpoch, 'fixture restart')
      assert(purge.stale ~= true and not fixture.owners:isCurrent(
        'synex_accounts', accountsEpoch))
      local stale, staleError = accounts.Metrics.increment(
        'synex_accounts_transactions_total', { outcome = 'committed' }, 1)
      assert(stale == false and type(staleError) == 'table'
        and staleError.code == 'STALE_RESOURCE')

      return table.concat({
        foreignError.code,
        invalidError.code,
        undeclaredError.code,
        staleError.code
      }, ':')
    `);
    assert.equal(
      result,
      'METRIC_NAMESPACE_FORBIDDEN:INVALID_METRIC_SAMPLE:CAPABILITY_UNDECLARED:STALE_RESOURCE',
    );
  } finally {
    engine.global.close();
  }
});

test('metric writer returns a structured error when bounded series capacity is exhausted', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = CreateMetricsFixture({
        default = { allow = {}, deny = {} },
        resources = {
          synex_capacity = { allow = {'synex.metrics.write'}, deny = {} }
        }
      }, 8)
      assert(fixture.security.capabilities:registerManifest('synex_capacity', {
        capabilities = { request = {'synex.metrics.write'} }
      }))
      local facade = assert(fixture.api.getAPIForCaller('synex_capacity', '^1.0.0'))
      for index = 1, 8 do
        local written, writeError = facade.Metrics.gauge(
          'synex_capacity_series_' .. index, {}, index)
        assert(written, writeError and writeError.code)
      end
      local rejected, rejection = facade.Metrics.gauge(
        'synex_capacity_series_9', {}, 9)
      assert(rejected == false and type(rejection) == 'table'
        and rejection.code == 'INVALID_METRIC_SAMPLE'
        and type(rejection.message) == 'string' and rejection.retryable == false)
      local cardinality = fixture.foundation.metrics:snapshot().cardinality
      assert(cardinality.series == 8 and cardinality.maximumSeries == 8
        and cardinality.droppedSamples == 1)
      return table.concat({
        rejection.code,
        cardinality.series,
        cardinality.maximumSeries,
        cardinality.droppedSamples
      }, ':')
    `);
    assert.equal(result, 'INVALID_METRIC_SAMPLE:8:8:1');
  } finally {
    engine.global.close();
  }
});
