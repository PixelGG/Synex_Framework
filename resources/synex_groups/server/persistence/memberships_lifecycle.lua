return function(Foundation)
local Shared = require('server.persistence.memberships_shared')(Foundation)
local Lifecycle = Shared.Lifecycle
local lifecycleState = Shared.lifecycleState
local legacyStatus = Shared.legacyStatus
local nextId = Shared.nextId
local ensureAffected = Shared.ensureAffected
local handlers = { read = {}, execute = {} }

function handlers.execute.members_transition(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    local target = lifecycleState(request.status)
    if Shared.isPreJoinState(membership.lifecycle_state)
        or Shared.isPreJoinState(target) then
        local _, authorizationError = runtime.authorize(
            tx, membership.group_public_id, request.actor_character_id,
            'synex.groups.members.manage', 'group', {
                target_membership = membership,
                parameters = { status = target, workflow_owned = true }
            })
        if authorizationError then return nil, authorizationError end
        local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
            and runtime.completeAuthorizationPreflight(context)
        if preflight then return preflight end
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Pre-join membership states are owned by invitation and application workflows.',
            false, { from = membership.lifecycle_state, to = target })
    end
    local transition, transitionError = Lifecycle.transition(
        'membership', membership.lifecycle_state, target)
    if not transition then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            transitionError.message, false, transitionError.details)
    end
    if not Foundation.isCallable(runtime.resolveMembershipTransitionPolicy) then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The membership transition policy boundary is unavailable.', true)
    end
    local policy, policyError = runtime.resolveMembershipTransitionPolicy(tx, {
        group_id = membership.group_public_id,
        internal_group_id = membership.group_id,
        from_status = membership.lifecycle_state,
        to_status = target,
        lock = true
    })
    if not policy then return nil, policyError end
    local _, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        policy.required_capability, 'group', {
            target_membership = membership,
            parameters = {
                status = target,
                transition_policy_id = policy.policy_id,
                transition_policy_configured = policy.configured
            }
        })
    if authorizationError then return nil, authorizationError end
    if policy.allowed ~= true then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The membership transition is disabled by group policy.', false, {
                from = membership.lifecycle_state,
                to = target,
                policy_id = policy.policy_id
            })
    end
    if policy.reason_required == true
        and (type(request.reason) ~= 'string' or #request.reason < 1) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'This membership transition requires a reason.', false, {
                field = 'reason', policy_id = policy.policy_id
            })
    end
    if policy.approval_required == true then
        if not Foundation.isCallable(runtime.verifyApprovedOperation) then
            return nil, Foundation.domainError('APPROVAL_REQUIRED',
                'The transition policy requires an approved Groups proposal.')
        end
        local approved, approvalError = runtime.verifyApprovedOperation(
            context, 'members_transition', request, membership.group_public_id)
        if not approved then return nil, approvalError end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if tonumber(membership.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The membership version changed.', true)
    end
    local allowedState = tx.one([[SELECT allowed.state_key
        FROM synex_group_organization_profiles AS organization
        INNER JOIN synex_group_type_membership_states AS allowed
            ON allowed.group_type_id = organization.group_type_id
        WHERE organization.group_id = ? AND allowed.state_key = ? FOR UPDATE]],
        { membership.group_id, target })
    if not allowedState then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The organization type does not permit the requested membership state.', false, {
                state = target
            })
    end
    if target == 'ACTIVE' then
        -- Lock the shared capacity owners before counting. Every activation path
        -- takes these locks in group-then-grade order so concurrent transactions
        -- cannot both observe the final free slot.
        local typePolicy = tx.one([[SELECT group_type.membership_limit,
                group_type.active_membership_limit
            FROM synex_group_organization_profiles AS organization
            INNER JOIN synex_group_types AS group_type
                ON group_type.id = organization.group_type_id
            WHERE organization.group_id = ? FOR UPDATE]], { membership.group_id })
        if not typePolicy then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The group type capacity policy is unavailable.', true)
        end
        if typePolicy.active_membership_limit ~= nil then
            local activeMembers = tx.one([[SELECT COUNT(*) AS count
                FROM synex_group_membership_profiles
                WHERE group_id = ? AND lifecycle_state = 'ACTIVE'
                    AND membership_id <> ?]], { membership.group_id, membership.id })
            if tonumber(activeMembers and activeMembers.count)
                >= tonumber(typePolicy.active_membership_limit) then
                return nil, Foundation.domainError('MEMBER_LIMIT_REACHED',
                    'The group has reached its active membership limit.')
            end
        end
        local grade = tx.one([[SELECT grade.id, control.member_limit
            FROM synex_group_membership_grades AS assigned
            INNER JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
            LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
            WHERE assigned.membership_id = ? AND grade.status = 'active'
            FOR UPDATE]], { membership.id })
        if not grade then
            return nil, Foundation.domainError('GRADE_NOT_FOUND',
                'An active membership requires an active assigned grade.')
        end
        if grade.member_limit ~= nil then
            local activeHolders = tx.one([[SELECT COUNT(*) AS count
                FROM synex_group_membership_grades AS assigned
                INNER JOIN synex_group_membership_profiles AS profile
                    ON profile.membership_id = assigned.membership_id
                WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'
                    AND assigned.membership_id <> ?]], { grade.id, membership.id })
            if tonumber(activeHolders and activeHolders.count)
                >= tonumber(grade.member_limit) then
                return nil, Foundation.domainError('GRADE_CAPACITY_REACHED',
                    'The assigned grade has reached its active member capacity.')
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
    end
    local nextVersion = tonumber(membership.version) + 1
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_memberships
        SET status = ?, version = version + 1
        WHERE id = ? AND version = ?]], {
        legacyStatus(target), membership.id, request.expected_version
    })
    if not changed then return nil, changeError end
    changed, changeError = ensureAffected(tx, [[UPDATE synex_group_membership_profiles
        SET lifecycle_state = ?, lifecycle_reason_code = ?,
            joined_at = CASE WHEN ? IN ('PROBATION', 'ACTIVE', 'SUSPENDED',
                    'LEAVE', 'INACTIVE')
                THEN COALESCE(joined_at, CURRENT_TIMESTAMP(6)) ELSE joined_at END,
            suspended_at = CASE WHEN ? IN ('SUSPENDED', 'LEAVE', 'INACTIVE')
                    THEN COALESCE(suspended_at, CURRENT_TIMESTAMP(6))
                WHEN ? IN ('PROBATION', 'ACTIVE') THEN NULL ELSE suspended_at END,
            left_at = CASE WHEN ? IN ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
                THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
            version = version + 1
        WHERE membership_id = ? AND version = ?]], {
        target, runtime.reason(request.reason, 'membership_transitioned'),
        target, target, target, target, membership.id, membership.profile_version
    })
    if not changed then return nil, changeError end
    local dutySession
    if target ~= 'ACTIVE' then
        local cleanupReason = transition.terminal
            and 'membership_terminal' or 'membership_suspended'
        dutySession = tx.one([[SELECT id, public_id, state_key, assignment_id,
                metadata_json, version
            FROM synex_group_duty_sessions
            WHERE membership_id = ? AND status = 'open' FOR UPDATE]], { membership.id })
        tx.query([[UPDATE synex_group_duty_sessions
            SET status = 'closed', ended_at = CURRENT_TIMESTAMP(6),
                reason_code = ?, version = version + 1
            WHERE membership_id = ? AND status = 'open']],
            { cleanupReason, membership.id })
        if dutySession then
            local eventId, eventError = nextId(runtime, 'group_devent')
            if not eventId then return nil, eventError end
            tx.query([[INSERT INTO synex_group_duty_events
                (event_id, duty_session_id, session_version, event_type,
                 state_key, actor_ref, reason_code, assignment_id, metadata_json)
                VALUES (?, ?, ?, 'ended', ?, ?, ?, ?, ?)]], {
                eventId, dutySession.id, tonumber(dutySession.version) + 1,
                dutySession.state_key, request.actor_character_id,
                cleanupReason, dutySession.assignment_id, dutySession.metadata_json
            })
        end
        tx.query([[UPDATE synex_group_assignment_members
            SET status = 'removed', left_at = CURRENT_TIMESTAMP(6),
                reason_code = ?, version = version + 1
            WHERE membership_id = ? AND status = 'active']], { cleanupReason, membership.id })
        tx.query([[UPDATE synex_group_delegations
            SET status = 'revoked', revoked_at = CURRENT_TIMESTAMP(6),
                reason_code = ?, version = version + 1
            WHERE status = 'active'
                AND (grantor_membership_id = ? OR grantee_membership_id = ?)]],
            { cleanupReason, membership.id, membership.id })
        if transition.terminal then
            tx.query([[UPDATE synex_group_membership_roles
                SET status = 'revoked', revoked_at = CURRENT_TIMESTAMP(6),
                    reason_code = 'membership_terminal', version = version + 1
                WHERE membership_id = ? AND status = 'active']], { membership.id })
            tx.query('DELETE FROM synex_group_primary_memberships_by_type WHERE membership_id = ?',
                { membership.id })
            tx.query('DELETE FROM synex_group_primary_memberships WHERE membership_id = ?',
                { membership.id })
        end
    end
    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        membership.public_id, 'membership', target, nextVersion)
    local snapshot = {
        membership_id = membership.public_id,
        group_id = membership.group_public_id,
        character_id = membership.character_id,
        lifecycle_state = target,
        version = nextVersion
    }
    local membershipEventId, membershipEventError = nextId(runtime, 'group_mevent')
    if not membershipEventId then return nil, membershipEventError end
    tx.query([[INSERT INTO synex_group_membership_events
        (event_id, membership_id, membership_version, event_type,
         actor_ref, snapshot_json)
        VALUES (?, ?, ?, 'transitioned', ?, ?)]], {
        membershipEventId, membership.id, nextVersion,
        request.actor_character_id, runtime.jsonEncode(snapshot)
    })
    local effects = {}
    if dutySession then
        effects[#effects + 1] = runtime.effect('duty.ended', 'duty_session',
            dutySession.public_id, membership.group_public_id,
            membership.character_id,
            { status = 'open', state = dutySession.state_key,
                version = dutySession.version },
            { status = 'closed', reason = transition.terminal
                and 'membership_terminal' or 'membership_suspended',
                version = tonumber(dutySession.version) + 1 },
            transition.terminal and 'membership_terminal' or 'membership_suspended',
            tonumber(dutySession.version) + 1)
    end
    local membershipAction = target == 'ACTIVE' and 'membership.activated'
        or target == 'SUSPENDED' and 'membership.suspended'
        or transition.terminal and 'membership.terminated'
        or 'membership.' .. target:lower()
    effects[#effects + 1] = runtime.effect(
        membershipAction, 'membership',
        membership.public_id, membership.group_public_id,
        membership.character_id,
        { status = membership.lifecycle_state, version = membership.version },
        response, request.reason, nextVersion)
    return response, nil, effects
end

function handlers.execute.members_set_grade(tx, request, runtime, context, approvalOperation)
    approvalOperation = approvalOperation or 'members_set_grade'
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    local actor, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.grades.manage', 'group', {
            target_membership = membership,
            parameters = { grade_id = request.grade_id }
        })
    if not actor then return nil, authorizationError end
    local grade = tx.one([[SELECT grade.id, grade.public_id, grade.grade_key,
            grade.rank_value, control.member_limit,
            control.promotion_requires_approval
        FROM synex_group_grades AS grade
        LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
        WHERE grade.public_id = ? AND grade.group_id = ? AND grade.status = 'active'
        FOR UPDATE]], { request.grade_id, membership.group_id })
    if not grade then
        return nil, Foundation.domainError('GRADE_NOT_FOUND',
            'The requested active grade does not belong to the group.')
    end
    local approvalVerified = false
    if tonumber(grade.promotion_requires_approval) == 1 then
        if not Foundation.isCallable(runtime.verifyApprovedOperation) then
            return nil, Foundation.domainError('APPROVAL_REQUIRED',
                'The target grade requires an approved Groups proposal.', false, {
                    action = 'membership.set_grade',
                    grade_id = grade.public_id
                })
        end
        local approved, approvalError = runtime.verifyApprovedOperation(
            context, approvalOperation, request, membership.group_public_id)
        if not approved then return nil, approvalError end
        approvalVerified = true
    end
    local actorGrade = tx.one([[SELECT grade.rank_value
        FROM synex_group_membership_grades AS assigned
        INNER JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
        WHERE assigned.membership_id = ? FOR UPDATE]], { actor.id })
    local current = tx.one([[SELECT grade.public_id, grade.grade_key, grade.rank_value
        FROM synex_group_membership_grades AS assigned
        INNER JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
        WHERE assigned.membership_id = ? FOR UPDATE]], { membership.id })
    local actorRank = actorGrade and tonumber(actorGrade.rank_value) or nil
    local currentRank = current and tonumber(current.rank_value) or nil
    local targetRank = tonumber(grade.rank_value)
    if actor.id == membership.id and not approvalVerified then
        if not Foundation.isCallable(runtime.verifyApprovedOperation) then
            return nil, Foundation.domainError('APPROVAL_REQUIRED',
                'Changing the actor\'s own grade requires an approved Groups proposal.',
                false, { action = 'membership.set_grade', grade_id = grade.public_id })
        end
        local approved, approvalError = runtime.verifyApprovedOperation(
            context, approvalOperation, request, membership.group_public_id)
        if not approved then return nil, approvalError end
    end
    if not actorRank or not currentRank
        or actor.id == membership.id and targetRank > currentRank
        or actor.id ~= membership.id
            and (actorRank <= currentRank or actorRank <= targetRank) then
        return nil, Foundation.domainError('TARGET_GRADE_TOO_HIGH',
            'The actor lacks rank authority over the target or requested grade.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if tonumber(membership.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The membership version changed.', true)
    end
    if grade.member_limit then
        local holders = tx.one([[SELECT COUNT(*) AS count
            FROM synex_group_membership_grades AS assigned
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = assigned.membership_id
            WHERE assigned.grade_id = ? AND profile.lifecycle_state = 'ACTIVE'
                AND assigned.membership_id <> ?]], { grade.id, membership.id })
        if tonumber(holders and holders.count) >= tonumber(grade.member_limit) then
            return nil, Foundation.domainError('GRADE_CAPACITY_REACHED',
                'The target grade has reached its capacity.')
        end
    end
    tx.query([[UPDATE synex_group_membership_grades
        SET grade_id = ?, assigned_by_ref = ?, version = version + 1,
            assigned_at = CURRENT_TIMESTAMP(6)
        WHERE membership_id = ?]], {
        grade.id, request.actor_character_id, membership.id
    })
    local nextVersion = tonumber(membership.version) + 1
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_memberships
        SET role_key = ?, version = version + 1
        WHERE id = ? AND version = ?]], {
        grade.grade_key, membership.id, request.expected_version
    })
    if not changed then return nil, changeError end
    tx.query([[UPDATE synex_group_membership_profiles
        SET version = version + 1, lifecycle_reason_code = ?
        WHERE membership_id = ?]], {
        runtime.reason(request.reason, 'grade_changed'), membership.id
    })
    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        membership.public_id, 'membership', membership.lifecycle_state, nextVersion)
    local membershipEventId, eventError = nextId(runtime, 'group_mevent')
    if not membershipEventId then return nil, eventError end
    tx.query([[INSERT INTO synex_group_membership_events
        (event_id, membership_id, membership_version, event_type,
         actor_ref, snapshot_json)
        VALUES (?, ?, ?, 'grade_changed', ?, ?)]], {
        membershipEventId, membership.id, nextVersion,
        request.actor_character_id,
        runtime.jsonEncode({ membership_id = membership.public_id,
            group_id = membership.group_public_id,
            character_id = membership.character_id,
            grade_id = grade.public_id,
            lifecycle_state = membership.lifecycle_state,
            version = nextVersion })
    })
    return response, nil, {
        runtime.effect('grade.changed', 'membership', membership.public_id,
            membership.group_public_id, membership.character_id,
            { grade_id = current and current.public_id, version = membership.version },
            { grade_id = grade.public_id, version = nextVersion },
            request.reason, nextVersion)
    }
end

return handlers
end
