import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) await load(engine, `core/synex_core/server/${module}.lua`);
  return engine;
}

test('network deadlines are finite bounded integers', async () => {
  const engine = await createEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local function envelope(deadline)
        return {
          wire = 1, requestId = 'request-deadline', procedure = 'synex.fixture.call',
          version = '1.0.0', payload = {}, deadlineMs = deadline
        }
      end
      for _, deadline in ipairs({ 49, 15001, 50.5, math.huge, -math.huge }) do
        local accepted, failure = security.validateNetworkEnvelope(envelope(deadline))
        assert(accepted == nil and failure.code == 'INVALID_DEADLINE')
      end
      local nan = 0 / 0
      local acceptedNan, nanFailure = security.validateNetworkEnvelope(envelope(nan))
      assert(acceptedNan == nil and nanFailure.code == 'INVALID_DEADLINE')
      assert(security.validateNetworkEnvelope(envelope(50)))
      assert(security.validateNetworkEnvelope(envelope(15000)))
      assert(security.validateNetworkEnvelope(envelope(1000), 1000))
      local configuredValue, configuredFailure = security.validateNetworkEnvelope(
        envelope(15000), 1000)
      assert(configuredValue == nil and configuredFailure.code == 'INVALID_DEADLINE')
      return nanFailure.code
    `);
    assert.equal(result, 'INVALID_DEADLINE');
  } finally {
    engine.global.close();
  }
});

test('network ingress rejects cyclic, deep, and non-plain payloads before JSON encoding', async () => {
  const engine = await createEngine(['foundation', 'security', 'messaging']);
  try {
    const result = await engine.doString(`
      local now, handlers, responses = 1000, {}, {}
      local forbiddenPayloads, encodedForbidden = {}, false
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if forbiddenPayloads[value] then encodedForbidden = true end
          return '{}'
        end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response) responses[#responses + 1] = response end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('network-payload-walk')
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation,
        contracts = { registry = { resolve = function()
          error('payload validation must precede contract resolution')
        end } },
        security = security, owners = {},
        players = { getBySource = function() return nil end }, lifecycle = {},
        protocol = SynexProtocol,
        config = { burst = 20, rate = 20, timeoutMs = 500, maximumTimeoutMs = 1000 },
        coreResource = 'synex_core'
      })
      messaging.network:bind()
      source = 42
      local function submit(id, payload)
        forbiddenPayloads[payload] = true
        handlers[SynexProtocol.events.request]({
          wire = 1, requestId = id, procedure = 'synex.fixture.call',
          version = '1.0.0', payload = payload
        })
        assert(responses[#responses].error.code == 'INVALID_PAYLOAD')
      end
      local cyclic = {}
      cyclic.self = cyclic
      submit('request-cyclic', cyclic)
      local deep, cursor = {}, nil
      cursor = deep
      for _ = 1, 13 do cursor.next = {}; cursor = cursor.next end
      submit('request-too-deep', deep)
      local metatablePayload = setmetatable({}, { __index = function() error('must not run') end })
      submit('request-metatable', metatablePayload)
      local tooMany = {}
      for index = 1, 513 do tooMany['key_' .. index] = index end
      submit('request-too-many', tooMany)
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-forged-deadline', procedure = 'synex.fixture.call',
        version = '1.0.0', payload = {}, deadlineMs = 15000
      })
      assert(responses[#responses].error.code == 'INVALID_DEADLINE')
      assert(not encodedForbidden and #responses == 5)
      return #responses
    `);
    assert.equal(result, 5);
  } finally {
    engine.global.close();
  }
});

test('provider errors are copied, closed, declared, and always release RPC ingress state', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local now, handlers, responses = 1000, {}, {}
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response) responses[#responses + 1] = response end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('provider-error-boundary')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners
      })
      for _, target in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
      }) do assert(lifecycle.core:transition(target, 'fixture')) end
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local session = {
        id = 'session-provider-errors', userId = 'user-provider-errors',
        source = 42, sourceGeneration = 1, state = 'ACTIVE'
      }
      local players = {
        getBySource = function() return session end,
        isCurrent = function(_, sessionId, playerSource, generation)
          return sessionId == session.id and playerSource == 42
            and generation == session.sourceGeneration
        end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = players, lifecycle = lifecycle,
        dependencies = lifecycle.dependencies, protocol = SynexProtocol,
        config = { burst = 24, rate = 24 }, coreResource = 'synex_core'
      })
      local input = { type = 'object', additionalProperties = false, properties = {} }
      local output = { type = 'object', additionalProperties = false, properties = {} }
      local returnedError = foundation.error('DECLARED_FAILURE', 'A declared failure.', {
        retryable = true, details = { reason = 'bounded' }
      })
      local handlersByName = {
        declared = function() return nil, returnedError end,
        undeclared = function()
          return nil, foundation.error('UNDECLARED_FAILURE', 'Must not escape.')
        end,
        readonly = function()
          return nil, foundation.readonly(foundation.error('DECLARED_FAILURE', 'Readonly.'))
        end,
        unknown = function()
          return nil, { code = 'DECLARED_FAILURE', message = 'Unknown.', retryable = false, extra = true }
        end,
        raised = function() error('provider-private-stack') end
      }
      for name, handler in pairs(handlersByName) do
        assert(messaging.gateway:register('synex_core', coreEpoch, {
          name = 'synex.fixture.' .. name, version = '1.0.0', provider = 'synex_core',
          kind = 'rpc', stability = 'experimental', errors = {'DECLARED_FAILURE'},
          network = 'client-to-server', sessionStates = {'ACTIVE'},
          input = input, output = output
        }, handler))
      end
      messaging.network:bind()
      source = 42
      local function invoke(name)
        handlers[SynexProtocol.events.request]({
          wire = 1, requestId = 'request-' .. name,
          procedure = 'synex.fixture.' .. name, version = '1.0.0', payload = {}
        })
        local snapshot = messaging.network:snapshot()
        assert(snapshot.activeInbound == 0 and snapshot.activeSources == 0)
        return responses[#responses]
      end
      local declared = invoke('declared')
      assert(declared.error.code == 'DECLARED_FAILURE'
        and declared.error.retryable == true and returnedError.traceId == nil)
      for _, name in ipairs({'undeclared', 'readonly', 'unknown', 'raised'}) do
        local response = invoke(name)
        assert(response.error.code == 'INTERNAL_ERROR')
      end
      assert(#responses == 5)
      return table.concat({ declared.error.code, responses[2].error.code,
        messaging.network:snapshot().activeInbound }, ':')
    `);
    assert.equal(result, 'DECLARED_FAILURE:INTERNAL_ERROR:0');
  } finally {
    engine.global.close();
  }
});

test('stale RPC providers cannot poison the canonical contract registry', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local staleEpoch = owners:activate('synex_fixture')
      local cleanup = owners:purge('synex_fixture', staleEpoch, 'fixture restart')
      assert(#cleanup.errors == 0)
      local currentEpoch = owners:activate('synex_fixture')
      assert(currentEpoch ~= staleEpoch)
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = registries.players,
        lifecycle = {}, dependencies = {}, protocol = SynexProtocol,
        config = {}, coreResource = 'synex_core'
      })
      local definition = {
        name = 'synex.fixture.poison', version = '1.0.0', provider = 'synex_fixture',
        kind = 'rpc', stability = 'experimental', network = 'none', errors = {},
        input = { type = 'object', additionalProperties = false, properties = {} },
        output = { type = 'object', additionalProperties = false, properties = {} }
      }
      local token, staleError = messaging.gateway:register(
        'synex_fixture', staleEpoch, definition, function() return {} end)
      assert(token == nil and staleError.code == 'STALE_RESOURCE')
      local unresolved, resolveError = contracts.registry:resolve(
        'synex.fixture.poison', '1.0.0')
      assert(unresolved == nil and resolveError.code == 'CONTRACT_NOT_FOUND')
      assert(messaging.gateway:register(
        'synex_fixture', currentEpoch, definition, function() return {} end))
      assert(contracts.registry:resolve('synex.fixture.poison', '1.0.0'))
      return staleError.code .. ':' .. resolveError.code
    `);
    assert.equal(result, 'STALE_RESOURCE:CONTRACT_NOT_FOUND');
  } finally {
    engine.global.close();
  }
});

test('service boundaries preflight requests and normalize provider failures without leaking raw errors', async () => {
  const engine = await createEngine(['foundation', 'registries', 'messaging']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local encodedForbidden, leakedPrivateText = false, false
      local forbiddenRequest = nil
      local function contains(value, needle, seen)
        if type(value) == 'string' then return value:find(needle, 1, true) ~= nil end
        if type(value) ~= 'table' then return false end
        seen = seen or {}
        if seen[value] then return false end
        seen[value] = true
        for key, child in pairs(value) do
          if contains(key, needle, seen) or contains(child, needle, seen) then return true end
        end
        return false
      end
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if value == forbiddenRequest then encodedForbidden = true end
          if type(value) == 'table' and rawget(value, 'level') ~= nil
            and contains(value, 'provider-private-secret') then leakedPrivateText = true end
          if contains(value, 'force-oversized') then return string.rep('x', 1025) end
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('service-boundary-hardening')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local epoch = owners:activate('synex_service')
      local dependencies = {
        provide = function() return true, nil end,
        removeProvider = function() return true, nil end,
        setProviderHealth = function() return true, nil end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = {},
        security = { capabilities = { check = function() return true, nil end } },
        owners = owners, lifecycle = {}, players = registries.players,
        dependencies = dependencies, protocol = SynexProtocol,
        config = { maximumPayloadBytes = 1024, timeoutMs = 5000, maximumTimeoutMs = 15000 },
        coreResource = 'synex_core'
      })
      local returnedError = foundation.error('SERVICE_DOMAIN_FAILURE', 'Expected failure.', {
        retryable = true, details = { reason = 'bounded' }
      })
      assert(messaging.services:provide('synex_service', epoch, {
        name = 'synex.fixture.service', version = '1.0.0',
        methods = {
          declared = function() return nil, returnedError end,
          hostile = function()
            return nil, setmetatable({
              code = 'HOSTILE', message = 'provider-private-secret'
            }, { __index = function() error('must not run') end })
          end,
          hostile_result = function()
            return setmetatable({ value = 'provider-private-secret' }, {
              __index = function() error('must not run') end
            })
          end,
          oversized_result = function() return { marker = 'force-oversized' } end,
          slow = function() now = now + 101 return {} end,
          raised = function() error('provider-private-secret') end
        }
      }))
      local cyclic = {}
      cyclic.self = cyclic
      forbiddenRequest = cyclic
      local invalid, invalidError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'declared', cyclic, {})
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT' and not encodedForbidden)
      local cyclicMetadata = {}
      cyclicMetadata.self = cyclicMetadata
      local _, metadataError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'declared', {}, {
          metadata = cyclicMetadata
        })
      assert(metadataError.code == 'INVALID_SERVICE_CONTEXT')
      local _, traceError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'declared', {}, {
          traceId = string.rep('t', 100000)
        })
      assert(traceError.code == 'INVALID_SERVICE_CONTEXT')
      local _, contextSizeError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'declared', {}, {
          metadata = { marker = 'force-oversized' }
        })
      assert(contextSizeError.code == 'PAYLOAD_TOO_LARGE')

      local _, declaredError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'declared', {}, {
          traceId = 'trace-service-boundary'
        })
      assert(declaredError ~= returnedError and declaredError.code == 'SERVICE_DOMAIN_FAILURE'
        and declaredError.traceId == 'trace-service-boundary' and returnedError.traceId == nil)
      declaredError.details.reason = 'consumer mutation'
      assert(returnedError.details.reason == 'bounded')
      local _, deadlineError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'slow', {}, {
          timeoutMs = 100
        })
      assert(deadlineError.code == 'DEADLINE_EXCEEDED')
      for _, method in ipairs({'hostile', 'hostile_result', 'raised'}) do
        local _, failure = messaging.services:call(
          'synex_service', epoch, 'synex.fixture.service', '1.0.0', method, {}, {})
        assert(failure.code == 'SERVICE_FAILED')
      end
      local _, oversizedError = messaging.services:call(
        'synex_service', epoch, 'synex.fixture.service', '1.0.0', 'oversized_result', {}, {})
      assert(oversizedError.code == 'SERVICE_FAILED')
      assert(not leakedPrivateText)
      return table.concat({invalidError.code, declaredError.code, tostring(leakedPrivateText)}, ':')
    `);
    assert.equal(result, 'INVALID_ARGUMENT:SERVICE_DOMAIN_FAILURE:false');
  } finally {
    engine.global.close();
  }
});

test('service dependency health and cleanup are isolated by provider major', async () => {
  const engine = await createEngine(['foundation', 'registries', 'lifecycle', 'messaging']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('service-major-isolation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local providerEpoch = owners:activate('synex_provider')
      owners:activate('synex_consumer_v1')
      owners:activate('synex_consumer_v2')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners
      })
      lifecycle.dependencies:require('synex_consumer_v1', 'synex.fixture.multi', '^1.0.0', false, true)
      lifecycle.dependencies:require('synex_consumer_v2', 'synex.fixture.multi', '^2.0.0', false, true)
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = {},
        security = { capabilities = { check = function() return true, nil end } },
        owners = owners, lifecycle = lifecycle, players = registries.players,
        dependencies = lifecycle.dependencies, protocol = SynexProtocol,
        config = {}, coreResource = 'synex_core'
      })
      for _, version in ipairs({'1.0.0', '2.0.0'}) do
        assert(messaging.services:provide('synex_provider', providerEpoch, {
          name = 'synex.fixture.multi', version = version,
          methods = { read = function() return { version = version } end }
        }))
      end
      assert(#lifecycle.dependencies:validate() == 0)
      assert(messaging.services:setHealth(
        'synex_provider', providerEpoch, 'synex.fixture.multi', '1.0.0', 'UNHEALTHY'))
      local unhealthy = lifecycle.dependencies:validate()
      assert(#unhealthy == 1 and unhealthy[1].consumer == 'synex_consumer_v1')
      local graph = lifecycle.dependencies:snapshot()
      assert(graph.providers['synex.fixture.multi'].synex_provider['1'] == '1.0.0')
      assert(graph.providers['synex.fixture.multi'].synex_provider['2'] == '2.0.0')
      assert(graph.providerHealth['synex.fixture.multi'].synex_provider['1'].health == 'UNHEALTHY')
      assert(graph.providerHealth['synex.fixture.multi'].synex_provider['2'].health == 'HEALTHY')

      assert(lifecycle.dependencies:removeProvider(
        'synex_provider', 'synex.fixture.multi', '1.0.0'))
      graph = lifecycle.dependencies:snapshot()
      assert(graph.providers['synex.fixture.multi'].synex_provider['1'] == nil)
      assert(graph.providers['synex.fixture.multi'].synex_provider['2'] == '2.0.0')
      local afterCleanup = lifecycle.dependencies:validate()
      assert(#afterCleanup == 1 and afterCleanup[1].consumer == 'synex_consumer_v1')

      local staleEpoch = owners:activate('synex_stale_provider')
      assert(#owners:purge('synex_stale_provider', staleEpoch, 'fixture restart').errors == 0)
      owners:activate('synex_stale_provider')
      local staleToken, staleError = messaging.services:provide('synex_stale_provider', staleEpoch, {
        name = 'synex.fixture.stale', version = '1.0.0',
        methods = { read = function() return {} end }
      })
      assert(staleToken == nil and staleError.code == 'STALE_RESOURCE')
      assert(lifecycle.dependencies:snapshot().providers['synex.fixture.stale'] == nil)

      local oversizedMethods = {}
      for index = 1, 65 do oversizedMethods['method_' .. index] = function() return {} end end
      local oversizedToken, oversizedError = messaging.services:provide('synex_provider', providerEpoch, {
        name = 'synex.fixture.oversized', version = '1.0.0', methods = oversizedMethods
      })
      assert(oversizedToken == nil and oversizedError.code == 'INVALID_SERVICE')
      local unknownToken, unknownError = messaging.services:provide('synex_provider', providerEpoch, {
        name = 'synex.fixture.unknown', version = '1.0.0',
        methods = { read = function() return {} end }, unknown = true
      })
      assert(unknownToken == nil and unknownError.code == 'INVALID_SERVICE')
      for index = 1, 126 do
        assert(messaging.services:provide('synex_provider', providerEpoch, {
          name = ('synex.fixture.capacity_%d'):format(index), version = '1.0.0',
          methods = { read = function() return {} end }
        }))
      end
      local limitToken, limitError = messaging.services:provide('synex_provider', providerEpoch, {
        name = 'synex.fixture.capacity_overflow', version = '1.0.0',
        methods = { read = function() return {} end }
      })
      assert(limitToken == nil and limitError.code == 'SERVICE_REGISTRATION_LIMIT')
      return table.concat({unhealthy[1].consumer, afterCleanup[1].consumer,
        staleError.code, limitError.code}, ':')
    `);
    assert.equal(
      result,
      'synex_consumer_v1:synex_consumer_v1:STALE_RESOURCE:SERVICE_REGISTRATION_LIMIT',
    );
  } finally {
    engine.global.close();
  }
});

test('network RPC enforces each resolved contract rate limit after the aggregate ingress gate', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local handlers, responses = {}, {}
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response) responses[#responses + 1] = response end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('contract-rate-limits')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners
      })
      for _, target in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
      }) do assert(lifecycle.core:transition(target, 'fixture')) end
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local session = {
        id = 'session-rate-limit', userId = 'user-rate-limit',
        source = 42, sourceGeneration = 1, state = 'ACTIVE'
      }
      local players = {
        getBySource = function() return session end,
        isCurrent = function(_, sessionId, playerSource, generation)
          return sessionId == session.id and playerSource == 42
            and generation == session.sourceGeneration
        end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = players, lifecycle = lifecycle,
        dependencies = lifecycle.dependencies, protocol = SynexProtocol,
        config = { burst = 20, rate = 20 }, coreResource = 'synex_core'
      })
      local schema = { type = 'object', additionalProperties = false, properties = {} }
      local function register(name, capacity)
        assert(messaging.gateway:register('synex_core', coreEpoch, {
          name = 'synex.fixture.' .. name, version = '1.0.0', provider = 'synex_core',
          kind = 'rpc', stability = 'experimental', errors = {},
          network = 'client-to-server', sessionStates = {'ACTIVE'},
          rateLimit = { capacity = capacity, refillPerSecond = 0.001 },
          input = schema, output = schema
        }, function() return {} end))
      end
      register('slow', 1)
      register('fast', 2)
      local invalidToken, invalidRateError = messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.invalid_rate', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', stability = 'experimental', errors = {},
        network = 'client-to-server', sessionStates = {'ACTIVE'},
        rateLimit = { capacity = 1, refillPerSecond = 0 / 0 },
        input = schema, output = schema
      }, function() return {} end)
      assert(invalidToken == nil and invalidRateError.code == 'INVALID_CONTRACT')
      messaging.network:bind()
      source = 42
      local sequence = 0
      local function invoke(name)
        sequence = sequence + 1
        handlers[SynexProtocol.events.request]({
          wire = 1, requestId = 'request-rate-' .. sequence,
          procedure = 'synex.fixture.' .. name, version = '1.0.0', payload = {}
        })
        return responses[#responses]
      end
      assert(invoke('slow').ok == true)
      assert(invoke('slow').error.code == 'RATE_LIMITED')
      assert(invoke('fast').ok == true)
      assert(invoke('fast').ok == true)
      assert(invoke('fast').error.code == 'RATE_LIMITED')
      assert(#responses == 5)
      return table.concat({responses[2].error.code, responses[5].error.code, #responses}, ':')
    `);
    assert.equal(result, 'RATE_LIMITED:RATE_LIMITED:5');
  } finally {
    engine.global.close();
  }
});
