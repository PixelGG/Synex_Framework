assert(SynexBridgeKernel and SynexBridgeKernel.Foundation,
    'synex_bridge foundation must load before resolver')

local Foundation = SynexBridgeKernel.Foundation
local Resolver = {}

local CONFIG_FIELDS = {
    defaultMode = true, providers = true, profiles = true,
    surfaces = true, consumers = true,
}
local PROFILE_FIELDS = {
    id = true, version = true, provider = true, mode = true, status = true,
    failurePolicy = true, requiredSurfaces = true, requiredAdapters = true,
    requiredCatalogs = true,
    script = true, evidence = true, certificationVerified = true,
    providerVersion = true, targetFrameworkApiRange = true,
    certificationArtifact = true,
    vendor = true, upstream = true, requiredDomains = true,
    requiredExports = true, requiredEvents = true, directSql = true,
    knownLimitations = true, testedFlows = true,
}
local SCRIPT_FIELDS = { name = true, testedVersion = true }
local EVIDENCE_FIELDS = { tests = true, sourceUrls = true }
local UPSTREAM_FIELDS = { repository = true, revision = true }
local EXPORT_FIELDS = { resource = true, name = true, side = true }
local EVENT_FIELDS = { name = true, direction = true }
local DIRECT_SQL_FIELDS = { table = true, mode = true }
local TESTED_FLOW_FIELDS = {
    name = true, status = true, environmentRequirements = true,
}
local REQUIRED_SURFACE_FIELDS = { name = true, acceptedStatuses = true }
local REQUIRED_ADAPTER_FIELDS = { name = true, versionRange = true }
local REQUIRED_CATALOG_FIELDS = {
    name = true, versionRange = true, domain = true, revision = true,
}
local SURFACE_FIELDS = {
    name = true, provider = true, status = true, modes = true, deprecated = true,
    requiredCapability = true, requiredAdapter = true, adapterOperations = true,
    requiredCatalog = true, catalogOperations = true,
}
local ADAPTER_OPERATION_FIELDS = { name = true, nativeCapabilities = true }
local CATALOG_OPERATION_FIELDS = { name = true, nativeCapabilities = true }
local CATALOG_DOMAINS = {
    identity = true, accounts = true, groups = true, metadata = true,
    inventory = true, vehicles = true, interaction = true,
    notifications = true, ui = true, banking = true, provider = true,
}
local CONSUMER_FIELDS = {
    resource = true, provider = true, mode = true, profileId = true,
    failurePolicy = true, enabled = true,
}

local function validateArray(value, maximum)
    if type(value) ~= 'table' or #value > maximum then return false end
    for key in pairs(value) do
        if not Foundation.isSafeInteger(key, 1, #value) then return false end
    end
    return true
end

local function validateStatusArray(value)
    if not validateArray(value, 5) or #value < 1 then return false end
    local seen = {}
    for _, status in ipairs(value) do
        if not Foundation.isStatus(status) or seen[status] then return false end
        seen[status] = true
    end
    return true
end

local function validateModeArray(value)
    if not validateArray(value, 3) or #value < 1 then return false end
    local seen = {}
    for _, mode in ipairs(value) do
        if not Foundation.isMode(mode) or seen[mode] then return false end
        seen[mode] = true
    end
    return true
end

local function validateEvidenceArray(value, maximum, validator)
    if not validateArray(value, maximum) or #value < 1 then return false end
    local seen = {}
    for _, item in ipairs(value) do
        if not validator(item) or seen[item] then return false end
        seen[item] = true
    end
    return true
end

local function validateOptionalStringArray(value, maximum, validator)
    if value == nil then return {}, true end
    if not validateArray(value, maximum) then return nil, false end
    local normalized, seen = {}, {}
    for index, item in ipairs(value) do
        if not validator(item) or seen[item] then return nil, false end
        seen[item] = true
        normalized[index] = item
    end
    return normalized, true
end

local function validEvidenceTest(value)
    if not Foundation.isBoundedString(value, 1, 256,
        '^[A-Za-z0-9][A-Za-z0-9_./%-]*$')
        or value:find('//', 1, true) then return false end
    for segment in value:gmatch('[^/]+') do
        if segment == '.' or segment == '..' then return false end
    end
    return true
end

local function validEvidenceUrl(value)
    return Foundation.isBoundedString(value, 12, 512, '^https://[^%s]+$')
end

local function validateProfile(value)
    local profile, profileError = Foundation.copyClosedObject(value, PROFILE_FIELDS, {
        'id', 'version', 'script', 'provider', 'mode', 'status', 'failurePolicy',
        'providerVersion', 'targetFrameworkApiRange', 'requiredSurfaces',
        'requiredAdapters', 'evidence',
    }, { root = 'object', maximumEntries = 256, maximumBytes = 32768 })
    if not profile then return nil, profileError end
    profile.requiredCatalogs = profile.requiredCatalogs or {}
    profile.requiredDomains = profile.requiredDomains or {}
    profile.requiredExports = profile.requiredExports or {}
    profile.requiredEvents = profile.requiredEvents or {}
    profile.directSql = profile.directSql or {}
    profile.knownLimitations = profile.knownLimitations or {}
    profile.testedFlows = profile.testedFlows or {}
    if not Foundation.isDefinitionName(profile.id) or not Foundation.semver(profile.version)
        or not Foundation.isProvider(profile.provider) or not Foundation.isStatus(profile.status)
        or not Foundation.isFailurePolicy(profile.failurePolicy)
        or not Foundation.isMode(profile.mode)
        or not Foundation.isSemver(profile.providerVersion)
        or (profile.targetFrameworkApiRange ~= nil
            and not Foundation.isSemverRange(profile.targetFrameworkApiRange))
        or not validateArray(profile.requiredSurfaces, 128)
        or not validateArray(profile.requiredAdapters, 32)
        or not validateArray(profile.requiredCatalogs, 32)
        or (profile.certificationVerified ~= nil
            and type(profile.certificationVerified) ~= 'boolean')
        or (profile.certificationArtifact ~= nil
            and (not validEvidenceTest(profile.certificationArtifact)
                or not profile.certificationArtifact:match(
                    '^compatibility/certifications/[a-z][a-z0-9_.%-]*%.json$'))) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if profile.vendor ~= nil and not Foundation.isBoundedString(
        profile.vendor, 1, 96) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if profile.upstream ~= nil then
        local upstream, upstreamError = Foundation.copyClosedObject(
            profile.upstream, UPSTREAM_FIELDS, { 'repository', 'revision' }, {
                root = 'object', maximumEntries = 4, maximumBytes = 1024,
                maximumStringBytes = 512, maximumKeyBytes = 32,
            })
        if not upstream
            or not Foundation.isBoundedString(
                upstream.repository, 12, 512, '^https://[^%s]+$')
            or not Foundation.isBoundedString(
                upstream.revision, 40, 40, '^[0-9a-f]+$') then
            return nil, upstreamError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        profile.upstream = upstream
    elseif profile.targetFrameworkApiRange == nil then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local script, scriptError = Foundation.copyClosedObject(
        profile.script, SCRIPT_FIELDS, { 'name' }, {
            root = 'object', maximumEntries = 8, maximumBytes = 1024,
            maximumStringBytes = 128, maximumKeyBytes = 64,
        })
    local evidence, evidenceError = Foundation.copyClosedObject(
        profile.evidence, EVIDENCE_FIELDS, { 'tests', 'sourceUrls' }, {
            root = 'object', maximumEntries = 64, maximumBytes = 16384,
            maximumStringBytes = 512, maximumArrayItems = 32,
            maximumKeyBytes = 64,
        })
    if not script or not evidence
        or not Foundation.isBoundedString(script.name, 1, 96,
            '^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
        or (script.testedVersion ~= nil
            and not Foundation.isSemver(script.testedVersion))
        or not validateEvidenceArray(evidence.tests, 32, validEvidenceTest)
        or not validateEvidenceArray(evidence.sourceUrls, 16, validEvidenceUrl) then
        return nil, scriptError or evidenceError
            or Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    profile.script, profile.evidence = script, evidence
    local domains, domainsValid = validateOptionalStringArray(
        profile.requiredDomains, 16, function(value)
            return type(value) == 'string' and CATALOG_DOMAINS[value] == true
        end)
    local limitations, limitationsValid = validateOptionalStringArray(
        profile.knownLimitations, 64, function(value)
            return Foundation.isBoundedString(value, 1, 256)
        end)
    if not domainsValid or not limitationsValid then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    profile.requiredDomains, profile.knownLimitations = domains, limitations
    local seenProfileRequirements = {}
    for index, candidate in ipairs(profile.requiredExports) do
        local requirement, requirementError = Foundation.copyClosedObject(
            candidate, EXPORT_FIELDS, { 'resource', 'name', 'side' }, {
                root = 'object', maximumEntries = 8, maximumBytes = 1024,
                maximumStringBytes = 128, maximumKeyBytes = 32,
            })
        local key = requirement and table.concat({
            tostring(requirement.side), tostring(requirement.resource),
            tostring(requirement.name),
        }, ':') or ''
        if not requirement or not Foundation.isResourceName(requirement.resource)
            or not Foundation.isBoundedString(requirement.name, 1, 96,
                '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            or (requirement.side ~= 'client' and requirement.side ~= 'server'
                and requirement.side ~= 'shared')
            or seenProfileRequirements[key] then
            return nil, requirementError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        seenProfileRequirements[key] = true
        profile.requiredExports[index] = requirement
    end
    seenProfileRequirements = {}
    for index, candidate in ipairs(profile.requiredEvents) do
        local requirement, requirementError = Foundation.copyClosedObject(
            candidate, EVENT_FIELDS, { 'name', 'direction' }, {
                root = 'object', maximumEntries = 6, maximumBytes = 1024,
                maximumStringBytes = 128, maximumKeyBytes = 32,
            })
        local key = requirement and requirement.direction .. ':' .. requirement.name or ''
        local direction = requirement and requirement.direction or nil
        if not requirement or not Foundation.isBoundedString(
            requirement.name, 1, 128, '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            or (direction ~= 'client_to_server' and direction ~= 'server_to_client'
                and direction ~= 'local_client' and direction ~= 'local_server')
            or seenProfileRequirements[key] then
            return nil, requirementError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        seenProfileRequirements[key] = true
        profile.requiredEvents[index] = requirement
    end
    seenProfileRequirements = {}
    for index, candidate in ipairs(profile.directSql) do
        local assumption, assumptionError = Foundation.copyClosedObject(
            candidate, DIRECT_SQL_FIELDS, { 'table', 'mode' }, {
                root = 'object', maximumEntries = 4, maximumBytes = 512,
                maximumStringBytes = 64, maximumKeyBytes = 16,
            })
        local key = assumption and assumption.mode .. ':' .. assumption.table or ''
        if not assumption or not Foundation.isBoundedString(
            assumption.table, 1, 64, '^[A-Za-z0-9_]+$')
            or (assumption.mode ~= 'read' and assumption.mode ~= 'write'
                and assumption.mode ~= 'read_write')
            or seenProfileRequirements[key] then
            return nil, assumptionError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        seenProfileRequirements[key] = true
        profile.directSql[index] = assumption
    end
    seenProfileRequirements = {}
    for index, candidate in ipairs(profile.testedFlows) do
        local flow, flowError = Foundation.copyClosedObject(
            candidate, TESTED_FLOW_FIELDS,
            { 'name', 'status', 'environmentRequirements' }, {
                root = 'object', maximumEntries = 40, maximumBytes = 8192,
                maximumStringBytes = 256, maximumArrayItems = 32,
                maximumKeyBytes = 32,
            })
        local requirements, requirementsValid
        if flow then
            requirements, requirementsValid = validateOptionalStringArray(
                flow.environmentRequirements, 32, function(value)
                    return Foundation.isBoundedString(value, 1, 128)
                end)
        end
        if not flow or not Foundation.isDefinitionName(flow.name)
            or (flow.status ~= 'PASS' and flow.status ~= 'FAIL'
                and flow.status ~= 'NOT_TESTED')
            or not requirementsValid or seenProfileRequirements[flow.name] then
            return nil, flowError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        seenProfileRequirements[flow.name] = true
        flow.environmentRequirements = requirements
        profile.testedFlows[index] = flow
    end
    local names = {}
    for index, candidate in ipairs(profile.requiredSurfaces) do
        local requirement, requirementError = Foundation.copyClosedObject(
            candidate, REQUIRED_SURFACE_FIELDS, { 'name', 'acceptedStatuses' },
            { root = 'object', maximumEntries = 16, maximumBytes = 2048,
                maximumStringBytes = 256, maximumKeyBytes = 64 }
        )
        if not requirement or not Foundation.isDefinitionName(requirement.name)
            or not validateStatusArray(requirement.acceptedStatuses) or names[requirement.name] then
            return nil, requirementError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        names[requirement.name] = true
        profile.requiredSurfaces[index] = requirement
    end
    names = {}
    for index, candidate in ipairs(profile.requiredAdapters) do
        local requirement, requirementError = Foundation.copyClosedObject(
            candidate, REQUIRED_ADAPTER_FIELDS, { 'name' },
            { root = 'object', maximumEntries = 8, maximumBytes = 1024,
                maximumStringBytes = 256, maximumKeyBytes = 64 }
        )
        if not requirement or not Foundation.isDefinitionName(requirement.name)
            or (requirement.versionRange ~= nil
                and not Foundation.isSemverRange(requirement.versionRange))
            or names[requirement.name] then
            return nil, requirementError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        names[requirement.name] = true
        profile.requiredAdapters[index] = requirement
    end
    names = {}
    for index, candidate in ipairs(profile.requiredCatalogs) do
        local requirement, requirementError = Foundation.copyClosedObject(
            candidate, REQUIRED_CATALOG_FIELDS, { 'name', 'domain', 'revision' },
            { root = 'object', maximumEntries = 12, maximumBytes = 1536,
                maximumStringBytes = 256, maximumKeyBytes = 64 }
        )
        if not requirement or not Foundation.isDefinitionName(requirement.name)
            or not Foundation.isIdentifier(requirement.domain)
            or CATALOG_DOMAINS[requirement.domain] ~= true
            or not Foundation.isSafeInteger(
                requirement.revision, 1, Foundation.MAX_SAFE_INTEGER)
            or (requirement.versionRange ~= nil
                and not Foundation.isSemverRange(requirement.versionRange))
            or names[requirement.name] then
            return nil, requirementError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        names[requirement.name] = true
        profile.requiredCatalogs[index] = requirement
    end
    if profile.status == 'CERTIFIED' and (script.testedVersion == nil
        or profile.certificationVerified ~= true
        or profile.certificationArtifact == nil) then
        profile.status = 'UNKNOWN'
    end
    profile.certificationVerified = nil
    return profile, nil
end

local function validateSurface(value)
    local surface, surfaceError = Foundation.copyClosedObject(value, SURFACE_FIELDS, {
        'name', 'provider', 'status', 'modes', 'deprecated', 'adapterOperations',
    }, { root = 'object', maximumEntries = 128, maximumBytes = 16384 })
    if not surface then return nil, surfaceError end
    surface.catalogOperations = surface.catalogOperations or {}
    if not Foundation.isDefinitionName(surface.name) or not Foundation.isProvider(surface.provider)
        or not Foundation.isStatus(surface.status) or not validateModeArray(surface.modes)
        or type(surface.deprecated) ~= 'boolean' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if surface.requiredAdapter ~= nil and surface.requiredCatalog ~= nil then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if not validateArray(surface.adapterOperations, 32) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if surface.requiredAdapter ~= nil then
        if not Foundation.isDefinitionName(surface.requiredAdapter)
            or not Foundation.isIdentifier(surface.requiredCapability)
            or #surface.adapterOperations < 1 then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
    elseif surface.requiredCapability ~= nil and not Foundation.isIdentifier(
        surface.requiredCapability) or #surface.adapterOperations > 0 then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local operations = {}
    for index, candidate in ipairs(surface.adapterOperations) do
        local operation, operationError = Foundation.copyClosedObject(
            candidate, ADAPTER_OPERATION_FIELDS, { 'name', 'nativeCapabilities' }, {
                root = 'object', maximumEntries = 32, maximumBytes = 4096,
                maximumStringBytes = 256, maximumArrayItems = 16,
                maximumObjectProperties = 4, maximumKeyBytes = 64,
            })
        if not operation or not Foundation.isIdentifier(operation.name)
            or not validateArray(operation.nativeCapabilities, 16)
            or #operation.nativeCapabilities < 1 or operations[operation.name] then
            return nil, operationError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local capabilities = {}
        for _, capability in ipairs(operation.nativeCapabilities) do
            if not Foundation.isIdentifier(capability) or capabilities[capability] then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            capabilities[capability] = true
        end
        operations[operation.name] = operation
        surface.adapterOperations[index] = operation
    end
    if not validateArray(surface.catalogOperations, 32) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    if surface.requiredCatalog ~= nil then
        if not Foundation.isDefinitionName(surface.requiredCatalog)
            or not Foundation.isIdentifier(surface.requiredCapability)
            or #surface.catalogOperations < 1 then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
    elseif #surface.catalogOperations > 0 then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    operations = {}
    for index, candidate in ipairs(surface.catalogOperations) do
        local operation, operationError = Foundation.copyClosedObject(
            candidate, CATALOG_OPERATION_FIELDS, { 'name', 'nativeCapabilities' }, {
                root = 'object', maximumEntries = 32, maximumBytes = 4096,
                maximumStringBytes = 256, maximumArrayItems = 16,
                maximumObjectProperties = 4, maximumKeyBytes = 64,
            })
        if not operation or not Foundation.isIdentifier(operation.name)
            or not validateArray(operation.nativeCapabilities, 16)
            or #operation.nativeCapabilities < 1 or operations[operation.name] then
            return nil, operationError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local capabilities = {}
        for _, capability in ipairs(operation.nativeCapabilities) do
            if not Foundation.isIdentifier(capability) or capabilities[capability] then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            capabilities[capability] = true
        end
        operations[operation.name] = operation
        surface.catalogOperations[index] = operation
    end
    return surface, nil
end

local function validateConsumer(value)
    local consumer, consumerError = Foundation.copyClosedObject(value, CONSUMER_FIELDS, {
        'resource', 'provider', 'profileId', 'failurePolicy', 'enabled',
    }, { root = 'object', maximumEntries = 32, maximumBytes = 4096,
        maximumStringBytes = 512, maximumKeyBytes = 64 })
    if not consumer then return nil, consumerError end
    if not Foundation.isResourceName(consumer.resource) or not Foundation.isProvider(consumer.provider)
        or not Foundation.isDefinitionName(consumer.profileId)
        or not Foundation.isFailurePolicy(consumer.failurePolicy)
        or (consumer.mode ~= nil and not Foundation.isMode(consumer.mode))
        or type(consumer.enabled) ~= 'boolean' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    return consumer, nil
end

local function contains(values, expected)
    for _, value in ipairs(values) do if value == expected then return true end end
    return false
end

local function statusAllowed(mode, status)
    if status == 'UNSUPPORTED' or status == 'UNKNOWN' then return false end
    if mode == 'strict' then return status == 'CERTIFIED' or status == 'COMPATIBLE' end
    return status == 'CERTIFIED' or status == 'COMPATIBLE' or status == 'PARTIAL'
end

function Resolver.create(options)
    if type(options) ~= 'table' or options.adapters == nil or options.catalogs == nil
        or (options.telemetry ~= nil and type(options.telemetry) ~= 'table') then
        error('compatibility resolver options are invalid')
    end
    local adapters, catalogs, telemetry = options.adapters, options.catalogs, options.telemetry
    local maximumConfigurations = options.maximumConfigurations or 16
    local maximumConsumers = options.maximumConsumers or 256
    if not Foundation.isSafeInteger(maximumConfigurations, 1, 128)
        or not Foundation.isSafeInteger(maximumConsumers, 1, 2048) then
        error('compatibility resolver limits are invalid')
    end
    local configurations, consumers, disabled = {}, {}, {}
    local configurationCount, consumerCount = 0, 0
    local resolver = {}

    local function fail(consumer, compatError)
        local policy = consumer and consumer.failurePolicy or 'fail_start'
        local mode = consumer and consumer.mode or 'strict'
        if policy == 'disable' and consumer then disabled[consumer.resource] = consumer.epoch end
        if policy == 'warn' and consumer and mode ~= 'silent' and telemetry then
            local warningKey = 'compat.' .. compatError.code:lower():gsub('_', '.')
            telemetry:warnOnce(consumer.resource, consumer.epoch,
                warningKey, compatError.code, {
                    provider = consumer.provider, profileId = consumer.profileId,
                })
        end
        return nil, compatError, policy
    end

    function resolver:configure(owner, epoch, config)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local copied, configError = Foundation.copyClosedObject(config, CONFIG_FIELDS, {
            'providers', 'profiles', 'surfaces', 'consumers',
        }, { root = 'object', maximumEntries = 2048, maximumBytes = 262144,
            maximumStringBytes = 4096, maximumArrayItems = 1024,
            maximumObjectProperties = 32 })
        if not copied then return nil, configError end
        copied.defaultMode = copied.defaultMode or 'strict'
        if not Foundation.isMode(copied.defaultMode) or type(copied.providers) ~= 'table'
            or not validateArray(copied.profiles, 128) or not validateArray(copied.surfaces, 512)
            or not validateArray(copied.consumers, maximumConsumers) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local providers = {}
        for provider, enabled in pairs(copied.providers) do
            if not Foundation.isProvider(provider) or type(enabled) ~= 'boolean' then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            providers[provider] = enabled
        end
        local profiles, surfaces, incomingConsumers = {}, {}, {}
        for _, value in ipairs(copied.profiles) do
            local profile, profileError = validateProfile(value)
            if not profile then return nil, profileError end
            if profiles[profile.id] then return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS') end
            profiles[profile.id] = profile
        end
        for _, value in ipairs(copied.surfaces) do
            local surface, surfaceError = validateSurface(value)
            if not surface then return nil, surfaceError end
            local key = surface.provider .. ':' .. surface.name
            if surfaces[key] then return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS') end
            surfaces[key] = surface
        end
        for _, value in ipairs(copied.consumers) do
            local consumer, consumerError = validateConsumer(value)
            if not consumer then return nil, consumerError end
            consumer.mode = consumer.mode or copied.defaultMode
            consumer.epoch, consumer.owner = epoch, owner
            if incomingConsumers[consumer.resource]
                or (consumers[consumer.resource] and consumers[consumer.resource].owner ~= owner) then
                return nil, Foundation.error('COMPAT_OWNER_CONFLICT')
            end
            incomingConsumers[consumer.resource] = consumer
        end
        local previous = configurations[owner]
        if previous and epoch < previous.epoch then
            return nil, Foundation.error('COMPAT_VERSION_CONFLICT')
        end
        local replacedCount = previous and previous.consumerCount or 0
        local incomingCount = 0
        for _ in pairs(incomingConsumers) do incomingCount = incomingCount + 1 end
        if consumerCount - replacedCount + incomingCount > maximumConsumers then
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        if not previous and configurationCount >= maximumConfigurations then
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        if previous then
            for resource in pairs(previous.consumers) do
                consumers[resource], disabled[resource] = nil, nil
            end
        else
            configurationCount = configurationCount + 1
        end
        local state = {
            owner = owner, epoch = epoch, providers = providers, profiles = profiles,
            surfaces = surfaces, consumers = incomingConsumers, consumerCount = incomingCount,
        }
        configurations[owner] = state
        consumerCount = consumerCount - replacedCount + incomingCount
        for resource, consumer in pairs(incomingConsumers) do consumers[resource] = consumer end
        return { owner = owner, epoch = epoch, consumers = incomingCount }, nil
    end

    function resolver:resolve(resource, surfaceName, operation)
        if not Foundation.isResourceName(resource) or not Foundation.isDefinitionName(surfaceName)
            or not Foundation.isIdentifier(operation) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT'), 'fail_start'
        end
        local consumer = consumers[resource]
        if not consumer then return fail(nil, Foundation.error('COMPAT_CONSUMER_DENIED')) end
        if disabled[resource] == consumer.epoch or not consumer.enabled then
            return fail(consumer, Foundation.error('COMPAT_PROVIDER_DISABLED'))
        end
        local state = configurations[consumer.owner]
        if not state or state.epoch ~= consumer.epoch then
            return fail(consumer, Foundation.error('COMPAT_STALE_SESSION'))
        end
        if state.providers[consumer.provider] ~= true then
            return fail(consumer, Foundation.error('COMPAT_PROVIDER_DISABLED'))
        end
        local profile = state.profiles[consumer.profileId]
        if not profile or profile.provider ~= consumer.provider
            or (profile.mode ~= nil and profile.mode ~= consumer.mode)
            or not statusAllowed(consumer.mode, profile.status) then
            return fail(consumer, Foundation.error('COMPAT_PROFILE_INCOMPLETE'))
        end
        local adapterListing = adapters:list()
        local selectedAdapters = {}
        for _, adapterRequirement in ipairs(profile.requiredAdapters) do
            local selected
            for _, adapter in ipairs(adapterListing.items) do
                if adapter.name == adapterRequirement.name
                    and (adapter.provider == consumer.provider or adapter.provider == 'all')
                    and adapter.status ~= 'UNSUPPORTED' and adapter.status ~= 'UNKNOWN'
                    and Foundation.semverSatisfies(
                        adapter.version, adapterRequirement.versionRange)
                    and (not selected
                        or Foundation.compareSemver(adapter.version, selected.version) > 0) then
                    selected = adapter
                end
            end
            if not selected then
                return fail(consumer, Foundation.error('COMPAT_ADAPTER_MISSING'))
            end
            selectedAdapters[adapterRequirement.name] = selected
        end
        local catalogListing = catalogs:list()
        local selectedCatalogs = {}
        for _, catalogRequirement in ipairs(profile.requiredCatalogs) do
            local selected, staleRevision
            for _, catalog in ipairs(catalogListing.items) do
                if catalog.name == catalogRequirement.name
                    and catalog.domain == catalogRequirement.domain
                    and (catalog.provider == consumer.provider or catalog.provider == 'all')
                    and statusAllowed(consumer.mode, catalog.status)
                    and Foundation.semverSatisfies(
                        catalog.version, catalogRequirement.versionRange) then
                    if catalog.revision == catalogRequirement.revision
                        and (not selected or Foundation.compareSemver(
                            catalog.version, selected.version) > 0) then
                        selected = catalog
                    elseif catalog.revision ~= catalogRequirement.revision then
                        staleRevision = true
                    end
                end
            end
            if not selected then
                return fail(consumer, Foundation.error(staleRevision
                    and 'COMPAT_VERSION_CONFLICT' or 'COMPAT_CATALOG_UNAVAILABLE'))
            end
            selectedCatalogs[catalogRequirement.name] = selected
        end
        local requirement
        for _, candidate in ipairs(profile.requiredSurfaces) do
            if candidate.name == surfaceName then requirement = candidate; break end
        end
        local surface = state.surfaces[consumer.provider .. ':' .. surfaceName]
        if not requirement or not surface or not contains(requirement.acceptedStatuses, surface.status)
            or not contains(surface.modes, consumer.mode)
            or not statusAllowed(consumer.mode, surface.status) then
            return fail(consumer, Foundation.error('COMPAT_API_UNSUPPORTED'))
        end
        local handler, adapterDefinition, adapterOperation = nil, nil, nil
        if surface.requiredAdapter then
            local selected = selectedAdapters[surface.requiredAdapter]
            if not selected then
                return fail(consumer, Foundation.error('COMPAT_PROFILE_INCOMPLETE'))
            end
            for _, candidate in ipairs(surface.adapterOperations) do
                if candidate.name == operation then adapterOperation = candidate; break end
            end
            if not adapterOperation then
                return fail(consumer, Foundation.error('COMPAT_API_UNSUPPORTED'))
            end
            handler, adapterDefinition = adapters:resolve(
                surface.requiredAdapter,
                assert(Foundation.semver(selected.version)).major,
                operation
            )
            if not handler or adapterDefinition.version ~= selected.version then
                return fail(consumer, Foundation.error('COMPAT_ADAPTER_MISSING'))
            end
        end
        local catalogHandler, catalogDefinition, catalogOperation = nil, nil, nil
        if surface.requiredCatalog then
            local selected = selectedCatalogs[surface.requiredCatalog]
            if not selected then
                return fail(consumer, Foundation.error('COMPAT_PROFILE_INCOMPLETE'))
            end
            for _, candidate in ipairs(surface.catalogOperations) do
                if candidate.name == operation then catalogOperation = candidate; break end
            end
            if not catalogOperation then
                return fail(consumer, Foundation.error('COMPAT_API_UNSUPPORTED'))
            end
            local catalogError
            catalogHandler, catalogDefinition, catalogError = catalogs:resolve(
                surface.requiredCatalog,
                assert(Foundation.semver(selected.version)).major,
                operation,
                selected.revision
            )
            if not catalogHandler or catalogDefinition.version ~= selected.version then
                return fail(consumer, catalogError
                    or Foundation.error('COMPAT_CATALOG_UNAVAILABLE'))
            end
        end
        if surface.deprecated then
            if consumer.mode == 'strict' then
                return fail(consumer, Foundation.error('COMPAT_API_DEPRECATED'))
            end
            if consumer.mode ~= 'silent' and telemetry then
                telemetry:warnOnce(resource, consumer.epoch, 'compat.api_deprecated',
                    'COMPAT_API_DEPRECATED', { surface = surface.name })
            end
        end
        return {
            consumer = resource, provider = consumer.provider, mode = consumer.mode,
            profileId = profile.id, profileVersion = profile.version,
            profileStatus = profile.status, script = Foundation.copyDto(profile.script),
            providerVersion = profile.providerVersion,
            targetFrameworkApiRange = profile.targetFrameworkApiRange,
            surface = Foundation.copyDto(surface), adapter = adapterDefinition,
            adapterOperation = Foundation.copyDto(adapterOperation), handler = handler,
            catalog = catalogDefinition,
            catalogOperation = Foundation.copyDto(catalogOperation),
            catalogHandler = catalogHandler,
        }, nil, nil
    end

    function resolver:cleanup(owner, epoch)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local state = configurations[owner]
        if not state or state.epoch ~= epoch then return 0, nil end
        local removed = 0
        for resource in pairs(state.consumers) do
            consumers[resource], disabled[resource] = nil, nil
            removed = removed + 1
        end
        configurations[owner] = nil
        configurationCount, consumerCount = configurationCount - 1, consumerCount - removed
        return removed, nil
    end

    function resolver:configuredConsumers() return consumerCount end
    return resolver
end

SynexBridgeKernel.Resolver = Resolver
