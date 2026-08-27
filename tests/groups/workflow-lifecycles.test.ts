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

async function loadFoundation(engine: LuaEngine): Promise<void> {
  const source = await readFile(
    path.join(root, 'resources/synex_groups/server/foundation.lua'),
    'utf8',
  );
  await engine.doString(
    `Foundation = assert(load(${JSON.stringify(source)}, '@server/foundation.lua'))()`,
  );
}

test('workflow expiry is replay-safe and activation capacity is centralized', async () => {
  const [
    sql,
    workflowEntities,
    invitations,
    applications,
    membershipShared,
    membershipLifecycle,
  ] = await Promise.all([
    readFile(
      path.join(root, 'resources/synex_groups/migrations/022_workflow_lifecycle_expiry.sql'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/migrations/030_membership_workflow_entities.sql'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/memberships_invitations.lua'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/workflows_applications.lua'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/memberships_shared.lua'),
      'utf8',
    ),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/memberships_lifecycle.lua'),
      'utf8',
    ),
  ]);
  assert.match(sql, /IF NOT EXISTS[\s\S]*?`COLUMN_NAME` = 'expires_at'/u);
  assert.match(sql, /TIMESTAMPADD\(DAY, 30, `created_at`\)/u);
  assert.match(sql, /'submitted', 'reviewing', 'approved', 'rejected', 'withdrawn', 'expired'/u);
  assert.match(sql, /idx_group_applications_expiry` \(`status`, `expires_at`, `id`\)/u);
  assert.match(sql, /DROP CONSTRAINT `chk_group_applications_status`/u);
  assert.match(sql, /DROP CONSTRAINT `chk_group_applications_review`/u);
  assert.match(workflowEntities, /ADD COLUMN `membership_id` BIGINT UNSIGNED NULL/u);
  assert.match(workflowEntities, /MODIFY COLUMN `membership_id` BIGINT UNSIGNED NOT NULL/u);
  assert.match(workflowEntities, /FOREIGN KEY \(`membership_id`\)[\s\S]*?ON DELETE RESTRICT/u);
  assert.match(workflowEntities, /information_schema`.`CHECK_CONSTRAINTS`/u);
  assert.match(workflowEntities, /UPPER\(`COLUMN_NAME`\) = 'ENFORCED'/u);
  assert.match(workflowEntities, /UPPER\(COALESCE\(ENFORCED, ''NO''\)\) = ''YES''/u);
  assert.match(
    workflowEntities,
    /event_typein''added'',''role_changed'',''suspended'',''removed'',''transitioned'',''grade_changed'',''visibility_changed'''/u,
  );
  for (const source of [invitations, applications]) {
    assert.match(source, /membership_id/u);
    assert.match(source, /activateWorkflowMembership/u);
  }
  assert.match(membershipShared, /active_membership_limit/u);
  assert.match(
    membershipShared,
    /lifecycle_state IN\s*\('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE'\)/u,
  );
  assert.match(membershipShared, /SUM\(CASE WHEN lifecycle_state = 'ACTIVE'/u);
  assert.match(
    membershipLifecycle,
    /joined_at = CASE WHEN \? IN \('PROBATION', 'ACTIVE', 'SUSPENDED',\s*'LEAVE', 'INACTIVE'\)/u,
  );
  assert.doesNotMatch(
    membershipLifecycle,
    /joined_at = CASE WHEN \? IN \([^)]*'TERMINATED'[^)]*\)/u,
  );
});

test('pre-join membership reads never fabricate joined_at and the field is optional', async () => {
  const [catalogRaw, readSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8'),
    readFile(
      path.join(root, 'resources/synex_groups/server/persistence/memberships_read.lua'),
      'utf8',
    ),
  ]);
  const catalog = JSON.parse(catalogRaw) as {
    contracts: Array<{ name: string; output: { required?: string[] } }>;
  };
  const getContract = catalog.contracts.find(
    (candidate) => candidate.name === 'synex.groups.members.get',
  );
  assert.ok(getContract);
  assert.equal(getContract.output.required?.includes('joined_at'), false);
  assert.doesNotMatch(readSource, /COALESCE\(profile\.joined_at, profile\.created_at\)/u);

  const engine = await new LuaFactory().createEngine();
  try {
    await loadFoundation(engine);
    await preload(
      engine,
      'server.domain.constants',
      'resources/synex_groups/server/domain/constants.lua',
    );
    await preload(
      engine,
      'server.domain.lifecycle',
      'resources/synex_groups/server/domain/lifecycle.lua',
    );
    await preload(
      engine,
      'server.persistence.memberships_shared',
      'resources/synex_groups/server/persistence/memberships_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.memberships_read',
      'resources/synex_groups/server/persistence/memberships_read.lua',
    );
    const result = await engine.doString(`
      local Memberships = require('server.persistence.memberships_read')(Foundation)
      local row = {
        membership_id = 'group_member_00000001', group_id = 'group_public_0001',
        character_id = 'character_target_0001', status = 'INVITED',
        visibility = 'hidden', joined_at = nil, left_at = nil, version = 1
      }
      local tx = {
        one = function() return row end,
        many = function() return { row } end
      }
      local fetched, fetchError = Memberships.read.members_get(tx, {
        membership_id = 'group_member_00000001'
      })
      assert(fetchError == nil and fetched.status == 'INVITED'
        and fetched.joined_at == nil)
      local listed, listError = Memberships.read.members_list(tx, {
        group_id = 'group_public_0001', actor_character_id = 'character_actor_0001'
      }, { authorize = function() return {}, nil end })
      assert(listError == nil and #listed.items == 1
        and listed.items[1].joined_at == nil)
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('invitation decline, revoke, and stale replacement are CAS guarded', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadFoundation(engine);
    await preload(
      engine,
      'server.domain.constants',
      'resources/synex_groups/server/domain/constants.lua',
    );
    await preload(
      engine,
      'server.domain.lifecycle',
      'resources/synex_groups/server/domain/lifecycle.lua',
    );
    await preload(
      engine,
      'server.persistence.memberships_shared',
      'resources/synex_groups/server/persistence/memberships_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.memberships_invitations',
      'resources/synex_groups/server/persistence/memberships_invitations.lua',
    );
    const result = await engine.doString(`
      local Invitations = require('server.persistence.memberships_invitations')(Foundation)
      local effects, updates, activations = {}, {}, {}
      local runtime = {}
      function runtime.authorize()
        return { id = 7, rank_value = 100 }
      end
      function runtime.requireGroup()
        return { id = 10, status = 'active', lifecycle_state = 'ACTIVE' }
      end
      function runtime.id(namespace) return namespace .. '_00000001' end
      function runtime.reason(_, fallback) return fallback end
      function runtime.jsonEncode() return '{}' end
      function runtime.touchGroup() return true end
      function runtime.enforceMembershipActivation(_, membership)
        activations[#activations + 1] = membership
        return true, nil
      end
      function runtime.resolveMembershipTransitionPolicy(_, request)
        return { configured = false, allowed = true,
          from_status = request.from_status, to_status = request.to_status }
      end
      function runtime.success(id, kind, status, version)
        return { entity_id = id, entity_type = kind, status = status,
          version = version, replayed = false }
      end
      function runtime.effect(action, kind, id, groupId, characterId,
          before, after, reason, version)
        return { action = action, entityType = kind, entityId = id,
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = reason, version = version }
      end

      local function closeTx(characterId)
        local tx = {}
        function tx.one()
          return { id = 41, public_id = 'group_invite_00000001', group_id = 10,
            character_id = characterId, status = 'pending', version = 3,
            group_public_id = 'group_public_0001', expired = 0,
            membership_id = 71, membership_public_id = 'group_member_00000001',
            membership_version = 3, membership_lifecycle = 'INVITED',
            membership_profile_version = 3 }
        end
        function tx.affected(sql, parameters)
          updates[#updates + 1] = { sql = sql, parameters = parameters }
          return 1
        end
        function tx.query(sql, parameters)
          updates[#updates + 1] = { sql = sql, parameters = parameters }
          return { affectedRows = 1 }
        end
        return tx
      end

      local declined, declineError, declineEffects =
        Invitations.execute.members_decline(closeTx('character_actor_0001'), {
          invitation_id = 'group_invite_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 3,
          reason = 'not_interested'
        }, runtime)
      assert(declineError == nil and declined.status == 'declined'
        and declined.version == 4 and declineEffects[1].action
          == 'membership.invitation_declined')
      assert(#declineEffects == 2 and declineEffects[2].action == 'membership.draft')

      local revoked, revokeError = Invitations.execute.members_revoke_invite(
        closeTx('character_target_0001'), {
          invitation_id = 'group_invite_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 3,
          reason = 'invitation_cancelled'
        }, runtime)
      assert(revokeError == nil and revoked.status == 'revoked')

      local staleTx = {}
      function staleTx.one(sql)
        if sql:find('FROM synex_group_invitations AS invitation', 1, true) then
          return { id = 42, public_id = 'group_invite_stale_0001',
            membership_id = 72, version = 2, expired = 1,
            membership_public_id = 'group_member_00000002',
            membership_version = 2, membership_lifecycle = 'INVITED',
            membership_profile_version = 2 }
        end
        if sql:find('SELECT allowed.state_key', 1, true) then
          return { state_key = 'allowed' }
        end
        if sql:find('SELECT group_type.membership_limit', 1, true) then
          return { membership_limit = nil }
        end
        if sql:find('SELECT membership.id', 1, true) then
          return { id = 72, public_id = 'group_member_00000002', group_id = 10,
            group_public_id = 'group_public_0001',
            character_id = 'character_target_0001', lifecycle_state = 'DRAFT',
            version = 3, profile_version = 3 }
        end
        error('unexpected stale-invite query: ' .. sql)
      end
      function staleTx.affected(sql)
        return 1
      end
      function staleTx.insert(sql)
        assert(sql:find('INSERT INTO synex_group_invitations', 1, true))
        return 43
      end
      function staleTx.query() return { affectedRows = 1 } end
      local replacement, replacementError, replacementEffects =
        Invitations.execute.members_invite(staleTx, {
          group_id = 'group_public_0001', actor_character_id = 'character_actor_0001',
          character_id = 'character_target_0001', role_ids = {}
        }, runtime)
      assert(replacementError == nil and replacement.status == 'pending')
      assert(#replacementEffects == 4
        and replacementEffects[1].action == 'membership.invitation_expired'
        and replacementEffects[2].action == 'membership.draft'
        and replacementEffects[3].action == 'membership.invited'
        and replacementEffects[4].action == 'membership.invited')

      local acceptWrites = {}
      local acceptTx = {}
      function acceptTx.one(sql)
        if sql:find('FROM synex_group_invitations AS invitation', 1, true) then
          return { id = 51, public_id = 'group_invite_accepted_01', group_id = 10,
            character_id = 'character_target_0001', membership_id = 71,
            membership_public_id = 'group_member_00000001',
            membership_version = 4, membership_lifecycle = 'INVITED',
            membership_profile_version = 4, grade_id = nil,
            status = 'pending', version = 2, group_public_id = 'group_public_0001',
            group_status = 'active', group_lifecycle = 'ACTIVE', inside_window = 1 }
        end
        if sql:find('SELECT allowed.state_key', 1, true) then
          return { state_key = 'allowed' }
        end
        if sql:find('group_type.membership_limit', 1, true) then
          return { membership_limit = nil, active_membership_limit = nil }
        end
        if sql:find('SELECT COUNT(*) AS total_count', 1, true) then
          return { total_count = 0, active_count = 0 }
        end
        if sql:find('FROM synex_group_grades AS grade', 1, true) then
          return { id = 61, public_id = 'group_grade_00000001',
            grade_key = 'member', member_limit = nil }
        end
        error('unexpected invitation acceptance query: ' .. sql)
      end
      function acceptTx.many() return {} end
      function acceptTx.query(sql)
        acceptWrites[#acceptWrites + 1] = sql
        return { affectedRows = 1 }
      end
      function acceptTx.affected(sql)
        acceptWrites[#acceptWrites + 1] = sql
        return 1
      end
      local accepted, acceptError, acceptEffects = Invitations.execute.members_accept(
        acceptTx, { invitation_id = 'group_invite_accepted_01',
          actor_character_id = 'character_target_0001' }, runtime)
      assert(acceptError == nil and accepted.status == 'ACTIVE'
        and #acceptEffects == 2
        and acceptEffects[1].action == 'membership.invitation_accepted'
        and acceptEffects[2].action == 'membership.activated')
      assert(#activations == 1 and activations[1].id == 71
        and activations[1].group_id == 10
        and activations[1].character_id == 'character_target_0001')
      assert(acceptWrites[#acceptWrites]:find("reason_code = 'invitation_accepted'", 1, true))

      local ownerOnlyTx = {}
      function ownerOnlyTx.one(sql)
        if sql:find('FROM synex_group_invitations AS invitation', 1, true) then
          return { id = 52, public_id = 'group_invite_owner_only01', group_id = 10,
            character_id = 'character_target_0001', membership_id = 72,
            membership_public_id = 'group_member_00000002',
            membership_version = 1, membership_lifecycle = 'INVITED',
            membership_profile_version = 1, grade_id = nil,
            status = 'pending', version = 1, group_public_id = 'group_public_0001',
            group_status = 'active', group_lifecycle = 'ACTIVE', inside_window = 1 }
        end
        if sql:find('FROM synex_group_grades AS grade', 1, true) then
          assert(sql:find("grade.grade_key <> 'owner'", 1, true))
          return nil
        end
        error('unexpected owner-only invitation query: ' .. sql)
      end
      local ownerAccepted, ownerError = Invitations.execute.members_accept(
        ownerOnlyTx, { invitation_id = 'group_invite_owner_only01',
          actor_character_id = 'character_target_0001' }, runtime)
      assert(ownerAccepted == nil and ownerError.code == 'GRADE_NOT_FOUND')
      return declined.status .. ':' .. revoked.status .. ':' .. accepted.status
    `);
    assert.equal(result, 'declined:revoked:ACTIVE');
  } finally {
    engine.global.close();
  }
});

test('applications require review before approval and close every terminal path with CAS', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadFoundation(engine);
    await preload(
      engine,
      'server.domain.constants',
      'resources/synex_groups/server/domain/constants.lua',
    );
    await preload(
      engine,
      'server.domain.lifecycle',
      'resources/synex_groups/server/domain/lifecycle.lua',
    );
    await preload(
      engine,
      'server.persistence.memberships_shared',
      'resources/synex_groups/server/persistence/memberships_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.workflows_shared',
      'resources/synex_groups/server/persistence/workflows_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.workflows_applications',
      'resources/synex_groups/server/persistence/workflows_applications.lua',
    );
    const result = await engine.doString(`
      local Applications = require('server.persistence.workflows_applications')(Foundation)
      local sequence, writes, activations = 0, {}, {}
      local runtime = { applicationSchemas = {
        validateData = function(_, value) return value end
      } }
      function runtime.id(namespace)
        sequence = sequence + 1
        return namespace .. '_' .. string.format('%08d', sequence)
      end
      function runtime.authorize()
        return { id = 21, public_id = 'membership_reviewer_0001' }
      end
      function runtime.reason(_, fallback) return fallback end
      function runtime.touchGroup() return true end
      function runtime.enforceMembershipActivation(_, membership)
        activations[#activations + 1] = membership
        return true, nil
      end
      function runtime.resolveMembershipTransitionPolicy(_, request)
        return { configured = false, allowed = true,
          from_status = request.from_status, to_status = request.to_status }
      end
      function runtime.jsonEncode() return '{}' end
      function runtime.jsonDecode() return { application_schema = {} } end
      function runtime.requireGroup(_, groupId)
        return { id = 10, public_id = groupId, status = 'active',
          lifecycle_state = 'ACTIVE', type_schema_version = 1,
          type_metadata_json = '{}' }
      end
      function runtime.success(id, kind, status, version)
        return { entity_id = id, entity_type = kind, status = status,
          version = version, replayed = false }
      end
      function runtime.effect(action, kind, id, groupId, characterId,
          before, after, reason, version)
        return { action = action, entityType = kind, entityId = id,
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = reason, version = version }
      end

      local function application(status, insideWindow)
        local lifecycle = status == 'reviewing' and 'UNDER_REVIEW' or 'APPLICANT'
        local membershipVersion = status == 'reviewing' and 2 or 1
        return { id = 30, public_id = 'group_apply_00000001', group_id = 10,
          character_id = 'character_target_0001', membership_id = 50,
          membership_public_id = 'group_member_00000001',
          membership_version = membershipVersion,
          membership_lifecycle = lifecycle,
          membership_profile_version = membershipVersion,
          status = status, version = 1,
          group_public_id = 'group_public_0001', group_status = 'active',
          group_lifecycle = 'ACTIVE',
          inside_window = insideWindow }
      end
      local function reviewTx(row, ownerOnly)
        local tx = {}
        function tx.one(sql)
          if sql:find('FROM synex_group_applications AS application', 1, true) then
            return row
          end
          if sql:find('SELECT allowed.state_key', 1, true) then
            return { state_key = 'allowed' }
          end
          if sql:find('group_type.membership_limit', 1, true) then
            return { membership_limit = nil, active_membership_limit = nil }
          end
          if sql:find('SELECT COUNT(*) AS total_count', 1, true) then
            return { total_count = 0, active_count = 0 }
          end
          if sql:find('FROM synex_group_grades AS grade', 1, true) then
            assert(sql:find("grade.grade_key <> 'owner'", 1, true))
            if ownerOnly then return nil end
            return { id = 40, public_id = 'group_grade_00000001',
              grade_key = 'member', member_limit = nil }
          end
          error('unexpected application query: ' .. sql)
        end
        function tx.affected(sql, parameters)
          writes[#writes + 1] = { sql = sql, parameters = parameters }
          return 1
        end
        function tx.insert() return 50 end
        function tx.query(sql, parameters)
          writes[#writes + 1] = { sql = sql, parameters = parameters }
          return { affectedRows = 1 }
        end
        return tx
      end

      local staleSubmitTx = {}
      function staleSubmitTx.one(sql)
        if sql:find('FROM synex_group_applications AS application', 1, true) then
          return { id = 29, public_id = 'group_apply_stale_0001',
            membership_id = 51, status = 'submitted', version = 2, expired = 1,
            membership_public_id = 'group_member_00000002',
            membership_version = 2, membership_lifecycle = 'APPLICANT',
            membership_profile_version = 2 }
        end
        if sql:find('SELECT allowed.state_key', 1, true) then
          return { state_key = 'allowed' }
        end
        if sql:find('SELECT group_type.membership_limit', 1, true) then
          return { membership_limit = nil }
        end
        if sql:find('SELECT membership.id', 1, true) then
          return { id = 51, public_id = 'group_member_00000002', group_id = 10,
            group_public_id = 'group_public_0001',
            character_id = 'character_target_0001', lifecycle_state = 'DRAFT',
            version = 3, profile_version = 3 }
        end
        error('unexpected application submit query: ' .. sql)
      end
      function staleSubmitTx.affected(sql)
        return 1
      end
      function staleSubmitTx.query(sql)
        return { affectedRows = 1 }
      end
      local submitted, submitError, submitEffects =
        Applications.execute.applications_submit(staleSubmitTx, {
          group_id = 'group_public_0001', actor_character_id = 'character_target_0001',
          schema_version = 1, data = {}
        }, runtime)
      assert(submitError == nil and submitted.status == 'submitted'
        and #submitEffects == 4
        and submitEffects[1].action == 'application.expired'
        and submitEffects[2].action == 'membership.draft'
        and submitEffects[3].action == 'membership.applicant'
        and submitEffects[4].action == 'application.submitted')

      local reviewing, reviewingError, reviewingEffects =
        Applications.execute.applications_review(reviewTx(application('submitted', 1)), {
          application_id = 'group_apply_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 1,
          decision = 'under_review', reason = 'review_started'
        }, runtime)
      assert(reviewingError == nil and reviewing.status == 'under_review'
        and reviewingEffects[1].action == 'membership.under_review'
        and reviewingEffects[2].action == 'application.under_review')
      assert(writes[1].sql:find("SET status = 'reviewing'", 1, true))

      writes = {}
      local invalid, invalidError = Applications.execute.applications_review(
        reviewTx(application('submitted', 1)), {
          application_id = 'group_apply_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 1,
          decision = 'approved', reason = 'approved'
        }, runtime)
      assert(invalid == nil and invalidError.code == 'INVALID_TRANSITION' and #writes == 0)

      local approved, approvedError, approvedEffects =
        Applications.execute.applications_review(reviewTx(application('reviewing', 1)), {
          application_id = 'group_apply_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 1,
          decision = 'approved', reason = 'approved'
        }, runtime)
      assert(approvedError == nil and approved.status == 'approved'
        and #approvedEffects == 3
        and approvedEffects[1].action == 'membership.approved'
        and approvedEffects[2].action == 'membership.activated'
        and approvedEffects[3].action == 'application.approved')
      assert(#activations == 1 and activations[1].id == 50
        and activations[1].group_id == 10
        and activations[1].character_id == 'character_target_0001')

      local ownerApproved, ownerApprovalError = Applications.execute.applications_review(
        reviewTx(application('reviewing', 1), true), {
          application_id = 'group_apply_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 1,
          decision = 'approved', reason = 'approved'
        }, runtime)
      assert(ownerApproved == nil and ownerApprovalError.code == 'GRADE_NOT_FOUND')

      writes = {}
      local expired, expiredError = Applications.execute.applications_review(
        reviewTx(application('reviewing', 0)), {
          application_id = 'group_apply_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 1,
          decision = 'rejected', reason = 'rejected'
        }, runtime)
      assert(expired == nil and expiredError.code == 'INVALID_TRANSITION' and #writes == 0)

      local withdrawTx = {}
      function withdrawTx.one()
        return { id = 30, public_id = 'group_apply_00000001', group_id = 10,
          character_id = 'character_target_0001', membership_id = 50,
          membership_public_id = 'group_member_00000001',
          membership_version = 2, membership_lifecycle = 'UNDER_REVIEW',
          membership_profile_version = 2,
          status = 'reviewing', version = 2,
          group_public_id = 'group_public_0001', inside_window = 1 }
      end
      function withdrawTx.affected() return 1 end
      function withdrawTx.query() return { affectedRows = 1 } end
      local withdrawn, withdrawError = Applications.execute.applications_withdraw(
        withdrawTx, { application_id = 'group_apply_00000001',
          actor_character_id = 'character_target_0001', expected_version = 2,
          reason = 'withdrawn' }, runtime)
      assert(withdrawError == nil and withdrawn.status == 'withdrawn'
        and withdrawn.version == 3)
      return submitted.status .. ':' .. reviewing.status .. ':'
        .. approved.status .. ':' .. withdrawn.status
    `);
    assert.equal(result, 'submitted:under_review:approved:withdrawn');
  } finally {
    engine.global.close();
  }
});

test('assignment completion and cancellation atomically close participants and linked duty', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadFoundation(engine);
    await preload(
      engine,
      'server.persistence.workflows_shared',
      'resources/synex_groups/server/persistence/workflows_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.workflows_assignments',
      'resources/synex_groups/server/persistence/workflows_assignments.lua',
    );
    const result = await engine.doString(`
      local Assignments = require('server.persistence.workflows_assignments')(Foundation)
      local runtime = {}
      function runtime.authorize() return { id = 21 } end
      function runtime.reason(_, fallback) return fallback end
      function runtime.touchGroup() return true end
      function runtime.success(id, kind, status, version)
        return { entity_id = id, entity_type = kind, status = status,
          version = version, replayed = false }
      end
      function runtime.effect(action, kind, id, groupId, characterId,
          before, after, reason, version)
        return { action = action, entityType = kind, entityId = id,
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = reason, version = version }
      end
      local writes = {}
      local tx = {}
      function tx.one()
        return { id = 70, public_id = 'group_assign_00000001', group_id = 10,
          status = 'active', version = 4, group_public_id = 'group_public_0001' }
      end
      function tx.affected(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        if sql:find('INSERT INTO synex_group_duty_events', 1, true) then return 2 end
        if sql:find('UPDATE synex_group_duty_sessions', 1, true) then return 2 end
        if sql:find('UPDATE synex_group_assignment_members', 1, true) then return 3 end
        if sql:find('UPDATE synex_group_assignments', 1, true) then return 1 end
        error('unexpected assignment write: ' .. sql)
      end
      local completed, completedError, effects = Assignments.execute.assignments_complete(
        tx, { assignment_id = 'group_assign_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 4,
          reason = 'operation_completed' }, runtime)
      assert(completedError == nil and completed.status == 'completed'
        and completed.version == 5 and #effects == 1)
      assert(effects[1].after.participants_removed == 3
        and effects[1].after.duty_sessions_closed == 2)
      assert(writes[1].sql:find('INSERT INTO synex_group_duty_events', 1, true)
        and writes[4].parameters[1] == 'completed')

      local cancelled, cancelError = Assignments.execute.assignments_cancel(
        tx, { assignment_id = 'group_assign_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 4,
          reason = 'operation_cancelled' }, runtime)
      assert(cancelError == nil and cancelled.status == 'cancelled')

      local mismatchTx = {}
      function mismatchTx.one() return tx.one() end
      function mismatchTx.affected(sql)
        if sql:find('INSERT INTO synex_group_duty_events', 1, true) then return 2 end
        if sql:find('UPDATE synex_group_duty_sessions', 1, true) then return 1 end
        error('assignment close continued after a duty-history mismatch')
      end
      local mismatch, mismatchError = Assignments.execute.assignments_complete(
        mismatchTx, { assignment_id = 'group_assign_00000001',
          actor_character_id = 'character_actor_0001', expected_version = 4,
          reason = 'operation_completed' }, runtime)
      assert(mismatch == nil and mismatchError.code == 'DATABASE_ERROR')
      return completed.status .. ':' .. cancelled.status .. ':' .. mismatchError.code
    `);
    assert.equal(result, 'completed:cancelled:DATABASE_ERROR');
  } finally {
    engine.global.close();
  }
});
