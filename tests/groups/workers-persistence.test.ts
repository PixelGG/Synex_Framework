import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('lifecycle maintenance expires bounded entities transactionally with audit and outbox effects', async () => {
  const [foundationSource, workersSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/workers.lua'),
      'utf8',
    ),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      local createWorkers = assert(load(${JSON.stringify(workersSource)},
        '@server/persistence/workers.lua'))()
      local effects, updates, invalidations = {}, {}, 0
      local rows = {
        roles = { id = 1, public_id = 'role_assignment_0001', version = 2,
          status = 'active',
          group_public_id = 'group_public_0001', character_id = 'character_0001' },
        delegations = { id = 2, public_id = 'delegation_0001', version = 3,
          status = 'active',
          group_public_id = 'group_public_0001', character_id = 'character_0002' },
        invitations = { id = 3, public_id = 'invitation_0001', version = 4,
          status = 'pending',
          group_public_id = 'group_public_0001', character_id = 'character_0003',
          membership_id = 31, membership_public_id = 'membership_00000031',
          membership_version = 2, membership_lifecycle = 'INVITED',
          membership_profile_version = 2 },
        applications = { id = 6, public_id = 'application_0001', version = 2,
          status = 'reviewing', public_status = 'under_review',
          group_public_id = 'group_public_0001',
          character_id = 'character_0004', membership_id = 32,
          membership_public_id = 'membership_00000032', membership_version = 3,
          membership_lifecycle = 'UNDER_REVIEW', membership_profile_version = 3 },
        assignments = { id = 4, public_id = 'assignment_0001', version = 5,
          status = 'active',
          group_public_id = 'group_public_0001' },
        proposals = { id = 5, public_id = 'proposal_0001', version = 6,
          status = 'approved',
          group_public_id = 'group_public_0001' }
      }
      local tx = {}
      function tx.many(sql, parameters)
        assert(parameters[1] >= 1 and parameters[1] <= 6)
        if sql:find('synex_group_membership_roles', 1, true) then return { rows.roles } end
        if sql:find('synex_group_delegations', 1, true) then return { rows.delegations } end
        if sql:find('synex_group_invitations', 1, true) then return { rows.invitations } end
        if sql:find('synex_group_applications', 1, true) then return { rows.applications } end
        if sql:find('synex_group_assignments', 1, true) then return { rows.assignments } end
        if sql:find('synex_group_proposals', 1, true) then return { rows.proposals } end
        error('unexpected maintenance select: ' .. sql)
      end
      function tx.affected(sql, parameters)
        updates[#updates + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      local port = {}
      createWorkers(port, {
        Foundation = Foundation,
        domainError = Foundation.domainError,
        jsonDecode = function() return {} end,
        many = function() return {} end,
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
          effects[#effects + 1] = item
          return true
        end,
        withTransaction = function(handler)
          local ok, failure = handler(tx)
          return ok, failure
        end
      })
      local report, failure = port:maintain({ maximum = 6 })
      assert(failure == nil and report.total == 6)
      assert(report.roles == 1 and report.delegations == 1
        and report.invitations == 1 and report.applications == 1
        and report.assignments == 1 and report.proposals == 1)
      assert(#updates == 15 and #effects == 8 and invalidations == 1)
      assert(effects[1].action == 'role.expired')
      assert(effects[2].action == 'delegation.expired')
      assert(effects[2].eventType == 'synex.groups.delegation.expired')
      assert(effects[3].action == 'membership.invitation_expired')
      assert(effects[4].action == 'membership.draft'
        and effects[4].before.status == 'INVITED')
      assert(effects[5].action == 'application.expired'
        and effects[5].before.status == 'under_review')
      assert(effects[6].action == 'membership.draft'
        and effects[6].before.status == 'UNDER_REVIEW')
      assert(effects[8].action == 'proposal.expired'
        and effects[8].before.status == 'approved')
      assert(effects[7].after.members_removed == 1
        and effects[7].after.duty_sessions_closed == 1)
      for _, index in ipairs({ 1, 2, 3, 5, 7, 8 }) do
        local item = effects[index]
        assert(item.after.status == 'expired')
        assert(item.after.version == item.before.version + 1)
      end
      return table.concat({ report.total, effects[2].action, invalidations }, ':')
    `);
    assert.equal(result, '6:delegation.expired:1');
  } finally {
    engine.global.close();
  }
});

test('lifecycle maintenance rolls back and preserves cache state when effect persistence fails', async () => {
  const [foundationSource, workersSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/workers.lua'),
      'utf8',
    ),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      local createWorkers = assert(load(${JSON.stringify(workersSource)},
        '@server/persistence/workers.lua'))()
      local invalidations = 0
      local tx = {
        many = function(sql)
          if sql:find('synex_group_membership_roles', 1, true) then
            return {{ id = 1, public_id = 'role_assignment_0001', version = 1,
              status = 'active', group_public_id = 'group_public_0001' }}
          end
          return {}
        end,
        affected = function() return 1 end
      }
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
        id = function() return 'group_maintenance_0001' end,
        writeEffect = function()
          return nil, Foundation.domainError('DATABASE_ERROR', 'audit failed', true)
        end,
        withTransaction = function(handler)
          local ok, failure = handler(tx)
          if ok then return true end
          return nil, failure
        end
      })
      local report, failure = port:maintain({ maximum = 1 })
      assert(report == nil and failure.code == 'DATABASE_ERROR' and invalidations == 0)
      return failure.code
    `);
    assert.equal(result, 'DATABASE_ERROR');
  } finally {
    engine.global.close();
  }
});

test('lifecycle maintenance rotates saturated entity classes so relationship expiry cannot starve', async () => {
  const [foundationSource, workersSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/workers.lua'),
      'utf8',
    ),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      local createWorkers = assert(load(${JSON.stringify(workersSource)},
        '@server/persistence/workers.lua'))()
      local effects = {}
      local tx = {}
      function tx.many(sql)
        if sql:find('synex_group_membership_roles', 1, true) then
          return {{ id = 1, public_id = 'role_assignment_0001', version = 1,
            status = 'active', group_public_id = 'group_alpha_0001' }}
        end
        if sql:find('FROM synex_group_relationships AS relationship', 1, true) then
          return {{ id = 71, public_id = 'groups_relation_0001', version = 4,
            status = 'active', source_group_id = 41, target_group_id = 42,
            valid_until = '2026-08-25T11:00:00.000000Z',
            group_public_id = 'group_alpha_0001',
            target_group_public_id = 'group_beta_0001' }}
        end
        return {}
      end
      function tx.affected(sql)
        if sql:find('synex_group_read_model_versions', 1, true) then return 2 end
        return 1
      end
      local port = {}
      createWorkers(port, {
        Foundation = Foundation, domainError = Foundation.domainError,
        jsonDecode = function() return {} end, many = function() return {} end,
        update = function() return 1 end,
        cache = { invalidate = function() return 1 end },
        effect = function(action, entityType, entityId, groupId, characterId,
            before, after, reason, version)
          return { action = action, entityType = entityType, entityId = entityId,
            groupId = groupId, characterId = characterId, before = before,
            after = after, reason = reason, version = version }
        end,
        id = function() return 'group_maintenance_0001' end,
        writeEffect = function(_, item) effects[#effects + 1] = item return true end,
        withTransaction = function(handler) return handler(tx) end
      })
      local first = assert(port:maintain({ maximum = 1 }))
      local second = assert(port:maintain({ maximum = 1 }))
      assert(first.roles == 1 and first.relationships == 0)
      assert(second.roles == 0 and second.relationships == 1)
      assert(effects[2].action == 'relationship.expired')
      assert(effects[2].after.ended_at == '2026-08-25T11:00:00.000000Z')
      return first.roles .. ':' .. second.relationships .. ':' .. #effects
    `);
    assert.equal(result, '1:1:2');
  } finally {
    engine.global.close();
  }
});
