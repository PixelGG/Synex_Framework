local Sensor = SynexInteractContextSensor
local RESOURCE = GetCurrentResourceName()

local snapshot = { items = {}, worldContext = nil, registryRevision = 0 }
local primary, primaryScore = nil, nil
local uiApi
local lastQueryAt = 0
local queryInterval = 250
local queryInFlight = false
local interactionBusy = false
local latestHitNetId = nil

local function rpc(name, payload, timeoutMs)
    local value, operationError = exports['synex_core']:Call(name, '1.0.0', payload or {}, {
        timeoutMs = timeoutMs or 2500,
        traceId = ('interact_client_%08x'):format(GetGameTimer() & 0xffffffff),
    })
    if value == false and type(operationError) == 'table' then return nil, operationError end
    return value, operationError
end

local function ui()
    if uiApi then return uiApi end
    if GetResourceState('synex_ui') ~= 'started' then return nil end
    local ok, api = pcall(function() return exports['synex_ui']:GetAPI('^1.0.0') end)
    if ok and type(api) == 'table' then uiApi = api end
    return uiApi
end

local function decorateCandidate(candidate, sample)
    local position = candidate.position
    if type(position) ~= 'table' then return candidate end
    local dx = position.x - sample.camera.x
    local dy = position.y - sample.camera.y
    local dz = position.z - sample.camera.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length > 0.0001 then
        local dot = (dx / length) * sample.forward.x + (dy / length) * sample.forward.y + (dz / length) * sample.forward.z
        candidate.gazeScore = math.max(0, math.min(1, (dot + 1) * 0.5))
    else
        candidate.gazeScore = 1
    end
    candidate.lineOfSight = HasEntityClearLosToCoord(PlayerPedId(), position.x, position.y, position.z, 17)
    return candidate
end

local function choosePrimary(sample)
    local candidates = {}
    for _, candidate in ipairs(snapshot.items or {}) do
        candidates[#candidates + 1] = decorateCandidate(candidate, sample)
    end
    primary, primaryScore = Sensor.choose(candidates, sample)
end

local function drawText(x, y, text, scale, alpha)
    SetTextFont(0)
    SetTextScale(0.0, scale)
    SetTextColour(245, 247, 250, alpha or 235)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function drawAffordance(candidate)
    if not candidate or type(candidate.position) ~= 'table' then return end
    local visible, sx, sy = World3dToScreen2d(candidate.position.x, candidate.position.y,
        candidate.position.z + 0.08)
    if not visible then return end
    local count = 0
    for _, item in ipairs(snapshot.items or {}) do
        if item.objectKey == candidate.objectKey then count = count + 1 end
    end
    local width = math.min(0.19, math.max(0.095, 0.062 + (#(candidate.label or '') * 0.0024)))
    DrawRect(sx, sy + 0.018, width, 0.037, 10, 13, 18, 188)
    DrawRect(sx - width * 0.5 + 0.002, sy + 0.018, 0.0025, 0.029, 215, 222, 232, 205)
    drawText(sx, sy + 0.007, ('[E]  %s%s'):format(candidate.label or 'Interact',
        count > 1 and ('   +%d'):format(count - 1) or ''), 0.29, 240)
end

local function executeCandidate(candidate)
    if not candidate or interactionBusy then return end
    interactionBusy = true
    local beginResult, beginError = rpc('synex.interact.begin', {
        objectKey = candidate.objectKey,
        actionKey = candidate.actionKey,
        revision = candidate.revision,
        worldContext = snapshot.worldContext,
    }, 3000)
    if not beginResult then interactionBusy = false; return nil, beginError end
    local result, executeError = rpc('synex.interact.execute', {
        leaseId = beginResult.lease.id,
        objectKey = candidate.objectKey,
        actionKey = candidate.actionKey,
        payload = {},
    }, 10000)
    interactionBusy = false
    return result, executeError
end

local function openActionMenu()
    if interactionBusy or not primary then return end
    local api = ui()
    if not api or type(api.contextMenu) ~= 'function' then return end
    local options, byId, count = {}, {}, 0
    for _, candidate in ipairs(snapshot.items or {}) do
        if candidate.objectKey == primary.objectKey then
            local id = candidate.objectKey .. '|' .. candidate.actionKey
            if not byId[id] then
                byId[id] = candidate
                count = count + 1
                options[#options + 1] = {
                    id = id,
                    label = candidate.label,
                    description = candidate.description,
                    icon = candidate.icon,
                }
            end
        end
    end
    if count < 2 then return end
    local result = api.contextMenu({
        title = 'Interaktion',
        options = options,
        searchable = false,
    })
    if type(result) == 'table' and result.status == 'confirmed' then
        local id = result.value or result.selected or result.id
        if byId[id] then executeCandidate(byId[id]) end
    end
end

local function refreshCandidates()
    if queryInFlight or interactionBusy then return end
    queryInFlight = true
    local payload = { radius = 6.0 }
    if latestHitNetId then payload.hitNetId = latestHitNetId end
    local result = rpc('synex.interact.candidates', payload, 1800)
    queryInFlight = false
    if type(result) == 'table' and type(result.items) == 'table' then snapshot = result end
end

local function netIdForSample(sample)
    local entity = sample and sample.entity or nil
    if not entity or entity <= 0 or not DoesEntityExist(entity) or not NetworkGetEntityIsNetworked(entity) then
        return nil
    end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if type(netId) ~= 'number' or netId < 1 or netId > 65535 then return nil end
    return netId
end

CreateThread(function()
    while true do
        local sample = Sensor.sample(6.0)
        if sample then
            latestHitNetId = netIdForSample(sample)
            choosePrimary(sample)
            local now = GetGameTimer()
            if now - lastQueryAt >= queryInterval then
                lastQueryAt = now
                CreateThread(refreshCandidates)
            end
            if primary and primaryScore and primaryScore > -math.huge then
                drawAffordance(primary)
                if IsControlJustReleased(0, 38) then
                    local selected = primary
                    CreateThread(function() executeCandidate(selected) end)
                elseif IsControlJustReleased(0, 47) then
                    CreateThread(openActionMenu)
                end
                Wait(0)
            else
                Wait(75)
            end
        else
            primary = nil
            latestHitNetId = nil
            Wait(250)
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'synex_ui' then uiApi = nil end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'synex_ui' then uiApi = nil end
    if resource ~= RESOURCE then return end
    primary = nil
    latestHitNetId = nil
    snapshot = { items = {}, worldContext = nil, registryRevision = 0 }
end)
