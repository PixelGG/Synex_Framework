import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();
const workflowModules = [
  'workflows_shared',
  'workflows_duty',
  'workflows_assignments',
  'workflows_applications',
  'workflows_proposals',
  'workflows',
] as const;
const membershipModules = [
  'memberships_shared',
  'memberships_read',
  'memberships_invitations',
  'memberships_lifecycle',
  'memberships_access',
  'memberships_reporting',
  'memberships',
] as const;

function persistencePath(name: string): string {
  return `resources/synex_groups/server/persistence/${name}.lua`;
}

async function readPersistenceModules(names: readonly string[]): Promise<string> {
  return (await Promise.all(names.map((name) =>
    readFile(path.join(root, persistencePath(name)), 'utf8')))).join('\n');
}

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

async function bootstrap(engine: LuaEngine): Promise<void> {
  await preload(engine, 'server.domain.constants', 'resources/synex_groups/server/domain/constants.lua');
  await preload(engine, 'server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua');
  for (const name of [...workflowModules, ...membershipModules]) {
    await preload(engine, `server.persistence.${name}`, persistencePath(name));
  }
  const foundation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'foundation.lua'),
    'utf8',
  );
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    Workflows = require('server.persistence.workflows')(Foundation)
    Memberships = require('server.persistence.memberships')(Foundation)

    function workflowRuntime(overrides)
      overrides = overrides or {}
      local sequence = 0
      local runtime = {}
      function runtime.id(namespace)
        sequence = sequence + 1
        return namespace .. '_' .. string.format('%08d', sequence)
      end
      function runtime.reason(_, fallback) return fallback end
      function runtime.success(entityId, entityType, status, version)
        return {
          entity_id = entityId, entity_type = entityType, status = status,
          version = version, replayed = false
        }
      end
      function runtime.effect(action, entityType, entityId, groupId, characterId,
          before, after, reason, version)
        return {
          action = action, entityType = entityType, entityId = entityId,
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = reason, version = version
        }
      end
      function runtime.jsonEncode() return '{}' end
      function runtime.jsonDecode() return {} end
      function runtime.authorize(_, groupId, characterId, capability)
        if overrides.authorize then
          return overrides.authorize(groupId, characterId, capability)
        end
        return {
          id = 21, public_id = 'member_actor_0001', character_id = characterId,
          group_id = 10, group_public_id = groupId, lifecycle_state = 'ACTIVE'
        }
      end
      function runtime.requireGroup(_, groupId)
        if overrides.requireGroup then return overrides.requireGroup(groupId) end
        return {
          id = 10, public_id = groupId, status = 'active',
          lifecycle_state = 'ACTIVE', version = 4
        }
      end
      function runtime.requireMembership(_, membershipId)
        if overrides.requireMembership then return overrides.requireMembership(membershipId) end
        return {
          id = 31, public_id = membershipId, group_id = 10,
          group_public_id = 'group_alpha_0001', character_id = 'character_target_0001',
          lifecycle_state = 'ACTIVE', version = 1, profile_version = 1
        }
      end
      function runtime.touchGroup() return true end
      function runtime.resolveMembershipTransitionPolicy(_, input)
        if overrides.resolveMembershipTransitionPolicy then
          return overrides.resolveMembershipTransitionPolicy(input)
        end
        return {
          configured = false,
          group_id = input.group_id,
          from_status = input.from_status,
          to_status = input.to_status,
          allowed = true,
          required_capability = 'synex.groups.members.manage',
          approval_required = false,
          reason_required = true
        }
      end
      function runtime.verifyApprovedOperation(context, operation, request, groupId)
        if overrides.verifyApprovedOperation then
          return overrides.verifyApprovedOperation(context, operation, request, groupId)
        end
        return nil, Foundation.domainError('APPROVAL_REQUIRED',
          'The operation requires a validated proposal execution context.')
      end
      function runtime.validateApproved()
        if overrides.validateApproved then return overrides.validateApproved() end
        return true
      end
      function runtime.invokeApproved()
        if overrides.invokeApproved then return overrides.invokeApproved() end
        return runtime.success('target_entity_0001', 'group', 'active', 2), nil, {}
      end
      return runtime
    end
  `);
}

function functionBody(source: string, name: string, nextName: string): string {
  const start = source.indexOf(`function handlers.execute.${name}`);
  const end = source.indexOf(`function handlers.execute.${nextName}`, start + 1);
  assert.notEqual(start, -1, `${name} handler is missing`);
  assert.notEqual(end, -1, `${nextName} handler is missing`);
  return source.slice(start, end);
}

test('workflow and membership catalogs stay server-only, transactional, and CAS guarded', async () => {
  const [workflows, memberships] = await Promise.all([
    readPersistenceModules(workflowModules),
    readPersistenceModules(membershipModules),
  ]);
  for (const source of [workflows, memberships]) {
    assert.doesNotMatch(
      source,
      /\bMySQL\b|oxmysql|RegisterNetEvent|RegisterServerEvent|TriggerClientEvent|PerformHttpRequest/u,
    );
    assert.doesNotMatch(source, /:format\s*\(\s*request\./u);
    assert.match(source, /FOR UPDATE/u);
  }

  const accept = functionBody(memberships, 'members_accept', 'members_transition');
  assert.match(accept, /WHERE id = \? AND status = 'pending' AND version = \?/u);
  assert.match(accept, /grade\.grade_key <> 'owner'/u);
  const review = functionBody(workflows, 'applications_review', 'applications_withdraw');
  assert.match(review, /WHERE id = \?[\s\S]*?version = \?/u);
  assert.match(review, /grade\.grade_key <> 'owner'/u);
  const dutyUpdate = functionBody(workflows, 'duty_update', 'duty_stop');
  assert.match(dutyUpdate, /WHERE id = \? AND status = 'open' AND version = \?/u);
  const dutyStop = functionBody(workflows, 'duty_stop', 'assignments_create');
  assert.match(dutyStop, /WHERE id = \? AND status = 'open' AND version = \?/u);
  const leave = functionBody(workflows, 'assignments_leave', 'assignments_complete');
  assert.match(leave, /WHERE id = \? AND status = 'active' AND version = \?/u);
  const complete = functionBody(workflows, 'assignments_complete', 'assignments_cancel');
  assert.match(complete, /closeAssignment\(tx, request, runtime, 'completed', context\)/u);
  assert.match(
    workflows,
    /local function closeAssignment[\s\S]*?synex_group_duty_events[\s\S]*?synex_group_assignment_members/u,
  );
  const withdraw = functionBody(workflows, 'applications_withdraw', 'proposals_create');
  assert.match(withdraw, /status IN \('submitted', 'reviewing'\)[\s\S]*?version = \?/u);
  const approve = functionBody(workflows, 'proposals_approve', 'proposals_reject');
  assert.match(approve, /decideProposal/u);

  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    assert.equal(
      await engine.doString(`
        local workflowNames = {
          'duty_start', 'duty_update', 'duty_stop', 'assignments_create',
          'assignments_join', 'assignments_leave', 'assignments_complete',
          'assignments_cancel', 'applications_submit', 'applications_review',
          'applications_withdraw', 'proposals_create', 'proposals_approve',
          'proposals_reject'
        }
        local membershipNames = { 'members_decline', 'members_revoke_invite' }
        for _, name in ipairs(workflowNames) do
          assert(type(Workflows.execute[name]) == 'function')
        end
        for _, name in ipairs(membershipNames) do
          assert(type(Memberships.execute[name]) == 'function')
        end
        return #workflowNames + #membershipNames
      `),
      16,
    );
  } finally {
    engine.global.close();
  }
});

test('assignment joins enforce the persisted validity window and leaves preserve duty integrity', async () => {
  const source = await readPersistenceModules(workflowModules);
  const join = functionBody(source, 'assignments_join', 'assignments_leave');
  assert.match(join, /valid_from\s*<=\s*CURRENT_TIMESTAMP\(6\)/u);
  assert.match(join, /valid_until\s+IS NULL[\s\S]*?valid_until\s*>\s*CURRENT_TIMESTAMP\(6\)/u);

  const leave = functionBody(source, 'assignments_leave', 'applications_submit');
  assert.match(
    leave,
    /synex_group_duty_sessions/u,
    'leaving an assignment must close its linked duty with history or reject while duty is open',
  );
});

test('membership terminal transitions retain an explicit duty event before closing sessions', async () => {
  const source = await readPersistenceModules(membershipModules);
  const transition = functionBody(source, 'members_transition', 'members_set_grade');
  assert.match(transition, /INSERT INTO synex_group_duty_events/u);
  assert.match(transition, /event_type/u);
  assert.match(transition, /membership_terminal/u);
});

test('generic membership transitions cannot bypass invitation or application workflows', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes, authorizations, policyReads = 0, 0, 0
      local tx = {}
      function tx.one() error('workflow-owned transitions must not query policy state') end
      function tx.affected() writes = writes + 1 return 1 end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      local runtime = workflowRuntime({
        requireMembership = function(membershipId)
          return {
            id = 31, public_id = membershipId, group_id = 10,
            group_public_id = 'group_alpha_0001',
            character_id = 'character_target_0001',
            lifecycle_state = 'INVITED', version = 1, profile_version = 1
          }
        end,
        authorize = function(_, _, capability)
          authorizations = authorizations + 1
          assert(capability == 'synex.groups.members.manage')
          return { id = 21 }
        end,
        resolveMembershipTransitionPolicy = function()
          policyReads = policyReads + 1
          error('workflow-owned transitions must not resolve generic policy state')
        end
      })
      local value, failure = Memberships.execute.members_transition(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'ACTIVE', reason = 'bypass_attempt'
      }, runtime)
      assert(value == nil and failure.code == 'INVALID_TRANSITION')
      assert(authorizations == 1 and policyReads == 0 and writes == 0)
      return failure.code
    `);
    assert.equal(result, 'INVALID_TRANSITION');
  } finally {
    engine.global.close();
  }
});

test('membership transitions emit the stable activated, suspended, and terminal domain event names', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function transition(target, current)
        local tx = {}
        function tx.one(sql)
          if sql:find('synex_group_type_membership_states', 1, true) then
            return { state_key = target }
          end
          if sql:find('group_type.active_membership_limit', 1, true) then
            return { membership_limit = nil, active_membership_limit = nil }
          end
          if sql:find('FROM synex_group_membership_grades AS assigned', 1, true)
              and sql:find('control.member_limit', 1, true) then
            return { id = 41, member_limit = nil }
          end
          if sql:find('synex_group_duty_sessions', 1, true) then return nil end
          error('unexpected transition query: ' .. sql)
        end
        function tx.affected() return 1 end
        function tx.query() return { affectedRows = 1 } end
        local runtime = workflowRuntime({
          requireMembership = function(membershipId)
            return {
              id = 31, public_id = membershipId, group_id = 10,
              group_public_id = 'group_alpha_0001',
              character_id = 'character_target_0001',
              lifecycle_state = current, version = 1, profile_version = 1
            }
          end
        })
        runtime.enforceMembershipActivation = function() return true end
        local value, failure, effects = Memberships.execute.members_transition(tx, {
          actor_character_id = 'character_actor_0001',
          membership_id = 'membership_target_0001', expected_version = 1,
          status = target, reason = 'lifecycle_test'
        }, runtime)
        assert(value and failure == nil and #effects == 1)
        return effects[1].action
      end

      local activated = transition('ACTIVE', 'SUSPENDED')
      local suspended = transition('SUSPENDED', 'ACTIVE')
      local terminated = transition('TERMINATED', 'ACTIVE')
      local banned = transition('BANNED', 'ACTIVE')
      assert(activated == 'membership.activated')
      assert(suspended == 'membership.suspended')
      assert(terminated == 'membership.terminated')
      assert(banned == 'membership.terminated')
      return table.concat({ activated, suspended, terminated, banned }, ':')
    `);
    assert.equal(
      result,
      'membership.activated:membership.suspended:membership.terminated:membership.terminated',
    );
  } finally {
    engine.global.close();
  }
});

test('membership type states fail closed and leave transitions revoke live authority without terminal cleanup', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = 0
      local rejectedTx = {}
      function rejectedTx.one(sql)
        if sql:find('synex_group_type_membership_states', 1, true) then return nil end
        error('unexpected type-state query: ' .. sql)
      end
      function rejectedTx.affected() writes = writes + 1 return 1 end
      function rejectedTx.query() writes = writes + 1 return { affectedRows = 1 } end
      local denied, deniedError = Memberships.execute.members_transition(rejectedTx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'LEAVE', reason = 'approved_leave'
      }, workflowRuntime())
      assert(denied == nil and deniedError.code == 'INVALID_TRANSITION' and writes == 0)

      local statements, affectedParameters = {}, {}
      local tx = {}
      function tx.one(sql)
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'LEAVE' }
        end
        if sql:find('synex_group_duty_sessions', 1, true) then
          return { id = 51, public_id = 'duty_session_0001', state_key = 'on_duty',
            assignment_id = 61, metadata_json = '{}', version = 2 }
        end
        error('unexpected leave query: ' .. sql)
      end
      function tx.affected(sql, parameters)
        statements[#statements + 1] = sql
        affectedParameters[#affectedParameters + 1] = parameters
        return 1
      end
      function tx.query(sql)
        statements[#statements + 1] = sql
        return { affectedRows = 1 }
      end
      local changed, changeError, effects = Memberships.execute.members_transition(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'LEAVE', reason = 'approved_leave'
      }, workflowRuntime())
      assert(changeError == nil and changed.status == 'LEAVE' and #effects == 2)
      assert(affectedParameters[1][1] == 'suspended')
      local joined = table.concat(statements, string.char(10))
      assert(joined:find('UPDATE synex_group_duty_sessions', 1, true))
      assert(joined:find('UPDATE synex_group_assignment_members', 1, true))
      assert(joined:find('UPDATE synex_group_delegations', 1, true))
      assert(not joined:find('UPDATE synex_group_membership_roles', 1, true))
      assert(not joined:find('DELETE FROM synex_group_primary_memberships', 1, true))
      return deniedError.code .. ':' .. changed.status
    `);
    assert.equal(result, 'INVALID_TRANSITION:LEAVE');
  } finally {
    engine.global.close();
  }
});

test('membership activation locks and enforces group and assigned-grade capacity', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function suspendedRuntime()
        return workflowRuntime({
          requireMembership = function(membershipId)
            return {
              id = 31, public_id = membershipId, group_id = 10,
              group_public_id = 'group_alpha_0001',
              character_id = 'character_target_0001',
              lifecycle_state = 'SUSPENDED', version = 1, profile_version = 1
            }
          end
        })
      end
      local request = {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'ACTIVE', reason = 'reactivated'
      }

      local groupWrites = 0
      local groupTx = {}
      function groupTx.one(sql)
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'ACTIVE' }
        end
        if sql:find('group_type.active_membership_limit', 1, true) then
          assert(sql:find('FOR UPDATE', 1, true))
          return { membership_limit = 10, active_membership_limit = 1 }
        end
        if sql:find('COUNT(*) AS count', 1, true) then return { count = 1 } end
        error('unexpected group-capacity query: ' .. sql)
      end
      function groupTx.affected() groupWrites = groupWrites + 1 return 1 end
      function groupTx.query() groupWrites = groupWrites + 1 return { affectedRows = 1 } end
      local groupValue, groupError = Memberships.execute.members_transition(
        groupTx, request, suspendedRuntime())
      assert(groupValue == nil and groupError.code == 'MEMBER_LIMIT_REACHED')
      assert(groupWrites == 0)

      local gradeWrites = 0
      local gradeTx = {}
      function gradeTx.one(sql)
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'ACTIVE' }
        end
        if sql:find('group_type.active_membership_limit', 1, true) then
          assert(sql:find('FOR UPDATE', 1, true))
          return { membership_limit = nil, active_membership_limit = nil }
        end
        if sql:find('FROM synex_group_membership_grades AS assigned', 1, true)
            and sql:find('control.member_limit', 1, true) then
          assert(sql:find('FOR UPDATE', 1, true))
          return { id = 41, member_limit = 1 }
        end
        if sql:find('COUNT(*) AS count', 1, true) then return { count = 1 } end
        error('unexpected grade-capacity query: ' .. sql)
      end
      function gradeTx.affected() gradeWrites = gradeWrites + 1 return 1 end
      function gradeTx.query() gradeWrites = gradeWrites + 1 return { affectedRows = 1 } end
      local gradeValue, gradeError = Memberships.execute.members_transition(
        gradeTx, request, suspendedRuntime())
      assert(gradeValue == nil and gradeError.code == 'GRADE_CAPACITY_REACHED')
      assert(gradeWrites == 0)
      return groupError.code .. ':' .. gradeError.code
    `);
    assert.equal(result, 'MEMBER_LIMIT_REACHED:GRADE_CAPACITY_REACHED');
  } finally {
    engine.global.close();
  }
});

test('membership transition policies enforce exact capability, reason, allow, and internal approval gates', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes, capabilities = 0, {}
      local tx = {}
      function tx.one() return nil end
      function tx.affected() writes = writes + 1 return 1 end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      local request = {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'SUSPENDED'
      }
      local function policy(overrides)
        local value = {
          configured = true, policy_id = 'transition_policy_0001',
          group_id = 'group_alpha_0001', from_status = 'ACTIVE',
          to_status = 'SUSPENDED', allowed = true,
          required_capability = 'synex.groups.members.suspend',
          approval_required = false, reason_required = false, version = 1
        }
        for key, item in pairs(overrides or {}) do value[key] = item end
        return value
      end
      local deniedRuntime = workflowRuntime({
        resolveMembershipTransitionPolicy = function() return policy({ allowed = false }) end,
        authorize = function(_, _, capability)
          capabilities[#capabilities + 1] = capability
          return { id = 21 }
        end
      })
      local denied, deniedError = Memberships.execute.members_transition(
        tx, request, deniedRuntime)
      assert(denied == nil and deniedError.code == 'INVALID_TRANSITION')
      assert(capabilities[1] == 'synex.groups.members.suspend' and writes == 0)

      local reasonRuntime = workflowRuntime({
        resolveMembershipTransitionPolicy = function()
          return policy({ reason_required = true })
        end
      })
      local missingReason, reasonError = Memberships.execute.members_transition(
        tx, request, reasonRuntime)
      assert(missingReason == nil and reasonError.code == 'VALIDATION_FAILED')

      local approvalRuntime = workflowRuntime({
        resolveMembershipTransitionPolicy = function()
          return policy({ approval_required = true })
        end
      })
      local forged, forgedError = Memberships.execute.members_transition(
        tx, request, approvalRuntime,
        { approvedProposalId = 'proposal_forged_0001' })
      assert(forged == nil and forgedError.code == 'APPROVAL_REQUIRED')

      local verifiedRuntime = workflowRuntime({
        resolveMembershipTransitionPolicy = function()
          return policy({ approval_required = true })
        end,
        verifyApprovedOperation = function(_, operation, exactRequest, groupId)
          assert(operation == 'members_transition' and exactRequest == request)
          assert(groupId == 'group_alpha_0001')
          return true, nil
        end
      })
      local passedApproval, postApprovalError = Memberships.execute.members_transition(
        tx, request, verifiedRuntime, { internal = true })
      assert(passedApproval == nil and postApprovalError.code == 'INVALID_TRANSITION')
      assert(writes == 0)
      return table.concat({ deniedError.code, reasonError.code,
        forgedError.code, postApprovalError.code }, ':')
    `);
    assert.equal(
      result,
      'INVALID_TRANSITION:VALIDATION_FAILED:APPROVAL_REQUIRED:INVALID_TRANSITION',
    );
  } finally {
    engine.global.close();
  }
});

test('approval-controlled grade changes require a validated proposal execution context', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = 0
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_grades AS grade', 1, true) then
          return { id = 71, public_id = 'grade_target_0001', grade_key = 'command',
            rank_value = 50, member_limit = nil, promotion_requires_approval = 1 }
        end
        if sql:find('SELECT grade.rank_value', 1, true) then
          return { rank_value = 100 }
        end
        if sql:find('SELECT grade.public_id', 1, true) then
          return { public_id = 'grade_current_0001', grade_key = 'member', rank_value = 10 }
        end
        error('unexpected grade query: ' .. sql)
      end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      function tx.affected() writes = writes + 1 return 1 end
      local request = {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', grade_id = 'grade_target_0001',
        expected_version = 1, reason = 'approved_promotion'
      }
      local denied, deniedError = Memberships.execute.members_set_grade(
        tx, request, workflowRuntime())
      assert(denied == nil and deniedError.code == 'APPROVAL_REQUIRED' and writes == 0)
      local forged, forgedError = Memberships.execute.members_set_grade(
        tx, request, workflowRuntime(), { approvedProposalId = 'proposal_alpha_0001' })
      assert(forged == nil and forgedError.code == 'APPROVAL_REQUIRED' and writes == 0)
      local approvedRuntime = workflowRuntime({
        verifyApprovedOperation = function(_, operation, approvedRequest, groupId)
          assert(operation == 'members_set_grade')
          assert(approvedRequest == request and groupId == 'group_alpha_0001')
          return true, nil
        end
      })
      local changed, changeError = Memberships.execute.members_set_grade(
        tx, request, approvedRuntime, { internal = true })
      assert(changeError == nil and changed.entity_id == 'membership_target_0001')
      assert(writes >= 4)
      return deniedError.code .. ':' .. changed.status
    `);
    assert.equal(result, 'APPROVAL_REQUIRED:ACTIVE');
  } finally {
    engine.global.close();
  }
});

test('applications fail closed without a registered matching schema', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = 0
      local tx = {}
      function tx.one(sql)
        if sql:find('SELECT membership.id', 1, true) then return nil end
        if sql:find('FROM synex_group_applications', 1, true) then return nil end
        if sql:find('application', 1, true) and sql:find('schema', 1, true) then return nil end
        if sql:find('synex_group_types', 1, true) then return nil end
        return nil
      end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      local value, failure = Workflows.execute.applications_submit(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        schema_version = 1, data = { unregistered_free_form_field = 'must-not-persist' }
      }, workflowRuntime())
      assert(value == nil and type(failure) == 'table')
      assert(failure.code == 'VALIDATION_FAILED')
      assert(writes == 0)
      return failure.code
    `);
    assert.equal(result, 'VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('application approval applies group and grade capacity before durable membership activation', async () => {
  const [workflowSource, activation] = await Promise.all([
    readPersistenceModules(workflowModules),
    readFile(path.join(root, persistencePath('memberships_shared')), 'utf8'),
  ]);
  const review = functionBody(workflowSource, 'applications_review', 'proposals_create');
  assert.match(review, /activateWorkflowMembership/u);
  assert.match(activation, /group_type\.membership_limit|group_type[\s\S]*?membership_limit/u);
  assert.match(activation, /group_type\.active_membership_limit/u);
  assert.match(
    activation,
    /lifecycle_state IN\s*\('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE'\)/u,
  );
  assert.match(activation, /lifecycle_state = 'ACTIVE'/u);
  assert.match(activation, /control\.member_limit|member_limit/u);
  assert.match(review, /group_status|group_lifecycle|lifecycle_state/u);
  assert.match(activation, /MEMBER_LIMIT_REACHED/u);
  assert.match(activation, /GRADE_CAPACITY_REACHED/u);
});

test('approval proposals cannot execute a payload against a different group scope', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = 0
      local tx = {}
      function tx.one(sql)
        if sql:find('SELECT CASE', 1, true) then return { valid = 1 } end
        if sql:find('synex_group_read_model_versions', 1, true) then
          return { model_version = 7 }
        end
        return nil
      end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      local value, failure = Workflows.execute.proposals_create(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        action = 'group.archive', payload = {
          group_id = 'group_bravo_0002', expected_version = 1,
          idempotency_key = 'approved-target-0001', reason = 'cross-scope'
        },
        required_approvals = 2, expires_at = '2099-01-01T00:00:00Z',
        reason = 'approval_requested'
      }, workflowRuntime())
      assert(value == nil and type(failure) == 'table')
      assert(failure.code == 'VALIDATION_FAILED' or failure.code == 'INVALID_SCOPE')
      assert(writes == 0)
      return failure.code
    `);
    assert.match(String(result), /^(?:VALIDATION_FAILED|INVALID_SCOPE)$/u);
  } finally {
    engine.global.close();
  }
});

test('stale proposal decisions stop before approval persistence or execution', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes, invoked = 0, 0
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_proposals AS proposal', 1, true) then
          return {
            id = 41, public_id = 'proposal_alpha_0001', group_id = 10,
            group_public_id = 'group_alpha_0001', status = 'pending',
            required_approvals = 2, created_by_membership_id = 99,
            version = 3, proposal_type = 'group.archive', payload_json = '{}',
            expected_group_version = 7, expired = 0
          }
        end
        error('stale decisions must not continue to another query')
      end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      local runtime = workflowRuntime({
        invokeApproved = function() invoked = invoked + 1 end
      })
      local value, failure = Workflows.execute.proposals_approve(tx, {
        actor_character_id = 'character_actor_0001',
        proposal_id = 'proposal_alpha_0001', expected_version = 2,
        reason = 'stale-approval'
      }, runtime, { caller = 'test_probe' })
      assert(value == nil and failure.code == 'CONCURRENT_MODIFICATION')
      assert(writes == 0 and invoked == 0)
      return failure.code
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});

test('proposal execution revalidates quorum authority and invokes the immutable execution hook only at quorum', async () => {
  const [workflowSource, approvedOperationsSource, serviceSource] = await Promise.all([
    readPersistenceModules(workflowModules),
    readFile(path.join(root,
      'resources/synex_groups/server/persistence/approved_operations.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/service.lua'), 'utf8'),
  ]);
  const approval = functionBody(workflowSource, 'proposals_approve', 'proposals_reject');
  const decisionStart = workflowSource.indexOf('local function decideProposal');
  const approvalStart = workflowSource.indexOf('function handlers.execute.proposals_approve');
  const decision = workflowSource.slice(decisionStart, approvalStart);
  assert.match(decision, /currentApprovals[\s\S]*synex\.groups\.approvals\.manage/u);
  assert.match(decision, /#currentApprovals\s*<\s*tonumber\(proposal\.required_approvals\)/u);
  assert.match(decision, /runtime\.invokeApproved/u);
  assert.match(approvedOperationsSource, /beforeProposalExecute/u);
  assert.match(approvedOperationsSource, /cannot alter approved content/u);
  assert.match(serviceSource, /before_proposal_execute/u);
  assert.doesNotMatch(
    serviceSource,
    /proposals_approve\s*=\s*'before_proposal_execute'/u,
    'the execution hook must not run for non-quorum approval votes',
  );
  assert.match(approval, /decideProposal/u);
});
