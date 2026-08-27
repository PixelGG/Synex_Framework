SynexEntityValidation = {}

local MAX_HASH = 4294967295
local MIN_HASH = -2147483648
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_BUCKET = 2147483647
local MAX_COORDINATE = 20000.0
local ENTITY_TYPES = { object = true, ped = true, vehicle = true }
local OWNER_TYPES = { character = true, group = true, resource = true, system = true, user = true }
local PERSISTENCE_POLICIES = {
    owner_lifetime = true,
    persistent = true,
    session = true,
    temporary = true,
}
local RECOVERY_POLICIES = {
    automatic = true,
    manual = true,
    none = true,
    on_demand = true,
}
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
    archetype = true,
    binding = true,
    bucket = true,
    bucketGeneration = true,
    doorFlag = true,
    entityType = true,
    heading = true,
    idempotencyKey = true,
    model = true,
    owner = true,
    pedType = true,
    persistent = true,
    persistentKey = true,
    persistencePolicy = true,
    position = true,
    reasonCode = true,
    recoveryPolicy = true,
    tags = true,
    timeoutMs = true,
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

local function validateNamespace(value, label)
    if type(value) ~= 'string' or #value < 3 or #value > 128
        or value ~= value:lower()
        or value:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') == nil
        or value:match('%.%.') then
        return fail('INVALID_ARGUMENT', (label or 'namespace') .. ' is invalid')
    end
    return value
end

local function validateReasonCode(value)
    local reasonCode, reasonError = validateNamespace(value, 'reasonCode')
    if not reasonCode then return nil, reasonError end
    return reasonCode
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

function SynexEntityValidation.validateOwner(owner)
    return validateOwner(owner)
end

function SynexEntityValidation.validatePosition(position)
    return validatePosition(position)
end

function SynexEntityValidation.validateIdentifier(value, label, maximum)
    return validateBoundedIdentifier(value, label or 'identifier', maximum or 128)
end

function SynexEntityValidation.validateNamespace(value, label)
    return validateNamespace(value, label)
end

function SynexEntityValidation.validateReasonCode(value)
    return validateReasonCode(value)
end

function SynexEntityValidation.validatePersistencePolicy(value)
    if not PERSISTENCE_POLICIES[value] then
        return fail('INVALID_ARGUMENT', 'persistencePolicy is not supported')
    end
    return value
end

function SynexEntityValidation.validateRecoveryPolicy(value)
    if not RECOVERY_POLICIES[value] then
        return fail('INVALID_ARGUMENT', 'recoveryPolicy is not supported')
    end
    return value
end

function SynexEntityValidation.validateBinding(binding, required)
    if binding == nil and not required then return nil end
    if type(binding) ~= 'table' then
        return fail('INVALID_ARGUMENT', 'binding must be an object')
    end
    for key in pairs(binding) do
        if key ~= 'namespace' and key ~= 'ref' then
            return fail('INVALID_ARGUMENT', 'binding contains an unknown field')
        end
    end
    local namespace, namespaceError = validateNamespace(binding.namespace, 'binding.namespace')
    if not namespace then return nil, namespaceError end
    local reference, referenceError = validateBoundedIdentifier(binding.ref, 'binding.ref', 128)
    if not reference then return nil, referenceError end
    return { namespace = namespace, ref = reference }
end

function SynexEntityValidation.validateEntityRef(request)
    if type(request) ~= 'table' then
        return fail('INVALID_ARGUMENT', 'EntityRef must be an object')
    end
    local entityId, entityError = SynexEntityValidation.validateEntityId(request.entityId)
    if not entityId then return nil, entityError end
    local generation, generationError = SynexEntityValidation.validateGeneration(request.generation)
    if not generation then return nil, generationError end
    return { entityId = entityId, generation = generation }
end

function SynexEntityValidation.validatePage(limit, cursor, maximum)
    maximum = maximum or 100
    if limit == nil then limit = math.min(50, maximum) end
    if not isInteger(limit) or limit < 1 or limit > maximum then
        return fail('INVALID_ARGUMENT', 'limit is outside the supported range')
    end
    if cursor ~= nil then
        local normalized, cursorError = validateBoundedIdentifier(cursor, 'cursor', 128)
        if not normalized then return nil, cursorError end
        cursor = normalized
    end
    return { limit = limit, cursor = cursor }
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
    local persistencePolicy = request.persistencePolicy
    if persistencePolicy ~= nil then
        local policyError
        persistencePolicy, policyError = SynexEntityValidation.validatePersistencePolicy(persistencePolicy)
        if not persistencePolicy then return nil, policyError end
    else
        persistencePolicy = request.persistent == true and 'persistent' or 'temporary'
    end
    local persistent = persistencePolicy == 'persistent' or persistencePolicy == 'owner_lifetime'
    if request.persistent ~= nil and request.persistent ~= persistent then
        return fail('INVALID_ARGUMENT', 'persistent conflicts with persistencePolicy')
    end

    local recoveryPolicy = request.recoveryPolicy
        or (persistent and 'automatic' or 'none')
    local recoveryError
    recoveryPolicy, recoveryError = SynexEntityValidation.validateRecoveryPolicy(recoveryPolicy)
    if not recoveryPolicy then return nil, recoveryError end
    if not persistent and recoveryPolicy == 'automatic' then
        return fail('INVALID_ARGUMENT', 'automatic recovery requires durable persistence')
    end

    local persistentKey
    if persistent then
        persistentKey, ownerError = SynexEntityValidation.validatePersistentKey(request.persistentKey)
        if not persistentKey then
            return nil, ownerError
        end
    elseif request.persistentKey ~= nil then
        return fail('INVALID_ARGUMENT', 'persistentKey is only valid for persistent entities')
    end

    local binding, bindingError = SynexEntityValidation.validateBinding(request.binding, false)
    if bindingError then return nil, bindingError end

    local archetype
    if request.archetype ~= nil then
        if type(request.archetype) ~= 'table' then
            return fail('INVALID_ARGUMENT', 'archetype must be an object')
        end
        for key in pairs(request.archetype) do
            if key ~= 'namespace' and key ~= 'version' then
                return fail('INVALID_ARGUMENT', 'archetype contains an unknown field')
            end
        end
        local namespace, namespaceError = validateNamespace(
            request.archetype.namespace,
            'archetype.namespace'
        )
        if not namespace then return nil, namespaceError end
        local version = request.archetype.version
        if not isInteger(version) or version < 1 or version > MAX_SAFE_INTEGER then
            return fail('INVALID_ARGUMENT', 'archetype.version is outside the supported range')
        end
        archetype = { namespace = namespace, schemaVersion = version, version = version }
    end

    local reasonCode = request.reasonCode
    if reasonCode ~= nil then
        local reasonError
        reasonCode, reasonError = validateReasonCode(reasonCode)
        if not reasonCode then return nil, reasonError end
    end

    local timeoutMs = request.timeoutMs
    if timeoutMs ~= nil and (not isInteger(timeoutMs) or timeoutMs < 250 or timeoutMs > 10000) then
        return fail('INVALID_ARGUMENT', 'timeoutMs is outside the supported range')
    end

    local idempotencyKey = request.idempotencyKey
    if idempotencyKey ~= nil then
        local keyError
        idempotencyKey, keyError = validateBoundedIdentifier(
            idempotencyKey, 'idempotencyKey', 36)
        if not idempotencyKey then return nil, keyError end
        if #idempotencyKey < 8 then
            return fail('INVALID_ARGUMENT', 'idempotencyKey has an invalid length')
        end
    end

    local tags = {}
    if request.tags ~= nil then
        if type(request.tags) ~= 'table' then
            return fail('INVALID_ARGUMENT', 'tags must be an array')
        end
        local seen = {}
        for index, tag in ipairs(request.tags) do
            if index > 16 then return fail('INVALID_ARGUMENT', 'tags exceed the supported limit') end
            local normalizedTag, tagError = validateNamespace(tag, 'tag')
            if not normalizedTag then return nil, tagError end
            if seen[normalizedTag] then return fail('INVALID_ARGUMENT', 'tags must be unique') end
            seen[normalizedTag] = true
            tags[index] = normalizedTag
        end
        for key in pairs(request.tags) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #tags then
                return fail('INVALID_ARGUMENT', 'tags must be a dense array')
            end
        end
    end

    local normalized = {
        archetype = archetype,
        binding = binding,
        bucket = bucket,
        bucketGeneration = bucketReference.generation,
        entityType = request.entityType,
        heading = heading,
        idempotencyKey = idempotencyKey,
        model = model,
        owner = owner,
        persistent = persistent,
        persistentKey = persistentKey,
        persistencePolicy = persistencePolicy,
        position = position,
        reasonCode = reasonCode,
        recoveryPolicy = recoveryPolicy,
        tags = tags,
        timeoutMs = timeoutMs,
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
