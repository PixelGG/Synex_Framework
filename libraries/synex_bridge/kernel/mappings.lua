assert(SynexBridgeKernel and SynexBridgeKernel.Foundation and SynexBridgeKernel.Catalogs,
    'synex_bridge foundation and catalogs must load before mappings')

local Foundation = SynexBridgeKernel.Foundation
local Catalogs = SynexBridgeKernel.Catalogs
local Mappings = {}

local FORBIDDEN_METADATA_FIELDS = {
    access_token = true, accounts = true, balances = true, bank = true, capabilities = true,
    cash = true, character_id = true, characterid = true, discord = true, fivem = true,
    groups = true, identifiers = true, inventory = true, ip = true, license = true,
    license2 = true, money = true, password = true, password_hash = true,
    permissions = true, refresh_token = true, roles = true, routingbucket = true,
    session_id = true, sessionid = true, source = true, source_generation = true,
    steam = true, token = true, tokens = true, user_id = true, userid = true,
}
local IDENTITY_FIELDS = {
    id = true, version = true, provider = true, entityKind = true,
    legacyId = true, nativeId = true, status = true,
}
local ACCOUNT_FIELDS = {
    id = true, version = true, provider = true, alias = true, currencyCode = true,
    accountKey = true, accountRole = true, minorUnit = true, status = true,
    fundingPolicy = true, sinkPolicy = true, legacyName = true, label = true,
    round = true,
}
local GROUP_FIELDS = {
    id = true, version = true, provider = true, legacyType = true,
    legacyName = true, nativeGroupKey = true, nativeGroupType = true,
    grades = true, bossRoles = true, dutySupported = true, dutyState = true,
    status = true,
}
local METADATA_FIELDS = {
    id = true, version = true, provider = true, key = true, valueType = true,
    minimum = true, maximum = true, maxLength = true, storageKey = true,
    status = true, sensitive = true,
}
local PERMISSION_FIELDS = {
    id = true, version = true, provider = true, legacyGroup = true,
    nativePermission = true, priority = true, fallback = true, status = true,
}
local POLICY_FIELDS = { kind = true, accountRef = true }
local GRADE_FIELDS = { legacyGrade = true, gradeKey = true }
local VALUE_TYPES = { boolean = true, integer = true, number = true, string = true }

local function boundedValue(value, minimum, maximum)
    return Foundation.isBoundedString(value, minimum, maximum)
        and not value:find('[%z\1-\31\127]')
end

local function lookupKey(prefix, ...)
    local parts = { prefix }
    for index = 1, select('#', ...) do
        local value = tostring(select(index, ...))
        parts[#parts + 1] = ('%d:%s'):format(#value, value)
    end
    return table.concat(parts, '|')
end

local function validateBase(definition, fields, required)
    local normalized, definitionError = Foundation.copyClosedObject(definition, fields, required, {
        root = 'object', maximumEntries = 256, maximumBytes = 32768,
        maximumArrayItems = 64, maximumObjectProperties = 32,
    })
    if not normalized then return nil, definitionError end
    if not Foundation.isDefinitionName(normalized.id)
        or not Foundation.semver(normalized.version)
        or not Foundation.isProvider(normalized.provider)
        or not Foundation.isStatus(normalized.status) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return normalized, nil
end

local function validateIdentity(definition)
    local normalized, definitionError = validateBase(definition, IDENTITY_FIELDS, {
        'id', 'version', 'provider', 'entityKind', 'legacyId', 'nativeId', 'status',
    })
    if not normalized then return nil, definitionError end
    if (normalized.entityKind ~= 'user' and normalized.entityKind ~= 'character')
        or not boundedValue(normalized.legacyId, 1, 128)
        or not boundedValue(normalized.nativeId, 1, 128) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return normalized, nil
end

local function validatePolicy(value, allowed)
    local policy, policyError = Foundation.copyClosedObject(value, POLICY_FIELDS, { 'kind' }, {
        root = 'object', maximumEntries = 8, maximumBytes = 2048,
        maximumStringBytes = 256, maximumKeyBytes = 64,
    })
    if not policy then return nil, policyError end
    if not allowed[policy.kind] then return nil, Foundation.error('COMPAT_INVALID_ARGUMENT') end
    if policy.kind == 'account' then
        if not boundedValue(policy.accountRef, 1, 128) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
    elseif policy.accountRef ~= nil then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return policy, nil
end

local function validateAccount(definition)
    local normalized, definitionError = validateBase(definition, ACCOUNT_FIELDS, {
        'id', 'version', 'provider', 'alias', 'currencyCode', 'accountKey',
        'accountRole', 'minorUnit', 'status', 'fundingPolicy', 'sinkPolicy',
    })
    if not normalized then return nil, definitionError end
    if not Foundation.isIdentifier(normalized.alias)
        or normalized.accountRole ~= 'asset'
        or not Foundation.isBoundedString(normalized.currencyCode, 2, 16,
            '^[a-z][a-z0-9_]+$')
        or not Foundation.isBoundedString(normalized.accountKey, 3, 31,
            '^[a-z][a-z0-9_]+$')
        or not Foundation.isSafeInteger(normalized.minorUnit, 0, 6) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    normalized.legacyName = normalized.legacyName or normalized.alias
    normalized.label = normalized.label or normalized.legacyName
    normalized.round = normalized.round ~= false
    if not Foundation.isIdentifier(normalized.legacyName)
        or not boundedValue(normalized.label, 1, 64)
        or type(normalized.round) ~= 'boolean' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local funding, fundingError = validatePolicy(normalized.fundingPolicy, {
        deny = true, account = true, mint = true,
    })
    if not funding then return nil, fundingError end
    local sink, sinkError = validatePolicy(normalized.sinkPolicy, {
        deny = true, account = true, burn = true,
    })
    if not sink then return nil, sinkError end
    normalized.fundingPolicy, normalized.sinkPolicy = funding, sink
    return normalized, nil
end

local function validateGroup(definition)
    local normalized, definitionError = validateBase(definition, GROUP_FIELDS, {
        'id', 'version', 'provider', 'legacyType', 'legacyName', 'nativeGroupKey',
        'nativeGroupType', 'grades', 'dutySupported', 'status',
    })
    if not normalized then return nil, definitionError end
    if not Foundation.isIdentifier(normalized.legacyType)
        or not Foundation.isIdentifier(normalized.legacyName)
        or not Foundation.isIdentifier(normalized.nativeGroupKey)
        or not Foundation.isIdentifier(normalized.nativeGroupType)
        or type(normalized.dutySupported) ~= 'boolean'
        or type(normalized.grades) ~= 'table' or #normalized.grades > 64 then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if normalized.dutySupported == true then
        if not Foundation.isBoundedString(normalized.dutyState, 2, 32,
            '^[a-z][a-z0-9_-]+$') then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
    elseif normalized.dutyState ~= nil then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    normalized.bossRoles = normalized.bossRoles or {}
    if type(normalized.bossRoles) ~= 'table' or #normalized.bossRoles > 32 then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local bossRoles = {}
    for index, roleKey in ipairs(normalized.bossRoles) do
        if not Foundation.isIdentifier(roleKey) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        if bossRoles[roleKey] then
            return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
        end
        bossRoles[roleKey] = true
        normalized.bossRoles[index] = roleKey
    end
    local seen, seenGradeKeys = {}, {}
    for index, value in ipairs(normalized.grades) do
        local grade, gradeError = Foundation.copyClosedObject(value, GRADE_FIELDS, {
            'legacyGrade', 'gradeKey',
        }, {
            root = 'object', maximumEntries = 8, maximumBytes = 1024,
            maximumStringBytes = 256, maximumKeyBytes = 64,
        })
        if not grade then return nil, gradeError end
        local legacyType = type(grade.legacyGrade)
        if not Foundation.isSafeInteger(grade.legacyGrade, 0, 65535)
            or not Foundation.isIdentifier(grade.gradeKey) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local legacyKey = legacyType .. ':' .. tostring(grade.legacyGrade)
        if seen[legacyKey] or seenGradeKeys[grade.gradeKey] then
            return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
        end
        seen[legacyKey] = true
        seenGradeKeys[grade.gradeKey] = true
        normalized.grades[index] = grade
    end
    return normalized, nil
end

local function validateMetadata(definition)
    local normalized, definitionError = validateBase(definition, METADATA_FIELDS, {
        'id', 'version', 'provider', 'key', 'valueType', 'storageKey',
        'status', 'sensitive',
    })
    if not normalized then return nil, definitionError end
    local lowered = type(normalized.key) == 'string' and normalized.key:lower() or ''
    if not Foundation.isIdentifier(normalized.key) or FORBIDDEN_METADATA_FIELDS[lowered] then
        return nil, Foundation.error(FORBIDDEN_METADATA_FIELDS[lowered]
            and 'COMPAT_METADATA_FORBIDDEN' or 'COMPAT_INVALID_ARGUMENT')
    end
    local storageKey = type(normalized.storageKey) == 'string'
        and normalized.storageKey:lower() or ''
    if not VALUE_TYPES[normalized.valueType]
        or not Foundation.isIdentifier(normalized.storageKey)
        or FORBIDDEN_METADATA_FIELDS[storageKey]
        or normalized.sensitive ~= false then
        return nil, Foundation.error(FORBIDDEN_METADATA_FIELDS[storageKey]
            and 'COMPAT_METADATA_FORBIDDEN' or 'COMPAT_INVALID_ARGUMENT')
    end
    if normalized.minimum ~= nil and (type(normalized.minimum) ~= 'number'
            or normalized.minimum ~= normalized.minimum
            or normalized.minimum == math.huge or normalized.minimum == -math.huge) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if normalized.maximum ~= nil and (type(normalized.maximum) ~= 'number'
            or normalized.maximum ~= normalized.maximum
            or normalized.maximum == math.huge or normalized.maximum == -math.huge) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if normalized.minimum ~= nil and normalized.maximum ~= nil
        and normalized.minimum > normalized.maximum then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if normalized.maxLength ~= nil
        and not Foundation.isSafeInteger(normalized.maxLength, 1, 4096) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return normalized, nil
end

local function validatePermission(definition)
    local normalized, definitionError = validateBase(definition, PERMISSION_FIELDS, {
        'id', 'version', 'provider', 'legacyGroup', 'nativePermission',
        'priority', 'fallback', 'status',
    })
    if not normalized then return nil, definitionError end
    if not Foundation.isIdentifier(normalized.legacyGroup)
        or not Foundation.isBoundedString(normalized.nativePermission, 1, 128,
            '^[a-z][a-z0-9%._%-]*$')
        or not Foundation.isSafeInteger(normalized.priority, 0, 65535)
        or type(normalized.fallback) ~= 'boolean' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return normalized, nil
end

local DOMAIN_DEFINITIONS = {
    identity = {
        validate = validateIdentity,
        indexes = function(value)
            return {
                lookupKey('legacy', value.provider, value.entityKind, value.legacyId),
                lookupKey('native', value.provider, value.entityKind, value.nativeId),
            }
        end,
    },
    accounts = {
        validate = validateAccount,
        indexes = function(value)
            return {
                lookupKey('alias', value.provider, value.alias),
                lookupKey('native', value.provider, value.currencyCode,
                    value.accountKey, value.accountRole, value.minorUnit),
            }
        end,
    },
    groups = {
        validate = validateGroup,
        indexes = function(value)
            local indexes = {
                lookupKey('legacy', value.provider, value.legacyType, value.legacyName),
            }
            -- Qbox collapses jobs and gangs into bare-name group maps. Reject
            -- cross-type name collisions instead of authorizing the wrong group.
            if value.provider == 'qbx' then
                indexes[#indexes + 1] = lookupKey(
                    'qbx_name', value.provider, value.legacyName)
            end
            return indexes
        end,
    },
    metadata = {
        validate = validateMetadata,
        indexes = function(value) return { lookupKey('key', value.provider, value.key) } end,
    },
    permissions = {
        validate = validatePermission,
        indexes = function(value)
            return { lookupKey('legacy', value.provider, value.legacyGroup) }
        end,
    },
}

local function createDomain(name, definition, limits)
    local index = {}
    local base = Catalogs.createRegistry({
        kind = 'mappings.' .. name,
        nameField = 'id',
        versionField = 'version',
        maximumEntries = limits and limits.maximumEntries,
        maximumEntriesPerOwner = limits and limits.maximumEntriesPerOwner,
        maximumOwners = limits and limits.maximumOwners,
        validate = definition.validate,
    })
    local domain = {}

    function domain:register(owner, epoch, value)
        local normalized, validationError = definition.validate(value)
        if not normalized then return nil, validationError end
        local version = Foundation.semver(normalized.version)
        local registryKey = ('%s@%d'):format(normalized.id, version.major)
        for _, lookupKey in ipairs(definition.indexes(normalized)) do
            local existing = index[lookupKey]
            if existing and existing.registryKey ~= registryKey then
                return nil, Foundation.error(name == 'identity'
                    and 'COMPAT_IDENTITY_CONFLICT' or 'COMPAT_MAPPING_AMBIGUOUS')
            end
        end
        local previous = base:get(normalized.id, version.major)
        local registered, registrationError = base:register(owner, epoch, normalized)
        if not registered then return nil, registrationError end
        if previous then
            for _, lookupKey in ipairs(definition.indexes(previous)) do
                if index[lookupKey] and index[lookupKey].registryKey == registryKey then
                    index[lookupKey] = nil
                end
            end
        end
        for _, lookupKey in ipairs(definition.indexes(registered)) do
            index[lookupKey] = { id = registered.id, major = version.major, registryKey = registryKey }
        end
        return registered, nil
    end

    function domain:get(id, major) return base:get(id, major) end
    function domain:list() return base:list() end
    function domain:resolve(lookupKey)
        if not boundedValue(lookupKey, 1, 512) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local reference = index[lookupKey]
        if not reference then
            return nil, Foundation.error(name == 'metadata'
                and 'COMPAT_METADATA_UNSUPPORTED' or 'COMPAT_MAPPING_MISSING')
        end
        return base:get(reference.id, reference.major)
    end
    function domain:cleanup(owner, epoch)
        local count, removed, cleanupError = base:cleanup(owner, epoch)
        if count == nil then return nil, cleanupError end
        local removedSet = {}
        for _, key in ipairs(removed) do removedSet[key] = true end
        for lookupKey, reference in pairs(index) do
            if removedSet[reference.registryKey] then index[lookupKey] = nil end
        end
        return count, nil
    end
    function domain:count() return base:count() end
    return domain
end

function Mappings.create(options)
    if options ~= nil and type(options) ~= 'table' then
        error('compatibility mapping options are invalid')
    end
    local limits = options and options.limits or nil
    if limits ~= nil and type(limits) ~= 'table' then
        error('compatibility mapping limits are invalid')
    end
    local registry = {
        identity = createDomain('identity', DOMAIN_DEFINITIONS.identity, limits),
        accounts = createDomain('accounts', DOMAIN_DEFINITIONS.accounts, limits),
        groups = createDomain('groups', DOMAIN_DEFINITIONS.groups, limits),
        metadata = createDomain('metadata', DOMAIN_DEFINITIONS.metadata, limits),
        permissions = createDomain('permissions', DOMAIN_DEFINITIONS.permissions, limits),
    }
    function registry:isMetadataForbidden(key)
        return type(key) == 'string' and FORBIDDEN_METADATA_FIELDS[key:lower()] == true
    end
    function registry:forbiddenMetadataFields()
        local fields = {}
        for field in pairs(FORBIDDEN_METADATA_FIELDS) do fields[#fields + 1] = field end
        table.sort(fields)
        return fields
    end
    function registry:resolveIdentity(provider, entityKind, direction, value)
        if not Foundation.isProvider(provider)
            or (entityKind ~= 'user' and entityKind ~= 'character')
            or (direction ~= 'legacy' and direction ~= 'native')
            or not boundedValue(value, 1, 128) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        return registry.identity:resolve(lookupKey(direction, provider, entityKind, value))
    end
    function registry:resolveAccount(provider, alias)
        if not Foundation.isProvider(provider) or not Foundation.isIdentifier(alias) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        return registry.accounts:resolve(lookupKey('alias', provider, alias))
    end
    function registry:resolveGroup(provider, legacyType, legacyName)
        if not Foundation.isProvider(provider) or not Foundation.isIdentifier(legacyType)
            or not Foundation.isIdentifier(legacyName) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        return registry.groups:resolve(lookupKey('legacy', provider, legacyType, legacyName))
    end
    function registry:resolveMetadata(provider, key)
        if not Foundation.isProvider(provider) or not Foundation.isIdentifier(key) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        if registry:isMetadataForbidden(key) then
            return nil, Foundation.error('COMPAT_METADATA_FORBIDDEN')
        end
        return registry.metadata:resolve(lookupKey('key', provider, key))
    end
    function registry:resolvePermission(provider, legacyGroup)
        if not Foundation.isProvider(provider)
            or not Foundation.isIdentifier(legacyGroup) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        return registry.permissions:resolve(
            lookupKey('legacy', provider, legacyGroup))
    end
    function registry:cleanup(owner, epoch)
        local total = 0
        for _, name in ipairs({
            'identity', 'accounts', 'groups', 'metadata', 'permissions',
        }) do
            local count, cleanupError = registry[name]:cleanup(owner, epoch)
            if count == nil then return nil, cleanupError end
            total = total + count
        end
        return total, nil
    end
    return registry
end

SynexBridgeKernel.Mappings = Mappings
