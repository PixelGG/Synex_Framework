assert(SynexBridgeKernel and SynexBridgeKernel.Runtime,
    'synex_bridge kernel runtime must load before the server coordinator')
assert(SynexBridgeKernel.Certification,
    'synex_bridge certification verifier must load before the server coordinator')
assert(SynexBridgeIdentityStore,
    'synex_bridge identity store must load before the server coordinator')

local Foundation = SynexBridgeKernel.Foundation
local RESOURCE = GetCurrentResourceName()
local CONFIG_OWNER = RESOURCE
local CONFIG_EPOCH = 1
local CORE_API_RANGE = '^1.0.0'

local PROVIDER_BY_RESOURCE = {
    synex_bridge_qb = 'qb',
    synex_bridge_qbx = 'qbx',
    synex_bridge_esx = 'esx',
}
local RESOURCE_BY_PROVIDER = {
    qb = 'synex_bridge_qb',
    qbx = 'synex_bridge_qbx',
    esx = 'synex_bridge_esx',
}
local OPERATION_SURFACES = {
    qb = {
        ['core_object.read'] = 'qb.server.core_object',
        ['core_object.filter'] = 'qb.server.core_object_filtering',
        ['player.read'] = 'qb.server.player_lookup',
        ['player.lookup_identifier'] = 'qb.server.identifier_player_lookup',
        ['player.enumerate'] = 'qb.server.player_enumeration',
        ['money.read'] = 'qb.server.player_lookup',
        ['money.add'] = 'qb.player.money_mutation',
        ['money.remove'] = 'qb.player.money_mutation',
        ['money.set'] = 'qb.player.money_mutation',
        ['groups.set_job'] = 'qb.player.group_mutation',
        ['groups.set_gang'] = 'qb.player.group_mutation',
        ['groups.set_duty'] = 'qb.player.duty_mutation',
        ['groups.read'] = 'qb.server.player_lookup',
        ['metadata.read'] = 'qb.server.player_lookup',
        ['metadata.set'] = 'qb.player.metadata_mutation',
        ['callback.register'] = 'qb.server.callback_registration',
        ['callback.invoke'] = 'qb.server.callback_registration',
        ['client.player_data.read'] = 'qb.client.player_data',
        ['client.callback.invoke'] = 'qb.client.callback_invocation',
        ['telemetry.read'] = 'qb.server.core_object',
        ['permissions.read'] = 'qb.server.permission_view',
        ['lifecycle.publish'] = 'qb.shared.lifecycle_events',
        ['events.job.publish'] = 'qb.shared.job_update_events',
        ['events.gang.publish'] = 'qb.shared.gang_update_events',
        ['events.duty.publish'] = 'qb.shared.duty_update_events',
        ['events.money.publish'] = 'qb.shared.money_update_events',
    },
    qbx = {
        ['core_object.read'] = 'qbx.server.player_lookup',
        ['player.read'] = 'qbx.server.player_lookup',
        ['player.lookup_identifier'] = 'qbx.server.identifier_player_lookup',
        ['player.enumerate'] = 'qbx.server.player_lookup',
        ['player.offline_read'] = 'qbx.server.offline_player_lookup',
        ['money.read'] = 'qbx.server.money_read',
        ['money.add'] = 'qbx.server.money_mutation',
        ['money.remove'] = 'qbx.server.money_mutation',
        ['money.set'] = 'qbx.server.money_mutation',
        ['groups.set_job'] = 'qbx.server.group_mutation',
        ['groups.set_gang'] = 'qbx.server.group_mutation',
        ['groups.set_primary'] = 'qbx.server.primary_group_mutation',
        ['groups.set_duty'] = 'qbx.server.duty_mutation',
        ['metadata.read'] = 'qbx.server.metadata_read',
        ['metadata.set'] = 'qbx.player.metadata_mutation',
        ['callback.register'] = 'qbx.server.callback_registration',
        ['callback.invoke'] = 'qbx.server.callback_registration',
        ['client.player_data.read'] = 'qbx.client.player_data',
        ['groups.read'] = 'qbx.server.groups_read',
        ['telemetry.read'] = 'qbx.server.player_lookup',
        ['permissions.read'] = 'qbx.server.permission_admin',
        ['lifecycle.publish'] = 'qbx.shared.lifecycle_events',
        ['events.group.publish'] = 'qbx.shared.group_update_events',
        ['events.duty.publish'] = 'qbx.shared.duty_update_events',
        ['events.money.publish'] = 'qbx.shared.money_update_events',
    },
    esx = {
        ['shared_object.read'] = 'esx.server.shared_object',
        ['player.read'] = 'esx.server.player_lookup',
        ['player.lookup_identifier'] = 'esx.server.identifier_player_lookup',
        ['player.enumerate'] = 'esx.server.player_enumeration',
        ['money.read'] = 'esx.xplayer.accounts_read',
        ['accounts.custom_read'] = 'esx.xplayer.custom_accounts',
        ['money.add'] = 'esx.xplayer.money_mutation',
        ['money.remove'] = 'esx.xplayer.money_mutation',
        ['money.set'] = 'esx.xplayer.money_mutation',
        ['groups.set_job'] = 'esx.xplayer.job_mutation',
        ['groups.set_duty'] = 'esx.xplayer.duty_mutation',
        ['metadata.read'] = 'esx.server.player_lookup',
        ['metadata.set'] = 'esx.xplayer.metadata_mutation',
        ['callback.register'] = 'esx.server.callback_registration',
        ['callback.invoke'] = 'esx.server.callback_registration',
        ['client.player_data.read'] = 'esx.client.player_data',
        ['client.callback.invoke'] = 'esx.client.callback_invocation',
        ['groups.read'] = 'esx.xplayer.job_read',
        ['telemetry.read'] = 'esx.server.shared_object',
        ['permissions.read'] = 'esx.xplayer.permission_group',
        ['lifecycle.publish'] = 'esx.shared.lifecycle_events',
        ['events.job.publish'] = 'esx.shared.job_update_events',
        ['events.account.publish'] = 'esx.shared.account_update_events',
    },
}
local OPERATION_SUFFIXES = {
    ['core_object.read'] = 'read',
    ['core_object.filter'] = 'read',
    ['shared_object.read'] = 'read',
    ['player.read'] = 'read',
    ['player.lookup_identifier'] = 'read',
    ['player.enumerate'] = 'read',
    ['player.offline_read'] = 'read',
    ['money.read'] = 'read',
    ['accounts.custom_read'] = 'read',
    ['groups.read'] = 'read',
    ['metadata.read'] = 'read',
    ['telemetry.read'] = 'read',
    ['permissions.read'] = 'read',
    ['money.add'] = 'write',
    ['money.remove'] = 'write',
    ['money.set'] = 'write',
    ['groups.set_job'] = 'write',
    ['groups.set_gang'] = 'write',
    ['groups.set_primary'] = 'write',
    ['groups.set_duty'] = 'write',
    ['metadata.set'] = 'write',
    ['callback.register'] = 'callbacks',
    ['callback.invoke'] = 'callbacks',
    ['client.player_data.read'] = 'read',
    ['client.callback.invoke'] = 'callbacks',
    ['lifecycle.publish'] = 'read',
    ['events.job.publish'] = 'read',
    ['events.gang.publish'] = 'read',
    ['events.group.publish'] = 'read',
    ['events.duty.publish'] = 'read',
    ['events.money.publish'] = 'read',
    ['events.account.publish'] = 'read',
}
local NATIVE_CAPABILITIES_BY_OPERATION = {
    ['core_object.read'] = { 'synex.identity.read' },
    ['core_object.filter'] = { 'synex.identity.read' },
    ['shared_object.read'] = { 'synex.identity.read' },
    ['player.read'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['player.lookup_identifier'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['player.enumerate'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['player.offline_read'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['money.read'] = {
        'synex.identity.read', 'synex.accounts.read',
    },
    ['accounts.custom_read'] = {
        'synex.identity.read', 'synex.accounts.read',
    },
    ['groups.read'] = {
        'synex.identity.read', 'synex.groups.read',
    },
    ['metadata.read'] = { 'synex.identity.read' },
    ['telemetry.read'] = { 'synex.runtime.read' },
    ['permissions.read'] = { 'synex.identity.read', 'synex.permissions.read' },
    ['money.add'] = {
        'synex.identity.read', 'synex.accounts.read',
    },
    ['money.remove'] = {
        'synex.identity.read', 'synex.accounts.read',
    },
    ['money.set'] = {
        'synex.identity.read', 'synex.accounts.read',
    },
    ['groups.set_job'] = {
        'synex.identity.read', 'synex.groups.read',
        'synex.groups.compatibility.set_primary_grade',
    },
    ['groups.set_gang'] = {
        'synex.identity.read', 'synex.groups.read',
        'synex.groups.compatibility.set_primary_grade',
    },
    ['groups.set_primary'] = {
        'synex.identity.read', 'synex.groups.read',
        'synex.groups.compatibility.set_primary_grade',
    },
    ['groups.set_duty'] = {
        'synex.identity.read', 'synex.groups.read',
        'synex.groups.duty',
    },
    ['metadata.set'] = { 'synex.identity.read' },
    ['callback.register'] = { 'synex.identity.read' },
    ['callback.invoke'] = { 'synex.identity.read' },
    ['client.player_data.read'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['client.callback.invoke'] = { 'synex.identity.read' },
    ['lifecycle.publish'] = {
        'synex.identity.read', 'synex.accounts.read', 'synex.groups.read',
    },
    ['events.job.publish'] = { 'synex.identity.read', 'synex.groups.read' },
    ['events.gang.publish'] = { 'synex.identity.read', 'synex.groups.read' },
    ['events.group.publish'] = { 'synex.identity.read', 'synex.groups.read' },
    ['events.duty.publish'] = { 'synex.identity.read', 'synex.groups.read' },
    ['events.money.publish'] = { 'synex.identity.read', 'synex.accounts.read' },
    ['events.account.publish'] = { 'synex.identity.read', 'synex.accounts.read' },
}
local PUBLICATION_SURFACES = {
    qb = {
        { name = 'qb.shared.job_update_events', operation = 'events.job.publish' },
        { name = 'qb.shared.gang_update_events', operation = 'events.gang.publish' },
        { name = 'qb.shared.duty_update_events', operation = 'events.duty.publish' },
        { name = 'qb.shared.money_update_events', operation = 'events.money.publish' },
    },
    qbx = {
        { name = 'qbx.shared.group_update_events', operation = 'events.group.publish' },
        { name = 'qbx.shared.duty_update_events', operation = 'events.duty.publish' },
        { name = 'qbx.shared.money_update_events', operation = 'events.money.publish' },
    },
    esx = {
        { name = 'esx.shared.job_update_events', operation = 'events.job.publish' },
        { name = 'esx.shared.account_update_events', operation = 'events.account.publish' },
    },
}
local CLIENT_ACCESS_OPERATIONS = {
    qb = {
        playerData = 'client.player_data.read',
        callbacks = 'client.callback.invoke',
    },
    qbx = {
        playerData = 'client.player_data.read',
    },
    esx = {
        playerData = 'client.player_data.read',
        callbacks = 'client.callback.invoke',
    },
}
local SURFACE_DEPENDENCIES = {
    qb = {
        ['qb.server.core_object_filtering'] = { 'qb.server.core_object' },
        ['qb.shared.job_update_events'] = { 'qb.shared.lifecycle_events' },
        ['qb.shared.gang_update_events'] = { 'qb.shared.lifecycle_events' },
        ['qb.shared.duty_update_events'] = { 'qb.shared.lifecycle_events' },
        ['qb.shared.money_update_events'] = { 'qb.shared.lifecycle_events' },
        ['qb.client.callback_invocation'] = {
            'qb.client.player_data', 'qb.server.callback_registration',
        },
    },
    qbx = {
        ['qbx.shared.group_update_events'] = { 'qbx.shared.lifecycle_events' },
        ['qbx.shared.duty_update_events'] = { 'qbx.shared.lifecycle_events' },
        ['qbx.shared.money_update_events'] = { 'qbx.shared.lifecycle_events' },
    },
    esx = {
        ['esx.shared.job_update_events'] = { 'esx.shared.lifecycle_events' },
        ['esx.shared.account_update_events'] = { 'esx.shared.lifecycle_events' },
        ['esx.client.callback_invocation'] = {
            'esx.client.player_data', 'esx.server.callback_registration',
        },
    },
}
local COMPATIBILITY_CAPABILITIES = {
    qb = {
        ['synex.compat.qb.read'] = true,
        ['synex.compat.qb.write'] = true,
        ['synex.compat.qb.callbacks'] = true,
    },
    qbx = {
        ['synex.compat.qbx.read'] = true,
        ['synex.compat.qbx.write'] = true,
        ['synex.compat.qbx.callbacks'] = true,
    },
    esx = {
        ['synex.compat.esx.read'] = true,
        ['synex.compat.esx.write'] = true,
        ['synex.compat.esx.callbacks'] = true,
    },
}
local LIMITS = {
    configurationBytes = 524288,
    usageEntries = 512,
    adapterSnapshots = 1,
    clientConsumers = 128,
    safeInteger = Foundation.MAX_SAFE_INTEGER,
}

local function failure(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
end

local function callable(value)
    return Foundation.isCallable(value)
end

local function readInvoker()
    if type(GetInvokingResource) ~= 'function' then return nil end
    local ok, value = pcall(GetInvokingResource)
    if not ok or not Foundation.isResourceName(value) then return nil end
    return value
end

local function readJson(path)
    local raw = LoadResourceFile(RESOURCE, path)
    if type(raw) ~= 'string' or #raw < 2 or #raw > LIMITS.configurationBytes then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            ('Compatibility configuration %s is missing or outside its bound.'):format(path))
    end
    local decoded, value = pcall(json.decode, raw)
    if not decoded or type(value) ~= 'table' then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            ('Compatibility configuration %s is not valid JSON.'):format(path))
    end
    return value, nil
end

local function requireEnvelope(value, kind)
    if type(value) ~= 'table' or value.schema ~= 1 or value.kind ~= kind then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            ('Compatibility configuration %s has an invalid envelope.'):format(kind))
    end
    return value, nil
end

local runtime = SynexBridgeKernel.Runtime.create({
    maximumConfigurations = 8,
    maximumConsumers = 512,
    telemetry = {
        warningSink = function(entry)
            local copied = Foundation.copyDto(entry, {
                root = 'object', maximumDepth = 5, maximumEntries = 64,
                maximumBytes = 8192, maximumStringBytes = 512,
                maximumArrayItems = 16, maximumObjectProperties = 24,
            })
            if copied then
                print(json.encode({
                    level = 'warn', component = RESOURCE,
                    event = 'compatibility_warning', fields = copied,
                }))
            end
        end,
    },
})

local coreApi
local controlProviderBound = false
local identityLifecycleBound = false
local coreRebindGeneration = 0
local configuredConsumers = {}
local configuredConsumersByProvider = { qb = 0, qbx = 0, esx = 0 }
local configuredLifecycleByProvider = { qb = {}, qbx = {}, esx = {} }
local moneyPolicies = {}
local surfaceDocuments = {}
local matrix

local function getApi()
    if coreApi then return coreApi, nil end
    local called, resolved, resolveError = pcall(function()
        return exports.synex_core:GetAPI(CORE_API_RANGE)
    end)
    if not called or type(resolved) ~= 'table' then
        return nil, type(resolveError) == 'table' and resolveError
            or failure('SYNEX_UNAVAILABLE', 'The Synex Core API is unavailable.', true)
    end
    coreApi = resolved
    return resolved, nil
end

local COORDINATOR_TRACE_APIS = {
    InvokeAdapter = true,
    ResolveCatalog = true,
    InvokeCatalog = true,
}

local function traceCoordinator(api, authorization, provider, consumer, legacyApi, handler)
    local tracing = type(api) == 'table' and api.Tracing or nil
    local run = type(tracing) == 'table' and tracing.run or nil
    if type(authorization) ~= 'table'
        or not Foundation.isBoundedString(authorization.traceId, 8, 64,
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
        or not Foundation.isProvider(provider)
        or not Foundation.isResourceName(consumer)
        or COORDINATOR_TRACE_APIS[legacyApi] ~= true
        or not callable(handler) or not callable(run) then
        return nil, failure('COMPAT_INTERNAL',
            'The Core compatibility trace boundary is unavailable.', true)
    end
    local called, value, operationError = pcall(run, {
        operation = ('compat.%s.%s'):format(provider, legacyApi),
        traceId = authorization.traceId,
        compatProvider = provider,
        consumer = consumer,
        legacyApi = legacyApi,
    }, handler)
    if not called then
        return nil, failure('COMPAT_INTERNAL',
            'The Core compatibility trace boundary failed.', true)
    end
    if value == false and type(operationError) == 'table' then value = nil end
    if value == nil and type(operationError) ~= 'table' then
        return nil, failure('COMPAT_INTERNAL',
            'The Core compatibility trace boundary returned no result.', true)
    end
    return value, operationError
end

local identityStore = SynexBridgeIdentityStore.create({
    getApi = getApi,
    jsonDecode = function(value) return json.decode(value) end,
    jsonEncode = function(value) return json.encode(value) end,
})

local function transformSurfaces(document)
    local result = {}
    local expectedResource = RESOURCE_BY_PROVIDER[document.provider]
    local targetRange = type(document.targetFrameworkApiRange) == 'string'
        and document.targetFrameworkApiRange or nil
    if type(document.surfaces) ~= 'table' or document.providerResource ~= expectedResource
        or not Foundation.isSemver(document.providerVersion)
        or targetRange ~= nil and not Foundation.isSemverRange(targetRange) then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            'A compatibility surface manifest has no surfaces.')
    end
    for index, source in ipairs(document.surfaces) do
        if type(source) ~= 'table' then
            return nil, failure('COMPAT_CONFIGURATION_INVALID',
                'A compatibility surface entry is invalid.')
        end
        result[index] = {
            name = source.name,
            provider = document.provider,
            status = source.status,
            modes = source.modes,
            deprecated = source.deprecated,
            requiredCapability = source.requiredCapability,
            requiredAdapter = source.requiredAdapter,
            adapterOperations = source.adapterOperations,
            requiredCatalog = source.requiredCatalog,
            catalogOperations = source.catalogOperations or {},
        }
    end
    return result, nil
end

local function transformProfiles(document, documentsByProvider)
    local result = {}
    if type(document.profiles) ~= 'table' then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            'The compatibility profile registry is invalid.')
    end
    for index, source in ipairs(document.profiles) do
        local profile, profileError = Foundation.copyClosedObject(source, {
            id = true, version = true, script = true, provider = true,
            mode = true, status = true, failurePolicy = true,
            providerVersion = true, targetFrameworkApiRange = true,
            certificationArtifact = true, requiredSurfaces = true,
            requiredAdapters = true, requiredCatalogs = true, evidence = true,
            vendor = true, upstream = true, requiredDomains = true,
            requiredExports = true, requiredEvents = true, directSql = true,
            knownLimitations = true, testedFlows = true,
        }, {
            'id', 'version', 'script', 'provider', 'mode', 'status',
            'failurePolicy', 'providerVersion', 'targetFrameworkApiRange',
            'requiredSurfaces',
            'requiredAdapters', 'evidence',
        }, {
            root = 'object', maximumDepth = 8, maximumEntries = 512,
            maximumBytes = 65536, maximumStringBytes = 512,
            maximumArrayItems = 128, maximumObjectProperties = 32,
        })
        if not profile then return nil, profileError end
        local requiredSurfaceNames = {}
        for _, requirement in ipairs(profile.requiredSurfaces or {}) do
            requiredSurfaceNames[requirement.name] = true
        end
        for surface, dependencies in pairs(
            SURFACE_DEPENDENCIES[profile.provider] or {}) do
            if requiredSurfaceNames[surface] then
                for _, dependency in ipairs(dependencies) do
                    if not requiredSurfaceNames[dependency] then
                        return nil, failure('COMPAT_PROFILE_INCOMPLETE',
                            ('Compatibility surface %s requires %s.'):format(
                                surface, dependency))
                    end
                end
            end
        end
        local requiredAdapters = {}
        for adapterIndex, adapter in ipairs(profile.requiredAdapters or {}) do
            requiredAdapters[adapterIndex] = {
                name = adapter.name, versionRange = adapter.versionRange,
            }
        end
        local requiredCatalogs = {}
        for catalogIndex, catalog in ipairs(profile.requiredCatalogs or {}) do
            requiredCatalogs[catalogIndex] = {
                name = catalog.name,
                versionRange = catalog.versionRange,
                domain = catalog.domain,
                revision = catalog.revision,
            }
        end
        local surfaceDocument = documentsByProvider[profile.provider]
        local expectedResource = RESOURCE_BY_PROVIDER[profile.provider]
        local catalogTargetRange = surfaceDocument
            and type(surfaceDocument.targetFrameworkApiRange) == 'string'
            and surfaceDocument.targetFrameworkApiRange or nil
        local readProviderVersion, installedProviderVersion = pcall(
            GetResourceMetadata, expectedResource, 'version', 0)
        local upstreamMatches = profile.upstream == nil
            or type(surfaceDocument) == 'table'
                and type(surfaceDocument.upstream) == 'table'
                and profile.upstream.repository == surfaceDocument.upstream.repository
                and profile.upstream.revision == surfaceDocument.upstream.revision
        if not surfaceDocument or surfaceDocument.providerResource ~= expectedResource
            or profile.providerVersion ~= surfaceDocument.providerVersion
            or profile.targetFrameworkApiRange ~= catalogTargetRange
            or not upstreamMatches
            or not readProviderVersion
            or installedProviderVersion ~= profile.providerVersion then
            return nil, Foundation.error('COMPAT_PROFILE_INCOMPLETE')
        end
        local certificationVerified = profile.status == 'CERTIFIED'
            and SynexBridgeKernel.Certification.verify({
                profile = profile,
                surfaceDocument = surfaceDocument,
                loadFile = function(path) return LoadResourceFile(RESOURCE, path) end,
                decode = function(raw) return json.decode(raw) end,
            }) == true
        result[index] = {
            id = profile.id,
            version = profile.version,
            script = profile.script,
            provider = profile.provider,
            mode = profile.mode,
            status = profile.status,
            failurePolicy = profile.failurePolicy,
            providerVersion = profile.providerVersion,
            targetFrameworkApiRange = profile.targetFrameworkApiRange,
            certificationArtifact = profile.certificationArtifact,
            requiredSurfaces = profile.requiredSurfaces,
            requiredAdapters = requiredAdapters,
            requiredCatalogs = requiredCatalogs,
            evidence = profile.evidence,
            vendor = profile.vendor,
            upstream = profile.upstream,
            requiredDomains = profile.requiredDomains or {},
            requiredExports = profile.requiredExports or {},
            requiredEvents = profile.requiredEvents or {},
            directSql = profile.directSql or {},
            knownLimitations = profile.knownLimitations or {},
            testedFlows = profile.testedFlows or {},
            certificationVerified = certificationVerified,
        }
    end
    return result, nil
end

local function transformConsumers(document, profiles)
    local result = {}
    local profilesById = {}
    for _, profile in ipairs(profiles) do profilesById[profile.id] = profile end
    configuredConsumers = {}
    configuredConsumersByProvider = { qb = 0, qbx = 0, esx = 0 }
    configuredLifecycleByProvider = { qb = {}, qbx = {}, esx = {} }
    for index, source in ipairs(document.consumers or {}) do
        result[index] = {
            resource = source.resource,
            provider = source.provider,
            mode = source.mode,
            profileId = source.profileId,
            failurePolicy = source.failurePolicy,
            enabled = source.enabled,
        }
        if source.enabled == true then
            configuredConsumers[source.resource] = result[index]
            if configuredConsumersByProvider[source.provider] ~= nil then
                configuredConsumersByProvider[source.provider] =
                    configuredConsumersByProvider[source.provider] + 1
            end
            local profile = profilesById[source.profileId]
            if profile and profile.provider == source.provider then
                for _, requirement in ipairs(profile.requiredSurfaces) do
                    if requirement.name:match('%.shared%.lifecycle_events$') then
                        local lifecycleConsumers = configuredLifecycleByProvider[source.provider]
                        lifecycleConsumers[#lifecycleConsumers + 1] = source.resource
                        break
                    end
                end
            end
        end
    end
    return result, nil
end

local function registerMappings(document)
    for _, domainName in ipairs({
        'identity', 'accounts', 'groups', 'metadata', 'permissions',
    }) do
        local domain = runtime.mappings[domainName]
        local definitions = document[domainName]
        -- Schema 1 originally shipped without the additive permission-view
        -- registry. Treat its absence as an empty, fail-closed registry while
        -- the checked-in schema requires the field for new configurations.
        if domainName == 'permissions' and definitions == nil then definitions = {} end
        if type(definitions) ~= 'table' or type(domain) ~= 'table' then
            return nil, failure('COMPAT_CONFIGURATION_INVALID',
                ('Compatibility mapping domain %s is invalid.'):format(domainName))
        end
        for _, definition in ipairs(definitions) do
            local registered, registrationError = domain:register(
                CONFIG_OWNER, CONFIG_EPOCH, definition)
            if not registered then return nil, registrationError end
        end
    end
    return true, nil
end

local function loadMoneyPolicies(document)
    moneyPolicies = {}
    if type(document.policies) ~= 'table' or #document.policies > 512 then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            'The compatibility money-policy registry is invalid.')
    end
    for _, value in ipairs(document.policies) do
        local policy, policyError = Foundation.copyClosedObject(value, {
            id = true, version = true, provider = true, consumer = true,
            moneyAlias = true, direction = true, legacyReason = true,
            action = true, accountId = true, nativeReasonCode = true,
            status = true,
        }, {
            'id', 'version', 'provider', 'consumer', 'moneyAlias', 'direction',
            'legacyReason', 'action', 'nativeReasonCode', 'status',
        }, {
            root = 'object', maximumEntries = 32, maximumBytes = 8192,
            maximumStringBytes = 256, maximumKeyBytes = 64,
        })
        if not policy then return nil, policyError end
        if not Foundation.isDefinitionName(policy.id)
            or not Foundation.isSemver(policy.version)
            or not Foundation.isProvider(policy.provider)
            or not Foundation.isResourceName(policy.consumer)
            or not Foundation.isIdentifier(policy.moneyAlias)
            or (policy.direction ~= 'add' and policy.direction ~= 'remove')
            or not Foundation.isBoundedString(policy.legacyReason, 1, 128,
                '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            or not Foundation.isBoundedString(policy.nativeReasonCode, 3, 96,
                '^[a-z][a-z0-9_.:%-]*$')
            or (policy.status ~= 'ACTIVE' and policy.status ~= 'DISABLED') then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local transferPolicy = policy.action == 'transfer'
            and Foundation.isBoundedString(policy.accountId, 36, 36,
                '^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[1-5][0-9a-f][0-9a-f][0-9a-f]%-[89ab][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$')
        local mintPolicy = policy.action == 'mint'
            and policy.direction == 'add' and policy.accountId == nil
        local burnPolicy = policy.action == 'burn'
            and policy.direction == 'remove' and policy.accountId == nil
        if not transferPolicy and not mintPolicy and not burnPolicy then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local key = table.concat({ policy.provider, policy.consumer,
            policy.moneyAlias, policy.direction, policy.legacyReason }, ':')
        if moneyPolicies[key] then
            return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
        end
        moneyPolicies[key] = policy
    end
    return true, nil
end

local function createMatrix(surfaceDocumentsValue)
    local result = {
        apiVersion = '1.0.0',
        deprecated = true,
        preferredPath = 'native-synex-contracts',
        isolation = 'consumer-bound-provider-and-domain-gates',
        qb = {}, qbx = {}, esx = {},
        unsupported = {
            'authorization-equivalence', 'direct-sql', 'offline-player-mutation',
            'public-mutable-player-state', 'universal-domain-emulation',
        },
    }
    for provider, document in pairs(surfaceDocumentsValue) do
        for _, surface in ipairs(document.surfaces) do
            result[provider][surface.name] = surface.status:lower()
        end
    end
    return result
end

local function configureRuntime()
    local profilesDocument, profilesError = readJson('compatibility/profiles.json')
    if not profilesDocument then return nil, profilesError end
    local consumersDocument, consumersError = readJson('compatibility/consumers.json')
    if not consumersDocument then return nil, consumersError end
    local mappingsDocument, mappingsError = readJson('compatibility/mappings.json')
    if not mappingsDocument then return nil, mappingsError end
    local moneyPolicyDocument, moneyPolicyError = readJson(
        'compatibility/money-policies.json')
    if not moneyPolicyDocument then return nil, moneyPolicyError end
    if not requireEnvelope(profilesDocument, 'synex-compatibility-profiles')
        or not requireEnvelope(consumersDocument, 'synex-compatibility-consumers')
        or not requireEnvelope(mappingsDocument, 'synex-compatibility-mappings')
        or not requireEnvelope(moneyPolicyDocument,
            'synex-compatibility-money-policies') then
        return nil, failure('COMPAT_CONFIGURATION_INVALID',
            'A compatibility registry has an invalid envelope.')
    end

    local surfaces = {}
    for _, provider in ipairs({ 'qb', 'qbx', 'esx' }) do
        local document, documentError = readJson(
            ('compatibility/surfaces/%s.json'):format(provider))
        if not document then return nil, documentError end
        if not requireEnvelope(document, 'synex-compatibility-surfaces')
            or document.provider ~= provider then
            return nil, failure('COMPAT_CONFIGURATION_INVALID',
                ('The %s compatibility surface manifest is invalid.'):format(provider))
        end
        surfaceDocuments[provider] = document
        local transformed, transformError = transformSurfaces(document)
        if not transformed then return nil, transformError end
        for _, surface in ipairs(transformed) do surfaces[#surfaces + 1] = surface end
    end
    local profiles, profileError = transformProfiles(
        profilesDocument, surfaceDocuments)
    if not profiles then return nil, profileError end
    local consumers, consumerError = transformConsumers(consumersDocument, profiles)
    if not consumers then return nil, consumerError end
    local configured, configurationError = runtime.resolver:configure(
        CONFIG_OWNER, CONFIG_EPOCH, {
            defaultMode = consumersDocument.defaultMode,
            providers = { qb = true, qbx = true, esx = true },
            profiles = profiles,
            surfaces = surfaces,
            consumers = consumers,
        })
    if not configured then return nil, configurationError end
    local mappingsRegistered, mappingError = registerMappings(mappingsDocument)
    if not mappingsRegistered then return nil, mappingError end
    local policiesLoaded, policyError = loadMoneyPolicies(moneyPolicyDocument)
    if not policiesLoaded then return nil, policyError end
    matrix = createMatrix(surfaceDocuments)
    return configured, nil
end

local configured, configurationError = configureRuntime()
if not configured then
    error(('synex_bridge compatibility configuration failed: %s'):format(
        type(configurationError) == 'table' and configurationError.code or 'UNKNOWN'))
end

local traceCounter = 0
local function traceId()
    local api = getApi()
    if api and type(api.Ids) == 'table' and callable(api.Ids.next) then
        local called, value = pcall(api.Ids.next, 'compat_trace')
        if called and Foundation.isBoundedString(value, 8, 96,
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then return value end
    end
    traceCounter = (traceCounter + 1) % 1000000000
    return ('compat:%d:%d:%d'):format(
        os.time(), GetGameTimer() % 1000000000, traceCounter)
end

local function providerRequest(request, allowed, required)
    local invoker = readInvoker()
    local provider = invoker and PROVIDER_BY_RESOURCE[invoker] or nil
    if not provider then
        return nil, nil, failure('COMPAT_CONSUMER_DENIED',
            'Only an official Synex compatibility provider may call this operation.')
    end
    local copied, copyError = Foundation.copyClosedObject(
        request, allowed, required, {
            root = 'object', maximumDepth = 12, maximumEntries = 2048,
            maximumBytes = 262144, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 128,
        })
    if not copied then return nil, nil, copyError end
    if copied.provider ~= provider
        or copied.providerResource ~= nil and copied.providerResource ~= invoker then
        return nil, nil, failure('COMPAT_FRAMEWORK_CONFLICT',
            'The provider identity does not match the invoking resource.')
    end
    return copied, provider, nil
end

local function outcomeFor(errorValue)
    local code = type(errorValue) == 'table' and errorValue.code or ''
    if code:find('DENIED', 1, true) or code:find('DISABLED', 1, true) then return 'denied' end
    if code:find('UNSUPPORTED', 1, true) or code:find('MISSING', 1, true)
        or code == 'COMPAT_CATALOG_UNAVAILABLE' then return 'unsupported' end
    if code:find('TIMEOUT', 1, true) then return 'timeout' end
    if code:find('LIMIT', 1, true) then return 'rate_limited' end
    if code:find('DEPRECATED', 1, true) then return 'deprecated' end
    return 'error'
end

local function finishResolution(token, outcome, telemetry)
    if token then (telemetry or runtime.telemetry):finish(token, outcome) end
end

local function authorizeConsumer(request, provider, surfaceName,
        nativeCapabilities, deferCompletion, executableKind, telemetrySurface)
    local telemetry = executableKind == 'catalog'
        and runtime.catalogTelemetry or runtime.telemetry
    local token, telemetryError = telemetry:start(
        request.consumer, CONFIG_EPOCH, telemetrySurface or surfaceName)
    if telemetrySurface ~= nil and not token then return nil, telemetryError end
    local resolution, resolutionError, action = runtime.resolver:resolve(
        request.consumer, surfaceName, request.operation)
    if not resolution then
        finishResolution(token, outcomeFor(resolutionError), telemetry)
        if type(resolutionError) == 'table' then resolutionError.action = action end
        return nil, resolutionError
    end
    local compatibilityCapability = resolution.surface
        and resolution.surface.requiredCapability or nil
    if resolution.provider ~= provider or resolution.surface.name ~= surfaceName then
        local conflict = Foundation.error('COMPAT_FRAMEWORK_CONFLICT')
        finishResolution(token, outcomeFor(conflict), telemetry)
        return nil, conflict
    end
    if not COMPATIBILITY_CAPABILITIES[provider]
        or COMPATIBILITY_CAPABILITIES[provider][compatibilityCapability] ~= true
        or request.capability ~= nil and request.capability ~= compatibilityCapability then
        local unsupported = Foundation.error('COMPAT_API_UNSUPPORTED')
        finishResolution(token, outcomeFor(unsupported), telemetry)
        return nil, unsupported
    end
    if nativeCapabilities == nil then
        local operationPolicy = executableKind == 'catalog'
            and resolution.catalogOperation or resolution.adapterOperation
        nativeCapabilities = type(operationPolicy) == 'table'
            and operationPolicy.nativeCapabilities or nil
    end
    if type(nativeCapabilities) ~= 'table' or #nativeCapabilities < 1
        or #nativeCapabilities > 16 then
        local unsupported = Foundation.error('COMPAT_API_UNSUPPORTED')
        finishResolution(token, outcomeFor(unsupported), telemetry)
        return nil, unsupported
    end
    local seenCapabilities = {}
    for index, capability in pairs(nativeCapabilities) do
        if not Foundation.isSafeInteger(index, 1, #nativeCapabilities)
            or not Foundation.isIdentifier(capability)
            or seenCapabilities[capability] then
            local unsupported = Foundation.error('COMPAT_API_UNSUPPORTED')
            finishResolution(token, outcomeFor(unsupported), telemetry)
            return nil, unsupported
        end
        seenCapabilities[capability] = true
    end
    local script = resolution.script
    local profileError
    local providerResource = RESOURCE_BY_PROVIDER[provider]
    local providerVersionRead, installedProviderVersion = pcall(
        GetResourceMetadata, providerResource, 'version', 0)
    if not providerVersionRead or installedProviderVersion ~= resolution.providerVersion
        or type(script) ~= 'table' or script.name ~= request.consumer then
        profileError = Foundation.error('COMPAT_PROFILE_INCOMPLETE')
    elseif script.testedVersion ~= nil then
        local readVersion, installedVersion = pcall(
            GetResourceMetadata, request.consumer, 'version', 0)
        if not readVersion or installedVersion ~= script.testedVersion then
            profileError = Foundation.error('COMPAT_PROFILE_INCOMPLETE')
        end
    end
    if profileError then
        finishResolution(token, outcomeFor(profileError), telemetry)
        return nil, profileError
    end
    local api, apiError = getApi()
    if not api then
        finishResolution(token, outcomeFor(apiError), telemetry)
        return nil, apiError
    end
    local capabilities = api.Capabilities
    local checkResource = type(capabilities) == 'table'
        and capabilities.checkResource or nil
    if not callable(checkResource) then
        local boundaryError = failure('COMPAT_AUTHORIZATION_INVALID',
            'The Core delegated capability boundary is unavailable.', true)
        finishResolution(token, outcomeFor(boundaryError), telemetry)
        return nil, boundaryError
    end
    local authorizationTraceId = traceId()
    local requiredCapabilities = { compatibilityCapability }
    for _, capability in ipairs(nativeCapabilities) do
        requiredCapabilities[#requiredCapabilities + 1] = capability
    end
    for index, capability in ipairs(requiredCapabilities) do
        local checked, allowed, authorizationError = pcall(
            checkResource, request.consumer, capability,
            ('compat.%s.%s.%s'):format(provider, request.operation,
                index == 1 and 'compatibility' or 'native'))
        if not checked then
            local boundaryError = failure('COMPAT_AUTHORIZATION_INVALID',
                'The Core delegated capability check failed.', true)
            finishResolution(token, outcomeFor(boundaryError), telemetry)
            return nil, boundaryError
        end
        if not allowed then
            local denied = type(authorizationError) == 'table' and authorizationError
                or Foundation.error('COMPAT_CONSUMER_DENIED')
            if type(denied) == 'table' and denied.traceId == nil then
                denied.traceId = authorizationTraceId
            end
            finishResolution(token, outcomeFor(denied), telemetry)
            return nil, denied
        end
    end
    if not deferCompletion then finishResolution(token, 'success', telemetry) end
    return {
        authority = 'core',
        mode = resolution.mode,
        traceId = authorizationTraceId,
        profileId = resolution.profileId,
        profileVersion = resolution.profileVersion,
        surface = resolution.surface.name,
        status = resolution.surface.status,
    }, nil, resolution, token
end

local function resolveConsumer(request, provider)
    local expectedSuffix = OPERATION_SUFFIXES[request.operation]
    local nativeCapabilities = NATIVE_CAPABILITIES_BY_OPERATION[request.operation]
    local expectedCapability = expectedSuffix
        and ('synex.compat.%s.%s'):format(provider, expectedSuffix) or nil
    local surfaceName = OPERATION_SURFACES[provider]
        and OPERATION_SURFACES[provider][request.operation] or nil
    if not expectedCapability or request.capability ~= expectedCapability or not surfaceName
        or type(nativeCapabilities) ~= 'table' or #nativeCapabilities < 1 then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    return authorizeConsumer(request, provider, surfaceName, nativeCapabilities, false)
end

exports('AuthorizeCompatibilityConsumer', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, providerResource = true, consumer = true,
        capability = true, operation = true,
    }, { 'provider', 'providerResource', 'consumer', 'capability', 'operation' })
    if not copied then return nil, requestError end
    return resolveConsumer(copied, provider)
end)

exports('InvokeCompatibilityAdapter', function(consumer, request)
    local providerResource = readInvoker()
    local provider = providerResource and PROVIDER_BY_RESOURCE[providerResource] or nil
    if not provider or not Foundation.isResourceName(consumer) then
        return nil, Foundation.error('COMPAT_CONSUMER_DENIED')
    end
    local copied, requestError = Foundation.copyClosedObject(request, {
        surface = true, operation = true, payload = true,
    }, { 'surface', 'operation', 'payload' }, {
        root = 'object', maximumDepth = 12, maximumEntries = 512,
        maximumBytes = 65536, maximumStringBytes = 4096,
        maximumArrayItems = 128, maximumObjectProperties = 64,
        maximumKeyBytes = 96,
    })
    if not copied or not Foundation.isDefinitionName(copied.surface)
        or not Foundation.isIdentifier(copied.operation) then
        return nil, requestError or Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local payload, payloadError = Foundation.copyDto(copied.payload, {
        root = 'object', maximumDepth = 10, maximumEntries = 384,
        maximumBytes = 49152, maximumStringBytes = 4096,
        maximumArrayItems = 128, maximumObjectProperties = 64,
        maximumKeyBytes = 96,
    })
    if not payload then return nil, payloadError end
    local authorization, authorizationError, resolution, token = authorizeConsumer({
        consumer = consumer, operation = copied.operation,
    }, provider, copied.surface, nil, true, 'adapter')
    if not authorization then return nil, authorizationError end
    local api, apiError = getApi()
    if not api then
        finishResolution(token, outcomeFor(apiError))
        return nil, apiError
    end
    if not callable(resolution.handler) or type(resolution.adapter) ~= 'table'
        or type(resolution.adapterOperation) ~= 'table' then
        local missing = Foundation.error('COMPAT_ADAPTER_MISSING')
        local _, traceError = traceCoordinator(api, authorization, provider,
            consumer, 'InvokeAdapter', function() return nil, missing end)
        finishResolution(token, outcomeFor(traceError))
        return nil, traceError
    end
    local context, contextError = Foundation.copyDto({
        schemaVersion = 1,
        traceId = authorization.traceId,
        provider = provider,
        providerResource = providerResource,
        consumer = consumer,
        profile = {
            id = resolution.profileId,
            version = resolution.profileVersion,
            status = resolution.profileStatus,
            mode = resolution.mode,
        },
        surface = {
            name = resolution.surface.name,
            status = resolution.surface.status,
        },
        adapter = {
            name = resolution.adapter.name,
            version = resolution.adapter.version,
            domain = resolution.adapter.domain,
            status = resolution.adapter.status,
        },
        operation = copied.operation,
    }, {
        root = 'object', maximumDepth = 6, maximumEntries = 64,
        maximumBytes = 8192, maximumStringBytes = 256,
        maximumArrayItems = 16, maximumObjectProperties = 16,
        maximumKeyBytes = 64,
    })
    if not context then
        finishResolution(token, outcomeFor(contextError))
        return nil, contextError
    end
    local function execute()
        local called, value, adapterError = pcall(resolution.handler, context, payload)
        if not called then return nil, Foundation.error('COMPAT_INTERNAL') end
        if value == nil or value == false then
            local structured = Foundation.copyClosedObject(adapterError, {
                code = true, message = true, retryable = true,
            }, { 'code' }, {
                root = 'object', maximumEntries = 8, maximumBytes = 2048,
                maximumStringBytes = 512, maximumObjectProperties = 3,
                maximumKeyBytes = 32,
            })
            local sanitized = structured and Foundation.error(structured.code) or nil
            if not sanitized or sanitized.code ~= structured.code then
                sanitized = Foundation.error('COMPAT_RESOLUTION_FAILED')
            end
            return nil, sanitized
        end
        return Foundation.copyDto(value, {
            root = 'object', maximumDepth = 10, maximumEntries = 384,
            maximumBytes = 49152, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 64,
            maximumKeyBytes = 96,
        })
    end
    local result, resultError = traceCoordinator(
        api, authorization, provider, consumer, 'InvokeAdapter', execute)
    finishResolution(token, result and 'success' or outcomeFor(resultError))
    return result, resultError
end)

local function compatibilityCatalogCall(consumer, request, invoke)
    local providerResource = readInvoker()
    local provider = providerResource and PROVIDER_BY_RESOURCE[providerResource] or nil
    if not provider or not Foundation.isResourceName(consumer) then
        return nil, Foundation.error('COMPAT_CONSUMER_DENIED')
    end
    local allowed = { surface = true, operation = true }
    local required = { 'surface', 'operation' }
    if invoke then
        allowed.payload = true
        required[#required + 1] = 'payload'
    end
    local copied, requestError = Foundation.copyClosedObject(request, allowed, required, {
        root = 'object', maximumDepth = 12, maximumEntries = 512,
        maximumBytes = 65536, maximumStringBytes = 4096,
        maximumArrayItems = 128, maximumObjectProperties = 64,
        maximumKeyBytes = 96,
    })
    if not copied or not Foundation.isDefinitionName(copied.surface)
        or not Foundation.isIdentifier(copied.operation) then
        return nil, requestError or Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local payload
    if invoke then
        local payloadError
        payload, payloadError = Foundation.copyDto(copied.payload, {
            root = 'object', maximumDepth = 10, maximumEntries = 384,
            maximumBytes = 49152, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 64,
            maximumKeyBytes = 96,
        })
        if not payload then return nil, payloadError end
    end
    local telemetrySurface = ('catalog.%s.%s'):format(
        provider, invoke and 'invoke' or 'resolve')
    local authorization, authorizationError, resolution, token = authorizeConsumer({
        consumer = consumer, operation = copied.operation,
    }, provider, copied.surface, nil, true, 'catalog', telemetrySurface)
    if not authorization then return nil, authorizationError end
    local api, apiError = getApi()
    if not api then
        finishResolution(token, outcomeFor(apiError), runtime.catalogTelemetry)
        return nil, apiError
    end
    if not callable(resolution.catalogHandler) or type(resolution.catalog) ~= 'table'
        or type(resolution.catalogOperation) ~= 'table' then
        local missing = Foundation.error('COMPAT_CATALOG_UNAVAILABLE')
        local traceApi = invoke and 'InvokeCatalog' or 'ResolveCatalog'
        local _, traceError = traceCoordinator(api, authorization, provider,
            consumer, traceApi, function() return nil, missing end)
        finishResolution(token, outcomeFor(traceError), runtime.catalogTelemetry)
        return nil, traceError
    end
    local metadata, metadataError = Foundation.copyDto({
        schemaVersion = 1,
        traceId = authorization.traceId,
        provider = provider,
        providerResource = providerResource,
        consumer = consumer,
        profile = {
            id = resolution.profileId,
            version = resolution.profileVersion,
            status = resolution.profileStatus,
            mode = resolution.mode,
        },
        surface = {
            name = resolution.surface.name,
            status = resolution.surface.status,
        },
        catalog = {
            name = resolution.catalog.name,
            version = resolution.catalog.version,
            provider = resolution.catalog.provider,
            domain = resolution.catalog.domain,
            status = resolution.catalog.status,
            authority = resolution.catalog.authority,
            revision = resolution.catalog.revision,
        },
        operation = copied.operation,
    }, {
        root = 'object', maximumDepth = 6, maximumEntries = 72,
        maximumBytes = 8192, maximumStringBytes = 256,
        maximumArrayItems = 16, maximumObjectProperties = 16,
        maximumKeyBytes = 64,
    })
    if not metadata then
        finishResolution(token, outcomeFor(metadataError), runtime.catalogTelemetry)
        return nil, metadataError
    end
    local traceApi = invoke and 'InvokeCatalog' or 'ResolveCatalog'
    local function execute()
        if not invoke then return metadata, nil end
        local called, value, catalogError = pcall(
            resolution.catalogHandler, metadata, payload)
        if not called then return nil, Foundation.error('COMPAT_INTERNAL') end
        if value == nil or value == false then
            local structured = Foundation.copyClosedObject(catalogError, {
                code = true, message = true, retryable = true,
            }, { 'code' }, {
                root = 'object', maximumEntries = 8, maximumBytes = 2048,
                maximumStringBytes = 512, maximumObjectProperties = 3,
                maximumKeyBytes = 32,
            })
            local sanitized = structured and Foundation.error(structured.code) or nil
            if not sanitized or sanitized.code ~= structured.code then
                sanitized = Foundation.error('COMPAT_RESOLUTION_FAILED')
            end
            return nil, sanitized
        end
        return Foundation.copyDto(value, {
            root = 'object', maximumDepth = 10, maximumEntries = 384,
            maximumBytes = 49152, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 64,
            maximumKeyBytes = 96,
        })
    end
    local result, resultError = traceCoordinator(
        api, authorization, provider, consumer, traceApi, execute)
    finishResolution(token, result and 'success' or outcomeFor(resultError),
        runtime.catalogTelemetry)
    return result, resultError
end

exports('ResolveCompatibilityCatalog', function(consumer, request)
    return compatibilityCatalogCall(consumer, request, false)
end)

exports('InvokeCompatibilityCatalog', function(consumer, request)
    return compatibilityCatalogCall(consumer, request, true)
end)

exports('ResolveCompatibilityIdentity', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, identifierType = true, characterId = true,
    }, { 'provider', 'identifierType', 'characterId' })
    if not copied then return nil, requestError end
    local static = runtime.mappings:resolveIdentity(
        provider, 'character', 'native', copied.characterId)
    if static then
        return {
            provider = provider,
            identifierType = copied.identifierType,
            identifier = static.legacyId,
            characterId = copied.characterId,
            importSource = 'static_registry',
        }, nil
    end
    return identityStore:resolve(provider, copied.identifierType, copied.characterId)
end)

exports('FindCompatibilityIdentity', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, identifierType = true, identifier = true,
    }, { 'provider', 'identifierType', 'identifier' })
    if not copied then return nil, requestError end
    if not Foundation.isBoundedString(copied.identifier, 1, 191) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local static = runtime.mappings:resolveIdentity(
        provider, 'character', 'legacy', copied.identifier)
    if static then
        return {
            provider = provider,
            identifierType = copied.identifierType,
            identifier = copied.identifier,
            characterId = static.nativeId,
            importSource = 'static_registry',
        }, nil
    end
    return identityStore:findByLegacy(
        provider, copied.identifierType, copied.identifier)
end)

local function metadataDefinitions(provider)
    local listed, listError = runtime.mappings.metadata:list()
    if not listed then return nil, listError end
    local byLegacy, byStorage = {}, {}
    for _, definition in ipairs(listed.items) do
        if definition.provider == provider and definition.status ~= 'UNSUPPORTED'
            and definition.status ~= 'UNKNOWN' then
            if byLegacy[definition.key] or byStorage[definition.storageKey] then
                return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
            end
            byLegacy[definition.key] = definition
            byStorage[definition.storageKey] = definition
        end
    end
    return { byLegacy = byLegacy, byStorage = byStorage }, nil
end

local function validateMetadataValue(definition, value)
    local kind = type(value)
    if definition.valueType == 'boolean' and kind ~= 'boolean'
        or definition.valueType == 'string' and kind ~= 'string'
        or definition.valueType == 'integer' and (kind ~= 'number'
            or math.type(value) ~= 'integer')
        or definition.valueType == 'number' and kind ~= 'number' then
        return nil, Foundation.error('COMPAT_DTO_INVALID')
    end
    if kind == 'number' and (value ~= value or value == math.huge
        or value == -math.huge or math.abs(value) > Foundation.MAX_SAFE_INTEGER) then
        return nil, Foundation.error('COMPAT_DTO_INVALID')
    end
    if definition.minimum ~= nil and value < definition.minimum
        or definition.maximum ~= nil and value > definition.maximum
        or definition.maxLength ~= nil and kind == 'string'
            and #value > definition.maxLength then
        return nil, Foundation.error('COMPAT_DTO_LIMIT')
    end
    return true, nil
end

exports('ResolveMetadataMapping', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, consumer = true, key = true, operation = true,
    }, { 'provider', 'consumer', 'key', 'operation' })
    if not copied then return nil, requestError end
    if copied.operation ~= 'write' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    local definition, mappingError = runtime.mappings:resolveMetadata(provider, copied.key)
    if not definition then return nil, mappingError end
    return {
        allowed = definition.status ~= 'UNSUPPORTED' and definition.status ~= 'UNKNOWN',
        nativeKey = definition.storageKey,
        valueType = definition.valueType,
        minimum = definition.minimum,
        maximum = definition.maximum,
        maxLength = definition.maxLength,
    }, nil
end)

exports('GetCompatibilityMetadata', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, characterId = true,
    }, { 'provider', 'characterId' })
    if not copied then return nil, requestError end
    local stored, storeError = identityStore:listMetadata(provider, copied.characterId)
    if not stored then return nil, storeError end
    local definitions, definitionError = metadataDefinitions(provider)
    if not definitions then return nil, definitionError end
    local values, versions = {}, {}
    for storageKey, value in pairs(stored.values) do
        local definition = definitions.byStorage[storageKey]
        if not definition then return nil, Foundation.error('COMPAT_METADATA_UNSUPPORTED') end
        local valid, valueError = validateMetadataValue(definition, value)
        if not valid then return nil, valueError end
        values[definition.key] = value
        versions[definition.key] = stored.versions[storageKey]
    end
    return { values = values, versions = versions }, nil
end)

exports('SetCompatibilityMetadata', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, characterId = true, key = true, value = true,
        expectedVersion = true, traceId = true, consumer = true,
    }, { 'provider', 'characterId', 'key', 'value', 'consumer' })
    if not copied then return nil, requestError end
    local definitions, definitionError = metadataDefinitions(provider)
    if not definitions then return nil, definitionError end
    local definition = definitions.byStorage[copied.key]
    if not definition then return nil, Foundation.error('COMPAT_METADATA_UNSUPPORTED') end
    local valid, valueError = validateMetadataValue(definition, copied.value)
    if not valid then return nil, valueError end
    return identityStore:setMetadata(provider, copied.characterId,
        definition.storageKey, copied.value, copied.expectedVersion)
end)

exports('ResolveMoneyPolicy', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, consumer = true, moneyAlias = true,
        direction = true, legacyReason = true,
    }, { 'provider', 'consumer', 'moneyAlias', 'direction', 'legacyReason' })
    if not copied then return nil, requestError end
    if copied.direction ~= 'add' and copied.direction ~= 'remove' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local mapping, mappingError = runtime.mappings:resolveAccount(
        provider, copied.moneyAlias)
    if not mapping then return nil, mappingError end
    if mapping.status == 'UNSUPPORTED' or mapping.status == 'UNKNOWN' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    local key = table.concat({ provider, copied.consumer, copied.moneyAlias,
        copied.direction, copied.legacyReason }, ':')
    local policy = moneyPolicies[key]
    if type(policy) ~= 'table' or policy.status ~= 'ACTIVE' then
        return nil, failure('COMPAT_MONEY_POLICY_DENIED',
            'The compatibility money operation has no explicit funding or sink policy.')
    end
    return {
        action = policy.action, accountId = policy.accountId,
        reasonCode = policy.nativeReasonCode,
        policyId = policy.id, policyVersion = policy.version,
        mappingId = mapping.id, mappingVersion = mapping.version,
    }, nil
end)

exports('ResolveCompatibilityAccountMapping', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, alias = true,
    }, { 'provider', 'alias' })
    if not copied then return nil, requestError end
    local mapping, mappingError = runtime.mappings:resolveAccount(
        provider, copied.alias)
    if not mapping then return nil, mappingError end
    if mapping.status == 'UNSUPPORTED' or mapping.status == 'UNKNOWN' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    return {
        id = mapping.id,
        version = mapping.version,
        alias = mapping.alias,
        currencyCode = mapping.currencyCode,
        accountKey = mapping.accountKey,
        accountRole = mapping.accountRole,
        minorUnit = mapping.minorUnit,
        legacyName = mapping.legacyName,
        label = mapping.label,
        round = mapping.round,
        status = mapping.status,
    }, nil
end)

exports('ListCompatibilityAccountMappings', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true,
    }, { 'provider' })
    if not copied then return nil, requestError end
    local listed, listError = runtime.mappings.accounts:list()
    if not listed then return nil, listError end
    local items, seen = {}, {}
    for _, mapping in ipairs(listed.items or {}) do
        if mapping.provider == provider and mapping.status ~= 'UNSUPPORTED'
            and mapping.status ~= 'UNKNOWN' then
            if seen[mapping.alias] then
                return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
            end
            seen[mapping.alias] = true
            items[#items + 1] = {
                id = mapping.id,
                version = mapping.version,
                alias = mapping.alias,
                currencyCode = mapping.currencyCode,
                accountKey = mapping.accountKey,
                accountRole = mapping.accountRole,
                minorUnit = mapping.minorUnit,
                legacyName = mapping.legacyName,
                label = mapping.label,
                round = mapping.round,
                status = mapping.status,
            }
        end
    end
    table.sort(items, function(left, right) return left.alias < right.alias end)
    return { items = items, truncated = false }, nil
end)

exports('ListCompatibilityPermissionMappings', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true,
    }, { 'provider' })
    if not copied then return nil, requestError end
    local listed, listError = runtime.mappings.permissions:list()
    if not listed then return nil, listError end
    local items, seen, fallback = {}, {}, nil
    for _, mapping in ipairs(listed.items or {}) do
        if mapping.provider == provider and mapping.status ~= 'UNSUPPORTED'
            and mapping.status ~= 'UNKNOWN' then
            if seen[mapping.legacyGroup] then
                return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
            end
            if mapping.fallback == true then
                if fallback ~= nil then
                    return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
                end
                fallback = mapping.legacyGroup
            end
            seen[mapping.legacyGroup] = true
            items[#items + 1] = {
                id = mapping.id,
                version = mapping.version,
                legacyGroup = mapping.legacyGroup,
                nativePermission = mapping.nativePermission,
                priority = mapping.priority,
                fallback = mapping.fallback,
                status = mapping.status,
            }
        end
    end
    table.sort(items, function(left, right)
        if left.priority ~= right.priority then return left.priority > right.priority end
        return left.legacyGroup < right.legacyGroup
    end)
    return { items = items, fallback = fallback, truncated = false }, nil
end)

exports('ResolveCompatibilityGroupMapping', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, legacyType = true, legacyName = true,
        legacyGrade = true,
    }, { 'provider', 'legacyType', 'legacyName', 'legacyGrade' })
    if not copied then return nil, requestError end
    if (copied.legacyType ~= 'job' and copied.legacyType ~= 'gang')
        or not Foundation.isIdentifier(copied.legacyName)
        or not Foundation.isSafeInteger(copied.legacyGrade, 0, 65535) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local mapping, mappingError = runtime.mappings:resolveGroup(
        provider, copied.legacyType, copied.legacyName)
    if not mapping then return nil, mappingError end
    if mapping.status == 'UNSUPPORTED' or mapping.status == 'UNKNOWN' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    local gradeKey
    for _, grade in ipairs(mapping.grades) do
        if grade.legacyGrade == copied.legacyGrade then
            if gradeKey ~= nil then
                return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
            end
            gradeKey = grade.gradeKey
        end
    end
    if gradeKey == nil then
        return nil, Foundation.error('COMPAT_MAPPING_MISSING')
    end
    local bossRoles, bossRoleError = Foundation.copyDto(mapping.bossRoles or {}, {
        root = 'array', maximumDepth = 2, maximumEntries = 32,
        maximumBytes = 2048, maximumStringBytes = 64,
        maximumArrayItems = 32, maximumObjectProperties = 1,
    })
    if not bossRoles then return nil, bossRoleError end
    return {
        id = mapping.id,
        version = mapping.version,
        legacyType = mapping.legacyType,
        legacyName = mapping.legacyName,
        legacyGrade = copied.legacyGrade,
        nativeGroupType = mapping.nativeGroupType,
        nativeGroupKey = mapping.nativeGroupKey,
        gradeKey = gradeKey,
        bossRoles = bossRoles,
        dutySupported = mapping.dutySupported == true,
        dutyState = mapping.dutyState,
        status = mapping.status,
    }, nil
end)

exports('ProjectCompatibilityGroups', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, groups = true,
    }, { 'provider', 'groups' })
    if not copied then return nil, requestError end
    if type(copied.groups) ~= 'table' or type(copied.groups.items) ~= 'table'
        or copied.groups.truncated ~= false or copied.groups.next_cursor ~= nil
        or #copied.groups.items > 8 then
        return nil, Foundation.error('COMPAT_PROJECTION_UNAVAILABLE')
    end
    local listed, listError = runtime.mappings.groups:list()
    if not listed then return nil, listError end
    local byNative = {}
    for _, definition in ipairs(listed.items) do
        if definition.provider == provider and definition.status ~= 'UNSUPPORTED'
            and definition.status ~= 'UNKNOWN' then
            local key = definition.nativeGroupType .. ':' .. definition.nativeGroupKey
            if byNative[key] then return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS') end
            byNative[key] = definition
        end
    end
    local projected, seenNative, primaryTypes = {}, {}, {}
    for _, membership in ipairs(copied.groups.items) do
        if membership.status == 'ACTIVE' then
            local group = membership.group
            if type(group) ~= 'table' then
                return nil, Foundation.error('COMPAT_PROJECTION_UNAVAILABLE')
            end
            local nativeKey = tostring(group.type) .. ':' .. tostring(group.key)
            local definition = byNative[nativeKey]
            if not definition then return nil, Foundation.error('COMPAT_MAPPING_MISSING') end
            if seenNative[nativeKey] then
                return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
            end
            seenNative[nativeKey] = true
            if membership.is_primary == true then
                if primaryTypes[definition.legacyType] then
                    return nil, Foundation.error('COMPAT_MAPPING_AMBIGUOUS')
                end
                primaryTypes[definition.legacyType] = true
            end
            local grade = membership.grade
            local legacyGrade
            if grade ~= nil then
                for _, candidate in ipairs(definition.grades) do
                    if candidate.gradeKey == grade.key then
                        legacyGrade = candidate.legacyGrade
                        break
                    end
                end
                if legacyGrade == nil then
                    return nil, Foundation.error('COMPAT_MAPPING_MISSING')
                end
            elseif #definition.grades > 0 then
                return nil, Foundation.error('COMPAT_MAPPING_MISSING')
            end
            local item, itemError = Foundation.copyDto(membership, {
                root = 'object', maximumDepth = 10, maximumEntries = 256,
                maximumBytes = 32768, maximumStringBytes = 4096,
                maximumArrayItems = 16, maximumObjectProperties = 32,
            })
            if not item then return nil, itemError end
            item.group.key = definition.legacyName
            item.group.type = definition.legacyType
            if item.grade then item.grade.rank = legacyGrade end
            if definition.dutySupported ~= true then item.duty = nil end
            local bossRoles, isBoss = {}, false
            for _, roleKey in ipairs(definition.bossRoles or {}) do
                bossRoles[roleKey] = true
            end
            for _, role in ipairs(item.roles or {}) do
                if type(role) == 'table' and bossRoles[role.key] then
                    isBoss = true
                    break
                end
            end
            item.compatibility_is_boss = isBoss
            projected[#projected + 1] = item
        end
    end
    return { items = projected, truncated = false }, nil
end)

local function activeLifecycleCandidate(provider, excludedResource)
    local providerResource = RESOURCE_BY_PROVIDER[provider]
    local providerState = providerResource and GetResourceState(providerResource) or nil
    if providerResource == excludedResource
        or providerState ~= 'started' and providerState ~= 'starting' then
        return nil, Foundation.error('COMPAT_PROVIDER_DISABLED'), 0
    end
    local consumers = configuredLifecycleByProvider[provider]
    if type(consumers) ~= 'table' or #consumers < 1 then
        return nil, Foundation.error('COMPAT_PROVIDER_DISABLED'), 0
    end
    local lastError
    local activeCandidates = 0
    for _, consumer in ipairs(consumers) do
        local state = GetResourceState(consumer)
        if consumer ~= excludedResource
            and (state == 'started' or state == 'starting') then
            activeCandidates = activeCandidates + 1
            local authorization, authorizationError = resolveConsumer({
                consumer = consumer,
                capability = ('synex.compat.%s.read'):format(provider),
                operation = 'lifecycle.publish',
            }, provider)
            if authorization then
                return {
                    provider = provider,
                    consumer = consumer,
                    authorization = authorization,
                }, nil, activeCandidates
            end
            lastError = authorizationError
        end
    end
    if activeCandidates == 0 then
        return nil, Foundation.error('COMPAT_PROVIDER_DISABLED'), 0
    end
    return nil, lastError or Foundation.error('COMPAT_CONSUMER_DENIED'),
        activeCandidates
end

local function activeConfiguredConsumers(provider, excludedResource)
    local candidates = {}
    for resource, consumer in pairs(configuredConsumers) do
        if consumer.provider == provider and resource ~= excludedResource then
            local state = GetResourceState(resource)
            if state == 'started' or state == 'starting' then
                candidates[#candidates + 1] = resource
            end
        end
    end
    table.sort(candidates)
    return candidates
end

local function authorizeFirstConsumer(provider, candidates, operation)
    local suffix = OPERATION_SUFFIXES[operation]
    if not suffix then return nil, Foundation.error('COMPAT_API_UNSUPPORTED') end
    local lastError
    for _, consumer in ipairs(candidates) do
        local authorization, authorizationError = resolveConsumer({
            consumer = consumer,
            capability = ('synex.compat.%s.%s'):format(provider, suffix),
            operation = operation,
        }, provider)
        if authorization then
            return {
                provider = provider,
                consumer = consumer,
                authorization = authorization,
                operation = operation,
            }, nil
        end
        lastError = authorizationError
    end
    return nil, lastError or Foundation.error('COMPAT_PROVIDER_DISABLED')
end

local function activeClientProjectionCandidate(provider, candidates)
    local operations = CLIENT_ACCESS_OPERATIONS[provider]
    if type(operations) ~= 'table' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    if not operations.playerData then
        return nil, Foundation.error('COMPAT_PROVIDER_DISABLED')
    end
    return authorizeFirstConsumer(provider, candidates, operations.playerData)
end

local function authorizedClientConsumers(provider, candidates)
    local operations = CLIENT_ACCESS_OPERATIONS[provider]
    if type(operations) ~= 'table' then
        return nil, Foundation.error('COMPAT_API_UNSUPPORTED')
    end
    local access = { playerData = {}, callbacks = {} }
    local playerDataAccess = {}
    for _, kind in ipairs({ 'playerData', 'callbacks' }) do
        local operation = operations[kind]
        if operation ~= nil then
            local suffix = OPERATION_SUFFIXES[operation]
            if not suffix then return nil, Foundation.error('COMPAT_API_UNSUPPORTED') end
            for _, consumer in ipairs(candidates) do
                local authorized = resolveConsumer({
                    consumer = consumer,
                    capability = ('synex.compat.%s.%s'):format(provider, suffix),
                    operation = operation,
                }, provider)
                if authorized and (kind ~= 'callbacks'
                    or playerDataAccess[consumer] == true) then
                    local list = access[kind]
                    if #list >= LIMITS.clientConsumers then
                        return nil, failure('COMPAT_REGISTRY_LIMIT',
                            'The compatibility client consumer allowlist reached its bound.', true)
                    end
                    list[#list + 1] = consumer
                    if kind == 'playerData' then playerDataAccess[consumer] = true end
                end
            end
        end
    end
    return access, nil
end

exports('ShouldPublishLifecycle', function(request)
    local copied, provider, requestError = providerRequest(request, {
        provider = true, providerResource = true, excludedConsumer = true,
    }, { 'provider', 'providerResource' })
    if not copied then return nil, requestError end
    if copied.excludedConsumer ~= nil
        and not Foundation.isResourceName(copied.excludedConsumer) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local lifecycleRequested, requestedError, activeCandidates = activeLifecycleCandidate(
        provider, copied.excludedConsumer)
    local qbcOwner
    if provider == 'qb' or provider == 'qbx' then
        local qbCandidate, qbxCandidate
        if provider == 'qb' then
            qbCandidate = lifecycleRequested
            qbxCandidate = activeLifecycleCandidate('qbx', copied.excludedConsumer)
        else
            qbCandidate = activeLifecycleCandidate('qb', copied.excludedConsumer)
            qbxCandidate = lifecycleRequested
        end
        qbcOwner = qbCandidate and 'qb' or (qbxCandidate and 'qbx' or nil)
    end
    local activeConsumers = activeConfiguredConsumers(provider, copied.excludedConsumer)
    local requested = lifecycleRequested
    local providerState = GetResourceState(copied.providerResource)
    local providerActive = copied.providerResource ~= copied.excludedConsumer
        and (providerState == 'started' or providerState == 'starting')
    if not requested and providerActive then
        local projectionRequested, projectionError = activeClientProjectionCandidate(
            provider, activeConsumers)
        requested = projectionRequested
        requestedError = projectionError or requestedError
    end
    if requested then
        local clientAccess, clientAccessError = authorizedClientConsumers(
            provider, activeConsumers)
        if not clientAccess then return nil, clientAccessError end
        local publicationSurfaces = {}
        for _, definition in ipairs(PUBLICATION_SURFACES[provider] or {}) do
            local authorized = authorizeFirstConsumer(
                provider, activeConsumers, definition.operation)
            publicationSurfaces[definition.name] = authorized ~= nil
        end
        return {
            consumer = requested.consumer,
            traceId = requested.authorization.traceId,
            authorizationOperation = requested.operation or 'lifecycle.publish',
            families = {
                qbc = lifecycleRequested ~= nil and qbcOwner == provider,
                qbx = lifecycleRequested ~= nil and provider == 'qbx',
                esx = lifecycleRequested ~= nil and provider == 'esx',
            },
            surfaces = publicationSurfaces,
            clientAccess = clientAccess,
        }, nil
    end
    if qbcOwner ~= nil and qbcOwner ~= provider then
        return {
            standby = true,
            coveredFamilies = { qbc = true, qbx = false, esx = false },
        }, nil
    end
    if activeCandidates == 0 then
        return nil, Foundation.error('COMPAT_PROVIDER_DISABLED')
    end
    return nil, requestedError or Foundation.error('COMPAT_CONSUMER_DENIED')
end)

exports('RegisterCompatibilityAdapter', function(definition, implementation)
    local owner = readInvoker()
    if not owner then
        return nil, Foundation.error('COMPAT_CONSUMER_DENIED')
    end
    local api, apiError = getApi()
    if not api then return nil, apiError end
    local allowed, authorizationError = api.Capabilities.checkResource(
        owner, 'synex.compat.adapter.register', 'compatibility.adapter.register')
    if not allowed then return nil, authorizationError end
    return runtime.adapters:register(owner, 1, definition, implementation)
end)

exports('RegisterCompatibilityCatalog', function(definition, implementation)
    local owner = readInvoker()
    if not owner then return nil, Foundation.error('COMPAT_CONSUMER_DENIED') end
    local api, apiError = getApi()
    if not api then return nil, apiError end
    local allowed, authorizationError = api.Capabilities.checkResource(
        owner, 'synex.compat.catalog.register', 'compatibility.catalog.register')
    if not allowed then return nil, authorizationError end
    return runtime.catalogs:register(owner, 1, definition, implementation)
end)

exports('GetCompatibilityMatrix', function()
    return Foundation.copyDto(matrix, {
        root = 'object', maximumDepth = 8, maximumEntries = 1024,
        maximumBytes = 131072, maximumStringBytes = 4096,
        maximumArrayItems = 128, maximumObjectProperties = 512,
    })
end)

exports('GetCompatibilityConsumerStatus', function(resource)
    local invoker = readInvoker()
    if invoker ~= resource then
        return nil, Foundation.error('COMPAT_CONSUMER_DENIED')
    end
    local consumer = configuredConsumers[resource]
    if not consumer then return nil, Foundation.error('COMPAT_CONSUMER_DENIED') end
    return Foundation.copyDto(consumer), nil
end)

local ADAPTERS = {
    { framework = 'qb', resource = 'synex_bridge_qb' },
    { framework = 'qbx', resource = 'synex_bridge_qbx' },
    { framework = 'esx', resource = 'synex_bridge_esx' },
}

local function denseArray(value, maximum)
    if type(value) ~= 'table' or #value > maximum then return false end
    local count, maximumIndex = 0, 0
    for key in pairs(value) do
        if not Foundation.isSafeInteger(key, 1, maximum) then return false end
        count, maximumIndex = count + 1, math.max(maximumIndex, key)
    end
    return count == maximumIndex and count == #value
end

local USAGE_TERMINAL_OUTCOMES = {
    'success', 'denied', 'unsupported', 'error', 'timeout', 'rate_limited',
}

local function validateUsageMetrics(entry)
    if type(entry.outcomes) ~= 'table' or getmetatable(entry.outcomes) ~= nil
        or type(entry.latency) ~= 'table' or getmetatable(entry.latency) ~= nil then
        return false
    end
    local allowedOutcomeKeys, outcomeKeyCount = { deprecated = true }, 0
    local terminalCalls = 0
    for _, outcome in ipairs(USAGE_TERMINAL_OUTCOMES) do
        allowedOutcomeKeys[outcome] = true
        local value = entry.outcomes[outcome]
        if not Foundation.isSafeInteger(value, 0, entry.calls) then return false end
        terminalCalls = Foundation.saturatingAdd(terminalCalls, value)
    end
    if not Foundation.isSafeInteger(
        entry.outcomes.deprecated, 0, entry.calls) then return false end
    for key in pairs(entry.outcomes) do
        if type(key) ~= 'string' or not allowedOutcomeKeys[key] then return false end
        outcomeKeyCount = outcomeKeyCount + 1
    end
    if outcomeKeyCount ~= #USAGE_TERMINAL_OUTCOMES + 1
        or terminalCalls ~= entry.calls
        or entry.outcomes.deprecated ~= entry.calls then return false end

    local latencyKeyCount = 0
    for key in pairs(entry.latency) do
        if key ~= 'samples' and key ~= 'totalMs' and key ~= 'maximumMs' then
            return false
        end
        latencyKeyCount = latencyKeyCount + 1
    end
    if latencyKeyCount ~= 3
        or entry.latency.samples ~= entry.calls
        or not Foundation.isSafeInteger(entry.latency.samples, 1, LIMITS.safeInteger)
        or not Foundation.isSafeInteger(entry.latency.totalMs, 0, LIMITS.safeInteger)
        or not Foundation.isSafeInteger(
            entry.latency.maximumMs, 0, entry.latency.totalMs) then
        return false
    end
    return true
end

local function validateAdapterHealth(health)
    if type(health) ~= 'table' or getmetatable(health) ~= nil
        or (health.status ~= 'READY' and health.status ~= 'DEGRADED')
        or not denseArray(health.reasons, 4)
        or not Foundation.isSafeInteger(health.callbackPending, 0, 512)
        or health.callbackCapacity ~= 512
        or not Foundation.isSafeInteger(health.callbackRegistrations, 0, 256)
        or health.callbackRegistrationCapacity ~= 256
        or not Foundation.isSafeInteger(health.projectionEntries, 0, 256)
        or health.projectionCapacity ~= 256
        or not Foundation.isSafeInteger(health.usageEntries, 0, LIMITS.usageEntries)
        or health.usageCapacity ~= LIMITS.usageEntries then
        return false
    end
    local allowed = {
        status = true, reasons = true, callbackPending = true,
        callbackCapacity = true, callbackRegistrations = true,
        callbackRegistrationCapacity = true, projectionEntries = true,
        projectionCapacity = true, usageEntries = true, usageCapacity = true,
    }
    local keys, seenReasons = 0, {}
    for key in pairs(health) do
        if type(key) ~= 'string' or not allowed[key] then return false end
        keys = keys + 1
    end
    if keys ~= 10 then return false end
    for _, reason in ipairs(health.reasons) do
        if not Foundation.isIdentifier(reason) or seenReasons[reason] then return false end
        seenReasons[reason] = true
    end
    return true
end

local function readAdapterUsage(adapter)
    local state = GetResourceState(adapter.resource)
    if state ~= 'started' and state ~= 'starting' then
        return nil, 'ADAPTER_NOT_STARTED', state
    end
    local called, bundle = pcall(function()
        return exports[adapter.resource]:GetControlCompatibilityUsage()
    end)
    if not called or type(bundle) ~= 'table' or bundle.schemaVersion ~= 1
        or type(bundle.truncated) ~= 'boolean'
        or not denseArray(bundle.snapshots, LIMITS.adapterSnapshots)
        or #bundle.snapshots ~= 1 then
        return nil, 'USAGE_SNAPSHOT_UNAVAILABLE', state
    end
    local snapshot = bundle.snapshots[1]
    if type(snapshot) ~= 'table' or snapshot.framework ~= adapter.framework
        or snapshot.deprecated ~= true or type(snapshot.truncated) ~= 'boolean'
        or not denseArray(snapshot.entries, LIMITS.usageEntries)
        or not validateAdapterHealth(snapshot.health) then
        return nil, 'USAGE_SNAPSHOT_INVALID', state
    end
    local items, calls = {}, 0
    local outcomes = {
        success = 0, denied = 0, unsupported = 0, deprecated = 0,
        error = 0, timeout = 0, rate_limited = 0,
    }
    local latency = { samples = 0, totalMs = 0, maximumMs = 0 }
    for index, entry in ipairs(snapshot.entries) do
        if type(entry) ~= 'table'
            or not Foundation.isResourceName(entry.resource)
            or not Foundation.isIdentifier(entry.operation)
            or not Foundation.isSafeInteger(entry.calls, 1, LIMITS.safeInteger)
            or not Foundation.isSafeInteger(entry.firstSeenMs, 0, LIMITS.safeInteger)
            or not Foundation.isSafeInteger(entry.lastSeenMs,
                entry.firstSeenMs, LIMITS.safeInteger)
            or not validateUsageMetrics(entry) then
            return nil, 'USAGE_SNAPSHOT_INVALID', state
        end
        calls = Foundation.saturatingAdd(calls, entry.calls)
        for outcome in pairs(outcomes) do
            outcomes[outcome] = Foundation.saturatingAdd(
                outcomes[outcome], entry.outcomes[outcome])
        end
        latency.samples = Foundation.saturatingAdd(
            latency.samples, entry.latency.samples)
        latency.totalMs = Foundation.saturatingAdd(
            latency.totalMs, entry.latency.totalMs)
        latency.maximumMs = math.max(
            latency.maximumMs, entry.latency.maximumMs)
        items[index] = {
            id = ('%s:%03d:%s:%s'):format(
                adapter.framework, index, entry.resource, entry.operation),
            framework = adapter.framework,
            adapterResource = adapter.resource,
            consumerResource = entry.resource,
            operation = entry.operation,
            calls = entry.calls,
            firstSeenMs = entry.firstSeenMs,
            lastSeenMs = entry.lastSeenMs,
            deprecated = true,
            success = entry.outcomes.success,
            denied = entry.outcomes.denied,
            unsupported = entry.outcomes.unsupported,
            deprecatedCalls = entry.outcomes.deprecated,
            errors = entry.outcomes.error,
            timeouts = entry.outcomes.timeout,
            rateLimited = entry.outcomes.rate_limited,
            latency = {
                samples = entry.latency.samples,
                totalMs = entry.latency.totalMs,
                maximumMs = entry.latency.maximumMs,
                averageMs = math.floor(entry.latency.totalMs / entry.latency.samples),
            },
        }
    end
    return {
        available = true, state = state, calls = calls, entries = #items,
        truncated = snapshot.truncated or bundle.truncated, items = items,
        status = snapshot.health.status,
        reasons = Foundation.copyDto(snapshot.health.reasons),
        health = Foundation.copyDto(snapshot.health),
        outcomes = outcomes,
        latency = latency,
    }, nil, state
end

local function readUsage()
    local result = {
        items = {}, adapters = {}, totalCalls = 0,
        availableAdapters = 0, unavailableAdapters = 0, degradedAdapters = 0,
        totalSuccess = 0, totalDenied = 0, totalUnsupported = 0,
        totalDeprecated = 0, totalErrors = 0, totalTimeouts = 0,
        totalRateLimited = 0, totalLatencyMs = 0, maximumLatencyMs = 0,
        truncated = false,
    }
    for _, adapter in ipairs(ADAPTERS) do
        local snapshot, errorCode, state = readAdapterUsage(adapter)
        if snapshot then
            result.availableAdapters = result.availableAdapters + 1
            result.totalCalls = Foundation.saturatingAdd(result.totalCalls, snapshot.calls)
            result.totalSuccess = Foundation.saturatingAdd(
                result.totalSuccess, snapshot.outcomes.success)
            result.totalDenied = Foundation.saturatingAdd(
                result.totalDenied, snapshot.outcomes.denied)
            result.totalUnsupported = Foundation.saturatingAdd(
                result.totalUnsupported, snapshot.outcomes.unsupported)
            result.totalDeprecated = Foundation.saturatingAdd(
                result.totalDeprecated, snapshot.outcomes.deprecated)
            result.totalErrors = Foundation.saturatingAdd(
                result.totalErrors, snapshot.outcomes.error)
            result.totalTimeouts = Foundation.saturatingAdd(
                result.totalTimeouts, snapshot.outcomes.timeout)
            result.totalRateLimited = Foundation.saturatingAdd(
                result.totalRateLimited, snapshot.outcomes.rate_limited)
            result.totalLatencyMs = Foundation.saturatingAdd(
                result.totalLatencyMs, snapshot.latency.totalMs)
            result.maximumLatencyMs = math.max(
                result.maximumLatencyMs, snapshot.latency.maximumMs)
            if snapshot.status == 'DEGRADED' then
                result.degradedAdapters = result.degradedAdapters + 1
            end
            result.truncated = result.truncated or snapshot.truncated
            result.adapters[adapter.framework] = {
                available = true, state = snapshot.state, calls = snapshot.calls,
                entries = snapshot.entries, truncated = snapshot.truncated,
                status = snapshot.status, reasons = snapshot.reasons,
                outcomes = snapshot.outcomes, latency = snapshot.latency,
                health = snapshot.health,
            }
            for _, item in ipairs(snapshot.items) do
                if #result.items >= LIMITS.usageEntries * #ADAPTERS then
                    result.truncated = true
                    break
                end
                result.items[#result.items + 1] = item
            end
        else
            result.unavailableAdapters = result.unavailableAdapters + 1
            result.adapters[adapter.framework] = {
                available = false, state = state, calls = 0, entries = 0,
                truncated = false, code = errorCode, status = 'UNAVAILABLE',
                reasons = { errorCode },
            }
        end
    end
    table.sort(result.items, function(left, right) return left.id < right.id end)
    return result, nil
end

local function readCatalogUsage()
    local snapshot, snapshotError = runtime.catalogTelemetry:snapshot()
    if not snapshot then return nil, snapshotError end
    local result = {
        items = {}, registeredCatalogs = runtime.catalogs:count(),
        totalCalls = 0, totalSuccess = 0, totalDenied = 0,
        totalUnsupported = 0, totalDeprecated = 0, totalErrors = 0,
        totalTimeouts = 0, totalRateLimited = 0, totalLatencyMs = 0,
        maximumLatencyMs = 0, truncated = snapshot.truncated == true,
    }
    for _, series in ipairs(snapshot.series) do
        local provider, action = series.surface:match('^catalog%.([a-z]+)%.([a-z]+)$')
        local consumer = configuredConsumers[series.owner]
        if PROVIDER_BY_RESOURCE[RESOURCE_BY_PROVIDER[provider]] == provider
            and (action == 'resolve' or action == 'invoke')
            and type(consumer) == 'table' and consumer.provider == provider then
            local outcomes = type(series.outcomes) == 'table' and series.outcomes or {}
            local latency = type(series.latency) == 'table' and series.latency or {}
            local item = {
                id = ('catalog:%s:%s:%s'):format(provider, series.owner, action),
                provider = provider,
                consumerResource = series.owner,
                operation = 'catalog.' .. action,
                calls = series.count,
                success = outcomes.success or 0,
                denied = outcomes.denied or 0,
                unsupported = outcomes.unsupported or 0,
                deprecatedCalls = outcomes.deprecated or 0,
                errors = outcomes.error or 0,
                timeouts = outcomes.timeout or 0,
                rateLimited = outcomes.rate_limited or 0,
                latency = {
                    samples = series.count,
                    totalMs = latency.totalMs or 0,
                    maximumMs = latency.maximumMs or 0,
                    averageMs = series.count > 0
                        and math.floor((latency.totalMs or 0) / series.count) or 0,
                },
            }
            if #result.items >= LIMITS.usageEntries then
                result.truncated = true
                break
            end
            result.items[#result.items + 1] = item
            result.totalCalls = Foundation.saturatingAdd(result.totalCalls, item.calls)
            result.totalSuccess = Foundation.saturatingAdd(result.totalSuccess, item.success)
            result.totalDenied = Foundation.saturatingAdd(result.totalDenied, item.denied)
            result.totalUnsupported = Foundation.saturatingAdd(
                result.totalUnsupported, item.unsupported)
            result.totalDeprecated = Foundation.saturatingAdd(
                result.totalDeprecated, item.deprecatedCalls)
            result.totalErrors = Foundation.saturatingAdd(result.totalErrors, item.errors)
            result.totalTimeouts = Foundation.saturatingAdd(
                result.totalTimeouts, item.timeouts)
            result.totalRateLimited = Foundation.saturatingAdd(
                result.totalRateLimited, item.rateLimited)
            result.totalLatencyMs = Foundation.saturatingAdd(
                result.totalLatencyMs, item.latency.totalMs)
            result.maximumLatencyMs = math.max(
                result.maximumLatencyMs, item.latency.maximumMs)
        end
    end
    table.sort(result.items, function(left, right) return left.id < right.id end)
    return result, nil
end

local controlProvider = assert(SynexBridgeControlProvider,
    'synex_bridge control provider module is unavailable').create({
    matrix = matrix, readUsage = readUsage, readCatalogUsage = readCatalogUsage,
})

local function bindControlProvider()
    if controlProviderBound then return true end
    local api, apiError = getApi()
    if not api then return nil, apiError end
    local metadata, registrationError = controlProvider:register(api)
    if not metadata then return nil, registrationError end
    controlProviderBound = true
    return true, nil
end

local function bindIdentityLifecycle()
    if identityLifecycleBound then return true end
    local api, apiError = getApi()
    if not api then return nil, apiError end
    if type(api.Characters) ~= 'table'
        or not callable(api.Characters.registerLifecycleParticipant) then
        return nil, failure('SYNEX_UNAVAILABLE',
            'The character lifecycle registry is unavailable.', true)
    end
    local token, registrationError = api.Characters.registerLifecycleParticipant({
        name = 'synex_bridge.persistence',
        priority = 200,
        required = true,
        timeoutMs = 5000,
        prepare = function() return {} end,
        deletePreflight = function() return { action = 'delete' } end,
        deleteCommit = function(context)
            local plan = type(context) == 'table' and context.plan or nil
            local characterId = type(plan) == 'table' and plan.characterId or nil
            return identityStore:deleteCharacter(context.planId, characterId)
        end,
    })
    if not token then return nil, registrationError end
    identityLifecycleBound = true
    return true, nil
end

local initialControlReady = bindControlProvider()
local initialLifecycleReady = bindIdentityLifecycle()
if not initialControlReady or not initialLifecycleReady then
    coreRebindGeneration = coreRebindGeneration + 1
    local generation, attempts = coreRebindGeneration, 0
    local function initialRebind()
        if generation ~= coreRebindGeneration then return end
        attempts = attempts + 1
        local controlReady = bindControlProvider()
        local lifecycleReady = bindIdentityLifecycle()
        if controlReady and lifecycleReady or attempts >= 20 then return end
        SetTimeout(250, initialRebind)
    end
    SetTimeout(250, initialRebind)
end

AddEventHandler('onResourceStart', function(startedResource)
    if startedResource ~= 'synex_core' then return end
    coreRebindGeneration = coreRebindGeneration + 1
    local generation = coreRebindGeneration
    coreApi, controlProviderBound, identityLifecycleBound = nil, false, false
    local attempts = 0
    local function rebind()
        if generation ~= coreRebindGeneration then return end
        attempts = attempts + 1
        local controlReady = bindControlProvider()
        local lifecycleReady = bindIdentityLifecycle()
        if controlReady and lifecycleReady or attempts >= 20 then return end
        SetTimeout(250, rebind)
    end
    SetTimeout(0, rebind)
end)

AddEventHandler('onResourceStop', function(stoppedResource)
    if stoppedResource == 'synex_core' then
        coreRebindGeneration = coreRebindGeneration + 1
        coreApi, controlProviderBound, identityLifecycleBound = nil, false, false
        return
    end
    runtime:cleanup(stoppedResource, CONFIG_EPOCH)
end)
