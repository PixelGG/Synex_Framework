local transport = assert(SynexBridgeClient,
    'synex_bridge native client library is unavailable').create({
    requestEvent = 'synex_bridge_esx:server:callback',
    responseEvent = 'synex_bridge_esx:client:callback',
})

local FACADE_RESOURCE = 'es_extended'
local currentPlayerData = {}
local authorizedConsumers = { playerData = {}, callbacks = {} }

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

local function playerDataFor(consumer)
    if not hasAccess(consumer, 'playerData') then return nil end
    return copy(currentPlayerData)
end

local function sharedObject(consumer)
    local object = {}
    if hasAccess(consumer, 'playerData') then
        object.GetPlayerData = function()
            return playerDataFor(consumer)
        end
    end
    if hasAccess(consumer, 'callbacks') then
        object.TriggerServerCallback = function(name, callback, ...)
            if not hasAccess(consumer, 'callbacks') then return false end
            return transport:triggerCallback(consumer, name, callback, ...)
        end
    end
    return next(object) ~= nil and object or nil
end

RegisterNetEvent('synex_bridge_esx:client:projection', function(
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

exports('getSharedObject', function()
    return sharedObject(GetInvokingResource())
end)
exports('GetPlayerData', function()
    return playerDataFor(GetInvokingResource())
end)
exports('GetSharedObjectForConsumer', function(consumer)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(consumer) then return nil end
    return sharedObject(consumer)
end)
exports('GetPlayerDataForConsumer', function(consumer)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(consumer) then return nil end
    return playerDataFor(consumer)
end)
