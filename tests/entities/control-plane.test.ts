import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

type ControlProviderDescriptor = {
  namespace: string;
  operations: string[];
  schemaVersion: number;
  views: Array<{
    id: string;
    operation: string;
    presentation: string;
  }>;
};

test('Entities publishes a bounded read-only Control provider instead of Control-owned domain code', async () => {
  const [descriptorSource, provider, inspectProvider, controlServer] = await Promise.all([
    source('resources/synex_entities/synex.resource.json'),
    source('resources/synex_entities/server/control_provider.lua'),
    source('resources/synex_entities/server/control_provider_inspect.lua'),
    source('resources/synex_control/server/server.lua'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    controlProvider: ControlProviderDescriptor;
    dependencies: { optional: Array<{ name: string }>; required: Array<{ name: string }> };
  };
  const metadata = descriptor.controlProvider;

  assert.equal(metadata.schemaVersion, 1);
  assert.equal(metadata.namespace, 'entities');
  assert.deepEqual(metadata.operations, [
    'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings',
  ]);
  assert.ok(metadata.views.some((view) => view.id === 'entities'
    && view.operation === 'list' && view.presentation === 'table'));
  assert.ok(metadata.views.some((view) => view.operation === 'inspect'
    && view.presentation === 'detail'));
  assert.ok(metadata.views.some((view) => view.id === 'findings'
    && view.operation === 'findings' && view.presentation === 'findings'));

  for (const operation of metadata.operations.filter((name) => name !== 'inspect')) {
    assert.match(provider, new RegExp(`handlers\\.${operation}\\s*=\\s*function`, 'u'));
  }
  assert.match(provider, /handlers\.inspect\s*=\s*inspectProvider\.create/u);
  assert.match(inspectProvider, /return function\(request, context\)/u);
  assert.match(provider, /api\.ControlProviders/u);
  assert.match(provider, /ControlProviders\.register/u);
  assert.match(provider, /spawnAdmission\.quotaSnapshot/u);
  assert.match(provider, /protected\('quotas'/u);
  assert.doesNotMatch(`${provider}\n${inspectProvider}`,
    /handlers\.(?:create|delete|dematerialize|materialize|move|spawn|update)\s*=/u);
  assert.doesNotMatch(controlServer, /synex\.entities\.(?:spawn|delete|materialize|dematerialize|bucket\.move)/u);
  assert.ok(!descriptor.dependencies.required.some((entry) => entry.name === 'synex_control'));
  assert.ok(!descriptor.dependencies.optional.some((entry) => entry.name === 'synex_control'));
});

test('Entity search is authority-routed to the provider and remains exact and cursor bounded', async () => {
  const [protocol, provider, limits] = await Promise.all([
    source('resources/synex_control/server/request_protocol.lua'),
    source('resources/synex_entities/server/control_provider.lua'),
    source('resources/synex_control/shared/limits.lua'),
  ]);

  assert.match(protocol, /provider\s*=\s*request\.provider/u);
  assert.match(protocol, /query\s*=\s*validateQuery\(request\.query\)/u);
  assert.match(protocol, /mode ~= 'exact' and mode ~= 'prefix'/u);
  assert.match(provider, /query\.kind ~= 'entity'/u);
  assert.match(provider, /query\.mode ~= 'exact'/u);
  assert.match(provider, /not validId\(query\.value\)/u);
  assert.match(provider, /networkOwnerPolicy/u);
  assert.match(limits, /maximumCursorBytes\s*=\s*256/u);
  assert.match(limits, /maximumResponseBytes\s*=\s*32768/u);
});

test('Entity Control navigation is provider metadata-driven and restricted to safe render primitives', async () => {
  const [app, protocol, renderers] = await Promise.all([
    source('resources/synex_control/web/app.js'),
    source('resources/synex_control/web/core/protocol.js'),
    source('resources/synex_control/web/components/renderers.js'),
  ]);

  assert.match(app, /snapshot\.providers\.filter/u);
  assert.match(app, /provider\.views/u);
  assert.match(protocol, /normalizeProviders/u);
  for (const primitive of [
    'metrics', 'key-value', 'table', 'detail', 'timeline', 'graph', 'findings',
  ]) {
    assert.ok(protocol.includes(`'${primitive}'`), `${primitive} renderer must remain allowlisted`);
  }
  assert.match(renderers, /node\.textContent\s*=/u);
  assert.doesNotMatch(`${app}\n${renderers}`, /innerHTML|outerHTML|insertAdjacentHTML/u);
});

test('recovery inspector uses an entity identifier and exposes current circuit plus bounded history', async () => {
  const [supportSource, inspectSource, providerSource, descriptorSource] = await Promise.all([
    source('resources/synex_entities/server/control_provider_support.lua'),
    source('resources/synex_entities/server/control_provider_inspect.lua'),
    source('resources/synex_entities/server/control_provider.lua'),
    source('resources/synex_entities/synex.resource.json'),
  ]);
  const descriptorJson = JSON.parse(descriptorSource) as {
    controlProvider: { views: Array<{
      id: string;
      operation: string;
      presentation: string;
      description: string;
      input?: { fields: Array<{ key: string; label: string }> };
    }> };
  };
  const recoveryView = descriptorJson.controlProvider.views
    .find((view) => view.id === 'recovery');
  assert.equal(recoveryView?.presentation, 'detail');
  assert.equal(recoveryView?.input?.fields[0]?.key, 'id');
  assert.equal(recoveryView?.input?.fields[0]?.label, 'Entity ID');
  assert.match(recoveryView?.description ?? '', /entity recovery circuit/u);

  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      assert(load(${JSON.stringify(supportSource)},
        '@resources/synex_entities/server/control_provider_support.lua'))()
      assert(load(${JSON.stringify(inspectSource)},
        '@resources/synex_entities/server/control_provider_inspect.lua'))()
      assert(load(${JSON.stringify(providerSource)},
        '@resources/synex_entities/server/control_provider.lua'))()
      local descriptor
      local calls = 0
      local foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable == true }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        reportUnexpected = function() error('unexpected provider failure') end,
      }
      local provider = SynexEntityControlProvider.create({
        foundation = foundation,
        service = {
          inspectEntity = function(request)
            calls = calls + 1
            assert(request.entityId == 'entity_alpha_0001' and request.recoveryLimit == 3)
            return {
              persistence = {
                entityId = request.entityId, generation = 7,
                recoveryPolicy = 'automatic', status = 'failed',
                recovery = {
                  attempts = 3, circuit = 'open', failureCode = 'SPAWN_FAILED',
                  nextRetryAt = '2026-08-26T12:00:00.000000Z',
                  windowStartedAt = '2026-08-26T11:59:00.000000Z',
                },
              },
              recovery = {
                { recovery_id = 19, entity_id = request.entityId,
                  attempt_number = 3, outcome = 'failed',
                  failure_code = 'SPAWN_FAILED',
                  next_retry_at = '2026-08-26T12:00:00.000000Z',
                  occurred_at = '2026-08-26T11:59:30.000000Z' },
              },
            }
          end,
        },
        queryOperations = {}, authorityRepository = {}, database = {},
        state = { buckets = {} }, registry = { all = function() return {} end },
        config = {}, bucketPolicy = {}, spawnAdmission = {},
        coreRef = { value = { ownerEpoch = 4 } },
      })
      assert(provider.register({ ControlProviders = { register = function(value)
        descriptor = value
        return { namespace = value.namespace }
      end } }))
      local inspected = assert(descriptor.operations.inspect({
        view = 'recovery', id = 'entity_alpha_0001', limit = 3,
      }, { traceId = 'trace_entity_recovery_control_001' }))
      assert(calls == 1 and inspected.entity.entityId == 'entity_alpha_0001')
      assert(inspected.entity.generation == 7 and inspected.entity.recoveryPolicy == 'automatic')
      assert(inspected.attempts == 3 and inspected.circuit == 'OPEN')
      assert(inspected.lastFailure == 'SPAWN_FAILED')
      assert(inspected.nextRetry == '2026-08-26T12:00:00.000000Z')
      assert(#inspected.history.items == 1 and inspected.history.limit == 3)
      assert(inspected.history.items[1].entityId == 'entity_alpha_0001')
      assert(inspected.history.hasMore == false and inspected.history.truncated == false)

      local invalid, invalidError = descriptor.operations.inspect({
        view = 'recovery', id = 'entity_alpha_0001', cursor = 'ignored_cursor',
      }, { traceId = 'trace_entity_recovery_control_002' })
      assert(invalid == false and invalidError.code == 'VALIDATION_FAILED' and calls == 1)
      return inspected.circuit
    `);
    assert.equal(result, 'OPEN');
  } finally {
    engine.global.close();
  }
});
