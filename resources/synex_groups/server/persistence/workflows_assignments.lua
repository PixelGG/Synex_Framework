return function(Foundation)
local Shared = require('server.persistence.workflows_shared')(Foundation)
local identifier = Shared.identifier
local updateOne = Shared.updateOne
local validWindow = Shared.validWindow
local handlers = { read = {}, execute = {} }
local MAXIMUM_ASSIGNMENT_METADATA_BYTES = 16384

local function encodeMetadata(runtime, metadata)
    local encodedOk, encoded = pcall(runtime.jsonEncode, metadata or {})
    if not encodedOk or type(encoded) ~= 'string'
        or #encoded > MAXIMUM_ASSIGNMENT_METADATA_BYTES then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Assignment metadata exceeds its supported 16 KiB bound.')
    end
    return encoded, nil
end

function handlers.execute.assignments_create(tx, request, runtime, context)
    local actor, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.assignments.manage', 'group')
    if not actor then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = runtime.requireGroup(tx, request.group_id, true)
    if not group then return nil, groupError end
    if group.status ~= 'active' or group.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'Assignments require an active group.')
    end
    local windowValid, windowError = validWindow(
        tx, request.starts_at, request.ends_at)
    if not windowValid then return nil, windowError end
    local parentInternalId
    if request.parent_assignment_id then
        local parent = tx.one([[SELECT id FROM synex_group_assignments
            WHERE public_id = ? AND group_id = ? AND status = 'active' FOR UPDATE]],
            { request.parent_assignment_id, group.id })
        if not parent then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The parent assignment is not active in the same group.')
        end
        parentInternalId = parent.id
    end
    local assignmentId, idError = identifier(runtime, 'group_assign')
    if not assignmentId then return nil, idError end
    local metadataJson, metadataError = encodeMetadata(runtime, request.metadata)
    if not metadataJson then return nil, metadataError end
    tx.query([[INSERT INTO synex_group_assignments
        (public_id, group_id, assignment_key, display_name, status, member_limit,
         valid_from, valid_until, created_by_membership_id, version,
         parent_assignment_id, assignment_type, metadata_json)
        VALUES (?, ?, ?, ?, 'active', NULL, COALESCE(?, CURRENT_TIMESTAMP(6)),
            ?, ?, 1, ?, ?, ?)]], {
        assignmentId, group.id, assignmentId, request.name,
        request.starts_at, request.ends_at, actor.id, parentInternalId,
        request.type, metadataJson
    })
    local response = runtime.success(assignmentId, 'assignment', 'active', 1)
    return response, nil, {
        runtime.effect('assignment.created', 'assignment', assignmentId,
            request.group_id, request.actor_character_id, nil,
            { name = request.name, type = request.type,
                parent_assignment_id = request.parent_assignment_id, version = 1 },
            'assignment_created', 1)
    }
end

function handlers.execute.assignments_join(tx, request, runtime, context)
    local assignment = tx.one([[SELECT assignment.id, assignment.public_id,
            assignment.group_id, assignment.status, assignment.member_limit,
            CASE WHEN assignment.valid_from <= CURRENT_TIMESTAMP(6)
                AND (assignment.valid_until IS NULL
                    OR assignment.valid_until > CURRENT_TIMESTAMP(6))
                THEN 1 ELSE 0 END AS inside_window,
            group_record.public_id AS group_public_id
        FROM synex_group_assignments AS assignment
        INNER JOIN synex_groups AS group_record ON group_record.id = assignment.group_id
        WHERE assignment.public_id = ? FOR UPDATE]], { request.assignment_id })
    if not assignment then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The assignment is not active inside its configured time window.')
    end
    local _, authorizationError = runtime.authorize(
        tx, assignment.group_public_id, request.actor_character_id,
        'synex.groups.assignments.manage', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if assignment.status ~= 'active'
        or tonumber(assignment.inside_window) ~= 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The assignment is not active inside its configured time window.')
    end
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    if membership.group_id ~= assignment.group_id
        or membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_ACTIVE',
            'Assignment participants need an active membership in the same group.')
    end
    if tx.one([[SELECT id FROM synex_group_assignment_members
        WHERE assignment_id = ? AND membership_id = ? AND status = 'active'
        FOR UPDATE]], { assignment.id, membership.id }) then
        return nil, Foundation.domainError('IDEMPOTENCY_CONFLICT',
            'The membership already participates in this assignment.')
    end
    if assignment.member_limit then
        local count = tx.one([[SELECT COUNT(*) AS count
            FROM synex_group_assignment_members
            WHERE assignment_id = ? AND status = 'active']], { assignment.id })
        if tonumber(count and count.count) >= tonumber(assignment.member_limit) then
            return nil, Foundation.domainError('MEMBER_LIMIT_REACHED',
                'The assignment has reached its member limit.')
        end
    end
    local assignmentMemberId, idError = identifier(runtime, 'group_amember')
    if not assignmentMemberId then return nil, idError end
    tx.query([[INSERT INTO synex_group_assignment_members
        (assignment_id, membership_id, status, joined_at, left_at,
         reason_code, version, public_id, role_key)
        VALUES (?, ?, 'active', CURRENT_TIMESTAMP(6), NULL,
            'assignment_joined', 1, ?, ?)]], {
        assignment.id, membership.id, assignmentMemberId, request.role or 'member'
    })
    local response = runtime.success(
        assignmentMemberId, 'assignment_member', 'active', 1)
    return response, nil, {
        runtime.effect('assignment.joined', 'assignment_member',
            assignmentMemberId, assignment.group_public_id,
            membership.character_id, nil,
            { assignment_id = assignment.public_id,
                membership_id = membership.public_id, role = request.role or 'member',
                version = 1 },
            'assignment_joined', 1)
    }
end

function handlers.execute.assignments_leave(tx, request, runtime, context)
    local participant = tx.one([[SELECT participant.id, participant.public_id,
            participant.version, participant.status,
            participant.assignment_id, participant.membership_id,
            assignment.public_id AS assignment_public_id,
            group_record.public_id AS group_public_id,
            membership.public_id AS membership_public_id,
            profile.character_id
        FROM synex_group_assignment_members AS participant
        INNER JOIN synex_group_assignments AS assignment
            ON assignment.id = participant.assignment_id
        INNER JOIN synex_groups AS group_record ON group_record.id = assignment.group_id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = participant.membership_id
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        WHERE participant.public_id = ? FOR UPDATE]], {
        request.assignment_member_id
    })
    if not participant then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The assignment membership does not exist.')
    end
    if participant.character_id ~= request.actor_character_id then
        local _, authorizationError = runtime.authorize(
            tx, participant.group_public_id, request.actor_character_id,
            'synex.groups.assignments.manage', 'group')
        if authorizationError then return nil, authorizationError end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if participant.status ~= 'active'
        or tonumber(participant.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The assignment membership changed.', true)
    end
    local nextVersion = tonumber(participant.version) + 1
    local dutySession = tx.one([[SELECT id, public_id, state_key, metadata_json,
            version FROM synex_group_duty_sessions
        WHERE membership_id = ? AND assignment_id = ? AND status = 'open'
        FOR UPDATE]], { participant.membership_id, participant.assignment_id })
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_assignment_members
        SET status = 'left', left_at = CURRENT_TIMESTAMP(6), reason_code = ?,
            version = version + 1
        WHERE id = ? AND status = 'active' AND version = ?]], {
        runtime.reason(request.reason, 'assignment_left'),
        participant.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local effects = {}
    if dutySession then
        local dutyVersion = tonumber(dutySession.version) + 1
        local dutyChanged, dutyError = updateOne(tx, [[UPDATE synex_group_duty_sessions
            SET status = 'closed', ended_at = CURRENT_TIMESTAMP(6),
                reason_code = 'assignment_left', version = version + 1
            WHERE id = ? AND status = 'open' AND version = ?]], {
            dutySession.id, dutySession.version
        })
        if not dutyChanged then return nil, dutyError end
        local eventId, eventError = identifier(runtime, 'group_devent')
        if not eventId then return nil, eventError end
        tx.query([[INSERT INTO synex_group_duty_events
            (event_id, duty_session_id, session_version, event_type, state_key,
             actor_ref, reason_code, assignment_id, metadata_json)
            VALUES (?, ?, ?, 'ended', ?, ?, 'assignment_left', ?, ?)]], {
            eventId, dutySession.id, dutyVersion, dutySession.state_key,
            request.actor_character_id, participant.assignment_id,
            dutySession.metadata_json
        })
        effects[#effects + 1] = runtime.effect('duty.ended', 'duty_session',
            dutySession.public_id, participant.group_public_id,
            participant.character_id,
            { status = 'open', state = dutySession.state_key,
                version = dutySession.version },
            { status = 'closed', reason = 'assignment_left',
                version = dutyVersion }, 'assignment_left', dutyVersion)
    end
    local response = runtime.success(
        participant.public_id, 'assignment_member', 'left', nextVersion)
    effects[#effects + 1] = runtime.effect('assignment.left', 'assignment_member',
        participant.public_id, participant.group_public_id,
        participant.character_id,
        { assignment_id = participant.assignment_public_id,
            membership_id = participant.membership_public_id,
            status = 'active', version = participant.version },
        response, request.reason, nextVersion)
    return response, nil, effects
end

local function closeAssignment(tx, request, runtime, target, context)
    local assignment = tx.one([[SELECT assignment.id, assignment.public_id,
            assignment.group_id, assignment.status, assignment.version,
            group_record.public_id AS group_public_id
        FROM synex_group_assignments AS assignment
        INNER JOIN synex_groups AS group_record ON group_record.id = assignment.group_id
        WHERE assignment.public_id = ? FOR UPDATE]], { request.assignment_id })
    if not assignment then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The assignment does not exist.')
    end
    local _, authorizationError = runtime.authorize(
        tx, assignment.group_public_id, request.actor_character_id,
        'synex.groups.assignments.manage', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if assignment.status ~= 'active' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Only an active assignment can be closed.')
    end
    if tonumber(assignment.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The assignment changed before it could be closed.', true)
    end

    local reasonCode = runtime.reason(request.reason, 'assignment_' .. target)
    local dutyEvents = tx.affected([[INSERT INTO synex_group_duty_events
        (event_id, duty_session_id, session_version, event_type, state_key,
         actor_ref, reason_code, assignment_id, metadata_json)
        SELECT CONCAT('group_devent_', SUBSTRING(SHA2(CONCAT(
                'synex:assignment:', session.public_id, ':', ?, ':',
                session.version + 1), 256), 1, 35)),
            session.id, session.version + 1, 'ended', session.state_key,
            ?, ?, session.assignment_id, session.metadata_json
        FROM synex_group_duty_sessions AS session
        WHERE session.assignment_id = ? AND session.status = 'open'
        ORDER BY session.id ASC]], {
        target, request.actor_character_id, reasonCode, assignment.id
    })
    local dutySessions = tx.affected([[UPDATE synex_group_duty_sessions
        SET status = 'closed', ended_at = CURRENT_TIMESTAMP(6),
            reason_code = ?, version = version + 1
        WHERE assignment_id = ? AND status = 'open']], {
        reasonCode, assignment.id
    })
    if dutyEvents ~= dutySessions then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'Assignment duty history could not be closed atomically.', true)
    end
    local participants = tx.affected([[UPDATE synex_group_assignment_members
        SET status = 'removed', left_at = CURRENT_TIMESTAMP(6),
            reason_code = ?, version = version + 1
        WHERE assignment_id = ? AND status = 'active']], {
        reasonCode, assignment.id
    })
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_assignments
        SET status = ?, version = version + 1
        WHERE id = ? AND status = 'active' AND version = ?]], {
        target, assignment.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local touched, touchError = runtime.touchGroup(tx, assignment.group_id)
    if not touched then return nil, touchError end
    local nextVersion = tonumber(assignment.version) + 1
    local response = runtime.success(
        assignment.public_id, 'assignment', target, nextVersion)
    return response, nil, {
        runtime.effect('assignment.' .. target, 'assignment',
            assignment.public_id, assignment.group_public_id,
            request.actor_character_id,
            { status = assignment.status, version = assignment.version },
            { status = target, participants_removed = participants,
                duty_sessions_closed = dutySessions, version = nextVersion },
            request.reason, nextVersion)
    }
end

function handlers.execute.assignments_complete(tx, request, runtime, context)
    return closeAssignment(tx, request, runtime, 'completed', context)
end

function handlers.execute.assignments_cancel(tx, request, runtime, context)
    return closeAssignment(tx, request, runtime, 'cancelled', context)
end

return handlers
end
