local function consumer()
    local resource = GetInvokingResource()
    if type(resource) ~= 'string' or #resource < 2 or #resource > 64
        or not resource:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') then
        return nil
    end
    return resource
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metadata = getmetatable(value)
    if type(metadata) ~= 'table' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable then metadata = rawMetadata end
    end
    return type(metadata) == 'table' and type(rawget(metadata, '__call')) == 'function'
end

exports('getSharedObject', function()
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetSharedObjectForConsumer(caller)
end)
exports('GetPlayerFromId', function(playerSource)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetPlayerFromIdForConsumer(caller, playerSource)
end)
exports('GetPlayerFromIdentifier', function(identifier)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetPlayerFromIdentifierForConsumer(
        caller, identifier)
end)
exports('GetPlayerIdFromIdentifier', function(identifier)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetPlayerIdFromIdentifierForConsumer(
        caller, identifier)
end)
exports('GetPlayers', function()
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetPlayersForConsumer(caller)
end)
exports('GetExtendedPlayers', function(key, value, minimal)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetExtendedPlayersForConsumer(
        caller, key, value, minimal)
end)
exports('RegisterServerCallback', function(name, handler)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:RegisterServerCallbackForConsumer(caller, name, handler)
end)

AddEventHandler('esx:getSharedObject', function(callback)
    local caller = consumer()
    if not caller or not isCallable(callback) then return end
    local object = exports.synex_bridge_esx:GetSharedObjectForConsumer(caller)
    if object then pcall(callback, object) end
end)
