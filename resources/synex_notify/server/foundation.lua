SynexNotifyFoundation = {}

local MAXIMUM_SAFE_INTEGER = 9007199254740991

function SynexNotifyFoundation.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local ok, metadata = pcall(getmetatable, value)
    return ok and type(metadata) == 'table' and type(metadata.__call) == 'function'
end

function SynexNotifyFoundation.failure(code, message, retryable, details)
    local value = {
        code = type(code) == 'string' and code or 'NOTIFY_INTERNAL_ERROR',
        message = type(message) == 'string' and message or 'The notification operation failed.',
        retryable = retryable == true,
    }
    if type(details) == 'table' then value.details = details end
    return nil, value
end

function SynexNotifyFoundation.publicError(value)
    if type(value) ~= 'table' or type(value.code) ~= 'string' then
        return {
            code = 'NOTIFY_INTERNAL_ERROR',
            message = 'The notification operation failed.',
            retryable = false,
        }
    end
    local code = value.code
    local trusted = code:match('^NOTIFY_[A-Z0-9_]+$') ~= nil
    if not trusted then
        code = value.retryable == true and 'NOTIFY_UNAVAILABLE' or 'NOTIFY_INTERNAL_ERROR'
    end
    return {
        code = code,
        message = trusted and type(value.message) == 'string' and value.message
            or 'The notification operation failed.',
        retryable = value.retryable == true,
    }
end

function SynexNotifyFoundation.protect(handler, ...)
    local results = table.pack(pcall(handler, ...))
    if not results[1] then
        return SynexNotifyFoundation.failure('NOTIFY_INTERNAL_ERROR',
            'The notification operation failed.', false)
    end
    return table.unpack(results, 2, results.n)
end

function SynexNotifyFoundation.monotonicClock(timer)
    local modulus, half = 4294967296, 2147483648
    local previous, elapsed = nil, 0
    return function()
        local ok, current = pcall(timer)
        if not ok or type(current) ~= 'number' then return elapsed end
        current = math.floor(current)
        if current < 0 then current = current + modulus end
        current = current % modulus
        if previous == nil then
            previous, elapsed = current, current
            return elapsed
        end
        local delta = (current - previous) % modulus
        if delta <= half then
            previous, elapsed = current, math.min(MAXIMUM_SAFE_INTEGER, elapsed + delta)
        end
        return elapsed
    end
end

function SynexNotifyFoundation.copy(value, depth, seen)
    if type(value) ~= 'table' then return value end
    depth, seen = depth or 0, seen or {}
    if depth > 8 or seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        result[SynexNotifyFoundation.copy(key, depth + 1, seen)] =
            SynexNotifyFoundation.copy(child, depth + 1, seen)
    end
    seen[value] = nil
    return result
end
