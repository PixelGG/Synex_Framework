import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('generic idempotency never reclaims an expired or indeterminate execution', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/reliability.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local now, records, effects = 1000, {}, 0
      local globalCount, ownerCounts, namespaceCounts = 0, {}, {}
      local lockExpired, recordExpired, failCompletion = false, false, false
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.unencodable then error('fixture encoding failure') end
          if type(value) == 'table' and value.ok then return '{"ok":true}' end
          return '{}'
        end,
        jsonDecode = function(value)
          if value == '{"ok":true}' then return { ok = true } end
          return {}
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('idempotency-hardening')
      local database = {}
      function database:update(sql, parameters)
        local namespace, key
        if sql:find('INSERT INTO \`synex_idempotency_keys\`', 1, true) then
          namespace, key = parameters[1], parameters[2]
          local identity = namespace .. ':' .. key
          if records[identity] then return 0, nil end
          records[identity] = {
            request_hash = parameters[3], state = 'pending', response_json = nil,
            owner_token = parameters[4]
          }
          return 1, nil
        end
        if sql:find("SET \`state\` = 'failed'", 1, true) then
          namespace, key = parameters[1], parameters[2]
          local record = records[namespace .. ':' .. key]
          if record and record.owner_token == parameters[3] and record.state == 'pending' then
            record.state = 'failed'
            return 1, nil
          end
          return 0, nil
        end
        if sql:find("SET \`state\` = 'completed'", 1, true) then
          if failCompletion then
            return nil, foundation.error('DATABASE_ERROR', 'fixture completion uncertainty')
          end
          namespace, key = parameters[2], parameters[3]
          local record = records[namespace .. ':' .. key]
          if record and record.owner_token == parameters[4] and record.state == 'pending' then
            record.state = 'completed'
            record.response_json = parameters[1]
            return 1, nil
          end
          return 0, nil
        end
        error('unexpected idempotency update')
      end
      function database:query(_, parameters)
        local record = records[parameters[1] .. ':' .. parameters[2]]
        if not record then return {}, nil end
        return { {
          request_hash = record.request_hash,
          state = record.state,
          response_json = record.response_json,
          lock_expired = lockExpired and 1 or 0,
          record_expired = recordExpired and 1 or 0
        } }, nil
      end
      function database:withTransaction(handler)
        local accepted = handler(function(sql, parameters)
          if sql:find('FROM \`synex_idempotency_capacity\`', 1, true) then
            return {{ entry_count = globalCount, global_limit = 100,
              owner_limit = 100, namespace_limit = 100 }}
          end
          if sql:find('INSERT IGNORE INTO \`synex_idempotency_owner_capacity\`', 1, true) then
            if ownerCounts[parameters[1]] ~= nil then return { affectedRows = 0 } end
            ownerCounts[parameters[1]] = 0
            return { affectedRows = 1 }
          end
          if sql:find('FROM \`synex_idempotency_owner_capacity\`', 1, true) then
            local count = ownerCounts[parameters[1]]
            return count ~= nil and {{ entry_count = count }} or {}
          end
          if sql:find('INSERT IGNORE INTO \`synex_idempotency_namespace_capacity\`', 1, true) then
            if namespaceCounts[parameters[1]] then return { affectedRows = 0 } end
            namespaceCounts[parameters[1]] = { owner_resource = parameters[2], entry_count = 0 }
            return { affectedRows = 1 }
          end
          if sql:find('FROM \`synex_idempotency_namespace_capacity\`', 1, true) then
            local row = namespaceCounts[parameters[1]]
            return row and {{ owner_resource = row.owner_resource, entry_count = row.entry_count }} or {}
          end
          if sql:find('FROM \`synex_idempotency_keys\`', 1, true) then
            local rows = database:query(sql, parameters)
            return rows
          end
          if sql:find('UPDATE \`synex_idempotency_capacity\`', 1, true) then
            globalCount = globalCount + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_idempotency_owner_capacity\`', 1, true) then
            ownerCounts[parameters[1]] = ownerCounts[parameters[1]] + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_idempotency_namespace_capacity\`', 1, true) then
            namespaceCounts[parameters[1]].entry_count = namespaceCounts[parameters[1]].entry_count + 1
            return { affectedRows = 1 }
          end
          if sql:find('INSERT INTO \`synex_idempotency_keys\`', 1, true) then
            local inserted = database:update(sql, parameters)
            return { affectedRows = inserted }
          end
          error('unexpected idempotency transaction query')
        end)
        return accepted == true and true or nil
      end
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation,
        database = database,
        platform = platform,
        instanceId = 'idempotency-hardening',
        sha256 = function() return string.rep('a', 64) end,
        features = { durableEvents = false, sagas = false }
      })

      local nestedError = nil
      local first = assert(reliability.idempotency:run(
        'synex_fixture', 'slow', '11111111-1111-4111-8111-111111111111', {}, function()
          effects = effects + 1
          lockExpired = true
          local _, err = reliability.idempotency:run(
            'synex_fixture', 'slow', '11111111-1111-4111-8111-111111111111', {}, function()
              effects = effects + 100
              return { ok = true }
            end)
          nestedError = err
          return { ok = true }
        end))
      assert(first.ok and effects == 1 and nestedError.code == 'IDEMPOTENCY_INDETERMINATE')
      local replay, _, replayMeta = reliability.idempotency:run(
        'synex_fixture', 'slow', '11111111-1111-4111-8111-111111111111', {}, function()
          effects = effects + 100
        end)
      assert(replay.ok and replayMeta.replayed == true and effects == 1)

      lockExpired = false
      local _, encodingError = reliability.idempotency:run(
        'synex_fixture', 'encode', '22222222-2222-4222-8222-222222222222', {}, function()
          effects = effects + 1
          return { unencodable = true }
        end)
      assert(encodingError.code == 'IDEMPOTENCY_INDETERMINATE' and effects == 2)
      local _, failedReplay = reliability.idempotency:run(
        'synex_fixture', 'encode', '22222222-2222-4222-8222-222222222222', {}, function()
          effects = effects + 100
        end)
      assert(failedReplay.code == 'IDEMPOTENCY_FAILED' and effects == 2)

      failCompletion, lockExpired = true, false
      local _, completionError = reliability.idempotency:run(
        'synex_fixture', 'completion', '33333333-3333-4333-8333-333333333333', {}, function()
          effects = effects + 1
          return { ok = true }
        end)
      assert(completionError.code == 'IDEMPOTENCY_INDETERMINATE' and effects == 3)
      failCompletion, lockExpired, recordExpired = false, true, true
      local _, uncertainReplay = reliability.idempotency:run(
        'synex_fixture', 'completion', '33333333-3333-4333-8333-333333333333', {}, function()
          effects = effects + 100
        end)
      assert(uncertainReplay.code == 'IDEMPOTENCY_INDETERMINATE' and effects == 3)
      return table.concat({nestedError.code, encodingError.code,
        failedReplay.code, completionError.code, uncertainReplay.code, effects}, ':')
    `);
    assert.equal(result,
      'IDEMPOTENCY_INDETERMINATE:IDEMPOTENCY_INDETERMINATE:IDEMPOTENCY_FAILED:'
      + 'IDEMPOTENCY_INDETERMINATE:IDEMPOTENCY_INDETERMINATE:3');
  } finally {
    engine.global.close();
  }
});
