SynexInteractCancellation = {}

local Limits = assert(SynexInteractLimits,
    'interact limits must be loaded before cancellation policy')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded before cancellation policy')
local Cancellation = SynexInteractCancellation

local booleanKeys = {
    'cancelOnMove', 'cancelOnDamage', 'cancelOnDeath', 'cancelOnRagdoll',
    'cancelOnVehicleChange', 'cancelOnTargetMove', 'cancelOnTargetLoss',
    'cancelOnWorldChange',
}
local optionalKeys = {
    'cancelOnMove', 'cancelOnDamage', 'cancelOnDeath', 'cancelOnRagdoll',
    'cancelOnVehicleChange', 'cancelOnTargetMove', 'cancelOnTargetLoss',
    'cancelOnWorldChange', 'actorMoveDistance', 'targetMoveDistance',
    'cancelDistance', 'distanceHysteresis', 'distanceGraceMs',
    'targetLossGraceMs',
}
local defaults = {
    cancelOnMove = false,
    cancelOnDamage = false,
    cancelOnDeath = false,
    cancelOnRagdoll = false,
    cancelOnVehicleChange = false,
    cancelOnTargetMove = false,
    cancelOnTargetLoss = false,
    cancelOnWorldChange = false,
}

local function validNumber(value, minimum, maximum)
    return Validation.isFinite(value) and value >= minimum and value <= maximum
end

local function vector(value)
    return Validation.vector3(value)
end

local function vehicle(value)
    return Validation.isInteger(value, 1, 2147483647) and value or false
end

local function sameWorld(left, right)
    if left == nil and right == nil then return true end
    if not Validation.isPlainTable(left) or not Validation.isPlainTable(right) then
        return false
    end
    return left.instanceId == right.instanceId
end

function Cancellation.normalize(value)
    value = value or {}
    if not Validation.exactObject(value, {}, optionalKeys) then return nil end
    for _, key in ipairs(booleanKeys) do
        if value[key] ~= nil and type(value[key]) ~= 'boolean' then return nil end
    end
    if value.actorMoveDistance ~= nil
            and not validNumber(value.actorMoveDistance, 0.05, 20)
        or value.targetMoveDistance ~= nil
            and not validNumber(value.targetMoveDistance, 0.05, 20)
        or value.cancelDistance ~= nil
            and not validNumber(value.cancelDistance, 0.25, 20)
        or value.distanceHysteresis ~= nil
            and not validNumber(value.distanceHysteresis, 0, 5)
        or value.distanceGraceMs ~= nil
            and not Validation.isInteger(value.distanceGraceMs, 0, 10000)
        or value.targetLossGraceMs ~= nil
            and not Validation.isInteger(value.targetLossGraceMs, 0, 10000) then
        return nil
    end
    local result = Validation.copy(defaults)
    for key, candidate in pairs(value) do result[key] = candidate end
    if result.cancelOnMove and result.actorMoveDistance == nil then
        result.actorMoveDistance = 0.75
    end
    if result.cancelOnTargetMove and result.targetMoveDistance == nil then
        result.targetMoveDistance = 0.50
    end
    if result.cancelOnTargetLoss and result.targetLossGraceMs == nil then
        result.targetLossGraceMs = 500
    end
    if result.cancelDistance ~= nil then
        if result.distanceHysteresis == nil then
            result.distanceHysteresis = math.min(0.25, result.cancelDistance * 0.25)
        end
        if result.distanceGraceMs == nil then result.distanceGraceMs = 250 end
        if result.distanceHysteresis >= result.cancelDistance then return nil end
    elseif result.distanceHysteresis ~= nil or result.distanceGraceMs ~= nil then
        return nil
    end
    return result
end

function Cancellation.create(policy, sample, timestamp)
    local normalized = Cancellation.normalize(policy)
    if not normalized or not Validation.isPlainTable(sample)
        or not Validation.isPlainTable(sample.actor)
        or not Validation.isInteger(timestamp, 0, Limits.maximumSafeInteger) then
        return nil
    end
    return {
        policy = normalized,
        actorOrigin = vector(sample.actor.position),
        targetOrigin = vector(sample.targetPosition),
        actorVehicle = vehicle(sample.actor.vehicle),
        actorHealth = Validation.isFinite(sample.actor.health)
            and sample.actor.health or nil,
        worldInstance = Validation.copy(sample.worldInstance),
        lastTargetAt = timestamp,
        outOfRangeAt = nil,
    }
end

function Cancellation.evaluate(state, context, selected, timestamp)
    if not Validation.isPlainTable(state) or not Validation.isPlainTable(state.policy)
        or not Validation.isPlainTable(context)
        or not Validation.isPlainTable(context.actor)
        or not Validation.isInteger(timestamp, 0, Limits.maximumSafeInteger) then
        return 'TARGET_STATE_CHANGED'
    end
    local policy, actor = state.policy, context.actor
    if policy.cancelOnDeath and actor.dead == true then return 'ACTOR_DIED' end
    if policy.cancelOnRagdoll and actor.ragdoll == true then return 'ACTOR_RAGDOLL' end

    local currentHealth = Validation.isFinite(actor.health) and actor.health or nil
    if policy.cancelOnDamage and currentHealth ~= nil and state.actorHealth ~= nil
        and currentHealth < state.actorHealth then
        state.actorHealth = currentHealth
        return 'ACTOR_DAMAGED'
    end
    if currentHealth ~= nil then state.actorHealth = currentHealth end

    local actorPosition = vector(actor.position)
    if policy.cancelOnMove and actorPosition and state.actorOrigin
        and Validation.distance(actorPosition, state.actorOrigin) > policy.actorMoveDistance then
        return 'ACTOR_MOVED'
    end
    if policy.cancelOnVehicleChange
        and vehicle(actor.vehicle) ~= state.actorVehicle then
        return 'TARGET_STATE_CHANGED'
    end
    if policy.cancelOnWorldChange
        and not sameWorld(state.worldInstance, context.worldInstance) then
        return 'WORLD_CHANGED'
    end

    if selected == nil then
        if policy.cancelOnTargetLoss
            and timestamp - state.lastTargetAt >= policy.targetLossGraceMs then
            return 'TARGET_GONE'
        end
        return nil
    end
    state.lastTargetAt = timestamp

    local targetPosition = vector(selected.position)
    if policy.cancelOnTargetMove and targetPosition and state.targetOrigin
        and Validation.distance(targetPosition, state.targetOrigin)
            > policy.targetMoveDistance then
        return 'TARGET_MOVED'
    end
    if policy.cancelDistance ~= nil and Validation.isFinite(selected.distance) then
        local upper = policy.cancelDistance + policy.distanceHysteresis
        local lower = math.max(0, policy.cancelDistance - policy.distanceHysteresis)
        if selected.distance > upper then
            state.outOfRangeAt = state.outOfRangeAt or timestamp
        elseif selected.distance < lower then
            state.outOfRangeAt = nil
        end
        if state.outOfRangeAt ~= nil
            and timestamp - state.outOfRangeAt >= policy.distanceGraceMs then
            return 'OUT_OF_RANGE'
        end
    end
    return nil
end
