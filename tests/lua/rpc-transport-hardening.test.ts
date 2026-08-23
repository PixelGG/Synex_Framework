import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) await load(engine, `core/synex_core/server/${module}.lua`);
  return engine;
}

test('rate limiter enforces a hard bucket bound and expires inactive buckets', async () => {
  const engine = await coreEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        rateLimiterMaximum = 64, rateLimiterTtlMs = 1000
      })
      for index = 1, 64 do
        assert(security.rateLimiter:consume('fixture:' .. index, 1, 1, 1))
      end
      local rejected, rejectionError = security.rateLimiter:consume('fixture:overflow', 1, 1, 1)
      assert(rejected == nil and rejectionError.code == 'RATE_LIMITED')
      local invalid, invalidError = security.rateLimiter:consume('fixture:invalid', 1, 0 / 0, 1)
      assert(invalid == nil and invalidError.code == 'INVALID_RATE_LIMIT')
      local saturated = security.rateLimiter:snapshot()
      assert(saturated.buckets == 64 and saturated.maximum == 64 and saturated.ttlMs == 1000)
      now = 2501
      assert(security.rateLimiter:consume('fixture:after-expiry', 1, 1, 1))
      local expired = security.rateLimiter:snapshot()
      assert(expired.buckets == 1)
      return table.concat({saturated.buckets, rejectionError.code, expired.buckets}, ':')
    `);
    assert.equal(result, '64:RATE_LIMITED:1');
  } finally {
    engine.global.close();
  }
});

test('RPC ingress bounds malformed and unknown-procedure floods across source reuse', async () => {
  const engine = await coreEngine(['foundation', 'security', 'messaging']);
  try {
    const result = await engine.doString(`
      local now, handlers, responses, resolutions = 1000, {}, {}, 0
      local activeSession = nil
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response) responses[#responses + 1] = response end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rpc-ingress-hardening')
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        rateLimiterMaximum = 64, rateLimiterTtlMs = 60000
      })
      local contracts = { registry = {} }
      function contracts.registry:resolve(name)
        resolutions = resolutions + 1
        if name == 'synex.fixture.server_only' then
          return {
            name = name, version = '1.0.0', network = 'none',
            sessionStates = {'ACTIVE'}
          }, nil
        end
        return nil, foundation.error('CONTRACT_NOT_FOUND', 'fixture contract missing')
      end
      local players = {
        getBySource = function() return activeSession end,
        isCurrent = function() return true end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = {}, players = players, lifecycle = {},
        protocol = SynexProtocol, config = { burst = 4, rate = 0.01 },
        coreResource = 'synex_core'
      })
      messaging.network:bind()
      source = 42

      for _ = 1, 100 do handlers[SynexProtocol.events.request]('malformed') end
      assert(#responses == 4 and resolutions == 0)
      assert(security.rateLimiter:snapshot().buckets == 1)
      messaging.network:purgeSource(42, nil)
      assert(security.rateLimiter:snapshot().buckets == 0)

      activeSession = {
        id = 'session-old', userId = 'user-old', sourceGeneration = 1, state = 'ACTIVE'
      }
      for index = 1, 2000 do
        handlers[SynexProtocol.events.request]({
          wire = 1, requestId = ('request-old-%d'):format(index),
          procedure = ('synex.unknown_%d'):format(index), version = '1.0.0', payload = {}
        })
      end
      assert(#responses == 8 and resolutions == 4)
      assert(security.rateLimiter:snapshot().buckets == 1)

      activeSession = {
        id = 'session-new', userId = 'user-new', sourceGeneration = 3, state = 'ACTIVE'
      }
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-new-1',
        procedure = 'synex.unknown_new', version = '1.0.0', payload = {}
      })
      assert(security.rateLimiter:snapshot().buckets == 2)
      messaging.network:purgeSource(42, 1)
      assert(security.rateLimiter:snapshot().buckets == 1)

      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-new-2',
        procedure = 'synex.fixture.server_only', version = '1.0.0', payload = {}
      })
      assert(responses[#responses].error.code == 'NETWORK_ACCESS_DENIED')
      assert(security.rateLimiter:snapshot().buckets == 1)
      return table.concat({#responses, resolutions, security.rateLimiter:snapshot().buckets}, ':')
    `);
    assert.equal(result, '10:6:1');
  } finally {
    engine.global.close();
  }
});

test('RPC ingress rejects aggregate payload bytes before JSON encoding', async () => {
  const engine = await coreEngine(['foundation', 'security', 'messaging']);
  try {
    const result = await engine.doString(`
      local handlers, responses, resolutions, payloadEncodes = {}, {}, 0, 0
      local oversized = {}
      for index = 1, 64 do oversized['field' .. index] = string.rep('x', 32) end
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if value == oversized then payloadEncodes = payloadEncodes + 1 end
          return '{}'
        end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response) responses[#responses + 1] = response end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rpc-pre-encode-byte-budget')
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local contracts = { registry = {
        resolve = function()
          resolutions = resolutions + 1
          return nil, foundation.error('CONTRACT_NOT_FOUND', 'fixture contract missing')
        end
      } }
      local session = {
        id = 'session-active', userId = 'user-active', sourceGeneration = 1, state = 'ACTIVE'
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = {}, lifecycle = {},
        players = {
          getBySource = function() return session end,
          isCurrent = function() return true end
        },
        protocol = SynexProtocol,
        config = { maximumPayloadBytes = 1024, burst = 24, rate = 12 },
        coreResource = 'synex_core'
      })
      messaging.network:bind()
      source = 42
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-aggregate-large',
        procedure = 'synex.fixture.unknown', version = '1.0.0', payload = oversized
      })
      assert(#responses == 1 and responses[1].error.code == 'PAYLOAD_TOO_LARGE')
      assert(payloadEncodes == 0 and resolutions == 0,
        'aggregate byte rejection must happen before encoding and contract resolution')
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-aggregate-small',
        procedure = 'synex.fixture.unknown', version = '1.0.0', payload = { value = 'ok' }
      })
      assert(#responses == 2 and responses[2].error.code == 'CONTRACT_NOT_FOUND'
        and resolutions == 1)
      return table.concat({responses[1].error.code, payloadEncodes, resolutions}, ':')
    `);
    assert.equal(result, 'PAYLOAD_TOO_LARGE:0:1');
  } finally {
    engine.global.close();
  }
});

test('RPC responses enforce the encoded byte cap and keep error fallbacks bounded', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'contracts', 'security', 'messaging']);
  try {
    const result = await engine.doString(`
      local now, handlers, responses, responseBytes = 1000, {}, {}, {}
      local smallTrace = nil
      local function jsonEncode(value)
        if type(value) ~= 'table' or value.wire == nil then return '{}' end
        local size = 128
        if value.ok == true and type(value.value) == 'table' then
          size = size + #(value.value.blob or '')
        elseif type(value.error) == 'table' then
          size = size + #(value.error.code or '') + #(value.error.message or '')
            + #(value.error.traceId or '')
        end
        return string.rep('x', size)
      end
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = jsonEncode,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response)
          responses[#responses + 1] = response
          responseBytes[#responseBytes + 1] = #jsonEncode(response)
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rpc-response-hardening')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local session = {
        id = 'session-active', userId = 'user-active', source = 42,
        sourceGeneration = 1, state = 'ACTIVE'
      }
      local players = {
        getBySource = function() return session end,
        isCurrent = function(_, sessionId, playerSource, generation)
          return sessionId == session.id and playerSource == 42
            and generation == session.sourceGeneration
        end
      }
      local lifecycle = { core = { isOperational = function() return true end } }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = players, lifecycle = lifecycle,
        dependencies = {}, protocol = SynexProtocol,
        config = { maximumPayloadBytes = 1024, burst = 24, rate = 12 },
        coreResource = 'synex_core'
      })
      local input = { type = 'object', additionalProperties = false, properties = {} }
      local output = {
        type = 'object', required = {'blob'}, additionalProperties = false,
        properties = { blob = { type = 'string', maxLength = 4096 } }
      }
      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.small', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', stability = 'experimental', errors = {},
        network = 'client-to-server', sessionStates = {'ACTIVE'},
        input = input, output = output
      }, function(_, context)
        smallTrace = context.traceId
        return { blob = string.rep('s', 128) }, nil
      end))
      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.boundary', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', stability = 'experimental', errors = {},
        network = 'client-to-server', sessionStates = {'ACTIVE'},
        input = input, output = output
      }, function()
        return { blob = string.rep('b', 896) }, nil
      end))
      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.large', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', stability = 'experimental', errors = {},
        network = 'client-to-server', sessionStates = {'ACTIVE'},
        input = input, output = output
      }, function()
        return { blob = string.rep('l', 2048) }, nil
      end))
      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.failure', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', stability = 'experimental', errors = {'FIXTURE_FAILURE'},
        network = 'client-to-server', sessionStates = {'ACTIVE'},
        input = input, output = output
      }, function()
        return nil, foundation.error('FIXTURE_FAILURE', string.rep('e', 512))
      end))
      messaging.network:bind()
      source = 42
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-small',
        procedure = 'synex.fixture.small', version = '1.0.0', payload = {}
      })
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-boundary',
        procedure = 'synex.fixture.boundary', version = '1.0.0', payload = {}
      })
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-large',
        procedure = 'synex.fixture.large', version = '1.0.0', payload = {}
      })
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-error',
        procedure = 'synex.fixture.failure', version = '1.0.0', payload = {}
      })
      assert(#responses == 4, ('expected 4 responses, got %d'):format(#responses))
      assert(responses[1].ok == true and responseBytes[1] < 1024)
      assert(type(smallTrace) == 'string' and smallTrace == responses[1].traceId)
      assert(responses[2].ok == true and responseBytes[2] == 1024)
      assert(responses[3].ok == false and responses[3].error.code == 'RESPONSE_TOO_LARGE')
      assert(responses[3].value == nil and responseBytes[3] <= 1024)
      assert(responses[4].ok == false and responses[4].error.code == 'FIXTURE_FAILURE')
      assert(#responses[4].error.message == 512 and responseBytes[4] <= 1024)
      assert(security.rateLimiter:snapshot().buckets == 5)
      return table.concat({responses[3].error.code, responses[4].error.code,
        #responses[4].error.message, security.rateLimiter:snapshot().buckets}, ':')
    `);
    assert.equal(result, 'RESPONSE_TOO_LARGE:FIXTURE_FAILURE:512:5');
  } finally {
    engine.global.close();
  }
});

test('public RPC options enforce the documented timeout without accepting forged session context', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'bootstrap_api']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rpc-public-options')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local captured = nil
      local messaging = {
        gateway = {
          invoke = function(_, caller, callerEpoch, name, version, request, options)
            captured = foundation.copy(options)
            return { caller = caller, epoch = callerEpoch, name = name, version = version }, nil
          end
        },
        events = {}, hooks = {}, services = {}
      }
      local runtimeGate = { requireAvailable = function() return true, nil end }
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform,
        foundation = foundation,
        registries = registries,
        security = { capabilities = {} },
        identity = { characters = {} },
        contractSystem = {},
        messaging = messaging,
        coreResource = 'synex_core',
        runtime = {},
        stateService = {},
        lifecycle = {},
        reliability = {},
        sagaRuntime = {},
        facadeCache = {},
        runtimeGate = runtimeGate,
        ensureOwner = function(caller)
          assert(caller == 'synex_fixture')
          return epoch, nil
        end,
        defaultConfig = { rpc = { timeoutMs = 5000, maximumTimeoutMs = 15000 } }
      })
      local facade = assert(api.getAPIForCaller('synex_fixture', '^1.0.0'))
      local value = assert(facade.RPC.call('synex.fixture.echo', '1.0.0', {}, {
        timeoutMs = 3000,
        traceId = 'trace_fixture',
        idempotencyKey = 'idem_fixture'
      }))
      assert(value.caller == 'synex_fixture' and value.epoch == epoch)
      assert(captured.deadlineAt == 4000 and captured.traceId == 'trace_fixture'
        and captured.idempotencyKey == 'idem_fixture')
      assert(captured.timeoutMs == nil and captured.session == nil and captured.source == nil
        and captured.sourceGeneration == nil)

      local forged, forgedError = facade.RPC.call('synex.fixture.echo', '1.0.0', {}, {
        session = { id = 'forged' }, source = 77
      })
      assert(forged == nil and forgedError.code == 'INVALID_RPC_OPTIONS')
      local invalid, invalidError = facade.RPC.call('synex.fixture.echo', '1.0.0', {}, {
        timeoutMs = 15000.5
      })
      assert(invalid == nil and invalidError.code == 'INVALID_RPC_OPTIONS')
      local invoked = assert(api.invokeForCaller('synex_fixture', 'synex.fixture.echo', '1.0.0', {}, nil))
      assert(invoked.caller == 'synex_fixture' and captured.deadlineAt == 6000)
      return table.concat({ value.name, forgedError.code, invalidError.code, captured.deadlineAt }, ':')
    `);
    assert.equal(result, 'synex.fixture.echo:INVALID_RPC_OPTIONS:INVALID_RPC_OPTIONS:6000');
  } finally {
    engine.global.close();
  }
});
