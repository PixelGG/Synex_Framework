SynexEntityRegistry = {}

local function failure(code, message)
    return nil, { code = code, message = message, retryable = false }
end

function SynexEntityRegistry.new()
    local byId = {}
    local byNetId = {}
    local byOwner = {}
    local byPersistentKey = {}
    local count = 0
    local registry = {}

    function registry.insert(record)
        local entityId, entityIdError = SynexEntityValidation.validateEntityId(record and record.entityId)
        if not entityId then
            return nil, entityIdError
        end

        local generation, generationError = SynexEntityValidation.validateGeneration(record.generation)
        if not generation then
            return nil, generationError
        end

        local resourceOwner, ownerError = SynexEntityValidation.validateCaller(record.resourceOwner)
        if not resourceOwner then
            return nil, ownerError
        end

        if type(record.netId) ~= 'number'
            or record.netId ~= record.netId
            or record.netId == math.huge
            or record.netId == -math.huge
            or record.netId % 1 ~= 0
            or record.netId < 1
            or record.netId > 65535 then
            return failure('INVALID_ARGUMENT', 'netId is outside the supported range')
        end
        if record.persistentKey ~= nil then
            local persistentKey, persistentKeyError = SynexEntityValidation.validatePersistentKey(record.persistentKey)
            if not persistentKey then
                return nil, persistentKeyError
            end
            if byPersistentKey[persistentKey] then
                return failure('CONFLICT', 'persistentKey is already registered')
            end
            record.persistentKey = persistentKey
        end
        if byId[entityId] or byNetId[record.netId] then
            return failure('CONFLICT', 'entityId or netId is already registered')
        end

        record.entityId = entityId
        record.generation = generation
        record.resourceOwner = resourceOwner
        byId[entityId] = record
        byNetId[record.netId] = { entityId = entityId, generation = generation }
        if record.persistentKey then
            byPersistentKey[record.persistentKey] = { entityId = entityId, generation = generation }
        end
        byOwner[resourceOwner] = byOwner[resourceOwner] or {}
        byOwner[resourceOwner][entityId] = true
        count = count + 1
        return record
    end

    function registry.resolve(entityId, generation, resourceOwner)
        local record = byId[entityId]
        if not record then
            return failure('NOT_FOUND', 'entity is not registered')
        end
        if record.generation ~= generation then
            return failure('STALE_ENTITY', 'entity generation does not match')
        end
        if resourceOwner and record.resourceOwner ~= resourceOwner then
            return failure('FORBIDDEN', 'entity belongs to another resource')
        end
        return record
    end

    function registry.byNetworkId(netId)
        local reference = byNetId[netId]
        if not reference then
            return nil
        end
        return byId[reference.entityId], reference.generation
    end

    function registry.byPersistentKey(persistentKey, resourceOwner)
        local reference = byPersistentKey[persistentKey]
        if not reference then
            return failure('NOT_FOUND', 'persistent entity is not registered')
        end
        return registry.resolve(reference.entityId, reference.generation, resourceOwner)
    end

    function registry.remove(entityId, generation)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then
            return nil, resolveError
        end

        byId[entityId] = nil
        byNetId[record.netId] = nil
        if record.persistentKey then
            byPersistentKey[record.persistentKey] = nil
        end
        local ownerEntries = byOwner[record.resourceOwner]
        if ownerEntries then
            ownerEntries[entityId] = nil
            if next(ownerEntries) == nil then
                byOwner[record.resourceOwner] = nil
            end
        end
        count = count - 1
        return record
    end

    function registry.bumpGeneration(entityId, generation)
        local record, resolveError = registry.resolve(entityId, generation)
        if not record then
            return nil, resolveError
        end

        record.generation = record.generation + 1
        byNetId[record.netId].generation = record.generation
        if record.persistentKey then
            byPersistentKey[record.persistentKey].generation = record.generation
        end
        return record
    end

    function registry.forOwner(resourceOwner)
        local records = {}
        for entityId in pairs(byOwner[resourceOwner] or {}) do
            records[#records + 1] = byId[entityId]
        end
        table.sort(records, function(left, right)
            return left.entityId < right.entityId
        end)
        return records
    end

    function registry.forLogicalOwner(ownerType, ownerId)
        local records = {}
        for _, record in pairs(byId) do
            if record.owner and record.owner.type == ownerType and record.owner.id == ownerId then
                records[#records + 1] = record
            end
        end
        table.sort(records, function(left, right)
            return left.entityId < right.entityId
        end)
        return records
    end

    function registry.all()
        local records = {}
        for _, record in pairs(byId) do
            records[#records + 1] = record
        end
        table.sort(records, function(left, right)
            return left.entityId < right.entityId
        end)
        return records
    end

    function registry.count()
        return count
    end

    return registry
end

function SynexEntityRegistry.newState()
    return {
        buckets = {},
        entities = SynexEntityRegistry.new(),
        playerMemberships = {},
    }
end

SynexEntityValidation.newRegistry = SynexEntityRegistry.new
