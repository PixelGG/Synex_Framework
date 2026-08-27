local transport = assert(SynexBridgeClient,
    'synex_bridge native client library is unavailable').create({
    requestEvent = 'synex_bridge_qb:server:callback',
    responseEvent = 'synex_bridge_qb:client:callback',
})

local FACADE_RESOURCE = 'qb-core'
local currentPlayerData = {}
local authorizedConsumers = { playerData = {}, callbacks = {} }

local function isCallable(value)
    if type(value) == 'function' then return true end
    local valueType = type(value)
    if valueType ~= 'table' and valueType ~= 'userdata' then return false end
    local metatable = getmetatable(value)
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetatable = pcall(debug.getmetatable, value)
        if readable then metatable = rawMetatable end
    end
    return type(metatable) == 'table'
        and type(rawget(metatable, '__call')) == 'function'
end

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item, seen) end
    seen[value] = nil
    return result
end

local function validConsumer(value)
    return type(value) == 'string' and #value >= 2 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function consumerSet(value)
    if type(value) ~= 'table' then return nil end
    local count = rawlen(value)
    if count > 128 then return nil end
    local present = 0
    for key in next, value do
        if type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > count then return nil end
        present = present + 1
    end
    if present ~= count then return nil end
    local result, previous = {}, nil
    for index = 1, count do
        local consumer = rawget(value, index)
        if not validConsumer(consumer) or previous ~= nil and previous >= consumer then
            return nil
        end
        result[consumer], previous = true, consumer
    end
    return result
end

local function readClientAccess(value)
    if type(value) ~= 'table' then return nil end
    for key in next, value do
        if key ~= 'playerData' and key ~= 'callbacks' then return nil end
    end
    local playerData = consumerSet(rawget(value, 'playerData'))
    local callbacks = consumerSet(rawget(value, 'callbacks'))
    if not playerData or not callbacks then return nil end
    for consumer in pairs(callbacks) do
        if playerData[consumer] ~= true then return nil end
    end
    return { playerData = playerData, callbacks = callbacks }
end

local function hasAccess(consumer, surface)
    return validConsumer(consumer)
        and type(authorizedConsumers[surface]) == 'table'
        and authorizedConsumers[surface][consumer] == true
end

local function getPlayerData(consumer, callback)
    if not hasAccess(consumer, 'playerData') then return nil end
    local data = copy(currentPlayerData)
    if callback == nil then return data end
    if not isCallable(callback) then return nil end
    pcall(callback, data)
    return nil
end

local function triggerCallback(consumer, name, ...)
    if not hasAccess(consumer, 'callbacks') then return nil end
    local arguments = table.pack(...)
    local callback = arguments[1]
    if isCallable(callback) then
        return transport:triggerCallback(consumer, name, callback,
            table.unpack(arguments, 2, arguments.n))
    end
    if type(promise) ~= 'table' or type(promise.new) ~= 'function'
        or type(Citizen) ~= 'table' or type(Citizen.Await) ~= 'function' then
        return nil
    end
    local created, deferred = pcall(promise.new)
    if not created or deferred == nil then return nil end
    local started = transport:triggerCallback(consumer, name, function(...)
        deferred:resolve(table.pack(...))
    end, table.unpack(arguments, 1, arguments.n))
    if not started then return nil end
    local response = Citizen.Await(deferred)
    if type(response) == 'table' and type(response.n) == 'number'
        and math.type(response.n) == 'integer' and response.n >= 0
        and response.n <= 16 then
        return table.unpack(response, 1, response.n)
    end
    return response
end

local function coreObject(consumer, filters)
    local functions = {}
    if hasAccess(consumer, 'playerData') then
        functions.GetPlayerData = function(callback)
            return getPlayerData(consumer, callback)
        end
    end
    if hasAccess(consumer, 'callbacks') then
        functions.TriggerCallback = function(name, ...)
            return triggerCallback(consumer, name, ...)
        end
    end
    if next(functions) == nil then return nil end
    local object = { Functions = functions }
    if filters == nil then return object end
    if type(filters) ~= 'table' or #filters > 8 then return nil end
    local count, seen = 0, {}
    for key, value in pairs(filters) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > #filters or type(value) ~= 'string'
            or #value < 1 or #value > 32 or seen[value] then return nil end
        count, seen[value] = count + 1, true
    end
    if count ~= #filters then return nil end
    local filtered = {}
    for _, name in ipairs(filters) do
        if object[name] ~= nil then filtered[name] = object[name] end
    end
    return filtered
end

RegisterNetEvent('synex_bridge_qb:client:projection', function(
    action, playerData, clientAccess)
    if source ~= 65535 then return end
    local access = action == 'replace' and readClientAccess(clientAccess) or nil
    if access and next(access.playerData) ~= nil and type(playerData) == 'table' then
        currentPlayerData = copy(playerData)
        authorizedConsumers = access
    elseif action == 'clear' then
        currentPlayerData = {}
        authorizedConsumers = { playerData = {}, callbacks = {} }
    elseif action == 'replace' then
        currentPlayerData = {}
        authorizedConsumers = { playerData = {}, callbacks = {} }
    end
end)

exports('GetCoreObject', function(filters)
    return coreObject(GetInvokingResource(), filters)
end)
exports('GetPlayerData', function(callback)
    return getPlayerData(GetInvokingResource(), callback)
end)
exports('GetCoreObjectForConsumer', function(consumer, filters)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(consumer) then return nil end
    return coreObject(consumer, filters)
end)
exports('GetPlayerDataForConsumer', function(consumer, callback)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(consumer) then return nil end
    return getPlayerData(consumer, callback)
end)
