local transport = assert(SynexBridgeClient, 'synex_bridge native client library is unavailable').create({
    requestEvent = 'synex_bridge_qb:server:callback',
    responseEvent = 'synex_bridge_qb:client:callback',
})

local currentPlayerData = {}

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

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function(playerData)
    if source ~= 65535 or type(playerData) ~= 'table' then return end
    currentPlayerData = copy(playerData)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    if source ~= 65535 then return end
    currentPlayerData = {}
end)

local coreObject = {
    Compatibility = { framework = 'qb', status = 'partial', deprecated = true },
    Functions = {
        GetPlayerData = function() return copy(currentPlayerData) end,
        TriggerCallback = function(name, callback, ...)
            return transport:triggerCallback(name, callback, ...)
        end,
    },
}

exports('GetCoreObject', function()
    return coreObject
end)

exports('GetPlayerData', function()
    return copy(currentPlayerData)
end)
