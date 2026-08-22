local isOpen = false
local lastRefreshAt = -SynexControlLimits.clientRefreshMilliseconds
local lastSearchAt = -SynexControlLimits.clientSearchMilliseconds

local function closePanel()
    if not isOpen then
        SetNuiFocus(false, false)
        return
    end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
end

local function openPanel(snapshot)
    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = 'open',
        snapshot = snapshot,
    })
end

RegisterNetEvent('synex_control:snapshot', function(message)
    if source ~= 65535 or type(message) ~= 'table' or type(message.snapshot) ~= 'table' then
        return
    end
    if message.open == true then
        openPanel(message.snapshot)
    elseif isOpen then
        SendNUIMessage({
            type = 'snapshot',
            snapshot = message.snapshot,
        })
    end
end)

RegisterNUICallback('close', function(_, callback)
    closePanel()
    callback({ ok = true })
end)

RegisterNUICallback('refresh', function(_, callback)
    if not isOpen then
        callback({ ok = false, error = 'CLOSED' })
        return
    end
    local now = GetGameTimer()
    if now - lastRefreshAt < SynexControlLimits.clientRefreshMilliseconds then
        callback({ ok = false, error = 'RATE_LIMITED' })
        return
    end
    lastRefreshAt = now
    TriggerServerEvent('synex_control:refresh')
    callback({ ok = true })
end)

RegisterNUICallback('search', function(request, callback)
    if not isOpen then
        callback({ ok = false, error = 'CLOSED' })
        return
    end
    if type(request) ~= 'table' then
        callback({ ok = false, error = 'INVALID_ARGUMENT' })
        return
    end
    for key in pairs(request) do
        if key ~= 'kind' and key ~= 'value' then
            callback({ ok = false, error = 'INVALID_ARGUMENT' })
            return
        end
    end
    local kinds = { trace = true, character = true, transaction = true, resource = true }
    if not kinds[request.kind] or type(request.value) ~= 'string'
        or #request.value < 2 or #request.value > SynexControlLimits.maximumSearchBytes
        or request.value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        callback({ ok = false, error = 'INVALID_ARGUMENT' })
        return
    end
    local now = GetGameTimer()
    if now - lastSearchAt < SynexControlLimits.clientSearchMilliseconds then
        callback({ ok = false, error = 'RATE_LIMITED' })
        return
    end
    lastSearchAt = now
    TriggerServerEvent('synex_control:search', {
        kind = request.kind,
        value = request.value,
    })
    callback({ ok = true })
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        closePanel()
    end
end)
