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

async function bootstrap(engine: LuaEngine): Promise<void> {
  await preload(engine, 'server.domain.constants',
    'resources/synex_groups/server/domain/constants.lua');
  await preload(engine, 'server.domain.lifecycle',
    'resources/synex_groups/server/domain/lifecycle.lua');
  for (const name of [
    'memberships_shared',
    'memberships_invitations',
    'memberships_lifecycle',
    'memberships_access',
    'workflows_shared',
    'workflows_duty',
    'workflows_assignments',
    'workflows_applications',
    'governance_shared',
    'governance_capabilities',
    'organizations_shared',
    'organizations_structure',
  ]) {
    await preload(
      engine,
      `server.persistence.${name}`,
      `resources/synex_groups/server/persistence/${name}.lua`,
    );
  }
  await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await engine.doString(`
    Foundation = require 'server.foundation'
    Validation = require('server.validation')(Foundation)
    MembershipInvitations = require('server.persistence.memberships_invitations')(Foundation)
    MembershipLifecycle = require('server.persistence.memberships_lifecycle')(Foundation)
    MembershipAccess = require('server.persistence.memberships_access')(Foundation)
    Duty = require('server.persistence.workflows_duty')(Foundation)
    Assignments = require('server.persistence.workflows_assignments')(Foundation)
    Applications = require('server.persistence.workflows_applications')(Foundation)
    GovernanceCapabilities = require('server.persistence.governance_capabilities')(Foundation)
    OrganizationStructure = require('server.persistence.organizations_structure')(Foundation).execute

    function coverageRuntime(overrides)
      overrides = overrides or {}
      local sequence = 0
      local runtime = { calls = { authorize = 0, touch = 0 } }
      function runtime.id(namespace)
        sequence = sequence + 1
        return namespace .. '_' .. string.format('%08d', sequence)
      end
      function runtime.reason(_, fallback) return fallback end
      function runtime.jsonEncode() return '{}' end
      function runtime.jsonDecode() return { application_schema = {} } end
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
      function runtime.authorize(tx, groupId, actorId, capability, scope, policyContext)
        runtime.calls.authorize = runtime.calls.authorize + 1
        if overrides.authorize then
          return overrides.authorize(tx, groupId, actorId, capability, scope, policyContext)
        end
        return {
          id = 21, public_id = 'membership_actor_0001',
          character_id = actorId, group_id = 10,
          group_public_id = groupId, lifecycle_state = 'ACTIVE'
        }, nil, { delegable = true }
      end
      function runtime.requireGroup(tx, groupId, lock)
        if overrides.requireGroup then return overrides.requireGroup(tx, groupId, lock) end
        return {
          id = 10, public_id = groupId, status = 'active',
          lifecycle_state = 'ACTIVE', version = 1,
          type_schema_version = 1,
          type_metadata_json = '{"application_schema":{}}'
        }, nil
      end
      function runtime.requireMembership(tx, membershipId, lock)
        if overrides.requireMembership then
          return overrides.requireMembership(tx, membershipId, lock)
        end
        return {
          id = 31, public_id = membershipId, group_id = 10,
          group_public_id = 'group_alpha_0001',
          character_id = 'character_offline_0001',
          lifecycle_state = 'ACTIVE', version = 1, profile_version = 1
        }, nil
      end
      function runtime.touchGroup()
        runtime.calls.touch = runtime.calls.touch + 1
        return true, nil
      end
      runtime.applicationSchemas = {
        validateData = function(_, value) return value, nil end
      }
      return runtime
    end
  `);
}

test('grade changes cover demotion and both rank-authority boundaries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = {}
      local actorRank, currentRank, targetRank = 100, 50, 10
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_grades AS grade', 1, true) then
          return { id = 71, public_id = 'grade_junior_0001', grade_key = 'junior',
            rank_value = targetRank, member_limit = nil, promotion_requires_approval = 0 }
        end
        if sql:find('SELECT grade.rank_value', 1, true) then
          return { rank_value = actorRank }
        end
        if sql:find('SELECT grade.public_id', 1, true) then
          return { public_id = 'grade_current_0001', grade_key = 'senior',
            rank_value = currentRank }
        end
        error('unexpected grade query: ' .. sql)
      end
      function tx.query(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      local runtime = coverageRuntime()
      local request = {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001',
        grade_id = 'grade_junior_0001', expected_version = 1,
        reason = 'approved_demotion'
      }
      local changed, changeError, effects =
        MembershipLifecycle.execute.members_set_grade(tx, request, runtime)
      assert(changeError == nil and changed.status == 'ACTIVE' and changed.version == 2)
      assert(#effects == 1 and effects[1].action == 'grade.changed')
      assert(effects[1].before.grade_id == 'grade_current_0001')
      assert(effects[1].after.grade_id == 'grade_junior_0001')
      assert(#writes == 4 and runtime.calls.touch == 1)

      writes = {}
      actorRank, currentRank, targetRank = 50, 50, 10
      local denied, deniedError =
        MembershipLifecycle.execute.members_set_grade(tx, request, coverageRuntime())
      assert(denied == nil and deniedError.code == 'TARGET_GRADE_TOO_HIGH')
      assert(#writes == 0)

      actorRank, currentRank, targetRank = 100, 50, 100
      local boundary, boundaryError =
        MembershipLifecycle.execute.members_set_grade(tx, request, coverageRuntime())
      assert(boundary == nil and boundaryError.code == 'TARGET_GRADE_TOO_HIGH')
      assert(#writes == 0)

      actorRank, currentRank, targetRank = 50, 50, 10
      local selfRuntime = coverageRuntime({
        authorize = function(_, groupId, actorId)
          return { id = 31, public_id = 'membership_target_0001',
            character_id = actorId, group_id = 10, group_public_id = groupId,
            lifecycle_state = 'ACTIVE' }, nil
        end
      })
      local selfChanged, selfError = MembershipLifecycle.execute.members_set_grade(
        tx, request, selfRuntime)
      assert(selfChanged == nil and selfError.code == 'APPROVAL_REQUIRED' and #writes == 0)
      local approvedSelfRuntime = coverageRuntime({
        authorize = function(_, groupId, actorId)
          return { id = 31, public_id = 'membership_target_0001',
            character_id = actorId, group_id = 10, group_public_id = groupId,
            lifecycle_state = 'ACTIVE' }, nil
        end
      })
      approvedSelfRuntime.verifyApprovedOperation = function(_, operation, exactRequest, groupId)
        assert(operation == 'members_set_grade' and exactRequest == request)
        assert(groupId == 'group_alpha_0001')
        return true, nil
      end
      local approvedSelf, approvedSelfError = MembershipLifecycle.execute.members_set_grade(
        tx, request, approvedSelfRuntime, { internal = true })
      assert(approvedSelfError == nil and approvedSelf.status == 'ACTIVE' and #writes == 4)
      return changed.status .. ':' .. deniedError.code .. ':' .. boundaryError.code
        .. ':' .. selfError.code .. ':' .. approvedSelf.status
    `);
    assert.equal(
      result,
      'ACTIVE:TARGET_GRADE_TOO_HIGH:TARGET_GRADE_TOO_HIGH:APPROVAL_REQUIRED:ACTIVE',
    );
  } finally {
    engine.global.close();
  }
});

test('one offline membership can hold multiple roles, including a temporary role, and remove one', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      GetPlayers = function() error('role persistence must not scan online players') end
      GetPlayerName = function() error('offline membership must not require a player handle') end
      local inserts = {}
      local tx = {}
      function tx.one(sql, parameters)
        if sql:find('FROM synex_group_roles', 1, true) then
          return { id = parameters[1] == 'role_recruiter_0001' and 41 or 42,
            public_id = parameters[1], exclusivity = 'none', holder_limit = nil }
        end
        if sql:find('FROM synex_group_membership_roles', 1, true) then return nil end
        if sql:find('SELECT CASE', 1, true) then return { valid = 1 } end
        error('unexpected role assignment query: ' .. sql)
      end
      function tx.query(sql, parameters)
        inserts[#inserts + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = coverageRuntime()
      local first = assert(MembershipAccess.execute.roles_assign(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_offline_0001', role_id = 'role_recruiter_0001',
        reason = 'secondary_function'
      }, runtime))
      local temporary = assert(MembershipAccess.execute.roles_assign(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_offline_0001', role_id = 'role_incident_0001',
        valid_from = '2099-01-01T00:00:00Z',
        valid_until = '2099-01-02T00:00:00Z', reason = 'temporary_command'
      }, runtime))
      assert(first.entity_id ~= temporary.entity_id and #inserts == 2)
      assert(inserts[2].parameters[5] == '2099-01-01T00:00:00Z')
      assert(inserts[2].parameters[6] == '2099-01-02T00:00:00Z')

      local selfRuntime = coverageRuntime({
        authorize = function(_, groupId, actorId, _, _, policyContext)
          assert(policyContext.target_membership.public_id == 'membership_offline_0001')
          assert(policyContext.parameters.role_id == 'role_self_0001')
          return { id = 31, public_id = 'membership_offline_0001',
            character_id = actorId, group_id = 10, group_public_id = groupId,
            lifecycle_state = 'ACTIVE' }, nil
        end
      })
      local selfRoleRequest = {
        actor_character_id = 'character_offline_0001',
        membership_id = 'membership_offline_0001', role_id = 'role_self_0001',
        reason = 'self_escalation_attempt'
      }
      local selfAssigned, selfAssignError = MembershipAccess.execute.roles_assign(
        tx, selfRoleRequest, selfRuntime)
      assert(selfAssigned == nil and selfAssignError.code == 'APPROVAL_REQUIRED'
        and #inserts == 2)
      selfRuntime.verifyApprovedOperation = function(_, operation, exactRequest, groupId)
        assert(operation == 'roles_assign' and exactRequest == selfRoleRequest)
        assert(groupId == 'group_alpha_0001')
        return true, nil
      end
      local approvedSelfRole, approvedSelfRoleError = MembershipAccess.execute.roles_assign(
        tx, selfRoleRequest, selfRuntime, { internal = true })
      assert(approvedSelfRoleError == nil and approvedSelfRole.status == 'active'
        and #inserts == 3)

      local removeTx = {}
      function removeTx.one(sql)
        if sql:find('FROM synex_group_membership_roles AS assignment', 1, true) then
          return {
            id = 51, public_id = temporary.entity_id, version = 1, status = 'active',
            role_public_id = 'role_incident_0001',
            membership_internal_id = 31, group_id = 10,
            membership_public_id = 'membership_offline_0001',
            character_id = 'character_offline_0001', lifecycle_state = 'ACTIVE',
            group_internal_id = 10,
            group_public_id = 'group_alpha_0001'
          }
        end
        error('unexpected role removal query: ' .. sql)
      end
      local revocations = 0
      function removeTx.affected(sql)
        assert(sql:find("SET status = 'revoked'", 1, true))
        revocations = revocations + 1
        return 1
      end
      local removed, removeError, removeEffects =
        MembershipAccess.execute.roles_remove(removeTx, {
          actor_character_id = 'character_actor_0001',
          membership_role_id = temporary.entity_id, expected_version = 1,
          reason = 'function_ended'
        }, runtime)
      assert(removeError == nil and removed.status == 'revoked' and removed.version == 2)
      assert(removeEffects[1].action == 'role.removed')

      local selfRemoveRuntime = coverageRuntime({
        authorize = function(_, groupId, actorId, _, _, policyContext)
          assert(policyContext.target_membership.public_id == 'membership_offline_0001')
          assert(policyContext.parameters.role_id == 'role_incident_0001')
          return { id = 31, public_id = 'membership_offline_0001',
            character_id = actorId, group_id = 10, group_public_id = groupId,
            lifecycle_state = 'ACTIVE' }, nil
        end
      })
      local selfRemoveRequest = {
        actor_character_id = 'character_offline_0001',
        membership_role_id = temporary.entity_id, expected_version = 1,
        reason = 'self_deny_bypass_attempt'
      }
      local selfRemoved, selfRemoveError = MembershipAccess.execute.roles_remove(
        removeTx, selfRemoveRequest, selfRemoveRuntime)
      assert(selfRemoved == nil and selfRemoveError.code == 'APPROVAL_REQUIRED'
        and revocations == 1)
      selfRemoveRuntime.verifyApprovedOperation = function(_, operation, exactRequest, groupId)
        assert(operation == 'roles_remove' and exactRequest == selfRemoveRequest)
        assert(groupId == 'group_alpha_0001')
        return true, nil
      end
      local approvedRemoval, approvedRemovalError = MembershipAccess.execute.roles_remove(
        removeTx, selfRemoveRequest, selfRemoveRuntime, { internal = true })
      assert(approvedRemovalError == nil and approvedRemoval.status == 'revoked'
        and revocations == 2)
      return first.status .. ':' .. temporary.status .. ':' .. removed.status
        .. ':' .. selfRemoveError.code .. ':' .. approvedRemoval.status
    `);
    assert.equal(result, 'active:active:revoked:APPROVAL_REQUIRED:revoked');
  } finally {
    engine.global.close();
  }
});

test('invitations reject a pending duplicate and materialize an offline target membership', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      GetPlayers = function() error('invitations must not scan online players') end
      GetPlayerName = function() error('offline invitations must not resolve a player handle') end
      local inserted = 0
      local runtime = coverageRuntime()
      local duplicateTx = {}
      function duplicateTx.one(sql)
        if sql:find('FROM synex_group_invitations AS invitation', 1, true) then
          return { id = 41, public_id = 'invite_existing_0001', version = 1, expired = 0 }
        end
        error('unexpected duplicate invitation query: ' .. sql)
      end
      function duplicateTx.insert() inserted = inserted + 1 return 51 end
      function duplicateTx.query() inserted = inserted + 1 return { affectedRows = 1 } end
      local duplicate, duplicateError = MembershipInvitations.execute.members_invite(
        duplicateTx, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
          character_id = 'character_offline_0001', role_ids = {}
        }, runtime)
      assert(duplicate == nil and duplicateError.code == 'IDEMPOTENCY_CONFLICT')
      assert(inserted == 0)

      local offlineTx = {}
      function offlineTx.one(sql)
        if sql:find('FROM synex_group_invitations AS invitation', 1, true) then return nil end
        if sql:find('SELECT allowed.state_key', 1, true) then
          return { state_key = 'allowed' }
        end
        if sql:find('SELECT group_type.membership_limit', 1, true) then
          return { membership_limit = nil }
        end
        if sql:find('SELECT membership.id', 1, true) then return nil end
        error('unexpected offline invitation query: ' .. sql)
      end
      function offlineTx.insert(sql)
        inserted = inserted + 1
        if sql:find('INSERT INTO synex_group_memberships', 1, true) then return 52 end
        assert(sql:find('INSERT INTO synex_group_invitations', 1, true))
        return 53
      end
      function offlineTx.query() inserted = inserted + 1 return { affectedRows = 1 } end
      local invitation, invitationError, effects =
        MembershipInvitations.execute.members_invite(offlineTx, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
          character_id = 'character_offline_0001', role_ids = {},
          reason = 'offline_recruitment'
        }, runtime)
      assert(invitationError == nil and invitation.status == 'pending' and inserted == 5)
      assert(#effects == 2 and effects[1].action == 'membership.invited'
        and effects[2].characterId == 'character_offline_0001')
      return duplicateError.code .. ':' .. invitation.status
    `);
    assert.equal(result, 'IDEMPOTENCY_CONFLICT:pending');
  } finally {
    engine.global.close();
  }
});

test('delegation revocation is versioned and invalid scopes fail at the public boundary', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local invalidRequest = {
        idempotency_key = 'delegation-invalid-0001',
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        grantee_membership_id = 'membership_target_0001',
        capability = 'synex.groups.members.read', scope = 'foreign_group',
        valid_until = '2099-01-01T00:00:00Z', reason = 'invalid_scope'
      }
      local valid, scopeError = Validation.operation('delegations_create', invalidRequest)
      assert(valid == nil and scopeError.code == 'VALIDATION_FAILED')
      assert(scopeError.details.field == 'scope')

      local crossGroupRuntime = coverageRuntime({
        requireMembership = function(_, membershipId)
          return {
            id = 31, public_id = membershipId, group_id = 99,
            group_public_id = 'group_foreign_0001',
            character_id = 'character_offline_0001',
            lifecycle_state = 'ACTIVE', version = 1
          }
        end
      })
      local crossGroup, crossGroupError =
        GovernanceCapabilities.execute.delegations_create({}, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
          grantee_membership_id = 'membership_foreign_0001',
          capability = 'synex.groups.members.read', scope = 'group',
          valid_until = '2099-01-01T00:00:00Z', reason = 'cross_group'
        }, crossGroupRuntime)
      assert(crossGroup == nil and crossGroupError.code == 'INVALID_SCOPE')
      assert(crossGroupRuntime.calls.authorize == 2)

      local updates = 0
      local tx = {}
      function tx.one()
        return {
          id = 61, public_id = 'delegation_target_0001', group_id = 10,
          grantee_membership_id = 31, capability_pattern = 'synex.groups.members.read',
          scope_kind = 'group', scope_ref = '', status = 'active', version = 3,
          group_public_id = 'group_alpha_0001',
          character_id = 'character_offline_0001'
        }
      end
      function tx.affected(sql, parameters)
        assert(sql:find("SET status = 'revoked'", 1, true))
        assert(parameters[2] == 61 and parameters[3] == 3)
        updates = updates + 1
        return 1
      end
      local runtime = coverageRuntime()
      local revoked, revokeError, effects =
        GovernanceCapabilities.execute.delegations_revoke(tx, {
          actor_character_id = 'character_actor_0001',
          delegation_id = 'delegation_target_0001', expected_version = 3,
          reason = 'authority_removed'
        }, runtime)
      assert(revokeError == nil and revoked.status == 'revoked' and revoked.version == 4)
      assert(updates == 1 and runtime.calls.touch == 1)
      assert(#effects == 1 and effects[1].action == 'delegation.revoked')
      return scopeError.code .. ':' .. crossGroupError.code .. ':' .. revoked.status
    `);
    assert.equal(result, 'VALIDATION_FAILED:INVALID_SCOPE:revoked');
  } finally {
    engine.global.close();
  }
});

test('duty start, update, and stop are direct, duplicate-safe, and reject inactive members', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local runtime = coverageRuntime()
      local writes = {}
      local startTx = {}
      function startTx.one(sql)
        if sql:find('synex_group_organization_profiles', 1, true) then
          return { group_type_id = 7 }
        end
        if sql:find('synex_group_duty_states', 1, true) then
          return { state_key = 'on_duty' }
        end
        if sql:find('synex_group_duty_sessions', 1, true) then return nil end
        error('unexpected duty-start query: ' .. sql)
      end
      function startTx.insert(sql)
        assert(sql:find('INSERT INTO synex_group_duty_sessions', 1, true))
        writes[#writes + 1] = sql
        return 71
      end
      function startTx.query(sql)
        writes[#writes + 1] = sql
        return { affectedRows = 1 }
      end
      local started, startError, startEffects = Duty.execute.duty_start(startTx, {
        actor_character_id = 'character_offline_0001',
        membership_id = 'membership_offline_0001', state = 'on_duty', metadata = {}
      }, runtime)
      assert(startError == nil and started.status == 'open' and started.version == 1)
      assert(#writes == 2 and startEffects[1].action == 'duty.started')

      local duplicateTx = {}
      function duplicateTx.one(sql)
        if sql:find('synex_group_organization_profiles', 1, true) then
          return { group_type_id = 7 }
        end
        if sql:find('synex_group_duty_states', 1, true) then
          return { state_key = 'on_duty' }
        end
        if sql:find('synex_group_duty_sessions', 1, true) then return { id = 71 } end
        error('unexpected duplicate-duty query: ' .. sql)
      end
      local duplicate, duplicateError = Duty.execute.duty_start(duplicateTx, {
        actor_character_id = 'character_offline_0001',
        membership_id = 'membership_offline_0001', state = 'on_duty'
      }, runtime)
      assert(duplicate == nil and duplicateError.code == 'INVALID_TRANSITION')

      local inactiveRuntime = coverageRuntime({
        requireMembership = function(_, membershipId)
          return { id = 31, public_id = membershipId, group_id = 10,
            group_public_id = 'group_alpha_0001', character_id = 'character_offline_0001',
            lifecycle_state = 'SUSPENDED', version = 1 }
        end
      })
      local inactive, inactiveError = Duty.execute.duty_start({
        one = function() error('inactive duty must stop before SQL') end
      }, {
        actor_character_id = 'character_offline_0001',
        membership_id = 'membership_offline_0001', state = 'on_duty'
      }, inactiveRuntime)
      assert(inactive == nil and inactiveError.code == 'MEMBERSHIP_NOT_ACTIVE')
      assert(inactiveRuntime.calls.authorize == 1)

      local sessionVersion = 1
      local function sessionTx()
        local tx = {}
        function tx.one(sql)
          if sql:find('FROM synex_group_duty_sessions AS session', 1, true) then
            return {
              id = 71, public_id = started.entity_id, membership_id = 31,
              state_key = sessionVersion == 1 and 'on_duty' or 'responding',
              status = 'open', assignment_id = nil, metadata_json = '{}',
              version = sessionVersion, membership_public_id = 'membership_offline_0001',
              character_id = 'character_offline_0001', lifecycle_state = 'ACTIVE',
              group_internal_id = 10, group_public_id = 'group_alpha_0001',
              group_type_id = 7
            }
          end
          if sql:find('synex_group_duty_states', 1, true) then
            return { state_key = 'responding' }
          end
          error('unexpected duty-session query: ' .. sql)
        end
        function tx.affected() return 1 end
        function tx.query(sql)
          writes[#writes + 1] = sql
          return { affectedRows = 1 }
        end
        return tx
      end
      local updated, updateError, updateEffects = Duty.execute.duty_update(sessionTx(), {
        actor_character_id = 'character_offline_0001',
        duty_session_id = started.entity_id, expected_version = 1,
        state = 'responding', metadata = {}
      }, runtime)
      assert(updateError == nil and updated.status == 'open' and updated.version == 2)
      assert(updateEffects[1].action == 'duty.updated')
      sessionVersion = 2
      local stopped, stopError, stopEffects = Duty.execute.duty_stop(sessionTx(), {
        actor_character_id = 'character_offline_0001',
        duty_session_id = started.entity_id, expected_version = 2,
        reason = 'shift_complete'
      }, runtime)
      assert(stopError == nil and stopped.status == 'closed' and stopped.version == 3)
      assert(stopEffects[1].action == 'duty.ended')
      return table.concat({ started.status, duplicateError.code, inactiveError.code,
        updated.status, stopped.status }, ':')
    `);
    assert.equal(
      result,
      'open:INVALID_TRANSITION:MEMBERSHIP_NOT_ACTIVE:open:closed',
    );
  } finally {
    engine.global.close();
  }
});

test('assignment create, join, and leave execute their complete persistence paths', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local runtime = coverageRuntime()
      local createWrites = {}
      local createTx = {}
      function createTx.query(sql, parameters)
        createWrites[#createWrites + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local created, createError, createEffects = Assignments.execute.assignments_create(
        createTx, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
          name = 'Night operation', type = 'operation', metadata = {}
        }, runtime)
      assert(createError == nil and created.status == 'active' and #createWrites == 1)
      assert(createEffects[1].action == 'assignment.created')
      local oversizedRuntime = coverageRuntime()
      oversizedRuntime.jsonEncode = function() return string.rep('x', 16385) end
      local oversized, oversizedError = Assignments.execute.assignments_create(
        createTx, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
          name = 'Oversized operation', type = 'operation', metadata = { payload = 'large' }
        }, oversizedRuntime)
      assert(oversized == nil and oversizedError.code == 'VALIDATION_FAILED'
        and #createWrites == 1)

      local joinWrites = {}
      local joinTx = {}
      function joinTx.one(sql)
        if sql:find('FROM synex_group_assignments AS assignment', 1, true) then
          return { id = 81, public_id = created.entity_id, group_id = 10,
            status = 'active', member_limit = nil, inside_window = 1,
            group_public_id = 'group_alpha_0001' }
        end
        if sql:find('synex_group_assignment_members', 1, true) then return nil end
        error('unexpected assignment join query: ' .. sql)
      end
      function joinTx.query(sql, parameters)
        joinWrites[#joinWrites + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local joined, joinError, joinEffects = Assignments.execute.assignments_join(
        joinTx, {
          actor_character_id = 'character_actor_0001', assignment_id = created.entity_id,
          membership_id = 'membership_offline_0001', role = 'operator'
        }, runtime)
      assert(joinError == nil and joined.status == 'active' and #joinWrites == 1)
      assert(joinWrites[1].parameters[4] == 'operator')
      assert(joinEffects[1].action == 'assignment.joined')

      local leaveWrites = {}
      local leaveTx = {}
      function leaveTx.one(sql)
        if sql:find('FROM synex_group_assignment_members AS participant', 1, true) then
          return {
            id = 91, public_id = joined.entity_id, version = 1, status = 'active',
            assignment_id = 81, membership_id = 31,
            assignment_public_id = created.entity_id,
            group_public_id = 'group_alpha_0001',
            membership_public_id = 'membership_offline_0001',
            character_id = 'character_offline_0001'
          }
        end
        if sql:find('synex_group_duty_sessions', 1, true) then return nil end
        error('unexpected assignment leave query: ' .. sql)
      end
      function leaveTx.affected(sql)
        leaveWrites[#leaveWrites + 1] = sql
        return 1
      end
      local left, leaveError, leaveEffects = Assignments.execute.assignments_leave(
        leaveTx, {
          actor_character_id = 'character_offline_0001',
          assignment_member_id = joined.entity_id, expected_version = 1,
          reason = 'operation_complete'
        }, runtime)
      assert(leaveError == nil and left.status == 'left' and left.version == 2)
      assert(#leaveWrites == 1 and #leaveEffects == 1)
      assert(leaveEffects[1].action == 'assignment.left')
      return created.status .. ':' .. joined.status .. ':' .. left.status
        .. ':' .. oversizedError.code
    `);
    assert.equal(result, 'active:active:left:VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('applications reject successfully and an active duplicate cannot be submitted', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local runtime = coverageRuntime()
      local changed = 0
      local rejectTx = {}
      function rejectTx.one(sql)
        if sql:find('FROM synex_group_applications AS application', 1, true) then
          return {
            id = 101, public_id = 'application_target_0001', group_id = 10,
            character_id = 'character_offline_0001', membership_id = 31,
            membership_public_id = 'membership_target_0001',
            membership_version = 2, membership_lifecycle = 'UNDER_REVIEW',
            membership_profile_version = 2,
            status = 'reviewing', version = 2,
            group_public_id = 'group_alpha_0001', group_status = 'active',
            group_lifecycle = 'ACTIVE', inside_window = 1
          }
        end
        if sql:find('SELECT allowed.state_key', 1, true) then
          return { state_key = 'DRAFT' }
        end
        error('unexpected reject query: ' .. sql)
      end
      function rejectTx.affected(sql, parameters)
        changed = changed + 1
        return 1
      end
      function rejectTx.query() changed = changed + 1 return { affectedRows = 1 } end
      local rejected, rejectError, rejectEffects = Applications.execute.applications_review(
        rejectTx, {
          actor_character_id = 'character_actor_0001',
          application_id = 'application_target_0001', expected_version = 2,
          decision = 'REJECTED', reason = 'requirements_not_met'
        }, runtime)
      assert(rejectError == nil and rejected.status == 'rejected' and rejected.version == 3)
      assert(changed == 4 and runtime.calls.touch == 1)
      assert(#rejectEffects == 2 and rejectEffects[1].action == 'membership.draft'
        and rejectEffects[2].action == 'application.rejected')

      local writes = 0
      local duplicateTx = {}
      function duplicateTx.one(sql)
        if sql:find('FROM synex_group_applications AS application', 1, true) then
          return { id = 102, public_id = 'application_existing_0001',
            status = 'submitted', version = 1, expired = 0 }
        end
        error('unexpected application duplicate query: ' .. sql)
      end
      function duplicateTx.query() writes = writes + 1 return { affectedRows = 1 } end
      function duplicateTx.affected() writes = writes + 1 return 1 end
      local duplicate, duplicateError = Applications.execute.applications_submit(
        duplicateTx, {
          actor_character_id = 'character_offline_0001', group_id = 'group_alpha_0001',
          schema_version = 1, data = {}
        }, runtime)
      assert(duplicate == nil and duplicateError.code == 'IDEMPOTENCY_CONFLICT')
      assert(writes == 0)
      return rejected.status .. ':' .. duplicateError.code
    `);
    assert.equal(result, 'rejected:IDEMPOTENCY_CONFLICT');
  } finally {
    engine.global.close();
  }
});

test('relationship update persists status, invalidates both groups, and emits one effect', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = {}
      local tx = {}
      function tx.one(sql)
        if sql:find('synex_group_relationships', 1, true)
            and sql:find(' AS ', 1, true) then
          return {
            id = 111, public_id = 'relationship_target_0001',
            source_group_id = 10, target_group_id = 20,
            status = 'active', valid_from = '2026-01-01 00:00:00.000000',
            valid_until = nil, version = 4,
            source_public_id = 'group_alpha_0001',
            target_public_id = 'group_bravo_0001', type_key = 'alliance'
          }
        end
        error('unexpected relationship query: ' .. sql)
      end
      function tx.query(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = coverageRuntime()
      local changed, changeError, effects =
        OrganizationStructure.relationships_update(tx, {
          actor_character_id = 'character_actor_0001',
          relationship_id = 'relationship_target_0001', expected_version = 4,
          status = 'ended', reason = 'agreement_complete'
        }, runtime)
      assert(changeError == nil and changed.status == 'ended' and changed.version == 5)
      assert(#writes == 3)
      assert(writes[1].sql:find('UPDATE', 1, true)
        and writes[1].sql:find('synex_group_relationships', 1, true))
      assert(writes[2].parameters[1] == 10 and writes[3].parameters[1] == 20)
      assert(#effects == 1 and effects[1].action == 'relationship.changed')
      assert(effects[1].before.status == 'active' and effects[1].after.status == 'ended')
      return changed.status .. ':' .. changed.version .. ':' .. #writes
    `);
    assert.equal(result, 'ended:5:3');
  } finally {
    engine.global.close();
  }
});
