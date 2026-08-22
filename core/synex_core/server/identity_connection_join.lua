local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionJoin = function(deps)
    local platform = assert(deps.platform, 'connection join requires platform')
    local foundation = assert(deps.foundation, 'connection join requires foundation')
    local players = assert(deps.players, 'connection join requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection join requires lifecycle')
    local rateLimiter = assert(deps.rateLimiter, 'connection join requires rate limiter')
    local userRepository = assert(deps.userRepository, 'connection join requires user repository')
    local sessionRepository = assert(deps.sessionRepository, 'connection join requires session repository')
    local normalizeIdentifiers = assert(deps.normalizeIdentifiers, 'connection join requires identifier normalization')
    local identifierFingerprint = assert(deps.identifierFingerprint, 'connection join requires identity fingerprinting')
    local transition = assert(deps.transition, 'connection join requires session transition')
    local leases = assert(deps.leases, 'connection join requires cluster leases')
    local joinClaims = assert(deps.joinClaims, 'connection join requires join claims')
    local isQuiesced = assert(deps.isQuiesced, 'connection join requires quiesce state')
    local logConnectionStage = assert(deps.logConnectionStage, 'connection join requires stage telemetry')
    local releaseAdmission = assert(deps.releaseAdmission, 'connection join requires admission release')
    local releaseConnectionLease = assert(deps.releaseConnectionLease, 'connection join requires lease release')
    local clearQueueEntry = assert(deps.clearQueueEntry, 'connection join requires queue cleanup')
    local logger = foundation.logger

    return function(finalSource, oldSource)
        finalSource = tonumber(finalSource) or finalSource
        oldSource = tonumber(oldSource) or oldSource
        local now = foundation.monotonicMs()
        local orphan = { id = foundation.nextId('connection_orphan'), receivedAt = now }
        local dropAttempted = false
        local dropGuard = nil
        local claimToken = nil
        local function clearOwnedClaim()
            if not claimToken then return end
            foundation.safeCall(joinClaims.clear, joinClaims, finalSource, claimToken)
            claimToken = nil
        end
        local function rejectJoin(connection, code, message, shouldDrop)
            local dropAllowed = shouldDrop ~= false
            if dropAllowed and dropGuard then
                local checked, current = foundation.safeCall(dropGuard)
                dropAllowed = checked and current == true
            end
            if dropAllowed and not dropAttempted and type(finalSource) == 'number' then
                dropAttempted = true
                foundation.safeCall(platform.dropPlayer, finalSource,
                    ('Synex [%s]: %s'):format(code, message):sub(1, 256))
            end
            clearOwnedClaim()
            logConnectionStage(connection or orphan, 'rejected', code, 'warn')
            return foundation.error(code, message)
        end

        if type(finalSource) ~= 'number' or math.type(finalSource) ~= 'integer' or finalSource <= 0
            or type(oldSource) ~= 'number' or math.type(oldSource) ~= 'integer' then
            return nil, rejectJoin(orphan, 'INVALID_JOIN_SOURCE', 'The join source is invalid. Please reconnect.')
        end
        local admissionCode, admissionMessage = nil, nil
        if isQuiesced() then
            admissionCode = 'CORE_STOPPING'
            admissionMessage = 'The Synex runtime is stopping. Please reconnect shortly.'
        elseif not lifecycle.core:canAdmitPlayers() then
            admissionCode = 'CORE_NOT_READY'
            admissionMessage = 'The Synex runtime is not ready to open a session. Please reconnect shortly.'
        end
        if admissionCode then
            local pending = players:getPending(oldSource)
            local rejection = rejectJoin(pending or orphan, admissionCode, admissionMessage)
            if pending then
                local current = players:getPending(oldSource)
                local removed = nil
                if current and current.id == pending.id then removed = players:removePending(oldSource) end
                if removed then clearQueueEntry(removed) end
                releaseAdmission(removed or pending)
                releaseConnectionLease(removed or pending)
            end
            return nil, rejection
        end

        local rateInvoked, rateAllowed = foundation.safeCall(rateLimiter.consume, rateLimiter,
            'join:' .. tostring(finalSource) .. ':lifecycle', 4, 0.2, 1)
        if not rateInvoked or not rateAllowed then
            return nil, rejectJoin(orphan, 'JOIN_RATE_LIMITED',
                'Too many session join attempts were received. Please reconnect.')
        end

        local existing = players:getBySource(finalSource)
        if existing then
            return nil, rejectJoin(orphan, 'SOURCE_ALREADY_BOUND',
                'This player source already owns a session.', false)
        end

        local pending = players:getPending(oldSource)
        if pending then
            logConnectionStage(pending, 'player_joining_received')
        else
            logConnectionStage(orphan, 'player_joining_received', 'PENDING_CONNECTION_NOT_FOUND', 'warn')
            return nil, rejectJoin(orphan, 'PENDING_CONNECTION_NOT_FOUND',
                'The accepted connection is missing. Please reconnect.')
        end
        if type(pending.expiresAt) ~= 'number' or pending.expiresAt <= now then
            local rejection = rejectJoin(pending, 'PENDING_CONNECTION_EXPIRED',
                'The accepted connection expired. Please reconnect.')
            local removed = players:removePending(oldSource)
            if removed then clearQueueEntry(removed) end
            releaseAdmission(removed or pending)
            releaseConnectionLease(removed or pending)
            return nil, rejection
        end
        if pending.state ~= 'AUTHENTICATED' or type(pending.userId) ~= 'string' or pending.userId == ''
            or type(pending.identityFingerprint) ~= 'string' or pending.identityFingerprint == '' then
            return nil, rejectJoin(pending, 'PENDING_CONNECTION_NOT_READY',
                'The connection has not completed authentication. Please reconnect.')
        end
        claimToken = joinClaims:begin(finalSource, pending.id)

        local identityVerified = false
        local persistenceAttempted = false
        local leaseReleased = false
        local boundSession = nil
        local function readCurrentIdentity()
            local read, identifiers = foundation.safeCall(function()
                return normalizeIdentifiers(platform.getPlayerIdentifiers(finalSource))
            end)
            if not read or type(identifiers) ~= 'table' or #identifiers == 0 then return nil, nil end
            local hashed, fingerprint = foundation.safeCall(identifierFingerprint, identifiers)
            if not hashed or type(fingerprint) ~= 'string' then return nil, nil end
            return fingerprint, identifiers
        end
        local function sourceMatchesPendingIdentity()
            local fingerprint = readCurrentIdentity()
            return fingerprint ~= nil and fingerprint == pending.identityFingerprint
        end
        local function admissionIsCurrent()
            return not isQuiesced() and lifecycle.core:canAdmitPlayers()
        end
        local function sourceAuthorityIsCurrent()
            return joinClaims:isCurrent(finalSource, claimToken, pending.id)
                and sourceMatchesPendingIdentity()
        end
        local function continuationIsCurrent()
            return admissionIsCurrent() and sourceAuthorityIsCurrent()
        end
        local function releaseOwnedLease(candidate)
            if leaseReleased then return end
            local authority = candidate and candidate.clusterLease and candidate or pending
            if not authority or not authority.clusterLease then return end
            leaseReleased = true
            foundation.safeCall(releaseConnectionLease, authority)
        end
        local function removeOwnedPending()
            local current = players:getPending(oldSource)
            local removed = nil
            if current and current.id == pending.id then
                local removedOk, value = foundation.safeCall(players.removePending, players, oldSource)
                if removedOk then removed = value end
                if removed then clearQueueEntry(removed) end
            end
            releaseAdmission(pending)
            return removed
        end
        local function cleanupOwnedSession(closePersistence)
            local current = players:getBySource(finalSource)
            if not current or current.id ~= pending.sessionId then
                current = players:getSession(pending.sessionId)
            end
            if not current or current.id ~= pending.sessionId or current.userId ~= pending.userId then current = nil end
            local authority = current
            if not authority and boundSession and boundSession.id == pending.sessionId
                and boundSession.userId == pending.userId then authority = boundSession end
            if closePersistence and authority then
                local closed, closeResult, closeError = foundation.safeCall(
                    sessionRepository.close, sessionRepository, authority, 'join pipeline failed')
                if not closed or not closeResult then
                    local failure = closed and closeError or nil
                    foundation.safeCall(logger.error, logger, 'join persistence compensation failed', {
                        correlationId = pending.id,
                        code = type(failure) == 'table' and failure.code or 'SESSION_CLOSE_FAILED'
                    })
                end
            end
            if current then
                foundation.safeCall(players.removeSession, players, current.id)
            else
                removeOwnedPending()
            end
            releaseAdmission(pending)
            releaseOwnedLease(authority or pending)
        end
        local function rejectClosedAdmission(closePersistence)
            if admissionIsCurrent() then return nil end
            local stopping = isQuiesced()
            local rejection = rejectJoin(
                pending,
                stopping and 'CORE_STOPPING' or 'CORE_NOT_READY',
                stopping
                    and 'The Synex runtime is stopping. Please reconnect shortly.'
                    or 'The Synex runtime stopped admitting players. Please reconnect shortly.')
            if boundSession then
                cleanupOwnedSession(closePersistence)
            else
                local removed = removeOwnedPending()
                if not stopping then releaseOwnedLease(removed or pending) end
            end
            return rejection
        end

        local invoked, joined, joinError = foundation.safeCall(function()
            local fingerprint, identifiers = readCurrentIdentity()
            if not identifiers then
                return nil, rejectJoin(pending, 'JOIN_IDENTITY_REQUIRED',
                    'The joining player has no supported platform identity. Please reconnect.')
            end
            if type(fingerprint) ~= 'string' or fingerprint ~= pending.identityFingerprint then
                return nil, rejectJoin(pending, 'JOIN_IDENTITY_MISMATCH',
                    'The joining player does not match the accepted connection.')
            end
            dropGuard = function()
                if not sourceAuthorityIsCurrent() then return false end
                local session = players:getSession(pending.sessionId)
                if session then
                    return session.userId == pending.userId and session.source == finalSource
                        and players:isCurrent(session.id, finalSource, session.sourceGeneration)
                end
                local current = players:getPending(oldSource)
                return current ~= nil and current.id == pending.id
                    and players:getBySource(finalSource) == nil
            end
            local resolvedUser = userRepository:findByIdentifiers(identifiers)
            if not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(false)
                if admissionError then return nil, admissionError end
                return nil, rejectJoin(pending, 'JOIN_SOURCE_CHANGED',
                    'The player source changed while the session was opening.', false)
            end
            if not resolvedUser then
                return nil, rejectJoin(pending, 'JOIN_IDENTITY_UNVERIFIED',
                    'The joining player identity could not be verified. Please reconnect.')
            end
            if resolvedUser.id ~= pending.userId or resolvedUser.status ~= 'active' then
                return nil, rejectJoin(pending, 'JOIN_IDENTITY_MISMATCH',
                    'The joining player does not match the accepted connection.')
            end
            if players:getBySource(finalSource) then
                return nil, rejectJoin(pending, 'SOURCE_ALREADY_BOUND',
                    'This player source already owns a session.', false)
            end
            local current = players:getPending(oldSource)
            if not current or current.id ~= pending.id or current.sessionId ~= pending.sessionId
                or current.userId ~= pending.userId then
                return nil, rejectJoin(pending, 'PENDING_CONNECTION_CHANGED',
                    'The accepted connection is no longer current. Please reconnect.')
            end
            identityVerified = true
            logConnectionStage(pending, 'join_identity_verified')

            local session = {
                id = pending.sessionId, userId = pending.userId, state = 'AUTHENTICATED',
                source = finalSource, sourceGeneration = 0, characterId = nil, version = 1,
                connectedAt = foundation.utcIso(), clusterLease = pending.clusterLease,
                persistencePending = true
            }
            local transitioned = transition(session, 'SELECTING_CHARACTER')
            if not transitioned then
                local rejection = rejectJoin(pending, 'SESSION_INITIALIZATION_FAILED',
                    'The session could not be initialized. Please reconnect.')
                cleanupOwnedSession(false)
                return nil, rejection
            end
            session.persistedVersion = session.version
            if not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(false)
                if admissionError then return nil, admissionError end
                return nil, rejectJoin(pending, 'JOIN_SOURCE_CHANGED',
                    'The player source changed while the session was opening.', false)
            end
            local leaseInvoked, leaseRenewed = foundation.safeCall(leases.renew, leases, pending.clusterLease)
            if not leaseInvoked or not leaseRenewed then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Session authority expired before the join completed. Please reconnect.')
                cleanupOwnedSession(false)
                return nil, rejection
            end
            if not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(false)
                if admissionError then return nil, admissionError end
                return nil, rejectJoin(pending, 'JOIN_SOURCE_CHANGED',
                    'The player source changed while the session was opening.', false)
            end
            logConnectionStage(pending, 'join_lease_verified')
            if not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(false)
                if admissionError then return nil, admissionError end
                return nil, rejectJoin(pending, 'JOIN_SOURCE_CHANGED',
                    'The player source changed while the session was opening.', false)
            end
            local bound, bindError = players:bindJoined(oldSource, finalSource, session)
            if not bound then
                local rejection = rejectJoin(pending, 'SESSION_BIND_FAILED',
                    'The connection could not be bound to a session. Please reconnect.')
                cleanupOwnedSession(false)
                return nil, rejection
            end
            boundSession = bound
            releaseAdmission(pending)
            persistenceAttempted = true
            local persisted, persistenceError = sessionRepository:create(bound)
            if not players:isCurrent(bound.id, finalSource, bound.sourceGeneration)
                or not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(true)
                if admissionError then return nil, admissionError end
                clearOwnedClaim()
                cleanupOwnedSession(true)
                logConnectionStage(pending, 'rejected', 'CONNECTION_CANCELLED', 'warn')
                return nil, foundation.error('CONNECTION_CANCELLED',
                    'The player disconnected while the session was opening.')
            end
            if not persisted then
                local leaseLost = type(persistenceError) == 'table' and persistenceError.code == 'LEASE_LOST'
                local rejection = rejectJoin(pending, leaseLost and 'JOIN_LEASE_LOST'
                    or 'SESSION_PERSISTENCE_FAILED', leaseLost
                    and 'Session authority changed before persistence. Please reconnect.'
                    or 'The session could not be saved. Please reconnect.')
                cleanupOwnedSession(not leaseLost)
                return nil, rejection
            end
            local finalLeaseInvoked, finalLeaseRenewed = foundation.safeCall(
                leases.renew, leases, pending.clusterLease)
            if not finalLeaseInvoked or not finalLeaseRenewed then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Session authority changed while the session was opening. Please reconnect.')
                cleanupOwnedSession(true)
                return nil, rejection
            end
            if not players:isCurrent(bound.id, finalSource, bound.sourceGeneration)
                or not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(true)
                if admissionError then return nil, admissionError end
                clearOwnedClaim()
                cleanupOwnedSession(true)
                logConnectionStage(pending, 'rejected', 'CONNECTION_CANCELLED', 'warn')
                return nil, foundation.error('CONNECTION_CANCELLED',
                    'The player disconnected while the session was opening.')
            end
            local opened, openError = players:updateSession(bound.id, function(candidate)
                if candidate.source ~= finalSource
                    or candidate.sourceGeneration ~= bound.sourceGeneration
                    or candidate.persistencePending ~= true then
                    error('join session authority changed before publication')
                end
                candidate.persistencePending = nil
            end)
            if not opened or not players:isCurrent(bound.id, finalSource, bound.sourceGeneration)
                or not continuationIsCurrent() then
                local admissionError = rejectClosedAdmission(true)
                if admissionError then return nil, admissionError end
                local rejection = rejectJoin(pending, 'SESSION_FINALIZATION_FAILED',
                    'The session could not be finalized. Please reconnect.')
                cleanupOwnedSession(true)
                if openError then
                    foundation.safeCall(logger.error, logger, 'join session publication failed', {
                        correlationId = pending.id,
                        code = openError.code or 'SESSION_FINALIZATION_FAILED'
                    })
                end
                return nil, rejection
            end
            boundSession = opened
            clearOwnedClaim()
            logConnectionStage(pending, 'session_opened')
            foundation.safeCall(logger.info, logger, 'session opened', {
                correlationId = pending.id, sessionId = opened.id, userId = opened.userId,
                source = finalSource, generation = opened.sourceGeneration
            })
            return opened, nil
        end)
        if not invoked then
            foundation.safeCall(logger.error, logger, 'player join pipeline failed', {
                correlationId = pending.id, code = 'JOIN_PIPELINE_FAILED'
            })
            local rejection = rejectJoin(pending, 'JOIN_PIPELINE_FAILED',
                'The session could not be opened. Please reconnect.')
            if identityVerified then cleanupOwnedSession(persistenceAttempted) end
            return nil, rejection
        end
        return joined, joinError
    end
end
