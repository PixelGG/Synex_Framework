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

test('foundation recognizes callable Cfx proxies and restores execution context', async () => {
  const engine = await createKernelEngine(['foundation']);
  await engine.global.set('cfxCallableUserdata', {});
  await engine.global.set('cfxPlainUserdata', {});
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local function plain(value) return value end
      local tableCalls, userdataCalls = 0, 0
      local callableTable = setmetatable({ __cfx_functionReference = 'fixture-table' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, left, right)
          tableCalls = tableCalls + 1
          local context = assert(foundation.currentContext())
          assert(context.caller == 'synex_fixture' and context.nested.value == 1)
          context.nested.value = 99
          return left, nil, right
        end
      })
      debug.setmetatable(cfxCallableUserdata, {
        __metatable = 'protected-cfx-userdata',
        __call = function(_, value)
          userdataCalls = userdataCalls + 1
          assert(foundation.currentContext().caller == 'synex_userdata')
          return value, nil, 'tail'
        end
      })
      debug.setmetatable(cfxPlainUserdata, {
        __metatable = 'protected-noncallable-userdata'
      })

      assert(type(cfxCallableUserdata) == 'userdata')
      assert(foundation.isCallable(plain))
      assert(foundation.isCallable(callableTable))
      assert(foundation.isCallable(cfxCallableUserdata))
      assert(not foundation.isCallable(nil) and not foundation.isCallable(42))
      assert(not foundation.isCallable({ __cfx_functionReference = 'spoof-only' }))
      assert(not foundation.isCallable(setmetatable({ __cfx_functionReference = 'spoof-string' }, {
        __metatable = 'protected-spoof', __call = 'function'
      })))
      assert(not foundation.isCallable(setmetatable({}, {
        __metatable = 'protected-index-spoof', __index = { __call = plain }
      })))
      assert(not foundation.isCallable(cfxPlainUserdata))

      local sourceContext = { caller = 'synex_fixture', nested = { value = 1 } }
      local values = table.pack(foundation.withContext(sourceContext, callableTable, 'first', 'third'))
      assert(values.n == 3 and values[1] == 'first' and values[2] == nil and values[3] == 'third')
      assert(sourceContext.nested.value == 1 and foundation.currentContext() == nil)

      local userdataValues = table.pack(foundation.withContext(
        { caller = 'synex_userdata' }, cfxCallableUserdata, 'userdata-result'))
      assert(userdataValues.n == 3 and userdataValues[1] == 'userdata-result'
        and userdataValues[2] == nil and userdataValues[3] == 'tail')
      assert(foundation.currentContext() == nil)

      local outer = foundation.withContext({ caller = 'synex_outer' }, function()
        assert(foundation.currentContext().caller == 'synex_outer')
        local ok, failure = pcall(function()
          foundation.withContext({ caller = 'synex_inner' }, setmetatable({}, {
            __call = function()
              assert(foundation.currentContext().caller == 'synex_inner')
              error('fixture-context-failure')
            end
          }))
        end)
        assert(not ok and tostring(failure):find('fixture-context-failure', 1, true))
        assert(foundation.currentContext().caller == 'synex_outer')
        return plain('restored')
      end)
      assert(outer == 'restored' and foundation.currentContext() == nil)
      local invalid = pcall(foundation.withContext, {}, { __cfx_functionReference = 'spoof' })
      assert(not invalid and foundation.currentContext() == nil)
      assert(tableCalls == 1 and userdataCalls == 1)
      return table.concat({tableCalls, userdataCalls, outer}, ':')
    `);
    assert.equal(result, '1:1:restored');
  } finally {
    engine.global.close();
  }
});

test('foundation keeps public result tuples array-shaped across Cfx without-hole transport', async () => {
  const engine = await createKernelEngine(['foundation']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local failure = foundation.error('FIXTURE_FAILURE', 'fixture')

      local function transportShape(values)
        local count, maximum = 0, 0
        for key in pairs(values) do
          if type(key) == 'number' and math.type(key) == 'integer' and key > 0 then
            count = count + 1
            maximum = math.max(maximum, key)
          end
        end
        return maximum == count and 'array' or 'map'
      end

      local legacyFailure = { (function() return nil, failure end)() }
      assert(transportShape(legacyFailure) == 'map'
        and legacyFailure[1] == nil and legacyFailure[2] == failure)

      local publicFailure = { foundation.cfxResult(function()
        return nil, failure
      end) }
      assert(transportShape(publicFailure) == 'array'
        and #publicFailure == 2 and publicFailure[1] == false
        and publicFailure[2] == failure)

      local value = { accepted = true }
      local metadata = { replayed = false }
      local safeSuccess = table.pack(foundation.safeCall(function()
        return value, nil, metadata
      end))
      assert(safeSuccess.n == 4 and safeSuccess[1] == true
        and safeSuccess[2] == value and safeSuccess[3] == nil
        and safeSuccess[4] == metadata)

      local publicSuccess = table.pack(foundation.cfxResult(function()
        return value, nil, metadata
      end))
      assert(publicSuccess.n == 3 and transportShape(publicSuccess) == 'array'
        and publicSuccess[1] == value and publicSuccess[2] == false
        and publicSuccess[3] == metadata)

      local single = table.pack(foundation.cfxResult(function() return 'ready' end))
      assert(single.n == 1 and single[1] == 'ready')

      local trailingNil = table.pack(foundation.cfxResult(function()
        return value, nil
      end))
      assert(trailingNil.n == 2 and trailingNil[1] == value and trailingNil[2] == nil)

      return table.concat({transportShape(legacyFailure), transportShape(publicFailure),
        transportShape(publicSuccess), tostring(publicFailure[1])}, ':')
    `);
    assert.equal(result, 'map:array:array:false');
  } finally {
    engine.global.close();
  }
});

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
    assert(lifecycle.core:healthStatus() == 'DEGRADED')
    lifecycle.core:setCriticalFoundationsValidated(true)
    assert(lifecycle.core:canAdmitPlayers())
    assert(lifecycle.core:healthStatus() == 'HEALTHY')
    lifecycle.core:setHealth('cluster', 'DEGRADED', 'fixture failure')
    assert(not lifecycle.core:canAdmitPlayers())
    assert(lifecycle.core:healthStatus() == 'DEGRADED')
    lifecycle.core:setHealth('cluster', 'HEALTHY')
    assert(lifecycle.core:canAdmitPlayers())
    assert(lifecycle.core:healthStatus() == 'HEALTHY')
    assert(lifecycle.core:transition('DEGRADED', 'critical dependency'))
    assert(lifecycle.core:isOperational() and not lifecycle.core:canAdmitPlayers())
    assert(lifecycle.core:healthStatus() == 'DEGRADED')
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

test('player registry seeds persisted source generations once and fails closed at exhaustion', async () => {
  const engine = await createKernelEngine(['foundation', 'registries']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registry = SynexCoreFactories.registries({ foundation = foundation }).players
    assert(registry:seedSourceGeneration(37))
    assert(registry:createPending(10, { sessionId = 'one' }))
    local first = assert(registry:bindJoined(10, 42, { id = 'one', userId = 'u1' }))
    assert(registry:createPending(11, { sessionId = 'two' }))
    local second = assert(registry:bindJoined(11, 43, { id = 'two', userId = 'u2' }))
    assert(first.sourceGeneration == 38 and second.sourceGeneration == 38)
    registry:removeSession('one')
    assert(registry:createPending(12, { sessionId = 'three' }))
    local third = assert(registry:bindJoined(12, 42, { id = 'three', userId = 'u3' }))
    assert(third.sourceGeneration == 40)
    local reseeded, reseedError = registry:seedSourceGeneration(1)
    assert(reseeded == nil and reseedError.code == 'SOURCE_GENERATION_ALREADY_ACTIVE')

    local exhausted = SynexCoreFactories.registries({ foundation = foundation }).players
    assert(exhausted:seedSourceGeneration(9007199254740990))
    assert(exhausted:createPending(20, { sessionId = 'maximum' }))
    local maximum = assert(exhausted:bindJoined(20, 99, { id = 'maximum', userId = 'u4' }))
    assert(maximum.sourceGeneration == 9007199254740991)
    exhausted:removeSession('maximum')
    assert(exhausted:createPending(21, { sessionId = 'overflow' }))
    local overflow, overflowError = exhausted:bindJoined(21, 99, { id = 'overflow', userId = 'u5' })
    assert(overflow == nil and overflowError.code == 'SOURCE_GENERATION_EXHAUSTED')
    return table.concat({first.sourceGeneration, second.sourceGeneration, third.sourceGeneration,
      reseedError.code, overflowError.code}, ':')
  `);
  assert.equal(result, '38:38:40:SOURCE_GENERATION_ALREADY_ACTIVE:SOURCE_GENERATION_EXHAUSTED');
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

test('owner registries bound artifacts and concurrent operations with reusable capacity', async () => {
  const engine = await createKernelEngine(['foundation', 'registries']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('owner-capacity')
    local owners = SynexCoreFactories.registries({
      foundation = foundation,
      maximumArtifactsPerOwner = 2,
      maximumArtifactsPerKind = 1,
      maximumOperationsPerOwner = 1
    }).owners
    local epoch = owners:activate('synex_example')
    assert(owners:track('synex_example', epoch, 'hook', 'a', function() end))
    local duplicate, duplicateError = owners:track(
      'synex_example', epoch, 'hook', 'a', function() end)
    assert(duplicate == nil and duplicateError.code == 'DUPLICATE_OWNER_ARTIFACT')
    local kindOverflow, kindError = owners:track(
      'synex_example', epoch, 'hook', 'b', function() end)
    assert(kindOverflow == nil and kindError.code == 'OWNER_ARTIFACT_LIMIT')
    assert(owners:track('synex_example', epoch, 'service', 'b', function() end))
    local totalOverflow, totalError = owners:track(
      'synex_example', epoch, 'state', 'c', function() end)
    assert(totalOverflow == nil and totalError.code == 'OWNER_ARTIFACT_LIMIT')
    assert(owners:list()[1].artifacts == 2)
    assert(owners:release('synex_example', 'hook', 'a'))
    assert(owners:track('synex_example', epoch, 'state', 'c', function() end))

    local operation = assert(owners:beginOperation('synex_example', epoch))
    local operationOverflow, operationError = owners:beginOperation('synex_example', epoch)
    assert(operationOverflow == nil and operationError.code == 'OWNER_OPERATION_LIMIT')
    assert(owners:finishOperation('synex_example', epoch, operation))
    assert(owners:beginOperation('synex_example', epoch))
    local report = owners:purge('synex_example', epoch, 'fixture cleanup')
    assert(report.cleaned == 2 and report.aborted == 1)
    return table.concat({duplicateError.code, kindError.code, totalError.code,
      operationError.code, report.cleaned, report.aborted}, ':')
  `);
  assert.equal(result,
    'DUPLICATE_OWNER_ARTIFACT:OWNER_ARTIFACT_LIMIT:OWNER_ARTIFACT_LIMIT:OWNER_OPERATION_LIMIT:2:1');
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
    assert(not foundation.semver(string.rep('1', 129)))
    assert(not foundation.semverSatisfies('1.1.0-beta.1', '^1.0.0'))
    assert(not foundation.semverSatisfies('1.0.0', 123))
    assert(not foundation.semverSatisfies('1.0.0', string.rep('>', 257)))
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
    local serviceCalls = 0
    local readHandler = setmetatable({ __cfx_functionReference = 'fixture-service-read' }, {
      __metatable = 'protected-cfx-funcref',
      __call = function(_, request, context)
        serviceCalls = serviceCalls + 1
        assert(type(request) == 'table')
        return { caller = context.caller }
      end
    })
    local invalidService, invalidServiceError = messaging.services:provide('synex_provider', providerEpoch, {
      name = 'synex.fixture..admin', version = '1.0.0', methods = { read = function() return {} end }
    })
    assert(invalidService == nil and invalidServiceError.code == 'INVALID_SERVICE')
    assert(messaging.services:provide('synex_provider', providerEpoch, {
      name = 'synex.fixture', version = '1.0.0',
      capabilities = { read = 'synex.fixture.read' },
      methods = {
        read = readHandler,
        private = function() return { value = true } end
      }
    }))
    local spoofed, spoofedError = messaging.services:call(
      'synex_consumer', consumerEpoch, 'synex.fixture', '^1.0.0', 'read', {},
      { caller = 'synex_spoofed', callerEpoch = 999 }
    )
    assert(spoofed == nil and spoofedError.code == 'INVALID_SERVICE_CONTEXT')
    local value = assert(messaging.services:call(
      'synex_consumer', consumerEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {}
    ))
    assert(value.caller == 'synex_consumer' and serviceCalls == 1)
    local privateValue, privateError = messaging.services:call(
      'synex_consumer', consumerEpoch, 'synex.fixture', '^1.0.0', 'private', {}, {}
    )
    assert(privateValue == nil and privateError.code == 'SERVICE_METHOD_PRIVATE')
    local deniedValue, deniedError = messaging.services:call(
      'synex_attacker', attackerEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {}
    )
    assert(deniedValue == nil and deniedError.code == 'CAPABILITY_UNDECLARED')
    return value.caller .. ':' .. spoofedError.code
  `);
  assert.equal(result, 'synex_consumer:INVALID_SERVICE_CONTEXT');
  engine.global.close();
});

test('network RPC limiter state is fenced by source generation', async () => {
  const engine = await createKernelEngine(['foundation', 'registries', 'messaging']);
  try {
    const result = await engine.doString(`
      local handlers, consumed, purged = {}, {}, {}
      local platform = setmetatable({
        onNet = function(event, handler) handlers[event] = handler end,
        triggerClientEvent = function() end,
        jsonEncode = function() return '{}' end
      }, { __index = FakePlatform })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rpc-source-generation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'session-old' }))
      local old = assert(players:bindJoined(-1, 42, {
        id = 'session-old', userId = 'user-old', state = 'ACTIVE', version = 1
      }))
      local limiter = {}
      function limiter:consume(key)
        consumed[#consumed + 1] = key
        return nil, foundation.error('RATE_LIMITED', 'fixture')
      end
      function limiter:purge(prefix) purged[#purged + 1] = prefix end
      local security = {
        validateNetworkEnvelope = function() return true, nil end,
        rateLimiter = limiter
      }
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation,
        contracts = { registry = { resolve = function() error('rate gate must run first') end } },
        security = security, owners = owners, players = players, lifecycle = {},
        protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
      })
      messaging.network:bind()
      source = 42
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-old', procedure = 'synex.fixture.read',
        version = '1.0.0', payload = {}
      })
      handlers[SynexProtocol.events.cancel]('request-old')
      messaging.network:purgeSource(42, old.sourceGeneration)
      assert(players:detachSource(old.id, 42, old.sourceGeneration))
      assert(players:removeSession(old.id))
      assert(players:createPending(-2, { sessionId = 'session-new' }))
      local replacement = assert(players:bindJoined(-2, 42, {
        id = 'session-new', userId = 'user-new', state = 'ACTIVE', version = 1
      }))
      handlers[SynexProtocol.events.request]({
        wire = 1, requestId = 'request-new', procedure = 'synex.fixture.read',
        version = '1.0.0', payload = {}
      })
      handlers[SynexProtocol.events.cancel]('request-new')
      assert(consumed[1] == ('rpc:42:%s:ingress'):format(old.sourceGeneration))
      assert(consumed[2] == ('rpc-cancel:42:%s:'):format(old.sourceGeneration))
      assert(consumed[3] == ('rpc:42:%s:ingress'):format(replacement.sourceGeneration))
      assert(consumed[4] == ('rpc-cancel:42:%s:'):format(replacement.sourceGeneration))
      assert(purged[1] == ('rpc:42:%s:'):format(old.sourceGeneration))
      assert(purged[2] == ('rpc-cancel:42:%s:'):format(old.sourceGeneration))
      assert(not purged[1]:find(':' .. replacement.sourceGeneration .. ':', 1, true))
      return table.concat({old.sourceGeneration, replacement.sourceGeneration, #consumed, #purged}, ':')
    `);
    assert.equal(result, '1:3:4:2');
  } finally {
    engine.global.close();
  }
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
    local opened = lifecycle.dependencies:snapshot().providerHealth['synex.fixture'].synex_provider['1']
    assert(opened.health == 'HEALTHY' and opened.circuit == 'OPEN')
    assert(#lifecycle.dependencies:validate() == 1)
    now = now + 5001
    failProvider = false
    assert(messaging.services:call(
      'synex_core', coreEpoch, 'synex.fixture', '^1.0.0', 'read', {}, {}))
    local recovered = lifecycle.dependencies:snapshot().providerHealth['synex.fixture'].synex_provider['1']
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
    security.capabilities:registerManifest('synex_core', {
      capabilities = { request = {} },
      events = { publish = {'synex.fixture.*'}, subscribe = {} }
    })
    security.capabilities:registerManifest('synex_consumer', {
      capabilities = { request = {} },
      events = { publish = {}, subscribe = {'synex.fixture.changed'} }
    })
    security.capabilities:registerManifest('synex_failing_consumer', {
      capabilities = { request = {} },
      events = { publish = {}, subscribe = {'synex.fixture.changed'} }
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

test('session lease acquisition is fenced by the current ready runtime instance', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local calls, expectedOwner, currentBoot = {}, 'instance-a:session-a', 'boot-a'
    local contended, contendedReads = false, 0
    local globalCount, globalLimit, otherCount, otherLimit = 0, 100, 0, 100
    local leaseRows = {
      ['session:user-a'] = {
        owner_id = 'instance-a:session-a', fencing_token = 6,
        valid = 1, lease_capacity_kind = 'session'
      }
    }
    local function capacityKind(name)
      if name:sub(1, 8) == 'session:' then return 'session' end
      if name:sub(1, 10) == 'admission:' then return 'admission' end
      return 'other'
    end
    local function hasParameter(parameters, expected)
      for _, value in ipairs(parameters or {}) do if value == expected then return true end end
      return false
    end
    local adapter = {
      query = function(sql, parameters)
        calls[#calls + 1] = { kind = 'query', sql = sql, parameters = parameters }
        return {{ owner_id = expectedOwner, fencing_token = 7, valid = 1 }}
      end,
      scalar = function() return nil end,
      insert = function() return 0 end,
      update = function(sql, parameters)
        calls[#calls + 1] = { kind = 'update', sql = sql, parameters = parameters }
        return 1
      end,
      transaction = function() return true end,
      startTransaction = function(handler)
        return handler(function(sql, parameters)
          calls[#calls + 1] = { kind = 'transaction', sql = sql, parameters = parameters }
          if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
            if contended then
              contendedReads = contendedReads + 1
              return {{ owner_id = 'instance-b:session-b', fencing_token = 1,
                valid = 1, lease_capacity_kind = capacityKind(parameters[1]) }}
            end
            local row = leaseRows[parameters[1]]
            return row and {{ owner_id = row.owner_id, fencing_token = row.fencing_token,
              valid = row.valid, lease_capacity_kind = row.lease_capacity_kind }} or {}
          end
          if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
          if sql:find('synex_instance_boots', 1, true) then
            return hasParameter(parameters, currentBoot) and {{ boot_id = currentBoot }} or {}
          end
          if sql:find('INSERT IGNORE INTO', 1, true)
              and sql:find('synex_cluster_leases', 1, true) then
            if leaseRows[parameters[1]] then return { affectedRows = 0 } end
            leaseRows[parameters[1]] = {
              owner_id = parameters[2], fencing_token = 1, valid = 1,
              lease_capacity_kind = capacityKind(parameters[1])
            }
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_leases', 1, true) then
            if sql:find('terminal_compaction_at', 1, true) then
              local row = leaseRows[parameters[5]]
              if not row then return { affectedRows = 0 } end
              row.owner_id, row.fencing_token, row.valid =
                parameters[3], row.fencing_token + 1, 1
              return { affectedRows = 1 }
            end
            return { affectedRows = 1 }
          end
          if sql:find('FROM', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
            return {{ entry_count = globalCount, global_limit = globalLimit }}
          end
          if sql:find('FROM', 1, true)
              and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
            return {{ lease_capacity_kind = parameters[1], entry_count = otherCount,
              kind_limit = otherLimit }}
          end
          if sql:find('UPDATE', 1, true)
              and sql:find('synex_cluster_lease_capacity', 1, true) then
            globalCount = globalCount + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true)
              and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
            otherCount = otherCount + 1
            return { affectedRows = 1 }
          end
          error('unexpected lease fixture SQL')
        end)
      end
    }
    local leases = SynexCoreFactories.persistence({
      platform = FakePlatform,
      foundation = foundation,
      db = adapter,
      instanceId = 'instance-a'
    }).leases

    local lease = assert(leases:acquire(
      'session:user-a', 'instance-a:session-a', 45, 'instance-a', 'boot-a'))
    assert(lease.fencingToken == 7 and lease.requesterInstanceId == 'instance-a'
      and lease.requesterBootId == 'boot-a' and #calls == 5)
    assert(calls[1].sql:find('synex_instances', 1, true)
      and calls[1].sql:find("ready", 1, true) and calls[1].sql:find('FOR UPDATE', 1, true))
    assert(calls[2].sql:find('synex_instance_boots', 1, true)
      and calls[2].sql:find('FOR UPDATE', 1, true))
    assert(calls[3].sql:find('SELECT', 1, true)
      and calls[3].sql:find('synex_cluster_leases', 1, true)
      and calls[3].sql:find('FOR UPDATE', 1, true))
    assert(calls[4].sql:find('UPDATE', 1, true)
      and calls[4].sql:find('fencing_token', 1, true)
      and calls[4].sql:find('terminal_compaction_at', 1, true))
    assert(calls[5].sql:find('SELECT', 1, true)
      and calls[5].sql:find('FOR UPDATE', 1, true))

    local beforeInvalid = #calls
    local invalid, invalidError = leases:acquire(
      'session:user-a', 'instance-a:session-a', 45, 'instance-b', 'boot-a')
    assert(invalid == nil and invalidError.code == 'INVALID_LEASE_AUTHORITY')
    assert(#calls == beforeInvalid)

    local missingBoot, missingBootError = leases:acquire(
      'session:user-a', 'instance-a:session-a', 45, 'instance-a')
    assert(missingBoot == nil and missingBootError.code == 'INVALID_LEASE_AUTHORITY')
    assert(#calls == beforeInvalid)

    local unfenced, unfencedError = leases:acquire(
      'session:user-a', 'instance-a:session-a', 45)
    assert(unfenced == nil and unfencedError.code == 'INVALID_LEASE_AUTHORITY')
    local unfencedRenewed, unfencedRenewError = leases:renew({
      name = 'session:user-a', owner = 'instance-a:session-a', fencingToken = 7, ttlSeconds = 45
    })
    assert(unfencedRenewed == nil and unfencedRenewError.code == 'INVALID_LEASE_AUTHORITY')
    assert(#calls == beforeInvalid)

    currentBoot = 'boot-b'
    local renewed, renewError = leases:renew(lease)
    assert(renewed == nil and renewError.code == 'LEASE_LOST' and #calls == 7)
    assert(calls[7].sql:find('synex_instance_boots', 1, true)
      and calls[7].parameters[1] == 'instance-a' and calls[7].parameters[2] == 'boot-a')
    local stale, staleError = leases:acquire(
      'session:user-a', 'instance-a:session-a', 45, 'instance-a', 'boot-a')
    assert(stale == nil and staleError.code == 'LEASE_BUSY' and #calls == 9)

    currentBoot = 'boot-a'
    contended = true
    local beforeContention = #calls
    local collided, collisionError = leases:acquire(
      'session:user-b', 'instance-a:session-b', 45, 'instance-a', 'boot-a')
    assert(collided == nil and collisionError.code == 'LEASE_BUSY'
      and collisionError.retryable == true and #calls == beforeContention + 3)
    assert(calls[beforeContention + 3].sql:find('SELECT', 1, true)
      and calls[beforeContention + 3].sql:find('FOR UPDATE', 1, true))
    contended = false

    expectedOwner = 'instance-a:saga-a'
    local beforeGeneric = #calls
    local generic = assert(leases:acquire('generic:test', expectedOwner, 45))
    assert(generic.owner == expectedOwner and #calls == beforeGeneric + 7
      and globalCount == 1 and otherCount == 1)
    assert(calls[beforeGeneric + 2].sql:find('INSERT IGNORE INTO', 1, true))
    for index = beforeGeneric + 1, beforeGeneric + 7 do
      assert(not calls[index].sql:find('synex_instances', 1, true))
    end
    return table.concat({lease.fencingToken, invalidError.code, missingBootError.code,
      unfencedError.code, unfencedRenewError.code, renewError.code, staleError.code, generic.owner}, ':')
  `);
  assert.equal(result,
    '7:INVALID_LEASE_AUTHORITY:INVALID_LEASE_AUTHORITY:INVALID_LEASE_AUTHORITY:'
    + 'INVALID_LEASE_AUTHORITY:LEASE_LOST:LEASE_BUSY:instance-a:saga-a');
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

test('migration worker leases use restart-unique owners and reject delayed reacquisition', async () => {
  const engine = await createKernelEngine(['foundation', 'persistence']);
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    foundation.configureIds('migration-owner-fence')
    local lease = { owner = nil, token = 0, valid = false }
    local adapter = {
      query = function()
        return lease.owner and {{ owner_id = lease.owner, fencing_token = lease.token,
          valid = lease.valid and 1 or 0 }} or {}
      end,
      scalar = function() return nil end,
      insert = function() return 0 end,
      update = function(sql, parameters)
        if sql:find('fencing_token', 1, true) and sql:find(' + 1', 1, true) then
          if not lease.valid or lease.owner == parameters[4] then
            lease.owner, lease.token, lease.valid = parameters[1], lease.token + 1, true
            return 1
          end
          return 0
        end
        if sql:find('INSERT IGNORE', 1, true) then
          if not lease.owner then
            lease.owner, lease.token, lease.valid = parameters[2], 1, true
            return 1
          end
          return 0
        end
        if sql:find('SET ', 1, true) and sql:find('expires_at', 1, true)
          and sql:find('CURRENT_TIMESTAMP', 1, true) then
          if lease.owner == parameters[2] and lease.token == parameters[3] then
            lease.valid = false
            return 1
          end
          return 0
        end
        return 1
      end,
      transaction = function() return true end
    }
    local bootA = SynexCoreFactories.persistence({
      platform = FakePlatform, foundation = foundation, db = adapter, instanceId = 'instance-a'
    }).migrations
    assert(bootA:acquireLease() == 1)
    local ownerA = lease.owner
    lease.valid = false
    local bootB = SynexCoreFactories.persistence({
      platform = FakePlatform, foundation = foundation, db = adapter, instanceId = 'instance-a'
    }).migrations
    assert(bootB:acquireLease() == 2)
    local ownerB = lease.owner
    assert(ownerA ~= ownerB)
    assert(ownerA:find('instance-a:migration:', 1, true) == 1
      and ownerB:find('instance-a:migration:', 1, true) == 1)
    local stale, staleError = bootA:acquireLease()
    assert(stale == nil and staleError.code == 'MIGRATION_LEASE_BUSY')
    assert(bootA:releaseLease())
    assert(lease.owner == ownerB and lease.token == 2 and lease.valid == true)
    return staleError.code
  `);
  assert.equal(result, 'MIGRATION_LEASE_BUSY');
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
    local failRelease, leaseOwner = false, nil
    local adapter = {
      query = function()
        return {{ owner_id = leaseOwner, fencing_token = 4, valid = 1 }}
      end,
      scalar = function() return nil end,
      insert = function() return 0 end,
      update = function(sql, parameters)
        if failRelease then return nil, { code = 'PORT_FAILED' } end
        if sql:find('fencing_token', 1, true) and sql:find(' + 1', 1, true) then
          leaseOwner = parameters[1]
          assert(leaseOwner:find('instance-a:migration:', 1, true) == 1 and #leaseOwner <= 96)
        end
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
