import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const repositoryPaths = [
  'authority_recovery_repository.lua',
  'authority_inspection_repository.lua',
  'authority_diagnostics_repository.lua',
  'authority_repository.lua',
].map((file) => path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  file,
));

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const repositoryPath of repositoryPaths) {
      await engine.doString(await readFile(repositoryPath, 'utf8'));
    }
    return await engine.doString(assertions) as T;
  } finally {
    engine.global.close();
  }
}

test('authority repository is UTC-fenced, bounded, and exposes the complete private port', async () => {
  const sources = await Promise.all(repositoryPaths.map((file) => readFile(file, 'utf8')));
  const source = sources.join('\n');
  for (const moduleSource of sources) {
    assert.ok(moduleSource.split(/\r?\n/u).length <= 700);
  }
  for (const method of [
    'reconcileBootAuthority', 'heartbeat', 'releaseAuthority',
    'recordRecoveryFailure', 'recordRecoverySuccess', 'listRecoverable',
    'getOwnerDeletionSummary', 'applyOwnerDeletion', 'inspectAuthority',
    'inspectRecovery', 'purgeRecoveryHistory', 'inspectEntity', 'queryDefinitions',
    'diagnosticSnapshot',
  ]) {
    assert.match(source, new RegExp(`function repository\\.${method}\\(`, 'u'), method);
  }
  assert.doesNotMatch(source, /UTC_TIMESTAMP/u);
  assert.match(source, /`lease_until` > CURRENT_TIMESTAMP\(6\)/u);
  assert.match(source, /`authority_token` = \? AND `resource_epoch` = \?/u);
  assert.match(source, /TIMESTAMPADD\(SECOND, -\?, CURRENT_TIMESTAMP\(6\)\)/u);
  assert.match(source, /delaySeconds = math\.min\(policy\.maxDelaySeconds, delaySeconds \+ jitter\)/u);
  assert.match(source, /`recovery_circuit_state` = 'paused'/u);
  assert.match(source, /`recovery_circuit_state` = 'open'/u);
  assert.match(source, /`recovery_circuit_state` = CASE WHEN \? = 1[\s\S]*?'half_open'/u);
  assert.match(source, /`synex_entity_recovery_history`/u);
  assert.match(source, /`retain_until` <= CURRENT_TIMESTAMP\(6\)/u);
  assert.match(source, /COALESCE\(`next_recovery_at`,[\s\S]*?`entity_id` > \?/u);
  assert.match(source, /ORDER BY COALESCE\(`next_recovery_at`/u);
  assert.match(source, /LIMIT \? FOR UPDATE/u);
  assert.match(source, /NOT EXISTS \(SELECT 1 FROM `synex_entity_authority_leases`/u);
  assert.match(source, /l\.`instance_id` <> \? OR l\.`authority_token` <> \?/u);
  assert.match(source, /ON DUPLICATE KEY UPDATE `entity_id` = `entity_id`/u);
  assert.doesNotMatch(source, /DELETE FROM `synex_entities`/u);
});

test('authority heartbeat and release preserve the complete runtime fence', async () => {
  const result = await runLua<string>(String.raw`
    local statements = {}
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function() error('maintenance should not run') end,
        query = function() error('query should not run') end,
        update = function(sql, parameters)
          statements[#statements + 1] = { sql = sql, parameters = parameters }
          return #statements == 1 and 3 or 2
        end
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected repository failure') end
      },
      health = {}
    })
    local authority = {
      serverScope = 'roleplay-main', instanceId = 'instance_001',
      token = 'authority_001', resourceEpoch = 4, leaseSeconds = 30
    }
    local heartbeat = assert(repository.heartbeat(authority, { traceId = 'trace_heartbeat_001' }))
    local released = assert(repository.releaseAuthority(
      authority, 'synex.entities.resource_stopped', { traceId = 'trace_release_001' }
    ))
    assert(heartbeat.renewed == 3 and released.released == 2)
    assert(statements[1].sql:find('CURRENT_TIMESTAMP(6)', 1, true))
    assert(not statements[1].sql:find('UTC_TIMESTAMP', 1, true))
    assert(table.concat(statements[1].parameters, ':') ==
      '30:instance_001:authority_001:4:roleplay-main')
    assert(table.concat(statements[2].parameters, ':') ==
      'trace_release_001:instance_001:authority_001:4:roleplay-main')
    return heartbeat.renewed .. ':' .. released.released
  `);
  assert.equal(result, '3:2');
});

test('recovery failure atomically pauses storms and persists the exact lease fence', async () => {
  const result = await runLua<string>(String.raw`
    local operations = {}
    local historyOutcome
    local leaseFence
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function(operation, handler)
          assert(operation == 'entities.recovery_failure')
          return handler({
            one = function(sql)
              operations[#operations + 1] = sql:find('recovery_window_started_at', 1, true)
                and 'entity_lock' or 'lease_lock'
              if sql:find('FROM', 1, true) and sql:find('synex_entities', 1, true) then
                return {
                  generation = 8, status = 'recovering', recovery_policy = 'automatic',
                  recovery_attempt_count = 2, recovery_circuit_state = 'half_open',
                  version = 12, window_live = 1
                }
              end
              return { lease_generation = 5, version = 7 }
            end,
            update = function(sql, parameters)
              if sql:find('UPDATE', 1, true) and sql:find('synex_entities', 1, true) then
                operations[#operations + 1] = 'entity_update'
                assert(sql:find('recovery_circuit_state', 1, true)
                  and sql:find("'paused'", 1, true))
                assert(parameters[1] == 3 and parameters[2] == 1)
              elseif sql:find('synex_entity_recovery_history', 1, true) then
                operations[#operations + 1] = 'history_insert'
                historyOutcome = parameters[3]
              else
                operations[#operations + 1] = 'lease_release'
                leaseFence = table.concat({
                  parameters[3], parameters[4], parameters[5], parameters[6], parameters[7]
                }, ':')
              end
              return 1
            end
          })
        end,
        query = function() error('query should not run') end,
        update = function() error('direct update should not run') end
      },
      foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable,
            traceId = context and context.traceId }
        end,
        reportUnexpected = function() error('unexpected repository failure') end
      },
      health = {}
    })
    local authority = {
      serverScope = 'roleplay-main', instanceId = 'instance_001',
      token = 'authority_001', resourceEpoch = 4, leaseSeconds = 30
    }
    local value = assert(repository.recordRecoveryFailure(
      'entity_0001', 8, authority, 'SPAWN_TIMEOUT', {
        maxAttempts = 3, windowSeconds = 60, baseDelaySeconds = 2,
        maxDelaySeconds = 30, jitterSeconds = 4, durationMs = 1500
      }, { traceId = 'trace_recovery_001' }
    ))
    assert(value.attempts == 3 and value.circuit == 'paused')
    assert(value.delaySeconds == nil and value.version == 13)
    assert(historyOutcome == 'paused')
    assert(leaseFence == 'instance_001:authority_001:4:roleplay-main:5')
    assert(table.concat(operations, ',') ==
      'entity_lock,lease_lock,entity_update,history_insert,lease_release')
    return value.status .. ':' .. value.circuit
  `);
  assert.equal(result, 'failed:paused');
});

test('recovery backoff and success reset remain bounded and history-backed', async () => {
  const result = await runLua<string>(String.raw`
    local entity = {
      generation = 3, status = 'recovering', recovery_policy = 'automatic',
      recovery_attempt_count = 1, recovery_circuit_state = 'half_open',
      version = 5, window_live = 1
    }
    local openDelay
    local successHistory = false
    local operation
    local repository = SynexEntityAuthorityRepository.create({
      recoveryHistoryRetentionSeconds = 3600,
      database = {
        maintenance = function(name, handler)
          operation = name
          return handler({
            one = function(sql)
              if sql:find('FROM', 1, true) and sql:find('synex_entities', 1, true) then
                return entity
              end
              return { lease_generation = 9, version = 2 }
            end,
            update = function(sql, parameters)
              if sql:find('UPDATE', 1, true) and sql:find('synex_entities', 1, true)
                and sql:find('recovery_circuit_state', 1, true)
                and sql:find("'open'", 1, true) then
                openDelay = parameters[3]
              end
              if sql:find('synex_entity_recovery_history', 1, true)
                and sql:find("'recovered'", 1, true) then
                successHistory = true
              end
              return 1
            end
          })
        end,
        query = function() error('query should not run') end,
        update = function() error('direct update should not run') end
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected repository failure') end
      },
      health = {}
    })
    local authority = {
      serverScope = 'roleplay-main', instanceId = 'instance_001',
      token = 'authority_001', resourceEpoch = 4, leaseSeconds = 30
    }
    local failed = assert(repository.recordRecoveryFailure(
      'entity_0001', 3, authority, 'SPAWN_FAILED', {
        maxAttempts = 5, windowSeconds = 60, baseDelaySeconds = 2,
        maxDelaySeconds = 30, jitterSeconds = 0, durationMs = 50
      }, { traceId = 'trace_recovery_002' }
    ))
    assert(operation == 'entities.recovery_failure')
    assert(failed.attempts == 2 and failed.circuit == 'open' and openDelay == 4)

    entity = { status = 'active', recovery_attempt_count = 2, version = 6 }
    local recovered = assert(repository.recordRecoverySuccess(
      'entity_0001', 3, authority, 225, { traceId = 'trace_recovery_003' }
    ))
    assert(operation == 'entities.recovery_success')
    assert(recovered.attempts == 2 and recovered.version == 7 and successHistory)
    return failed.delaySeconds .. ':' .. recovered.status
  `);
  assert.equal(result, '4:active');
});

test('boot reconciliation and owner deletion are fenced, bounded, and tombstone-safe', async () => {
  const result = await runLua<string>(String.raw`
    local operation
    local captured = {}
    local queryStage = 0
    local repository = SynexEntityAuthorityRepository.create({
      bootReconcileLimit = 2,
      database = {
        maintenance = function(name, handler)
          operation = name
          queryStage = 0
          return handler({
            one = function(sql)
              queryStage = queryStage + 1
              if name == 'entities.boot_authority_reconcile' then
                return { total = queryStage == 1 and 2 or 0 }
              end
              return { total = 0 }
            end,
            many = function(sql)
              captured[#captured + 1] = sql
              return {
                { entity_id = 'entity_0001', status = 'active' },
                { entity_id = 'entity_0002', status = 'orphaned' }
              }
            end,
            update = function(sql)
              captured[#captured + 1] = sql
              return 2
            end
          })
        end,
        query = function() error('query should not run') end,
        update = function() error('direct update should not run') end
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected repository failure') end
      },
      health = {}
    })
    local authority = {
      serverScope = 'roleplay-main', instanceId = 'instance_001',
      token = 'authority_001', resourceEpoch = 4, leaseSeconds = 30
    }
    local boot = assert(repository.reconcileBootAuthority(
      'roleplay-main', authority, { traceId = 'trace_boot_001' }
    ))
    assert(operation == 'entities.boot_authority_reconcile')
    assert(boot.conflicts == 2 and boot.reconciled == 2 and boot.remaining == 0)
    assert(captured[1]:find('NOT EXISTS', 1, true))

    captured = {}
    local deleted = assert(repository.applyOwnerDeletion(
      'character', 'character_001', 'delete', nil,
      'synex.entities.owner_deleted', 2, { traceId = 'trace_delete_001' }
    ))
    assert(operation == 'entities.owner_deletion')
    assert(deleted.affected == 2 and deleted.complete and #deleted.entityIds == 2)
    local joined = table.concat(captured, '\n')
    assert(joined:find("'deleted'", 1, true))
    assert(joined:find('synex_entity_authority_leases', 1, true))
    assert(joined:find('synex_entity_bindings', 1, true))
    assert(not joined:find('DELETE FROM', 1, true))
    return boot.conflicts .. ':' .. deleted.affected
  `);
  assert.equal(result, '2:2');
});

test('definition queries expose only bounded whitelisted public filters', async () => {
  const result = await runLua<string>(String.raw`
    local capturedSql
    local capturedParameters
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function() error('maintenance should not run') end,
        query = function(sql, parameters)
          capturedSql = sql
          capturedParameters = parameters
          return {}
        end,
        update = function() error('update should not run') end
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected repository failure') end
      },
      health = {}
    })
    local page = assert(repository.queryDefinitions({
      limit = 12,
      bucket = 17,
      entityTypes = { 'vehicle', 'object' },
      persistencePolicy = 'persistent',
      archetypeNamespace = 'synex.vehicle.police',
      materialized = true,
      afterEntityId = 'entity_0009'
    }, { traceId = 'trace_query_001' }))
    assert(#page.items == 0 and page.nextAfterEntityId == nil)
    assert(capturedSql:find('bucket_id', 1, true))
    assert(capturedSql:find('entity_type', 1, true))
    assert(capturedSql:find('persistence_policy', 1, true))
    assert(capturedSql:find('archetype_namespace', 1, true))
    assert(capturedSql:find("'active', 'spawning', 'recovering'", 1, true))
    assert(table.concat(capturedParameters, ':') ==
      '17:vehicle:object:persistent:synex.vehicle.police:entity_0009:12')
    local invalid, invalidError = repository.queryDefinitions({
      limit = 1, entityTypes = { 'vehicle', 'vehicle' }
    }, { traceId = 'trace_query_002' })
    assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
    return 'filtered'
  `);
  assert.equal(result, 'filtered');
});

test('diagnostic repository returns one bounded read-only page and pressure counts', async () => {
  const result = await runLua<string>(String.raw`
    local operation
    local manyCalls = 0
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function(name, handler)
          operation = name
          return handler({
            many = function(sql, parameters, limit)
              manyCalls = manyCalls + 1
              assert(not sql:find('UPDATE ', 1, true)
                and not sql:find('INSERT ', 1, true)
                and not sql:find('DELETE FROM', 1, true))
              assert(limit <= 3)
              if manyCalls == 1 then
                return {
                  { entity_id = 'entity_0001' },
                  { entity_id = 'entity_0002' },
                  { entity_id = 'entity_0003' },
                }
              end
              if manyCalls == 10 then return { { entity_id = 'entity_0001' } } end
              return {}
            end,
            one = function()
              return {
                definitions = 3, active_bindings = 1, live_leases = 1,
                spawn_outcomes = 2, failed_spawns = 1
              }
            end,
            update = function() error('diagnostics must not mutate') end,
          })
        end,
        query = function() error('direct query should not run') end,
        update = function() error('direct update should not run') end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected repository failure') end,
      },
      health = {},
    })
    local snapshot = assert(repository.diagnosticSnapshot({
      limit = 2, recoveryAttemptThreshold = 3,
      runtimeEntityIds = { 'entity_0001' }
    }, {
      serverScope = 'roleplay-main', instanceId = 'instance_001', resourceEpoch = 4
    }, { traceId = 'trace_diagnostic_repo_001' }))
    assert(operation == 'entities.diagnostic_snapshot' and manyCalls == 10)
    assert(#snapshot.definitions == 2 and snapshot.truncated == true)
    assert(snapshot.nextAfterEntityId == 'entity_0002')
    assert(snapshot.counts.definitions == 3)
    assert(snapshot.counts.failed_spawns == 1 and #snapshot.componentSchemas == 0)
    assert(snapshot.knownRuntimeEntities[1].entity_id == 'entity_0001')
    assert(snapshot.sampledRuntimeEntityIds[1] == 'entity_0001')
    return snapshot.nextAfterEntityId
  `);
  assert.equal(result, 'entity_0002');
});
