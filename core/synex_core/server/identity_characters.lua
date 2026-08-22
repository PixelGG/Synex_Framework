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
    local instanceId = assert(deps.instanceId, 'identity characters requires instance ID')

    local participants = {}
    local participantSequence = 0
    local participantCount = 0
    local participantMaximum = 128
    local cache = {}
    local cacheSize = 0
    local cacheMaximum = math.max(64, math.min(tonumber(deps.cacheMaximum) or 1024, 10000))
    local cacheTtlMs = math.max(1000, math.min(tonumber(deps.cacheTtlMs) or 30000, 300000))
    local pendingUnloads = {}
    local pendingUnloadCharacters = {}
    local pendingUnloadCount = 0
    local pendingUnloadMaximum = math.max(64, math.min(tonumber(deps.pendingUnloadMaximum) or 1024, 4096))
    local characters = {}
    local function clearPendingUnload(sessionId)
        local entry = pendingUnloads[sessionId]
        if not entry then return end
        if pendingUnloadCharacters[entry.characterId] == sessionId then
            pendingUnloadCharacters[entry.characterId] = nil
        end
        pendingUnloads[sessionId] = nil
        pendingUnloadCount = math.max(0, pendingUnloadCount - 1)
    end
    local function persistencePendingError(message, cause, details)
        details = details or {}
        details.cause = type(cause) == 'table' and cause.code or 'PERSISTENCE_RETRY'
        return foundation.error('SESSION_PERSISTENCE_PENDING', message,
            { retryable = true, details = details })
    end

    local function invokeParticipant(participant, handler, ...)
        local started = foundation.monotonicMs()
        local invoked, result, handlerError = invokeOwned(participant, handler, ...)
        local elapsed = math.max(0, foundation.monotonicMs() - started)
        if elapsed > participant.timeoutMs then
            return nil, foundation.error('PARTICIPANT_TIMEOUT', 'A character lifecycle participant exceeded its deadline.', {
                retryable = true, details = { timeoutMs = participant.timeoutMs, elapsedMs = elapsed }
            })
        end
        if not invoked then
            return nil, type(result) == 'table' and result
                or foundation.error('PARTICIPANT_FAILED', 'A character lifecycle participant failed.', { retryable = true })
        end
        if handlerError ~= nil then
            return nil, type(handlerError) == 'table' and handlerError
                or foundation.error('PARTICIPANT_FAILED', 'A character lifecycle participant returned an error.', { retryable = true })
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
            if a.priority == b.priority then return reverse and a.sequence > b.sequence or a.sequence < b.sequence end
            return reverse and a.priority < b.priority or a.priority > b.priority
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

    local function validateDeletionPlan(plan)
        if type(plan) ~= 'table' or plan.schema ~= 1 or type(plan.characterId) ~= 'string'
            or #plan.characterId < 1 or #plan.characterId > 36 or type(plan.actions) ~= 'table'
            or #plan.actions > participantMaximum then
            return nil, foundation.error('INVALID_DELETE_PLAN', 'The persisted character deletion plan is invalid.')
        end
        for index, action in ipairs(plan.actions) do
            if type(action) ~= 'table' or type(action.owner) ~= 'string' or #action.owner < 1 or #action.owner > 64
                or (action.participant ~= nil and (type(action.participant) ~= 'string'
                    or #action.participant < 1 or #action.participant > 64))
                or type(action.action) ~= 'string' then
                return nil, foundation.error('INVALID_DELETE_PLAN',
                    ('Character deletion action %d is invalid.'):format(index))
            end
        end
        return true, nil
    end

    local function markDeletionAttempt(planId)
        return database:update([[UPDATE `synex_character_deletion_plans`
            SET `state` = 'executing', `version` = LEAST(`version` + 1, 18446744073709551615)
            WHERE `id` = ? AND `state` IN ('pending', 'executing')]], { planId })
    end

    local function markDeletionFailed(planId, code)
        local normalized = type(code) == 'string' and code:upper():gsub('[^A-Z0-9_]', '_'):sub(1, 96)
            or 'INVALID_DELETE_PLAN'
        return database:update([[UPDATE `synex_character_deletion_plans`
            SET `state` = 'failed', `failure_code` = ?, `executed_at` = CURRENT_TIMESTAMP(6),
                `version` = LEAST(`version` + 1, 18446744073709551615)
            WHERE `id` = ? AND `state` IN ('pending', 'executing')]], { normalized, planId })
    end

    local function completeDeletion(planId)
        local affected, err = database:update([[UPDATE `synex_character_deletion_plans`
            SET `state` = 'completed', `failure_code` = NULL, `executed_at` = CURRENT_TIMESTAMP(6),
                `version` = LEAST(`version` + 1, 18446744073709551615)
            WHERE `id` = ? AND `state` IN ('pending', 'executing')]], { planId })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then
            return nil, foundation.error('DELETE_PLAN_CONFLICT', 'The character deletion plan changed during reconciliation.', {
                retryable = true
            })
        end
        return true, nil
    end

    local function processDeletionPlan(planId, plan)
        local valid, validationError = validateDeletionPlan(plan)
        if not valid then
            local _, markerError = markDeletionFailed(planId, validationError.code)
            return nil, markerError or validationError
        end
        local lease, leaseError = leases:acquire('character-delete:' .. planId,
            tostring(instanceId):sub(1, 72) .. ':character-delete', 30)
        if not lease then return nil, leaseError end
        local function release()
            local _, releaseError = leases:release(lease)
            if releaseError then logger:error('character deletion reconciliation lease release failed', {
                planId = planId, code = releaseError.code
            }) end
        end
        local attempted, attemptError = markDeletionAttempt(planId)
        if attemptError then release(); return nil, attemptError end
        if tonumber(attempted) ~= 1 then
            release()
            return nil, foundation.error('DELETE_PLAN_CONFLICT',
                'The character deletion plan is no longer eligible for reconciliation.', {
                    retryable = true
                })
        end
        for _, action in ipairs(plan.actions) do
            if action.notify ~= false then
                local participant = findParticipant(action)
                if not participant or type(participant.deleteCommit) ~= 'function' then
                    release()
                    return nil, foundation.error('DELETE_PARTICIPANT_UNAVAILABLE',
                        'A character deletion participant is unavailable.', { retryable = true })
                end
                local _, participantError = invokeParticipant(participant, participant.deleteCommit,
                    foundation.readonly({ planId = planId, plan = plan }))
                if participantError then release(); return nil, participantError end
            end
        end
        local completed, completionError = completeDeletion(planId)
        release()
        if not completed then return nil, completionError end
        local _, eventError = messaging.events:publish(coreResource, owners:epoch(coreResource),
            'synex.characters.deleted', { characterId = plan.characterId, planId = planId })
        if eventError then logger:error('character deletion event publication failed', {
            planId = planId, code = eventError.code
        }) end
        return { planId = planId, characterId = plan.characterId, state = 'completed' }, nil
    end

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
        local candidate, hookError = messaging.hooks:run(deps.coreResource, owners:epoch(deps.coreResource),
            'synex.characters.before_create', input, { sessionId = sessionId, userId = session.userId })
        if not candidate then return nil, hookError end
        local character, createError = characterRepository:create(session.userId, candidate)
        if not character then return nil, createError end
        cacheCharacter(character)
        messaging.events:publish(coreResource, owners:epoch(coreResource), 'synex.characters.created', {
            characterId = character.id, userId = session.userId, slot = character.slot
        })
        return character, nil
    end

    function characters:delete(sessionId, characterId)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.persistencePending or session.replacementClosePending then
            return nil, persistencePendingError('The session is waiting for a durable state update.')
        end
        if session.state ~= 'SELECTING_CHARACTER' then return nil, foundation.error('INVALID_SESSION_STATE', 'An active character cannot be deleted.') end
        local character, characterError = characterRepository:getOwned(session.userId, characterId)
        if not character then return nil, characterError end
        local plan = { schema = 1, characterId = characterId, actions = {} }
        local ordered = orderedParticipants(false)
        for _, participant in ipairs(ordered) do
            if participant.deletePreflight then
                local result, participantError = invokeParticipant(participant, participant.deletePreflight,
                    foundation.readonly({ session = session, character = character }))
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
                local encodedMetadata = not participantError and result.metadata and platform.jsonEncode(result.metadata) or nil
                if encodedMetadata and #encodedMetadata > 4096 then return nil, foundation.error('INVALID_DELETE_PLAN', 'Deletion plan metadata is too large.') end
                if not participantError then plan.actions[#plan.actions + 1] = {
                    owner = participant.owner, participant = participant.name, action = result.action,
                    metadata = result.metadata, notify = type(participant.deleteCommit) == 'function'
                } end
            end
        end
        local planValid, planValidationError = validateDeletionPlan(plan)
        if not planValid then return nil, planValidationError end
        local planId = foundation.nextId('del')
        local planJson = platform.jsonEncode(plan)
        if type(planJson) ~= 'string' or #planJson > 65536 then
            return nil, foundation.error('INVALID_DELETE_PLAN', 'The character deletion plan is too large.')
        end
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            local locked = query([[SELECT `version`, `status`, `deleted_at` FROM `synex_characters`
                WHERE `id` = ? AND `user_id` = ? FOR UPDATE]], { characterId, session.userId })
            local row = locked and locked[1]
            if not row or row.deleted_at ~= nil or row.status ~= 'active' then
                domainError = foundation.error('CHARACTER_NOT_FOUND', 'The character is no longer available.')
                return false
            end
            if tonumber(row.version) ~= tonumber(character.version) then
                domainError = foundation.error('CHARACTER_CONFLICT', 'The character changed during deletion preflight.', { retryable = true })
                return false
            end
            query([[INSERT INTO `synex_character_deletion_plans`
                (`id`, `character_id`, `requested_by_ref`, `state`, `plan_json`, `version`)
                VALUES (?, ?, ?, 'executing', ?, 1)]], { planId, characterId, 'user:' .. session.userId, planJson })
            local updated = query([[UPDATE `synex_characters` SET `status` = 'deleted', `deleted_at` = CURRENT_TIMESTAMP(6),
                `first_name` = 'Deleted', `last_name` = 'Character', `date_of_birth` = NULL,
                `metadata_json` = '{}', `version` = `version` + 1
                WHERE `id` = ? AND `user_id` = ? AND `version` = ? AND `deleted_at` IS NULL]],
                { characterId, session.userId, character.version })
            if not updated or tonumber(updated.affectedRows) ~= 1 then
                domainError = foundation.error('CHARACTER_CONFLICT', 'The character changed during deletion.', { retryable = true })
                return false
            end
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`, `context_json`)
                VALUES (?, ?, 'user', ?, 'character.delete', 'character', ?, ?)]],
                { foundation.nextId('audit'), foundation.nextId('trace'), session.userId, characterId, planJson })
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        invalidateCharacter(characterId)
        local result, reconciliationError = processDeletionPlan(planId, plan)
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
        if session.persistencePending or session.replacementClosePending or pendingUnloadCharacters[characterId] ~= nil then
            return nil, persistencePendingError('The requested character is waiting for a durable session update.')
        end
        if session.state ~= 'SELECTING_CHARACTER' then return nil, foundation.error('INVALID_SESSION_STATE', 'The session is not selecting a character.') end
        local character, characterError = characterRepository:getOwned(session.userId, characterId)
        if not character then return nil, characterError end
        cacheCharacter(character)
        local duplicate = players:sessionsByUser(session.userId)
        for _, other in ipairs(duplicate) do
            if other.id ~= session.id and other.characterId == character.id then
                return nil, foundation.error('CHARACTER_ALREADY_ACTIVE', 'The character is active in another session.')
            end
        end
        local loading, transitionError = players:updateSession(session.id, function(candidate)
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
        for _, participant in ipairs(orderedParticipants(false)) do
            local context = { session = foundation.copy(loading), character = foundation.copy(character), traceId = foundation.nextId('trace') }
            local preparedValue, participantError = invokeParticipant(participant, participant.prepare,
                foundation.readonly(context))
            if participantError then
                logger:error('character load participant failed', {
                    participant = participant.name, sessionId = session.id, code = participantError.code
                })
                if participant.required then
                    rollbackPrepared(context)
                    players:updateSession(session.id, function(candidate) candidate.state = 'SELECTING_CHARACTER'; candidate.version = candidate.version + 1 end)
                    return nil, type(participantError) == 'table' and participantError
                        or foundation.error('CHARACTER_LOAD_FAILED', 'A character load participant failed.', { retryable = true })
                end
            else
                prepared[#prepared + 1] = { participant = participant, value = preparedValue }
            end
        end
        local bound, bindError = players:bindCharacter(session.id, character.id)
        if not bound then
            rollbackPrepared({ session = loading, character = character })
            players:updateSession(session.id, function(candidate) candidate.state = 'SELECTING_CHARACTER'; candidate.version = candidate.version + 1 end)
            return nil, bindError
        end
        local active, activeError = players:updateSession(session.id, function(candidate)
            candidate.characterId = character.id
            local _, err = transition(candidate, 'ACTIVE')
            if err then error(err.message) end
        end)
        if not active then
            players:unbindCharacter(session.id)
            rollbackPrepared({ session = loading, character = character })
            players:updateSession(session.id, function(candidate) candidate.state = 'SELECTING_CHARACTER'; candidate.version = candidate.version + 1 end)
            return nil, activeError
        end
        local persisted, persistenceError = sessionRepository:update(active)
        if not persisted then
            players:unbindCharacter(session.id)
            rollbackPrepared({ session = active, character = character })
            players:updateSession(session.id, function(candidate)
                candidate.state = 'SELECTING_CHARACTER'
                candidate.characterId = nil
                candidate.version = candidate.version + 1
            end)
            return nil, persistenceError
        end
        players:updateSession(session.id, function(candidate) candidate.persistedVersion = active.version end)
        for _, completed in ipairs(prepared) do
            if completed.participant.commit then
                local _, commitError = invokeParticipant(completed.participant, completed.participant.commit,
                    completed.value, foundation.readonly({ session = active, character = character }))
                if commitError then logger:error('optional character participant commit notification failed', {
                    participant = completed.participant.name, code = commitError.code
                }) end
            end
        end
        metrics:increment('synex_character_loads_total', { ok = true })
        return { session = players:getSession(session.id), character = character }, nil
    end

    function characters:unload(sessionId, reason)
        local session = players:getSession(sessionId)
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.persistencePending or session.replacementClosePending then
            return nil, persistencePendingError('The session is waiting for a durable state update.')
        end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string' then
            return nil, foundation.error('INVALID_SESSION_STATE', 'The session has no active character.')
        end
        if pendingUnloadCount >= pendingUnloadMaximum then
            return nil, persistencePendingError('Character unload persistence is at capacity.')
        end
        local unloading, err = players:updateSession(session.id, function(candidate) transition(candidate, 'UNLOADING_CHARACTER') end)
        if not unloading then return nil, err end
        local requiredFailure = nil
        for _, participant in ipairs(orderedParticipants(true)) do
            if participant.unload then
                local _, participantError = invokeParticipant(participant, participant.unload,
                    foundation.readonly({ session = unloading, reason = reason }))
                if participantError then
                    logger:error('character unload participant failed', {
                        participant = participant.name, required = participant.required, code = participantError.code
                    })
                    if participant.required and not requiredFailure then requiredFailure = {
                        participant = participant.name, error = participantError
                    } end
                end
            end
        end
        if requiredFailure then
            local restored, restoreError = players:updateSession(session.id, function(candidate)
                candidate.state = 'ACTIVE'
                candidate.version = (candidate.version or 0) + 1
            end)
            if not restored then
                logger:error('character unload state restoration failed', {
                    sessionId = session.id,
                    participant = requiredFailure.participant,
                    code = restoreError and restoreError.code or 'UNKNOWN'
                })
            end
            return nil, foundation.error('CHARACTER_UNLOAD_FAILED',
                ('Required unload participant %s failed.'):format(requiredFailure.participant), {
                    retryable = true,
                    details = { cause = requiredFailure.error.code, stateRestored = restored ~= nil }
                })
        end
        local unbound, unbindError = players:unbindCharacter(session.id)
        if not unbound then return nil, unbindError end
        local selected, selectedError = players:updateSession(session.id, function(candidate)
            candidate.characterId = nil
            transition(candidate, 'SELECTING_CHARACTER')
        end)
        if not selected then
            players:bindCharacter(session.id, session.characterId)
            players:updateSession(session.id, function(candidate) candidate.state = 'ACTIVE' end)
            return nil, selectedError
        end
        local persisted, persistenceError = sessionRepository:update(selected)
        if not persisted then
            local marked, markError = players:updateSession(session.id, function(candidate)
                candidate.persistencePending = true
            end)
            if marked then
                pendingUnloads[session.id] = {
                    session = foundation.copy(selected), characterId = session.characterId,
                    source = selected.source, sourceGeneration = selected.sourceGeneration,
                    attempts = 0, lastError = persistenceError and persistenceError.code or 'DATABASE_ERROR'
                }
                pendingUnloadCharacters[session.characterId] = session.id
                pendingUnloadCount = pendingUnloadCount + 1
                metrics:increment('synex_character_unload_reconciliation_total', { result = 'queued' })
            else
                logger:error('character unload persistence marker failed', {
                    sessionId = session.id, code = markError and markError.code or 'UNKNOWN'
                })
            end
            return nil, persistencePendingError('The character was unloaded locally and is awaiting persistence.',
                persistenceError, { queued = marked ~= nil, state = 'SELECTING_CHARACTER' })
        end
        local synchronized, synchronizationError = players:updateSession(session.id, function(candidate)
            candidate.persistedVersion = selected.version
            candidate.persistencePending = nil
        end)
        if not synchronized then return nil, synchronizationError end
        return synchronized, nil
    end

    function characters:reconcileUnloads(limit)
        limit = limit == nil and 10 or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Unload reconciliation limit must be 1 through 32.')
        end
        local sessionIds = {}
        for sessionId in pairs(pendingUnloads) do sessionIds[#sessionIds + 1] = sessionId end
        table.sort(sessionIds)
        local report = { examined = 0, completed = 0, deferred = 0, abandoned = 0 }
        for index = 1, math.min(limit, #sessionIds) do
            local sessionId = sessionIds[index]
            local entry = pendingUnloads[sessionId]
            report.examined = report.examined + 1
            local function isCurrent(candidate)
                return candidate ~= nil and candidate.persistencePending == true
                    and candidate.state == 'SELECTING_CHARACTER' and candidate.characterId == nil
                    and candidate.version == entry.session.version and candidate.source == entry.source
                    and candidate.sourceGeneration == entry.sourceGeneration
            end
            if not isCurrent(players:getSession(sessionId)) then
                clearPendingUnload(sessionId)
                report.abandoned = report.abandoned + 1
                metrics:increment('synex_character_unload_reconciliation_total', { result = 'abandoned' })
            else
                entry.attempts = entry.attempts + 1
                local persisted, persistenceError = sessionRepository:update(entry.session)
                local durable = persisted ~= nil
                if not durable and persistenceError and persistenceError.code == 'SESSION_CONFLICT'
                    and type(sessionRepository.getState) == 'function' then
                    local stored, readError = sessionRepository:getState(sessionId)
                    durable = stored ~= nil and stored.state == 'SELECTING_CHARACTER'
                        and stored.characterId == nil and stored.version == entry.session.version
                    if readError then persistenceError = readError end
                end
                if durable and isCurrent(players:getSession(sessionId)) then
                    local synchronized, synchronizationError = players:updateSession(sessionId, function(candidate)
                        candidate.persistedVersion = entry.session.version
                        candidate.persistencePending = nil
                    end)
                    if synchronized then
                        clearPendingUnload(sessionId)
                        report.completed = report.completed + 1
                        metrics:increment('synex_character_unload_reconciliation_total', { result = 'completed' })
                    else
                        entry.lastError = synchronizationError and synchronizationError.code or 'SESSION_UPDATE_FAILED'
                        report.deferred = report.deferred + 1
                    end
                elseif durable then
                    clearPendingUnload(sessionId)
                    report.abandoned = report.abandoned + 1
                    metrics:increment('synex_character_unload_reconciliation_total', { result = 'abandoned' })
                else
                    entry.lastError = persistenceError and persistenceError.code or 'DATABASE_ERROR'
                    report.deferred = report.deferred + 1
                    metrics:increment('synex_character_unload_reconciliation_total', { result = 'deferred' })
                end
            end
        end
        report.pending = pendingUnloadCount
        return report, nil
    end

    function characters:reconcileDeletions(limit)
        limit = limit == nil and 10 or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Deletion reconciliation limit must be 1 through 32.')
        end
        local rows, queryError = database:query([[SELECT `id`, `plan_json`
            FROM `synex_character_deletion_plans` WHERE `state` IN ('pending', 'executing')
            ORDER BY `created_at`, `id` LIMIT ?]], { limit })
        if not rows then return nil, queryError end
        local report = { examined = #rows, completed = 0, deferred = 0, invalid = 0 }
        for _, row in ipairs(rows) do
            local decodedOk, plan = pcall(platform.jsonDecode, row.plan_json)
            if not decodedOk or type(plan) ~= 'table' then
                markDeletionFailed(row.id, 'INVALID_DELETE_PLAN')
                report.invalid = report.invalid + 1
            else
                local completed, reconciliationError = processDeletionPlan(row.id, plan)
                if completed then
                    report.completed = report.completed + 1
                    metrics:increment('synex_character_delete_reconciliation_total', { result = 'completed' })
                else
                    report.deferred = report.deferred + 1
                    metrics:increment('synex_character_delete_reconciliation_total', {
                        result = reconciliationError and reconciliationError.code == 'DELETE_PARTICIPANT_UNAVAILABLE'
                            and 'participant_unavailable' or 'error'
                    })
                end
            end
        end
        return report, nil
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
        return {
            entries = cacheSize, maximum = cacheMaximum, ttlMs = cacheTtlMs,
            pendingSessionWrites = pendingUnloadCount, pendingSessionWriteMaximum = pendingUnloadMaximum
        }
    end

    return characters
end
