import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('database driver messages never enter structured logs', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/persistence.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local now, records = 1000, {}
      local secret = 'license:private-identifier-value'
      local driverError = {
        code = 'ER_DUP_ENTRY', errno = 1062, sqlState = '23000',
        message = "Duplicate entry '" .. secret .. "' for key 'uq_identifier'"
      }
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function(record)
          records[#records + 1] = record
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        config = { deadlockRetries = 0 },
        instanceId = 'redaction-test',
        db = {
          query = function() return nil, driverError end,
          scalar = function() return nil, driverError end,
          insert = function() return nil, driverError end,
          update = function() return nil, driverError end,
          transaction = function() return nil, driverError end,
          startTransaction = function() return nil, driverError end
        }
      }).database

      local _, queryError = database:query('SELECT value FROM fixture WHERE identifier = ?', { secret })
      local _, batchError = database:transaction({ { query = 'UPDATE fixture SET value = ?', values = { secret } } })
      local _, interactiveError = database:withTransaction(function() return true end)
      assert(queryError.code == 'DATABASE_ERROR')
      assert(batchError.code == 'TRANSACTION_REJECTED')
      assert(interactiveError.code == 'TRANSACTION_REJECTED')
      assert(#records == 3)
      for _, record in ipairs(records) do
        local fields = record.fields
        assert(fields.error == nil and fields.message == nil)
        assert(fields.databaseCode == 'UNIQUE_VIOLATION')
        assert(fields.errno == 1062 and fields.sqlState == '23000')
        for _, value in pairs(fields) do
          assert(type(value) ~= 'string' or not value:find(secret, 1, true))
        end
      end
      return table.concat({records[1].fields.failureType,
        records[2].fields.failureType, records[3].fields.failureType}, ':')
    `);
    assert.equal(result, 'adapter_error:rejected:rejected');
  } finally {
    engine.global.close();
  }
});
