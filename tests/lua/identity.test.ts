import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('replace_old closes local authority before acquiring the new cluster lease', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/registries.lua',
      'core/synex_core/server/identity_common.lua',
      'core/synex_core/server/identity_repository.lua',
      'core/synex_core/server/identity_characters.lua',
      'core/synex_core/server/identity_connections.lua',
      'core/synex_core/server/identity.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local now, released, acquired, purged = 1000, 0, 0, 0
      local dropped, completed = {}, nil
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
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'old-session' }))
      assert(players:bindJoined(-1, 41, {
        id = 'old-session', userId = 'user-fixture', state = 'SELECTING_CHARACTER',
        version = 2, persistedVersion = 2,
        clusterLease = { leaseName = 'session:user-fixture', owner = 'old-owner', fencingToken = 1 }
      }))

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
      function database:update()
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

      local identity = SynexCoreFactories.identity({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        owners = owners,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = function() purged = purged + 1 end } },
        config = {
          duplicatePolicy = 'replace_old', allowlistRequired = false, queueEnabled = false,
          pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45
        },
        instanceId = 'instance-a',
        coreResource = 'synex_core',
        leases = leases,
        instances = instances
      })
      identity.connections:handleConnecting(-2, 'Fixture', {
        defer = function() end,
        update = function() end,
        done = function(reason) completed = reason == nil and '<accepted>' or reason end
      })

      assert(completed == '<accepted>')
      assert(players:getSession('old-session') == nil)
      assert(type(dropped[41]) == 'string')
      assert(released == 1 and acquired == 1 and purged == 1)
      local pending = assert(players:getPending(-2))
      assert(pending.state == 'AUTHENTICATED')
      assert(pending.clusterLease.fencingToken == 2)
      return table.concat({completed, released, acquired, purged}, ':')
    `);
    assert.equal(result, '<accepted>:1:1:1');
  } finally {
    engine.global.close();
  }
});
