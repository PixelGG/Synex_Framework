import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function reliabilityEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/server/factories.lua');
  await load(engine, 'core/synex_core/server/foundation.lua');
  await load(engine, 'core/synex_core/server/reliability.lua');
  return engine;
}

test('saga candidate cursor advances past a full deferred window and rotates states at maximum one', async () => {
  const engine = await reliabilityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 9 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-worker-scalability')
      local tick = string.char(96)

      local function candidate(state, id)
        return {
          id = id, public_id = ('00000000-0000-4000-8000-%012d'):format(id),
          owner_resource = 'synex_fixture', saga_type = 'fixture.workflow',
          state = state, version = 1,
          updated_at = ('2026-08-23 00:%02d:%02d.000000'):format(
            math.floor(id / 60), id % 60),
          deadline_expired = 0, age_ms = 60000
        }
      end

      local fairCalls = {}
      local fairDatabase = {}
      function fairDatabase:query(sql, parameters)
        assert(sql:find('FORCE INDEX (' .. tick .. 'idx_sagas_state_updated' .. tick .. ')', 1, true))
        local ids = { pending = 1, running = 2, compensating = 3 }
        if sql:find('DESC', 1, true) then
          assert(#parameters == 1)
          return { candidate(parameters[1], ids[parameters[1]]) }, nil
        end
        assert(sql:find('ORDER BY ' .. tick .. 'updated_at' .. tick .. ' ASC, '
          .. tick .. 'id' .. tick .. ' ASC LIMIT ?', 1, true))
        assert(not sql:find(tick .. 'owner_resource' .. tick .. ' = ?', 1, true))
        assert(#parameters == 5 or #parameters == 8)
        assert(parameters[#parameters] == 50)
        fairCalls[#fairCalls + 1] = parameters[1] .. ':' .. tostring(#parameters)
        return { candidate(parameters[1], ids[parameters[1]]) }, nil
      end
      local fair = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = fairDatabase,
        instanceId = 'saga-fair', features = { sagas = true }
      })
      local first = assert(fair.sagas:candidates(1))
      local second = assert(fair.sagas:candidates(1))
      local third = assert(fair.sagas:candidates(1))
      local fourth = assert(fair.sagas:candidates(1))
      assert(first[1].state == 'pending' and second[1].state == 'running'
        and third[1].state == 'compensating' and fourth[1].state == 'pending')
      assert(#fairCalls == 4 and fairCalls[4] == 'pending:5')

      local pendingCalls, highWatermarkCalls, previousCursor = 0, 0, 0
      local backlogDatabase = {}
      function backlogDatabase:query(sql, parameters)
        assert(sql:find('FORCE INDEX (' .. tick .. 'idx_sagas_state_updated' .. tick .. ')', 1, true))
        if sql:find('DESC', 1, true) then
          if parameters[1] ~= 'pending' then return {}, nil end
          highWatermarkCalls = highWatermarkCalls + 1
          return { candidate('pending', highWatermarkCalls == 1 and 51 or 100) }, nil
        end
        assert(parameters[#parameters] == 50)
        if parameters[1] ~= 'pending' then return {}, nil end
        pendingCalls = pendingCalls + 1
        local cursorId, highId
        if #parameters == 5 then
          cursorId, highId = 0, parameters[4]
        else
          assert(#parameters == 8 and parameters[2] == parameters[3]
            and parameters[5] == parameters[6])
          cursorId, highId = parameters[4], parameters[7]
          assert(cursorId == previousCursor)
        end
        local rows = {}
        for id = cursorId + 1, math.min(cursorId + 50, highId) do
          rows[#rows + 1] = candidate('pending', id)
        end
        previousCursor = cursorId + 1
        return rows, nil
      end
      local backlog = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = backlogDatabase,
        instanceId = 'saga-backlog', features = { sagas = true }
      })
      local deferred, runnable
      for attempt = 1, 51 do
        local batch = assert(backlog.sagas:candidates(1))
        assert(#batch == 1)
        if attempt == 1 then deferred = batch[1] end
        if attempt == 51 then runnable = batch[1] end
      end
      assert(deferred.publicId:sub(-12) == '000000000001')
      assert(runnable.publicId:sub(-12) == '000000000051')
      local wrapped = assert(backlog.sagas:candidates(1))
      assert(wrapped[1].publicId:sub(-12) == '000000000001')
      assert(pendingCalls == 52 and highWatermarkCalls == 2)

      local budgetDatabase = {}
      function budgetDatabase:query(sql, parameters)
        local state = parameters[1]
        if sql:find('DESC', 1, true) then
          if state == 'pending' then return { candidate(state, 9) }, nil end
          if state == 'running' then return { candidate(state, 100) }, nil end
          return {}, nil
        end
        local firstId
        if state == 'pending' then firstId = 1
        elseif #parameters == 5 then firstId = 51
        else
          assert(#parameters == 8 and parameters[4] == 51)
          firstId = 52
        end
        local highId = #parameters == 5 and parameters[4] or parameters[7]
        local rows = {}
        for id = firstId, math.min(firstId + 49, highId) do
          rows[#rows + 1] = candidate(state, id)
        end
        return rows, nil
      end
      local budget = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = budgetDatabase,
        instanceId = 'saga-rest-budget', features = { sagas = true }
      })
      local partial = assert(budget.sagas:candidates(10))
      local continued = assert(budget.sagas:candidates(1))
      assert(#partial == 10 and partial[10].state == 'running'
        and partial[10].publicId:sub(-2) == '51')
      assert(continued[1].state == 'running'
        and continued[1].publicId:sub(-2) == '52')

      return table.concat({first[1].state, second[1].state, third[1].state,
        fourth[1].state, deferred.publicId:sub(-2),
        runnable.publicId:sub(-2), wrapped[1].publicId:sub(-2),
        continued[1].publicId:sub(-2)}, ':')
    `);
    assert.equal(result, 'pending:running:compensating:pending:01:51:01:52');
  } finally {
    engine.global.close();
  }
});

test('saga candidate scan post-filters selectors and rejects oversized adapter results', async () => {
  const engine = await reliabilityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 13 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-selector-window')
      local queryCalls = 0
      local database = {}
      function database:query(sql, parameters)
        if sql:find('DESC', 1, true) then
          if parameters[1] ~= 'pending' then return {}, nil end
          return {{ id = 50, state = 'pending',
            updated_at = '2026-08-23 00:00:50.000000' }}, nil
        end
        queryCalls = queryCalls + 1
        assert(#parameters <= 8 and parameters[#parameters] == 50)
        assert(not sql:find('owner_resource = ?', 1, true)
          and not sql:find('saga_type = ?', 1, true))
        if parameters[1] ~= 'pending' then return {}, nil end
        local rows = {}
        for id = 1, 50 do
          rows[id] = {
            id = id, public_id = ('00000000-0000-4000-8000-%012d'):format(id),
            owner_resource = id == 50 and 'synex_target' or 'synex_other',
            saga_type = id == 50 and 'target.workflow' or 'other.workflow',
            state = 'pending', version = 1,
            updated_at = ('2026-08-23 00:00:%02d.000000'):format(id % 60),
            deadline_expired = 0, age_ms = 1
          }
        end
        return rows, nil
      end
      local reliability = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'saga-selector', features = { sagas = true }
      })
      local selected = assert(reliability.sagas:candidates(1, {{
        ownerResource = 'synex_target', sagaType = 'target.workflow'
      }}))
      assert(#selected == 1 and selected[1].ownerResource == 'synex_target'
        and queryCalls == 1)

      local oversizedDatabase = {}
      function oversizedDatabase:query(sql, parameters)
        if sql:find('DESC', 1, true) then
          return {{ id = 51, state = parameters[1],
            updated_at = '2026-08-23 00:00:51.000000' }}, nil
        end
        local rows = {}
        for id = 1, 51 do
          rows[id] = {
            id = id, public_id = 'poison', owner_resource = 'synex_target',
            saga_type = 'target.workflow', state = parameters[1], version = 1,
            updated_at = '2026-08-23 00:00:00.000000',
            deadline_expired = 0, age_ms = 0
          }
        end
        return rows, nil
      end
      local invalid = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = oversizedDatabase,
        instanceId = 'saga-invalid', features = { sagas = true }
      })
      local value, failure = invalid.sagas:candidates(1)
      assert(value == nil and failure.code == 'DATABASE_RESULT_INVALID')
      return table.concat({selected[1].ownerResource, queryCalls, failure.code}, ':')
    `);
    assert.equal(result, 'synex_target:1:DATABASE_RESULT_INVALID');
  } finally {
    engine.global.close();
  }
});

test('terminal outbox compaction rotates exact queues and shares one strict budget', async () => {
  const engine = await reliabilityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 17 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('outbox-queue-scalability')
      local tick = string.char(96)
      local mode, calls = 'single', {}
      local database = {}
      function database:update(sql, parameters)
        local branch = sql:find('idx_outbox_compact_published', 1, true)
          and 'published' or 'dead'
        assert(sql:find('FORCE INDEX', 1, true) and not sql:find('COALESCE', 1, true))
        assert(not sql:find("'published' OR", 1, true)
          and not sql:find("'dead' OR", 1, true))
        assert(sql:find(tick .. 'payload_json' .. tick .. " = '{}'", 1, true)
          and sql:find(tick .. 'headers_json' .. tick .. " = '{}'", 1, true)
          and not sql:find(tick .. 'last_error_code' .. tick, 1, true))
        calls[#calls + 1] = branch .. ':' .. tostring(parameters[2])
        if mode == 'single' then return 1, nil end
        if branch == 'published' then return 2, nil end
        return 1, nil
      end
      local reliability = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'outbox-scalability', features = { durableEvents = true }
      })
      local first = assert(reliability.outbox:compactTerminal(1, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      }))
      local second = assert(reliability.outbox:compactTerminal(1, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      }))
      assert(first.compacted == 1 and first.published == 1 and first.dead == 0)
      assert(second.compacted == 1 and second.published == 0 and second.dead == 1)
      assert(calls[1] == 'published:1' and calls[2] == 'dead:1')

      mode = 'shared'
      local shared = assert(reliability.outbox:compactTerminal(3, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      }))
      assert(shared.compacted == 3 and shared.published == 2 and shared.dead == 1)
      assert(calls[3] == 'published:3' and calls[4] == 'dead:1')

      local invalidDatabase = { update = function(_, _, parameters)
        return parameters[2] + 1, nil
      end }
      local invalid = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = invalidDatabase,
        instanceId = 'outbox-invalid', features = { durableEvents = true }
      })
      local value, failure = invalid.outbox:compactTerminal(1, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      })
      assert(value == nil and failure.code == 'DATABASE_RESULT_INVALID')
      return table.concat({calls[1], calls[2], shared.compacted, failure.code}, ':')
    `);
    assert.equal(result, 'published:1:dead:1:3:DATABASE_RESULT_INVALID');
  } finally {
    engine.global.close();
  }
});

test('idempotency compaction excludes marked history through its exact eligibility queue', async () => {
  const engine = await reliabilityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 19 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('idempotency-queue-scalability')
      local tick = string.char(96)
      local sqlSeen, maximumSeen = nil, nil
      local database = { update = function(_, sql, parameters)
        sqlSeen, maximumSeen = sql, parameters[1]
        return 1, nil
      end }
      local reliability = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'idempotency-scalability', features = {}
      })
      local report = assert(reliability.idempotency:compactExpired(7))
      assert(report.compacted == 1 and maximumSeen == 7)
      assert(sqlSeen:find('FORCE INDEX (' .. tick
        .. 'idx_idempotency_response_compaction' .. tick .. ')', 1, true))
      assert(sqlSeen:find(tick .. 'response_compaction_at' .. tick .. ' IS NULL', 1, true)
        and sqlSeen:find('SET ' .. tick .. 'response_json' .. tick .. ' = NULL, '
          .. tick .. 'response_compaction_at' .. tick .. ' =', 1, true))
      assert(not sqlSeen:find(tick .. 'response_json' .. tick .. ' IS NOT NULL', 1, true))

      local invalidDatabase = { update = function() return 8, nil end }
      local invalid = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = invalidDatabase,
        instanceId = 'idempotency-invalid', features = {}
      })
      local value, failure = invalid.idempotency:compactExpired(7)
      assert(value == nil and failure.code == 'DATABASE_RESULT_INVALID')
      return table.concat({report.compacted, maximumSeen, failure.code}, ':')
    `);
    assert.equal(result, '1:7:DATABASE_RESULT_INVALID');
  } finally {
    engine.global.close();
  }
});

test('both saga append paths reject step 2049 before any history or state write', async () => {
  const engine = await reliabilityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 23 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-history-limit')
      local row = { id = 91, state = 'running', current_step = 2048, version = 7 }
      local stepWrites, sagaWrites = 0, 0
      local tick = string.char(96)
      local database = {}
      function database:withTransaction(handler)
        local accepted = handler(function(sql)
          if sql:find('FOR UPDATE', 1, true) then
            return {{
              id = row.id, state = row.state,
              current_step = row.current_step, version = row.version
            }}
          end
          if sql:find('INSERT INTO ' .. tick .. 'synex_saga_steps' .. tick, 1, true) then
            stepWrites = stepWrites + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. tick .. 'synex_sagas' .. tick, 1, true) then
            sagaWrites = sagaWrites + 1
            return { affectedRows = 1 }
          end
          error('unexpected saga history SQL')
        end)
        if accepted == true then return true, nil end
        return false, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end
      local sagas = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'saga-history-limit', features = { sagas = true }
      }).sagas
      local recorded, recordError = sagas:record(
        'synex_fixture', 'saga-history', 7,
        'fixture.step', 'succeeded', {})
      assert(recorded == nil and recordError.code == 'SAGA_HISTORY_LIMIT')
      local appended, appendError = sagas:appendRuntimeEvent({
        ownerResource = 'synex_fixture', publicId = 'saga-history',
        expectedVersion = 7, stepName = 'fixture.runtime', eventType = 'started',
        attempt = 1, nextState = 'running', terminal = false,
        payload = {}, context = {}, clearError = false
      })
      assert(appended == nil and appendError.code == 'SAGA_HISTORY_LIMIT')
      assert(stepWrites == 0 and sagaWrites == 0
        and row.current_step == 2048 and row.version == 7 and row.state == 'running')
      return table.concat({recordError.code, appendError.code,
        stepWrites, sagaWrites, row.current_step, row.version}, ':')
    `);
    assert.equal(result, 'SAGA_HISTORY_LIMIT:SAGA_HISTORY_LIMIT:0:0:2048:7');
  } finally {
    engine.global.close();
  }
});
