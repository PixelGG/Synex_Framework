return function(Foundation)
local Shared = require('server.persistence.memberships_shared')(Foundation)
local Lifecycle = Shared.Lifecycle
local lifecycleState = Shared.lifecycleState
local legacyStatus = Shared.legacyStatus
local nextId = Shared.nextId
local ensureAffected = Shared.ensureAffected
local handlers = { read = {}, execute = {} }
local MEMBERSHIP_VISIBILITY = {
    public = true,
    members = true,
    management = true,
    hidden = true,
    server_only = true
}
local PREJOIN_LIFECYCLE = {
    DRAFT = true,
    INVITED = true,
    APPLICANT = true,
    UNDER_REVIEW = true,
    APPROVED = true
}

function handlers.execute.members_set_visibility(tx, request, runtime, context)
    local visibility = request.visibility
    if not MEMBERSHIP_VISIBILITY[visibility] then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The requested membership visibility is invalid.')
    end
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    local _, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.members.manage', 'group', {
            target_membership = membership,
            parameters = {
                visibility = visibility,
                reason = request.reason
            }
        })
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if PREJOIN_LIFECYCLE[membership.lifecycle_state]
        and visibility ~= 'hidden' and visibility ~= 'server_only' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Pre-join memberships cannot be exposed through the member directory.')
    end
    local currentVersion = tonumber(membership.version)
    local profileVersion = tonumber(membership.profile_version)
    if not currentVersion or math.type(currentVersion) ~= 'integer'
        or currentVersion < 1
        or not profileVersion or math.type(profileVersion) ~= 'integer'
        or profileVersion < 1 then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored membership visibility versions are invalid.', true)
    end
    if currentVersion ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The membership visibility changed concurrently.', true)
    end
    if membership.visibility == visibility then
        return runtime.success(
            membership.public_id, 'membership', visibility, currentVersion), nil, {}
    end

    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_memberships
        SET version = version + 1
        WHERE id = ? AND version = ?]], {
        membership.id, request.expected_version
    }, 'The membership changed while its visibility was being updated.')
    if not changed then return nil, changeError end
    changed, changeError = ensureAffected(tx, [[UPDATE synex_group_membership_profiles
        SET visibility = ?, lifecycle_reason_code = ?, version = version + 1
        WHERE membership_id = ? AND version = ?]], {
        visibility, runtime.reason(request.reason, 'membership_visibility_changed'),
        membership.id, profileVersion
    }, 'The membership profile changed while its visibility was being updated.')
    if not changed then return nil, changeError end

    local nextVersion = currentVersion + 1
    local membershipEventId, eventError = nextId(runtime, 'group_mevent')
    if not membershipEventId then return nil, eventError end
    local snapshot = {
        membership_id = membership.public_id,
        group_id = membership.group_public_id,
        character_id = membership.character_id,
        visibility = visibility,
        version = nextVersion
    }
    tx.query([[INSERT INTO synex_group_membership_events
        (event_id, membership_id, membership_version, event_type,
         actor_ref, snapshot_json)
        VALUES (?, ?, ?, 'visibility_changed', ?, ?)]], {
        membershipEventId, membership.id, nextVersion,
        request.actor_character_id, runtime.jsonEncode(snapshot)
    })
    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        membership.public_id, 'membership', visibility, nextVersion)
    return response, nil, {
        runtime.effect('membership.visibility_changed', 'membership',
            membership.public_id, membership.group_public_id,
            membership.character_id,
            { visibility = membership.visibility, version = currentVersion,
                profile_version = profileVersion },
            { visibility = visibility, version = nextVersion,
                profile_version = profileVersion + 1 },
            request.reason, nextVersion)
    }
end

function handlers.execute.members_set_primary(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    if membership.character_id ~= request.actor_character_id
        or membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'Only an active member may select their own primary membership.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local groupType = tx.one([[SELECT type_record.id
        FROM synex_group_organization_profiles AS profile
        INNER JOIN synex_group_types AS type_record ON type_record.id = profile.group_type_id
        WHERE profile.group_id = ? AND type_record.type_key = ? FOR UPDATE]],
        { membership.group_id, request.group_type })
    if not groupType then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The membership does not belong to the requested group type.')
    end
    local current = tx.one([[SELECT membership_id, public_id, version
        FROM synex_group_primary_memberships_by_type
        WHERE character_id = ? AND group_type_id = ? FOR UPDATE]], {
        request.actor_character_id, groupType.id
    })
    local nextVersion = current and tonumber(current.version) + 1 or 1
    local primaryId = current and current.public_id or nil
    if current then
        local updated, updateError = ensureAffected(tx,
            [[UPDATE synex_group_primary_memberships_by_type
            SET membership_id = ?, assigned_by_ref = ?, reason_code = 'self_selected',
                version = version + 1, assigned_at = CURRENT_TIMESTAMP(6)
            WHERE character_id = ? AND group_type_id = ? AND version = ?]], {
            membership.id, request.actor_character_id,
            request.actor_character_id, groupType.id, current.version
        }, 'The primary membership changed concurrently.')
        if not updated then return nil, updateError end
    else
        local idError
        primaryId, idError = nextId(runtime, 'group_primary')
        if not primaryId then return nil, idError end
        tx.query([[INSERT INTO synex_group_primary_memberships_by_type
            (character_id, group_type_id, membership_id, public_id, assigned_by_ref,
             reason_code, version)
            VALUES (?, ?, ?, ?, ?, 'self_selected', 1)]], {
            request.actor_character_id, groupType.id,
            membership.id, primaryId, request.actor_character_id
        })
    end
    local response = runtime.success(
        primaryId, 'membership_primary', 'active', nextVersion)
    return response, nil, {
        runtime.effect('membership.primary_changed', 'membership_primary',
            primaryId, membership.group_public_id,
            membership.character_id,
            current and { membership_internal_id = current.membership_id,
                version = current.version } or nil,
            { membership_id = membership.public_id, group_type = request.group_type,
                version = nextVersion },
            'self_selected', nextVersion)
    }
end

function handlers.execute.roles_assign(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    if membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_ACTIVE',
            'Roles can only be assigned to active memberships.')
    end
    local actor, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.roles.manage', 'group', {
            target_membership = membership,
            parameters = { role_id = request.role_id }
        })
    if not actor then return nil, authorizationError end
    local role = tx.one([[SELECT id, public_id, exclusivity, holder_limit
        FROM synex_group_roles
        WHERE public_id = ? AND group_id = ? AND status = 'active' FOR UPDATE]],
        { request.role_id, membership.group_id })
    if not role then
        return nil, Foundation.domainError('ROLE_NOT_FOUND',
            'The requested active role does not belong to the group.')
    end
    if actor.id == membership.id then
        if not Foundation.isCallable(runtime.verifyApprovedOperation) then
            return nil, Foundation.domainError('APPROVAL_REQUIRED',
                'Assigning a role to the actor requires an approved Groups proposal.',
                false, { action = 'role.assign', role_id = role.public_id })
        end
        local approved, approvalError = runtime.verifyApprovedOperation(
            context, 'roles_assign', request, membership.group_public_id)
        if not approved then return nil, approvalError end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local active = tx.one([[SELECT id FROM synex_group_membership_roles
        WHERE membership_id = ? AND role_id = ? AND status = 'active'
        FOR UPDATE]], { membership.id, role.id })
    if active then
        return nil, Foundation.domainError('ROLE_EXCLUSIVE_CONFLICT',
            'The membership already holds this role.')
    end
    if role.holder_limit then
        local holders = tx.one([[SELECT COUNT(*) AS count
            FROM synex_group_membership_roles
            WHERE role_id = ? AND status = 'active'
                AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP(6))]],
            { role.id })
        if tonumber(holders and holders.count) >= tonumber(role.holder_limit) then
            return nil, Foundation.domainError('ROLE_EXCLUSIVE_CONFLICT',
                'The role has reached its holder limit.')
        end
    end
    if request.valid_from ~= nil or request.valid_until ~= nil then
        local window = tx.one([[SELECT CASE
            WHEN ? IS NOT NULL AND CAST(? AS DATETIME(6)) <= CURRENT_TIMESTAMP(6) THEN 0
            WHEN ? IS NOT NULL AND ? IS NOT NULL
                AND CAST(? AS DATETIME(6)) <= CAST(? AS DATETIME(6)) THEN 0
            ELSE 1 END AS valid]], {
            request.valid_until, request.valid_until,
            request.valid_from, request.valid_until,
            request.valid_until, request.valid_from
        })
        if not window or tonumber(window.valid) ~= 1 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The role assignment time window is invalid.')
        end
    end
    local assignmentId, idError = nextId(runtime, 'group_mrole')
    if not assignmentId then return nil, idError end
    tx.query([[INSERT INTO synex_group_membership_roles
        (public_id, membership_id, role_id, exclusive_role_id, status,
         valid_from, valid_until, revoked_at, assigned_by_ref, reason_code, version)
        VALUES (?, ?, ?, ?, 'active', COALESCE(?, CURRENT_TIMESTAMP(6)),
            ?, NULL, ?, ?, 1)]], {
        assignmentId, membership.id, role.id,
        role.exclusivity == 'group' and role.id or nil,
        request.valid_from, request.valid_until, request.actor_character_id,
        runtime.reason(request.reason, 'role_assigned')
    })
    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(assignmentId, 'membership_role', 'active', 1)
    return response, nil, {
        runtime.effect('role.assigned', 'membership_role', assignmentId,
            membership.group_public_id, membership.character_id, nil,
            { role_id = role.public_id, membership_id = membership.public_id,
                version = 1 },
            request.reason, 1)
    }
end

function handlers.execute.roles_remove(tx, request, runtime, context)
    local assignment = tx.one([[SELECT assignment.id, assignment.public_id,
            assignment.version, assignment.status, role.public_id AS role_public_id,
            membership.id AS membership_internal_id,
            membership.public_id AS membership_public_id,
            membership.group_id, profile.character_id, profile.lifecycle_state,
            group_record.id AS group_internal_id,
            group_record.public_id AS group_public_id
        FROM synex_group_membership_roles AS assignment
        INNER JOIN synex_group_roles AS role ON role.id = assignment.role_id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = assignment.membership_id
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        WHERE assignment.public_id = ? FOR UPDATE]], { request.membership_role_id })
    if not assignment then
        return nil, Foundation.domainError('ROLE_NOT_FOUND',
            'The membership role assignment does not exist.')
    end
    local targetMembership = {
        id = tonumber(assignment.membership_internal_id),
        public_id = assignment.membership_public_id,
        group_id = tonumber(assignment.group_id),
        group_public_id = assignment.group_public_id,
        character_id = assignment.character_id,
        lifecycle_state = assignment.lifecycle_state
    }
    if not targetMembership.id or math.type(targetMembership.id) ~= 'integer'
        or targetMembership.id < 1 or not targetMembership.group_id
        or math.type(targetMembership.group_id) ~= 'integer'
        or targetMembership.group_id < 1 then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored role assignment membership is invalid.', true)
    end
    local actor, authorizationError = runtime.authorize(
        tx, assignment.group_public_id, request.actor_character_id,
        'synex.groups.roles.manage', 'group', {
            target_membership = targetMembership,
            parameters = { role_id = assignment.role_public_id }
        })
    if not actor then return nil, authorizationError end
    if actor.id == targetMembership.id then
        if not Foundation.isCallable(runtime.verifyApprovedOperation) then
            return nil, Foundation.domainError('APPROVAL_REQUIRED',
                'Removing a role from the actor requires an approved Groups proposal.',
                false, { action = 'role.remove', role_id = assignment.role_public_id })
        end
        local approved, approvalError = runtime.verifyApprovedOperation(
            context, 'roles_remove', request, assignment.group_public_id)
        if not approved then return nil, approvalError end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if assignment.status ~= 'active'
        or tonumber(assignment.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The membership role assignment changed.', true)
    end
    local nextVersion = tonumber(assignment.version) + 1
    local changed, changeError = ensureAffected(tx, [[UPDATE synex_group_membership_roles
        SET status = 'revoked', revoked_at = CURRENT_TIMESTAMP(6),
            reason_code = ?, version = version + 1
        WHERE id = ? AND status = 'active' AND version = ?]], {
        runtime.reason(request.reason, 'role_removed'),
        assignment.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local touched, touchError = runtime.touchGroup(tx, assignment.group_internal_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        assignment.public_id, 'membership_role', 'revoked', nextVersion)
    return response, nil, {
        runtime.effect('role.removed', 'membership_role', assignment.public_id,
            assignment.group_public_id, assignment.character_id,
            { role_id = assignment.role_public_id,
                membership_id = assignment.membership_public_id,
                status = assignment.status, version = assignment.version },
            response, request.reason, nextVersion)
    }
end

return handlers
end
