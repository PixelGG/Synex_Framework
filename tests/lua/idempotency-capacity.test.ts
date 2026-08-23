import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('persistent idempotency quotas preserve replay and roll back every partial claim', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/reliability.lua',
    ]) await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));

    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 7 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.variant == 2 then return '{"variant":2}' end
          if type(value) == 'table' and value.ok then return '{"ok":true}' end
          return '{}'
        end,
        jsonDecode = function(value)
          if value == '{"ok":true}' then return { ok = true } end
          return {}
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('idempotency-capacity')
      local state, failureStage = nil, nil

      local function clone(source)
        if type(source) ~= 'table' then return source end
        local copy = {}
        for key, value in pairs(source) do copy[key] = clone(value) end
        return copy
      end

      local function reset(globalCount, globalLimit, ownerLimit, namespaceLimit)
        state = {
          global = {
            entry_count = globalCount, global_limit = globalLimit,
            owner_limit = ownerLimit, namespace_limit = namespaceLimit
          },
          owners = {}, namespaces = {}, records = {}
        }
        failureStage = nil
      end

      local database = {}
      function database:withTransaction(handler)
        local before = clone(state)
        local accepted = handler(function(sql, parameters)
          if sql:find('FROM \`synex_idempotency_capacity\`', 1, true) then
            return { clone(state.global) }
          end
          if sql:find('INSERT IGNORE INTO \`synex_idempotency_owner_capacity\`', 1, true) then
            local owner = parameters[1]
            if state.owners[owner] then return { affectedRows = 0 } end
            state.owners[owner] = { entry_count = 0 }
            return { affectedRows = 1 }
          end
          if sql:find('FROM \`synex_idempotency_owner_capacity\`', 1, true) then
            local row = state.owners[parameters[1]]
            return row and { clone(row) } or {}
          end
          if sql:find('INSERT IGNORE INTO \`synex_idempotency_namespace_capacity\`', 1, true) then
            local namespace, owner = parameters[1], parameters[2]
            if state.namespaces[namespace] then return { affectedRows = 0 } end
            state.namespaces[namespace] = { owner_resource = owner, entry_count = 0 }
            return { affectedRows = 1 }
          end
          if sql:find('FROM \`synex_idempotency_namespace_capacity\`', 1, true) then
            local row = state.namespaces[parameters[1]]
            return row and { clone(row) } or {}
          end
          if sql:find('FROM \`synex_idempotency_keys\`', 1, true) then
            local row = state.records[parameters[1] .. '\\0' .. parameters[2]]
            return row and { clone(row) } or {}
          end
          if sql:find('UPDATE \`synex_idempotency_capacity\`', 1, true) then
            if failureStage == 'global_increment' then return { affectedRows = 0 } end
            if state.global.entry_count ~= parameters[1]
              or state.global.entry_count >= state.global.global_limit then
              return { affectedRows = 0 }
            end
            state.global.entry_count = state.global.entry_count + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_idempotency_owner_capacity\`', 1, true) then
            if failureStage == 'owner_increment' then return { affectedRows = 0 } end
            local row = state.owners[parameters[1]]
            if not row or row.entry_count ~= parameters[2] then return { affectedRows = 0 } end
            row.entry_count = row.entry_count + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_idempotency_namespace_capacity\`', 1, true) then
            if failureStage == 'namespace_increment' then return { affectedRows = 0 } end
            local row = state.namespaces[parameters[1]]
            if not row or row.owner_resource ~= parameters[2]
              or row.entry_count ~= parameters[3] then return { affectedRows = 0 } end
            row.entry_count = row.entry_count + 1
            return { affectedRows = 1 }
          end
          if sql:find('INSERT INTO \`synex_idempotency_keys\`', 1, true) then
            local identity = parameters[1] .. '\\0' .. parameters[2]
            if state.records[identity] then return { affectedRows = 0 } end
            state.records[identity] = {
              request_hash = parameters[3], state = 'pending', response_json = nil,
              owner_token = parameters[4], lock_expired = 0, record_expired = 0
            }
            if failureStage == 'insert' then return { affectedRows = 0 } end
            return { affectedRows = 1 }
          end
          error('unexpected transactional query: ' .. sql)
        end)
        if accepted == true then return true, nil end
        state = before
        return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end
      function database:update(sql, parameters)
        if sql:find("SET \`state\` = 'failed'", 1, true) then
          local row = state.records[parameters[1] .. '\\0' .. parameters[2]]
          if row and row.owner_token == parameters[3] and row.state == 'pending' then
            row.state = 'failed'
            return 1, nil
          end
          return 0, nil
        end
        if sql:find("SET \`state\` = 'completed'", 1, true) then
          local row = state.records[parameters[2] .. '\\0' .. parameters[3]]
          if row and row.owner_token == parameters[4] and row.state == 'pending' then
            row.state, row.response_json = 'completed', parameters[1]
            return 1, nil
          end
          return 0, nil
        end
        error('unexpected update: ' .. sql)
      end
      local reliability = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        sha256 = function(value)
          return value:find('variant', 1, true) and string.rep('b', 64)
            or string.rep('a', 64)
        end,
        instanceId = 'idempotency-capacity', features = {}
      })
      local owner, operation = 'synex_fixture', 'fixture.write'
      local namespace = owner .. ':' .. operation
      local key = '11111111-1111-4111-8111-111111111111'
      local effects = 0

      reset(0, 1, 1, 1)
      local first = assert(reliability.idempotency:run(owner, operation, key, {}, function()
        effects = effects + 1
        return { ok = true }
      end))
      assert(first.ok and effects == 1 and state.global.entry_count == 1
        and state.owners[owner].entry_count == 1
        and state.namespaces[namespace].entry_count == 1)
      local replay, replayError, replayMeta = reliability.idempotency:run(
        owner, operation, key, {}, function() effects = effects + 100 end)
      assert(replay.ok and replayError == nil and replayMeta.replayed == true and effects == 1)
      local conflict, conflictError = reliability.idempotency:run(
        owner, operation, key, { variant = 2 }, function() effects = effects + 100 end)
      assert(conflict == nil and conflictError.code == 'IDEMPOTENCY_CONFLICT' and effects == 1)
      local denied, deniedError = reliability.idempotency:run(
        owner, operation, '22222222-2222-4222-8222-222222222222', {},
        function() effects = effects + 100 end)
      assert(denied == nil and deniedError.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED'
        and deniedError.details.scope == 'global' and effects == 1)

      reset(1, 10, 1, 1)
      state.owners[owner] = { entry_count = 1 }
      state.namespaces[namespace] = { owner_resource = owner, entry_count = 1 }
      local _, ownerDenied = reliability.idempotency:run(
        owner, operation, key, {}, function() effects = effects + 100 end)
      assert(ownerDenied.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED'
        and ownerDenied.details.scope == 'owner')

      reset(1, 10, 10, 1)
      state.owners[owner] = { entry_count = 1 }
      state.namespaces[namespace] = { owner_resource = owner, entry_count = 1 }
      local _, namespaceDenied = reliability.idempotency:run(
        owner, operation, key, {}, function() effects = effects + 100 end)
      assert(namespaceDenied.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED'
        and namespaceDenied.details.scope == 'namespace')

      for _, stage in ipairs({ 'owner_increment', 'namespace_increment', 'insert' }) do
        reset(0, 10, 10, 10)
        failureStage = stage
        local _, rollbackError = reliability.idempotency:run(
          owner, operation, key, {}, function() effects = effects + 100 end)
        assert(rollbackError.code == 'IDEMPOTENCY_CAPACITY_INVALID'
          and state.global.entry_count == 0 and next(state.owners) == nil
          and next(state.namespaces) == nil and next(state.records) == nil)
      end

      reset(1, 1, 1, 1)
      state.records[namespace .. '\\0' .. key] = {
        request_hash = string.rep('a', 64), state = 'completed', response_json = '{"ok":true}',
        owner_token = 'existing', lock_expired = 0, record_expired = 0
      }
      local drifted, driftError = reliability.idempotency:run(
        owner, operation, key, {}, function() effects = effects + 100 end)
      assert(drifted == nil and driftError.code == 'IDEMPOTENCY_CAPACITY_INVALID'
        and next(state.owners) == nil and next(state.namespaces) == nil)

      return table.concat({ effects, tostring(replayMeta.replayed), conflictError.code,
        deniedError.details.scope, ownerDenied.details.scope,
        namespaceDenied.details.scope, driftError.code }, ':')
    `);
    assert.equal(
      result,
      '1:true:IDEMPOTENCY_CONFLICT:global:owner:namespace:IDEMPOTENCY_CAPACITY_INVALID',
    );
  } finally {
    engine.global.close();
  }
});
