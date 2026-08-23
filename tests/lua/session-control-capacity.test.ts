import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function runtimeEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/runtime_persistence_instances.lua',
    'core/synex_core/server/runtime_persistence_control.lua',
    'core/synex_core/server/runtime_persistence_control_retention.lua',
    'core/synex_core/server/runtime_persistence_rbac.lua',
    'core/synex_core/server/runtime_persistence.lua',
  ]) await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  return engine;
}

test('session-control quotas replay valid pending rows and atomically reject stale replacement at cap', async () => {
  const engine = await runtimeEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 17 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('session-control-capacity')
      local state, failureStage, bootId

      local function clone(value)
        if type(value) ~= 'table' then return value end
        local copy = {}
        for key, child in pairs(value) do copy[key] = clone(child) end
        return copy
      end

      local function reset(globalCount, globalLimit, requesterLimit)
        state = {
          global = { entry_count = globalCount, global_limit = globalLimit,
            requester_limit = requesterLimit },
          counters = {}, requests = {}, authorities = {}
        }
        failureStage = nil
      end

      local database = {}
      function database:transaction(statements)
        bootId = statements[2].values[2]
        return true, nil
      end
      function database:query()
        return {{ id = 'remote-session', server_instance_id = 'instance-b' }}, nil
      end
      function database:update(sql, parameters)
        if sql:find('request_id', 1, true) and sql:find(' IN (', 1, true) then
          local changed = 0
          for index = 3, #parameters do
            local row = state.requests[parameters[index]]
            if row and row.requested_by_instance_id == 'instance-a'
              and row.state == 'pending' then
              row.state, row.completed_at = 'expired', true
              changed = changed + 1
            end
          end
          return changed, nil
        end
        error('unexpected non-transactional update')
      end
      function database:withTransaction(handler)
        local before = clone(state)
        local accepted = handler(function(sql, parameters)
          if sql:find('SELECT \`requester\`.\`instance_id\`', 1, true) then
            return {{ instance_id = 'instance-a' }}
          end
          if sql:find('synex_cluster_leases', 1, true) then
            return {{ owner_id = 'instance-a:admission', fencing_token = 7, valid = 1 }}
          end
          if sql:find('idx_sessions_user_open', 1, true) then
            return {{ id = 'remote-session', server_instance_id = 'instance-b' }}
          end
          if sql:find('FROM \`synex_sessions\`', 1, true)
            and sql:find('closed_at', 1, true) and sql:find('FOR UPDATE', 1, true) then
            return {{ id = 'remote-session', server_instance_id = 'instance-b' }}
          end
          if sql:find('EXISTS (', 1, true)
            and sql:find('synex_session_control_requests', 1, true) then
            for _, row in pairs(state.requests) do
              if row.target_session_id == 'remote-session' and row.state == 'pending' then
                return {{ request_id = row.request_id,
                  requested_by_instance_id = row.requested_by_instance_id,
                  target_instance_id = row.target_instance_id,
                  request_unexpired = row.unexpired and 1 or 0,
                  requester_valid = row.requester_valid and 1 or 0 }}
              end
            end
            return {}
          end
          if sql:find('FROM \`synex_session_control_capacity\`', 1, true) then
            return { clone(state.global) }
          end
          if sql:find('INSERT IGNORE INTO', 1, true)
            and sql:find('synex_session_control_requester_capacity', 1, true) then
            local requester = parameters[1]
            if state.counters[requester] ~= nil then return { affectedRows = 0 } end
            state.counters[requester] = 0
            return { affectedRows = 1 }
          end
          if sql:find('FROM \`synex_session_control_requester_capacity\`', 1, true) then
            local rows = {}
            for _, requester in ipairs(parameters) do
              if state.counters[requester] ~= nil then
                rows[#rows + 1] = { requested_by_instance_id = requester,
                  entry_count = state.counters[requester] }
              end
            end
            table.sort(rows, function(left, right)
              return left.requested_by_instance_id < right.requested_by_instance_id
            end)
            return rows
          end
          if sql:find('FORCE INDEX (\`idx_session_control_requester_pending\`)', 1, true) then
            for _, row in pairs(state.requests) do
              if row.requested_by_instance_id == parameters[1] then
                return {{ request_id = row.request_id }}
              end
            end
            return {}
          end
          if sql:find("SET \`state\` = 'expired'", 1, true) then
            local row = state.requests[parameters[1]]
            if not row or row.state ~= 'pending'
              or row.requested_by_instance_id ~= parameters[3] then
              return { affectedRows = 0 }
            end
            row.state, row.completed_at = 'expired', true
            return { affectedRows = 1 }
          end
          if sql:find('DELETE FROM', 1, true)
            and sql:find('synex_session_control_requester_capacity', 1, true) then
            local requester = parameters[1]
            if state.counters[requester] == 0 then
              state.counters[requester] = nil
              return { affectedRows = 1 }
            end
            return { affectedRows = 0 }
          end
          if sql:find('UPDATE \`synex_session_control_capacity\`', 1, true) then
            if state.global.entry_count ~= parameters[1]
              or state.global.entry_count >= state.global.global_limit then
              return { affectedRows = 0 }
            end
            state.global.entry_count = state.global.entry_count + 1
            return { affectedRows = 1 }
          end
          if sql:find('synex_session_control_requester_capacity', 1, true)
            and sql:find('SET \`entry_count\` = \`entry_count\` + 1', 1, true) then
            local requester, expected, limit = parameters[1], parameters[2], parameters[3]
            if state.counters[requester] ~= expected or expected >= limit then
              return { affectedRows = 0 }
            end
            state.counters[requester] = expected + 1
            return { affectedRows = 1 }
          end
          if sql:find('INSERT INTO \`synex_session_control_requests\`', 1, true) then
            if failureStage == 'request' then return { affectedRows = 0 } end
            local requestId = parameters[1]
            state.requests[requestId] = {
              request_id = requestId, target_session_id = parameters[2],
              target_instance_id = parameters[3], requested_by_instance_id = parameters[4],
              state = 'pending', unexpired = true, requester_valid = true
            }
            return { affectedRows = 1 }
          end
          if sql:find('INSERT INTO', 1, true)
            and sql:find('synex_session_control_authority', 1, true) then
            if failureStage == 'authority' then return { affectedRows = 0 } end
            state.authorities[parameters[1]] = parameters[2]
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_session_control_requests\`', 1, true) then
            local row = state.requests[parameters[3]]
            if not row or row.requested_by_instance_id ~= parameters[5]
              or row.state ~= 'pending' then return { affectedRows = 0 } end
            row.target_instance_id, row.unexpired = parameters[1], true
            return { affectedRows = 1 }
          end
          error('unexpected transactional SQL: ' .. sql)
        end)
        if accepted == true then return true, nil end
        state = before
        return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end

      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', sessionControlRetentionDays = 30
      }).instances
      assert(instances:register('Instance A'))
      local gate = { name = 'admission:user-a', owner = 'instance-a:admission',
        fencingToken = 7, requesterInstanceId = 'instance-a', requesterBootId = bootId }

      reset(1, 1, 1)
      state.counters['instance-b'] = 1
      state.requests.foreign = { request_id = 'foreign', target_session_id = 'remote-session',
        target_instance_id = 'instance-b', requested_by_instance_id = 'instance-b',
        state = 'pending', unexpired = true, requester_valid = true }
      state.authorities.foreign = 'boot-b'
      assert(instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate) == 1)
      assert(state.global.entry_count == 1 and state.requests.foreign.state == 'pending'
        and state.counters['instance-a'] == nil and state.authorities.foreign == 'boot-b')

      reset(1, 1, 1)
      state.counters['instance-a'] = 1
      state.requests.owned = { request_id = 'owned', target_session_id = 'remote-session',
        target_instance_id = 'instance-b', requested_by_instance_id = 'instance-a',
        state = 'pending', unexpired = true, requester_valid = false }
      state.authorities.owned = 'old-boot'
      assert(instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate) == 1)
      assert(state.global.entry_count == 1 and state.authorities.owned == bootId)

      reset(1, 1, 1)
      state.counters['instance-b'] = 1
      state.requests.stale = { request_id = 'stale', target_session_id = 'remote-session',
        target_instance_id = 'instance-b', requested_by_instance_id = 'instance-b',
        state = 'pending', unexpired = false, requester_valid = true }
      state.authorities.stale = 'boot-b'
      local denied, deniedError = instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate)
      assert(denied == nil and deniedError.code == 'SESSION_CONTROL_CAPACITY_EXCEEDED'
        and deniedError.details.scope == 'global')
      assert(state.requests.stale.state == 'expired' and state.global.entry_count == 1
        and state.counters['instance-a'] == nil)

      reset(1, 2, 1)
      state.counters['instance-a'] = 1
      state.requests.retained = { request_id = 'retained', target_session_id = 'closed-session',
        target_instance_id = 'instance-b', requested_by_instance_id = 'instance-a',
        state = 'completed', unexpired = false, requester_valid = false }
      local requesterDenied, requesterDeniedError = instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate)
      assert(requesterDenied == nil
        and requesterDeniedError.code == 'SESSION_CONTROL_CAPACITY_EXCEEDED'
        and requesterDeniedError.details.scope == 'requester'
        and state.global.entry_count == 1 and state.counters['instance-a'] == 1)

      reset(1, 2, 2)
      state.requests.drift = { request_id = 'drift', target_session_id = 'remote-session',
        target_instance_id = 'instance-b', requested_by_instance_id = 'instance-b',
        state = 'pending', unexpired = true, requester_valid = true }
      local drifted, driftError = instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate)
      assert(drifted == nil and driftError.code == 'SESSION_CONTROL_CAPACITY_INVALID'
        and state.requests.drift.state == 'pending')

      reset(4294967296, 4294967295, 100)
      local overflowed, overflowError = instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate)
      assert(overflowed == nil and overflowError.code == 'SESSION_CONTROL_CAPACITY_INVALID'
        and state.global.entry_count == 4294967296)

      reset(0, 2, 2)
      assert(instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate) == 1)
      assert(state.global.entry_count == 1 and state.counters['instance-a'] == 1)
      local created = nil
      for requestId, row in pairs(state.requests) do
        if row.requested_by_instance_id == 'instance-a' then created = requestId end
      end
      assert(created and state.authorities[created] == bootId)

      reset(0, 2, 2)
      failureStage = 'authority'
      local failed, failure = instances:requestRemoteKicks(
        'user-a', 45, function() return true end, gate)
      assert(failed == nil and failure.code == 'SESSION_CONTROL_CAPACITY_INVALID')
      assert(state.global.entry_count == 0 and next(state.counters) == nil
        and next(state.requests) == nil and next(state.authorities) == nil)

      return table.concat({ deniedError.code, deniedError.details.scope,
        requesterDeniedError.details.scope, driftError.code, overflowError.code,
        failure.code, tostring(state.global.entry_count) }, ':')
    `);
    assert.equal(result, [
      'SESSION_CONTROL_CAPACITY_EXCEEDED', 'global', 'requester',
      'SESSION_CONTROL_CAPACITY_INVALID', 'SESSION_CONTROL_CAPACITY_INVALID',
      'SESSION_CONTROL_CAPACITY_INVALID', '0',
    ].join(':'));
  } finally {
    engine.global.close();
  }
});

test('terminal session-control compaction is fair, bounded, and rolls back exact child anomalies', async () => {
  const engine = await runtimeEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 19 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local state = {
        global = { entry_count = 3, global_limit = 100, requester_limit = 50 },
        counter = 3,
        requests = {
          completed = { request_id = 'completed', requested_by_instance_id = 'instance-a',
            state = 'completed', authority = true },
          expired = { request_id = 'expired', requested_by_instance_id = 'instance-a',
            state = 'expired', authority = false },
          pending = { request_id = 'pending', requested_by_instance_id = 'instance-a',
            state = 'pending', authority = true }
        }
      }
      local failChild = true
      local function clone(value)
        if type(value) ~= 'table' then return value end
        local copy = {}
        for key, child in pairs(value) do copy[key] = clone(child) end
        return copy
      end
      local database = { transaction = function() return true, nil end }
      function database:withTransaction(handler)
        local before = clone(state)
        local accepted = handler(function(sql, parameters)
          if sql:find('idx_session_control_terminal_retention', 1, true) then
            local row = state.requests[parameters[1]]
            if not row then return {} end
            return {{ request_id = row.request_id,
              requested_by_instance_id = row.requested_by_instance_id,
              authority_request_id = row.authority and row.request_id or nil }}
          end
          if sql:find('FROM \`synex_session_control_capacity\`', 1, true) then
            return { clone(state.global) }
          end
          if sql:find('FROM \`synex_session_control_requester_capacity\`', 1, true) then
            return {{ requested_by_instance_id = 'instance-a', entry_count = state.counter }}
          end
          if sql:find('DELETE \`authority\`', 1, true) then
            local row = state.requests[parameters[1]]
            if failChild then return { affectedRows = 0 } end
            local changed = row and row.authority and 1 or 0
            if row then row.authority = false end
            return { affectedRows = changed }
          end
          if sql:find('DELETE FROM \`synex_session_control_requests\`', 1, true) then
            local row = state.requests[parameters[1]]
            if not row or row.state ~= parameters[2] then return { affectedRows = 0 } end
            state.requests[parameters[1]] = nil
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_session_control_capacity\`', 1, true) then
            state.global.entry_count = state.global.entry_count - parameters[1]
            return { affectedRows = 1 }
          end
          if sql:find('synex_session_control_requester_capacity', 1, true)
            and sql:find('SET \`entry_count\` = \`entry_count\` - ?', 1, true) then
            state.counter = state.counter - parameters[1]
            return { affectedRows = 1 }
          end
          error('unexpected compaction SQL: ' .. sql)
        end)
        if accepted == true then return true, nil end
        state = before
        return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', sessionControlRetentionDays = 30
      }).instances

      local failed, failure = instances:compactTerminalControls(1)
      assert(failed == nil and failure.code == 'SESSION_CONTROL_COMPACTION_INVALID')
      assert(state.requests.completed and state.requests.completed.authority
        and state.global.entry_count == 3 and state.counter == 3)
      failChild = false
      local completed = assert(instances:compactTerminalControls(1))
      local expired = assert(instances:compactTerminalControls(1))
      assert(completed.state == 'completed' and completed.requestsDeleted == 1
        and completed.authorityDeleted == 1 and completed.legacyWithoutAuthority == 0)
      assert(expired.state == 'expired' and expired.requestsDeleted == 1
        and expired.authorityDeleted == 0 and expired.legacyWithoutAuthority == 1)
      assert(state.requests.pending and state.requests.pending.state == 'pending'
        and state.global.entry_count == 1 and state.counter == 1)
      return table.concat({ completed.state, expired.state,
        completed.requestsDeleted, expired.legacyWithoutAuthority,
        state.global.entry_count }, ':')
    `);
    assert.equal(result, 'completed:expired:1:1:1');
  } finally {
    engine.global.close();
  }
});
