import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

test('core audit retention skips retain-forever and archives bounded UTC batches without source deletion', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'core/synex_core/server/factories.lua');
    await load(engine, 'core/synex_core/server/foundation.lua');
    await load(engine, 'core/synex_core/server/retention.lua');
    const result = await engine.doString(`
      local platform = {
        print = function() end, nowGame = function() return 1000 end,
        jsonEncode = function() return '{}' end, jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local touched = false
      local retained = SynexCoreFactories.retention({
        foundation = foundation,
        database = { update = function() touched = true return 0, nil end },
        config = {
          batchSize = 250,
          audit = { mode = 'retain_forever', archiveAfterDays = 365 }
        }
      })
      local skipped = assert(retained.audit:archiveBatch())
      assert(skipped.skipped and skipped.archived == 0 and skipped.sourceRowsDeleted == 0)
      assert(touched == false)

      local calls = {}
      local archiving = SynexCoreFactories.retention({
        foundation = foundation,
        database = { withTransaction = function(_, handler)
          local committed = handler(function(sql, parameters)
            calls[#calls + 1] = { sql = sql, parameters = parameters }
            if sql:find('SELECT CAST', 1, true) then
              local rows = {}
              for index = 1, 17 do rows[index] = { source_audit_id = tostring(index) } end
              return rows
            end
            return { affectedRows = 17 }
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end },
        config = {
          batchSize = 25,
          audit = { mode = 'archive', archiveAfterDays = 90 }
        }
      })
      local report = assert(archiving.audit:archiveBatch())
      assert(report.archived == 17 and report.sourceRowsDeleted == 0 and report.batchExhausted == false)
      assert(#calls == 3 and calls[1].parameters[1] == 90 and calls[1].parameters[2] == 25)
      assert(calls[1].sql:find('archive_recorded_at', 1, true)
        and calls[1].sql:find('FOR UPDATE', 1, true)
        and calls[1].sql:find('ORDER BY', 1, true)
        and calls[1].sql:find('LIMIT ?', 1, true))
      assert(calls[2].sql:find('INSERT IGNORE INTO', 1, true)
        and calls[2].sql:find('synex_audit_archive', 1, true)
        and calls[2].sql:find('UTC_TIMESTAMP(6)', 1, true))
      assert(calls[3].sql:find('UPDATE', 1, true)
        and calls[3].sql:find('archive_recorded_at', 1, true)
        and calls[3].sql:find('event_id', 1, true)
        and calls[3].sql:find('occurred_at', 1, true))
      assert(#calls[2].parameters == 17 and #calls[3].parameters == 17)
      for _, call in ipairs(calls) do assert(call.sql:find('DELETE', 1, true) == nil) end
      return table.concat({skipped.mode, report.scope, report.archived}, ':')
    `);
    assert.equal(result, 'retain_forever:audit:17');
  } finally {
    engine.global.close();
  }
});

test('core audit retention rolls back unless every locked source row has a matching archive checkpoint', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'core/synex_core/server/factories.lua');
    await load(engine, 'core/synex_core/server/foundation.lua');
    await load(engine, 'core/synex_core/server/retention.lua');
    const result = await engine.doString(`
      local platform = {
        print = function() end, nowGame = function() return 1000 end,
        jsonEncode = function() return '{}' end, jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local rolledBack, call = false, 0
      local retention = SynexCoreFactories.retention({
        foundation = foundation,
        database = { withTransaction = function(_, handler)
          local committed = handler(function(sql)
            call = call + 1
            if call == 1 then
              return {{ source_audit_id = '41' }, { source_audit_id = '42' }}
            end
            if call == 2 then return { affectedRows = 1 } end
            return { affectedRows = 1 }
          end)
          rolledBack = committed ~= true
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end },
        config = { batchSize = 2, audit = { mode = 'archive', archiveAfterDays = 30 } }
      })
      local report, archiveError = retention.audit:archiveBatch()
      assert(report == nil and archiveError.code == 'RETENTION_ARCHIVE_INCOMPLETE')
      assert(rolledBack and call == 3)
      return archiveError.code
    `);
    assert.equal(result, 'RETENTION_ARCHIVE_INCOMPLETE');
  } finally {
    engine.global.close();
  }
});

test('financial retention validates policy and returns a redacted idempotent archive report', async () => {
  const source = await readFile(
    path.join(root, 'resources/synex_accounts/server/retention.lua'),
    'utf8',
  );
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local create = assert(load(${JSON.stringify(source)}))()({
        domainError = function(code, message, retryable)
          return { code = code, message = message, retryable = retryable == true }
        end
      })
      local invalid, invalidError = create({
        update = function() error('must not run') end,
        policy = { mode = 'delete', archiveAfterDays = 30, batchSize = 20 }
      })
      assert(invalid == nil and invalidError.code == 'INVALID_RETENTION_POLICY')

      local touched = false
      local retained = assert(create({
        update = function() touched = true return 0 end,
        policy = { mode = 'retain_forever', archiveAfterDays = 30, batchSize = 20 }
      }))
      local skipped = assert(retained:archiveBatch())
      assert(skipped.skipped == true and skipped.sourceRowsDeleted == 0 and touched == false)

      local capturedSql, capturedParameters
      local archive = assert(create({
        update = function(sql, parameters)
          capturedSql, capturedParameters = sql, parameters
          return 20
        end,
        policy = { mode = 'archive', archiveAfterDays = 30, batchSize = 20 }
      }))
      local report = assert(archive:archiveBatch())
      assert(report.archived == 20 and report.batchExhausted == true)
      assert(report.sourceRowsDeleted == 0 and report.scope == 'financial')
      assert(capturedParameters[1] == 30 and capturedParameters[2] == 20)
      assert(capturedSql:find('INSERT IGNORE INTO', 1, true))
      assert(capturedSql:find('synex_financial_transaction_archive', 1, true))
      assert(capturedSql:find('UTC_TIMESTAMP(6)', 1, true))
      assert(capturedSql:find('DELETE', 1, true) == nil)

      local failed = assert(create({
        update = function() error('database credentials must stay private') end,
        policy = { mode = 'archive', archiveAfterDays = 30, batchSize = 20 }
      }))
      local failedReport, failedError = failed:archiveBatch()
      assert(failedReport == nil and failedError.code == 'RETENTION_DATABASE_ERROR')
      assert(failedError.message:find('credentials', 1, true) == nil)
      return table.concat({invalidError.code, report.scope, failedError.code}, ':')
    `);
    assert.equal(result, 'INVALID_RETENTION_POLICY:financial:RETENTION_DATABASE_ERROR');
  } finally {
    engine.global.close();
  }
});
