SynexWorldFoundation = {}

local Foundation = SynexWorldFoundation
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local publicCodes = {
    CONCURRENT_MODIFICATION = true, CORE_UNAVAILABLE = true,
    DOOR_NOT_FOUND = true, DOOR_STATE_INVALID = true,
    FORBIDDEN = true, INSTANCE_BUCKET_UNAVAILABLE = true, INSTANCE_CLOSED = true,
    INSTANCE_FULL = true, INSTANCE_NOT_FOUND = true, INTERNAL_ERROR = true,
    INVALID_ARGUMENT = true, MAP_PACKAGE_UNAVAILABLE = true, OUT_OF_CONTEXT = true,
    PORTAL_NOT_FOUND = true, PORTAL_TOO_FAR = true, PORTAL_UNAVAILABLE = true,
    QUERY_LIMIT_EXCEEDED = true, RATE_LIMITED = true, SPATIAL_INDEX_DEGRADED = true,
    STALE_RESOURCE = true, STALE_WORLD_REF = true, STATE_SCHEMA_MISMATCH = true,
    TRANSITION_DENIED = true, TRANSITION_GRANT_EXPIRED = true,
    TRANSITION_GRANT_REPLAYED = true, UNAVAILABLE = true, WORLD_ACCESS_DENIED = true,
    WORLD_BUNDLE_CONFLICT = true, WORLD_BUNDLE_INVALID = true,
    WORLD_DEPENDENCY_MISSING = true, WORLD_GEOMETRY_INVALID = true,
    WORLD_GRAPH_CYCLE = true, WORLD_NOT_FOUND = true, WORLD_REFERENCE_INVALID = true,
    WORLD_STATE_CONFLICT = true, WORLD_STATE_NOT_FOUND = true,
    WORLD_STATE_SCHEMA_INVALID = true, WORLD_STATE_VALUE_INVALID = true,
    WRONG_INSTANCE = true,
}

function Foundation.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local ok, metatable = pcall(debug.getmetatable, value)
    if not ok or type(metatable) ~= 'table' then return false end
    local call = rawget(metatable, '__call')
    return type(call) == 'function' or type(call) == 'table' or type(call) == 'userdata'
end

function Foundation.create(options)
    local health = assert(options.health, 'world foundation requires health')
    local encode = assert(options.encode, 'world foundation requires JSON encoding')
    local now = assert(options.now, 'world foundation requires monotonic time')
    local utc = assert(options.utc, 'world foundation requires UTC time')
    local resourceName = assert(options.resourceName, 'world foundation requires resource name')
    local healthChanged = options.onHealthChanged
    if healthChanged ~= nil and not Foundation.isCallable(healthChanged) then
        error('world health observer is invalid', 0)
    end
    local notifyingHealth = false
    local foundation = {}

    local function notifyHealthChanged()
        if not healthChanged or notifyingHealth then return end
        notifyingHealth = true
        pcall(healthChanged, health.state)
        notifyingHealth = false
    end

    function foundation.failure(code, message, retryable, details)
        return Validation.failure(code, message, retryable, details)
    end
    function foundation.copy(value)
        local ok, copied = pcall(Validation.copy, value)
        return ok and copied or nil
    end
    function foundation.protect(operation, handler, context)
        local results = table.pack(xpcall(handler, function(caught)
            local code = type(caught) == 'table' and caught.code or 'UNEXPECTED_FAILURE'
            local payload = { level = 'error', component = resourceName,
                message = 'world operation failed', fields = {
                    operation = operation, code = code,
                    traceId = context and context.traceId or nil,
                    errorType = type(caught),
                }, timestamp = utc() }
            local encodedOk, encoded = pcall(encode, payload)
            print(encodedOk and encoded or ('[%s] world operation failed'):format(resourceName))
            return type(caught) == 'table' and caught or {
                code = 'INTERNAL_ERROR', message = 'The World operation failed.', retryable = false,
            }
        end))
        if not results[1] then return nil, results[2] end
        return table.unpack(results, 2, results.n)
    end
    function foundation.publicError(operationError)
        if type(operationError) ~= 'table' then
            return { code = 'INTERNAL_ERROR', message = 'The World operation failed.', retryable = false }
        end
        local code = publicCodes[operationError.code] and operationError.code or 'INTERNAL_ERROR'
        return { code = code,
            message = code == 'INTERNAL_ERROR' and 'The World operation failed.'
                or tostring(operationError.message or 'The World operation failed.'),
            retryable = operationError.retryable == true,
            traceId = operationError.traceId }
    end
    function foundation.setHealth(state, code, message)
        health.state = state
        if code then
            health.reasons[code] = { code = code, message = message or code, at = utc() }
        end
        notifyHealthChanged()
    end
    function foundation.clearHealth(code)
        if health.reasons[code] == nil then return false end
        health.reasons[code] = nil
        if next(health.reasons) == nil and health.state ~= 'STOPPING' then
            health.state = 'READY'
        end
        notifyHealthChanged()
        return true
    end
    function foundation.onHealthChanged(handler)
        if handler ~= nil and not Foundation.isCallable(handler) then
            error('world health observer is invalid', 0)
        end
        healthChanged = handler
        notifyHealthChanged()
        return true
    end
    function foundation.healthSnapshot()
        local reasons = {}
        for _, reason in pairs(health.reasons) do reasons[#reasons + 1] = Validation.copy(reason) end
        table.sort(reasons, function(left, right) return left.code < right.code end)
        return { state = health.state, reasons = reasons,
            revision = health.revision, startedAt = health.startedAt,
            persistence = health.persistence, service = health.service }
    end
    function foundation.now() return now() end
    function foundation.utc() return utc() end
    return foundation
end
