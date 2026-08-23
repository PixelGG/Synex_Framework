import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function createEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/registries.lua',
    'core/synex_core/server/identity_connection_claims.lua',
    'core/synex_core/server/identity_connection_authority.lua',
    'core/synex_core/server/identity_connection_heartbeat.lua',
    'core/synex_core/server/identity_connection_maintenance.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('the per-user admission gate serializes policy transitions and sequential allow sessions', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, policy, durableOpen = 1000, 'deny_new', true
      local leasesByName, acquiredNames, durableChecks = {}, {}, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 7 end,
        wait = function(delay) now = now + delay end,
        print = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      local function refreshDeadline(connection, field, startedAt)
        local key = field == 'clusterLease' and 'clusterLeaseDeadlineAt'
          or 'admissionGateDeadlineAt'
        connection[key] = startedAt + 25000
        connection.authorityDeadlineAt = math.min(
          connection.clusterLeaseDeadlineAt or math.huge,
          connection.admissionGateDeadlineAt or math.huge)
        return connection.authorityDeadlineAt
      end
      local function syncAuthority(connection)
        return players:updatePending(connection.tempSource, function(candidate)
          candidate.clusterLease = foundation.copy(connection.clusterLease)
          candidate.admissionGateLease = foundation.copy(connection.admissionGateLease)
          candidate.clusterLeaseDeadlineAt = connection.clusterLeaseDeadlineAt
          candidate.admissionGateDeadlineAt = connection.admissionGateDeadlineAt
          candidate.authorityDeadlineAt = connection.authorityDeadlineAt
        end)
      end
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        local row = leasesByName[name]
        if row and row.expiresAt > now and row.owner ~= owner then
          return nil, foundation.error('LEASE_BUSY', 'fixture busy', { retryable = true })
        end
        local token = row and row.fencingToken + 1 or 1
        row = { name = name, owner = owner, fencingToken = token, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId,
          expiresAt = now + ttl * 1000 }
        leasesByName[name] = row
        acquiredNames[#acquiredNames + 1] = name
        return foundation.copy(row), nil
      end
      function leases:renew(lease)
        local row = leasesByName[lease.name]
        if not row or row.expiresAt <= now or row.owner ~= lease.owner
          or row.fencingToken ~= lease.fencingToken then
          return nil, foundation.error('LEASE_LOST', 'fixture stale', { retryable = true })
        end
        row.expiresAt = now + lease.ttlSeconds * 1000
        return true, nil
      end
      function leases:release(lease)
        local row = leasesByName[lease.name or lease.leaseName]
        if row and row.owner == lease.owner and row.fencingToken == lease.fencingToken then
          row.expiresAt = now
          return true, nil
        end
        return nil, foundation.error('LEASE_LOST', 'fixture stale', { retryable = true })
      end
      local instances = {
        bootId = function() return 'boot-a', nil end,
        hasOpenUserSessions = function(_, userId, remoteOnly, gate, guard)
          durableChecks = durableChecks + 1
          assert(userId == 'user-a' and remoteOnly == false)
          assert(gate.name == 'admission:user-a' and guard())
          return durableOpen, nil
        end,
        requestRemoteKicks = function() error('deny/allow must not request remote kicks') end
      }
      local function releaseConnection(connection)
        for _, field in ipairs({'clusterLease', 'admissionGateLease'}) do
          if connection[field] then assert(leases:release(connection[field])); connection[field] = nil end
        end
        return true, nil
      end
      local authority = SynexCoreFactories.identityConnectionAuthority({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        leases = leases, instances = instances, instanceId = 'instance-a',
        duplicatePolicy = function() return policy end,
        joinClaims = SynexCoreFactories.identityConnectionClaims({ foundation = foundation }),
        clearQueueEntry = function() end, releaseAdmission = function() end,
        releaseConnectionLease = releaseConnection, resetAdmissionState = function() end,
        refreshLeaseDeadline = refreshDeadline, syncPendingAuthority = syncAuthority,
        logConnectionStage = function() end,
        config = { clusterSessionLeaseSeconds = 45, queueTimeoutMs = 5000, pendingTtlMs = 5000 }
      })
      local terminal = { state = 'open', update = function() end, afterTick = function() end }
      local function pending(id, source)
        local connection = { id = id, sessionId = 'session-' .. id,
          tempSource = source, userId = 'user-a', state = 'AUTHENTICATING' }
        assert(players:createPending(source, connection))
        return connection
      end

      -- A durable session created by an older allow-policy node is visible to
      -- deny_new even though it owns an individual session lease.
      local denied = pending('deny', -1)
      assert(authority:acquireAdmissionGate(denied, 'user-a', terminal))
      local admitted, deniedError = authority:acquireDuplicate(
        denied, 'user-a', terminal, 'deny_new')
      assert(admitted == nil and deniedError.code == 'DUPLICATE_SESSION')
      assert(leasesByName['session:user-a'] == nil and durableChecks == 1)
      assert(releaseConnection(denied))

      -- Allow remains parallel at the session-lease layer, but every insert
      -- passes through the same reusable user gate.
      policy, durableOpen = 'allow', false
      local first = pending('allow-a', -2)
      assert(authority:acquireAdmissionGate(first, 'user-a', terminal))
      assert(authority:acquireDuplicate(first, 'user-a', terminal, 'allow'))
      leasesByName['admission:user-a'].expiresAt = now -- atomic insert/retire
      players:removePending(-2)

      local second = pending('allow-b', -3)
      assert(authority:acquireAdmissionGate(second, 'user-a', terminal))
      assert(authority:acquireDuplicate(second, 'user-a', terminal, 'allow'))
      assert(first.clusterLease.name ~= second.clusterLease.name)
      assert(first.clusterLease.name == 'session:user-a:session-allow-a',
        tostring(first.clusterLease.name))
      assert(second.clusterLease.name == 'session:user-a:session-allow-b',
        tostring(second.clusterLease.name))
      assert(leasesByName['admission:user-a'].fencingToken == 3)
      return table.concat({durableChecks, #acquiredNames,
        leasesByName['admission:user-a'].fencingToken}, ':')
    `);
    assert.equal(result, '1:5:3');
  } finally {
    engine.global.close();
  }
});

test('kick_old drains every bounded remote page before shared authority is acquired', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, remoteOpen, pendingClose = 1000, 65, 0
      local batches, sharedAcquiredAt = {}, nil
      local leasesByName = {}
      local platform = {
        nowGame = function() return now end, random = function() return 11 end,
        print = function() end,
        wait = function(delay)
          now = now + delay
          remoteOpen = math.max(0, remoteOpen - pendingClose)
          pendingClose = 0
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local function refreshDeadline(connection, field, startedAt)
        local key = field == 'clusterLease' and 'clusterLeaseDeadlineAt'
          or 'admissionGateDeadlineAt'
        connection[key] = startedAt + 25000
        connection.authorityDeadlineAt = math.min(
          connection.clusterLeaseDeadlineAt or math.huge,
          connection.admissionGateDeadlineAt or math.huge)
        return connection.authorityDeadlineAt
      end
      local function syncAuthority(connection)
        return registries.players:updatePending(connection.tempSource, function(candidate)
          candidate.clusterLease = foundation.copy(connection.clusterLease)
          candidate.admissionGateLease = foundation.copy(connection.admissionGateLease)
          candidate.clusterLeaseDeadlineAt = connection.clusterLeaseDeadlineAt
          candidate.admissionGateDeadlineAt = connection.admissionGateDeadlineAt
          candidate.authorityDeadlineAt = connection.authorityDeadlineAt
        end)
      end
      local connection = { id = 'kick', sessionId = 'session-kick', tempSource = -1,
        userId = 'user-a', state = 'AUTHENTICATING' }
      assert(registries.players:createPending(-1, connection))
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        local row = leasesByName[name]
        if row and row.expiresAt > now and row.owner ~= owner then
          return nil, foundation.error('LEASE_BUSY', 'fixture busy', { retryable = true })
        end
        local token = row and row.fencingToken + 1 or 1
        row = { name = name, owner = owner, fencingToken = token, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId,
          expiresAt = now + ttl * 1000 }
        leasesByName[name] = row
        if name == 'session:user-a' then sharedAcquiredAt = remoteOpen end
        return foundation.copy(row), nil
      end
      function leases:renew(lease)
        local row = leasesByName[lease.name]
        if not row or row.owner ~= lease.owner or row.fencingToken ~= lease.fencingToken
          or row.expiresAt <= now then
          return nil, foundation.error('LEASE_LOST', 'fixture stale', { retryable = true })
        end
        row.expiresAt = now + lease.ttlSeconds * 1000
        return true, nil
      end
      function leases:release(lease)
        local row = leasesByName[lease.name]
        if row then row.expiresAt = now end
        return true, nil
      end
      local instances = {
        bootId = function() return 'boot-a', nil end,
        requestRemoteKicks = function(_, userId, _, guard, gate)
          assert(userId == 'user-a' and guard() and gate.name == 'admission:user-a')
          local requested = math.min(32, remoteOpen)
          pendingClose = requested
          if requested > 0 then batches[#batches + 1] = requested end
          return requested, nil
        end,
        hasOpenUserSessions = function(_, userId, remoteOnly, gate, guard)
          assert(userId == 'user-a' and remoteOnly == false and guard()
            and gate.name == 'admission:user-a')
          return remoteOpen > 0, nil
        end
      }
      local function releaseConnection(candidate)
        for _, field in ipairs({'clusterLease', 'admissionGateLease'}) do
          if candidate[field] then leases:release(candidate[field]); candidate[field] = nil end
        end
        return true, nil
      end
      local authority = SynexCoreFactories.identityConnectionAuthority({
        platform = platform, foundation = foundation, players = registries.players,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        leases = leases, instances = instances, instanceId = 'instance-a',
        duplicatePolicy = function() return 'kick_old' end,
        joinClaims = SynexCoreFactories.identityConnectionClaims({ foundation = foundation }),
        clearQueueEntry = function() end, releaseAdmission = function() end,
        releaseConnectionLease = releaseConnection, resetAdmissionState = function() end,
        refreshLeaseDeadline = refreshDeadline, syncPendingAuthority = syncAuthority,
        logConnectionStage = function() end,
        config = { clusterSessionLeaseSeconds = 45, queueTimeoutMs = 120000,
          pendingTtlMs = 120000, queueUpdateMs = 250 }
      })
      local terminal = { state = 'open', update = function() end, afterTick = function() end }
      assert(authority:acquireAdmissionGate(connection, 'user-a', terminal))
      assert(authority:acquireDuplicate(connection, 'user-a', terminal, 'kick_old'))
      assert(#batches == 3 and batches[1] == 32 and batches[2] == 32 and batches[3] == 1)
      assert(remoteOpen == 0 and sharedAcquiredAt == 0)
      return table.concat({#batches, batches[1], batches[2], batches[3], sharedAcquiredAt}, ':')
    `);
    assert.equal(result, '3:32:32:1:0');
  } finally {
    engine.global.close();
  }
});

test('a parallel admission cannot evaluate policy before the previous insert releases the gate', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, durableOpen, firstInserted, waits = 1000, false, false, 0
      local gate = nil
      local platform = {
        nowGame = function() return now end, random = function() return 13 end,
        print = function() end,
        wait = function(delay)
          now = now + delay
          waits = waits + 1
          if waits == 1 then
            assert(not durableOpen and gate and gate.expiresAt > now - delay)
            durableOpen, firstInserted, gate.expiresAt = true, true, now
          end
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local function refreshDeadline(connection, field, startedAt)
        local key = field == 'clusterLease' and 'clusterLeaseDeadlineAt'
          or 'admissionGateDeadlineAt'
        connection[key] = startedAt + 25000
        connection.authorityDeadlineAt = math.min(
          connection.clusterLeaseDeadlineAt or math.huge,
          connection.admissionGateDeadlineAt or math.huge)
        return connection.authorityDeadlineAt
      end
      local function syncAuthority(connection)
        return registries.players:updatePending(connection.tempSource, function(candidate)
          candidate.clusterLease = foundation.copy(connection.clusterLease)
          candidate.admissionGateLease = foundation.copy(connection.admissionGateLease)
          candidate.clusterLeaseDeadlineAt = connection.clusterLeaseDeadlineAt
          candidate.admissionGateDeadlineAt = connection.admissionGateDeadlineAt
          candidate.authorityDeadlineAt = connection.authorityDeadlineAt
        end)
      end
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        if name == 'admission:user-a' then
          if gate and gate.expiresAt > now and gate.owner ~= owner then
            return nil, foundation.error('LEASE_BUSY', 'fixture busy', { retryable = true })
          end
          gate = { name = name, owner = owner,
            fencingToken = gate and gate.fencingToken + 1 or 1,
            ttlSeconds = ttl, requesterInstanceId = requesterInstanceId,
            requesterBootId = requesterBootId, expiresAt = now + ttl * 1000 }
          return foundation.copy(gate), nil
        end
        return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
      end
      function leases:renew(lease)
        if lease.name == 'admission:user-a' and (not gate or gate.owner ~= lease.owner
          or gate.fencingToken ~= lease.fencingToken or gate.expiresAt <= now) then
          return nil, foundation.error('LEASE_LOST', 'fixture stale', { retryable = true })
        end
        return true, nil
      end
      function leases:release() return true, nil end
      local instances = {
        bootId = function() return 'boot-a', nil end,
        hasOpenUserSessions = function(_, _, _, _, guard)
          assert(firstInserted and guard())
          return durableOpen, nil
        end,
        requestRemoteKicks = function() return 0, nil end
      }
      local authority = SynexCoreFactories.identityConnectionAuthority({
        platform = platform, foundation = foundation, players = registries.players,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        leases = leases, instances = instances, instanceId = 'instance-a',
        duplicatePolicy = function() return 'deny_new' end,
        joinClaims = SynexCoreFactories.identityConnectionClaims({ foundation = foundation }),
        clearQueueEntry = function() end, releaseAdmission = function() end,
        releaseConnectionLease = function() return true, nil end,
        refreshLeaseDeadline = refreshDeadline, syncPendingAuthority = syncAuthority,
        resetAdmissionState = function() end, logConnectionStage = function() end,
        config = { clusterSessionLeaseSeconds = 45, queueTimeoutMs = 5000, pendingTtlMs = 5000 }
      })
      local terminal = { state = 'open', update = function() end, afterTick = function() end }
      local first = { id = 'first', sessionId = 'session-first', tempSource = -1,
        userId = 'user-a', state = 'AUTHENTICATING' }
      local second = { id = 'second', sessionId = 'session-second', tempSource = -2,
        userId = 'user-a', state = 'AUTHENTICATING' }
      assert(registries.players:createPending(-1, first))
      assert(registries.players:createPending(-2, second))
      assert(authority:acquireAdmissionGate(first, 'user-a', terminal))
      assert(authority:acquireAdmissionGate(second, 'user-a', terminal))
      local admitted, admissionError = authority:acquireDuplicate(
        second, 'user-a', terminal, 'deny_new')
      assert(admitted == nil and admissionError.code == 'DUPLICATE_SESSION')
      assert(firstInserted and waits == 1 and gate.owner == 'instance-a:session-second')
      return table.concat({waits, gate.fencingToken, admissionError.code}, ':')
    `);
    assert.equal(result, '1:2:DUPLICATE_SESSION');
  } finally {
    engine.global.close();
  }
});

test('a pending heartbeat cannot resurrect an admission gate retired by the session commit', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, gateRetired, releases = 1000, false, 0
      local renewals = {}
      local platform = {
        nowGame = function() return now end, random = function() return 17 end,
        wait = function(delay) now = now + delay end, print = function() end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      local pending = {
        id = 'connection-a', sessionId = 'session-a', tempSource = -1,
        userId = 'user-a', state = 'AUTHENTICATED', receivedAt = now,
        expiresAt = now + 120000,
        admissionGateLease = { name = 'admission:user-a', owner = 'instance-a:session-a',
          fencingToken = 3, ttlSeconds = 45 },
        clusterLease = { name = 'session:user-a', owner = 'instance-a:session-a',
          fencingToken = 7, ttlSeconds = 45 },
        admissionGateDeadlineAt = now + 25000,
        clusterLeaseDeadlineAt = now + 25000,
        authorityDeadlineAt = now + 25000
      }
      assert(players:createPending(-1, pending))
      local leases = {}
      function leases:renew(lease)
        renewals[#renewals + 1] = lease.name
        if lease.name == 'admission:user-a' and not gateRetired then
          -- The join transaction commits and retires the gate after this
          -- heartbeat selected its stale pending snapshot.
          local bound = assert(players:bindJoined(-1, 42, {
            id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER',
            version = 2, persistedVersion = 2, persistencePending = true,
            clusterLease = pending.clusterLease,
            admissionGateLease = pending.admissionGateLease,
            admissionGateDeadlineAt = pending.admissionGateDeadlineAt,
            clusterLeaseDeadlineAt = pending.clusterLeaseDeadlineAt,
            authorityDeadlineAt = pending.authorityDeadlineAt
          }))
          assert(bound.id == 'session-a')
          gateRetired = true
          return nil, foundation.error('LEASE_LOST', 'gate retired', { retryable = true })
        end
        assert(lease.name ~= 'admission:user-a', 'retired gate was renewed twice')
        return true, nil
      end
      function leases:release()
        releases = releases + 1
        return true, nil
      end
      local maintenance = SynexCoreFactories.identityConnectionMaintenance({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { setHealth = function() end } },
        messaging = { network = { purgeSource = function() end } },
        config = { clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = leases,
        instances = {
          touchSessions = function(_, ids) assert(#ids == 1 and ids[1] == 'session-a'); return true, nil end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function() return {}, nil end,
          completeControl = function() return true, nil end
        },
        characters = {}, sessionRepository = {}, sessionTransitions = {},
        transition = function() return true, nil end,
        rateLimiter = { purge = function() end },
        joinClaims = SynexCoreFactories.identityConnectionClaims({ foundation = foundation }),
        logConnectionStage = function() end, releaseAdmission = function() end,
        releaseConnectionLease = function() releases = releases + 1; return true, nil end,
        refreshLeaseDeadline = function(connection, field, startedAt)
          local key = field == 'clusterLease' and 'clusterLeaseDeadlineAt'
            or 'admissionGateDeadlineAt'
          connection[key] = startedAt + 25000
          connection.authorityDeadlineAt = math.min(
            connection.clusterLeaseDeadlineAt or math.huge,
            connection.admissionGateDeadlineAt or math.huge)
          return connection.authorityDeadlineAt
        end,
        clearQueueEntry = function() end, recordReconnectGrace = function() end,
        purgeReconnectGrace = function() end, isQuiesced = function() return false end
      })
      local healthy, heartbeatError = maintenance:heartbeat()
      assert(healthy, heartbeatError and heartbeatError.code)
      local session = assert(players:getSession('session-a'))
      assert(gateRetired and session.persistencePending == true and releases == 0)
      assert(#renewals == 2 and renewals[1] == 'admission:user-a'
        and renewals[2] == 'session:user-a')
      return table.concat({tostring(gateRetired), releases, #renewals}, ':')
    `);
    assert.equal(result, 'true:0:2');
  } finally {
    engine.global.close();
  }
});
