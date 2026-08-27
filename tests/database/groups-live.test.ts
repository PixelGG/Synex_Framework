import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import type { Connection, ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import {
  applyMigrations,
  liveDatabaseGate,
  loadMigrations,
  openLiveDatabase,
} from './harness.js';
import {
  createGroupsLiveRaceClient,
  runGroupsLiveServiceScenario,
  type GroupsLiveRaceOperation,
  type GroupsLiveRaceResult,
} from '../groups/live-service-database.js';

interface StoredIdRow extends RowDataPacket {
  id: string | number;
}

interface PublicIdRow extends RowDataPacket {
  id: string | number;
  public_id: string;
}

interface GroupsFixture {
  userIds: string[];
  characterIds: string[];
  typeIds: number[];
  groupIds: number[];
  mainTypeId?: number;
  capacityTypeId?: number;
  mainGroupId?: number;
  mainGroupPublicId?: string;
  groupCapacityGroupId?: number;
  gradeCapacityGroupId?: number;
  mainMemberGradeId?: number;
  mainChiefGradeId?: number;
  groupCapacityGradeId?: number;
  gradeCapacityGradeId?: number;
  capabilityRoleId?: number;
  exclusiveRoleId?: number;
  chiefRoleId?: number;
  representativeMembershipId?: number;
  promotionMembershipIds: number[];
  roleMembershipIds: number[];
  transitionMembershipId?: number;
  groupCapacityMembershipIds: number[];
  gradeCapacityMembershipIds: number[];
  invitationId?: number;
  invitationPublicId?: string;
  invitationMembershipId?: number;
  policyId?: number;
}

interface PlanRow extends RowDataPacket {
  table: string;
  type: string;
  key: string | null;
}

const gate = liveDatabaseGate();

function asNumber(value: unknown): number {
  const number = typeof value === 'number' ? value : Number.parseInt(String(value), 10);
  assert.ok(Number.isSafeInteger(number) && number > 0, `invalid internal identifier: ${String(value)}`);
  return number;
}

function token(prefix: string, length = 24): string {
  return `${prefix}_${randomUUID().replaceAll('-', '').slice(0, length)}`;
}

function characterId(): string {
  return randomUUID().replaceAll('-', '');
}

function placeholders(values: readonly unknown[]): string {
  assert.ok(values.length > 0);
  return values.map(() => '?').join(', ');
}

function databaseCode(error: unknown): string | undefined {
  if (!error || typeof error !== 'object' || !('code' in error)) return undefined;
  return typeof error.code === 'string' ? error.code : undefined;
}

function assertProductionLuaRace(
  results: readonly GroupsLiveRaceResult[],
  operation: GroupsLiveRaceOperation,
  expectedLoserCodes: readonly string[],
): void {
  assert.equal(results.length, 2);
  for (const result of results) {
    assert.equal(result.operation, operation);
    assert.equal(result.unexpectedErrors, 0);
  }
  const winners = results.filter((result) => result.ok);
  const losers = results.filter((result) => !result.ok);
  assert.equal(winners.length, 1, `${operation} must commit exactly one winner`);
  assert.equal(losers.length, 1, `${operation} must reject exactly one contender`);
  assert.ok(winners[0]?.value?.entity_id);
  assert.ok((winners[0]?.runtimeEffects ?? 0) >= 1);
  assert.equal(winners[0]?.auditEntries, winners[0]?.runtimeEffects);
  assert.equal(losers[0]?.runtimeEffects, 0);
  assert.equal(losers[0]?.auditEntries, 0);
  const loserError = losers[0]?.error;
  const failClosedPreflight = loserError?.code === 'DATABASE_ERROR'
    && loserError.retryable === true
    && loserError.message === 'The Groups authorization preflight is temporarily unavailable.';
  assert.ok(
    expectedLoserCodes.includes(String(loserError?.code)) || failClosedPreflight,
    `${operation} returned unexpected loser ${JSON.stringify(loserError)}`,
  );
}

async function setTransactionDefaults(connection: Connection): Promise<void> {
  await connection.query('SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED');
  await connection.query('SET SESSION innodb_lock_wait_timeout = 10');
}

async function insertCharacter(
  connection: Connection,
  fixture: GroupsFixture,
  index: number,
): Promise<string> {
  const userId = randomUUID();
  const id = characterId();
  await connection.query(
    `INSERT INTO synex_users (id, status, locale, metadata_json, version)
     VALUES (?, 'active', 'en', '{}', 1)`,
    [userId],
  );
  await connection.query(
    `INSERT INTO synex_character_slots (user_id, slot_limit, version)
     VALUES (?, 1, 1)`,
    [userId],
  );
  await connection.query(
    `INSERT INTO synex_characters
     (id, user_id, slot, status, first_name, last_name, metadata_json, version)
     VALUES (?, ?, 1, 'active', ?, 'Fixture', '{}', 1)`,
    [id, userId, `Live${index}`],
  );
  fixture.userIds.push(userId);
  fixture.characterIds.push(id);
  return id;
}

async function insertGroupType(
  connection: Connection,
  fixture: GroupsFixture,
  membershipLimit: number,
  activeMembershipLimit: number,
): Promise<{ id: number; key: string }> {
  const key = token('live_type', 12);
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_types
     (public_id, type_key, owner_resource, display_name, creation_mode,
      primary_policy, membership_limit, active_membership_limit, create_permission,
      required_approvals, approval_permission,
      hierarchy_enabled, relationships_enabled, status, version, schema_version,
      dynamic_creation, metadata_json)
     VALUES (?, ?, 'synex_groups', 'Live Groups type', 'dynamic', 'optional', ?, ?, ?, 0, ?,
             1, 1, 'active', 1, 1, 1, '{}')`,
    [token('gtype'), key, membershipLimit, activeMembershipLimit,
      `synex.groups.create.${key}`, `synex.groups.create.approve.${key}`],
  );
  const id = asNumber(result.insertId);
  fixture.typeIds.push(id);
  await connection.query(
    `INSERT INTO synex_group_type_membership_states
     (group_type_id, state_key, sort_order)
     SELECT ?, state_key,
       CASE state_key
         WHEN 'DRAFT' THEN 0 WHEN 'INVITED' THEN 1 WHEN 'APPLICANT' THEN 2
         WHEN 'UNDER_REVIEW' THEN 3 WHEN 'APPROVED' THEN 4 WHEN 'PROBATION' THEN 5
         WHEN 'ACTIVE' THEN 6 WHEN 'SUSPENDED' THEN 7 WHEN 'LEAVE' THEN 8
         WHEN 'INACTIVE' THEN 9 WHEN 'TERMINATED' THEN 10 WHEN 'BANNED' THEN 11
         WHEN 'LEFT' THEN 12 WHEN 'ARCHIVED' THEN 13 ELSE 15
       END
     FROM synex_group_membership_states WHERE status = 'active'`,
    [id],
  );
  await connection.query(
    `INSERT INTO synex_group_type_duty_states (group_type_id, state_key)
     SELECT ?, state_key FROM synex_group_duty_states WHERE status = 'active'`,
    [id],
  );
  return { id, key };
}

async function insertGroup(
  connection: Connection,
  fixture: GroupsFixture,
  groupType: { id: number; key: string },
  label: string,
): Promise<{ id: number; publicId: string; slug: string }> {
  const groupKey = token('live_group', 12);
  const publicId = token('group');
  await connection.beginTransaction();
  try {
    const [reservation] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_group_slug_reservations
       (slug, owner_kind, owner_public_id, version) VALUES (?, 'group', ?, 1)`,
      [groupKey, publicId],
    );
    assert.equal(reservation.affectedRows, 1);
    const [result] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_groups
       (public_id, group_key, display_name, group_type, status, metadata_json, version)
       VALUES (?, ?, ?, ?, 'active', '{}', 1)`,
      [publicId, groupKey, label, groupType.key],
    );
    const id = asNumber(result.insertId);
    await connection.query(
      `INSERT INTO synex_group_organization_profiles
       (group_id, group_type_id, slug, visibility, creation_source, lifecycle_state,
        lifecycle_reason_code, definition_key, definition_digest, suspended_at,
        archived_at, deleted_at, version, name, label, description, dynamic, metadata_json)
       VALUES (?, ?, ?, 'internal', 'dynamic', 'ACTIVE', 'live_test_created',
               NULL, NULL, NULL, NULL, NULL, 1, ?, ?, NULL, 1, '{}')`,
      [id, groupType.id, groupKey, label, label],
    );
    await connection.query(
      `INSERT INTO synex_group_hierarchy_closure
       (ancestor_group_id, descendant_group_id, depth) VALUES (?, ?, 0)`,
      [id, id],
    );
    await connection.query(
      `INSERT INTO synex_group_read_model_versions
       (group_id, model_version, invalidated_at) VALUES (?, 1, CURRENT_TIMESTAMP(6))`,
      [id],
    );
    await connection.commit();
    fixture.groupIds.push(id);
    return { id, publicId, slug: groupKey };
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function insertGrade(
  connection: Connection,
  groupId: number,
  key: string,
  rank: number,
  capacity: number | null,
): Promise<number> {
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_grades
     (public_id, group_id, grade_key, display_name, rank_value, status, version)
     VALUES (?, ?, ?, ?, ?, 'active', 1)`,
    [token('ggrade'), groupId, key, key === 'chief' ? 'Chief' : 'Member', rank],
  );
  const id = asNumber(result.insertId);
  await connection.query(
    `INSERT INTO synex_group_grade_controls
     (grade_id, member_limit, promotion_requires_approval, version)
     VALUES (?, ?, 0, 1)`,
    [id, capacity],
  );
  return id;
}

async function insertRole(
  connection: Connection,
  groupId: number,
  key: string,
  exclusivity: 'none' | 'group',
  holderLimit: number | null,
): Promise<number> {
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_roles
     (public_id, group_id, role_key, display_name, description, exclusivity,
      holder_limit, status, version)
     VALUES (?, ?, ?, ?, NULL, ?, ?, 'active', 1)`,
    [token('grole'), groupId, key, key === 'chief_command' ? 'Chief command' : 'Responder',
      exclusivity, holderLimit],
  );
  return asNumber(result.insertId);
}

async function insertMembership(
  connection: Connection,
  groupId: number,
  gradeId: number,
  character: string,
  lifecycle: 'ACTIVE' | 'SUSPENDED' | 'PROBATION',
): Promise<number> {
  const legacyStatus = lifecycle === 'SUSPENDED' ? 'suspended' : 'active';
  const [gradeRows] = await connection.query<RowDataPacket[]>(
    'SELECT grade_key FROM synex_group_grades WHERE id = ?',
    [gradeId],
  );
  assert.equal(gradeRows.length, 1);
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_memberships
     (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
     VALUES (?, ?, 'character', ?, ?, ?, 1)`,
    [token('gmember'), groupId, character, String(gradeRows[0]?.grade_key), legacyStatus],
  );
  const membershipId = asNumber(result.insertId);
  await connection.query(
    `INSERT INTO synex_group_membership_profiles
     (membership_id, group_id, character_id, lifecycle_state, visibility,
      joined_at, suspended_at, left_at, lifecycle_reason_code, version)
     VALUES (?, ?, ?, ?, 'members', CURRENT_TIMESTAMP(6),
             CASE WHEN ? = 'SUSPENDED' THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
             NULL, 'live_test_created', 1)`,
    [membershipId, groupId, character, lifecycle, lifecycle],
  );
  await connection.query(
    `INSERT INTO synex_group_membership_grades
     (membership_id, grade_id, assigned_by_ref, version)
     VALUES (?, ?, ?, 1)`,
    [membershipId, gradeId, character],
  );
  await connection.query(
    `INSERT INTO synex_group_reporting_closure
     (manager_membership_id, report_membership_id, depth) VALUES (?, ?, 0)`,
    [membershipId, membershipId],
  );
  return membershipId;
}

async function insertInvitationMembership(
  connection: Connection,
  groupId: number,
  groupPublicId: string,
  character: string,
): Promise<number> {
  const publicId = token('gmember');
  const [result] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_memberships
     (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
     VALUES (?, ?, 'character', ?, 'pending', 'active', 1)`,
    [publicId, groupId, character],
  );
  const membershipId = asNumber(result.insertId);
  await connection.query(
    `INSERT INTO synex_group_membership_profiles
     (membership_id, group_id, character_id, lifecycle_state, visibility,
      joined_at, suspended_at, left_at, lifecycle_reason_code, version)
     VALUES (?, ?, ?, 'INVITED', 'hidden', NULL, NULL, NULL,
             'live_test_invited', 1)`,
    [membershipId, groupId, character],
  );
  await connection.query(
    `INSERT INTO synex_group_reporting_closure
     (manager_membership_id, report_membership_id, depth) VALUES (?, ?, 0)`,
    [membershipId, membershipId],
  );
  await connection.query(
    `INSERT INTO synex_group_membership_events
     (event_id, membership_id, membership_version, event_type, actor_ref, snapshot_json)
     VALUES (?, ?, 1, 'added', NULL, ?)`,
    [token('gmevent'), membershipId, JSON.stringify({
      membership_id: publicId,
      group_id: groupPublicId,
      character_id: character,
      lifecycle_state: 'INVITED',
      version: 1,
    })],
  );
  return membershipId;
}

async function createFixture(connection: Connection, fixture: GroupsFixture): Promise<void> {
  const characters: string[] = [];
  for (let index = 0; index < 11; index += 1) {
    characters.push(await insertCharacter(connection, fixture, index));
  }

  const mainType = await insertGroupType(connection, fixture, 100, 100);
  const capacityType = await insertGroupType(connection, fixture, 100, 1);
  fixture.mainTypeId = mainType.id;
  fixture.capacityTypeId = capacityType.id;

  const main = await insertGroup(connection, fixture, mainType, 'Live Groups main');
  const groupCapacity = await insertGroup(
    connection, fixture, capacityType, 'Live Groups member capacity',
  );
  const gradeCapacity = await insertGroup(
    connection, fixture, mainType, 'Live Groups grade capacity',
  );
  fixture.mainGroupId = main.id;
  fixture.mainGroupPublicId = main.publicId;
  fixture.groupCapacityGroupId = groupCapacity.id;
  fixture.gradeCapacityGroupId = gradeCapacity.id;

  fixture.mainMemberGradeId = await insertGrade(connection, main.id, 'member', 0, null);
  fixture.mainChiefGradeId = await insertGrade(connection, main.id, 'chief', 100, 1);
  fixture.groupCapacityGradeId = await insertGrade(
    connection, groupCapacity.id, 'member', 0, null,
  );
  fixture.gradeCapacityGradeId = await insertGrade(
    connection, gradeCapacity.id, 'member', 0, 1,
  );

  fixture.capabilityRoleId = await insertRole(connection, main.id, 'responder', 'none', null);
  fixture.exclusiveRoleId = await insertRole(
    connection, main.id, 'incident_command', 'group', 1,
  );
  fixture.chiefRoleId = await insertRole(
    connection, main.id, 'chief_command', 'group', 1,
  );
  await connection.query(
    `INSERT INTO synex_group_role_capabilities
     (role_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
     VALUES (?, 'police.records.read', 'allow', 'group', '', 1, 1)`,
    [fixture.capabilityRoleId],
  );

  fixture.representativeMembershipId = await insertMembership(
    connection, main.id, fixture.mainMemberGradeId, characters[0]!, 'ACTIVE',
  );
  await connection.query(
    `INSERT INTO synex_group_membership_roles
     (public_id, membership_id, role_id, exclusive_role_id, status, valid_from,
      valid_until, revoked_at, assigned_by_ref, reason_code, version)
     VALUES (?, ?, ?, NULL, 'active', CURRENT_TIMESTAMP(6), NULL, NULL, ?,
             'live_test_created', 1)`,
    [token('gmrole'), fixture.representativeMembershipId, fixture.capabilityRoleId, characters[0]],
  );

  for (const character of characters.slice(1, 3)) {
    fixture.promotionMembershipIds.push(await insertMembership(
      connection, main.id, fixture.mainMemberGradeId, character, 'ACTIVE',
    ));
  }
  for (const character of characters.slice(3, 5)) {
    fixture.roleMembershipIds.push(await insertMembership(
      connection, main.id, fixture.mainMemberGradeId, character, 'ACTIVE',
    ));
  }
  fixture.transitionMembershipId = await insertMembership(
    connection, main.id, fixture.mainMemberGradeId, characters[5]!, 'ACTIVE',
  );
  for (const character of characters.slice(7, 9)) {
    fixture.groupCapacityMembershipIds.push(await insertMembership(
      connection, groupCapacity.id, fixture.groupCapacityGradeId, character, 'SUSPENDED',
    ));
  }
  fixture.gradeCapacityMembershipIds.push(await insertMembership(
    connection, gradeCapacity.id, fixture.gradeCapacityGradeId, characters[9]!, 'SUSPENDED',
  ));
  fixture.gradeCapacityMembershipIds.push(await insertMembership(
    connection, gradeCapacity.id, fixture.gradeCapacityGradeId, characters[10]!, 'PROBATION',
  ));

  fixture.invitationPublicId = token('ginvite');
  fixture.invitationMembershipId = await insertInvitationMembership(
    connection, main.id, main.publicId, characters[6]!,
  );
  const [invitation] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_invitations
     (public_id, group_id, character_id, membership_id, grade_id,
      status, invited_by_membership_id,
      reason_code, expires_at, responded_at, version)
     VALUES (?, ?, ?, ?, ?, 'pending', ?, 'live_test_created',
             TIMESTAMPADD(HOUR, 1, CURRENT_TIMESTAMP(6)), NULL, 1)`,
    [fixture.invitationPublicId, main.id, characters[6], fixture.invitationMembershipId,
      fixture.mainMemberGradeId, fixture.representativeMembershipId],
  );
  fixture.invitationId = asNumber(invitation.insertId);

  const [policy] = await connection.query<ResultSetHeader>(
    `INSERT INTO synex_group_policies
     (public_id, group_id, policy_key, display_name, status, default_effect, version)
     VALUES (?, ?, 'members.manage', 'Manage members', 'active', 'deny', 1)`,
    [token('gpolicy'), main.id],
  );
  fixture.policyId = asNumber(policy.insertId);
  await connection.query(
    `INSERT INTO synex_group_policy_rules
     (policy_id, rule_key, priority, effect, action_pattern, subject_kind,
      scope_kind, scope_ref, condition_json, version)
     VALUES (?, 'initial_allow', 10, 'allow', 'synex.groups.members.manage',
             'membership', 'group', '', NULL, 1)`,
    [fixture.policyId],
  );

  await connection.query(
    `INSERT INTO synex_group_duty_sessions
     (public_id, membership_id, state_key, status, reason_code, version,
      assignment_id, metadata_json)
     VALUES (?, ?, 'on_duty', 'open', 'live_test_created', 1, NULL, '{}')`,
    [token('gduty'), fixture.representativeMembershipId],
  );
}

async function prepareProductionLuaRaceFixture(
  connection: Connection,
  fixture: GroupsFixture,
): Promise<void> {
  assert.ok(fixture.mainGroupId && fixture.representativeMembershipId && fixture.capacityTypeId
    && fixture.groupCapacityGroupId && fixture.gradeCapacityGroupId);

  const mainOwnerGradeId = await insertGrade(
    connection, fixture.mainGroupId, 'owner', 1000, null,
  );
  const groupCapacityOwnerGradeId = await insertGrade(
    connection, fixture.groupCapacityGroupId, 'owner', 1000, null,
  );
  const gradeCapacityOwnerGradeId = await insertGrade(
    connection, fixture.gradeCapacityGroupId, 'owner', 1000, null,
  );
  await connection.query(
    `UPDATE synex_group_membership_grades
     SET grade_id = ?, assigned_at = CURRENT_TIMESTAMP(6)
     WHERE membership_id = ?`,
    [mainOwnerGradeId, fixture.representativeMembershipId],
  );
  await connection.query(
    `UPDATE synex_group_memberships SET role_key = 'owner'
     WHERE id = ?`,
    [fixture.representativeMembershipId],
  );

  await connection.query(
    `UPDATE synex_group_types SET active_membership_limit = 2
     WHERE id = ?`,
    [fixture.capacityTypeId],
  );
  await insertMembership(
    connection,
    fixture.groupCapacityGroupId,
    groupCapacityOwnerGradeId,
    fixture.characterIds[0]!,
    'ACTIVE',
  );
  await insertMembership(
    connection,
    fixture.gradeCapacityGroupId,
    gradeCapacityOwnerGradeId,
    fixture.characterIds[0]!,
    'ACTIVE',
  );

  for (const groupId of fixture.groupIds) {
    await connection.query(
      `INSERT INTO synex_group_default_capabilities
       (group_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
       VALUES (?, 'synex.groups.*', 'allow', 'group', '', 0, 1)`,
      [groupId],
    );
  }
}

async function cleanupFixture(connection: Connection, fixture: GroupsFixture): Promise<void> {
  if (fixture.groupIds.length > 0) {
    const inGroups = placeholders(fixture.groupIds);
    await connection.query(
      `DELETE duty_event FROM synex_group_duty_events AS duty_event
       INNER JOIN synex_group_duty_sessions AS duty_session
         ON duty_session.id = duty_event.duty_session_id
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = duty_session.membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE duty_session FROM synex_group_duty_sessions AS duty_session
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = duty_session.membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE membership_event FROM synex_group_membership_events AS membership_event
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = membership_event.membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE invitation_role FROM synex_group_invitation_roles AS invitation_role
       INNER JOIN synex_group_invitations AS invitation
         ON invitation.id = invitation_role.invitation_id
       WHERE invitation.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_invitations WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE policy_rule FROM synex_group_policy_rules AS policy_rule
       INNER JOIN synex_group_policies AS policy ON policy.id = policy_rule.policy_id
       WHERE policy.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_policies WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE capability FROM synex_group_role_capabilities AS capability
       INNER JOIN synex_group_roles AS role_record ON role_record.id = capability.role_id
       WHERE role_record.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE assignment FROM synex_group_membership_roles AS assignment
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = assignment.membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE closure FROM synex_group_reporting_closure AS closure
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = closure.report_membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE assigned FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_memberships AS membership
         ON membership.id = assigned.membership_id
       WHERE membership.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_membership_profiles WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_memberships WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE control FROM synex_group_grade_controls AS control
       INNER JOIN synex_group_grades AS grade ON grade.id = control.grade_id
       WHERE grade.group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_grades WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_roles WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_default_capabilities WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_read_model_versions WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_group_hierarchy_closure
       WHERE ancestor_group_id IN (${inGroups}) OR descendant_group_id IN (${inGroups})`,
      [...fixture.groupIds, ...fixture.groupIds],
    );
    await connection.query(
      `DELETE FROM synex_group_organization_profiles WHERE group_id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE reservation FROM synex_group_slug_reservations AS reservation
       INNER JOIN synex_groups AS group_record
         ON reservation.owner_kind = 'group'
        AND reservation.owner_public_id = group_record.public_id
       WHERE group_record.id IN (${inGroups})`,
      fixture.groupIds,
    );
    await connection.query(
      `DELETE FROM synex_groups WHERE id IN (${inGroups})`,
      fixture.groupIds,
    );
  }
  if (fixture.typeIds.length > 0) {
    const inTypes = placeholders(fixture.typeIds);
    await connection.query(
      `DELETE FROM synex_group_type_membership_states WHERE group_type_id IN (${inTypes})`,
      fixture.typeIds,
    );
    await connection.query(
      `DELETE FROM synex_group_type_duty_states WHERE group_type_id IN (${inTypes})`,
      fixture.typeIds,
    );
    await connection.query(
      `DELETE FROM synex_group_types WHERE id IN (${inTypes})`,
      fixture.typeIds,
    );
  }
  if (fixture.characterIds.length > 0) {
    await connection.query(
      `DELETE FROM synex_characters WHERE id IN (${placeholders(fixture.characterIds)})`,
      fixture.characterIds,
    );
  }
  if (fixture.userIds.length > 0) {
    const inUsers = placeholders(fixture.userIds);
    await connection.query(
      `DELETE FROM synex_character_slots WHERE user_id IN (${inUsers})`,
      fixture.userIds,
    );
    await connection.query(
      `DELETE FROM synex_users WHERE id IN (${inUsers})`,
      fixture.userIds,
    );
  }
}

async function cleanupTraceEvidence(connection: Connection, traceId: string): Promise<void> {
  await connection.query(
    `DELETE delivery FROM synex_group_audit_delivery AS delivery
     INNER JOIN synex_group_domain_history AS history ON history.id = delivery.history_id
     WHERE history.correlation_id = ?`,
    [traceId],
  );
  await connection.query(
    `DELETE outbox_record FROM synex_group_outbox AS outbox_record
     INNER JOIN synex_group_domain_history AS history
       ON history.event_id = outbox_record.event_id
     WHERE history.correlation_id = ?`,
    [traceId],
  );
  await connection.query(
    'DELETE FROM synex_group_domain_history WHERE correlation_id = ?',
    [traceId],
  );
}

async function promoteToCapacityGrade(
  connection: Connection,
  membershipId: number,
  gradeId: number,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [grades] = await connection.query<RowDataPacket[]>(
      `SELECT grade.grade_key, control.member_limit
       FROM synex_group_grades AS grade
       INNER JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
       WHERE grade.id = ? AND grade.status = 'active' FOR UPDATE`,
      [gradeId],
    );
    assert.equal(grades.length, 1);
    const limit = Number(grades[0]?.member_limit);
    const [counts] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = assigned.membership_id
       WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'
         AND assigned.membership_id <> ?`,
      [gradeId, membershipId],
    );
    if (Number(counts[0]?.count) >= limit) {
      await connection.rollback();
      return false;
    }
    await connection.query(
      `UPDATE synex_group_membership_grades
       SET grade_id = ?, version = version + 1, assigned_at = CURRENT_TIMESTAMP(6)
       WHERE membership_id = ?`,
      [gradeId, membershipId],
    );
    const [updated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_memberships
       SET role_key = ?, version = version + 1
       WHERE id = ? AND version = 1`,
      [String(grades[0]?.grade_key), membershipId],
    );
    if (updated.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function assignExclusiveRole(
  connection: Connection,
  membershipId: number,
  roleId: number,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [roles] = await connection.query<RowDataPacket[]>(
      `SELECT id, holder_limit FROM synex_group_roles
       WHERE id = ? AND status = 'active' FOR UPDATE`,
      [roleId],
    );
    assert.equal(roles.length, 1);
    const [counts] = await connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_roles
       WHERE role_id = ? AND status = 'active'
         AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP(6))`,
      [roleId],
    );
    if (Number(counts[0]?.count) >= Number(roles[0]?.holder_limit)) {
      await connection.rollback();
      return false;
    }
    await connection.query(
      `INSERT INTO synex_group_membership_roles
       (public_id, membership_id, role_id, exclusive_role_id, status, valid_from,
        valid_until, revoked_at, reason_code, version)
       VALUES (?, ?, ?, ?, 'active', CURRENT_TIMESTAMP(6), NULL, NULL,
               'live_concurrency_test', 1)`,
      [token('gmrole'), membershipId, roleId, roleId],
    );
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    if (databaseCode(error) === 'ER_DUP_ENTRY') return false;
    throw error;
  }
}

async function acceptInvitation(connection: Connection, invitationId: number): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [invitations] = await connection.query<RowDataPacket[]>(
      `SELECT id, group_id, character_id, membership_id, grade_id, status, version
       FROM synex_group_invitations WHERE id = ? FOR UPDATE`,
      [invitationId],
    );
    const invitation = invitations[0];
    if (!invitation || invitation.status !== 'pending') {
      await connection.rollback();
      return false;
    }
    const [grades] = await connection.query<RowDataPacket[]>(
      `SELECT public_id, grade_key FROM synex_group_grades
       WHERE id = ? AND group_id = ? AND status = 'active' FOR UPDATE`,
      [invitation.grade_id, invitation.group_id],
    );
    assert.equal(grades.length, 1);
    const [memberships] = await connection.query<RowDataPacket[]>(
      `SELECT membership.id, membership.public_id, membership.version,
              profile.version AS profile_version, profile.lifecycle_state,
              group_record.public_id AS group_public_id
       FROM synex_group_memberships AS membership
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = membership.id
       INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
       WHERE membership.id = ? AND membership.group_id = ?
         AND profile.character_id = ? FOR UPDATE`,
      [invitation.membership_id, invitation.group_id, invitation.character_id],
    );
    const membership = memberships[0];
    if (!membership || membership.lifecycle_state !== 'INVITED'
      || Number(membership.version) !== 1 || Number(membership.profile_version) !== 1) {
      await connection.rollback();
      return false;
    }
    const [membershipUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_memberships
       SET role_key = ?, status = 'active', version = version + 1
       WHERE id = ? AND version = 1`,
      [String(grades[0]?.grade_key), invitation.membership_id],
    );
    const [profileUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_membership_profiles
       SET lifecycle_state = 'ACTIVE', visibility = 'members',
           joined_at = CURRENT_TIMESTAMP(6), suspended_at = NULL, left_at = NULL,
           lifecycle_reason_code = 'invitation_accepted', version = version + 1
       WHERE membership_id = ? AND version = 1 AND lifecycle_state = 'INVITED'`,
      [invitation.membership_id],
    );
    if (membershipUpdated.affectedRows !== 1 || profileUpdated.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.query(
      `INSERT INTO synex_group_membership_grades
       (membership_id, grade_id, assigned_by_ref, version) VALUES (?, ?, ?, 1)`,
      [invitation.membership_id, invitation.grade_id, invitation.character_id],
    );
    await connection.query(
      `INSERT INTO synex_group_membership_events
       (event_id, membership_id, membership_version, event_type, actor_ref, snapshot_json)
       VALUES (?, ?, 2, 'transitioned', ?, ?)`,
      [token('gmevent'), invitation.membership_id, invitation.character_id,
        JSON.stringify({
          membership_id: String(membership.public_id),
          group_id: String(membership.group_public_id),
          character_id: String(invitation.character_id),
          grade_id: String(grades[0]?.public_id),
          lifecycle_state: 'ACTIVE',
          version: 2,
        })],
    );
    const [accepted] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_invitations
       SET status = 'accepted', responded_at = CURRENT_TIMESTAMP(6), version = version + 1
       WHERE id = ? AND status = 'pending' AND version = ?`,
      [invitationId, invitation.version],
    );
    if (accepted.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    if (databaseCode(error) === 'ER_DUP_ENTRY') return false;
    throw error;
  }
}

async function changeMembershipState(
  connection: Connection,
  membershipId: number,
  target: 'SUSPENDED' | 'TERMINATED',
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [memberships] = await connection.query<RowDataPacket[]>(
      `SELECT membership.version, profile.version AS profile_version
       FROM synex_group_memberships AS membership
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = membership.id
       WHERE membership.id = ? FOR UPDATE`,
      [membershipId],
    );
    if (memberships.length !== 1 || Number(memberships[0]?.version) !== 1
      || Number(memberships[0]?.profile_version) !== 1) {
      await connection.rollback();
      return false;
    }
    const [membershipUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_memberships
       SET status = ?, version = version + 1 WHERE id = ? AND version = 1`,
      [target === 'TERMINATED' ? 'removed' : 'suspended', membershipId],
    );
    assert.equal(membershipUpdated.affectedRows, 1);
    const [profileUpdated] = target === 'TERMINATED'
      ? await connection.query<ResultSetHeader>(
        `UPDATE synex_group_membership_profiles
         SET lifecycle_state = 'TERMINATED', lifecycle_reason_code = 'live_terminated',
             joined_at = COALESCE(joined_at, CURRENT_TIMESTAMP(6)),
             left_at = CURRENT_TIMESTAMP(6), version = version + 1
         WHERE membership_id = ? AND version = 1`,
        [membershipId],
      )
      : await connection.query<ResultSetHeader>(
        `UPDATE synex_group_membership_profiles
         SET lifecycle_state = 'SUSPENDED', lifecycle_reason_code = 'live_suspended',
             joined_at = COALESCE(joined_at, CURRENT_TIMESTAMP(6)),
             suspended_at = COALESCE(suspended_at, CURRENT_TIMESTAMP(6)),
             left_at = NULL, version = version + 1
         WHERE membership_id = ? AND version = 1`,
        [membershipId],
      );
    assert.equal(profileUpdated.affectedRows, 1);
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function updatePolicy(
  connection: Connection,
  policyId: number,
  ruleKey: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [policies] = await connection.query<RowDataPacket[]>(
      'SELECT version FROM synex_group_policies WHERE id = ? FOR UPDATE',
      [policyId],
    );
    if (policies.length !== 1 || Number(policies[0]?.version) !== 1) {
      await connection.rollback();
      return false;
    }
    const [updated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_policies
       SET display_name = ?, version = version + 1 WHERE id = ? AND version = 1`,
      [`Policy ${ruleKey}`, policyId],
    );
    if (updated.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.query('DELETE FROM synex_group_policy_rules WHERE policy_id = ?', [policyId]);
    await connection.query(
      `INSERT INTO synex_group_policy_rules
       (policy_id, rule_key, priority, effect, action_pattern, subject_kind,
        scope_kind, scope_ref, condition_json, version)
       VALUES (?, ?, 20, 'allow', 'synex.groups.members.manage', 'membership',
               'group', '', NULL, 1)`,
      [policyId, ruleKey],
    );
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function activateMembership(
  connection: Connection,
  membershipId: number,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [memberships] = await connection.query<RowDataPacket[]>(
      `SELECT membership.group_id, membership.version,
              profile.version AS profile_version, profile.lifecycle_state
       FROM synex_group_memberships AS membership
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = membership.id
       WHERE membership.id = ? FOR UPDATE`,
      [membershipId],
    );
    const membership = memberships[0];
    if (!membership || Number(membership.version) !== 1
      || Number(membership.profile_version) !== 1
      || membership.lifecycle_state === 'ACTIVE') {
      await connection.rollback();
      return false;
    }
    const [types] = await connection.query<RowDataPacket[]>(
      `SELECT group_type.active_membership_limit
       FROM synex_group_organization_profiles AS profile
       INNER JOIN synex_group_types AS group_type ON group_type.id = profile.group_type_id
       WHERE profile.group_id = ? FOR UPDATE`,
      [membership.group_id],
    );
    assert.equal(types.length, 1);
    const groupLimit = types[0]?.active_membership_limit;
    if (groupLimit !== null && groupLimit !== undefined) {
      const [counts] = await connection.query<RowDataPacket[]>(
        `SELECT COUNT(*) AS count FROM synex_group_membership_profiles
         WHERE group_id = ? AND lifecycle_state = 'ACTIVE' AND membership_id <> ?`,
        [membership.group_id, membershipId],
      );
      if (Number(counts[0]?.count) >= Number(groupLimit)) {
        await connection.rollback();
        return false;
      }
    }
    const [grades] = await connection.query<RowDataPacket[]>(
      `SELECT assigned.grade_id, control.member_limit
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
       LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
       WHERE assigned.membership_id = ? AND grade.status = 'active' FOR UPDATE`,
      [membershipId],
    );
    assert.equal(grades.length, 1);
    const gradeLimit = grades[0]?.member_limit;
    if (gradeLimit !== null && gradeLimit !== undefined) {
      const [counts] = await connection.query<RowDataPacket[]>(
        `SELECT COUNT(*) AS count
         FROM synex_group_membership_grades AS assigned
         INNER JOIN synex_group_membership_profiles AS profile
           ON profile.membership_id = assigned.membership_id
         WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'
           AND assigned.membership_id <> ?`,
        [grades[0]?.grade_id, membershipId],
      );
      if (Number(counts[0]?.count) >= Number(gradeLimit)) {
        await connection.rollback();
        return false;
      }
    }
    const [membershipUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_memberships
       SET status = 'active', version = version + 1 WHERE id = ? AND version = 1`,
      [membershipId],
    );
    const [profileUpdated] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_membership_profiles
       SET lifecycle_state = 'ACTIVE', lifecycle_reason_code = 'live_reactivated',
           joined_at = COALESCE(joined_at, CURRENT_TIMESTAMP(6)), suspended_at = NULL,
           left_at = NULL, version = version + 1
       WHERE membership_id = ? AND version = 1`,
      [membershipId],
    );
    if (membershipUpdated.affectedRows !== 1 || profileUpdated.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function assertPlanUses(
  connection: Connection,
  sql: string,
  parameters: readonly unknown[],
  table: string,
  index: string,
): Promise<void> {
  const [rows] = await connection.query<PlanRow[]>(`EXPLAIN ${sql}`, [...parameters]);
  const row = rows.find((candidate) => String(candidate.table) === table);
  assert.ok(row, `EXPLAIN did not include ${table}`);
  assert.equal(String(row.key), index, `${table} did not use ${index}`);
  assert.notEqual(String(row.type).toUpperCase(), 'ALL', `${table} used a full scan`);
}

async function attemptDirectGroupCreate(
  connection: Connection,
  slug: string,
  publicId: string,
  groupType: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [reservation] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_group_slug_reservations
       (slug, owner_kind, owner_public_id, version) VALUES (?, 'group', ?, 1)`,
      [slug, publicId],
    );
    if (reservation.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.query(
      `INSERT INTO synex_groups
       (public_id, group_key, display_name, group_type, status, metadata_json, version)
       VALUES (?, ?, 'Slug race group', ?, 'active', '{}', 1)`,
      [publicId, slug, groupType],
    );
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function attemptPendingCreationRequest(
  connection: Connection,
  slug: string,
  publicId: string,
  groupType: { id: number; key: string },
  actorCharacterId: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [reservation] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_group_slug_reservations
       (slug, owner_kind, owner_public_id, version)
       VALUES (?, 'creation_request', ?, 1)`,
      [slug, publicId],
    );
    if (reservation.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    await connection.query(
      `INSERT INTO synex_group_creation_requests
       (public_id, group_type_id, requested_by_ref, idempotency_key,
        requested_slug, request_json, required_approvals, approval_count,
        creator_permission, approval_permission, type_schema_version, type_version,
        status, expires_at, version)
       VALUES (?, ?, ?, ?, ?, '{}', 1, 0, ?, ?, 1, 1, 'pending',
               TIMESTAMPADD(HOUR, 1, CURRENT_TIMESTAMP(6)), 1)`,
      [
        publicId,
        groupType.id,
        actorCharacterId,
        token('creation_idempotency'),
        slug,
        `synex.groups.create.${groupType.key}`,
        `synex.groups.create.approve.${groupType.key}`,
      ],
    );
    await connection.commit();
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function attemptGroupRename(
  connection: Connection,
  group: { id: number; publicId: string; slug: string },
  nextSlug: string,
): Promise<boolean> {
  await connection.beginTransaction();
  try {
    const [reservation] = await connection.query<ResultSetHeader>(
      `INSERT IGNORE INTO synex_group_slug_reservations
       (slug, owner_kind, owner_public_id, version) VALUES (?, 'group', ?, 1)`,
      [nextSlug, group.publicId],
    );
    if (reservation.affectedRows !== 1) {
      await connection.rollback();
      return false;
    }
    const [current] = await connection.query<RowDataPacket[]>(
      `SELECT version FROM synex_group_slug_reservations
       WHERE slug = ? AND owner_kind = 'group' AND owner_public_id = ? FOR UPDATE`,
      [group.slug, group.publicId],
    );
    assert.equal(current.length, 1);
    const [legacy] = await connection.query<ResultSetHeader>(
      `UPDATE synex_groups SET group_key = ?, version = version + 1
       WHERE id = ? AND public_id = ? AND group_key = ?`,
      [nextSlug, group.id, group.publicId, group.slug],
    );
    const [profile] = await connection.query<ResultSetHeader>(
      `UPDATE synex_group_organization_profiles SET slug = ?, version = version + 1
       WHERE group_id = ? AND slug = ?`,
      [nextSlug, group.id, group.slug],
    );
    assert.equal(legacy.affectedRows, 1);
    assert.equal(profile.affectedRows, 1);
    const [released] = await connection.query<ResultSetHeader>(
      `DELETE FROM synex_group_slug_reservations
       WHERE slug = ? AND owner_kind = 'group' AND owner_public_id = ?`,
      [group.slug, group.publicId],
    );
    assert.equal(released.affectedRows, 1);
    await connection.commit();
    group.slug = nextSlug;
    return true;
  } catch (error) {
    await connection.rollback();
    throw error;
  }
}

async function cleanupSlugRace(
  connection: Connection,
  slug: string,
  groupPublicId: string,
  requestPublicId: string,
): Promise<void> {
  await connection.query('DELETE FROM synex_group_slug_reservations WHERE slug = ?', [slug]);
  await connection.query(
    'DELETE FROM synex_group_creation_requests WHERE public_id = ?',
    [requestPublicId],
  );
  await connection.query('DELETE FROM synex_groups WHERE public_id = ?', [groupPublicId]);
}

test('live Groups migrations apply and replay with enforced relational metadata', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection, databaseName } = await openLiveDatabase();
  try {
    const migrations = await loadMigrations();
    const groupMigrations = migrations.filter(
      (migration) => migration.directory === 'resources/synex_groups/migrations',
    );
    assert.ok(groupMigrations.length >= 19, 'the complete Groups migration chain is missing');
    await applyMigrations(connection, migrations);
    const creationApprovalMigration = groupMigrations.find(
      (migration) => migration.file === '025_dynamic_group_creation_approvals.sql',
    );
    assert.ok(creationApprovalMigration, 'Groups migration 025 is missing');
    const workflowEntitiesMigration = groupMigrations.find(
      (migration) => migration.file === '030_membership_workflow_entities.sql',
    );
    assert.ok(workflowEntitiesMigration, 'Groups migration 030 is missing');

    // A replay must repair the normalized reservation index for legacy rows,
    // including UUID identifiers which predate the namespaced ID allocator.
    const replayPublicId = randomUUID();
    const replaySlug = token('replay-slug', 12);
    await connection.query(
      `INSERT INTO synex_groups
       (public_id, group_key, display_name, group_type, status, metadata_json, version)
       VALUES (?, ?, 'Migration replay group', 'unaffiliated', 'active', '{}', 1)`,
      [replayPublicId, replaySlug],
    );
    await applyMigrations(connection, [creationApprovalMigration]);
    await applyMigrations(connection, [creationApprovalMigration]);
    const [replayReservations] = await connection.query<RowDataPacket[]>(
      `SELECT owner_kind, owner_public_id, version
       FROM synex_group_slug_reservations WHERE slug = ?`,
      [replaySlug],
    );
    assert.equal(replayReservations.length, 1);
    assert.equal(replayReservations[0]?.owner_kind, 'group');
    assert.equal(replayReservations[0]?.owner_public_id, replayPublicId);
    assert.equal(Number(replayReservations[0]?.version), 1);
    await connection.query(
      'DELETE FROM synex_group_slug_reservations WHERE slug = ?',
      [replaySlug],
    );
    await connection.query('DELETE FROM synex_groups WHERE public_id = ?', [replayPublicId]);

    await applyMigrations(connection, groupMigrations);
    await applyMigrations(connection, groupMigrations);

    await connection.query(
      'ALTER TABLE synex_group_membership_events '
        + 'DROP CONSTRAINT chk_group_membership_events_type_v2',
    );
    await connection.query(
      `ALTER TABLE synex_group_membership_events
       ADD CONSTRAINT chk_group_membership_events_type_v2
       CHECK (event_type IN (
         'added', 'role_changed', 'suspended', 'removed', 'transitioned',
         'grade_changed', 'visibility_changed', 'tampered'
       ))`,
    );
    await assert.rejects(
      applyMigrations(connection, [workflowEntitiesMigration]),
      /workflow entity verification failed/u,
    );
    await connection.query(
      'ALTER TABLE synex_group_membership_events '
        + 'DROP CONSTRAINT chk_group_membership_events_type_v2',
    );
    await applyMigrations(connection, [workflowEntitiesMigration]);

    const [tables] = await connection.query<RowDataPacket[]>(
      `SELECT table_name, engine FROM information_schema.tables
       WHERE table_schema = ? AND table_name LIKE 'synex_group\\_%' ESCAPE '\\\\'`,
      [databaseName],
    );
    assert.ok(tables.length >= 40, 'the Groups relational model is incomplete');
    assert.ok(tables.every((row) => String(row.engine).toUpperCase() === 'INNODB'));

    const expectedChecks = new Set([
      'chk_group_membership_profiles_lifecycle',
      'chk_group_membership_profiles_dates',
      'chk_group_membership_roles_exclusive',
      'chk_group_policy_rules_scope',
      'chk_group_default_capability_delegable',
      'chk_group_grade_capability_delegable',
      'chk_group_role_capability_delegable',
      'chk_group_membership_capability_delegable',
      'chk_group_types_active_membership_limit',
      'chk_group_types_member_limit_order',
      'chk_group_types_create_permission',
    ]);
    const [checks] = await connection.query<RowDataPacket[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE constraint_schema = ? AND constraint_type = 'CHECK'
         AND constraint_name IN (${placeholders([...expectedChecks])})`,
      [databaseName, ...expectedChecks],
    );
    assert.deepEqual(new Set(checks.map((row) => String(row.constraint_name))), expectedChecks);

    const expectedForeignKeys = new Set([
      'fk_group_membership_profiles_member',
      'fk_group_membership_profiles_group',
      'fk_group_membership_grades_membership',
      'fk_group_membership_grades_grade',
      'fk_group_membership_roles_membership',
      'fk_group_membership_roles_role',
      'fk_group_role_capabilities_role',
      'fk_group_policy_rules_policy',
    ]);
    const [foreignKeys] = await connection.query<RowDataPacket[]>(
      `SELECT constraint_name FROM information_schema.table_constraints
       WHERE constraint_schema = ? AND constraint_type = 'FOREIGN KEY'
         AND constraint_name IN (${placeholders([...expectedForeignKeys])})`,
      [databaseName, ...expectedForeignKeys],
    );
    assert.deepEqual(
      new Set(foreignKeys.map((row) => String(row.constraint_name))),
      expectedForeignKeys,
    );

    const expectedIndexes = new Map<string, string[]>([
      ['uq_group_memberships_subject', ['group_id', 'subject_kind', 'subject_ref']],
      ['idx_group_membership_profiles_character',
        ['character_id', 'lifecycle_state', 'group_id', 'membership_id']],
      ['idx_group_membership_profiles_group',
        ['group_id', 'lifecycle_state', 'visibility', 'membership_id']],
      ['idx_group_membership_roles_role',
        ['role_id', 'status', 'valid_until', 'membership_id']],
      ['idx_group_role_capability_lookup',
        ['capability_pattern', 'effect', 'scope_kind', 'role_id']],
      ['idx_group_policy_rules_eval',
        ['policy_id', 'priority', 'effect', 'action_pattern', 'id']],
      ['idx_group_duty_sessions_state', ['status', 'state_key', 'started_at', 'id']],
    ]);
    const [indexRows] = await connection.query<RowDataPacket[]>(
      `SELECT index_name, seq_in_index, column_name, index_type, sub_part
       FROM information_schema.statistics
       WHERE table_schema = ? AND index_name IN (${placeholders([...expectedIndexes.keys()])})
       ORDER BY index_name, seq_in_index`,
      [databaseName, ...expectedIndexes.keys()],
    );
    for (const [indexName, columns] of expectedIndexes) {
      const rows = indexRows.filter((row) => row.index_name === indexName);
      assert.deepEqual(rows.map((row) => String(row.column_name)), columns, indexName);
      assert.ok(rows.every((row) => String(row.index_type).toUpperCase() === 'BTREE'));
      assert.ok(rows.every((row) => row.sub_part === null));
    }

    const boundaryTypeKey = `a-${'b'.repeat(62)}`;
    assert.equal(boundaryTypeKey.length, 64);
    const [boundaryType] = await connection.query<ResultSetHeader>(
      `INSERT INTO synex_group_types
       (public_id, type_key, owner_resource, display_name, creation_mode,
         primary_policy, membership_limit, active_membership_limit, create_permission,
         required_approvals, approval_permission,
         hierarchy_enabled, relationships_enabled, status, version, schema_version,
         dynamic_creation, metadata_json)
       VALUES (?, ?, 'synex_groups', 'Boundary type', 'dynamic', 'optional',
                100000, 100000, ?, 0, ?, 1, 1, 'active', 1, 1, 1, '{}')`,
      [token('gtype'), boundaryTypeKey, `synex.groups.create.${boundaryTypeKey}`,
        `synex.groups.create.approve.${boundaryTypeKey}`],
    );
    const boundaryTypeId = asNumber(boundaryType.insertId);
    await connection.query(
      `INSERT INTO synex_group_type_default_grades
       (group_type_id, grade_key, display_name, rank_value, member_limit, sort_order, version)
       VALUES (?, 'member', 'Member', 0, 100000, 0, 1)`,
      [boundaryTypeId],
    );
    await connection.query(
      `INSERT INTO synex_group_type_default_roles
       (group_type_id, role_key, display_name, assignable, exclusive,
        holder_limit, sort_order, version)
       VALUES (?, 'member', 'Member', 1, 0, 100000, 0, 1)`,
      [boundaryTypeId],
    );
    const [boundaryRows] = await connection.query<RowDataPacket[]>(
      `SELECT membership_limit, active_membership_limit, create_permission
       FROM synex_group_types WHERE id = ?`,
      [boundaryTypeId],
    );
    assert.equal(Number(boundaryRows[0]?.membership_limit), 100000);
    assert.equal(Number(boundaryRows[0]?.active_membership_limit), 100000);
    assert.equal(boundaryRows[0]?.create_permission, `synex.groups.create.${boundaryTypeKey}`);

    const boundaryGroupPublicId = randomUUID();
    const boundarySlug = `g-${'s'.repeat(62)}`;
    const boundaryEntityKey = `k-${'z'.repeat(62)}`;
    assert.equal(boundarySlug.length, 64);
    assert.equal(boundaryEntityKey.length, 64);
    await connection.beginTransaction();
    let boundaryGroupId: number;
    try {
      await connection.query(
        `INSERT INTO synex_group_slug_reservations
         (slug, owner_kind, owner_public_id, version) VALUES (?, 'group', ?, 1)`,
        [boundarySlug, boundaryGroupPublicId],
      );
      const [boundaryGroup] = await connection.query<ResultSetHeader>(
        `INSERT INTO synex_groups
         (public_id, group_key, display_name, group_type, status, metadata_json, version)
         VALUES (?, ?, 'Identifier boundary group', ?, 'active', '{}', 1)`,
        [boundaryGroupPublicId, boundarySlug, boundaryTypeKey],
      );
      boundaryGroupId = asNumber(boundaryGroup.insertId);
      await connection.query(
        `INSERT INTO synex_group_grades
         (public_id, group_id, grade_key, display_name, rank_value, status, version)
         VALUES (?, ?, ?, 'Identifier boundary grade', 1, 'active', 1)`,
        [token('ggrade'), boundaryGroupId, boundaryEntityKey],
      );
      await connection.query(
        `INSERT INTO synex_group_roles
         (public_id, group_id, role_key, display_name, exclusivity, status, version)
         VALUES (?, ?, ?, 'Identifier boundary role', 'none', 'active', 1)`,
        [token('grole'), boundaryGroupId, boundaryEntityKey],
      );
      await connection.query(
        `INSERT INTO synex_group_memberships
         (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
         VALUES (?, ?, 'user', ?, ?, 'active', 1)`,
        [token('gmember'), boundaryGroupId, token('subject'), boundaryEntityKey],
      );
      await connection.commit();
    } catch (error) {
      await connection.rollback();
      throw error;
    }
    const [identifierRows] = await connection.query<RowDataPacket[]>(
      `SELECT group_record.group_type, grade.grade_key, role_record.role_key,
              membership.role_key AS membership_role_key
       FROM synex_groups AS group_record
       INNER JOIN synex_group_grades AS grade ON grade.group_id = group_record.id
       INNER JOIN synex_group_roles AS role_record ON role_record.group_id = group_record.id
       INNER JOIN synex_group_memberships AS membership
         ON membership.group_id = group_record.id
       WHERE group_record.id = ?`,
      [boundaryGroupId],
    );
    assert.equal(identifierRows.length, 1);
    assert.equal(identifierRows[0]?.group_type, boundaryTypeKey);
    assert.equal(identifierRows[0]?.grade_key, boundaryEntityKey);
    assert.equal(identifierRows[0]?.role_key, boundaryEntityKey);
    assert.equal(identifierRows[0]?.membership_role_key, boundaryEntityKey);
    await connection.query('DELETE FROM synex_group_memberships WHERE group_id = ?', [boundaryGroupId]);
    await connection.query('DELETE FROM synex_group_roles WHERE group_id = ?', [boundaryGroupId]);
    await connection.query('DELETE FROM synex_group_grades WHERE group_id = ?', [boundaryGroupId]);
    await connection.query(
      `DELETE FROM synex_group_slug_reservations
       WHERE slug = ? AND owner_kind = 'group' AND owner_public_id = ?`,
      [boundarySlug, boundaryGroupPublicId],
    );
    await connection.query('DELETE FROM synex_groups WHERE id = ?', [boundaryGroupId]);
    await connection.query(
      'DELETE FROM synex_group_type_default_roles WHERE group_type_id = ?',
      [boundaryTypeId],
    );
    await connection.query(
      'DELETE FROM synex_group_type_default_grades WHERE group_type_id = ?',
      [boundaryTypeId],
    );
    await connection.query('DELETE FROM synex_group_types WHERE id = ?', [boundaryTypeId]);

    const [routines] = await connection.query<RowDataPacket[]>(
      `SELECT routine_name FROM information_schema.routines
       WHERE routine_schema = ? AND routine_name LIKE 'synex_groups_migrate\\_%' ESCAPE '\\\\'`,
      [databaseName],
    );
    assert.equal(routines.length, 0, 'migration helper procedures must not survive replay');
  } finally {
    await connection.end();
  }
});

test('live public Groups service mutation and read preserve one trace through MariaDB and event dispatch', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const { connection } = await openLiveDatabase();
  const fixture: GroupsFixture = {
    userIds: [],
    characterIds: [],
    typeIds: [],
    groupIds: [],
    promotionMembershipIds: [],
    roleMembershipIds: [],
    groupCapacityMembershipIds: [],
    gradeCapacityMembershipIds: [],
  };
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const traceId = `trace_groups_${suffix}`;
  try {
    await applyMigrations(connection, await loadMigrations());
    await setTransactionDefaults(connection);
    await createFixture(connection, fixture);
    assert.ok(fixture.capabilityRoleId && fixture.mainGroupPublicId);
    assert.ok(fixture.characterIds[0]);
    await connection.query(
      `INSERT INTO synex_group_role_capabilities
       (role_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
       VALUES (?, 'synex.groups.update', 'allow', 'group', '', 0, 1)`,
      [fixture.capabilityRoleId],
    );

    const nextLabel = `Lua service ${suffix}`;
    const scenario = await runGroupsLiveServiceScenario(connection, {
      actorCharacterId: fixture.characterIds[0],
      groupId: fixture.mainGroupPublicId,
      expectedVersion: 1,
      idempotencyKey: `groups_live_${suffix}`,
      nextLabel,
      traceId,
      eventSuffix: suffix,
    });

    assert.deepEqual(scenario.mutation, {
      entity_id: fixture.mainGroupPublicId,
      entity_type: 'group',
      status: 'active',
      version: 2,
      replayed: false,
    });
    assert.equal(scenario.read.group_id, fixture.mainGroupPublicId);
    assert.equal(scenario.read.label, nextLabel);
    assert.equal(scenario.read.version, 2);
    assert.equal(scenario.runtimeEffects, 1);
    assert.equal(scenario.databaseCalls.transactions, 1);
    assert.ok(scenario.databaseCalls.reads >= 2);
    assert.ok(scenario.databaseCalls.writes >= 4);

    const [evidence] = await connection.query<RowDataPacket[]>(
      `SELECT history.id AS history_id, history.event_id, history.aggregate_id,
              history.aggregate_version, history.event_type, history.actor_kind,
              history.actor_ref, history.reason_code, history.correlation_id,
              history.context_json, history.before_json, history.after_json,
              delivery.state AS audit_state,
              delivery.external_event_id AS audit_event_id,
              outbox_record.state AS outbox_state,
              outbox_record.payload_json AS outbox_payload
       FROM synex_group_domain_history AS history
       INNER JOIN synex_group_audit_delivery AS delivery
         ON delivery.history_id = history.id
       INNER JOIN synex_group_outbox AS outbox_record
         ON outbox_record.event_id = history.event_id
       WHERE history.correlation_id = ?`,
      [traceId],
    );
    assert.equal(evidence.length, 1);
    const row = evidence[0]!;
    assert.equal(row.aggregate_id, fixture.mainGroupPublicId);
    assert.equal(Number(row.aggregate_version), 2);
    assert.equal(row.event_type, 'synex.groups.group.updated');
    assert.equal(row.actor_kind, 'character');
    assert.equal(row.actor_ref, fixture.characterIds[0]);
    assert.equal(row.reason_code, 'live_service_update');
    assert.equal(row.correlation_id, traceId);
    assert.equal(row.audit_state, 'delivered');
    assert.equal(row.audit_event_id, scenario.audit.eventId);
    assert.equal(row.outbox_state, 'published');

    const context = JSON.parse(String(row.context_json)) as Record<string, unknown>;
    const before = JSON.parse(String(row.before_json)) as Record<string, unknown>;
    const after = JSON.parse(String(row.after_json)) as Record<string, unknown>;
    const payload = JSON.parse(String(row.outbox_payload)) as Record<string, unknown>;
    assert.equal(context.traceId, traceId);
    assert.equal(context.caller, 'synex_groups_live_probe');
    assert.equal(context.operation, 'group.updated');
    assert.equal(before.version, 1);
    assert.equal(after.version, 2);
    assert.equal(after.label, nextLabel);
    assert.equal(payload.event_id, row.event_id);
    assert.equal(payload.group_id, fixture.mainGroupPublicId);

    assert.equal(scenario.audit.action, 'group.updated');
    assert.equal(scenario.audit.targetId, fixture.mainGroupPublicId);
    assert.equal(scenario.audit.traceId, traceId);
    assert.equal(scenario.published.eventType, row.event_type);
    assert.equal(scenario.published.eventId, row.event_id);
    assert.equal(scenario.published.payloadEventId, row.event_id);
    assert.equal(scenario.published.aggregateId, fixture.mainGroupPublicId);
    assert.equal(scenario.published.traceId, traceId);
    assert.ok(scenario.report.claimed >= 1);
    assert.ok(scenario.report.published >= 1);
  } finally {
    try {
      await cleanupTraceEvidence(connection, traceId);
      await cleanupFixture(connection, fixture);
    } finally {
      await connection.end();
    }
  }
});

test('live production Lua handlers serialize independent-connection Groups races', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const secondary = await openLiveDatabase();
  const fixture: GroupsFixture = {
    userIds: [],
    characterIds: [],
    typeIds: [],
    groupIds: [],
    promotionMembershipIds: [],
    roleMembershipIds: [],
    groupCapacityMembershipIds: [],
    gradeCapacityMembershipIds: [],
  };
  const traceIds: string[] = [];
  const clients: Array<Awaited<ReturnType<typeof createGroupsLiveRaceClient>>> = [];
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    await setTransactionDefaults(primary.connection);
    await setTransactionDefaults(secondary.connection);
    await createFixture(primary.connection, fixture);
    await prepareProductionLuaRaceFixture(primary.connection, fixture);

    assert.ok(fixture.mainGroupId && fixture.mainGroupPublicId
      && fixture.mainChiefGradeId && fixture.exclusiveRoleId && fixture.chiefRoleId
      && fixture.representativeMembershipId && fixture.policyId
      && fixture.invitationId && fixture.invitationPublicId
      && fixture.transitionMembershipId && fixture.groupCapacityGroupId
      && fixture.gradeCapacityGroupId);

    const targetMembershipIds = [
      ...fixture.promotionMembershipIds,
      ...fixture.roleMembershipIds,
      fixture.transitionMembershipId,
      ...fixture.groupCapacityMembershipIds,
      ...fixture.gradeCapacityMembershipIds,
    ];
    const [membershipRows] = await primary.connection.query<PublicIdRow[]>(
      `SELECT id, public_id FROM synex_group_memberships
       WHERE id IN (${placeholders(targetMembershipIds)})`,
      targetMembershipIds,
    );
    assert.equal(membershipRows.length, targetMembershipIds.length);
    const memberships = new Map(
      membershipRows.map((row) => [asNumber(row.id), String(row.public_id)]),
    );
    const membershipPublicId = (internalId: number): string => {
      const publicId = memberships.get(internalId);
      assert.ok(publicId, `missing membership public id for ${internalId}`);
      return publicId;
    };

    const [gradeRows] = await primary.connection.query<PublicIdRow[]>(
      'SELECT id, public_id FROM synex_group_grades WHERE id = ?',
      [fixture.mainChiefGradeId],
    );
    const [roleRows] = await primary.connection.query<PublicIdRow[]>(
      'SELECT id, public_id FROM synex_group_roles WHERE id IN (?, ?)',
      [fixture.exclusiveRoleId, fixture.chiefRoleId],
    );
    assert.equal(gradeRows.length, 1);
    assert.equal(roleRows.length, 2);
    const rolePublicIds = new Map(
      roleRows.map((row) => [asNumber(row.id), String(row.public_id)]),
    );

    const left = await createGroupsLiveRaceClient(
      primary.connection, token('lua_race_left', 12),
    );
    const right = await createGroupsLiveRaceClient(
      secondary.connection, token('lua_race_right', 12),
    );
    clients.push(left, right);

    const race = async (
      operation: GroupsLiveRaceOperation,
      leftRequest: Record<string, unknown>,
      rightRequest: Record<string, unknown>,
      loserCodes: readonly string[],
    ): Promise<void> => {
      const leftTrace = token('trace_lua_left', 16);
      const rightTrace = token('trace_lua_right', 16);
      traceIds.push(leftTrace, rightTrace);
      const results = await Promise.all([
        left.invoke({
          operation,
          request: { ...leftRequest, idempotency_key: token('idem_lua_left', 16) },
          traceId: leftTrace,
        }),
        right.invoke({
          operation,
          request: { ...rightRequest, idempotency_key: token('idem_lua_right', 16) },
          traceId: rightTrace,
        }),
      ]);
      assertProductionLuaRace(results, operation, loserCodes);
    };

    const actorCharacterId = fixture.characterIds[0]!;
    const chiefGradePublicId = String(gradeRows[0]?.public_id);
    await race(
      'members_set_grade',
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.promotionMembershipIds[0]!),
        grade_id: chiefGradePublicId,
        expected_version: 1,
        reason: 'live_lua_grade_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.promotionMembershipIds[1]!),
        grade_id: chiefGradePublicId,
        expected_version: 1,
        reason: 'live_lua_grade_race',
      },
      ['GRADE_CAPACITY_REACHED', 'CONCURRENT_MODIFICATION'],
    );
    const [chiefs] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = assigned.membership_id
       WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'`,
      [fixture.mainChiefGradeId],
    );
    assert.equal(Number(chiefs[0]?.count), 1);

    const exclusiveRolePublicId = rolePublicIds.get(fixture.exclusiveRoleId);
    assert.ok(exclusiveRolePublicId);
    await race(
      'roles_assign',
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.roleMembershipIds[0]!),
        role_id: exclusiveRolePublicId,
        reason: 'live_lua_exclusive_role_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.roleMembershipIds[1]!),
        role_id: exclusiveRolePublicId,
        reason: 'live_lua_exclusive_role_race',
      },
      ['ROLE_EXCLUSIVE_CONFLICT'],
    );
    const [exclusiveHolders] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_roles
       WHERE role_id = ? AND exclusive_role_id = ? AND status = 'active'`,
      [fixture.exclusiveRoleId, fixture.exclusiveRoleId],
    );
    assert.equal(Number(exclusiveHolders[0]?.count), 1);

    const chiefRolePublicId = rolePublicIds.get(fixture.chiefRoleId);
    assert.ok(chiefRolePublicId);
    await race(
      'roles_assign',
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.roleMembershipIds[0]!),
        role_id: chiefRolePublicId,
        reason: 'live_lua_chief_role_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.roleMembershipIds[1]!),
        role_id: chiefRolePublicId,
        reason: 'live_lua_chief_role_race',
      },
      ['ROLE_EXCLUSIVE_CONFLICT'],
    );
    const [chiefRoleHolders] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_roles
       WHERE role_id = ? AND exclusive_role_id = ? AND status = 'active'`,
      [fixture.chiefRoleId, fixture.chiefRoleId],
    );
    assert.equal(Number(chiefRoleHolders[0]?.count), 1);

    const invitedCharacterId = fixture.characterIds[6]!;
    await race(
      'members_accept',
      {
        actor_character_id: invitedCharacterId,
        invitation_id: fixture.invitationPublicId,
      },
      {
        actor_character_id: invitedCharacterId,
        invitation_id: fixture.invitationPublicId,
      },
      ['INVALID_TRANSITION'],
    );
    const [accepted] = await primary.connection.query<RowDataPacket[]>(
      `SELECT invitation.status, invitation.version,
              (SELECT COUNT(*) FROM synex_group_membership_profiles AS profile
               WHERE profile.group_id = invitation.group_id
                 AND profile.character_id = invitation.character_id) AS memberships
       FROM synex_group_invitations AS invitation WHERE invitation.id = ?`,
      [fixture.invitationId],
    );
    assert.equal(accepted[0]?.status, 'accepted');
    assert.equal(Number(accepted[0]?.version), 2);
    assert.equal(Number(accepted[0]?.memberships), 1);

    const transitionMembershipPublicId = membershipPublicId(fixture.transitionMembershipId);
    await race(
      'members_transition',
      {
        actor_character_id: actorCharacterId,
        membership_id: transitionMembershipPublicId,
        expected_version: 1,
        status: 'TERMINATED',
        reason: 'live_lua_transition_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: transitionMembershipPublicId,
        expected_version: 1,
        status: 'SUSPENDED',
        reason: 'live_lua_transition_race',
      },
      ['CONCURRENT_MODIFICATION', 'INVALID_TRANSITION'],
    );
    const [transitioned] = await primary.connection.query<RowDataPacket[]>(
      `SELECT membership.version, membership.status, profile.version AS profile_version,
              profile.lifecycle_state
       FROM synex_group_memberships AS membership
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = membership.id
       WHERE membership.id = ?`,
      [fixture.transitionMembershipId],
    );
    assert.equal(Number(transitioned[0]?.version), 2);
    assert.equal(Number(transitioned[0]?.profile_version), 2);
    assert.ok(['SUSPENDED', 'TERMINATED'].includes(String(transitioned[0]?.lifecycle_state)));

    const policyDefinition = (ruleKey: string): Record<string, unknown> => ({
      display_name: `Policy ${ruleKey}`,
      default_effect: 'deny',
      status: 'active',
      rules: [{
        key: ruleKey,
        priority: 20,
        effect: 'allow',
        action: 'synex.groups.members.manage',
        subject_kind: 'membership',
        scope: 'group',
        scope_ref: '',
      }],
    });
    await race(
      'policies_set',
      {
        actor_character_id: actorCharacterId,
        group_id: fixture.mainGroupPublicId,
        action: 'members.manage',
        expected_version: 1,
        definition: policyDefinition('concurrent_lua_alpha'),
        reason: 'live_lua_policy_race',
      },
      {
        actor_character_id: actorCharacterId,
        group_id: fixture.mainGroupPublicId,
        action: 'members.manage',
        expected_version: 1,
        definition: policyDefinition('concurrent_lua_beta'),
        reason: 'live_lua_policy_race',
      },
      ['CONCURRENT_MODIFICATION'],
    );
    const [policy] = await primary.connection.query<RowDataPacket[]>(
      `SELECT policy.version, COUNT(rule_record.id) AS rules,
              MIN(rule_record.rule_key) AS rule_key
       FROM synex_group_policies AS policy
       LEFT JOIN synex_group_policy_rules AS rule_record ON rule_record.policy_id = policy.id
       WHERE policy.id = ? GROUP BY policy.id, policy.version`,
      [fixture.policyId],
    );
    assert.equal(Number(policy[0]?.version), 2);
    assert.equal(Number(policy[0]?.rules), 1);
    assert.ok(['concurrent_lua_alpha', 'concurrent_lua_beta']
      .includes(String(policy[0]?.rule_key)));

    await race(
      'members_transition',
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.groupCapacityMembershipIds[0]!),
        expected_version: 1,
        status: 'ACTIVE',
        reason: 'live_lua_group_capacity_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.groupCapacityMembershipIds[1]!),
        expected_version: 1,
        status: 'ACTIVE',
        reason: 'live_lua_group_capacity_race',
      },
      ['MEMBER_LIMIT_REACHED', 'CONCURRENT_MODIFICATION'],
    );
    const [activeAtGroupLimit] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_profiles
       WHERE group_id = ? AND lifecycle_state = 'ACTIVE'`,
      [fixture.groupCapacityGroupId],
    );
    assert.equal(Number(activeAtGroupLimit[0]?.count), 2);

    await race(
      'members_transition',
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.gradeCapacityMembershipIds[0]!),
        expected_version: 1,
        status: 'ACTIVE',
        reason: 'live_lua_grade_capacity_race',
      },
      {
        actor_character_id: actorCharacterId,
        membership_id: membershipPublicId(fixture.gradeCapacityMembershipIds[1]!),
        expected_version: 1,
        status: 'ACTIVE',
        reason: 'live_lua_grade_capacity_race',
      },
      ['GRADE_CAPACITY_REACHED', 'CONCURRENT_MODIFICATION'],
    );
    const [activeAtGradeLimit] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = assigned.membership_id
       WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'`,
      [fixture.gradeCapacityGradeId],
    );
    assert.equal(Number(activeAtGradeLimit[0]?.count), 1);

  } finally {
    for (const client of clients) client.close();
    try {
      for (const traceId of traceIds) await cleanupTraceEvidence(primary.connection, traceId);
      await cleanupFixture(primary.connection, fixture);
    } finally {
      await secondary.connection.end();
      await primary.connection.end();
    }
  }
});

test('live Groups relational flow, hot paths, and independent-connection races stay consistent', {
  skip: gate.enabled ? false : gate.reason,
}, async () => {
  const primary = await openLiveDatabase();
  const secondary = await openLiveDatabase();
  const fixture: GroupsFixture = {
    userIds: [],
    characterIds: [],
    typeIds: [],
    groupIds: [],
    promotionMembershipIds: [],
    roleMembershipIds: [],
    groupCapacityMembershipIds: [],
    gradeCapacityMembershipIds: [],
  };
  try {
    await applyMigrations(primary.connection, await loadMigrations());
    await setTransactionDefaults(primary.connection);
    await setTransactionDefaults(secondary.connection);
    await createFixture(primary.connection, fixture);

    assert.ok(fixture.mainGroupId && fixture.mainGroupPublicId
      && fixture.mainChiefGradeId && fixture.exclusiveRoleId && fixture.chiefRoleId
      && fixture.representativeMembershipId && fixture.policyId && fixture.invitationId
      && fixture.groupCapacityGroupId && fixture.gradeCapacityGroupId);
    assert.equal(fixture.promotionMembershipIds.length, 2);
    assert.equal(fixture.roleMembershipIds.length, 2);
    assert.equal(fixture.groupCapacityMembershipIds.length, 2);
    assert.equal(fixture.gradeCapacityMembershipIds.length, 2);

    const [raceTypeRows] = await primary.connection.query<RowDataPacket[]>(
      'SELECT type_key FROM synex_group_types WHERE id = ?',
      [fixture.mainTypeId],
    );
    assert.equal(raceTypeRows.length, 1);
    const raceType = {
      id: fixture.mainTypeId!,
      key: String(raceTypeRows[0]?.type_key),
    };

    // Independent READ COMMITTED transactions must serialize a direct create
    // and an approval-backed request through one normalized slug row.
    const createRequestSlug = token('race-create-request', 12);
    const directPublicId = token('groups_group');
    const requestPublicId = token('groups_creation');
    const createRequestResults = await Promise.all([
      attemptDirectGroupCreate(
        primary.connection, createRequestSlug, directPublicId, raceType.key,
      ),
      attemptPendingCreationRequest(
        secondary.connection,
        createRequestSlug,
        requestPublicId,
        raceType,
        fixture.characterIds[0]!,
      ),
    ]);
    assert.equal(createRequestResults.filter(Boolean).length, 1);
    const [createRequestReservation] = await primary.connection.query<RowDataPacket[]>(
      `SELECT owner_kind, owner_public_id FROM synex_group_slug_reservations
       WHERE slug = ?`,
      [createRequestSlug],
    );
    assert.equal(createRequestReservation.length, 1);
    const [createRequestOwners] = await primary.connection.query<RowDataPacket[]>(
      `SELECT
         (SELECT COUNT(*) FROM synex_groups WHERE group_key = ?)
         + (SELECT COUNT(*) FROM synex_group_creation_requests
              WHERE requested_slug = ? AND status IN ('pending', 'approved')) AS count`,
      [createRequestSlug, createRequestSlug],
    );
    assert.equal(Number(createRequestOwners[0]?.count), 1);
    await cleanupSlugRace(
      primary.connection, createRequestSlug, directPublicId, requestPublicId,
    );

    // Rename acquires the replacement first. A concurrent direct create can
    // either win or lose, but no committed state may share or lose the slug.
    const renameDirectSource = await insertGroup(
      primary.connection, fixture, raceType, 'Rename versus direct create',
    );
    const renameDirectTarget = token('race-rename-direct', 12);
    const renameDirectCompetitor = token('groups_group');
    const renameDirectResults = await Promise.all([
      attemptGroupRename(primary.connection, renameDirectSource, renameDirectTarget),
      attemptDirectGroupCreate(
        secondary.connection, renameDirectTarget, renameDirectCompetitor, raceType.key,
      ),
    ]);
    assert.equal(renameDirectResults.filter(Boolean).length, 1);
    const [renameDirectReservation] = await primary.connection.query<RowDataPacket[]>(
      `SELECT owner_kind, owner_public_id FROM synex_group_slug_reservations
       WHERE slug = ?`,
      [renameDirectTarget],
    );
    assert.equal(renameDirectReservation.length, 1);
    assert.equal(renameDirectReservation[0]?.owner_kind, 'group');
    const [renameDirectSourceReservation] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_slug_reservations AS reservation
       INNER JOIN synex_groups AS group_record
         ON group_record.public_id = reservation.owner_public_id
        AND group_record.group_key = reservation.slug
       WHERE reservation.owner_kind = 'group' AND group_record.id = ?`,
      [renameDirectSource.id],
    );
    assert.equal(Number(renameDirectSourceReservation[0]?.count), 1);
    await primary.connection.query(
      `DELETE FROM synex_group_slug_reservations
       WHERE owner_kind = 'group' AND owner_public_id = ?`,
      [renameDirectCompetitor],
    );
    await primary.connection.query(
      'DELETE FROM synex_groups WHERE public_id = ?',
      [renameDirectCompetitor],
    );

    // The same guarantee applies when the competing owner is a pending
    // approval request rather than an already materialized group.
    const renameRequestSource = await insertGroup(
      primary.connection, fixture, raceType, 'Rename versus creation request',
    );
    const renameRequestTarget = token('race-rename-request', 12);
    const renameRequestCompetitor = token('groups_creation');
    const renameRequestResults = await Promise.all([
      attemptGroupRename(primary.connection, renameRequestSource, renameRequestTarget),
      attemptPendingCreationRequest(
        secondary.connection,
        renameRequestTarget,
        renameRequestCompetitor,
        raceType,
        fixture.characterIds[1]!,
      ),
    ]);
    assert.equal(renameRequestResults.filter(Boolean).length, 1);
    const [renameRequestReservation] = await primary.connection.query<RowDataPacket[]>(
      `SELECT owner_kind, owner_public_id FROM synex_group_slug_reservations
       WHERE slug = ?`,
      [renameRequestTarget],
    );
    assert.equal(renameRequestReservation.length, 1);
    const [renameRequestSourceReservation] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_slug_reservations AS reservation
       INNER JOIN synex_groups AS group_record
         ON group_record.public_id = reservation.owner_public_id
        AND group_record.group_key = reservation.slug
       WHERE reservation.owner_kind = 'group' AND group_record.id = ?`,
      [renameRequestSource.id],
    );
    assert.equal(Number(renameRequestSourceReservation[0]?.count), 1);
    await primary.connection.query(
      `DELETE FROM synex_group_slug_reservations
       WHERE owner_kind = 'creation_request' AND owner_public_id = ?`,
      [renameRequestCompetitor],
    );
    await primary.connection.query(
      'DELETE FROM synex_group_creation_requests WHERE public_id = ?',
      [renameRequestCompetitor],
    );

    const [flow] = await primary.connection.query<RowDataPacket[]>(
      `SELECT character_record.id AS character_id, group_record.public_id AS group_id,
              membership.public_id AS membership_id, grade.public_id AS grade_id,
              role_record.public_id AS role_id, capability.capability_pattern,
              capability.effect, capability.delegable
       FROM synex_characters AS character_record
       INNER JOIN synex_group_memberships AS membership
         ON membership.subject_kind = 'character'
        AND membership.subject_ref = character_record.id
       INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
       INNER JOIN synex_group_membership_grades AS assigned_grade
         ON assigned_grade.membership_id = membership.id
       INNER JOIN synex_group_grades AS grade ON grade.id = assigned_grade.grade_id
       INNER JOIN synex_group_membership_roles AS assigned_role
         ON assigned_role.membership_id = membership.id AND assigned_role.status = 'active'
       INNER JOIN synex_group_roles AS role_record ON role_record.id = assigned_role.role_id
       INNER JOIN synex_group_role_capabilities AS capability
         ON capability.role_id = role_record.id
       WHERE character_record.id = ? AND group_record.public_id = ?`,
      [fixture.characterIds[0], fixture.mainGroupPublicId],
    );
    assert.equal(flow.length, 1);
    assert.equal(flow[0]?.capability_pattern, 'police.records.read');
    assert.equal(flow[0]?.effect, 'allow');
    assert.equal(Number(flow[0]?.delegable), 1);

    const promotionResults = await Promise.all([
      promoteToCapacityGrade(
        primary.connection, fixture.promotionMembershipIds[0]!, fixture.mainChiefGradeId,
      ),
      promoteToCapacityGrade(
        secondary.connection, fixture.promotionMembershipIds[1]!, fixture.mainChiefGradeId,
      ),
    ]);
    assert.equal(promotionResults.filter(Boolean).length, 1);
    const [chiefs] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = assigned.membership_id
       WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'`,
      [fixture.mainChiefGradeId],
    );
    assert.equal(Number(chiefs[0]?.count), 1);

    const roleResults = await Promise.all([
      assignExclusiveRole(
        primary.connection, fixture.roleMembershipIds[0]!, fixture.exclusiveRoleId,
      ),
      assignExclusiveRole(
        secondary.connection, fixture.roleMembershipIds[1]!, fixture.exclusiveRoleId,
      ),
    ]);
    assert.equal(roleResults.filter(Boolean).length, 1);
    const [exclusiveHolders] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_roles
       WHERE role_id = ? AND exclusive_role_id = ? AND status = 'active'`,
      [fixture.exclusiveRoleId, fixture.exclusiveRoleId],
    );
    assert.equal(Number(exclusiveHolders[0]?.count), 1);

    // Chief is modeled as its own exclusive functional role. Keep this race
    // independent from both grade promotion and the generic exclusive-role
    // race above so each required concurrency case has distinct evidence.
    const chiefAssignmentResults = await Promise.all([
      assignExclusiveRole(
        primary.connection, fixture.roleMembershipIds[0]!, fixture.chiefRoleId,
      ),
      assignExclusiveRole(
        secondary.connection, fixture.roleMembershipIds[1]!, fixture.chiefRoleId,
      ),
    ]);
    assert.equal(chiefAssignmentResults.filter(Boolean).length, 1);
    const [chiefRoleHolders] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_roles
       WHERE role_id = ? AND exclusive_role_id = ? AND status = 'active'`,
      [fixture.chiefRoleId, fixture.chiefRoleId],
    );
    assert.equal(Number(chiefRoleHolders[0]?.count), 1);

    const inviteResults = await Promise.all([
      acceptInvitation(primary.connection, fixture.invitationId),
      acceptInvitation(secondary.connection, fixture.invitationId),
    ]);
    assert.equal(inviteResults.filter(Boolean).length, 1);
    const [accepted] = await primary.connection.query<RowDataPacket[]>(
      `SELECT invitation.status, invitation.version,
              (SELECT COUNT(*) FROM synex_group_membership_profiles AS profile
               WHERE profile.group_id = invitation.group_id
                 AND profile.character_id = invitation.character_id) AS memberships
       FROM synex_group_invitations AS invitation WHERE invitation.id = ?`,
      [fixture.invitationId],
    );
    assert.equal(accepted[0]?.status, 'accepted');
    assert.equal(Number(accepted[0]?.version), 2);
    assert.equal(Number(accepted[0]?.memberships), 1);

    const transitionResults = await Promise.all([
      changeMembershipState(primary.connection, fixture.transitionMembershipId!, 'TERMINATED'),
      changeMembershipState(secondary.connection, fixture.transitionMembershipId!, 'SUSPENDED'),
    ]);
    assert.equal(transitionResults.filter(Boolean).length, 1);
    const [transitioned] = await primary.connection.query<RowDataPacket[]>(
      `SELECT membership.version, membership.status, profile.version AS profile_version,
              profile.lifecycle_state
       FROM synex_group_memberships AS membership
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = membership.id
       WHERE membership.id = ?`,
      [fixture.transitionMembershipId],
    );
    assert.equal(Number(transitioned[0]?.version), 2);
    assert.equal(Number(transitioned[0]?.profile_version), 2);
    assert.ok(['SUSPENDED', 'TERMINATED'].includes(String(transitioned[0]?.lifecycle_state)));

    const policyResults = await Promise.all([
      updatePolicy(primary.connection, fixture.policyId, 'concurrent_alpha'),
      updatePolicy(secondary.connection, fixture.policyId, 'concurrent_beta'),
    ]);
    assert.equal(policyResults.filter(Boolean).length, 1);
    const [policy] = await primary.connection.query<RowDataPacket[]>(
      `SELECT policy.version, COUNT(rule_record.id) AS rules,
              MIN(rule_record.rule_key) AS rule_key
       FROM synex_group_policies AS policy
       LEFT JOIN synex_group_policy_rules AS rule_record ON rule_record.policy_id = policy.id
       WHERE policy.id = ? GROUP BY policy.id, policy.version`,
      [fixture.policyId],
    );
    assert.equal(Number(policy[0]?.version), 2);
    assert.equal(Number(policy[0]?.rules), 1);
    assert.ok(['concurrent_alpha', 'concurrent_beta'].includes(String(policy[0]?.rule_key)));

    const groupActivationResults = await Promise.all([
      activateMembership(primary.connection, fixture.groupCapacityMembershipIds[0]!),
      activateMembership(secondary.connection, fixture.groupCapacityMembershipIds[1]!),
    ]);
    assert.equal(groupActivationResults.filter(Boolean).length, 1);
    const [activeAtGroupLimit] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count FROM synex_group_membership_profiles
       WHERE group_id = ? AND lifecycle_state = 'ACTIVE'`,
      [fixture.groupCapacityGroupId],
    );
    assert.equal(Number(activeAtGroupLimit[0]?.count), 1);

    const gradeActivationResults = await Promise.all([
      activateMembership(primary.connection, fixture.gradeCapacityMembershipIds[0]!),
      activateMembership(secondary.connection, fixture.gradeCapacityMembershipIds[1]!),
    ]);
    assert.equal(gradeActivationResults.filter(Boolean).length, 1);
    const [activeAtGradeLimit] = await primary.connection.query<RowDataPacket[]>(
      `SELECT COUNT(*) AS count
       FROM synex_group_membership_grades AS assigned
       INNER JOIN synex_group_membership_profiles AS profile
         ON profile.membership_id = assigned.membership_id
       WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'`,
      [fixture.gradeCapacityGradeId],
    );
    assert.equal(Number(activeAtGradeLimit[0]?.count), 1);

    await assertPlanUses(
      primary.connection,
      `SELECT id, status FROM synex_groups FORCE INDEX (uq_groups_public_id)
       WHERE public_id = ?`,
      [fixture.mainGroupPublicId], 'synex_groups', 'uq_groups_public_id',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT membership_id FROM synex_group_membership_profiles
       FORCE INDEX (idx_group_membership_profiles_character)
       WHERE character_id = ? AND lifecycle_state = 'ACTIVE'
       ORDER BY group_id, membership_id LIMIT 32`,
      [fixture.characterIds[0]], 'synex_group_membership_profiles',
      'idx_group_membership_profiles_character',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT role_id FROM synex_group_role_capabilities
       FORCE INDEX (idx_group_role_capability_lookup)
       WHERE capability_pattern = 'police.records.read' AND effect = 'allow'
         AND scope_kind = 'group' ORDER BY role_id LIMIT 257`,
      [], 'synex_group_role_capabilities', 'idx_group_role_capability_lookup',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT membership_id FROM synex_group_membership_profiles
       FORCE INDEX (idx_group_membership_profiles_group)
       WHERE group_id = ? AND lifecycle_state = 'ACTIVE' AND visibility = 'members'
       ORDER BY membership_id LIMIT 256`,
      [fixture.mainGroupId], 'synex_group_membership_profiles',
      'idx_group_membership_profiles_group',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT id FROM synex_group_duty_sessions
       FORCE INDEX (idx_group_duty_sessions_state)
       WHERE status = 'open' AND state_key = 'on_duty'
       ORDER BY started_at, id LIMIT 256`,
      [], 'synex_group_duty_sessions', 'idx_group_duty_sessions_state',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT id FROM synex_group_policy_rules
       FORCE INDEX (idx_group_policy_rules_eval)
       WHERE policy_id = ? ORDER BY priority DESC, effect ASC, action_pattern, id LIMIT 65`,
      [fixture.policyId], 'synex_group_policy_rules', 'idx_group_policy_rules_eval',
    );
    await assertPlanUses(
      primary.connection,
      `SELECT COUNT(*) AS active_members
       FROM synex_group_assignment_members
       FORCE INDEX (idx_group_assignment_members_assignment_active)
       WHERE assignment_id = ? AND active_marker = 1`,
      [1], 'synex_group_assignment_members',
      'idx_group_assignment_members_assignment_active',
    );
  } finally {
    try {
      await cleanupFixture(primary.connection, fixture);
    } finally {
      await secondary.connection.end();
      await primary.connection.end();
    }
  }
});
