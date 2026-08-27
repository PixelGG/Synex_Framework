import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const lifecyclePath = path.join(
  process.cwd(), 'resources', 'synex_entities', 'server', 'authority_lifecycle.lua',
);

test('recovery worker advances one bounded reconciliation and retention batch per tick', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(lifecyclePath, 'utf8'));
    const result = await engine.doString(String.raw`
      local authority = {
        instanceId = 'instance_0001', leaseSeconds = 30, resourceEpoch = 4,
        serverScope = 'roleplay-main', token = 'authority_0001',
      }
      local reconciliationCalls, purgeCalls, listCalls = 0, 0, 0
      local health = { reason = nil }
      local healthTransitions = {}
      local repository = {
        reconcileBootAuthority = function(scope, current)
          reconciliationCalls = reconciliationCalls + 1
          assert(scope == 'roleplay-main' and current == authority)
          if reconciliationCalls == 1 then
            return { conflicts = 0, reconciled = 16, remaining = 2 }
          end
          return { conflicts = 0, reconciled = 2, remaining = 0 }
        end,
        purgeRecoveryHistory = function(limit)
          purgeCalls = purgeCalls + 1
          assert(limit == 16)
          if purgeCalls == 3 then
            return nil, { code = 'RETENTION_FAILED', retryable = true }
          end
          return { purged = 1, remaining = math.max(0, 2 - purgeCalls) }
        end,
        listRecoverable = function(scope, _, _, limit)
          listCalls = listCalls + 1
          assert(scope == 'roleplay-main' and limit == 16)
          return {}
        end,
      }
      local service = {}
      SynexEntityAuthorityLifecycle.attach(service, {
        activateReserved = function() error('no recovery rows expected') end,
        authorityRepository = repository,
        caller = function() return 'synex_entities' end,
        checkpointRecord = function() error('checkpoint not expected') end,
        config = {
          recoveryBaseDelaySeconds = 2, recoveryBatchSize = 16,
          recoveryJitterSeconds = 3, recoveryMaxAttempts = 5,
          recoveryMaxDelaySeconds = 60, recoveryStormThreshold = 4,
          recoveryWindowSeconds = 300,
        },
        coreRef = {},
        entityRuntime = {},
        extensionRegistry = {},
        extensionOperations = {},
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        foundation = {
          setHealth = function(state, reason)
            health.reason = reason
            healthTransitions[#healthTransitions + 1] = state .. ':' .. reason
          end,
        },
        getAuthority = function() return authority end,
        getGameTimer = function() return 0 end,
        health = health,
        idempotent = function() error('idempotency not expected') end,
        lanes = {}, nextId = function() error('ID allocation not expected') end,
        normalizeDefinition = function() return {} end,
        observability = {
          gauge = function() return true end,
          increment = function() return true end,
          timer = function() return function() return 0 end end,
        },
        registry = {}, requireAuthority = function() return authority end,
        resourceName = 'synex_entities',
        setAuthority = function(value) authority = value end,
        spawnAdmission = {}, validation = {},
      })

      local first = assert(service.runRecovery({ traceId = 'trace_recovery_tick_01' }))
      assert(first.reconciled == 16 and first.reconciliationRemaining == 2)
      assert(first.purged == 1 and first.attempted == 0)
      assert(health.reason == 'AUTHORITY_RECONCILIATION_BACKLOG')
      local second = assert(service.runRecovery({ traceId = 'trace_recovery_tick_02' }))
      assert(second.reconciled == 2 and second.reconciliationRemaining == 0)
      assert(second.purged == 1 and second.attempted == 0)
      assert(reconciliationCalls == 2 and purgeCalls == 2 and listCalls == 2)
      assert(healthTransitions[1]:find('AUTHORITY_RECONCILIATION_BACKLOG', 1, true))
      assert(healthTransitions[2]:find('reconciliation is current', 1, true))
      local third, retentionError = service.runRecovery({ traceId = 'trace_recovery_tick_03' })
      assert(third == nil and retentionError.code == 'RETENTION_FAILED')
      assert(reconciliationCalls == 3 and purgeCalls == 3 and listCalls == 2)
      return reconciliationCalls .. ':' .. purgeCalls .. ':' .. listCalls
    `) as string;
    assert.equal(result, '3:3:2');
  } finally {
    engine.global.close();
  }
});

test('heartbeat detaches all local persistent entities on partial or complete lease loss', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(lifecyclePath, 'utf8'));
    const result = await engine.doString(String.raw`
      local authority = { token = 'authority_0001' }
      local renewed = 1
      local deletes, conflicts = 0, 0
      local records = {
        { entityId = 'entity_0001', generation = 3, persistent = true,
          authorityLeaseGeneration = 7 },
        { entityId = 'entity_0002', generation = 8, persistent = true,
          authorityLeaseGeneration = 9 },
        { entityId = 'temporary_0001', generation = 1, persistent = false },
      }
      local service = {}
      SynexEntityAuthorityLifecycle.attach(service, {
        activateReserved = function() end,
        authorityRepository = {
          heartbeat = function(current)
            assert(current == authority)
            return { renewed = renewed }
          end,
        },
        caller = function() return 'synex_entities' end,
        checkpointRecord = function() end,
        config = {}, coreRef = {}, extensionRegistry = {}, extensionOperations = {},
        entityRuntime = {
          delete = function(record)
            assert(record.persistent == true)
            deletes = deletes + 1
            return true
          end,
        },
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        foundation = {
          setHealth = function(_, reason)
            if reason == 'AUTHORITY_LEASE_CONFLICT' then conflicts = conflicts + 1 end
          end,
        },
        getAuthority = function() return authority end,
        getGameTimer = function() return 0 end,
        idempotent = function() end, lanes = {}, nextId = function() end,
        normalizeDefinition = function() end,
        observability = {
          gauge = function() return true end,
          increment = function() return true end,
          timer = function() return function() return 0 end end,
        },
        registry = { all = function() return records end, count = function() return 1 end },
        requireAuthority = function() return authority end,
        resourceName = 'synex_entities',
        setAuthority = function(value) authority = value end,
        spawnAdmission = {}, validation = {},
      })

      local value, partial = service.heartbeat({ traceId = 'trace_heartbeat_partial_01' })
      assert(value == nil and partial.code == 'AUTHORITY_LEASE_CONFLICT')
      assert(partial.details.expected == 2 and partial.details.renewed == 1)
      assert(deletes == 2 and authority == nil)

      authority = { token = 'authority_0002' }
      renewed = 0
      local value2, complete = service.heartbeat({ traceId = 'trace_heartbeat_complete_01' })
      assert(value2 == nil and complete.code == 'AUTHORITY_LEASE_CONFLICT')
      assert(complete.details.expected == 2 and complete.details.renewed == 0)
      assert(deletes == 4 and conflicts == 2 and authority == nil)
      return deletes .. ':' .. conflicts
    `) as string;
    assert.equal(result, '4:2');
  } finally {
    engine.global.close();
  }
});
