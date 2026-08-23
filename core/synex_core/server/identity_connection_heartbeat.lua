local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionHeartbeat = function(deps)
    local platform = assert(deps.platform, 'connection heartbeat requires platform')
    local foundation = assert(deps.foundation, 'connection heartbeat requires foundation')
    local players = assert(deps.players, 'connection heartbeat requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection heartbeat requires lifecycle')
    local config = deps.config or {}
    local leases = assert(deps.leases, 'connection heartbeat requires cluster leases')
    local instances = assert(deps.instances, 'connection heartbeat requires cluster instances')
    local maintenance = assert(deps.maintenance, 'connection heartbeat requires maintenance')
    local sameLease = assert(deps.sameLease, 'connection heartbeat requires lease comparison')
    local refreshLeaseDeadline = assert(deps.refreshLeaseDeadline,
        'connection heartbeat requires local lease deadlines')
    local clearQueueEntry = assert(deps.clearQueueEntry,
        'connection heartbeat requires queue cleanup')
    local releaseAdmission = assert(deps.releaseAdmission,
        'connection heartbeat requires admission release')
    local releaseConnectionLease = assert(deps.releaseConnectionLease,
        'connection heartbeat requires lease release')
    local logConnectionStage = assert(deps.logConnectionStage,
        'connection heartbeat requires stage telemetry')
    local isQuiesced = assert(deps.isQuiesced, 'connection heartbeat requires quiesce authority')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local pendingLeaseRenewalOffset = 0
    local heartbeat = {}

    local function renewPendingLeases()
        local now = foundation.monotonicMs()
        local candidates = {}
        for _, entry in ipairs(players:listPending()) do
            local pending = entry.connection
            if (pending.state == 'AUTHENTICATING' or pending.state == 'AUTHENTICATED')
                and (pending.admissionGateLease or pending.clusterLease)
                and type(pending.expiresAt) == 'number' and pending.expiresAt > now then
                candidates[#candidates + 1] = entry
            end
        end
        if #candidates == 0 then
            pendingLeaseRenewalOffset = 0
            return true, nil
        end
        local leaseMs = math.max(10000,
            math.min(tonumber(config.clusterSessionLeaseSeconds) or 45, 300) * 1000)
        local heartbeatMs = math.max(1000,
            math.min(tonumber(config.clusterHeartbeatMs) or 10000, leaseMs - 1))
        local marginMs = math.max(1000, math.min(leaseMs - 1000, heartbeatMs * 2))
        local usableMs = math.max(1000, leaseMs - marginMs)
        local renewalRounds = math.max(1,
            math.floor(math.max(heartbeatMs, usableMs - 1000) / heartbeatMs))
        local limit = math.min(#candidates, math.max(1, math.ceil(#candidates / renewalRounds)))
        local failures = 0
        for offset = 0, limit - 1 do
            if isQuiesced() then return true, nil end
            local index = ((pendingLeaseRenewalOffset + offset) % #candidates) + 1
            local entry = candidates[index]
            local renewed, value, renewError = true, true, nil
            local candidate = foundation.copy(entry.connection)
            for _, field in ipairs({ 'admissionGateLease', 'clusterLease' }) do
                local lease = candidate[field]
                if lease then
                    local attemptStartedAt = foundation.monotonicMs()
                    local current = players:getPending(entry.source)
                    if not current or current.id ~= candidate.id
                        or current.sessionId ~= candidate.sessionId
                        or not sameLease(current[field], lease) then
                        renewed, value = true, nil
                        renewError = foundation.error('PENDING_LEASE_EXPIRED',
                            'Pending connection authority expired before renewal.')
                        break
                    end
                    renewed, value, renewError = foundation.safeCall(leases.renew, leases, lease)
                    current = players:getPending(entry.source)
                    if not renewed or not value or not current or current.id ~= candidate.id
                        or current.sessionId ~= candidate.sessionId
                        or not sameLease(current[field], lease)
                        or not refreshLeaseDeadline(candidate, field, attemptStartedAt) then
                        renewed, value = renewed, nil
                        renewError = renewError or foundation.error('PENDING_LEASE_EXPIRED',
                            'Pending connection authority expired during renewal.')
                        break
                    end
                end
            end
            if renewed and value then
                local published, publishError = players:updatePending(entry.source, function(current)
                    if current.id ~= candidate.id or current.sessionId ~= candidate.sessionId
                        or current.userId ~= candidate.userId
                        or (candidate.admissionGateLease and not sameLease(
                            current.admissionGateLease, candidate.admissionGateLease))
                        or (candidate.clusterLease and not sameLease(
                            current.clusterLease, candidate.clusterLease)) then
                        error('pending authority changed during heartbeat publication')
                    end
                    current.admissionGateDeadlineAt = candidate.admissionGateDeadlineAt
                    current.clusterLeaseDeadlineAt = candidate.clusterLeaseDeadlineAt
                    current.authorityDeadlineAt = candidate.authorityDeadlineAt
                end)
                if not published then
                    value = nil
                    renewError = publishError or foundation.error(
                        'PENDING_LEASE_RENEW_FAILED',
                        'Pending connection authority renewal could not be published.')
                end
            end
            if isQuiesced() then return true, nil end
            if not renewed or not value then
                local current = type(players.getRawPending) == 'function'
                    and players:getRawPending(entry.source) or players:getPending(entry.source)
                local joined = players:getSession(entry.connection.sessionId)
                local handedOff = joined ~= nil
                    and joined.userId == entry.connection.userId
                if current and current.id == entry.connection.id then
                    local removed = players:removePending(entry.source)
                    if removed then clearQueueEntry(removed) end
                    releaseAdmission(removed or entry.connection)
                    releaseConnectionLease(removed or entry.connection)
                    logConnectionStage(removed or entry.connection, 'pending_lease_lost',
                        'PENDING_LEASE_RENEW_FAILED', 'error')
                elseif not joined or joined.userId ~= entry.connection.userId then
                    releaseAdmission(entry.connection)
                    releaseConnectionLease(entry.connection)
                end
                if not handedOff then
                    failures = failures + 1
                    foundation.safeCall(logger.error, logger, 'pending session lease renewal failed', {
                        correlationId = entry.connection.id,
                        code = type(renewError) == 'table'
                            and renewError.code or 'PENDING_LEASE_RENEW_FAILED'
                    })
                end
            end
        end
        pendingLeaseRenewalOffset = (pendingLeaseRenewalOffset + limit) % #candidates
        foundation.safeCall(metrics.gauge, metrics,
            'synex_pending_lease_renewal_failures', {}, failures)
        if failures > 0 then
            return nil, foundation.error('PENDING_LEASE_RENEW_FAILED',
                'One or more accepted connection leases could not be renewed.')
        end
        return true, nil
    end

    function heartbeat:run()
        if isQuiesced() then return true, nil end
        maintenance:purgeExpired()
        if isQuiesced() then return true, nil end
        local pendingLeasesHealthy, pendingLeaseError = renewPendingLeases()
        if isQuiesced() then return true, nil end
        local reconciled, reconciliationError = maintenance:reconcileClosures(32)
        if isQuiesced() then return true, nil end
        if not reconciled then
            logger:error('session close reconciliation failed', {
                code = type(reconciliationError) == 'table'
                    and reconciliationError.code or 'SESSION_CLOSE_FAILED'
            })
        end
        local disconnected, disconnectError = maintenance:reconcileDisconnects(32)
        if isQuiesced() then return true, nil end
        if not disconnected then
            logger:error('lost session disconnect reconciliation failed', {
                code = type(disconnectError) == 'table'
                    and disconnectError.code or 'PLAYER_DROP_FAILED'
            })
        end
        local sessions = players:snapshot().sessions
        local sessionIds = {}
        local sessionLeasesHealthy = true
        local sessionLeaseError = nil
        local sessionCleanupAccepted = true
        for _, session in ipairs(sessions) do
            if session.clusterLease then
                local attemptStartedAt = foundation.monotonicMs()
                local raw = players:getSession(session.id)
                local rawCurrent = raw ~= nil and sameLease(
                    raw.clusterLease, session.clusterLease)
                    and raw.source == session.source
                    and raw.sourceGeneration == session.sourceGeneration
                local deadlineCurrent = rawCurrent
                    and type(raw.authorityDeadlineAt) == 'number'
                    and raw.authorityDeadlineAt > attemptStartedAt
                local invoked, renewed, renewError = foundation.safeCall(
                    function()
                        if not deadlineCurrent then
                            return nil, foundation.error('SESSION_LEASE_EXPIRED',
                                'Active session authority expired before renewal.')
                        end
                        return leases:renew(session.clusterLease)
                    end)
                if isQuiesced() then return true, nil end
                raw = players:getSession(session.id)
                rawCurrent = raw ~= nil and sameLease(raw.clusterLease, session.clusterLease)
                    and raw.source == session.source
                    and raw.sourceGeneration == session.sourceGeneration
                local locallyCurrent = rawCurrent and type(raw.authorityDeadlineAt) == 'number'
                    and raw.authorityDeadlineAt > foundation.monotonicMs()
                local deadlineRefreshed = invoked and renewed and locallyCurrent
                    and refreshLeaseDeadline(session, 'clusterLease', attemptStartedAt) ~= nil
                local leaseAccepted = deadlineRefreshed == true
                if leaseAccepted then
                    local published, publishError = players:updateSession(session.id, function(current)
                        if not sameLease(current.clusterLease, session.clusterLease)
                            or current.source ~= session.source
                            or current.sourceGeneration ~= session.sourceGeneration then
                            error('session authority changed during heartbeat publication')
                        end
                        current.clusterLeaseDeadlineAt = session.clusterLeaseDeadlineAt
                        current.authorityDeadlineAt = session.authorityDeadlineAt
                    end)
                    if published then
                        sessionIds[#sessionIds + 1] = session.id
                    else
                        leaseAccepted = false
                        renewError = publishError
                    end
                end
                if not leaseAccepted then
                    sessionLeasesHealthy = false
                    sessionLeaseError = sessionLeaseError or foundation.error(
                        'SESSION_LEASE_RENEW_FAILED', 'Active session authority could not be renewed.')
                    local failure = invoked and renewError or renewed
                    foundation.safeCall(logger.error, logger, 'cluster session lease lost', {
                        sessionId = session.id,
                        code = type(failure) == 'table'
                            and failure.code or 'SESSION_LEASE_RENEW_FAILED'
                    })
                    local currentCheck, isCurrent = foundation.safeCall(
                        players.isRawCurrent, players,
                        session.id, session.source, session.sourceGeneration)
                    local binding = currentCheck and isCurrent and 'current' or 'stale'
                    local cleanupReport, cleanupError = nil, nil
                    if binding == 'current' and session.source ~= nil then
                        cleanupReport, cleanupError = maintenance:invalidateLostSession(
                            session, 'cluster session authority lost')
                    elseif rawCurrent and raw and raw.source == nil then
                        cleanupReport, cleanupError = maintenance:closeOrDefer(
                            raw, 'cluster session authority lost', {
                                attempts = 1, recordReconnectGrace = false
                            })
                    end
                    if ((binding == 'current' and session.source ~= nil)
                        or (rawCurrent and raw and raw.source == nil))
                        and cleanupReport == nil then
                        sessionCleanupAccepted = false
                        sessionLeaseError = sessionLeaseError or cleanupError
                    end
                    foundation.safeCall(metrics.increment, metrics,
                        'synex_session_lease_loss_total', { binding = binding })
                end
            else
                sessionIds[#sessionIds + 1] = session.id
            end
        end
        local touched, touchError = instances:touchSessions(sessionIds,
            function() return not isQuiesced() end)
        if isQuiesced() then return true, nil end
        if not touched then logger:error('session heartbeat persistence failed', { code = touchError.code }) end
        local cluster, heartbeatError = nil, nil
        if sessionCleanupAccepted then
            cluster, heartbeatError = instances:heartbeat(config.clusterSessionLeaseSeconds or 45,
                function() return not isQuiesced() end)
        else
            heartbeatError = foundation.error('SESSION_CLEANUP_NOT_ACCEPTED',
                'Lost session authority could not be queued for durable cleanup.')
        end
        if isQuiesced() then return true, nil end
        if not cluster then logger:error('instance heartbeat failed', { code = heartbeatError.code }) end
        local controls, controlError = instances:pendingLocalControls()
        if isQuiesced() then return true, nil end
        if not controls then
            logger:error('cluster control polling failed', { code = controlError.code })
        else
            local controlProcessingHealthy = true
            local controlProcessingError = nil
            for _, control in ipairs(controls) do
                if isQuiesced() then return true, nil end
                local target = players:getSession(control.target_session_id)
                local current = target and target.source ~= nil and control.action == 'kick'
                    and players:isCurrent(target.id, target.source, target.sourceGeneration)
                local dropAccepted = false
                local dispatchFailed = false
                if current then
                    local invoked, result, dropError = foundation.safeCall(
                        platform.dropPlayer, target.source,
                        tostring(control.reason or 'Session replaced.'):sub(1, 128))
                    dropAccepted = invoked and result ~= false
                    if not dropAccepted then
                        dispatchFailed = true
                        controlProcessingHealthy = false
                        controlProcessingError = controlProcessingError or foundation.error(
                            'PLAYER_DROP_FAILED', 'The cluster control player drop failed.', {
                                retryable = true
                            })
                        local failure = invoked and dropError or result
                        logger:error('cluster control player drop failed', {
                            requestId = control.request_id,
                            code = type(failure) == 'table'
                                and failure.code or 'PLAYER_DROP_FAILED'
                        })
                    end
                end
                if not dispatchFailed then
                    local completed, completionError = instances:completeControl(
                        control, dropAccepted)
                    if isQuiesced() then return true, nil end
                    if not completed then
                        controlProcessingHealthy = false
                        controlProcessingError = controlProcessingError or completionError
                            or foundation.error('CONTROL_COMPLETION_PENDING',
                                'The cluster control completion is still pending.', {
                                    retryable = true
                                })
                        if completionError then
                            logger:error('cluster control completion failed', {
                                requestId = control.request_id, code = completionError.code
                            })
                        end
                    end
                end
            end
            if not controlProcessingHealthy then
                controlError = controlProcessingError
                controls = nil
            end
        end
        local healthy = pendingLeasesHealthy == true and reconciled ~= nil
            and disconnected ~= nil
            and sessionLeasesHealthy and touched == true
            and cluster ~= nil and controls ~= nil
        lifecycle.core:setHealth('cluster', healthy and 'HEALTHY' or 'DEGRADED',
            healthy and nil or 'cluster heartbeat or control polling failed')
        return healthy, healthy and nil
            or (pendingLeaseError or reconciliationError or disconnectError or sessionLeaseError
                or touchError or heartbeatError or controlError)
    end


    return heartbeat
end
