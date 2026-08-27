import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const persistencePath = path.join(root, 'core/synex_core/server/persistence.lua');

async function persistenceEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/persistence.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('Core records every classified deadlock separately from retries performed', async () => {
  const engine = await persistenceEngine();
  try {
    const result = await engine.doString(`
      local clock, batchCalls, interactiveCalls = 1000, 0, 0
      local deadlock = {
        code = 'ER_LOCK_DEADLOCK', errno = 1213, sqlState = '40001',
        message = 'fixture deadlock'
      }
      local platform = {
        nowGame = function() clock = clock + 1 return clock end,
        random = function() return 1 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local adapter = {
        query = function() return nil, deadlock end,
        scalar = function() return nil, deadlock end,
        insert = function() return nil, deadlock end,
        update = function() return nil, deadlock end,
        transaction = function()
          batchCalls = batchCalls + 1
          return nil, deadlock
        end,
        startTransaction = function()
          interactiveCalls = interactiveCalls + 1
          if interactiveCalls == 1 then return nil, deadlock end
          return true, nil
        end
      }
      local database = SynexCoreFactories.persistence({
        platform = platform, foundation = foundation, db = adapter,
        instanceId = 'deadlock-metrics-test',
        config = { deadlockRetries = 1, queryWarnMs = 1000 }
      }).database

      for _, operation in ipairs({ 'query', 'scalar', 'insert', 'update' }) do
        local value, operationError = database[operation](database,
          'SELECT value FROM fixture', {})
        assert(value == nil and operationError.code == 'DATABASE_ERROR'
          and operationError.retryable == true)
      end
      local batch, batchError = database:transaction({{
        query = 'UPDATE fixture SET value = ?', values = { 1 }
      }})
      assert(batch == nil and batchError.code == 'TRANSACTION_REJECTED'
        and batchError.retryable == true and batchCalls == 2)
      local interactive, interactiveError = database:withTransaction(function()
        return true
      end)
      assert(interactive == true and interactiveError == nil
        and interactiveCalls == 2)

      local values = foundation.metrics:snapshot().values
      local function metric(name, kind)
        return values[name .. ':4:kind=string:' .. tostring(#kind) .. ':' .. kind]
      end
      assert(metric('synex_db_deadlocks_total', 'query') == 1)
      assert(metric('synex_db_deadlocks_total', 'scalar') == 1)
      assert(metric('synex_db_deadlocks_total', 'insert') == 1)
      assert(metric('synex_db_deadlocks_total', 'update') == 1)
      assert(metric('synex_db_deadlocks_total', 'batch') == 2)
      assert(metric('synex_db_deadlocks_total', 'interactive') == 1)
      assert(metric('synex_db_deadlock_retries_total', 'batch') == 1)
      assert(metric('synex_db_deadlock_retries_total', 'interactive') == 1)
      assert(metric('synex_db_deadlock_retries_total', 'query') == nil)
      return 'deadlocks-observed-retries-distinct'
    `);
    assert.equal(result, 'deadlocks-observed-retries-distinct');
  } finally {
    engine.global.close();
  }
});

test('Core deadlock occurrence counters saturate before publishing their gauge', async () => {
  const persistence = await readFile(persistencePath, 'utf8');
  assert.match(persistence,
    /local maximumDatabaseDeadlockCount = 9007199254740991/);
  assert.match(persistence,
    /if current < maximumDatabaseDeadlockCount then[\s\S]*current = current \+ 1/);
  assert.match(persistence,
    /metrics:gauge\('synex_db_deadlocks_total', \{ kind = kind \}, current\)/);
  assert.doesNotMatch(persistence,
    /metrics:increment\('synex_db_deadlocks_total'/);
});
