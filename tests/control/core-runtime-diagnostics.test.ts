import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

async function coreEngine(files: string[]) {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/shared/protocol.lua',
    'core/synex_core/server/factories.lua',
    ...files.map((file) => `core/synex_core/server/${file}.lua`),
  ]) {
    await engine.doString(await source(relativePath));
  }
  return engine;
}

test('player registry pages a large session index without materializing a full snapshot', async () => {
  const engine = await coreEngine(['foundation', 'registries']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function(_, maximum) return math.min(maximum or 1, 17) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players

      local function join(index, id, leaseDeadline)
        local tempSource = -index
        assert(players:createPending(tempSource, { sessionId = id, tempSource = tempSource }))
        local session = {
          id = id, userId = ('user-%05d'):format(index), state = 'ACTIVE', version = 1,
          serverInstanceId = 'instance-a', connectedAt = '2026-08-26T00:00:00Z'
        }
        if leaseDeadline ~= nil then
          session.clusterLease = { name = 'session:' .. id }
          session.authorityDeadlineAt = leaseDeadline
        end
        assert(players:bindJoined(tempSource, index, session))
      end

      for index = 1, 10000 do
        join(index, ('session-%05d'):format(index), index == 5000 and 999 or nil)
      end
      local first = assert(players:listSessions({ limit = 3 }))
      assert(first.total == 10000 and #first.items == 3 and first.items[1].id == 'session-00001')
      assert(first.nextCursor == 'session-00003' and first.hasMore == true)

      join(10001, 'session-00000', nil)
      local second = assert(players:listSessions({ cursor = first.nextCursor, limit = 3 }))
      assert(second.items[1].id == 'session-00004' and second.items[3].id == 'session-00006')
      assert(second.nextCursor == 'session-00006' and second.hasMore == true)

      local stale = assert(players:staleSessions({
        cursor = 'session-04998', limit = 5, scanLimit = 10
      }))
      assert(stale.scanned == 10 and stale.matched == 1 and #stale.items == 1)
      assert(stale.items[1].sessionId == 'session-05000'
        and stale.items[1].reasons[1] == 'AUTHORITY_EXPIRED')
      assert(stale.complete == false and stale.nextCursor == 'session-05008')

      local changed, changedError = players:updateSession('session-00004', function(candidate)
        candidate.id = 'session-tampered'
      end)
      assert(changed == nil and changedError.code == 'SESSION_IDENTITY_CHANGED')
      assert(players:removeSession('session-00005'))
      local afterRemoval = assert(players:listSessions({ cursor = 'session-00004', limit = 2 }))
      assert(afterRemoval.items[1].id == 'session-00006')
      return table.concat({ first.total, first.nextCursor, stale.items[1].reasons[1] }, ':')
    `);
    assert.equal(result, '10000:session-00003:AUTHORITY_EXPIRED');
  } finally {
    engine.global.close();
  }
});

test('generic outbox diagnostics expose bounded state and keyset metadata without payloads', async () => {
  const engine = await coreEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function(_, maximum) return math.min(maximum or 1, 17) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local pageCalls = 0
      local database = {}
      function database:query(sql, parameters)
        if sql:find('GROUP BY \`state\`', 1, true) then
          return {
            { state = 'pending', total = '2', retried = '1', attempts = '2',
              maximum_attempts = '2', oldest_age_ms = '5000' },
            { state = 'publishing', total = '1', retried = '1', attempts = '1',
              maximum_attempts = '1', oldest_age_ms = '2000' },
            { state = 'published', total = '7', retried = '3', attempts = '7',
              maximum_attempts = '1', oldest_age_ms = '9000' },
            { state = 'dead', total = '1', retried = '1', attempts = '10',
              maximum_attempts = '10', oldest_age_ms = '8000' }
          }, nil
        end
        pageCalls = pageCalls + 1
        assert(not sql:find('\`payload_json\`', 1, true)
          and not sql:find('\`headers_json\`', 1, true)
          and not sql:find('\`aggregate_id\`', 1, true)
          and not sql:find('\`locked_by\`', 1, true))
        if pageCalls == 1 then
          assert(#parameters == 1 and parameters[1] == 3)
        else
          assert(#parameters == 2 and parameters[1] == '8' and parameters[2] == 3)
        end
        return {
          { cursor_id = pageCalls == 1 and '9' or '7', event_id = 'event-a',
            producer_resource = 'synex_fixture', aggregate_type = 'fixture',
            event_type = 'fixture.changed', schema_version = 1, state = 'pending',
            attempts = 2, last_error_code = 'RETRYABLE', available_at = 'available',
            created_at = 'created', age_ms = '5000' },
          { cursor_id = pageCalls == 1 and '8' or '6', event_id = 'event-b',
            producer_resource = 'synex_fixture', aggregate_type = 'fixture',
            event_type = 'fixture.changed', schema_version = 1, state = 'published',
            attempts = 1, published_at = 'published', created_at = 'created', age_ms = '4000' },
          { cursor_id = pageCalls == 1 and '7' or '5', event_id = 'event-c',
            producer_resource = 'synex_fixture', aggregate_type = 'fixture',
            event_type = 'fixture.changed', schema_version = 1, state = 'dead',
            attempts = 10, last_error_code = 'TERMINAL', created_at = 'created', age_ms = '8000' }
        }, nil
      end
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', features = { durableEvents = true }
      })
      local first = assert(reliability.outbox:snapshot({ limit = 2 }))
      assert(first.status == 'AVAILABLE' and first.health == 'ERROR')
      assert(first.total == 11 and first.backlog == 4 and first.retried == 6)
      assert(first.oldestBacklogAgeMs == 8000 and first.nextCursor == '8')
      assert(first.hasMore == true and #first.items == 2)
      assert(first.items[1].payload == nil and first.items[1].headers == nil
        and first.items[1].aggregateId == nil and first.payloadsExposed == false
        and first.headersExposed == false)
      local second = assert(reliability.outbox:snapshot({ cursor = first.nextCursor, limit = 2 }))
      assert(second.items[1].cursor == '7' and second.nextCursor == '6')
      return table.concat({ first.total, first.backlog, first.nextCursor, second.nextCursor }, ':')
    `);
    assert.equal(result, '11:4:8:6');
  } finally {
    engine.global.close();
  }
});
