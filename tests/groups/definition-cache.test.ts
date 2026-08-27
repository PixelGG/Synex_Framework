import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const lua = await source(relativePath);
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(lua)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

test('definition cache is bounded, revision-keyed, defensively copied, observable, and restart-empty', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(
      engine,
      'server.persistence.definition_cache',
      'resources/synex_groups/server/persistence/definition_cache.lua',
    );
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Cache = require('server.persistence.definition_cache')(Foundation)
      local cache = Cache({ maximum = 16 })
      local original = { rules = {{ capability = 'groups.read', effect = 'allow' }} }
      assert(cache:put('grade_rules', 'group_alpha:grade_owner', 1, original))
      original.rules[1].effect = 'deny'
      local first = assert(cache:get('grade_rules', 'group_alpha:grade_owner', 1))
      assert(first.rules[1].effect == 'allow')
      first.rules[1].effect = 'deny'
      assert(cache:get('grade_rules', 'group_alpha:grade_owner', 1).rules[1].effect == 'allow')
      assert(cache:get('grade_rules', 'group_alpha:grade_owner', 2) == nil)

      assert(cache:put('policy_rules', 'group_alpha:members.promote', 3, {}))
      for index = 1, 16 do
        assert(cache:put('role_sources', 'group_beta:member_' .. index, 1, {}))
      end
      local bounded = cache:snapshot()
      assert(bounded.size == 16 and bounded.maximum == 16 and bounded.evictions == 2)
      local removed = cache:invalidateGroup('group_alpha')
      assert(removed <= 1)
      local beforeClear = cache:snapshot()
      assert(beforeClear.hits == 2 and beforeClear.misses == 1)
      local cleared = cache:clear()
      local final = cache:snapshot()
      assert(cleared == beforeClear.size and final.size == 0)
      assert(final.invalidations >= cleared and final.clears == 1)

      local restarted = Cache({ maximum = 16 })
      local restart = restarted:snapshot()
      assert(restart.size == 0 and restart.hits == 0 and restart.writes == 0)
      local invalid, invalidError = restarted:put('grade_rules', 'bad identity', 1, {})
      assert(invalid == nil and invalidError.code == 'INVALID_CACHE_KEY')
      local invalidValue, valueError = restarted:put('grade_rules', 'group_alpha', 1, true)
      assert(invalidValue == nil and valueError.code == 'INVALID_CACHE_VALUE')
      assert(restarted:invalidate(nil, 'group_alpha') == 0)
      local optionsOk = pcall(Cache, 1)
      assert(optionsOk == false)
      return table.concat({ bounded.size, bounded.evictions, final.size, restart.size }, ':')
    `);
    assert.equal(result, '16:2:0:0');
  } finally {
    engine.global.close();
  }
});

test('capability definitions reuse one revision and fail closed before a stale revision can grant', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(
      engine,
      'server.persistence.definition_cache',
      'resources/synex_groups/server/persistence/definition_cache.lua',
    );
    await preload(
      engine,
      'server.persistence.capability_access',
      'resources/synex_groups/server/persistence/capability_access.lua',
    );
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createAccess = require('server.persistence.capability_access')(Foundation)
      local membershipRevision, verifiedRevision, effect = 1, 1, 'allow'
      local counts = { defaults = 0, grade = 0, roles = 0, dynamic = 0 }
      local evaluations = {}
      local evaluator = {}
      function evaluator:evaluate(request)
        evaluations[#evaluations + 1] = request
        return { allowed = request.grade.rules[1].effect == 'allow',
          reason = request.grade.rules[1].effect == 'allow' and 'MATCHED_ALLOW' or 'MATCHED_DENY',
          trace = {} }, nil
      end
      local access = createAccess({
        evaluator = evaluator,
        getStoredPolicyEvaluator = function() return nil end,
        getRuntime = function() return {} end
      })
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_memberships AS membership', 1, true) then
          return { id = 11, public_id = 'membership_alpha', version = 1,
            lifecycle_state = 'ACTIVE', group_internal_id = 7,
            definition_revision = membershipRevision,
            grade_internal_id = 3, grade_public_id = 'grade_owner' }
        end
        if sql:find('FROM synex_group_read_model_versions', 1, true) then
          return { model_version = verifiedRevision }
        end
        error('unexpected row query: ' .. sql)
      end
      function tx.many(sql)
        if sql:find('synex_group_default_capabilities', 1, true) then
          counts.defaults = counts.defaults + 1
          return {{ id = 1, capability_pattern = 'groups.read', effect = effect,
            scope_kind = 'group', scope_ref = '', delegable = 0 }}
        end
        if sql:find('synex_group_grade_capabilities', 1, true) then
          counts.grade = counts.grade + 1
          return {{ id = 2, capability_pattern = 'groups.read', effect = effect,
            scope_kind = 'group', scope_ref = '', delegable = 0 }}
        end
        if sql:find('synex_group_membership_roles', 1, true) then
          counts.roles = counts.roles + 1
          return {{ assignment_public_id = 'assignment_alpha', role_public_id = 'role_chief',
            capability_id = 3, capability_pattern = 'groups.read', effect = effect,
            scope_kind = 'group', scope_ref = '', delegable = 0,
            valid_from_unix = 1, valid_until_unix = 4102444800 }}
        end
        if sql:find('synex_group_delegations', 1, true)
            or sql:find('synex_group_membership_capabilities', 1, true) then
          counts.dynamic = counts.dynamic + 1
          return {}
        end
        error('unexpected list query: ' .. sql)
      end

      local first = assert(access.evaluateCharacter(
        tx, 'group_alpha', 'character_alpha', 'groups.read', 'group', false))
      local second = assert(access.evaluateCharacter(
        tx, 'group_alpha', 'character_alpha', 'groups.read', 'group', false))
      assert(first.allowed and second.allowed)
      assert(counts.defaults == 1 and counts.grade == 1 and counts.roles == 1)
      assert(counts.dynamic == 4)
      local warm = access.definitionCacheSnapshot()
      assert(warm.size == 3 and warm.hits == 3 and warm.misses == 3)

      effect, membershipRevision, verifiedRevision = 'deny', 2, 2
      local revised = assert(access.evaluateCharacter(
        tx, 'group_alpha', 'character_alpha', 'groups.read', 'group', false))
      assert(revised.allowed == false and revised.reason == 'MATCHED_DENY')
      assert(evaluations[#evaluations].grade.rules[1].effect == 'deny')
      assert(counts.defaults == 2 and counts.grade == 2 and counts.roles == 2)

      membershipRevision, verifiedRevision = 2, 3
      local stale, staleError = access.evaluateCharacter(
        tx, 'group_alpha', 'character_alpha', 'groups.read', 'group', false)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(access.definitionCacheSnapshot().size == 0)
      assert(access.clearDefinitions() == 0)
      return table.concat({ warm.size, counts.defaults, counts.grade,
        counts.roles, staleError.code }, ':')
    `);
    assert.equal(result, '3:2:2:2:CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});

test('policy rules are version-cached, revalidated against DB authority, and invalidated by mutation', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(
      engine,
      'server.persistence.definition_cache',
      'resources/synex_groups/server/persistence/definition_cache.lua',
    );
    await preload(
      engine,
      'server.persistence.governance_shared',
      'resources/synex_groups/server/persistence/governance_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.governance_policies',
      'resources/synex_groups/server/persistence/governance_policies.lua',
    );
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Cache = require('server.persistence.definition_cache')(Foundation)
      local handlers = require('server.persistence.governance_policies')(Foundation)
      local cache = Cache({ maximum = 16 })
      local version, verifiedVersion, ruleEffect, reads = 1, 1, 'allow', 0
      local runtime = { definitionCache = cache, jsonDecode = function() return {} end }
      function runtime.requireGroup(_, groupId)
        return { id = 10, public_id = groupId, status = 'active',
          lifecycle_state = 'ACTIVE', version = 1 }
      end
      function runtime.authorize()
        return { id = 21, public_id = 'membership_actor', lifecycle_state = 'ACTIVE' }
      end
      function runtime.touchGroup() return true end
      function runtime.reason(_, fallback) return fallback end
      function runtime.success(id, kind, status, revision)
        return { entity_id = id, entity_type = kind, status = status,
          version = revision, replayed = false }
      end
      function runtime.effect(action, kind, id, groupId, characterId,
          before, after, operationReason, revision)
        return { action = action, entityType = kind, entityId = id,
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = operationReason, version = revision }
      end
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_policies', 1, true)
            and sql:find('policy_key', 1, true) then
          return { id = 44, public_id = 'policy_alpha', default_effect = 'deny',
            status = 'active', version = version }
        end
        if sql:find('SELECT version FROM synex_group_policies', 1, true) then
          return { version = verifiedVersion }
        end
        error('unexpected policy row query: ' .. sql)
      end
      function tx.many(sql)
        assert(sql:find('synex_group_policy_rules', 1, true))
        reads = reads + 1
        return {{ rule_key = 'rule_alpha', priority = 10, effect = ruleEffect,
          action_pattern = 'groups.members.promote', subject_kind = 'character',
          scope_kind = 'group', scope_ref = '', condition_json = nil }}
      end
      function tx.affected() return 1 end
      function tx.query() return { affectedRows = 1 } end

      local input = { group_id = 'group_alpha', action = 'groups.members.promote',
        actor_membership = { id = 21 }, parameters = {}, scope = 'group' }
      local first = assert(handlers.evaluateStoredPolicy(tx, input, runtime))
      local second = assert(handlers.evaluateStoredPolicy(tx, input, runtime))
      assert(first.decision == 'ALLOW' and second.decision == 'ALLOW' and reads == 1)
      assert(cache:snapshot().hits == 1)

      version, verifiedVersion, ruleEffect = 2, 2, 'deny'
      local revised = assert(handlers.evaluateStoredPolicy(tx, input, runtime))
      assert(revised.decision == 'DENY' and reads == 2)

      verifiedVersion = 3
      local stale, staleError = handlers.evaluateStoredPolicy(tx, input, runtime)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(cache:get('policy_rules', 'group_alpha:groups.members.promote', 2) == nil)

      verifiedVersion = 2
      assert(cache:put('policy_rules', 'group_alpha:groups.members.promote', 2, {{
        rule_key = 'stale', priority = 1, effect = 'allow',
        action_pattern = 'groups.members.promote', subject_kind = 'character',
        scope_kind = 'group', scope_ref = ''
      }}))
      local changed = assert(handlers.execute.policies_set(tx, {
        actor_character_id = 'character_actor', group_id = 'group_alpha',
        action = 'groups.members.promote', expected_version = 2,
        definition = { display_name = 'Promotion', default_effect = 'deny', rules = {} },
        reason = 'policy_update'
      }, runtime))
      assert(changed.version == 3)
      assert(cache:get('policy_rules', 'group_alpha:groups.members.promote', 2) == nil)
      local metrics = cache:snapshot()
      assert(metrics.invalidations >= 2)
      return table.concat({ first.decision, revised.decision, reads,
        changed.version, staleError.code }, ':')
    `);
    assert.equal(result, 'ALLOW:DENY:2:3:CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});

test('policy rank conditions perform one bounded rank read for the complete rule set', async () => {
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
      'server.persistence.governance_policies',
      'resources/synex_groups/server/persistence/governance_policies.lua',
    );
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local handlers = require('server.persistence.governance_policies')(Foundation)
      local rankReads = 0
      local runtime = { jsonDecode = function()
        return { actor_rank_above_target = true }
      end }
      function runtime.requireGroup(_, groupId)
        return { id = 10, public_id = groupId, status = 'active',
          lifecycle_state = 'ACTIVE', version = 1 }
      end
      local rules = {}
      for index = 1, 64 do
        rules[index] = {
          rule_key = ('rank_rule_%02d'):format(index), priority = 100 - index,
          effect = 'allow', action_pattern = 'groups.members.promote',
          subject_kind = 'character', scope_kind = 'group', scope_ref = '',
          condition_json = 'rank-condition'
        }
      end
      local tx = {}
      function tx.one(sql)
        if sql:find('policy_key', 1, true) then
          return { id = 44, public_id = 'policy_rank', default_effect = 'deny', version = 7 }
        end
        if sql:find('actor_grade.rank_value', 1, true) then
          rankReads = rankReads + 1
          return { actor_rank = 10, target_rank = 5 }
        end
        if sql:find('SELECT version FROM synex_group_policies', 1, true) then
          return { version = 7 }
        end
        error('unexpected query')
      end
      function tx.many() return rules end
      local evaluated = assert(handlers.evaluateStoredPolicy(tx, {
        group_id = 'group_alpha', action = 'groups.members.promote', scope = 'group',
        actor_membership = { id = 21, group_id = 10, lifecycle_state = 'ACTIVE' },
        target_membership = { id = 22, group_id = 10, lifecycle_state = 'ACTIVE' },
        parameters = {}
      }, runtime))
      assert(evaluated.decision == 'ALLOW' and #evaluated.trace == 64)
      assert(rankReads == 1)
      return rankReads
    `);
    assert.equal(result, 1);
  } finally {
    engine.global.close();
  }
});
