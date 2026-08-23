import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const modules = [
  'core/synex_core/shared/protocol.lua',
  'core/synex_core/server/factories.lua',
  'core/synex_core/server/foundation.lua',
  'core/synex_core/server/registries.lua',
  'core/synex_core/server/identity_connection_replacement.lua',
  'core/synex_core/server/identity_connection_claims.lua',
  'core/synex_core/server/identity_connection_authority.lua',
  'core/synex_core/server/identity_connection_ingress.lua',
  'core/synex_core/server/identity_connection_terminals.lua',
  'core/synex_core/server/identity_connection_join.lua',
  'core/synex_core/server/identity_connection_connecting.lua',
  'core/synex_core/server/identity_connection_heartbeat.lua',
  'core/synex_core/server/identity_connection_maintenance.lua',
  'core/synex_core/server/identity_connections.lua',
];

async function createEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of modules) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('failed drops retain the bounded active capacity and reconcile fairly', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, recover = 1000, false
      local closeOrder, releaseCount, leaseAcquires = {}, 0, 0
      local completions = {}
      local platform = {
        nowGame = function() return now end, random = function() return 61 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + (delay or 0) end,
        defer = function() end, dropPlayer = function() end,
        getPlayerIdentifiers = function() return {'license:capacity'} end,
        isPlayerAceAllowed = function() return false end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('close-capacity')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      for index = 1, 3 do
        local sessionId, source = 'session-' .. index, 40 + index
        assert(players:createPending(-index, { sessionId = sessionId }))
        assert(players:bindJoined(-index, source, {
          id = sessionId, userId = 'user-' .. index, state = 'ACTIVE', version = 1,
          persistedSource = source, persistedSourceGeneration = 1,
          clusterLease = {
            name = 'session:user-' .. index .. ':' .. sessionId,
            owner = 'instance-a:' .. sessionId, fencingToken = index, ttlSeconds = 45,
            requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
          }, clusterLeaseDeadlineAt = now + 25000,
          authorityDeadlineAt = now + 25000
        }))
      end
      local sessionRepository = {}
      function sessionRepository:close(candidate)
        if not recover then return nil, { code = 'DATABASE_UNAVAILABLE' } end
        closeOrder[#closeOrder + 1] = candidate.id
        assert(candidate.persistedSource == 40 + tonumber(candidate.id:sub(9)))
        assert(candidate.persistedSourceGeneration == 1)
        return true, nil
      end
      function sessionRepository:getState()
        return nil, { code = 'SESSION_NOT_FOUND' }
      end
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players,
        owners = registries.owners, instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() return true end } },
        config = { duplicatePolicy = 'deny_new', maximumActiveSessions = 3,
          maximumConcurrentConnections = 4, pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = {
          acquire = function()
            leaseAcquires = leaseAcquires + 1
            return nil, { code = 'UNEXPECTED_LEASE_ACQUIRE' }
          end,
          release = function() releaseCount = releaseCount + 1 return true, nil end,
          renew = function() return true, nil end
        },
        instances = { bootId = function() return 'boot-a', nil end },
        characters = { unload = function() return true, nil end },
        userRepository = { authenticate = function()
          return { id = 'capacity-user', status = 'active' }, nil
        end },
        accessRepository = { check = function() return true, nil end },
        sessionRepository = sessionRepository,
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function()
          return {{ type = 'license', value = 'capacity', normalized = 'license:capacity' }}
        end,
        sha256 = function() return string.rep('a', 64) end,
        sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
        transition = function(candidate, target)
          candidate.state = target
          candidate.version = (candidate.version or 0) + 1
          return candidate, nil
        end
      })
      for index = 1, 3 do
        local report = assert(connection:handleDropped(40 + index, 'database outage'))
        assert(report.closed == false)
      end
      assert(players:activeCount() == 3 and connection:snapshot().activeSessions == 3)
      assert(players:getBySource(41) == nil and players:getBySource(42) == nil
        and players:getBySource(43) == nil)
      assert(connection:handleConnecting(-20, 'capacity', {
        defer = function() end, update = function() end,
        done = function(reason) completions[#completions + 1] = reason end
      }))
      assert(#completions == 1 and completions[1]:find('[SERVER_FULL]', 1, true))
      assert(leaseAcquires == 0 and players:activeCount() == 3)

      recover = true
      for index = 1, 3 do
        local report = assert(connection:reconcileClosures(1))
        assert(report.inspected == 1 and report.closed == 1 and report.pending == 3 - index)
      end
      assert(table.concat(closeOrder, ',') == 'session-1,session-2,session-3')
      assert(players:activeCount() == 0 and releaseCount == 3)
      return table.concat({#closeOrder, releaseCount, leaseAcquires,
        connection:snapshot().activeSessions}, ':')
    `);
    assert.equal(result, '3:3:0:0');
  } finally {
    engine.global.close();
  }
});

test('join compensation detaches before two failed closes and later unblocks deny_new', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, closeCalls, renewCalls, releases = 1000, 0, 0, 0
      local durableOpen, recover = false, false
      local identifiers = { [-1] = {'license:victim'}, [42] = {'license:victim'},
        [-2] = {'license:victim'} }
      local doneReasons, drops, purges = {}, {}, 0
      local platform = {
        nowGame = function() return now end, random = function() return 67 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + (delay or 0) end, defer = function() end,
        getPlayerIdentifiers = function(source) return identifiers[source] or {} end,
        isPlayerAceAllowed = function() return false end,
        dropPlayer = function(source) drops[#drops + 1] = source end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('join-close-recovery')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
      end
      function leases:renew()
        renewCalls = renewCalls + 1
        if renewCalls == 7 then return nil, { code = 'LEASE_LOST' } end
        return true, nil
      end
      function leases:release() releases = releases + 1 return true, nil end
      local sessionRepository = {}
      function sessionRepository:create()
        durableOpen = true
        return true, nil
      end
      function sessionRepository:close(candidate)
        closeCalls = closeCalls + 1
        assert(candidate.userId == 'user-victim')
        assert(candidate.persistedSource == 42 and candidate.persistedSourceGeneration == 1)
        if not recover then return nil, { code = 'DATABASE_UNAVAILABLE' } end
        durableOpen = false
        return true, nil
      end
      function sessionRepository:getState()
        return { userId = 'user-victim', serverInstanceId = 'instance-a', source = 42,
          sourceGeneration = 1, state = durableOpen and 'SELECTING_CHARACTER' or 'CLOSED',
          closed = not durableOpen }, nil
      end
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players,
        owners = registries.owners, instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function() end
        } },
        messaging = { network = { purgeSource = function(_, source, generation)
          assert(source == 42 and generation == 1)
          purges = purges + 1
          return true
        end } },
        config = { duplicatePolicy = 'deny_new', maximumActiveSessions = 2,
          maximumConcurrentConnections = 2, pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = leases,
        instances = {
          bootId = function() return 'boot-a', nil end,
          hasOpenUserSessions = function() return durableOpen, nil end
        },
        characters = { unload = function() return true, nil end },
        userRepository = {
          authenticate = function() return { id = 'user-victim', status = 'active' }, nil end,
          findByIdentifiers = function() return { id = 'user-victim', status = 'active' }, nil end
        },
        accessRepository = { check = function() return true, nil end },
        sessionRepository = sessionRepository,
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function()
          return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
        end,
        sha256 = function() return string.rep('b', 64) end,
        sessionTransitions = { SELECTING_CHARACTER = { DISCONNECTING = true } },
        transition = function(candidate, target)
          candidate.state = target
          candidate.version = (candidate.version or 0) + 1
          return candidate, nil
        end
      })
      local function deferrals(source)
        return { defer = function() end, update = function() end, done = function(reason)
          doneReasons[source] = reason or '<accepted>'
        end }
      end
      assert(connection:handleConnecting(-1, 'victim', deferrals(-1)))
      assert(players:getPending(-1) ~= nil, tostring(doneReasons[-1]))
      local joined, joinError = connection:handleJoining(42, -1)
      assert(joined == nil and joinError.code == 'JOIN_LEASE_LOST',
        tostring(joined) .. ':' .. tostring(joinError and joinError.code))
      assert(closeCalls == 2 and durableOpen and #drops == 1 and drops[1] == 42,
        table.concat({closeCalls, tostring(durableOpen), #drops, tostring(drops[1])}, ':'))
      assert(purges == 1 and players:getBySource(42) == nil,
        tostring(purges) .. ':' .. tostring(players:getBySource(42)))
      local retained = assert(players:sessionsByUser('user-victim')[1])
      assert(retained.source == nil and players:activeCount() == 1 and releases == 0)

      local replacementPending, replacementPendingError = players:createPending(
        -99, { sessionId = 'replacement' })
      assert(replacementPending, replacementPendingError and replacementPendingError.code)
      local replacementBound, replacementBindError = players:bindJoined(-99, 42, {
        id = 'replacement', userId = 'other-user', state = 'ACTIVE', version = 1,
        persistedSource = 42, persistedSourceGeneration = 3
      })
      assert(replacementBound, replacementBindError and replacementBindError.code)
      recover = true
      local reconciliation, reconciliationError = connection:reconcileClosures(1)
      assert(reconciliation, reconciliationError and reconciliationError.code)
      assert(reconciliation.closed == 1 and reconciliation.pending == 0)
      assert(closeCalls == 3 and durableOpen == false and releases == 1,
        table.concat({closeCalls, tostring(durableOpen), releases}, ':'))
      local replacement = players:getBySource(42)
      assert(replacement and replacement.id == 'replacement',
        tostring(replacement and replacement.id))
      assert(players:sessionsByUser('user-victim')[1] == nil)

      assert(connection:handleConnecting(-2, 'victim retry', deferrals(-2)))
      assert(doneReasons[-2] == '<accepted>')
      return table.concat({closeCalls, releases, purges, players:activeCount(),
        doneReasons[-2]}, ':')
    `);
    assert.equal(result, '3:1:1:1:<accepted>');
  } finally {
    engine.global.close();
  }
});

test('SESSION_CONFLICT is terminal only for the exact closed durable identity', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local exact, stateReads, releases = false, 0, 0
      local platform = { nowGame = function() return 1000 end, random = function() return 71 end,
        print = function() end, wait = function() end, jsonEncode = function() return '{}' end }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('close-conflict')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      assert(players:createPending(-1, { sessionId = 'conflict-session' }))
      assert(players:bindJoined(-1, 33, {
        id = 'conflict-session', userId = 'expected-user', state = 'DISCONNECTING', version = 1,
        persistedSource = 33, persistedSourceGeneration = 1,
        clusterLease = { name = 'session:expected-user:conflict-session',
          owner = 'instance-a:conflict-session', fencingToken = 1,
          requesterInstanceId = 'instance-a', requesterBootId = 'boot-a' },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))
      local maintenance = SynexCoreFactories.identityConnectionMaintenance({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { setHealth = function() end } },
        messaging = { network = { purgeSource = function() end } },
        config = { maximumActiveSessions = 1 }, instanceId = 'instance-a',
        leases = {}, instances = {}, characters = {},
        sessionRepository = {
          close = function() return nil, { code = 'SESSION_CONFLICT' } end,
          getState = function()
            stateReads = stateReads + 1
            return { userId = exact and 'expected-user' or 'foreign-user',
              serverInstanceId = 'instance-a', source = 33, sourceGeneration = 1,
              state = 'CLOSED', closed = true }, nil
          end
        },
        sessionTransitions = {}, transition = function() end,
        rateLimiter = { purge = function() end }, joinClaims = { invalidate = function() end },
        logConnectionStage = function() end, releaseAdmission = function() end,
        releaseConnectionLease = function() releases = releases + 1 return true, nil end,
        refreshLeaseDeadline = function(connection, field, startedAt)
          local key = field == 'clusterLease' and 'clusterLeaseDeadlineAt'
            or 'admissionGateDeadlineAt'
          connection[key] = startedAt + 25000
          connection.authorityDeadlineAt = connection.clusterLeaseDeadlineAt
            or connection.admissionGateDeadlineAt
          return connection.authorityDeadlineAt
        end,
        clearQueueEntry = function() end, recordReconnectGrace = function() end,
        purgeReconnectGrace = function() end, isQuiesced = function() return false end
      })
      local first = assert(maintenance:closeOrDefer(players:getSession('conflict-session'),
        'conflict', { attempts = 1 }))
      assert(first.deferred and players:activeCount() == 1 and releases == 0)
      local retry, retryError = maintenance:reconcileClosures(1)
      assert(retry == nil and retryError.code == 'SESSION_CONFLICT')
      assert(players:activeCount() == 1 and releases == 0)
      exact = true
      local resolved = assert(maintenance:reconcileClosures(1))
      assert(resolved.closed == 1 and resolved.pending == 0)
      assert(players:activeCount() == 0 and releases == 1 and stateReads == 3)
      return table.concat({stateReads, releases, players:activeCount()}, ':')
    `);
    assert.equal(result, '3:1:0');
  } finally {
    engine.global.close();
  }
});
