SynexInteractActorLocks = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

local allowedChannels = {
    ['actor.movement'] = true, ['actor.hands'] = true, ['actor.weapon'] = true,
    ['actor.fullbody'] = true, ['actor.camera'] = true, ['actor.input'] = true,
    ['ui.primary'] = true,
}

function SynexInteractActorLocks.create()
    local locks, count = {}, 0
    local runtime = {}

    local function key(actorKey, channel) return actorKey .. '#' .. channel end

    function runtime.claim(actorKey, channels, sessionId, executionId)
        if not Validation.actorKey(actorKey) or not Validation.token(sessionId)
            or not Validation.token(executionId) then
            return Validation.failure('INTERACT_LOCK_INVALID', 'Actor lock identity is invalid.')
        end
        local normalized = Validation.array(channels or {}, Limits.maximumLocksPerGraph,
            function(channel) return allowedChannels[channel] == true end)
        if not normalized then
            return Validation.failure('INTERACT_LOCK_INVALID', 'Actor lock channels are invalid.')
        end
        table.sort(normalized)
        local additions = 0
        for index, channel in ipairs(normalized) do
            if index > 1 and normalized[index - 1] == channel then
                return Validation.failure('INTERACT_LOCK_INVALID', 'Actor lock channels are duplicated.')
            end
            local current = locks[key(actorKey, channel)]
            if current and (current.sessionId ~= sessionId or current.executionId ~= executionId) then
                return Validation.failure('INTERACT_ACTOR_BUSY', 'The actor is already using this control channel.')
            end
            if not current then additions = additions + 1 end
        end
        if count + additions > Limits.maximumActorLocks then
            return Validation.failure('INTERACT_ACTOR_BUSY', 'Actor lock capacity is exhausted.')
        end
        for _, channel in ipairs(normalized) do
            local id = key(actorKey, channel)
            if not locks[id] then
                locks[id] = { actorKey = actorKey, channel = channel,
                    sessionId = sessionId, executionId = executionId }
                count = count + 1
            end
        end
        return { actorKey = actorKey, channels = Validation.copy(normalized),
            sessionId = sessionId, executionId = executionId }, nil
    end

    function runtime.release(sessionId, executionId, actorKey)
        local ids = {}
        for id, record in pairs(locks) do
            if record.sessionId == sessionId
                and (executionId == nil or record.executionId == executionId)
                and (actorKey == nil or record.actorKey == actorKey) then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do locks[id] = nil; count = count - 1 end
        return #ids
    end

    function runtime.owns(actorKey, channels, sessionId, executionId)
        if not Validation.actorKey(actorKey) or not Validation.token(sessionId)
            or not Validation.token(executionId) then
            return Validation.failure('INTERACT_LOCK_INVALID', 'Actor lock identity is invalid.')
        end
        local normalized = Validation.array(channels or {}, Limits.maximumLocksPerGraph,
            function(channel) return allowedChannels[channel] == true end)
        if not normalized then
            return Validation.failure('INTERACT_LOCK_INVALID', 'Actor lock channels are invalid.')
        end
        for _, channel in ipairs(normalized) do
            local record = locks[key(actorKey, channel)]
            if not record or record.sessionId ~= sessionId
                or record.executionId ~= executionId then
                return Validation.failure('INTERACT_LEASE_STALE',
                    'The interaction actor lock fence changed.')
            end
        end
        return true, nil
    end

    function runtime.cleanupActor(actorKey)
        local ids = {}
        for id, record in pairs(locks) do if record.actorKey == actorKey then ids[#ids + 1] = id end end
        for _, id in ipairs(ids) do locks[id] = nil; count = count - 1 end
        return #ids
    end

    function runtime.snapshot() return { active = count, capacity = Limits.maximumActorLocks } end
    return runtime
end
