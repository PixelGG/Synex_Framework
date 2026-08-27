import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function createEngine(): Promise<LuaEngine> {
  const modules = [
    ['server.foundation', 'resources/synex_groups/server/foundation.lua'],
    ['server.domain.constants', 'resources/synex_groups/server/domain/constants.lua'],
    ['server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua'],
    [
      'server.persistence.membership_transition_policies',
      'resources/synex_groups/server/persistence/membership_transition_policies.lua',
    ],
  ] as const;
  const sources = await Promise.all(modules.map(async ([name, relativePath]) => ({
    name,
    relativePath,
    source: await readFile(path.join(root, relativePath), 'utf8'),
  })));
  const engine = await new LuaFactory().createEngine();
  for (const item of sources) {
    await engine.doString(
      `package.preload[${JSON.stringify(item.name)}] = assert(load(${JSON.stringify(item.source)}, ${JSON.stringify(`@${item.relativePath}`)}))`,
    );
  }
  return engine;
}

const fixture = String.raw`
  local Foundation = require 'server.foundation'
  local Policies = require('server.persistence.membership_transition_policies')(Foundation)
  local runtime = { touched = 0, authorizations = {}, effects = {} }
  function runtime.requireGroup(_, groupId)
    return {
      id = 17, public_id = groupId, status = 'active', lifecycle_state = 'ACTIVE',
      version = 4
    }
  end
  function runtime.authorize(_, groupId, actorId, capability, scope)
    runtime.authorizations[#runtime.authorizations + 1] = {
      groupId = groupId, actorId = actorId, capability = capability, scope = scope
    }
    if runtime.deny then
      return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
    end
    return { id = 31, public_id = 'group_member_actor_0001' }
  end
  function runtime.id()
    return 'group_transition_policy_00000001'
  end
  function runtime.touchGroup(_, groupId)
    assert(groupId == 17)
    runtime.touched = runtime.touched + 1
    return true
  end
  function runtime.success(entityId, entityType, status, version)
    return { entity_id = entityId, entity_type = entityType,
      status = status, version = version, replayed = false }
  end
  function runtime.effect(action, entityType, entityId, groupId, characterId,
      before, after, reason, version)
    local effect = { action = action, entityType = entityType, entityId = entityId,
      groupId = groupId, characterId = characterId, before = before, after = after,
      reason = reason, version = version }
    runtime.effects[#runtime.effects + 1] = effect
    return effect
  end
  local request = {
    actor_character_id = 'character_actor_00000001',
    group_id = 'groups_group_00000001',
    from_status = 'ACTIVE',
    to_status = 'SUSPENDED',
    allowed = true,
    required_capability = 'synex.groups.members.suspend',
    approval_required = true,
    reason_required = true,
    reason = 'security_review'
  }
`;

test('migration 028 creates a replay-verified normalized transition-policy authority', async () => {
  const migration = await readFile(path.join(
    root,
    'resources/synex_groups/migrations/028_membership_transition_policies.sql',
  ), 'utf8');
  assert.match(
    migration,
    /CREATE TABLE IF NOT EXISTS `synex_group_membership_transition_policies`/u,
  );
  assert.match(
    migration,
    /UNIQUE KEY `uq_group_membership_transition_policy_route`\s*\(`group_id`, `from_state`, `to_state`\)/u,
  );
  assert.match(migration, /`allowed` TINYINT UNSIGNED NOT NULL DEFAULT 1/u);
  assert.match(
    migration,
    /`required_capability`[\s\S]*?DEFAULT 'synex\.groups\.members\.manage'/u,
  );
  assert.match(migration, /`approval_required` TINYINT UNSIGNED NOT NULL DEFAULT 0/u);
  assert.match(migration, /`reason_required` TINYINT UNSIGNED NOT NULL DEFAULT 1/u);
  assert.match(
    migration,
    /fk_group_membership_transition_policy_from_state[\s\S]*?synex_group_membership_states/u,
  );
  assert.match(
    migration,
    /fk_group_membership_transition_policy_to_state[\s\S]*?synex_group_membership_states/u,
  );
  assert.match(
    migration,
    /chk_group_membership_transition_policy_capability[\s\S]*?\\\\\./u,
  );
  assert.match(
    migration,
    /synex_groups_verify_028_membership_transition_policies/u,
  );
  assert.equal(migration.match(/^-- synex:statement$/gmu)?.length, 4);
});

test('transition-policy module is server-only and has no direct database adapter coupling', async () => {
  const source = await readFile(path.join(
    root,
    'resources/synex_groups/server/persistence/membership_transition_policies.lua',
  ), 'utf8');
  assert.doesNotMatch(
    source,
    /\bMySQL\b|oxmysql|RegisterNetEvent|RegisterServerEvent|TriggerClientEvent/u,
  );
  assert.doesNotMatch(source, /PerformHttpRequest|loadstring|dofile/u);

  const engine = await createEngine();
  try {
    assert.equal(await engine.doString(`
      local Foundation = require 'server.foundation'
      local built = require('server.persistence.membership_transition_policies')(Foundation)
      assert(type(built.read.members_transition_policy_get) == 'function')
      assert(type(built.execute.members_transition_policy_set) == 'function')
      return type(built.resolveMembershipTransitionPolicy)
    `), 'function');
  } finally {
    await engine.global.close();
  }
});

test('policy resolution preserves compatibility defaults and rejects malformed durable rows', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`${fixture}
      local tx = { row = nil, queries = 0 }
      function tx.one(sql, parameters)
        tx.queries = tx.queries + 1
        assert(sql:find('synex_group_membership_transition_policies', 1, true))
        assert(parameters[1] == 17 and parameters[2] == 'ACTIVE'
          and parameters[3] == 'SUSPENDED')
        return tx.row
      end
      local defaults = assert(Policies.resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id, internal_group_id = 17,
        from_status = 'active', to_status = 'suspended', lock = true
      }))
      assert(defaults.configured == false and defaults.allowed == true)
      assert(defaults.required_capability == 'synex.groups.members.manage')
      assert(defaults.approval_required == false and defaults.reason_required == true)

      tx.row = {
        id = 71, public_id = 'group_transition_policy_00000002', group_id = 17,
        from_state = 'ACTIVE', to_state = 'SUSPENDED', allowed = 0,
        required_capability = 'synex.groups.members.suspend',
        approval_required = 1, reason_required = 0, version = 6
      }
      local configured = assert(Policies.resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id, internal_group_id = 17,
        from_status = 'ACTIVE', to_status = 'SUSPENDED'
      }))
      assert(configured.configured and configured._internal_id == 71)
      assert(configured.allowed == false and configured.approval_required == true
        and configured.reason_required == false and configured.version == 6)

      tx.row.allowed = 2
      local malformed, malformedError = Policies.resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id, internal_group_id = 17,
        from_status = 'ACTIVE', to_status = 'SUSPENDED'
      })
      assert(malformed == nil and malformedError.code == 'DATABASE_RESULT_INVALID'
        and malformedError.retryable == true)

      local beforeQueries = tx.queries
      local impossible, impossibleError = Policies.resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id, internal_group_id = 17,
        from_status = 'ACTIVE', to_status = 'APPROVED'
      })
      assert(impossible == nil and impossibleError.code == 'INVALID_TRANSITION')
      assert(tx.queries == beforeQueries)
      local workflowOwned, workflowOwnedError = Policies.resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id, internal_group_id = 17,
        from_status = 'INVITED', to_status = 'ACTIVE'
      })
      assert(workflowOwned == nil and workflowOwnedError.code == 'INVALID_TRANSITION')
      assert(tx.queries == beforeQueries)
      return defaults.required_capability .. ':' .. configured.version .. ':'
        .. malformedError.code .. ':' .. impossibleError.code .. ':'
        .. workflowOwnedError.code
    `);
    assert.equal(
      result,
      'synex.groups.members.manage:6:DATABASE_RESULT_INVALID:INVALID_TRANSITION:INVALID_TRANSITION',
    );
  } finally {
    await engine.global.close();
  }
});

test('policy creation validates type-state ceilings and persists a bounded exact capability', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`${fixture}
      local tx = { stateAllowed = true, policy = nil, writes = {} }
      function tx.one(sql)
        if sql:find('synex_group_organization_profiles', 1, true) then
          if not tx.stateAllowed then return nil end
          return { from_state = 'ACTIVE', to_state = 'SUSPENDED' }
        end
        if sql:find('synex_group_membership_transition_policies', 1, true) then
          return tx.policy
        end
        error('unexpected policy query: ' .. sql)
      end
      function tx.affected(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end

      local created, createError, effects =
        Policies.execute.members_transition_policy_set(tx, request, runtime)
      assert(created, createError and createError.code)
      assert(created.entity_type == 'membership_transition_policy'
        and created.version == 1 and #effects == 1)
      assert(runtime.authorizations[1].capability == 'synex.groups.policies.manage')
      assert(runtime.authorizations[1].scope == 'group' and runtime.touched == 1)
      local inserted = tx.writes[1]
      assert(inserted.sql:find('INSERT INTO', 1, true))
      assert(inserted.parameters[2] == 17 and inserted.parameters[3] == 'ACTIVE'
        and inserted.parameters[4] == 'SUSPENDED')
      assert(inserted.parameters[5] == 1
        and inserted.parameters[6] == 'synex.groups.members.suspend')
      assert(inserted.parameters[7] == 1 and inserted.parameters[8] == 1)
      assert(effects[1].before.configured == false
        and effects[1].after.approval_required == true)

      local writesBefore = #tx.writes
      request.required_capability = 'synex.groups.members.*'
      local wildcard, wildcardError =
        Policies.execute.members_transition_policy_set(tx, request, runtime)
      assert(wildcard == nil and wildcardError.code == 'VALIDATION_FAILED')
      assert(#tx.writes == writesBefore)

      request.required_capability = 'synex.groups.members.suspend'
      tx.stateAllowed = false
      local outsideType, outsideTypeError =
        Policies.execute.members_transition_policy_set(tx, request, runtime)
      assert(outsideType == nil and outsideTypeError.code == 'INVALID_TRANSITION')
      assert(#tx.writes == writesBefore)
      return created.entity_type .. ':' .. wildcardError.code .. ':'
        .. outsideTypeError.code
    `);
    assert.equal(
      result,
      'membership_transition_policy:VALIDATION_FAILED:INVALID_TRANSITION',
    );
  } finally {
    await engine.global.close();
  }
});

test('policy updates use the locked internal identifier and exact optimistic CAS', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`${fixture}
      local tx = { writes = {}, policy = {
        id = 73, public_id = 'group_transition_policy_00000003', group_id = 17,
        from_state = 'ACTIVE', to_state = 'SUSPENDED', allowed = 1,
        required_capability = 'synex.groups.members.manage',
        approval_required = 0, reason_required = 1, version = 4
      }}
      function tx.one(sql)
        if sql:find('synex_group_organization_profiles', 1, true) then
          return { from_state = 'ACTIVE', to_state = 'SUSPENDED' }
        end
        if sql:find('synex_group_membership_transition_policies', 1, true) then
          return tx.policy
        end
        error('unexpected update query: ' .. sql)
      end
      function tx.affected(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end

      request.expected_version = 3
      local stale, staleError =
        Policies.execute.members_transition_policy_set(tx, request, runtime)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(#tx.writes == 0 and runtime.touched == 0)

      request.expected_version = 4
      request.allowed = false
      request.reason_required = false
      local changed, changeError, effects =
        Policies.execute.members_transition_policy_set(tx, request, runtime)
      assert(changed, changeError and changeError.code)
      assert(changed.entity_id == tx.policy.public_id and changed.version == 5)
      assert(#tx.writes == 1 and tx.writes[1].sql:find('UPDATE', 1, true))
      assert(tx.writes[1].parameters[6] == 73
        and tx.writes[1].parameters[7] == 4)
      assert(effects[1].before._internal_id == nil
        and effects[1].before.version == 4
        and effects[1].after.allowed == false)

      local public = assert(Policies.read.members_transition_policy_get(tx,
        request, runtime))
      assert(public._internal_id == nil and public.policy_id == tx.policy.public_id)
      return staleError.code .. ':' .. changed.version .. ':'
        .. tostring(public._internal_id)
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION:5:nil');
  } finally {
    await engine.global.close();
  }
});
