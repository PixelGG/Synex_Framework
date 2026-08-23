import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function characterEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/shared/protocol.lua',
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/registries.lua',
    'core/synex_core/server/identity_session_fencing.lua',
    'core/synex_core/server/identity_character_deletion_reconciliation.lua',
    'core/synex_core/server/identity_character_unloads.lua',
    'core/synex_core/server/identity_characters.lua',
  ]) {
    await load(engine, relativePath);
  }
  return engine;
}

test('cross-instance character selection serializes on the character row with exactly one winner', async () => {
  const engine = await characterEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('cluster-select-serialization')
      local character = {
        id = 'character-a', user_id = 'user-a', status = 'active', deleted_at = nil, version = 1
      }
      local sessions, traces, updates
      local function reset()
        sessions = {
          ['session-a'] = {
            id = 'session-a', user_id = 'user-a', server_instance_id = 'instance-a',
            source_value = 41, source_generation = 1, state = 'SELECTING_CHARACTER',
            character_id = nil, version = 1, closed_at = nil
          },
          ['session-b'] = {
            id = 'session-b', user_id = 'user-a', server_instance_id = 'instance-b',
            source_value = 42, source_generation = 1, state = 'SELECTING_CHARACTER',
            character_id = nil, version = 1, closed_at = nil
          }
        }
        traces, updates = {}, 0
      end
      local function desired(id, instanceId, source)
        return {
          id = id, userId = 'user-a', source = source, sourceGeneration = 1,
          state = 'ACTIVE', characterId = 'character-a', version = 3,
          persistedVersion = 1, persistedSource = source, persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:user-a:' .. id, owner = instanceId .. ':' .. id,
            fencingToken = 1, requesterInstanceId = instanceId, requesterBootId = 'boot-' .. id
          }
        }
      end
      local desiredA = desired('session-a', 'instance-a', 41)
      local desiredB = desired('session-b', 'instance-b', 42)
      local characterView = {
        id = character.id, userId = character.user_id, status = character.status,
        deletedAt = character.deleted_at, version = character.version
      }
      local function repository(instanceId)
        local database = {}
        function database:withTransaction(handler)
          local trace = {}
          traces[#traces + 1] = trace
          local before = foundation.copy(sessions)
          local function query(sql, parameters)
            if sql:find('synex_characters', 1, true) and sql:find('FOR UPDATE', 1, true) then
              trace[#trace + 1] = 'character'
              return { foundation.copy(character) }
            end
            if sql:find('synex_sessions', 1, true) and sql:match('^%s*SELECT') then
              if sql:find('WHERE ' .. string.char(96) .. 'id' .. string.char(96)
                  .. ' = ?', 1, true) then
                trace[#trace + 1] = 'own'
                local row = sessions[parameters[1]]
                return row and { foundation.copy(row) } or {}
              end
              assert(sql:find('idx_sessions_character_open', 1, true))
              trace[#trace + 1] = 'conflicts'
              local rows = {}
              for _, row in pairs(sessions) do
                if row.closed_at == nil
                    and row.character_id == parameters[1] and row.id ~= parameters[2] then
                  rows[#rows + 1] = foundation.copy(row)
                end
              end
              table.sort(rows, function(left, right) return left.id < right.id end)
              return rows
            end
            if sql:find('synex_instances', 1, true) then
              trace[#trace + 1] = 'instance'
              return parameters[1] == instanceId and {{ status = 'ready' }} or {}
            end
            if sql:find('synex_instance_boots', 1, true) then
              trace[#trace + 1] = 'boot'
              return parameters[1] == instanceId and {{ boot_id = parameters[2] }} or {}
            end
            if sql:find('synex_cluster_leases', 1, true) then
              trace[#trace + 1] = 'lease'
              local sessionId = parameters[1]:match('([^:]+)$')
              local row = sessions[sessionId]
              return row and {{
                owner_id = instanceId .. ':' .. sessionId, fencing_token = 1, valid = 1
              }} or {}
            end
            if sql:find('UPDATE', 1, true) and sql:find('synex_sessions', 1, true) then
              trace[#trace + 1] = 'update'
              local row = sessions[parameters[5]]
              assert(row and row.user_id == parameters[6])
              assert(row.server_instance_id == parameters[7])
              assert(row.source_generation == parameters[8])
              assert(row.source_value == parameters[9])
              assert(row.state == 'SELECTING_CHARACTER' and row.character_id == nil)
              assert(row.version == parameters[11])
              row.source_value, row.source_generation = parameters[1], parameters[2]
              row.state, row.character_id, row.version = 'ACTIVE', parameters[3], parameters[4]
              updates = updates + 1
              return 1
            end
            error('unexpected selection statement')
          end
          local committed = handler(query)
          if not committed then sessions = before end
          return committed, committed and nil or foundation.error(
            'TRANSACTION_ABORTED', 'fixture transaction aborted', { retryable = true })
        end
        return SynexCoreFactories.identitySessionFencing({
          foundation = foundation, database = database, instanceId = instanceId
        })
      end
      local repositoryA = repository('instance-a')
      local repositoryB = repository('instance-b')

      local function run(firstRepository, firstSession, secondRepository, secondSession, winnerId)
        reset()
        local winner, winnerError = firstRepository:activateCharacter(
          firstSession, characterView, function() return true end)
        assert(winner, winnerError and (winnerError.code .. ':' .. winnerError.message)
          .. ':updates=' .. tostring(updates) .. ':trace=' .. table.concat(traces[#traces], ',')
          or 'winner failed without an error')
        local loser, loserError = secondRepository:activateCharacter(
          secondSession, characterView, function() return true end)
        assert(loser == nil and loserError.code == 'CHARACTER_ALREADY_ACTIVE')
        assert(updates == 1 and sessions[winnerId].state == 'ACTIVE'
          and sessions[winnerId].character_id == 'character-a')
        local loserId = winnerId == 'session-a' and 'session-b' or 'session-a'
        assert(sessions[loserId].state == 'SELECTING_CHARACTER'
          and sessions[loserId].character_id == nil)
        assert(#traces == 2)
        for _, trace in ipairs(traces) do
          assert(trace[1] == 'character' and trace[2] == 'own'
            and trace[3] == 'conflicts')
        end
      end
      run(repositoryA, desiredA, repositoryB, desiredB, 'session-a')
      run(repositoryB, desiredB, repositoryA, desiredA, 'session-b')
      return 'session-a:session-b:' .. tostring(updates)
    `);
    assert.equal(result, 'session-a:session-b:1');
  } finally {
    engine.global.close();
  }
});

test('local active character bindings reject select and delete before persistence', async () => {
  const engine = await characterEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 2 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('local-character-binding')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      local function add(tempSource, source, id, state, characterId)
        assert(players:createPending(tempSource, { sessionId = id }))
        assert(players:bindJoined(tempSource, source, {
          id = id, userId = 'user-a', state = state, characterId = characterId,
          version = 1, persistedVersion = 1, persistedSource = source,
          persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:user-a:' .. id, owner = 'instance-a:' .. id,
            fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
          },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }))
        if characterId then assert(players:bindCharacter(id, characterId)) end
      end
      add(-1, 41, 'session-active', 'ACTIVE', 'character-a')
      add(-2, 42, 'session-selecting', 'SELECTING_CHARACTER', nil)
      local reads, writes = 0, 0
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = owners, messaging = { hooks = {}, events = {} }, coreResource = 'synex_core',
        characterRepository = {
          getOwned = function()
            reads = reads + 1
            return { id = 'character-a', userId = 'user-a', status = 'active', version = 1 }, nil
          end
        },
        sessionRepository = {
          activateCharacter = function() writes = writes + 1 return true, nil end
        },
        invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
        transition = function(candidate, target)
          candidate.state = target
          candidate.version = candidate.version + 1
          return candidate, nil
        end,
        leases = {}, instances = {}, instanceId = 'instance-a'
      })
      local selected, selectError = characters:select('session-selecting', 'character-a')
      local deleted, deleteError = characters:delete('session-selecting', 'character-a')
      assert(selected == nil and selectError.code == 'CHARACTER_ALREADY_ACTIVE')
      assert(deleted == nil and deleteError.code == 'CHARACTER_DELETE_BLOCKED')
      assert(reads == 1 and writes == 0)
      assert(players:getSession('session-active').state == 'ACTIVE'
        and players:getSession('session-selecting').state == 'SELECTING_CHARACTER')
      return table.concat({selectError.code, deleteError.code, reads, writes}, ':')
    `);
    assert.equal(result, 'CHARACTER_ALREADY_ACTIVE:CHARACTER_DELETE_BLOCKED:1:0');
  } finally {
    engine.global.close();
  }
});

test('delete and select use the same character-first serialization in both commit orders', async () => {
  const engine = await characterEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 3 end,
        print = function() end,
        jsonEncode = function() return '{"schema":1,"characterId":"character-a","actions":[]}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('delete-select-serialization')
      local character, durableSessions, traces, planWrites
      local function resetStore()
        character = {
          id = 'character-a', user_id = 'user-a', status = 'active', deleted_at = nil, version = 1
        }
        durableSessions = {
          ['session-delete'] = {
            id = 'session-delete', user_id = 'user-a', server_instance_id = 'instance-delete',
            source_value = 41, source_generation = 1, state = 'SELECTING_CHARACTER',
            character_id = nil, version = 1, closed_at = nil
          },
          ['session-select'] = {
            id = 'session-select', user_id = 'user-a', server_instance_id = 'instance-select',
            source_value = 42, source_generation = 1, state = 'SELECTING_CHARACTER',
            character_id = nil, version = 1, closed_at = nil
          }
        }
        traces, planWrites = {}, 0
      end
      local database = {}
      function database:withTransaction(handler)
        local trace = {}
        traces[#traces + 1] = trace
        local beforeCharacter = foundation.copy(character)
        local beforeSessions = foundation.copy(durableSessions)
        local beforePlans = planWrites
        local function query(sql, parameters)
          if sql:find('synex_characters', 1, true) and sql:match('^%s*SELECT')
              and sql:find('FOR UPDATE', 1, true) then
            trace[#trace + 1] = 'character'
            if character.id ~= parameters[1] then return {} end
            return {{
              id = character.id, user_id = character.user_id, version = character.version,
              status = character.status, deleted_at = character.deleted_at
            }}
          end
          if sql:find('synex_sessions', 1, true) and sql:match('^%s*SELECT') then
            if sql:find('WHERE ' .. string.char(96) .. 'id' .. string.char(96)
                .. ' = ?', 1, true) then
              trace[#trace + 1] = 'own'
              local row = durableSessions[parameters[1]]
              return row and { foundation.copy(row) } or {}
            end
            assert(sql:find('idx_sessions_character_open', 1, true))
            trace[#trace + 1] = 'conflicts'
            local rows = {}
            for _, row in pairs(durableSessions) do
              if row.closed_at == nil
                  and row.character_id == parameters[1] and row.id ~= parameters[2] then
                rows[#rows + 1] = foundation.copy(row)
              end
            end
            table.sort(rows, function(left, right) return left.id < right.id end)
            return rows
          end
          if sql:find('synex_instances', 1, true) then
            trace[#trace + 1] = 'instance'
            return {{ status = 'ready' }}
          end
          if sql:find('synex_instance_boots', 1, true) then
            trace[#trace + 1] = 'boot'
            return {{ boot_id = parameters[2] }}
          end
          if sql:find('synex_cluster_leases', 1, true) then
            trace[#trace + 1] = 'lease'
            local sessionId = parameters[1]:match('([^:]+)$')
            local row = durableSessions[sessionId]
            return row and {{
              owner_id = row.server_instance_id .. ':' .. sessionId,
              fencing_token = 1, valid = 1
            }} or {}
          end
          if sql:find('synex_character_deletion_plans', 1, true) then
            trace[#trace + 1] = 'plan'
            planWrites = planWrites + 1
            return 1
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_characters', 1, true) then
            trace[#trace + 1] = 'delete'
            if character.status ~= 'active' or character.deleted_at ~= nil
                or character.version ~= parameters[3] then return { affectedRows = 0 } end
            character.status, character.deleted_at = 'deleted', 'fixture-now'
            character.version = character.version + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_sessions', 1, true) then
            trace[#trace + 1] = 'activate'
            local row = durableSessions[parameters[5]]
            if not row or row.state ~= 'SELECTING_CHARACTER' or row.character_id ~= nil
                or row.version ~= parameters[11] then return { affectedRows = 0 } end
            row.source_value, row.source_generation = parameters[1], parameters[2]
            row.state, row.character_id, row.version = 'ACTIVE', parameters[3], parameters[4]
            return { affectedRows = 1 }
          end
          if sql:find('synex_audit_log', 1, true) then
            trace[#trace + 1] = 'audit'
            return { affectedRows = 1 }
          end
          error('unexpected delete/select statement')
        end
        local committed = handler(query)
        if not committed then
          character, durableSessions, planWrites = beforeCharacter, beforeSessions, beforePlans
        end
        return committed, committed and nil or foundation.error(
          'TRANSACTION_ABORTED', 'fixture transaction aborted', { retryable = true })
      end
      local function characterRepository()
        return {
          getOwned = function(_, userId, characterId)
            if userId ~= character.user_id or characterId ~= character.id
                or character.status ~= 'active' or character.deleted_at ~= nil then
              return nil, foundation.error('CHARACTER_NOT_FOUND', 'fixture character unavailable')
            end
            return {
              id = character.id, userId = character.user_id, status = character.status,
              version = character.version
            }, nil
          end
        }
      end
      local function service(instanceId, sessionId, source)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        assert(registries.players:createPending(-source, { sessionId = sessionId }))
        assert(registries.players:bindJoined(-source, source, {
          id = sessionId, userId = 'user-a', state = 'SELECTING_CHARACTER',
          characterId = nil, version = 1, persistedVersion = 1,
          persistedSource = source, persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:user-a:' .. sessionId, owner = instanceId .. ':' .. sessionId,
            fencingToken = 1, requesterInstanceId = instanceId,
            requesterBootId = 'boot-' .. sessionId
          },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }))
        local sessionRepository = SynexCoreFactories.identitySessionFencing({
          foundation = foundation, database = database, instanceId = instanceId
        })
        local characters = SynexCoreFactories.identityCharacters({
          platform = platform, foundation = foundation, database = database,
          players = registries.players, owners = registries.owners,
          messaging = {
            hooks = {}, events = { publish = function() return true, nil end }
          },
          coreResource = 'synex_core', characterRepository = characterRepository(),
          sessionRepository = sessionRepository,
          invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
          transition = function(candidate, target)
            candidate.state = target
            candidate.version = candidate.version + 1
            return candidate, nil
          end,
          leases = {
            acquire = function()
              return nil, foundation.error('LEASE_BUSY', 'fixture reconciliation deferred', {
                retryable = true
              })
            end
          },
          instances = { bootId = function() return 'boot-' .. sessionId, nil end },
          instanceId = instanceId
        })
        return characters, registries.players
      end

      resetStore()
      local deleteFirst = service('instance-delete', 'session-delete', 41)
      local selectSecond, selectPlayers = service('instance-select', 'session-select', 42)
      local deleted, deleteFirstError = deleteFirst:delete('session-delete', 'character-a')
      assert(deleted, deleteFirstError and (deleteFirstError.code .. ':' .. deleteFirstError.message)
        or 'delete failed without an error')
      local selectedAfterDelete, selectedAfterDeleteError = selectSecond:select(
        'session-select', 'character-a')
      assert(deleted.state == 'reconciling' and selectedAfterDelete == nil
        and selectedAfterDeleteError.code == 'CHARACTER_NOT_FOUND')
      assert(character.status == 'deleted' and planWrites == 1)
      assert(selectPlayers:getSession('session-select').state == 'SELECTING_CHARACTER')
      assert(traces[1][1] == 'character' and traces[1][2] == 'own'
        and traces[1][3] == 'conflicts')

      resetStore()
      local deleteSecond = service('instance-delete', 'session-delete', 41)
      local selectFirst, selectedPlayers = service('instance-select', 'session-select', 42)
      local selectedFirst, selectFirstError = selectFirst:select('session-select', 'character-a')
      assert(selectedFirst, selectFirstError and selectFirstError.code or 'select failed without an error')
      local deletedAfterSelect, deletedAfterSelectError = deleteSecond:delete(
        'session-delete', 'character-a')
      assert(deletedAfterSelect == nil and deletedAfterSelectError.code == 'CHARACTER_DELETE_BLOCKED')
      assert(character.status == 'active' and character.deleted_at == nil and planWrites == 0)
      assert(selectedPlayers:getSession('session-select').state == 'ACTIVE')
      assert(#traces == 2)
      for _, trace in ipairs(traces) do
        assert(trace[1] == 'character' and trace[2] == 'own'
          and trace[3] == 'conflicts')
      end
      return table.concat({deleted.state, selectedAfterDeleteError.code,
        deletedAfterSelectError.code, selectedPlayers:getSession('session-select').state}, ':')
    `);
    assert.equal(result,
      'reconciling:CHARACTER_NOT_FOUND:CHARACTER_DELETE_BLOCKED:ACTIVE');
  } finally {
    engine.global.close();
  }
});
