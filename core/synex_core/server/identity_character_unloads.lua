local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityCharacterUnloads = function(deps)
    local foundation = assert(deps.foundation, 'character unloads require foundation')
    local players = assert(deps.players, 'character unloads require the player registry')
    local sessionRepository = assert(deps.sessionRepository, 'character unloads require session persistence')
    local transition = assert(deps.transition, 'character unloads require session transitions')
    local invokeParticipant = assert(deps.invokeParticipant, 'character unloads require participant invocation')
    local orderedParticipants = assert(deps.orderedParticipants, 'character unloads require participant ordering')
    local persistencePendingError = assert(deps.persistencePendingError,
        'character unloads require persistence errors')
    local sessionConflict = assert(deps.sessionConflict, 'character unloads require conflict errors')
    local currentSession = assert(deps.currentSession, 'character unloads require local session fencing')
    local sessionMatches = assert(deps.sessionMatches, 'character unloads require exact session matching')
    local updateCurrentSession = assert(deps.updateCurrentSession,
        'character unloads require local compare-and-swap updates')
    local logger, metrics = foundation.logger, foundation.metrics
    local pending, pendingCharacters, pendingCount = {}, {}, 0
    local cursor = nil
    local maximum = math.max(64, math.min(tonumber(deps.maximum) or 1024, 4096))
    local unloads = {}

    local function clear(sessionId)
        local entry = pending[sessionId]
        if not entry then return end
        if pendingCharacters[entry.characterId] == sessionId then
            pendingCharacters[entry.characterId] = nil
        end
        pending[sessionId] = nil
        pendingCount = math.max(0, pendingCount - 1)
    end

    function unloads:isCharacterPending(characterId)
        return pendingCharacters[characterId] ~= nil
    end

    function unloads:unload(sessionId, reason)
        local session = players:getSession(sessionId)
        if not session then
            return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.')
        end
        if session.persistencePending or session.replacementClosePending then
            return nil, persistencePendingError('The session is waiting for a durable state update.')
        end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string' then
            return nil, foundation.error('INVALID_SESSION_STATE', 'The session has no active character.')
        end
        if not currentSession(session) then
            return nil, sessionConflict('Character unload requires the current session generation.')
        end
        if pendingCount >= maximum then
            return nil, persistencePendingError('Character unload persistence is at capacity.')
        end
        local durableBefore = {
            state = 'ACTIVE', characterId = session.characterId,
            version = session.persistedVersion,
            source = session.persistedSource or session.source,
            sourceGeneration = session.persistedSourceGeneration or session.sourceGeneration
        }
        local unloading, transitionError = updateCurrentSession(session, function(candidate)
            local _, err = transition(candidate, 'UNLOADING_CHARACTER')
            if err then error(err.message) end
        end)
        if not unloading then return nil, transitionError end
        local requiredFailure, requiredFailureCount = nil, 0
        for _, participant in ipairs(orderedParticipants(true)) do
            if participant.unload then
                local _, participantError = invokeParticipant(participant, participant.unload,
                    foundation.readonly({ session = unloading, reason = reason }))
                if not currentSession(unloading) then
                    return nil, sessionConflict(
                        'The session changed during character unload participant cleanup.')
                end
                if participantError then
                    logger:error('character unload participant failed', {
                        participant = participant.name,
                        required = participant.required,
                        code = participantError.code
                    })
                    if participant.required then
                        requiredFailureCount = requiredFailureCount + 1
                        if not requiredFailure then
                            requiredFailure = { participant = participant.name, error = participantError }
                        end
                    end
                end
            end
        end
        if not currentSession(unloading) then
            return nil, sessionConflict('The session changed before character unbinding.')
        end
        local unbound, unbindError = players:unbindCharacter(session.id)
        if not unbound then return nil, unbindError end
        local selected, selectedError = updateCurrentSession(unbound, function(candidate)
            local _, err = transition(candidate, 'SELECTING_CHARACTER')
            if err then error(err.message) end
        end)
        if not selected then
            return nil, selectedError
        end
        local persist = sessionRepository.updateFenced or sessionRepository.update
        local persisted, persistenceError = persist(sessionRepository, selected, durableBefore,
            function() return currentSession(selected) ~= nil end)
        if not persisted then
            local marked, markError = updateCurrentSession(selected, function(candidate)
                candidate.persistencePending = true
            end)
            if marked then
                pending[session.id] = {
                    session = foundation.copy(selected),
                    characterId = session.characterId,
                    expected = foundation.copy(durableBefore),
                    localSession = foundation.copy(marked),
                    attempts = 0,
                    lastError = persistenceError and persistenceError.code or 'DATABASE_ERROR'
                }
                pendingCharacters[session.characterId] = session.id
                pendingCount = pendingCount + 1
                metrics:increment('synex_character_unload_reconciliation_total', { result = 'queued' })
            else
                logger:error('character unload persistence marker failed', {
                    sessionId = session.id,
                    code = markError and markError.code or 'UNKNOWN'
                })
            end
            return nil, persistencePendingError(
                'The character was unloaded locally and is awaiting persistence.',
                persistenceError, { queued = marked ~= nil, state = 'SELECTING_CHARACTER' })
        end
        local synchronized, synchronizationError = updateCurrentSession(selected, function(candidate)
            candidate.persistedVersion = selected.version
            candidate.persistedSource = selected.source or selected.persistedSource or durableBefore.source
            candidate.persistedSourceGeneration = selected.sourceGeneration
            candidate.persistencePending = nil
        end)
        if not synchronized then return nil, synchronizationError end
        if requiredFailure then
            return nil, foundation.error('CHARACTER_UNLOAD_FAILED',
                ('Required unload participant %s failed; Core completed fail-closed unbinding.')
                    :format(requiredFailure.participant), {
                    details = {
                        cause = requiredFailure.error.code,
                        failedParticipants = requiredFailureCount,
                        cleanupContinued = true,
                        stateRestored = false,
                        state = synchronized.state,
                        persisted = true
                    }
                })
        end
        return synchronized, nil
    end

    function unloads:reconcile(limit)
        limit = limit == nil and 10 or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Unload reconciliation limit must be 1 through 32.')
        end
        local sessionIds = {}
        for sessionId in pairs(pending) do sessionIds[#sessionIds + 1] = sessionId end
        table.sort(sessionIds)
        local report = { examined = 0, completed = 0, deferred = 0, abandoned = 0 }
        local startIndex = 1
        if cursor ~= nil then
            startIndex = nil
            for index, sessionId in ipairs(sessionIds) do
                if sessionId > cursor then startIndex = index break end
            end
            startIndex = startIndex or 1
        end
        for offset = 0, math.min(limit, #sessionIds) - 1 do
            local index = ((startIndex + offset - 1) % #sessionIds) + 1
            local sessionId = sessionIds[index]
            local entry = pending[sessionId]
            cursor = sessionId
            report.examined = report.examined + 1
            local function isCurrent(candidate)
                return sessionMatches(candidate, entry.localSession)
            end
            if not isCurrent(players:getSession(sessionId)) then
                clear(sessionId)
                report.abandoned = report.abandoned + 1
                metrics:increment('synex_character_unload_reconciliation_total', {
                    result = 'abandoned'
                })
            else
                entry.attempts = entry.attempts + 1
                local persist = sessionRepository.updateFenced or sessionRepository.update
                local persisted, persistenceError = persist(
                    sessionRepository, entry.session, entry.expected,
                    function() return isCurrent(players:getSession(sessionId)) end)
                if persisted and isCurrent(players:getSession(sessionId)) then
                    local synchronized, synchronizationError = updateCurrentSession(
                        entry.localSession, function(candidate)
                            candidate.persistedVersion = entry.session.version
                            candidate.persistedSource = entry.session.source
                                or entry.session.persistedSource or entry.expected.source
                            candidate.persistedSourceGeneration = entry.session.sourceGeneration
                            candidate.persistencePending = nil
                        end)
                    if synchronized then
                        clear(sessionId)
                        report.completed = report.completed + 1
                        metrics:increment('synex_character_unload_reconciliation_total', {
                            result = 'completed'
                        })
                    else
                        entry.lastError = synchronizationError
                            and synchronizationError.code or 'SESSION_UPDATE_FAILED'
                        report.deferred = report.deferred + 1
                    end
                elseif persisted then
                    clear(sessionId)
                    report.abandoned = report.abandoned + 1
                    metrics:increment('synex_character_unload_reconciliation_total', {
                        result = 'abandoned'
                    })
                else
                    entry.lastError = persistenceError and persistenceError.code or 'DATABASE_ERROR'
                    report.deferred = report.deferred + 1
                    metrics:increment('synex_character_unload_reconciliation_total', {
                        result = 'deferred'
                    })
                end
            end
        end
        if pendingCount == 0 then cursor = nil end
        report.pending = pendingCount
        return report, nil
    end

    function unloads:snapshot()
        return { count = pendingCount, maximum = maximum }
    end

    return unloads
end
