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
exports('GetPlayerData', function()
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_esx:GetPlayerDataForConsumer(caller)
end)

AddEventHandler('esx:getSharedObject', function(callback)
    local caller = consumer()
    if not caller or not isCallable(callback) then return end
    local object = exports.synex_bridge_esx:GetSharedObjectForConsumer(caller)
    if object then pcall(callback, object) end
end)
