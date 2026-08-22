local transport = assert(SynexBridgeClient, 'synex_bridge native client library is unavailable').create({
    requestEvent = 'synex_bridge_esx:server:callback',
    responseEvent = 'synex_bridge_esx:client:callback',
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

RegisterNetEvent('esx:playerLoaded', function(playerData)
    if source ~= 65535 or type(playerData) ~= 'table' then return end
    currentPlayerData = copy(playerData)
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    if source ~= 65535 then return end
    currentPlayerData = {}
end)

local sharedObject = {
    Compatibility = { framework = 'esx', status = 'partial', deprecated = true },
    GetPlayerData = function() return copy(currentPlayerData) end,
    TriggerServerCallback = function(name, callback, ...)
        return transport:triggerCallback(name, callback, ...)
    end,
}

exports('getSharedObject', function() return sharedObject end)
exports('GetPlayerData', function() return copy(currentPlayerData) end)
