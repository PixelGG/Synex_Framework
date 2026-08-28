SynexWorldDoorEngine = {}

local DoorEngine = SynexWorldDoorEngine
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local MAXIMUM_SAFE_INTEGER = 9007199254740991
local states = { LOCKED = true, UNLOCKED = true, DISABLED = true }
local actorTypes = {
    resource = true, system = true, user = true, character = true, entity = true,
}

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function validReference(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function doorFailure(code, message, retryable, details)
    return Validation.failure(code, message, retryable, details)
end

function DoorEngine.create(options)
    options = type(options) == 'table' and options or {}
    local repository, resolveDefinition = options.repository, options.resolveDefinition
    local newId, nowIso, onChanged = options.newId, options.nowIso, options.onChanged
    local scheduler, onSchedulerError = options.scheduler, options.onSchedulerError
    local schedulerCaller = options.schedulerCaller or 'synex_world'
    local schemaVersion = options.schemaVersion or 1
    if type(repository) ~= 'table' or not callable(repository.getDoorState)
        or not callable(repository.setDoorState) or not callable(resolveDefinition)
        or not callable(newId) or not callable(nowIso)
        or type(scheduler) ~= 'table' or not callable(scheduler.after)
        or not callable(scheduler.cancel)
        or onChanged ~= nil and not callable(onChanged)
        or onSchedulerError ~= nil and not callable(onSchedulerError)
        or select(1, Validation.resourceName(schedulerCaller)) == nil
        or not Validation.isInteger(schemaVersion, 1, 2147483647) then
        error('world door engine dependencies are incomplete', 0)
    end
    local runtimeState, relockSchedules, persistentCache = {}, {}, {}
    local cacheHead, cacheTail, cacheCount = nil, nil, 0
    local engine = {}

    local function unlinkCache(node)
        if node.previous then node.previous.next = node.next else cacheHead = node.next end
        if node.next then node.next.previous = node.previous else cacheTail = node.previous end
        persistentCache[node.key], cacheCount = nil, cacheCount - 1
    end

    local function cachePut(key, record)
        local previous = persistentCache[key]
        if previous and previous.present and record ~= nil
            and type(previous.record) == 'table'
            and Validation.isInteger(previous.record.version, 0, MAXIMUM_SAFE_INTEGER)
            and Validation.isInteger(record.version, 0, MAXIMUM_SAFE_INTEGER)
            and record.version < previous.record.version then
            return false
        end
        if previous then unlinkCache(previous) end
        local node = { key = key, present = record ~= nil,
            record = record and Validation.copy(record) or nil, previous = cacheTail }
        if cacheTail then cacheTail.next = node else cacheHead = node end
        cacheTail, persistentCache[key], cacheCount = node, node, cacheCount + 1
        while cacheCount > Limits.maximumPersistentDoorCacheEntries do
            unlinkCache(cacheHead)
        end
        return true
    end

    local function reportSchedulerError(operation, key, operationError)
        if not onSchedulerError then return end
        local code = type(operationError) == 'table' and operationError.code or nil
        if type(code) ~= 'string' or #code < 1 or #code > 64 then
            code = operation == 'schedule' and 'SCHEDULER_UNAVAILABLE'
                or operation == 'cancel' and 'SCHEDULER_CANCEL_FAILED'
                or 'DOOR_AUTO_RELOCK_FAILED'
        end
        pcall(onSchedulerError, { operation = operation, key = key, code = code })
    end

    local function cancelRelock(key)
        local entry = relockSchedules[key]
        if not entry then return false end
        relockSchedules[key] = nil
        local called, cancelled, cancelError = pcall(scheduler.cancel, entry.token)
        if not called or cancelled ~= true then
            reportSchedulerError('cancel', key, called and cancelError or cancelled)
        end
        return true
    end

    local function resolve(key)
        local normalized, keyError = Validation.namespacedKey(key)
        if not normalized then return nil, keyError end
        local called, definition, resolveError = pcall(resolveDefinition, normalized)
        if not called then
            return doorFailure('DOOR_NOT_FOUND', 'World door definition is unavailable.', true)
        end
        if not definition then
            if type(resolveError) == 'table' and resolveError.code ~= 'WORLD_NOT_FOUND' then
                return nil, resolveError
            end
            return doorFailure('DOOR_NOT_FOUND', 'World door does not exist.')
        end
        if type(definition) ~= 'table' or definition.kind ~= 'door'
            or definition.key ~= normalized or not states[definition.defaultState]
            or type(definition.persistent) ~= 'boolean'
            or not Validation.isInteger(definition.revision, 1, MAXIMUM_SAFE_INTEGER)
            or definition.autoRelockSeconds ~= nil
                and not Validation.isInteger(definition.autoRelockSeconds, 1, 86400)
            or not Validation.isDenseArray(definition.leaves, 8) or #definition.leaves < 1 then
            return doorFailure('WORLD_REFERENCE_INVALID',
                'World door definition is invalid or stale.')
        end
        return definition
    end

    local function provenanceFor(request, context)
        if type(context) ~= 'table' then
            return doorFailure('INVALID_ARGUMENT', 'World door mutation caller context is required.')
        end
        local caller, callerError = Validation.resourceName(context.caller)
        if not caller then return nil, callerError end
        if not validReference(context.traceId, 8, 64) then
            return doorFailure('INVALID_ARGUMENT', 'World door mutation trace is invalid.')
        end
        local actorType, actorRef = 'resource', caller
        if context.actor ~= nil then
            if not Validation.exactObject(context.actor, { type = true, ref = true }) then
                return doorFailure('INVALID_ARGUMENT', 'World door mutation actor is invalid.')
            end
            actorType, actorRef = context.actor.type, context.actor.ref
        elseif context.principalKind ~= nil or context.principalRef ~= nil then
            actorType, actorRef = context.principalKind, context.principalRef
        end
        if not actorTypes[actorType] or not validReference(actorRef, 1, 128)
            or actorType == 'resource' and actorRef ~= caller
            or actorType == 'system' and (caller ~= 'synex_core' or actorRef ~= caller) then
            return doorFailure('INVALID_ARGUMENT', 'World door actor provenance is invalid.')
        end
        local reason, reasonError = Validation.reasonCode(request.reasonCode)
        if not reason then return nil, reasonError end
        local called, timestamp = pcall(nowIso)
        if not called or type(timestamp) ~= 'string' or #timestamp < 20 or #timestamp > 32 then
            return doorFailure('CORE_UNAVAILABLE', 'World door timestamp is unavailable.', true)
        end
        return {
            actorType = actorType,
            actorRef = actorRef,
            sourceResource = caller,
            reasonCode = reason,
            traceId = context.traceId,
            timestamp = timestamp,
        }
    end

    local function nextEventId()
        local called, value = pcall(newId, 'world_event')
        if not called or not validReference(value, 8, 36) then
            return doorFailure('CORE_UNAVAILABLE', 'World door event identifier is unavailable.', true)
        end
        return value
    end

    local function defaultSnapshot(definition)
        return {
            key = definition.key,
            schemaVersion = schemaVersion,
            definitionRevision = definition.revision,
            state = definition.defaultState,
            version = 0,
            persistent = definition.persistent,
            defaulted = true,
        }
    end

    local function scheduleRelock(definition, result, traceId)
        if result.replayed == true then return true end
        cancelRelock(definition.key)
        if result.state ~= 'UNLOCKED' or definition.autoRelockSeconds == nil then return true end

        local entry = {
            key = definition.key,
            definitionRevision = definition.revision,
            autoRelockSeconds = definition.autoRelockSeconds,
            expectedVersion = result.version,
            traceId = traceId,
        }
        local function relock()
            if relockSchedules[entry.key] ~= entry then return false end
            relockSchedules[entry.key] = nil

            local active, activeError = resolve(entry.key)
            if not active or active.revision ~= entry.definitionRevision
                or active.autoRelockSeconds ~= entry.autoRelockSeconds then
                if activeError and activeError.code ~= 'DOOR_NOT_FOUND' then
                    reportSchedulerError('relock', entry.key, activeError)
                end
                return false
            end
            local current, currentError = engine:get({ key = entry.key })
            if not current then
                reportSchedulerError('relock', entry.key, currentError)
                return false
            end
            if current.state ~= 'UNLOCKED' or current.version ~= entry.expectedVersion then
                return false
            end

            local called, idempotencyKey, idError = pcall(newId, 'world_relock')
            if not called or not validReference(idempotencyKey, 8, 36) then
                reportSchedulerError('relock', entry.key, called and idError or idempotencyKey)
                return false
            end
            local changed, changeError = engine:setState({
                key = entry.key,
                expectedDefinitionRevision = entry.definitionRevision,
                state = 'LOCKED',
                expectedVersion = entry.expectedVersion,
                idempotencyKey = idempotencyKey,
                reasonCode = 'door.auto_relock',
            }, {
                caller = schedulerCaller,
                traceId = entry.traceId,
            })
            if not changed and (type(changeError) ~= 'table'
                or changeError.code ~= 'CONCURRENT_MODIFICATION') then
                reportSchedulerError('relock', entry.key, changeError)
            end
            return changed ~= nil
        end
        local called, token, scheduleError = pcall(scheduler.after,
            definition.autoRelockSeconds * 1000, relock,
            { name = 'synex_world.door_auto_relock' })
        if not called or token == nil then
            reportSchedulerError('schedule', definition.key,
                called and scheduleError or token)
            return false
        end
        entry.token = token
        relockSchedules[definition.key] = entry
        return true
    end

    function engine:get(request)
        if not Validation.exactObject(request or {}, { key = true }) then
            return doorFailure('INVALID_ARGUMENT', 'World door lookup request is invalid.')
        end
        local definition, definitionError = resolve(request.key)
        if not definition then return nil, definitionError end
        local record, readError
        if definition.persistent then
            local cached = persistentCache[definition.key]
            if cached then
                record = cached.present and Validation.copy(cached.record) or nil
            else
                record, readError = repository:getDoorState(definition.key)
                if not readError then cachePut(definition.key, record) end
            end
        else
            record = runtimeState[definition.key]
        end
        if not record then
            if readError then return nil, readError end
            return defaultSnapshot(definition)
        end
        if record.schemaVersion ~= schemaVersion or not states[record.state] then
            return doorFailure('STATE_SCHEMA_MISMATCH',
                'Persisted door state is incompatible with the active World schema.')
        end
        local snapshot = Validation.copy(record)
        snapshot.definitionRevision = definition.revision
        return snapshot
    end

    function engine:setState(request, context)
        if not Validation.exactObject(request or {}, {
                key = true, state = true, expectedVersion = true,
                idempotencyKey = true, reasonCode = true,
                expectedDefinitionRevision = true,
            }) or not Validation.isInteger(request.expectedVersion, 0, MAXIMUM_SAFE_INTEGER)
            or request.expectedDefinitionRevision ~= nil
                and not Validation.isInteger(request.expectedDefinitionRevision, 1, 2147483647)
            or not validReference(request.idempotencyKey, 8, 36) then
            return doorFailure('INVALID_ARGUMENT', 'World door mutation request is invalid.')
        end
        if not states[request.state] then
            return doorFailure('DOOR_STATE_INVALID', 'World door state is invalid.')
        end
        local definition, definitionError = resolve(request.key)
        if not definition then return nil, definitionError end
        if request.expectedDefinitionRevision ~= nil
            and definition.revision ~= request.expectedDefinitionRevision then
            return doorFailure('STALE_WORLD_REF',
                'World door definition changed before the mutation was applied.', true)
        end
        local provenance, provenanceError = provenanceFor(request, context)
        if not provenance then return nil, provenanceError end
        local eventId, idError = nextEventId()
        if not eventId then return nil, idError end
        if definition.persistent then
            local result, persistError = repository:setDoorState({
                doorKey = definition.key,
                schemaVersion = schemaVersion,
                state = request.state,
                expectedVersion = request.expectedVersion,
                idempotencyKey = request.idempotencyKey,
                eventId = eventId,
                provenance = provenance,
            })
            if not result then return nil, persistError end
            result.definitionRevision = definition.revision
            cachePut(definition.key, result)
            if result.replayed ~= true then
                scheduleRelock(definition, result, provenance.traceId)
            end
            if onChanged and result.replayed ~= true then
                pcall(onChanged, Validation.copy(result))
            end
            return result
        end

        local current = runtimeState[definition.key]
        local currentVersion = current and current.version or 0
        if current and current.schemaVersion ~= schemaVersion then
            return doorFailure('STATE_SCHEMA_MISMATCH',
                'Runtime door state is incompatible with the active World schema.')
        end
        if currentVersion ~= request.expectedVersion then
            return doorFailure('CONCURRENT_MODIFICATION',
                'World door state changed before the mutation could be applied.', true,
                { expectedVersion = request.expectedVersion, currentVersion = currentVersion })
        end
        local record = {
            key = definition.key,
            schemaVersion = schemaVersion,
            definitionRevision = definition.revision,
            state = request.state,
            version = currentVersion + 1,
            persistent = false,
            defaulted = false,
            eventId = eventId,
            provenance = {
                actor = { type = provenance.actorType, ref = provenance.actorRef },
                sourceResource = provenance.sourceResource,
                reasonCode = provenance.reasonCode,
                traceId = provenance.traceId,
                timestamp = provenance.timestamp,
            },
        }
        runtimeState[definition.key] = Validation.copy(record)
        scheduleRelock(definition, record, provenance.traceId)
        if onChanged then pcall(onChanged, Validation.copy(record)) end
        return record
    end

    function engine:purgeRuntime(doorKey)
        local normalized, keyError = Validation.namespacedKey(doorKey)
        if not normalized then return nil, keyError end
        cancelRelock(normalized)
        local removed = runtimeState[normalized] ~= nil
        runtimeState[normalized] = nil
        local cached = persistentCache[normalized]
        if cached then unlinkCache(cached) end
        return { removed = removed and 1 or 0, persistentPreserved = true }
    end

    return engine
end
