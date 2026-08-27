SynexEntityCheckpointGuard = {}

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= minimum and value <= maximum
end

function SynexEntityCheckpointGuard.create(options)
    assert(type(options) == 'table', 'entity checkpoint-guard options are required')
    local debounceMs = assert(options.debounceMs, 'checkpoint debounce is required')
    local getGameTimer = assert(options.getGameTimer, 'checkpoint clock is required')
    local maximumEntries = options.maximumEntries or 4096
    assert(integer(debounceMs, 1000, 60000), 'checkpoint debounce is invalid')
    assert(integer(maximumEntries, 1, 20000), 'checkpoint guard capacity is invalid')
    local entries, count = {}, 0
    local guard = {}

    local function elapsed(now, previous)
        local delta = now - previous
        if delta < 0 then delta = delta + 4294967296 end
        return math.max(0, delta)
    end

    local function limited(context)
        return nil, {
            code = 'RATE_LIMITED',
            message = 'The entity checkpoint debounce is active',
            retryable = true,
            traceId = type(context) == 'table' and context.traceId or nil,
        }
    end

    function guard.check(entityId, generation, context)
        if type(entityId) ~= 'string' or #entityId < 8 or #entityId > 64
            or not integer(generation, 1, 9007199254740991) then
            return nil, {
                code = 'INVALID_ARGUMENT',
                message = 'The checkpoint EntityRef is invalid',
                retryable = false,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        local current = entries[entityId]
        local now = tonumber(getGameTimer())
        if not integer(now, 0, 4294967295) then
            return nil, {
                code = 'UNAVAILABLE', message = 'The checkpoint clock is unavailable',
                retryable = true,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        if current and current.generation == generation
            and elapsed(now, current.committedAt) < debounceMs then
            return limited(context)
        end
        if not current and count >= maximumEntries then return limited(context) end
        return { entityId = entityId, generation = generation, observedAt = now }
    end

    function guard.commit(ticket)
        if type(ticket) ~= 'table' or type(ticket.entityId) ~= 'string'
            or not integer(ticket.generation, 1, 9007199254740991)
            or not integer(ticket.observedAt, 0, 4294967295) then return false end
        if entries[ticket.entityId] == nil then count = count + 1 end
        entries[ticket.entityId] = {
            committedAt = ticket.observedAt,
            generation = ticket.generation,
        }
        return true
    end

    function guard.clear(entityId, generation)
        local current = entries[entityId]
        if not current or generation ~= nil and current.generation ~= generation then return false end
        entries[entityId] = nil
        count = math.max(0, count - 1)
        return true
    end

    function guard.size()
        return count
    end

    return guard
end
