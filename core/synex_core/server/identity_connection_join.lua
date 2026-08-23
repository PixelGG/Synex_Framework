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
    local refreshLeaseDeadline = assert(deps.refreshLeaseDeadline,
        'connection join requires local lease deadlines')
    local clearLeaseDeadline = assert(deps.clearLeaseDeadline,
        'connection join requires local lease deadline cleanup')
    local closeOrDeferSession = assert(deps.closeOrDeferSession,
        'connection join requires durable close reconciliation')
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
        local function sameLease(left, right)
            return type(left) == 'table' and type(right) == 'table'
                and (left.name or left.leaseName) == (right.name or right.leaseName)
                and left.owner == right.owner
                and left.fencingToken == right.fencingToken
        end
        local function publishPendingDeadlines()
            return players:updatePending(oldSource, function(candidate)
                if candidate.id ~= pending.id or candidate.sessionId ~= pending.sessionId
                    or candidate.userId ~= pending.userId
                    or not sameLease(candidate.admissionGateLease, pending.admissionGateLease)
                    or not sameLease(candidate.clusterLease, pending.clusterLease) then
                    error('pending lease authority changed during renewal')
                end
                candidate.admissionGateDeadlineAt = pending.admissionGateDeadlineAt
                candidate.clusterLeaseDeadlineAt = pending.clusterLeaseDeadlineAt
                candidate.authorityDeadlineAt = pending.authorityDeadlineAt
            end)
        end
        local function releaseOwnedLease(candidate)
            if leaseReleased then return end
            local authority = candidate and (candidate.clusterLease or candidate.admissionGateLease)
                and candidate or pending
            if not authority or (not authority.clusterLease and not authority.admissionGateLease) then return end
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
                local coordinated, closeReport, closeError = foundation.safeCall(
                    closeOrDeferSession, authority, 'join pipeline failed', {
                        attempts = 2, recordReconnectGrace = false,
                        detachSource = true, source = finalSource,
                        sourceGeneration = authority.sourceGeneration
                    })
                if coordinated and closeReport then
                    if closeReport.deferred then
                        foundation.safeCall(logger.error, logger,
                            'join persistence compensation deferred', {
                                correlationId = pending.id,
                                code = foundation.failureCode(
                                    closeReport.failure, 'SESSION_CLOSE_FAILED')
                            })
                    else
                        leaseReleased = true
                    end
                    releaseAdmission(pending)
                    return
                end
                foundation.safeCall(logger.error, logger, 'join persistence compensation failed', {
                    correlationId = pending.id,
                    code = foundation.failureCode(
                        coordinated and closeError or closeReport, 'SESSION_CLOSE_FAILED')
                })
                releaseAdmission(pending)
                return
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
                admissionGateLease = pending.admissionGateLease,
                admissionGateDeadlineAt = pending.admissionGateDeadlineAt,
                clusterLeaseDeadlineAt = pending.clusterLeaseDeadlineAt,
                authorityDeadlineAt = pending.authorityDeadlineAt,
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
            local authorityRenewed = true
            for _, field in ipairs({ 'admissionGateLease', 'clusterLease' }) do
                local lease = pending[field]
                if type(lease) ~= 'table' then authorityRenewed = false break end
                local attemptStartedAt = foundation.monotonicMs()
                local oldDeadline = pending.authorityDeadlineAt
                if type(oldDeadline) ~= 'number' or oldDeadline <= attemptStartedAt then
                    authorityRenewed = false
                    break
                end
                local leaseInvoked, leaseRenewed = foundation.safeCall(leases.renew, leases, lease)
                local currentPending = players:getPending(oldSource)
                if not leaseInvoked or not leaseRenewed or not currentPending
                    or currentPending.id ~= pending.id
                    or not sameLease(currentPending[field], lease)
                    or not refreshLeaseDeadline(pending, field, attemptStartedAt) then
                    authorityRenewed = false
                    break
                end
                local published = publishPendingDeadlines()
                if not published then authorityRenewed = false break end
            end
            if not authorityRenewed then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Admission or session authority expired before the join completed. Please reconnect.')
                cleanupOwnedSession(false)
                return nil, rejection
            end
            session.admissionGateDeadlineAt = pending.admissionGateDeadlineAt
            session.clusterLeaseDeadlineAt = pending.clusterLeaseDeadlineAt
            session.authorityDeadlineAt = pending.authorityDeadlineAt
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
                local leaseLost = type(persistenceError) == 'table'
                    and (persistenceError.code == 'LEASE_LOST'
                        or persistenceError.code == 'ADMISSION_GATE_LOST')
                local rejection = rejectJoin(pending, leaseLost and 'JOIN_LEASE_LOST'
                    or 'SESSION_PERSISTENCE_FAILED', leaseLost
                    and 'Session authority changed before persistence. Please reconnect.'
                    or 'The session could not be saved. Please reconnect.')
                cleanupOwnedSession(not leaseLost)
                return nil, rejection
            end
            pending.admissionGateLease = nil
            clearLeaseDeadline(pending, 'admissionGateLease')
            bound.admissionGateLease = nil
            clearLeaseDeadline(bound, 'admissionGateLease')
            local gateCleared, gateClearError = players:updateSession(bound.id, function(candidate)
                if candidate.source ~= finalSource
                    or candidate.sourceGeneration ~= bound.sourceGeneration
                    or candidate.persistencePending ~= true
                    or not sameLease(candidate.clusterLease, bound.clusterLease)
                    or not sameLease(candidate.admissionGateLease, session.admissionGateLease) then
                    error('join session authority changed before gate retirement publication')
                end
                candidate.admissionGateLease = nil
                candidate.admissionGateDeadlineAt = nil
                candidate.clusterLeaseDeadlineAt = bound.clusterLeaseDeadlineAt
                candidate.authorityDeadlineAt = bound.authorityDeadlineAt
            end)
            if not gateCleared then
                local rejection = rejectJoin(pending, 'SESSION_FINALIZATION_FAILED',
                    'Admission authority retirement could not be published. Please reconnect.')
                cleanupOwnedSession(true)
                if gateClearError then
                    foundation.safeCall(logger.error, logger,
                        'join admission gate retirement publication failed', {
                            correlationId = pending.id,
                            code = gateClearError.code or 'SESSION_FINALIZATION_FAILED'
                        })
                end
                return nil, rejection
            end
            bound = gateCleared
            boundSession = bound
            local finalAttemptStartedAt = foundation.monotonicMs()
            if not players:isCurrent(bound.id, finalSource, bound.sourceGeneration) then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Session authority expired before finalization. Please reconnect.')
                cleanupOwnedSession(true)
                return nil, rejection
            end
            local finalLeaseInvoked, finalLeaseRenewed = foundation.safeCall(
                leases.renew, leases, pending.clusterLease)
            if not finalLeaseInvoked or not finalLeaseRenewed
                or not players:isCurrent(bound.id, finalSource, bound.sourceGeneration)
                or not refreshLeaseDeadline(bound, 'clusterLease', finalAttemptStartedAt) then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Session authority changed while the session was opening. Please reconnect.')
                cleanupOwnedSession(true)
                return nil, rejection
            end
            local deadlinePublished, deadlinePublishError = players:updateSession(
                bound.id, function(candidate)
                    if candidate.source ~= finalSource
                        or candidate.sourceGeneration ~= bound.sourceGeneration
                        or candidate.persistencePending ~= true
                        or not sameLease(candidate.clusterLease, bound.clusterLease)
                        or candidate.admissionGateLease ~= nil then
                        error('join session authority changed during final lease renewal')
                    end
                    candidate.clusterLeaseDeadlineAt = bound.clusterLeaseDeadlineAt
                    candidate.authorityDeadlineAt = bound.authorityDeadlineAt
                end)
            if not deadlinePublished then
                local rejection = rejectJoin(pending, 'JOIN_LEASE_LOST',
                    'Session authority renewal could not be published. Please reconnect.')
                cleanupOwnedSession(true)
                if deadlinePublishError then
                    foundation.safeCall(logger.error, logger,
                        'join lease deadline publication failed', {
                            correlationId = pending.id,
                            code = deadlinePublishError.code or 'JOIN_LEASE_LOST'
                        })
                end
                return nil, rejection
            end
            bound = deadlinePublished
            boundSession = bound
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
                candidate.admissionGateLease = nil
                candidate.admissionGateDeadlineAt = nil
                candidate.clusterLeaseDeadlineAt = bound.clusterLeaseDeadlineAt
                candidate.authorityDeadlineAt = bound.authorityDeadlineAt
                candidate.persistencePending = nil
                candidate.persistedSource = finalSource
                candidate.persistedSourceGeneration = bound.sourceGeneration
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
