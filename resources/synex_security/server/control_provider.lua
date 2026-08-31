SynexSecurityControlProvider = {}

local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')

local PLAYER_INPUT = { fields = {{
    key = 'id', label = 'Subject reference', source = 'id', type = 'string',
    format = 'identifier', required = true, minLength = 3, maxLength = 128,
}} }

local CASE_INPUT = { fields = {{
    key = 'id', label = 'Case ID', source = 'id', type = 'string',
    format = 'identifier', required = true, minLength = 8, maxLength = 64,
}} }

local VIEWS = {
    { id = 'overview', label = 'Security overview', operation = 'summary',
        presentation = 'key-value', order = 10,
        description = 'Bounded signal, expectation, case, mitigation, and enforcement totals.',
        accessClass = 'security' },
    { id = 'health', label = 'Security health', operation = 'health',
        presentation = 'key-value', order = 20,
        description = 'Detector, Sentinel, persistence, Core, and event-hook health.',
        accessClass = 'security' },
    { id = 'detectors', label = 'Detectors', operation = 'list',
        presentation = 'table', order = 30,
        description = 'Configured mode and bounded runtime health for each detector.',
        accessClass = 'security' },
    { id = 'cases', label = 'Security cases', operation = 'list',
        presentation = 'table', order = 40,
        description = 'Cursor-bounded case summaries without raw client telemetry.',
        accessClass = 'security' },
    { id = 'player', label = 'Player assessment', operation = 'inspect',
        presentation = 'detail', order = 50,
        description = 'Security-authorized subject assessment, expectations, cases, and enforcement history.',
        accessClass = 'security', input = PLAYER_INPUT },
    { id = 'case', label = 'Case inspector', operation = 'inspect',
        presentation = 'timeline', order = 60,
        description = 'Bounded case timeline, evidence classes, policy, and enforcement provenance.',
        accessClass = 'security', input = CASE_INPUT },
    { id = 'hardening', label = 'Cfx hardening advisor', operation = 'findings',
        presentation = 'findings', order = 70,
        description = 'Read-only Cfx hardening recommendations and compatibility impact.',
        accessClass = 'security' },
    { id = 'performance', label = 'Security metrics', operation = 'metrics',
        presentation = 'metrics', order = 80,
        description = 'Bounded detector, case, mitigation, and ingestion measurements.',
        accessClass = 'security' },
    { id = 'findings', label = 'Doctor findings', operation = 'findings',
        presentation = 'findings', order = 90,
        description = 'Runtime health, retained pipeline, and Cfx hardening findings.',
        accessClass = 'security' },
}

function SynexSecurityControlProvider.create(options)
    local diagnostics = assert(options.diagnostics, 'security control provider requires diagnostics')
    local provider = {}

    local function exact(request, optional)
        local allowed = { view = true }
        for _, key in ipairs(optional or {}) do allowed[key] = true end
        if not Validation.exactObject(request or {}, allowed, { view = true })
            or not Validation.text(request.view, 2, 48) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security control request is invalid.')
        end
        return request
    end

    local operations = {}
    function operations.summary(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'overview' then return nil, operationError or {
            code = 'SECURITY_INVALID_REQUEST', message = 'Security overview view is invalid.' } end
        return diagnostics.summary(), nil
    end
    function operations.health(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'health' then return nil, operationError or {
            code = 'SECURITY_INVALID_REQUEST', message = 'Security health view is invalid.' } end
        return diagnostics.health(), nil
    end
    function operations.list(request)
        local value, operationError = exact(request, { 'cursor', 'limit', 'filters', 'sort' })
        if not value then return nil, operationError end
        if value.filters ~= nil and next(value.filters) ~= nil
            or value.sort ~= nil and next(value.sort) ~= nil then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security lists do not accept arbitrary filters or sorting.')
        end
        local cursor = value.cursor
        if type(cursor) == 'string' and cursor:match('^[0-9]+$') then cursor = tonumber(cursor) end
        if cursor ~= nil and not Validation.isInteger(cursor, 0, 1000000)
            or value.limit ~= nil and not Validation.isInteger(value.limit, 1, 100) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security pagination is invalid.')
        end
        local page, pageError = diagnostics.list(value.view, cursor, value.limit)
        if page and page.nextCursor ~= nil then page.nextCursor = tostring(page.nextCursor) end
        return page, pageError
    end
    function operations.inspect(request)
        local value, operationError = exact(request, { 'id' })
        if not value or not Validation.text(value.id, 3, 128) then return nil,
            operationError or { code = 'SECURITY_INVALID_REQUEST',
                message = 'Security inspector identity is invalid.' } end
        return diagnostics.inspect(value.view, value.id)
    end
    function operations.metrics(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'performance' then return nil, operationError or {
            code = 'SECURITY_INVALID_REQUEST', message = 'Security metrics view is invalid.' } end
        return diagnostics.metrics()
    end
    function operations.findings(request)
        local value, operationError = exact(request, { 'cursor', 'limit', 'filters', 'sort' })
        if not value or value.cursor ~= nil
            or value.filters ~= nil and next(value.filters) ~= nil
            or value.sort ~= nil and next(value.sort) ~= nil
            or value.limit ~= nil and not Validation.isInteger(value.limit, 1, 100) then
            return nil, operationError or { code = 'SECURITY_INVALID_REQUEST',
                message = 'Security findings view is invalid.' }
        end
        if value.view == 'hardening' then return diagnostics.hardening() end
        if value.view == 'findings' then return diagnostics.doctor(value.limit) end
        return Validation.failure('SECURITY_INVALID_REQUEST',
            'Security findings view is invalid.')
    end

    local bounded = {}
    for name, handler in pairs(operations) do
        bounded[name] = function(...)
            local value, operationError = Foundation.protect(handler, ...)
            if value == nil then return nil, Foundation.publicError(operationError) end
            return value, nil
        end
    end

    function provider.register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not Validation.isCallable(register) then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'The Core control-provider registry is unavailable.', true)
        end
        return register({
            schemaVersion = 1,
            namespace = 'security',
            label = 'Security',
            category = 'foundation',
            version = '1.0.0',
            operations = bounded,
            views = VIEWS,
        })
    end

    provider.views, provider.operations = VIEWS, operations
    return provider
end
