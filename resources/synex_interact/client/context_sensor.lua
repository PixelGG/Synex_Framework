SynexInteractContextSensor = {}

local Sensor = SynexInteractContextSensor

local function rotationToDirection(rotation)
    local z = math.rad(rotation.z)
    local x = math.rad(rotation.x)
    local cosX = math.abs(math.cos(x))
    return vector3(-math.sin(z) * cosX, math.cos(z) * cosX, math.sin(x))
end

function Sensor.sample(maxDistance)
    local ped = PlayerPedId()
    if ped <= 0 then return nil end
    local coords = GetEntityCoords(ped)
    local camera = GetGameplayCamCoord()
    local direction = rotationToDirection(GetGameplayCamRot(2))
    local destination = camera + direction * (maxDistance or 6.0)
    local ray = StartShapeTestLosProbe(camera.x, camera.y, camera.z,
        destination.x, destination.y, destination.z,
        -1, ped, 7)
    local _, hit, hitCoords, _, entity = GetShapeTestResult(ray)
    local speed = GetEntitySpeed(ped)
    return {
        player = { x = coords.x, y = coords.y, z = coords.z },
        camera = { x = camera.x, y = camera.y, z = camera.z },
        forward = { x = direction.x, y = direction.y, z = direction.z },
        hit = hit == 1,
        hitPosition = hit == 1 and { x = hitCoords.x, y = hitCoords.y, z = hitCoords.z } or nil,
        entity = entity and entity > 0 and entity or nil,
        speed = speed,
        inVehicle = IsPedInAnyVehicle(ped, false),
        timestamp = GetGameTimer(),
    }
end

function Sensor.score(candidate, sample)
    local distance = candidate.distance or math.huge
    local maxDistance = candidate.maxDistance or 2.5
    if distance > maxDistance then return -math.huge end
    local distanceScore = 1.0 - math.min(1.0, distance / maxDistance)
    local gazeScore = candidate.gazeScore or 0.5
    local lineOfSight = candidate.lineOfSight == false and 0 or 1
    local priority = candidate.priority or 0
    return priority * 100 + distanceScore * 20 + gazeScore * 12 + lineOfSight * 8
end

function Sensor.choose(candidates, sample)
    local best, bestScore
    for _, candidate in ipairs(candidates or {}) do
        local score = Sensor.score(candidate, sample)
        if not bestScore or score > bestScore
            or score == bestScore and tostring(candidate.actionKey) < tostring(best.actionKey) then
            best, bestScore = candidate, score
        end
    end
    return best, bestScore
end
