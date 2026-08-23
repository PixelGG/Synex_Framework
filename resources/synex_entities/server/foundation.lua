SynexEntityFoundation = {}

local function safeLabel(value, fallback, maximum)
    if type(value) ~= 'string' or #value < 1 or #value > maximum
        or value:match('^[%w%._:%-]+$') == nil then
        return fallback
    end
    return value
end

function SynexEntityFoundation.create(options)
    assert(type(options) == 'table', 'entity foundation options are required')
    local resourceName = assert(options.resourceName, 'entity foundation resourceName is required')
    local validation = assert(options.validation, 'entity foundation validation is required')
    local registry = assert(options.registry, 'entity foundation registry is required')
    local state = assert(options.state, 'entity foundation state is required')
    local ports = assert(options.ports, 'entity foundation ports are required')
    local limits = assert(options.limits, 'entity foundation limits are required')
    local health = assert(options.health, 'entity foundation health is required')
    local errorSink = assert(options.errorSink, 'entity foundation errorSink is required')

    local mutationLimiter = validation.newTokenBucket(24, 8)
    local readLimiter = validation.newTokenBucket(80, 25)
    local ownerCycles = {}
    local mutationLocks = {}
    local pendingSpawns = 0
    local pendingOwnerSpawns = {}
    local pendingBucketSpawns = {}
    local cleanupOwner
    local foundation = {}

    function foundation.failure(code, message, retryable, context)
        return nil, {
            code = code,
            message = message,
            retryable = retryable == true,
            traceId = type(context) == 'table' and context.traceId or nil,
        }
    end

    function foundation.setHealth(healthState, reason)
        health.state = healthState
        health.reason = reason
    end

    function foundation.reportUnexpected(operation, caught, context)
        local event = {
            code = 'UNEXPECTED_FAILURE',
            detail = '[REDACTED]',
            errorType = type(caught),
            operation = safeLabel(operation, 'unknown', 96),
            traceId = safeLabel(type(context) == 'table' and context.traceId or nil, 'unavailable', 128),
        }
        local sinkOk = pcall(errorSink, event)
        if not sinkOk then
            print(('[%s] error_sink_failed operation=%s traceId=%s'):format(
                resourceName,
                event.operation,
                event.traceId
            ))
        end
    end

    function foundation.protect(operation, handler, context)
        local values = table.pack(pcall(handler))
        if not values[1] then
            foundation.reportUnexpected(operation, values[2], context)
        end
        return table.unpack(values, 1, values.n)
    end

    function foundation.isCallable(value)
        local valueType = type(value)
        if valueType == 'function' then return true end
        if valueType ~= 'table' and valueType ~= 'userdata' then return false end
        local metatable = getmetatable(value)
        if type(metatable) ~= 'table'
            and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
            local readable, rawMetatable = pcall(debug.getmetatable, value)
            if readable then metatable = rawMetatable end
        end
        return type(metatable) == 'table'
            and type(rawget(metatable, '__call')) == 'function'
    end

    function foundation.getCaller(context)
        if type(context) ~= 'table' then
            return foundation.failure('FORBIDDEN', 'A Core invocation context is required', false, context)
        end

        local caller = context.caller or context.callerResource or context.resource
        if type(context.principal) == 'table' and context.principal.kind == 'resource' then
            caller = caller or context.principal.name
        end

        local normalized, validationError = validation.validateCaller(caller)
        if not normalized then
            validationError.traceId = context.traceId
            return nil, validationError
        end
        return normalized
    end

    function foundation.takeRateLimit(caller, cost, context, readOnly)
        local limiter = readOnly and readLimiter or mutationLimiter
        if not limiter.take(caller, cost, ports.getGameTimer()) then
            return foundation.failure(
                'RATE_LIMITED',
                'The resource exceeded its entity operation budget',
                true,
                context
            )
        end
        return true
    end

    function foundation.currentOwnerCycle(owner)
        return ownerCycles[owner] or 0
    end

    function foundation.isResourceActive(owner)
        local resourceState = ports.getResourceState(owner)
        return resourceState == 'started' or resourceState == 'starting'
    end

    function foundation.setCleanupOwner(handler)
        assert(type(handler) == 'function', 'entity cleanup handler must be a function')
        cleanupOwner = handler
    end

    function foundation.withOwnerMutation(caller, context, handler)
        if not foundation.isResourceActive(caller) then
            return foundation.failure(
                'STALE_RESOURCE',
                'The invoking resource is no longer started',
                true,
                context
            )
        end
        if mutationLocks[caller] then
            return foundation.failure(
                'CONFLICT',
                'Another entity mutation for this resource is in progress',
                true,
                context
            )
        end

        local cycle = foundation.currentOwnerCycle(caller)
        local token = {}
        mutationLocks[caller] = token
        local ok, value, operationError = xpcall(handler, debug.traceback)
        if mutationLocks[caller] == token then
            mutationLocks[caller] = nil
        end

        local staleOwner = foundation.currentOwnerCycle(caller) ~= cycle
            or not foundation.isResourceActive(caller)
        if staleOwner and cleanupOwner then
            local cleanupOk, cleanupError = pcall(cleanupOwner, caller, cycle)
            if not cleanupOk then
                foundation.reportUnexpected('owner.cleanup', cleanupError, context)
                foundation.setHealth('DEGRADED', 'A stopped resource could not be cleaned up')
            end
        end
        if not ok then
            error(value, 0)
        end
        if staleOwner then
            return foundation.failure(
                'STALE_RESOURCE',
                'The invoking resource restarted during the operation',
                true,
                context
            )
        end
        return value, operationError
    end

    function foundation.withSpawnReservation(caller, bucketId, context, handler)
        local ownerPending = pendingOwnerSpawns[caller] or 0
        local bucketPending = pendingBucketSpawns[bucketId] or 0
        if registry.count() + pendingSpawns >= limits.maxEntities then
            return foundation.failure('UNAVAILABLE', 'The managed entity limit has been reached', true, context)
        end
        if #registry.forOwner(caller) + ownerPending >= limits.maxOwnerEntities then
            return foundation.failure('RATE_LIMITED', 'The resource entity limit has been reached', true, context)
        end
        if bucketId > 0 and state.buckets[bucketId]
            and foundation.tableCount(state.buckets[bucketId].entities) + bucketPending
                >= limits.maxBucketEntities then
            return foundation.failure(
                'RATE_LIMITED',
                'The routing bucket entity limit has been reached',
                true,
                context
            )
        end

        pendingSpawns = pendingSpawns + 1
        pendingOwnerSpawns[caller] = ownerPending + 1
        pendingBucketSpawns[bucketId] = bucketPending + 1
        local ok, value, operationError = xpcall(handler, debug.traceback)
        pendingSpawns = math.max(0, pendingSpawns - 1)
        pendingOwnerSpawns[caller] = math.max(0, (pendingOwnerSpawns[caller] or 1) - 1)
        pendingBucketSpawns[bucketId] = math.max(0, (pendingBucketSpawns[bucketId] or 1) - 1)
        if pendingOwnerSpawns[caller] == 0 then
            pendingOwnerSpawns[caller] = nil
        end
        if pendingBucketSpawns[bucketId] == 0 then
            pendingBucketSpawns[bucketId] = nil
        end
        if not ok then
            error(value, 0)
        end
        return value, operationError
    end

    function foundation.advanceOwnerCycle(owner)
        local stoppedCycle = foundation.currentOwnerCycle(owner)
        local mutationInFlight = mutationLocks[owner] ~= nil
        ownerCycles[owner] = stoppedCycle + 1
        mutationLimiter.clear(owner)
        readLimiter.clear(owner)
        return stoppedCycle, mutationInFlight
    end

    function foundation.tableCount(value)
        local count = 0
        for _ in pairs(value) do
            count = count + 1
        end
        return count
    end

    return foundation
end
