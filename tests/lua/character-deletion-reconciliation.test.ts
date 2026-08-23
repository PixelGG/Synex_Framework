import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

async function load(engine: LuaEngine, file: string): Promise<void> {
  await engine.doString(await readFile(file, 'utf8'));
}

async function reconciliationEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  await load(engine, 'core/synex_core/server/foundation.lua');
  await load(engine, 'core/synex_core/server/identity_character_deletion_reconciliation.lua');
  return engine;
}

test('character deletion plans accept only bounded exact plain-data shapes', async () => {
  const engine = await reconciliationEngine();
  try {
    const result = await engine.doString(`
      local jsonEncodeCalls = 0
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          jsonEncodeCalls = jsonEncodeCalls + 1
          if type(value) == 'table' and value.oversized then return string.rep('x', 4097) end
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-plan-validation')
      local service = SynexCoreFactories.identityCharacterDeletionReconciliation({
        platform = platform, foundation = foundation, database = {}, leases = {}, instances = {},
        owners = {}, messaging = {}, stateService = {}, instanceId = 'instance-a',
        coreResource = 'synex_core', invokeParticipant = function() end,
        findParticipant = function() end, participantMaximum = 999
      })
      local action = {
        owner = 'synex_domain', participant = 'domain.deletion', action = 'anonymize',
        metadata = { request = 'fixture' }, notify = true
      }
      assert(service:validate({ schema = 1, characterId = 'character-a', actions = { action } }))

      local invalid = {}
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {}, extra = true }
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'attacker', participant = 'domain.deletion', action = 'delete' }
      } }
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'block' }
      } }
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        [2] = { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete' }
      } }
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete', unexpected = true }
      } }
      local cyclic = {}
      cyclic.self = cyclic
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete', metadata = cyclic }
      } }
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete',
          metadata = { oversized = true } }
      } }
      local deep = {}
      local cursor = deep
      for _ = 1, 9 do cursor.child = {}; cursor = cursor.child end
      invalid[#invalid + 1] = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete', metadata = deep }
      } }
      local tooManyActions = {}
      for index = 1, 129 do
        tooManyActions[index] = {
          owner = 'synex_domain', participant = 'domain.deletion', action = 'delete', notify = false
        }
      end
      invalid[#invalid + 1] = {
        schema = 1, characterId = 'character-a', actions = tooManyActions
      }
      invalid[#invalid + 1] = { schema = 1, characterId = 'CHARACTER:A', actions = {} }

      for index, plan in ipairs(invalid) do
        local valid, validationError = service:validate(plan)
        assert(valid == nil and validationError.code == 'INVALID_DELETE_PLAN', index)
      end
      assert(jsonEncodeCalls == 2, 'structurally invalid metadata must not reach the JSON encoder')
      return #invalid
    `);
    assert.equal(result, 10);
  } finally {
    engine.global.close();
  }
});

test('a stolen character deletion lease fences the stale worker from finalization', async () => {
  const engine = await reconciliationEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-delete-fence')
      local row = { state = 'executing', version = 1, fencingToken = nil, nextAttemptAt = 0 }
      local activeFence, activeOwner, terminalCompactionAt, leaseSequence = nil, nil, nil, 0
      local participantCalls, projectionChecks, purgeCalls, completionCalls, published = 0, 0, 0, 0, 0
      local database = {}
      function database:update(sql, parameters)
        if sql:find('attempt_count', 1, true) then
          local expected = parameters[3]
          if row.state ~= 'completed' and row.version == expected then
            row.state = 'executing'
            row.fencingToken = parameters[1]
            row.version = row.version + 1
            row.nextAttemptAt = 5
            return 1, nil
          end
          return 0, nil
        end
        error('unexpected deletion update')
      end
      function database:withTransaction(handler)
        local beforeRow = foundation.copy(row)
        local beforeFence, beforeOwner, beforeMarker = activeFence, activeOwner, terminalCompactionAt
        local committed = handler(function(sql, parameters)
          if sql:find("SET \`state\` = 'completed'", 1, true) then
            completionCalls = completionCalls + 1
            if row.state == 'executing' and row.version == parameters[2]
                and row.fencingToken == parameters[3] then
              row.state = 'completed'
              row.fencingToken = nil
              row.version = row.version + 1
              return { affectedRows = 1 }
            end
            return { affectedRows = 0 }
          end
          if sql:find('synex_cluster_leases', 1, true) then
            assert(sql:find('terminal_compaction_at', 1, true))
            if parameters[1] == 'character-delete:del_fixture'
                and parameters[2] == activeOwner and parameters[3] == activeFence
                and terminalCompactionAt == nil then
              activeOwner, activeFence, terminalCompactionAt = 'terminal', activeFence + 1, 'now'
              return { affectedRows = 1 }
            end
            return { affectedRows = 0 }
          end
          error('unexpected deletion transaction')
        end)
        if committed ~= true then
          row, activeFence, activeOwner, terminalCompactionAt =
            beforeRow, beforeFence, beforeOwner, beforeMarker
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      local leases = {}
      function leases:acquire(name, owner, ttl, instanceId, bootId)
        assert(name == 'character-delete:del_fixture' and ttl == 120
          and instanceId == 'instance-a' and bootId == 'boot-a')
        leaseSequence = leaseSequence + 1
        activeFence = leaseSequence
        activeOwner = owner
        terminalCompactionAt = nil
        return {
          name = name, owner = owner, fencingToken = leaseSequence, ttlSeconds = ttl,
          requesterInstanceId = instanceId, requesterBootId = bootId
        }, nil
      end
      function leases:renew(lease)
        if lease.fencingToken ~= activeFence then
          return nil, foundation.error('LEASE_LOST', 'fixture lease was superseded', { retryable = true })
        end
        return true, nil
      end
      function leases:release(lease)
        if activeFence == lease.fencingToken and activeOwner == lease.owner then activeFence = nil end
        return true, nil
      end
      local service
      local plan = { schema = 1, characterId = 'character-a', actions = {
        { owner = 'synex_domain', participant = 'domain.deletion', action = 'delete',
          metadata = { domain = 'one' }, notify = true },
        { owner = 'synex_other', participant = 'other.deletion', action = 'retain',
          metadata = { domain = 'two' }, notify = true }
      } }
      local stateService = {}
      function stateService:purgeSubject(scope, subject)
        assert(scope == 'character' and subject == 'character-a')
        purgeCalls = purgeCalls + 1
        if purgeCalls == 1 then
          activeFence = nil
          local winner, winnerError = service:process(
            'del_fixture', row.version, plan, 'character-a')
          assert(winner and winnerError == nil and winner.state == 'completed')
        end
        return { cleared = 1 }, nil
      end
      service = SynexCoreFactories.identityCharacterDeletionReconciliation({
        platform = platform, foundation = foundation, database = database, leases = leases,
        instances = { bootId = function() return 'boot-a', nil end }, owners = {
          epoch = function() return 1 end
        }, messaging = { events = { publish = function()
          published = published + 1
          return true, nil
        end } }, stateService = stateService, instanceId = 'instance-a',
        coreResource = 'synex_core', participantMaximum = 128,
        findParticipant = function(action) return {
          deleteCommit = function(context)
            participantCalls = participantCalls + 1
            assert(context.plan.schema == 1 and context.plan.characterId == 'character-a')
            assert(#context.plan.actions == 1
              and context.plan.actions[1].owner == action.owner
              and context.plan.actions[1].metadata.domain == action.metadata.domain)
            projectionChecks = projectionChecks + 1
            return true, nil
          end
        } end,
        invokeParticipant = function(participant, handler, ...)
          return handler(...)
        end
      })
      local stale, staleError = service:process(
        'del_fixture', 1, plan, 'character-a')
      assert(stale == nil and staleError.code == 'DELETE_LEASE_LOST')
      assert(row.state == 'completed' and row.version == 4 and row.fencingToken == nil)
      assert(activeOwner == 'terminal' and terminalCompactionAt == 'now')
      assert(leaseSequence == 2 and participantCalls == 4 and projectionChecks == 4 and purgeCalls == 2)
      assert(completionCalls == 1 and published == 1)
      return table.concat({row.state, row.version, participantCalls, projectionChecks,
        purgeCalls, completionCalls, published}, ':')
    `);
    assert.equal(result, 'completed:4:4:4:2:1:1');
  } finally {
    engine.global.close();
  }
});

test('pre-attempt lease contention cannot invalidate its winner and a bounded batch still progresses', async () => {
  const engine = await reconciliationEngine();
  try {
    const result = await engine.doString(`
      local now = 0
      local plans = {
        del_a = { id = 'del_a', version = 1, state = 'executing', nextAttemptAt = 0,
          createdAt = 1, json = 'plan-a', characterId = 'character-a' },
        del_b = { id = 'del_b', version = 1, state = 'executing', nextAttemptAt = 0,
          createdAt = 2, json = 'plan-b', characterId = 'character-b' },
        del_bad = { id = 'del_bad', version = 1, state = 'executing', nextAttemptAt = 0,
          createdAt = 3, json = 'plan-bad', characterId = 'INVALID:CHARACTER' }
      }
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function(value)
          for _, row in pairs(plans) do
            if row.json == value then
              return { schema = 1, characterId = row.characterId, actions = {} }
            end
          end
          error('unknown fixture plan')
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-delete-due')
      local leaseRows = {}
      local database = {}
      function database:query(sql, parameters)
        assert(sql:find('next_attempt_at', 1, true)
          and sql:find('<= CURRENT_TIMESTAMP(6)', 1, true)
          and sql:find('ORDER BY \`next_attempt_at\`, \`created_at\`, \`id\` LIMIT ?', 1, true))
        local candidates = {}
        for _, row in pairs(plans) do
          if (row.state == 'pending' or row.state == 'executing')
              and row.nextAttemptAt <= now then
            candidates[#candidates + 1] = row
          end
        end
        table.sort(candidates, function(left, right)
          if left.nextAttemptAt ~= right.nextAttemptAt then
            return left.nextAttemptAt < right.nextAttemptAt
          end
          if left.createdAt ~= right.createdAt then return left.createdAt < right.createdAt end
          return left.id < right.id
        end)
        local rows = {}
        for index = 1, math.min(parameters[1], #candidates) do
          local row = candidates[index]
          rows[#rows + 1] = {
            id = row.id, character_id = row.characterId,
            version = row.version, plan_json = row.json
          }
        end
        return rows, nil
      end
      function database:update(sql, parameters)
        if sql:find("SET \`state\` = 'failed'", 1, true) then
          local row = plans[parameters[2]]
          if row and row.version == parameters[3]
              and (row.state == 'pending' or row.state == 'executing') then
            row.state = 'failed'
            row.version = row.version + 1
            return 1, nil
          end
          return 0, nil
        end
        if sql:find('attempt_count', 1, true) then
          local row = plans[parameters[2]]
          if row and row.version == parameters[3] and row.nextAttemptAt <= now then
            row.version = row.version + 1
            row.nextAttemptAt = now + 5
            row.fencingToken = parameters[1]
            return 1, nil
          end
          return 0, nil
        end
        if sql:find("SET \`state\` = 'completed'", 1, true) then
          local row = plans[parameters[1]]
          if row and row.version == parameters[2] and row.fencingToken == parameters[3] then
            row.state = 'completed'
            row.version = row.version + 1
            row.fencingToken = nil
            return 1, nil
          end
          return 0, nil
        end
        error('unexpected deletion update')
      end
      function database:withTransaction(handler)
        local beforePlans, beforeLeases = foundation.copy(plans), foundation.copy(leaseRows)
        local committed = handler(function(sql, parameters)
          if sql:find('synex_character_deletion_plans', 1, true) then
            local affected, updateError = database:update(sql, parameters)
            assert(updateError == nil)
            return { affectedRows = affected }
          end
          if sql:find('synex_cluster_leases', 1, true) then
            assert(sql:find('terminal_compaction_at', 1, true))
            local lease = leaseRows[parameters[1]]
            if not lease or lease.marker ~= nil then return { affectedRows = 0 } end
            if parameters[2] ~= nil
                and (lease.owner ~= parameters[2] or lease.token ~= parameters[3]) then
              return { affectedRows = 0 }
            end
            lease.owner, lease.token, lease.marker = 'terminal', lease.token + 1, 'now'
            return { affectedRows = 1 }
          end
          error('unexpected deletion transaction')
        end)
        if committed ~= true then
          plans, leaseRows = beforePlans, beforeLeases
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      local busyA = true
      local leases = {
        acquire = function(_, name, owner, ttl, instanceId, bootId)
          if busyA and name == 'character-delete:del_a' then
            return nil, foundation.error('LEASE_BUSY', 'fixture contention', { retryable = true })
          end
          leaseRows[name] = { owner = owner, token = 2, marker = nil }
          return {
            name = name, owner = owner, fencingToken = 2, ttlSeconds = ttl,
            requesterInstanceId = instanceId, requesterBootId = bootId
          }, nil
        end,
        renew = function() return true, nil end,
        release = function() return true, nil end
      }
      local service = SynexCoreFactories.identityCharacterDeletionReconciliation({
        platform = platform, foundation = foundation, database = database, leases = leases,
        instances = { bootId = function() return 'boot-a', nil end },
        owners = { epoch = function() return 1 end },
        messaging = { events = { publish = function() return true, nil end } },
        stateService = { purgeSubject = function() return { cleared = 0 }, nil end },
        instanceId = 'instance-a', coreResource = 'synex_core', participantMaximum = 128,
        invokeParticipant = function() end, findParticipant = function() end
      })
      local first = assert(service:reconcile(3))
      assert(first.examined == 3 and first.deferred == 1
        and first.completed == 1 and first.invalid == 1)
      assert(plans.del_a.version == 1 and plans.del_a.nextAttemptAt == 0,
        'a lease loser must not mutate the plan version observed by its winner')
      assert(plans.del_b.state == 'completed' and plans.del_bad.state == 'failed')
      assert(leaseRows['character-delete:del_b'].owner == 'terminal'
        and leaseRows['character-delete:del_b'].marker == 'now')
      assert(leaseRows['character-delete:del_bad'] == nil)
      busyA = false
      local second = assert(service:reconcile(1))
      assert(second.examined == 1 and second.completed == 1
        and plans.del_a.state == 'completed' and plans.del_a.version == 3)
      assert(leaseRows['character-delete:del_a'].owner == 'terminal'
        and leaseRows['character-delete:del_a'].marker == 'now')
      local exhausted = assert(service:reconcile(1))
      assert(exhausted.examined == 0, 'invalid character IDs must leave the due queue')
      local invalid, invalidError = service:reconcile(0)
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      return table.concat({first.deferred, first.completed, first.invalid, second.completed,
        plans.del_a.version, plans.del_b.state, plans.del_bad.state}, ':')
    `);
    assert.equal(result, '1:1:1:1:3:completed:failed');
  } finally {
    engine.global.close();
  }
});
