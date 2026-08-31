-- Advisory telemetry only. Every value in this file can be forged or suppressed by
-- a compromised client; authoritative security decisions remain server-side.

local CONTRACT = 'synex.security.sentinel.report'
local CONTRACT_VERSION = '1.0.0'
local BOOTSTRAP_CHALLENGE = 'bootstrap'
local DEFAULT_INTERVAL_MS = 3000
local MINIMUM_INTERVAL_MS = 1000
local MAXIMUM_INTERVAL_MS = 30000
local RPC_TIMEOUT_MS = 5000

local active = true
local sequence = 0
local challengeRef = BOOTSTRAP_CHALLENGE
local nextIntervalMs = DEFAULT_INTERVAL_MS
local timer = math.max(0, tonumber(GetGameTimer()) or 0)
local clientEpoch = math.floor(timer % 2147483647) + 1
local pending = nil

local function rebootstrap()
    local current = math.max(0, tonumber(GetGameTimer()) or 0)
    clientEpoch = (clientEpoch + math.floor(current) + 1) % 9007199254740991
    if clientEpoch < 1 then clientEpoch = 1 end
    sequence = 0
    challengeRef = BOOTSTRAP_CHALLENGE
    pending = nil
end

local function finite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or 0
    if not finite(value) then return 0 end
    return math.max(minimum, math.min(maximum, value))
end

local function integer(value, minimum, maximum)
    return math.floor(clamp(value, minimum, maximum))
end

local function unsignedHash(value)
    value = tonumber(value) or 0
    if not finite(value) then return 0 end
    return math.floor(value) % 4294967296
end

local function vectorValue(value, key, index)
    if value == nil then return 0 end
    local ok, resolved = pcall(function() return value[key] end)
    if ok and finite(resolved) then return resolved end
    ok, resolved = pcall(function() return value[index] end)
    return ok and finite(resolved) and resolved or 0
end

local function vector3(value, minimum, maximum)
    return {
        clamp(vectorValue(value, 'x', 1), minimum, maximum),
        clamp(vectorValue(value, 'y', 2), minimum, maximum),
        clamp(vectorValue(value, 'z', 3), minimum, maximum),
    }
end

local function safeNative(handler, fallback, ...)
    local ok, value = pcall(handler, ...)
    if not ok or value == nil then return fallback end
    return value
end

local function sample()
    local ped = tonumber(safeNative(PlayerPedId, 0)) or 0
    local position = ped > 0 and safeNative(GetEntityCoords, nil, ped, false) or nil
    local velocity = ped > 0 and safeNative(GetEntityVelocity, nil, ped) or nil
    local camera = safeNative(GetGameplayCamCoord, nil)
    return {
        position = vector3(position, -20000, 20000),
        velocity = vector3(velocity, -1000, 1000),
        camera = vector3(camera, -20000, 20000),
        health = integer(ped > 0 and safeNative(GetEntityHealth, 0, ped) or 0,
            0, 1000),
        armor = integer(ped > 0 and safeNative(GetPedArmour, 0, ped) or 0,
            0, 1000),
        visible = ped <= 0 or safeNative(IsEntityVisible, true, ped) == true,
        alpha = integer(ped > 0 and safeNative(GetEntityAlpha, 255, ped) or 255,
            0, 255),
        model = unsignedHash(ped > 0 and safeNative(GetEntityModel, 0, ped) or 0),
        weapon = unsignedHash(ped > 0
            and safeNative(GetSelectedPedWeapon, 0, ped) or 0),
        movement = {
            inVehicle = ped > 0 and safeNative(IsPedInAnyVehicle, false, ped, false) == true,
            ragdoll = ped > 0 and safeNative(IsPedRagdoll, false, ped) == true,
            falling = ped > 0 and safeNative(IsPedFalling, false, ped) == true,
            parachute = integer(ped > 0
                and safeNative(GetPedParachuteState, -1, ped) or -1, -1, 3),
        },
    }
end

local function createReport()
    sequence = sequence + 1
    return {
        clientEpoch = clientEpoch,
        sequence = sequence,
        sampledAtMs = math.floor(math.max(0, GetGameTimer()) % 4294967296),
        challengeRef = challengeRef,
        sample = sample(),
    }
end

local function call(report)
    local ok, value, operationError = pcall(function()
        return exports.synex_core:Call(CONTRACT, CONTRACT_VERSION, report, {
            timeoutMs = RPC_TIMEOUT_MS,
        })
    end)
    if ok and type(operationError) == 'table'
        and (operationError.code == 'SECURITY_SENTINEL_REPLAY'
            or operationError.code == 'SECURITY_SENTINEL_STALE') then
        rebootstrap()
        return 'reset'
    end
    if not ok or value == false or type(value) ~= 'table'
        or operationError ~= nil or value.accepted ~= true
        or type(value.nextChallengeRef) ~= 'string'
        or #value.nextChallengeRef < 8 or #value.nextChallengeRef > 64 then
        return false
    end
    challengeRef = value.nextChallengeRef
    nextIntervalMs = integer(value.nextReportAfterMs or DEFAULT_INTERVAL_MS,
        MINIMUM_INTERVAL_MS, MAXIMUM_INTERVAL_MS)
    return true
end

CreateThread(function()
    while active do
        pending = pending or createReport()
        local result = call(pending)
        if result == true then pending = nil end
        Wait(nextIntervalMs)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        active = false
        pending = nil
    end
end)
