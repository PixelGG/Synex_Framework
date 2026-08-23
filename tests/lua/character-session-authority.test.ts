import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function authorityEngine(): Promise<LuaEngine> {
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
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('source reuse during create and select yields cannot mutate the replacement caller', async () => {
  const engine = await authorityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 5 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-source-reuse')
      local function session(id, userId)
        return {
          id = id, userId = userId, state = 'SELECTING_CHARACTER', characterId = nil,
          version = 1, persistedVersion = 1, persistedSource = 41,
          persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:' .. userId .. ':' .. id, owner = 'instance-a:' .. id,
            fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
          },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }
      end
      local function installReplacement(players)
        assert(players:detachSource('session-old', 41, 1))
        assert(players:createPending(-2, { sessionId = 'session-replacement' }))
        assert(players:bindJoined(-2, 41, session('session-replacement', 'user-replacement')))
      end
      local function fixture(kind)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        local owners, players = registries.owners, registries.players
        owners:activate('synex_core')
        assert(players:createPending(-1, { sessionId = 'session-old' }))
        assert(players:bindJoined(-1, 41, session('session-old', 'user-a')))
        local repositoryCalls, rollbacks = 0, 0
        local messaging = {
          hooks = {
            run = function(_, owner, epoch, hookName, input)
              assert(owner == 'synex_core' and epoch == owners:epoch('synex_core'))
              assert(hookName == 'synex.characters.before_create')
              installReplacement(players)
              return foundation.copy(input), nil
            end
          },
          events = { publish = function() error('stale create published an event') end }
        }
        local characters = SynexCoreFactories.identityCharacters({
          platform = platform, foundation = foundation, database = {}, players = players,
          owners = owners, messaging = messaging, coreResource = 'synex_core',
          characterRepository = {
            create = function()
              repositoryCalls = repositoryCalls + 1
              error('stale create reached persistence')
            end,
            getOwned = function()
              return { id = 'character-a', userId = 'user-a', status = 'active', version = 1 }, nil
            end
          },
          sessionRepository = {
            activateCharacter = function()
              repositoryCalls = repositoryCalls + 1
              error('stale select reached persistence')
            end
          },
          invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
          transition = function(candidate, target)
            candidate.state = target
            candidate.version = candidate.version + 1
            return candidate, nil
          end,
          leases = {}, instances = {}, instanceId = 'instance-a'
        })
        if kind == 'select' then
          local epoch = owners:activate('synex_source_reuse')
          assert(characters:registerParticipant('synex_source_reuse', epoch, {
            name = 'source.reuse',
            prepare = function()
              installReplacement(players)
              return { prepared = true }, nil
            end,
            rollback = function()
              rollbacks = rollbacks + 1
              return true, nil
            end
          }))
        end
        local value, operationError
        if kind == 'create' then
          value, operationError = characters:create('session-old', {
            slot = 1, firstName = 'Ada', lastName = 'Lovelace'
          })
        else
          value, operationError = characters:select('session-old', 'character-a')
        end
        assert(value == nil and operationError.code == 'SESSION_PERSISTENCE_PENDING')
        assert(operationError.details.cause == 'SESSION_CONFLICT' and repositoryCalls == 0)
        local replacement = assert(players:getBySource(41))
        assert(replacement.id == 'session-replacement' and replacement.state == 'SELECTING_CHARACTER'
          and replacement.characterId == nil)
        local stale = assert(players:getSession('session-old'))
        assert(stale.source == nil and stale.characterId == nil and stale.state ~= 'ACTIVE')
        return rollbacks
      end
      local createRollbacks = fixture('create')
      local selectRollbacks = fixture('select')
      assert(createRollbacks == 0 and selectRollbacks == 1)
      return table.concat({createRollbacks, selectRollbacks, 'SESSION_PERSISTENCE_PENDING'}, ':')
    `);
    assert.equal(result, '0:1:SESSION_PERSISTENCE_PENDING');
  } finally {
    engine.global.close();
  }
});

test('soft-deleted slots can be recreated while concurrent creates serialize on the slot row', async () => {
  const engine = await authorityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 6 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-slot-reuse')
      local characters = {{
        id = 'character-deleted', user_id = 'user-a', slot = 1,
        status = 'deleted', deleted_at = 'fixture-past', active_slot_marker = nil
      }}
      local traces, inserts = {}, 0
      local database = {}
      function database:withTransaction(handler)
        local trace = {}
        traces[#traces + 1] = trace
        local function query(sql, parameters)
          if sql:find('synex_character_slots', 1, true) then
            trace[#trace + 1] = 'slot'
            assert(sql:find('FOR UPDATE', 1, true) and parameters[1] == 'user-a')
            return {{ slot_limit = 4 }}
          end
          if sql:find('synex_characters', 1, true)
              and sql:find('\`deleted_at\` IS NULL', 1, true)
              and sql:match('^%s*SELECT') then
            trace[#trace + 1] = 'active-slot'
            for _, row in ipairs(characters) do
              if row.user_id == parameters[1] and row.slot == parameters[2]
                  and row.deleted_at == nil then return {{ id = row.id }} end
            end
            return {}
          end
          if sql:find('synex_sessions', 1, true) and sql:match('^%s*SELECT') then
            if sql:find('WHERE \`id\` = ?', 1, true) then
              trace[#trace + 1] = 'own'
              return {{
                id = 'session-a', user_id = 'user-a', server_instance_id = 'instance-a',
                source_value = 41, source_generation = 1, state = 'SELECTING_CHARACTER',
                character_id = nil, version = 1, closed_at = nil
              }}
            end
            assert(sql:find('idx_sessions_character_open', 1, true)
              and sql:find('LIMIT 1 FOR UPDATE', 1, true))
            trace[#trace + 1] = 'conflicts'
            return {}
          end
          if sql:find('synex_instances', 1, true) then
            trace[#trace + 1] = 'instance'
            return {{ status = 'ready' }}
          end
          if sql:find('synex_instance_boots', 1, true) then
            trace[#trace + 1] = 'boot'
            return {{ boot_id = 'boot-a' }}
          end
          if sql:find('synex_cluster_leases', 1, true) then
            trace[#trace + 1] = 'lease'
            return {{ owner_id = 'instance-a:session-a', fencing_token = 1, valid = 1 }}
          end
          if sql:find('INSERT INTO', 1, true) and sql:find('synex_characters', 1, true) then
            trace[#trace + 1] = 'insert'
            inserts = inserts + 1
            characters[#characters + 1] = {
              id = parameters[1], user_id = parameters[2], slot = parameters[3],
              status = 'active', deleted_at = nil, active_slot_marker = 1
            }
            return 1
          end
          error('unexpected character slot statement')
        end
        local committed = handler(query)
        return committed, committed and nil or foundation.error(
          'TRANSACTION_ABORTED', 'fixture transaction aborted', { retryable = true })
      end
      local repository = SynexCoreFactories.identitySessionFencing({
        foundation = foundation, database = database, instanceId = 'instance-a'
      })
      local session = {
        id = 'session-a', userId = 'user-a', source = 41, sourceGeneration = 1,
        state = 'SELECTING_CHARACTER', version = 1, persistedVersion = 1,
        persistedSource = 41, persistedSourceGeneration = 1,
        clusterLease = {
          name = 'session:user-a:session-a', owner = 'instance-a:session-a',
          fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
        }
      }
      local input = { slot = 1, firstName = 'Katherine', lastName = 'Johnson' }
      local recreated = assert(repository:createCharacter(session, input, function() return true end))
      assert(recreated.slot == 1 and inserts == 1 and characters[1].active_slot_marker == nil
        and characters[2].active_slot_marker == 1)
      local duplicate, duplicateError = repository:createCharacter(
        session, input, function() return true end)
      assert(duplicate == nil and duplicateError.code == 'CHARACTER_SLOT_UNAVAILABLE')
      assert(inserts == 1 and traces[1][1] == 'slot' and traces[1][2] == 'active-slot'
        and traces[1][3] == 'own' and traces[1][4] == 'conflicts'
        and traces[1][#traces[1]] == 'insert')
      assert(traces[2][1] == 'slot' and traces[2][2] == 'active-slot' and #traces[2] == 2)
      characters[2].status, characters[2].deleted_at, characters[2].active_slot_marker =
        'deleted', 'fixture-later', nil
      assert(repository:createCharacter(session, input, function() return true end))
      assert(inserts == 2 and characters[3].active_slot_marker == 1)
      return table.concat({recreated.slot, duplicateError.code, inserts}, ':')
    `);
    assert.equal(result, '1:CHARACTER_SLOT_UNAVAILABLE:2');
  } finally {
    engine.global.close();
  }
});

test('boot and lease swaps between prepare and persistence fence create select unload and reconciliation', async () => {
  const engine = await authorityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 7 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-authority-swap')
      local outcomes = {}
      local function run(operation, loss)
        local authority = 'current'
        local insertWrites, sessionWrites, rollbacks = 0, 0, 0
        local durable = {
          id = 'session-a', user_id = 'user-a', server_instance_id = 'instance-a',
          source_value = 41, source_generation = 1,
          state = operation == 'unload' and 'ACTIVE' or 'SELECTING_CHARACTER',
          character_id = operation == 'unload' and 'character-a' or nil,
          version = 1, closed_at = nil
        }
        local character = {
          id = 'character-a', user_id = 'user-a', status = 'active', deleted_at = nil, version = 1
        }
        local database = {}
        function database:withTransaction(handler)
          local durableBefore = foundation.copy(durable)
          local writesBefore = { insertWrites, sessionWrites }
          local function query(sql, parameters)
            if sql:find('synex_character_slots', 1, true) then
              return {{ slot_limit = 4 }}
            end
            if sql:find('synex_characters', 1, true)
                and sql:find('\`deleted_at\` IS NULL', 1, true)
                and sql:find('\`slot\` = ?', 1, true) then
              return {}
            end
            if sql:find('synex_characters', 1, true) and sql:match('^%s*SELECT') then
              return { foundation.copy(character) }
            end
            if sql:find('synex_sessions', 1, true) and sql:match('^%s*SELECT') then
              if sql:find('WHERE \`id\` = ?', 1, true) then
                return parameters[1] == durable.id and { foundation.copy(durable) } or {}
              end
              assert(sql:find('idx_sessions_character_open', 1, true)
                and sql:find('LIMIT 1 FOR UPDATE', 1, true))
              return {}
            end
            if sql:find('synex_instances', 1, true) then
              return {{ status = 'ready' }}
            end
            if sql:find('synex_instance_boots', 1, true) then
              return authority == 'boot-lost' and {} or {{ boot_id = 'boot-a' }}
            end
            if sql:find('synex_cluster_leases', 1, true) then
              if authority == 'lease-lost' then
                return {{ owner_id = 'instance-b:stolen', fencing_token = 2, valid = 1 }}
              elseif authority == 'borrowed-lease' then
                return {{ owner_id = 'instance-b:borrowed', fencing_token = 1, valid = 1 }}
              end
              return {{ owner_id = 'instance-a:session-a', fencing_token = 1, valid = 1 }}
            end
            if sql:find('INSERT INTO', 1, true) and sql:find('synex_characters', 1, true) then
              insertWrites = insertWrites + 1
              return 1
            end
            if sql:find('UPDATE', 1, true) and sql:find('synex_sessions', 1, true) then
              sessionWrites = sessionWrites + 1
              if sql:find("'ACTIVE'", 1, true) then
                durable.source_value, durable.source_generation = parameters[1], parameters[2]
                durable.state, durable.character_id, durable.version = 'ACTIVE', parameters[3], parameters[4]
              else
                durable.source_value, durable.source_generation = parameters[1], parameters[2]
                durable.state, durable.character_id, durable.version = parameters[3], parameters[4], parameters[5]
              end
              return 1
            end
            error('unexpected authority-fencing statement')
          end
          local committed = handler(query)
          if not committed then
            durable = durableBefore
            insertWrites, sessionWrites = writesBefore[1], writesBefore[2]
          end
          return committed, committed and nil or foundation.error(
            'TRANSACTION_ABORTED', 'fixture transaction aborted', { retryable = true })
        end
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        local owners, players = registries.owners, registries.players
        owners:activate('synex_core')
        local domainEpoch = owners:activate('synex_authority_fixture')
        assert(players:createPending(-1, { sessionId = 'session-a' }))
        assert(players:bindJoined(-1, 41, {
          id = 'session-a', userId = 'user-a', state = durable.state,
          characterId = durable.character_id, version = 1, persistedVersion = 1,
          persistedSource = 41, persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:user-a:session-a',
            owner = loss == 'borrowed-lease' and 'instance-b:borrowed' or 'instance-a:session-a',
            fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
          },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }))
        if durable.character_id then assert(players:bindCharacter('session-a', durable.character_id)) end
        local sessionRepository = SynexCoreFactories.identitySessionFencing({
          foundation = foundation, database = database, instanceId = 'instance-a'
        })
        local messaging = {
          hooks = {
            run = function(_, owner, epoch, hookName, input)
              assert(owner == 'synex_core' and epoch == owners:epoch('synex_core'))
              assert(hookName == 'synex.characters.before_create')
              authority = loss
              return foundation.copy(input), nil
            end
          },
          events = { publish = function() return true, nil end }
        }
        local characterRepository = {
          create = function(_, session, input, guard)
            return sessionRepository:createCharacter(session, input, guard)
          end,
          getOwned = function(_, userId, characterId)
            assert(userId == character.user_id and characterId == character.id)
            return {
              id = character.id, userId = character.user_id, status = character.status,
              version = character.version
            }, nil
          end
        }
        local characters = SynexCoreFactories.identityCharacters({
          platform = platform, foundation = foundation, database = database, players = players,
          owners = owners, messaging = messaging, coreResource = 'synex_core',
          characterRepository = characterRepository, sessionRepository = sessionRepository,
          invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
          transition = function(candidate, target)
            candidate.state = target
            candidate.version = candidate.version + 1
            return candidate, nil
          end,
          leases = {}, instances = { bootId = function() return 'boot-a', nil end },
          instanceId = 'instance-a'
        })
        if operation ~= 'create' then
          assert(characters:registerParticipant('synex_authority_fixture', domainEpoch, {
            name = 'authority.swap',
            prepare = function()
              if operation == 'select' then authority = loss end
              return { prepared = true }, nil
            end,
            rollback = function()
              rollbacks = rollbacks + 1
              return true, nil
            end,
            unload = function()
              if operation == 'unload' then authority = loss end
              return true, nil
            end
          }))
        end
        if operation == 'create' then
          local created, createError = characters:create('session-a', {
            slot = 1, firstName = 'Grace', lastName = 'Hopper'
          })
          assert(created == nil and createError.code == 'LEASE_LOST')
          assert(insertWrites == 0 and sessionWrites == 0)
        elseif operation == 'select' then
          local selected, selectError = characters:select('session-a', 'character-a')
          assert(selected == nil and selectError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(selectError.details.cause == 'LEASE_LOST' and rollbacks == 1)
          local localSession = assert(players:getSession('session-a'))
          assert(localSession.state == 'SELECTING_CHARACTER' and localSession.characterId == nil)
          assert(sessionWrites == 0 and durable.state == 'SELECTING_CHARACTER')
        else
          local unloaded, unloadError = characters:unload('session-a', 'authority fixture')
          assert(unloaded == nil and unloadError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(unloadError.details.cause == 'LEASE_LOST' and sessionWrites == 0)
          local pending = assert(players:getSession('session-a'))
          assert(pending.state == 'SELECTING_CHARACTER' and pending.characterId == nil
            and pending.persistencePending == true)
          local pendingVersion = pending.version
          local report = assert(characters:reconcileUnloads(1))
          local after = assert(players:getSession('session-a'))
          assert(report.deferred == 1 and report.completed == 0 and sessionWrites == 0)
          assert(after.version == pendingVersion and after.persistencePending == true)
          assert(durable.state == 'ACTIVE' and durable.character_id == 'character-a')
        end
        outcomes[#outcomes + 1] = operation .. ':' .. loss
      end
      for _, loss in ipairs({ 'boot-lost', 'lease-lost', 'borrowed-lease' }) do
        run('create', loss)
        run('select', loss)
        run('unload', loss)
      end
      return table.concat(outcomes, '|')
    `);
    assert.equal(result, [
      'create:boot-lost', 'select:boot-lost', 'unload:boot-lost',
      'create:lease-lost', 'select:lease-lost', 'unload:lease-lost',
      'create:borrowed-lease', 'select:borrowed-lease', 'unload:borrowed-lease',
    ].join('|'));
  } finally {
    engine.global.close();
  }
});
