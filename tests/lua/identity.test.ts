import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

const identityModules = [
  'core/synex_core/shared/protocol.lua',
  'core/synex_core/server/factories.lua',
  'core/synex_core/server/foundation.lua',
  'core/synex_core/server/registries.lua',
  'core/synex_core/server/identity_common.lua',
  'core/synex_core/server/identity_repository.lua',
  'core/synex_core/server/identity_characters.lua',
  'core/synex_core/server/identity_connection_replacement.lua',
  'core/synex_core/server/identity_connection_claims.lua',
  'core/synex_core/server/identity_connection_join.lua',
  'core/synex_core/server/identity_connection_maintenance.lua',
  'core/synex_core/server/identity_connections.lua',
  'core/synex_core/server/identity.lua',
];

async function createIdentityEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of identityModules) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('session persistence is atomically fenced by the current cluster lease', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local affected, capturedSql, capturedParameters = 0, nil, nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 11 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local database = {
        update = function(_, sql, parameters)
          capturedSql, capturedParameters = sql, parameters
          return affected, nil
        end
      }
      local repositories = SynexCoreFactories.identityRepository({
        platform = platform, foundation = foundation, database = database,
        players = registries.players, config = {}, instanceId = 'instance-a',
        normalizeIdentifiers = function() return {} end
      })
      local session = {
        id = 'session-a', userId = 'user-a', source = 42, sourceGeneration = 7,
        state = 'SELECTING_CHARACTER', version = 2,
        clusterLease = { name = 'session:user-a', owner = 'instance-a:session-a', fencingToken = 9 }
      }
      local created, createError = repositories.sessions:create(session)
      assert(created == nil and createError.code == 'LEASE_LOST')
      assert(capturedSql:find('synex_cluster_leases', 1, true)
        and capturedSql:find('fencing_token', 1, true)
        and capturedSql:find('expires_at', 1, true))
      assert(capturedParameters[8] == session.clusterLease.name
        and capturedParameters[9] == session.clusterLease.owner
        and capturedParameters[10] == session.clusterLease.fencingToken)
      affected = 1
      assert(repositories.sessions:create(session))
      return table.concat({capturedParameters[8], capturedParameters[9], capturedParameters[10]}, ':')
    `);
    assert.equal(result, 'session:user-a:instance-a:session-a:9');
  } finally {
    engine.global.close();
  }
});

test('replace_old fences a reused player source before dropping the previous authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, released, acquired, purged = 1000, 0, 0, 0
      local blockedCharacterMutations, joinFlagObserved = 0, false
      local dropped, completed, completionCalls, completionArity = {}, nil, 0, nil
      local stages = {}
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 17) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end,
        defer = function() end,
        dropPlayer = function(playerSource, reason) dropped[playerSource] = reason end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('identity-test')
      function foundation.logger:write(_, message, fields)
        if message == 'connection stage' then
          assert(type(fields.correlationId) == 'string' and fields.correlationId ~= '')
          assert(fields.source == nil and fields.userId == nil and fields.identifiers == nil
            and fields.playerName == nil and fields.error == nil)
          stages[#stages + 1] = fields.stage
        end
      end
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'old-session' }))
      assert(players:bindJoined(-1, 41, {
        id = 'old-session', userId = 'user-fixture', state = 'SELECTING_CHARACTER',
        version = 2, persistedVersion = 2,
        clusterLease = { leaseName = 'session:user-fixture', owner = 'old-owner', fencingToken = 1 }
      }))

      local identity = nil
      local database = {}
      function database:query(sql)
        if sql:find('SELECT DISTINCT', 1, true) then
          return {{
            id = 'user-fixture', status = 'active', locale = 'en',
            metadata_json = '{}', version = 1
          }}, nil
        end
        return {}, nil
      end
      function database:update(sql)
        if sql:find('INSERT INTO \`synex_sessions\`', 1, true) then
          local visible = assert(players:getBySource(42))
          assert(visible.persistencePending == true)
          joinFlagObserved = true
          local _, createError = identity.characters:create(visible.id, {})
          local _, deleteError = identity.characters:delete(visible.id, 'character-fixture')
          local _, selectError = identity.characters:select(visible.id, 'character-fixture')
          assert(createError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(deleteError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(selectError.code == 'SESSION_PERSISTENCE_PENDING')
          blockedCharacterMutations = blockedCharacterMutations + 3
        end
        return 1, nil
      end
      function database:insert()
        return 1, nil
      end

      local leases = {}
      function leases:acquire(name, owner, ttl)
        acquired = acquired + 1
        return { leaseName = name, owner = owner, fencingToken = 2, ttl = ttl }, nil
      end
      function leases:release()
        released = released + 1
        return true, nil
      end
      function leases:renew(lease) return lease, nil end

      local instances = {}
      function instances:requestRemoteKicks() return 0, nil end
      function instances:touchSessions() return true, nil end
      function instances:heartbeat() return {}, nil end
      function instances:pendingLocalControls() return {}, nil end
      function instances:completeControl() return true, nil end

      local config = {
        duplicatePolicy = 'replace_old', allowlistRequired = false, queueEnabled = false,
        pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45
      }
      local rateLimiter = {
        consume = function() return true, nil end,
        purge = function() end
      }
      local function purgeSource(_, source, generation)
        purged = purged + 1
        if source == 41 then
          local previous = assert(players:getSession('old-session'))
          assert(players:getBySource(source) == nil and previous.source == nil)
          assert(previous.sourceGeneration > generation)
          assert(players:createPending(-99, { sessionId = 'replacement-session' }))
          assert(players:bindJoined(-99, source, {
            id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
        end
      end
      identity = SynexCoreFactories.identity({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        owners = owners,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = purgeSource } },
        config = config,
        instanceId = 'instance-a',
        coreResource = 'synex_core',
        leases = leases,
        instances = instances,
        rateLimiter = rateLimiter,
        sha256 = function(value) return value end
      })
      identity.connections:handleConnecting(-2, 'Fixture', {
        defer = function() end,
        update = function() end,
        done = function(...)
          completionCalls = completionCalls + 1
          completionArity = select('#', ...)
          local reason = ...
          completed = reason == nil and '<accepted>' or reason
        end
      })

      assert(completed == '<accepted>')
      assert(completionCalls == 1 and completionArity == 0)
      assert(players:getSession('old-session') == nil)
      assert(type(dropped[41]) == 'string' and players:getBySource(41).userId == 'replacement-user')
      assert(released == 1 and acquired == 1 and purged == 1)
      local pending = assert(players:getPending(-2))
      assert(pending.state == 'AUTHENTICATED')
      assert(pending.clusterLease.fencingToken == 2)
      local joined = assert(identity.connections:handleJoining(42, -2))
      assert(joined.persistencePending == nil)
      assert(players:getBySource(42).state == 'SELECTING_CHARACTER')
      assert(players:getBySource(42).persistencePending == nil)
      assert(joinFlagObserved and blockedCharacterMutations == 3)
      local expectedStages = {
        'received', 'identity_ok', 'access_ok', 'lease_acquired', 'deferral_accepted',
        'player_joining_received', 'join_identity_verified', 'join_lease_verified', 'session_opened'
      }
      for index, stage in ipairs(expectedStages) do assert(stages[index] == stage) end

      config.duplicatePolicy = 'allow'
      function foundation.logger:write() error('fixture-post-terminal-logger') end
      function foundation.metrics:increment() error('fixture-post-terminal-metric') end
      function foundation.metrics:observe() error('fixture-post-terminal-metric') end
      function foundation.metrics:gauge() error('fixture-post-terminal-metric') end
      local secondArity = nil
      assert(identity.connections:handleConnecting(-3, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...) secondArity = select('#', ...) end
      }))
      assert(secondArity == 0 and players:getPending(-3) ~= nil)
      now = now + config.pendingTtlMs + 1
      assert(identity.connections:purgeExpired(1) == 1)
      assert(players:getPending(-3) == nil and released == 2 and acquired == 2)
      return table.concat({completed, released, acquired, purged,
        blockedCharacterMutations, tostring(joinFlagObserved)}, ':')
    `);
    assert.equal(result, '<accepted>:2:2:1:3:true');
  } finally {
    engine.global.close();
  }
});

test('replace_old retains failed durable closes for bounded heartbeat reconciliation', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function runCase(kind)
        local now, released, acquired, unloads, closes, renewals = 1000, 0, 0, 0, 0, 0
        local closeFails = kind == 'close'
        local connection, releaseHook = nil, nil
        local completion = nil
        local platform = {
          nowGame = function() now = now + 1 return now end,
          random = function(_, maximum) return math.min(maximum or 1, 19) end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:fixture'} end,
          wait = function(delay) now = now + delay end, defer = function() end,
          dropPlayer = function() end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('replace-failure-' .. kind)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        local players, owners = registries.players, registries.owners
        owners:activate('synex_core')
        assert(players:createPending(-1, { sessionId = 'old-' .. kind }))
        assert(players:bindJoined(-1, 41, {
          id = 'old-' .. kind, userId = 'user-fixture', state = 'ACTIVE',
          characterId = 'character-' .. kind, version = 2, persistedVersion = 2,
          clusterLease = { name = 'session:user-fixture', owner = 'old-owner',
            fencingToken = 1, ttlSeconds = 45 }
        }))
        local characters = {}
        function characters:unload(sessionId)
          unloads = unloads + 1
          local detached = assert(players:getSession(sessionId))
          assert(detached.source == nil and players:getBySource(41) == nil)
          assert(players:createPending(-99, { sessionId = 'replacement-' .. kind }))
          assert(players:bindJoined(-99, 41, {
            id = 'replacement-' .. kind, userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
          if kind == 'unload' then
            return nil, foundation.error('UNLOAD_FAILED', 'fixture unload failure')
          end
          return true, nil
        end
        connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, players = players, owners = owners,
          lifecycle = { core = {
            canAdmitPlayers = function() return true end,
            setHealth = function() end
          } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'replace_old', queueEnabled = false,
            pendingTtlMs = 120000, clusterSessionLeaseSeconds = 45 },
          instanceId = 'instance-a',
          leases = {
            acquire = function() acquired = acquired + 1 return nil, foundation.error('UNEXPECTED', 'unexpected') end,
            release = function()
              released = released + 1
              if releaseHook then local hook = releaseHook; releaseHook = nil; hook() end
              return true, nil
            end,
            renew = function()
              renewals = renewals + 1
              return true, nil
            end
          },
          instances = {
            requestRemoteKicks = function() return 0, nil end,
            touchSessions = function() return true, nil end,
            heartbeat = function() return {}, nil end,
            pendingLocalControls = function() return {}, nil end,
            completeControl = function() return true, nil end
          },
          characters = characters,
          userRepository = {
            authenticate = function() return { id = 'user-fixture', status = 'active' }, nil end,
            findByIdentifiers = function() return { id = 'user-fixture', status = 'active' }, nil end
          },
          sessionRepository = {
            create = function() return true, nil end,
            close = function()
              closes = closes + 1
              if closeFails then
                return nil, foundation.error('CLOSE_FAILED', 'fixture close failure')
              end
              return true, nil
            end
          },
          accessRepository = { check = function() return true, nil end },
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'fixture', normalized = 'license:fixture' }}
          end,
          sha256 = function(value) return value end,
          sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
          transition = function(session, target) session.state = target return session, nil end
        })
        assert(connection:handleConnecting(-2, 'Fixture', {
          defer = function() end, update = function() end,
          done = function(reason) completion = reason end
        }))
        assert(type(completion) == 'string'
          and completion:find('[SESSION_REPLACE_FAILED]', 1, true))
        assert(players:getBySource(41).id == 'replacement-' .. kind)
        assert(players:getPending(-2) == nil)
        assert(acquired == 0 and unloads == 1 and closes == 1)
        if kind == 'unload' then
          assert(players:getSession('old-' .. kind) == nil and released == 1)
          return kind .. ':' .. released .. ':' .. players:getBySource(41).userId
        end

        local tombstone = assert(players:getSession('old-close'))
        assert(tombstone.source == nil and tombstone.replacementClosePending == true)
        assert(tombstone.clusterLease.owner == 'old-owner' and released == 0)
        assert(connection:heartbeat())
        tombstone = assert(players:getSession('old-close'))
        assert(tombstone.source == nil and tombstone.replacementClosePending == true)
        assert(closes == 2 and renewals == 1 and released == 0)
        assert(players:getBySource(41).id == 'replacement-close')

        closeFails = false
        releaseHook = function() assert(connection:heartbeat()) end
        assert(connection:heartbeat())
        assert(players:getSession('old-close') == nil and released == 1)
        assert(players:getBySource(41).id == 'replacement-close')
        assert(closes == 3 and renewals == 1)
        assert(connection:heartbeat())
        assert(closes == 3 and renewals == 1 and released == 1)
        return kind .. ':' .. released .. ':' .. closes .. ':' .. renewals .. ':'
          .. players:getBySource(41).userId
      end
      return runCase('unload') .. '|' .. runCase('close')
    `);
    assert.equal(result, 'unload:1:replacement-user|close:1:3:1:replacement-user');
  } finally {
    engine.global.close();
  }
});

test('replacement cleanup treats an absent durable session row as already closed', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local releases, closes, reads = 0, 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 23 end,
        print = function() end, dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      assert(players:createPending(-1, { sessionId = 'old-missing' }))
      local old = assert(players:bindJoined(-1, 41, {
        id = 'old-missing', userId = 'user-missing', state = 'SELECTING_CHARACTER',
        version = 2, persistedVersion = 2,
        clusterLease = { name = 'session:user-missing', owner = 'old-owner',
          fencingToken = 4, ttlSeconds = 45 }
      }))
      local replacement = SynexCoreFactories.identityConnectionReplacement({
        platform = platform, foundation = foundation, players = players,
        messaging = { network = { purgeSource = function(_, source, generation)
          assert(source == 41 and generation == old.sourceGeneration)
          assert(players:getBySource(41) == nil)
          assert(players:createPending(-2, { sessionId = 'new-source-owner' }))
          assert(players:bindJoined(-2, 41, {
            id = 'new-source-owner', userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
        end } },
        characters = {},
        sessionRepository = {
          close = function()
            closes = closes + 1
            return nil, foundation.error('SESSION_CONFLICT', 'fixture conflict', { retryable = true })
          end,
          getState = function()
            reads = reads + 1
            return nil, foundation.error('SESSION_NOT_FOUND', 'fixture missing')
          end
        },
        releaseConnectionLease = function(session)
          releases = releases + 1
          assert(session.id == 'old-missing' and session.source == nil)
          return true, nil
        end
      })
      assert(replacement:replace('user-missing'))
      assert(players:getSession('old-missing') == nil)
      assert(players:getBySource(41).id == 'new-source-owner')
      local report = assert(replacement:reconcile(1))
      assert(report.examined == 0 and report.pending == 0)
      return table.concat({releases, closes, reads, players:getBySource(41).userId}, ':')
    `);
    assert.equal(result, '1:1:1:replacement-user');
  } finally {
    engine.global.close();
  }
});

test('replacement close tombstones reject every character mutation while reconciliation is pending', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 29 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'replacement-tombstone' }))
      assert(players:bindJoined(-1, 41, {
        id = 'replacement-tombstone', userId = 'user-tombstone',
        state = 'SELECTING_CHARACTER', version = 2, persistedVersion = 2,
        replacementClosePending = true
      }))
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {},
        players = players, owners = owners,
        messaging = { hooks = {}, events = {} }, coreResource = 'synex_core',
        characterRepository = {}, sessionRepository = {},
        invokeOwned = function() error('fixture mutation escaped tombstone guard') end,
        transition = function() error('fixture mutation escaped tombstone guard') end,
        leases = {}, instanceId = 'instance-a'
      })
      local _, createError = characters:create('replacement-tombstone', {})
      local _, deleteError = characters:delete('replacement-tombstone', 'character-a')
      local _, selectError = characters:select('replacement-tombstone', 'character-a')
      assert(players:bindCharacter('replacement-tombstone', 'character-a'))
      assert(players:updateSession('replacement-tombstone', function(candidate)
        candidate.state = 'ACTIVE'
      end))
      local _, unloadError = characters:unload('replacement-tombstone', 'fixture')
      assert(createError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(deleteError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(selectError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(unloadError.code == 'SESSION_PERSISTENCE_PENDING')
      return table.concat({
        createError.code, deleteError.code, selectError.code, unloadError.code
      }, ':')
    `);
    assert.equal(result, [
      'SESSION_PERSISTENCE_PENDING', 'SESSION_PERSISTENCE_PENDING',
      'SESSION_PERSISTENCE_PENDING', 'SESSION_PERSISTENCE_PENDING',
    ].join(':'));
  } finally {
    engine.global.close();
  }
});

test('connection exceptions reject once with a stable code and release pending authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, completionCalls, completionArity, completionReason, released = 1000, 0, nil, nil, 0
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 19) end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end, defer = function() end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('connection-failure-test')
      function foundation.logger:write(_, message, fields)
        if message == 'connection stage' then
          assert(type(fields.correlationId) == 'string')
          assert(fields.source == nil and fields.userId == nil and fields.identifiers == nil
            and fields.playerName == nil and fields.error == nil)
        end
      end
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      local epoch = owners:activate('synex_core')
      local leases = {
        acquire = function(_, name, owner, ttl)
          return { leaseName = name, owner = owner, fencingToken = 1, ttl = ttl }, nil
        end,
        release = function() released = released + 1 return true, nil end
      }
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = function() end } },
        config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
          gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45 },
        leases = leases, instanceId = 'instance-a', characters = {},
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value) return value end,
        instances = { requestRemoteKicks = function() return 0, nil end },
        userRepository = { authenticate = function() return { id = 'user-fixture' }, nil end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() error('fixture-private-database-error') end,
        normalizeIdentifiers = function() return {{ type = 'license', value = 'fixture' }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      assert(connection:registerGate('synex_core', epoch, {
        name = 'fixture gate', priority = 0, timeoutMs = 1000, run = function() return true end
      }))
      local connected, connectionError = connection:handleConnecting(-2, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...)
          completionCalls = completionCalls + 1
          completionArity = select('#', ...)
          completionReason = ...
        end
      })
      assert(connected == nil and connectionError.code == 'CONNECTION_PIPELINE_FAILED')
      assert(completionCalls == 1 and completionArity == 1)
      assert(completionReason:find('[CONNECTION_PIPELINE_FAILED]', 1, true))
      assert(not completionReason:find('fixture-private', 1, true))
      assert(players:getPending(-2) == nil and released == 1)
      assert(connection:snapshot().admissionReservations == 0)
      return completionReason
    `);
    assert.match(result, /\[CONNECTION_PIPELINE_FAILED\]/);
    assert.doesNotMatch(result, /fixture-private/);
  } finally {
    engine.global.close();
  }
});

test('a failed accepted deferral terminal is attempted once and retained only until pending TTL cleanup', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, doneCalls, released = 1000, 0, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 23 end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end, defer = function() end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('deferral-terminal-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = function() end } },
        config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = {
          acquire = function(_, name, owner, ttl)
            return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl }, nil
          end,
          release = function() released = released + 1 return true, nil end
        },
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value) return value end,
        instances = { requestRemoteKicks = function() return 0, nil end }, characters = {},
        userRepository = { authenticate = function() return { id = 'user-fixture', status = 'active' }, nil end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function() return {{ type = 'license', value = 'fixture' }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      local connected, connectionError = connection:handleConnecting(-2, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...)
          doneCalls = doneCalls + 1
          assert(select('#', ...) == 0)
          error('fixture-private-terminal-error')
        end
      })
      assert(connected == nil and connectionError.code == 'DEFERRAL_TERMINATION_FAILED')
      assert(doneCalls == 1 and players:getPending(-2) ~= nil and released == 0)
      now = now + 120001
      assert(connection:purgeExpired(1) == 1)
      assert(players:getPending(-2) == nil and released == 1)
      return table.concat({doneCalls, released, connectionError.code}, ':')
    `);
    assert.equal(result, '1:1:DEFERRAL_TERMINATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('playerJoining rejects cross-pending hijack, replay, and source-local floods without consuming victim authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, released, persisted, identityReads = 1000, 0, 0, 0
      local sourceIdentities, lookupReuse, renewReuse, releaseReuse = {}, nil, nil, nil
      local sameIdentityReuse, sameIdentityResult = nil, nil
      local drops, dropOwners, rateBuckets, purgedRateKeys = {}, {}, {}, {}
      local function identityFor(source)
        if sourceIdentities[source] then return sourceIdentities[source] end
        if source == 99 then return 'attacker' end
        if source == 98 then return 'alternate' end
        return 'victim'
      end
      local platform = {
        nowGame = function() return now end, random = function() return 29 end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function(source) return {'license:' .. identityFor(source)} end,
        wait = function(delay) now = now + delay end, defer = function() end,
        dropPlayer = function(source, reason)
          drops[source] = drops[source] or {}
          drops[source][#drops[source] + 1] = reason
          dropOwners[source] = dropOwners[source] or {}
          dropOwners[source][#dropOwners[source] + 1] = identityFor(source)
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('join-boundary-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local rateLimiter = {}
      function rateLimiter:consume(key)
        rateBuckets[key] = (rateBuckets[key] or 0) + 1
        if rateBuckets[key] > 4 then return nil, { code = 'RATE_LIMITED' } end
        return true, nil
      end
      function rateLimiter:purge(prefix) purgedRateKeys[#purgedRateKeys + 1] = prefix end
      local config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
        clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 }
      local connection = nil
      local userRepository = {}
      function userRepository:authenticate(raw)
        return { id = raw[1]:find('attacker', 1, true) and 'user-attacker' or 'user-victim', status = 'active' }, nil
      end
      function userRepository:findByIdentifiers(identifiers)
        identityReads = identityReads + 1
        local resolved = {
          id = identifiers[1].value == 'attacker' and 'user-attacker' or 'user-victim',
          status = 'active'
        }
        if lookupReuse then sourceIdentities[lookupReuse] = 'attacker'; lookupReuse = nil end
        if sameIdentityReuse then
          local reusedSource = sameIdentityReuse
          sameIdentityReuse = nil
          connection:handleDropped(reusedSource, 'same identity source reuse')
          local replacement, replacementError = connection:handleJoining(reusedSource, -3)
          sameIdentityResult = assert(replacement, replacementError and replacementError.code)
        end
        return resolved, nil
      end
      local function normalize(values)
        local value = values[1]:match('^[^:]+:(.+)$')
        return {{ type = 'license', value = value, normalized = 'license:' .. value }}
      end
      connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end, setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() end } },
        config = config,
        leases = {
          acquire = function(_, name, owner, ttl)
            return { name = name, owner = owner, fencingToken = 7, ttlSeconds = ttl }, nil
          end,
          release = function()
            released = released + 1
            if releaseReuse then sourceIdentities[releaseReuse] = 'attacker'; releaseReuse = nil end
            return true, nil
          end,
          renew = function()
            if renewReuse then sourceIdentities[renewReuse] = 'attacker'; renewReuse = nil end
            return true, nil
          end
        },
        rateLimiter = rateLimiter,
        sha256 = function(value) return value end,
        instances = { requestRemoteKicks = function() return 0, nil end }, characters = {},
        userRepository = userRepository,
        sessionRepository = {
          create = function() persisted = persisted + 1 return true, nil end,
          close = function() return true, nil end
        },
        accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end, normalizeIdentifiers = normalize,
        sessionTransitions = { SELECTING_CHARACTER = { DISCONNECTING = true } },
        transition = function(session, target)
          session.state = target
          session.version = (session.version or 0) + 1
          return session, nil
        end
      })
      local doneArity = nil
      local connected, connectError = connection:handleConnecting(-2, 'Victim', {
        defer = function() end, update = function() end,
        done = function(...) doneArity = select('#', ...) end
      })
      assert(connected, connectError and connectError.code)
      local accepted = assert(players:getPending(-2))
      assert(doneArity == 0 and accepted.userId == 'user-victim')

      local sameUser, sameUserError = connection:handleJoining(98, -2)
      assert(sameUser == nil and sameUserError.code == 'JOIN_IDENTITY_MISMATCH')
      assert(players:getPending(-2).id == accepted.id and #drops[98] == 1 and identityReads == 0)

      for attempt = 1, 4 do
        local joined, joinError = connection:handleJoining(99, -2)
        assert(joined == nil and joinError.code == 'JOIN_IDENTITY_MISMATCH')
        local preserved = assert(players:getPending(-2))
        assert(preserved.id == accepted.id and preserved.clusterLease.fencingToken == 7)
        assert(players:getBySource(99) == nil and released == 0)
      end
      local limited, limitedError = connection:handleJoining(99, -2)
      assert(limited == nil and limitedError.code == 'JOIN_RATE_LIMITED')
      assert(identityReads == 0 and #drops[99] == 5 and players:getPending(-2).id == accepted.id)

      config.duplicatePolicy = 'allow'
      local replacementAccepted = nil
      assert(connection:handleConnecting(-3, 'Replacement', {
        defer = function() end, update = function() end,
        done = function(reason) replacementAccepted = reason == nil end
      }))
      local replacementPending = assert(players:getPending(-3))
      assert(replacementAccepted and replacementPending.userId == accepted.userId)
      sameIdentityReuse = 95
      local sameIdentityStale, sameIdentityError = connection:handleJoining(95, -2)
      assert(sameIdentityStale == nil and sameIdentityError.code == 'JOIN_SOURCE_CHANGED')
      assert(sameIdentityResult.id == replacementPending.sessionId)
      assert(players:getBySource(95).id == replacementPending.sessionId and drops[95] == nil)
      assert(players:getPending(-2).id == accepted.id)
      connection:handleDropped(95, 'replacement fixture cleanup')
      assert(players:getBySource(95) == nil and released == 1)

      sourceIdentities[97], lookupReuse = 'victim', 97
      local lookupStale, lookupStaleError = connection:handleJoining(97, -2)
      assert(lookupStale == nil and lookupStaleError.code == 'JOIN_SOURCE_CHANGED')
      assert(drops[97] == nil and players:getPending(-2).id == accepted.id and released == 1)

      sourceIdentities[96], renewReuse = 'victim', 96
      local renewStale, renewStaleError = connection:handleJoining(96, -2)
      assert(renewStale == nil and renewStaleError.code == 'JOIN_SOURCE_CHANGED')
      assert(drops[96] == nil and players:getPending(-2).id == accepted.id and released == 1)

      local joined = assert(connection:handleJoining(42, -2))
      assert(joined.userId == 'user-victim' and players:getPending(-2) == nil)
      assert(players:getBySource(42).id == accepted.sessionId and persisted == 2 and identityReads == 5)
      local replay, replayError = connection:handleJoining(42, -2)
      assert(replay == nil and replayError.code == 'SOURCE_ALREADY_BOUND' and drops[42] == nil)
      connection:handleDropped(42, 'fixture')
      assert(released == 2 and purgedRateKeys[#purgedRateKeys] == 'join:42:')

      sourceIdentities[77], releaseReuse = 'victim', 77
      assert(players:createPending(-5, {
        id = 'expired-connection', sessionId = 'expired-session', tempSource = -5,
        state = 'AUTHENTICATED', userId = 'user-victim', receivedAt = now - 1,
        expiresAt = now, identityFingerprint = 'unused',
        clusterLease = { owner = 'expired-owner', fencingToken = 8, ttlSeconds = 45 }
      }))
      local expired, expiredError = connection:handleJoining(77, -5)
      assert(expired == nil and expiredError.code == 'PENDING_CONNECTION_EXPIRED')
      assert(dropOwners[77][1] == 'victim' and sourceIdentities[77] == 'attacker')
      assert(players:getPending(-5) == nil and released == 3)
      return table.concat({#drops[99], identityReads, persisted, released, replayError.code}, ':')
    `);
    assert.equal(result, '5:5:2:3:SOURCE_ALREADY_BOUND');
  } finally {
    engine.global.close();
  }
});

test('playerJoining compensates transition, bind, persistence, and disconnect races exactly once', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function runCase(kind)
        local now, released, dropped, closeCalls, renewCalls, opened = 1000, 0, {}, 0, 0, 0
        local leaseTaken = false
        local sourceIdentity = 'victim'
        local platform = {
          nowGame = function() return now end, random = function() return 31 end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:' .. sourceIdentity} end,
          dropPlayer = function(source, reason) dropped[#dropped + 1] = { source = source, reason = reason } end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('join-failure-' .. kind)
        function foundation.logger:write(_, message, fields)
          if message == 'connection stage' and fields.stage == 'session_opened' then opened = opened + 1 end
        end
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        local players = registries.players
        assert(players:createPending(-2, {
          id = 'connection-' .. kind, sessionId = 'session-' .. kind,
          tempSource = -2, receivedAt = now, expiresAt = now + 120000,
          state = 'AUTHENTICATED', userId = 'user-victim',
          identityFingerprint = 'fixture-hash',
          clusterLease = { name = 'session:user-victim', owner = 'instance-a:session-' .. kind,
            fencingToken = 9, ttlSeconds = 45 }
        }))
        local originalBind = players.bindJoined
        if kind == 'bind' then
          players.bindJoined = function(self, ...)
            assert(originalBind(self, ...))
            error('fixture-private-bind-error')
          end
        end
        if kind == 'cancelled' then
          players.isCurrent = function(self, sessionId)
            self:removeSession(sessionId)
            return false
          end
        end
        local connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, players = players, owners = registries.owners,
          lifecycle = { core = { canAdmitPlayers = function() return true end } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'deny_new', pendingTtlMs = 120000,
            clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
          leases = {
            release = function() released = released + 1 return true, nil end,
            renew = function()
              renewCalls = renewCalls + 1
              if leaseTaken then
                return nil, { code = 'LEASE_LOST' }
              end
              return true, nil
            end
          },
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          sha256 = function() return 'fixture-hash' end,
          instances = {}, characters = {},
          userRepository = {
            findByIdentifiers = function() return { id = 'user-victim', status = 'active' }, nil end
          },
          sessionRepository = {
            create = function()
              if kind == 'persistence' then error('fixture-private-persistence-error') end
              if kind == 'lease_after_create' then leaseTaken = true end
              if kind == 'reused' then
                local previous = assert(players:getBySource(42))
                assert(players:removeSession(previous.id))
                assert(players:createPending(-99, { sessionId = 'replacement-session' }))
                assert(players:bindJoined(-99, 42, {
                  id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
                  version = 1, persistedVersion = 1
                }))
                sourceIdentity = 'attacker'
              end
              return true, nil
            end,
            close = function() closeCalls = closeCalls + 1 return true, nil end
          },
          accessRepository = {}, invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
          end,
          sessionTransitions = {},
          transition = function(session, target)
            if kind == 'transition' then error('fixture-private-transition-error') end
            session.state = target
            session.version = session.version + 1
            return session, nil
          end
        })
        local joined, joinError = connection:handleJoining(42, -2)
        local expectedCode = kind == 'lease_after_create' and 'JOIN_LEASE_LOST'
          or ((kind == 'cancelled' or kind == 'reused') and 'CONNECTION_CANCELLED'
          or 'JOIN_PIPELINE_FAILED')
        assert(joined == nil and joinError.code == expectedCode)
        if kind == 'cancelled' or kind == 'reused' then
          assert(#dropped == 0)
        else
          assert(#dropped == 1 and dropped[1].source == 42)
          assert(dropped[1].reason:find('[' .. expectedCode .. ']', 1, true))
          assert(not dropped[1].reason:find('fixture-private', 1, true))
        end
        assert(players:getPending(-2) == nil and players:getSession('session-' .. kind) == nil)
        if kind == 'reused' then
          assert(players:getBySource(42).userId == 'replacement-user')
        else
          assert(players:getBySource(42) == nil)
        end
        assert(released == 1)
        if kind == 'persistence' or kind == 'cancelled' or kind == 'reused'
          or kind == 'lease_after_create' then
          assert(closeCalls == 1)
        else
          assert(closeCalls == 0)
        end
        if kind == 'lease_after_create' then assert(renewCalls == 2 and leaseTaken) end
        assert(opened == 0)
        return kind .. ':' .. tostring(closeCalls)
      end
      return table.concat({
        runCase('transition'), runCase('bind'), runCase('persistence'), runCase('cancelled'),
        runCase('reused'), runCase('lease_after_create')
      }, '|')
    `);
    assert.equal(result,
      'transition:0|bind:0|persistence:1|cancelled:1|reused:1|lease_after_create:1');
  } finally {
    engine.global.close();
  }
});

test('playerDropped detaches and purges before yielded cleanup can observe a reused owner', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, releases, purges, completedControls, health = 1000, 0, 0, 0, {}
      local drops = {}
      local platform = {
        nowGame = function() return now end, random = function() return 35 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + delay end,
        dropPlayer = function(source) drops[source] = (drops[source] or 0) + 1 end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('drop-source-reuse')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      assert(players:createPending(-2, { sessionId = 'old-session' }))
      local old = assert(players:bindJoined(-2, 42, {
        id = 'old-session', userId = 'old-user', state = 'ACTIVE', characterId = 'old-character',
        version = 2, persistedVersion = 2,
        clusterLease = { owner = 'old-owner', fencingToken = 1, ttlSeconds = 45 }
      }))
      local connection = nil
      local characters = {}
      function characters:unload(sessionId)
        local detached = assert(players:getSession(old.id))
        assert(sessionId == old.id and players:getBySource(42) == nil and purges == 1)
        assert(detached.source == nil and detached.sourceGeneration > old.sourceGeneration)
        assert(players:createPending(-99, { sessionId = 'replacement-session' }))
        assert(players:bindJoined(-99, 42, {
          id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
          version = 1, persistedVersion = 1
        }))
        local healthy, heartbeatError = connection:heartbeat()
        assert(healthy == false and heartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
        return true, nil
      end
      connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function(_, component, status) health[component] = status end
        } },
        messaging = { network = { purgeSource = function() purges = purges + 1 end } },
        config = { duplicatePolicy = 'allow', pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = {
          release = function() releases = releases + 1 return true, nil end,
          renew = function() return nil, { code = 'LEASE_LOST' } end
        },
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value) return value end,
        instances = {
          touchSessions = function() return true, nil end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function() return {{
            target_session_id = old.id, action = 'kick', request_id = 'stale-control', reason = 'stale'
          }}, nil end,
          completeControl = function(_, requestId)
            assert(requestId == 'stale-control')
            completedControls = completedControls + 1
            return true, nil
          end
        },
        characters = characters, userRepository = {}, accessRepository = {},
        sessionRepository = { close = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function() return {} end,
        sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
        transition = function(session, target) session.state = target return session, nil end
      })
      local report = assert(connection:handleDropped(42, 'old connection closed'))
      assert(report.closed and #report.failures == 0)
      assert(players:getSession(old.id) == nil)
      assert(players:getBySource(42).userId == 'replacement-user')
      assert(drops[42] == nil and releases == 1 and purges == 1 and completedControls == 1)
      assert(health.cluster == 'DEGRADED' and health['disconnect-cleanup'] == 'HEALTHY')
      return table.concat({releases, purges, completedControls, health.cluster,
        players:getBySource(42).userId}, ':')
    `);
    assert.equal(result, '1:1:1:DEGRADED:replacement-user');
  } finally {
    engine.global.close();
  }
});

test('pending lease heartbeat preserves delayed join authority and fails closed on renewal loss', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function fixture(label)
        local now, authority, renewCalls, releaseCalls, renewFails = 1000, nil, 0, 0, false
        local renewHook, releaseHook = nil, nil
        local drops, health = {}, nil
        local platform = {
          nowGame = function() return now end, random = function() return 37 end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:victim'} end,
          wait = function(delay) now = now + delay end, defer = function() end,
          dropPlayer = function(source, reason) drops[source] = reason end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('lease-heartbeat-' .. label)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        local leases = {}
        function leases:acquire(name, owner, ttl)
          if authority and authority.expiresAt > now and authority.owner ~= owner then
            return nil, { code = 'LEASE_BUSY' }
          end
          local token = authority and authority.fencingToken + 1 or 1
          authority = { name = name, owner = owner, fencingToken = token,
            ttlSeconds = ttl, expiresAt = now + ttl * 1000 }
          return { name = name, owner = owner, fencingToken = token, ttlSeconds = ttl }, nil
        end
        function leases:renew(lease)
          renewCalls = renewCalls + 1
          if renewHook then
            local callback = renewHook
            renewHook = nil
            callback()
          end
          if renewFails or not authority or authority.expiresAt <= now
            or authority.owner ~= lease.owner or authority.fencingToken ~= lease.fencingToken then
            return nil, { code = 'LEASE_LOST' }
          end
          authority.expiresAt = now + lease.ttlSeconds * 1000
          return true, nil
        end
        function leases:release(lease)
          releaseCalls = releaseCalls + 1
          if releaseHook then
            local callback = releaseHook
            releaseHook = nil
            callback()
          end
          if authority and authority.owner == lease.owner and authority.fencingToken == lease.fencingToken then
            authority.expiresAt = now
          end
          return true, nil
        end
        local userRepository = {
          authenticate = function() return { id = 'user-victim', status = 'active' }, nil end,
          findByIdentifiers = function() return { id = 'user-victim', status = 'active' }, nil end
        }
        local connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, instanceId = 'instance-a',
          players = registries.players, owners = registries.owners,
          lifecycle = { core = {
            canAdmitPlayers = function() return true end,
            setHealth = function(_, _, status) health = status end
          } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
            clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
          leases = leases,
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          sha256 = function(value) return value end,
          instances = {
            requestRemoteKicks = function() return 0, nil end,
            touchSessions = function() return true, nil end,
            heartbeat = function() return {}, nil end,
            pendingLocalControls = function() return {}, nil end,
            completeControl = function() return true, nil end
          },
          characters = {}, userRepository = userRepository,
          sessionRepository = { create = function() return true, nil end, close = function() return true, nil end },
          accessRepository = { check = function() return true, nil end },
          invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
          end,
          sessionTransitions = {},
          transition = function(session, target)
            session.state = target
            session.version = session.version + 1
            return session, nil
          end
        })
        return {
          connection = connection, players = registries.players, drops = drops,
          connect = function(tempSource)
            local completion = nil
            local connected, connectError = connection:handleConnecting(tempSource, 'Victim', {
              defer = function() end, update = function() end,
              done = function(reason) completion = reason == nil and '<accepted>' or reason end
            })
            return completion, connected, connectError
          end,
          advance = function(ms) now = now + ms end,
          setRenewFailure = function(value) renewFails = value end,
          setReleaseHook = function(callback) releaseHook = callback end,
          replaceSourceOnRenew = function(source)
            renewHook = function()
              local previous = registries.players:getBySource(source)
              assert(previous and registries.players:removeSession(previous.id))
              assert(registries.players:createPending(-99, { sessionId = 'replacement-session' }))
              assert(registries.players:bindJoined(-99, source, {
                id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
                version = 1, persistedVersion = 1
              }))
            end
          end,
          stats = function() return now, authority, renewCalls, releaseCalls, health end
        }
      end

      local delayed = fixture('delayed')
      local delayedCompletion, delayedConnected, delayedError = delayed.connect(-2)
      assert(delayedCompletion == '<accepted>' and delayedConnected,
        delayedError and delayedError.code)
      for _ = 1, 6 do delayed.advance(10000); assert(delayed.connection:heartbeat()) end
      local duplicate = delayed.connect(-3)
      assert(duplicate:find('[DUPLICATE_SESSION]', 1, true))
      for _ = 1, 3 do delayed.advance(10000); assert(delayed.connection:heartbeat()) end
      local delayedNow, authority, renewed = delayed.stats()
      assert(delayedNow >= 91000 and authority.expiresAt > delayedNow and renewed >= 9)
      assert(delayed.connection:handleJoining(42, -2))
      assert(delayed.players:getBySource(42).userId == 'user-victim')
      delayed.setRenewFailure(true)
      delayed.advance(10000)
      local sessionHealthy, sessionHeartbeatError = delayed.connection:heartbeat()
      local _, _, _, _, sessionHealth = delayed.stats()
      assert(sessionHealthy == false and sessionHeartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
      assert(sessionHealth == 'DEGRADED')
      assert(delayed.drops[42]:find('authority was lost', 1, true))

      local stale = fixture('stale')
      local staleCompletion, staleConnected, staleConnectError = stale.connect(-2)
      assert(staleCompletion == '<accepted>' and staleConnected,
        staleConnectError and staleConnectError.code)
      assert(stale.connection:handleJoining(42, -2))
      stale.setRenewFailure(true)
      stale.replaceSourceOnRenew(42)
      stale.advance(10000)
      local staleHealthy, staleHeartbeatError = stale.connection:heartbeat()
      assert(staleHealthy == false and staleHeartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
      assert(stale.players:getBySource(42).userId == 'replacement-user')
      assert(stale.drops[42] == nil)

      local cleanup = fixture('cleanup')
      local cleanupNow = select(1, cleanup.stats())
      assert(cleanup.players:createPending(-2, {
        id = 'expired-a', sessionId = 'expired-session-a', tempSource = -2,
        state = 'AUTHENTICATED', receivedAt = cleanupNow - 1, expiresAt = cleanupNow,
        clusterLease = { owner = 'a', fencingToken = 1, ttlSeconds = 45 }
      }))
      assert(cleanup.players:createPending(-3, {
        id = 'expired-b', sessionId = 'expired-session-b', tempSource = -3,
        state = 'AUTHENTICATED', receivedAt = cleanupNow - 1, expiresAt = cleanupNow,
        clusterLease = { owner = 'b', fencingToken = 1, ttlSeconds = 45 }
      }))
      cleanup.setReleaseHook(function()
        assert(cleanup.players:removePending(-3).id == 'expired-b')
        assert(cleanup.players:createPending(-3, {
          id = 'replacement-pending', sessionId = 'replacement-pending-session', tempSource = -3,
          state = 'AUTHENTICATED', receivedAt = cleanupNow, expiresAt = cleanupNow + 120000
        }))
      end)
      assert(cleanup.connection:purgeExpired(2) == 1)
      assert(cleanup.players:getPending(-2) == nil)
      assert(cleanup.players:getPending(-3).id == 'replacement-pending')

      local failed = fixture('failed')
      local failedCompletion, failedConnected, failedConnectError = failed.connect(-2)
      assert(failedCompletion == '<accepted>' and failedConnected,
        failedConnectError and failedConnectError.code)
      failed.setRenewFailure(true)
      failed.advance(10000)
      local healthy, heartbeatError = failed.connection:heartbeat()
      local _, _, _, failedReleases, failedHealth = failed.stats()
      assert(healthy == false and heartbeatError.code == 'PENDING_LEASE_RENEW_FAILED')
      assert(failed.players:getPending(-2) == nil and failed.connection:snapshot().admissionReservations == 0)
      assert(failedReleases == 1 and failedHealth == 'DEGRADED')
      local joined, joinError = failed.connection:handleJoining(42, -2)
      assert(joined == nil and joinError.code == 'PENDING_CONNECTION_NOT_FOUND')
      assert(failed.drops[42]:find('[PENDING_CONNECTION_NOT_FOUND]', 1, true))
      return table.concat({renewed, failedReleases, failedHealth, joinError.code}, ':')
    `);
    assert.match(result, /^\d+:1:DEGRADED:PENDING_CONNECTION_NOT_FOUND$/u);
  } finally {
    engine.global.close();
  }
});

test('bootstrap registers the built-in playerJoining event before subscribing to it', async () => {
  const source = await readFile(path.join(root, 'core/synex_core/server/bootstrap_lifecycle.lua'), 'utf8');
  const registration = source.indexOf("platform.registerNetEvent('playerJoining')");
  const subscription = source.indexOf("platform.addEventHandler('playerJoining'");
  assert.ok(registration >= 0, 'playerJoining must be registered in the resource');
  assert.ok(subscription > registration, 'playerJoining must be registered before its handler is added');
  assert.equal(source.match(/platform\.registerNetEvent\('playerJoining'\)/gu)?.length, 1);
  const handler = source.slice(subscription, source.indexOf("platform.addEventHandler('playerDropped'", subscription));
  assert.doesNotMatch(handler, /platform\.dropPlayer/u,
    'the outer join boundary cannot prove final-source ownership after an unexpected yield');
});
