import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) await load(engine, `core/synex_core/server/${module}.lua`);
  return engine;
}

test('persistent RBAC caches subjects, enforces deny precedence, and invalidates on writes', async () => {
  const engine = await coreEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local now, subjectLoads = 1000, 0
      local assigned = true
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local store = {}
      function store:loadRoles()
        return {
          { role_name = 'operator', version = 3, permission_key = 'fixture.*', effect = 'allow' },
          { role_name = 'operator', version = 3, permission_key = 'fixture.delete', effect = 'deny' }
        }, nil
      end
      function store:loadSubject()
        subjectLoads = subjectLoads + 1
        return { version = subjectLoads, roles = assigned and {'operator'} or {} }, nil
      end
      function store:defineRole() return true, nil end
      function store:assign() assigned = true return true, nil end
      function store:revoke() assigned = false return true, nil end

      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} },
        rbacStore = store, rbacCacheTtlMs = 5000, rbacCacheMaximum = 64
      })
      assert(security.rbac:hydrate())
      assert(security.rbac:check('user:fixture', 'fixture.read'))
      assert(not security.rbac:check('user:fixture', 'fixture.delete'))
      assert(subjectLoads == 1)
      assert(security.rbac:revoke('user:fixture', 'operator', {
        actor = 'synex_fixture', actorType = 'resource', reason = 'fixture revoke', traceId = 'trace-fixture'
      }))
      assert(not security.rbac:check('user:fixture', 'fixture.read'))
      assert(subjectLoads == 2)
      local invalid, invalidError = security.rbac:defineRole('Invalid Role', {'fixture.read'}, {
        actor = 'synex_fixture', reason = 'fixture define', traceId = 'trace-fixture'
      })
      assert(invalid == nil and invalidError.code == 'INVALID_ROLE')
      local snapshot = security.rbac:snapshot()
      assert(snapshot.persistent and snapshot.hydrated and snapshot.roles == 1)
      return table.concat({subjectLoads, snapshot.roles, snapshot.cachedSubjects}, ':')
    `);
    assert.equal(result, '2:1:1');
  } finally {
    engine.global.close();
  }
});

test('access management commits audit atomically and replays identical deterministic entries', async () => {
  const engine = await coreEngine(['foundation', 'identity_repository']);
  try {
    const result = await engine.doString(`
      local auditCount, banRow, allowRow = 0, nil, nil
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and type(value.reason) == 'string' then
            return 'reason:' .. value.reason
          end
          return '{}'
        end,
        jsonDecode = function(value)
          local reason = type(value) == 'string' and value:match('^reason:(.+)$') or nil
          if not reason then error('invalid fixture JSON') end
          return { reason = reason }
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('access-replay')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('FROM synex_access_bans', 1, true)
            or sql:find('synex_access_bans', 1, true) and sql:find('SELECT', 1, true) then
            return banRow and { foundation.copy(banRow) } or {}
          end
          if sql:find('synex_allowlist_entries', 1, true) and sql:find('SELECT', 1, true) then
            return allowRow and { foundation.copy(allowRow) } or {}
          end
          if sql:find('synex_access_bans', 1, true) and sql:find('INSERT INTO', 1, true) then
            banRow = {
              user_id = parameters[2], reason = parameters[3], expires_at = parameters[5],
              revoked_at = nil
            }
            return { affectedRows = 1 }
          end
          if sql:find('synex_allowlist_entries', 1, true) and sql:find('INSERT INTO', 1, true) then
            allowRow = {
              user_id = parameters[2], expires_at = parameters[4], revoked_at = nil,
              audit_context_json = nil
            }
            return { affectedRows = 1 }
          end
          if sql:find('synex_audit_log', 1, true) and sql:find('INSERT INTO', 1, true) then
            auditCount = auditCount + 1
            if parameters[5] == 'access.allow' then allowRow.audit_context_json = parameters[10] end
            return { affectedRows = 1 }
          end
          error('unexpected SQL: ' .. sql)
        end
        local committed = handler(query)
        return committed, committed and nil or foundation.error('TRANSACTION_ABORTED', 'fixture abort')
      end
      local repositories = SynexCoreFactories.identityRepository({
        platform = platform, foundation = foundation, database = database,
        players = { bindIdentifier = function() end }, config = {}, instanceId = 'instance-a',
        normalizeIdentifiers = function() return {} end
      })
      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'unused', traceId = 'trace-access-01'
      }
      local ban = { id = 'ban-entry-01', userId = 'user-0001', reason = 'policy violation' }
      assert(repositories.access:ban(ban, context))
      assert(repositories.access:ban(foundation.copy(ban), context))
      local changedBan, changedBanError = repositories.access:ban({
        id = ban.id, userId = ban.userId, reason = 'different reason'
      }, context)
      assert(changedBan == nil and changedBanError.code == 'ACCESS_ENTRY_CONFLICT')
      local allow = { id = 'allow-entry-01', userId = 'user-0001', reason = 'approved' }
      assert(repositories.access:allow(allow, context))
      assert(repositories.access:allow(foundation.copy(allow), context))
      local changedAllow, changedAllowError = repositories.access:allow({
        id = allow.id, userId = allow.userId, reason = 'different approval'
      }, context)
      assert(changedAllow == nil and changedAllowError.code == 'ACCESS_ENTRY_CONFLICT')
      assert(auditCount == 2)
      return table.concat({auditCount, changedBanError.code, changedAllowError.code}, ':')
    `);
    assert.equal(result, '2:ACCESS_ENTRY_CONFLICT:ACCESS_ENTRY_CONFLICT');
  } finally {
    engine.global.close();
  }
});

test('persistent RBAC mutations write actor, reason, before, and after in the same transaction', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local auditRows, assignment = {}, nil
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.reason then return 'reason:' .. value.reason end
          if type(value) == 'table' and value.assigned ~= nil then return 'assigned:' .. tostring(value.assigned) end
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rbac-audit')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('synex_rbac_roles', 1, true) and sql:find('SELECT', 1, true) then return {} end
          if sql:find('assigned_by_ref', 1, true) and sql:find('SELECT', 1, true) then
            return assignment and {{ assigned_by_ref = 'synex_control', expires_at = nil }} or {}
          end
          if sql:find('synex_rbac_subject_roles', 1, true) and sql:find('INSERT INTO', 1, true) then
            assignment = true
          elseif sql:find('synex_rbac_subject_roles', 1, true) and sql:find('DELETE FROM', 1, true) then
            assignment = nil
          elseif sql:find('synex_audit_log', 1, true) and sql:find('INSERT INTO', 1, true) then
            auditRows[#auditRows + 1] = foundation.copy(parameters)
          end
          return { affectedRows = 1 }
        end
        local committed = handler(query)
        return committed, committed and nil or foundation.error('TRANSACTION_ABORTED', 'fixture abort')
      end
      local persistence = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      })
      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'operator request',
        traceId = 'trace-rbac-01'
      }
      assert(persistence.rbac:defineRole('operator', {
        { permission = 'fixture.read', effect = 'allow' }
      }, context))
      assert(persistence.rbac:assign('user:fixture', 'operator', context))
      assert(persistence.rbac:revoke('user:fixture', 'operator', context))
      assert(#auditRows == 3)
      assert(auditRows[1][2] == context.traceId and auditRows[1][4] == context.actor)
      assert(auditRows[1][5] == 'rbac.role.define' and auditRows[1][9] ~= nil)
      assert(auditRows[2][5] == 'rbac.assignment.assign'
        and auditRows[2][8] == 'assigned:false' and auditRows[2][9] == 'assigned:true')
      assert(auditRows[3][5] == 'rbac.assignment.revoke'
        and auditRows[3][8] == 'assigned:true' and auditRows[3][9] == 'assigned:false')
      for _, row in ipairs(auditRows) do assert(row[10] == 'reason:operator request') end
      return table.concat({#auditRows, auditRows[1][5], auditRows[3][5]}, ':')
    `);
    assert.equal(result, '3:rbac.role.define:rbac.assignment.revoke');
  } finally {
    engine.global.close();
  }
});

test('offline-first character reads use a bounded TTL cache and return defensive copies', async () => {
  const engine = await coreEngine(['foundation', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local now, fetches = 1000, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-cache')
      local repository = {}
      function repository:get(characterId)
        fetches = fetches + 1
        return {
          id = characterId, userId = 'user-fixture', slot = 1, status = 'active',
          firstName = 'Ada', lastName = 'Lovelace', metadata = { nested = { value = fetches } }, version = fetches
        }, nil
      end
      local players = {
        getSession = function(_, id)
          if id == 'session-fixture' then return { id = id, state = 'ACTIVE', characterId = 'char-fixture' } end
        end,
        getBySource = function(_, source)
          if source == 42 then return { id = 'session-fixture', state = 'ACTIVE', characterId = 'char-fixture' } end
        end
      }
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = {}, messaging = {}, coreResource = 'synex_core', characterRepository = repository,
        sessionRepository = {}, invokeOwned = function() end, transition = function() end,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instanceId = 'instance-a',
        cacheMaximum = 64, cacheTtlMs = 1000
      })
      local first = assert(characters:get('char-fixture'))
      first.metadata.nested.value = 999
      local second = assert(characters:getActive(42))
      assert(second.metadata.nested.value == 1 and fetches == 1)
      now = now + 1001
      local refreshed = assert(characters:get('char-fixture'))
      assert(refreshed.version == 2 and fetches == 2)
      for index = 1, 70 do assert(characters:get(('char-%02d'):format(index))) end
      local snapshot = characters:cacheSnapshot()
      assert(snapshot.entries == 64 and snapshot.maximum == 64 and snapshot.ttlMs == 1000)
      return table.concat({fetches, snapshot.entries, refreshed.version}, ':')
    `);
    assert.equal(result, '72:64:2');
  } finally {
    engine.global.close();
  }
});

test('character deletion persists reconciliation and retries domain commit errors', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local foundation, persistedPlan
      local now, participantCalls, leaseCount, published = 1000, 0, 0, 0
      local planState, planId = nil, nil
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.schema == 1 then
            persistedPlan = foundation.copy(value)
            return '{"schema":1}'
          end
          return '{}'
        end,
        jsonDecode = function() return foundation.copy(persistedPlan) end
      }
      foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('delete-reconcile')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local coreEpoch = registries.owners:activate('synex_core')
      local domainEpoch = registries.owners:activate('synex_domain')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('SELECT', 1, true) and sql:find('synex_characters', 1, true) then
            return {{ version = 1, status = 'active', deleted_at = nil }}
          end
          if sql:find('INSERT INTO', 1, true) and sql:find('synex_character_deletion_plans', 1, true) then
            planId, planState = parameters[1], 'executing'
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_characters', 1, true) then return { affectedRows = 1 } end
          return { affectedRows = 1 }
        end
        return handler(query), nil
      end
      function database:update(sql)
        if sql:find("state", 1, true) and sql:find("completed", 1, true) then planState = 'completed' end
        return 1, nil
      end
      function database:query(sql)
        assert(sql:find('synex_character_deletion_plans', 1, true))
        if planState == 'executing' then return {{ id = planId, plan_json = '{"schema":1}' }}, nil end
        return {}, nil
      end
      local players = {
        getSession = function(_, sessionId)
          if sessionId == 'session-a' then
            return { id = sessionId, userId = 'user-a', state = 'SELECTING_CHARACTER' }
          end
        end
      }
      local messaging = {
        hooks = {},
        events = { publish = function()
          published = published + 1
          return true, nil
        end }
      }
      local leases = {
        acquire = function(_, name, owner)
          leaseCount = leaseCount + 1
          assert(name:find('character-delete:', 1, true) == 1 and owner:find(':character-delete', 1, true))
          return { name = name, owner = owner, fencingToken = leaseCount }, nil
        end,
        release = function() return true, nil end
      }
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = database, players = players,
        owners = registries.owners, messaging = messaging, coreResource = 'synex_core',
        characterRepository = { getOwned = function()
          return { id = 'character-a', userId = 'user-a', version = 1 }, nil
        end },
        sessionRepository = {}, leases = leases, instanceId = 'instance-a',
        invokeOwned = function(entry, handler, ...)
          assert(registries.owners:isCurrent(entry.owner, entry.epoch))
          return foundation.safeCall(handler, ...)
        end,
        transition = function() return true, nil end
      })
      assert(characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'synex_domain', prepare = function() return true end,
        deletePreflight = function() return { action = 'anonymize' }, nil end,
        deleteCommit = function()
          participantCalls = participantCalls + 1
          if participantCalls == 1 then
            return nil, { code = 'DOMAIN_RETRY', message = 'retry', retryable = true }
          end
          return { applied = true }, nil
        end
      }))
      local invalidParticipant, invalidParticipantError = characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'invalid_timeout', prepare = function() return true end, timeoutMs = 99
      })
      assert(invalidParticipant == nil and invalidParticipantError.code == 'INVALID_PARTICIPANT')
      assert(characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'optional_slow', required = false, timeoutMs = 100,
        prepare = function() return true end,
        deletePreflight = function() now = now + 101 return { action = 'allow' }, nil end
      }))
      local deletion = assert(characters:delete('session-a', 'character-a'))
      assert(deletion.state == 'reconciling' and planState == 'executing')
      assert(participantCalls == 1 and published == 0)
      local report = assert(characters:reconcileDeletions(10))
      assert(report.completed == 1 and report.deferred == 0 and planState == 'completed')
      assert(participantCalls == 2 and published == 1 and leaseCount == 2)
      return table.concat({deletion.state, report.completed, participantCalls, published}, ':')
    `);
    assert.equal(result, 'reconciling:1:2:1');
  } finally {
    engine.global.close();
  }
});

test('required character participant deadlines fail closed for load and unload', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('participant-deadline')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local session = {
        id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER',
        characterId = nil, version = 1, persistedVersion = 1
      }
      local players = {}
      function players:getSession(id) if id == session.id then return foundation.copy(session) end end
      function players:sessionsByUser() return { foundation.copy(session) } end
      function players:updateSession(id, mutator)
        if id ~= session.id then return nil, foundation.error('SESSION_NOT_FOUND', 'missing') end
        local candidate = foundation.copy(session)
        mutator(candidate)
        session = candidate
        return foundation.copy(session), nil
      end
      function players:bindCharacter() return true, nil end
      function players:unbindCharacter() return true, nil end
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = registries.owners,
        messaging = { hooks = {}, events = {} }, coreResource = 'synex_core',
        characterRepository = { getOwned = function()
          return { id = 'character-a', userId = 'user-a', version = 1 }, nil
        end },
        sessionRepository = { update = function() return true, nil end },
        invokeOwned = function(entry, handler, ...)
          assert(registries.owners:isCurrent(entry.owner, entry.epoch))
          return foundation.safeCall(handler, ...)
        end,
        transition = function(candidate, target)
          candidate.state = target
          candidate.version = (candidate.version or 0) + 1
          return candidate, nil
        end,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instanceId = 'instance-a'
      })
      local invalidEpoch = registries.owners:activate('synex_invalid_commit')
      local invalidParticipant, invalidParticipantError = characters:registerParticipant(
        'synex_invalid_commit', invalidEpoch, {
          name = 'invalid_required_commit', prepare = function() return true end,
          commit = function() return true end
        }
      )
      assert(invalidParticipant == nil and invalidParticipantError.code == 'INVALID_PARTICIPANT')
      assert(invalidParticipantError.message:find('cannot define commit', 1, true))
      local optionalCommitCalls = 0
      local notificationEpoch = registries.owners:activate('synex_optional_commit')
      assert(characters:registerParticipant('synex_optional_commit', notificationEpoch, {
        name = 'optional_commit', required = false, priority = 10,
        prepare = function() return true end,
        commit = function()
          optionalCommitCalls = optionalCommitCalls + 1
          return nil, foundation.error('OPTIONAL_NOTIFICATION_FAILED', 'fixture')
        end
      }))
      local requiredEpoch = registries.owners:activate('synex_required_load')
      assert(characters:registerParticipant('synex_required_load', requiredEpoch, {
        name = 'required_load', timeoutMs = 100,
        prepare = function() now = now + 101 return true end
      }))
      local loaded, loadError = characters:select('session-a', 'character-a')
      assert(loaded == nil and loadError.code == 'PARTICIPANT_TIMEOUT')
      assert(session.state == 'SELECTING_CHARACTER' and session.characterId == nil)
      registries.owners:purge('synex_required_load', requiredEpoch, 'fixture')
      local optionalEpoch = registries.owners:activate('synex_optional_load')
      assert(characters:registerParticipant('synex_optional_load', optionalEpoch, {
        name = 'optional_load', required = false, timeoutMs = 100,
        prepare = function() now = now + 101 return true end
      }))
      assert(characters:select('session-a', 'character-a'))
      assert(session.state == 'ACTIVE' and session.characterId == 'character-a')
      local unloadEpoch = registries.owners:activate('synex_required_unload')
      assert(characters:registerParticipant('synex_required_unload', unloadEpoch, {
        name = 'required_unload', timeoutMs = 100, prepare = function() return true end,
        unload = function() now = now + 101 return true end
      }))
      local unloaded, unloadError = characters:unload('session-a', 'fixture')
      assert(unloaded == nil and unloadError.code == 'CHARACTER_UNLOAD_FAILED')
      assert(unloadError.details.cause == 'PARTICIPANT_TIMEOUT' and unloadError.details.stateRestored)
      assert(session.state == 'ACTIVE' and session.characterId == 'character-a')
      registries.owners:purge('synex_required_unload', unloadEpoch, 'fixture')
      assert(characters:unload('session-a', 'fixture'))
      assert(session.state == 'SELECTING_CHARACTER' and session.characterId == nil)
      assert(optionalCommitCalls == 1)
      return table.concat({invalidParticipantError.code, optionalCommitCalls, loadError.code,
        unloadError.code, session.state}, ':')
    `);
    assert.equal(result,
      'INVALID_PARTICIPANT:1:PARTICIPANT_TIMEOUT:CHARACTER_UNLOAD_FAILED:SELECTING_CHARACTER');
  } finally {
    engine.global.close();
  }
});

test('failed character unload persistence blocks reuse and reconciles bounded pending sessions', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('unload-reconciliation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local function addSession(tempSource, source, id, state, characterId)
        assert(players:createPending(tempSource, { sessionId = id }))
        assert(players:bindJoined(tempSource, source, {
          id = id, userId = 'user-a', state = state, characterId = characterId,
          version = 5, persistedVersion = 5
        }))
        if characterId then assert(players:bindCharacter(id, characterId)) end
      end
      addSession(-1, 41, 'session-a', 'ACTIVE', 'character-a')
      addSession(-2, 42, 'session-b', 'SELECTING_CHARACTER', nil)
      local persisted = {
        ['session-a'] = { state = 'ACTIVE', characterId = 'character-a', version = 5 }
      }
      local failNext = { ['session-a'] = true }
      local sessionRepository = {}
      function sessionRepository:update(candidate)
        if failNext[candidate.id] then
          failNext[candidate.id] = nil
          return nil, foundation.error('DATABASE_ERROR', 'fixture outage', { retryable = true })
        end
        persisted[candidate.id] = {
          state = candidate.state, characterId = candidate.characterId, version = candidate.version
        }
        return true, nil
      end
      function sessionRepository:getState(sessionId)
        return foundation.copy(persisted[sessionId]), nil
      end
      local repositoryCalls = 0
      local characterRepository = {
        create = function() repositoryCalls = repositoryCalls + 1 return nil end,
        getOwned = function() repositoryCalls = repositoryCalls + 1 return nil end
      }
      local function transition(candidate, target)
        local allowed = (candidate.state == 'ACTIVE' and target == 'UNLOADING_CHARACTER')
          or (candidate.state == 'UNLOADING_CHARACTER' and target == 'SELECTING_CHARACTER')
        if not allowed then return nil, foundation.error('INVALID_SESSION_TRANSITION', 'fixture') end
        candidate.state = target
        candidate.version = candidate.version + 1
        return candidate, nil
      end
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = registries.owners, messaging = { hooks = {}, events = {} },
        coreResource = 'synex_core', characterRepository = characterRepository,
        sessionRepository = sessionRepository,
        invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
        transition = transition,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instanceId = 'instance-a', pendingUnloadMaximum = 64
      })
      local unloaded, unloadError = characters:unload('session-a', 'fixture')
      assert(unloaded == nil and unloadError.code == 'SESSION_PERSISTENCE_PENDING')
      local pending = assert(players:getSession('session-a'))
      assert(pending.state == 'SELECTING_CHARACTER' and pending.characterId == nil
        and pending.persistencePending == true)
      local selected, selectError = characters:select('session-b', 'character-a')
      local created, createError = characters:create('session-a', {})
      local deleted, deleteError = characters:delete('session-a', 'character-a')
      assert(selected == nil and selectError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(created == nil and createError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(deleted == nil and deleteError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(repositoryCalls == 0)
      local report = assert(characters:reconcileUnloads(1))
      local reconciled = assert(players:getSession('session-a'))
      assert(report.completed == 1 and report.pending == 0 and reconciled.persistencePending == nil)
      assert(reconciled.persistedVersion == reconciled.version)

      addSession(-3, 43, 'session-c', 'ACTIVE', 'character-c')
      persisted['session-c'] = { state = 'ACTIVE', characterId = 'character-c', version = 5 }
      failNext['session-c'] = true
      assert(characters:unload('session-c', 'fixture') == nil)
      players:removeSession('session-c')
      local abandoned = assert(characters:reconcileUnloads(1))
      local snapshot = characters:cacheSnapshot()
      assert(abandoned.abandoned == 1 and abandoned.pending == 0
        and snapshot.pendingSessionWrites == 0 and snapshot.pendingSessionWriteMaximum == 64)
      return table.concat({unloadError.code, report.completed, abandoned.abandoned, repositoryCalls}, ':')
    `);
    assert.equal(result, 'SESSION_PERSISTENCE_PENDING:1:1:0');
  } finally {
    engine.global.close();
  }
});

test('recurring scheduler entries expose bounded worker health and recover after failures', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local now, callbacks, attempts = 1000, {}, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(delay, callback) callbacks[#callbacks + 1] = callback end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('worker-health')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      assert(lifecycle.scheduler:every('synex_fixture', epoch, 100, function()
        attempts = attempts + 1
        now = now + 5
        if attempts <= 3 then return nil, { code = 'FIXTURE_FAILURE' } end
        return true, nil
      end, { name = 'fixture.worker' }))
      for index = 1, 3 do callbacks[index]() end
      local unhealthy = lifecycle.scheduler:snapshot()[1]
      assert(unhealthy.health == 'UNHEALTHY' and unhealthy.runs == 3 and unhealthy.lastError == 'FIXTURE_FAILURE')
      callbacks[4]()
      local recovered = lifecycle.scheduler:snapshot()[1]
      assert(recovered.health == 'HEALTHY' and recovered.runs == 4 and recovered.lastError == nil)
      return table.concat({unhealthy.health, recovered.health, recovered.durationMs}, ':')
    `);
    assert.equal(result, 'UNHEALTHY:HEALTHY:5');
  } finally {
    engine.global.close();
  }
});

test('live dependency validation requires running providers, real registration, and granted capabilities', async () => {
  const engine = await coreEngine([
    'foundation', 'registries', 'lifecycle', 'security', 'bootstrap_discovery',
  ]);
  try {
    const result = await engine.doString(`
      local states = {
        synex_provider = 'started', synex_consumer = 'started',
        synex_optional = 'started', synex_blocked = 'started'
      }
      local manifests = {
        synex_provider = {
          critical = true, capabilities = { request = {} },
          services = { provide = {'synex.fixture@1'}, require = {}, optional = {} }
        },
        synex_consumer = {
          critical = true, capabilities = { request = {'synex.fixture.read'} },
          services = { provide = {}, require = {'synex.fixture@1'}, optional = {} }
        },
        synex_optional = {
          critical = true, capabilities = { request = {} },
          services = { provide = {}, require = {}, optional = {'synex.fixture@1'} }
        },
        synex_blocked = {
          critical = true, capabilities = { request = {'synex.fixture.write'} },
          services = { provide = {}, require = {}, optional = {} }
        }
      }
      local names = {'synex_provider', 'synex_consumer', 'synex_optional', 'synex_blocked'}
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function(raw) return manifests[raw] end,
        numResources = function() return #names end,
        resourceByIndex = function(index) return names[index + 1] end,
        resourceMetadata = function(name, key)
          if key == 'synex_manifest' then return 'synex.resource.json' end
        end,
        loadResourceFile = function(name) return name end,
        resourceState = function(name) return states[name] or 'missing' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = {
            synex_consumer = { allow = {'synex.fixture.read'}, deny = {} },
            synex_blocked = { allow = {}, deny = {} }
          }
        }
      })
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation,
        resourceManifest = { validate = function(_, name, manifest)
          assert(name == manifest.name or manifest.name == nil)
          return true, nil
        end },
        security = security, registries = registries, lifecycle = lifecycle,
        stateService = { captureOwner = function() end, restoreOwner = function() end }
      })
      assert(discovery.discoverAll())
      local initial = discovery.validateActive()
      assert(#initial == 4)
      local sawOptional = false
      for _, finding in ipairs(initial) do
        if finding.consumer == 'synex_optional' then
          assert(finding.kind == 'dependency' and finding.severity == 'warning')
          sawOptional = true
        end
      end
      assert(sawOptional)
      lifecycle.dependencies:provide('synex_provider', 'synex.fixture', '1.0.0')
      local registered = discovery.validateActive()
      assert(#registered == 1 and registered[1].kind == 'capability'
        and registered[1].resource == 'synex_blocked' and registered[1].severity == 'error')
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', 'UNHEALTHY', 'CLOSED'))
      local unhealthy = discovery.validateActive()
      assert(#unhealthy == 4)
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', 'HEALTHY', 'OPEN'))
      local opened = discovery.validateActive()
      assert(#opened == 4)
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', 'HEALTHY', 'CLOSED'))
      assert(#discovery.validateActive() == 1)
      states.synex_provider = 'stopped'
      local stopped = discovery.validateActive()
      assert(#stopped == 3)
      local stoppedEnforced = discovery.validateActive(nil, true)
      local sawStoppedCritical = false
      for _, finding in ipairs(stoppedEnforced) do
        if finding.kind == 'resource' and finding.resource == 'synex_provider'
            and finding.state == 'stopped' and finding.severity == 'error' then
          sawStoppedCritical = true
        end
      end
      assert(#stoppedEnforced == 4 and sawStoppedCritical)
      states.synex_blocked = 'stopped'
      states.synex_provider = 'started'
      assert(#discovery.validateActive() == 0)
      local inactiveBlocked = discovery.validateActive(nil, true)
      assert(#inactiveBlocked == 1 and inactiveBlocked[1].kind == 'resource'
        and inactiveBlocked[1].resource == 'synex_blocked')
      lifecycle.dependencies:removeProvider('synex_provider')
      local missingRegistration = discovery.validateActive()
      assert(#missingRegistration == 3)
      return table.concat({
        #initial, #registered, #unhealthy, #opened, #stopped,
        #stoppedEnforced, #inactiveBlocked, #missingRegistration
      }, ':')
    `);
    assert.equal(result, '4:1:4:4:3:4:1:3');
  } finally {
    engine.global.close();
  }
});

test('resource dependency versions fail closed at runtime and optional metadata degrades to warnings', async () => {
  const engine = await coreEngine(['foundation', 'resource_manifest', 'bootstrap_discovery']);
  try {
    const result = await engine.doString(`
      local states = { synex_entities = 'started', synex_core = 'started', oxmysql = 'started' }
      local versions = { synex_core = '0.1.0', oxmysql = '2.14.1' }
      local duplicateVersions = {}
      local manifest = {
        critical = true,
        capabilities = { request = {} },
        services = { provide = {}, require = {}, optional = {} },
        dependencies = {
          required = {
            { name = 'synex_core', version = '>=0.1.0' },
            { name = 'oxmysql', version = '>=2.14.1 <3.0.0' }
          },
          optional = {}, development = {}
        }
      }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        resourceState = function(name) return states[name] or 'missing' end,
        resourceMetadata = function(name, key, index)
          if key ~= 'version' then return nil end
          if index == 1 then return duplicateVersions[name] end
          return versions[name]
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local resourceManifest = SynexCoreFactories.resourceManifest({ foundation = foundation })
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation, resourceManifest = resourceManifest,
        security = { capabilities = { preflight = function() return {} end } },
        registries = {},
        lifecycle = { dependencies = {
          validate = function() return {} end,
          snapshot = function() return { providers = {}, providerHealth = {} } end
        } },
        stateService = {}, manifests = { synex_entities = manifest }
      })

      assert(#discovery.validateActive() == 0)
      versions.oxmysql = '3.0.0'
      local incompatible = discovery.validateActive()
      assert(#incompatible == 1 and incompatible[1].dependency == 'oxmysql'
        and incompatible[1].code == 'DEPENDENCY_VERSION_INCOMPATIBLE'
        and incompatible[1].severity == 'error')
      manifest.critical = false
      local nonCritical = discovery.validateActive()
      assert(#nonCritical == 1 and nonCritical[1].code == 'DEPENDENCY_VERSION_INCOMPATIBLE'
        and nonCritical[1].severity == 'warning')
      manifest.critical = true
      versions.oxmysql = nil
      local missing = discovery.validateActive()
      assert(#missing == 1 and missing[1].code == 'DEPENDENCY_VERSION_METADATA_MISSING'
        and missing[1].severity == 'error')
      versions.oxmysql = 'v2.14.1'
      local invalid = discovery.validateActive()
      assert(#invalid == 1 and invalid[1].code == 'DEPENDENCY_VERSION_METADATA_INVALID'
        and invalid[1].severity == 'error')
      versions.oxmysql = '2.14.1'
      duplicateVersions.oxmysql = '2.14.2'
      local ambiguous = discovery.validateActive()
      assert(#ambiguous == 1 and ambiguous[1].code == 'DEPENDENCY_VERSION_METADATA_AMBIGUOUS'
        and ambiguous[1].severity == 'error')
      duplicateVersions.oxmysql = nil
      states.oxmysql = 'stopped'
      local unavailable = discovery.validateActive()
      assert(#unavailable == 1 and unavailable[1].code == 'DEPENDENCY_RESOURCE_UNAVAILABLE'
        and unavailable[1].severity == 'error')
      states.oxmysql = 'started'
      manifest.dependencies.optional = {{ name = 'synex_observer', version = '^1.0.0' }}
      local optional = discovery.validateActive()
      assert(#optional == 1 and optional[1].dependency == 'synex_observer'
        and optional[1].code == 'DEPENDENCY_RESOURCE_UNAVAILABLE'
        and optional[1].severity == 'warning')
      return table.concat({
        incompatible[1].code, missing[1].code, invalid[1].code,
        ambiguous[1].code, unavailable[1].code, optional[1].severity
      }, ':')
    `);
    assert.equal(
      result,
      'DEPENDENCY_VERSION_INCOMPATIBLE:DEPENDENCY_VERSION_METADATA_MISSING:'
        + 'DEPENDENCY_VERSION_METADATA_INVALID:DEPENDENCY_VERSION_METADATA_AMBIGUOUS:'
        + 'DEPENDENCY_RESOURCE_UNAVAILABLE:warning',
    );
  } finally {
    engine.global.close();
  }
});

test('dependency health refresh clears recovered registry findings without changing resource state', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      local findings = {
        { kind = 'provider', resource = 'synex_provider', service = 'synex.fixture', severity = 'error' },
        { kind = 'resource-dependency', resource = 'synex_consumer', dependency = 'oxmysql', severity = 'warning' }
      }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      registries.resources:upsert('synex_provider', {
        name = 'synex_provider', critical = true, services = { provide = {'synex.fixture@1'} }
      }, 'STARTED')
      registries.resources:upsert('synex_consumer', {
        name = 'synex_consumer', critical = false, services = { provide = {} }
      }, 'STARTED')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      for _, target in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
      }) do assert(lifecycle.core:transition(target, 'fixture')) end
      SynexCoreFactories.commands = function() return { bind = function() return true end } end
      local noop = function() return true end
      local runtime = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        coreResource = 'synex_core', messaging = {}, identity = {}, reloadSnapshots = {},
        registries = registries, lifecycle = lifecycle, facadeCache = {}, defaultConfig = {},
        persistence = {}, manifests = { synex_provider = {}, synex_consumer = {} }, reliability = {},
        sagaRuntime = {}, retention = {}, security = {},
        api = {
          getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
          registerCoreContracts = noop, registerCoreServices = noop
        },
        discovery = {
          discoverResource = noop, discoverAll = noop,
          validateActive = function() return findings end,
          ensureOwner = noop, supportsStateHandoff = noop,
          captureStateHandoff = noop, restoreStateHandoff = noop
        }
      })
      local first, firstCritical = runtime:refreshDependencyHealth()
      local degraded = assert(registries.resources:get('synex_provider'))
      local dependencyDegraded = assert(registries.resources:get('synex_consumer'))
      assert(#first == 2 and firstCritical == 1)
      assert(degraded.state == 'STARTED' and degraded.health.status == 'UNHEALTHY')
      assert(dependencyDegraded.state == 'STARTED' and dependencyDegraded.health.status == 'DEGRADED')
      assert(lifecycle.core:get() == 'DEGRADED')
      findings = {}
      local recovered, recoveredCritical = runtime:refreshDependencyHealth()
      local healthy = assert(registries.resources:get('synex_provider'))
      local dependencyHealthy = assert(registries.resources:get('synex_consumer'))
      assert(#recovered == 0 and recoveredCritical == 0)
      assert(healthy.state == 'STARTED' and healthy.health.status == 'HEALTHY')
      assert(dependencyHealthy.state == 'STARTED' and dependencyHealthy.health.status == 'HEALTHY')
      assert(#healthy.health.reasons == 0 and lifecycle.core:get() == 'READY')
      return table.concat({
        degraded.health.status, dependencyDegraded.health.status,
        healthy.health.status, dependencyHealthy.health.status, healthy.state
      }, ':')
    `);
    assert.equal(result, 'UNHEALTHY:DEGRADED:HEALTHY:HEALTHY:STARTED');
  } finally {
    engine.global.close();
  }
});

test('capability delegation is bridge-granted, target-declared, and limited to active resources', async () => {
  const engine = await coreEngine(['foundation', 'security', 'bootstrap_api']);
  try {
    const result = await engine.doString(`
      local states = { synex_bridge = 'started', synex_consumer = 'started', synex_attacker = 'started' }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        invokingResource = function() return nil end,
        resourceState = function(name) return states[name] or 'missing' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('delegate-test')
      local owners = {
        isCurrent = function(_, resource, epoch) return epoch == 1 and states[resource] == 'started' end,
        beginOperation = function() return 'operation-a', nil end,
        finishOperation = function() return true end
      }
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = {
            synex_bridge = { allow = {'synex.capabilities.delegate'}, deny = {} },
            synex_consumer = { allow = {'synex.compat.qb.read'}, deny = {} },
            synex_attacker = { allow = {}, deny = {} }
          }
        }
      })
      security.capabilities:registerManifest('synex_bridge', {
        capabilities = { request = {'synex.capabilities.delegate'} }
      })
      security.capabilities:registerManifest('synex_consumer', {
        capabilities = { request = {'synex.compat.qb.read'} }
      })
      security.capabilities:registerManifest('synex_attacker', {
        capabilities = { request = {'synex.capabilities.delegate'} }
      })
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform, foundation = foundation, registries = { owners = owners },
        security = security, identity = {}, contractSystem = {}, messaging = {},
        coreResource = 'synex_core', runtime = {}, stateService = {}, lifecycle = {},
        reliability = {}, sagaRuntime = {}, facadeCache = {}, defaultConfig = { retention = {} },
        ensureOwner = function(resource)
          if states[resource] ~= 'started' then return nil, foundation.error('RESOURCE_NOT_STARTED', 'stopped') end
          return 1, nil
        end
      })
      local bridge = assert(api.getAPIForCaller('synex_bridge', '^1.0.0'))
      assert(bridge.Capabilities.checkResource('synex_consumer', 'synex.compat.qb.read', 'GetPlayerData'))
      local malformed, malformedError = bridge.Capabilities.checkResource('../consumer', 'synex.compat.qb.read')
      assert(malformed == nil and malformedError.code == 'INVALID_DELEGATION_TARGET')
      states.synex_consumer = 'stopped'
      local stopped, stoppedError = bridge.Capabilities.checkResource(
        'synex_consumer', 'synex.compat.qb.read', 'GetPlayerData')
      assert(stopped == nil and stoppedError.code == 'DELEGATION_TARGET_UNAVAILABLE')
      local attacker = assert(api.getAPIForCaller('synex_attacker', '^1.0.0'))
      local denied, deniedError = attacker.Capabilities.checkResource(
        'synex_bridge', 'synex.capabilities.delegate', 'impersonate')
      assert(denied == nil and deniedError.code == 'CAPABILITY_DENIED')
      return table.concat({malformedError.code, stoppedError.code, deniedError.code}, ':')
    `);
    assert.equal(result,
      'INVALID_DELEGATION_TARGET:DELEGATION_TARGET_UNAVAILABLE:CAPABILITY_DENIED');
  } finally {
    engine.global.close();
  }
});

test('control diagnostic search crosses its declared and granted capability gateway', async () => {
  const [descriptorSource, policySource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_control/synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/config/capabilities.json'), 'utf8'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    capabilities: { request: string[] };
  };
  const policy = JSON.parse(policySource) as {
    default: { allow: string[]; deny: string[] };
    resources: { synex_control: { allow: string[]; deny: string[] } };
  };
  const luaList = (values: string[]): string =>
    `{${values.map((value) => JSON.stringify(value)).join(',')}}`;
  const engine = await coreEngine(['foundation', 'security', 'bootstrap_api']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        invokingResource = function() return nil end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('control-search-test')
      local owners = {
        isCurrent = function(_, resource, epoch)
          return resource == 'synex_control' and epoch == 1
        end,
        beginOperation = function() return 'operation-control-search', nil end,
        finishOperation = function() return true end
      }
      local security = SynexCoreFactories.security({
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = {
          default = {
            allow = ${luaList(policy.default.allow)},
            deny = ${luaList(policy.default.deny)}
          },
          resources = {
            synex_control = {
              allow = ${luaList(policy.resources.synex_control.allow)},
              deny = ${luaList(policy.resources.synex_control.deny)}
            }
          }
        }
      })
      security.capabilities:registerManifest('synex_control', {
        capabilities = { request = ${luaList(descriptor.capabilities.request)} }
      })
      local searches = 0
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform,
        foundation = foundation,
        registries = { owners = owners },
        security = security,
        identity = {},
        contractSystem = {},
        messaging = {},
        coreResource = 'synex_core',
        runtime = {},
        stateService = {},
        lifecycle = {},
        reliability = {
          audit = {
            search = function(_, request)
              searches = searches + 1
              return { kind = request.kind, value = request.value }, nil
            end
          }
        },
        sagaRuntime = {},
        facadeCache = {},
        defaultConfig = { retention = {} },
        ensureOwner = function(resource)
          if resource == 'synex_control' then return 1, nil end
          return nil, foundation.error('RESOURCE_NOT_STARTED', 'stopped')
        end
      })
      local control = assert(api.getAPIForCaller('synex_control', '^1.0.0'))
      local value, searchError = control.Diagnostics.search({
        kind = 'trace', value = 'trace-control-search'
      })
      assert(searchError == nil, searchError and searchError.code or 'search failed')
      assert(value ~= nil)
      assert(searches == 1)
      return value.kind .. ':' .. value.value
    `);
    assert.equal(result, 'trace:trace-control-search');
  } finally {
    engine.global.close();
  }
});

test('queue admission preserves reserved slots for ACE staff and maintenance fails closed', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_connections']);
  try {
    const result = await engine.doString(`
      local now, completions, leaseNames = 1000, {}, {}
      local staff, admission = false, false
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function(source) return {'license:' .. tostring(source)} end,
        isPlayerAceAllowed = function(source, ace) return staff and source == -3 and ace == 'synex.queue.staff' end,
        defer = function() end,
        wait = function(delay) now = now + delay end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('queue-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'occupied' }))
      assert(players:bindJoined(-1, 11, {
        id = 'occupied', userId = 'existing-user', state = 'SELECTING_CHARACTER', version = 1
      }))
      local config = {
        duplicatePolicy = 'allow', allowlistRequired = false, queueEnabled = false,
        pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45,
        maximumActiveSessions = 2, maximumQueued = 4, queueReservedSlots = 1,
        queueStaffAce = 'synex.queue.staff', maintenanceMode = false
      }
      local leases = {
        acquire = function(_, name, owner, ttl)
          leaseNames[#leaseNames + 1] = name
          return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl }, nil
        end,
        release = function() return true, nil end,
        renew = function() return true, nil end
      }
      local instances = {
        requestRemoteKicks = function() return 0, nil end,
        touchSessions = function() return true, nil end,
        heartbeat = function() return {}, nil end,
        pendingLocalControls = function() return {}, nil end,
        completeControl = function() return true, nil end
      }
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = {
          canAdmitPlayers = function() return admission end,
          setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() end } }, config = config,
        instanceId = 'instance-a', coreResource = 'synex_core', leases = leases, instances = instances,
        characters = {}, userRepository = { authenticate = function(_, identifiers)
          return { id = identifiers[1]:gsub('[^A-Za-z0-9_-]', '_'), status = 'active' }, nil
        end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function(values) return {{ type = 'license', value = values[1] }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      local function deferrals(source)
        return {
          defer = function() end, update = function() end,
          done = function(reason) completions[source] = reason == nil and '<accepted>' or reason end
        }
      end
      connection:handleConnecting(-5, 'NotReady', deferrals(-5))
      assert(completions[-5]:find('starting', 1, true) and players:getPending(-5) == nil)
      admission = true
      connection:handleConnecting(-2, 'Ordinary', deferrals(-2))
      assert(completions[-2]:find('active session limit', 1, true))
      staff = true
      connection:handleConnecting(-3, 'Staff', deferrals(-3))
      assert(completions[-3] == '<accepted>' and players:getPending(-3).staff == true)
      assert(leaseNames[1]:match('^session:') and leaseNames[1]:find(':sessi_', 1, true))
      config.maintenanceMode = true
      staff = false
      connection:handleConnecting(-4, 'Maintenance', deferrals(-4))
      assert(completions[-4]:find('maintenance mode', 1, true))
      local snapshot = connection:snapshot()
      assert(snapshot.reservedSlots == 1 and snapshot.rejected == 1 and snapshot.maintenance)
      return table.concat({snapshot.rejected, snapshot.reservedSlots, #leaseNames}, ':')
    `);
    assert.equal(result, '1:1:1');
  } finally {
    engine.global.close();
  }
});

test('disconnect cleanup attempts every step and always removes runtime authority', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_connections']);
  try {
    const result = await engine.doString(`
      local now, closeAttempts, purges = 1000, 0, 0
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + delay end, dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('disconnect-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'session-fixture' }))
      assert(players:bindJoined(-1, 42, {
        id = 'session-fixture', userId = 'user-fixture', state = 'ACTIVE', version = 1,
        clusterLease = { name = 'session:user-fixture', owner = 'instance-a:session-fixture', fencingToken = 1, ttlSeconds = 45 }
      }))
      local lifecycleHealth = nil
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function(_, _, status) lifecycleHealth = status end
        } },
        messaging = { network = { purgeSource = function() purges = purges + 1 error('purge failed') end } },
        config = { duplicatePolicy = 'deny_new', clusterSessionLeaseSeconds = 45, queueReconnectGraceMs = 60000 },
        instanceId = 'instance-a', coreResource = 'synex_core',
        leases = { release = function() return nil, { code = 'LEASE_RELEASE_FAILED' } end },
        instances = {},
        characters = { unload = function() return nil, { code = 'UNLOAD_FAILED' } end },
        userRepository = {}, accessRepository = {},
        sessionRepository = { close = function()
          closeAttempts = closeAttempts + 1
          return nil, { code = 'CLOSE_FAILED' }
        end },
        invokeOwned = function() end, normalizeIdentifiers = function() return {} end,
        sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
        transition = function(session, target) session.state = target return true, nil end
      })
      local report = connection:handleDropped(42, 'fixture')
      assert(report.closed == false and #report.failures >= 4)
      assert(players:getSession('session-fixture') == nil and closeAttempts == 2 and purges == 1)
      assert(lifecycleHealth == 'DEGRADED' and connection:snapshot().reconnectGraceEntries == 1)
      return table.concat({#report.failures, closeAttempts, purges, lifecycleHealth}, ':')
    `);
    assert.match(String(result), /^\d+:2:1:DEGRADED$/u);
  } finally {
    engine.global.close();
  }
});

test('diagnostic audit search is bounded, exact, and redacts unsafe references', async () => {
  const engine = await coreEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local capturedSql, capturedParameters
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('audit-search')
      local database = {}
      function database:query(sql, parameters)
        capturedSql, capturedParameters = sql, parameters
        return {
          {
            event_id = 'event-1', occurred_at = '2026-08-22 12:00:00',
            actor_type = 'resource', actor_id = 'synex_fixture', action = 'fixture.read',
            target_type = 'character', target_id = 'character-fixture', trace_id = 'trace-1'
          },
          {
            event_id = 'event-2', occurred_at = '2026-08-22 11:59:00',
            actor_type = 'user', actor_id = 'license:private', action = 'fixture.change',
            target_type = 'identifier', target_id = 'license:private', trace_id = 'trace-2'
          },
          {
            event_id = 'event-3', occurred_at = '2026-08-22 11:58:00',
            actor_type = 'system', actor_id = 'synex_core', action = 'fixture.old',
            target_type = 'resource', target_id = 'synex_fixture', trace_id = 'trace-3'
          }
        }, nil
      end
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', features = {}, sha256 = function() return 'hash' end
      })
      local search = assert(reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', limit = 2
      }))
      assert(search.kind == 'resource' and search.limit == 2 and search.truncated == true)
      assert(#search.entries == 2 and search.entries[1].actor.reference == 'synex_fixture')
      assert(search.entries[2].actor.reference == '[redacted]')
      assert(search.entries[2].target.reference == '[redacted]' and search.entries[2].masked == true)
      assert(capturedSql:find("actor_type", 1, true) and capturedSql:find("target_type", 1, true))
      assert(capturedParameters[1] == 'synex_fixture' and capturedParameters[2] == 'synex_fixture')
      assert(capturedParameters[3] == 3)
      local invalid, invalidError = reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', limit = 65
      })
      assert(invalid == nil and invalidError.code == 'INVALID_AUDIT_SEARCH')
      local unknown, unknownError = reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', extra = true
      })
      assert(unknown == nil and unknownError.code == 'INVALID_AUDIT_SEARCH')
      return table.concat({search.kind, #search.entries, tostring(search.truncated)}, ':')
    `);
    assert.equal(result, 'resource:2:true');
  } finally {
    engine.global.close();
  }
});

test('operator command registry is console-only, typed, bounded, and service-backed', async () => {
  const engine = await coreEngine(['foundation', 'commands']);
  try {
    const result = await engine.doString(`
      local registered, emitted, serviceCalls, auditCalls = {}, {}, 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value) emitted[#emitted + 1] = value return '{}' end,
        registerCommand = function(name, handler, restricted)
          registered[name] = { handler = handler, restricted = restricted }
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('commands-test')
      local owners = {
        epoch = function() return 7 end,
        isCurrent = function(_, resource, epoch) return resource == 'synex_core' and epoch == 7 end
      }
      local commands = SynexCoreFactories.commands({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        runtime = { doctor = function() return { status = 'PASS' }, nil end },
        lifecycle = {
          core = { snapshot = function() return { state = 'READY', operational = true } end },
          scheduler = { snapshot = function() return {{ health = 'HEALTHY' }} end }
        },
        registries = {
          owners = owners,
          resources = { list = function() return {{
            name = 'synex_fixture', state = 'STARTED', epoch = 1,
            manifest = { version = '1.0.0' }, health = { status = 'HEALTHY' }
          }} end },
          players = { summary = function() return { activeSessions = 0, pendingConnections = 0 } end }
        },
        identity = { connections = { snapshot = function() return { queued = 0, maximumQueued = 128 } end } },
        persistence = {
          instances = { snapshot = function() return { total = 1, healthy = 1, stale = 0 } end },
          migrations = { snapshot = function() return { resources = {}, totals = {}, truncated = false }, nil end },
          rbac = { summary = function() return { roles = 1, activeAssignments = 0 }, nil end }
        },
        reliability = { audit = { search = function(_, request)
          auditCalls = auditCalls + 1
          return { kind = request.kind, entries = {}, limit = request.limit, truncated = false }, nil
        end } },
        messaging = { services = { call = function(_, caller, epoch, name, range, method, request)
          serviceCalls = serviceCalls + 1
          assert(caller == 'synex_core' and epoch == 7 and range == '^1.0.0' and next(request) == nil)
          return { service = name, method = method }, nil
        end } },
        security = {
          rbac = { snapshot = function() return { persistent = true, hydrated = true } end },
          capabilities = { snapshot = function() return {
            synex_fixture = { requested = { ['synex.fixture.read'] = true }, policy = {
              allow = {'synex.fixture.read'}, deny = {}
            } }
          } end }
        }
      })
      assert(commands:bind())
      assert(registered.synex.restricted and registered.synex_status.restricted and registered.synex_doctor.restricted)
      local denied, deniedError = commands:dispatch(42, {'status'})
      assert(denied == nil and deniedError.code == 'CONSOLE_ONLY')
      local invalid, invalidError = commands:dispatch(0, {'trace', 'resource', 'synex_fixture', '65'})
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT' and auditCalls == 0)
      local trace = assert(commands:dispatch(0, {'trace', 'resource', 'synex_fixture', '8'}))
      assert(trace.kind == 'resource' and trace.limit == 8 and auditCalls == 1)
      local ledger = assert(commands:dispatch(0, {'ledger'}))
      local entities = assert(commands:dispatch(0, {'entities'}))
      assert(ledger.available and ledger.summary.service == 'synex.accounts')
      assert(entities.available and entities.summary.service == 'synex.entities')
      assert(serviceCalls == 2 and emitted[#emitted].ok == true)
      return table.concat({deniedError.code, invalidError.code, trace.limit, serviceCalls}, ':')
    `);
    assert.equal(result, 'CONSOLE_ONLY:INVALID_ARGUMENT:8:2');
  } finally {
    engine.global.close();
  }
});

test('durable saga runtime resumes with leases, retries, deadlines, and reverse compensation', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'saga_runtime']);
  try {
    const result = await engine.doString(`
      local now, saga, sequence = 1000, nil, 0
      local runs, compensations, leasesAcquired, leasesReleased, audits = 0, {}, 0, 0, 0
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-runtime')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local store = {}
      function store:start(sagaType, correlationId, context, options)
        sequence = sequence + 1
        saga = {
          publicId = ('saga-%d'):format(sequence), sagaType = sagaType, correlationId = correlationId,
          state = 'pending', currentStep = 0, version = 1, context = foundation.copy(context),
          steps = {}, ageMs = 100000, deadlineExpired = false, deadlineAt = options.deadlineAt
        }
        return { publicId = saga.publicId, state = saga.state, currentStep = 0, version = 1 }, nil
      end
      function store:candidates()
        if not saga or saga.state == 'completed' or saga.state == 'failed' then return {}, nil end
        return {{ publicId = saga.publicId, sagaType = saga.sagaType, state = saga.state, version = saga.version }}, nil
      end
      function store:load(publicId)
        assert(saga and publicId == saga.publicId)
        return foundation.copy(saga), nil
      end
      function store:appendRuntimeEvent(command)
        assert(command.publicId == saga.publicId and command.expectedVersion == saga.version)
        saga.currentStep = saga.currentStep + 1
        saga.version = saga.version + 1
        saga.state = command.nextState
        saga.context = foundation.copy(command.context)
        saga.steps[#saga.steps + 1] = {
          sequence = saga.currentStep, name = command.stepName, event = command.eventType,
          attempt = command.attempt, payload = foundation.copy(command.payload), error = foundation.copy(command.error)
        }
        if command.error then saga.lastError = foundation.copy(command.error) end
        saga.ageMs = 100000
        return { publicId = saga.publicId, state = saga.state, currentStep = saga.currentStep, version = saga.version }, nil
      end
      function store:snapshot()
        return { enabled = true, total = saga and 1 or 0, states = saga and {[saga.state] = 1} or {} }, nil
      end
      local audit = { append = function(_, entry)
        audits = audits + 1
        assert(entry.targetType == 'saga' and entry.targetId == saga.publicId)
        return { eventId = ('audit-%d'):format(audits) }, nil
      end }
      local leases = {
        acquire = function(_, name, owner, ttl)
          leasesAcquired = leasesAcquired + 1
          assert(name == 'saga:' .. saga.publicId and owner == 'instance-a:saga' and ttl == 45)
          return { name = name, owner = owner, fencingToken = leasesAcquired, ttlSeconds = ttl }, nil
        end,
        release = function() leasesReleased = leasesReleased + 1 return true, nil end
      }
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = store, audit = audit,
        leases = leases, owners = registries.owners, instanceId = 'instance-a', enabled = true
      })
      local invalid, invalidError = runtime:register('synex_fixture', epoch, {
        name = 'fixture.invalid', steps = {{ name = 'step', run = function() return {} end }}
      })
      assert(invalid == nil and invalidError.code == 'INVALID_SAGA_DEFINITION')
      assert(runtime:register('synex_fixture', epoch, {
        name = 'fixture.purchase', timeoutMs = 60000, steps = {
          {
            name = 'reserve', maxAttempts = 2, retryDelayMs = 100,
            run = function(context)
              context.reserved = true
              return { context = context, output = { reservation = 'opaque' } }, nil
            end,
            compensate = function()
              compensations[#compensations + 1] = 'reserve'
              return { output = { released = true } }, nil
            end
          },
          {
            name = 'commit', maxAttempts = 2, retryDelayMs = 100,
            run = function()
              runs = runs + 1
              return nil, { code = 'FIXTURE_RETRY', retryable = true }
            end,
            compensate = function()
              compensations[#compensations + 1] = 'commit'
              return { output = { reverted = true } }, nil
            end
          }
        }
      }))
      assert(runtime:start('synex_fixture', 'fixture.purchase', 'correlation-1', { value = 1 }, {}, 'trace-start'))
      for index = 1, 5 do
        local report, dispatchError = runtime:dispatchBatch(10)
        assert(report and dispatchError == nil)
      end
      assert(saga.state == 'failed' and runs == 2)
      assert(#compensations == 2 and compensations[1] == 'commit' and compensations[2] == 'reserve')
      assert(leasesAcquired == 5 and leasesReleased == 5)
      local forwardFailures = 0
      for _, event in ipairs(saga.steps) do
        if event.name == 'commit' and event.event == 'failed' and event.payload.phase == 'forward' then
          forwardFailures = forwardFailures + 1
        end
      end
      assert(forwardFailures == 2)

      local runsBeforeDeadline = runs
      assert(runtime:start('synex_fixture', 'fixture.purchase', 'correlation-2', {}, {}, 'trace-deadline'))
      saga.deadlineExpired = true
      assert(runtime:dispatchBatch(10))
      assert(saga.state == 'failed' and saga.lastError.code == 'SAGA_DEADLINE_EXCEEDED')
      assert(runs == runsBeforeDeadline)
      local snapshot = runtime:snapshot()
      assert(snapshot.enabled and #snapshot.handlers == 1 and snapshot.persisted.total == 1)
      return table.concat({runs, compensations[1], compensations[2], leasesAcquired, audits}, ':')
    `);
    assert.match(String(result), /^2:commit:reserve:6:\d+$/u);
  } finally {
    engine.global.close();
  }
});
