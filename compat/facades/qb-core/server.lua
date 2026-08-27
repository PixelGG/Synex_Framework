local function consumer()
    local resource = GetInvokingResource()
    if type(resource) ~= 'string' or #resource < 2 or #resource > 64
        or not resource:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') then
        return nil
    end
    return resource
end

exports('GetCoreObject', function(filters)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qb:GetCoreObjectForConsumer(caller, filters)
end)

exports('GetPlayer', function(playerSource)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qb:GetPlayerForConsumer(caller, playerSource)
end)

exports('GetPlayerByCitizenId', function(citizenId)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qb:GetPlayerByCitizenIdForConsumer(
        caller, citizenId)
end)
