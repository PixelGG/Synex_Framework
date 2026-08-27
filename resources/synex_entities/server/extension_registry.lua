SynexEntityExtensionRegistry = {}

local KINDS = {
    archetype = true,
    component = true,
    state = true,
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

local function validateOwner(value)
    if type(value) ~= 'string' or #value < 1 or #value > 64
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return failure('INVALID_ARGUMENT', 'owner resource is invalid')
    end
    return value
end

local function validateEpoch(value)
    if not isInteger(value) or value < 1 or value > 9007199254740991 then
        return failure('INVALID_ARGUMENT', 'owner epoch is invalid')
    end
    return value
end

local function validateNamespace(value)
    if type(value) ~= 'string' or #value < 3 or #value > 128
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return failure('INVALID_ARGUMENT', 'extension namespace is invalid')
    end
    return value
end

local function ownsNamespace(owner, namespace)
    return namespace == owner
        or namespace:sub(1, #owner + 1) == owner .. '.'
        or namespace:sub(1, #owner + 1) == owner .. ':'
end

local function copyBounded(value, limits)
    local state = { active = {}, bytes = 0, keys = 0 }

    local function copy(item, depth)
        if depth > limits.maximumDepth then
            return failure('DEFINITION_TOO_LARGE', 'extension definition exceeds its depth limit')
        end
        local kind = type(item)
        if kind == 'nil' or kind == 'boolean' then return item end
        if kind == 'number' then
            if not isFinite(item) then
                return failure('INVALID_DEFINITION', 'extension definition contains a non-finite number')
            end
            state.bytes = state.bytes + 16
            return item
        end
        if kind == 'string' then
            if #item > limits.maximumStringBytes then
                return failure('DEFINITION_TOO_LARGE', 'extension definition contains an oversized string')
            end
            state.bytes = state.bytes + #item
            if state.bytes > limits.maximumBytes then
                return failure('DEFINITION_TOO_LARGE', 'extension definition exceeds its byte limit')
            end
            return item
        end
        if kind ~= 'table' or getmetatable(item) ~= nil then
            return failure('INVALID_DEFINITION', 'extension definitions must be plain JSON data')
        end
        if state.active[item] then
            return failure('INVALID_DEFINITION', 'extension definition contains a cycle')
        end
        state.active[item] = true

        local result = {}
        local keyKind
        local maximumIndex = 0
        local itemCount = 0
        for key, child in pairs(item) do
            local currentKeyKind = type(key)
            if currentKeyKind ~= 'string' and currentKeyKind ~= 'number' then
                state.active[item] = nil
                return failure('INVALID_DEFINITION', 'extension definition contains an invalid key')
            end
            if currentKeyKind == 'number' and (not isInteger(key) or key < 1) then
                state.active[item] = nil
                return failure('INVALID_DEFINITION', 'extension definition arrays must use positive indices')
            end
            if keyKind and keyKind ~= currentKeyKind then
                state.active[item] = nil
                return failure('INVALID_DEFINITION', 'extension definition cannot mix array and object keys')
            end
            keyKind = currentKeyKind
            if currentKeyKind == 'string' then
                if #key > limits.maximumStringBytes then
                    state.active[item] = nil
                    return failure('DEFINITION_TOO_LARGE', 'extension definition contains an oversized key')
                end
                state.bytes = state.bytes + #key
            else
                maximumIndex = math.max(maximumIndex, key)
            end
            state.keys = state.keys + 1
            itemCount = itemCount + 1
            if state.keys > limits.maximumKeys or state.bytes > limits.maximumBytes then
                state.active[item] = nil
                return failure('DEFINITION_TOO_LARGE', 'extension definition exceeds its structural limits')
            end
            local copied, copyError = copy(child, depth + 1)
            if copied == nil and copyError then
                state.active[item] = nil
                return nil, copyError
            end
            result[key] = copied
        end
        if keyKind == 'number' and maximumIndex ~= itemCount then
            state.active[item] = nil
            return failure('INVALID_DEFINITION', 'extension definition arrays must be dense')
        end
        state.active[item] = nil
        return result
    end

    return copy(value, 1)
end

function SynexEntityExtensionRegistry.create(options)
    options = options or {}
    local maximumDefinitions = options.maximumDefinitions or 2048
    local maximumDefinitionsPerOwner = options.maximumDefinitionsPerOwner or 256
    local maximumListResults = options.maximumListResults or 256
    local limits = {
        maximumBytes = options.maximumDefinitionBytes or 32768,
        maximumDepth = options.maximumDefinitionDepth or 10,
        maximumKeys = options.maximumDefinitionKeys or 512,
        maximumStringBytes = options.maximumStringBytes or 8192,
    }
    local returnLimits = {
        maximumBytes = limits.maximumBytes + 512,
        maximumDepth = limits.maximumDepth,
        maximumKeys = limits.maximumKeys + 8,
        maximumStringBytes = limits.maximumStringBytes,
    }
    assert(isInteger(maximumDefinitions) and maximumDefinitions >= 1
        and maximumDefinitions <= 20000, 'maximumDefinitions is invalid')
    assert(isInteger(maximumDefinitionsPerOwner) and maximumDefinitionsPerOwner >= 1
        and maximumDefinitionsPerOwner <= maximumDefinitions,
        'maximumDefinitionsPerOwner is invalid')
    assert(isInteger(maximumListResults) and maximumListResults >= 1
        and maximumListResults <= 1024, 'maximumListResults is invalid')
    assert(isInteger(limits.maximumBytes) and limits.maximumBytes >= 1024
        and limits.maximumBytes <= 262144, 'maximumDefinitionBytes is invalid')
    assert(isInteger(limits.maximumDepth) and limits.maximumDepth >= 2
        and limits.maximumDepth <= 32, 'maximumDefinitionDepth is invalid')
    assert(isInteger(limits.maximumKeys) and limits.maximumKeys >= 8
        and limits.maximumKeys <= 4096, 'maximumDefinitionKeys is invalid')
    assert(isInteger(limits.maximumStringBytes) and limits.maximumStringBytes >= 64
        and limits.maximumStringBytes <= limits.maximumBytes, 'maximumStringBytes is invalid')

    local activeEpochs = {}
    local entries = { archetype = {}, component = {}, state = {} }
    local ownerEntries = {}
    local ownerCounts = {}
    local count = 0
    local registry = {}

    local function removeOwnerEntries(owner)
        local owned = ownerEntries[owner]
        if not owned then return 0 end
        local removed = 0
        for kind, namespaces in pairs(owned) do
            for namespace in pairs(namespaces) do
                local current = entries[kind][namespace]
                if current and current.ownerResource == owner then
                    entries[kind][namespace] = nil
                    count = math.max(0, count - 1)
                    removed = removed + 1
                end
            end
        end
        ownerEntries[owner] = nil
        ownerCounts[owner] = nil
        return removed
    end

    function registry.beginOwner(ownerResource, ownerEpoch)
        local owner, ownerError = validateOwner(ownerResource)
        if not owner then return nil, ownerError end
        local epoch, epochError = validateEpoch(ownerEpoch)
        if not epoch then return nil, epochError end
        if activeEpochs[owner] and epoch < activeEpochs[owner] then
            return failure('STALE_RESOURCE', 'extension owner epoch moved backwards')
        end
        if activeEpochs[owner] == epoch then
            return { ownerResource = owner, ownerEpoch = epoch, replaced = 0 }
        end
        local replaced = removeOwnerEntries(owner)
        activeEpochs[owner] = epoch
        return { ownerResource = owner, ownerEpoch = epoch, replaced = replaced }
    end

    function registry.isCurrent(ownerResource, ownerEpoch)
        return activeEpochs[ownerResource] == ownerEpoch
    end

    function registry.register(kind, ownerResource, ownerEpoch, definition)
        if not KINDS[kind] then
            return failure('INVALID_ARGUMENT', 'extension kind is invalid')
        end
        local owner, ownerError = validateOwner(ownerResource)
        if not owner then return nil, ownerError end
        local epoch, epochError = validateEpoch(ownerEpoch)
        if not epoch then return nil, epochError end
        if activeEpochs[owner] ~= epoch then
            return failure('STALE_RESOURCE', 'extension owner epoch is not current')
        end
        if type(definition) ~= 'table' then
            return failure('INVALID_DEFINITION', 'extension definition must be an object')
        end
        local namespace, namespaceError = validateNamespace(definition.namespace)
        if not namespace then return nil, namespaceError end
        if not ownsNamespace(owner, namespace) then
            return failure('FOREIGN_NAMESPACE', 'extension namespace belongs to another resource')
        end
        if definition.ownerResource ~= nil and definition.ownerResource ~= owner then
            return failure('FOREIGN_NAMESPACE', 'definition owner does not match the invoking resource')
        end
        if definition.ownerEpoch ~= nil and definition.ownerEpoch ~= epoch then
            return failure('STALE_RESOURCE', 'definition owner epoch does not match')
        end
        local schemaVersion = definition.schemaVersion or definition.version
        if not isInteger(schemaVersion) or schemaVersion < 1 or schemaVersion > 1000000 then
            return failure('INVALID_DEFINITION', 'definition schemaVersion is invalid')
        end
        if entries[kind][namespace] then
            return failure('CONFLICT', 'extension namespace is already registered')
        end
        if count >= maximumDefinitions
            or (ownerCounts[owner] or 0) >= maximumDefinitionsPerOwner then
            return failure('REGISTRY_LIMIT', 'extension registry limit has been reached')
        end

        local stored, copyError = copyBounded(definition, limits)
        if not stored then return nil, copyError end
        stored.kind = kind
        stored.namespace = namespace
        stored.ownerEpoch = epoch
        stored.ownerResource = owner
        stored.schemaVersion = schemaVersion
        local result, resultError = copyBounded(stored, returnLimits)
        if not result then return nil, resultError end
        entries[kind][namespace] = stored
        ownerEntries[owner] = ownerEntries[owner] or {
            archetype = {}, component = {}, state = {},
        }
        ownerEntries[owner][kind][namespace] = true
        ownerCounts[owner] = (ownerCounts[owner] or 0) + 1
        count = count + 1
        return result
    end

    function registry.unregister(kind, ownerResource, ownerEpoch, namespace)
        if not KINDS[kind] then
            return failure('INVALID_ARGUMENT', 'extension kind is invalid')
        end
        if activeEpochs[ownerResource] ~= ownerEpoch then
            return failure('STALE_RESOURCE', 'extension owner epoch is not current')
        end
        local current = entries[kind][namespace]
        if not current then return false end
        if current.ownerResource ~= ownerResource or current.ownerEpoch ~= ownerEpoch then
            return failure('FORBIDDEN', 'extension registration belongs to another owner epoch')
        end
        entries[kind][namespace] = nil
        local owned = ownerEntries[ownerResource]
        if owned then
            owned[kind][namespace] = nil
            if next(owned.archetype) == nil and next(owned.component) == nil
                and next(owned.state) == nil then ownerEntries[ownerResource] = nil end
        end
        ownerCounts[ownerResource] = math.max(0, (ownerCounts[ownerResource] or 1) - 1)
        if ownerCounts[ownerResource] == 0 then ownerCounts[ownerResource] = nil end
        count = math.max(0, count - 1)
        return true
    end

    function registry.get(kind, namespace)
        if not KINDS[kind] then
            return failure('INVALID_ARGUMENT', 'extension kind is invalid')
        end
        local normalized, namespaceError = validateNamespace(namespace)
        if not normalized then return nil, namespaceError end
        local current = entries[kind][normalized]
        if not current then return failure('NOT_FOUND', 'extension definition is not registered') end
        if activeEpochs[current.ownerResource] ~= current.ownerEpoch then
            return failure('STALE_RESOURCE', 'extension definition belongs to a stale resource epoch')
        end
        return copyBounded(current, returnLimits)
    end

    function registry.list(kind, ownerResource, limit)
        if not KINDS[kind] then
            return failure('INVALID_ARGUMENT', 'extension kind is invalid')
        end
        if ownerResource ~= nil then
            local ownerError
            ownerResource, ownerError = validateOwner(ownerResource)
            if not ownerResource then return nil, ownerError end
        end
        limit = limit or maximumListResults
        if not isInteger(limit) or limit < 1 or limit > maximumListResults then
            return failure('INVALID_ARGUMENT', 'extension list limit is invalid')
        end
        local namespaces = {}
        for namespace, current in pairs(entries[kind]) do
            if ownerResource == nil or current.ownerResource == ownerResource then
                namespaces[#namespaces + 1] = namespace
            end
        end
        table.sort(namespaces)
        local truncated = #namespaces > limit
        local result = {}
        for index = 1, math.min(#namespaces, limit) do
            local copied, copyError = copyBounded(
                entries[kind][namespaces[index]],
                returnLimits
            )
            if not copied then return nil, copyError end
            result[#result + 1] = copied
        end
        return result, { truncated = truncated }
    end

    function registry.cleanup(ownerResource, ownerEpoch)
        if activeEpochs[ownerResource] ~= ownerEpoch then return 0 end
        local removed = removeOwnerEntries(ownerResource)
        activeEpochs[ownerResource] = nil
        return removed
    end

    function registry.registerArchetype(ownerResource, ownerEpoch, definition)
        return registry.register('archetype', ownerResource, ownerEpoch, definition)
    end

    function registry.registerComponentSchema(ownerResource, ownerEpoch, definition)
        return registry.register('component', ownerResource, ownerEpoch, definition)
    end

    function registry.registerStateSchema(ownerResource, ownerEpoch, definition)
        return registry.register('state', ownerResource, ownerEpoch, definition)
    end

    function registry.getArchetype(namespace)
        return registry.get('archetype', namespace)
    end

    function registry.getComponentSchema(namespace)
        return registry.get('component', namespace)
    end

    function registry.getStateSchema(namespace)
        return registry.get('state', namespace)
    end

    function registry.snapshot()
        return {
            archetypes = (function()
                local value = 0
                for _ in pairs(entries.archetype) do value = value + 1 end
                return value
            end)(),
            components = (function()
                local value = 0
                for _ in pairs(entries.component) do value = value + 1 end
                return value
            end)(),
            states = (function()
                local value = 0
                for _ in pairs(entries.state) do value = value + 1 end
                return value
            end)(),
            total = count,
        }
    end

    return registry
end
