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

      local capturedSql, capturedParameters
      local archiving = SynexCoreFactories.retention({
        foundation = foundation,
        database = { update = function(_, sql, parameters)
          capturedSql, capturedParameters = sql, parameters
          return 17, nil
        end },
        config = {
          batchSize = 25,
          audit = { mode = 'archive', archiveAfterDays = 90 }
        }
      })
      local report = assert(archiving.audit:archiveBatch())
      assert(report.archived == 17 and report.sourceRowsDeleted == 0 and report.batchExhausted == false)
      assert(capturedParameters[1] == 90 and capturedParameters[2] == 25)
      assert(capturedSql:find('INSERT IGNORE INTO', 1, true))
      assert(capturedSql:find('synex_audit_archive', 1, true))
      assert(capturedSql:find('UTC_TIMESTAMP(6)', 1, true))
      assert(capturedSql:find('ORDER BY', 1, true) and capturedSql:find('LIMIT ?', 1, true))
      assert(capturedSql:find('DELETE', 1, true) == nil)
      return table.concat({skipped.mode, report.scope, report.archived}, ':')
    `);
    assert.equal(result, 'retain_forever:audit:17');
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
