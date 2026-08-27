import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

test('static hierarchy relinking is cycle-safe and updates the locked edge with CAS', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(
      engine,
      'server.persistence.governance_shared',
      'resources/synex_groups/server/persistence/governance_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.governance_definitions_hierarchy',
      'resources/synex_groups/server/persistence/governance_definitions_hierarchy.lua',
    );
    const result = await engine.doString(String.raw`
      local Foundation = require 'server.foundation'
      local Hierarchy = require(
        'server.persistence.governance_definitions_hierarchy')(Foundation)
      local tx = { cas = false, closure = false }
      function tx.one(sql)
        if sql:find('SELECT MAX', 1, true) then return { maximum_depth = 0 } end
        return nil
      end
      function tx.many() return {} end
      function tx.query(sql)
        if sql:find('synex_group_hierarchy_closure', 1, true) then
          tx.closure = true
        end
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        if sql:find('UPDATE', 1, true)
          and sql:find('synex_group_hierarchy_edges', 1, true) then
          assert(parameters[1] == 4 and parameters[2] == 2 and parameters[3] == 7)
          assert(sql:find('version', 1, true) and sql:find('AND', 1, true))
          tx.cas = true
        end
        return 1
      end
      local applied = assert(Hierarchy.apply(tx, {
        targetGroupId = 2,
        groupState = { live = { id = 2, parent_group_id = 3, edge_version = 7 } }
      }, { targetGroupId = 4 }))
      return applied and tx.cas and tx.closure
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});
