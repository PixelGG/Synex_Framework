SynexControlProtocol = {}

local protocol = SynexControlProtocol

local operations = {
    overview = true,
    providers = true,
    section = true,
    inspect = true,
    search = true,
    page = true,
    simulate = true,
}

local allowedKeys = {
    requestId = true,
    operation = true,
    provider = true,
    view = true,
    id = true,
    cursor = true,
    limit = true,
    filters = true,
    sort = true,
    query = true,
}

local function exactObject(value, allowed, maximum)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in next, value do
        count = count + 1
        if count > maximum or type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

local function safeIdentifier(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function safeLookupIdentifier(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:@*%-]*$') ~= nil
end

local function safeName(value, maximum)
    return type(value) == 'string' and #value >= 1 and #value <= maximum
        and value:match('^[a-z][a-z0-9_.-]*$') ~= nil
        and value:match('[_.-]$') == nil
        and value:match('[_.-][_.-]') == nil
end

local function validateFilters(value)
    if value == nil then return {}, true end
    if type(value) ~= 'table' then return nil, false end
    local result, count = {}, 0
    for key, candidate in next, value do
        count = count + 1
        if count > SynexControlLimits.maximumFilters
            or not safeName(key, SynexControlLimits.maximumFilterKeyBytes) then
            return nil, false
        end
        local kind = type(candidate)
        if kind == 'string' then
            if #candidate > SynexControlLimits.maximumFilterValueBytes
                or candidate:find('[%z\1-\31\127]') then return nil, false end
            result[key] = candidate
        elseif kind == 'boolean' then
            result[key] = candidate
        elseif kind == 'number' and candidate == candidate
            and candidate ~= math.huge and candidate ~= -math.huge then
            result[key] = candidate
        else
            return nil, false
        end
    end
    return result, true
end

local function validateSort(value)
    if value == nil then return nil, true end
    if not exactObject(value, { field = true, direction = true }, 2)
        or not safeName(value.field, SynexControlLimits.maximumSortFieldBytes)
        or value.direction ~= 'asc' and value.direction ~= 'desc' then
        return nil, false
    end
    return { field = value.field, direction = value.direction }, true
end

local function validateQuery(value)
    if not exactObject(value, { kind = true, value = true, mode = true }, 3)
        or not safeName(value.kind, 32)
        or type(value.value) ~= 'string' or #value.value < 1
        or #value.value > SynexControlLimits.maximumSearchBytes
        or value.value:find('[%z\1-\31\127]') then return nil end
    local mode = value.mode or 'exact'
    if mode ~= 'exact' and mode ~= 'prefix' then return nil end
    if mode == 'prefix' and #value.value < 2 then return nil end
    if value.kind == 'resource' then
        if mode == 'prefix' then
            if #value.value > 64 or value.value:match('^[a-z][a-z0-9_.-]*$') == nil
                or value.value:match('[_.-][_.-]') ~= nil then return nil end
        elseif not safeName(value.value, 64) then return nil end
    elseif not safeLookupIdentifier(value.value, mode == 'prefix' and 2 or 1, 128) then
        return nil
    end
    return {
        kind = value.kind,
        mode = mode,
        value = value.value,
    }
end

function protocol.validate(request)
    if not exactObject(request, allowedKeys, 11) then return nil, 'INVALID_ARGUMENT' end
    local encoded, payload = pcall(json.encode, request)
    if not encoded or type(payload) ~= 'string'
        or #payload > SynexControlLimits.maximumRequestBytes then
        return nil, 'REQUEST_TOO_LARGE'
    end
    if not safeIdentifier(request.requestId, 8, SynexControlLimits.maximumRequestIdBytes)
        or not operations[request.operation] then return nil, 'INVALID_ARGUMENT' end

    local provider = request.provider
    local view = request.view
    local cursor = request.cursor
    local id = request.id
    if provider ~= nil and not safeName(provider, SynexControlLimits.maximumProviderBytes) then
        return nil, 'INVALID_ARGUMENT'
    end
    if view ~= nil and not safeName(view, SynexControlLimits.maximumViewBytes) then
        return nil, 'INVALID_ARGUMENT'
    end
    if cursor ~= nil and (type(cursor) ~= 'string' or #cursor < 1
        or #cursor > SynexControlLimits.maximumCursorBytes
        or cursor:find('[%z\1-\31\127]')) then return nil, 'INVALID_CURSOR' end
    if id ~= nil and not safeLookupIdentifier(id, 1, SynexControlLimits.maximumIdentifierBytes) then
        return nil, 'INVALID_ARGUMENT'
    end
    local limit = request.limit or SynexControlLimits.defaultPageSize
    if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
        or limit < 1 or limit > SynexControlLimits.maximumPageSize then
        return nil, 'INVALID_LIMIT'
    end
    local filters, filtersValid = validateFilters(request.filters)
    local sort, sortValid = validateSort(request.sort)
    if not filtersValid or not sortValid then return nil, 'INVALID_ARGUMENT' end

    local operation = request.operation
    if operation == 'overview' then
        if provider ~= nil or view ~= nil or id ~= nil or cursor ~= nil
            or request.filters ~= nil or request.sort ~= nil or request.query ~= nil then
            return nil, 'INVALID_ARGUMENT'
        end
    elseif operation == 'providers' then
        if provider ~= nil or view ~= nil or id ~= nil
            or request.filters ~= nil or request.sort ~= nil or request.query ~= nil then
            return nil, 'INVALID_ARGUMENT'
        end
    elseif operation == 'section' or operation == 'page' then
        if not provider or not view or id ~= nil or request.query ~= nil then
            return nil, 'INVALID_ARGUMENT'
        end
    elseif operation == 'inspect' then
        if not provider or not view or not id
            or cursor ~= nil or request.query ~= nil then return nil, 'INVALID_ARGUMENT' end
    elseif operation == 'simulate' then
        if not provider or not view or id ~= nil or cursor ~= nil
            or request.query ~= nil or request.sort ~= nil then
            return nil, 'INVALID_ARGUMENT'
        end
    elseif operation == 'search' then
        local query = validateQuery(request.query)
        if not query or not provider or not view or id ~= nil then return nil, 'INVALID_ARGUMENT' end
        request = {
            requestId = request.requestId,
            operation = operation,
            provider = provider,
            view = view,
            cursor = cursor,
            limit = limit,
            filters = filters,
            sort = sort,
            query = query,
        }
        return request, nil
    end

    return {
        requestId = request.requestId,
        operation = operation,
        provider = provider,
        view = view,
        id = id,
        cursor = cursor,
        limit = limit,
        filters = filters,
        sort = sort,
    }, nil
end

function protocol.requestCost(operation, provider, view)
    if operation == 'search' then return 2 end
    if operation == 'inspect' then return 2 end
    if operation == 'simulate' then return 3 end
    if provider == 'core' and (view == 'tracing' or view == 'audit') then return 3 end
    if operation == 'section' or operation == 'page' then return 1 end
    return 1
end
