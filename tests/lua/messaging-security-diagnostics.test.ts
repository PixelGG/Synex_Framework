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
  for (const module of ['foundation', 'registries', 'contracts', 'security', 'messaging']) {
    await load(engine, `core/synex_core/server/${module}.lua`);
  }
  return engine;
}

test('messaging records only safe contract and payload rejection metadata', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('messaging-security-diagnostics')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      assert(security.capabilities:registerManifest('synex_core', {
        capabilities = { request = {} },
        events = { publish = { 'synex.fixture.*' }, subscribe = {} },
        hooks = { run = { 'synex.fixture.*' }, register = {} }
      }))

      local rawFindings = {}
      local originalRecord = security.diagnostics.record
      security.diagnostics.record = function(self, finding)
        rawFindings[#rawFindings + 1] = foundation.copy(finding)
        return originalRecord(self, finding)
      end
      local dependencies = {
        provide = function() return true, nil end,
        removeProvider = function() return true, nil end,
        setProviderHealth = function() return true, nil end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = registries.players,
        lifecycle = { core = { isOperational = function() return true end } },
        dependencies = dependencies, protocol = SynexProtocol,
        config = { maximumPayloadBytes = 1024 }, coreResource = 'synex_core'
      })

      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.secure_diagnostics', version = '1.0.0',
        provider = 'synex_core', kind = 'rpc', stability = 'experimental',
        network = 'none', errors = {},
        input = {
          type = 'object', additionalProperties = false, required = { 'enabled' },
          properties = { enabled = { type = 'boolean' } }
        },
        output = {
          type = 'object', additionalProperties = false, required = { 'ok' },
          properties = { ok = { type = 'boolean' } }
        }
      }, function()
        return { ok = 'invalid-provider-value' }, nil
      end))

      local secret = 'github_pat_payload_secret_that_must_not_escape_1234567890'
      local invalidRequest, requestError = messaging.gateway:invoke(
        'synex_core', coreEpoch, 'synex.fixture.secure_diagnostics', '1.0.0',
        { enabled = secret }, {})
      assert(invalidRequest == nil and requestError.code == 'VALIDATION_FAILED')
      local invalidResponse, responseError = messaging.gateway:invoke(
        'synex_core', coreEpoch, 'synex.fixture.secure_diagnostics', '1.0.0',
        { enabled = true }, {})
      assert(invalidResponse == nil and responseError.code == 'INVALID_PROVIDER_RESPONSE')

      local eventPayload = { credential = secret }
      eventPayload.self = eventPayload
      local eventResult, eventError = messaging.events:publish(
        'synex_core', coreEpoch, 'synex.fixture.changed', eventPayload, {})
      assert(eventResult == nil and eventError.code == 'INVALID_EVENT')

      local hookPayload = { credential = secret }
      hookPayload.self = hookPayload
      local hookResult, hookError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.fixture.authorize', hookPayload, {})
      assert(hookResult == nil and hookError.code == 'INVALID_HOOK')

      assert(messaging.services:provide('synex_core', coreEpoch, {
        name = 'synex.fixture.diagnostics', version = '1.0.0',
        methods = {
          accept = function() return {} end,
          invalid = function()
            return setmetatable({ credential = secret }, { __index = function() end })
          end
        }
      }))
      local serviceRequest = { credential = secret }
      serviceRequest.self = serviceRequest
      local serviceValue, serviceError = messaging.services:call(
        'synex_core', coreEpoch, 'synex.fixture.diagnostics', '1.0.0',
        'accept', serviceRequest, {})
      assert(serviceValue == nil and serviceError.code == 'INVALID_ARGUMENT')
      local serviceResponse, serviceResponseError = messaging.services:call(
        'synex_core', coreEpoch, 'synex.fixture.diagnostics', '1.0.0',
        'invalid', {}, {})
      assert(serviceResponse == nil and serviceResponseError.code == 'SERVICE_FAILED')

      assert(#rawFindings == 6)
      local allowed = {
        category = true, severity = true, code = true, resource = true,
        scope = true, operation = true, summary = true
      }
      local observed = {}
      for _, finding in ipairs(rawFindings) do
        for key, value in pairs(finding) do
          assert(allowed[key], 'diagnostic forwarded an unexpected field: ' .. tostring(key))
          if type(value) == 'string' then
            assert(not value:find(secret, 1, true), 'diagnostic leaked request or response data')
          end
        end
        assert(finding.severity == 'WARNING')
        assert(finding.payload == nil and finding.request == nil and finding.response == nil)
        assert(finding.traceId == nil and finding.requestId == nil and finding.session == nil)
        assert(finding.source == nil and finding.details == nil and finding.identifier == nil)
        observed[finding.category .. ':' .. finding.code] = true
      end
      assert(observed['contract_validation:VALIDATION_FAILED'])
      assert(observed['contract_validation:INVALID_PROVIDER_RESPONSE'])
      assert(observed['payload_validation:INVALID_EVENT'])
      assert(observed['payload_validation:INVALID_HOOK'])
      assert(observed['payload_validation:INVALID_ARGUMENT'])
      assert(observed['payload_validation:INVALID_SERVICE_PROVIDER_RESPONSE'])

      local page = assert(security.diagnostics:page({ limit = 50 }))
      assert(#page.items == 6 and page.retained == 6)
      return table.concat({ requestError.code, responseError.code,
        eventError.code, hookError.code, serviceError.code, #page.items }, ':')
    `);

    assert.equal(
      result,
      'VALIDATION_FAILED:INVALID_PROVIDER_RESPONSE:INVALID_EVENT:INVALID_HOOK:INVALID_ARGUMENT:6',
    );
  } finally {
    engine.global.close();
  }
});

test('messaging validation results survive missing or failing diagnostics', async () => {
  const engine = await createEngine();
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
      foundation.configureIds('messaging-diagnostics-failure-isolation')
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      local recorded = {}
      security.diagnostics.record = function(_, finding)
        recorded[#recorded + 1] = foundation.copy(finding)
        return true, nil
      end
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation,
        contracts = { registry = { resolve = function()
          error('payload validation must precede contract resolution')
        end } },
        security = security, owners = {},
        players = { getBySource = function(playerSource)
          return { id = 'session-diagnostics-safe', source = playerSource,
            sourceGeneration = 7, userId = 'user-diagnostics-safe',
            characterId = 'character-diagnostics-safe' }
        end }, lifecycle = {},
        protocol = SynexProtocol,
        config = { burst = 10, rate = 10, maximumPayloadBytes = 1024 },
        coreResource = 'synex_core'
      })
      messaging.network:bind()
      source = 17
      local function submit(requestId)
        local payload = { credential = 'must-not-be-recorded' }
        payload.self = payload
        handlers[SynexProtocol.events.request]({
          wire = 1, requestId = requestId, procedure = 'synex.fixture.call',
          version = '1.0.0', payload = payload
        })
        return responses[#responses]
      end

      local first = submit('request-diagnostics-first')
      assert(first.error.code == 'INVALID_PAYLOAD' and #recorded == 1)
      assert(recorded[1].category == 'payload_validation')
      assert(recorded[1].scope == 'synex.fixture.call')
      assert(recorded[1].operation == 'rpc.ingress.validate')
      assert(recorded[1].resource == nil and recorded[1].traceId == nil
        and recorded[1].requestId == nil)
      assert(recorded[1].sessionId == 'session-diagnostics-safe')
      assert(recorded[1].source == 17 and recorded[1].sourceGeneration == 7)
      assert(recorded[1].userId == 'user-diagnostics-safe')
      assert(recorded[1].characterId == 'character-diagnostics-safe')

      security.diagnostics.record = function()
        error('diagnostics sink failure must stay isolated')
      end
      local second = submit('request-diagnostics-second')
      assert(second.error.code == 'INVALID_PAYLOAD' and #responses == 2)

      security.diagnostics = nil
      local third = submit('request-diagnostics-third')
      assert(third.error.code == 'INVALID_PAYLOAD' and #responses == 3)
      return table.concat({ first.error.code, second.error.code,
        third.error.code, #responses }, ':')
    `);

    assert.equal(result, 'INVALID_PAYLOAD:INVALID_PAYLOAD:INVALID_PAYLOAD:3');
  } finally {
    engine.global.close();
  }
});
