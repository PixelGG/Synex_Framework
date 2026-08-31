SynexInteractFoundation = {}

local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')
local Foundation = SynexInteractFoundation

Foundation.isCallable = Validation.isCallable

function Foundation.protect(handler, ...)
    if not Validation.isCallable(handler) then
        return Validation.failure('INTERACT_UNAVAILABLE', 'An interaction handler is unavailable.', true)
    end
    local results = table.pack(pcall(handler, ...))
    if not results[1] then
        return Validation.failure('INTERACT_INTERNAL_ERROR',
            'The interaction operation failed internally.', false)
    end
    return table.unpack(results, 2, results.n)
end

function Foundation.boundedCall(handler, options, ...)
    options = options or {}
    local now = options.now
    local wait = options.wait
    local spawn = options.spawn
    local timeoutMs = options.timeoutMs
    if not Validation.isCallable(handler) or not Validation.isCallable(now)
        or not Validation.isCallable(wait) or not Validation.isCallable(spawn)
        or not Validation.isInteger(timeoutMs, 1, 120000) then
        return Validation.failure('INTERACT_UNAVAILABLE',
            'A bounded interaction handler is unavailable.', true)
    end
    local arguments = table.pack(...)
    local state = { done = false, results = nil }
    local scheduled, scheduleError = Foundation.protect(function()
        spawn(function()
            state.results = table.pack(Foundation.protect(
                handler, table.unpack(arguments, 1, arguments.n)))
            state.done = true
        end)
        return true
    end)
    if scheduled == nil then return nil, scheduleError end
    local deadline = now() + timeoutMs
    while not state.done and now() < deadline do
        wait(math.min(10, math.max(1, deadline - now())))
    end
    if not state.done then
        return Validation.failure(options.timeoutCode or 'INTERACT_EXTENSION_TIMEOUT',
            options.timeoutMessage or 'The interaction extension exceeded its time budget.',
            options.retryable == true)
    end
    return table.unpack(state.results, 1, state.results.n)
end

function Foundation.publicError(value)
    if type(value) ~= 'table' then
        return { code = 'INTERACT_INTERNAL_ERROR',
            message = 'The interaction operation failed internally.', retryable = false }
    end
    local code = type(value.code) == 'string' and value.code or 'INTERACT_INTERNAL_ERROR'
    if code:sub(1, 9) ~= 'INTERACT_' and code ~= 'RATE_LIMITED'
        and code ~= 'PERMISSION_DENIED' and code ~= 'UNAVAILABLE'
        and code ~= 'STALE_RESOURCE' then code = 'INTERACT_DOMAIN_REJECTED' end
    return {
        code = code,
        message = type(value.message) == 'string' and value.message
            or 'The interaction operation was rejected.',
        retryable = value.retryable == true,
    }
end

function Foundation.monotonicClock(getGameTimer)
    local lastRaw, elapsed = nil, 0
    return function()
        local raw = tonumber(getGameTimer()) or 0
        if lastRaw ~= nil then
            local delta = raw - lastRaw
            if delta < -2147483648 then delta = delta + 4294967296 end
            if delta >= 0 and delta <= 2147483648 then elapsed = elapsed + delta end
        end
        lastRaw = raw
        return elapsed
    end
end

function Foundation.tokenBucket(now, capacity, refillPerSecond)
    local buckets = {}
    local api = {}
    function api.take(key, cost)
        local timestamp = now()
        local bucket = buckets[key]
        if not bucket then bucket = { tokens = capacity, at = timestamp }; buckets[key] = bucket end
        local elapsed = math.max(0, timestamp - bucket.at)
        bucket.tokens = math.min(capacity,
            bucket.tokens + elapsed * refillPerSecond / 1000)
        bucket.at = timestamp
        local required = cost or 1
        if bucket.tokens < required then
            return Validation.failure('INTERACT_RATE_LIMITED',
                'Interaction request rate exceeded.', true)
        end
        bucket.tokens = bucket.tokens - required
        return true, nil
    end
    function api.purge(prefix)
        for key in pairs(buckets) do
            if prefix == nil or key:sub(1, #prefix) == prefix then buckets[key] = nil end
        end
        return true
    end
    return api
end
