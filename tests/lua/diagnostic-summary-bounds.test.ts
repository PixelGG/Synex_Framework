import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(module: 'reliability' | 'runtime_persistence'): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/server/factories.lua');
  await load(engine, 'core/synex_core/server/foundation.lua');
  if (module === 'runtime_persistence') {
    for (const dependency of [
      'runtime_persistence_instances',
      'runtime_persistence_control',
      'runtime_persistence_control_retention',
      'runtime_persistence_rbac',
    ]) await load(engine, `core/synex_core/server/${dependency}.lua`);
  }
  await load(engine, `core/synex_core/server/${module}.lua`);
  return engine;
}

test('saga diagnostics use bounded index probes and expose lower-bound truncation', async () => {
  const engine = await coreEngine('reliability');
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 7 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local calls = 0
      local database = {}
      function database:query(sql, parameters)
        calls = calls + 1
        assert(not sql:find('COUNT(', 1, true) and not sql:find('GROUP BY', 1, true))
        local _, probes = sql:gsub('FORCE INDEX', '')
        assert(probes == 6 and #parameters == 6)
        for index = 1, 6 do assert(parameters[index] == 4) end
        return {
          { state = 'pending' }, { state = 'pending' },
          { state = 'pending' }, { state = 'pending' },
          { state = 'completed' }, { state = 'completed' }
        }, nil
      end
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', features = { sagas = true },
        diagnosticBatchMaximum = 3
      })
      local snapshot = assert(reliability.sagas:snapshot())
      assert(calls == 1 and snapshot.enabled and snapshot.truncated)
      assert(snapshot.total == 5 and snapshot.states.pending == 3
        and snapshot.states.completed == 2)
      assert(snapshot.stateTruncation.pending == true
        and snapshot.stateTruncation.completed == false)
      return table.concat({snapshot.total, snapshot.states.pending,
        snapshot.states.completed, tostring(snapshot.truncated)}, ':')
    `);
    assert.equal(result, '5:3:2:true');
  } finally {
    engine.global.close();
  }
});

test('RBAC diagnostics bound both persistent probes and report truncation', async () => {
  const engine = await coreEngine('runtime_persistence');
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 11 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local calls = 0
      local database = {}
      function database:query(sql, parameters)
        calls = calls + 1
        assert(not sql:find('COUNT(', 1, true) and not sql:find('GROUP BY', 1, true))
        if sql:find('synex_rbac_roles', 1, true) then
          assert(parameters[1] == 4 and sql:find('ORDER BY', 1, true)
            and sql:find('LIMIT ?', 1, true))
          return {{ role_name = 'a' }, { role_name = 'b' },
            { role_name = 'c' }, { role_name = 'd' }}, nil
        end
        assert(sql:find('idx_rbac_subject_roles_expiry', 1, true)
          and sql:find('UNION ALL', 1, true))
        assert(sql:find('ORDER BY ' .. string.char(96) .. 'expires_at'
          .. string.char(96) .. ', ' .. string.char(96) .. 'subject_ref'
          .. string.char(96) .. ' LIMIT ?', 1, true))
        assert(#parameters == 3 and parameters[1] == 4
          and parameters[2] == 4 and parameters[3] == 4)
        return {
          { subject_ref = 'user:a', role_name = 'a' },
          { subject_ref = 'user:b', role_name = 'b' },
          { subject_ref = 'user:c', role_name = 'c' },
          { subject_ref = 'user:d', role_name = 'd' }
        }, nil
      end
      local persistence = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', maintenanceBatchMaximum = 3
      })
      local summary = assert(persistence.rbac:summary())
      assert(calls == 2 and summary.roles == 3 and summary.activeAssignments == 3)
      assert(summary.rolesTruncated and summary.activeAssignmentsTruncated)
      return table.concat({summary.roles, summary.activeAssignments,
        tostring(summary.rolesTruncated), tostring(summary.activeAssignmentsTruncated)}, ':')
    `);
    assert.equal(result, '3:3:true:true');
  } finally {
    engine.global.close();
  }
});
