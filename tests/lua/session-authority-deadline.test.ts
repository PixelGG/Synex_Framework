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
    'core/synex_core/server/identity_connection_heartbeat.lua',
    'core/synex_core/server/identity_connection_maintenance.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('registry and public player boundaries reject expired or malformed authority', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now = 1000
      local foundation = SynexCoreFactories.foundation({ platform = {
        nowGame = function() return now end, random = function() return 79 end,
        print = function() end
      } })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players
      assert(players:createPending(-1, { sessionId = 'session-a' }))
      local session = assert(players:bindJoined(-1, 51, {
        id = 'session-a', userId = 'user-a', state = 'ACTIVE', version = 1,
        clusterLease = { name = 'session:user-a:session-a', owner = 'instance-a:session-a',
          fencingToken = 4, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))
      assert(players:bindCharacter(session.id, 'character-a'))
      assert(players:getBySource(51).id == session.id)
      assert(players:getByCharacter('character-a').id == session.id)
      assert(players:sessionsByUser('user-a')[1].id == session.id)
      assert(players:isCurrent(session.id, 51, session.sourceGeneration))

      now = 26000
      assert(players:getBySource(51) == nil and players:getByCharacter('character-a') == nil)
      assert(#players:sessionsByUser('user-a') == 0)
      assert(not players:isCurrent(session.id, 51, session.sourceGeneration))
      assert(players:getRawBySource(51).id == session.id)
      assert(players:rawSessionsByUser('user-a')[1].id == session.id)
      assert(players:isRawCurrent(session.id, 51, session.sourceGeneration))

      assert(players:updateSession(session.id, function(candidate)
        candidate.clusterLease = {}
        candidate.authorityDeadlineAt = nil
      end))
      assert(players:getBySource(51) == nil)
      assert(players:updateSession(session.id, function(candidate)
        candidate.clusterLease = 'malformed'
        candidate.authorityDeadlineAt = now + 100000
      end))
      assert(players:getBySource(51) == nil)
      return table.concat({#players:sessionsByUser('user-a'),
        #players:rawSessionsByUser('user-a'), tostring(players:getBySource(51))}, ':')
    `);
    assert.equal(result, '0:1:nil');
  } finally {
    engine.global.close();
  }
});

test('successful heartbeats extend only bounded authority and lost authority is synchronously detached', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, renewCalls = 1000, 0
      local handled, releases, purges = 0, 0, 0
      local touchBatches, drops = {}, 0
      local platform = {
        nowGame = function() return now end, random = function() return 83 end,
        print = function() end, wait = function(delay) now = now + (delay or 0) end,
        dropPlayer = function(source)
          drops = drops + 1
          assert(source == 52)
          if drops == 1 then
            error('fixture drop failure')
          elseif drops == 3 then
            local players = _G.deadlinePlayers
            assert(players:getRawBySource(source) == nil)
            assert(players:createPending(-99, { sessionId = 'replacement' }))
            assert(players:bindJoined(-99, source, {
              id = 'replacement', userId = 'user-b', state = 'ACTIVE', version = 1
            }))
          end
          return false
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players
      _G.deadlinePlayers = players
      assert(players:createPending(-1, { sessionId = 'session-a' }))
      local session = assert(players:bindJoined(-1, 52, {
        id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER', version = 1,
        persistedSource = 52, persistedSourceGeneration = 1,
        clusterLease = { name = 'session:user-a:session-a', owner = 'instance-a:session-a',
          fencingToken = 7, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))
      local sessionRepository = {
        close = function(_, candidate)
          assert(candidate.id == 'session-a' and candidate.persistedSource == 52)
          return true, nil
        end,
        getState = function() return nil, { code = 'SESSION_NOT_FOUND' } end
      }
      local maintenance = SynexCoreFactories.identityConnectionMaintenance({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { setHealth = function() end } },
        messaging = { network = { purgeSource = function(_, source, generation)
          assert(source == 52 and generation == 1); purges = purges + 1; return true
        end } },
        stateService = { purgePlayer = function(_, source, generation)
          assert(source == 52 and generation == 1)
          return { failures = {} }, nil
        end },
        config = { clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000,
          maximumActiveSessions = 2 },
        leases = { renew = function()
          renewCalls = renewCalls + 1
          return true, nil
        end },
        instances = {
          touchSessions = function(_, ids)
            touchBatches[#touchBatches + 1] = table.concat(ids, ',')
            return true, nil
          end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function() return {}, nil end,
          completeControl = function() return true, nil end
        },
        characters = {}, sessionRepository = sessionRepository,
        sessionTransitions = { SELECTING_CHARACTER = { DISCONNECTING = true } },
        transition = function(candidate, target)
          candidate.state = target; candidate.version = candidate.version + 1
          return candidate, nil
        end,
        rateLimiter = { purge = function() end },
        joinClaims = { invalidate = function() end }, logConnectionStage = function() end,
        releaseAdmission = function() end,
        releaseConnectionLease = function() releases = releases + 1; return true, nil end,
        refreshLeaseDeadline = function(candidate, field, startedAt)
          assert(field == 'clusterLease')
          local deadline = startedAt + 25000
          if deadline <= now then return nil end
          candidate.clusterLeaseDeadlineAt = deadline
          candidate.authorityDeadlineAt = deadline
          return deadline
        end,
        clearQueueEntry = function() end, recordReconnectGrace = function() end,
        purgeReconnectGrace = function() end, isQuiesced = function() return false end
      })

      assert(maintenance:heartbeat())
      assert(players:getBySource(52).authorityDeadlineAt == 26000)
      now = 20000
      assert(maintenance:heartbeat())
      assert(players:getBySource(52).authorityDeadlineAt == 45000)
      now = 27000
      assert(players:getBySource(52).id == 'session-a')
      handled = handled + (players:getBySource(52) and 1 or 0)

      now = 45000
      assert(players:getBySource(52) == nil)
      handled = handled + (players:getBySource(52) and 1 or 0)
      local healthy, heartbeatError = maintenance:heartbeat()
      assert(not healthy and heartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
      assert(renewCalls == 2 and touchBatches[#touchBatches] == '')
      assert(players:getRawBySource(52) == nil and players:getSession('session-a') == nil)
      assert(maintenance:pendingDisconnectRetries() == 1)
      assert(drops == 1 and purges == 1 and releases == 1 and handled == 1)

      local retryHealthy, retryError = maintenance:heartbeat()
      assert(not retryHealthy and retryError.code == 'PLAYER_DROP_FAILED')
      assert(maintenance:pendingDisconnectRetries() == 1 and drops == 2)
      assert(maintenance:heartbeat())
      assert(maintenance:pendingDisconnectRetries() == 0 and drops == 3)
      assert(players:getBySource(52).id == 'replacement')
      assert(players:activeCount() == 1)
      return table.concat({renewCalls, handled, drops, purges, releases,
        players:getBySource(52).sourceGeneration}, ':')
    `);
    assert.equal(result, '2:1:3:1:1:3');
  } finally {
    engine.global.close();
  }
});

test('pending lease rotation refreshes three authorities before their safe deadline', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local now, renewals = 1000, 0
      local platform = {
        nowGame = function() return now end, random = function() return 89 end,
        print = function() end, wait = function(delay) now = now + (delay or 0) end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players
      for index = 1, 3 do
        assert(players:createPending(-index, {
          id = 'pending-' .. index, sessionId = 'session-' .. index,
          tempSource = -index, userId = 'user-' .. index, state = 'AUTHENTICATED',
          expiresAt = 120000,
          clusterLease = { name = 'session:user-' .. index, owner = 'instance:' .. index,
            fencingToken = index, ttlSeconds = 45 },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }))
      end
      local maintenance = SynexCoreFactories.identityConnectionMaintenance({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { setHealth = function() end } },
        messaging = { network = { purgeSource = function() end } },
        config = { clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = { renew = function() renewals = renewals + 1 return true, nil end },
        instances = {
          touchSessions = function() return true, nil end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function() return {}, nil end,
          completeControl = function() return true, nil end
        },
        characters = {}, sessionRepository = {}, sessionTransitions = {},
        transition = function() end, rateLimiter = { purge = function() end },
        joinClaims = { invalidate = function() end }, logConnectionStage = function() end,
        releaseAdmission = function() end, releaseConnectionLease = function() return true, nil end,
        refreshLeaseDeadline = function(candidate, field, startedAt)
          candidate.clusterLeaseDeadlineAt = startedAt + 25000
          candidate.authorityDeadlineAt = candidate.clusterLeaseDeadlineAt
          return candidate.authorityDeadlineAt > now and candidate.authorityDeadlineAt or nil
        end,
        clearQueueEntry = function() end, recordReconnectGrace = function() end,
        purgeReconnectGrace = function() end, isQuiesced = function() return false end
      })
      for tick = 1, 3 do
        now = tick * 10000
        assert(maintenance:heartbeat())
        for index = 1, 3 do
          assert(players:getPending(-index), 'pending expired before bounded renewal')
        end
      end
      assert(renewals == 6)
      return table.concat({renewals, players:getPending(-1).authorityDeadlineAt,
        players:getPending(-2).authorityDeadlineAt,
        players:getPending(-3).authorityDeadlineAt}, ':')
    `);
    assert.equal(result, '6:45000:55000:55000');
  } finally {
    engine.global.close();
  }
});

test('bridge and exported player access resolve sessions through authority-aware registry methods', async () => {
  const [bridge, bootstrap, registries] = await Promise.all([
    readFile(path.join(root, 'libraries/synex_bridge/native_server.lua'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/server/bootstrap_api.lua'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/server/registries.lua'), 'utf8'),
  ]);
  assert.match(bridge, /Players\.getBySource/u);
  assert.match(bootstrap, /registries\.players:getBySource/u);
  assert.match(bootstrap, /registries\.players:sessionsByUser/u);
  assert.match(registries, /function playerRegistry:getBySource[\s\S]*?authorityCurrent\(session\)/u);
  assert.match(registries, /function playerRegistry:sessionsByUser[\s\S]*?authorityCurrent/u);
});
