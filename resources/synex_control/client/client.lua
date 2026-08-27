local PROTOCOL_VERSION = SynexControlLimits.protocolVersion
local desiredOpen = false
local nuiReady = false
local lastRequestAt = {}
local lastErrorAt = -SynexControlLimits.clientErrorMilliseconds

local operations = {
    inspect = true,
    overview = true,
    page = true,
    providers = true,
    search = true,
    section = true,
    simulate = true,
}

local operationCooldowns = {
    inspect = SynexControlLimits.clientInspectMilliseconds,
    overview = SynexControlLimits.clientRefreshMilliseconds,
    page = SynexControlLimits.clientPageMilliseconds,
    providers = SynexControlLimits.clientProviderMilliseconds,
    search = SynexControlLimits.clientSearchMilliseconds,
    section = SynexControlLimits.clientRequestMilliseconds,
    simulate = SynexControlLimits.clientInspectMilliseconds,
}

local allowedRequestKeys = {
    cursor = true,
    filters = true,
    id = true,
    limit = true,
    operation = true,
    provider = true,
    query = true,
    requestId = true,
    sort = true,
    view = true,
}

local function reply(callback, ok, code, data)
    if ok then
        callback({ ok = true, data = data or {} })
        return
    end
    callback({ ok = false, error = { code = code or 'INVALID_REQUEST' } })
end

local function releaseFocus()
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
end

local function syncVisibility(reason)
    if not desiredOpen then releaseFocus() end
    if not nuiReady then return end
    SendNUIMessage({
        type = 'control:visibility',
        version = PROTOCOL_VERSION,
        payload = {
            open = desiredOpen,
            reason = reason,
        },
    })
    if desiredOpen then
        SetNuiFocusKeepInput(false)
        SetNuiFocus(true, true)
    end
end

local function setOpen(open, reason)
    desiredOpen = open == true
    syncVisibility(reason)
end

local function validBoundedString(value, maximum, pattern, minimum)
    return type(value) == 'string' and #value >= (minimum or 1) and #value <= maximum
        and (not pattern or value:match(pattern) ~= nil)
end

local function validCursor(value)
    return value == nil or validBoundedString(value, SynexControlLimits.maximumCursorBytes,
        '^[^%c]+$')
end

local function validFilters(filters)
    if filters == nil then return true end
    if type(filters) ~= 'table' then return false end
    local count = 0
    for key, value in pairs(filters) do
        count = count + 1
        if count > SynexControlLimits.maximumFilterEntries
            or not validBoundedString(key, SynexControlLimits.maximumKeyBytes,
                '^[a-z][a-zA-Z0-9_.%-]*$') then return false end
        local valueType = type(value)
        if valueType == 'string' then
            if #value > SynexControlLimits.maximumFilterValueBytes or value:find('%c') then return false end
        elseif valueType == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then return false end
        elseif valueType ~= 'boolean' then
            return false
        end
    end
    return true
end

local function validSort(sort)
    if sort == nil then return true end
    if type(sort) ~= 'table' then return false end
    for key in pairs(sort) do
        if key ~= 'direction' and key ~= 'field' then return false end
    end
    return validBoundedString(sort.field, SynexControlLimits.maximumKeyBytes,
        '^[a-z][a-zA-Z0-9_.%-]*$') and (sort.direction == 'asc' or sort.direction == 'desc')
end

local function validQuery(query)
    if type(query) ~= 'table' then return false end
    for key in pairs(query) do
        if key ~= 'kind' and key ~= 'mode' and key ~= 'value' then
            return false
        end
    end
    if not validBoundedString(query.kind, 32, '^[a-z][a-z0-9_%-]*$')
        or not validBoundedString(query.value, SynexControlLimits.maximumSearchBytes,
            '^[A-Za-z0-9][A-Za-z0-9_.:@*%-]*$', 2) then return false end
    if query.mode ~= 'exact' and query.mode ~= 'prefix' then return false end
    return true
end

local function validateRequest(request)
    if type(request) ~= 'table' then return nil end
    for key in pairs(request) do
        if not allowedRequestKeys[key] then return nil end
    end
    if not validBoundedString(request.requestId, SynexControlLimits.maximumRequestIdBytes,
        '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$', 8) or not operations[request.operation] then return nil end
    if request.limit ~= nil and (type(request.limit) ~= 'number'
        or math.type(request.limit) ~= 'integer' or request.limit < 1
        or request.limit > SynexControlLimits.maximumPageLimit) then return nil end
    if not validCursor(request.cursor) or not validFilters(request.filters)
        or not validSort(request.sort) then return nil end
    local providerPattern = '^[a-z][a-z0-9_.%-]*$'
    local viewPattern = '^[a-z][a-z0-9_.%-]*$'
    if request.provider ~= nil and not validBoundedString(request.provider,
        SynexControlLimits.maximumProviderBytes, providerPattern) then return nil end
    if request.view ~= nil and not validBoundedString(request.view,
        SynexControlLimits.maximumViewBytes, viewPattern) then return nil end
    if request.id ~= nil and not validBoundedString(request.id,
        SynexControlLimits.maximumIdentifierBytes, '^[A-Za-z0-9][A-Za-z0-9_.:@*%-]*$') then return nil end
    if request.operation == 'search' then
        if request.provider == nil or request.view == nil or request.id ~= nil
            or not validQuery(request.query) then return nil end
    elseif request.query ~= nil then
        return nil
    end
    if request.operation == 'section' or request.operation == 'page' then
        if request.provider == nil or request.view == nil then return nil end
    elseif request.operation == 'inspect' then
        if request.provider == nil or request.view == nil or request.id == nil
            or request.cursor ~= nil then return nil end
    elseif request.operation == 'simulate' then
        if request.provider == nil or request.view == nil or request.id ~= nil
            or request.cursor ~= nil or request.sort ~= nil or request.query ~= nil then
            return nil
        end
    elseif request.operation == 'overview' then
        if request.provider ~= nil or request.view ~= nil or request.id ~= nil
            or request.cursor ~= nil or request.filters ~= nil or request.sort ~= nil then return nil end
    elseif request.operation == 'providers' then
        if request.provider ~= nil or request.view ~= nil or request.id ~= nil
            or request.filters ~= nil or request.sort ~= nil then return nil end
    end
    local encoded, jsonValue = pcall(json.encode, request)
    if not encoded or type(jsonValue) ~= 'string'
        or #jsonValue > SynexControlLimits.maximumRequestBytes then return nil end
    return request
end

RegisterNetEvent('synex_control:open', function()
    if source ~= 65535 then return end
    if desiredOpen then return end
    setOpen(true, 'authorized')
end)

local function revokeAccess(code)
    desiredOpen = false
    lastRequestAt = {}
    releaseFocus()
    if nuiReady then
        SendNUIMessage({
            type = 'control:access-revoked',
            version = PROTOCOL_VERSION,
            payload = { code = code or 'ACCESS_REVOKED' },
        })
        syncVisibility('access_revoked')
    end
end

RegisterNetEvent('synex_control:access_revoked', function(message)
    if source ~= 65535 then return end
    local code = type(message) == 'table' and message.code or nil
    if code ~= nil and code ~= 'ACCESS_DENIED' and code ~= 'ACCESS_REVOKED' then return end
    revokeAccess(code)
end)

RegisterNetEvent('synex_control:response', function(response)
    if source ~= 65535 or type(response) ~= 'table'
        or (response.version ~= nil and response.version ~= PROTOCOL_VERSION)
        or not validBoundedString(response.requestId, SynexControlLimits.maximumRequestIdBytes,
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$', 8) then return end
    local encoded, jsonValue = pcall(json.encode, response)
    if not encoded or type(jsonValue) ~= 'string'
        or #jsonValue > SynexControlLimits.maximumResponseBytes then return end
    local errorCode = type(response.error) == 'table' and response.error.code or response.error
    if errorCode == 'ACCESS_DENIED' or errorCode == 'ACCESS_REVOKED' then
        revokeAccess(errorCode)
        return
    end
    if not desiredOpen or not nuiReady then return end
    SendNUIMessage({
        type = 'control:response',
        version = PROTOCOL_VERSION,
        response = response,
    })
end)

RegisterNetEvent('synex_control:invalidate', function(message)
    if source ~= 65535 or not desiredOpen or not nuiReady or type(message) ~= 'table'
        or message.reason ~= 'RESOURCE_STATE_CHANGED'
        or not validBoundedString(message.resource, 64, '^[a-z][a-z0-9_%-]*$')
        or (message.state ~= 'started' and message.state ~= 'stopped') then return end
    SendNUIMessage({
        type = 'control:invalidate',
        version = PROTOCOL_VERSION,
        payload = {
            reason = message.reason,
            resource = message.resource,
            state = message.state,
        },
    })
end)

RegisterNuiCallback('ready', function(request, callback)
    if type(request) ~= 'table' or request.version ~= PROTOCOL_VERSION then
        reply(callback, false, 'PROTOCOL_MISMATCH')
        return
    end
    nuiReady = true
    syncVisibility('ready')
    reply(callback, true, nil, { version = PROTOCOL_VERSION })
end)

RegisterNuiCallback('close', function(_, callback)
    local wasOpen = desiredOpen
    setOpen(false, 'user')
    if wasOpen then TriggerServerEvent('synex_control:closed') end
    reply(callback, true)
end)

RegisterNuiCallback('request', function(request, callback)
    if not desiredOpen or not nuiReady then
        reply(callback, false, 'CLOSED')
        return
    end
    local validated = validateRequest(request)
    if not validated then
        reply(callback, false, 'INVALID_REQUEST')
        return
    end
    local now = GetGameTimer()
    local lastAt = lastRequestAt[validated.operation]
        or -(operationCooldowns[validated.operation] or SynexControlLimits.clientRequestMilliseconds)
    local cooldown = operationCooldowns[validated.operation]
        or SynexControlLimits.clientRequestMilliseconds
    if now - lastAt < cooldown then
        reply(callback, false, 'RATE_LIMITED')
        return
    end
    lastRequestAt[validated.operation] = now
    TriggerServerEvent('synex_control:request', validated)
    reply(callback, true, nil, { requestId = validated.requestId })
end)

RegisterNuiCallback('reportError', function(request, callback)
    if type(request) ~= 'table' then
        reply(callback, false, 'INVALID_REQUEST')
        return
    end
    for key in pairs(request) do
        if key ~= 'code' and key ~= 'view' then
            reply(callback, false, 'INVALID_REQUEST')
            return
        end
    end
    if not validBoundedString(request.code, 64, '^[A-Z][A-Z0-9_]*$')
        or (request.view ~= nil and not validBoundedString(request.view, 64,
            '^[a-z][a-z0-9_.%-]*$')) then
        reply(callback, false, 'INVALID_REQUEST')
        return
    end
    local now = GetGameTimer()
    if now - lastErrorAt < SynexControlLimits.clientErrorMilliseconds then
        reply(callback, false, 'RATE_LIMITED')
        return
    end
    lastErrorAt = now
    TriggerServerEvent('synex_control:nui_error', {
        code = request.code,
        view = request.view,
    })
    reply(callback, true)
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    desiredOpen = false
    nuiReady = false
    lastRequestAt = {}
    releaseFocus()
end)
