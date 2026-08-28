SynexWorldDatabaseAdapter = {}

local Adapter = SynexWorldDatabaseAdapter
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local MAXIMUM_PARAMETERS = 128
local MAXIMUM_ROWS = 8192
local MAXIMUM_RESULT_BYTES = 4 * 1024 * 1024
local MAXIMUM_REQUEST_BYTES = 8 * 1024 * 1024
local MAXIMUM_RESPONSE_BYTES = 4 * 1024 * 1024
local MAXIMUM_STATEMENTS = 4096
local MAXIMUM_TIMEOUT_MS = 30000

local safeMessages = {
    CONCURRENT_MODIFICATION = 'World state changed before the requested mutation could be committed.',
    CORE_UNAVAILABLE = 'The Synex Core database port is unavailable.',
    DATABASE_DEADLINE_EXCEEDED = 'The World persistence deadline was exceeded.',
    DATABASE_PARAMETER_MISMATCH = 'World persistence parameters are invalid.',
    DATABASE_RESULT_INVALID = 'World persistence returned an invalid result.',
    DATABASE_STATEMENT_LIMIT = 'The World persistence statement budget was exceeded.',
    DATABASE_TABLE_NOT_OWNED = 'World persistence attempted to access a table it does not own.',
    IDEMPOTENCY_CAPACITY_EXCEEDED = 'World persistence idempotency capacity is exhausted.',
    IDEMPOTENCY_CONFLICT = 'The World mutation idempotency key was already used for another request.',
    INVALID_ARGUMENT = 'The World persistence request is invalid.',
    INVALID_DATABASE_PARAMETERS = 'World persistence parameters are invalid.',
    INVALID_DATABASE_TRANSACTION = 'The World persistence transaction is invalid.',
    OUTBOX_WRITE_FAILED = 'The World domain event could not be persisted.',
    STALE_RESOURCE = 'The World resource binding is stale.',
}

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function domainError(code, retryable)
    local normalized = type(code) == 'string' and code:match('^[A-Z][A-Z0-9_]*$')
        and #code <= 64 and code or 'DATABASE_ERROR'
    return {
        code = normalized,
        message = safeMessages[normalized] or 'The World persistence operation failed.',
        retryable = retryable == true,
    }
end

local function sanitizeError(candidate, fallbackCode)
    if type(candidate) ~= 'table' then return domainError(fallbackCode or 'DATABASE_ERROR', true) end
    local code = type(candidate.code) == 'string' and candidate.code or fallbackCode
    return domainError(code or 'DATABASE_ERROR', candidate.retryable == true)
end

local function boundedInteger(value, defaultValue, minimum, maximum)
    value = value == nil and defaultValue or value
    if not Validation.isInteger(value, minimum, maximum) then return nil end
    return value
end

local function placeholderCount(sql)
    if type(sql) ~= 'string' or #sql < 1 or #sql > 65535 then return nil end
    local count, index, state, quote = 0, 1, 'plain', nil
    while index <= #sql do
        local current, following = sql:sub(index, index), sql:sub(index + 1, index + 1)
        if state == 'quoted' then
            if current == quote then
                if following == quote then index = index + 1 else state, quote = 'plain', nil end
            elseif current == '\\' and following ~= '' then
                index = index + 1
            end
        elseif state == 'identifier' then
            if current == '`' then
                if following == '`' then index = index + 1 else state = 'plain' end
            end
        elseif state == 'line_comment' then
            if current == '\n' or current == '\r' then state = 'plain' end
        elseif state == 'block_comment' then
            if current == '*' and following == '/' then state, index = 'plain', index + 1 end
        elseif current == "'" or current == '"' then
            state, quote = 'quoted', current
        elseif current == '`' then
            state = 'identifier'
        elseif current == '#' then
            state = 'line_comment'
        elseif current == '-' and following == '-'
            and (sql:sub(index + 2, index + 2) == ''
                or sql:sub(index + 2, index + 2):match('%s')) then
            state, index = 'line_comment', index + 1
        elseif current == '/' and following == '*' then
            state, index = 'block_comment', index + 1
        elseif current == '?' then
            count = count + 1
            if count > MAXIMUM_PARAMETERS then return nil end
        end
        index = index + 1
    end
    if state == 'quoted' or state == 'identifier' or state == 'block_comment' then return nil end
    return count
end

function Adapter.create(options)
    options = type(options) == 'table' and options or {}
    local dataPort = options.dataPort
    if type(dataPort) ~= 'table' or not callable(dataPort.null)
        or not callable(dataPort.read) or not callable(dataPort.write)
        or not callable(dataPort.transaction) or not callable(dataPort.maintenance) then
        error('world database adapter requires the Synex Core DataPort facade', 0)
    end

    local function parameters(sql, candidate)
        local expected = placeholderCount(sql)
        if expected == nil or candidate ~= nil and type(candidate) ~= 'table' then
            return nil, domainError('INVALID_DATABASE_PARAMETERS')
        end
        for key in pairs(candidate or {}) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > expected then
                return nil, domainError('INVALID_DATABASE_PARAMETERS')
            end
        end
        local normalized = {}
        for index = 1, expected do
            local value = candidate and rawget(candidate, index) or nil
            if value == nil then
                local called, sentinel = pcall(dataPort.null)
                if not called or sentinel == nil then
                    return nil, domainError('CORE_UNAVAILABLE', true)
                end
                value = sentinel
            end
            normalized[index] = value
        end
        return normalized
    end

    local function invoke(method, ...)
        local called, value, operationError, metadata = pcall(method, ...)
        if not called then return nil, sanitizeError(value, 'DATABASE_ERROR') end
        if value == false and type(operationError) == 'table' then value = nil end
        if value == nil then return nil, sanitizeError(operationError, 'DATABASE_ERROR') end
        return value, nil, metadata
    end

    local function requestOptions(candidate, maintenance)
        candidate = type(candidate) == 'table' and candidate or {}
        local normalized = {
            timeoutMs = boundedInteger(candidate.timeoutMs, 15000, 1, MAXIMUM_TIMEOUT_MS),
            maximumRows = boundedInteger(candidate.maximumRows, MAXIMUM_ROWS, 1, MAXIMUM_ROWS),
            maximumResultBytes = boundedInteger(candidate.maximumResultBytes,
                MAXIMUM_RESULT_BYTES, 1024, MAXIMUM_RESULT_BYTES),
            maximumResponseBytes = boundedInteger(candidate.maximumResponseBytes,
                MAXIMUM_RESPONSE_BYTES, 1024, MAXIMUM_RESPONSE_BYTES),
            maximumStatements = boundedInteger(candidate.maximumStatements,
                maintenance and 256 or MAXIMUM_STATEMENTS, 1, MAXIMUM_STATEMENTS),
        }
        if not normalized.timeoutMs or not normalized.maximumRows
            or not normalized.maximumResultBytes or not normalized.maximumResponseBytes
            or not normalized.maximumStatements then
            return nil, domainError('INVALID_ARGUMENT')
        end
        return normalized
    end

    local function adaptTransaction(transaction)
        if type(transaction) ~= 'table' then
            error(domainError('INVALID_DATABASE_TRANSACTION'), 0)
        end
        local wrapped = {}
        local function checked(name, sql, values, limit)
            local method = transaction[name]
            if not callable(method) then error(domainError('INVALID_DATABASE_TRANSACTION'), 0) end
            local normalized, parameterError = parameters(sql, values)
            if not normalized then error(parameterError, 0) end
            local value, operationError = method(transaction, sql, normalized, limit)
            if value == false and type(operationError) == 'table' then value = nil end
            if value == nil and operationError ~= nil then
                error(sanitizeError(operationError, 'DATABASE_ERROR'), 0)
            end
            return value
        end
        function wrapped.query(sql, values, limit) return checked('query', sql, values, limit) end
        function wrapped.many(sql, values, limit)
            local rows = checked('many', sql, values, limit)
            if type(rows) ~= 'table' then error(domainError('DATABASE_RESULT_INVALID'), 0) end
            return rows
        end
        function wrapped.one(sql, values) return checked('one', sql, values) end
        function wrapped.affected(sql, values)
            local affected = checked('affected', sql, values)
            if not Validation.isInteger(affected, 0, 9007199254740991) then
                error(domainError('DATABASE_RESULT_INVALID'), 0)
            end
            return affected
        end
        wrapped.update = wrapped.affected
        function wrapped.insert(sql, values) return checked('insert', sql, values) end
        return wrapped
    end

    local adapter = {}

    function adapter:parameters(sql, candidate) return parameters(sql, candidate) end

    function adapter:read(sql, values, optionsValue)
        local normalized, parameterError = parameters(sql, values)
        if not normalized then return nil, parameterError end
        local limits, limitError = requestOptions(optionsValue, false)
        if not limits then return nil, limitError end
        return invoke(dataPort.read, {
            sql = sql,
            parameters = normalized,
            maximumRows = limits.maximumRows,
            maximumResultBytes = limits.maximumResultBytes,
            timeoutMs = limits.timeoutMs,
        })
    end

    function adapter:write(sql, values, optionsValue)
        local normalized, parameterError = parameters(sql, values)
        if not normalized then return nil, parameterError end
        local limits, limitError = requestOptions(optionsValue, false)
        if not limits then return nil, limitError end
        return invoke(dataPort.write, {
            sql = sql,
            parameters = normalized,
            timeoutMs = limits.timeoutMs,
        })
    end

    function adapter:transaction(request, handler)
        if type(request) ~= 'table' or not callable(handler)
            or type(request.operation) ~= 'string' or type(request.idempotencyKey) ~= 'string'
            or type(request.request) ~= 'table' then
            return nil, domainError('INVALID_DATABASE_TRANSACTION')
        end
        local limits, limitError = requestOptions(request, false)
        if not limits then return nil, limitError end
        local maximumRequestBytes = boundedInteger(request.maximumRequestBytes,
            MAXIMUM_REQUEST_BYTES, 1024, MAXIMUM_REQUEST_BYTES)
        if not maximumRequestBytes then return nil, domainError('INVALID_ARGUMENT') end
        return invoke(dataPort.transaction, {
            operation = request.operation,
            idempotencyKey = request.idempotencyKey,
            request = request.request,
            timeoutMs = limits.timeoutMs,
            maximumRows = limits.maximumRows,
            maximumResultBytes = limits.maximumResultBytes,
            maximumRequestBytes = maximumRequestBytes,
            maximumResponseBytes = limits.maximumResponseBytes,
            maximumStatements = limits.maximumStatements,
        }, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
    end

    function adapter:maintenance(operation, handler, optionsValue)
        if type(operation) ~= 'string' or not callable(handler) then
            return nil, domainError('INVALID_DATABASE_TRANSACTION')
        end
        local limits, limitError = requestOptions(optionsValue, true)
        if not limits then return nil, limitError end
        return invoke(dataPort.maintenance, {
            operation = operation,
            timeoutMs = limits.timeoutMs,
            maximumRows = limits.maximumRows,
            maximumResultBytes = limits.maximumResultBytes,
            maximumResponseBytes = limits.maximumResponseBytes,
            maximumStatements = limits.maximumStatements,
        }, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
    end

    return adapter
end
