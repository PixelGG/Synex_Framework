SynexSecurityDatabase = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')

function SynexSecurityDatabase.create(options)
    options = options or {}
    local coreRef = assert(options.coreRef, 'security database requires Core reference')

    local function method(name)
        local api = coreRef.value
        local database = type(api) == 'table' and api.Database or nil
        local handler = type(database) == 'table' and database[name] or nil
        return Validation.isCallable(handler) and handler or nil
    end

    local function invoke(name, ...)
        local handler = method(name)
        if not handler then
            return Validation.failure('SECURITY_PERSISTENCE_UNAVAILABLE',
                'The Synex Core database port is unavailable.', true)
        end
        local values = table.pack(pcall(handler, ...))
        if not values[1] then
            return Validation.failure('SECURITY_PERSISTENCE_UNAVAILABLE',
                'The security persistence call failed.', true)
        end
        if values[2] == false and type(values[3]) == 'table' then
            return nil, values[3]
        end
        if values[2] == nil then return nil, values[3] end
        return table.unpack(values, 2, values.n)
    end

    local database = {}

    function database.null()
        return invoke('null')
    end

    local function parameters(values)
        if values == nil then return {} end
        if type(values) ~= 'table' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security persistence parameters must be a dense array.')
        end
        local count = 0
        for key in pairs(values) do
            if not Validation.isInteger(key, 1, 128) then
                return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                    'Security persistence parameters are invalid.')
            end
            count = math.max(count, key)
        end
        local result = {}
        for index = 1, count do
            local value = rawget(values, index)
            if value == nil then
                value = database.null()
                if value == nil then
                    return Validation.failure('SECURITY_PERSISTENCE_UNAVAILABLE',
                        'The database NULL sentinel is unavailable.', true)
                end
            end
            result[index] = value
        end
        return result
    end

    function database.read(sql, values, optionsValue)
        if not Validation.text(sql, 1, 32768) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security persistence SQL is invalid.')
        end
        local normalized, parameterError = parameters(values)
        if not normalized then return nil, parameterError end
        local limits = optionsValue or {}
        return invoke('read', {
            sql = sql,
            parameters = normalized,
            maximumRows = Validation.isInteger(limits.maximumRows, 1,
                Limits.maximumCases + 1)
                and limits.maximumRows or 100,
            maximumResultBytes = Validation.isInteger(
                limits.maximumResultBytes, 1024, 4194304)
                and limits.maximumResultBytes or 262144,
            timeoutMs = Validation.isInteger(limits.timeoutMs, 1, 30000)
                and limits.timeoutMs or 5000,
        })
    end

    function database.write(sql, values, optionsValue)
        if not Validation.text(sql, 1, 32768) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security persistence SQL is invalid.')
        end
        local normalized, parameterError = parameters(values)
        if not normalized then return nil, parameterError end
        local limits = optionsValue or {}
        return invoke('write', {
            sql = sql,
            parameters = normalized,
            timeoutMs = Validation.isInteger(limits.timeoutMs, 1, 30000)
                and limits.timeoutMs or 5000,
        })
    end

    function database.transaction(request, handler)
        if type(request) ~= 'table' or not Validation.isCallable(handler)
            or not Validation.semanticKey(request.operation, 96)
            or not Validation.token(request.idempotencyKey, 8, 64)
            or type(request.request) ~= 'table' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security persistence transaction is invalid.')
        end
        return invoke('transaction', {
            operation = request.operation,
            idempotencyKey = request.idempotencyKey,
            request = request.request,
            timeoutMs = 10000,
            maximumRows = 128,
            maximumResultBytes = 262144,
            maximumRequestBytes = 65536,
            maximumResponseBytes = 262144,
            maximumStatements = 16,
        }, handler)
    end

    function database.maintenance(operation, handler)
        if not Validation.semanticKey(operation, 96) or not Validation.isCallable(handler) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security maintenance operation is invalid.')
        end
        return invoke('maintenance', {
            operation = operation,
            timeoutMs = 15000,
            maximumRows = 500,
            maximumResultBytes = 524288,
            maximumResponseBytes = 262144,
            maximumStatements = 32,
        }, handler)
    end

    return database
end
