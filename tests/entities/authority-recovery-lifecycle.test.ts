import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(resource, relativePath), 'utf8');
}

test('recovery lifecycle records exactly one fenced outcome with bounded duration and policy', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await source('server/authority_lifecycle.lua'));
    const result = await engine.doString(String.raw`
      local timerValues = { 1000, 1125, 2000, 2075, 3000, 3050 }
      local timerIndex = 0
      local failureCalls, successCalls, registryUpdates, compensationDeletes = 0, 0, 0, 0
      local activationMode = 'failure'
      local authority = {
        serverScope = 'roleplay-main', instanceId = 'instance_001',
        token = 'authority_001', resourceEpoch = 4, leaseSeconds = 30
      }
      local repository = {
        claimMaterialization = function(entityId, resourceOwner, current, recovering)
          assert(entityId == 'entity_0001' and resourceOwner == 'synex_vehicles')
          assert(current == authority and recovering == true)
          return {
            definition = { entityId = entityId }, generation = 6,
            leaseGeneration = 9, version = 12
          }
        end,
        bindingFor = function() return nil end,
        recordRecoveryFailure = function(entityId, generation, current, code, policy)
          failureCalls = failureCalls + 1
          assert(entityId == 'entity_0001' and generation == 6 and current == authority)
          if failureCalls == 1 then
            assert(code == 'SPAWN_TIMEOUT' and policy.durationMs == 125)
          else
            assert(code == 'PERSISTENCE_UNAVAILABLE' and policy.durationMs == 50)
          end
          assert(policy.maxAttempts == 5 and policy.windowSeconds == 300)
          assert(policy.baseDelaySeconds == 2 and policy.maxDelaySeconds == 60)
          assert(policy.jitterSeconds == 3)
          return { attempts = 2, circuit = 'open', version = 13 }
        end,
        recordRecoverySuccess = function(entityId, generation, current, durationMs)
          successCalls = successCalls + 1
          assert(entityId == 'entity_0001' and generation == 6 and current == authority)
          if activationMode == 'commit_failure' then
            assert(durationMs == 50)
            return nil, { code = 'PERSISTENCE_UNAVAILABLE', message = 'offline' }
          end
          assert(durationMs == 75)
          return { attempts = 2, status = 'active', version = 14 }
        end,
      }
      local service = {}
      SynexEntityAuthorityLifecycle.attach(service, {
        activateReserved = function()
          if activationMode == 'failure' then
            return nil, { code = 'SPAWN_TIMEOUT', message = 'timed out' }
          end
          return { entityId = 'entity_0001', generation = 6 }, { netId = 22 }
        end,
        authorityRepository = repository,
        caller = function() return 'synex_vehicles' end,
        checkpointRecord = function() error('checkpoint should not run') end,
        config = {
          recoveryBaseDelaySeconds = 2,
          recoveryJitterSeconds = 3,
          recoveryMaxAttempts = 5,
          recoveryMaxDelaySeconds = 60,
          recoveryWindowSeconds = 300,
        },
        coreRef = {},
        entityRuntime = {
          delete = function()
            compensationDeletes = compensationDeletes + 1
            return true
          end,
          queueCleanup = function() error('verified delete must not queue') end,
        },
        extensionRegistry = {},
        extensionOperations = { cleanupEntity = function() return true end },
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        foundation = {},
        getAuthority = function() return authority end,
        getGameTimer = function()
          timerIndex = timerIndex + 1
          return timerValues[timerIndex]
        end,
        idempotent = function() error('idempotency should not run') end,
        lanes = {
          entityKey = function(entityId) return entityId end,
          with = function(_, _, _, handler) return handler() end,
        },
        nextId = function() error('ID allocation should not run') end,
        normalizeDefinition = function() return {} end,
        observability = {
          audit = function() return true end,
          before = function() return true end,
          event = function() return true end,
          gauge = function() return true end,
          increment = function() return true end,
          timer = function()
            return function() return 0 end
          end,
        },
        registry = {
          count = function() return 1 end,
          update = function(entityId, generation, changes)
            registryUpdates = registryUpdates + 1
            assert(entityId == 'entity_0001' and generation == 6 and changes.version == 14)
            return { entityId = entityId, generation = generation, version = changes.version }
          end,
        },
        requireAuthority = function() return authority end,
        resourceName = 'synex_entities',
        setAuthority = function() error('authority should not change') end,
        spawnAdmission = {
          withReservation = function(_, _, _, handler) return handler() end,
        },
        validation = {},
      })

      local definition = {
        entityId = 'entity_0001', generation = 5,
        resourceOwner = 'synex_vehicles'
      }
      local failed, failureError = service.recoverOne(definition, {
        traceId = 'trace_recovery_failure_001'
      })
      assert(failed == nil and failureError.code == 'SPAWN_TIMEOUT')
      assert(failureCalls == 1 and successCalls == 0 and registryUpdates == 0)

      activationMode = 'success'
      assert(service.recoverOne(definition, { traceId = 'trace_recovery_success_001' }))
      assert(failureCalls == 1 and successCalls == 1 and registryUpdates == 1)
      activationMode = 'commit_failure'
      local committed, commitError = service.recoverOne(definition, {
        traceId = 'trace_recovery_commit_failure_001'
      })
      assert(committed == nil and commitError.code == 'PERSISTENCE_UNAVAILABLE')
      assert(failureCalls == 2 and successCalls == 2 and registryUpdates == 1)
      assert(compensationDeletes == 1)
      return failureCalls .. ':' .. successCalls .. ':' .. registryUpdates
        .. ':' .. compensationDeletes
    `) as string;
    assert.equal(result, '2:2:1:1');
  } finally {
    engine.global.close();
  }
});

test('recovery activation skips generic failure persistence and config bounds every policy input', async () => {
  const [service, lifecycle, config] = await Promise.all([
    source('server/authority_service.lua'),
    source('server/authority_lifecycle.lua'),
    source('server/bootstrap_config.lua'),
  ]);
  assert.equal((service.match(/authorityRepository\.markFailed\(/gu) ?? []).length, 4);
  assert.match(lifecycle, /recordRecoveryFailure\(/u);
  assert.match(lifecycle, /recordRecoverySuccess\(/u);
  for (const name of [
    'recovery_base_delay_seconds',
    'recovery_jitter_seconds',
    'recovery_max_attempts',
    'recovery_max_delay_seconds',
    'recovery_window_seconds',
  ]) {
    assert.match(config, new RegExp(`synex_entities_${name}`, 'u'));
  }
  assert.match(config, /config\.recoveryMaxDelaySeconds = math\.max\(/u);
  assert.match(config, /config\.recoveryJitterSeconds = math\.min\(/u);
});
