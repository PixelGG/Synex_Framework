assert(SynexBridgeKernel and SynexBridgeKernel.Foundation,
    'synex_bridge kernel foundation must load before catalogs')

local Foundation = SynexBridgeKernel.Foundation
local Catalogs = {}

local REGISTRY_DEFAULTS = {
    maximumEntries = 256,
    maximumEntriesPerOwner = 64,
    maximumOwners = 64,
}
local ADAPTER_FIELDS = {
    name = true, version = true, provider = true, domain = true,
    status = true, operations = true,
}
local CATALOG_FIELDS = {
    name = true, version = true, provider = true, domain = true,
    status = true, authority = true, revision = true, operations = true,
}
local CATALOG_AUTHORITIES = { domain = true, ['compatibility/static'] = true }
local DOMAIN_INTERFACES = {
    identity = true, accounts = true, groups = true, metadata = true,
    inventory = true, vehicles = true, interaction = true,
    notifications = true, ui = true, banking = true, provider = true,
}

local function validateStringArray(value, maximum)
    if type(value) ~= 'table' or #value < 1 or #value > maximum then return false end
    local seen = {}
    for index, item in ipairs(value) do
        if not Foundation.isIdentifier(item) or seen[item] then return false end
        seen[item] = true
    end
    for key in pairs(value) do
        if not Foundation.isSafeInteger(key, 1, #value) then return false end
    end
    return true
end

local function validateExecutableDefinition(definition, fields, catalog)
    local normalized, definitionError = Foundation.copyClosedObject(definition, fields, {
        'name', 'version', 'provider', 'domain', 'status', 'operations',
    }, { root = 'object', maximumEntries = 160, maximumBytes = 32768 })
    if not normalized then return nil, definitionError end
    if not Foundation.isDefinitionName(normalized.name) or not Foundation.semver(normalized.version)
        or (normalized.provider ~= 'all' and not Foundation.isProvider(normalized.provider))
        or not Foundation.isIdentifier(normalized.domain)
        or DOMAIN_INTERFACES[normalized.domain] ~= true
        or not Foundation.isStatus(normalized.status)
        or not validateStringArray(normalized.operations, 64) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if catalog then
        if CATALOG_AUTHORITIES[normalized.authority] ~= true
            or not Foundation.isSafeInteger(
                normalized.revision, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
    elseif normalized.authority ~= nil or normalized.revision ~= nil then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return normalized, nil
end

function Catalogs.createRegistry(options)
    if type(options) ~= 'table' or not Foundation.isIdentifier(options.kind)
        or (options.validate ~= nil and type(options.validate) ~= 'function')
        or (options.validateUpdate ~= nil
            and type(options.validateUpdate) ~= 'function') then
        error('compatibility registry options are invalid')
    end
    local limits = {}
    for key, default in pairs(REGISTRY_DEFAULTS) do
        local candidate = options[key]
        if candidate ~= nil and not Foundation.isSafeInteger(candidate, 1, 4096) then
            error('compatibility registry limits are invalid')
        end
        limits[key] = candidate or default
    end
    if limits.maximumEntriesPerOwner > limits.maximumEntries
        or limits.maximumOwners > limits.maximumEntries then
        error('compatibility registry limits are inconsistent')
    end

    local nameField = options.nameField or 'name'
    local versionField = options.versionField or 'version'
    if not Foundation.isIdentifier(nameField) or not Foundation.isIdentifier(versionField) then
        error('compatibility registry key fields are invalid')
    end
    local records = {}
    local ownerKeys = {}
    local size = 0
    local ownerCount = 0

    local function keyFor(name, version)
        local parsed = Foundation.semver(version)
        if not parsed then return nil end
        return ('%s@%d'):format(name, parsed.major)
    end

    local registry = {}
    function registry:register(owner, epoch, definition)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local copied, copyError = Foundation.copyDto(definition, {
            root = 'object', maximumEntries = 512, maximumBytes = 65536,
            maximumArrayItems = 128, maximumObjectProperties = 64,
        })
        if not copied then return nil, copyError end
        if not Foundation.isDefinitionName(copied[nameField])
            or not Foundation.semver(copied[versionField]) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local normalized, validationError = copied, nil
        if options.validate then normalized, validationError = options.validate(copied) end
        if not normalized then return nil, validationError or Foundation.error('COMPAT_INVALID_ARGUMENT') end
        local final, finalError = Foundation.copyDto(normalized, {
            root = 'object', maximumEntries = 512, maximumBytes = 65536,
            maximumArrayItems = 128, maximumObjectProperties = 64,
        })
        if not final then return nil, finalError end
        if final[nameField] ~= copied[nameField]
            or final[versionField] ~= copied[versionField] then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end

        local key = keyFor(final[nameField], final[versionField])
        local previous = records[key]
        if previous then
            if previous.owner ~= owner then return nil, Foundation.error('COMPAT_OWNER_CONFLICT') end
            if epoch < previous.epoch
                or Foundation.compareSemver(final[versionField], previous.definition[versionField]) < 0 then
                return nil, Foundation.error('COMPAT_VERSION_CONFLICT')
            end
            if options.validateUpdate then
                local accepted, updateError = options.validateUpdate(
                    previous.definition, final)
                if not accepted then
                    return nil, updateError or Foundation.error('COMPAT_VERSION_CONFLICT')
                end
            end
            previous.definition = final
            previous.epoch = epoch
            return Foundation.copyDto(final), nil, key
        end

        local owned = ownerKeys[owner]
        if not owned then
            if ownerCount >= limits.maximumOwners then
                return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
            end
            owned = {}
            ownerKeys[owner] = owned
            ownerCount = ownerCount + 1
        end
        local ownedCount = 0
        for _ in pairs(owned) do ownedCount = ownedCount + 1 end
        if size >= limits.maximumEntries or ownedCount >= limits.maximumEntriesPerOwner then
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        records[key] = { owner = owner, epoch = epoch, definition = final }
        owned[key] = true
        size = size + 1
        return Foundation.copyDto(final), nil, key
    end

    function registry:get(name, major)
        if not Foundation.isDefinitionName(name)
            or not Foundation.isSafeInteger(major, 0, 65535) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local record = records[('%s@%d'):format(name, major)]
        if not record then return nil, Foundation.error('COMPAT_MAPPING_MISSING') end
        return Foundation.copyDto(record.definition), nil
    end

    function registry:list()
        local items = {}
        for _, record in pairs(records) do items[#items + 1] = Foundation.copyDto(record.definition) end
        table.sort(items, function(left, right)
            if left[nameField] == right[nameField] then
                return left[versionField] < right[versionField]
            end
            return left[nameField] < right[nameField]
        end)
        return { kind = options.kind, count = #items, items = items }, nil
    end

    function registry:cleanup(owner, epoch)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local owned = ownerKeys[owner]
        if not owned then return 0, {}, nil end
        local removed = {}
        for key in pairs(owned) do
            local record = records[key]
            if record and record.epoch == epoch then
                records[key] = nil
                owned[key] = nil
                size = size - 1
                removed[#removed + 1] = key
            end
        end
        if next(owned) == nil then ownerKeys[owner] = nil; ownerCount = ownerCount - 1 end
        table.sort(removed)
        return #removed, removed, nil
    end

    function registry:count() return size end
    return registry
end

local function createExecutableRegistry(kind, definitionFields, catalog, limits)
    if limits ~= nil and type(limits) ~= 'table' then
        error('compatibility executable registry limits are invalid')
    end
    local implementations = {}
    local registry = Catalogs.createRegistry({
        kind = kind,
        maximumEntries = limits and limits.maximumEntries,
        maximumEntriesPerOwner = limits and limits.maximumEntriesPerOwner,
        maximumOwners = limits and limits.maximumOwners,
        validate = function(definition)
            return validateExecutableDefinition(definition, definitionFields, catalog)
        end,
        validateUpdate = catalog and function(previous, candidate)
            if candidate.revision <= previous.revision then
                return nil, Foundation.error('COMPAT_VERSION_CONFLICT')
            end
            return true, nil
        end or nil,
    })
    local executable = {}

    function executable:register(owner, epoch, definition, implementation)
        local normalized, definitionError = validateExecutableDefinition(
            definition, definitionFields, catalog
        )
        if not normalized then return nil, definitionError end
        if type(implementation) ~= 'table' or getmetatable(implementation) ~= nil then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local expected = {}
        for _, operation in ipairs(normalized.operations) do expected[operation] = true end
        for operation, handler in pairs(implementation) do
            if not expected[operation] or not Foundation.isCallable(handler) then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
        end
        for operation in pairs(expected) do
            if not Foundation.isCallable(implementation[operation]) then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
        end
        local registered, registrationError, key = registry:register(owner, epoch, normalized)
        if not registered then return nil, registrationError end
        implementations[key] = implementation
        return registered, nil
    end

    function executable:resolve(name, major, operation, revision)
        if not Foundation.isIdentifier(operation) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local definition = registry:get(name, major)
        if catalog then
            if not Foundation.isSafeInteger(revision, 1, Foundation.MAX_SAFE_INTEGER) then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            if definition and definition.revision ~= revision then
                return nil, Foundation.error('COMPAT_VERSION_CONFLICT')
            end
        elseif revision ~= nil then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local implementation = definition and implementations[('%s@%d'):format(name, major)] or nil
        local handler = implementation and implementation[operation] or nil
        if not definition or not Foundation.isCallable(handler) then
            return nil, Foundation.error(catalog
                and 'COMPAT_CATALOG_UNAVAILABLE' or 'COMPAT_ADAPTER_MISSING')
        end
        return handler, definition
    end

    function executable:get(name, major) return registry:get(name, major) end
    function executable:list() return registry:list() end
    function executable:count() return registry:count() end
    function executable:cleanup(owner, epoch)
        local count, keys, cleanupError = registry:cleanup(owner, epoch)
        if count == nil then return nil, cleanupError end
        for _, key in ipairs(keys) do implementations[key] = nil end
        return count, nil
    end
    return executable
end

function Catalogs.createAdapters(limits)
    return createExecutableRegistry('adapters', ADAPTER_FIELDS, false, limits)
end

function Catalogs.createCatalogs(limits)
    return createExecutableRegistry('catalogs', CATALOG_FIELDS, true, limits)
end

function Catalogs.domainInterfaces()
    local result = {}
    for name in pairs(DOMAIN_INTERFACES) do result[#result + 1] = name end
    table.sort(result)
    return result
end

SynexBridgeKernel.Catalogs = Catalogs
