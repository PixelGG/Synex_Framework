local factories = assert(SynexCoreFactories, 'factories must be loaded first')
factories.identityCharacters = function(deps)
    local platform = assert(deps.platform, 'identity characters requires platform')
    local foundation = assert(deps.foundation, 'identity characters requires foundation')
    local database = assert(deps.database, 'identity characters requires database')
    local players = assert(deps.players, 'identity characters requires player registry')
    local owners = assert(deps.owners, 'identity characters requires owner registry')
    local messaging = assert(deps.messaging, 'identity characters requires messaging')
    local coreResource = assert(deps.coreResource, 'identity characters requires core resource')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local characterRepository = assert(deps.characterRepository, 'identity characters requires character repository')
    local sessionRepository = assert(deps.sessionRepository, 'identity characters requires session repository')
    local invokeOwned = assert(deps.invokeOwned, 'identity characters requires owned invocation')
    local transition = assert(deps.transition, 'identity characters requires session transitions')
    local leases = assert(deps.leases, 'identity characters requires cluster leases')
    local instances = assert(deps.instances, 'identity characters requires cluster instances')
    local instanceId = assert(deps.instanceId, 'identity characters requires instance ID')
    local stateService = deps.stateService or {
        purgeSubject = function() return { cleared = 0 }, nil end
    }
    local participants = {}
    local participantSequence = 0
    local participantCount = 0
    local participantMaximum = 128
    local cache = {}
    local cacheSize = 0
    local cacheMaximum = math.max(64, math.min(tonumber(deps.cacheMaximum) or 1024, 10000))
    local cacheTtlMs = math.max(1000, math.min(tonumber(deps.cacheTtlMs) or 30000, 300000))
    local characters = {}
    local function persistencePendingError(message, cause, details)
        details = details or {}
        details.cause = type(cause) == 'table' and cause.code or 'PERSISTENCE_RETRY'
        return foundation.error('SESSION_PERSISTENCE_PENDING', message,
            { retryable = true, details = details })
    end
    local function leaseName(lease)
        return type(lease) == 'table' and (lease.name or lease.leaseName) or nil
    end
    local function sessionMatches(candidate, expected)
        if type(candidate) ~= 'table' or type(expected) ~= 'table'
            or candidate.id ~= expected.id or candidate.userId ~= expected.userId
            or candidate.source ~= expected.source
            or candidate.sourceGeneration ~= expected.sourceGeneration
            or candidate.state ~= expected.state or candidate.characterId ~= expected.characterId
            or candidate.version ~= expected.version
            or candidate.persistedVersion ~= expected.persistedVersion
            or candidate.persistedSource ~= expected.persistedSource
            or candidate.persistedSourceGeneration ~= expected.persistedSourceGeneration
            or candidate.persistencePending ~= expected.persistencePending
            or candidate.replacementClosePending ~= expected.replacementClosePending then
            return false
        end
        local candidateLease, expectedLease = candidate.clusterLease, expected.clusterLease
        if leaseName(candidateLease) ~= leaseName(expectedLease)
            or type(candidateLease) ~= 'table' or type(expectedLease) ~= 'table'
            or candidateLease.owner ~= expectedLease.owner
            or candidateLease.fencingToken ~= expectedLease.fencingToken
            or candidateLease.requesterInstanceId ~= expectedLease.requesterInstanceId
            or candidateLease.requesterBootId ~= expectedLease.requesterBootId then
            return false
        end
        if expected.source == nil then return true end
        if type(players.isCurrent) ~= 'function' then return false end
        local invoked, current = foundation.safeCall(
            players.isCurrent, players, expected.id, expected.source, expected.sourceGeneration)
        return invoked and current == true
    end
    local function currentSession(expected)
        local candidate = players:getSession(expected.id)
        return sessionMatches(candidate, expected) and candidate or nil
    end
    local function sessionConflict(message)
        return persistencePendingError(message, { code = 'SESSION_CONFLICT' })
    end
    local function updateCurrentSession(expected, mutator)
        if not currentSession(expected) then
            return nil, sessionConflict('The caller session changed during the character operation.')
        end
        local updated = players:updateSession(expected.id, function(candidate)
            if not sessionMatches(candidate, expected) then
                error('character session fence changed')
            end
            mutator(candidate)
        end)
        if not updated then
            return nil, sessionConflict('The caller session changed during the character operation.')
        end
        return updated, nil
    end
    local function characterLocallyActive(characterId, excludedSessionId)
        if type(players.getByCharacter) == 'function' then
            local active = players:getByCharacter(characterId)
            return active ~= nil and active.id ~= excludedSessionId, active
        end
        if type(players.snapshot) == 'function' then
            local snapshot = players:snapshot()
            for _, active in ipairs(snapshot.sessions or {}) do
                if active.characterId == characterId and active.id ~= excludedSessionId then
                    return true, active
                end
            end
        end
        return false, nil
    end
    local function invokeParticipant(participant, handler, ...)
        local started = foundation.monotonicMs()
        local invoked, result, handlerError = invokeOwned(participant, handler, ...)
        local elapsed = math.max(0, foundation.monotonicMs() - started)
        if elapsed > participant.timeoutMs then
            return nil, foundation.error('PARTICIPANT_TIMEOUT', 'A character lifecycle participant exceeded its deadline.', {
                retryable = true, details = { timeoutMs = participant.timeoutMs, elapsedMs = elapsed }
            }), invoked and result or nil
        end
        if not invoked then
            return nil, type(result) == 'table' and result
                or foundation.error('PARTICIPANT_FAILED', 'A character lifecycle participant failed.', { retryable = true })
        end
        if handlerError ~= nil then
            return nil, type(handlerError) == 'table' and handlerError
                or foundation.error('PARTICIPANT_FAILED',
                    'A character lifecycle participant returned an error.', { retryable = true }), result
        end
        return result == nil and true or result, nil
    end
    local function cacheCharacter(character)
        if type(character) ~= 'table' or type(character.id) ~= 'string' then return end
        local now = foundation.monotonicMs()
        if not cache[character.id] then
            cacheSize = cacheSize + 1
            if cacheSize > cacheMaximum then
                local oldestId, oldestAt = nil, nil
                for characterId, entry in pairs(cache) do
                    if oldestAt == nil or entry.touchedAt < oldestAt then oldestId, oldestAt = characterId, entry.touchedAt end
                end
                if oldestId then
                    cache[oldestId] = nil
                    cacheSize = cacheSize - 1
                    metrics:increment('synex_character_cache_total', { result = 'eviction' })
                end
            end
        end
        cache[character.id] = {
            value = foundation.copy(character), version = tonumber(character.version) or 0,
            expiresAt = now + cacheTtlMs, touchedAt = now
        }
    end
    local function invalidateCharacter(characterId)
        if cache[characterId] then cache[characterId] = nil; cacheSize = math.max(0, cacheSize - 1) end
        metrics:increment('synex_character_cache_total', { result = 'invalidation' })
    end
    function characters:registerParticipant(owner, epoch, definition)
        local timeoutMs = type(definition) == 'table' and (definition.timeoutMs or 5000) or nil
        local priority = type(definition) == 'table' and (definition.priority or 0) or nil
        local optionalHandlersValid = type(definition) == 'table'
        for _, field in ipairs({ 'commit', 'rollback', 'unload', 'deletePreflight', 'deleteCommit' }) do
            if optionalHandlersValid and definition[field] ~= nil and type(definition[field]) ~= 'function' then
                optionalHandlersValid = false
            end
        end
        if type(definition) ~= 'table' or type(definition.name) ~= 'string' or #definition.name < 1
            or #definition.name > 64 or not definition.name:match('^[a-z][a-z0-9_.%-]*$')
            or type(definition.prepare) ~= 'function' or not optionalHandlersValid
            or type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < 100 or timeoutMs > 30000
            or type(priority) ~= 'number' or math.type(priority) ~= 'integer'
            or priority < -1000 or priority > 1000
            or (definition.required ~= nil and type(definition.required) ~= 'boolean') then
            return nil, foundation.error('INVALID_PARTICIPANT',
                'Character participant identity, handlers, or timeout are invalid.')
        end
        if definition.required ~= false and definition.commit ~= nil then
            return nil, foundation.error('INVALID_PARTICIPANT',
                'Required character participants must complete activation in prepare and cannot define commit.')
        end
        if definition.required ~= false and definition.rollback == nil then
            return nil, foundation.error('INVALID_PARTICIPANT',
                'Required character participants must define rollback for prepared activation state.')
        end
        if participantCount >= participantMaximum then
            return nil, foundation.error('PARTICIPANT_LIMIT', 'The character participant registry is full.')
        end
        participantSequence = participantSequence + 1
        local token = foundation.nextId('character_participant')
        local entry = {
            owner = owner, epoch = epoch, token = token, name = definition.name,
            prepare = definition.prepare, commit = definition.commit, rollback = definition.rollback, unload = definition.unload,
            deletePreflight = definition.deletePreflight, deleteCommit = definition.deleteCommit,
            priority = priority, required = definition.required ~= false,
            sequence = participantSequence, timeoutMs = timeoutMs
        }
        participants[token] = entry
        participantCount = participantCount + 1
        local _, err = owners:track(owner, epoch, 'character_participant', token, function()
            if participants[token] then participants[token] = nil; participantCount = math.max(0, participantCount - 1) end
        end)
        if err then participants[token] = nil; participantCount = participantCount - 1; return nil, err end
        return token, nil
    end
    local function orderedParticipants(reverse)
        local result = {}
        for _, participant in pairs(participants) do
            if owners:isCurrent(participant.owner, participant.epoch) then result[#result + 1] = participant end
        end
        table.sort(result, function(a, b)
            if a.priority == b.priority then
                if reverse then return a.sequence > b.sequence end
                return a.sequence < b.sequence
            end
            if reverse then return a.priority < b.priority end
            return a.priority > b.priority
        end)
        return result
    end
    local function findParticipant(action)
        for _, participant in pairs(participants) do
            if participant.owner == action.owner and owners:isCurrent(participant.owner, participant.epoch)
                and (action.participant == nil or action.participant == participant.name) then
                return participant
            end
        end
        return nil
    end

    local deletionReconciliation = factories.identityCharacterDeletionReconciliation({
        platform = platform,
        foundation = foundation,
        database = database,
        leases = leases,
        instances = instances,
        owners = owners,
        messaging = messaging,
        stateService = stateService,
        invokeParticipant = invokeParticipant,
        findParticipant = findParticipant,
        instanceId = instanceId,
        coreResource = coreResource,
        participantMaximum = participantMaximum
    })
    local unloads = factories.identityCharacterUnloads({
        foundation = foundation,
        players = players,
        sessionRepository = sessionRepository,
        transition = transition,
        invokeParticipant = invokeParticipant,
        orderedParticipants = orderedParticipants,
        persistencePendingError = persistencePendingError,
        sessionConflict = sessionConflict,
        currentSession = currentSession,
        sessionMatches = sessionMatches,
        updateCurrentSession = updateCurrentSession,
        maximum = deps.pendingUnloadMaximum
    })

    function characters:list(sessionId)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        local result, err = characterRepository:list(session.userId)
        if not result then return nil, err end
        for _, character in ipairs(result) do cacheCharacter(character) end
        return result, nil
    end

    function characters:get(characterId)
        if type(characterId) ~= 'string' or #characterId < 1 or #characterId > 36 then
            return nil, foundation.error('INVALID_CHARACTER_ID', 'Character ID is invalid.')
        end
        local now = foundation.monotonicMs()
        local cached = cache[characterId]
        if cached and cached.expiresAt > now then
            cached.touchedAt = now
            metrics:increment('synex_character_cache_total', { result = 'hit' })
            return foundation.copy(cached.value), nil
        end
        if cached then invalidateCharacter(characterId) end
        local character, err = characterRepository:get(characterId)
        if not character then
            metrics:increment('synex_character_cache_total', { result = err and 'error' or 'miss' })
            return nil, err
        end
        cacheCharacter(character)
        metrics:increment('synex_character_cache_total', { result = 'miss' })
        return foundation.copy(character), nil
    end

    function characters:getActive(sessionOrSource)
        local session = players:getSession(sessionOrSource)
        if not session then session = players:getBySource(tonumber(sessionOrSource) or sessionOrSource) end
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.state ~= 'ACTIVE' or not session.characterId then
            return nil, foundation.error('CHARACTER_NOT_ACTIVE', 'The session has no active character.')
        end
        return self:get(session.characterId)
    end

    function characters:create(sessionId, input)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.persistencePending or session.replacementClosePending then
            return nil, persistencePendingError('The session is waiting for a durable state update.')
        end
        if session.state ~= 'SELECTING_CHARACTER' then return nil, foundation.error('INVALID_SESSION_STATE', 'Characters can only be created while selecting a character.') end
        if type(input) ~= 'table' then return nil, foundation.error('INVALID_ARGUMENT', 'Character input must be an object.') end
        if not currentSession(session) then
            return nil, sessionConflict('Character creation requires the current caller session generation.')
        end
        local candidate, hookError = messaging.hooks:run(deps.coreResource, owners:epoch(deps.coreResource),
            'synex.characters.before_create', input, {
                metadata = { sessionId = sessionId, userId = session.userId }
            })
        if not candidate then return nil, hookError end
        if not currentSession(session) then
            return nil, sessionConflict('The caller session changed during character creation.')
        end
        local character, createError = characterRepository:create(session, candidate, function()
            return currentSession(session) ~= nil
        end)
        if not character then return nil, createError end
        if not currentSession(session) then
            return nil, sessionConflict(
                'The caller session changed while character creation committed.')
        end
        cacheCharacter(character)
        messaging.events:publish(coreResource, owners:epoch(coreResource), 'synex.characters.created', {
            characterId = character.id, userId = session.userId, slot = character.slot
        })
        if not currentSession(session) then
            return nil, sessionConflict('The caller session changed while character creation completed.')
        end
        return character, nil
    end

    function characters:delete(sessionId, characterId)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.persistencePending or session.replacementClosePending then
            return nil, persistencePendingError('The session is waiting for a durable state update.')
        end
        if session.state ~= 'SELECTING_CHARACTER' then return nil, foundation.error('INVALID_SESSION_STATE', 'An active character cannot be deleted.') end
        if not currentSession(session) then
            return nil, sessionConflict('Character deletion requires the current caller session generation.')
        end
        if characterLocallyActive(characterId, session.id) then
            return nil, foundation.error('CHARACTER_DELETE_BLOCKED',
                'The character is active in another local session.', { retryable = true })
        end
        local character, characterError = characterRepository:getOwned(session.userId, characterId)
        if not character then return nil, characterError end
        if not currentSession(session) then
            return nil, sessionConflict('The caller session changed during character deletion.')
        end
        local plan = { schema = 1, characterId = characterId, actions = {} }
        local ordered = orderedParticipants(false)
        for _, participant in ipairs(ordered) do
            if participant.deletePreflight then
                local result, participantError = invokeParticipant(participant, participant.deletePreflight,
                    foundation.readonly({ session = session, character = character }))
                if not currentSession(session) then
                    return nil, sessionConflict(
                        'The caller session changed during character deletion preflight.')
                end
                if participantError then
                    logger:error('character deletion preflight failed', {
                        participant = participant.name, required = participant.required, code = participantError.code
                    })
                    if participant.required then return nil, foundation.error('CHARACTER_DELETE_PREFLIGHT_FAILED',
                        ('Deletion preflight failed for %s.'):format(participant.name), { retryable = true }) end
                end
                local allowedActions = { allow = true, delete = true, anonymize = true, retain = true, block = true }
                if not participantError and (type(result) ~= 'table' or not allowedActions[result.action]) then
                    return nil, foundation.error('INVALID_DELETE_PLAN', ('Deletion participant %s returned an invalid action.'):format(participant.name))
                end
                if not participantError and result.action == 'block' then
                    return nil, foundation.error(result.code or 'CHARACTER_DELETE_BLOCKED', result.message or 'A dependent resource blocked character deletion.')
                end
                if not participantError then plan.actions[#plan.actions + 1] = {
                    owner = participant.owner, participant = participant.name, action = result.action,
                    metadata = result.metadata, notify = type(participant.deleteCommit) == 'function'
                } end
            end
        end
        local planValid, planValidationError = deletionReconciliation:validate(plan)
        if not planValid then return nil, planValidationError end
        local planId = foundation.nextId('del')
        local encodedPlan, planJson = pcall(platform.jsonEncode, plan)
        if not encodedPlan or type(planJson) ~= 'string' or #planJson > 65536 then
            return nil, foundation.error('INVALID_DELETE_PLAN', 'The character deletion plan is too large.')
        end
        if not currentSession(session) then
            return nil, sessionConflict('The caller session changed before character deletion commit.')
        end
        if characterLocallyActive(characterId, session.id) then
            return nil, foundation.error('CHARACTER_DELETE_BLOCKED',
                'The character is active in another local session.', { retryable = true })
        end
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            domainError = nil
            local locked = query([[SELECT `version`, `status`, `deleted_at` FROM `synex_characters`
                WHERE `id` = ? AND `user_id` = ? FOR UPDATE]], { characterId, session.userId })
            if not currentSession(session) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed while the character was locked.', {
                        retryable = true
                    })
                return false
            end
            local row = locked and locked[1]
            if not row or row.deleted_at ~= nil or row.status ~= 'active' then
                domainError = foundation.error('CHARACTER_NOT_FOUND', 'The character is no longer available.')
                return false
            end
            if tonumber(row.version) ~= tonumber(character.version) then
                domainError = foundation.error('CHARACTER_CONFLICT', 'The character changed during deletion preflight.', { retryable = true })
                return false
            end
            if type(sessionRepository.lockCharacterSessions) == 'function' then
                local own
                own, domainError = sessionRepository:lockCharacterSessions(query, session,
                    characterId, {
                        state = 'SELECTING_CHARACTER', characterId = nil,
                        version = session.persistedVersion,
                        source = session.persistedSource or session.source,
                        sourceGeneration = session.persistedSourceGeneration or session.sourceGeneration
                    }, function() return currentSession(session) ~= nil end,
                    'CHARACTER_DELETE_BLOCKED')
                if not own then return false end
            elseif not currentSession(session) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed before deletion persistence.', {
                        retryable = true
                    })
                return false
            end
            query([[INSERT INTO `synex_character_deletion_plans`
                (`id`, `character_id`, `requested_by_ref`, `state`, `plan_json`, `version`)
                VALUES (?, ?, ?, 'executing', ?, 1)]], { planId, characterId, 'user:' .. session.userId, planJson })
            if not currentSession(session) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed during deletion persistence.', {
                        retryable = true
                    })
                return false
            end
            local updated = query([[UPDATE `synex_characters` SET `status` = 'deleted', `deleted_at` = CURRENT_TIMESTAMP(6),
                `first_name` = 'Deleted', `last_name` = 'Character', `date_of_birth` = NULL,
                `metadata_json` = '{}', `version` = `version` + 1
                WHERE `id` = ? AND `user_id` = ? AND `version` = ? AND `deleted_at` IS NULL]],
                { characterId, session.userId, character.version })
            if not updated or tonumber(updated.affectedRows) ~= 1 then
                domainError = foundation.error('CHARACTER_CONFLICT', 'The character changed during deletion.', { retryable = true })
                return false
            end
            if not currentSession(session) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed during deletion persistence.', {
                        retryable = true
                    })
                return false
            end
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`, `context_json`)
                VALUES (?, ?, 'user', ?, 'character.delete', 'character', ?, ?)]],
                { foundation.nextId('audit'), foundation.nextId('trace'), session.userId, characterId, planJson })
            if not currentSession(session) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed before deletion commit.', { retryable = true })
                return false
            end
            return true
        end)
        if not committed then
            local failure = domainError or transactionError
            if failure and (failure.code == 'LEASE_LOST' or failure.code == 'SESSION_CONFLICT') then
                return nil, persistencePendingError(
                    'Character deletion lost caller session authority before commit.', failure)
            end
            return nil, failure
        end
        invalidateCharacter(characterId)
        if not currentSession(session) then
            logger:error('character deletion caller changed after durable commit', {
                planId = planId, characterId = characterId
            })
            metrics:increment('synex_character_delete_reconciliation_total', { result = 'deferred' })
            return { planId = planId, characterId = characterId, state = 'reconciling' }, nil
        end
        local result, reconciliationError = deletionReconciliation:process(
            planId, 1, plan, characterId)
        if result then return result, nil end
        logger:error('character deletion requires post-commit reconciliation', {
            planId = planId, code = reconciliationError and reconciliationError.code or 'UNAVAILABLE'
        })
        metrics:increment('synex_character_delete_reconciliation_total', { result = 'deferred' })
        return { planId = planId, characterId = characterId, state = 'reconciling' }, nil
    end

    function characters:select(sessionId, characterId)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.persistencePending or session.replacementClosePending
            or unloads:isCharacterPending(characterId) then
            return nil, persistencePendingError('The requested character is waiting for a durable session update.')
        end
        if session.state ~= 'SELECTING_CHARACTER' then return nil, foundation.error('INVALID_SESSION_STATE', 'The session is not selecting a character.') end
        if not currentSession(session) then
            return nil, sessionConflict('Character selection requires the current caller session generation.')
        end
        local character, characterError = characterRepository:getOwned(session.userId, characterId)
        if not character then return nil, characterError end
        if not currentSession(session) then
            return nil, sessionConflict('The caller session changed during character selection.')
        end
        cacheCharacter(character)
        if characterLocallyActive(character.id, session.id) then
            return nil, foundation.error('CHARACTER_ALREADY_ACTIVE',
                'The character is active in another session.', { retryable = true })
        end
        local loading, transitionError = updateCurrentSession(session, function(candidate)
            local _, err = transition(candidate, 'LOADING_CHARACTER')
            if err then error(err.message) end
        end)
        if not loading then return nil, transitionError end
        local prepared = {}
        local function rollbackPrepared(context)
            for index = #prepared, 1, -1 do
                local completed = prepared[index]
                if completed.participant.rollback then
                    local _, rollbackError = invokeParticipant(completed.participant,
                        completed.participant.rollback, completed.value, foundation.readonly(context))
                    if rollbackError then logger:error('character participant rollback failed', {
                        participant = completed.participant.name, code = rollbackError.code
                    }) end
                end
            end
        end
        local function restoreSelecting(expected)
            local current = currentSession(expected)
            if not current then return nil end
            if current.characterId == character.id then
                local unbound = players:unbindCharacter(current.id)
                if not unbound then return nil end
                current = unbound
            end
            return updateCurrentSession(current, function(candidate)
                candidate.state = 'SELECTING_CHARACTER'
                candidate.characterId = nil
                candidate.version = (candidate.version or 0) + 1
            end)
        end
        for _, participant in ipairs(orderedParticipants(false)) do
            local context = { session = foundation.copy(loading), character = foundation.copy(character), traceId = foundation.nextId('trace') }
            local preparedValue, participantError, rollbackValue = invokeParticipant(participant, participant.prepare,
                foundation.readonly(context))
            if not participantError then
                prepared[#prepared + 1] = { participant = participant, value = preparedValue }
            elseif participant.required and participant.rollback then
                prepared[#prepared + 1] = { participant = participant, value = rollbackValue }
            end
            if not currentSession(loading) then
                rollbackPrepared(context)
                return nil, sessionConflict(
                    'The caller session changed during character participant preparation.')
            end
            if participantError then
                logger:error('character load participant failed', {
                    participant = participant.name, sessionId = session.id, code = participantError.code
                })
                if participant.required then
                    rollbackPrepared(context)
                    restoreSelecting(loading)
                    return nil, type(participantError) == 'table' and participantError
                        or foundation.error('CHARACTER_LOAD_FAILED', 'A character load participant failed.', { retryable = true })
                end
            end
        end
        if characterLocallyActive(character.id, session.id) then
            rollbackPrepared({ session = loading, character = character })
            restoreSelecting(loading)
            return nil, foundation.error('CHARACTER_ALREADY_ACTIVE',
                'The character became active in another local session.', { retryable = true })
        end
        local bound, bindError = players:bindCharacter(session.id, character.id)
        if not bound then
            rollbackPrepared({ session = loading, character = character })
            restoreSelecting(loading)
            return nil, bindError
        end
        local active, activeError = updateCurrentSession(bound, function(candidate)
            local _, err = transition(candidate, 'ACTIVE')
            if err then error(err.message) end
        end)
        if not active then
            rollbackPrepared({ session = loading, character = character })
            restoreSelecting(bound)
            return nil, activeError
        end
        local persisted, persistenceError
        if type(sessionRepository.activateCharacter) == 'function' then
            persisted, persistenceError = sessionRepository:activateCharacter(
                active, character, function() return currentSession(active) ~= nil end)
        else
            persisted, persistenceError = sessionRepository:update(active, {
                state = 'SELECTING_CHARACTER', characterId = nil,
                version = active.persistedVersion,
                source = active.persistedSource or active.source,
                sourceGeneration = active.persistedSourceGeneration or active.sourceGeneration
            }, function() return currentSession(active) ~= nil end)
        end
        if not persisted then
            rollbackPrepared({ session = active, character = character })
            restoreSelecting(active)
            if persistenceError and (persistenceError.code == 'LEASE_LOST'
                or persistenceError.code == 'SESSION_CONFLICT') then
                return nil, persistencePendingError(
                    'Character selection lost session authority before commit.', persistenceError)
            end
            return nil, persistenceError
        end
        if not currentSession(active) then
            return nil, sessionConflict(
                'The caller session changed while character activation committed.')
        end
        local synchronized, synchronizationError = updateCurrentSession(active, function(candidate)
            candidate.persistedVersion = active.version
            candidate.persistedSource = active.source or active.persistedSource
            candidate.persistedSourceGeneration = active.sourceGeneration
        end)
        if not synchronized then return nil, synchronizationError end
        for _, completed in ipairs(prepared) do
            if completed.participant.commit then
                local _, commitError = invokeParticipant(completed.participant, completed.participant.commit,
                    completed.value, foundation.readonly({ session = synchronized, character = character }))
                if commitError then logger:error('optional character participant commit notification failed', {
                    participant = completed.participant.name, code = commitError.code
                }) end
                if not currentSession(synchronized) then
                    return nil, sessionConflict(
                        'The caller session changed during character activation notification.')
                end
            end
        end
        metrics:increment('synex_character_loads_total', { ok = true })
        return { session = synchronized, character = character }, nil
    end

    function characters:unload(sessionId, reason)
        return unloads:unload(sessionId, reason)
    end

    function characters:reconcileUnloads(limit)
        return unloads:reconcile(limit)
    end

    function characters:reconcileDeletions(limit)
        limit = limit == nil and 10 or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Deletion reconciliation limit must be 1 through 32.')
        end
        return deletionReconciliation:reconcile(limit)
    end

    function characters:invalidate(characterId)
        if characterId ~= nil and (type(characterId) ~= 'string' or #characterId < 1 or #characterId > 36) then
            return nil, foundation.error('INVALID_CHARACTER_ID', 'Character ID is invalid.')
        end
        if characterId then invalidateCharacter(characterId)
        else cache = {}; cacheSize = 0 end
        return true, nil
    end

    function characters:cacheSnapshot()
        local unloadSnapshot = unloads:snapshot()
        return {
            entries = cacheSize, maximum = cacheMaximum, ttlMs = cacheTtlMs,
            pendingSessionWrites = unloadSnapshot.count,
            pendingSessionWriteMaximum = unloadSnapshot.maximum
        }
    end

    return characters
end
