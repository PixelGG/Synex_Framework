return function(Foundation)
local function createDatabaseAdapter(database)
    if type(database) ~= 'table'
        or not Foundation.isCallable(database.null)
        or not Foundation.isCallable(database.read)
        or not Foundation.isCallable(database.write)
        or not Foundation.isCallable(database.transaction)
        or not Foundation.isCallable(database.maintenance) then
        error('groups database adapter requires the Synex Core Database API')
    end

    local function placeholderCount(sql)
        if type(sql) ~= 'string' then return nil end
        local count, index, state, quote = 0, 1, 'plain', nil
        while index <= #sql do
            local current = sql:sub(index, index)
            local following = sql:sub(index + 1, index + 1)
            if state == 'quoted' then
                if current == quote then
                    if following == quote then
                        index = index + 1
                    else
                        state, quote = 'plain', nil
                    end
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
                if current == '*' and following == '/' then
                    state = 'plain'
                    index = index + 1
                end
            elseif current == "'" or current == '"' then
                state, quote = 'quoted', current
            elseif current == '`' then
                state = 'identifier'
            elseif current == '#' then
                state = 'line_comment'
            elseif current == '-' and following == '-'
                and (sql:sub(index + 2, index + 2) == ''
                    or sql:sub(index + 2, index + 2):match('%s')) then
                state = 'line_comment'
                index = index + 1
            elseif current == '/' and following == '*' then
                state = 'block_comment'
                index = index + 1
            elseif current == '?' then
                count = count + 1
            end
            index = index + 1
        end
        if state == 'quoted' or state == 'identifier' or state == 'block_comment' then
            return nil
        end
        return count
    end

    local function normalizeParameters(sql, candidate)
        local expected = placeholderCount(sql)
        if expected == nil or expected > 128 then
            return nil, Foundation.domainError('INVALID_DATABASE_PARAMETERS',
                'The Groups database statement has invalid parameter syntax.')
        end
        if candidate ~= nil and type(candidate) ~= 'table' then
            return nil, Foundation.domainError('INVALID_DATABASE_PARAMETERS',
                'Groups database parameters must be positional values.')
        end
        for key in pairs(candidate or {}) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > expected then
                return nil, Foundation.domainError('INVALID_DATABASE_PARAMETERS',
                    'Groups database parameters do not match the SQL placeholders.')
            end
        end
        local normalized = {}
        for index = 1, expected do
            local value = candidate and rawget(candidate, index) or nil
            if value == nil then
                local called, sentinel, nullError = pcall(database.null)
                if not called or type(sentinel) ~= 'table' then
                    return nil, type(nullError) == 'table' and nullError
                        or type(sentinel) == 'table' and sentinel
                        or Foundation.domainError('CORE_UNAVAILABLE',
                            'The Synex Core database NULL sentinel is unavailable.', true)
                end
                value = sentinel
            end
            normalized[index] = value
        end
        return normalized, nil
    end

    local function invoke(method, ...)
        local called, value, operationError, metadata = pcall(method, ...)
        if not called then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The Synex Core database port raised an unexpected error.', true)
        end
        if value == false and type(operationError) == 'table' then value = nil end
        return value, operationError, metadata
    end

    local adapter = {}

    function adapter:parameters(sql, candidate)
        return normalizeParameters(sql, candidate)
    end

    function adapter:read(sql, parameters, options)
        local normalized, parameterError = normalizeParameters(sql, parameters)
        if not normalized then return nil, parameterError end
        options = type(options) == 'table' and options or {}
        return invoke(database.read, {
            sql = sql,
            parameters = normalized,
            maximumRows = options.maximumRows or 8192,
            maximumResultBytes = options.maximumResultBytes or 4194304,
            timeoutMs = options.timeoutMs or 15000
        })
    end

    function adapter:write(sql, parameters, options)
        local normalized, parameterError = normalizeParameters(sql, parameters)
        if not normalized then return nil, parameterError end
        options = type(options) == 'table' and options or {}
        return invoke(database.write, {
            sql = sql,
            parameters = normalized,
            timeoutMs = options.timeoutMs or 15000
        })
    end

    local function adaptTransaction(transaction)
        local wrapped = {}
        local function checked(method, sql, parameters, limit)
            local normalized, parameterError = normalizeParameters(sql, parameters)
            if not normalized then error(parameterError, 0) end
            local value, operationError = method(transaction, sql, normalized, limit)
            if value == false and type(operationError) == 'table' then value = nil end
            if value == nil and operationError ~= nil then error(operationError, 0) end
            return value
        end
        function wrapped.query(sql, parameters, limit)
            return checked(transaction.query, sql, parameters, limit)
        end
        function wrapped.many(sql, parameters, limit)
            local rows = checked(transaction.many, sql, parameters, limit)
            if type(rows) ~= 'table' then
                error(Foundation.domainError('DATABASE_RESULT_INVALID',
                    'The Groups database read returned invalid rows.'), 0)
            end
            return rows
        end
        function wrapped.one(sql, parameters)
            return checked(transaction.one, sql, parameters)
        end
        function wrapped.affected(sql, parameters)
            return checked(transaction.affected, sql, parameters)
        end
        wrapped.update = wrapped.affected
        function wrapped.insert(sql, parameters)
            return checked(transaction.insert, sql, parameters)
        end
        return wrapped
    end

    function adapter:adaptTransaction(transaction)
        return adaptTransaction(transaction)
    end

    function adapter:transaction(request, handler)
        if type(request) ~= 'table' or not Foundation.isCallable(handler) then
            return nil, Foundation.domainError('INVALID_DATABASE_TRANSACTION',
                'The Groups transaction request is invalid.')
        end
        local coreRequest = {
            operation = request.operation,
            idempotencyKey = request.idempotencyKey,
            request = request.request or {},
            timeoutMs = request.timeoutMs or 15000,
            maximumRows = request.maximumRows or 8192,
            maximumResultBytes = request.maximumResultBytes or 4194304,
            maximumRequestBytes = request.maximumRequestBytes or 8388608,
            maximumResponseBytes = request.maximumResponseBytes or 4194304,
            maximumStatements = request.maximumStatements or 4096
        }
        return invoke(database.transaction, coreRequest, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
    end

    function adapter:maintenance(operation, handler, options)
        if type(operation) ~= 'string' or not Foundation.isCallable(handler) then
            return nil, Foundation.domainError('INVALID_DATABASE_TRANSACTION',
                'The Groups maintenance request is invalid.')
        end
        options = type(options) == 'table' and options or {}
        return invoke(database.maintenance, {
            operation = operation,
            timeoutMs = options.timeoutMs or 15000,
            maximumRows = options.maximumRows or 8192,
            maximumResultBytes = options.maximumResultBytes or 4194304,
            maximumResponseBytes = options.maximumResponseBytes or 1048576,
            maximumStatements = options.maximumStatements or 4096
        }, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
    end

    function adapter:readOrError(sql, parameters, options)
        local rows, operationError = self:read(sql, parameters, options)
        if not rows then error(operationError, 0) end
        return rows
    end

    function adapter:writeOrError(sql, parameters, options)
        local result, operationError = self:write(sql, parameters, options)
        if not result then error(operationError, 0) end
        return result
    end

    return adapter
end

return createDatabaseAdapter
end
