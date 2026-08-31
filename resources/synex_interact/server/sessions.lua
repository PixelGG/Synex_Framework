SynexInteractSessions = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractSessions.create(options)
    options = options or {}
    local now = assert(options.now, 'session runtime requires a monotonic clock')
    local sessions, count = {}, 0
    local actorSessions, sourceSessions = {}, {}
    local runtime = {}

    local function participantKey(source, sourceGeneration)
        return tostring(source) .. ':' .. tostring(sourceGeneration)
    end

    local function indexParticipant(session, actorKey, member)
        actorSessions[actorKey] = actorSessions[actorKey] or {}
        actorSessions[actorKey][session.id] = session
        sourceSessions[member.source] = sourceSessions[member.source] or {}
        sourceSessions[member.source][session.id .. '#' .. actorKey] = {
            session = session, actorKey = actorKey,
            sourceGeneration = member.sourceGeneration,
        }
    end

    local function unindexParticipant(session, actorKey, member)
        local actorIndex = actorSessions[actorKey]
        if actorIndex then
            actorIndex[session.id] = nil
            if next(actorIndex) == nil then actorSessions[actorKey] = nil end
        end
        local sourceIndex = sourceSessions[member.source]
        if sourceIndex then
            sourceIndex[session.id .. '#' .. actorKey] = nil
            if next(sourceIndex) == nil then sourceSessions[member.source] = nil end
        end
    end

    function runtime.create(request)
        if count >= Limits.maximumActiveSessions or sessions[request.sessionId] then
            return Validation.failure('INTERACT_SESSION_LIMIT', 'Interaction session capacity is exhausted.')
        end
        local roles = {}
        for _, definition in ipairs(request.roles or {}) do
            if roles[definition.role] then
                return Validation.failure('INTERACT_SESSION_INVALID', 'Participant roles must be unique.')
            end
            roles[definition.role] = {
                role = definition.role, required = definition.required,
                capacity = definition.capacity or 1,
                lossPolicy = definition.lossPolicy or 'ABORT', members = {}, count = 0,
                lateJoin = definition.lateJoin == true,
                replacementReservationId = nil,
            }
        end
        local session = {
            id = request.sessionId, state = 'WAITING', roles = roles,
            ownerResource = request.ownerResource, ownerEpoch = request.ownerEpoch,
            bundleKey = request.bundleKey, bundleRevision = request.bundleRevision,
            intentKey = request.intentKey, target = Validation.copy(request.target),
            worldInstance = Validation.copy(request.worldInstance),
            reservationId = request.reservationId,
            slotClaims = Validation.copy(request.slotClaims or {}),
            createdAt = now(), expiresAt = request.expiresAt,
            executionId = nil, cancellation = nil,
            invitations = {}, invitationCount = 0,
        }
        sessions[session.id], count = session, count + 1
        return session, nil
    end

    function runtime.join(sessionId, actor, roleName, leaseId, reservationId)
        local session = sessions[sessionId]
        if not session or session.state ~= 'WAITING'
            and session.state ~= 'RUNNING' then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND', 'The interaction session is unavailable.')
        end
        if session.expiresAt <= now() then
            return Validation.failure('INTERACT_SESSION_EXPIRED', 'The interaction session expired.')
        end
        local role = session.roles[roleName]
        if not role or role.count >= role.capacity then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED', 'The participant role is unavailable.')
        end
        local replacing = role.replacementReservationId ~= nil
            and role.replacementReservationId == reservationId
        local admittedLate = session.executionId ~= nil and not replacing
        if admittedLate and (role.required or not role.lateJoin) then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant role does not allow late join.')
        end
        local key = participantKey(actor.source, actor.sourceGeneration)
        for _, candidate in pairs(session.roles) do
            if candidate.members[key] then
                return Validation.failure('INTERACT_PARTICIPANT_DENIED', 'The actor already joined this session.')
            end
        end
        role.members[key] = {
            key = key, source = actor.source, sourceGeneration = actor.sourceGeneration,
            sessionIdentity = actor.sessionIdentity, role = roleName,
            leaseId = leaseId, reservationId = reservationId, ready = false,
            joinedAt = now(), lateJoin = admittedLate,
        }
        indexParticipant(session, key, role.members[key])
        if replacing then
            role.replacementReservationId = nil
        end
        role.count = role.count + 1
        return role.members[key], nil
    end

    local function removeInvitation(session, invitationId)
        if session.invitations[invitationId] then
            session.invitations[invitationId] = nil
            session.invitationCount = math.max(0, session.invitationCount - 1)
            return true
        end
        return false
    end

    local function invitationFor(session, invitationId, actor, roleName)
        local invitation = session and session.invitations[invitationId] or nil
        if not invitation or invitation.expiresAt <= now() then
            if invitation then removeInvitation(session, invitationId) end
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant invitation is unavailable or expired.')
        end
        if invitation.sessionId ~= session.id
            or invitation.ownerResource ~= session.ownerResource
            or invitation.ownerEpoch ~= session.ownerEpoch
            or invitation.role ~= roleName
            or invitation.source ~= actor.source
            or invitation.sourceGeneration ~= actor.sourceGeneration
            or invitation.sessionIdentity ~= actor.sessionIdentity then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant invitation does not authorize this actor and role.')
        end
        return invitation, nil
    end

    function runtime.invite(sessionId, invitation)
        local session = sessions[sessionId]
        if not session or session.state ~= 'WAITING' and session.state ~= 'RUNNING'
            or session.expiresAt <= now() then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session is unavailable.')
        end
        local role = session.roles[invitation.role]
        if not role or role.count >= role.capacity
            or session.invitationCount >= Limits.maximumSessionInvitations
            or session.invitations[invitation.id] ~= nil
            or invitation.ownerResource ~= session.ownerResource
            or invitation.ownerEpoch ~= session.ownerEpoch
            or not Validation.token(invitation.id, 8, 96)
            or not Validation.isInteger(invitation.source, 1, 65535)
            or not Validation.isInteger(invitation.sourceGeneration, 1)
            or not Validation.token(invitation.sessionIdentity, 8, 96)
            or not Validation.isInteger(invitation.expiresAt, now() + 1,
                session.expiresAt) then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant invitation is invalid or capacity is exhausted.')
        end
        local stored = Validation.copy(invitation)
        stored.sessionId = session.id
        session.invitations[stored.id] = stored
        session.invitationCount = session.invitationCount + 1
        return Validation.copy(stored), nil
    end

    function runtime.getInvitation(sessionId, invitationId, actor, roleName)
        local session = sessions[sessionId]
        if not session then return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local invitation, operationError = invitationFor(
            session, invitationId, actor, roleName)
        return invitation and Validation.copy(invitation) or nil, operationError
    end

    function runtime.consumeInvitation(sessionId, invitationId, actor, roleName)
        local session = sessions[sessionId]
        if not session then return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local invitation, operationError = invitationFor(
            session, invitationId, actor, roleName)
        if not invitation then return nil, operationError end
        removeInvitation(session, invitationId)
        return invitation, nil
    end

    function runtime.expireInvitations(timestamp)
        if not Validation.isInteger(timestamp, 0) then return 0 end
        local expired = 0
        for _, session in pairs(sessions) do
            local ids = {}
            for invitationId, invitation in pairs(session.invitations) do
                if invitation.expiresAt <= timestamp then ids[#ids + 1] = invitationId end
            end
            for _, invitationId in ipairs(ids) do
                if removeInvitation(session, invitationId) then expired = expired + 1 end
            end
        end
        return expired
    end

    function runtime.markReady(sessionId, actorKey)
        local session = sessions[sessionId]
        if not session or session.state ~= 'WAITING' and session.state ~= 'READY'
            and session.state ~= 'RUNNING' then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local found = false
        for _, role in pairs(session.roles) do
            local participant = role.members[actorKey]
            if participant then participant.ready, found = true, true; break end
        end
        if not found then return Validation.failure('INTERACT_PARTICIPANT_DENIED',
            'The actor is not part of this interaction session.') end
        if session.state == 'RUNNING' then
            return { sessionId = sessionId, ready = true, state = session.state,
                lateJoin = true }, nil
        end
        local ready = true
        for _, role in pairs(session.roles) do
            if role.required then
                local readyCount = 0
                for _, member in pairs(role.members) do if member.ready then readyCount = readyCount + 1 end end
                if readyCount < role.capacity then ready = false; break end
            end
        end
        if ready and session.state == 'WAITING' then session.state = 'READY' end
        return { sessionId = sessionId, ready = ready, state = session.state }, nil
    end

    function runtime.leave(sessionId, actorKey, reason)
        local session = sessions[sessionId]
        if not session then return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local removed, policy, removedRole
        for _, role in pairs(session.roles) do
            if role.members[actorKey] then
                removed, policy, removedRole = role.members[actorKey], role.lossPolicy, role
                role.members[actorKey], role.count = nil, role.count - 1
                unindexParticipant(session, actorKey, removed)
                break
            end
        end
        if not removed then return Validation.failure('INTERACT_PARTICIPANT_DENIED',
            'The actor is not part of this interaction session.') end
        if removed and policy == 'ABORT' then
            session.state = 'CANCELLING'
            session.cancellation = reason or 'PARTICIPANT_LOST'
        elseif removed and policy == 'REPLACE' then
            removedRole.replacementReservationId = removed.reservationId
            session.state = 'WAITING'
        end
        return { participant = removed, policy = policy, state = session.state,
            role = removedRole and removedRole.role or nil }, nil
    end

    function runtime.discard(sessionId, actorKey)
        local session = sessions[sessionId]
        if not session then return nil end
        for _, role in pairs(session.roles) do
            local removed = role.members[actorKey]
            if removed then
                role.members[actorKey] = nil
                role.count = math.max(0, role.count - 1)
                unindexParticipant(session, actorKey, removed)
                return removed
            end
        end
        return nil
    end

    function runtime.setExecution(sessionId, executionId)
        local session = sessions[sessionId]
        if not session or session.state ~= 'READY' then
            return Validation.failure('INTERACT_SESSION_NOT_READY', 'The participant barrier is not ready.')
        end
        session.executionId, session.state = executionId, 'RUNNING'
        return session, nil
    end

    function runtime.resumeExecution(sessionId, executionId)
        local session = sessions[sessionId]
        if not session or session.state ~= 'READY'
            or session.executionId ~= executionId then
            return Validation.failure('INTERACT_SESSION_NOT_READY',
                'The replacement participant barrier is not ready.')
        end
        session.state = 'RUNNING'
        return session, nil
    end

    function runtime.finish(sessionId, state, reason)
        local session = sessions[sessionId]
        if not session then return false end
        session.state = state
        session.cancellation = reason
        return true
    end

    function runtime.remove(sessionId)
        local session = sessions[sessionId]
        if not session then return nil end
        for _, role in pairs(session.roles) do
            for actorKey, member in pairs(role.members) do
                unindexParticipant(session, actorKey, member)
            end
        end
        sessions[sessionId], count = nil, count - 1
        return session
    end

    function runtime.get(sessionId) return sessions[sessionId] end

    function runtime.findActor(actorKey)
        local result = {}
        for _, session in pairs(actorSessions[actorKey] or {}) do
            result[#result + 1] = session
        end
        table.sort(result, function(left, right) return left.id < right.id end)
        return result
    end

    function runtime.findSource(source)
        local result = {}
        for _, record in pairs(sourceSessions[source] or {}) do
            result[#result + 1] = record
        end
        table.sort(result, function(left, right)
            if left.session.id == right.session.id then
                return left.actorKey < right.actorKey
            end
            return left.session.id < right.session.id
        end)
        return result
    end

    function runtime.findOwner(ownerResource, ownerEpoch)
        local result = {}
        for _, session in pairs(sessions) do
            if session.ownerResource == ownerResource
                and (ownerEpoch == nil or session.ownerEpoch == ownerEpoch) then
                result[#result + 1] = session
            end
        end
        table.sort(result, function(left, right) return left.id < right.id end)
        return result
    end

    function runtime.expired(timestamp)
        local result = {}
        if not Validation.isInteger(timestamp, 0) then return result end
        for _, session in pairs(sessions) do
            if session.expiresAt <= timestamp and session.state ~= 'CANCELLING' then
                result[#result + 1] = session
            end
        end
        table.sort(result, function(left, right) return left.id < right.id end)
        return result
    end

    function runtime.list(cursor, limit)
        local values = {}
        for _, session in pairs(sessions) do
            local participants = 0
            for _, role in pairs(session.roles) do participants = participants + role.count end
            values[#values + 1] = { sessionId = session.id, state = session.state,
                intent = session.intentKey, ownerResource = session.ownerResource,
                bundleRevision = session.bundleRevision, participants = participants,
                createdAt = session.createdAt, expiresAt = session.expiresAt }
        end
        table.sort(values, function(left, right) return left.sessionId < right.sessionId end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + size - 1) do items[#items + 1] = values[index] end
        local hasMore = start + #items - 1 < #values
        return { items = items, nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end

    function runtime.snapshot()
        local invitations = 0
        for _, session in pairs(sessions) do invitations = invitations + session.invitationCount end
        return { active = count, invitations = invitations,
            capacity = Limits.maximumActiveSessions }
    end
    return runtime
end
