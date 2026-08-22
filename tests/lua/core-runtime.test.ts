import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(source);
}

async function createKernelEngine(files: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of files) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    local now = 1000
    FakePlatform = {
      nowGame = function() now = now + 1 return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function(value) return '{}' end,
      jsonDecode = function() return {} end,
      loadResourceFile = function() return nil end,
      setTimeout = function(_, callback) callback() end
    }
  `);
  return engine;
}

test('SHA-256 uses a deterministic canonical digest', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const digest = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local persistence = SynexCoreFactories.persistence({
      platform = FakePlatform,
      foundation = foundation,
      db = {
        query = function() return {} end,
        scalar = function() return nil end,
        insert = function() return 1 end,
        update = function() return 1 end,
        transaction = function() return true end
      }
    })
    return persistence.sha256('abc')
  `);
  assert.equal(digest, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  engine.global.close();
});

test('core lifecycle rejects transitions outside the explicit state machine', async () => {
  const engine = await createKernelEngine(['foundation', 'registries', 'lifecycle']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    registries.owners:activate('synex_core')
    local lifecycle = SynexCoreFactories.lifecycle({
      platform = FakePlatform, foundation = foundation, owners = registries.owners
    })
    local value, err = lifecycle.core:transition('READY', 'invalid shortcut')
    assert(value == nil)
    assert(err.code == 'INVALID_STATE_TRANSITION')
    assert(lifecycle.core:get() == 'CREATED')
    return err.code
  `);
  assert.equal(result, 'INVALID_STATE_TRANSITION');
  engine.global.close();
});

test('player admission requires READY, completed critical validation, and no health reasons', async () => {
  const engine = await createKernelEngine(['foundation', 'registries', 'lifecycle']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    registries.owners:activate('synex_core')
    local lifecycle = SynexCoreFactories.lifecycle({
      platform = FakePlatform, foundation = foundation, owners = registries.owners
    })
    for _, target in ipairs({
      'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
      'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
    }) do assert(lifecycle.core:transition(target, 'fixture')) end
    assert(lifecycle.core:isOperational())
    assert(not lifecycle.core:canAdmitPlayers())
    lifecycle.core:setCriticalFoundationsValidated(true)
    assert(lifecycle.core:canAdmitPlayers())
    lifecycle.core:setHealth('cluster', 'DEGRADED', 'fixture failure')
    assert(not lifecycle.core:canAdmitPlayers())
    lifecycle.core:setHealth('cluster', 'HEALTHY')
    assert(lifecycle.core:canAdmitPlayers())
    assert(lifecycle.core:transition('DEGRADED', 'critical dependency'))
    assert(lifecycle.core:isOperational() and not lifecycle.core:canAdmitPlayers())
    return lifecycle.core:snapshot().playerAdmission
  `);
  assert.equal(result, false);
  engine.global.close();
});

test('player registry invalidates reused sources with a new generation', async () => {
  const engine = await createKernelEngine(['foundation', 'registries']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registry = SynexCoreFactories.registries({ foundation = foundation }).players
    assert(registry:createPending(10, { sessionId = 'one' }))
    local first = assert(registry:bindJoined(10, 42, { id = 'one', userId = 'u1', state = 'SELECTING_CHARACTER' }))
    assert(first.sourceGeneration == 1)
    assert(registry:isCurrent('one', 42, 1))
    registry:removeSession('one')
    assert(not registry:isCurrent('one', 42, 1))
    assert(registry:createPending(11, { sessionId = 'two' }))
    local second = assert(registry:bindJoined(11, 42, { id = 'two', userId = 'u2', state = 'SELECTING_CHARACTER' }))
    assert(second.sourceGeneration == 3)
    return second.sourceGeneration
  `);
  assert.equal(result, 3);
  engine.global.close();
});

test('owner purge revokes all tracked artifacts once', async () => {
  const engine = await createKernelEngine(['foundation', 'registries']);
  const cleaned = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local owners = SynexCoreFactories.registries({ foundation = foundation }).owners
    local epoch = owners:activate('synex_example')
    local count = 0
    assert(owners:track('synex_example', epoch, 'hook', 'a', function() count = count + 1 end))
    assert(owners:track('synex_example', epoch, 'service', 'b', function() count = count + 1 end))
    local report = owners:purge('synex_example')
    assert(report.cleaned == 2)
    assert(not owners:isCurrent('synex_example', epoch))
    owners:purge('synex_example')
    assert(count == 2)
    return count
  `);
  assert.equal(cleaned, 2);
  engine.global.close();
});

test('contract validation rejects unknown properties and oversized strings', async () => {
  const engine = await createKernelEngine(['foundation', 'contracts']);
  const code = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local ok, finding = contracts.validate({
      type = 'object', required = {'name'}, additionalProperties = false,
      properties = { name = { type = 'string', maxLength = 8 } }
    }, { name = 'Synex', extra = true })
    assert(ok == nil)
    assert(finding.rule == 'additionalProperties')
    return finding.rule
  `);
  assert.equal(code, 'additionalProperties');
  engine.global.close();
});

test('character delete contract accepts durable reconciliation states only', async () => {
  const engine = await createKernelEngine(['foundation', 'contracts']);
  try {
    await load(engine, 'core/synex_core/shared/generated_contracts.lua');
    const code = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol, generated = SynexGeneratedContracts
      })
      local contract = assert(contracts.registry:resolve('synex.identity.characters.delete', '1.0.0'))
      assert(contracts.registry:validateOutput(contract, {
        planId = 'plan-fixture', characterId = 'character-fixture', state = 'completed'
      }))
      assert(contracts.registry:validateOutput(contract, {
        planId = 'plan-fixture', characterId = 'character-fixture', state = 'reconciling'
      }))
      local invalid, invalidError = contracts.registry:validateOutput(contract, {
        planId = 'plan-fixture', characterId = 'character-fixture', state = 'pending'
      })
      assert(invalid == nil and invalidError.code == 'INVALID_PROVIDER_RESPONSE')
      return invalidError.code
    `);
    assert.equal(code, 'INVALID_PROVIDER_RESPONSE');
  } finally {
    engine.global.close();
  }
});

test('capability policy applies deny precedence over grants', async () => {
  const engine = await createKernelEngine(['foundation', 'security']);
  const code = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = {
        default = { allow = {}, deny = {} },
        resources = { synex_example = { allow = {'synex.accounts.*'}, deny = {'synex.accounts.mint'} } }
      }
    })
    security.capabilities:registerManifest('synex_example', {
      capabilities = { request = {'synex.accounts.mint'} }
    })
    local ok, err = security.capabilities:check('synex_example', 'synex.accounts.mint', {})
    assert(ok == nil)
    return err.code
  `);
  assert.equal(code, 'CAPABILITY_DENIED');
  engine.global.close();
});

test('semantic ranges and capability wildcards use boundary-aware matching', async () => {
  const engine = await createKernelEngine(['foundation']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    assert(foundation.semverSatisfies('1.4.2', '^1.2.0'))
    assert(not foundation.semverSatisfies('2.0.0', '^1.2.0'))
    assert(foundation.semverSatisfies('1.4.2', '>=1.0.0 <2.0.0'))
    assert(foundation.semverSatisfies('0.2.8', '^0.2.1'))
    assert(not foundation.semverSatisfies('0.3.0', '^0.2.1'))
    assert(foundation.semver('1.0.0-alpha.2'))
    assert(not foundation.semver('1.0.0-alpha..2'))
    assert(not foundation.semver('1.0.0-alpha.02'))
    assert(not foundation.semverSatisfies('1.1.0-beta.1', '^1.0.0'))
    assert(foundation.semverCompare(
      foundation.semver('1.0.0-beta.10'), foundation.semver('1.0.0-beta.2')
    ) > 0)
    assert(foundation.wildcardMatch('synex.accounts.*', 'synex.accounts.read'))
    assert(not foundation.wildcardMatch('synex.account.*', 'synex.accounts.read'))
    return true
  `);
  assert.equal(result, true);
  engine.global.close();
});

test('opaque IDs remain bounded and unique under a deterministic burst', async () => {
  const engine = await createKernelEngine(['foundation']);
  const count = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('test-node')
    local seen = {}
    for index = 1, 10000 do
      local id = foundation.nextId('entity')
      assert(#id <= 36)
      assert(not seen[id])
      seen[id] = true
    end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    return count
  `);
  assert.equal(count, 10_000);
  engine.global.close();
});

test('repeated owner restarts do not retain stale registrations', async () => {
  const engine = await createKernelEngine(['foundation', 'registries']);
  const cleaned = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local owners = SynexCoreFactories.registries({ foundation = foundation }).owners
    local cleaned = 0
    for iteration = 1, 250 do
      local epoch = owners:activate('synex_restart_fixture')
      for artifact = 1, 8 do
        local token = tostring(iteration) .. ':' .. tostring(artifact)
        assert(owners:track('synex_restart_fixture', epoch, 'fixture', token, function() cleaned = cleaned + 1 end))
      end
      local report = owners:purge('synex_restart_fixture')
      assert(report.cleaned == 8)
      assert(#report.errors == 0)
      assert(not owners:isCurrent('synex_restart_fixture', epoch))
    end
    return cleaned
  `);
  assert.equal(cleaned, 2_000);
  engine.global.close();
});

test('schema fuzzer rejects malformed payloads without escaping the validator', async () => {
  const engine = await createKernelEngine(['foundation', 'contracts']);
  const rejected = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local schema = {
      type = 'object', additionalProperties = false, required = {'id', 'amount'},
      properties = {
        id = { type = 'string', minLength = 1, maxLength = 36 },
        amount = { type = 'integer', minimum = 1, maximum = 1000000 }
      }
    }
    local malformed = {
      false, true, 1, -1, 'text',
      {}, {id = ''}, {id = 'x', amount = 0}, {id = 'x', amount = 1.5},
      {id = string.rep('x', 37), amount = 1},
      {id = 'x', amount = 1, unexpected = true},
      {id = {'nested'}, amount = 1}
    }
    local rejected = 0
    for round = 1, 200 do
      for _, payload in ipairs(malformed) do
        local ok = contracts.validate(schema, payload)
        if not ok then rejected = rejected + 1 end
      end
    end
    return rejected
  `);
  assert.equal(rejected, 2_400);
  engine.global.close();
});

test('service registry injects the real caller and keeps capability-less methods private', async () => {
  const engine = await createKernelEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local owners = registries.owners
    local coreEpoch = owners:activate('synex_core')
    local providerEpoch = owners:activate('synex_provider')
    local consumerEpoch = owners:activate('synex_consumer')
    local attackerEpoch = owners:activate('synex_attacker')
    local lifecycle = SynexCoreFactories.lifecycle({
      platform = FakePlatform, foundation = foundation, owners = owners
    })
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = {
        default = { allow = {}, deny = {} },
        resources = { synex_consumer = { allow = {'synex.fixture.read'}, deny = {} } }
      }
    })
    security.capabilities:registerManifest('synex_consumer', {
      capabilities = { request = {'synex.fixture.read'} }
    })
    security.capabilities:registerManifest('synex_attacker', { capabilities = { request = {} } })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local messaging = SynexCoreFactories.messaging({
      platform = FakePlatform, foundation = foundation, contracts = contracts,
      security = security, owners = owners, players = registries.players,
      lifecycle = lifecycle, dependencies = lifecycle.dependencies,
      protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
    })
    local invalidService, invalidServiceError = messaging.services:provide('synex_provider', providerEpoch, {
      name = 'synex.fixture..admin', version = '1.0.0', methods = { read = function() return {} end }
    })
    assert(invalidService == nil and invalidServiceError.code == 'INVALID_SERVICE')
    assert(messaging.services:provide('synex_provider', providerEpoch, {
      name = 'synex.fixture', version = '1.0.0',
      capabilities = { read = 'synex.fixture.read' },
      methods = {
        read = function(_, context) return { caller = context.caller } end,
        private = function() return { value = true } end
      }
    }))
    local value = assert(messaging.services:call(
      'synex_consumer', consumerEpoch, 'synex.fixture', '^1.0.0', 'read', {},
      { caller = 'synex_spoofed', callerEpoch = 999 }
    ))
    assert(value.caller == 'synex_consumer')
    local privateValue, privateError = messaging.services:call(
      'synex_consumer', consumerEpoch, 'synex.fixture', '^1.0.0', 'private', {}, {}
    )
    assert(privateValue == nil and privateError.code == 'SERVICE_METHOD_PRIVATE')
    local deniedValue, deniedError = messaging.services:call(
      'synex_attacker', attackerEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {}
    )
    assert(deniedValue == nil and deniedError.code == 'CAPABILITY_UNDECLARED')
    return value.caller
  `);
  assert.equal(result, 'synex_consumer');
  engine.global.close();
});

test('service provider health and circuit state drive dependency validation and recover', async () => {
  const engine = await createKernelEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  const result = await engine.doString(`
    local now, failProvider = 1000, true
    local platform = setmetatable({
      nowGame = function() return now end
    }, { __index = FakePlatform })
    local foundation = SynexCoreFactories.foundation({ platform = platform })
    foundation.configureIds('provider-health')
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local owners = registries.owners
    local coreEpoch = owners:activate('synex_core')
    local providerEpoch = owners:activate('synex_provider')
    local lifecycle = SynexCoreFactories.lifecycle({
      platform = platform, foundation = foundation, owners = owners
    })
    lifecycle.dependencies:require('synex_core', 'synex.fixture', '^1.0.0', false, true)
    local security = SynexCoreFactories.security({
      platform = platform, foundation = foundation, coreResource = 'synex_core',
      policy = { default = { allow = {}, deny = {} }, resources = {} }
    })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local messaging = SynexCoreFactories.messaging({
      platform = platform, foundation = foundation, contracts = contracts,
      security = security, owners = owners, players = registries.players,
      lifecycle = lifecycle, dependencies = lifecycle.dependencies,
      protocol = SynexProtocol, config = { circuitResetMs = 5000 }, coreResource = 'synex_core'
    })
    assert(messaging.services:provide('synex_provider', providerEpoch, {
      name = 'synex.fixture', version = '1.0.0',
      methods = { read = function()
        if failProvider then return nil, foundation.error('FIXTURE_FAILURE', 'fixture failure') end
        return { ready = true }, nil
      end }
    }))
    assert(#lifecycle.dependencies:validate() == 0)
    for _ = 1, 5 do
      local value, callError = messaging.services:call(
        'synex_core', coreEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {})
      assert(value == nil and callError.code == 'FIXTURE_FAILURE')
    end
    local opened = lifecycle.dependencies:snapshot().providerHealth['synex.fixture'].synex_provider
    assert(opened.health == 'HEALTHY' and opened.circuit == 'OPEN')
    assert(#lifecycle.dependencies:validate() == 1)
    now = now + 5001
    failProvider = false
    assert(messaging.services:call(
      'synex_core', coreEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {}))
    local recovered = lifecycle.dependencies:snapshot().providerHealth['synex.fixture'].synex_provider
    assert(recovered.health == 'HEALTHY' and recovered.circuit == 'CLOSED')
    assert(#lifecycle.dependencies:validate() == 0)
    assert(messaging.services:setHealth(
      'synex_provider', providerEpoch, 'synex.fixture', '1.0.0', 'UNHEALTHY'))
    assert(#lifecycle.dependencies:validate() == 1)
    assert(messaging.services:setHealth(
      'synex_provider', providerEpoch, 'synex.fixture', '1.0.0', 'HEALTHY'))
    assert(#lifecycle.dependencies:validate() == 0)
    return opened.circuit .. ':' .. recovered.circuit
  `);
  assert.equal(result, 'OPEN:CLOSED');
  engine.global.close();
});

test('durable event delivery preserves outbox identity across subscriber retries', async () => {
  const engine = await createKernelEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('durable-events')
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local owners = registries.owners
    local publisherEpoch = owners:activate('synex_core')
    local consumerEpoch = owners:activate('synex_consumer')
    local failingEpoch = owners:activate('synex_failing_consumer')
    local lifecycle = SynexCoreFactories.lifecycle({
      platform = FakePlatform, foundation = foundation, owners = owners
    })
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = { default = { allow = {}, deny = {} }, resources = {} }
    })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local messaging = SynexCoreFactories.messaging({
      platform = FakePlatform, foundation = foundation, contracts = contracts,
      security = security, owners = owners, players = registries.players,
      lifecycle = lifecycle, dependencies = lifecycle.dependencies,
      protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
    })
    local deliveries, failures, firstEventId = 0, 0, nil
    assert(messaging.events:subscribe('synex_consumer', consumerEpoch, 'synex.fixture.changed', function(_, context)
      assert(context.durable == true and context.outbox == true)
      assert(context.aggregateId == 'aggregate-a' and context.schemaVersion == 2)
      firstEventId = firstEventId or context.eventId
      assert(context.eventId == firstEventId)
      deliveries = deliveries + 1
      return true, nil
    end))
    assert(messaging.events:subscribe('synex_failing_consumer', failingEpoch, 'synex.fixture.changed', function(_, context)
      assert(context.eventId == 'event-stable-01')
      failures = failures + 1
      if failures == 1 then return nil, foundation.error('CONSUMER_RETRY', 'retry', { retryable = true }) end
      return true, nil
    end))
    local forged, forgedError = messaging.events:publish('synex_core', publisherEpoch,
      'synex.fixture.changed', {}, { outbox = true, eventId = 'event-stable-01' })
    assert(forged == nil and forgedError.code == 'DURABLE_EVENT_REQUIRES_OUTBOX')
    local metadata = {
      eventId = 'event-stable-01', aggregateId = 'aggregate-a', schemaVersion = 2,
      traceId = 'trace-stable-01'
    }
    local first, firstError = messaging.events:publishOutbox(
      'synex_core', publisherEpoch, 'synex.fixture.changed', { value = 1 }, metadata)
    assert(first == nil and firstError.code == 'OUTBOX_DELIVERY_FAILED' and firstError.retryable)
    local second = assert(messaging.events:publishOutbox(
      'synex_core', publisherEpoch, 'synex.fixture.changed', { value = 1 }, metadata))
    assert(second.delivered == 2 and second.failed == 0)
    local empty = assert(messaging.events:publishOutbox(
      'synex_core', publisherEpoch, 'synex.fixture.unobserved', {}, {
        eventId = 'event-empty-01', aggregateId = 'aggregate-a', schemaVersion = 1
      }))
    assert(empty.delivered == 0 and empty.failed == 0)
    return table.concat({firstEventId, deliveries, failures}, ':')
  `);
  assert.equal(result, 'event-stable-01:2:2');
  engine.global.close();
});

test('state authority validates cross-resource capabilities and owns replication revisions', async () => {
  const engine = await createKernelEngine([
    'foundation',
    'registries',
    'contracts',
    'security',
    'state',
  ]);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local owners = registries.owners
    owners:activate('synex_core')
    local ownerEpoch = owners:activate('synex_owner')
    local consumerEpoch = owners:activate('synex_consumer')
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = {
        default = { allow = {}, deny = {} },
        resources = { synex_consumer = { allow = {'synex.fixture.state.read', 'synex.fixture.state.write'}, deny = {} } }
      }
    })
    security.capabilities:registerManifest('synex_consumer', {
      capabilities = { request = {'synex.fixture.state.read', 'synex.fixture.state.write'} }
    })
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local replicated
    local state = SynexCoreFactories.state({
      platform = FakePlatform, foundation = foundation, contracts = contracts,
      owners = owners, security = security, coreResource = 'synex_core',
      replicate = function(_, _, snapshot) replicated = snapshot return true end
    })
    local malformed, malformedError = state:define('synex_owner', ownerEpoch, {
      name = 'synex_owner.malformed', scope = 'global', authority = 'server',
      schema = { type = 'integer' }, readCapability = 'synex..state'
    })
    assert(malformed == nil and malformedError.code == 'INVALID_STATE_DEFINITION')
    assert(state:define('synex_owner', ownerEpoch, {
      name = 'synex_owner.status', scope = 'global', authority = 'server',
      schema = { type = 'integer', minimum = 0 }, replicated = true,
      readCapability = 'synex.fixture.state.read',
      writeCapability = 'synex.fixture.state.write'
    }))
    local snapshot = assert(state:set(
      'synex_consumer', consumerEpoch, 'synex_owner.status', nil, 7,
      { revision = 'caller-controlled' }
    ))
    assert(snapshot.revision ~= 'caller-controlled')
    assert(replicated.revision == snapshot.revision and replicated.value == 7)
    local current = assert(state:get('synex_consumer', consumerEpoch, 'synex_owner.status', nil))
    assert(current == 7)
    local entityState, entityError = state:define('synex_owner', ownerEpoch, {
      name = 'synex_owner.entity_status', scope = 'entity', authority = 'owner',
      schema = { type = 'integer' }, replicated = true
    })
    assert(entityState == nil and entityError.code == 'UNSUPPORTED_REPLICATION_SCOPE')
    return snapshot.revision
  `);
  assert.match(String(result), /^state_/);
  engine.global.close();
});

test('core database adapter rejects malformed port results without turning failures into empty reads', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local mode = 'valid'
    local adapter = {
      query = function()
        if mode == 'query_nil' then return nil end
        if mode == 'query_error' then return {}, { code = 'PORT_FAILED' } end
        return {}
      end,
      scalar = function()
        if mode == 'scalar_table' then return {} end
        return nil
      end,
      insert = function()
        if mode == 'insert_nil' then return nil end
        if mode == 'insert_fraction' then return 1.5 end
        return 0
      end,
      update = function()
        if mode == 'update_nil' then return nil end
        if mode == 'update_negative' then return -1 end
        if mode == 'update_infinite' then return math.huge end
        return 0
      end,
      transaction = function() return true end
    }
    local database = SynexCoreFactories.persistence({
      platform = FakePlatform,
      foundation = foundation,
      db = adapter
    }).database

    mode = 'query_nil'
    local value, err = database:query('SELECT 1', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'query_error'
    value, err = database:query('SELECT 1', {})
    assert(value == nil and err.code == 'DATABASE_ERROR')
    mode = 'scalar_table'
    value, err = database:scalar('SELECT 1', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'valid'
    value, err = database:scalar('SELECT NULL', {})
    assert(value == nil and err == nil)
    assert(database:query('SELECT 1', {}))
    assert(database:update('UPDATE fixture', {}) == 0)
    assert(database:insert('INSERT fixture', {}) == 0)
    mode = 'update_nil'
    value, err = database:update('UPDATE fixture', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'update_negative'
    value, err = database:update('UPDATE fixture', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'update_infinite'
    value, err = database:update('UPDATE fixture', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'insert_nil'
    value, err = database:insert('INSERT fixture', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    mode = 'insert_fraction'
    value, err = database:insert('INSERT fixture', {})
    assert(value == nil and err.code == 'DATABASE_RESULT_INVALID')
    return 'fail-closed'
  `);
  assert.equal(result, 'fail-closed');
  engine.global.close();
});

test('database UTC session validation fails closed on offset, malformed, and adapter errors', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local offset, failQuery, capturedSql = 0, false, nil
    local database = SynexCoreFactories.persistence({
      platform = FakePlatform,
      foundation = foundation,
      db = {
        query = function() return {} end,
        scalar = function(sql)
          capturedSql = sql
          if failQuery then return nil, { code = 'PORT_FAILED' } end
          return offset
        end,
        insert = function() return 0 end,
        update = function() return 0 end,
        transaction = function() return true end
      }
    }).database
    assert(database:validateUtcSession())
    assert(capturedSql == 'SELECT TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), CURRENT_TIMESTAMP()) AS offset_seconds')
    offset = 3600
    local valid, timezoneError = database:validateUtcSession()
    assert(valid == nil and timezoneError.code == 'DATABASE_TIMEZONE_INVALID')
    offset = nil
    valid, timezoneError = database:validateUtcSession()
    assert(valid == nil and timezoneError.code == 'DATABASE_TIMEZONE_INVALID')
    failQuery = true
    valid, timezoneError = database:validateUtcSession()
    assert(valid == nil and timezoneError.code == 'DATABASE_ERROR')
    return timezoneError.code
  `);
  assert.equal(result, 'DATABASE_ERROR');
  engine.global.close();
});

test('outbox dispatch aborts before claiming when stale-claim reset fails', async () => {
  const engine = await createKernelEngine(['foundation', 'reliability']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('outbox-test')
    local queries, updates, handlerCalls = 0, 0, 0
    local database = {
      update = function()
        updates = updates + 1
        return nil, foundation.error('DATABASE_ERROR', 'reset failed', { retryable = true })
      end,
      query = function()
        queries = queries + 1
        return {}, nil
      end
    }
    local reliability = SynexCoreFactories.reliability({
      platform = FakePlatform,
      foundation = foundation,
      database = database,
      sha256 = function() return string.rep('0', 64) end,
      instanceId = 'outbox-test',
      features = { durableEvents = true }
    })
    local report, err = reliability.outbox:dispatchBatch(function()
      handlerCalls = handlerCalls + 1
      return true
    end, 25)
    assert(report == nil and err.code == 'DATABASE_ERROR')
    assert(updates == 1 and queries == 0 and handlerCalls == 0)
    return err.code
  `);
  assert.equal(result, 'DATABASE_ERROR');
  engine.global.close();
});

test('migration lease release reports adapter failure and remains retryable', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('migration-release-test')
    local failRelease = false
    local adapter = {
      query = function()
        return {{ owner_id = 'instance-a', fencing_token = 4, valid = 1 }}
      end,
      scalar = function() return nil end,
      insert = function() return 0 end,
      update = function()
        if failRelease then return nil, { code = 'PORT_FAILED' } end
        return 1
      end,
      transaction = function() return true end
    }
    local migrations = SynexCoreFactories.persistence({
      platform = FakePlatform,
      foundation = foundation,
      db = adapter,
      instanceId = 'instance-a'
    }).migrations
    assert(migrations:acquireLease() == 4)
    failRelease = true
    local released, releaseError = migrations:releaseLease()
    assert(released == nil and releaseError.code == 'DATABASE_ERROR')
    failRelease = false
    assert(migrations:releaseLease())
    return releaseError.code
  `);
  assert.equal(result, 'DATABASE_ERROR');
  engine.global.close();
});
