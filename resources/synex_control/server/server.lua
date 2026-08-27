local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'

local ACE = {
    view = 'synex.control.view',
    audit = 'synex.control.audit',
    security = 'synex.control.security',
    financial = 'synex.control.financial',
    identifiers = 'synex.control.identifiers',
}
local ACCESS_ACE = {
    general = ACE.view,
    audit = ACE.audit,
    security = ACE.security,
    financial = ACE.financial,
    identifiers = ACE.identifiers,
}

local PRESENTATIONS = {
    detail = true,
    findings = true,
    graph = true,
    ['key-value'] = true,
    metrics = true,
    table = true,
    timeline = true,
}

local requestBuckets = {}
local inFlightByPlayer = {}
local responseCache = {}
local openPlayers = {}
local cursorHandles = {}
local cacheSequence = 0
local cursorSequence = 0
local cachedApi
local providerRegistered = false

local CURSOR_HANDLE_TTL_MILLISECONDS = 120000
local MAXIMUM_CURSOR_HANDLES_PER_PLAYER = 64
local META_WINDOW_MILLISECONDS = 60000
local MAXIMUM_META_EVENTS = 1024

local meta = {
    cacheHits = 0,
    cacheMisses = 0,
    nuiErrors = 0,
    payloadBytesMaximum = 0,
    payloadBytesTotal = 0,
    payloadTruncations = 0,
    providerFailures = 0,
    providerTimeouts = 0,
    requests = 0,
    responses = 0,
    sanitizerFailures = 0,
    searches = 0,
    serializationCount = 0,
    serializationMaximumMs = 0,
    serializationTotalMs = 0,
    recentRequests = {},
    recentSearches = {},
    recentTimeouts = {},
    recentTransitions = {},
    recentIncidents = {},
    providerHealth = {},
    providerDurationMaximumMs = {},
}

local function recordMetaEvent(events)
    events[#events + 1] = GetGameTimer()
    if #events > MAXIMUM_META_EVENTS then table.remove(events, 1) end
end

local function recentMetaCount(events, now)
    local first = 1
    while first <= #events and now - events[first] > META_WINDOW_MILLISECONDS do
        first = first + 1
    end
    if first > 1 then
        local retained = {}
        for index = first, #events do retained[#retained + 1] = events[index] end
        for index = 1, #events do events[index] = retained[index] end
        for index = #retained + 1, #events do events[index] = nil end
    end
    return #events
end

local function recordTransition(resourceName, state)
    local atMs = GetGameTimer()
    local transitions = meta.recentTransitions
    transitions[#transitions + 1] = {
        atMs = atMs,
        resource = tostring(resourceName):sub(1, 64),
        state = state,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
    if #transitions > 64 then table.remove(transitions, 1) end
    local incidents = meta.recentIncidents
    incidents[#incidents + 1] = {
        atMs = atMs,
        code = 'RESOURCE_STATE_CHANGED',
        kind = 'resource_transition',
        label = 'Resource ' .. tostring(state),
        resource = tostring(resourceName):sub(1, 64),
        status = state == 'started' and 'HEALTHY' or 'UNAVAILABLE',
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
    if #incidents > 128 then table.remove(incidents, 1) end
end

local function recordIncident(kind, resource, status, code, label)
    local incidents = meta.recentIncidents
    incidents[#incidents + 1] = {
        atMs = GetGameTimer(),
        code = tostring(code):sub(1, 64),
        kind = tostring(kind):sub(1, 32),
        label = tostring(label):sub(1, 96),
        resource = tostring(resource):sub(1, 64),
        status = status,
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }
    if #incidents > 128 then table.remove(incidents, 1) end
end

local function callable(value)
    local kind = type(value)
    if kind == 'function' then return true end
    if kind ~= 'table' and kind ~= 'userdata' then return false end
    local mt = getmetatable(value)
    if type(mt) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMt = pcall(debug.getmetatable, value)
        if readable then mt = rawMt end
    end
    return type(mt) == 'table' and type(rawget(mt, '__call')) == 'function'
end

local function nowIso()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function publicError(code, retryable)
    local aliases = {
        CONTROL_PROVIDER_BUSY = 'PROVIDER_BUSY',
        CONTROL_PROVIDER_CIRCUIT_OPEN = 'PROVIDER_UNAVAILABLE',
        CONTROL_PROVIDER_NOT_FOUND = 'PROVIDER_UNAVAILABLE',
        CONTROL_PROVIDER_OPERATION_UNSUPPORTED = 'VIEW_UNAVAILABLE',
        DEADLINE_EXCEEDED = 'PROVIDER_TIMEOUT',
        INVALID_CONTROL_PROVIDER_REQUEST = 'INVALID_ARGUMENT',
        INVALID_PROVIDER_RESPONSE = 'PROVIDER_RESPONSE_INVALID',
        PROVIDER_ERROR = 'PROVIDER_UNAVAILABLE',
        PROVIDER_IN_FLIGHT = 'PROVIDER_BUSY',
        PROVIDER_RESPONSE_TOO_LARGE = 'PAYLOAD_TOO_LARGE',
        STALE_RESOURCE = 'PROVIDER_RESTARTED',
    }
    code = aliases[code] or code
    local allowedCodes = {
        ACCESS_REVOKED = true,
        CORE_UNAVAILABLE = true,
        INVALID_ARGUMENT = true,
        INVALID_CURSOR = true,
        INVALID_LIMIT = true,
        INVALID_PROVIDER = true,
        NOT_EXPOSED = true,
        NOT_FOUND = true,
        PAYLOAD_TOO_LARGE = true,
        PROVIDER_BUSY = true,
        PROVIDER_RESTARTED = true,
        PROVIDER_RESPONSE_INVALID = true,
        PROVIDER_TIMEOUT = true,
        PROVIDER_UNAVAILABLE = true,
        RATE_LIMITED = true,
        REQUEST_TOO_LARGE = true,
        STALE_ENTITY = true,
        VIEW_UNAVAILABLE = true,
    }
    return {
        code = allowedCodes[code] and code or 'PROVIDER_UNAVAILABLE',
        retryable = retryable == true,
    }
end

local function failureCode(candidate, fallback)
    if type(candidate) == 'table' and type(candidate.code) == 'string' then
        return candidate.code
    end
    if type(candidate) == 'string' and candidate:match('^[A-Z][A-Z0-9_]+$') then
        return candidate
    end
    return fallback or 'PROVIDER_UNAVAILABLE'
end

local function callApi(handler, ...)
    if not callable(handler) then return nil, { code = 'PROVIDER_UNAVAILABLE' } end
    local invoked, value, callError = pcall(handler, ...)
    if not invoked then return nil, { code = 'PROVIDER_UNAVAILABLE' } end
    if value == nil or value == false then
        return nil, type(callError) == 'table' and callError or { code = 'PROVIDER_UNAVAILABLE' }
    end
    return value, nil
end

local function playerValid(playerSource)
    return type(playerSource) == 'number' and math.type(playerSource) == 'integer'
        and playerSource > 0 and GetPlayerName(tostring(playerSource)) ~= nil
end

local function allowed(playerSource, ace)
    return playerValid(playerSource)
        and IsPlayerAceAllowed(tostring(playerSource), ace) == true
end

local function permissionProjection(playerSource)
    return {
        general = true,
        audit = allowed(playerSource, ACE.audit),
        financial = allowed(playerSource, ACE.financial),
        identifiers = allowed(playerSource, ACE.identifiers),
        security = allowed(playerSource, ACE.security),
    }
end

local function permissionKey(permissions)
    return ('a%d-f%d-i%d-s%d'):format(
        permissions.audit and 1 or 0,
        permissions.financial and 1 or 0,
        permissions.identifiers and 1 or 0,
        permissions.security and 1 or 0)
end

local function accessAllowed(permissions, accessClass)
    return accessClass == 'general' or permissions[accessClass] == true
end

local function permissionWasRevoked(before, current)
    for accessClass, wasAllowed in pairs(before) do
        if wasAllowed == true and current[accessClass] ~= true then return true end
    end
    return false
end

local function takeTokens(playerSource, cost)
    local now = GetGameTimer()
    local bucket = requestBuckets[playerSource]
    if not bucket then
        bucket = { tokens = SynexControlLimits.serverBurst, updatedAt = now }
        requestBuckets[playerSource] = bucket
    end
    local elapsed = math.max(0, now - bucket.updatedAt) / 1000
    bucket.tokens = math.min(SynexControlLimits.serverBurst,
        bucket.tokens + elapsed * SynexControlLimits.serverRefillPerSecond)
    bucket.updatedAt = now
    if bucket.tokens < cost then return false end
    bucket.tokens = bucket.tokens - cost
    return true
end

local function releaseInFlight(playerSource)
    local current = inFlightByPlayer[playerSource]
    if type(current) ~= 'number' or current <= 1 then
        inFlightByPlayer[playerSource] = nil
        return
    end
    inFlightByPlayer[playerSource] = current - 1
end

local function clearCache()
    responseCache = {}
    cacheSequence = cacheSequence + 1
end

local function cursorScope(request)
    local encoded, value = pcall(json.encode, {
        filters = request.filters,
        id = request.id,
        limit = request.limit,
        operation = request.operation,
        provider = request.provider,
        query = request.query,
        sort = request.sort,
        view = request.view,
    })
    if not encoded or type(value) ~= 'string' or #value > 2048 then return nil end
    return value
end

local function clearCursorHandles(playerSource)
    cursorHandles[playerSource] = nil
end

local function purgeCursorHandles(playerSource, now)
    local store = cursorHandles[playerSource]
    if type(store) ~= 'table' then return nil end
    for handle, entry in pairs(store.entries) do
        if type(entry) ~= 'table' or type(entry.expiresAt) ~= 'number'
            or entry.expiresAt <= now then
            store.entries[handle] = nil
        end
    end
    local order = {}
    for _, handle in ipairs(store.order) do
        if store.entries[handle] ~= nil then order[#order + 1] = handle end
    end
    store.order = order
    return store
end

local function resolveCursorHandle(playerSource, request)
    if request.cursor == nil then return true end
    local scope = cursorScope(request)
    local store = scope and purgeCursorHandles(playerSource, GetGameTimer()) or nil
    local entry = store and store.entries[request.cursor] or nil
    if type(entry) ~= 'table' or entry.playerSource ~= playerSource
        or entry.scope ~= scope then return false end
    request.cursor = entry.cursor
    return true
end

local function sealNextCursor(playerSource, request, value)
    if type(value) ~= 'table' or value.nextCursor == nil then return true end
    local rawCursor = value.nextCursor
    if (type(rawCursor) ~= 'string' and type(rawCursor) ~= 'number')
        or type(rawCursor) == 'string' and (#rawCursor < 1
            or #rawCursor > SynexControlLimits.maximumCursorBytes) then return false end
    local scope = cursorScope(request)
    if not scope then return false end
    local now = GetGameTimer()
    local store = purgeCursorHandles(playerSource, now)
    if not store then
        store = { entries = {}, order = {} }
        cursorHandles[playerSource] = store
    end
    while #store.order >= MAXIMUM_CURSOR_HANDLES_PER_PLAYER do
        store.entries[table.remove(store.order, 1)] = nil
    end
    cursorSequence = cursorSequence + 1
    local handle = ('cursor-%08x-%08x'):format(cursorSequence, now)
    store.entries[handle] = {
        cursor = rawCursor,
        expiresAt = now + CURSOR_HANDLE_TTL_MILLISECONDS,
        playerSource = playerSource,
        scope = scope,
    }
    store.order[#store.order + 1] = handle
    value.nextCursor = handle
    return true
end

local function cloneCacheValue(value, state, depth)
    state = state or { entries = 0, seen = {} }
    depth = depth or 0
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' then return value, true end
    if kind == 'number' then
        return value, value == value and value ~= math.huge and value ~= -math.huge
    end
    if kind == 'string' then
        return value, #value <= SynexControlLimits.maximumResponseBytes
    end
    if kind ~= 'table' or depth >= SynexControlLimits.maximumDepth
        or state.seen[value] then return nil, false end
    state.seen[value] = true
    local cloned = {}
    for key, nested in next, value do
        state.entries = state.entries + 1
        local keyKind = type(key)
        if state.entries > SynexControlLimits.maximumEntriesPerResponse
            or keyKind ~= 'string' and keyKind ~= 'number'
            or keyKind == 'string' and (#key < 1
                or #key > SynexControlLimits.maximumKeyBytes)
            or keyKind == 'number' and (math.type(key) ~= 'integer' or key < 1) then
            state.seen[value] = nil
            return nil, false
        end
        local copied, valid = cloneCacheValue(nested, state, depth + 1)
        if not valid then
            state.seen[value] = nil
            return nil, false
        end
        cloned[key] = copied
    end
    state.seen[value] = nil
    return cloned, true
end

local function cacheGet(key)
    local entry = responseCache[key]
    local now = GetGameTimer()
    if not entry or entry.sequence ~= cacheSequence or entry.expiresAt <= now then
        responseCache[key] = nil
        meta.cacheMisses = meta.cacheMisses + 1
        return nil
    end
    local cloned, valid = cloneCacheValue(entry.value)
    if not valid then
        responseCache[key] = nil
        meta.cacheMisses = meta.cacheMisses + 1
        return nil
    end
    entry.lastAccessAt = now
    meta.cacheHits = meta.cacheHits + 1
    return cloned
end

local function cachePut(key, value, ttl)
    local cachedValue, valid = cloneCacheValue(value)
    if not valid then return false end
    local count = 0
    for _ in pairs(responseCache) do count = count + 1 end
    if count >= SynexControlLimits.maximumCacheEntries then
        local oldestKey, oldestAt
        for candidateKey, candidate in pairs(responseCache) do
            if not oldestAt or candidate.lastAccessAt < oldestAt then
                oldestKey, oldestAt = candidateKey, candidate.lastAccessAt
            end
        end
        if oldestKey then responseCache[oldestKey] = nil end
    end
    local now = GetGameTimer()
    responseCache[key] = {
        createdAt = now,
        lastAccessAt = now,
        expiresAt = now + ttl,
        sequence = cacheSequence,
        value = cachedValue,
    }
    return true
end

local function metaSnapshot()
    local now = GetGameTimer()
    local recentRequests = recentMetaCount(meta.recentRequests, now)
    local recentSearches = recentMetaCount(meta.recentSearches, now)
    local recentTimeouts = recentMetaCount(meta.recentTimeouts, now)
    local duration = {}
    for namespace, value in pairs(meta.providerDurationMaximumMs) do
        duration[namespace] = value
    end
    return {
        status = recentTimeouts > 0 and 'DEGRADED' or 'HEALTHY',
        counters = {
            cacheHits = meta.cacheHits,
            cacheMisses = meta.cacheMisses,
            nuiErrors = meta.nuiErrors,
            payloadBytesMaximum = meta.payloadBytesMaximum,
            payloadBytesTotal = meta.payloadBytesTotal,
            payloadTruncations = meta.payloadTruncations,
            providerFailures = meta.providerFailures,
            providerTimeouts = meta.providerTimeouts,
            requests = meta.requests,
            responses = meta.responses,
            sanitizerFailures = meta.sanitizerFailures,
            searches = meta.searches,
            serializationCount = meta.serializationCount,
            serializationMaximumMs = meta.serializationMaximumMs,
            serializationTotalMs = meta.serializationTotalMs,
        },
        rollingWindow = {
            milliseconds = META_WINDOW_MILLISECONDS,
            requests = recentRequests,
            searches = recentSearches,
            providerTimeouts = recentTimeouts,
            requestsPerMinute = recentRequests,
            searchesPerMinute = recentSearches,
        },
        recentTransitions = meta.recentTransitions,
        providerDurationMaximumMs = duration,
    }
end

local function incidentSnapshot()
    local now = GetGameTimer()
    local items, eligible = {}, 0
    for _, event in ipairs(meta.recentIncidents) do
        if type(event.atMs) == 'number' and now - event.atMs <= META_WINDOW_MILLISECONDS then
            eligible = eligible + 1
            items[#items + 1] = {
                code = event.code,
                correlation = 'temporal-only',
                detail = 'Observed in the same bounded incident window; no root cause is inferred.',
                kind = event.kind,
                label = event.label,
                resource = event.resource,
                status = event.status,
                timestamp = event.timestamp,
            }
        end
    end
    while #items > 100 do table.remove(items, 1) end
    return {
        items = items,
        hasMore = false,
        rootCauseInferred = false,
        temporalWindowMilliseconds = META_WINDOW_MILLISECONDS,
        truncated = eligible > #items,
    }
end

local function registerSelf(api)
    if providerRegistered then return end
    local providers = api and api.ControlProviders
    if not providers or not callable(providers.register) then return end
    local registered = callApi(providers.register, {
        schemaVersion = 1,
        namespace = 'control',
        label = 'Control Plane',
        category = 'operations',
        version = '1.0.0',
        views = {
            {
                id = 'overview',
                label = 'Overview',
                operation = 'summary',
                presentation = 'metrics',
                accessClass = 'general',
                order = 5,
                description = 'Bounded Control request, provider, payload, cache, and NUI summary.',
            },
            {
                id = 'health',
                label = 'Meta Health',
                operation = 'health',
                presentation = 'metrics',
                accessClass = 'general',
                order = 10,
                description = 'Bounded Control request, provider, payload, and NUI health counters.',
            },
            {
                id = 'metrics',
                label = 'Payload Metrics',
                operation = 'metrics',
                presentation = 'metrics',
                accessClass = 'general',
                order = 20,
                description = 'Bounded request rates, response sizes, cache behavior, and provider durations.',
            },
            {
                id = 'findings',
                label = 'Findings',
                operation = 'findings',
                presentation = 'findings',
                accessClass = 'general',
                order = 30,
                description = 'Current sanitized Control degradation findings without operator mutations.',
            },
            {
                id = 'incident_window',
                label = 'Incident Window',
                operation = 'list',
                presentation = 'timeline',
                accessClass = 'general',
                order = 40,
                description = 'Bounded temporal correlation of Control-observed provider and resource events.',
            },
        },
        operations = {
            summary = function() return metaSnapshot() end,
            health = function() return metaSnapshot() end,
            metrics = function() return metaSnapshot() end,
            list = function() return incidentSnapshot() end,
            findings = function()
                local findings = {}
                local recentTimeouts = recentMetaCount(meta.recentTimeouts, GetGameTimer())
                if recentTimeouts > 0 then
                    findings[#findings + 1] = {
                        code = 'PROVIDER_TIMEOUTS_OBSERVED',
                        severity = 'DEGRADED',
                        count = recentTimeouts,
                    }
                end
                if meta.payloadTruncations > 0 then
                    findings[#findings + 1] = {
                        code = 'PAYLOAD_LIMITS_OBSERVED',
                        severity = 'WARNING',
                        count = meta.payloadTruncations,
                    }
                end
                return { items = findings, hasMore = false }
            end,
        },
    })
    providerRegistered = registered ~= nil
end

local function acquireApi()
    if GetResourceState(CORE_RESOURCE) ~= 'started' then
        cachedApi = nil
        providerRegistered = false
        return nil, { code = 'CORE_UNAVAILABLE' }
    end
    if type(cachedApi) == 'table' then
        registerSelf(cachedApi)
        return cachedApi, nil
    end
    local invoked, api = pcall(function()
        return exports[CORE_RESOURCE]:GetAPI(CORE_RANGE)
    end)
    if not invoked or type(api) ~= 'table' then
        return nil, { code = 'CORE_UNAVAILABLE' }
    end
    cachedApi = api
    registerSelf(api)
    return api, nil
end

local function normalizeProviderPage(value)
    local entries = type(value) == 'table' and (value.providers or value.entries or value) or nil
    if type(entries) ~= 'table' then return nil end
    local providers = {}
    for _, entry in ipairs(entries) do
        if type(entry) == 'table' and type(entry.namespace) == 'string'
            and type(entry.label) == 'string' then providers[#providers + 1] = entry end
        if #providers >= SynexControlLimits.maximumProviders then break end
    end
    table.sort(providers, function(left, right) return left.namespace < right.namespace end)
    local nextCursor = type(value.nextCursor) == 'string' and value.nextCursor or nil
    local hasMore = value.hasMore == true or value.truncated == true and nextCursor ~= nil
    return providers, {
        hasMore = hasMore,
        nextCursor = nextCursor,
        total = type(value.total) == 'number' and value.total or nil,
        truncated = value.truncated == true or #entries > SynexControlLimits.maximumProviders,
    }
end

local function listProviderPage(api, cursor, limit)
    local providers = api and api.ControlProviders
    local value, listError = callApi(providers and providers.list, {
        cursor = cursor,
        limit = limit,
    })
    if not value then return nil, listError end
    local normalized, page = normalizeProviderPage(value)
    if not normalized then return nil, { code = 'PROVIDER_RESPONSE_INVALID' } end
    return normalized, nil, page
end

local function listProviders(api)
    local collected, seen = {}, {}
    local cursor, truncated, total = nil, false, nil
    while #collected < SynexControlLimits.maximumProviders do
        local remaining = SynexControlLimits.maximumProviders - #collected
        local page, listError, metadata = listProviderPage(api, cursor,
            math.min(SynexControlLimits.providerCatalogPageSize, remaining))
        if not page then return nil, listError end
        total = metadata.total or total
        for _, provider in ipairs(page) do
            if not seen[provider.namespace] then
                seen[provider.namespace] = true
                collected[#collected + 1] = provider
            end
        end
        if not metadata.hasMore then
            truncated = metadata.truncated and metadata.nextCursor == nil
            break
        end
        if metadata.nextCursor == nil or metadata.nextCursor == cursor then
            truncated = true
            break
        end
        cursor = metadata.nextCursor
    end
    if total and total > #collected or #collected >= SynexControlLimits.maximumProviders
        and cursor ~= nil then truncated = true end
    table.sort(collected, function(left, right) return left.namespace < right.namespace end)
    return collected, nil, truncated
end

local function operationSupported(provider, operation)
    local operations = provider and provider.operations
    if type(operations) ~= 'table' then return false end
    for key, value in pairs(operations) do
        if key == operation and value == true then return true end
        if value == operation then return true end
    end
    return false
end

local function findProvider(providers, namespace)
    for _, provider in ipairs(providers or {}) do
        if provider.namespace == namespace then return provider end
    end
    return nil
end

local function describeProvider(api, namespace)
    local providers = api and api.ControlProviders
    if providers and callable(providers.describe) then
        local provider, describeError = callApi(providers.describe, namespace)
        if not provider then return nil, describeError end
        if type(provider) ~= 'table' or provider.namespace ~= namespace
            or type(provider.label) ~= 'string' then
            return nil, { code = 'PROVIDER_RESPONSE_INVALID' }
        end
        return provider, nil
    end
    local listed, listError = listProviders(api)
    if not listed then return nil, listError end
    return findProvider(listed, namespace), nil
end

local function findView(provider, viewId)
    for _, view in ipairs(type(provider) == 'table' and provider.views or {}) do
        if type(view) == 'table' and view.id == viewId
            and PRESENTATIONS[view.presentation] then return view end
    end
    return nil
end

local function searchKindFor(view, kind, mode)
    local search = type(view) == 'table' and view.search or nil
    for _, candidate in ipairs(type(search) == 'table' and search.kinds or {}) do
        if type(candidate) == 'table' and candidate.id == kind then
            for _, supported in ipairs(type(candidate.modes) == 'table' and candidate.modes or {}) do
                if supported == mode then return candidate end
            end
            return nil
        end
    end
    return nil
end

local function requestAccessClass(api, request)
    if request.operation == 'overview' or request.operation == 'providers' then
        return 'general', nil
    end
    local provider, listError = describeProvider(api, request.provider)
    if listError then return nil, listError end
    if not provider then return nil, { code = 'PROVIDER_UNAVAILABLE', retryable = true } end
    local view = findView(provider, request.view)
    if not view then return nil, { code = 'VIEW_UNAVAILABLE' } end
    if request.operation == 'search' then
        local query = request.query
        local candidate = query and searchKindFor(view, query.kind, query.mode)
        if not candidate then return nil, { code = 'INVALID_ARGUMENT' } end
        return candidate.accessClass, nil
    end
    return view.accessClass, nil
end

local function projectViewInput(input)
    if type(input) ~= 'table' or type(input.fields) ~= 'table' then return nil end
    local fields = {}
    for _, field in ipairs(input.fields) do
        if type(field) == 'table' and type(field.key) == 'string'
            and type(field.label) == 'string' then
            fields[#fields + 1] = {
                key = field.key,
                label = field.label,
                source = field.source,
                type = field.type,
                format = field.format,
                required = field.required == true,
                minLength = field.minLength,
                maxLength = field.maxLength,
                minimum = field.minimum,
                maximum = field.maximum,
            }
        end
        if #fields >= 8 then break end
    end
    return #fields > 0 and { fields = fields } or nil
end

local function projectViewSearch(search, permissions)
    if type(search) ~= 'table' or type(search.kinds) ~= 'table' then return nil end
    local kinds = {}
    for _, kind in ipairs(search.kinds) do
        if type(kind) == 'table' and type(kind.id) == 'string'
            and type(kind.modes) == 'table' and ACCESS_ACE[kind.accessClass] then
            local modes = {}
            for _, mode in ipairs(kind.modes) do
                if mode == 'exact' or mode == 'prefix' then modes[#modes + 1] = mode end
                if #modes >= 2 then break end
            end
            if #modes > 0 then
                kinds[#kinds + 1] = {
                    id = kind.id,
                    modes = modes,
                    accessClass = kind.accessClass,
                    authorized = accessAllowed(permissions, kind.accessClass),
                }
            end
        end
        if #kinds >= 16 then break end
    end
    return #kinds > 0 and { kinds = kinds } or nil
end

local function projectProvider(provider, permissions)
    local views = {}
    local providerAuthorized = false
    local summaryAuthorized = false
    for _, view in ipairs(type(provider.views) == 'table' and provider.views or {}) do
        if type(view) == 'table' and type(view.id) == 'string'
            and type(view.label) == 'string' and PRESENTATIONS[view.presentation] then
            local authorized = accessAllowed(permissions, view.accessClass)
            if authorized then providerAuthorized = true end
            -- The overview sampler always invokes the canonical `overview` summary.
            -- Authorization for another summary view must never grant access to it.
            if authorized and view.id == 'overview' and view.operation == 'summary' then
                summaryAuthorized = true
            end
            views[#views + 1] = {
                id = view.id,
                label = view.label,
                operation = view.operation,
                presentation = view.presentation,
                order = view.order,
                accessClass = view.accessClass,
                input = projectViewInput(view.input),
                search = projectViewSearch(view.search, permissions),
                authorized = authorized,
            }
        end
    end
    local metrics = {}
    for _, key in ipairs({
        'calls', 'successes', 'failures', 'rejections', 'timeouts', 'busy',
        'lastDurationMs', 'maximumDurationMs', 'lastResponseBytes',
    }) do
        local value = type(provider.metrics) == 'table' and provider.metrics[key] or nil
        if type(value) == 'number' and value >= 0 and value < 2147483648 then
            metrics[key] = value
        end
    end
    return {
        namespace = provider.namespace,
        label = provider.label,
        category = provider.category,
        version = provider.version,
        resource = provider.resource,
        health = provider.health,
        circuit = provider.circuit,
        operations = provider.operations,
        capabilities = provider.capabilities or provider.operations,
        views = views,
        metrics = metrics,
        authorized = providerAuthorized,
        summaryAuthorized = summaryAuthorized,
    }
end

local function invokeProvider(api, namespace, operation, request)
    local providers = api and api.ControlProviders
    local startedAt = GetGameTimer()
    local value, invocationError = callApi(providers and providers.invoke,
        namespace, operation, request, {
            timeoutMs = SynexControlLimits.providerTimeoutMilliseconds,
        })
    local duration = math.max(0, GetGameTimer() - startedAt)
    meta.providerDurationMaximumMs[namespace] = math.max(
        meta.providerDurationMaximumMs[namespace] or 0, duration)
    if not value then
        local code = failureCode(invocationError, 'PROVIDER_UNAVAILABLE')
        local expected = code == 'INVALID_ARGUMENT' or code == 'INVALID_CURSOR'
            or code == 'INVALID_LIMIT' or code == 'NOT_EXPOSED'
            or code == 'NOT_FOUND' or code == 'STALE_ENTITY'
            or code == 'VIEW_UNAVAILABLE'
        if not expected then meta.providerFailures = meta.providerFailures + 1 end
        if code == 'PROVIDER_TIMEOUT' or code == 'DEADLINE_EXCEEDED' then
            meta.providerTimeouts = meta.providerTimeouts + 1
            recordMetaEvent(meta.recentTimeouts)
            recordIncident('provider_timeout', namespace, 'DEGRADED', code,
                'Provider request timed out')
        end
        return nil, {
            code = publicError(code).code,
            retryable = code == 'PROVIDER_TIMEOUT' or code == 'DEADLINE_EXCEEDED'
                or code == 'CONTROL_PROVIDER_BUSY' or code == 'CONTROL_PROVIDER_NOT_FOUND'
                or code == 'CONTROL_PROVIDER_CIRCUIT_OPEN' or code == 'STALE_RESOURCE',
        }
    end
    if type(value) ~= 'table' or value.namespace ~= namespace
        or value.operation ~= operation or value.data == nil then
        meta.providerFailures = meta.providerFailures + 1
        return nil, { code = 'PROVIDER_RESPONSE_INVALID' }
    end
    local sanitized, report = SynexControlSanitizer.sanitize(value.data, {
        revealIdentifiers = true,
    })
    if sanitized == nil or type(report) ~= 'table' then
        meta.sanitizerFailures = meta.sanitizerFailures + 1
        return nil, { code = 'PROVIDER_RESPONSE_INVALID' }
    end
    if report.truncated then
        meta.payloadTruncations = meta.payloadTruncations + 1
        return nil, { code = 'PAYLOAD_TOO_LARGE' }
    end
    return sanitized, nil
end

local function overview(api, permissions)
    local providers, listError, catalogTruncated = listProviders(api)
    if not providers then return nil, listError end
    local projected, summaries, attention = {}, {}, {}
    local severityCounts = {
        CRITICAL = 0,
        DEGRADED = 0,
        ERROR = 0,
        HEALTHY = 0,
        INFO = 0,
        UNAVAILABLE = 0,
        WARNING = 0,
    }
    local startedAt = GetGameTimer()
    local sampled = 0
    for _, provider in ipairs(providers) do
        local projection = projectProvider(provider, permissions)
        projected[#projected + 1] = projection
        local providerHealth = severityCounts[provider.health] ~= nil
            and provider.health or 'UNAVAILABLE'
        local summaryAuthorized = projection.summaryAuthorized == true
        if summaryAuthorized and operationSupported(provider, 'summary')
            and sampled < SynexControlLimits.maximumOverviewProviders
            and GetGameTimer() - startedAt < SynexControlLimits.maximumOverviewMilliseconds then
            sampled = sampled + 1
            local summary, summaryError = invokeProvider(api, provider.namespace, 'summary', {
                view = 'overview',
                limit = SynexControlLimits.overviewSummaryEntryLimit,
            })
            summaries[provider.namespace] = summary or {
                available = false,
                error = publicError(failureCode(summaryError, 'PROVIDER_UNAVAILABLE'), true),
            }
            if type(summary) == 'table' and severityCounts[summary.status] ~= nil then
                providerHealth = summary.status
            elseif not summary then
                providerHealth = 'UNAVAILABLE'
            end
            if provider.namespace == 'core' and type(summary) == 'table'
                and type(summary.attention) == 'table' then
                for _, finding in ipairs(summary.attention) do
                    if #attention >= 16 then break end
                    if type(finding) == 'table' then
                        attention[#attention + 1] = {
                            code = type(finding.component) == 'string'
                                and finding.component or 'CORE_HEALTH',
                            severity = severityCounts[finding.status] ~= nil
                                and finding.status or 'WARNING',
                            summary = type(finding.message) == 'string'
                                and finding.message or 'Core health requires attention.',
                            resource = 'synex_core',
                        }
                    end
                end
            end
        elseif not summaryAuthorized then
            summaries[provider.namespace] = { available = false, restricted = true }
        else
            summaries[provider.namespace] = { available = false, error = publicError('VIEW_UNAVAILABLE') }
        end
        projection.health = providerHealth
        if meta.providerHealth[provider.namespace] ~= providerHealth then
            meta.providerHealth[provider.namespace] = providerHealth
            recordIncident('provider_health', provider.namespace, providerHealth,
                'PROVIDER_HEALTH_CHANGED', 'Provider health changed')
        end
        severityCounts[providerHealth] = severityCounts[providerHealth] + 1
    end
    return {
        generatedAt = nowIso(),
        attention = attention,
        readOnly = true,
        providerCatalog = {
            count = #projected,
            truncated = catalogTruncated == true,
        },
        severityCounts = severityCounts,
        summaries = summaries,
        sampling = {
            providers = #providers,
            sampled = sampled,
            truncated = sampled < #providers or catalogTruncated == true,
            catalogTruncated = catalogTruncated == true,
        },
    }, nil
end

local function providerMetadata(api, permissions, request)
    local providers, listError, page = listProviderPage(api, request.cursor,
        math.min(request.limit or SynexControlLimits.providerCatalogPageSize,
            SynexControlLimits.providerCatalogPageSize))
    if not providers then return nil, listError end
    local projected = {}
    for _, provider in ipairs(providers) do
        projected[#projected + 1] = projectProvider(provider, permissions)
    end
    return {
        providers = projected,
        generatedAt = nowIso(),
        nextCursor = page.nextCursor,
        hasMore = page.hasMore,
        readOnly = true,
        total = page.total,
        truncated = page.truncated,
    }, nil
end

local function routeProvider(api, request)
    local provider, listError = describeProvider(api, request.provider)
    if listError then return nil, listError end
    if not provider then return nil, { code = 'PROVIDER_UNAVAILABLE', retryable = true } end

    local providerOperation
    if request.operation == 'search' then
        providerOperation = 'search'
    elseif request.operation == 'inspect' then
        providerOperation = 'inspect'
    else
        local view = findView(provider, request.view)
        if not view then return nil, { code = 'VIEW_UNAVAILABLE' } end
        providerOperation = view.operation
        if providerOperation == 'getSummary' then providerOperation = 'summary' end
        if providerOperation == 'getHealth' then providerOperation = 'health' end
        if providerOperation == 'getMetrics' then providerOperation = 'metrics' end
        if providerOperation == 'getFindings' then providerOperation = 'findings' end
        if type(providerOperation) ~= 'string' then providerOperation = 'list' end
    end
    if not operationSupported(provider, providerOperation) then
        return nil, { code = 'VIEW_UNAVAILABLE' }
    end

    return invokeProvider(api, request.provider, providerOperation, {
        cursor = request.cursor,
        filters = request.filters,
        id = request.id,
        limit = request.limit,
        query = request.query,
        sort = request.sort,
        view = request.view,
    })
end

local function cacheKey(request, permissions)
    if request.operation ~= 'overview' and request.operation ~= 'providers' then return nil end
    local encoded, value = pcall(json.encode, {
        cursor = request.cursor,
        limit = request.limit,
        operation = request.operation,
        provider = request.provider,
        view = request.view,
        filters = request.filters,
        sort = request.sort,
    })
    if not encoded then return nil end
    return permissionKey(permissions) .. ':' .. value
end

local function execute(api, request, permissions)
    local key = cacheKey(request, permissions)
    if key then
        local cached = cacheGet(key)
        if cached ~= nil then return cached, nil end
    end
    local value, operationError
    if request.operation == 'overview' then
        value, operationError = overview(api, permissions)
    elseif request.operation == 'providers' then
        value, operationError = providerMetadata(api, permissions, request)
    else
        value, operationError = routeProvider(api, request)
    end
    if value and key then
        local ttl = request.operation == 'overview'
            and SynexControlLimits.overviewCacheMilliseconds
            or SynexControlLimits.providerCacheMilliseconds
        cachePut(key, value, ttl)
    end
    return value, operationError
end

local function sendError(playerSource, requestId, code, retryable)
    local errorValue = publicError(code, retryable)
    local safeRequestId = type(requestId) == 'string' and #requestId >= 8
        and #requestId <= SynexControlLimits.maximumRequestIdBytes
        and requestId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
        and requestId or 'invalid-request'
    TriggerClientEvent('synex_control:response', playerSource, {
        schemaVersion = 1,
        requestId = safeRequestId,
        ok = false,
        error = errorValue,
        generatedAt = nowIso(),
    })
end

local function sendValue(playerSource, request, value, permissions, startedAt)
    if not sealNextCursor(playerSource, request, value) then
        sendError(playerSource, request.requestId, 'PROVIDER_RESPONSE_INVALID', false)
        return
    end
    local envelope = {
        schemaVersion = 1,
        requestId = request.requestId,
        ok = true,
        data = value,
        meta = {
            durationMs = math.max(0, GetGameTimer() - startedAt),
            generatedAt = nowIso(),
            readOnly = true,
        },
    }
    local serializationStartedAt = GetGameTimer()
    local encodeResponse = SynexControlSanitizer.encode
    if request.operation == 'overview' or request.operation == 'providers' then
        encodeResponse = SynexControlSanitizer.encodeProviderMetadataEnvelope
    end
    local sanitized, report, encodeError, bytes = encodeResponse(envelope, {
        maximumBytes = SynexControlLimits.maximumResponseBytes,
        revealIdentifiers = permissions.identifiers,
    })
    local serializationDuration = math.max(0, GetGameTimer() - serializationStartedAt)
    meta.serializationCount = meta.serializationCount + 1
    meta.serializationTotalMs = meta.serializationTotalMs + serializationDuration
    meta.serializationMaximumMs = math.max(meta.serializationMaximumMs,
        serializationDuration)
    if not sanitized then
        meta.sanitizerFailures = meta.sanitizerFailures + 1
        if encodeError == 'PAYLOAD_TOO_LARGE' then
            meta.payloadTruncations = meta.payloadTruncations + 1
            sendError(playerSource, request.requestId, 'PAYLOAD_TOO_LARGE', false)
        else
            sendError(playerSource, request.requestId, 'PROVIDER_RESPONSE_INVALID', false)
        end
        return
    end
    if report.truncated then
        meta.payloadTruncations = meta.payloadTruncations + 1
        sendError(playerSource, request.requestId, 'PAYLOAD_TOO_LARGE', false)
        return
    end
    meta.payloadBytesTotal = meta.payloadBytesTotal + bytes
    meta.payloadBytesMaximum = math.max(meta.payloadBytesMaximum, bytes)
    meta.responses = meta.responses + 1
    TriggerClientEvent('synex_control:response', playerSource, sanitized)
end

RegisterCommand('synex-control', function(playerSource)
    if not playerValid(playerSource) or not allowed(playerSource, ACE.view) then return end
    openPlayers[playerSource] = true
    TriggerClientEvent('synex_control:open', playerSource, { schemaVersion = 1 })
end, false)

RegisterNetEvent('synex_control:request', function(candidate)
    local playerSource = source
    local requestId = type(candidate) == 'table' and candidate.requestId or nil
    if not playerValid(playerSource) then return end
    if not allowed(playerSource, ACE.view) then
        openPlayers[playerSource] = nil
        sendError(playerSource, requestId, 'ACCESS_REVOKED', false)
        TriggerClientEvent('synex_control:access_revoked', playerSource)
        return
    end
    openPlayers[playerSource] = true

    local request, validationError = SynexControlProtocol.validate(candidate)
    if not request then
        sendError(playerSource, requestId, validationError, false)
        return
    end
    if not takeTokens(playerSource,
        SynexControlProtocol.requestCost(request.operation, request.provider, request.view)) then
        sendError(playerSource, request.requestId, 'RATE_LIMITED', true)
        return
    end
    if (inFlightByPlayer[playerSource] or 0) >= SynexControlLimits.maximumInFlightPerPlayer then
        sendError(playerSource, request.requestId, 'RATE_LIMITED', true)
        return
    end

    inFlightByPlayer[playerSource] = (inFlightByPlayer[playerSource] or 0) + 1
    meta.requests = meta.requests + 1
    recordMetaEvent(meta.recentRequests)
    if request.operation == 'search' then
        meta.searches = meta.searches + 1
        recordMetaEvent(meta.recentSearches)
    end
    local startedAt = GetGameTimer()
    local permissions = permissionProjection(playerSource)
    local api, apiError = acquireApi()
    if not api then
        releaseInFlight(playerSource)
        sendError(playerSource, request.requestId, failureCode(apiError, 'CORE_UNAVAILABLE'), true)
        return
    end
    local accessClass, accessError = requestAccessClass(api, request)
    if not accessClass then
        releaseInFlight(playerSource)
        sendError(playerSource, request.requestId,
            failureCode(accessError, 'VIEW_UNAVAILABLE'), false)
        return
    end
    local routeAce = ACCESS_ACE[accessClass]
    if not routeAce or not allowed(playerSource, routeAce) then
        releaseInFlight(playerSource)
        openPlayers[playerSource] = nil
        clearCursorHandles(playerSource)
        sendError(playerSource, request.requestId, 'ACCESS_REVOKED', false)
        return
    end
    if not resolveCursorHandle(playerSource, request) then
        releaseInFlight(playerSource)
        sendError(playerSource, request.requestId, 'INVALID_CURSOR', false)
        return
    end

    local invoked, value, operationError = pcall(execute, api, request, permissions)
    releaseInFlight(playerSource)
    if not invoked or not value then
        local code = invoked and failureCode(operationError, 'PROVIDER_UNAVAILABLE')
            or 'PROVIDER_UNAVAILABLE'
        local retryable = invoked and type(operationError) == 'table'
            and operationError.retryable == true
        sendError(playerSource, request.requestId, code,
            retryable or code == 'PROVIDER_TIMEOUT' or code == 'PROVIDER_BUSY'
                or code == 'PROVIDER_UNAVAILABLE' or code == 'CORE_UNAVAILABLE')
        return
    end
    if not playerValid(playerSource) then return end
    local currentPermissions = permissionProjection(playerSource)
    local baseStillAllowed = allowed(playerSource, ACE.view)
    local routeStillAllowed = routeAce ~= nil and allowed(playerSource, routeAce)
    if not baseStillAllowed or not routeStillAllowed
        or permissionWasRevoked(permissions, currentPermissions) then
        openPlayers[playerSource] = nil
        clearCursorHandles(playerSource)
        sendError(playerSource, request.requestId, 'ACCESS_REVOKED', false)
        TriggerClientEvent('synex_control:access_revoked', playerSource, {
            code = 'ACCESS_REVOKED',
        })
        return
    end
    sendValue(playerSource, request, value, currentPermissions, startedAt)
end)

RegisterNetEvent('synex_control:closed', function()
    local playerSource = source
    if not playerValid(playerSource) then return end
    openPlayers[playerSource] = nil
    clearCursorHandles(playerSource)
end)

RegisterNetEvent('synex_control:nui_error', function(report)
    local playerSource = source
    if not playerValid(playerSource) or not allowed(playerSource, ACE.view)
        or type(report) ~= 'table' then return end
    for key in pairs(report) do
        if key ~= 'code' and key ~= 'view' then return end
    end
    if type(report.code) ~= 'string' or #report.code < 1 or #report.code > 64
        or report.code:match('^[A-Z][A-Z0-9_]*$') == nil then return end
    if report.view ~= nil and (type(report.view) ~= 'string' or #report.view > 64
        or report.view:match('^[a-z][a-z0-9_.-]*$') == nil) then return end
    if not takeTokens(playerSource, 1) then return end
    meta.nuiErrors = meta.nuiErrors + 1
end)

AddEventHandler('playerDropped', function()
    local playerSource = source
    requestBuckets[playerSource] = nil
    inFlightByPlayer[playerSource] = nil
    openPlayers[playerSource] = nil
    clearCursorHandles(playerSource)
end)

local function invalidateOpenViewers(resourceName, state)
    if type(resourceName) ~= 'string' or not resourceName:match('^synex_') then return end
    recordTransition(resourceName, state)
    for playerSource in pairs(openPlayers) do
        if playerValid(playerSource) and allowed(playerSource, ACE.view) then
            TriggerClientEvent('synex_control:invalidate', playerSource, {
                reason = 'RESOURCE_STATE_CHANGED',
                resource = resourceName,
                state = state,
            })
        end
    end
end

if type(CreateThread) == 'function' and type(Wait) == 'function' then
    CreateThread(function()
        while true do
            Wait(5000)
            local viewers = {}
            for playerSource in pairs(openPlayers) do viewers[#viewers + 1] = playerSource end
            for _, playerSource in ipairs(viewers) do
                if not playerValid(playerSource) or not allowed(playerSource, ACE.view) then
                    openPlayers[playerSource] = nil
                    clearCursorHandles(playerSource)
                    if playerValid(playerSource) then
                        TriggerClientEvent('synex_control:access_revoked', playerSource, {
                            code = 'ACCESS_REVOKED',
                        })
                    end
                end
            end
        end
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == CORE_RESOURCE then
        cachedApi = nil
        providerRegistered = false
    end
    clearCache()
    cursorHandles = {}
    invalidateOpenViewers(resourceName, 'started')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == CORE_RESOURCE then
        cachedApi = nil
        providerRegistered = false
    end
    clearCache()
    cursorHandles = {}
    invalidateOpenViewers(resourceName, 'stopped')
end)
