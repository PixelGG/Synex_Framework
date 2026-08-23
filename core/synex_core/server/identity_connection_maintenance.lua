local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionMaintenance = function(deps)
    local platform = assert(deps.platform, 'connection maintenance requires platform')
    local foundation = assert(deps.foundation, 'connection maintenance requires foundation')
    local players = assert(deps.players, 'connection maintenance requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection maintenance requires lifecycle')
    local messaging = assert(deps.messaging, 'connection maintenance requires messaging')
    local stateService = deps.stateService or {
        purgePlayer = function() return { cleared = 0, replicated = 0, skipped = 0, failures = {} }, nil end
    }
    local config = deps.config or {}
    local leases = assert(deps.leases, 'connection maintenance requires cluster leases')
    local instances = assert(deps.instances, 'connection maintenance requires cluster instances')
    local characters = assert(deps.characters, 'connection maintenance requires character service')
    local sessionRepository = assert(deps.sessionRepository, 'connection maintenance requires session repository')
    local instanceId = deps.instanceId
    local sessionTransitions = assert(deps.sessionTransitions, 'connection maintenance requires transition map')
    local transition = assert(deps.transition, 'connection maintenance requires session transitions')
    local rateLimiter = assert(deps.rateLimiter, 'connection maintenance requires rate limiter')
    local joinClaims = assert(deps.joinClaims, 'connection maintenance requires join claims')
    local logConnectionStage = assert(deps.logConnectionStage, 'connection maintenance requires stage telemetry')
    local releaseAdmission = assert(deps.releaseAdmission, 'connection maintenance requires admission release')
    local releaseConnectionLease = assert(deps.releaseConnectionLease, 'connection maintenance requires lease release')
    local refreshLeaseDeadline = assert(deps.refreshLeaseDeadline,
        'connection maintenance requires local lease deadlines')
    local clearQueueEntry = assert(deps.clearQueueEntry, 'connection maintenance requires queue cleanup')
    local recordReconnectGrace = assert(deps.recordReconnectGrace, 'connection maintenance requires reconnect grace')
    local purgeReconnectGrace = assert(deps.purgeReconnectGrace, 'connection maintenance requires grace cleanup')
    local isQuiesced = assert(deps.isQuiesced, 'connection maintenance requires quiesce authority')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local pendingCleanupOffset = 0
    local deferredClosures = {}
    local deferredClosureOrder = {}
    local deferredClosureHead = 1
    local deferredClosureTail = 0
    local deferredClosureCount = 0
    local disconnectRetries = {}
    local disconnectRetryOrder = {}
    local disconnectRetryHead = 1
    local disconnectRetryTail = 0
    local disconnectRetryCount = 0
    local maximumDeferredClosures = math.max(1,
        math.min(tonumber(config.maximumActiveSessions) or 128, 10000))
    local maintenance = {}

    local function sameLease(left, right)
        return type(left) == 'table' and type(right) == 'table'
            and (left.name or left.leaseName) == (right.name or right.leaseName)
            and left.owner == right.owner
            and left.fencingToken == right.fencingToken
    end

    local function compactDisconnectRetryOrder()
        if disconnectRetryHead <= 256
            or disconnectRetryHead <= math.floor(disconnectRetryTail / 2) then return end
        local compacted = {}
        for index = disconnectRetryHead, disconnectRetryTail do
            local key = disconnectRetryOrder[index]
            if key and disconnectRetries[key] then compacted[#compacted + 1] = key end
        end
        disconnectRetryOrder = compacted
        disconnectRetryHead = 1
        disconnectRetryTail = #compacted
    end

    local function enqueueDisconnectRetry(expected)
        local key = expected.id .. ':' .. tostring(expected.sourceGeneration)
        if disconnectRetries[key] then return true, nil end
        if disconnectRetryCount >= maximumDeferredClosures then
            return nil, foundation.error('DISCONNECT_RETRY_BACKLOG_FULL',
                'Lost-session disconnect retry capacity is exhausted.', { retryable = true })
        end
        disconnectRetries[key] = {
            key = key, id = expected.id, source = expected.source,
            sourceGeneration = expected.sourceGeneration,
            clusterLease = foundation.copy(expected.clusterLease)
        }
        disconnectRetryTail = disconnectRetryTail + 1
        disconnectRetryOrder[disconnectRetryTail] = key
        disconnectRetryCount = disconnectRetryCount + 1
        foundation.safeCall(metrics.gauge, metrics,
            'synex_session_disconnect_retries_pending', {}, disconnectRetryCount)
        return true, nil
    end

    local function removeDisconnectRetry(key)
        if not disconnectRetries[key] then return false end
        disconnectRetries[key] = nil
        disconnectRetryCount = math.max(0, disconnectRetryCount - 1)
        return true
    end

    local function deferClosure(session, reason, options)
        if type(session) ~= 'table' or type(session.id) ~= 'string' then
            return nil, foundation.error('SESSION_CLOSE_FAILED',
                'Deferred session closure requires a stable session identity.')
        end
        local candidate = foundation.copy(session)
        candidate.closeReason = tostring(reason or 'dropped'):sub(1, 128)
        candidate.recordReconnectGrace = type(options) ~= 'table'
            or options.recordReconnectGrace ~= false
        if deferredClosures[candidate.id] then
            deferredClosures[candidate.id] = candidate
            return true, nil
        end
        if deferredClosureCount >= maximumDeferredClosures then
            return nil, foundation.error('SESSION_CLOSE_BACKLOG_FULL',
                'Deferred session closure capacity is exhausted.', { retryable = true })
        end
        deferredClosures[candidate.id] = candidate
        deferredClosureTail = deferredClosureTail + 1
        deferredClosureOrder[deferredClosureTail] = candidate.id
        deferredClosureCount = deferredClosureCount + 1
        foundation.safeCall(metrics.gauge, metrics,
            'synex_session_close_reconciliation_pending', {},
            deferredClosureCount)
        return true, nil
    end

    local function compactClosureOrder()
        if deferredClosureHead <= 256
            or deferredClosureHead <= math.floor(deferredClosureTail / 2) then return end
        local compacted = {}
        for index = deferredClosureHead, deferredClosureTail do
            local sessionId = deferredClosureOrder[index]
            if sessionId and deferredClosures[sessionId] then
                compacted[#compacted + 1] = sessionId
            end
        end
        deferredClosureOrder = compacted
        deferredClosureHead = 1
        deferredClosureTail = #compacted
    end

    local function resolveClosedConflict(candidate)
        if type(sessionRepository.getState) ~= 'function' then return false, nil end
        local invoked, stored, stateError = foundation.safeCall(
            sessionRepository.getState, sessionRepository, candidate.id)
        if not invoked then
            return false, foundation.error('SESSION_STATE_READ_FAILED',
                'Deferred session closure state could not be verified.', { retryable = true })
        end
        local expectedSource = candidate.persistedSource
        if expectedSource == nil then expectedSource = candidate.source end
        local expectedGeneration = candidate.persistedSourceGeneration
            or candidate.sourceGeneration
        local expectedInstanceId = instanceId
        if expectedInstanceId == nil and type(candidate.clusterLease) == 'table' then
            expectedInstanceId = candidate.clusterLease.requesterInstanceId
        end
        if stored and (stored.closed == true or stored.state == 'CLOSED')
            and stored.userId == candidate.userId
            and type(expectedInstanceId) == 'string'
            and stored.serverInstanceId == expectedInstanceId
            and tonumber(stored.sourceGeneration) == tonumber(expectedGeneration)
            and (expectedSource == nil
                or tonumber(stored.source) == tonumber(expectedSource)) then
            return true, nil
        end
        if type(stateError) == 'table' and stateError.code == 'SESSION_NOT_FOUND' then return true, nil end
        return false, stateError
    end

    local function finalizeDeferredClosure(sessionId, candidate)
        local releaseInvoked, released, releaseError = foundation.safeCall(
            releaseConnectionLease, candidate)
        if not releaseInvoked or not released then
            return nil, releaseInvoked and releaseError or foundation.error(
                'LEASE_RELEASE_FAILED', 'Reconciled session authority could not be released.')
        end
        deferredClosures[sessionId] = nil
        deferredClosureCount = math.max(0, deferredClosureCount - 1)
        players:removeSession(sessionId)
        if candidate.recordReconnectGrace ~= false then
            recordReconnectGrace(candidate.userId)
        end
        return true, nil
    end

    function maintenance:closeOrDefer(session, reason, options)
        if type(session) ~= 'table' or type(session.id) ~= 'string' then
            return nil, foundation.error('SESSION_CLOSE_FAILED',
                'Session closure requires a stable session identity.')
        end
        options = type(options) == 'table' and options or {}
        local attempts = math.max(1, math.min(tonumber(options.attempts) or 2, 2))
        local registered = players:getSession(session.id)
        local candidate = registered or foundation.copy(session)
        if candidate.userId ~= session.userId then
            return nil, foundation.error('SESSION_CONFLICT',
                'Session closure authority no longer matches the local registry.')
        end
        if options.detachSource == true then
            local expectedSource = options.source
            if expectedSource == nil then expectedSource = session.source end
            local expectedGeneration = options.sourceGeneration
                or session.sourceGeneration
            candidate.persistedSource = candidate.persistedSource or expectedSource
            candidate.persistedSourceGeneration = candidate.persistedSourceGeneration
                or expectedGeneration
            if registered then
                local prepared, prepareError = players:updateSession(candidate.id, function(current)
                    if current.userId ~= candidate.userId then
                        error('session ownership changed before source detach')
                    end
                    current.persistedSource = current.persistedSource or expectedSource
                    current.persistedSourceGeneration = current.persistedSourceGeneration
                        or expectedGeneration
                end)
                if not prepared then return nil, prepareError end
                candidate = prepared
            end
            if registered and candidate.source ~= nil then
                if candidate.source ~= expectedSource
                    or candidate.sourceGeneration ~= expectedGeneration then
                    return nil, foundation.error('SOURCE_NOT_CURRENT',
                        'The join source binding changed before compensation.')
                end
                local detached, detachError = players:detachSource(
                    candidate.id, expectedSource, expectedGeneration)
                if not detached then return nil, detachError end
                foundation.safeCall(stateService.purgePlayer, stateService,
                    expectedSource, expectedGeneration)
                foundation.safeCall(messaging.network.purgeSource, messaging.network,
                    expectedSource, expectedGeneration)
                candidate = players:getSession(candidate.id) or candidate
            end
        end
        if registered and candidate.state ~= 'DISCONNECTING' and candidate.state ~= 'CLOSED' then
            local transitioned, transitionError = players:updateSession(candidate.id, function(current)
                if current.userId ~= candidate.userId then
                    error('session ownership changed before close')
                end
                if current.state ~= 'DISCONNECTING' and current.state ~= 'CLOSED'
                    and sessionTransitions[current.state]
                    and sessionTransitions[current.state].DISCONNECTING then
                    transition(current, 'DISCONNECTING')
                end
            end)
            if not transitioned then return nil, transitionError end
            candidate = transitioned
        end
        local lastError = nil
        for attempt = 1, attempts do
            local invoked, value, closeError = foundation.safeCall(
                sessionRepository.close, sessionRepository, candidate,
                tostring(reason or 'dropped'):sub(1, 128))
            local resolved = invoked and value == true
            local failure = invoked and closeError or value
            if not resolved and type(failure) == 'table'
                and failure.code == 'SESSION_CONFLICT' then
                local conflictResolved, conflictError = resolveClosedConflict(candidate)
                resolved = conflictResolved == true
                failure = conflictError or failure
            end
            if resolved then
                local finalized, finalizeError = finalizeDeferredClosure(candidate.id, candidate)
                if finalized then
                    return { closed = true, deferred = false, attempts = attempt }, nil
                end
                lastError = finalizeError
                break
            end
            lastError = failure or foundation.error('SESSION_CLOSE_FAILED',
                'The durable session could not be closed.', { retryable = true })
            if attempt < attempts then platform.wait(25) end
        end
        local deferred, deferError = deferClosure(candidate, reason, options)
        if not deferred then return nil, deferError end
        return {
            closed = false, deferred = true, attempts = attempts,
            failure = lastError
        }, nil
    end

    function maintenance:reconcileClosures(maximum)
        maximum = maximum == nil and 32 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 256 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Session close reconciliation batch size must be an integer from 1 through 256.')
        end
        if deferredClosureCount == 0 then
            deferredClosureOrder = {}
            deferredClosureHead = 1
            deferredClosureTail = 0
            return { inspected = 0, closed = 0, pending = 0 }, nil
        end
        local inspected, closed, firstError = 0, 0, nil
        local available = deferredClosureCount
        while inspected < maximum and inspected < available
            and deferredClosureHead <= deferredClosureTail do
            local sessionId = deferredClosureOrder[deferredClosureHead]
            deferredClosureOrder[deferredClosureHead] = nil
            deferredClosureHead = deferredClosureHead + 1
            local candidate = deferredClosures[sessionId]
            if candidate then
                inspected = inspected + 1
                local invoked, value, closeError = foundation.safeCall(
                    sessionRepository.close, sessionRepository, candidate, candidate.closeReason)
                local resolved = invoked and value == true
                local failure = invoked and closeError or value
                if not resolved and type(failure) == 'table'
                    and failure.code == 'SESSION_CONFLICT' then
                    local conflictResolved, conflictError = resolveClosedConflict(candidate)
                    resolved = conflictResolved == true
                    failure = conflictError or failure
                end
                if resolved then
                    local finalized, finalizeError = finalizeDeferredClosure(sessionId, candidate)
                    if finalized then
                        closed = closed + 1
                    else
                        firstError = firstError or finalizeError
                        deferredClosureTail = deferredClosureTail + 1
                        deferredClosureOrder[deferredClosureTail] = sessionId
                    end
                else
                    firstError = firstError or failure or foundation.error(
                        'SESSION_CLOSE_FAILED',
                        'Deferred session closure failed.', { retryable = true })
                    deferredClosureTail = deferredClosureTail + 1
                    deferredClosureOrder[deferredClosureTail] = sessionId
                end
            end
        end
        compactClosureOrder()
        foundation.safeCall(metrics.gauge, metrics,
            'synex_session_close_reconciliation_pending', {}, deferredClosureCount)
        foundation.safeCall(metrics.increment, metrics,
            'synex_session_close_reconciliation_total', {
                result = firstError and 'retry' or 'complete'
            }, closed)
        if firstError then return nil, firstError end
        return { inspected = inspected, closed = closed, pending = deferredClosureCount }, nil
    end

    function maintenance:pendingDisconnectRetries()
        return disconnectRetryCount
    end

    function maintenance:reconcileDisconnects(maximum)
        maximum = maximum == nil and 32 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 256 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Disconnect retry batch size must be an integer from 1 through 256.')
        end
        local inspected, completed, cancelled, firstError = 0, 0, 0, nil
        local available = disconnectRetryCount
        while inspected < maximum and inspected < available
            and disconnectRetryHead <= disconnectRetryTail do
            local key = disconnectRetryOrder[disconnectRetryHead]
            disconnectRetryOrder[disconnectRetryHead] = nil
            disconnectRetryHead = disconnectRetryHead + 1
            local expected = disconnectRetries[key]
            if expected then
                inspected = inspected + 1
                local replacement = type(players.getRawBySource) == 'function'
                    and players:getRawBySource(expected.source)
                    or players:getBySource(expected.source)
                local pending = type(players.getRawPending) == 'function'
                    and players:getRawPending(expected.source) or players:getPending(expected.source)
                if replacement ~= nil or pending ~= nil then
                    removeDisconnectRetry(key)
                    cancelled = cancelled + 1
                else
                    local invoked, result, dropError = foundation.safeCall(
                        platform.dropPlayer, expected.source,
                        'Synex session authority was lost. Please reconnect.')
                    replacement = type(players.getRawBySource) == 'function'
                        and players:getRawBySource(expected.source)
                        or players:getBySource(expected.source)
                    pending = type(players.getRawPending) == 'function'
                        and players:getRawPending(expected.source)
                        or players:getPending(expected.source)
                    if replacement ~= nil or pending ~= nil then
                        removeDisconnectRetry(key)
                        cancelled = cancelled + 1
                    elseif invoked and result ~= false then
                        removeDisconnectRetry(key)
                        completed = completed + 1
                    else
                        firstError = firstError or dropError or foundation.error(
                            'PLAYER_DROP_FAILED',
                            'Lost-session disconnect retry was not accepted.', {
                                retryable = true
                            })
                        disconnectRetryTail = disconnectRetryTail + 1
                        disconnectRetryOrder[disconnectRetryTail] = key
                    end
                end
            end
        end
        compactDisconnectRetryOrder()
        foundation.safeCall(metrics.gauge, metrics,
            'synex_session_disconnect_retries_pending', {}, disconnectRetryCount)
        foundation.safeCall(metrics.increment, metrics,
            'synex_session_disconnect_retry_total', {
                result = firstError and 'retry' or 'complete'
            }, completed + cancelled)
        if firstError then return nil, firstError end
        return {
            inspected = inspected, completed = completed, cancelled = cancelled,
            pending = disconnectRetryCount
        }, nil
    end

    local function cleanupDetachedSession(session, playerSource, reason)
        local failures = {}
        local statePurged, stateReport, stateError = foundation.safeCall(
            stateService.purgePlayer, stateService, playerSource, session.sourceGeneration)
        if not statePurged or not stateReport then
            local failure = statePurged and stateError or stateReport
            failures[#failures + 1] = {
                step = 'player_state_purge',
                code = type(failure) == 'table' and failure.code or 'RUNTIME_ERROR'
            }
            foundation.safeCall(logger.error, logger, 'disconnect player state cleanup failed', {
                sessionId = session.id,
                code = type(failure) == 'table' and failure.code or 'RUNTIME_ERROR'
            })
        elseif #(stateReport.failures or {}) > 0 then
            failures[#failures + 1] = {
                step = 'player_state_purge',
                code = 'STATE_REPLICATION_FAILED'
            }
            foundation.safeCall(logger.error, logger, 'disconnect player state cleanup was incomplete', {
                sessionId = session.id,
                failures = #stateReport.failures
            })
        end
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
                    code = foundation.failureCode(failure, 'DISCONNECT_CLEANUP_FAILED')
                }
                logger:error('disconnect cleanup step failed', {
                    step = step, sessionId = session.id, userId = session.userId,
                    code = foundation.failureCode(failure, 'DISCONNECT_CLEANUP_FAILED')
                })
                return nil
            end
            return value
        end
        if session.state == 'ACTIVE' then
            capture('character_unload', function() return characters:unload(session.id, 'disconnect') end)
        end
        local current = players:getSession(session.id)
        if not current then
            if #failures > 0 then
                metrics:increment('synex_disconnect_cleanup_total', { result = 'partial' })
                lifecycle.core:setHealth('disconnect-cleanup', 'DEGRADED',
                    ('%d cleanup step(s) failed'):format(#failures))
            else
                metrics:increment('synex_disconnect_cleanup_total', { result = 'complete' })
                lifecycle.core:setHealth('disconnect-cleanup', 'HEALTHY')
            end
            return { closed = true, failures = failures, finalizedConcurrently = true }
        end
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
        local closeReport, closeError = maintenance:closeOrDefer(current, reason, {
            attempts = 2, recordReconnectGrace = true
        })
        local closed = closeReport and closeReport.closed == true
        if not closeReport then
            failures[#failures + 1] = {
                step = 'session_close_reconciliation',
                code = foundation.failureCode(closeError, 'SESSION_CLOSE_BACKLOG_FULL')
            }
            logger:error('disconnect close reconciliation capacity failed', {
                sessionId = session.id,
                code = foundation.failureCode(closeError, 'SESSION_CLOSE_BACKLOG_FULL')
            })
        elseif closeReport.deferred then
            failures[#failures + 1] = {
                step = 'session_close_deferred',
                code = foundation.failureCode(closeReport.failure, 'SESSION_CLOSE_FAILED')
            }
        end
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
        if not closeReport then return nil, closeError end
        return { closed = closed, failures = failures }
    end

    function maintenance:handleDropped(playerSource, reason)
        playerSource = tonumber(playerSource) or playerSource
        joinClaims:invalidate(playerSource)
        local session = type(players.getRawBySource) == 'function'
            and players:getRawBySource(playerSource) or players:getBySource(playerSource)
        if not session then
            foundation.safeCall(rateLimiter.purge, rateLimiter,
                'join:' .. tostring(playerSource) .. ':')
            foundation.safeCall(
                messaging.network.purgeSource, messaging.network, playerSource, nil)
            local pending = players:removePending(playerSource)
            if pending then clearQueueEntry(pending) end
            releaseAdmission(pending)
            releaseConnectionLease(pending)
            if pending then
                logConnectionStage(pending, 'pending_cancelled', 'PLAYER_DROPPED', 'warn')
            end
            return
        end
        local detached, detachError = players:detachSource(
            session.id, playerSource, session.sourceGeneration)
        if not detached then
            foundation.safeCall(logger.warn, logger, 'stale player drop ignored', {
                sessionId = session.id,
                code = detachError and detachError.code or 'SOURCE_NOT_CURRENT'
            })
            return nil, detachError
        end
        foundation.safeCall(rateLimiter.purge, rateLimiter,
            'join:' .. tostring(playerSource) .. ':')
        return cleanupDetachedSession(detached, playerSource, reason)
    end

    function maintenance:invalidateLostSession(expected, reason)
        if type(expected) ~= 'table' or type(expected.id) ~= 'string'
            or expected.source == nil or type(expected.clusterLease) ~= 'table' then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Lost session invalidation requires exact source and lease authority.')
        end
        local current = type(players.getRawBySource) == 'function'
            and players:getRawBySource(expected.source) or players:getBySource(expected.source)
        if not current or current.id ~= expected.id
            or current.sourceGeneration ~= expected.sourceGeneration
            or not sameLease(current.clusterLease, expected.clusterLease) then
            return { invalidated = false, stale = true }, nil
        end
        local detached, detachError = players:detachSource(
            expected.id, expected.source, expected.sourceGeneration)
        if not detached then return nil, detachError end
        joinClaims:invalidate(expected.source)
        foundation.safeCall(rateLimiter.purge, rateLimiter,
            'join:' .. tostring(expected.source) .. ':')
        local report, cleanupError = cleanupDetachedSession(
            detached, expected.source, reason or 'cluster session authority lost')
        local replacement = type(players.getRawBySource) == 'function'
            and players:getRawBySource(expected.source) or players:getBySource(expected.source)
        local pending = type(players.getRawPending) == 'function'
            and players:getRawPending(expected.source) or players:getPending(expected.source)
        if replacement == nil and pending == nil then
            local invoked, result, dropError = foundation.safeCall(
                platform.dropPlayer, expected.source,
                'Synex session authority was lost. Please reconnect.')
            replacement = type(players.getRawBySource) == 'function'
                and players:getRawBySource(expected.source) or players:getBySource(expected.source)
            pending = type(players.getRawPending) == 'function'
                and players:getRawPending(expected.source) or players:getPending(expected.source)
            if replacement == nil and pending == nil and (not invoked or result == false) then
                local queued, queueError = enqueueDisconnectRetry(expected)
                if not queued then return nil, queueError or dropError end
                if report then report.disconnectRetryQueued = true end
            end
        end
        if not report then return nil, cleanupError end
        report.invalidated = true
        return report, nil
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
                local current = type(players.getRawPending) == 'function'
                    and players:getRawPending(entry.source) or players:getPending(entry.source)
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

    local heartbeat = factories.identityConnectionHeartbeat({
        platform = platform,
        foundation = foundation,
        players = players,
        lifecycle = lifecycle,
        config = config,
        leases = leases,
        instances = instances,
        maintenance = maintenance,
        sameLease = sameLease,
        refreshLeaseDeadline = refreshLeaseDeadline,
        clearQueueEntry = clearQueueEntry,
        releaseAdmission = releaseAdmission,
        releaseConnectionLease = releaseConnectionLease,
        logConnectionStage = logConnectionStage,
        isQuiesced = isQuiesced
    })

    function maintenance:heartbeat()
        return heartbeat:run()
    end

    return maintenance
end
