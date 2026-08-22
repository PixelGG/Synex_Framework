SynexEntityValidation = {}

local MAX_HASH = 4294967295
local MIN_HASH = -2147483648
local MAX_BUCKET = 2147483647
local MAX_COORDINATE = 20000.0
local ENTITY_TYPES = { object = true, ped = true, vehicle = true }
local OWNER_TYPES = { character = true, resource = true, system = true, user = true }
local VEHICLE_TYPES = {
    automobile = true,
    bike = true,
    boat = true,
    heli = true,
    plane = true,
    submarine = true,
    trailer = true,
}
local SPAWN_KEYS = {
    bucket = true,
    bucketGeneration = true,
    doorFlag = true,
    entityType = true,
    heading = true,
    model = true,
    owner = true,
    pedType = true,
    persistent = true,
    persistentKey = true,
    position = true,
    vehicleType = true,
}

local function fail(code, message)
    return nil, { code = code, message = message, retryable = false }
end

local function isFinite(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isInteger(value)
    return isFinite(value) and value % 1 == 0
end

local function validateBoundedIdentifier(value, label, maximum)
    if type(value) ~= 'string' or #value < 1 or #value > maximum then
        return fail('INVALID_ARGUMENT', label .. ' has an invalid length')
    end

    if not value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
        return fail('INVALID_ARGUMENT', label .. ' contains unsupported characters')
    end

    return value
end

local function validatePosition(position)
    if type(position) ~= 'table' then
        return fail('INVALID_ARGUMENT', 'position must be an object')
    end

    for key in pairs(position) do
        if key ~= 'x' and key ~= 'y' and key ~= 'z' then
            return fail('INVALID_ARGUMENT', 'position contains an unknown field')
        end
    end

    local normalized = {}
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        local value = position[axis]
        if not isFinite(value) or math.abs(value) > MAX_COORDINATE then
            return fail('INVALID_ARGUMENT', ('position.%s is outside the supported range'):format(axis))
        end
        normalized[axis] = value + 0.0
    end

    return normalized
end

local function validateOwner(owner)
    if type(owner) ~= 'table' then
        return fail('INVALID_ARGUMENT', 'owner must be an object')
    end

    for key in pairs(owner) do
        if key ~= 'id' and key ~= 'type' then
            return fail('INVALID_ARGUMENT', 'owner contains an unknown field')
        end
    end

    if not OWNER_TYPES[owner.type] then
        return fail('INVALID_ARGUMENT', 'owner.type is not supported')
    end

    local ownerId, ownerError = validateBoundedIdentifier(owner.id, 'owner.id', 64)
    if not ownerId then
        return nil, ownerError
    end

    return { id = ownerId, type = owner.type }
end

function SynexEntityValidation.normalizeHash(value)
    if not isInteger(value) or value < MIN_HASH or value > MAX_HASH then
        return fail('INVALID_ARGUMENT', 'model must be a 32-bit integer hash')
    end

    if value < 0 then
        return value + 4294967296
    end

    return value
end

function SynexEntityValidation.validateEntityId(value)
    if type(value) ~= 'string' or #value < 8 or #value > 64 then
        return fail('INVALID_ARGUMENT', 'entityId has an invalid length')
    end

    if not value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
        return fail('INVALID_ARGUMENT', 'entityId contains unsupported characters')
    end

    return value
end

function SynexEntityValidation.validateCaller(value)
    return validateBoundedIdentifier(value, 'callerResource', 64)
end

function SynexEntityValidation.validatePersistentKey(value)
    local persistentKey, persistentKeyError = validateBoundedIdentifier(value, 'persistentKey', 128)
    if not persistentKey then
        return nil, persistentKeyError
    end
    if persistentKey ~= persistentKey:lower() then
        return fail('INVALID_ARGUMENT', 'persistentKey must use lowercase characters')
    end
    return persistentKey
end

function SynexEntityValidation.validateGeneration(value)
    if not isInteger(value) or value < 1 or value > 9007199254740991 then
        return fail('INVALID_ARGUMENT', 'generation must be a positive safe integer')
    end

    return value
end

function SynexEntityValidation.validateBucketGeneration(value)
    local generation, generationError = validateBoundedIdentifier(value, 'bucketGeneration', 64)
    if not generation then
        return nil, generationError
    end
    if #generation < 8 then
        return fail('INVALID_ARGUMENT', 'bucketGeneration has an invalid length')
    end
    return generation
end

function SynexEntityValidation.validateBucketReference(bucket, generation, allowDefault)
    if not isInteger(bucket) or bucket < 0 or bucket > MAX_BUCKET then
        return fail('INVALID_ARGUMENT', 'bucket is outside the supported range')
    end

    if bucket == 0 and allowDefault then
        if generation ~= 0 then
            return fail('INVALID_ARGUMENT', 'the default bucket requires generation 0')
        end
        return { id = 0, generation = 0 }
    end

    local normalizedGeneration, generationError = SynexEntityValidation.validateBucketGeneration(generation)
    if not normalizedGeneration then
        return nil, generationError
    end

    if bucket == 0 then
        return fail('INVALID_ARGUMENT', 'bucket 0 is not valid for this operation')
    end

    return { id = bucket, generation = normalizedGeneration }
end

function SynexEntityValidation.validateSpawn(request)
    if type(request) ~= 'table' then
        return fail('INVALID_ARGUMENT', 'request must be an object')
    end

    for key in pairs(request) do
        if not SPAWN_KEYS[key] then
            return fail('INVALID_ARGUMENT', 'request contains an unknown field')
        end
    end

    if not ENTITY_TYPES[request.entityType] then
        return fail('INVALID_ARGUMENT', 'entityType is not supported')
    end

    local model, modelError = SynexEntityValidation.normalizeHash(request.model)
    if not model then
        return nil, modelError
    end

    local position, positionError = validatePosition(request.position)
    if not position then
        return nil, positionError
    end

    local owner, ownerError = validateOwner(request.owner)
    if not owner then
        return nil, ownerError
    end

    local heading = request.heading == nil and 0.0 or request.heading
    if not isFinite(heading) or heading < -360.0 or heading > 360.0 then
        return fail('INVALID_ARGUMENT', 'heading is outside the supported range')
    end
    heading = heading % 360.0

    local bucket = request.bucket == nil and 0 or request.bucket
    if not isInteger(bucket) or bucket < 0 or bucket > MAX_BUCKET then
        return fail('INVALID_ARGUMENT', 'bucket is outside the supported range')
    end

    local bucketReference, bucketError = SynexEntityValidation.validateBucketReference(
        bucket,
        request.bucketGeneration == nil and 0 or request.bucketGeneration,
        true
    )
    if not bucketReference then
        return nil, bucketError
    end

    if request.persistent ~= nil and type(request.persistent) ~= 'boolean' then
        return fail('INVALID_ARGUMENT', 'persistent must be a boolean')
    end
    local persistent = request.persistent == true

    local persistentKey
    if persistent then
        persistentKey, ownerError = SynexEntityValidation.validatePersistentKey(request.persistentKey)
        if not persistentKey then
            return nil, ownerError
        end
    elseif request.persistentKey ~= nil then
        return fail('INVALID_ARGUMENT', 'persistentKey is only valid for persistent entities')
    end

    local normalized = {
        bucket = bucket,
        bucketGeneration = bucketReference.generation,
        entityType = request.entityType,
        heading = heading,
        model = model,
        owner = owner,
        persistent = persistent,
        persistentKey = persistentKey,
        position = position,
    }

    if request.entityType == 'vehicle' then
        if not VEHICLE_TYPES[request.vehicleType] then
            return fail('INVALID_ARGUMENT', 'vehicleType is not supported')
        end
        if request.pedType ~= nil or request.doorFlag ~= nil then
            return fail('INVALID_ARGUMENT', 'vehicle requests contain fields for another entity type')
        end
        normalized.vehicleType = request.vehicleType
    elseif request.entityType == 'ped' then
        if not isInteger(request.pedType) or request.pedType < 0 or request.pedType > 29 then
            return fail('INVALID_ARGUMENT', 'pedType is outside the supported range')
        end
        if request.vehicleType ~= nil or request.doorFlag ~= nil then
            return fail('INVALID_ARGUMENT', 'ped requests contain fields for another entity type')
        end
        normalized.pedType = request.pedType
    else
        if request.doorFlag ~= nil and type(request.doorFlag) ~= 'boolean' then
            return fail('INVALID_ARGUMENT', 'doorFlag must be a boolean')
        end
        if request.vehicleType ~= nil or request.pedType ~= nil then
            return fail('INVALID_ARGUMENT', 'object requests contain fields for another entity type')
        end
        normalized.doorFlag = request.doorFlag == true
    end

    return normalized
end

function SynexEntityValidation.newTokenBucket(capacity, refillPerSecond)
    assert(isFinite(capacity) and capacity > 0, 'capacity must be positive')
    assert(isFinite(refillPerSecond) and refillPerSecond > 0, 'refillPerSecond must be positive')

    local buckets = {}
    local limiter = {}

    function limiter.take(key, cost, nowMilliseconds)
        if type(key) ~= 'string' or key == '' then
            return false
        end
        if not isFinite(cost) or cost <= 0 or not isFinite(nowMilliseconds) then
            return false
        end

        local bucket = buckets[key]
        if not bucket then
            bucket = { tokens = capacity, updatedAt = nowMilliseconds }
            buckets[key] = bucket
        end

        local elapsed = math.max(0, nowMilliseconds - bucket.updatedAt) / 1000
        bucket.tokens = math.min(capacity, bucket.tokens + elapsed * refillPerSecond)
        bucket.updatedAt = nowMilliseconds
        if bucket.tokens < cost then
            return false
        end

        bucket.tokens = bucket.tokens - cost
        return true
    end

    function limiter.clear(key)
        buckets[key] = nil
    end

    return limiter
end
