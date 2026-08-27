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

test('relationship get and list are actor-authorized, bounded, scoped, and expiry-aware', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.persistence.organizations_shared',
      'resources/synex_groups/server/persistence/organizations_shared.lua');
    await preload(engine, 'server.persistence.organizations_structure',
      'resources/synex_groups/server/persistence/organizations_structure.lua');
    const foundation = await readFile(path.join(
      root, 'resources/synex_groups/server/foundation.lua',
    ), 'utf8');
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
      local read = require('server.persistence.organizations_structure')(Foundation).read
      local authorizations = 0
      local runtime = {
        authorize = function(_, groupId, actorId, capability, scope, policy)
          authorizations = authorizations + 1
          assert(groupId == 'group_alpha_0001')
          assert(actorId == 'character_actor_0001')
          assert(capability == 'synex.groups.relationships.read' and scope == 'group')
          assert(policy.kind == 'relationship' and policy.group_id == groupId)
          return true, nil
        end,
        jsonDecode = function(encoded)
          assert(encoded == '{"tier":"gold"}')
          return { tier = 'gold' }
        end
      }
      local expiredRow = {
        relationship_id = 'groups_relation_0001',
        source_group_id = 'group_alpha_0001', target_group_id = 'group_beta_0001',
        relation_type = 'ally_of', direction = 'symmetric', status = 'active',
        effective_status = 'ended', valid_from = '2026-08-25T10:00:00.000000Z',
        valid_until = '2026-08-25T11:00:00.000000Z', ended_at = nil,
        effective_ended_at = '2026-08-25T11:00:00.000000Z',
        metadata_json = '{"tier":"gold"}', version = 4,
        created_at = '2026-08-25T10:00:00.000000Z',
        updated_at = '2026-08-25T10:00:00.000000Z'
      }
      local getParameters
      local getTx = {
        one = function(sql, parameters)
          assert(sql:find("THEN 'pending'", 1, true))
          assert(sql:find("THEN 'ended'", 1, true))
          assert(sql:find('source\`.\`public_id\` = ? OR \`target\`.\`public_id\` = ?', 1, true))
          getParameters = parameters
          return expiredRow
        end
      }
      local value, getError = read.relationships_get(getTx, {
        group_id = 'group_alpha_0001', relationship_id = 'groups_relation_0001',
        actor_character_id = 'character_actor_0001'
      }, runtime)
      assert(getError == nil and value.status == 'ended' and value.version == 4)
      assert(value.metadata.tier == 'gold'
        and value.ended_at == '2026-08-25T11:00:00.000000Z')
      assert(getParameters[1] == 'groups_relation_0001'
        and getParameters[2] == 'group_alpha_0001'
        and getParameters[3] == 'group_alpha_0001')

      local pendingRow = {}
      for key, item in pairs(expiredRow) do pendingRow[key] = item end
      pendingRow.relationship_id = 'groups_relation_pending_0001'
      pendingRow.effective_status = 'pending'
      pendingRow.valid_from = '2099-08-25T10:00:00.000000Z'
      pendingRow.valid_until = nil
      pendingRow.effective_ended_at = nil
      getTx.one = function(sql)
        assert(sql:find("valid_from.+CURRENT_TIMESTAMP%(6%)") ~= nil)
        return pendingRow
      end
      local pending, pendingError = read.relationships_get(getTx, {
        group_id = 'group_alpha_0001', relationship_id = pendingRow.relationship_id,
        actor_character_id = 'character_actor_0001'
      }, runtime)
      assert(pendingError == nil and pending.status == 'pending'
        and pending.ended_at == nil)

      local oversizedRow = {}
      for key, item in pairs(expiredRow) do oversizedRow[key] = item end
      oversizedRow.metadata_json = string.rep('x', 16385)
      getTx.one = function() return oversizedRow end
      local oversized, oversizedError = read.relationships_get(getTx, {
        group_id = 'group_alpha_0001', relationship_id = oversizedRow.relationship_id,
        actor_character_id = 'character_actor_0001'
      }, runtime)
      assert(oversized == nil and oversizedError.code == 'READ_MODEL_TOO_LARGE')

      local listSql, listParameters
      local activeRow = {}
      for key, item in pairs(expiredRow) do activeRow[key] = item end
      activeRow.relationship_id = 'groups_relation_0002'
      activeRow.status = 'active'
      activeRow.effective_status = 'active'
      activeRow.valid_until = nil
      activeRow.effective_ended_at = nil
      local listTx = {
        one = function(sql, parameters)
          assert(sql:find('FROM \`synex_groups\`', 1, true))
          assert(parameters[1] == 'group_alpha_0001')
          return { id = 41 }
        end,
        many = function(sql, parameters)
          listSql, listParameters = sql, parameters
          if parameters[3] == 'pending' then return { pendingRow } end
          return { activeRow, expiredRow }
        end
      }
      local listed, listError = read.relationships_list(listTx, {
        group_id = 'group_alpha_0001', actor_character_id = 'character_actor_0001',
        direction = 'incoming', relation_type = 'ally_of', status = 'active',
        cursor = 'groups_relation_0000', limit = 1
      }, runtime)
      assert(listError == nil and #listed.items == 1 and listed.truncated == true)
      assert(listed.next_cursor == 'groups_relation_0002')
      assert(listed.items[1].metadata == nil)
      assert(listSql:find('\`relationship\`.\`target_group_id\` = ?', 1, true))
      assert(not listSql:find('\`relationship\`.\`source_group_id\` = ? OR', 1, true))
      assert(listSql:find("THEN 'ended'", 1, true))
      assert(listSql:find("THEN 'pending'", 1, true))
      assert(listParameters[1] == 41 and listParameters[2] == 'ally_of'
        and listParameters[3] == 'active'
        and listParameters[4] == 'groups_relation_0000' and listParameters[5] == 2)

      local pendingList, pendingListError = read.relationships_list(listTx, {
        group_id = 'group_alpha_0001', actor_character_id = 'character_actor_0001',
        direction = 'incoming', relation_type = 'ally_of', status = 'pending', limit = 1
      }, runtime)
      assert(pendingListError == nil and #pendingList.items == 1
        and pendingList.items[1].status == 'pending')

      local rejected, boundsError = read.relationships_list(listTx, {
        group_id = 'group_alpha_0001', actor_character_id = 'character_actor_0001',
        limit = 101
      }, runtime)
      assert(rejected == nil and boundsError.code == 'VALIDATION_FAILED')
      assert(authorizations == 5)
      return table.concat({ value.status, pending.status, listed.next_cursor,
        authorizations }, ':')
    `);
    assert.equal(result, 'ended:pending:groups_relation_0002:5');
  } finally {
    engine.global.close();
  }
});

test('relationship metadata decoding is object-only and bounded before and after JSON parsing', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.persistence.organizations_shared',
      'resources/synex_groups/server/persistence/organizations_shared.lua');
    const foundation = await readFile(path.join(
      root, 'resources/synex_groups/server/foundation.lua',
    ), 'utf8');
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
      local Shared = require('server.persistence.organizations_shared')(Foundation)
      local decoded = 0
      local runtime = { jsonDecode = function()
        decoded = decoded + 1
        return { tier = 'gold' }
      end }
      local metadata, failure = Shared.decodeMetadata(runtime, '{"tier":"gold"}')
      assert(failure == nil and metadata.tier == 'gold' and decoded == 1)

      runtime.jsonDecode = function()
        return setmetatable({}, { __jsontype = 'array' })
      end
      local _, arrayError = Shared.decodeMetadata(runtime, '[]')
      assert(arrayError.code == 'DATABASE_RESULT_INVALID')

      local deep, cursor = {}, nil
      cursor = deep
      for index = 1, 9 do cursor.child = {} cursor = cursor.child end
      runtime.jsonDecode = function() return deep end
      local _, depthError = Shared.decodeMetadata(runtime, '{}')
      assert(depthError.code == 'DATABASE_RESULT_INVALID')

      decoded = 0
      runtime.jsonDecode = function() decoded = decoded + 1 return {} end
      local _, sizeError = Shared.decodeMetadata(runtime, string.rep('x', 1048577))
      assert(sizeError.code == 'DATABASE_RESULT_INVALID' and decoded == 0)
      return arrayError.code .. ':' .. depthError.code .. ':' .. sizeError.code
    `);
    assert.equal(
      result,
      'DATABASE_RESULT_INVALID:DATABASE_RESULT_INVALID:DATABASE_RESULT_INVALID',
    );
  } finally {
    engine.global.close();
  }
});

test('relationship maintenance ends expired edges and persists one durable effect', async () => {
  const [foundationSource, workersSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(path.join(
      root, 'resources/synex_groups/server/persistence/workers.lua',
    ), 'utf8'),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      local createWorkers = assert(load(${JSON.stringify(workersSource)},
        '@server/persistence/workers.lua'))()
      local effectWritten, relationshipUpdate, readModelUpdate
      local invalidations = 0
      local tx = {}
      function tx.many(sql)
        if sql:find('FROM synex_group_relationships AS relationship', 1, true) then
          return {{
            id = 71, public_id = 'groups_relation_0001', version = 4,
            status = 'suspended', source_group_id = 41, target_group_id = 42,
            valid_until = '2026-08-25T11:00:00.000000Z',
            group_public_id = 'group_alpha_0001',
            target_group_public_id = 'group_beta_0001'
          }}
        end
        return {}
      end
      function tx.affected(sql, parameters)
        if sql:find('UPDATE synex_group_relationships', 1, true) then
          relationshipUpdate = { sql = sql, parameters = parameters }
          return 1
        end
        if sql:find('UPDATE synex_group_read_model_versions', 1, true) then
          readModelUpdate = { sql = sql, parameters = parameters }
          return 2
        end
        error('unexpected relationship maintenance write: ' .. sql)
      end
      local port = {}
      createWorkers(port, {
        Foundation = Foundation, domainError = Foundation.domainError,
        jsonDecode = function() return {} end, many = function() return {} end,
        update = function() return 1 end,
        cache = { invalidate = function() invalidations = invalidations + 1 end },
        effect = function(action, entityType, entityId, groupId, characterId,
            before, after, reason, version)
          return { action = action, eventType = 'synex.groups.' .. action,
            entityType = entityType, entityId = entityId, groupId = groupId,
            characterId = characterId, before = before, after = after,
            reason = reason, version = version }
        end,
        id = function(namespace)
          assert(namespace == 'group_maintenance')
          return 'group_maintenance_0001'
        end,
        writeEffect = function(suppliedTx, item, request, context)
          assert(suppliedTx == tx and next(request) == nil)
          assert(context.caller == 'synex_groups'
            and context.traceId == 'group_maintenance_0001')
          effectWritten = item
          return true, nil
        end,
        withTransaction = function(handler) return handler(tx) end
      })
      local report, failure = port:maintain({ maximum = 10 })
      assert(failure == nil and report.total == 1 and report.relationships == 1)
      assert(relationshipUpdate.sql:find("SET status = 'ended'", 1, true))
      assert(relationshipUpdate.sql:find('ended_at = valid_until', 1, true))
      assert(relationshipUpdate.sql:find("status IN ('active', 'suspended')", 1, true))
      assert(relationshipUpdate.sql:find('version = ?', 1, true))
      assert(relationshipUpdate.parameters[1] == 71
        and relationshipUpdate.parameters[2] == 4)
      assert(readModelUpdate.parameters[1] == 41 and readModelUpdate.parameters[2] == 42)
      assert(effectWritten.action == 'relationship.expired'
        and effectWritten.eventType == 'synex.groups.relationship.expired')
      assert(effectWritten.before.status == 'suspended'
        and effectWritten.after.status == 'ended' and effectWritten.after.version == 5)
      assert(effectWritten.after.source_group_id == 'group_alpha_0001'
        and effectWritten.after.target_group_id == 'group_beta_0001')
      assert(effectWritten.after.ended_at == '2026-08-25T11:00:00.000000Z')
      assert(effectWritten.reason == 'relationship_window_expired'
        and invalidations == 1)
      return table.concat({ report.relationships, effectWritten.after.status,
        invalidations }, ':')
    `);
    assert.equal(result, '1:ended:1');
  } finally {
    engine.global.close();
  }
});

test('relationship maintenance fails closed on a stale CAS without side effects', async () => {
  const [foundationSource, workersSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(path.join(
      root, 'resources/synex_groups/server/persistence/workers.lua',
    ), 'utf8'),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      local createWorkers = assert(load(${JSON.stringify(workersSource)},
        '@server/persistence/workers.lua'))()
      local writes, effects, invalidations = 0, 0, 0
      local tx = {
        many = function(sql)
          if sql:find('FROM synex_group_relationships AS relationship', 1, true) then
            return {{ id = 71, public_id = 'groups_relation_0001', version = 4,
              status = 'active', source_group_id = 41, target_group_id = 42,
              group_public_id = 'group_alpha_0001',
              target_group_public_id = 'group_beta_0001' }}
          end
          return {}
        end,
        affected = function()
          writes = writes + 1
          return 0
        end
      }
      local port = {}
      createWorkers(port, {
        Foundation = Foundation, domainError = Foundation.domainError,
        jsonDecode = function() return {} end, many = function() return {} end,
        update = function() return 1 end,
        cache = { invalidate = function() invalidations = invalidations + 1 end },
        effect = function() error('effect must not be created after stale CAS') end,
        id = function() return 'group_maintenance_0001' end,
        writeEffect = function() effects = effects + 1 return true end,
        withTransaction = function(handler)
          local value, failure = handler(tx)
          if value then return value, failure end
          return nil, failure
        end
      })
      local report, failure = port:maintain({ maximum = 10 })
      assert(report == nil and failure.code == 'CONCURRENT_MODIFICATION')
      assert(writes == 1 and effects == 0 and invalidations == 0)
      return failure.code
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});
