return function(Foundation)
local Shared = require('server.persistence.workflows_shared')(Foundation)
local identifier = Shared.identifier
local updateOne = Shared.updateOne
local validWindow = Shared.validWindow
local handlers = { read = {}, execute = {} }

local function dutyContext(tx, sessionId)
    return tx.one([[SELECT session.id, session.public_id, session.membership_id,
            session.state_key, session.status, session.assignment_id,
            session.metadata_json, session.version,
            membership.public_id AS membership_public_id,
            profile.character_id, profile.lifecycle_state,
            group_record.id AS group_internal_id,
            group_record.public_id AS group_public_id,
            organization.group_type_id
        FROM synex_group_duty_sessions AS session
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = session.membership_id
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        INNER JOIN synex_group_organization_profiles AS organization
            ON organization.group_id = group_record.id
        WHERE session.public_id = ? FOR UPDATE]], { sessionId })
end

local function dutyState(tx, groupTypeId, stateKey)
    return tx.one([[SELECT state.state_key
        FROM synex_group_duty_states AS state
        INNER JOIN synex_group_type_duty_states AS allowed
            ON allowed.state_key = state.state_key
        WHERE allowed.group_type_id = ? AND state.state_key = ?
            AND state.status = 'active' FOR UPDATE]], { groupTypeId, stateKey })
end

local function assignmentForDuty(tx, assignmentId, membershipId, groupInternalId)
    if assignmentId == nil then return nil, nil end
    local assignment = tx.one([[SELECT assignment.id
        FROM synex_group_assignments AS assignment
        INNER JOIN synex_group_assignment_members AS participant
            ON participant.assignment_id = assignment.id
        WHERE assignment.public_id = ? AND assignment.group_id = ?
            AND assignment.status = 'active'
            AND participant.membership_id = ? AND participant.status = 'active'
            AND assignment.valid_from <= CURRENT_TIMESTAMP(6)
            AND (assignment.valid_until IS NULL
                OR assignment.valid_until > CURRENT_TIMESTAMP(6))
        FOR UPDATE]], { assignmentId, groupInternalId, membershipId })
    if not assignment then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Duty assignment requires an active assignment membership.')
    end
    return assignment.id, nil
end

function handlers.execute.duty_start(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    local _, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.duty.start', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_ACTIVE',
            'Duty requires an active membership.')
    end
    local typeRow = tx.one([[SELECT group_type_id
        FROM synex_group_organization_profiles WHERE group_id = ? FOR UPDATE]],
        { membership.group_id })
    if not typeRow or not dutyState(tx, typeRow.group_type_id, request.state) then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The requested duty state is not enabled for this group type.')
    end
    if tx.one([[SELECT id FROM synex_group_duty_sessions
        WHERE membership_id = ? AND status = 'open' FOR UPDATE]], { membership.id }) then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The membership already has an open duty session.')
    end
    local assignmentInternalId, assignmentError = assignmentForDuty(
        tx, request.assignment_id, membership.id, membership.group_id)
    if assignmentError then return nil, assignmentError end
    local dutyId, idError = identifier(runtime, 'group_duty')
    if not dutyId then return nil, idError end
    local eventId, eventError = identifier(runtime, 'group_devent')
    if not eventId then return nil, eventError end
    local metadataJson = runtime.jsonEncode(request.metadata or {})
    local internalId = tx.insert([[INSERT INTO synex_group_duty_sessions
        (public_id, membership_id, state_key, status, started_at, ended_at,
         reason_code, version, assignment_id, metadata_json)
        VALUES (?, ?, ?, 'open', CURRENT_TIMESTAMP(6), NULL,
            'duty_started', 1, ?, ?)]], {
        dutyId, membership.id, request.state, assignmentInternalId, metadataJson
    })
    tx.query([[INSERT INTO synex_group_duty_events
        (event_id, duty_session_id, session_version, event_type, state_key,
         actor_ref, reason_code, assignment_id, metadata_json)
        VALUES (?, ?, 1, 'started', ?, ?, 'duty_started', ?, ?)]], {
        eventId, internalId, request.state, request.actor_character_id,
        assignmentInternalId, metadataJson
    })
    local response = runtime.success(dutyId, 'duty_session', 'open', 1)
    return response, nil, {
        runtime.effect('duty.started', 'duty_session', dutyId,
            membership.group_public_id, membership.character_id, nil,
            { membership_id = membership.public_id, state = request.state,
                assignment_id = request.assignment_id, version = 1 },
            'duty_started', 1)
    }
end

function handlers.execute.duty_update(tx, request, runtime, context)
    local session = dutyContext(tx, request.duty_session_id)
    if not session then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The duty session does not exist.')
    end
    local _, authorizationError = runtime.authorize(
        tx, session.group_public_id, request.actor_character_id,
        'synex.groups.duty.update', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if session.status ~= 'open' or tonumber(session.version) ~= request.expected_version
        or session.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The open duty session or membership changed.', true)
    end
    if not dutyState(tx, session.group_type_id, request.state) then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The requested duty state is not enabled for this group type.')
    end
    local assignmentInternalId, assignmentError = assignmentForDuty(
        tx, request.assignment_id, session.membership_id, session.group_internal_id)
    if assignmentError then return nil, assignmentError end
    local nextVersion = tonumber(session.version) + 1
    local metadataJson = runtime.jsonEncode(request.metadata)
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_duty_sessions
        SET state_key = ?, assignment_id = ?, metadata_json = ?,
            reason_code = 'duty_updated', version = version + 1
        WHERE id = ? AND status = 'open' AND version = ?]], {
        request.state, assignmentInternalId, metadataJson,
        session.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local eventId, eventError = identifier(runtime, 'group_devent')
    if not eventId then return nil, eventError end
    tx.query([[INSERT INTO synex_group_duty_events
        (event_id, duty_session_id, session_version, event_type, state_key,
         actor_ref, reason_code, assignment_id, metadata_json)
        VALUES (?, ?, ?, 'state_changed', ?, ?, 'duty_updated', ?, ?)]], {
        eventId, session.id, nextVersion, request.state,
        request.actor_character_id, assignmentInternalId, metadataJson
    })
    local response = runtime.success(
        session.public_id, 'duty_session', 'open', nextVersion)
    return response, nil, {
        runtime.effect('duty.updated', 'duty_session', session.public_id,
            session.group_public_id, session.character_id,
            { state = session.state_key, version = session.version },
            { state = request.state, assignment_id = request.assignment_id,
                version = nextVersion },
            'duty_updated', nextVersion)
    }
end

function handlers.execute.duty_stop(tx, request, runtime, context)
    local session = dutyContext(tx, request.duty_session_id)
    if not session then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The duty session does not exist.')
    end
    local _, authorizationError = runtime.authorize(
        tx, session.group_public_id, request.actor_character_id,
        'synex.groups.duty.stop', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if session.status ~= 'open' or tonumber(session.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The duty session changed.', true)
    end
    local nextVersion = tonumber(session.version) + 1
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_duty_sessions
        SET status = 'closed', ended_at = CURRENT_TIMESTAMP(6), reason_code = ?,
            version = version + 1
        WHERE id = ? AND status = 'open' AND version = ?]], {
        runtime.reason(request.reason, 'duty_ended'),
        session.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local eventId, eventError = identifier(runtime, 'group_devent')
    if not eventId then return nil, eventError end
    tx.query([[INSERT INTO synex_group_duty_events
        (event_id, duty_session_id, session_version, event_type, state_key,
         actor_ref, reason_code, assignment_id, metadata_json)
        VALUES (?, ?, ?, 'ended', ?, ?, ?, ?, ?)]], {
        eventId, session.id, nextVersion, session.state_key,
        request.actor_character_id, runtime.reason(request.reason, 'duty_ended'),
        session.assignment_id, session.metadata_json
    })
    local response = runtime.success(
        session.public_id, 'duty_session', 'closed', nextVersion)
    return response, nil, {
        runtime.effect('duty.ended', 'duty_session', session.public_id,
            session.group_public_id, session.character_id,
            { state = session.state_key, status = 'open', version = session.version },
            response, request.reason, nextVersion)
    }
end

return handlers
end
