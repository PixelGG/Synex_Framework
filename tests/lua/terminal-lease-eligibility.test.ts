import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('saga terminal state and compaction eligibility commit atomically under the exact lease fence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/reliability.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 7 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('terminal-saga-eligibility')
      local saga, lease, steps, retirementCalls
      local function reset(owner, token)
        saga = {
          id = 91, state = 'running', current_step = 0, version = 7,
          owner_resource = 'synex_fixture'
        }
        lease = owner and {
          name = 'saga:saga_fixture', owner = owner, token = token,
          marker = nil, valid = true
        } or nil
        steps, retirementCalls = 0, 0
      end
      local database = {}
      function database:withTransaction(handler)
        local beforeSaga = foundation.copy(saga)
        local beforeLease = foundation.copy(lease)
        local beforeSteps = steps
        local committed = handler(function(sql, parameters)
          if sql:find('FROM ' .. string.char(96) .. 'synex_sagas'
              .. string.char(96), 1, true) and sql:find('FOR UPDATE', 1, true) then
            return { foundation.copy(saga) }
          end
          if sql:find('INSERT INTO ' .. string.char(96) .. 'synex_saga_steps'
              .. string.char(96), 1, true) then
            steps = steps + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. string.char(96) .. 'synex_sagas'
              .. string.char(96), 1, true) then
            local runtime = sql:find('context_json', 1, true) ~= nil
            local expectedVersion = parameters[runtime and 8 or 6]
            if saga.version ~= expectedVersion
                or saga.state == 'completed' or saga.state == 'failed'
                or saga.state == 'cancelled' then
              return { affectedRows = 0 }
            end
            saga.state, saga.current_step = parameters[1], parameters[2]
            saga.version = saga.version + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. string.char(96) .. 'synex_cluster_leases'
              .. string.char(96), 1, true) then
            retirementCalls = retirementCalls + 1
            assert(sql:find('terminal_compaction_at', 1, true))
            assert(parameters[1] == 'saga:saga_fixture')
            if not lease or lease.marker ~= nil then return { affectedRows = 0 } end
            if parameters[2] ~= nil and (lease.owner ~= parameters[2]
                or lease.token ~= parameters[3] or not lease.valid) then
              return { affectedRows = 0 }
            end
            lease.owner, lease.token, lease.marker, lease.valid =
              'terminal', lease.token + 1, 'fixture-now', false
            return { affectedRows = 1 }
          end
          error('unexpected saga transaction SQL')
        end)
        if committed ~= true then
          saga, lease, steps = beforeSaga, beforeLease, beforeSteps
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      local sagas = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', sha256 = function() return string.rep('a', 64) end,
        features = { sagas = true }
      }).sagas
      local function runtimeCommand(snapshot, nextState, eventType)
        return {
          ownerResource = 'synex_fixture', publicId = 'saga_fixture',
          expectedVersion = 7, stepName = 'fixture.commit', eventType = eventType,
          nextState = nextState, attempt = 1, payload = {}, context = {},
          clearError = true, terminal = true, lease = snapshot
        }
      end

      reset('instance-a:worker', 10)
      local winner = assert(sagas:appendRuntimeEvent(runtimeCommand({
        name = lease.name, owner = lease.owner, fencingToken = lease.token
      }, 'completed', 'succeeded')))
      assert(winner.state == 'completed' and saga.state == 'completed' and saga.version == 8)
      assert(steps == 1 and retirementCalls == 1 and lease.owner == 'terminal'
        and lease.token == 11 and lease.marker == 'fixture-now')

      reset('instance-b:winner', 11)
      local stale, staleError = sagas:appendRuntimeEvent(runtimeCommand({
        name = lease.name, owner = 'instance-a:stale', fencingToken = 10
      }, 'failed', 'failed'))
      assert(stale == nil and staleError.code == 'SAGA_LEASE_LOST')
      assert(saga.state == 'running' and saga.version == 7 and saga.current_step == 0)
      assert(steps == 0 and lease.owner == 'instance-b:winner'
        and lease.token == 11 and lease.marker == nil)

      reset('instance-a:old-worker', 12)
      local publiclyFailed = assert(sagas:record(
        'synex_fixture', 'saga_fixture', 7, 'fixture.public_failure', 'failed', {},
        { code = 'PUBLIC_FAILURE' }))
      assert(publiclyFailed.state == 'failed' and saga.state == 'failed' and saga.version == 8)
      assert(lease.owner == 'terminal' and lease.token == 13
        and lease.marker == 'fixture-now')
      local oldWorker, oldWorkerError = sagas:appendRuntimeEvent({
        ownerResource = 'synex_fixture', publicId = 'saga_fixture',
        expectedVersion = 8, stepName = 'fixture.stale', eventType = 'failed',
        nextState = 'failed', attempt = 1, payload = {}, context = {},
        terminal = true, lease = {
          name = 'saga:saga_fixture', owner = 'instance-a:old-worker', fencingToken = 12
        }
      })
      assert(oldWorker == nil and oldWorkerError.code == 'SAGA_TERMINAL')
      assert(saga.version == 8 and steps == 1)

      reset(nil, nil)
      local withoutLease = assert(sagas:record(
        'synex_fixture', 'saga_fixture', 7, 'fixture.no_lease', 'failed', {}))
      assert(withoutLease.state == 'failed' and saga.state == 'failed'
        and saga.version == 8 and lease == nil and retirementCalls == 1)
      return table.concat({winner.state, staleError.code, publiclyFailed.state,
        oldWorkerError.code, withoutLease.state}, ':')
    `);
    assert.equal(
      result,
      'completed:SAGA_LEASE_LOST:failed:SAGA_TERMINAL:failed',
    );
  } finally {
    engine.global.close();
  }
});

test('character deletion completion and invalid-plan failure retire leases in their terminal transaction', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/identity_character_deletion_reconciliation.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 9 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('terminal-character-delete-eligibility')
      local plan, leaseRow, returnedToken, acquiredOwner
      local function reset(databaseToken, token)
        plan = { state = 'pending', version = 1, fencingToken = nil }
        leaseRow = databaseToken and {
          owner = nil, token = databaseToken, marker = nil, valid = true
        } or nil
        returnedToken, acquiredOwner = token, nil
      end
      local database = {}
      function database:update(sql, parameters)
        assert(sql:find('attempt_count', 1, true))
        if plan.state ~= 'pending' or plan.version ~= parameters[3] then return 0, nil end
        plan.state, plan.fencingToken, plan.version = 'executing', parameters[1], plan.version + 1
        return 1, nil
      end
      function database:withTransaction(handler)
        local beforePlan, beforeLease = foundation.copy(plan), foundation.copy(leaseRow)
        local committed = handler(function(sql, parameters)
          if sql:find("SET \`state\` = 'completed'", 1, true) then
            if plan.state ~= 'executing' or plan.version ~= parameters[2]
                or plan.fencingToken ~= parameters[3] then
              return { affectedRows = 0 }
            end
            plan.state, plan.fencingToken, plan.version = 'completed', nil, plan.version + 1
            return { affectedRows = 1 }
          end
          if sql:find("SET \`state\` = 'failed'", 1, true) then
            if (plan.state ~= 'pending' and plan.state ~= 'executing')
                or plan.version ~= parameters[3] then
              return { affectedRows = 0 }
            end
            plan.state, plan.fencingToken, plan.version = 'failed', nil, plan.version + 1
            return { affectedRows = 1 }
          end
          if sql:find('synex_cluster_leases', 1, true) then
            assert(sql:find('terminal_compaction_at', 1, true))
            assert(parameters[1] == 'character-delete:plan_fixture')
            if not leaseRow or leaseRow.marker ~= nil then return { affectedRows = 0 } end
            if parameters[2] ~= nil and (leaseRow.owner ~= parameters[2]
                or leaseRow.token ~= parameters[3] or not leaseRow.valid) then
              return { affectedRows = 0 }
            end
            leaseRow.owner, leaseRow.token, leaseRow.marker, leaseRow.valid =
              'terminal', leaseRow.token + 1, 'fixture-now', false
            return { affectedRows = 1 }
          end
          error('unexpected character deletion transaction SQL')
        end)
        if committed ~= true then
          plan, leaseRow = beforePlan, beforeLease
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      local leases = {}
      function leases:acquire(name, owner, ttlSeconds, instanceId, bootId)
        assert(name == 'character-delete:plan_fixture' and instanceId == 'instance-a'
          and bootId == 'boot-a')
        acquiredOwner = owner
        if leaseRow then leaseRow.owner = owner end
        return {
          name = name, owner = owner, fencingToken = returnedToken,
          ttlSeconds = ttlSeconds, requesterInstanceId = instanceId,
          requesterBootId = bootId
        }, nil
      end
      function leases:renew() return true, nil end
      function leases:release() return true, nil end
      local service = SynexCoreFactories.identityCharacterDeletionReconciliation({
        platform = platform, foundation = foundation, database = database, leases = leases,
        instances = { bootId = function() return 'boot-a', nil end },
        owners = { epoch = function() return 1 end },
        messaging = { events = { publish = function() return true, nil end } },
        stateService = { purgeSubject = function() return { cleared = 0 }, nil end },
        instanceId = 'instance-a', coreResource = 'synex_core', participantMaximum = 128,
        invokeParticipant = function() return true, nil end,
        findParticipant = function() return nil end
      })
      local validPlan = { schema = 1, characterId = 'character-a', actions = {} }

      reset(7, 7)
      local completed = assert(service:process(
        'plan_fixture', 1, validPlan, 'character-a'))
      assert(completed.state == 'completed' and plan.state == 'completed' and plan.version == 3)
      assert(leaseRow.owner == 'terminal' and leaseRow.token == 8
        and leaseRow.marker == 'fixture-now')

      reset(8, 7)
      local stale, staleError = service:process(
        'plan_fixture', 1, validPlan, 'character-a')
      assert(stale == nil and staleError.code == 'DELETE_LEASE_LOST')
      assert(plan.state == 'executing' and plan.version == 2 and plan.fencingToken == 7,
        'the terminal plan update must roll back when exact lease retirement loses its fence')
      assert(leaseRow.owner == acquiredOwner and leaseRow.token == 8 and leaseRow.marker == nil)

      reset(4, 99)
      leaseRow.owner = 'instance-b:old-worker'
      local invalid, invalidError = service:process(
        'plan_fixture', 1, { schema = 99, characterId = 'character-a', actions = {} },
        'character-a')
      assert(invalid == nil and invalidError.code == 'INVALID_DELETE_PLAN')
      assert(plan.state == 'failed' and plan.version == 2)
      assert(leaseRow.owner == 'terminal' and leaseRow.token == 5
        and leaseRow.marker == 'fixture-now')
      return table.concat({completed.state, staleError.code, invalidError.code,
        plan.state, leaseRow.owner}, ':')
    `);
    assert.equal(
      result,
      'completed:DELETE_LEASE_LOST:INVALID_DELETE_PLAN:failed:terminal',
    );
  } finally {
    engine.global.close();
  }
});
