return function(Foundation)
local Lifecycle = require 'server.domain.lifecycle'
local function lifecycleState(value)
    return type(value) == 'string' and value:upper() or value
end

local function legacyStatus(state)
    if state == 'SUSPENDED' or state == 'LEAVE' or state == 'INACTIVE' then
        return 'suspended'
    end
    if state ~= 'TERMINATED' and state ~= 'BANNED'
        and state ~= 'LEFT' and state ~= 'ARCHIVED' then return 'active' end
    return 'removed'
end

local function nextId(runtime, namespace)
    local identifier, identifierError = runtime.id(namespace)
    if not identifier then return nil, identifierError end
    return identifier, nil
end

local function ensureAffected(tx, sql, parameters, message)
    local changed = tx.affected(sql, parameters)
    if changed ~= 1 then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            message or 'The Groups record changed concurrently.', true)
    end
    return true, nil
end

local preJoinStates = {
    DRAFT = true,
    INVITED = true,
    APPLICANT = true,
    UNDER_REVIEW = true,
    APPROVED = true
}

local function isPreJoinState(state)
    return preJoinStates[state] == true
end

local function validateWorkflowMembership(membership)
    if type(membership) ~= 'table' then return nil end
    local internalId = tonumber(membership.id)
    local groupId = tonumber(membership.group_id)
    local version = tonumber(membership.version)
    local profileVersion = tonumber(membership.profile_version)
    if not internalId or math.type(internalId) ~= 'integer' or internalId < 1
        or not groupId or math.type(groupId) ~= 'integer' or groupId < 1
        or not version or math.type(version) ~= 'integer' or version < 1
        or not profileVersion or math.type(profileVersion) ~= 'integer'
        or profileVersion < 1
        or not Foundation.isPublicId(membership.public_id)
        or not Foundation.isPublicId(membership.group_public_id)
        or not Foundation.isPublicId(membership.character_id)
        or not preJoinStates[membership.lifecycle_state] then
        return nil
    end
    membership.id = internalId
    membership.group_id = groupId
    membership.version = version
    membership.profile_version = profileVersion
    return membership
end

local function loadWorkflowMembership(tx, groupId, characterId)
    return tx.one([[SELECT membership.id, membership.public_id,
            membership.group_id, membership.version,
            profile.character_id, profile.lifecycle_state,
            profile.version AS profile_version,
            group_record.public_id AS group_public_id
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
            AND profile.group_id = membership.group_id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        WHERE membership.group_id = ? AND membership.subject_kind = 'character'
            AND profile.character_id = ? FOR UPDATE]], { groupId, characterId })
end

local function workflowStateAllowed(tx, groupId, state)
    return tx.one([[SELECT allowed.state_key
        FROM synex_group_organization_profiles AS organization
        INNER JOIN synex_group_type_membership_states AS allowed
            ON allowed.group_type_id = organization.group_type_id
            AND allowed.state_key = ?
        WHERE organization.group_id = ? FOR UPDATE]], { state, groupId }) ~= nil
end

local function ensureWorkflowCapacity(tx, groupId, excludedMembershipId)
    local policy = tx.one([[SELECT group_type.membership_limit
        FROM synex_group_organization_profiles AS organization
        INNER JOIN synex_group_types AS group_type
            ON group_type.id = organization.group_type_id
        WHERE organization.group_id = ? FOR UPDATE]], { groupId })
    if not policy then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The group type membership policy is unavailable.', true)
    end
    if policy.membership_limit == nil then return true, nil end
    local count = tx.one([[SELECT COUNT(*) AS count
        FROM synex_group_membership_profiles
        WHERE group_id = ? AND lifecycle_state IN
            ('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE')
            AND (? IS NULL OR membership_id <> ?)]], {
        groupId, excludedMembershipId, excludedMembershipId
    })
    local current = tonumber(count and count.count)
    if not current then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The group membership capacity result is invalid.', true)
    end
    if current >= tonumber(policy.membership_limit) then
        return nil, Foundation.domainError('MEMBER_LIMIT_REACHED',
            'The group has reached its current membership limit.')
    end
    return true, nil
end

local function membershipSnapshot(membership, state, version, gradeId)
    local snapshot = {
        membership_id = membership.public_id,
        group_id = membership.group_public_id,
        character_id = membership.character_id,
        lifecycle_state = state,
        version = version
    }
    if gradeId then snapshot.grade_id = gradeId end
    return snapshot
end

local function recordMembershipEvent(tx, runtime, membership, state, version, actor, eventType,
        gradeId)
    local eventId, eventError = nextId(runtime, 'group_mevent')
    if not eventId then return nil, eventError end
    tx.query([[INSERT INTO synex_group_membership_events
        (event_id, membership_id, membership_version, event_type,
         actor_ref, snapshot_json)
        VALUES (?, ?, ?, ?, ?, ?)]], {
        eventId, membership.id, version, eventType, actor,
        runtime.jsonEncode(membershipSnapshot(membership, state, version, gradeId))
    })
    return true, nil
end

local function transitionWorkflowMembership(tx, runtime, membership, target, reason, actor,
        allowSame)
    if not membership or not preJoinStates[target] then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The workflow membership is not in a pre-join lifecycle state.')
    end
    membership = validateWorkflowMembership(membership)
    if not membership then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored workflow membership is invalid.', true)
    end
    if membership.lifecycle_state == target then
        if allowSame then return membership, nil, nil end
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The workflow membership already has the requested state.')
    end
    local transition, transitionError = Lifecycle.transition(
        'membership', membership.lifecycle_state, target)
    if not transition then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            transitionError.message, false, transitionError.details)
    end
    if not workflowStateAllowed(tx, membership.group_id, target) then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The organization type does not permit the workflow membership state.', false, {
                state = target
            })
    end
    local nextVersion = tonumber(membership.version) + 1
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_memberships
        SET status = ?, version = version + 1
        WHERE id = ? AND version = ?]], {
        legacyStatus(target), membership.id, membership.version
    })
    if not changed then return nil, changeError end
    changed, changeError = ensureAffected(tx, [[UPDATE synex_group_membership_profiles
        SET lifecycle_state = ?, visibility = 'hidden',
            lifecycle_reason_code = ?, joined_at = NULL,
            suspended_at = NULL, left_at = NULL, version = version + 1
        WHERE membership_id = ? AND version = ?]], {
        target, reason, membership.id, membership.profile_version
    })
    if not changed then return nil, changeError end
    local recorded, recordError = recordMembershipEvent(
        tx, runtime, membership, target, nextVersion, actor, 'transitioned')
    if not recorded then return nil, recordError end
    local updated = {
        id = membership.id,
        public_id = membership.public_id,
        group_id = membership.group_id,
        group_public_id = membership.group_public_id,
        character_id = membership.character_id,
        lifecycle_state = target,
        version = nextVersion,
        profile_version = tonumber(membership.profile_version) + 1
    }
    return updated, nil, runtime.effect(
        'membership.' .. target:lower(), 'membership', membership.public_id,
        membership.group_public_id, membership.character_id,
        { status = membership.lifecycle_state, version = membership.version },
        { status = target, version = nextVersion }, reason, nextVersion)
end

local function materializeWorkflowMembership(tx, runtime, group, characterId, target, reason,
        actor)
    if not workflowStateAllowed(tx, group.id, 'DRAFT')
        or not workflowStateAllowed(tx, group.id, target) then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The organization type must permit DRAFT and the workflow membership state.', false, {
                state = target
            })
    end
    local membership = loadWorkflowMembership(tx, group.id, characterId)
    if membership then
        membership = validateWorkflowMembership(membership)
        if not membership then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The stored workflow membership is invalid.', true)
        end
        if membership.lifecycle_state ~= 'DRAFT'
            and membership.lifecycle_state ~= target then
            return nil, Foundation.domainError('MEMBERSHIP_ALREADY_EXISTS',
                'The character already has a membership lifecycle in this group.')
        end
        local capacity, capacityError = ensureWorkflowCapacity(tx, group.id, membership.id)
        if not capacity then return nil, capacityError end
        if membership.lifecycle_state == target then return membership, nil, nil end
        return transitionWorkflowMembership(
            tx, runtime, membership, target, reason, actor, false)
    end
    local capacity, capacityError = ensureWorkflowCapacity(tx, group.id, nil)
    if not capacity then return nil, capacityError end
    local publicId, idError = nextId(runtime, 'group_member')
    if not publicId then return nil, idError end
    local internalId = tx.insert([[INSERT INTO synex_group_memberships
        (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
        VALUES (?, ?, 'character', ?, 'pending', 'active', 1)]], {
        publicId, group.id, characterId
    })
    internalId = tonumber(internalId)
    if not internalId or math.type(internalId) ~= 'integer' or internalId < 1 then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The workflow membership identifier was not returned.', true)
    end
    tx.query([[INSERT INTO synex_group_membership_profiles
        (membership_id, group_id, character_id, lifecycle_state, visibility,
         joined_at, suspended_at, left_at, lifecycle_reason_code, version)
        VALUES (?, ?, ?, ?, 'hidden', NULL, NULL, NULL, ?, 1)]], {
        internalId, group.id, characterId, target, reason
    })
    tx.query([[INSERT INTO synex_group_reporting_closure
        (manager_membership_id, report_membership_id, depth)
        VALUES (?, ?, 0)]], { internalId, internalId })
    membership = {
        id = internalId,
        public_id = publicId,
        group_id = group.id,
        group_public_id = group.public_id,
        character_id = characterId,
        lifecycle_state = target,
        version = 1,
        profile_version = 1
    }
    local recorded, recordError = recordMembershipEvent(
        tx, runtime, membership, target, 1, actor, 'added')
    if not recorded then return nil, recordError end
    return membership, nil, runtime.effect(
        'membership.' .. target:lower(), 'membership', publicId,
        group.public_id, characterId, nil,
        { status = target, version = 1 }, reason, 1)
end

local function resolveWorkflowActivationTarget(tx, membership)
    for _, target in ipairs({ 'ACTIVE', 'PROBATION' }) do
        local transition = Lifecycle.canTransition(
            'membership', membership.lifecycle_state, target)
        if transition and workflowStateAllowed(tx, membership.group_id, target) then
            return target, nil
        end
    end
    return nil, Foundation.domainError('INVALID_TRANSITION',
        'The organization type permits neither active nor probation activation from this workflow state.')
end

local function activateWorkflowMembership(tx, runtime, membership, grade, actor, reason)
    membership = validateWorkflowMembership(membership)
    if not membership then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored workflow membership is invalid.', true)
    end
    local target, targetError = resolveWorkflowActivationTarget(tx, membership)
    if not target then return nil, targetError end
    local policy = tx.one([[SELECT group_type.membership_limit,
            group_type.active_membership_limit
        FROM synex_group_organization_profiles AS organization
        INNER JOIN synex_group_types AS group_type
            ON group_type.id = organization.group_type_id
        WHERE organization.group_id = ? FOR UPDATE]], { membership.group_id })
    if not policy then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The group type capacity policy is unavailable.', true)
    end
    local counts = tx.one([[SELECT COUNT(*) AS total_count,
            COALESCE(SUM(CASE WHEN lifecycle_state = 'ACTIVE' THEN 1 ELSE 0 END), 0)
                AS active_count
        FROM synex_group_membership_profiles
        WHERE group_id = ? AND membership_id <> ?
            AND lifecycle_state IN
                ('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE')]], {
        membership.group_id, membership.id
    })
    local totalCount = tonumber(counts and counts.total_count)
    local activeCount = tonumber(counts and counts.active_count)
    if not totalCount or not activeCount then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The group membership capacity result is invalid.', true)
    end
    if policy.membership_limit ~= nil
        and totalCount >= tonumber(policy.membership_limit) then
        return nil, Foundation.domainError('MEMBER_LIMIT_REACHED',
            'The group has reached its current membership limit.')
    end
    if target == 'ACTIVE' and policy.active_membership_limit ~= nil
        and activeCount >= tonumber(policy.active_membership_limit) then
        return nil, Foundation.domainError('MEMBER_LIMIT_REACHED',
            'The group has reached its active membership limit.')
    end
    if grade.member_limit ~= nil and target == 'ACTIVE' then
        local holders = tx.one([[SELECT COUNT(*) AS count
            FROM synex_group_membership_grades AS assigned
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = assigned.membership_id
            WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'
                AND assigned.membership_id <> ?]], { grade.id, membership.id })
        if tonumber(holders and holders.count) >= tonumber(grade.member_limit) then
            return nil, Foundation.domainError('GRADE_CAPACITY_REACHED',
                'The activation grade has reached its active member capacity.')
        end
    end
    if not Foundation.isCallable(runtime.enforceMembershipActivation) then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The membership attribute activation boundary is unavailable.', true)
    end
    local attributesReady, attributesError = runtime.enforceMembershipActivation(
        tx, {
            id = membership.id,
            group_id = membership.group_id,
            character_id = membership.character_id
        }, runtime)
    if not attributesReady then return nil, attributesError end
    local nextVersion = tonumber(membership.version) + 1
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_memberships
        SET role_key = ?, status = 'active', version = version + 1
        WHERE id = ? AND version = ?]], {
        grade.grade_key, membership.id, membership.version
    })
    if not changed then return nil, changeError end
    changed, changeError = ensureAffected(tx, [[UPDATE synex_group_membership_profiles
        SET lifecycle_state = ?, visibility = 'members',
            joined_at = COALESCE(joined_at, CURRENT_TIMESTAMP(6)),
            suspended_at = NULL, left_at = NULL, lifecycle_reason_code = ?,
            version = version + 1
        WHERE membership_id = ? AND version = ?]], {
        target, reason, membership.id, membership.profile_version
    })
    if not changed then return nil, changeError end
    tx.query([[INSERT INTO synex_group_membership_grades
        (membership_id, grade_id, assigned_by_ref, version)
        VALUES (?, ?, ?, 1)]], { membership.id, grade.id, actor })
    local recorded, recordError = recordMembershipEvent(
        tx, runtime, membership, target, nextVersion, actor, 'transitioned', grade.public_id)
    if not recorded then return nil, recordError end
    local updated = {
        id = membership.id,
        public_id = membership.public_id,
        group_id = membership.group_id,
        group_public_id = membership.group_public_id,
        character_id = membership.character_id,
        lifecycle_state = target,
        version = nextVersion,
        profile_version = tonumber(membership.profile_version) + 1
    }
    return updated, nil, runtime.effect(
        'membership.activated', 'membership', membership.public_id,
        membership.group_public_id, membership.character_id,
        { status = membership.lifecycle_state, version = membership.version },
        { status = target, grade_id = grade.public_id, version = nextVersion },
        reason, nextVersion)
end

return {
    Lifecycle = Lifecycle,
    lifecycleState = lifecycleState,
    legacyStatus = legacyStatus,
    isPreJoinState = isPreJoinState,
    nextId = nextId,
    ensureAffected = ensureAffected,
    loadWorkflowMembership = loadWorkflowMembership,
    transitionWorkflowMembership = transitionWorkflowMembership,
    materializeWorkflowMembership = materializeWorkflowMembership,
    activateWorkflowMembership = activateWorkflowMembership,
}
end
