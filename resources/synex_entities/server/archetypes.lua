SynexEntityArchetypes = {}

local ENTITY_TYPES = { object = true, ped = true, vehicle = true }
local PERSISTENCE_POLICIES = {
    owner_lifetime = true, persistent = true, session = true, temporary = true,
}
local RECOVERY_POLICIES = {
    automatic = true, manual = true, none = true, on_demand = true,
}
local VEHICLE_TYPES = {
    automobile = true, bike = true, boat = true, heli = true,
    plane = true, submarine = true, trailer = true,
}
local REGISTER_KEYS = {
    allowedModels = true,
    componentSchemas = true,
    defaultTags = true,
    descriptorJson = true,
    entityType = true,
    name = true,
    persistencePolicy = true,
    reasonCode = true,
    recoveryPolicy = true,
    spawnDefaults = true,
    stateSchemas = true,
    version = true,
}

local function finite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite(value) and value % 1 == 0
        and value >= minimum and value <= maximum
end

local function exactObject(value, allowed, required)
    if type(value) ~= 'table' then return false end
    for key in pairs(value) do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    for _, key in ipairs(required or {}) do
        if rawget(value, key) == nil then return false end
    end
    return true
end

local function denseArray(value, maximum, requireOne)
    if type(value) ~= 'table' or #value > maximum
        or (requireOne and #value < 1) then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key % 1 ~= 0
            or key < 1 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end

local function ownsNamespace(owner, namespace)
    return namespace == owner
        or namespace:sub(1, #owner + 1) == owner .. '.'
        or namespace:sub(1, #owner + 1) == owner .. ':'
end

local function copyArray(value)
    local result = {}
    for index, item in ipairs(value or {}) do
        if type(item) == 'table' then
            local copied = {}
            for key, child in pairs(item) do copied[key] = child end
            result[index] = copied
        else
            result[index] = item
        end
    end
    return result
end

local function sameArray(left, right, keys)
    if type(left) ~= 'table' or type(right) ~= 'table'
        or #left ~= #right then return false end
    for index = 1, #left do
        if keys then
            for _, key in ipairs(keys) do
                if left[index][key] ~= right[index][key] then return false end
            end
        elseif left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function sameDefaults(left, right)
    if type(left) ~= 'table' or type(right) ~= 'table' then return false end
    for _, key in ipairs({
        'doorFlag', 'heading', 'model', 'pedType', 'timeoutMs', 'vehicleType',
    }) do
        if left[key] ~= right[key] then return false end
    end
    return true
end

function SynexEntityArchetypes.create(options)
    assert(type(options) == 'table', 'entity archetype options are required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity archetype extension registry is required')
    local foundation = assert(options.foundation, 'entity archetype foundation is required')
    local jsonValues = assert(options.jsonValues, 'entity archetype JSON service is required')
    local ports = assert(options.ports, 'entity archetype ports are required')
    local validation = assert(options.validation, 'entity archetype validation is required')
    local service = {}

    local function fail(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end

    local function validateOwnedNamespace(value, caller, label, context)
        local namespace, namespaceError = validation.validateNamespace(value, label)
        if not namespace then
            namespaceError.traceId = context and context.traceId or nil
            return nil, namespaceError
        end
        if not ownsNamespace(caller, namespace) then
            return fail('FORBIDDEN',
                (label or 'namespace') .. ' belongs to another resource', false, context)
        end
        return namespace
    end

    local function validateOwnedReason(value, caller, context)
        local reason, reasonError = validation.validateReasonCode(value)
        if not reason then
            reasonError.traceId = context and context.traceId or nil
            return nil, reasonError
        end
        if not ownsNamespace(caller, reason) then
            return fail('FORBIDDEN',
                'reasonCode belongs to another resource', false, context)
        end
        return reason
    end

    local function stateKey(value, caller, context)
        if type(value) ~= 'string' or #value < 3 or #value > 128
            or value ~= value:lower()
            or value:match('^[a-z][a-z0-9_.:%-]+$') == nil then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype state schema key is invalid', false, context)
        end
        if not ownsNamespace(caller, value) then
            return fail('FORBIDDEN',
                'The archetype state schema key belongs to another resource', false, context)
        end
        return value
    end

    local function modelSet(value, context)
        if not denseArray(value, 32, true) then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype model set must contain between one and 32 models', false, context)
        end
        local result, seen = {}, {}
        for _, model in ipairs(value) do
            if not integer(model, 0, 4294967295) or seen[model] then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'The archetype model set is invalid', false, context)
            end
            seen[model], result[#result + 1] = true, model
        end
        table.sort(result)
        return result, seen
    end

    local function spawnDefaults(value, entityType, allowed, context)
        local keys = {
            doorFlag = true, heading = true, model = true, pedType = true,
            timeoutMs = true, vehicleType = true,
        }
        if not exactObject(value, keys, { 'model' })
            or not integer(value.model, 0, 4294967295)
            or not allowed[value.model]
            or value.heading ~= nil and (not finite(value.heading)
                or value.heading < -360 or value.heading > 360)
            or value.timeoutMs ~= nil and not integer(value.timeoutMs, 250, 10000) then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype spawn defaults are invalid', false, context)
        end
        local result = {
            heading = value.heading == nil and 0.0 or value.heading % 360.0,
            model = value.model,
            timeoutMs = value.timeoutMs,
        }
        if entityType == 'vehicle' then
            if not VEHICLE_TYPES[value.vehicleType]
                or value.pedType ~= nil or value.doorFlag ~= nil then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'Vehicle archetypes require a valid vehicleType default', false, context)
            end
            result.vehicleType = value.vehicleType
        elseif entityType == 'ped' then
            if not integer(value.pedType, 0, 29)
                or value.vehicleType ~= nil or value.doorFlag ~= nil then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'Ped archetypes require a valid pedType default', false, context)
            end
            result.pedType = value.pedType
        else
            if type(value.doorFlag) ~= 'boolean'
                or value.vehicleType ~= nil or value.pedType ~= nil then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'Object archetypes require a boolean doorFlag default', false, context)
            end
            result.doorFlag = value.doorFlag
        end
        return result
    end

    local function tags(value, caller, context)
        if not denseArray(value, 16, false) then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype default tags exceed their supported bound', false, context)
        end
        local result, seen = {}, {}
        for _, rawTag in ipairs(value) do
            local tag, tagError = validateOwnedNamespace(
                rawTag, caller, 'defaultTags', context)
            if not tag then return nil, tagError end
            if seen[tag] then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'The archetype default tags must be unique', false, context)
            end
            seen[tag], result[#result + 1] = true, tag
        end
        table.sort(result)
        return result
    end

    local function schemaReferences(value, kind, caller, epoch, context)
        if not denseArray(value, 16, false) then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype schema references exceed their supported bound', false, context)
        end
        local result, seen = {}, {}
        for _, reference in ipairs(value) do
            local nameKey = kind == 'state' and 'key' or 'namespace'
            if not exactObject(reference, { [nameKey] = true, schemaVersion = true },
                { nameKey, 'schemaVersion' })
                or not integer(reference.schemaVersion, 1, 9007199254740991) then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'An archetype schema reference is invalid', false, context)
            end
            local namespace, namespaceError
            if kind == 'state' then
                namespace, namespaceError = stateKey(reference.key, caller, context)
            else
                namespace, namespaceError = validateOwnedNamespace(
                    reference.namespace, caller, 'componentSchemas', context)
            end
            if not namespace then return nil, namespaceError end
            if seen[namespace] then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'Archetype schema references must be unique', false, context)
            end
            local definition = kind == 'state'
                and extensionRegistry.getStateSchema(namespace)
                or extensionRegistry.getComponentSchema(namespace)
            if not definition or definition.ownerResource ~= caller
                or definition.ownerEpoch ~= epoch then
                return fail('FORBIDDEN',
                    'The referenced schema belongs to another resource epoch', false, context)
            end
            if definition.schemaVersion ~= reference.schemaVersion then
                return fail('ARCHETYPE_SCHEMA_INVALID',
                    'The referenced schema version is not registered', false, context)
            end
            seen[namespace] = true
            result[#result + 1] = kind == 'state'
                and { key = namespace, schemaVersion = reference.schemaVersion }
                or { namespace = namespace, schemaVersion = reference.schemaVersion }
        end
        table.sort(result, function(left, right)
            return (left.key or left.namespace) < (right.key or right.namespace)
        end)
        return result
    end

    local function sameDefinition(left, right)
        return left.ownerResource == right.ownerResource
            and left.ownerEpoch == right.ownerEpoch
            and left.schemaVersion == right.schemaVersion
            and left.entityType == right.entityType
            and left.persistencePolicy == right.persistencePolicy
            and left.recoveryPolicy == right.recoveryPolicy
            and left.descriptorJson == right.descriptorJson
            and sameDefaults(left.spawnDefaults, right.spawnDefaults)
            and sameArray(left.allowedModels, right.allowedModels)
            and sameArray(left.defaultTags, right.defaultTags)
            and sameArray(left.componentSchemas, right.componentSchemas,
                { 'namespace', 'schemaVersion' })
            and sameArray(left.stateSchemas, right.stateSchemas,
                { 'key', 'schemaVersion' })
    end

    function service.registerOwned(request, caller, epoch, context)
        if not exactObject(request, REGISTER_KEYS, {
            'allowedModels', 'componentSchemas', 'defaultTags', 'descriptorJson',
            'entityType', 'name', 'persistencePolicy', 'reasonCode',
            'recoveryPolicy', 'spawnDefaults', 'stateSchemas', 'version',
        }) then
            return fail('INVALID_ARGUMENT',
                'Archetype registration is invalid', false, context)
        end
        local name, nameError = validateOwnedNamespace(request.name, caller, 'name', context)
        if not name then return nil, nameError end
        local reason, reasonError = validateOwnedReason(request.reasonCode, caller, context)
        if not reason then return nil, reasonError end
        if not integer(request.version, 1, 9007199254740991)
            or not ENTITY_TYPES[request.entityType]
            or not PERSISTENCE_POLICIES[request.persistencePolicy]
            or not RECOVERY_POLICIES[request.recoveryPolicy]
            or request.recoveryPolicy == 'automatic'
                and request.persistencePolicy ~= 'persistent'
                and request.persistencePolicy ~= 'owner_lifetime'
            or type(request.descriptorJson) ~= 'string'
            or #request.descriptorJson < 2 or #request.descriptorJson > 16384 then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The archetype descriptor is invalid', false, context)
        end
        local models, modelLookup = modelSet(request.allowedModels, context)
        if not models then return nil, modelLookup end
        local defaults, defaultsError = spawnDefaults(
            request.spawnDefaults, request.entityType, modelLookup, context)
        if not defaults then return nil, defaultsError end
        local defaultTags, tagsError = tags(request.defaultTags, caller, context)
        if not defaultTags then return nil, tagsError end
        local componentSchemas, componentError = schemaReferences(
            request.componentSchemas, 'component', caller, epoch, context)
        if not componentSchemas then return nil, componentError end
        local stateSchemas, stateError = schemaReferences(
            request.stateSchemas, 'state', caller, epoch, context)
        if not stateSchemas then return nil, stateError end
        local descriptor, descriptorError = jsonValues.decode(request.descriptorJson, 'object')
        if descriptor == nil then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                descriptorError and descriptorError.message
                    or 'The archetype descriptor JSON is invalid', false, context)
        end
        local definition = {
            allowedModels = models,
            componentSchemas = componentSchemas,
            defaultTags = defaultTags,
            descriptor = descriptor,
            descriptorJson = request.descriptorJson,
            entityType = request.entityType,
            namespace = name,
            ownerEpoch = epoch,
            ownerResource = caller,
            persistencePolicy = request.persistencePolicy,
            recoveryPolicy = request.recoveryPolicy,
            schemaVersion = request.version,
            spawnDefaults = defaults,
            stateSchemas = stateSchemas,
            version = request.version,
        }
        local existing = extensionRegistry.getArchetype(name)
        if existing then
            if sameDefinition(existing, definition) then
                return { name = name, ownerResource = caller,
                    registered = true, version = request.version }
            end
            return fail('ARCHETYPE_CONFLICT',
                'The archetype namespace is already registered', false, context)
        end
        local registered, registerError = extensionRegistry.registerArchetype(
            caller, epoch, definition)
        if not registered then
            local code = type(registerError) == 'table' and registerError.code or nil
            if code == 'FOREIGN_NAMESPACE' then code = 'FORBIDDEN' end
            if code == 'CONFLICT' then code = 'ARCHETYPE_CONFLICT' end
            if code ~= 'FORBIDDEN' and code ~= 'STALE_RESOURCE'
                and code ~= 'ARCHETYPE_CONFLICT' then code = 'ARCHETYPE_SCHEMA_INVALID' end
            return fail(code,
                type(registerError) == 'table' and registerError.message
                    or 'The archetype registration failed', false, context)
        end
        return { name = name, ownerResource = caller,
            registered = true, version = request.version }
    end

    local function archetypeReference(value, context)
        if not exactObject(value, { namespace = true, version = true },
            { 'namespace', 'version' }) then
            return fail('INVALID_ARGUMENT', 'The archetype reference is invalid', false, context)
        end
        local namespace, namespaceError = validation.validateNamespace(
            value.namespace, 'archetype.namespace')
        if not namespace then
            namespaceError.traceId = context and context.traceId or nil
            return nil, namespaceError
        end
        if not integer(value.version, 1, 9007199254740991) then
            return fail('INVALID_ARGUMENT',
                'The archetype version is outside the supported range', false, context)
        end
        return { namespace = namespace, version = value.version }
    end

    local function allowedModel(definition, model)
        for _, candidate in ipairs(definition.allowedModels or {}) do
            if candidate == model then return true end
        end
        return false
    end

    function service.prepareSpawn(request, invokingResource, context)
        if type(request) ~= 'table' or request.archetype == nil then
            return request, nil
        end
        local reference, referenceError = archetypeReference(request.archetype, context)
        if not reference then return nil, nil, referenceError end
        local definition = extensionRegistry.getArchetype(reference.namespace)
        if not definition or definition.schemaVersion ~= reference.version
            or not foundation.isResourceActive(definition.ownerResource) then
            local _, operationError = fail('ARCHETYPE_NOT_FOUND',
                'The requested archetype version is not active', false, context)
            return nil, nil, operationError
        end
        local prepared = {}
        for key, value in pairs(request) do prepared[key] = value end
        prepared.archetype = { namespace = reference.namespace, version = reference.version }
        if prepared.entityType == nil then
            prepared.entityType = definition.entityType
        elseif prepared.entityType ~= definition.entityType then
            local _, operationError = fail('INVALID_ENTITY_TYPE',
                'The explicit entity type conflicts with its archetype', false, context)
            return nil, nil, operationError
        end
        if prepared.model == nil then
            prepared.model = definition.spawnDefaults.model
        else
            local model, modelError = validation.normalizeHash(prepared.model)
            if not model then modelError.traceId = context and context.traceId return nil, nil, modelError end
            prepared.model = model
        end
        if not allowedModel(definition, prepared.model) then
            local _, operationError = fail('INVALID_MODEL',
                'The explicit model is not allowed by its archetype', false, context)
            return nil, nil, operationError
        end
        if prepared.heading == nil then prepared.heading = definition.spawnDefaults.heading end
        if prepared.timeoutMs == nil then prepared.timeoutMs = definition.spawnDefaults.timeoutMs end
        if prepared.persistencePolicy == nil and prepared.persistent == nil then
            prepared.persistencePolicy = definition.persistencePolicy
        end
        if prepared.recoveryPolicy == nil then
            prepared.recoveryPolicy = definition.recoveryPolicy
        end
        if prepared.tags == nil then prepared.tags = copyArray(definition.defaultTags) end
        if definition.entityType == 'vehicle' and prepared.vehicleType == nil then
            prepared.vehicleType = definition.spawnDefaults.vehicleType
        elseif definition.entityType == 'ped' and prepared.pedType == nil then
            prepared.pedType = definition.spawnDefaults.pedType
        elseif definition.entityType == 'object' and prepared.doorFlag == nil then
            prepared.doorFlag = definition.spawnDefaults.doorFlag
        end
        return prepared, definition
    end

    function service.descriptorJson(normalized, definition, context)
        local frozen = {
            allowedModels = copyArray(definition.allowedModels),
            componentSchemas = copyArray(definition.componentSchemas),
            defaultTags = copyArray(definition.defaultTags),
            descriptor = definition.descriptor,
            entityType = definition.entityType,
            namespace = definition.namespace,
            ownerResource = definition.ownerResource,
            persistencePolicy = definition.persistencePolicy,
            recoveryPolicy = definition.recoveryPolicy,
            spawnDefaults = definition.spawnDefaults,
            stateSchemas = copyArray(definition.stateSchemas),
            version = definition.schemaVersion,
        }
        local persisted = {
            archetype = frozen,
            resolvedSpawn = {
                doorFlag = normalized.doorFlag,
                entityType = normalized.entityType,
                model = normalized.model,
                pedType = normalized.pedType,
                persistencePolicy = normalized.persistencePolicy,
                recoveryPolicy = normalized.recoveryPolicy,
                vehicleType = normalized.vehicleType,
            },
        }
        local ok, encoded = foundation.protect('entity.archetype_descriptor.encode',
            function() return ports.jsonEncode(persisted) end, context)
        if not ok or type(encoded) ~= 'string' or #encoded < 2 or #encoded > 32768 then
            return fail('ARCHETYPE_SCHEMA_INVALID',
                'The frozen archetype descriptor exceeds its supported bound', false, context)
        end
        return encoded
    end

    return service
end
