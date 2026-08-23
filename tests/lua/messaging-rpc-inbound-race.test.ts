import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

test('RPC ingress reserves request identity and pending capacity across yielding authorization', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'core/synex_core/shared/protocol.lua');
    await load(engine, 'core/synex_core/server/factories.lua');
    for (const module of ['foundation', 'registries', 'contracts', 'messaging']) {
      await load(engine, `core/synex_core/server/${module}.lua`);
    }

    const result = await engine.doString(`
      local handlers, responses = {}, {}
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function(_, _, response)
          responses[#responses + 1] = response
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('messaging-rpc-inbound-race')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local session = {
        id = 'session-active', userId = 'user-active', source = 42,
        sourceGeneration = 7, state = 'ACTIVE', version = 1,
        authorityDeadlineAt = 2500
      }
      local yieldAuthorization = false
      local changeStateDuringAuthorization = false
      local security = {
        validateNetworkEnvelope = function() return true, nil end,
        rateLimiter = {
          consume = function() return true, nil end,
          purge = function() end
        },
        rbac = {
          check = function()
            if changeStateDuringAuthorization then
              changeStateDuringAuthorization = false
              session.state = 'UNLOADING_CHARACTER'
              session.version = session.version + 1
              return true, nil
            end
            if yieldAuthorization then
              yieldAuthorization = false
              coroutine.yield('authorization-pending')
            end
            return true, nil
          end
        },
        capabilities = { check = function() return true, nil end }
      }
      local players = {
        getBySource = function() return foundation.copy(session) end,
        isCurrent = function(_, sessionId, playerSource, generation)
          return sessionId == session.id and playerSource == session.source
            and generation == session.sourceGeneration
        end
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = players,
        lifecycle = { core = { isOperational = function() return true end } },
        protocol = SynexProtocol,
        config = { maximumPayloadBytes = 1024, maximumPendingPerSource = 1 },
        coreResource = 'synex_core'
      })
      local handlerCalls, observedDeadline = 0, nil
      assert(messaging.gateway:register('synex_core', coreEpoch, {
        name = 'synex.fixture.inbound_race', version = '1.0.0',
        provider = 'synex_core', kind = 'rpc', stability = 'experimental',
        network = 'client-to-server', capability = 'synex.fixture.invoke',
        sessionStates = {'ACTIVE'}, errors = {},
        input = { type = 'object' },
        output = {
          type = 'object', additionalProperties = false, required = {'accepted'},
          properties = { accepted = { type = 'boolean' } }
        }
      }, function(_, context)
        handlerCalls = handlerCalls + 1
        observedDeadline = context.deadlineAt
        return { accepted = true }, nil
      end))
      messaging.network:bind()
      source = 42

      local function beginAuthorizedRequest(envelope)
        yieldAuthorization = true
        local requestThread = coroutine.create(function()
          handlers[SynexProtocol.events.request](envelope)
        end)
        local resumed, marker = coroutine.resume(requestThread)
        assert(resumed and marker == 'authorization-pending'
          and coroutine.status(requestThread) == 'suspended')
        return requestThread
      end

      local function finishAuthorizedRequest(requestThread)
        local resumed, failure = coroutine.resume(requestThread)
        assert(resumed, failure)
        assert(coroutine.status(requestThread) == 'dead')
      end

      local duplicateEnvelope = {
        wire = 1, requestId = 'request-duplicate',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      }
      local duplicateThread = beginAuthorizedRequest(duplicateEnvelope)
      assert(messaging.network:snapshot().activeInbound == 1)
      handlers[SynexProtocol.events.request](duplicateEnvelope)
      assert(handlerCalls == 0)
      finishAuthorizedRequest(duplicateThread)
      assert(#responses == 2 and responses[1].error.code == 'DUPLICATE_REQUEST'
        and responses[2].ok == true)
      assert(handlerCalls == 1 and observedDeadline == session.authorityDeadlineAt
        and messaging.network:snapshot().activeInbound == 0,
        'network handlers must inherit the shorter session-authority deadline')

      local firstEnvelope = {
        wire = 1, requestId = 'request-cap-first',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      }
      local secondEnvelope = {
        wire = 1, requestId = 'request-cap-second',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      }
      local maximumObserved = 0
      local capacityThread = beginAuthorizedRequest(firstEnvelope)
      maximumObserved = math.max(maximumObserved,
        messaging.network:snapshot().activeInbound)
      handlers[SynexProtocol.events.request](secondEnvelope)
      maximumObserved = math.max(maximumObserved,
        messaging.network:snapshot().activeInbound)
      finishAuthorizedRequest(capacityThread)
      assert(#responses == 4 and responses[3].error.code == 'TOO_MANY_PENDING_REQUESTS'
        and responses[4].ok == true)
      assert(handlerCalls == 2 and maximumObserved == 1)

      local reusedEnvelope = {
        wire = 1, requestId = 'request-reused-id',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      }
      local staleThread = beginAuthorizedRequest(reusedEnvelope)
      assert(messaging.network:snapshot().activeInbound == 1)
      messaging.network:purgeSource(session.source, session.sourceGeneration)
      assert(messaging.network:snapshot().activeInbound == 0)
      local replacementThread = beginAuthorizedRequest(reusedEnvelope)
      assert(messaging.network:snapshot().activeInbound == 1)
      finishAuthorizedRequest(staleThread)
      assert(messaging.network:snapshot().activeInbound == 1 and handlerCalls == 2,
        'a stale finalizer must not remove or execute the replacement request')
      finishAuthorizedRequest(replacementThread)
      assert(#responses == 5 and responses[5].ok == true and handlerCalls == 3)
      changeStateDuringAuthorization = true
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-state-race',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      })
      assert(#responses == 6 and responses[6].error.code == 'INVALID_SESSION_STATE'
        and handlerCalls == 3, 'a state change during RBAC must fence handler invocation')
      session.state = 'ACTIVE'
      session.version = session.version + 1
      security.rbac.check = function() error('fixture authorization failure') end
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-auth-error',
        procedure = 'synex.fixture.inbound_race', version = '1.0.0', payload = {}
      })
      assert(#responses == 7 and responses[7].error.code == 'INTERNAL_ERROR'
        and handlerCalls == 3)
      local snapshot = messaging.network:snapshot()
      assert(snapshot.activeInbound == 0 and snapshot.activeSources == 0)
      return table.concat({responses[1].error.code, responses[3].error.code,
        responses[6].error.code, responses[7].error.code, handlerCalls, maximumObserved,
        snapshot.activeInbound, observedDeadline}, ':')
    `);

    assert.equal(
      result,
      'DUPLICATE_REQUEST:TOO_MANY_PENDING_REQUESTS:INVALID_SESSION_STATE:INTERNAL_ERROR:3:1:0:2500',
    );
  } finally {
    engine.global.close();
  }
});
