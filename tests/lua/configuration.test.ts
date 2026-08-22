import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function engineWith(...modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) await load(engine, `core/synex_core/server/${module}.lua`);
  await engine.doString(`
    FakePlatform = {
      print = function() end,
      nowGame = function() return 1000 end,
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end
    }
    function ValidRuntimeConfig()
      return {
        environment = 'production', strict = true, instanceId = '',
        database = {
          minimumOxmysqlVersion = '2.14.1', queryWarnMs = 250, queryTimeoutMs = 5000,
          deadlockRetries = 2, migrationLeaseSeconds = 30
        },
        connections = {
          pendingTtlMs = 120000, gateTimeoutMs = 10000, duplicatePolicy = 'deny_new',
          allowlistRequired = false, clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000,
          queueEnabled = false, queueUpdateMs = 1000, queueTimeoutMs = 120000,
          maximumQueued = 128, maximumActiveSessions = 128, queueReservedSlots = 0,
          queueStaffPriority = 1000, queueReconnectPriority = 500, queueReconnectGraceMs = 60000,
          queueStaffAce = 'synex.queue.staff', maintenanceMode = false,
          maintenanceMessage = 'Synex is currently in maintenance mode.',
          maintenanceBypassAce = 'synex.maintenance.bypass'
        },
        rpc = {
          timeoutMs = 5000, maximumTimeoutMs = 15000, maximumPendingPerSource = 16,
          maximumPayloadBytes = 32768, rate = 12, burst = 24
        },
        events = { maximumQueueDepth = 1024 },
        logging = { level = 'info', pretty = false },
        privacy = { identifierSaltConvar = 'synex_identifier_salt', diagnosticIdentifierPrefix = 8 },
        retention = {
          workerIntervalMs = 3600000, batchSize = 250,
          audit = { mode = 'retain_forever', archiveAfterDays = 365 },
          financial = { mode = 'retain_forever', archiveAfterDays = 365 }
        },
        features = { durableEvents = true, sagas = true, stateReplication = true }
      }
    end
  `);
  return engine;
}

test('runtime configuration rejects unknown keys and invalid cross-field values', async () => {
  const engine = await engineWith('foundation', 'configuration');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local validator = SynexCoreFactories.configuration({ foundation = foundation })
    local valid = ValidRuntimeConfig()
    assert(validator:validateRuntime(valid))
    valid.rpc.timeoutMs = valid.rpc.maximumTimeoutMs + 1
    local _, rangeError = validator:validateRuntime(valid)
    assert(rangeError.code == 'INVALID_CONFIGURATION')
    assert(rangeError.details.path == '$.rpc.timeoutMs')
    valid = ValidRuntimeConfig()
    valid.database.untrackedOption = true
    local _, unknownError = validator:validateRuntime(valid)
    assert(unknownError.details.path == '$.database.untrackedOption')
    valid = ValidRuntimeConfig()
    valid.connections.queueReservedSlots = valid.connections.maximumActiveSessions
    local _, reservedError = validator:validateRuntime(valid)
    assert(reservedError.details.path == '$.connections.queueReservedSlots')
    valid = ValidRuntimeConfig()
    valid.connections.maintenanceMessage = string.char(10)
    local _, messageError = validator:validateRuntime(valid)
    assert(messageError.details.path == '$.connections.maintenanceMessage')
    valid = ValidRuntimeConfig()
    valid.connections.duplicatePolicy = 'kick_old'
    assert(validator:validateRuntime(valid))
    valid.connections.duplicatePolicy = 'allow'
    assert(validator:validateRuntime(valid))
    valid = ValidRuntimeConfig()
    valid.retention.audit.mode = 'delete'
    local _, retentionModeError = validator:validateRuntime(valid)
    assert(retentionModeError.details.path == '$.retention.audit.mode')
    valid = ValidRuntimeConfig()
    valid.retention.batchSize = 1001
    local _, retentionBatchError = validator:validateRuntime(valid)
    assert(retentionBatchError.details.path == '$.retention.batchSize')
    valid = ValidRuntimeConfig()
    valid.retention.financial.archiveAfterDays = 0
    local _, retentionAgeError = validator:validateRuntime(valid)
    assert(retentionAgeError.details.path == '$.retention.financial.archiveAfterDays')
    valid = ValidRuntimeConfig()
    valid.retention.audit.mode = 'archive'
    valid.retention.financial.mode = 'archive'
    assert(validator:validateRuntime(valid))
    return table.concat({rangeError.code, unknownError.details.path, reservedError.details.path}, ':')
  `);
  assert.equal(result, 'INVALID_CONFIGURATION:$.database.untrackedOption:$.connections.queueReservedSlots');
  engine.global.close();
});

test('effective ConVar configuration is revalidated without silent clamping', async () => {
  const engine = await engineWith('foundation', 'configuration', 'runtime_configuration');
  const result = await engine.doString(`
    local overrides = { synex_queue_reserved_slots = '128', synex_maintenance = '0' }
    local platform = {
      print = function() end, nowGame = function() return 1000 end,
      jsonEncode = function() return '{}' end, jsonDecode = function() return {} end,
      getConvar = function(name, fallback) return overrides[name] or tostring(fallback) end
    }
    local foundation = SynexCoreFactories.foundation({ platform = platform })
    local validator = SynexCoreFactories.configuration({ foundation = foundation })
    local effective = SynexCoreFactories.runtimeConfiguration({
      platform = platform, configuration = validator
    })
    local function configured()
      local value = ValidRuntimeConfig()
      value.instanceId = 'test_instance'
      return value
    end
    local invalid, reservedError = effective:apply(configured())
    assert(invalid == nil and reservedError:find('queueReservedSlots', 1, true))
    overrides.synex_queue_reserved_slots = '0'
    overrides.synex_maintenance = '2'
    local invalidMaintenance, maintenanceError = effective:apply(configured())
    assert(invalidMaintenance == nil and maintenanceError:find('synex_maintenance', 1, true))
    overrides.synex_maintenance = '1'
    local valid = assert(effective:apply(configured()))
    assert(valid.connections.maintenanceMode == true and valid.connections.queueReservedSlots == 0)
    for _, malformed in ipairs({'abc', '1.5', ' 1', '1 '}) do
      overrides.synex_queue_staff_priority = malformed
      local rejected, malformedError = effective:apply(configured())
      assert(rejected == nil and malformedError:find('synex_queue_staff_priority', 1, true))
    end
    overrides.synex_queue_staff_priority = nil
    for _, malformed in ipairs({'true', '1.0', ' 0'}) do
      overrides.synex_maintenance = malformed
      local rejected, malformedError = effective:apply(configured())
      assert(rejected == nil and malformedError:find('synex_maintenance', 1, true))
    end
    return table.concat({overrides.synex_queue_reserved_slots, '1', tostring(valid.connections.maintenanceMode)}, ':')
  `);
  assert.equal(result, '0:1:true');
  engine.global.close();
});

test('bootstrap rejects malformed strict-mode ConVars before configuration can fail open', async () => {
  const engine = await engineWith('bootstrap');
  const result = await engine.doString(`
    SynexCoreFactories.foundation = function()
      return {
        loadJson = function(_, _, path)
          if path == 'config/default.json' then return { strict = true }, nil end
          return {}, nil
        end
      }
    end
    SynexCoreFactories.configuration = function() return {} end
    SynexCoreFactories.resourceManifest = function() return {} end
    local platform = {
      currentResource = function() return 'synex_core' end,
      getConvar = function(name, fallback)
        if name == 'synex_strict' then return '2' end
        return fallback
      end
    }
    local ok, failure = pcall(SynexCoreFactories.bootstrap, { platform = platform })
    assert(ok == false and tostring(failure):find('synex_strict must be exactly 0 or 1', 1, true))
    return 'fail-closed'
  `);
  assert.equal(result, 'fail-closed');
  engine.global.close();
});

test('capability policy validation rejects duplicate and malformed wildcard grants', async () => {
  const engine = await engineWith('foundation', 'configuration');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local validator = SynexCoreFactories.configuration({ foundation = foundation })
    assert(validator:validateCapabilityPolicy({
      default = { allow = {}, deny = {} },
      resources = { synex_fixture = { allow = {'synex.fixture.*'}, deny = {} } }
    }))
    local _, duplicate = validator:validateCapabilityPolicy({
      default = { allow = {'synex.fixture.read', 'synex.fixture.read'}, deny = {} }, resources = {}
    })
    local _, wildcard = validator:validateCapabilityPolicy({
      default = { allow = {'synex.*.read'}, deny = {} }, resources = {}
    })
    for _, malformed in ipairs({'synex..read', 'synex-', 'synex._read'}) do
      local _, separator = validator:validateCapabilityPolicy({
        default = { allow = {malformed}, deny = {} }, resources = {}
      })
      assert(separator.code == 'INVALID_CONFIGURATION')
    end
    assert(duplicate.code == 'INVALID_CONFIGURATION')
    assert(wildcard.code == 'INVALID_CONFIGURATION')
    return duplicate.details.path .. ':' .. wildcard.details.path
  `);
  assert.equal(result, '$.default.allow[2]:$.default.allow[1]');
  engine.global.close();
});

test('capability denials reach the bounded audit sink without trusting caller context', async () => {
  const engine = await engineWith('foundation', 'security');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = { default = { allow = {}, deny = {} }, resources = {} }
    })
    security.capabilities:registerManifest('synex_fixture', { capabilities = { request = {} } })
    local count, captured = 0, nil
    assert(security.capabilities:setAuditSink(function(entry)
      count = count + 1
      captured = entry
      return true
    end))
    local _, first = security.capabilities:check('synex_fixture', 'synex.accounts.mint', {
      traceId = 'trusted_trace', operation = 'fixture.call', actorId = 'spoofed'
    })
    local _, second = security.capabilities:check('synex_fixture', 'synex.accounts.mint', {
      traceId = 'trusted_trace', operation = 'fixture.call'
    })
    assert(first.code == 'CAPABILITY_UNDECLARED' and second.code == 'CAPABILITY_UNDECLARED')
    assert(count == 1)
    assert(captured.actorId == 'synex_fixture')
    assert(captured.action == 'capability.denied')
    assert(captured.traceId == 'trusted_trace')
    return captured.context.reason
  `);
  assert.equal(result, 'undeclared');
  engine.global.close();
});

test('disabled durable-event and saga feature flags fail closed before database access', async () => {
  const engine = await engineWith('foundation', 'persistence', 'reliability');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local touched = false
    local db = setmetatable({}, { __index = function()
      return function() touched = true return nil, foundation.error('UNEXPECTED_DATABASE_ACCESS', 'unexpected') end
    end })
    local reliability = SynexCoreFactories.reliability({
      foundation = foundation, platform = FakePlatform, database = db,
      instanceId = 'test', sha256 = function() return string.rep('0', 64) end,
      features = { durableEvents = false, sagas = false }
    })
    local _, outboxError = reliability.outbox:enqueue({
      aggregateType = 'fixture', aggregateId = '1', eventType = 'fixture.created'
    })
    local _, sagaError = reliability.sagas:start('fixture', 'correlation', {})
    assert(outboxError.code == 'FEATURE_DISABLED')
    assert(sagaError.code == 'FEATURE_DISABLED')
    assert(not touched)
    return outboxError.code .. ':' .. sagaError.code
  `);
  assert.equal(result, 'FEATURE_DISABLED:FEATURE_DISABLED');
  engine.global.close();
});

test('disabled state replication rejects replicated definitions before owner state is registered', async () => {
  const engine = await engineWith('foundation', 'registries', 'contracts', 'security', 'state');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local epoch = registries.owners:activate('synex_fixture')
    local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
    local security = SynexCoreFactories.security({
      platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
      policy = { default = { allow = {}, deny = {} }, resources = {} }
    })
    local state = SynexCoreFactories.state({
      platform = FakePlatform, foundation = foundation, contracts = contracts,
      owners = registries.owners, security = security, coreResource = 'synex_core',
      replicationEnabled = false, replicate = function() error('must not replicate') end
    })
    local token, err = state:define('synex_fixture', epoch, {
      name = 'synex_fixture.enabled', scope = 'global', authority = 'owner',
      schema = { type = 'boolean' }, replicated = true, sensitive = false
    })
    assert(token == nil and err.code == 'FEATURE_DISABLED')
    return err.code
  `);
  assert.equal(result, 'FEATURE_DISABLED');
  engine.global.close();
});

test('logger level can only be configured to a supported structured level', async () => {
  const engine = await engineWith('foundation');
  const result = await engine.doString(`
    local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
    assert(foundation.logger:configure('debug'))
    local ok, err = foundation.logger:configure('verbose')
    assert(ok == nil and err.code == 'INVALID_LOG_LEVEL')
    return err.code
  `);
  assert.equal(result, 'INVALID_LOG_LEVEL');
  engine.global.close();
});
