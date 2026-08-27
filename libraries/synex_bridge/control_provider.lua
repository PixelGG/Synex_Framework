SynexBridgeControlProvider = {}

local OPERATIONS = { 'summary', 'health', 'list', 'findings' }
local VIEWS = {
    {
        id = 'overview', label = 'Compatibility overview', operation = 'summary',
        presentation = 'key-value', accessClass = 'general', order = 10,
        description = 'Current bridge compatibility and live legacy-usage evidence.',
    },
    {
        id = 'health', label = 'Compatibility health', operation = 'health',
        presentation = 'key-value', accessClass = 'general', order = 15,
        description = 'Current compatibility lifecycle and adapter evidence availability.',
    },
    {
        id = 'compatibility_matrix', label = 'Compatibility matrix', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 20,
        description = 'Bounded capabilities and explicit unsupported legacy surfaces.',
    },
    {
        id = 'legacy_usage', label = 'Legacy usage', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 30,
        description = 'Live bounded usage reported by active compatibility adapters.',
    },
    {
        id = 'catalog_usage', label = 'Catalog usage', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 35,
        description = 'Live bounded catalog resolution and invocation evidence.',
    },
    {
        id = 'consumers', label = 'Compatibility consumers', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 40,
        description = 'Configured compatibility consumers without runtime payload data.',
    },
    {
        id = 'profiles', label = 'Compatibility profiles', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 45,
        description = 'Configured profiles and their bounded compatibility policy metadata.',
    },
    {
        id = 'adapters', label = 'Compatibility adapters', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 50,
        description = 'Live adapter availability and bounded health counters.',
    },
    {
        id = 'mappings', label = 'Compatibility mappings', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 55,
        description = 'Configured mapping metadata with identity values redacted.',
    },
    {
        id = 'unsupported_deprecated', label = 'Unsupported and deprecated', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 60,
        description = 'Catalog surfaces explicitly marked unsupported or deprecated.',
    },
    {
        id = 'errors', label = 'Compatibility errors', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 70,
        description = 'Bounded non-success outcome counters from live adapter telemetry.',
    },
    {
        id = 'latency', label = 'Compatibility latency', operation = 'list',
        presentation = 'table', accessClass = 'general', order = 80,
        description = 'Bounded latency counters from live compatibility operations.',
    },
    {
        id = 'migration_readiness', label = 'Migration readiness', operation = 'findings',
        presentation = 'findings', accessClass = 'general', order = 90,
        description = 'Evidence-only migration findings for each compatibility adapter.',
    },
}

local FRAMEWORKS = { 'qb', 'qbx', 'esx' }
local CONFIGURATION_BYTES = 524288
local CATALOG_ITEMS = 512

local function failure(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
end

local function callable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metadata = getmetatable(value)
    if type(metadata) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable then metadata = rawMetadata end
    end
    return type(metadata) == 'table' and type(rawget(metadata, '__call')) == 'function'
end

local function boundedString(value, maximum)
    return type(value) == 'string' and #value >= 1 and #value <= maximum
        and value:find('[%z\1-\31\127]') == nil
end

local function readCatalogDocument(path, kind)
    if type(LoadResourceFile) ~= 'function' or type(GetCurrentResourceName) ~= 'function'
        or type(json) ~= 'table' or not callable(json.decode) then return nil end
    local named, resource = pcall(GetCurrentResourceName)
    if not named or not boundedString(resource, 64) then return nil end
    local loaded, raw = pcall(LoadResourceFile, resource, path)
    if not loaded or type(raw) ~= 'string' or #raw < 2
        or #raw > CONFIGURATION_BYTES then return nil end
    local decoded, document = pcall(json.decode, raw)
    if not decoded or type(document) ~= 'table' or document.schema ~= 1
        or document.kind ~= kind then return nil end
    return document
end

local function appendBounded(items, value)
    if #items >= CATALOG_ITEMS then return false end
    items[#items + 1] = value
    return true
end

local function sortItems(items)
    table.sort(items, function(left, right) return left.id < right.id end)
    return items
end

local function emptyObject(value)
    return value == nil or type(value) == 'table' and next(value) == nil
end

local function validLimit(value)
    return value == nil or type(value) == 'number' and math.type(value) == 'integer'
        and value >= 1 and value <= 25
end

local function validCursor(value)
    return value == nil or type(value) == 'string' and #value >= 1 and #value <= 256
        and value:find('[%z\1-\31\127]') == nil
end

local function validateRequest(request, allowed, required)
    if type(request) ~= 'table' or getmetatable(request) ~= nil then
        return nil, failure('VALIDATION_FAILED', 'The compatibility request must be a plain object.')
    end
    for key in pairs(request) do
        if type(key) ~= 'string' or not allowed[key] then
            return nil, failure('VALIDATION_FAILED', 'The compatibility request contains an unknown field.')
        end
    end
    for _, key in ipairs(required or {}) do
        if request[key] == nil then
            return nil, failure('VALIDATION_FAILED', 'The compatibility request is missing a required field.')
        end
    end
    return request, nil
end

local function page(items, cursor, limit)
    local startIndex = 1
    if cursor ~= nil then
        local matched = false
        for index, item in ipairs(items) do
            if item.id == cursor then
                startIndex = index + 1
                matched = true
                break
            end
        end
        if not matched then
            return nil, failure('INVALID_CURSOR', 'The compatibility cursor is stale or invalid.')
        end
    end
    local selected = {}
    for index = startIndex, math.min(#items, startIndex + limit) do
        selected[#selected + 1] = items[index]
    end
    local hasMore = #selected > limit
    if hasMore then selected[#selected] = nil end
    return {
        items = selected,
        nextCursor = hasMore and selected[#selected] and selected[#selected].id or nil,
        hasMore = hasMore,
        truncated = hasMore,
    }, nil
end

function SynexBridgeControlProvider.create(options)
    assert(type(options) == 'table', 'bridge control provider options are required')
    local matrix = assert(options.matrix, 'bridge compatibility matrix is required')
    local readUsage = assert(options.readUsage, 'bridge usage reader is required')
    local readCatalogUsage = assert(
        options.readCatalogUsage, 'bridge catalog usage reader is required')

    local matrixItems = {}
    for _, framework in ipairs(FRAMEWORKS) do
        local surfaces = assert(matrix[framework], 'bridge framework matrix is required')
        local keys = {}
        for key in pairs(surfaces) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, surface in ipairs(keys) do
            matrixItems[#matrixItems + 1] = {
                id = framework .. ':' .. surface,
                framework = framework,
                surface = surface,
                support = surfaces[surface],
                deprecated = matrix.deprecated == true,
            }
        end
    end
    for index, surface in ipairs(matrix.unsupported or {}) do
        matrixItems[#matrixItems + 1] = {
            id = ('unsupported:%02d'):format(index),
            framework = 'all',
            surface = surface,
            support = 'unsupported',
            deprecated = matrix.deprecated == true,
        }
    end

    local profileDocument = readCatalogDocument(
        'compatibility/profiles.json', 'synex-compatibility-profiles')
    local consumerDocument = readCatalogDocument(
        'compatibility/consumers.json', 'synex-compatibility-consumers')
    local mappingDocument = readCatalogDocument(
        'compatibility/mappings.json', 'synex-compatibility-mappings')
    local profileItems, consumerItems, mappingItems = {}, {}, {}
    local catalogTruncated = { profiles = false, consumers = false, mappings = false }

    if profileDocument and type(profileDocument.profiles) == 'table'
        and #profileDocument.profiles <= 128 then
        for index, profile in ipairs(profileDocument.profiles) do
            if type(profile) == 'table' and boundedString(profile.id, 96)
                and boundedString(profile.version, 64) and boundedString(profile.provider, 8)
                and boundedString(profile.mode, 16) and boundedString(profile.status, 16)
                and boundedString(profile.failurePolicy, 16) then
                local script = type(profile.script) == 'table' and profile.script or {}
                local accepted = appendBounded(profileItems, {
                    id = ('profile:%03d:%s'):format(index, profile.id),
                    profileId = profile.id,
                    version = profile.version,
                    provider = profile.provider,
                    mode = profile.mode,
                    status = profile.status,
                    failurePolicy = profile.failurePolicy,
                    providerVersion = boundedString(profile.providerVersion, 64)
                        and profile.providerVersion or nil,
                    targetFrameworkApiRange = boundedString(
                        profile.targetFrameworkApiRange, 64)
                        and profile.targetFrameworkApiRange or nil,
                    script = boundedString(script.name, 96) and script.name or nil,
                    testedVersion = boundedString(script.testedVersion, 64)
                        and script.testedVersion or nil,
                    requiredSurfaces = type(profile.requiredSurfaces) == 'table'
                        and math.min(#profile.requiredSurfaces, 128) or 0,
                    requiredAdapters = type(profile.requiredAdapters) == 'table'
                        and math.min(#profile.requiredAdapters, 32) or 0,
                    requiredCatalogs = type(profile.requiredCatalogs) == 'table'
                        and math.min(#profile.requiredCatalogs, 32) or 0,
                })
                if not accepted then catalogTruncated.profiles = true break end
            end
        end
    else
        profileDocument = nil
    end

    if consumerDocument and type(consumerDocument.consumers) == 'table'
        and #consumerDocument.consumers <= 512 then
        for index, consumer in ipairs(consumerDocument.consumers) do
            if type(consumer) == 'table' and boundedString(consumer.resource, 64)
                and boundedString(consumer.provider, 8)
                and boundedString(consumer.failurePolicy, 16)
                and type(consumer.enabled) == 'boolean' then
                local accepted = appendBounded(consumerItems, {
                    id = ('consumer:%03d:%s'):format(index, consumer.resource),
                    resource = consumer.resource,
                    provider = consumer.provider,
                    profileId = boundedString(consumer.profileId, 96)
                        and consumer.profileId or nil,
                    mode = boundedString(consumer.mode, 16) and consumer.mode
                        or consumerDocument.defaultMode,
                    failurePolicy = consumer.failurePolicy,
                    enabled = consumer.enabled,
                })
                if not accepted then catalogTruncated.consumers = true break end
            end
        end
    else
        consumerDocument = nil
    end

    if mappingDocument then
        for _, category in ipairs({
            'identity', 'accounts', 'groups', 'metadata', 'permissions',
        }) do
            local mappings = mappingDocument[category]
            if category == 'permissions' and mappings == nil then mappings = {} end
            if type(mappings) ~= 'table' or #mappings > 512 then
                mappingDocument = nil
                mappingItems = {}
                break
            end
            for index, mapping in ipairs(mappings) do
                if type(mapping) == 'table' and boundedString(mapping.id, 96) then
                    local item = {
                        id = ('mapping:%s:%03d:%s'):format(category, index, mapping.id),
                        mappingId = mapping.id,
                        category = category,
                        provider = boundedString(mapping.provider, 8) and mapping.provider or nil,
                        status = boundedString(mapping.status, 16) and mapping.status or 'UNKNOWN',
                        identityValuesRedacted = category == 'identity',
                    }
                    if category == 'accounts' then
                        local currencyCode = boundedString(mapping.currencyCode, 16)
                            and mapping.currencyCode or nil
                        local accountKey = boundedString(mapping.accountKey, 64)
                            and mapping.accountKey or nil
                        local accountRole = mapping.accountRole == 'asset'
                            and mapping.accountRole or nil
                        local minorUnit = type(mapping.minorUnit) == 'number'
                            and math.type(mapping.minorUnit) == 'integer'
                            and mapping.minorUnit >= 0 and mapping.minorUnit <= 6
                            and mapping.minorUnit or nil
                        if not boundedString(mapping.alias, 32) or not currencyCode
                            or not accountKey or not accountRole or minorUnit == nil then
                            mappingDocument = nil
                            mappingItems = {}
                            break
                        end
                        item.source = mapping.alias
                        item.currencyCode = currencyCode
                        item.accountKey = accountKey
                        item.accountRole = accountRole
                        item.minorUnit = minorUnit
                        item.target = table.concat({ currencyCode, accountKey,
                            accountRole, tostring(minorUnit) }, ':')
                    elseif category == 'groups' then
                        item.sourceType = boundedString(mapping.legacyType, 64)
                            and mapping.legacyType or nil
                        item.targetType = boundedString(mapping.nativeGroupType, 64)
                            and mapping.nativeGroupType or nil
                    elseif category == 'metadata' then
                        item.source = boundedString(mapping.key, 128) and mapping.key or nil
                        item.target = boundedString(mapping.storageKey, 128)
                            and mapping.storageKey or nil
                    elseif category == 'permissions' then
                        item.source = boundedString(mapping.legacyGroup, 64)
                            and mapping.legacyGroup or nil
                        item.target = boundedString(mapping.nativePermission, 128)
                            and mapping.nativePermission or nil
                        item.priority = type(mapping.priority) == 'number'
                            and math.type(mapping.priority) == 'integer'
                            and mapping.priority >= 0 and mapping.priority <= 65535
                            and mapping.priority or nil
                        item.fallback = mapping.fallback == true
                        if not item.source or not item.target or item.priority == nil then
                            mappingDocument = nil
                            mappingItems = {}
                            break
                        end
                    end
                    if not appendBounded(mappingItems, item) then
                        catalogTruncated.mappings = true break
                    end
                end
            end
            if not mappingDocument then break end
            if catalogTruncated.mappings then break end
        end
    end

    sortItems(profileItems)
    sortItems(consumerItems)
    sortItems(mappingItems)
    local unsupportedDeprecatedItems = {}
    for _, item in ipairs(matrixItems) do
        local support = type(item.support) == 'string' and item.support:lower() or 'unknown'
        if support == 'unsupported' or item.deprecated == true then
            unsupportedDeprecatedItems[#unsupportedDeprecatedItems + 1] = {
                id = 'lifecycle:' .. item.id,
                framework = item.framework,
                surface = item.surface,
                support = item.support,
                unsupported = support == 'unsupported',
                deprecated = item.deprecated == true,
            }
        end
    end
    sortItems(unsupportedDeprecatedItems)

    local handlers = {}

    handlers.summary = function(request)
        local candidate, requestError = validateRequest(
            request, { view = true, limit = true }, { 'view' })
        if not candidate then return nil, requestError end
        if candidate.view ~= 'overview' or not validLimit(candidate.limit) then
            return nil, failure('VALIDATION_FAILED', 'The compatibility overview request is invalid.')
        end
        local usage, usageError = readUsage()
        local catalogUsage, catalogUsageError = readCatalogUsage()
        return {
            status = matrix.deprecated == true and 'WARNING' or 'HEALTHY',
            lifecycle = matrix.deprecated == true and 'DEPRECATED' or 'ACTIVE',
            apiVersion = matrix.apiVersion,
            preferredPath = matrix.preferredPath,
            isolation = matrix.isolation,
            frameworks = #FRAMEWORKS,
            compatibilityEntries = #matrixItems,
            unsupportedSurfaces = #(matrix.unsupported or {}),
            catalogStatus = profileDocument and consumerDocument and mappingDocument
                and 'AVAILABLE' or 'UNAVAILABLE',
            configuredProfiles = #profileItems,
            configuredConsumers = #consumerItems,
            configuredMappings = #mappingItems,
            catalogTruncated = catalogTruncated.profiles
                or catalogTruncated.consumers or catalogTruncated.mappings,
            usageStatus = usage and usage.availableAdapters > 0
                and (usage.unavailableAdapters > 0 and 'PARTIAL' or 'AVAILABLE') or 'UNAVAILABLE',
            availableAdapters = usage and usage.availableAdapters or 0,
            unavailableAdapters = usage and usage.unavailableAdapters or #FRAMEWORKS,
            degradedAdapters = usage and usage.degradedAdapters or 0,
            observedLegacyEntries = usage and #usage.items or 0,
            observedLegacyCalls = usage and usage.totalCalls or 0,
            observedSuccess = usage and usage.totalSuccess or 0,
            observedDenied = usage and usage.totalDenied or 0,
            observedUnsupported = usage and usage.totalUnsupported or 0,
            observedDeprecated = usage and usage.totalDeprecated or 0,
            observedErrors = usage and usage.totalErrors or 0,
            observedTimeouts = usage and usage.totalTimeouts or 0,
            observedRateLimited = usage and usage.totalRateLimited or 0,
            averageLatencyMs = usage and usage.totalCalls > 0
                and math.floor((usage.totalLatencyMs or 0) / usage.totalCalls) or 0,
            maximumLatencyMs = usage and usage.maximumLatencyMs or 0,
            providers = usage and usage.adapters or {},
            catalogUsageStatus = catalogUsage and 'AVAILABLE' or 'UNAVAILABLE',
            registeredRuntimeCatalogs = catalogUsage
                and catalogUsage.registeredCatalogs or 0,
            observedCatalogEntries = catalogUsage and #catalogUsage.items or 0,
            observedCatalogCalls = catalogUsage and catalogUsage.totalCalls or 0,
            observedCatalogDenied = catalogUsage and catalogUsage.totalDenied or 0,
            observedCatalogUnsupported = catalogUsage
                and catalogUsage.totalUnsupported or 0,
            observedCatalogErrors = catalogUsage and catalogUsage.totalErrors or 0,
            catalogUsageFailureCode = not catalogUsage
                and type(catalogUsageError) == 'table' and catalogUsageError.code or nil,
            usageFailureCode = not usage and type(usageError) == 'table'
                and usageError.code or nil,
        }, nil
    end

    handlers.health = function(request)
        local candidate, requestError = validateRequest(
            request, { view = true, limit = true }, { 'view' })
        if not candidate then return nil, requestError end
        if candidate.view ~= 'health' or not validLimit(candidate.limit) then
            return nil, failure('VALIDATION_FAILED',
                'The compatibility health request is invalid.')
        end
        local summary, summaryError = handlers.summary({
            view = 'overview', limit = candidate.limit,
        })
        if not summary then return nil, summaryError end
        return {
            status = summary.status,
            lifecycle = summary.lifecycle,
            catalogStatus = summary.catalogStatus,
            catalogTruncated = summary.catalogTruncated,
            usageStatus = summary.usageStatus,
            availableAdapters = summary.availableAdapters,
            unavailableAdapters = summary.unavailableAdapters,
            degradedAdapters = summary.degradedAdapters,
            observedLegacyCalls = summary.observedLegacyCalls,
            observedDenied = summary.observedDenied,
            observedUnsupported = summary.observedUnsupported,
            observedErrors = summary.observedErrors,
            observedTimeouts = summary.observedTimeouts,
            observedRateLimited = summary.observedRateLimited,
            averageLatencyMs = summary.averageLatencyMs,
            maximumLatencyMs = summary.maximumLatencyMs,
            providers = summary.providers,
            catalogUsageStatus = summary.catalogUsageStatus,
            registeredRuntimeCatalogs = summary.registeredRuntimeCatalogs,
            observedCatalogCalls = summary.observedCatalogCalls,
            observedCatalogDenied = summary.observedCatalogDenied,
            observedCatalogUnsupported = summary.observedCatalogUnsupported,
            observedCatalogErrors = summary.observedCatalogErrors,
            catalogUsageFailureCode = summary.catalogUsageFailureCode,
            usageFailureCode = summary.usageFailureCode,
        }, nil
    end

    handlers.list = function(request)
        local candidate, requestError = validateRequest(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' })
        if not candidate then return nil, requestError end
        if not validLimit(candidate.limit) or not validCursor(candidate.cursor)
            or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
            return nil, failure('VALIDATION_FAILED', 'The compatibility list request is invalid.')
        end
        local limit = candidate.limit or 20
        if candidate.view == 'compatibility_matrix' then
            return page(matrixItems, candidate.cursor, limit)
        end
        local staticItems, staticAvailable, staticTruncated
        if candidate.view == 'consumers' then
            staticItems, staticAvailable = consumerItems, consumerDocument ~= nil
            staticTruncated = catalogTruncated.consumers
        elseif candidate.view == 'profiles' then
            staticItems, staticAvailable = profileItems, profileDocument ~= nil
            staticTruncated = catalogTruncated.profiles
        elseif candidate.view == 'mappings' then
            staticItems, staticAvailable = mappingItems, mappingDocument ~= nil
            staticTruncated = catalogTruncated.mappings
        elseif candidate.view == 'unsupported_deprecated' then
            staticItems, staticAvailable, staticTruncated = unsupportedDeprecatedItems, true, false
        end
        if staticItems then
            if not staticAvailable then
                return nil, failure('VIEW_UNAVAILABLE',
                    'The checked-in compatibility catalog view is unavailable.', true)
            end
            local result, pageError = page(staticItems, candidate.cursor, limit)
            if not result then return nil, pageError end
            result.evidenceTruncated = staticTruncated == true
            return result, nil
        end
        if candidate.view == 'catalog_usage' then
            local catalogUsage, catalogUsageError = readCatalogUsage()
            if not catalogUsage then
                return nil, type(catalogUsageError) == 'table' and catalogUsageError
                    or failure('VIEW_UNAVAILABLE',
                        'Live compatibility catalog usage is unavailable.', true)
            end
            local result, pageError = page(catalogUsage.items, candidate.cursor, limit)
            if not result then return nil, pageError end
            result.registeredCatalogs = catalogUsage.registeredCatalogs
            result.observedCalls = catalogUsage.totalCalls
            result.evidenceTruncated = catalogUsage.truncated == true
            return result, nil
        end
        if candidate.view ~= 'legacy_usage' and candidate.view ~= 'adapters'
            and candidate.view ~= 'errors' and candidate.view ~= 'latency' then
            return nil, failure('VALIDATION_FAILED', 'The compatibility list view is invalid.')
        end
        local usage, usageError = readUsage()
        if not usage then
            return nil, type(usageError) == 'table' and usageError
                or failure('VIEW_UNAVAILABLE', 'Live legacy usage is unavailable.', true)
        end
        if candidate.view == 'adapters' then
            local adapterItems = {}
            for _, framework in ipairs(FRAMEWORKS) do
                local adapter = type(usage.adapters) == 'table'
                    and usage.adapters[framework] or nil
                adapterItems[#adapterItems + 1] = {
                    id = 'adapter:' .. framework,
                    provider = framework,
                    resource = 'synex_bridge_' .. framework,
                    available = type(adapter) == 'table' and adapter.available == true,
                    state = type(adapter) == 'table' and adapter.state or 'unknown',
                    status = type(adapter) == 'table' and adapter.status or 'UNAVAILABLE',
                    calls = type(adapter) == 'table' and adapter.calls or 0,
                    entries = type(adapter) == 'table' and adapter.entries or 0,
                    truncated = type(adapter) == 'table' and adapter.truncated == true,
                    code = type(adapter) == 'table' and adapter.code or nil,
                }
            end
            return page(adapterItems, candidate.cursor, limit)
        end
        if usage.availableAdapters == 0 then
            return nil, failure('VIEW_UNAVAILABLE', 'Live legacy usage is unavailable.', true)
        end
        local selectedItems, selectedTruncated = usage.items, usage.truncated == true
        if candidate.view == 'errors' or candidate.view == 'latency' then
            selectedItems = {}
            local matching = 0
            for _, item in ipairs(usage.items) do
                local include = candidate.view == 'latency'
                    or (item.denied or 0) > 0 or (item.unsupported or 0) > 0
                    or (item.errors or 0) > 0 or (item.timeouts or 0) > 0
                    or (item.rateLimited or 0) > 0
                if include then
                    matching = matching + 1
                    if #selectedItems < CATALOG_ITEMS then
                        if candidate.view == 'errors' then
                            selectedItems[#selectedItems + 1] = {
                                id = 'error:' .. item.id,
                                provider = item.framework,
                                adapterResource = item.adapterResource,
                                consumerResource = item.consumerResource,
                                operation = item.operation,
                                calls = item.calls,
                                denied = item.denied or 0,
                                unsupported = item.unsupported or 0,
                                errors = item.errors or 0,
                                timeouts = item.timeouts or 0,
                                rateLimited = item.rateLimited or 0,
                            }
                        else
                            local latency = type(item.latency) == 'table' and item.latency or {}
                            selectedItems[#selectedItems + 1] = {
                                id = 'latency:' .. item.id,
                                provider = item.framework,
                                adapterResource = item.adapterResource,
                                consumerResource = item.consumerResource,
                                operation = item.operation,
                                calls = item.calls,
                                samples = latency.samples or 0,
                                totalMs = latency.totalMs or 0,
                                averageMs = latency.averageMs or 0,
                                maximumMs = latency.maximumMs or 0,
                            }
                        end
                    end
                end
            end
            if matching > #selectedItems then selectedTruncated = true end
        end
        local result, pageError = page(selectedItems, candidate.cursor, limit)
        if not result then return nil, pageError end
        result.availableAdapters = usage.availableAdapters
        result.unavailableAdapters = usage.unavailableAdapters
        result.observedCalls = usage.totalCalls
        result.evidenceTruncated = selectedTruncated
        return result, nil
    end

    handlers.findings = function(request)
        local candidate, requestError = validateRequest(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' })
        if not candidate then return nil, requestError end
        if candidate.view ~= 'migration_readiness' or not validLimit(candidate.limit)
            or not validCursor(candidate.cursor) or not emptyObject(candidate.filters)
            or not emptyObject(candidate.sort) then
            return nil, failure('VALIDATION_FAILED', 'The migration-readiness request is invalid.')
        end
        local usage = readUsage()
        local adapters = usage and usage.adapters or {}
        local findings = {}
        for _, framework in ipairs(FRAMEWORKS) do
            local adapter = adapters[framework]
            if not adapter or adapter.available ~= true then
                findings[#findings + 1] = {
                    id = framework,
                    code = 'LEGACY_USAGE_UNAVAILABLE',
                    severity = 'UNAVAILABLE',
                    title = framework .. ' migration evidence',
                    summary = 'The live compatibility usage snapshot is unavailable.',
                }
            elseif adapter.truncated == true then
                findings[#findings + 1] = {
                    id = framework,
                    code = 'LEGACY_USAGE_EVIDENCE_TRUNCATED',
                    severity = 'WARNING',
                    title = framework .. ' migration evidence',
                    summary = ('%d call(s) observed; the bounded snapshot is incomplete.'):format(adapter.calls),
                }
            elseif adapter.calls > 0 then
                findings[#findings + 1] = {
                    id = framework,
                    code = 'LEGACY_USAGE_OBSERVED',
                    severity = 'WARNING',
                    title = framework .. ' legacy usage observed',
                    summary = ('%d call(s) across %d live usage entries.'):format(
                        adapter.calls, adapter.entries),
                }
            else
                findings[#findings + 1] = {
                    id = framework,
                    code = 'NO_LEGACY_USAGE_OBSERVED',
                    severity = 'INFO',
                    title = framework .. ' current-runtime evidence',
                    summary = 'No legacy calls are recorded in the current runtime snapshot; review is still required.',
                }
            end
        end
        return page(findings, candidate.cursor, candidate.limit or 20)
    end

    local boundaryHandlers = {}
    for operation, handler in pairs(handlers) do
        boundaryHandlers[operation] = function(...)
            local value, operationError = handler(...)
            if value == nil and operationError ~= nil then return false, operationError end
            return value, operationError
        end
    end

    local provider = {}
    function provider:register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not callable(register) then
            return nil, failure('UNAVAILABLE', 'The Core control-provider registry is unavailable.', true)
        end
        local called, metadata, registrationError = pcall(register, {
            schemaVersion = 1,
            namespace = 'compatibility',
            label = 'Compatibility',
            category = 'platform',
            version = '1.0.0',
            operations = boundaryHandlers,
            views = VIEWS,
        })
        if called and metadata then return metadata, nil end
        return nil, type(registrationError) == 'table' and registrationError
            or failure('UNAVAILABLE', 'The Compatibility provider could not be registered.', true)
    end
    provider.operations = OPERATIONS
    provider.views = VIEWS
    return provider
end
