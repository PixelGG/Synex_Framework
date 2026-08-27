SynexEntityDatabase = {}

local function isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metatable = getmetatable(value)
    if type(metatable) ~= 'table' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local readable, actual = pcall(debug.getmetatable, value)
        if readable then metatable = actual end
    end
    return type(metatable) == 'table' and type(rawget(metatable, '__call')) == 'function'
end

local function raiseOnError(value, operationError)
    if value == false and type(operationError) == 'table' then value = nil end
    if value == nil and operationError ~= nil then error(operationError, 0) end
    return value
end

function SynexEntityDatabase.createOxmysqlAdapter(driver)
    assert(type(driver) == 'table', 'oxmysql driver table is required')
    assert(type(driver.query) == 'table' and type(driver.query.await) == 'function', 'oxmysql query.await is required')
    assert(type(driver.update) == 'table' and type(driver.update.await) == 'function', 'oxmysql update.await is required')

    return {
        query = function(statement, parameters)
            return driver.query.await(statement, parameters)
        end,
        update = function(statement, parameters)
            return driver.update.await(statement, parameters)
        end,
    }
end

function SynexEntityDatabase.createCoreAdapter(coreRef)
    assert(type(coreRef) == 'table', 'Core reference table is required')

    local function database()
        local api = coreRef.value
        local port = api and api.Database
        if type(port) ~= 'table' or not isCallable(port.null)
            or not isCallable(port.read) or not isCallable(port.write)
            or not isCallable(port.transaction) or not isCallable(port.maintenance) then
            error({
                code = 'CORE_UNAVAILABLE',
                message = 'The Synex Core database port is unavailable',
                retryable = true,
            }, 0)
        end
        return port
    end

    local function parameters(values)
        if values == nil then return {} end
        if type(values) ~= 'table' then error('database parameters must be an array', 0) end
        local maximum, count = 0, 0
        for key in pairs(values) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > 128 then
                error('database parameters must be a bounded dense array', 0)
            end
            maximum = math.max(maximum, key)
            count = count + 1
        end
        local port = database()
        local normalized = {}
        for index = 1, maximum do
            local value = rawget(values, index)
            if value == nil then value = raiseOnError(port.null()) end
            normalized[index] = value
        end
        if maximum ~= count then
            -- Explicit NULL holes are normalized above; unrelated sparse indexes
            -- are rejected by the Core port's own positional validation.
            for index = 1, maximum do
                if rawget(values, index) == nil then count = count + 1 end
            end
            if count ~= maximum then error('database parameters are invalid', 0) end
        end
        return normalized
    end

    local adapter = {}

    function adapter.query(statement, values, options)
        options = type(options) == 'table' and options or {}
        return raiseOnError(database().read({
            sql = statement,
            parameters = parameters(values),
            maximumRows = options.maximumRows or 8192,
            maximumResultBytes = options.maximumResultBytes or 4194304,
            timeoutMs = options.timeoutMs or 15000,
        }))
    end

    function adapter.update(statement, values, options)
        options = type(options) == 'table' and options or {}
        local result = raiseOnError(database().write({
            sql = statement,
            parameters = parameters(values),
            timeoutMs = options.timeoutMs or 15000,
        }))
        local affected = type(result) == 'table' and tonumber(result.affectedRows) or nil
        if not affected or affected % 1 ~= 0 or affected < 0 then
            error('Core database write returned an invalid affected-row count', 0)
        end
        return affected
    end

    local function adaptTransaction(transaction)
        local adapted = {}
        local function invoke(method, statement, values, limit)
            return raiseOnError(method(transaction, statement, parameters(values), limit))
        end
        function adapted.query(statement, values, limit)
            return invoke(transaction.query, statement, values, limit)
        end
        function adapted.many(statement, values, limit)
            return invoke(transaction.many, statement, values, limit)
        end
        function adapted.one(statement, values)
            return invoke(transaction.one, statement, values)
        end
        function adapted.update(statement, values)
            return invoke(transaction.affected, statement, values)
        end
        adapted.affected = adapted.update
        return adapted
    end

    function adapter.transaction(request, handler)
        assert(type(request) == 'table' and isCallable(handler), 'transaction request is invalid')
        local value, operationError = database().transaction({
            operation = request.operation,
            idempotencyKey = request.idempotencyKey,
            request = request.request or {},
            timeoutMs = request.timeoutMs or 15000,
            maximumRows = request.maximumRows or 8192,
            maximumResultBytes = request.maximumResultBytes or 4194304,
            maximumRequestBytes = request.maximumRequestBytes or 1048576,
            maximumResponseBytes = request.maximumResponseBytes or 1048576,
            maximumStatements = request.maximumStatements or 512,
        }, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
        return raiseOnError(value, operationError)
    end

    function adapter.maintenance(operation, handler, options)
        options = type(options) == 'table' and options or {}
        local value, operationError = database().maintenance({
            operation = operation,
            timeoutMs = options.timeoutMs or 15000,
            maximumRows = options.maximumRows or 8192,
            maximumResultBytes = options.maximumResultBytes or 4194304,
            maximumResponseBytes = options.maximumResponseBytes or 1048576,
            maximumStatements = options.maximumStatements or 512,
        }, function(transaction)
            return handler(adaptTransaction(transaction))
        end)
        return raiseOnError(value, operationError)
    end

    return adapter
end
