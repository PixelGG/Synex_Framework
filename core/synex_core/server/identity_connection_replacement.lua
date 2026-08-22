local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionReplacement = function(deps)
    local platform = assert(deps.platform, 'connection replacement requires platform')
    local foundation = assert(deps.foundation, 'connection replacement requires foundation')
    local players = assert(deps.players, 'connection replacement requires player registry')
    local messaging = assert(deps.messaging, 'connection replacement requires messaging')
    local characters = assert(deps.characters, 'connection replacement requires character service')
    local sessionRepository = assert(deps.sessionRepository, 'connection replacement requires session repository')
    local releaseConnectionLease = assert(
        deps.releaseConnectionLease, 'connection replacement requires lease release')
    local isQuiesced = deps.isQuiesced or function() return false end
    local pendingClosures = {}
    local reconciliationOffset = 0
    local replacement = {}

    local function stoppingError()
        return foundation.error('CORE_STOPPING',
            'The Synex runtime is stopping and cannot replace local sessions.', { retryable = true })
    end

    local function closeDurably(session, reason)
        if isQuiesced() then return nil, stoppingError() end
        local invoked, closed, closeError = foundation.safeCall(
            sessionRepository.close, sessionRepository, session, reason)
        if isQuiesced() then return nil, stoppingError() end
        if not invoked then
            return nil, foundation.error('SESSION_CLOSE_FAILED',
                'The previous session could not be closed durably.', { retryable = true })
        end
        if closed then return true, nil end
        if closeError and closeError.code == 'SESSION_CONFLICT'
            and type(sessionRepository.getState) == 'function' then
            if isQuiesced() then return nil, stoppingError() end
            local readInvoked, stored, readError = foundation.safeCall(
                sessionRepository.getState, sessionRepository, session.id)
            if isQuiesced() then return nil, stoppingError() end
            if readInvoked and stored and stored.state == 'CLOSED' then return true, nil end
            if readInvoked and readError and readError.code == 'SESSION_NOT_FOUND' then return true, nil end
            if not readInvoked then
                closeError = foundation.error('SESSION_STATE_READ_FAILED',
                    'The previous session close state could not be verified.', { retryable = true })
            elseif readError then
                closeError = readError
            end
        end
        return nil, closeError or foundation.error('SESSION_CLOSE_FAILED',
            'The previous session could not be closed durably.', { retryable = true })
    end

    local function retainClosure(session, reason)
        local entry = pendingClosures[session.id]
        if not entry then
            entry = {
                userId = session.userId,
                reason = reason
            }
            pendingClosures[session.id] = entry
        end
        players:updateSession(session.id, function(candidate)
            candidate.replacementClosePending = true
        end)
    end

    local function finalizeClosure(session)
        pendingClosures[session.id] = nil
        players:removeSession(session.id)
        return releaseConnectionLease(session)
    end

    function replacement:replace(userId)
        if isQuiesced() then return nil, stoppingError() end
        local firstError = nil
        local function rememberFailure(err, code, message)
            if firstError then return end
            firstError = type(err) == 'table' and err
                or foundation.error(code, message, { retryable = true })
        end
        for _, session in ipairs(players:sessionsByUser(userId)) do
            if isQuiesced() then return nil, stoppingError() end
            local current = players:getSession(session.id) or session
            if current.source ~= nil then
                if isQuiesced() then return nil, stoppingError() end
                local detached, detachError = players:detachSource(
                    current.id, current.source, current.sourceGeneration)
                if detached then
                    current = detached
                    if isQuiesced() then return nil, stoppingError() end
                    foundation.safeCall(
                        messaging.network.purgeSource, messaging.network,
                        current.source, current.sourceGeneration)
                    if isQuiesced() then return nil, stoppingError() end
                    foundation.safeCall(platform.dropPlayer, current.source,
                        'This session was replaced by a newer connection.')
                    if isQuiesced() then return nil, stoppingError() end
                else
                    rememberFailure(detachError, 'SOURCE_DETACH_FAILED',
                        'The previous session source could not be detached safely.')
                    current = players:getSession(current.id) or current
                end
            end
            current = players:getSession(current.id) or current
            local closeReason = 'duplicate session replaced'
            if current.source ~= nil then
                retainClosure(current, closeReason)
            else
                if current.state == 'ACTIVE' then
                    local unloaded, unloadError = characters:unload(
                        current.id, closeReason)
                    if isQuiesced() then return nil, stoppingError() end
                    if not unloaded then
                        rememberFailure(unloadError, 'CHARACTER_UNLOAD_FAILED',
                            'The previous session character could not be unloaded.')
                    end
                end
                current = players:getSession(current.id) or current
                local closed, closeError = closeDurably(current, closeReason)
                if isQuiesced() then return nil, stoppingError() end
                if not closed then
                    retainClosure(current, closeReason)
                    rememberFailure(closeError, 'SESSION_CLOSE_FAILED',
                        'The previous session could not be closed durably.')
                else
                    local released, releaseError = finalizeClosure(current)
                    if not released then
                        rememberFailure(releaseError, 'LEASE_RELEASE_FAILED',
                            'The previous session lease could not be released.')
                    end
                end
            end
        end
        if firstError then return nil, firstError end
        return true, nil
    end

    function replacement:reconcile(limit)
        limit = limit == nil and 8 or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Replacement close reconciliation limit must be 1 through 32.')
        end
        local sessionIds = {}
        for sessionId in pairs(pendingClosures) do sessionIds[#sessionIds + 1] = sessionId end
        table.sort(sessionIds)
        local report = { examined = 0, completed = 0, deferred = 0, abandoned = 0 }
        local inspected = math.min(limit, #sessionIds)
        for offset = 0, inspected - 1 do
            if isQuiesced() then return report, nil end
            local index = ((reconciliationOffset + offset) % #sessionIds) + 1
            local sessionId = sessionIds[index]
            local entry = pendingClosures[sessionId]
            local current = players:getSession(sessionId)
            report.examined = report.examined + 1
            if not current or current.userId ~= entry.userId then
                pendingClosures[sessionId] = nil
                report.abandoned = report.abandoned + 1
            elseif current.source ~= nil then
                report.deferred = report.deferred + 1
            else
                local closed = closeDurably(current, entry.reason)
                if isQuiesced() then return report, nil end
                if closed then
                    local released, releaseError = finalizeClosure(current)
                    if not released then
                        foundation.safeCall(foundation.logger.warn, foundation.logger,
                            'replacement session lease release failed after durable close', {
                                sessionId = sessionId,
                                code = releaseError and releaseError.code or 'LEASE_RELEASE_FAILED'
                            })
                    end
                    report.completed = report.completed + 1
                else
                    report.deferred = report.deferred + 1
                end
            end
        end
        if #sessionIds > 0 then
            reconciliationOffset = (reconciliationOffset + inspected) % #sessionIds
        else
            reconciliationOffset = 0
        end
        local pending = 0
        for _ in pairs(pendingClosures) do pending = pending + 1 end
        report.pending = pending
        foundation.safeCall(foundation.metrics.gauge, foundation.metrics,
            'synex_replacement_close_pending', {}, pending)
        return report, nil
    end

    return replacement
end
