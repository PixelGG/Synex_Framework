SynexEntityPublicErrors = {}

local function codeSet(definitions)
    local byContract = {}
    for _, definition in ipairs(type(definitions) == 'table' and definitions or {}) do
        if type(definition) == 'table' and type(definition.name) == 'string'
            and type(definition.version) == 'string' and type(definition.errors) == 'table' then
            local exact = {}
            for _, code in ipairs(definition.errors) do
                if type(code) == 'string' then exact[code] = true end
            end
            byContract[definition.name .. '@' .. definition.version] = exact
            local aggregate = byContract[definition.name] or {}
            for code in pairs(exact) do aggregate[code] = true end
            byContract[definition.name] = aggregate
        end
    end
    return byContract
end

local function safeMessage(value, fallback)
    if type(value) ~= 'string' or value == '' then return fallback end
    value = value:gsub('[%z\1-\31\127]', ' ')
    if #value > 512 then value = value:sub(1, 512) end
    return value
end

local function quotaDetails(operationError)
    local candidate = operationError.details
    if operationError.code ~= 'ENTITY_QUOTA_EXCEEDED' or type(candidate) ~= 'table'
        or getmetatable(candidate) ~= nil then
        return nil
    end
    local scope = rawget(candidate, 'scope')
    local limit = rawget(candidate, 'limit')
    if type(scope) ~= 'string' or #scope < 1 or #scope > 64
        or type(limit) ~= 'number' or limit ~= limit or limit < 0
        or limit == math.huge or limit == -math.huge then return nil end
    return { limit = limit, scope = scope }
end

local function initialAlias(code)
    local fixed = {
        CORE_UNAVAILABLE = 'UNAVAILABLE',
        DATABASE_RESULT_INVALID = 'UNAVAILABLE',
        OPERATION_TIMEOUT = 'UNAVAILABLE',
        PERSISTENCE_UNAVAILABLE = 'UNAVAILABLE',
        REGISTRY_LIMIT = 'UNAVAILABLE',
        SPATIAL_INDEX_FULL = 'UNAVAILABLE',
    }
    if fixed[code] then return fixed[code] end
    if code:match('^CAPABILITY_') then return 'FORBIDDEN' end
    if code:match('^INVALID_IDEMPOTENCY_') then return 'INVALID_ARGUMENT' end
    if code == 'IDEMPOTENCY_CONFLICT' or code == 'IDEMPOTENCY_EXPIRED'
        or code == 'IDEMPOTENCY_FAILED' or code == 'IDEMPOTENCY_IN_PROGRESS' then
        return 'CONFLICT'
    end
    if code:match('^IDEMPOTENCY_') then return 'UNAVAILABLE' end
    return code
end

local function declaredAlias(code, declared)
    if declared[code] then return code end
    local compatible = {
        AUTHORITY_LEASE_CONFLICT = 'CONFLICT',
        BUCKET_CAPACITY_EXCEEDED = 'RATE_LIMITED',
        CONCURRENT_MODIFICATION = 'CONFLICT',
        ENTITY_NOT_FOUND = 'NOT_FOUND',
        ENTITY_NOT_MATERIALIZED = 'STALE_ENTITY',
        ENTITY_QUOTA_EXCEEDED = 'CONFLICT',
        FOREIGN_RESOURCE_OWNER = 'FORBIDDEN',
        HOOK_REJECTED = 'FORBIDDEN',
    }
    local alias = compatible[code]
    if alias and declared[alias] then return alias end
    if declared.UNAVAILABLE then return 'UNAVAILABLE' end
    if declared.INTERNAL_ERROR then return 'INTERNAL_ERROR' end
    return nil
end

local function normalize(operationError, declared)
    if type(operationError) ~= 'table' or type(operationError.code) ~= 'string'
        or operationError.code:match('^[A-Z][A-Z0-9_]+$') == nil then
        return { code = 'UNAVAILABLE', message = 'The Entity operation failed', retryable = true }
    end
    local originalCode = operationError.code
    local initial = initialAlias(originalCode)
    local code = declared and (declaredAlias(initial, declared)
        or declaredAlias(originalCode, declared) or 'UNAVAILABLE') or initial
    local message = safeMessage(operationError.message, 'The Entity operation failed')
    if code ~= originalCode then
        message = code == 'FORBIDDEN' and 'The Entity operation is not permitted'
            or code == 'INVALID_ARGUMENT' and 'The Entity request is invalid'
            or code == 'CONFLICT' and 'The Entity operation conflicts with current state'
            or 'An Entity dependency is unavailable'
    end
    local result = {
        code = code,
        message = message,
        retryable = code == 'UNAVAILABLE' or operationError.retryable == true,
    }
    if code == originalCode then result.details = quotaDetails(operationError) end
    return result
end

function SynexEntityPublicErrors.sanitize(operationError)
    return normalize(operationError, nil)
end

function SynexEntityPublicErrors.compile(definitions)
    local declaredByContract = codeSet(definitions)
    return function(contractName, operationError, context)
        local version = type(context) == 'table' and context.version or nil
        local declared = declaredByContract[contractName .. '@' .. tostring(version)]
            or declaredByContract[contractName] or { UNAVAILABLE = true }
        return normalize(operationError, declared)
    end
end
