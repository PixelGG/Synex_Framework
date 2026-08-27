import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('capability access composes every normalized source and preserves stored policy context', async () => {
  const [foundationSource, cacheSource, accessSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/definition_cache.lua'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/capability_access.lua'),
      'utf8',
    ),
  ]);
  const factory = new LuaFactory();
  const engine = await factory.createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      package.preload['server.persistence.definition_cache'] = assert(load(
        ${JSON.stringify(cacheSource)}, '@server/persistence/definition_cache.lua'))
      local createAccess = assert(load(${JSON.stringify(accessSource)},
        '@server/persistence/capability_access.lua'))()(Foundation)
      local capturedEvaluation
      local capturedPolicy
      local runtime = { marker = 'runtime-instance' }
      local evaluator = {}
      function evaluator:evaluate(request)
        capturedEvaluation = request
        return { allowed = true, reason = 'MATCHED_ALLOW', trace = {} }, nil
      end
      local access = createAccess({
        evaluator = evaluator,
        getStoredPolicyEvaluator = function()
          return function(_, request, suppliedRuntime)
            capturedPolicy = request
            assert(suppliedRuntime == runtime)
            return { decision = 'ALLOW', policy_id = 'policy_0001' }, nil
          end
        end,
        getRuntime = function() return runtime end
      })
      local tx = {}
      function tx.one(sql, parameters)
        if sql:find('FROM synex_group_memberships AS membership', 1, true) then
          assert(sql:find('FOR UPDATE', 1, true))
          assert(parameters[1] == 'group_0001' and parameters[2] == 'character_0001')
          return {
            id = 11, public_id = 'membership_0001', version = 4,
            lifecycle_state = 'ACTIVE', group_internal_id = 7,
            definition_revision = 9,
            grade_internal_id = 3, grade_public_id = 'grade_0001'
          }
        end
        if sql:find('FROM synex_group_read_model_versions', 1, true) then
          assert(sql:find('FOR UPDATE', 1, true) and parameters[1] == 7)
          return { model_version = 9 }
        end
        error('unexpected capability source row query: ' .. sql)
      end
      function tx.many(sql, parameters)
        if sql:find('synex_group_default_capabilities', 1, true) then
          assert(parameters[1] == 7)
          return {{
            id = 1, capability_pattern = 'synex.groups.directory.*',
            effect = 'allow', scope_kind = 'group', scope_ref = '', delegable = 1
          }}
        end
        if sql:find('synex_group_grade_capabilities', 1, true) then
          assert(parameters[1] == 3)
          return {{
            id = 2, capability_pattern = 'synex.groups.members.*',
            effect = 'deny', scope_kind = 'subtree', scope_ref = '', delegable = 0
          }}
        end
        if sql:find('synex_group_membership_roles', 1, true) then
          assert(parameters[1] == 11)
          return {{
            assignment_public_id = 'assignment_0001', role_public_id = 'role_0001',
            capability_id = 3, capability_pattern = 'synex.groups.roles.read',
            effect = 'allow', scope_kind = 'custom', scope_ref = 'subtree',
            delegable = 1,
            valid_from_unix = 1700000000000, valid_until_unix = 1700003600000
          }}
        end
        if sql:find('synex_group_delegations', 1, true) then
          assert(parameters[1] == 11)
          return {{
            public_id = 'delegation_0001', capability_pattern = 'synex.groups.duty.start',
            scope_kind = 'group', scope_ref = '', valid_from_unix = 1700000000,
            valid_until_unix = 1700003600
          }}
        end
        if sql:find('synex_group_membership_capabilities', 1, true) then
          assert(parameters[1] == 11)
          return {{
            id = 4, capability_pattern = 'synex.groups.directory.private',
            effect = 'allow', scope_kind = 'group', scope_ref = '',
            delegable = 0,
            valid_from_unix = 1700000000, valid_until_unix = 1700003600
          }}
        end
        error('unexpected capability source query: ' .. sql)
      end
      local target = { public_id = 'membership_target' }
      local parameters = { assignment_id = 'assignment_target' }
      local membership, accessError, evaluation = access.authorize(
        tx, 'group_0001', 'character_0001', 'synex.groups.directory.read',
        'relationship', { target_membership = target, parameters = parameters })
      assert(accessError == nil and membership.public_id == 'membership_0001')
      assert(evaluation.allowed == true and evaluation.membership == membership)
      assert(capturedEvaluation.capability == 'synex.groups.directory.read')
      assert(capturedEvaluation.scope.groupId == 'group_0001')
      assert(#capturedEvaluation.defaults == 1)
      assert(capturedEvaluation.defaults[1].id == 'group:1')
      assert(capturedEvaluation.defaults[1].delegable == true)
      assert(capturedEvaluation.defaults[1].scope.mode == 'group')
      assert(capturedEvaluation.grade.id == 'grade_0001')
      assert(capturedEvaluation.grade.rules[1].scope.mode == 'subtree')
      assert(#capturedEvaluation.roles == 1)
      assert(capturedEvaluation.roles[1].validFrom == 1700000000)
      assert(capturedEvaluation.roles[1].rules[1].scope.mode == 'subtree')
      assert(capturedEvaluation.roles[1].rules[1].delegable == true)
      assert(capturedEvaluation.membership.id == 'membership_0001')
      assert(capturedEvaluation.membership.rules[1].id == 'membership:4')
      assert(capturedEvaluation.delegations[1].id == 'delegation_0001')
      assert(capturedEvaluation.delegations[1].rules[1].delegable == false)
      assert(capturedPolicy.group_id == 'group_0001')
      assert(capturedPolicy.action == 'synex.groups.directory.read')
      assert(capturedPolicy.actor_membership == membership)
      assert(capturedPolicy.target_membership == target)
      assert(capturedPolicy.parameters == parameters)
      assert(capturedPolicy.scope == 'relationship')
      return 'all-sources'
    `);
    assert.equal(result, 'all-sources');
  } finally {
    engine.global.close();
  }
});
