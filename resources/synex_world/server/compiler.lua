SynexWorldCompiler = {}

local Compiler = SynexWorldCompiler
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Geometry = assert(SynexWorldGeometry, 'world geometry must be loaded first')
local Graph = assert(SynexWorldGraph, 'world graph must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local commonFields = {
    kind = true, key = true, label = true, parent = true, tags = true,
    mapPackages = true, iplBundles = true, geometry = true,
}

local kindFields = {
    region = {}, location = {}, zone = {},
    interior = { gameInteriorId = true },
    room = { gameRoomKey = true },
    anchor = { position = true, radius = true, entityRef = true },
    door = { position = true, heading = true, leaves = true, defaultState = true,
        persistent = true, accessPolicy = true, autoRelockSeconds = true },
    portal = { portalType = true, source = true, destination = true,
        accessPolicy = true, enabled = true },
    instance_template = { baseLocation = true, entry = true, exit = true,
        capacity = true, ttlSeconds = true, isolationProfile = true,
        cleanupPolicy = true },
    map_package = { resourceName = true, packageType = true,
        expectedResourceState = true, locations = true, dependencies = true,
        version = true, required = true },
    ipl_bundle = { ipls = true, scope = true, interiorSets = true },
    world_state_definition = { stateType = true, scope = true,
        persistence = true, schemaVersion = true, default = true, allowed = true,
        minimum = true, maximum = true, maxLength = true, structuredSchema = true },
}

local spatialKinds = {
    region = true, location = true, interior = true, room = true, zone = true,
    anchor = true, door = true, portal = true,
}

local contextKinds = {
    region = true, location = true, interior = true, room = true, zone = true,
}

local function failure(code, message, details)
    return Validation.failure(code, message, false, details)
end

local function exactForKind(object)
    local specific = kindFields[object.kind]
    if not specific then return false end
    for key in pairs(object) do
        if not commonFields[key] and not specific[key] then return false end
    end
    return true
end

local function stringArray(value, maximum, validator, errorMessage)
    if value == nil then return {} end
    if not Validation.isDenseArray(value, maximum) then
        return failure('WORLD_BUNDLE_INVALID', errorMessage)
    end
    local result, seen = {}, {}
    for index, candidate in ipairs(value) do
        local normalized, normalizeError = validator(candidate)
        if not normalized then return nil, normalizeError end
        if seen[normalized] then
            return failure('WORLD_BUNDLE_INVALID', errorMessage .. ' Values must be unique.')
        end
        seen[normalized] = true
        result[index] = normalized
    end
    table.sort(result)
    return result
end

local function resourceDependency(value)
    if type(value) ~= 'string' or #value < 1 or #value > 64
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.-]*$') == nil
        or value:find('..', 1, true) then
        return failure('WORLD_DEPENDENCY_MISSING', 'World resource dependency is invalid.')
    end
    return value
end

local function semanticVersion(value)
    if type(value) ~= 'string' or #value < 1 or #value > 64
        or value:find('+', 1, true) then return false end
    local core, prerelease = value, nil
    local separator = value:find('-', 1, true)
    if separator then
        core, prerelease = value:sub(1, separator - 1), value:sub(separator + 1)
        if #prerelease < 1 or prerelease:sub(1, 1) == '.'
            or prerelease:sub(-1) == '.' or prerelease:find('..', 1, true) then return false end
    end
    local major, minor, patch = core:match('^(%d+)%.(%d+)%.(%d+)$')
    local function validNumeric(identifier)
        return identifier ~= nil and (identifier == '0'
            or identifier:match('^[1-9]%d*$') ~= nil)
    end
    if not validNumeric(major) or not validNumeric(minor) or not validNumeric(patch) then
        return false
    end
    if prerelease then
        for identifier in prerelease:gmatch('[^.]+') do
            if identifier:match('^[0-9A-Za-z-]+$') == nil
                or identifier:match('^%d+$') and not validNumeric(identifier) then return false end
        end
    end
    return true
end

local function referenceArray(value, message)
    return stringArray(value, 32, function(candidate)
        return Validation.namespacedKey(candidate)
    end, message)
end

local function normalizeEntityRef(value)
    if value == nil then return nil end
    if not Validation.exactObject(value, { entityId = true, generation = true })
        or type(value.entityId) ~= 'string' or #value.entityId < 8 or #value.entityId > 64
        or value.entityId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
        or not Validation.isInteger(value.generation, 1, 9007199254740991) then
        return failure('WORLD_REFERENCE_INVALID', 'Entity-bound anchor reference is invalid.')
    end
    return { entityId = value.entityId, generation = value.generation }
end

local function normalizeAccessPolicy(value)
    if value == nil then return nil end
    if not Validation.exactObject(value, {
            requiredCapability = true, groupId = true, scope = true,
            stateRequirements = true, requireSameInstance = true,
        }) or next(value) == nil then
        return failure('WORLD_BUNDLE_INVALID', 'World access policy is invalid.')
    end
    local policy = { requireSameInstance = value.requireSameInstance == true }
    if value.requiredCapability ~= nil or value.groupId ~= nil then
        if type(value.requiredCapability) ~= 'string' or #value.requiredCapability < 1
            or #value.requiredCapability > 96
            or value.requiredCapability:match('^[a-z][a-z0-9._*-]*$') == nil
            or type(value.groupId) ~= 'string' or #value.groupId < 8 or #value.groupId > 48
            or value.groupId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or (value.scope ~= nil and value.scope ~= 'group' and value.scope ~= 'subtree') then
            return failure('WORLD_BUNDLE_INVALID', 'World capability policy is invalid.')
        end
        policy.requiredCapability, policy.groupId = value.requiredCapability, value.groupId
        policy.scope = value.scope or 'group'
    elseif value.scope ~= nil then
        return failure('WORLD_BUNDLE_INVALID', 'World access scope requires a capability policy.')
    end
    if value.stateRequirements ~= nil then
        if not Validation.isDenseArray(value.stateRequirements, 16) then
            return failure('WORLD_BUNDLE_INVALID', 'World state requirements are invalid.')
        end
        policy.stateRequirements = {}
        for index, requirement in ipairs(value.stateRequirements) do
            local requirementValue = requirement and requirement.value
            local valueType = type(requirementValue)
            local scalarValue = valueType == 'boolean'
                or valueType == 'number' and Validation.isFinite(requirementValue)
                    and math.abs(requirementValue) <= 9007199254740991
                    and (math.type(requirementValue) ~= 'integer'
                        or Validation.isInteger(requirementValue,
                            -9007199254740991, 9007199254740991))
                or valueType == 'string' and #requirementValue <= 256
                    and not Validation.hasControl(requirementValue)
            if not Validation.exactObject(requirement,
                    { key = true, scopeRef = true, operator = true, value = true })
                or (requirement.operator ~= 'equals' and requirement.operator ~= 'not_equals')
                or not scalarValue then
                return failure('WORLD_BUNDLE_INVALID', 'World state requirement is invalid.',
                    { requirement = index })
            end
            local key, keyError = Validation.namespacedKey(requirement.key)
            if not key then return nil, keyError end
            if requirement.scopeRef ~= nil then
                local scopeRef, scopeError = Validation.namespacedKey(requirement.scopeRef)
                if not scopeRef then return nil, scopeError end
            end
            policy.stateRequirements[index] = Validation.copy(requirement)
        end
    else
        policy.stateRequirements = {}
    end
    return policy
end

local function normalizeDoor(object, normalized)
    local position, positionError = Validation.vector3(object.position)
    if not position then return nil, positionError end
    if not Validation.isDenseArray(object.leaves, 8) or #object.leaves < 1
        or (object.defaultState ~= 'LOCKED' and object.defaultState ~= 'UNLOCKED'
            and object.defaultState ~= 'DISABLED')
        or type(object.persistent) ~= 'boolean'
        or (object.heading ~= nil and (not Validation.isFinite(object.heading)
            or math.abs(object.heading) > Limits.maximumHeadingMagnitude))
        or (object.autoRelockSeconds ~= nil
            and not Validation.isInteger(object.autoRelockSeconds, 1, 86400)) then
        return failure('WORLD_BUNDLE_INVALID', 'World door definition is invalid.')
    end
    normalized.position, normalized.heading = position, (object.heading or 0) % 360
    normalized.defaultState, normalized.persistent = object.defaultState, object.persistent
    normalized.autoRelockSeconds = object.autoRelockSeconds
    normalized.leaves = {}
    local leafIds = {}
    for index, leaf in ipairs(object.leaves) do
        if not Validation.exactObject(leaf,
                { id = true, model = true, position = true, heading = true, doorHash = true })
            or type(leaf.id) ~= 'string' or #leaf.id < 1 or #leaf.id > 32
            or leaf.id:match('^[a-z][a-z0-9_.-]*$') == nil or leafIds[leaf.id]
            or not Validation.isInteger(leaf.model, 0, 4294967295)
            or (leaf.doorHash ~= nil and not Validation.isInteger(leaf.doorHash, 0, 4294967295))
            or (leaf.heading ~= nil and (not Validation.isFinite(leaf.heading)
                or math.abs(leaf.heading) > Limits.maximumHeadingMagnitude)) then
            return failure('WORLD_BUNDLE_INVALID', 'World door leaf is invalid.', { leaf = index })
        end
        local leafPosition, leafError = Validation.vector3(leaf.position)
        if not leafPosition then return nil, leafError end
        leafIds[leaf.id] = true
        normalized.leaves[index] = { id = leaf.id, model = leaf.model,
            position = leafPosition, heading = (leaf.heading or 0) % 360,
            doorHash = leaf.doorHash and Validation.uint32(leaf.doorHash) or nil }
    end
    normalized.accessPolicy, positionError = normalizeAccessPolicy(object.accessPolicy)
    if object.accessPolicy and not normalized.accessPolicy then return nil, positionError end
    return { type = 'sphere', center = position, radius = 8.0 }
end

local function normalizePortal(object, normalized)
    if object.portalType ~= 'physical' and object.portalType ~= 'teleport'
        and object.portalType ~= 'instance'
        or not Validation.exactObject(object.source, { position = true, radius = true })
        or not Validation.isFinite(object.source.radius) or object.source.radius < 0.5
        or object.source.radius > Limits.maximumPortalDistance
        or not Validation.isPlainTable(object.destination) then
        return failure('WORLD_BUNDLE_INVALID', 'World portal definition is invalid.')
    end
    local source, sourceError = Validation.vector3(object.source.position)
    if not source then return nil, sourceError end
    normalized.portalType, normalized.source = object.portalType,
        { position = source, radius = object.source.radius + 0.0 }
    normalized.enabled = object.enabled ~= false
    normalized.accessPolicy, sourceError = normalizeAccessPolicy(object.accessPolicy)
    if object.accessPolicy and not normalized.accessPolicy then return nil, sourceError end
    if object.portalType == 'physical' then
        if not Validation.exactObject(object.destination, { target = true }) then
            return failure('WORLD_BUNDLE_INVALID', 'Physical portal destination is invalid.')
        end
        local target, targetError = Validation.namespacedKey(object.destination.target)
        if not target then return nil, targetError end
        normalized.destination = { target = target }
    elseif object.portalType == 'teleport' then
        if not Validation.exactObject(object.destination,
                { position = true, heading = true, target = true })
            or (object.destination.heading ~= nil
                and (not Validation.isFinite(object.destination.heading)
                    or math.abs(object.destination.heading) > Limits.maximumHeadingMagnitude)) then
            return failure('WORLD_BUNDLE_INVALID', 'Teleport portal destination is invalid.')
        end
        local destination, destinationError = Validation.vector3(object.destination.position)
        if not destination then return nil, destinationError end
        normalized.destination = { position = destination,
            heading = (object.destination.heading or 0) % 360 }
        if object.destination.target then
            normalized.destination.target, destinationError = Validation.namespacedKey(
                object.destination.target)
            if not normalized.destination.target then return nil, destinationError end
        end
    else
        if not Validation.exactObject(object.destination,
                { instanceTemplate = true, entry = true }) then
            return failure('WORLD_BUNDLE_INVALID', 'Instance portal destination is invalid.')
        end
        local template, templateError = Validation.namespacedKey(
            object.destination.instanceTemplate)
        if not template then return nil, templateError end
        normalized.destination = { instanceTemplate = template }
        if object.destination.entry then
            normalized.destination.entry, templateError = Validation.vector3(object.destination.entry)
            if not normalized.destination.entry then return nil, templateError end
        end
    end
    return { type = 'sphere', center = source, radius = object.source.radius }
end

local function normalizeInstanceTemplate(object, normalized)
    local baseLocation, refError = Validation.namespacedKey(object.baseLocation)
    if not baseLocation then return nil, refError end
    local entry, entryError = Validation.vector3(object.entry)
    if not entry then return nil, entryError end
    local exit, exitError = Validation.vector3(object.exit)
    if not exit then return nil, exitError end
    local emptyTtl = object.cleanupPolicy == 'empty_ttl'
        and Validation.isInteger(object.ttlSeconds, 1, 86400)
    local noTtl = object.cleanupPolicy ~= 'empty_ttl' and object.ttlSeconds == nil
    if not Validation.isInteger(object.capacity, 1, Limits.maximumInstanceMembers)
        or not emptyTtl and not noTtl
        or (object.isolationProfile ~= 'isolated_strict'
            and object.isolationProfile ~= 'session'
            and object.isolationProfile ~= 'character_selection'
            and object.isolationProfile ~= 'custom')
        or (object.cleanupPolicy ~= 'empty_ttl' and object.cleanupPolicy ~= 'owner_stop'
            and object.cleanupPolicy ~= 'manual') then
        return failure('WORLD_BUNDLE_INVALID', 'World instance template is invalid.')
    end
    normalized.baseLocation, normalized.entry, normalized.exit = baseLocation, entry, exit
    normalized.capacity, normalized.ttlSeconds = object.capacity, object.ttlSeconds
    normalized.isolationProfile, normalized.cleanupPolicy = object.isolationProfile,
        object.cleanupPolicy
    return nil
end

local function normalizeMapPackage(object, normalized)
    local resourceName, resourceError = resourceDependency(object.resourceName)
    if not resourceName then return nil, resourceError end
    local packageTypes = { mlo = true, ymap = true, ipl = true,
        interior = true, custom = true }
    if not packageTypes[object.packageType]
        or (object.expectedResourceState or 'started') ~= 'started'
        or (object.version ~= nil and not semanticVersion(object.version))
        or (object.required ~= nil and type(object.required) ~= 'boolean') then
        return failure('WORLD_BUNDLE_INVALID', 'World map package is invalid.')
    end
    local locations, locationsError = referenceArray(object.locations,
        'World map package locations are invalid.')
    if not locations then return nil, locationsError end
    local dependencies, dependenciesError = stringArray(object.dependencies, 32,
        resourceDependency, 'World map package dependencies are invalid.')
    if not dependencies then return nil, dependenciesError end
    normalized.resourceName, normalized.packageType = resourceName, object.packageType
    normalized.expectedResourceState, normalized.required = 'started', object.required ~= false
    normalized.locations, normalized.dependencies, normalized.version = locations,
        dependencies, object.version
    return nil
end

local function normalizeIplBundle(object, normalized)
    if object.scope ~= 'global' and object.scope ~= 'context' and object.scope ~= 'instance' then
        return failure('WORLD_BUNDLE_INVALID', 'IPL bundle scope is invalid.')
    end
    local ipls, iplError = stringArray(object.ipls, 64, function(value)
        if type(value) ~= 'string' or #value < 1 or #value > 96
            or Validation.hasControl(value) then
            return failure('WORLD_BUNDLE_INVALID', 'IPL name is invalid.')
        end
        return value
    end, 'IPL names are invalid.')
    if not ipls or #ipls < 1 then return nil, iplError or failure(
        'WORLD_BUNDLE_INVALID', 'IPL bundle must contain at least one IPL.') end
    normalized.scope, normalized.ipls = object.scope, ipls
    normalized.interiorSets = {}
    if object.interiorSets ~= nil then
        if not Validation.isDenseArray(object.interiorSets, 32) then
            return failure('WORLD_BUNDLE_INVALID', 'Interior entity sets are invalid.')
        end
        for index, item in ipairs(object.interiorSets) do
            if not Validation.exactObject(item,
                    { interiorId = true, name = true, color = true })
                or not Validation.isInteger(item.interiorId, 0, 2147483647)
                or type(item.name) ~= 'string' or #item.name < 1 or #item.name > 64
                or Validation.hasControl(item.name)
                or (item.color ~= nil and not Validation.isInteger(item.color, 0, 255)) then
                return failure('WORLD_BUNDLE_INVALID', 'Interior entity set is invalid.',
                    { interiorSet = index })
            end
            normalized.interiorSets[index] = Validation.copy(item)
        end
    end
    return nil
end

local function structuredPropertyName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') ~= nil
end

local function normalizeStructuredNode(candidate, depth, maximumDepth, counter)
    if not Validation.isPlainTable(candidate) or type(candidate.type) ~= 'string' then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured state node is invalid.')
    end
    counter.value = counter.value + 1
    if counter.value > Limits.maximumStructuredStateSchemaNodes then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured state schema is too complex.')
    end
    local nodeType = candidate.type
    if nodeType == 'boolean' then
        if not Validation.exactObject(candidate, { type = true }) then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'Boolean state node is invalid.')
        end
        return { type = nodeType }
    end
    if nodeType == 'integer' or nodeType == 'number' then
        if not Validation.exactObject(candidate,
                { type = true, minimum = true, maximum = true })
            or candidate.minimum ~= nil and (not Validation.isFinite(candidate.minimum)
                or math.abs(candidate.minimum) > 9007199254740991)
            or candidate.maximum ~= nil and (not Validation.isFinite(candidate.maximum)
                or math.abs(candidate.maximum) > 9007199254740991)
            or candidate.minimum ~= nil and candidate.maximum ~= nil
                and candidate.minimum > candidate.maximum then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'Numeric state node is invalid.')
        end
        return { type = nodeType, minimum = candidate.minimum, maximum = candidate.maximum }
    end
    if nodeType == 'string' then
        if not Validation.exactObject(candidate, { type = true, maxLength = true })
            or not Validation.isInteger(candidate.maxLength, 1, 4096) then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'String state node is invalid.')
        end
        return { type = nodeType, maxLength = candidate.maxLength }
    end
    if nodeType == 'enum' then
        if not Validation.exactObject(candidate, { type = true, allowed = true })
            or not Validation.isDenseArray(candidate.allowed, 64) or #candidate.allowed < 1 then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'Enum state node is invalid.')
        end
        local allowed, seen = {}, {}
        for index, value in ipairs(candidate.allowed) do
            if type(value) ~= 'string' or #value < 1 or #value > 128
                or Validation.hasControl(value) or seen[value] then
                return failure('WORLD_STATE_SCHEMA_INVALID', 'Enum state node is invalid.')
            end
            allowed[index], seen[value] = value, true
        end
        return { type = nodeType, allowed = allowed }
    end
    if nodeType == 'object' then
        if depth > maximumDepth or not Validation.exactObject(candidate, {
                type = true, properties = true, required = true,
                additionalProperties = true,
            }) or not Validation.isPlainTable(candidate.properties)
            or candidate.additionalProperties ~= false
            or not Validation.isDenseArray(candidate.required,
                Limits.maximumStructuredStateProperties) then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'Object state node is invalid.')
        end
        local keys = {}
        for key in pairs(candidate.properties) do
            if not structuredPropertyName(key) then
                return failure('WORLD_STATE_SCHEMA_INVALID',
                    'Structured state property name is invalid.')
            end
            keys[#keys + 1] = key
            if #keys > Limits.maximumStructuredStateProperties then
                return failure('WORLD_STATE_SCHEMA_INVALID',
                    'Structured state property capacity is exceeded.')
            end
        end
        table.sort(keys)
        local normalized = { type = nodeType, properties = {},
            required = {}, additionalProperties = false }
        for _, key in ipairs(keys) do
            local child, childError = normalizeStructuredNode(
                candidate.properties[key], depth + 1, maximumDepth, counter)
            if not child then return nil, childError end
            normalized.properties[key] = child
        end
        local required = {}
        for index, key in ipairs(candidate.required) do
            if not structuredPropertyName(key) or not normalized.properties[key]
                or required[key] then
                return failure('WORLD_STATE_SCHEMA_INVALID',
                    'Structured state required property is invalid.')
            end
            normalized.required[index], required[key] = key, true
        end
        table.sort(normalized.required)
        return normalized
    end
    if nodeType == 'array' then
        if depth > maximumDepth or not Validation.exactObject(candidate,
                { type = true, items = true, maximumItems = true })
            or not Validation.isInteger(candidate.maximumItems, 1,
                Limits.maximumStructuredStateArrayItems) then
            return failure('WORLD_STATE_SCHEMA_INVALID', 'Array state node is invalid.')
        end
        local items, itemsError = normalizeStructuredNode(
            candidate.items, depth + 1, maximumDepth, counter)
        if not items then return nil, itemsError end
        return { type = nodeType, items = items, maximumItems = candidate.maximumItems }
    end
    return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured state node type is invalid.')
end

local function normalizeStructuredSchema(schema)
    if not Validation.isPlainTable(schema)
        or (schema.type ~= 'object' and schema.type ~= 'array')
        or not Validation.isInteger(schema.maximumBytes, 1, Limits.maximumStateBytes)
        or not Validation.isInteger(schema.maximumDepth, 1,
            Limits.maximumStructuredStateDepth)
        or not Validation.isInteger(schema.maximumEntries, 1,
            Limits.maximumStructuredStateItems) then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured World state schema is invalid.')
    end
    local allowed = { type = true, maximumBytes = true, maximumDepth = true,
        maximumEntries = true }
    local node = { type = schema.type }
    if schema.type == 'object' then
        allowed.properties, allowed.required, allowed.additionalProperties = true, true, true
        node.properties, node.required = schema.properties, schema.required
        node.additionalProperties = schema.additionalProperties
    else
        allowed.items, allowed.maximumItems = true, true
        node.items, node.maximumItems = schema.items, schema.maximumItems
    end
    if not Validation.exactObject(schema, allowed) then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured World state schema is invalid.')
    end
    local normalized, normalizeError = normalizeStructuredNode(
        node, 1, schema.maximumDepth, { value = 0 })
    if not normalized then return nil, normalizeError end
    normalized.maximumBytes, normalized.maximumDepth, normalized.maximumEntries =
        schema.maximumBytes, schema.maximumDepth, schema.maximumEntries
    return normalized
end

local function validStructuredState(value, schema)
    local entries, active, encodedBytes = 0, {}, 0
    local function stringBytes(candidate)
        local bytes = 2
        for index = 1, #candidate do
            local byte = candidate:byte(index)
            if byte == 34 or byte == 92 then
                bytes = bytes + 2
            elseif byte < 32 or byte == 127 then
                return nil
            else
                bytes = bytes + 1
            end
        end
        return bytes
    end
    local function visit(candidate, node, depth)
        if node.type == 'boolean' then
            if type(candidate) ~= 'boolean' then return false end
            encodedBytes = encodedBytes + (candidate and 4 or 5)
            return true
        end
        if node.type == 'integer' then
            local valid = Validation.isInteger(candidate, -9007199254740991, 9007199254740991)
                and (node.minimum == nil or candidate >= node.minimum)
                and (node.maximum == nil or candidate <= node.maximum)
            if valid then encodedBytes = encodedBytes + #tostring(candidate) end
            return valid
        end
        if node.type == 'number' then
            local valid = Validation.isFinite(candidate) and math.abs(candidate) <= 9007199254740991
                and (node.minimum == nil or candidate >= node.minimum)
                and (node.maximum == nil or candidate <= node.maximum)
            if valid then encodedBytes = encodedBytes + #tostring(candidate) end
            return valid
        end
        if node.type == 'string' then
            if type(candidate) ~= 'string' or #candidate > node.maxLength then return false end
            local bytes = stringBytes(candidate)
            if not bytes then return false end
            encodedBytes = encodedBytes + bytes
            return true
        end
        if node.type == 'enum' then
            if type(candidate) ~= 'string' then return false end
            for _, allowed in ipairs(node.allowed) do
                if candidate == allowed then
                    encodedBytes = encodedBytes + assert(stringBytes(candidate))
                    return true
                end
            end
            return false
        end
        if type(candidate) ~= 'table' or not Validation.isJsonTable(candidate)
            or depth > schema.maximumDepth or active[candidate] then return false end
        local containerKind = Validation.jsonContainerKind(candidate)
        if node.type == 'array' and containerKind == 'object'
            or node.type == 'object' and containerKind == 'array' then return false end
        active[candidate] = true
        if node.type == 'array' then
            if not Validation.isDenseArray(candidate, node.maximumItems) then
                active[candidate] = nil; return false
            end
            encodedBytes = encodedBytes + 2
            for index, item in ipairs(candidate) do
                if index > 1 then encodedBytes = encodedBytes + 1 end
                entries = entries + 1
                if entries > schema.maximumEntries or not visit(item, node.items, depth + 1) then
                    active[candidate] = nil; return false
                end
            end
        else
            local seen = {}
            local count = 0
            encodedBytes = encodedBytes + 2
            for key, item in pairs(candidate) do
                local child = type(key) == 'string' and node.properties[key] or nil
                if not child then active[candidate] = nil; return false end
                entries, seen[key] = entries + 1, true
                count = count + 1
                if count > 1 then encodedBytes = encodedBytes + 1 end
                encodedBytes = encodedBytes + assert(stringBytes(key)) + 1
                if entries > schema.maximumEntries or not visit(item, child, depth + 1) then
                    active[candidate] = nil; return false
                end
            end
            for _, key in ipairs(node.required) do
                if not seen[key] then active[candidate] = nil; return false end
            end
        end
        active[candidate] = nil
        return true
    end
    return visit(value, schema, 1) and encodedBytes <= schema.maximumBytes
end

local function validStateValue(definition, value)
    if definition.stateType == 'boolean' then return type(value) == 'boolean' end
    if definition.stateType == 'integer' then
        return Validation.isInteger(value, -9007199254740991, 9007199254740991)
            and (definition.minimum == nil or value >= definition.minimum)
            and (definition.maximum == nil or value <= definition.maximum)
    end
    if definition.stateType == 'number' then
        return Validation.isFinite(value) and math.abs(value) <= 9007199254740991
            and (definition.minimum == nil or value >= definition.minimum)
            and (definition.maximum == nil or value <= definition.maximum)
    end
    if definition.stateType == 'string' then
        return type(value) == 'string' and #value <= (definition.maxLength or 4096)
            and #value <= Limits.maximumStateBytes and not Validation.hasControl(value)
    end
    if definition.stateType == 'enum' then
        if type(value) ~= 'string' then return false end
        for _, allowed in ipairs(definition.allowed or {}) do
            if value == allowed then return true end
        end
        return false
    end
    if definition.stateType == 'structured' then
        return validStructuredState(value, definition.structuredSchema)
    end
    return false
end

local function normalizeStateDefinition(object, normalized)
    local scalarTypes = { boolean = true, integer = true, number = true,
        string = true, enum = true, structured = true }
    local scopes = { global = true, region = true, location = true,
        interior = true, room = true, instance = true }
    if not scalarTypes[object.stateType] or not scopes[object.scope]
        or (object.persistence ~= 'runtime' and object.persistence ~= 'persistent')
        or not Validation.isInteger(object.schemaVersion, 1, 2147483647)
        or (object.minimum ~= nil and (not Validation.isFinite(object.minimum)
            or math.abs(object.minimum) > 9007199254740991))
        or (object.maximum ~= nil and (not Validation.isFinite(object.maximum)
            or math.abs(object.maximum) > 9007199254740991))
        or (object.minimum ~= nil and object.maximum ~= nil and object.minimum > object.maximum)
        or (object.maxLength ~= nil and not Validation.isInteger(object.maxLength, 1, 4096)) then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'World state definition is invalid.')
    end
    normalized.stateType, normalized.scope = object.stateType, object.scope
    normalized.persistence, normalized.schemaVersion = object.persistence, object.schemaVersion
    normalized.minimum, normalized.maximum, normalized.maxLength = object.minimum,
        object.maximum, object.maxLength
    if object.stateType == 'enum' then
        local allowed, allowedError = stringArray(object.allowed, 64, function(value)
            if type(value) ~= 'string' or #value < 1 or #value > 128
                or Validation.hasControl(value) then
                return failure('WORLD_STATE_SCHEMA_INVALID', 'World enum value is invalid.')
            end
            return value
        end, 'World enum values are invalid.')
        if not allowed or #allowed < 1 then return nil, allowedError or failure(
            'WORLD_STATE_SCHEMA_INVALID', 'World enum requires allowed values.') end
        normalized.allowed = allowed
    elseif object.allowed ~= nil then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Allowed values are valid only for enum state.')
    end
    if object.stateType == 'structured' then
        local structuredSchema, schemaError = normalizeStructuredSchema(object.structuredSchema)
        if not structuredSchema then return nil, schemaError end
        normalized.structuredSchema = structuredSchema
    elseif object.structuredSchema ~= nil then
        return failure('WORLD_STATE_SCHEMA_INVALID', 'Structured schema is valid only for structured state.')
    end
    normalized.default = Validation.copy(object.default)
    if rawget(object, 'default') ~= nil and not validStateValue(normalized, normalized.default) then
        return failure('WORLD_STATE_SCHEMA_INVALID',
            'World state default does not satisfy its schema.')
    end
    return nil
end

local function compileObject(object, ownerResource, bundleKey)
    if not Validation.isPlainTable(object) or not exactForKind(object) then
        return failure('WORLD_BUNDLE_INVALID', 'World object contains unsupported fields.')
    end
    local key, keyError = Validation.namespacedKey(object.key, ownerResource)
    if not key then return nil, keyError end
    local label, labelError = Validation.objectLabel(object.label)
    if object.label ~= nil and not label then return nil, labelError end
    local parent
    if object.parent ~= nil then
        parent, keyError = Validation.namespacedKey(object.parent)
        if not parent then return nil, keyError end
    end
    local tags, tagsError = Validation.tags(object.tags)
    if not tags then return nil, tagsError end
    local mapPackages, mapError = referenceArray(object.mapPackages,
        'World map package references are invalid.')
    if not mapPackages then return nil, mapError end
    local iplBundles, iplError = referenceArray(object.iplBundles,
        'World IPL bundle references are invalid.')
    if not iplBundles then return nil, iplError end
    local normalized = { kind = object.kind, key = key, label = label,
        parent = parent, tags = tags, mapPackages = mapPackages,
        iplBundles = iplBundles, ownerResource = ownerResource, bundleKey = bundleKey }
    local geometryCandidate = object.geometry
    if object.kind == 'anchor' then
        local position, positionError = Validation.vector3(object.position)
        if not position then return nil, positionError end
        if object.radius ~= nil and (not Validation.isFinite(object.radius)
            or object.radius < 0 or object.radius > 100) then
            return failure('WORLD_BUNDLE_INVALID', 'World anchor radius is invalid.')
        end
        normalized.position, normalized.radius = position, object.radius or 0
        normalized.entityRef, positionError = normalizeEntityRef(object.entityRef)
        if object.entityRef and not normalized.entityRef then return nil, positionError end
        geometryCandidate = object.radius and object.radius > 0
            and { type = 'sphere', center = position, radius = object.radius }
            or { type = 'point', position = position }
    elseif object.kind == 'door' then
        geometryCandidate, keyError = normalizeDoor(object, normalized)
        if not geometryCandidate then return nil, keyError end
    elseif object.kind == 'portal' then
        geometryCandidate, keyError = normalizePortal(object, normalized)
        if not geometryCandidate then return nil, keyError end
    elseif object.kind == 'instance_template' then
        local _, templateError = normalizeInstanceTemplate(object, normalized)
        if templateError then return nil, templateError end
    elseif object.kind == 'map_package' then
        local _, packageError = normalizeMapPackage(object, normalized)
        if packageError then return nil, packageError end
    elseif object.kind == 'ipl_bundle' then
        local _, bundleError = normalizeIplBundle(object, normalized)
        if bundleError then return nil, bundleError end
    elseif object.kind == 'world_state_definition' then
        local _, stateError = normalizeStateDefinition(object, normalized)
        if stateError then return nil, stateError end
    elseif object.kind == 'interior' then
        if object.gameInteriorId ~= nil and not Validation.isInteger(
            object.gameInteriorId, 0, 2147483647) then
            return failure('WORLD_BUNDLE_INVALID', 'GTA interior metadata is invalid.')
        end
        normalized.gameInteriorId = object.gameInteriorId
    elseif object.kind == 'room' then
        if object.gameRoomKey ~= nil and (type(object.gameRoomKey) ~= 'string'
            or #object.gameRoomKey > 64 or Validation.hasControl(object.gameRoomKey)) then
            return failure('WORLD_BUNDLE_INVALID', 'GTA room metadata is invalid.')
        end
        normalized.gameRoomKey = object.gameRoomKey
    end
    if contextKinds[object.kind] and geometryCandidate == nil then
        return failure('WORLD_GEOMETRY_INVALID', 'Spatial world object requires geometry.', { key = key })
    end
    local compiled
    if geometryCandidate then
        compiled, keyError = Geometry.compile(geometryCandidate)
        if not compiled then
            if type(keyError) == 'table' then
                keyError.details = keyError.details or {}; keyError.details.key = key
            end
            return nil, keyError
        end
    end
    normalized.geometry = geometryCandidate and Validation.copy(geometryCandidate) or nil
    normalized.compiledGeometry = compiled
    normalized.spatial = spatialKinds[object.kind] == true and compiled ~= nil
    return normalized
end

function Compiler.compileBundle(candidate, ownerResource, ownerEpoch)
    local owner, ownerError = Validation.resourceName(ownerResource)
    if not owner then return nil, ownerError end
    if not Validation.isInteger(ownerEpoch, 1, 9007199254740991) then
        return failure('STALE_RESOURCE', 'World bundle owner epoch is invalid.')
    end
    if not Validation.exactObject(candidate, {
            ['$schema'] = true, schema = true, key = true, version = true,
            dependencies = true, objects = true,
        }) or candidate.schema ~= Limits.schemaVersion
        or candidate['$schema'] ~= nil and (type(candidate['$schema']) ~= 'string'
            or #candidate['$schema'] < 1 or #candidate['$schema'] > 256
            or Validation.hasControl(candidate['$schema']))
        or not semanticVersion(candidate.version)
        or not Validation.isDenseArray(candidate.objects, Limits.maximumBundleObjects)
        or #candidate.objects < 1 then
        return failure('WORLD_BUNDLE_INVALID', 'World bundle envelope is invalid.')
    end
    local key, keyError = Validation.namespacedKey(candidate.key, owner)
    if not key then return nil, keyError end
    local dependencies, dependencyError = stringArray(candidate.dependencies, 32,
        resourceDependency, 'World bundle dependencies are invalid.')
    if not dependencies then return nil, dependencyError end
    local dependencySet = {}
    for _, dependency in ipairs(dependencies) do dependencySet[dependency] = true end
    local objects, orderedKeys = {}, {}
    for index, object in ipairs(candidate.objects) do
        local compiled, compileError = compileObject(object, owner, key)
        if not compiled then
            if type(compileError) == 'table' then
                compileError.details = compileError.details or {}; compileError.details.object = index
            end
            return nil, compileError
        end
        if objects[compiled.key] then
            return failure('WORLD_BUNDLE_CONFLICT', 'World bundle contains a duplicate key.',
                { key = compiled.key })
        end
        objects[compiled.key] = compiled
        orderedKeys[#orderedKeys + 1] = compiled.key
    end
    table.sort(orderedKeys)
    return { schema = Limits.schemaVersion, key = key, version = candidate.version,
        ownerResource = owner, ownerEpoch = ownerEpoch, dependencies = dependencies,
        dependencySet = dependencySet, objects = objects, orderedKeys = orderedKeys }
end

function Compiler.validateCombined(objects, bundles)
    local doorHashes, objectKeys = {}, {}
    for key in pairs(objects) do objectKeys[#objectKeys + 1] = key end
    table.sort(objectKeys)
    for _, key in ipairs(objectKeys) do
        local object = objects[key]
        if object.kind == 'door' then
            for _, leaf in ipairs(object.leaves) do
                local hash = Validation.uint32(leaf.doorHash)
                    or Validation.doorHash(object.key, leaf.id)
                local previous = doorHashes[hash]
                if previous then
                    return failure('WORLD_BUNDLE_CONFLICT',
                        'World door leaves resolve to the same DoorSystem hash.', {
                            doorHash = hash,
                            first = previous.doorKey .. ':' .. previous.leafId,
                            second = object.key .. ':' .. leaf.id,
                        })
                end
                doorHashes[hash] = { doorKey = object.key, leafId = leaf.id }
            end
        end
    end
    local graph, graphError = Graph.build(objects)
    if not graph then return nil, graphError end
    for key, object in pairs(objects) do
        local bundle = bundles[object.bundleKey]
        local function validateReference(reference, expectedKind)
            local target = objects[reference]
            if not target or (expectedKind and target.kind ~= expectedKind) then
                return failure('WORLD_REFERENCE_INVALID', 'World object reference is invalid.',
                    { key = key, reference = reference, expectedKind = expectedKind })
            end
            if target.ownerResource ~= object.ownerResource
                and not bundle.dependencySet[target.ownerResource] then
                return failure('WORLD_DEPENDENCY_MISSING',
                    'Cross-bundle reference owner is not a declared dependency.',
                    { key = key, dependency = target.ownerResource })
            end
            return true
        end
        for _, reference in ipairs(object.mapPackages or {}) do
            local valid, referenceError = validateReference(reference, 'map_package')
            if not valid then return nil, referenceError end
        end
        for _, reference in ipairs(object.iplBundles or {}) do
            local valid, referenceError = validateReference(reference, 'ipl_bundle')
            if not valid then return nil, referenceError end
        end
        if object.kind == 'world_state_definition' then
            local ranks = { region = 1, location = 2, interior = 3, room = 4 }
            local parent = object.parent and objects[object.parent] or nil
            if object.scope == 'global' and parent ~= nil
                or parent and ranks[object.scope]
                    and (not ranks[parent.kind] or ranks[parent.kind] > ranks[object.scope]) then
                return failure('WORLD_REFERENCE_INVALID',
                    'World state definition parent is incompatible with its scope.', {
                        key = key, parent = object.parent, scope = object.scope,
                    })
            end
        end
        for _, requirement in ipairs(object.accessPolicy and object.accessPolicy.stateRequirements or {}) do
            local valid, referenceError = validateReference(
                requirement.key, 'world_state_definition')
            if not valid then return nil, referenceError end
            local definition = objects[requirement.key]
            if definition.scope == 'global' and requirement.scopeRef ~= nil
                or definition.scope == 'instance' and requirement.scopeRef ~= nil then
                return failure('WORLD_REFERENCE_INVALID',
                    'World state requirement uses an invalid explicit scope.', {
                        key = key, reference = requirement.key,
                    })
            end
            if requirement.scopeRef ~= nil then
                valid, referenceError = validateReference(
                    requirement.scopeRef, definition.scope)
                if not valid then return nil, referenceError end
            end
            if definition.parent ~= nil then
                local current, matched = object, false
                while current do
                    if current.key == definition.parent then matched = true; break end
                    current = current.parent and objects[current.parent] or nil
                end
                if not matched then
                    return failure('WORLD_REFERENCE_INVALID',
                        'World access state definition is outside the target hierarchy.', {
                            key = key, reference = requirement.key,
                    })
                end
                if requirement.scopeRef ~= nil then
                    current, matched = objects[requirement.scopeRef], false
                    while current do
                        if current.key == definition.parent then matched = true; break end
                        current = current.parent and objects[current.parent] or nil
                    end
                    if not matched then
                        return failure('WORLD_REFERENCE_INVALID',
                            'World access state scope is outside its definition hierarchy.', {
                                key = key, reference = requirement.scopeRef,
                            })
                    end
                end
            end
            if definition.stateType == 'structured'
                or not validStateValue(definition, requirement.value) then
                return failure('WORLD_STATE_SCHEMA_INVALID',
                    'World access state requirement does not satisfy its state schema.', {
                        key = key, reference = requirement.key,
                    })
            end
        end
        if object.kind == 'portal' then
            local destination = object.destination
            local reference = destination.target or destination.instanceTemplate
            if reference then
                local expected = destination.instanceTemplate and 'instance_template' or nil
                local valid, referenceError = validateReference(reference, expected)
                if not valid then return nil, referenceError end
            end
        elseif object.kind == 'instance_template' then
            local valid, referenceError = validateReference(object.baseLocation, 'location')
            if not valid then return nil, referenceError end
        elseif object.kind == 'map_package' then
            for _, reference in ipairs(object.locations) do
                local valid, referenceError = validateReference(reference, 'location')
                if not valid then return nil, referenceError end
            end
        end
    end
    local resourceEdges, activeResources = {}, {}
    for _, bundle in pairs(bundles) do
        activeResources[bundle.ownerResource] = true
    end
    for _, bundle in pairs(bundles) do
        resourceEdges[bundle.ownerResource] = resourceEdges[bundle.ownerResource] or {}
        for _, dependency in ipairs(bundle.dependencies) do
            if activeResources[dependency] then
                resourceEdges[bundle.ownerResource][dependency] = true
            end
        end
    end
    local states = {}
    local function visit(resource)
        if states[resource] == 1 then
            return failure('WORLD_GRAPH_CYCLE', 'World bundle dependency graph contains a cycle.',
                { resource = resource })
        end
        if states[resource] == 2 then return true end
        states[resource] = 1
        for dependency in pairs(resourceEdges[resource] or {}) do
            if resourceEdges[dependency] then
                local valid, cycleError = visit(dependency)
                if not valid then return nil, cycleError end
            end
        end
        states[resource] = 2
        return true
    end
    for resource in pairs(resourceEdges) do
        local valid, cycleError = visit(resource)
        if not valid then return nil, cycleError end
    end
    return graph
end
