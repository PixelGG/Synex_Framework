return function(Foundation)
local Shared = require('server.persistence.memberships_shared')(Foundation)
local nextId = Shared.nextId
local ensureAffected = Shared.ensureAffected
local materializeWorkflowMembership = Shared.materializeWorkflowMembership
local transitionWorkflowMembership = Shared.transitionWorkflowMembership
local activateWorkflowMembership = Shared.activateWorkflowMembership
local handlers = { read = {}, execute = {} }

function handlers.execute.members_invite(tx, request, runtime, context)
    local actor, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.members.invite', 'group')
    if not actor then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = runtime.requireGroup(tx, request.group_id, true)
    if not group then return nil, groupError end
    if group.status ~= 'active' or group.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'Invitations require an active group.')
    end
    group.public_id = group.public_id or request.group_id
    local staleEffect
    local staleMembershipEffect
    local pending = tx.one([[SELECT invitation.id, invitation.public_id,
            invitation.membership_id, invitation.version,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN invitation.expires_at <= CURRENT_TIMESTAMP(6)
                THEN 1 ELSE 0 END AS expired
        FROM synex_group_invitations AS invitation
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = invitation.membership_id
            AND membership.group_id = invitation.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = invitation.group_id
            AND member_profile.character_id = invitation.character_id
        WHERE invitation.group_id = ? AND invitation.character_id = ?
            AND invitation.status = 'pending'
        FOR UPDATE]], { group.id, request.character_id })
    if pending then
        if tonumber(pending.expired) ~= 1 then
            return nil, Foundation.domainError('IDEMPOTENCY_CONFLICT',
                'A pending invitation already exists for this character.')
        end
        if pending.membership_lifecycle ~= 'INVITED' then
            return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                'The expired invitation membership lifecycle changed.', true)
        end
        local expired, expireError = ensureAffected(tx, [[UPDATE synex_group_invitations
            SET status = 'expired', responded_at = CURRENT_TIMESTAMP(6),
                reason_code = 'invitation_window_expired', version = version + 1
            WHERE id = ? AND status = 'pending' AND version = ?]], {
            pending.id, pending.version
        }, 'The expired invitation changed while a replacement was created.')
        if not expired then return nil, expireError end
        local resetMembership, resetError
        resetMembership, resetError, staleMembershipEffect = transitionWorkflowMembership(
            tx, runtime, {
                id = pending.membership_id,
                public_id = pending.membership_public_id,
                group_id = group.id,
                group_public_id = request.group_id,
                character_id = request.character_id,
                lifecycle_state = pending.membership_lifecycle,
                version = tonumber(pending.membership_version),
                profile_version = tonumber(pending.membership_profile_version)
            }, 'DRAFT', 'invitation_window_expired',
            request.actor_character_id, false)
        if not resetMembership then return nil, resetError end
        staleEffect = runtime.effect('membership.invitation_expired', 'invitation',
            pending.public_id, request.group_id, request.character_id,
            { status = 'pending', version = pending.version },
            { status = 'expired', version = tonumber(pending.version) + 1 },
            'invitation_window_expired', tonumber(pending.version) + 1)
    end

    local grade
    if request.grade_id then
        grade = tx.one([[SELECT id, public_id, rank_value FROM synex_group_grades
            WHERE public_id = ? AND group_id = ? AND status = 'active' FOR UPDATE]],
            { request.grade_id, group.id })
        if not grade then
            return nil, Foundation.domainError('GRADE_NOT_FOUND',
                'The requested active grade does not belong to the group.')
        end
        local actorGrade = tx.one([[SELECT actor_grade.rank_value
            FROM synex_group_membership_grades AS assigned
            INNER JOIN synex_group_grades AS actor_grade ON actor_grade.id = assigned.grade_id
            WHERE assigned.membership_id = ? FOR UPDATE]], { actor.id })
        if not actorGrade or tonumber(actorGrade.rank_value) <= tonumber(grade.rank_value) then
            return nil, Foundation.domainError('TARGET_GRADE_TOO_HIGH',
                'The actor cannot invite a member into a grade at or above their own rank.')
        end
    end
    local expiresAt = request.expires_at
    if expiresAt then
        local future = tx.one([[SELECT CASE WHEN CAST(? AS DATETIME(6))
                > CURRENT_TIMESTAMP(6) THEN 1 ELSE 0 END AS valid]], { expiresAt })
        if not future or tonumber(future.valid) ~= 1 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Invitation expiry must be in the future.')
        end
    end
    local membership, membershipError, membershipEffect = materializeWorkflowMembership(
        tx, runtime, group, request.character_id, 'INVITED',
        runtime.reason(request.reason, 'membership_invited'),
        request.actor_character_id)
    if not membership then return nil, membershipError end
    local invitationId, idError = nextId(runtime, 'group_invite')
    if not invitationId then return nil, idError end
    local internalId = tx.insert([[INSERT INTO synex_group_invitations
        (public_id, group_id, character_id, membership_id, grade_id, status,
         invited_by_membership_id, reason_code, expires_at, version)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, COALESCE(?, TIMESTAMPADD(DAY, 7,
            CURRENT_TIMESTAMP(6))), 1)]], {
        invitationId, group.id, request.character_id, membership.id,
        grade and grade.id or nil,
        actor.id, runtime.reason(request.reason, 'membership_invited'), expiresAt
    })
    for _, roleId in ipairs(request.role_ids or {}) do
        local role = tx.one([[SELECT id FROM synex_group_roles
            WHERE public_id = ? AND group_id = ? AND status = 'active' FOR UPDATE]],
            { roleId, group.id })
        if not role then
            return nil, Foundation.domainError('ROLE_NOT_FOUND',
                'An invited role does not belong to the group.')
        end
        tx.query([[INSERT INTO synex_group_invitation_roles
            (invitation_id, role_id) VALUES (?, ?)]], { internalId, role.id })
    end
    local response = runtime.success(invitationId, 'invitation', 'pending', 1)
    local effects = {}
    if staleEffect then effects[#effects + 1] = staleEffect end
    if staleMembershipEffect then effects[#effects + 1] = staleMembershipEffect end
    if membershipEffect then effects[#effects + 1] = membershipEffect end
    effects[#effects + 1] = runtime.effect('membership.invited', 'invitation',
        invitationId, request.group_id, request.character_id, nil, response,
        request.reason, 1)
    return response, nil, effects
end

function handlers.execute.members_accept(tx, request, runtime, context)
    local invitation = tx.one([[SELECT invitation.id, invitation.public_id,
            invitation.group_id, invitation.character_id, invitation.membership_id,
            invitation.grade_id,
            invitation.status, invitation.version,
            group_record.public_id AS group_public_id, group_record.status AS group_status,
            organization.lifecycle_state AS group_lifecycle,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN invitation.expires_at > CURRENT_TIMESTAMP(6)
                THEN 1 ELSE 0 END AS inside_window
        FROM synex_group_invitations AS invitation
        INNER JOIN synex_groups AS group_record ON group_record.id = invitation.group_id
        INNER JOIN synex_group_organization_profiles AS organization
            ON organization.group_id = group_record.id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = invitation.membership_id
            AND membership.group_id = invitation.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = invitation.group_id
            AND member_profile.character_id = invitation.character_id
        WHERE invitation.public_id = ? FOR UPDATE]], { request.invitation_id })
    if not invitation then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The invitation does not exist.')
    end
    if invitation.character_id ~= request.actor_character_id then
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'Only the invited character may accept this invitation.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if invitation.status ~= 'pending' or tonumber(invitation.inside_window) ~= 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The invitation is no longer pending and valid.')
    end
    if invitation.group_status ~= 'active' or invitation.group_lifecycle ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'The invitation group is not active.')
    end
    if invitation.membership_lifecycle ~= 'INVITED' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The invitation membership is no longer invited.')
    end

    local grade
    if invitation.grade_id then
        grade = tx.one([[SELECT grade.id, grade.public_id, grade.grade_key,
                control.member_limit
            FROM synex_group_grades AS grade
            LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
            WHERE grade.id = ? AND grade.group_id = ? AND grade.status = 'active'
            FOR UPDATE]], { invitation.grade_id, invitation.group_id })
    else
        grade = tx.one([[SELECT grade.id, grade.public_id, grade.grade_key,
                control.member_limit
            FROM synex_group_grades AS grade
            LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
            WHERE grade.group_id = ? AND grade.status = 'active'
                AND grade.grade_key <> 'owner'
            ORDER BY grade.rank_value ASC, grade.id ASC LIMIT 1 FOR UPDATE]],
            { invitation.group_id })
    end
    if not grade then
        return nil, Foundation.domainError('GRADE_NOT_FOUND',
            'The invitation has no available active grade.')
    end
    local membership, activationError, membershipEffect = activateWorkflowMembership(
        tx, runtime, {
            id = invitation.membership_id,
            public_id = invitation.membership_public_id,
            group_id = invitation.group_id,
            group_public_id = invitation.group_public_id,
            character_id = invitation.character_id,
            lifecycle_state = invitation.membership_lifecycle,
            version = tonumber(invitation.membership_version),
            profile_version = tonumber(invitation.membership_profile_version)
        }, grade, invitation.character_id, 'invitation_accepted')
    if not membership then return nil, activationError end

    local roleRows = tx.many([[SELECT role.id, role.public_id, role.exclusivity,
            role.holder_limit
        FROM synex_group_invitation_roles AS requested
        INNER JOIN synex_group_roles AS role ON role.id = requested.role_id
        WHERE requested.invitation_id = ? AND role.status = 'active'
        ORDER BY role.id ASC FOR UPDATE]], { invitation.id })
    for _, role in ipairs(roleRows) do
        if role.holder_limit then
            local holders = tx.one([[SELECT COUNT(*) AS count
                FROM synex_group_membership_roles
                WHERE role_id = ? AND status = 'active'
                    AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP(6))]],
                { role.id })
            if tonumber(holders and holders.count) >= tonumber(role.holder_limit) then
                return nil, Foundation.domainError('ROLE_EXCLUSIVE_CONFLICT',
                    'An invited role has reached its holder limit.')
            end
        end
        local assignmentId, assignmentError = nextId(runtime, 'group_mrole')
        if not assignmentId then return nil, assignmentError end
        tx.query([[INSERT INTO synex_group_membership_roles
            (public_id, membership_id, role_id, exclusive_role_id, status,
             valid_from, valid_until, revoked_at, assigned_by_ref, reason_code, version)
            VALUES (?, ?, ?, ?, 'active', CURRENT_TIMESTAMP(6), NULL, NULL,
                ?, 'invitation_accepted', 1)]], {
            assignmentId, membership.id, role.id,
            role.exclusivity == 'group' and role.id or nil,
            invitation.character_id
        })
    end
    local accepted, acceptedError = ensureAffected(tx, [[UPDATE synex_group_invitations
        SET status = 'accepted', responded_at = CURRENT_TIMESTAMP(6),
            reason_code = 'invitation_accepted', version = version + 1
        WHERE id = ? AND status = 'pending' AND version = ?]],
        { invitation.id, invitation.version },
        'The invitation changed while it was being accepted.')
    if not accepted then return nil, acceptedError end
    local touched, touchError = runtime.touchGroup(tx, invitation.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        membership.public_id, 'membership', membership.lifecycle_state, membership.version)
    return response, nil, {
        runtime.effect('membership.invitation_accepted', 'invitation',
            invitation.public_id, invitation.group_public_id,
            invitation.character_id,
            { status = 'pending', version = invitation.version },
            { status = 'accepted', version = tonumber(invitation.version) + 1 },
            'invitation_accepted', tonumber(invitation.version) + 1),
        membershipEffect
    }
end

local function closeInvitation(tx, request, runtime, target, context)
    local invitation = tx.one([[SELECT invitation.id, invitation.public_id,
            invitation.group_id, invitation.character_id, invitation.membership_id,
            invitation.status,
            invitation.version, group_record.public_id AS group_public_id,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN invitation.expires_at <= CURRENT_TIMESTAMP(6) THEN 1 ELSE 0 END AS expired
        FROM synex_group_invitations AS invitation
        INNER JOIN synex_groups AS group_record ON group_record.id = invitation.group_id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = invitation.membership_id
            AND membership.group_id = invitation.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = invitation.group_id
            AND member_profile.character_id = invitation.character_id
        WHERE invitation.public_id = ? FOR UPDATE]], { request.invitation_id })
    if not invitation then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The invitation does not exist.')
    end
    if target == 'declined' then
        if invitation.character_id ~= request.actor_character_id then
            return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
                'Only the invited character may decline this invitation.')
        end
    else
        local actor, authorizationError = runtime.authorize(
            tx, invitation.group_public_id, request.actor_character_id,
            'synex.groups.members.invite', 'group')
        if not actor then return nil, authorizationError end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if invitation.status ~= 'pending' or tonumber(invitation.expired) == 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Only a pending, unexpired invitation can be closed.')
    end
    if tonumber(invitation.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The invitation changed before it could be closed.', true)
    end
    if invitation.membership_lifecycle ~= 'INVITED' then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The durable membership lifecycle no longer matches the invitation.', true)
    end
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_invitations
        SET status = ?, responded_at = CURRENT_TIMESTAMP(6), reason_code = ?,
            version = version + 1
        WHERE id = ? AND status = 'pending' AND version = ?]], {
        target, runtime.reason(request.reason, 'invitation_' .. target),
        invitation.id, request.expected_version
    }, 'The invitation changed while it was being closed.')
    if not changed then return nil, changeError end
    local workflowMembership, membershipError, membershipEffect = transitionWorkflowMembership(
        tx, runtime, {
            id = invitation.membership_id,
            public_id = invitation.membership_public_id,
            group_id = invitation.group_id,
            group_public_id = invitation.group_public_id,
            character_id = invitation.character_id,
            lifecycle_state = invitation.membership_lifecycle,
            version = tonumber(invitation.membership_version),
            profile_version = tonumber(invitation.membership_profile_version)
        }, 'DRAFT', runtime.reason(request.reason, 'invitation_' .. target),
        request.actor_character_id, false)
    if not workflowMembership then return nil, membershipError end
    local touched, touchError = runtime.touchGroup(tx, invitation.group_id)
    if not touched then return nil, touchError end
    local nextVersion = tonumber(invitation.version) + 1
    local response = runtime.success(
        invitation.public_id, 'invitation', target, nextVersion)
    local effects = {
        runtime.effect('membership.invitation_' .. target, 'invitation',
            invitation.public_id, invitation.group_public_id,
            invitation.character_id,
            { status = invitation.status, version = invitation.version },
            response, request.reason, nextVersion)
    }
    if membershipEffect then effects[#effects + 1] = membershipEffect end
    return response, nil, effects
end

function handlers.execute.members_decline(tx, request, runtime, context)
    return closeInvitation(tx, request, runtime, 'declined', context)
end

function handlers.execute.members_revoke_invite(tx, request, runtime, context)
    return closeInvitation(tx, request, runtime, 'revoked', context)
end

return handlers
end
