SynexSecurityFoundation = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = SynexSecurityFoundation

Foundation.isCallable = Validation.isCallable

function Foundation.protect(handler, ...)
    if not Validation.isCallable(handler) then
        return Validation.failure('SECURITY_UNAVAILABLE',
            'A required security handler is unavailable.', true)
    end
    local results = table.pack(pcall(handler, ...))
    if not results[1] then
        return Validation.failure('SECURITY_INTERNAL_ERROR',
            'The security operation failed internally.', false)
    end
    return table.unpack(results, 2, results.n)
end

function Foundation.publicError(value)
    if type(value) ~= 'table' then
        return {
            code = 'SECURITY_INTERNAL_ERROR',
            message = 'The security operation failed internally.',
            retryable = false,
        }
    end
    local code = type(value.code) == 'string' and value.code or 'SECURITY_INTERNAL_ERROR'
    if code:sub(1, 9) ~= 'SECURITY_' and code ~= 'RATE_LIMITED'
        and code ~= 'PERMISSION_DENIED' and code ~= 'UNAVAILABLE'
        and code ~= 'STALE_RESOURCE' then code = 'SECURITY_DOMAIN_REJECTED' end
    return {
        code = code,
        message = type(value.message) == 'string' and value.message
            or 'The security operation was rejected.',
        retryable = value.retryable == true,
    }
end

function Foundation.round(value)
    local scale = Limits.confidencePrecision
    return math.floor(math.max(0, math.min(1, value)) * scale + 0.5) / scale
end

function Foundation.decay(value, ageMs, halfLifeMs)
    if not Validation.isFinite(value) or not Validation.isFinite(ageMs)
        or not Validation.isFinite(halfLifeMs) or halfLifeMs <= 0 then return 0 end
    if ageMs <= 0 then return value end
    return value * math.pow(0.5, ageMs / halfLifeMs)
end

function Foundation.subjectFromSignal(signal)
    return {
        source = signal.subjectSource,
        sessionId = signal.subjectSession,
        sourceGeneration = signal.sourceGeneration,
        userId = signal.subjectUser,
        characterId = signal.subjectCharacter,
        resourceName = signal.subjectResource,
    }
end

function Foundation.subjectKey(signal)
    return Validation.subjectKey(Foundation.subjectFromSignal(signal))
end

function Foundation.independenceKey(signal)
    local root = signal.rootEventId or signal.requestId or signal.traceId
    if root ~= nil then return 'root:' .. root end
    return 'signal:' .. signal.signalId
end

function Foundation.hypothesisKey(signal)
    return signal.category .. ':' .. (signal.correlationKey or signal.detector)
end

function Foundation.hypothesisForSignal(assessment, signal)
    if type(assessment) ~= 'table' or type(assessment.hypotheses) ~= 'table'
        or type(signal) ~= 'table' or type(signal.category) ~= 'string'
        or type(signal.detector) ~= 'string' then return nil end
    local key = Foundation.hypothesisKey(signal)
    for _, hypothesis in ipairs(assessment.hypotheses) do
        if type(hypothesis) == 'table' and hypothesis.key == key then
            return hypothesis
        end
    end
    return nil
end

function Foundation.maximumSeverity(left, right)
    if left == nil then return right end
    if right == nil then return left end
    if (Limits.severityRanks[right] or 0) > (Limits.severityRanks[left] or 0) then
        return right
    end
    return left
end

function Foundation.sortedKeys(value)
    local keys = {}
    for key in pairs(value or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

function Foundation.stableDigest(value)
    local textValue = tostring(value or '')
    local first, second = 2166136261, 5381
    for index = 1, #textValue do
        local byte = textValue:byte(index)
        first = (first * 16777619 + byte) % 4294967296
        second = (second * 33 + byte) % 4294967296
    end
    return ('%08x%08x'):format(first, second)
end

function Foundation.tokenBucket(now, capacity, refillPerSecond)
    local buckets, api = {}, {}
    function api.take(key, cost)
        local timestamp = now()
        local bucket = buckets[key]
        if bucket == nil then
            bucket = { tokens = capacity, at = timestamp }
            buckets[key] = bucket
        end
        local elapsed = math.max(0, timestamp - bucket.at)
        bucket.tokens = math.min(capacity,
            bucket.tokens + elapsed * refillPerSecond / 1000)
        bucket.at = timestamp
        local required = cost or 1
        if bucket.tokens < required then
            return Validation.failure('SECURITY_RATE_LIMITED',
                'The security operation rate was exceeded.', true)
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
