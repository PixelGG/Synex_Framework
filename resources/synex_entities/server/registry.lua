SynexEntityRegistry = {}
local orderedIndex = assert(SynexEntityOrderedIndex,
    'entity ordered index must be loaded first')
local addIndex, removeIndex, sortedRecords = orderedIndex.addIndex,
    orderedIndex.removeIndex, orderedIndex.sortedRecords
local OWNER_TYPES = {
    character = true,
    group = true,
    resource = true,
    system = true,
    user = true,
}
local function failure(code, message)
    return nil, { code = code, message = message, retryable = false }
end
local function isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end
local function isInteger(value)
    return isFinite(value) and value % 1 == 0
end
local function validateBoundedIdentifier(value, label, maximum)
    if type(value) ~= 'string' or #value < 1 or #value > maximum
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return failure('INVALID_ARGUMENT', label .. ' is invalid')
    end
    return value
end
local function validateNetId(value)
    if not isInteger(value) or value < 1 or value > 65535 then
        return failure('INVALID_ARGUMENT', 'netId is outside the supported range')
    end
    return value
end
local function validateHandle(value)
    if value == nil then return nil end
    if not isInteger(value) or value < 1 or value > 2147483647 then
        return failure('INVALID_ARGUMENT', 'handle is outside the supported range')
    end
    return value
end
local function validateBucket(value)
    value = value == nil and 0 or value
    if not isInteger(value) or value < 0 or value > 2147483647 then
        return failure('INVALID_ARGUMENT', 'bucket is outside the supported range')
    end
    return value
end
local function validatePosition(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then
        return failure('INVALID_ARGUMENT', 'position must be an object')
    end
    local normalized = {}
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        if not isFinite(value[axis]) or math.abs(value[axis]) > 20000 then
            return failure('INVALID_ARGUMENT', 'position is outside the supported world bounds')
        end
        normalized[axis] = value[axis] + 0.0
    end
    return normalized
end
local function validateLogicalOwner(owner)
    if owner == nil then return nil end
    if type(owner) ~= 'table' or not OWNER_TYPES[owner.type] then
        return failure('INVALID_ARGUMENT', 'logical owner is invalid')
    end
    for key in pairs(owner) do
        if key ~= 'id' and key ~= 'type' then
            return failure('INVALID_ARGUMENT', 'logical owner contains an unknown field')
        end
    end
    local ownerId, ownerError = validateBoundedIdentifier(owner.id, 'logical owner id', 64)
    if not ownerId then return nil, ownerError end
    return { id = ownerId, type = owner.type }
end
local function validateTags(tags)
    if type(tags) ~= 'table' or #tags > 64 then
        return failure('INVALID_ARGUMENT', 'tags must be a bounded array')
    end
    local result, seen, count = {}, {}, 0
    for key in pairs(tags) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #tags then
            return failure('INVALID_ARGUMENT', 'tags must be a dense array')
        end
        count = count + 1
    end
    if count ~= #tags then return failure('INVALID_ARGUMENT', 'tags must be a dense array') end
    for index, tag in ipairs(tags) do
        if type(tag) ~= 'string' or #tag < 3 or #tag > 128
            or tag ~= tag:lower()
            or tag:match('^[a-z][a-z0-9_.:%-]+$') == nil or seen[tag] then
            return failure('INVALID_ARGUMENT', 'tags contain an invalid value')
        end
        seen[tag], result[index] = true, tag
    end
    return result
end
local function ownsNamespace(resourceOwner, namespace)
    return namespace == resourceOwner
        or namespace:sub(1, #resourceOwner + 1) == resourceOwner .. '.'
        or namespace:sub(1, #resourceOwner + 1) == resourceOwner .. ':'
end
local function validateBinding(value, resourceOwner)
    if value == nil or value == false then return nil end
    if type(value) ~= 'table' then
        return failure('INVALID_ARGUMENT', 'binding must be an object')
    end
    for key in pairs(value) do
        if key ~= 'namespace' and key ~= 'ref' then
            return failure('INVALID_ARGUMENT', 'binding contains an unknown field')
        end
    end
    local namespace, namespaceError = validateBoundedIdentifier(
        value.namespace,
        'binding namespace',
        128
    )
    if not namespace then return nil, namespaceError end
    if not ownsNamespace(resourceOwner, namespace) then
        return failure('FORBIDDEN', 'binding namespace belongs to another resource')
    end
    local bindingRef, bindingError = validateBoundedIdentifier(value.ref, 'binding ref', 128)
    if not bindingRef then return nil, bindingError end
    return { namespace = namespace, ref = bindingRef }
end
local function compositeKey(left, right)
    return ('%d:%s%d:%s'):format(#left, left, #right, right)
end
local function bindingFromRecord(record, resourceOwner)
    local explicit = record.binding
    if explicit == nil and (record.bindingNamespace ~= nil or record.bindingRef ~= nil) then
        explicit = { namespace = record.bindingNamespace, ref = record.bindingRef }
    end
    return validateBinding(explicit, resourceOwner)
end
local function matchesExpectedReference(reference, expected)
    if expected == nil then return true end
    if type(expected) == 'number' then return reference.generation == expected end
    if type(expected) ~= 'table' then return nil end
    return reference.entityId == expected.entityId
        and reference.generation == expected.generation
end
function SynexEntityRegistry.new(options)
    options = options or {}
    local byId = {}
    local networkRefs = {}
    local handleRefs = {}
    local bindingRefs = {}
    local persistentRefs = {}
    local persistentOwners = {}
    local byResource = {}
    local byBucket = {}
    local byLogicalType = {}
    local orderedEntities = orderedIndex.create()
    local count = 0
    local spatialIndex = options.spatialIndex
    if spatialIndex == nil and options.spatial ~= false
        and type(SynexEntitySpatialIndex) == 'table'
        and type(SynexEntitySpatialIndex.create) == 'function' then
        spatialIndex = SynexEntitySpatialIndex.create(options.spatial)
    end
    local registry = {}
    local function logicalBucket(owner, create)
        if not owner then return nil end
        local byOwnerId = byLogicalType[owner.type]
        if not byOwnerId and create then
            byOwnerId = {}
            byLogicalType[owner.type] = byOwnerId
        end
        local bucket = byOwnerId and byOwnerId[owner.id] or nil
        if not bucket and create then
            bucket = {}
            byOwnerId[owner.id] = bucket
        end
        return bucket, byOwnerId
    end
    local function addLogical(record)
        local bucket = logicalBucket(record.owner, true)
        if bucket then bucket[record.entityId] = true end
    end
    local function removeLogical(record)
        local bucket, byOwnerId = logicalBucket(record.owner, false)
        if not bucket then return end
        bucket[record.entityId] = nil
        if next(bucket) == nil then
            byOwnerId[record.owner.id] = nil
            if next(byOwnerId) == nil then byLogicalType[record.owner.type] = nil end
        end
    end
    local function persistentKey(resourceOwner, value)
        return compositeKey(resourceOwner, value)
    end
    local function addPersistent(record)
        if not record.persistentKey then return end
        local key = persistentKey(record.resourceOwner, record.persistentKey)
        persistentRefs[key] = { entityId = record.entityId, generation = record.generation }
        addIndex(persistentOwners, record.persistentKey, record.resourceOwner)
    end
    local function removePersistent(record)
        if not record.persistentKey then return end
        persistentRefs[persistentKey(record.resourceOwner, record.persistentKey)] = nil
        removeIndex(persistentOwners, record.persistentKey, record.resourceOwner)
    end
    local function addBinding(record)
        if not record.binding then return end
        bindingRefs[compositeKey(record.binding.namespace, record.binding.ref)] = {
            entityId = record.entityId,
            generation = record.generation,
        }
    end
    local function removeBinding(record)
        if not record.binding then return end
        bindingRefs[compositeKey(record.binding.namespace, record.binding.ref)] = nil
    end
    local function refreshReferences(record)
        networkRefs[record.netId] = { entityId = record.entityId, generation = record.generation }
        if record.handle then
            handleRefs[record.handle] = {
                entityId = record.entityId,
                generation = record.generation,
            }
        end
        if record.persistentKey then
            local reference = persistentRefs[persistentKey(
                record.resourceOwner,
                record.persistentKey
            )]
            if reference then reference.generation = record.generation end
        end
        if record.binding then
            local reference = bindingRefs[compositeKey(
                record.binding.namespace,
                record.binding.ref
            )]
            if reference then reference.generation = record.generation end
        end
    end
    local function putSpatial(entityId, position, bucket)
        if not spatialIndex or not position then return true end
        if type(spatialIndex.get) == 'function' and spatialIndex.get(entityId) then
            return spatialIndex.update(entityId, position, bucket)
        end
        return spatialIndex.insert(entityId, position, bucket)
    end
    function registry.insert(record)
        if type(record) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'entity record must be an object')
        end
        local entityId, entityIdError = SynexEntityValidation.validateEntityId(record.entityId)
        if not entityId then return nil, entityIdError end
        local generation, generationError = SynexEntityValidation.validateGeneration(record.generation)
        if not generation then return nil, generationError end
        local resourceOwner, ownerError = SynexEntityValidation.validateCaller(record.resourceOwner)
        if not resourceOwner then return nil, ownerError end
        local netId, netIdError = validateNetId(record.netId)
        if not netId then return nil, netIdError end
        local handle, handleError = validateHandle(record.handle)
        if record.handle ~= nil and not handle then return nil, handleError end
        local bucket, bucketError = validateBucket(record.bucket)
        if not bucket then return nil, bucketError end
        local owner, logicalOwnerError = validateLogicalOwner(record.owner)
        if record.owner ~= nil and not owner then return nil, logicalOwnerError end
        local position, positionError = validatePosition(record.position)
        if record.position ~= nil and not position then return nil, positionError end
        local binding, bindingError = bindingFromRecord(record, resourceOwner)
        if (record.binding ~= nil or record.bindingNamespace ~= nil or record.bindingRef ~= nil)
            and not binding then return nil, bindingError end

        local persistentKeyValue
        if record.persistentKey ~= nil then
            persistentKeyValue, ownerError = SynexEntityValidation.validatePersistentKey(record.persistentKey)
            if not persistentKeyValue then return nil, ownerError end
        end
        if byId[entityId] or networkRefs[netId] or (handle and handleRefs[handle]) then
            return failure('CONFLICT', 'entityId, netId, or handle is already registered')
        end
        if persistentKeyValue
            and persistentRefs[persistentKey(resourceOwner, persistentKeyValue)] then
            return failure('CONFLICT', 'persistentKey is already registered for this resource')
        end
        if binding and bindingRefs[compositeKey(binding.namespace, binding.ref)] then
            return failure('BINDING_CONFLICT', 'binding is already active')
        end
        if spatialIndex and position then
            local indexed, indexError = spatialIndex.insert(entityId, position, bucket)
            if not indexed then return nil, indexError end
        end

        record.entityId = entityId
        record.generation = generation
        record.resourceOwner = resourceOwner
        record.netId = netId
        record.handle = handle
        record.bucket = bucket
        record.owner = owner
        record.position = position
        record.persistentKey = persistentKeyValue
        record.binding = binding
        record.bindingNamespace = binding and binding.namespace or nil
        record.bindingRef = binding and binding.ref or nil
        byId[entityId] = record
        orderedEntities.insert(entityId)
        networkRefs[netId] = { entityId = entityId, generation = generation }
        if handle then
            handleRefs[handle] = { entityId = entityId, generation = generation }
        end
        addPersistent(record)
        addBinding(record)
        addIndex(byResource, resourceOwner, entityId)
        addIndex(byBucket, bucket, entityId)
        addLogical(record)
        count = count + 1
        return record
    end
    function registry.byEntityId(entityId, expectedGeneration)
        local record = byId[entityId]
        if not record then return failure('NOT_FOUND', 'entity is not registered') end
        if expectedGeneration ~= nil and record.generation ~= expectedGeneration then
            return failure('STALE_ENTITY', 'entity generation does not match')
        end
        return record
    end
    function registry.resolve(entityId, generation, resourceOwner)
        local record = byId[entityId]
        if not record then return failure('NOT_FOUND', 'entity is not registered') end
        if record.generation ~= generation then
            return failure('STALE_ENTITY', 'entity generation does not match')
        end
        if resourceOwner and record.resourceOwner ~= resourceOwner then
            return failure('FOREIGN_RESOURCE_OWNER', 'entity belongs to another resource')
        end
        return record
    end
    function registry.byNetId(netId, expectedReference)
        local normalized, netIdError = validateNetId(netId)
        if not normalized then return nil, netIdError end
        local reference = networkRefs[normalized]
        if not reference then return failure('NOT_FOUND', 'network ID is not registered') end
        local record = byId[reference.entityId]
        if not record or record.generation ~= reference.generation
            or record.netId ~= normalized then
            return failure('STALE_ENTITY', 'network ID points to a stale entity reference')
        end
        local matches = matchesExpectedReference(reference, expectedReference)
        if matches == nil then return failure('INVALID_ARGUMENT', 'expected EntityRef is invalid') end
        if not matches then return failure('STALE_ENTITY', 'network ID EntityRef does not match') end
        return record, reference.generation
    end

    function registry.byNetworkId(netId)
        return registry.byNetId(netId)
    end

    function registry.byHandle(handle, expectedReference)
        if handle == nil then return failure('INVALID_ARGUMENT', 'runtime handle is required') end
        local normalized, handleError = validateHandle(handle)
        if not normalized then return nil, handleError end
        local reference = handleRefs[normalized]
        if not reference then return failure('NOT_FOUND', 'runtime handle is not registered') end
        local record = byId[reference.entityId]
        if not record or record.generation ~= reference.generation
            or record.handle ~= normalized then
            return failure('STALE_ENTITY', 'runtime handle points to a stale entity reference')
        end
        local matches = matchesExpectedReference(reference, expectedReference)
        if matches == nil then return failure('INVALID_ARGUMENT', 'expected EntityRef is invalid') end
        if not matches then return failure('STALE_ENTITY', 'runtime handle EntityRef does not match') end
        return record, reference.generation
    end

    function registry.resolveRef(reference, resourceOwner)
        if type(reference) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'EntityRef must be an object')
        end
        for key in pairs(reference) do
            if key ~= 'entityId' and key ~= 'generation' then
                return failure('INVALID_ARGUMENT', 'EntityRef contains an unknown field')
            end
        end
        return registry.resolve(reference.entityId, reference.generation, resourceOwner)
    end

    function registry.entityRef(record)
        if type(record) ~= 'table' or byId[record.entityId] ~= record then
            return failure('NOT_FOUND', 'entity record is not registered')
        end
        return { entityId = record.entityId, generation = record.generation }
    end

    function registry.byBinding(namespace, bindingRef, resourceOwner)
        local normalizedNamespace, namespaceError = validateBoundedIdentifier(
            namespace,
            'binding namespace',
            128
        )
        if not normalizedNamespace then return nil, namespaceError end
        local normalizedRef, refError = validateBoundedIdentifier(bindingRef, 'binding ref', 128)
        if not normalizedRef then return nil, refError end
        local reference = bindingRefs[compositeKey(normalizedNamespace, normalizedRef)]
        if not reference then return failure('NOT_FOUND', 'binding is not active') end
        return registry.resolve(reference.entityId, reference.generation, resourceOwner)
    end

    function registry.byPersistentKey(value, resourceOwner)
        local normalized, keyError = SynexEntityValidation.validatePersistentKey(value)
        if not normalized then return nil, keyError end
        if resourceOwner then
            local owner, ownerError = SynexEntityValidation.validateCaller(resourceOwner)
            if not owner then return nil, ownerError end
            resourceOwner = owner
            local reference = persistentRefs[persistentKey(resourceOwner, normalized)]
            if not reference then
                return failure('NOT_FOUND', 'persistent entity is not registered')
            end
            return registry.resolve(reference.entityId, reference.generation, resourceOwner)
        end
        local owners = persistentOwners[normalized]
        if not owners then return failure('NOT_FOUND', 'persistent entity is not registered') end
        local onlyOwner
        for owner in pairs(owners) do
            if onlyOwner then
                return failure('CONFLICT', 'persistentKey requires a resource namespace')
            end
            onlyOwner = owner
        end
        local reference = persistentRefs[persistentKey(onlyOwner, normalized)]
        return registry.resolve(reference.entityId, reference.generation)
    end

    function registry.update(entityId, generation, changes)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        if type(changes) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'changes must be an object')
        end
        for key in pairs(changes) do
            if key ~= 'owner' and key ~= 'position' and key ~= 'status'
                and key ~= 'tags'
                and key ~= 'version' then
                return failure('INVALID_ARGUMENT', 'changes contain an unsupported field')
            end
        end
        local nextOwner = record.owner
        if changes.owner == false then
            nextOwner = nil
        elseif changes.owner ~= nil then
            local ownerError
            nextOwner, ownerError = validateLogicalOwner(changes.owner)
            if not nextOwner then return nil, ownerError end
        end
        local nextPosition = record.position
        if changes.position ~= nil then
            local positionError
            nextPosition, positionError = validatePosition(changes.position)
            if not nextPosition then return nil, positionError end
        end
        local nextTags = record.tags
        if changes.tags ~= nil then
            local tagsError
            nextTags, tagsError = validateTags(changes.tags)
            if not nextTags then return nil, tagsError end
        end
        if changes.status ~= nil and (type(changes.status) ~= 'string'
            or #changes.status < 1 or #changes.status > 32
            or changes.status:match('^[a-z_]+$') == nil) then
            return failure('INVALID_ARGUMENT', 'status is invalid')
        end
        if changes.version ~= nil and (not isInteger(changes.version)
            or changes.version < 1 or changes.version > 9007199254740991) then
            return failure('INVALID_ARGUMENT', 'version is invalid')
        end
        if changes.position ~= nil then
            local indexed, indexError = putSpatial(entityId, nextPosition, record.bucket)
            if not indexed then return nil, indexError end
        end
        if changes.owner ~= nil then
            removeLogical(record)
            record.owner = nextOwner
            addLogical(record)
        end
        if changes.position ~= nil then record.position = nextPosition end
        if changes.tags ~= nil then record.tags = nextTags end
        if changes.status ~= nil then record.status = changes.status end
        if changes.version ~= nil then record.version = changes.version end
        return record
    end

    function registry.rebind(entityId, generation, binding)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        local normalized, bindingError = validateBinding(binding, record.resourceOwner)
        if binding ~= nil and binding ~= false and not normalized then
            return nil, bindingError
        end
        local existing = normalized
            and bindingRefs[compositeKey(normalized.namespace, normalized.ref)] or nil
        if existing and (existing.entityId ~= entityId or existing.generation ~= generation) then
            return failure('BINDING_CONFLICT', 'binding is already active')
        end
        removeBinding(record)
        record.binding = normalized
        record.bindingNamespace = normalized and normalized.namespace or nil
        record.bindingRef = normalized and normalized.ref or nil
        addBinding(record)
        return record
    end

    function registry.move(entityId, generation, bucket, position)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        local normalizedBucket, bucketError = validateBucket(bucket)
        if not normalizedBucket then return nil, bucketError end
        local normalizedPosition = record.position
        if position ~= nil then
            normalizedPosition, bucketError = validatePosition(position)
            if not normalizedPosition then return nil, bucketError end
        end
        if normalizedPosition then
            local indexed, indexError = putSpatial(
                entityId,
                normalizedPosition,
                normalizedBucket
            )
            if not indexed then return nil, indexError end
        end
        if record.bucket ~= normalizedBucket then
            removeIndex(byBucket, record.bucket, entityId)
            addIndex(byBucket, normalizedBucket, entityId)
        end
        record.bucket = normalizedBucket
        record.position = normalizedPosition
        return record
    end

    function registry.reincarnate(entityId, generation, runtime)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        if type(runtime) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'runtime incarnation must be an object')
        end
        for key in pairs(runtime) do
            if key ~= 'bucket' and key ~= 'generation' and key ~= 'handle'
                and key ~= 'netId' and key ~= 'position' and key ~= 'resourceCycle' then
                return failure('INVALID_ARGUMENT', 'runtime incarnation contains an unknown field')
            end
        end
        local nextGeneration, generationError = SynexEntityValidation.validateGeneration(runtime.generation)
        if not nextGeneration then return nil, generationError end
        if nextGeneration ~= generation + 1 then
            return failure('INVALID_ARGUMENT', 'runtime generation must advance exactly once')
        end
        local netId, netIdError = validateNetId(runtime.netId)
        if not netId then return nil, netIdError end
        local handle, handleError = validateHandle(runtime.handle)
        if runtime.handle == nil then
            return failure('INVALID_ARGUMENT', 'runtime handle is required')
        end
        if not handle then return nil, handleError end
        local bucket, bucketError = validateBucket(runtime.bucket == nil and record.bucket or runtime.bucket)
        if not bucket then return nil, bucketError end
        local position, positionError = validatePosition(runtime.position or record.position)
        if not position then
            if positionError then return nil, positionError end
            return failure('INVALID_ARGUMENT', 'runtime position is required')
        end
        local netConflict = networkRefs[netId]
        if netConflict and (netConflict.entityId ~= entityId
            or netConflict.generation ~= generation) then
            return failure('CONFLICT', 'network ID is already bound to another incarnation')
        end
        local handleConflict = handleRefs[handle]
        if handleConflict and (handleConflict.entityId ~= entityId
            or handleConflict.generation ~= generation) then
            return failure('CONFLICT', 'runtime handle is already bound to another incarnation')
        end
        if runtime.resourceCycle ~= nil and (not isInteger(runtime.resourceCycle)
            or runtime.resourceCycle < 1 or runtime.resourceCycle > 9007199254740991) then
            return failure('INVALID_ARGUMENT', 'resourceCycle is invalid')
        end
        if position then
            local indexed, indexError = putSpatial(entityId, position, bucket)
            if not indexed then return nil, indexError end
        end
        networkRefs[record.netId] = nil
        if record.handle then handleRefs[record.handle] = nil end
        if record.bucket ~= bucket then
            removeIndex(byBucket, record.bucket, entityId)
            addIndex(byBucket, bucket, entityId)
        end
        record.generation = nextGeneration
        record.netId = netId
        record.handle = handle
        record.bucket = bucket
        record.position = position
        record.resourceCycle = runtime.resourceCycle
        refreshReferences(record)
        return record
    end

    function registry.remove(entityId, generation)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        byId[entityId] = nil
        orderedEntities.remove(entityId)
        networkRefs[record.netId] = nil
        if record.handle then handleRefs[record.handle] = nil end
        removePersistent(record)
        removeBinding(record)
        removeIndex(byResource, record.resourceOwner, entityId)
        removeIndex(byBucket, record.bucket, entityId)
        removeLogical(record)
        if spatialIndex then spatialIndex.remove(entityId) end
        count = math.max(0, count - 1)
        return record
    end

    function registry.bumpGeneration(entityId, generation)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then return nil, resolveError end
        if record.generation >= 9007199254740991 then
            return failure('CONFLICT', 'entity generation is exhausted')
        end
        record.generation = record.generation + 1
        refreshReferences(record)
        return record
    end

    function registry.forResource(resourceOwner)
        return sortedRecords(byResource[resourceOwner], byId)
    end
    function registry.forOwner(resourceOwner)
        return registry.forResource(resourceOwner)
    end
    function registry.forLogicalOwner(ownerType, ownerId)
        local byOwnerId = byLogicalType[ownerType]
        return sortedRecords(byOwnerId and byOwnerId[ownerId] or nil, byId)
    end
    function registry.forBucket(bucket)
        return sortedRecords(byBucket[bucket], byId)
    end

    function registry.nearby(position, radius, bucket, limit)
        if not spatialIndex then
            return failure('UNAVAILABLE', 'The spatial index is unavailable')
        end
        local matches, query = spatialIndex.nearby(position, radius, bucket, limit)
        if not matches then return nil, query end
        local results = {}
        for _, match in ipairs(matches) do
            local record = byId[match.entityId]
            if record then
                results[#results + 1] = {
                    distanceSquared = match.distanceSquared,
                    record = record,
                }
            end
        end
        return results, query
    end
    function registry.all()
        return orderedEntities.all(function(entityId) return byId[entityId] end)
    end
    function registry.page(afterEntityId, limit)
        if afterEntityId ~= nil then
            local normalized, cursorError = SynexEntityValidation.validateEntityId(afterEntityId)
            if not normalized then return nil, cursorError end
            afterEntityId = normalized
        end
        if not isInteger(limit) or limit < 1 or limit > 1024 then
            return failure('INVALID_ARGUMENT', 'entity page limit is outside the supported range')
        end
        return orderedEntities.page(afterEntityId, limit,
            function(entityId) return byId[entityId] end)
    end
    function registry.count()
        return count
    end
    function registry.spatial()
        return spatialIndex
    end
    return registry
end
function SynexEntityRegistry.newState(options)
    local buckets, bucketIndex = orderedIndex.createStore()
    return {
        bucketIndex = bucketIndex,
        buckets = buckets,
        entities = SynexEntityRegistry.new(options),
        playerMemberships = {},
    }
end
SynexEntityValidation.newRegistry = SynexEntityRegistry.new
