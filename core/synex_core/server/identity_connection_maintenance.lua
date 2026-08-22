local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionMaintenance = function(deps)
    local platform = assert(deps.platform, 'connection maintenance requires platform')
    local foundation = assert(deps.foundation, 'connection maintenance requires foundation')
    local players = assert(deps.players, 'connection maintenance requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection maintenance requires lifecycle')
    local messaging = assert(deps.messaging, 'connection maintenance requires messaging')
    local config = deps.config or {}
    local leases = assert(deps.leases, 'connection maintenance requires cluster leases')
    local instances = assert(deps.instances, 'connection maintenance requires cluster instances')
    local characters = assert(deps.characters, 'connection maintenance requires character service')
    local sessionRepository = assert(deps.sessionRepository, 'connection maintenance requires session repository')
    local sessionTransitions = assert(deps.sessionTransitions, 'connection maintenance requires transition map')
    local transition = assert(deps.transition, 'connection maintenance requires session transitions')
    local rateLimiter = assert(deps.rateLimiter, 'connection maintenance requires rate limiter')
    local joinClaims = assert(deps.joinClaims, 'connection maintenance requires join claims')
    local logConnectionStage = assert(deps.logConnectionStage, 'connection maintenance requires stage telemetry')
    local releaseAdmission = assert(deps.releaseAdmission, 'connection maintenance requires admission release')
    local releaseConnectionLease = assert(deps.releaseConnectionLease, 'connection maintenance requires lease release')
    local clearQueueEntry = assert(deps.clearQueueEntry, 'connection maintenance requires queue cleanup')
    local recordReconnectGrace = assert(deps.recordReconnectGrace, 'connection maintenance requires reconnect grace')
    local purgeReconnectGrace = assert(deps.purgeReconnectGrace, 'connection maintenance requires grace cleanup')
    local isQuiesced = assert(deps.isQuiesced, 'connection maintenance requires quiesce authority')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local pendingCleanupOffset = 0
    local pendingLeaseRenewalOffset = 0
    local maintenance = {}

    function maintenance:handleDropped(playerSource, reason)
        playerSource = tonumber(playerSource) or playerSource
        joinClaims:invalidate(playerSource)
        local session = players:getBySource(playerSource)
        if session then
            local detached, detachError = players:detachSource(
                session.id, playerSource, session.sourceGeneration)
            if not detached then
                foundation.safeCall(logger.warn, logger, 'stale player drop ignored', {
                    sessionId = session.id,
                    code = detachError and detachError.code or 'SOURCE_NOT_CURRENT'
                })
                return nil, detachError
            end
            session = detached
        end
        foundation.safeCall(rateLimiter.purge, rateLimiter, 'join:' .. tostring(playerSource) .. ':')
        if not session then
            local pending = players:removePending(playerSource)
            if pending then clearQueueEntry(pending) end
            releaseAdmission(pending)
            releaseConnectionLease(pending)
            if pending then logConnectionStage(pending, 'pending_cancelled', 'PLAYER_DROPPED', 'warn') end
            return
        end
        local failures = {}
        local purged = foundation.safeCall(
            messaging.network.purgeSource, messaging.network, playerSource, session.sourceGeneration)
        if not purged then
            failures[#failures + 1] = { step = 'network_purge', code = 'RUNTIME_ERROR' }
            foundation.safeCall(logger.error, logger, 'disconnect network cleanup failed', {
                sessionId = session.id, code = 'RUNTIME_ERROR'
            })
        end
        local function capture(step, handler)
            local ok, value, err = foundation.safeCall(handler)
            if not ok or value == nil then
                local failure = ok and err or value
                failures[#failures + 1] = {
                    step = step,
                    code = type(failure) == 'table' and failure.code or 'RUNTIME_ERROR'
                }
                logger:error('disconnect cleanup step failed', {
                    step = step, sessionId = session.id, userId = session.userId,
                    error = tostring(type(failure) == 'table' and (failure.code or failure.message) or failure)
                })
                return nil
            end
            return value
        end
        if session.state == 'ACTIVE' then
            capture('character_unload', function() return characters:unload(session.id, 'disconnect') end)
        end
        local current = players:getSession(session.id) or session
        if current.state ~= 'DISCONNECTING' and current.state ~= 'CLOSED' then
            capture('session_transition', function()
                return players:updateSession(current.id, function(candidate)
                    if sessionTransitions[candidate.state] and sessionTransitions[candidate.state].DISCONNECTING then
                        transition(candidate, 'DISCONNECTING')
                    end
                end)
            end)
        end
        current = players:getSession(session.id) or current
        local closed = false
        for attempt = 1, 2 do
            local value = capture('session_close_' .. attempt,
                function() return sessionRepository:close(current, reason) end)
            if value then closed = true break end
            if attempt == 1 then platform.wait(25) end
        end
        capture('lease_release', function() return releaseConnectionLease(current) end)
        players:removeSession(session.id)
        recordReconnectGrace(session.userId)
        if #failures > 0 then
            metrics:increment('synex_disconnect_cleanup_total', { result = 'partial' })
            lifecycle.core:setHealth('disconnect-cleanup', 'DEGRADED',
                ('%d cleanup step(s) failed'):format(#failures))
        else
            metrics:increment('synex_disconnect_cleanup_total', { result = 'complete' })
            lifecycle.core:setHealth('disconnect-cleanup', 'HEALTHY')
        end
        logger:info('session closed', {
            sessionId = session.id, userId = session.userId,
            reason = tostring(reason or 'dropped'):sub(1, 128)
        })
        return { closed = closed, failures = failures }
    end

    function maintenance:purgeExpired(maximum)
        local now = foundation.monotonicMs()
        local entries = players:listPending()
        local limit = math.max(1, math.min(tonumber(maximum) or 64, 256))
        local purged = 0
        local inspected = math.min(#entries, limit)
        local oldestAgeMs = 0
        for _, entry in ipairs(entries) do
            oldestAgeMs = math.max(oldestAgeMs,
                math.max(0, now - (entry.connection.receivedAt or entry.connection.acceptedAt or now)))
        end
        for offset = 0, inspected - 1 do
            local index = ((pendingCleanupOffset + offset) % #entries) + 1
            local entry = entries[index]
            if entry.connection.expiresAt and entry.connection.expiresAt <= now then
                local current = players:getPending(entry.source)
                local removed = current and current.id == entry.connection.id
                    and current.expiresAt and current.expiresAt <= now
                    and players:removePending(entry.source) or nil
                if removed then
                    clearQueueEntry(removed)
                    releaseAdmission(removed)
                    releaseConnectionLease(removed)
                    logConnectionStage(removed, 'pending_expired', 'PENDING_CONNECTION_EXPIRED', 'warn')
                    purged = purged + 1
                end
            end
        end
        if #entries > 0 then
            pendingCleanupOffset = (pendingCleanupOffset + inspected) % #entries
        else
            pendingCleanupOffset = 0
        end
        purgeReconnectGrace(now)
        foundation.safeCall(metrics.gauge, metrics,
            'synex_pending_connections', {}, math.max(0, #entries - purged))
        foundation.safeCall(metrics.gauge, metrics,
            'synex_pending_connection_oldest_age_ms', {}, oldestAgeMs)
        return purged
    end

    local function renewPendingLeases()
        local now = foundation.monotonicMs()
        local candidates = {}
        for _, entry in ipairs(players:listPending()) do
            local pending = entry.connection
            if (pending.state == 'AUTHENTICATING' or pending.state == 'AUTHENTICATED') and pending.clusterLease
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
        local renewalRounds = math.max(1, math.floor((leaseMs - heartbeatMs) / heartbeatMs))
        local limit = math.min(#candidates, math.max(1, math.ceil(#candidates / renewalRounds)))
        local failures = 0
        for offset = 0, limit - 1 do
            if isQuiesced() then return true, nil end
            local index = ((pendingLeaseRenewalOffset + offset) % #candidates) + 1
            local entry = candidates[index]
            local renewed, value, renewError = foundation.safeCall(
                leases.renew, leases, entry.connection.clusterLease)
            if isQuiesced() then return true, nil end
            if not renewed or not value then
                local current = players:getPending(entry.source)
                local joined = players:getSession(entry.connection.sessionId)
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
                failures = failures + 1
                foundation.safeCall(logger.error, logger, 'pending session lease renewal failed', {
                    correlationId = entry.connection.id,
                    code = type(renewError) == 'table'
                        and renewError.code or 'PENDING_LEASE_RENEW_FAILED'
                })
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

    function maintenance:heartbeat()
        if isQuiesced() then return true, nil end
        self:purgeExpired()
        if isQuiesced() then return true, nil end
        local pendingLeasesHealthy, pendingLeaseError = renewPendingLeases()
        if isQuiesced() then return true, nil end
        local sessions = players:snapshot().sessions
        local sessionIds = {}
        local sessionLeasesHealthy = true
        local sessionLeaseError = nil
        for _, session in ipairs(sessions) do
            sessionIds[#sessionIds + 1] = session.id
            if session.clusterLease then
                local invoked, renewed, renewError = foundation.safeCall(
                    leases.renew, leases, session.clusterLease)
                if isQuiesced() then return true, nil end
                if not invoked or not renewed then
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
                        players.isCurrent, players, session.id, session.source, session.sourceGeneration)
                    local binding = currentCheck and isCurrent and 'current' or 'stale'
                    if binding == 'current' and session.source ~= nil then
                        foundation.safeCall(platform.dropPlayer, session.source,
                            'Synex session authority was lost. Please reconnect.')
                    end
                    foundation.safeCall(metrics.increment, metrics,
                        'synex_session_lease_loss_total', { binding = binding })
                end
            end
        end
        local touched, touchError = instances:touchSessions(sessionIds,
            function() return not isQuiesced() end)
        if isQuiesced() then return true, nil end
        if not touched then logger:error('session heartbeat persistence failed', { code = touchError.code }) end
        local cluster, heartbeatError = instances:heartbeat(config.clusterSessionLeaseSeconds or 45,
            function() return not isQuiesced() end)
        if isQuiesced() then return true, nil end
        if not cluster then logger:error('instance heartbeat failed', { code = heartbeatError.code }) end
        local controls, controlError = instances:pendingLocalControls()
        if isQuiesced() then return true, nil end
        if not controls then
            logger:error('cluster control polling failed', { code = controlError.code })
        else
            for _, control in ipairs(controls) do
                local completed, completionError = instances:completeControl(control.request_id)
                if isQuiesced() then return true, nil end
                if completed then
                    local target = players:getSession(control.target_session_id)
                    if target and target.source ~= nil and control.action == 'kick'
                        and players:isCurrent(target.id, target.source, target.sourceGeneration) then
                        local dropped = foundation.safeCall(platform.dropPlayer, target.source,
                            tostring(control.reason or 'Session replaced.'):sub(1, 128))
                        if not dropped then
                            logger:error('cluster control player drop failed', {
                                requestId = control.request_id, code = 'PLAYER_DROP_FAILED'
                            })
                        end
                    end
                elseif completionError then
                    logger:error('cluster control completion failed', { code = completionError.code })
                end
            end
        end
        local healthy = pendingLeasesHealthy == true and sessionLeasesHealthy and touched == true
            and cluster ~= nil and controls ~= nil
        lifecycle.core:setHealth('cluster', healthy and 'HEALTHY' or 'DEGRADED',
            healthy and nil or 'cluster heartbeat or control polling failed')
        return healthy, healthy and nil
            or (pendingLeaseError or sessionLeaseError or touchError or heartbeatError or controlError)
    end

    return maintenance
end
