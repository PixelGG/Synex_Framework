local Native = {}

local API_RANGE = '^1.0.0'
local SERVICE_RANGE = '^1.0.0'
local UUID_PATTERN = '^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[1-5][0-9a-f][0-9a-f][0-9a-f]%-[89ab][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$'

local LIMITS = {
    callbackArguments = 16,
    callbackBytes = 16384,
    callbackPendingPerSource = 8,
    callbackPendingGlobal = 512,
    callbackRegistrations = 256,
    callbackRegistrationsPerConsumer = 64,
    callbackTimeoutMs = 10000,
    callbackRate = 8,
    callbackBurst = 16,
    clientConsumers = 128,
    lifecycleLoads = 1024,
    maximumDepth = 6,
    maximumEntries = 192,
    maximumStringBytes = 1024,
    maximumUsageEntries = 512,
    projectionEntries = 256,
    projectionTtlMs = 500,
    playerEnumeration = 256,
}

local PROJECTION_INVALIDATION_TOPICS = {
    'synex.accounts.transaction.posted',
    'synex.accounts.transaction.reversed',
    'synex.accounts.transaction.refunded',
    'synex.accounts.account.created',
    'synex.accounts.account.frozen',
    'synex.accounts.account.unfrozen',
    'synex.accounts.account.closed',
    'synex.groups.group.created',
    'synex.groups.group.activated',
    'synex.groups.group.updated',
    'synex.groups.group.suspended',
    'synex.groups.group.resumed',
    'synex.groups.group.archived',
    'synex.groups.group.dissolving',
    'synex.groups.group.deleted',
    'synex.groups.membership.draft',
    'synex.groups.membership.invited',
    'synex.groups.membership.applicant',
    'synex.groups.membership.under_review',
    'synex.groups.membership.approved',
    'synex.groups.membership.activated',
    'synex.groups.membership.probation',
    'synex.groups.membership.suspended',
    'synex.groups.membership.leave',
    'synex.groups.membership.inactive',
    'synex.groups.membership.terminated',
    'synex.groups.membership.primary_changed',
    'synex.groups.membership.visibility_changed',
    'synex.groups.grade.changed',
    'synex.groups.role.assigned',
    'synex.groups.role.removed',
    'synex.groups.role.changed',
    'synex.groups.role.expired',
    'synex.groups.assignment.expired',
    'synex.groups.duty_state.registered',
    'synex.groups.duty.started',
    'synex.groups.duty.updated',
    'synex.groups.duty.ended',
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
}

local PUBLICATION_SURFACES_BY_PROVIDER = {
    qb = {
        ['qb.shared.job_update_events'] = true,
        ['qb.shared.gang_update_events'] = true,
        ['qb.shared.duty_update_events'] = true,
        ['qb.shared.money_update_events'] = true,
    },
    qbx = {
        ['qbx.shared.group_update_events'] = true,
        ['qbx.shared.duty_update_events'] = true,
        ['qbx.shared.money_update_events'] = true,
    },
    esx = {
        ['esx.shared.job_update_events'] = true,
        ['esx.shared.account_update_events'] = true,
    },
}
local PUBLICATION_AUTHORIZATION_BY_PROVIDER = {
    qb = {
        ['lifecycle.publish'] = 'read',
        ['client.player_data.read'] = 'read',
        ['client.callback.invoke'] = 'callbacks',
    },
    qbx = {
        ['lifecycle.publish'] = 'read',
        ['client.player_data.read'] = 'read',
    },
    esx = {
        ['lifecycle.publish'] = 'read',
        ['client.player_data.read'] = 'read',
        ['client.callback.invoke'] = 'callbacks',
    },
}

local USAGE_OUTCOMES = {
    success = true,
    denied = true,
    unsupported = true,
    error = true,
    timeout = true,
    rate_limited = true,
}

local TIMER_MODULUS = 4294967296
local MAXIMUM_SAFE_INTEGER = 9007199254740991

local function bridgeError(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
end

local function finiteInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
        and math.type(value) == 'integer' and value >= minimum and value <= maximum
end

local function boundedString(value, maximum)
    if type(value) ~= 'string' or value == '' or #value > maximum
        or value:find('[%z\1-\31\127]') then return nil end
    return value
end

local function copyBounded(value, budget, depth, seen)
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' then return value end
    if kind == 'number' then
        if value == value and value ~= math.huge and value ~= -math.huge then return value end
        return nil
    end
    if kind == 'string' then return value:sub(1, LIMITS.maximumStringBytes) end
    if kind ~= 'table' or depth >= LIMITS.maximumDepth or seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if budget.remaining <= 0 then break end
        if type(key) == 'number' or type(key) == 'string' then
            budget.remaining = budget.remaining - 1
            local safeKey = type(key) == 'string' and key:sub(1, 96) or key
            local safeValue = copyBounded(item, budget, depth + 1, seen)
            if safeValue ~= nil then result[safeKey] = safeValue end
        end
    end
    seen[value] = nil
    return result
end

local function safeCopy(value)
    return copyBounded(value, { remaining = LIMITS.maximumEntries }, 0, {})
end

local function strictCopy(value, options)
    local foundation = type(SynexBridgeKernel) == 'table'
        and SynexBridgeKernel.Foundation or nil
    if type(foundation) == 'table' and type(foundation.copyDto) == 'function' then
        return foundation.copyDto(value, options or {
            maximumDepth = LIMITS.maximumDepth,
            maximumEntries = LIMITS.maximumEntries,
            maximumBytes = LIMITS.callbackBytes,
            maximumStringBytes = LIMITS.maximumStringBytes,
            maximumArrayItems = LIMITS.maximumEntries,
            maximumObjectProperties = LIMITS.maximumEntries,
        })
    end
    local copied = safeCopy(value)
    if type(value) == 'table' and type(copied) ~= 'table' then
        return nil, bridgeError('COMPAT_DTO_INVALID', 'The compatibility value is invalid.')
    end
    local encodedOk, encoded = pcall(json.encode, copied)
    if not encodedOk or type(encoded) ~= 'string' or #encoded > LIMITS.callbackBytes then
        return nil, bridgeError('COMPAT_DTO_LIMIT', 'The compatibility value exceeds its bound.')
    end
    return copied, nil
end

local uuidCounter = 0
local uuidEpoch = ((os.time() & 0xffffffff) ~ (GetGameTimer() & 0xffffffff)) & 0xffffffff
local function uuidV4()
    uuidCounter = (uuidCounter + 1) & 0xffffffff
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return template:gsub('[xy]', function(symbol)
        local value = (math.random(0, 15) ~ (uuidCounter & 0xf) ~ (uuidEpoch & 0xf)) & 0xf
        if symbol == 'y' then value = (value & 0x3) | 0x8 end
        uuidCounter = ((uuidCounter << 1) | (uuidCounter >> 31)) & 0xffffffff
        uuidEpoch = ((uuidEpoch << 3) | (uuidEpoch >> 29)) & 0xffffffff
        return ('%x'):format(value)
    end)
end

local function validUuid(value)
    return type(value) == 'string' and value:match(UUID_PATTERN) ~= nil
end

local function validPublicId(value)
    return type(value) == 'string' and #value >= 8 and #value <= 48
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function validSubjectId(value)
    return type(value) == 'string' and #value >= 3 and #value <= 48
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function validCallbackName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 96
        and value:match('^[A-Za-z0-9_:%-%.]+$') ~= nil
end

local function validConsumer(value)
    return type(value) == 'string' and #value >= 2 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    local valueType = type(value)
    if valueType ~= 'table' and valueType ~= 'userdata' then return false end
    local metatable = getmetatable(value)
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetatable = pcall(debug.getmetatable, value)
        if readable then metatable = rawMetatable end
    end
    return type(metatable) == 'table' and type(rawget(metatable, '__call')) == 'function'
end

Native.isCallable = isCallable

local MAXIMUM_USAGE_ADAPTERS = 1
local usageAdapters = {}
local usageAdaptersOverflow = false
local usageExportRegistered = false

local function registerUsageAdapter(adapter)
    if #usageAdapters < MAXIMUM_USAGE_ADAPTERS then
        usageAdapters[#usageAdapters + 1] = adapter
    else
        usageAdaptersOverflow = true
    end
    if usageExportRegistered or not isCallable(exports) then return end
    local registered = pcall(exports, 'GetControlCompatibilityUsage', function()
        if type(GetInvokingResource) ~= 'function'
            or GetInvokingResource() ~= 'synex_bridge' then
            return nil, bridgeError('CALLER_INVALID',
                'Compatibility usage is available only to the Synex bridge provider.')
        end
        local snapshots = {}
        for index, candidate in ipairs(usageAdapters) do
            local read, snapshot = pcall(candidate.usageSnapshot, candidate)
            if not read or type(snapshot) ~= 'table' then
                return nil, bridgeError('USAGE_SNAPSHOT_UNAVAILABLE',
                    'Compatibility usage could not be read.', true)
            end
            snapshots[index] = snapshot
        end
        return {
            schemaVersion = 1,
            snapshots = snapshots,
            truncated = usageAdaptersOverflow,
        }
    end)
    usageExportRegistered = registered == true
end

function Native.create(options)
    assert(type(options) == 'table', 'native bridge options are required')
    local framework = assert(boundedString(options.framework, 16), 'framework is invalid')
    local capabilityPrefix = assert(boundedString(options.capabilityPrefix, 64), 'capabilityPrefix is invalid')
    local requestEvent = assert(boundedString(options.requestEvent, 96), 'requestEvent is invalid')
    local responseEvent = assert(boundedString(options.responseEvent, 96), 'responseEvent is invalid')
    local historicalResource = options.historicalResource
    if historicalResource ~= nil and (not boundedString(historicalResource, 64)
        or not historicalResource:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')) then
        error('historicalResource is invalid')
    end
    local resourceName = GetCurrentResourceName()
    local api
    local callbacks = {}
    local callbackOwners = {}
    local callbackRegistrations = 0
    local callbackRegistrationsByOwner = {}
    local pending = {}
    local pendingBySource = {}
    local pendingTotal = 0
    local buckets = {}
    local usage = {}
    local usageSize = 0
    local warningTimes = {}
    local frameworkConflict = false
    local projections = {}
    local projectionCount = 0
    local projectionRevisions = {}
    local projectionDomainRevision = 0
    local projectionInvalidationReady = false
    local projectionInvalidationTokens = {}
    local bindProjectionInvalidation
    local lifecycleLoads = {}
    local lifecycleLoadCount = 0
    local lifecycleDefinition
    local lifecycleToken
    local lifecycleRebindGeneration = 0
    local lifecycleRefreshPending = {}
    local lifecycleRefreshGeneration = {}
    local queueLifecycleRefresh
    local configuredAliases = options.moneyAliases or {}
    local discoverAccountMappings = options.discoverAccountMappings == true
    if type(configuredAliases) ~= 'table' or getmetatable(configuredAliases) ~= nil then
        error('moneyAliases must be a dense array')
    end
    local aliasCount = 0
    for index in pairs(configuredAliases) do
        if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > 32 then
            error('moneyAliases must be a dense array')
        end
        aliasCount = aliasCount + 1
    end
    if aliasCount > 32 then
        error('moneyAliases must contain at most 32 aliases')
    end
    local accountAliases, accountAliasSet = {}, {}
    for index = 1, aliasCount do
        local alias = configuredAliases[index]
        if not boundedString(alias, 32) or not alias:match('^[a-z][a-z0-9_]*$')
            or accountAliasSet[alias] then
            error(('invalid compatibility account alias: %s'):format(tostring(alias)))
        end
        accountAliases[index] = alias
        accountAliasSet[alias] = true
    end
    local metricPrefix = resourceName:gsub('[^A-Za-z0-9_]', '_') .. '_'

    local function emitMetric(kind, suffix, labels, value)
        local metrics = api and api.Metrics or nil
        local writer = type(metrics) == 'table' and metrics[kind] or nil
        if not isCallable(writer) then return end
        pcall(writer, metricPrefix .. suffix, labels or {}, value)
    end

    local function callBridgeExport(name, ...)
        local proxyRead, proxy = pcall(function() return exports.synex_bridge end)
        if not proxyRead or proxy == nil then
            return nil, bridgeError('COMPAT_BRIDGE_UNAVAILABLE',
                'The compatibility coordination service is unavailable.', true)
        end
        local methodRead, method = pcall(function() return proxy[name] end)
        if not methodRead or not isCallable(method) then
            return nil, bridgeError('COMPAT_BRIDGE_UNAVAILABLE',
                'The compatibility coordination service is unavailable.', true)
        end
        -- Cfx export funcrefs are invoked without a synthetic receiver.  Some
        -- test doubles model methods with a receiver, so use that form only
        -- when the real export invocation itself could not be made.
        local arguments = table.pack(...)
        local called, value, operationError = pcall(
            method, table.unpack(arguments, 1, arguments.n))
        if not called then
            called, value, operationError = pcall(
                method, proxy, table.unpack(arguments, 1, arguments.n))
        end
        if not called then
            return nil, bridgeError('COMPAT_BRIDGE_UNAVAILABLE',
                'The compatibility coordination service failed.', true)
        end
        if value == false and type(operationError) == 'table' then value = nil end
        return value, operationError
    end

    local function getApi()
        if api then return api, nil end
        local ok, resolved, resolveError = pcall(function()
            return exports.synex_core:GetAPI(API_RANGE)
        end)
        if not ok or type(resolved) ~= 'table' then
            return nil, type(resolveError) == 'table' and resolveError
                or bridgeError('SYNEX_UNAVAILABLE', 'The Synex API is unavailable.', true)
        end
        api = resolved
        if bindProjectionInvalidation then
            projectionInvalidationReady = bindProjectionInvalidation(resolved) == true
        end
        return api, nil
    end

    local function consumerIsActive(consumer)
        if type(consumer) ~= 'string' or consumer == '' or consumer == resourceName or consumer == 'synex_core' then
            return false
        end
        local state = GetResourceState(consumer)
        return state == 'started' or state == 'starting'
    end

    local function detectFrameworkConflict()
        if not historicalResource or type(GetResourceMetadata) ~= 'function' then
            return false
        end
        local state = GetResourceState(historicalResource)
        if state ~= 'started' and state ~= 'starting' then return false end
        local read, marker = pcall(
            GetResourceMetadata, historicalResource, 'synex_compatibility_facade', 0)
        return not read or marker ~= 'true'
    end

    local function refreshFrameworkConflict()
        local conflict = detectFrameworkConflict()
        if conflict and not frameworkConflict then
            local encoded, message = pcall(json.encode, {
                level = 'error', event = 'compatibility_framework_conflict',
                framework = framework, resource = historicalResource,
                code = 'COMPAT_FRAMEWORK_CONFLICT',
            })
            if encoded and type(message) == 'string' then print(message) end
        end
        frameworkConflict = conflict
    end

    refreshFrameworkConflict()

    local function usageTick()
        return GetGameTimer() % TIMER_MODULUS
    end

    local function usageOutcome(errorValue)
        local code = type(errorValue) == 'table' and errorValue.code or ''
        if code:find('DENIED', 1, true) or code:find('DISABLED', 1, true)
            or code == 'CALLER_INVALID' or code == 'COMPAT_FRAMEWORK_CONFLICT' then
            return 'denied'
        end
        if code:find('UNSUPPORTED', 1, true) or code:find('MISSING', 1, true)
            or code:find('NOT_FOUND', 1, true) then
            return 'unsupported'
        end
        if code:find('TIMEOUT', 1, true) then return 'timeout' end
        if code:find('LIMIT', 1, true) or code:find('RATE', 1, true) then
            return 'rate_limited'
        end
        return 'error'
    end

    local function beginUsage(consumer, operation)
        if not boundedString(consumer, 64)
            or not consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
            or not boundedString(operation, 128)
            or not operation:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
            return nil
        end
        local key = consumer .. ':' .. operation
        local now = usageTick()
        local entry = usage[key]
        if not entry then
            if usageSize >= LIMITS.maximumUsageEntries then return nil end
            entry = {
                resource = consumer,
                operation = operation,
                calls = 0,
                firstSeenMs = now,
                outcomes = {
                    success = 0,
                    denied = 0,
                    unsupported = 0,
                    deprecated = 0,
                    error = 0,
                    timeout = 0,
                    rate_limited = 0,
                },
                latency = { samples = 0, totalMs = 0, maximumMs = 0 },
            }
            usage[key] = entry
            usageSize = usageSize + 1
        end
        if entry.calls >= MAXIMUM_SAFE_INTEGER then return nil end
        if now < (entry.lastSeenMs or entry.firstSeenMs) then
            entry.firstSeenMs = now
        end
        entry.calls = math.min(MAXIMUM_SAFE_INTEGER, entry.calls + 1)
        entry.outcomes.deprecated = math.min(
            MAXIMUM_SAFE_INTEGER, entry.outcomes.deprecated + 1)
        entry.lastSeenMs = now
        local previous = warningTimes[key]
        if not previous then
            warningTimes[key] = now
            local encoded, message = pcall(json.encode, {
                level = 'warn', event = 'deprecated_compatibility_api_used', framework = framework,
                resource = consumer, operation = operation,
            })
            if encoded and type(message) == 'string' then print(message) end
        end
        return { entry = entry, startedAt = now, finished = false }
    end

    local function finishUsage(token, outcome, errorValue)
        if type(token) ~= 'table' or token.finished == true
            or not USAGE_OUTCOMES[outcome] then return end
        token.finished = true
        local entry = token.entry
        if type(entry) ~= 'table' or type(entry.outcomes) ~= 'table'
            or type(entry.latency) ~= 'table' then return end
        local now = usageTick()
        local elapsed = now >= token.startedAt and now - token.startedAt
            or TIMER_MODULUS - token.startedAt + now
        entry.outcomes[outcome] = math.min(
            MAXIMUM_SAFE_INTEGER, (entry.outcomes[outcome] or 0) + 1)
        entry.latency.samples = math.min(
            MAXIMUM_SAFE_INTEGER, entry.latency.samples + 1)
        entry.latency.totalMs = math.min(
            MAXIMUM_SAFE_INTEGER, entry.latency.totalMs + elapsed)
        entry.latency.maximumMs = math.max(entry.latency.maximumMs, elapsed)

        local operation = entry.operation
        local labels = { operation = operation, outcome = outcome }
        emitMetric('increment', 'compat_calls_total', labels, 1)
        emitMetric('increment', 'compat_deprecated_total', { operation = operation }, 1)
        emitMetric('observe', 'compat_operation_duration_ms',
            { operation = operation }, elapsed)
        if outcome == 'denied' then
            emitMetric('increment', 'compat_denials_total', { operation = operation }, 1)
        elseif outcome == 'unsupported' then
            emitMetric('increment', 'compat_unsupported_total', { operation = operation }, 1)
        elseif outcome == 'error' then
            emitMetric('increment', 'compat_provider_error_total', { operation = operation }, 1)
        end
        local errorCode = type(errorValue) == 'table' and errorValue.code or ''
        if errorCode == 'COMPAT_ADAPTER_MISSING' then
            emitMetric('increment', 'compat_adapter_missing_total', { operation = operation }, 1)
        end
        if errorCode == 'COMPAT_STALE_SESSION' then
            emitMetric('increment', 'compat_stale_session_rejected', { operation = operation }, 1)
        end
        if operation == 'callback.invoke' then
            emitMetric('increment', 'compat_callbacks_total', { outcome = outcome }, 1)
            if outcome == 'timeout' then
                emitMetric('increment', 'compat_callback_timeout_total', {}, 1)
            elseif outcome == 'rate_limited' then
                emitMetric('increment', 'compat_callback_rate_limit_total', {}, 1)
            end
        elseif operation:sub(1, 6) == 'money.' then
            emitMetric('increment', 'compat_money_translation_total', { outcome = outcome }, 1)
            if outcome ~= 'success' then
                emitMetric('increment', 'compat_money_translation_failed', { operation = operation }, 1)
            end
        end
    end

    local function finishResult(token, value, errorValue)
        finishUsage(token, value ~= nil and value ~= false
            and 'success' or usageOutcome(errorValue), errorValue)
        return value, errorValue
    end

    local function checkConsumerCapability(
        resolved, consumer, capability, operation, gate, traceId)
        local capabilities = resolved.Capabilities
        local checkResource = type(capabilities) == 'table'
            and capabilities.checkResource or nil
        if not isCallable(checkResource) then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core delegated capability boundary is unavailable.', true)
        end
        local checked, allowed, authorizationError = pcall(
            checkResource, consumer, capability,
            ('compat.%s.%s.%s'):format(framework, operation, gate))
        if not checked then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core delegated capability check failed.', true)
        end
        if not allowed then
            local denied = type(authorizationError) == 'table' and authorizationError
                or bridgeError('COMPAT_CONSUMER_DENIED',
                    'The Core denied a required consumer capability.')
            if type(denied) == 'table' and denied.traceId == nil then
                denied.traceId = traceId
            end
            return nil, denied
        end
        return true, nil
    end

    local function checkConsumerCapabilities(
        resolved, consumer, compatibilityCapability, operation, nativeCapabilities, traceId)
        local requiredCapabilities = { compatibilityCapability }
        for _, capability in ipairs(nativeCapabilities) do
            requiredCapabilities[#requiredCapabilities + 1] = capability
        end
        for index, capability in ipairs(requiredCapabilities) do
            local allowed, authorizationError = checkConsumerCapability(
                resolved, consumer, capability, operation,
                index == 1 and 'compatibility' or 'native', traceId)
            if not allowed then
                return nil, authorizationError
            end
        end
        return true, nil
    end

    local function authorize(consumer, suffix, operation, deferCompletion)
        local usageToken = beginUsage(consumer, operation)
        local function reject(errorValue)
            finishUsage(usageToken, usageOutcome(errorValue), errorValue)
            return nil, errorValue
        end
        local nativeCapabilities = NATIVE_CAPABILITIES_BY_OPERATION[operation]
        if type(nativeCapabilities) ~= 'table' or #nativeCapabilities < 1 then
            return reject(bridgeError('COMPAT_API_UNSUPPORTED',
                'The compatibility operation has no closed native capability policy.'))
        end
        if frameworkConflict then
            return reject(bridgeError('COMPAT_FRAMEWORK_CONFLICT',
                'A native legacy framework conflicts with this Synex compatibility provider.'))
        end
        if not consumerIsActive(consumer) then
            return reject(bridgeError(
                'CALLER_INVALID', 'The compatibility consumer is not active.'))
        end
        local coordination, coordinationError = callBridgeExport(
            'AuthorizeCompatibilityConsumer', {
                provider = framework,
                providerResource = resourceName,
                consumer = consumer,
                capability = capabilityPrefix .. '.' .. suffix,
                operation = operation,
            })
        if not coordination then return reject(coordinationError) end
        if type(coordination) ~= 'table'
            or (coordination.authority ~= 'core'
                and coordination.authority ~= 'operator_registry')
            or (coordination.mode ~= 'strict' and coordination.mode ~= 'compat'
                and coordination.mode ~= 'silent')
            or not boundedString(coordination.traceId, 64)
            or #coordination.traceId < 8
            or not coordination.traceId:match('^[A-Za-z0-9_.:%-]+$') then
            return reject(bridgeError('COMPAT_AUTHORIZATION_INVALID',
                'The compatibility authorization result is invalid.', true))
        end
        local resolved, resolveError = getApi()
        if not resolved then return reject(resolveError) end
        local allowed, authorizationError = checkConsumerCapabilities(
            resolved, consumer, capabilityPrefix .. '.' .. suffix,
            operation, nativeCapabilities, coordination.traceId)
        if not allowed then
            return reject(authorizationError)
        end
        if deferCompletion ~= true then finishUsage(usageToken, 'success') end
        return coordination, nil, usageToken
    end

    local function runTraced(authorization, consumer, legacyApi, handler)
        if type(authorization) ~= 'table'
            or not boundedString(authorization.traceId, 64)
            or #authorization.traceId < 8
            or not authorization.traceId:match('^[A-Za-z0-9_.:%-]+$')
            or not boundedString(consumer, 64)
            or not consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
            or not boundedString(legacyApi, 64)
            or not legacyApi:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            or not isCallable(handler) then
            return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                'The compatibility trace boundary is invalid.', true)
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local tracing = resolved.Tracing
        local run = type(tracing) == 'table' and tracing.run or nil
        if not isCallable(run) then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core compatibility trace boundary is unavailable.', true)
        end
        local operation = ('compat.%s.%s'):format(framework, legacyApi)
        local called, value, operationError = pcall(run, {
            operation = operation,
            traceId = authorization.traceId,
            compatProvider = framework,
            consumer = consumer,
            legacyApi = legacyApi,
        }, handler)
        if not called then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core compatibility trace boundary failed.', true)
        end
        if value == false and type(operationError) == 'table' then value = nil end
        return value, operationError
    end

    local function validateSource(playerSource)
        return finiteInteger(playerSource, 1, 65534) and GetPlayerName(tostring(playerSource)) ~= nil
    end

    local function denseArray(value, maximum)
        if type(value) ~= 'table' or #value > maximum then return false end
        local count, maximumIndex = 0, 0
        for key in pairs(value) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > maximum then return false end
            count = count + 1
            maximumIndex = math.max(maximumIndex, key)
        end
        return count == maximumIndex and count == #value
    end

    local function fenceMatches(fence, session, character)
        return type(fence) == 'table' and getmetatable(fence) == nil
            and type(session) == 'table' and type(character) == 'table'
            and fence.sessionId == session.id
            and fence.sourceGeneration == session.sourceGeneration
            and fence.characterId == session.characterId
            and character.id == fence.characterId
    end

    local function currentAuthority(playerSource, expectedFence)
        if not validateSource(playerSource) then
            return nil, nil, nil,
                bridgeError('INVALID_SOURCE', 'source must identify a connected player.')
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, nil, nil, resolveError end
        local session, sessionError = resolved.Players.getBySource(playerSource)
        if not session then
            return nil, nil, nil, sessionError
                or bridgeError('SESSION_NOT_FOUND', 'The Synex session is unavailable.')
        end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string'
            or not finiteInteger(session.sourceGeneration, 1, 9007199254740991)
            or type(session.id) ~= 'string' then
            return nil, nil, nil,
                bridgeError('CHARACTER_NOT_ACTIVE', 'The player has no active Synex character.')
        end
        local character, characterError = resolved.Characters.getActive(playerSource)
        if not character then return nil, nil, nil, characterError end
        if type(character) ~= 'table' or character.id ~= session.characterId then
            return nil, nil, nil, bridgeError(
                'INVALID_CHARACTER_SNAPSHOT',
                'The active character projection does not match the authoritative session.')
        end
        if expectedFence ~= nil and not fenceMatches(expectedFence, session, character) then
            return nil, nil, nil, bridgeError(
                'COMPAT_STALE_SESSION',
                'The legacy player object belongs to a stale source generation.')
        end
        return resolved, session, character, nil
    end

    local function connectedSources()
        if not isCallable(GetPlayers) then
            return nil, bridgeError('COMPAT_PLAYER_ENUMERATION_UNAVAILABLE',
                'The Cfx player enumeration boundary is unavailable.', true)
        end
        local called, rawPlayers = pcall(GetPlayers)
        if not called or type(rawPlayers) ~= 'table' then
            return nil, bridgeError('COMPAT_PLAYER_ENUMERATION_UNAVAILABLE',
                'The Cfx player enumeration boundary failed.', true)
        end
        local sources, seen, count = {}, {}, 0
        for key, rawSource in pairs(rawPlayers) do
            count = count + 1
            if count > LIMITS.playerEnumeration
                or type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > #rawPlayers then
                return nil, bridgeError('COMPAT_PLAYER_ENUMERATION_LIMIT',
                    'Connected player enumeration exceeded its safe bound.')
            end
            local sourceValue = tonumber(rawSource)
            if not finiteInteger(sourceValue, 1, 65534) or seen[sourceValue] then
                return nil, bridgeError('COMPAT_PLAYER_ENUMERATION_INVALID',
                    'Connected player enumeration returned invalid sources.', true)
            end
            seen[sourceValue] = true
            sources[#sources + 1] = sourceValue
        end
        if count ~= #rawPlayers then
            return nil, bridgeError('COMPAT_PLAYER_ENUMERATION_INVALID',
                'Connected player enumeration must be a dense array.', true)
        end
        table.sort(sources)
        return sources, nil
    end

    local function activeSources(resolved)
        local sources, sourceError = connectedSources()
        if not sources then return nil, sourceError end
        local active = {}
        for _, playerSource in ipairs(sources) do
            local session, sessionError = resolved.Players.getBySource(playerSource)
            if session ~= nil then
                if type(session) ~= 'table' or not boundedString(session.state, 32) then
                    return nil, bridgeError('INVALID_SESSION_SNAPSHOT',
                        'Synex returned an invalid active-session projection.', true)
                end
                if session.state == 'ACTIVE' then
                    if not boundedString(session.id, 64)
                        or not boundedString(session.characterId, 48)
                        or not finiteInteger(
                            session.sourceGeneration, 1, MAXIMUM_SAFE_INTEGER) then
                        return nil, bridgeError('INVALID_SESSION_SNAPSHOT',
                            'Synex returned an invalid active-session projection.', true)
                    end
                    active[#active + 1] = playerSource
                end
            elseif sessionError ~= nil then
                return nil, sessionError
            end
        end
        return active, nil
    end

    local function reverseIdentity(identifier)
        if not boundedString(identifier, 191) then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The compatibility identifier is invalid.')
        end
        local identifierType = framework == 'esx' and 'identifier' or 'citizenid'
        local identity, identityError = callBridgeExport(
            'FindCompatibilityIdentity', {
                provider = framework,
                identifierType = identifierType,
                identifier = identifier,
            })
        if identity == false then return false, nil end
        if not identity then return nil, identityError end
        if type(identity) ~= 'table' or identity.provider ~= framework
            or identity.identifierType ~= identifierType
            or identity.identifier ~= identifier
            or not boundedString(identity.characterId, 48) then
            return nil, bridgeError('COMPAT_IDENTITY_INVALID',
                'The compatibility identity projection is invalid.', true)
        end
        return identity, nil
    end

    local function onlineSourceForCharacter(resolved, characterId)
        local sources, sourceError = activeSources(resolved)
        if not sources then return nil, sourceError end
        local found
        for _, playerSource in ipairs(sources) do
            local session, sessionError = resolved.Players.getBySource(playerSource)
            if not session then
                return nil, sessionError or bridgeError('COMPAT_STALE_SESSION',
                    'A player session changed during compatibility lookup.', true)
            end
            if session.characterId == characterId then
                if found ~= nil then
                    return nil, bridgeError('COMPAT_IDENTITY_AMBIGUOUS',
                        'More than one active session matches the compatibility identity.')
                end
                found = playerSource
            end
        end
        return found or false, nil
    end

    local function activeSourceForReference(reference)
        if type(reference) == 'number' then
            if not validateSource(reference) then
                return nil, bridgeError('INVALID_SOURCE',
                    'source must identify a connected player.')
            end
            return reference, nil
        end
        if type(reference) ~= 'string' then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The player reference must be a source or compatibility identifier.')
        end
        local identity, identityError = reverseIdentity(reference)
        if identity == false then return false, nil end
        if not identity then return nil, identityError end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        return onlineSourceForCharacter(resolved, identity.characterId)
    end

    local function serviceTraceContext(traceId)
        return traceId and { traceId = traceId } or nil
    end

    local function validAccountMapping(mapping, alias)
        return type(mapping) == 'table' and mapping.alias == alias
            and boundedString(mapping.id, 96)
            and boundedString(mapping.version, 32)
            and boundedString(mapping.currencyCode, 16)
            and mapping.currencyCode:match('^[a-z][a-z0-9_]*$')
            and boundedString(mapping.accountKey, 31)
            and mapping.accountKey:match('^[a-z][a-z0-9_]*$')
            and mapping.accountRole == 'asset'
            and finiteInteger(mapping.minorUnit, 0, 6)
            and (mapping.legacyName == nil or boundedString(mapping.legacyName, 32)
                and mapping.legacyName:match('^[a-z][a-z0-9_.%-]*$'))
            and (mapping.label == nil or boundedString(mapping.label, 64))
            and (mapping.round == nil or type(mapping.round) == 'boolean')
            and (mapping.status == 'CERTIFIED'
                or mapping.status == 'COMPATIBLE'
                or mapping.status == 'PARTIAL')
    end

    local function accountMappings()
        local mappings, seen = {}, {}
        if discoverAccountMappings then
            local listed, listError = callBridgeExport(
                'ListCompatibilityAccountMappings', { provider = framework })
            if not listed then return nil, listError end
            if type(listed) ~= 'table' or listed.truncated ~= false
                or not denseArray(listed.items, 256) then
                return nil, bridgeError('COMPAT_MAPPING_MISSING',
                    'The compatibility account mapping catalog is invalid.')
            end
            for _, mapping in ipairs(listed.items) do
                local alias = type(mapping) == 'table' and mapping.alias or nil
                if not boundedString(alias, 32) or seen[alias]
                    or not validAccountMapping(mapping, alias) then
                    return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                        'The compatibility account mapping catalog is ambiguous.')
                end
                seen[alias] = true
                mappings[#mappings + 1] = mapping
            end
        else
            for _, alias in ipairs(accountAliases) do
                local mapping, mappingError = callBridgeExport(
                    'ResolveCompatibilityAccountMapping', {
                        provider = framework,
                        alias = alias,
                    })
                if not mapping then return nil, mappingError end
                if not validAccountMapping(mapping, alias) then
                    return nil, bridgeError('COMPAT_MAPPING_MISSING',
                        ('The %s account mapping is invalid.'):format(alias))
                end
                mappings[#mappings + 1] = mapping
            end
        end
        table.sort(mappings, function(left, right) return left.alias < right.alias end)
        return mappings, nil
    end

    local function accountMappingByAlias(alias)
        if not boundedString(alias, 32)
            or not alias:match('^[a-z][a-z0-9_]*$') then
            return nil, bridgeError('COMPAT_MAPPING_MISSING',
                'The compatibility account alias is invalid.')
        end
        local mappings, mappingsError = accountMappings()
        if not mappings then return nil, mappingsError end
        for _, mapping in ipairs(mappings) do
            if mapping.alias == alias then return mapping, nil end
        end
        return nil, bridgeError('COMPAT_MAPPING_MISSING',
            ('No reviewed account mapping exists for %s.'):format(alias))
    end

    local function mapAccounts(resolved, character, traceId)
        local projectionMappings, mappedTargets = {}, {}
        local mappings, mappingsError = accountMappings()
        if not mappings then return nil, mappingsError end
        for _, mapping in ipairs(mappings) do
            local alias = mapping.alias
            local scopedAccountKey = mapping.accountKey .. '_'
                .. character.id:gsub('%-', '')
            if #scopedAccountKey > 64
                or not scopedAccountKey:match('^[a-z][a-z0-9_]*$') then
                return nil, bridgeError('COMPAT_MAPPING_MISSING',
                    ('The %s account mapping cannot form an owner-scoped key.'):format(alias))
            end
            local targetKey = table.concat({
                mapping.currencyCode, scopedAccountKey,
                mapping.accountRole, tostring(mapping.minorUnit),
            }, ':')
            if mappedTargets[targetKey] then
                return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                    ('The %s and %s aliases resolve to the same account target.'):format(
                        mappedTargets[targetKey], alias))
            end
            mappedTargets[targetKey] = alias
            projectionMappings[alias] = {
                currency = mapping.currencyCode,
                accountKey = scopedAccountKey,
                accountRole = mapping.accountRole,
                minorUnit = mapping.minorUnit,
                legacyName = mapping.legacyName or alias,
                label = mapping.label or mapping.legacyName or alias,
                round = mapping.round ~= false,
            }
        end
        local accounts, accountError = resolved.Services.call(
            'synex.accounts', SERVICE_RANGE, 'list_by_owner', {
                owner_kind = 'character', owner_ref = character.id,
                actor_kind = 'character', actor_ref = character.id,
                limit = 50,
            }, serviceTraceContext(traceId))
        if not accounts then return nil, accountError end
        if type(accounts) ~= 'table' or not denseArray(accounts.items, 50) then
            return nil, bridgeError('INVALID_ACCOUNT_SNAPSHOT',
                'Synex returned an invalid account projection.')
        end
        if accounts.next_cursor ~= nil then
            return nil, bridgeError('ACCOUNT_PROJECTION_TRUNCATED',
                'The compatible account projection is incomplete; money lookup is fail-closed.')
        end

        local matches, money, accountIds, accountSequences, definitions = {}, {}, {}, {}, {}
        for alias in pairs(projectionMappings) do matches[alias] = {} end
        for _, account in ipairs(accounts.items) do
            if type(account) ~= 'table' or account.owner_kind ~= 'character'
                or account.owner_ref ~= character.id
                or (account.status ~= 'active' and account.status ~= 'frozen'
                    and account.status ~= 'closed')
                or not validUuid(account.account_id)
                or not boundedString(account.currency_code, 16)
                or not account.currency_code:match('^[a-z][a-z0-9_]*$')
                or not boundedString(account.account_key, 64)
                or not account.account_key:match('^[a-z][a-z0-9_]*$')
                or not finiteInteger(account.minor_unit, 0, 6)
                or not finiteInteger(account.booked_minor,
                    -9007199254740991, 9007199254740991)
                or not finiteInteger(account.sequence, 0, 9007199254740991)
                or account.account_role ~= 'asset' then
                return nil, bridgeError('INVALID_ACCOUNT_SNAPSHOT',
                    'Synex returned an invalid account projection.')
            end
            if account.status == 'active' then
                for alias, mapping in pairs(projectionMappings) do
                    if account.currency_code == mapping.currency
                        and account.account_key == mapping.accountKey
                        and account.account_role == mapping.accountRole
                        and account.minor_unit == mapping.minorUnit then
                        local bucket = matches[alias]
                        bucket[#bucket + 1] = account
                    end
                end
            end
        end
        for alias, bucket in pairs(matches) do
            if #bucket > 1 then
                return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                    ('More than one account matches the %s compatibility alias.'):format(alias))
            end
            if #bucket == 0 then
                return nil, bridgeError('MONEY_ACCOUNT_NOT_FOUND',
                    ('No active account matches the %s compatibility alias.'):format(alias))
            end
            money[alias] = bucket[1].booked_minor
            accountIds[alias] = bucket[1].account_id
            accountSequences[alias] = bucket[1].sequence
            local mapping = projectionMappings[alias]
            definitions[alias] = {
                alias = alias,
                name = mapping.legacyName,
                legacyName = mapping.legacyName,
                label = mapping.label,
                round = mapping.round,
                minorUnit = mapping.minorUnit,
            }
        end
        return {
            money = money,
            accountIds = accountIds,
            accountSequences = accountSequences,
            accountDefinitions = definitions,
            accounts = accounts.items,
        }, nil
    end

    local function readGroups(resolved, character, traceId)
        local groups, groupsError = resolved.Services.call(
            'synex.groups', SERVICE_RANGE, 'compatibility_snapshot', {
                actor_character_id = character.id,
                limit = 8,
            }, serviceTraceContext(traceId))
        if not groups then return nil, groupsError end
        if type(groups) ~= 'table' or not denseArray(groups.items, 8)
            or type(groups.truncated) ~= 'boolean'
            or groups.truncated or groups.next_cursor ~= nil then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The Groups compatibility projection is incomplete.')
        end
        for _, membership in ipairs(groups.items) do
            if type(membership) ~= 'table' or type(membership.group) ~= 'table'
                or not boundedString(membership.membership_id, 48)
                or not boundedString(membership.group.group_id, 48)
                or not boundedString(membership.group.key, 64)
                or not boundedString(membership.group.type, 64)
                or not boundedString(membership.group.name, 96)
                or not boundedString(membership.group.label, 96)
                or type(membership.is_primary) ~= 'boolean'
                or not denseArray(membership.roles, 8)
                or membership.roles_truncated ~= false then
                return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                    'The Groups compatibility projection is invalid or truncated.')
            end
        end
        local projected, projectionError = callBridgeExport(
            'ProjectCompatibilityGroups', {
                provider = framework,
                groups = groups,
            })
        if not projected then return nil, projectionError end
        if type(projected) ~= 'table' or projected.truncated ~= false
            or not denseArray(projected.items, 8) then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The mapped Groups compatibility projection is invalid.')
        end
        return projected, nil
    end

    local function projectionRevision(playerSource)
        return projectionRevisions[playerSource] or 0
    end

    local function cacheKey(playerSource, session, revision, domainRevision)
        return ('%d:%s:%d:%s:%d:%d'):format(playerSource, session.id,
            session.sourceGeneration, session.characterId, revision, domainRevision)
    end

    local function invalidateProjection(playerSource)
        local prefix = tostring(playerSource) .. ':'
        for key in pairs(projections) do
            if key:sub(1, #prefix) == prefix then
                projections[key] = nil
                projectionCount = math.max(0, projectionCount - 1)
            end
        end
        projectionRevisions[playerSource] =
            (projectionRevision(playerSource) + 1) & 0x7fffffff
    end

    local function invalidateAllProjections(topic)
        projections = {}
        projectionCount = 0
        projectionDomainRevision = (projectionDomainRevision + 1) & 0x7fffffff
        if topic then
            emitMetric('increment', 'compat_projection_invalidations_total', {
                topic = topic,
                scope = 'global',
            }, 1)
        end
    end

    local function invalidateCharacterProjections(characterId, topic)
        local candidates = {}
        local function include(playerSource, fence)
            if not finiteInteger(playerSource, 1, 65534)
                or type(fence) ~= 'table' or getmetatable(fence) ~= nil
                or fence.characterId ~= characterId
                or not boundedString(fence.sessionId, 64)
                or not finiteInteger(fence.sourceGeneration,
                    1, 9007199254740991) then
                return
            end
            local previous = candidates[playerSource]
            if previous == nil
                or fence.sourceGeneration > previous.sourceGeneration then
                candidates[playerSource] = fence
            end
        end
        for _, entry in pairs(lifecycleLoads) do
            if type(entry) == 'table' then
                include(entry.source, entry.fence)
            end
        end
        for _, cached in pairs(projections) do
            local value = type(cached) == 'table' and cached.value or nil
            if type(value) == 'table' then include(value.source, value.fence) end
        end

        for playerSource, fence in pairs(candidates) do
            local _, _, character = currentAuthority(playerSource, fence)
            if character and character.id == characterId then
                invalidateProjection(playerSource)
            end
        end
        emitMetric('increment', 'compat_projection_invalidations_total', {
            topic = topic,
            scope = 'character',
        }, 1)
    end

    bindProjectionInvalidation = function(resolved)
        if projectionInvalidationReady then return true, nil end
        if #projectionInvalidationTokens > 0 then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'Projection invalidation subscriptions are incomplete.', true)
        end
        local events = type(resolved) == 'table' and resolved.Events or nil
        if type(events) ~= 'table' or not isCallable(events.subscribe) then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'Projection invalidation events are unavailable.', true)
        end
        for _, topic in ipairs(PROJECTION_INVALIDATION_TOPICS) do
            local subscribedTopic = topic
            local token, subscriptionError = events.subscribe(subscribedTopic, function(payload)
                local targetCharacterId, unsafeIdentity = nil, false
                if type(payload) == 'table' then
                    local characterId = rawget(payload, 'character_id')
                    local camelCharacterId = rawget(payload, 'characterId')
                    if characterId ~= nil then
                        if validSubjectId(characterId) then
                            targetCharacterId = characterId
                        else
                            unsafeIdentity = true
                        end
                    end
                    if camelCharacterId ~= nil then
                        if not validSubjectId(camelCharacterId)
                            or targetCharacterId ~= nil
                                and targetCharacterId ~= camelCharacterId then
                            unsafeIdentity = true
                        else
                            targetCharacterId = camelCharacterId
                        end
                    end
                    if rawget(payload, 'owner_kind') == 'character' then
                        local ownerRef = rawget(payload, 'owner_ref')
                        if not validSubjectId(ownerRef)
                            or targetCharacterId ~= nil
                                and targetCharacterId ~= ownerRef then
                            unsafeIdentity = true
                        else
                            targetCharacterId = ownerRef
                        end
                    end
                end
                if not unsafeIdentity and targetCharacterId ~= nil then
                    invalidateCharacterProjections(
                        targetCharacterId, subscribedTopic)
                    if queueLifecycleRefresh then
                        queueLifecycleRefresh(subscribedTopic, {
                            characterId = targetCharacterId,
                        })
                    end
                else
                    invalidateAllProjections(subscribedTopic)
                    if queueLifecycleRefresh then
                        queueLifecycleRefresh(subscribedTopic)
                    end
                end
                return true
            end)
            if not token then return nil, subscriptionError end
            projectionInvalidationTokens[#projectionInvalidationTokens + 1] = token
        end
        projectionInvalidationReady = true
        return true, nil
    end

    local function copyProjection(value)
        return strictCopy(value, {
            root = 'object',
            maximumDepth = 10,
            maximumEntries = 2048,
            maximumBytes = 262144,
            maximumStringBytes = 4096,
            maximumArrayItems = 128,
            maximumObjectProperties = 128,
        })
    end

    local function readPlayerInternal(playerSource, accountsOnly, expectedFence, traceId)
        local resolved, session, character, authorityError =
            currentAuthority(playerSource, expectedFence)
        if not resolved then return nil, authorityError end
        local revision = projectionRevision(playerSource)
        local domainRevision = projectionDomainRevision
        local key = cacheKey(playerSource, session, revision, domainRevision)
        local now = GetGameTimer()
        if accountsOnly ~= true and projectionInvalidationReady then
            local cached = projections[key]
            if cached and (now >= cached.createdAt
                and now - cached.createdAt <= LIMITS.projectionTtlMs) then
                emitMetric('increment', 'compat_projection_cache_hit', {}, 1)
                return copyProjection(cached.value)
            end
            emitMetric('increment', 'compat_projection_cache_miss', {}, 1)
            if cached then
                projections[key] = nil
                projectionCount = math.max(0, projectionCount - 1)
            end
        end

        local financial, financialError = mapAccounts(resolved, character, traceId)
        if not financial then return nil, financialError end
        local fence = {
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            characterId = character.id,
        }
        local result = {
            source = playerSource,
            character = {
                id = character.id,
                slot = character.slot,
                firstName = character.firstName,
                lastName = character.lastName,
                dateOfBirth = character.dateOfBirth,
            },
            money = financial.money,
            accountDefinitions = financial.accountDefinitions,
            fence = fence,
        }
        if accountsOnly == true then
            result.accountIds = financial.accountIds
            result.accountSequences = financial.accountSequences
        else
            local groups, groupsError = readGroups(resolved, character, traceId)
            if not groups then
                emitMetric('increment', 'compat_group_translation_total',
                    { outcome = 'error' }, 1)
                emitMetric('increment', 'compat_group_translation_failed', {}, 1)
                return nil, groupsError
            end
            emitMetric('increment', 'compat_group_translation_total',
                { outcome = 'success' }, 1)
            local identifierType = framework == 'esx' and 'identifier' or 'citizenid'
            local identity, identityError = callBridgeExport(
                'ResolveCompatibilityIdentity', {
                    provider = framework,
                    identifierType = identifierType,
                    characterId = character.id,
                })
            if not identity then return nil, identityError end
            local metadata, metadataError = callBridgeExport(
                'GetCompatibilityMetadata', {
                    provider = framework,
                    characterId = character.id,
                })
            if not metadata then return nil, metadataError end
            result.groups = groups
            result.identity = identity
            result.metadata = metadata.values or {}
            result.metadataVersions = metadata.versions or {}
            result.revision = revision
        end

        local _, currentSession, currentCharacter, staleError =
            currentAuthority(playerSource, fence)
        if not currentSession or not fenceMatches(fence, currentSession, currentCharacter) then
            return nil, staleError or bridgeError(
                'COMPAT_STALE_SESSION',
                'The compatibility projection became stale while it was assembled.')
        end
        if revision ~= projectionRevision(playerSource)
            or domainRevision ~= projectionDomainRevision then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The compatibility projection changed while it was assembled.', true)
        end
        local copied, copyError = copyProjection(result)
        if not copied then return nil, copyError end
        if accountsOnly ~= true and projectionInvalidationReady then
            if projectionCount >= LIMITS.projectionEntries then
                projections = {}
                projectionCount = 0
            end
            projections[key] = { createdAt = now, value = copied }
            projectionCount = projectionCount + 1
            return copyProjection(copied)
        end
        return copied, nil
    end

    local function authorityFence(session, character)
        return {
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            characterId = character.id,
        }
    end

    local function verifyStableAuthority(playerSource, fence)
        local _, currentSession, currentCharacter, staleError =
            currentAuthority(playerSource, fence)
        if not currentSession
            or not fenceMatches(fence, currentSession, currentCharacter) then
            return nil, staleError or bridgeError('COMPAT_STALE_SESSION',
                'The compatibility projection became stale while it was assembled.')
        end
        return true, nil
    end

    local function readGroupsInternal(playerReference, expectedFence, traceId)
        local playerSource, sourceError = activeSourceForReference(playerReference)
        if playerSource == false then return false, nil end
        if not playerSource then return nil, sourceError end
        local resolved, session, character, authorityError =
            currentAuthority(playerSource, expectedFence)
        if not resolved then return nil, authorityError end
        local groups, groupsError = readGroups(resolved, character, traceId)
        if not groups then return nil, groupsError end
        local identifierType = framework == 'esx' and 'identifier' or 'citizenid'
        local identity, identityError = callBridgeExport(
            'ResolveCompatibilityIdentity', {
                provider = framework,
                identifierType = identifierType,
                characterId = character.id,
            })
        if not identity then return nil, identityError end
        local fence = authorityFence(session, character)
        local stable, staleError = verifyStableAuthority(playerSource, fence)
        if not stable then return nil, staleError end
        return copyProjection({
            source = playerSource,
            character = {
                id = character.id,
                slot = character.slot,
                firstName = character.firstName,
                lastName = character.lastName,
                dateOfBirth = character.dateOfBirth,
            },
            groups = groups,
            identity = identity,
            fence = fence,
            revision = projectionRevision(playerSource),
        })
    end

    local function readMetadataInternal(playerReference, expectedFence)
        local playerSource, sourceError = activeSourceForReference(playerReference)
        if playerSource == false then return false, nil end
        if not playerSource then return nil, sourceError end
        local _, session, character, authorityError =
            currentAuthority(playerSource, expectedFence)
        if not session then return nil, authorityError end
        local metadata, metadataError = callBridgeExport(
            'GetCompatibilityMetadata', {
                provider = framework,
                characterId = character.id,
            })
        if not metadata then return nil, metadataError end
        local fence = authorityFence(session, character)
        local stable, staleError = verifyStableAuthority(playerSource, fence)
        if not stable then return nil, staleError end
        return copyProjection({
            source = playerSource,
            character = { id = character.id },
            metadata = metadata.values or {},
            metadataVersions = metadata.versions or {},
            fence = fence,
            revision = projectionRevision(playerSource),
        })
    end

    local function readOfflinePlayerInternal(characterId, traceId)
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local character, characterError = resolved.Characters.get(characterId)
        if not character then return nil, characterError end
        if type(character) ~= 'table' or character.id ~= characterId
            or not boundedString(character.id, 48) then
            return nil, bridgeError('INVALID_CHARACTER_SNAPSHOT',
                'Synex returned an invalid offline character projection.', true)
        end
        local financial, financialError = mapAccounts(resolved, character, traceId)
        if not financial then return nil, financialError end
        local groups, groupsError = readGroups(resolved, character, traceId)
        if not groups then return nil, groupsError end
        local identifierType = framework == 'esx' and 'identifier' or 'citizenid'
        local identity, identityError = callBridgeExport(
            'ResolveCompatibilityIdentity', {
                provider = framework,
                identifierType = identifierType,
                characterId = character.id,
            })
        if not identity then return nil, identityError end
        local metadata, metadataError = callBridgeExport(
            'GetCompatibilityMetadata', {
                provider = framework,
                characterId = character.id,
            })
        if not metadata then return nil, metadataError end
        return copyProjection({
            offline = true,
            character = {
                id = character.id,
                slot = character.slot,
                firstName = character.firstName,
                lastName = character.lastName,
                dateOfBirth = character.dateOfBirth,
            },
            money = financial.money,
            accountDefinitions = financial.accountDefinitions,
            groups = groups,
            identity = identity,
            metadata = metadata.values or {},
            metadataVersions = metadata.versions or {},
            revision = 0,
        })
    end

    local adapter = {}

    function adapter:authorize(consumer, suffix, operation)
        return authorize(consumer, suffix, operation)
    end

    function adapter:trace(authorization, consumer, legacyApi, handler)
        return runTraced(authorization, consumer, legacyApi, handler)
    end

    function adapter:invokeCompatibilityAdapter(consumer, request)
        local operation = type(request) == 'table'
            and rawget(request, 'operation') or nil
        if not boundedString(consumer, 64)
            or not consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
            or not boundedString(operation, 128)
            or not operation:match('^[a-z][a-z0-9_.:%-]*$') then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The compatibility adapter invocation is invalid.')
        end
        local usageToken = beginUsage(consumer, operation)
        if not usageToken then
            return nil, bridgeError('COMPAT_REGISTRY_LIMIT',
                'The compatibility usage registry reached its bound.', true)
        end
        local function reject(errorValue)
            return finishResult(usageToken, nil, errorValue)
        end
        if frameworkConflict then
            return reject(bridgeError('COMPAT_FRAMEWORK_CONFLICT',
                'A native legacy framework conflicts with this Synex compatibility provider.'))
        end
        if not consumerIsActive(consumer) then
            return reject(bridgeError(
                'CALLER_INVALID', 'The compatibility consumer is not active.'))
        end
        local resolved, apiError = getApi()
        if not resolved then return reject(apiError) end
        local result, invokeError = callBridgeExport(
            'InvokeCompatibilityAdapter', consumer, request)
        if result == nil or result == false then
            return reject(type(invokeError) == 'table' and invokeError
                or bridgeError('COMPAT_RESOLUTION_FAILED',
                    'The compatibility adapter invocation failed.'))
        end
        local copied, copyError = strictCopy(result, {
            root = 'object', maximumDepth = 10, maximumEntries = 384,
            maximumBytes = 49152, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 64,
            maximumKeyBytes = 96,
        })
        if not copied then return reject(copyError) end
        return finishResult(usageToken, copied, nil)
    end

    function adapter:readPlayer(consumer, playerSource)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'player.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetPlayer', function()
                return readPlayerInternal(
                    playerSource, false, nil, authorization.traceId)
            end))
    end

    function adapter:readPlayerFenced(consumer, playerSource, fence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'player.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetPlayer', function()
                return readPlayerInternal(
                    playerSource, false, fence, authorization.traceId)
            end))
    end

    function adapter:readPlayerByIdentifier(consumer, identifier)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'player.lookup_identifier', true)
        if not authorization then return nil, authorizationError end
        local function execute()
            local identity, identityError = reverseIdentity(identifier)
            if identity == false then return false, nil end
            if not identity then return nil, identityError end
            local resolved, resolveError = getApi()
            if not resolved then return nil, resolveError end
            local playerSource, sourceError = onlineSourceForCharacter(
                resolved, identity.characterId)
            if playerSource == false then return false, nil end
            if not playerSource then return nil, sourceError end
            local snapshot, snapshotError = readPlayerInternal(
                playerSource, false, nil, authorization.traceId)
            if not snapshot then return nil, snapshotError end
            if type(snapshot.identity) ~= 'table'
                or snapshot.identity.identifier ~= identifier
                or snapshot.identity.characterId ~= identity.characterId then
                return nil, bridgeError('COMPAT_IDENTITY_CONFLICT',
                    'The active player identity changed during lookup.', true)
            end
            return snapshot, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetPlayerByIdentifier', execute))
    end

    function adapter:listPlayerSources(consumer)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'player.enumerate', true)
        if not authorization then return nil, authorizationError end
        local function execute()
            local resolved, resolveError = getApi()
            if not resolved then return nil, resolveError end
            return activeSources(resolved)
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetPlayers', execute))
    end

    function adapter:readOfflinePlayerByIdentifier(consumer, identifier)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'player.offline_read', true)
        if not authorization then return nil, authorizationError end
        local function execute()
            local identity, identityError = reverseIdentity(identifier)
            if identity == false then return false, nil end
            if not identity then return nil, identityError end
            local resolved, resolveError = getApi()
            if not resolved then return nil, resolveError end
            local onlineSource, onlineError = onlineSourceForCharacter(
                resolved, identity.characterId)
            if onlineSource == nil then return nil, onlineError end
            if onlineSource ~= false then
                return readPlayerInternal(
                    onlineSource, false, nil, authorization.traceId)
            end
            local snapshot, snapshotError = readOfflinePlayerInternal(
                identity.characterId, authorization.traceId)
            if not snapshot then return nil, snapshotError end
            if type(snapshot.identity) ~= 'table'
                or snapshot.identity.identifier ~= identifier then
                return nil, bridgeError('COMPAT_IDENTITY_CONFLICT',
                    'The offline player identity changed during lookup.', true)
            end
            return snapshot, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetOfflinePlayer', execute))
    end

    function adapter:readPermissionGroups(consumer, playerSource, expectedFence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'permissions.read', true)
        if not authorization then return nil, authorizationError end
        local function execute()
            local resolved, _, character, authorityError = currentAuthority(
                playerSource, expectedFence)
            if not resolved then return nil, authorityError end
            if type(resolved.Permissions) ~= 'table'
                or not isCallable(resolved.Permissions.check) then
                return nil, bridgeError('COMPAT_PERMISSION_UNAVAILABLE',
                    'The Synex permission projection boundary is unavailable.', true)
            end
            local catalog, catalogError = callBridgeExport(
                'ListCompatibilityPermissionMappings', { provider = framework })
            if not catalog then return nil, catalogError end
            if type(catalog) ~= 'table' or catalog.truncated ~= false
                or not denseArray(catalog.items, 128) then
                return nil, bridgeError('COMPAT_PERMISSION_MAPPING_INVALID',
                    'The compatibility permission mapping catalog is invalid.', true)
            end
            local subject = 'character:' .. character.id
            local allowed, fallback, highestPriority, primaryAllowed = {}, nil, nil, nil
            local seenLegacyGroups = {}
            for _, mapping in ipairs(catalog.items) do
                if type(mapping) ~= 'table'
                    or not boundedString(mapping.legacyGroup, 64)
                    or not mapping.legacyGroup:match('^[a-z][a-z0-9_.%-]*$')
                    or not boundedString(mapping.nativePermission, 128)
                    or not mapping.nativePermission:match('^[a-z][a-z0-9%._%-]*$')
                    or not finiteInteger(mapping.priority, 0, 65535)
                    or type(mapping.fallback) ~= 'boolean' then
                    return nil, bridgeError('COMPAT_PERMISSION_MAPPING_INVALID',
                        'The compatibility permission mapping catalog is invalid.', true)
                end
                if seenLegacyGroups[mapping.legacyGroup] then
                    return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                        'A compatibility permission group is mapped more than once.')
                end
                seenLegacyGroups[mapping.legacyGroup] = true
                if mapping.fallback == true then
                    if fallback ~= nil then
                        return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                            'More than one fallback permission group is configured.')
                    end
                    fallback = mapping.legacyGroup
                else
                    local permitted, permissionError = resolved.Permissions.check(
                        subject, mapping.nativePermission)
                    if permissionError then return nil, permissionError end
                    if permitted == true then
                        if highestPriority == nil or mapping.priority > highestPriority then
                            highestPriority = mapping.priority
                            primaryAllowed = mapping.legacyGroup
                        elseif mapping.priority == highestPriority then
                            return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                                'More than one permission group has the highest priority.')
                        end
                        allowed[#allowed + 1] = mapping.legacyGroup
                    end
                end
            end
            if fallback == nil then
                return nil, bridgeError('COMPAT_MAPPING_MISSING',
                    'No fallback compatibility permission group is configured.')
            end
            table.sort(allowed)
            local primary = primaryAllowed or fallback
            return { groups = allowed, primary = primary, fallback = fallback }, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetPermissionGroup', execute))
    end

    function adapter:readMoney(consumer, playerSource)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'money.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetMoney', function()
                local resolvedSource, sourceError = activeSourceForReference(playerSource)
                if resolvedSource == false then return false, nil end
                if not resolvedSource then return nil, sourceError end
                return readPlayerInternal(
                    resolvedSource, true, nil, authorization.traceId)
            end))
    end

    function adapter:readMoneyFenced(consumer, playerSource, fence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'money.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetMoney', function()
                return readPlayerInternal(
                    playerSource, true, fence, authorization.traceId)
            end))
    end

    function adapter:readCustomAccountsFenced(consumer, playerSource, fence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'accounts.custom_read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetCustomAccounts', function()
                return readPlayerInternal(
                    playerSource, true, fence, authorization.traceId)
            end))
    end

    function adapter:readGroups(consumer, playerSource)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'groups.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetGroups', function()
                return readGroupsInternal(
                    playerSource, nil, authorization.traceId)
            end))
    end

    function adapter:readGroupsFenced(consumer, playerSource, fence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'groups.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetGroups', function()
                return readGroupsInternal(
                    playerSource, fence, authorization.traceId)
            end))
    end

    function adapter:readMetadata(consumer, playerSource)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'metadata.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetMetadata', function()
                return readMetadataInternal(playerSource, nil)
            end))
    end

    function adapter:readMetadataFenced(consumer, playerSource, fence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'read', 'metadata.read', true)
        if not authorization then return nil, authorizationError end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'GetMetadata', function()
                return readMetadataInternal(playerSource, fence)
            end))
    end

    function adapter:unsupported(consumer, operation, message)
        if not boundedString(consumer, 64)
            or not consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
            or not boundedString(operation, 128)
            or not operation:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            or (message ~= nil and not boundedString(message, 256)) then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The unsupported compatibility usage is invalid.')
        end
        local usageToken = beginUsage(consumer, operation)
        if not usageToken then
            return nil, bridgeError('COMPAT_REGISTRY_LIMIT',
                'The compatibility usage registry reached its bound.', true)
        end
        if frameworkConflict then
            return finishResult(usageToken, nil, bridgeError(
                'COMPAT_FRAMEWORK_CONFLICT',
                'A native legacy framework conflicts with this Synex compatibility provider.'))
        end
        if not consumerIsActive(consumer) then
            return finishResult(usageToken, nil, bridgeError(
                'CALLER_INVALID', 'The compatibility consumer is not active.'))
        end
        return finishResult(usageToken, nil, bridgeError(
            'COMPAT_API_UNSUPPORTED', message
                or 'The requested compatibility API is unsupported.'))
    end

    function adapter:readPlayerInternal(playerSource)
        return readPlayerInternal(playerSource)
    end

    local function performMoneyTransfer(authorization, consumer, playerSource,
        moneyType, direction, amount, reason, expectedFence, legacyApi,
        preparedSnapshot, expectedPlayerSequence)
        local resolvedSource, sourceError = activeSourceForReference(playerSource)
        if resolvedSource == false then
            return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                'Compatibility money mutation requires active Synex player authority.')
        end
        if not resolvedSource then return nil, sourceError end
        playerSource = resolvedSource
        if type(moneyType) ~= 'string' or not moneyType:match('^[a-z][a-z0-9_]*$')
            or #moneyType > 32 or (direction ~= 'add' and direction ~= 'remove')
            or not finiteInteger(amount, 1, 9007199254740991) then
            return nil, bridgeError('INVALID_MONEY_OPERATION', 'Money type, direction, or integer amount is invalid.')
        end
        local reviewed, reviewedError = accountMappingByAlias(moneyType)
        if not reviewed then return nil, reviewedError end
        local snapshot = preparedSnapshot
        if not snapshot then
            local snapshotError
            snapshot, snapshotError = readPlayerInternal(
                playerSource, true, expectedFence, authorization.traceId)
            if not snapshot then return nil, snapshotError end
        end
        local playerAccount = snapshot.accountIds[moneyType]
        if not playerAccount then
            return nil, bridgeError('MONEY_ACCOUNT_NOT_FOUND', ('No active %s account is mapped.'):format(moneyType))
        end
        local legacyReason = type(reason) == 'string' and reason or 'legacy_bridge'
        if not boundedString(legacyReason, 128)
            or not legacyReason:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
            return nil, bridgeError('INVALID_MONEY_OPERATION',
                'The legacy money reason is invalid or unmapped.')
        end
        local policy, policyError = callBridgeExport('ResolveMoneyPolicy', {
            provider = framework,
            consumer = consumer,
            moneyAlias = moneyType,
            direction = direction,
            legacyReason = legacyReason,
        })
        if not policy then return nil, policyError end
        if type(policy) ~= 'table'
            or (policy.action ~= 'transfer' and policy.action ~= 'mint'
                and policy.action ~= 'burn')
            or not boundedString(policy.reasonCode, 96)
            or not policy.reasonCode:match('^[a-z][a-z0-9_.:%-]*$')
            or not boundedString(policy.policyId, 96)
            or not boundedString(policy.policyVersion, 32) then
            return nil, bridgeError('COMPAT_MONEY_POLICY_DENIED',
                'The legacy money operation has no reviewed funding or sink policy.')
        end
        if (policy.action == 'mint' and direction ~= 'add')
            or (policy.action == 'burn' and direction ~= 'remove') then
            return nil, bridgeError('COMPAT_MONEY_POLICY_DENIED',
                'The reviewed money policy does not match the mutation direction.')
        end
        if legacyApi == 'SetMoney' and policy.action ~= 'transfer' then
            return nil, bridgeError('COMPAT_MONEY_POLICY_DENIED',
                'SetMoney requires a sequence-fenced transfer policy.')
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local nativeCapability = ({
            transfer = 'synex.accounts.transfer',
            mint = 'synex.accounts.mint',
            burn = 'synex.accounts.burn',
        })[policy.action]
        local capabilityAllowed, capabilityError = checkConsumerCapability(
            resolved, consumer, nativeCapability, 'money.' .. direction,
            'native_action', authorization.traceId)
        if not capabilityAllowed then return nil, capabilityError end
        local operationId = uuidV4()
        local nativeReason = policy.reasonCode
        local metadataEncoded, metadataJson = pcall(json.encode, {
            compatibility = true,
            provider = framework,
            providerResource = resourceName,
            consumer = consumer,
            legacyApi = legacyApi,
            legacyReason = legacyReason,
            nativeReason = nativeReason,
            policy = {
                id = policy.policyId,
                version = policy.policyVersion,
                action = policy.action,
            },
            traceId = authorization.traceId,
            actor = {
                kind = 'character',
                ref = snapshot.fence.characterId,
                source = playerSource,
            },
        })
        if not metadataEncoded or type(metadataJson) ~= 'string'
            or #metadataJson > 4096 then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'The compatibility provenance payload is invalid.')
        end
        local mutationRequest = {
            idempotency_key = operationId,
            amount_minor = amount,
            reason_code = nativeReason,
            actor_kind = 'resource',
            actor_ref = consumer:sub(1, 128),
            reference_type = 'compatibility.legacy',
            reference_id = operationId,
            metadata_json = metadataJson,
        }
        local rpcName
        if policy.action == 'transfer' then
            local counterparty = policy.accountId
            if not validUuid(counterparty) then
                return nil, bridgeError(
                    'MONEY_COUNTERPARTY_NOT_CONFIGURED',
                    ('A reviewed %s counterparty account must be configured before legacy mutations are enabled.'):format(moneyType)
                )
            end
            if counterparty == playerAccount then
                return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                    'The configured money counterparty equals the player account.')
            end
            mutationRequest.source_account_id = direction == 'add'
                and counterparty or playerAccount
            mutationRequest.destination_account_id = direction == 'add'
                and playerAccount or counterparty
            rpcName = 'synex.accounts.transfer_v2'
        else
            if policy.accountId ~= nil then
                return nil, bridgeError('COMPAT_MONEY_POLICY_DENIED',
                    'Mint and burn policies cannot specify a counterparty account.')
            end
            mutationRequest.account_id = playerAccount
            rpcName = policy.action == 'mint'
                and 'synex.accounts.mint_v2' or 'synex.accounts.burn_v2'
        end
        if expectedPlayerSequence ~= nil and policy.action == 'transfer' then
            if not finiteInteger(expectedPlayerSequence, 0, MAXIMUM_SAFE_INTEGER) then
                return nil, bridgeError('INVALID_ACCOUNT_SNAPSHOT',
                    'The mapped account sequence is invalid.')
            end
            if direction == 'add' then
                mutationRequest.expected_destination_sequence = expectedPlayerSequence
            else
                mutationRequest.expected_source_sequence = expectedPlayerSequence
            end
        end
        local rpcOptions = {
            timeoutMs = 5000,
            traceId = authorization.traceId,
            idempotencyKey = operationId,
        }
        local result, mutationError = resolved.RPC.call(
            rpcName, '2.0.0', mutationRequest, rpcOptions)
        if not result and type(mutationError) == 'table'
            and mutationError.retryable == true then
            emitMetric('increment', 'compat_money_retry_total', {
                operation = 'money.' .. direction,
                action = policy.action,
            }, 1)
            result, mutationError = resolved.RPC.call(
                rpcName, '2.0.0', mutationRequest, rpcOptions)
        end
        if not result then return nil, mutationError end
        invalidateProjection(playerSource)
        return true, nil
    end

    function adapter:changeMoney(
        consumer, playerSource, moneyType, direction, amount, reason, expectedFence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', 'money.' .. tostring(direction), true)
        if not authorization then return nil, authorizationError end
        local function execute()
            return performMoneyTransfer(
                authorization, consumer, playerSource, moneyType, direction,
                amount, reason, expectedFence,
                direction == 'add' and 'AddMoney' or 'RemoveMoney')
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer,
            direction == 'add' and 'AddMoney' or 'RemoveMoney', execute))
    end

    function adapter:setMoney(
        consumer, playerSource, moneyType, targetAmount, reason, expectedFence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', 'money.set', true)
        if not authorization then return nil, authorizationError end
        local function execute()
        local resolvedSource, sourceError = activeSourceForReference(playerSource)
        if resolvedSource == false then
            return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                'Compatibility money mutation requires active Synex player authority.')
        end
        if not resolvedSource then return nil, sourceError end
        playerSource = resolvedSource
        if type(moneyType) ~= 'string' or not moneyType:match('^[a-z][a-z0-9_]*$')
            or #moneyType > 32
            or not finiteInteger(targetAmount, 0, MAXIMUM_SAFE_INTEGER) then
            return nil, bridgeError('INVALID_MONEY_OPERATION',
                'The mapped money type and target amount must be valid.')
        end
        local reviewed, reviewedError = accountMappingByAlias(moneyType)
        if not reviewed then return nil, reviewedError end
        local snapshot, snapshotError = readPlayerInternal(
            playerSource, true, expectedFence, authorization.traceId)
        if not snapshot then return nil, snapshotError end
        local currentAmount = snapshot.money[moneyType]
        local expectedSequence = snapshot.accountSequences[moneyType]
        if not finiteInteger(currentAmount, 0, MAXIMUM_SAFE_INTEGER)
            or not finiteInteger(expectedSequence, 0, MAXIMUM_SAFE_INTEGER) then
            return nil, bridgeError('INVALID_ACCOUNT_SNAPSHOT',
                'The mapped account amount or sequence is invalid.')
        end
        if currentAmount == targetAmount then return true, nil end
        local direction = targetAmount > currentAmount and 'add' or 'remove'
        local amount = targetAmount > currentAmount
            and targetAmount - currentAmount or currentAmount - targetAmount
        return performMoneyTransfer(
            authorization, consumer, playerSource, moneyType, direction,
            amount, reason, expectedFence, 'SetMoney', snapshot, expectedSequence)
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'SetMoney', execute))
    end

    local function compatibilityContext(authorization, consumer, legacyApi,
        idempotencyKey)
        return {
            traceId = authorization.traceId,
            timeoutMs = 5000,
            idempotencyKey = idempotencyKey,
            metadata = {
                compatibility = {
                    provider = framework,
                    consumer = consumer,
                    legacyApi = legacyApi,
                },
            },
        }
    end

    local function resolveGroupTarget(resolved, characterId, legacyType,
        legacyName, legacyGrade, authorization, consumer, legacyApi)
        local mapping, mappingError = callBridgeExport(
            'ResolveCompatibilityGroupMapping', {
                provider = framework,
                legacyType = legacyType,
                legacyName = legacyName,
                legacyGrade = legacyGrade,
            })
        if not mapping then return nil, mappingError end
        if type(mapping) ~= 'table'
            or not boundedString(mapping.id, 96)
            or not boundedString(mapping.version, 32)
            or mapping.legacyType ~= legacyType
            or mapping.legacyName ~= legacyName
            or mapping.legacyGrade ~= legacyGrade
            or not boundedString(mapping.nativeGroupType, 64)
            or not mapping.nativeGroupType:match('^[a-z][a-z0-9_%-]*$')
            or not boundedString(mapping.nativeGroupKey, 64)
            or not mapping.nativeGroupKey:match('^[a-z][a-z0-9_%-]*$')
            or not boundedString(mapping.gradeKey, 64)
            or not mapping.gradeKey:match('^[a-z][a-z0-9_%-]*$')
            or type(mapping.dutySupported) ~= 'boolean'
            or mapping.dutySupported == true and (
                not boundedString(mapping.dutyState, 32)
                or not mapping.dutyState:match('^[a-z][a-z0-9_%-]*$'))
            or mapping.dutySupported == false and mapping.dutyState ~= nil
            or (mapping.status ~= 'CERTIFIED'
                and mapping.status ~= 'COMPATIBLE'
                and mapping.status ~= 'PARTIAL') then
            return nil, bridgeError('COMPAT_MAPPING_MISSING',
                'The requested group or grade mapping is invalid.')
        end
        local target, targetError = resolved.Services.call(
            'synex.groups', SERVICE_RANGE, 'compatibility_resolve_target', {
                actor_character_id = characterId,
                group_type = mapping.nativeGroupType,
                group_key = mapping.nativeGroupKey,
                grade_key = mapping.gradeKey,
            }, compatibilityContext(
                authorization, consumer, legacyApi .. '.resolve', nil))
        if not target then return nil, targetError end
        if type(target) ~= 'table' or not validPublicId(target.group_id)
            or not validPublicId(target.grade_id)
            or target.membership_id ~= nil and not validPublicId(target.membership_id)
            or target.membership_status ~= nil and type(target.membership_status) ~= 'string'
            or target.membership_version ~= nil and not finiteInteger(
                target.membership_version, 1, 2147483647)
            or target.primary_state ~= nil and target.primary_state ~= 'unassigned'
                and target.primary_state ~= 'selected'
                and target.primary_state ~= 'different'
            or target.primary_version ~= nil and not finiteInteger(
                target.primary_version, 1, 2147483647)
            or target.duty_session_id ~= nil and not validPublicId(
                target.duty_session_id)
            or target.duty_state ~= nil and (
                not boundedString(target.duty_state, 32)
                or not target.duty_state:match('^[a-z][a-z0-9_%-]*$'))
            or target.duty_version ~= nil and not finiteInteger(
                target.duty_version, 1, 2147483647) then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'Synex Groups returned an invalid compatibility target.', true)
        end
        if target.membership_id == nil then
            if target.membership_status ~= nil or target.membership_version ~= nil
                or target.primary_state ~= nil or target.primary_version ~= nil
                or target.duty_session_id ~= nil or target.duty_state ~= nil
                or target.duty_version ~= nil then
                return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                    'Synex Groups returned an incomplete compatibility membership.', true)
            end
        elseif target.membership_status == nil or target.membership_version == nil
            or target.primary_state == nil
            or target.primary_state == 'unassigned' and target.primary_version ~= nil
            or target.primary_state ~= 'unassigned' and target.primary_version == nil
            or target.duty_session_id == nil and (
                target.duty_state ~= nil or target.duty_version ~= nil)
            or target.duty_session_id ~= nil and (
                target.duty_state == nil or target.duty_version == nil) then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'Synex Groups returned an incomplete compatibility membership.', true)
        end
        return { mapping = mapping, target = target }, nil
    end

    local function groupReason(value)
        local reason = type(value) == 'string' and value or 'compatibility_mapping'
        if not boundedString(reason, 128)
            or not reason:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The compatibility group reason is invalid.')
        end
        return reason, nil
    end

    local function performGroupMutation(authorization, consumer, playerSource,
        legacyType, legacyName, legacyGrade, reason, expectedFence, legacyApi)
        if legacyType ~= 'job' and legacyType ~= 'gang' then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'Only mapped job and gang mutations are supported.')
        end
        local resolvedSource, sourceError = activeSourceForReference(playerSource)
        if resolvedSource == false then
            return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                'Compatibility group mutation requires active Synex player authority.')
        end
        if not resolvedSource then return nil, sourceError end
        playerSource = resolvedSource
        if not boundedString(legacyName, 64)
            or not legacyName:match('^[a-z][a-z0-9_%-]*$')
            or not finiteInteger(legacyGrade, 0, 65535) then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The compatibility group name or grade is invalid.')
        end
        local mutationReason, reasonError = groupReason(reason)
        if not mutationReason then return nil, reasonError end
        local resolved, _, character, authorityError = currentAuthority(
            playerSource, expectedFence)
        if not resolved then return nil, authorityError end
        local resolution, resolutionError = resolveGroupTarget(
            resolved, character.id, legacyType, legacyName, legacyGrade,
            authorization, consumer, legacyApi)
        if not resolution then return nil, resolutionError end
        local target = resolution.target
        if target.membership_id == nil or target.membership_status ~= 'ACTIVE'
            or target.membership_version == nil or target.primary_state == nil then
            return nil, bridgeError('COMPAT_GROUP_MEMBERSHIP_REQUIRED',
                'The active character does not hold the mapped active membership.')
        end
        local idempotencyKey = uuidV4()
        local result, mutationError = resolved.Services.call(
            'synex.groups', SERVICE_RANGE,
            'compatibility_set_primary_grade', {
                idempotency_key = idempotencyKey,
                actor_character_id = character.id,
                membership_id = target.membership_id,
                grade_id = target.grade_id,
                expected_version = target.membership_version,
                group_type = resolution.mapping.nativeGroupType,
                expected_primary_version = target.primary_version or 0,
                reason = mutationReason,
            }, compatibilityContext(authorization, consumer, legacyApi,
                idempotencyKey))
        if not result then return nil, mutationError end
        if type(result) ~= 'table'
            or result.membership_id ~= target.membership_id
            or result.grade_id ~= target.grade_id
            or not finiteInteger(result.membership_version, 1, 2147483647)
            or not validPublicId(result.primary_id)
            or not finiteInteger(result.primary_version, 1, 2147483647)
            or result.replayed ~= false then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'Synex Groups returned an invalid mutation result.', true)
        end
        invalidateProjection(playerSource)
        return true, nil
    end

    function adapter:setGroup(consumer, playerSource, legacyType, legacyName,
        legacyGrade, reason, expectedFence)
        local operation = legacyType == 'job' and 'groups.set_job'
            or legacyType == 'gang' and 'groups.set_gang' or nil
        if not operation then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'Only mapped job and gang mutations are supported.')
        end
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', operation, true)
        if not authorization then return nil, authorizationError end
        local legacyApi = legacyType == 'job' and 'SetJob' or 'SetGang'
        return finishResult(usageToken, runTraced(
            authorization, consumer, legacyApi, function()
                return performGroupMutation(authorization, consumer,
                    playerSource, legacyType, legacyName, legacyGrade,
                    reason, expectedFence, legacyApi)
            end))
    end

    function adapter:setPrimaryGroup(consumer, playerSource, legacyType,
        legacyName)
        if legacyType ~= 'job' and legacyType ~= 'gang'
            or not boundedString(legacyName, 64)
            or not legacyName:match('^[a-z][a-z0-9_%-]*$') then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'The Qbox primary group mutation is invalid.')
        end
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', 'groups.set_primary', true)
        if not authorization then return nil, authorizationError end
        local legacyApi = legacyType == 'job'
            and 'SetPlayerPrimaryJob' or 'SetPlayerPrimaryGang'
        local function execute()
            local resolvedSource, sourceError = activeSourceForReference(playerSource)
            if resolvedSource == false then
                return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                    'Primary group mutation requires active Synex player authority.')
            end
            if not resolvedSource then return nil, sourceError end
            local snapshot, snapshotError = readGroupsInternal(
                resolvedSource, nil, authorization.traceId)
            if not snapshot then return nil, snapshotError end
            local legacyGrade
            for _, membership in ipairs(snapshot.groups.items) do
                local group = type(membership) == 'table'
                    and type(membership.group) == 'table'
                    and membership.group or nil
                if group and group.key == legacyName
                    and (group.type == legacyType
                        or legacyType == 'gang' and group.type == 'group') then
                    local grade = type(membership.grade) == 'table'
                        and membership.grade or nil
                    if not grade or not finiteInteger(grade.rank, 0, 65535) then
                        return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                            'The mapped Qbox membership has no valid current grade.')
                    end
                    if legacyGrade ~= nil then
                        return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                            'More than one mapped Qbox membership has the requested name.')
                    end
                    legacyGrade = grade.rank
                end
            end
            if legacyGrade == nil then
                return nil, bridgeError('COMPAT_GROUP_MEMBERSHIP_REQUIRED',
                    'Primary group mutation requires an existing mapped active membership.')
            end
            return performGroupMutation(authorization, consumer,
                resolvedSource, legacyType, legacyName, legacyGrade,
                legacyType == 'job' and 'compatibility_primary_job'
                    or 'compatibility_primary_gang',
                snapshot.fence, legacyApi)
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, legacyApi, execute))
    end

    function adapter:setDuty(consumer, playerSource, enabled, reason, expectedFence)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', 'groups.set_duty', true)
        if not authorization then return nil, authorizationError end
        local function execute()
            local resolvedSource, sourceError = activeSourceForReference(playerSource)
            if resolvedSource == false then
                return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                    'Compatibility duty mutation requires active Synex player authority.')
            end
            if not resolvedSource then return nil, sourceError end
            playerSource = resolvedSource
            if type(enabled) ~= 'boolean' then
                return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                    'The compatibility duty state must be boolean.')
            end
            local mutationReason, reasonError = groupReason(reason)
            if not mutationReason then return nil, reasonError end
            local resolved, _, character, authorityError = currentAuthority(
                playerSource, expectedFence)
            if not resolved then return nil, authorityError end
            local groups, groupsError = readGroups(
                resolved, character, authorization.traceId)
            if not groups then return nil, groupsError end
            local primaryJob
            for _, membership in ipairs(groups.items) do
                local group = type(membership) == 'table' and membership.group or nil
                if type(group) == 'table' and group.type == 'job'
                    and membership.is_primary == true then
                    if primaryJob then
                        return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                            'More than one primary job is projected for duty.')
                    end
                    primaryJob = membership
                end
            end
            if not primaryJob or type(primaryJob.group) ~= 'table'
                or not boundedString(primaryJob.group.key, 64)
                or type(primaryJob.grade) ~= 'table'
                or not finiteInteger(primaryJob.grade.rank, 0, 65535) then
                return nil, bridgeError('COMPAT_MAPPING_MISSING',
                    'No mapped primary job and grade are available for duty.')
            end
            local resolution, resolutionError = resolveGroupTarget(
                resolved, character.id, 'job', primaryJob.group.key,
                primaryJob.grade.rank, authorization, consumer, 'SetJobDuty')
            if not resolution then return nil, resolutionError end
            local mapping, target = resolution.mapping, resolution.target
            if mapping.dutySupported ~= true then
                return nil, bridgeError('COMPAT_API_UNSUPPORTED',
                    'Duty is not enabled by the reviewed group mapping.')
            end
            if target.membership_id == nil or target.membership_status ~= 'ACTIVE' then
                return nil, bridgeError('COMPAT_GROUP_MEMBERSHIP_REQUIRED',
                    'Duty requires the mapped active membership.')
            end
            if enabled == false and target.duty_session_id == nil
                or enabled == true and target.duty_session_id ~= nil
                    and target.duty_state == mapping.dutyState then
                return true, nil
            end
            local idempotencyKey = uuidV4()
            local method, request
            if enabled == false then
                method = 'duty_stop'
                request = {
                    idempotency_key = idempotencyKey,
                    actor_character_id = character.id,
                    duty_session_id = target.duty_session_id,
                    expected_version = target.duty_version,
                    reason = mutationReason,
                }
            elseif target.duty_session_id ~= nil then
                method = 'duty_update'
                request = {
                    idempotency_key = idempotencyKey,
                    actor_character_id = character.id,
                    duty_session_id = target.duty_session_id,
                    expected_version = target.duty_version,
                    state = mapping.dutyState,
                }
            else
                method = 'duty_start'
                request = {
                    idempotency_key = idempotencyKey,
                    actor_character_id = character.id,
                    membership_id = target.membership_id,
                    state = mapping.dutyState,
                }
            end
            local result, mutationError = resolved.Services.call(
                'synex.groups', SERVICE_RANGE, method, request,
                compatibilityContext(authorization, consumer, 'SetJobDuty',
                    idempotencyKey))
            if not result then return nil, mutationError end
            if type(result) ~= 'table' or not validPublicId(result.entity_id)
                or not finiteInteger(result.version, 1, 2147483647) then
                return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                    'Synex Groups returned an invalid duty result.', true)
            end
            invalidateProjection(playerSource)
            return true, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'SetJobDuty', execute))
    end

    function adapter:setMetadata(
        consumer, playerSource, key, value, expectedFence, expectedVersion)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'write', 'metadata.set', true)
        if not authorization then return nil, authorizationError end
        local function execute()
        local resolvedSource, sourceError = activeSourceForReference(playerSource)
        if resolvedSource == false then
            return nil, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
                'Compatibility metadata mutation requires active Synex player authority.')
        end
        if not resolvedSource then return nil, sourceError end
        playerSource = resolvedSource
        local _, session, character, authorityError = currentAuthority(
            playerSource, expectedFence)
        if not character then return nil, authorityError end
        local mutationFence = authorityFence(session, character)
        local mapping, mappingError = callBridgeExport('ResolveMetadataMapping', {
            provider = framework,
            consumer = consumer,
            key = key,
            operation = 'write',
        })
        if not mapping then return nil, mappingError end
        if type(mapping) ~= 'table' or mapping.allowed ~= true then
            return nil, bridgeError('COMPAT_METADATA_UNSUPPORTED',
                'The compatibility metadata key is not writable.')
        end
        local result, metadataError = callBridgeExport('SetCompatibilityMetadata', {
            provider = framework,
            characterId = character.id,
            key = mapping.nativeKey or key,
            value = value,
            expectedVersion = expectedVersion,
            traceId = authorization.traceId,
            consumer = consumer,
        })
        if not result then return nil, metadataError end
        invalidateProjection(playerSource)
        if queueLifecycleRefresh then
            queueLifecycleRefresh('synex.compat.metadata.changed', {
                source = playerSource,
                characterId = character.id,
                fence = mutationFence,
            })
        end
        return result, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'SetMetadata', execute))
    end

    function adapter:registerCallback(consumer, name, handler)
        local authorization, authorizationError, usageToken = authorize(
            consumer, 'callbacks', 'callback.register', true)
        if not authorization then return nil, authorizationError end
        local function execute()
        if not validCallbackName(name) or not isCallable(handler) then
            return nil, bridgeError('INVALID_CALLBACK', 'Callback name or handler is invalid.')
        end
        if not validConsumer(consumer) then
            return nil, bridgeError('COMPAT_CONSUMER_DENIED',
                'The compatibility callback consumer is invalid.')
        end
        local previousOwner = callbackOwners[name]
        if previousOwner and previousOwner ~= consumer then
            return nil, bridgeError('CALLBACK_NAME_CONFLICT', 'Another resource already owns this callback name.')
        end
        local callbackKey = consumer .. '\0' .. name
        local previous = callbacks[callbackKey]
        if not previous then
            local ownerCount = callbackRegistrationsByOwner[consumer] or 0
            if callbackRegistrations >= LIMITS.callbackRegistrations
                or ownerCount >= LIMITS.callbackRegistrationsPerConsumer then
                return nil, bridgeError('COMPAT_CALLBACK_LIMIT',
                    'The compatibility callback registry reached its bound.', true)
            end
            callbackRegistrations = callbackRegistrations + 1
            callbackRegistrationsByOwner[consumer] = ownerCount + 1
        end
        callbackOwners[name] = consumer
        callbacks[callbackKey] = { owner = consumer, name = name, handler = handler }
        return true, nil
        end
        return finishResult(usageToken, runTraced(
            authorization, consumer, 'RegisterCallback', execute))
    end

    function adapter:usageSnapshot(consumer)
        local result = {}
        local providerErrors = 0
        local unsupportedCalls = 0
        for _, entry in pairs(usage) do
            if consumer == nil or entry.resource == consumer then
                result[#result + 1] = safeCopy(entry)
                providerErrors = math.min(MAXIMUM_SAFE_INTEGER,
                    providerErrors + (entry.outcomes.error or 0))
                unsupportedCalls = math.min(MAXIMUM_SAFE_INTEGER,
                    unsupportedCalls + (entry.outcomes.unsupported or 0))
            end
        end
        table.sort(result, function(left, right)
            if left.resource == right.resource then return left.operation < right.operation end
            return left.resource < right.resource
        end)
        local reasons = {}
        if frameworkConflict then reasons[#reasons + 1] = 'framework_conflict' end
        if providerErrors > 0 then reasons[#reasons + 1] = 'provider_errors' end
        if unsupportedCalls > 0 then reasons[#reasons + 1] = 'unsupported_calls' end
        if pendingTotal >= math.floor(LIMITS.callbackPendingGlobal * 0.8) then
            reasons[#reasons + 1] = 'callback_pressure'
        end
        return {
            framework = framework,
            deprecated = true,
            entries = result,
            truncated = usageSize >= LIMITS.maximumUsageEntries,
            health = {
                status = #reasons > 0 and 'DEGRADED' or 'READY',
                reasons = reasons,
                callbackPending = pendingTotal,
                callbackCapacity = LIMITS.callbackPendingGlobal,
                callbackRegistrations = callbackRegistrations,
                callbackRegistrationCapacity = LIMITS.callbackRegistrations,
                projectionEntries = projectionCount,
                projectionCapacity = LIMITS.projectionEntries,
                usageEntries = usageSize,
                usageCapacity = LIMITS.maximumUsageEntries,
            },
        }
    end

    local function takeCallbackToken(playerSource)
        local now = GetGameTimer()
        local bucket = buckets[playerSource]
        if not bucket or now < bucket.updatedAt then
            bucket = { tokens = LIMITS.callbackBurst, updatedAt = now }
            buckets[playerSource] = bucket
        end
        local elapsed = math.max(0, now - bucket.updatedAt) / 1000
        bucket.tokens = math.min(LIMITS.callbackBurst, bucket.tokens + elapsed * LIMITS.callbackRate)
        bucket.updatedAt = now
        if bucket.tokens < 1 then return false end
        bucket.tokens = bucket.tokens - 1
        return true
    end

    local function emitTransportRateLimit()
        -- Transport admission happens before a callback owner is authorized, so
        -- it cannot safely create a consumer usage row.  These fixed-label Core
        -- counters still account for pressure without accepting client labels.
        emitMetric('increment', 'compat_callbacks_total', { outcome = 'rate_limited' }, 1)
        emitMetric('increment', 'compat_callback_rate_limit_total', {}, 1)
    end

    local function readCallbackSession(playerSource)
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local players = resolved.Players
        local getBySource = type(players) == 'table' and players.getBySource or nil
        if not isCallable(getBySource) then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core player boundary is unavailable.', true)
        end
        local read, session, sessionError = pcall(getBySource, playerSource)
        if not read then
            return nil, bridgeError('COMPAT_INTERNAL',
                'The Core player boundary failed.', true)
        end
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or not boundedString(session.id, 128)
            or not finiteInteger(session.sourceGeneration, 1, MAXIMUM_SAFE_INTEGER)
            or not boundedString(session.characterId, 48) then
            return nil, type(sessionError) == 'table' and sessionError
                or bridgeError('COMPAT_STALE_SESSION',
                    'The callback requires an active fenced session.')
        end
        return session, nil
    end

    local function sessionMatches(playerSource, sessionId, generation, characterId)
        if not validateSource(playerSource) then return false end
        local session = readCallbackSession(playerSource)
        return type(session) == 'table' and session.id == sessionId
            and session.sourceGeneration == generation
            and session.characterId == characterId
    end

    local function removePendingCallback(pendingKey)
        local item = pending[pendingKey]
        if not item then return nil end
        pending[pendingKey] = nil
        local sourceCount = pendingBySource[item.playerSource]
        if type(sourceCount) == 'number' and sourceCount > 1 then
            pendingBySource[item.playerSource] = sourceCount - 1
        else
            pendingBySource[item.playerSource] = nil
        end
        pendingTotal = math.max(0, pendingTotal - 1)
        return item
    end

    local function cancelPendingForCharacter(playerSource, characterId, message)
        local keys = {}
        for key, item in pairs(pending) do
            if item.playerSource == playerSource
                and (characterId == nil or item.characterId == characterId) then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local item = pending[key]
            if item then
                local stale = bridgeError('COMPAT_STALE_SESSION', message
                    or 'The callback character authority is no longer active.')
                finishUsage(item.usageToken, 'denied', stale)
                removePendingCallback(key)
            end
        end
    end

    local function normalizePackedArguments(arguments)
        if type(arguments) ~= 'table' then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'Compatibility callback arguments must be an array.')
        end
        local declaredCount = rawget(arguments, 'n')
        local count = declaredCount ~= nil and declaredCount or rawlen(arguments)
        if not finiteInteger(count, 0, LIMITS.callbackArguments) then
            return nil, bridgeError('COMPAT_DTO_LIMIT',
                'Compatibility callback arguments exceed their bound.')
        end
        local present = 0
        for key in next, arguments do
            if key ~= 'n' and (type(key) ~= 'number'
                or math.type(key) ~= 'integer' or key < 1 or key > count) then
                return nil, bridgeError('COMPAT_DTO_INVALID',
                    'Compatibility callback arguments are not a dense array.')
            end
            if key ~= 'n' then present = present + 1 end
        end
        if present ~= count then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'Compatibility callback arguments are not a dense array.')
        end
        local dense = {}
        for index = 1, count do dense[index] = rawget(arguments, index) end
        local copied, copyError = strictCopy(dense, {
            root = 'array',
            maximumDepth = LIMITS.maximumDepth,
            maximumEntries = LIMITS.maximumEntries,
            maximumBytes = LIMITS.callbackBytes,
            maximumStringBytes = LIMITS.maximumStringBytes,
            maximumArrayItems = LIMITS.callbackArguments,
            maximumObjectProperties = LIMITS.maximumEntries,
        })
        if not copied then return nil, copyError end
        return copied, nil
    end

    RegisterNetEvent(requestEvent, function(
        requestId, callbackConsumer, callbackName, arguments)
        local playerSource = source
        if not validateSource(playerSource) then return end
        if not takeCallbackToken(playerSource) then
            emitTransportRateLimit()
            return
        end
        if not boundedString(requestId, 64) or #requestId < 8
            or not requestId:match('^[A-Za-z0-9_-]+$')
            or not validConsumer(callbackConsumer)
            or not validCallbackName(callbackName) then return end
        local safeArguments = normalizePackedArguments(arguments)
        if not safeArguments then return end
        local encodedOk, encoded = pcall(json.encode, safeArguments)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > LIMITS.callbackBytes then return end
        local entry = callbacks[callbackConsumer .. '\0' .. callbackName]
        if not entry or entry.owner ~= callbackConsumer
            or callbackOwners[callbackName] ~= callbackConsumer then
            TriggerClientEvent(responseEvent, playerSource, requestId, false,
                bridgeError('CALLBACK_DENIED',
                    'The callback consumer is not authorized for this callback.'))
            return
        end
        -- Client resource names are routing hints, not Cfx security principals;
        -- authorization is always re-derived from the registered server owner.
        local callbackOwner = entry.owner
        local authorization, callbackAuthorizationError, usageToken = authorize(
            callbackOwner, 'callbacks', 'callback.invoke', true)
        if not authorization then
            TriggerClientEvent(responseEvent, playerSource, requestId, false,
                callbackAuthorizationError or bridgeError(
                    'CALLBACK_DENIED', 'Callback owner is not authorized.'))
            return
        end
        local session, sessionError = readCallbackSession(playerSource)
        if not session then
            finishUsage(usageToken, usageOutcome(sessionError), sessionError)
            return
        end
        local pendingCount = pendingBySource[playerSource] or 0
        if pendingCount >= LIMITS.callbackPendingPerSource
            or pendingTotal >= LIMITS.callbackPendingGlobal then
            finishUsage(usageToken, 'rate_limited')
            return
        end
        local pendingKey = ('%d:%s:%s:%s:%s'):format(playerSource,
            tostring(session.sourceGeneration), session.characterId,
            callbackOwner, requestId)
        if pending[pendingKey] then finishUsage(usageToken, 'denied'); return end
        local pendingItem = {
            owner = entry.owner,
            consumer = callbackOwner,
            playerSource = playerSource,
            requestId = requestId,
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            characterId = session.characterId,
            usageToken = usageToken,
        }
        pending[pendingKey] = pendingItem
        pendingBySource[playerSource] = pendingCount + 1
        pendingTotal = pendingTotal + 1
        local completed = false
        local function complete(ok, payload)
            if completed or pending[pendingKey] ~= pendingItem then return end
            completed = true
            removePendingCallback(pendingKey)
            local safePayload, payloadError
            if ok == true then
                safePayload, payloadError = normalizePackedArguments(payload)
            else
                safePayload, payloadError = strictCopy(payload, {
                    root = 'object',
                    maximumDepth = 4,
                    maximumEntries = 32,
                    maximumBytes = 4096,
                    maximumStringBytes = 512,
                    maximumArrayItems = 16,
                    maximumObjectProperties = 16,
                })
            end
            if not safePayload then
                ok, safePayload = false, bridgeError(
                    'CALLBACK_RESPONSE_INVALID',
                    'Callback response exceeded bridge limits.')
            end
            local payloadOk, payloadJson = pcall(json.encode, safePayload)
            if not payloadOk or type(payloadJson) ~= 'string'
                or #payloadJson > LIMITS.callbackBytes then
                ok, safePayload = false, bridgeError('CALLBACK_RESPONSE_INVALID', 'Callback response exceeded bridge limits.')
            end
            if not sessionMatches(playerSource, pendingItem.sessionId,
                pendingItem.sourceGeneration, pendingItem.characterId) then
                finishUsage(usageToken, 'denied', bridgeError(
                    'COMPAT_STALE_SESSION',
                    'The callback response belongs to a stale source generation.'))
                return
            end
            finishUsage(usageToken,
                ok == true and 'success' or usageOutcome(safePayload), safePayload)
            TriggerClientEvent(responseEvent, playerSource, requestId, ok == true, safePayload)
        end
        SetTimeout(LIMITS.callbackTimeoutMs, function()
            complete(false, bridgeError('CALLBACK_TIMEOUT', 'Compatibility callback timed out.', true))
        end)
        local response = function(...)
            local packed = table.pack(...)
            complete(true, packed)
        end
        local invoked = runTraced(
            authorization, callbackOwner, 'TriggerCallback', function()
                entry.handler(playerSource, response,
                    table.unpack(safeArguments, 1, rawlen(safeArguments)))
                return true, nil
            end)
        if not invoked then
            complete(false, bridgeError(
                'CALLBACK_FAILED', 'Compatibility callback failed.'))
        end
    end)

    local function lifecycleData(snapshot)
        local mapped, playerData = pcall(lifecycleDefinition.mapper, snapshot)
        if not mapped then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The legacy lifecycle projection failed.', true)
        end
        return strictCopy(playerData, {
            root = 'object', maximumDepth = 8, maximumEntries = 512,
            maximumBytes = 65536, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 128,
        })
    end

    local function sameLifecycleValue(left, right, depth, seen)
        if type(left) ~= type(right) then return false end
        if type(left) ~= 'table' then return left == right end
        if depth > 10 then return false end
        seen = seen or {}
        if seen[left] == right then return true end
        seen[left] = right
        for key, value in pairs(left) do
            if not sameLifecycleValue(value, right[key], depth + 1, seen) then
                return false
            end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end

    local function copyClientConsumerList(value)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil end
        local count = rawlen(value)
        if count > LIMITS.clientConsumers then return nil end
        local copied, seen, present = {}, {}, 0
        for index, consumer in pairs(value) do
            if not finiteInteger(index, 1, count)
                or not boundedString(consumer, 64)
                or not consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
                or seen[consumer] then
                return nil
            end
            present = present + 1
            seen[consumer] = true
            copied[index] = consumer
        end
        if present ~= count then return nil end
        for index = 2, count do
            if copied[index] <= copied[index - 1] then return nil end
        end
        return copied
    end

    local function lifecyclePublication(excludedConsumer)
        local publish, publishError = callBridgeExport('ShouldPublishLifecycle', {
            provider = framework,
            providerResource = resourceName,
            excludedConsumer = excludedConsumer,
        })
        if not publish then
            if type(publishError) == 'table'
                and publishError.code == 'COMPAT_PROVIDER_DISABLED' then
                return nil, nil, true, nil
            end
            return nil, publishError, false, nil
        end
        if type(publish) == 'table' and publish.standby == true then
            local covered = publish.coveredFamilies
            local keyCount = 0
            for key in pairs(publish) do
                if key ~= 'standby' and key ~= 'coveredFamilies' then
                    return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                        'The lifecycle standby result is invalid.', true), false, nil
                end
                keyCount = keyCount + 1
            end
            if keyCount ~= 2 or type(covered) ~= 'table'
                or getmetatable(covered) ~= nil
                or type(covered.qbc) ~= 'boolean'
                or type(covered.qbx) ~= 'boolean'
                or type(covered.esx) ~= 'boolean' then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle standby coverage is invalid.', true), false, nil
            end
            for key in pairs(covered) do
                if key ~= 'qbc' and key ~= 'qbx' and key ~= 'esx' then
                    return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                        'The lifecycle standby family is invalid.', true), false, nil
                end
            end
            return nil, nil, true, {
                qbc = covered.qbc, qbx = covered.qbx, esx = covered.esx,
            }
        end
        local families = type(publish) == 'table' and publish.families or nil
        local surfaces = type(publish) == 'table' and publish.surfaces or nil
        local clientAccess = type(publish) == 'table' and publish.clientAccess or nil
        local expectedSurfaces = PUBLICATION_SURFACES_BY_PROVIDER[framework]
        local authorizationOperations = PUBLICATION_AUTHORIZATION_BY_PROVIDER[framework]
        if type(publish) ~= 'table' or not boundedString(publish.consumer, 64)
            or not publish.consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
            or type(families) ~= 'table' or getmetatable(families) ~= nil
            or type(surfaces) ~= 'table' or getmetatable(surfaces) ~= nil
            or type(clientAccess) ~= 'table' or getmetatable(clientAccess) ~= nil
            or type(expectedSurfaces) ~= 'table'
            or type(authorizationOperations) ~= 'table'
            or type(authorizationOperations[publish.authorizationOperation]) ~= 'string'
            or type(families.qbc) ~= 'boolean'
            or type(families.qbx) ~= 'boolean'
            or type(families.esx) ~= 'boolean' then
            return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                'The lifecycle authorization result is invalid.', true), false, nil
        end
        for key in pairs(families) do
            if key ~= 'qbc' and key ~= 'qbx' and key ~= 'esx' then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle family ownership result is invalid.', true), false, nil
            end
        end
        for key in pairs(publish) do
            if key ~= 'consumer' and key ~= 'traceId' and key ~= 'families'
                and key ~= 'surfaces' and key ~= 'clientAccess'
                and key ~= 'authorizationOperation' then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle authorization result contains an unknown field.', true),
                    false, nil
            end
        end
        for key in pairs(clientAccess) do
            if key ~= 'playerData' and key ~= 'callbacks' then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle client authorization result is invalid.', true),
                    false, nil
            end
        end
        local playerDataConsumers = copyClientConsumerList(clientAccess.playerData)
        local callbackConsumers = copyClientConsumerList(clientAccess.callbacks)
        if not playerDataConsumers or not callbackConsumers
            or authorizationOperations['client.callback.invoke'] == nil
                and #callbackConsumers > 0 then
            return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                'The lifecycle client consumer allowlist is invalid.', true), false, nil
        end
        local copiedSurfaces = {}
        for surface in pairs(expectedSurfaces) do
            if type(surfaces[surface]) ~= 'boolean' then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle surface authorization result is incomplete.', true),
                    false, nil
            end
            copiedSurfaces[surface] = surfaces[surface]
        end
        for surface in pairs(surfaces) do
            if expectedSurfaces[surface] ~= true then
                return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                    'The lifecycle surface authorization result is invalid.', true),
                    false, nil
            end
        end
        local authorized, authorizationError = authorize(
            publish.consumer, authorizationOperations[publish.authorizationOperation],
            publish.authorizationOperation)
        if not authorized then return nil, authorizationError, false, nil end
        return {
            consumer = publish.consumer,
            traceId = boundedString(publish.traceId, 64) and publish.traceId or nil,
            authorizationOperation = publish.authorizationOperation,
            families = {
                qbc = families.qbc,
                qbx = families.qbx,
                esx = families.esx,
            },
            surfaces = copiedSurfaces,
            clientAccess = {
                playerData = playerDataConsumers,
                callbacks = callbackConsumers,
            },
        }, nil, false, nil
    end

    local function invokeLifecycleHandler(name, context)
        local handler = lifecycleDefinition.handlers[name]
        if not handler then return true, nil end
        local invoked, result, operationError = xpcall(function()
            return handler(context)
        end, function()
            return bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The compatibility lifecycle publisher failed.', true)
        end)
        if not invoked then return nil, result end
        if result == false then
            return nil, type(operationError) == 'table' and operationError
                or bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                    'The compatibility lifecycle publisher rejected the projection.', true)
        end
        return true, nil
    end

    local function sortedTopics(topics)
        local result = {}
        for topic in pairs(topics or {}) do result[#result + 1] = topic end
        table.sort(result)
        return result
    end

    local function updateLifecycleEntry(entry, snapshot, publication, topics)
        local playerData, projectionError = lifecycleData(snapshot)
        if not playerData then return nil, projectionError end
        if entry.published == false then
            local retained, retainedError = copyProjection(playerData)
            if not retained then return nil, retainedError end
            local current, currentError = copyProjection(playerData)
            if not current then return nil, currentError end
            local handlerPublication = publication
            if type(entry.handoffCoveredFamilies) == 'table' then
                handlerPublication = safeCopy(publication)
                local handlerFamilies = handlerPublication
                    and handlerPublication.families or nil
                if type(handlerFamilies) ~= 'table' then
                    return nil, bridgeError('COMPAT_AUTHORIZATION_INVALID',
                        'The lifecycle handoff publication is invalid.', true)
                end
                for family, covered in pairs(entry.handoffCoveredFamilies) do
                    if covered == true then handlerFamilies[family] = false end
                end
            end
            local published, handlerError = invokeLifecycleHandler('loaded', {
                source = entry.source,
                consumer = publication.consumer,
                publication = handlerPublication,
                snapshot = snapshot,
                playerData = current,
                fence = safeCopy(entry.fence),
                resync = false,
            })
            if not published then return nil, handlerError end
            entry.playerData = retained
            entry.consumer = publication.consumer
            entry.publication = publication
            entry.published = true
            entry.handoffCoveredFamilies = nil
            return true, nil
        end
        if sameLifecycleValue(entry.playerData, playerData, 0, {})
            and sameLifecycleValue(entry.publication, publication, 0, {}) then
            -- No player projection or publication authorization changed.
            entry.consumer = publication.consumer
            entry.publication = publication
            return true, nil
        end
        local retained, retainedError = copyProjection(playerData)
        if not retained then return nil, retainedError end
        local current, currentError = copyProjection(playerData)
        if not current then return nil, currentError end
        local previous, previousError = copyProjection(entry.playerData)
        if not previous then return nil, previousError end
        local published, handlerError = invokeLifecycleHandler('updated', {
            source = entry.source,
            consumer = publication.consumer,
            publication = publication,
            snapshot = snapshot,
            playerData = current,
            previousPlayerData = previous,
            topics = sortedTopics(topics),
            fence = safeCopy(entry.fence),
        })
        if not published then return nil, handlerError end
        entry.playerData = retained
        entry.consumer = publication.consumer
        entry.publication = publication
        return true, nil
    end

    local function unloadLifecycleEntry(deliveryKey, entry)
        if lifecycleLoads[deliveryKey] ~= entry then return true, nil end
        lifecycleLoads[deliveryKey] = nil
        lifecycleLoadCount = math.max(0, lifecycleLoadCount - 1)
        if entry.published == false then return true, nil end
        local previous, previousError = copyProjection(entry.playerData)
        if not previous then return nil, previousError end
        return invokeLifecycleHandler('unloaded', {
            source = entry.source,
            consumer = entry.consumer,
            publication = entry.publication,
            previousPlayerData = previous,
            fence = safeCopy(entry.fence),
        })
    end

    local function suspendLifecycleEntry(deliveryKey, entry, coveredFamilies)
        if lifecycleLoads[deliveryKey] ~= entry or entry.published == false then
            return true, nil
        end
        -- Fence the retained delivery before invoking provider code. Even if a
        -- public unload notification fails, the entry cannot publish a refresh
        -- until a fresh authoritative load succeeds.
        entry.published = false
        entry.handoffCoveredFamilies = nil
        local publicationFamilies = type(entry.publication) == 'table'
            and entry.publication.families or nil
        if type(coveredFamilies) == 'table'
            and type(publicationFamilies) == 'table' then
            local handoff, handoffCount = {}, 0
            for _, family in ipairs({ 'qbc', 'qbx', 'esx' }) do
                if coveredFamilies[family] == true
                    and publicationFamilies[family] == true then
                    handoff[family] = true
                    handoffCount = handoffCount + 1
                    publicationFamilies[family] = false
                end
            end
            if handoffCount > 0 then entry.handoffCoveredFamilies = handoff end
        end
        local previous, previousError = copyProjection(entry.playerData)
        if not previous then return nil, previousError end
        return invokeLifecycleHandler('unloaded', {
            source = entry.source,
            consumer = entry.consumer,
            publication = entry.publication,
            previousPlayerData = previous,
            fence = safeCopy(entry.fence),
        })
    end

    local function suspendLifecycleEntries(predicate, coveredFamilies)
        local keys = {}
        for key, entry in pairs(lifecycleLoads) do
            if type(entry) == 'table' and predicate(entry) then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        local suspended = false
        for _, key in ipairs(keys) do
            local entry = lifecycleLoads[key]
            if entry then
                suspended = true
                local cleared, clearError = suspendLifecycleEntry(
                    key, entry, coveredFamilies)
                if not cleared then
                    emitMetric('increment', 'compat_projection_update_failed_total', {
                        provider = framework,
                        code = type(clearError) == 'table'
                            and boundedString(clearError.code, 64) or 'UNKNOWN',
                    }, 1)
                end
            end
        end
        return suspended
    end

    local function refreshLifecycleSource(playerSource, state)
        if lifecycleRefreshPending[playerSource] ~= state then return end
        state.scheduled = false
        state.running = true
        local topics = state.topics
        state.topics = {}
        local entry = lifecycleLoads[state.deliveryKey]
        if not entry or entry.source ~= playerSource
            or (lifecycleRefreshGeneration[playerSource] or 0) ~= state.generation then
            lifecycleRefreshPending[playerSource] = nil
            return
        end
        local publication, publicationError, disabled, coveredFamilies =
            lifecyclePublication()
        if publication and not disabled then
            local snapshot, snapshotError = readPlayerInternal(
                playerSource, false, entry.fence)
            if snapshot and sessionMatches(playerSource,
                entry.fence.sessionId, entry.fence.sourceGeneration,
                entry.fence.characterId) then
                local updated, updateError = updateLifecycleEntry(
                    entry, snapshot, publication, topics)
                if not updated then publicationError = updateError end
            else
                publicationError = snapshotError or bridgeError(
                    'COMPAT_STALE_SESSION',
                    'The lifecycle refresh belongs to a stale source generation.')
            end
        elseif disabled then
            local suspended, suspendError = suspendLifecycleEntry(
                state.deliveryKey, entry, coveredFamilies)
            if not suspended then publicationError = suspendError end
        end
        if publicationError then
            emitMetric('increment', 'compat_projection_update_failed_total', {
                provider = framework,
                code = type(publicationError) == 'table'
                    and boundedString(publicationError.code, 64) or 'UNKNOWN',
            }, 1)
        end
        state.running = false
        if lifecycleRefreshPending[playerSource] ~= state then return end
        if next(state.topics) ~= nil
            and (lifecycleRefreshGeneration[playerSource] or 0) == state.generation then
            state.scheduled = true
            SetTimeout(0, function() refreshLifecycleSource(playerSource, state) end)
        else
            lifecycleRefreshPending[playerSource] = nil
        end
    end

    queueLifecycleRefresh = function(topic, target)
        if target ~= nil then
            if type(target) ~= 'table' or getmetatable(target) ~= nil
                or target.source ~= nil
                    and not finiteInteger(target.source, 1, 65534)
                or target.characterId ~= nil
                    and not validSubjectId(target.characterId)
                or target.fence ~= nil
                    and (type(target.fence) ~= 'table'
                        or getmetatable(target.fence) ~= nil
                        or not boundedString(target.fence.sessionId, 64)
                        or not finiteInteger(target.fence.sourceGeneration,
                            1, 9007199254740991)
                        or not validSubjectId(target.fence.characterId)) then
                return false
            end
        end
        local queuedSources = {}
        for deliveryKey, entry in pairs(lifecycleLoads) do
            local playerSource = type(entry) == 'table' and entry.source or nil
            local entryFence = type(entry) == 'table'
                and type(entry.fence) == 'table' and entry.fence or nil
            local targeted = target == nil or entryFence ~= nil
                and (target.source == nil or target.source == playerSource)
                and (target.characterId == nil
                    or target.characterId == entryFence.characterId)
                and (target.fence == nil
                    or target.fence.sessionId == entryFence.sessionId
                    and target.fence.sourceGeneration == entryFence.sourceGeneration
                    and target.fence.characterId == entryFence.characterId)
            if targeted and finiteInteger(playerSource, 1, 65534)
                and not queuedSources[playerSource] then
                queuedSources[playerSource] = true
                local state = lifecycleRefreshPending[playerSource]
                if not state then
                    state = {
                        deliveryKey = deliveryKey,
                        generation = lifecycleRefreshGeneration[playerSource] or 0,
                        topics = {}, scheduled = false, running = false,
                    }
                    lifecycleRefreshPending[playerSource] = state
                end
                state.topics[topic] = true
                if not state.scheduled and not state.running then
                    state.scheduled = true
                    SetTimeout(0, function()
                        refreshLifecycleSource(playerSource, state)
                    end)
                end
            end
        end
        return true
    end

    local function publishLifecycleSource(playerSource, publication, resync)
        local snapshot, snapshotError = readPlayerInternal(playerSource)
        if not snapshot then return nil, snapshotError end
        local deliveryKey = ('%s:%d'):format(
            snapshot.fence.sessionId, snapshot.fence.sourceGeneration)
        local existing = lifecycleLoads[deliveryKey]
        if existing then
            return updateLifecycleEntry(existing, snapshot, publication, {})
        end
        local staleKeys = {}
        for key, entry in pairs(lifecycleLoads) do
            if type(entry) == 'table' and entry.source == playerSource then
                staleKeys[#staleKeys + 1] = key
            end
        end
        table.sort(staleKeys)
        for _, key in ipairs(staleKeys) do
            local unloaded, unloadError = unloadLifecycleEntry(
                key, lifecycleLoads[key])
            if not unloaded then return nil, unloadError end
        end
        if lifecycleLoadCount >= LIMITS.lifecycleLoads then
            return nil, bridgeError('COMPAT_REGISTRY_LIMIT',
                'The compatibility lifecycle delivery registry reached its bound.', true)
        end
        local playerData, projectionError = lifecycleData(snapshot)
        if not playerData then return nil, projectionError end
        local retained, retainedError = copyProjection(playerData)
        if not retained then return nil, retainedError end
        local current, currentError = copyProjection(playerData)
        if not current then return nil, currentError end
        local published, handlerError = invokeLifecycleHandler('loaded', {
            source = playerSource,
            consumer = publication.consumer,
            publication = publication,
            snapshot = snapshot,
            playerData = current,
            fence = safeCopy(snapshot.fence),
            resync = resync == true,
        })
        if not published then return nil, handlerError end
        lifecycleLoads[deliveryKey] = {
            source = playerSource,
            fence = safeCopy(snapshot.fence),
            consumer = publication.consumer,
            publication = publication,
            playerData = retained,
            published = true,
        }
        lifecycleLoadCount = lifecycleLoadCount + 1
        return true, nil
    end

    local function rehydrateActiveLifecycle()
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local sources, sourceError = activeSources(resolved)
        if not sources then return nil, sourceError end
        if #sources == 0 then return true, nil end
        local publication, publicationError, disabled, coveredFamilies =
            lifecyclePublication()
        if disabled then
            suspendLifecycleEntries(function() return true end, coveredFamilies)
            return true, nil
        end
        if not publication then return nil, publicationError end
        for _, playerSource in ipairs(sources) do
            local published, publishError = publishLifecycleSource(
                playerSource, publication, true)
            if not published then return nil, publishError end
        end
        return true, nil
    end

    local function bindLifecycle()
        if lifecycleToken then return lifecycleToken, nil end
        if not lifecycleDefinition then
            return nil, bridgeError('COMPAT_PROJECTION_UNAVAILABLE',
                'The compatibility lifecycle is not configured.')
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local token, registrationError = resolved.Characters.registerLifecycleParticipant({
            name = resourceName,
            priority = -100,
            required = false,
            prepare = function(context)
                return { source = context and context.session and context.session.source }
            end,
            commit = function(prepared)
                local playerSource = prepared and prepared.source
                local publication, publicationError, disabled = lifecyclePublication()
                if disabled then return true end
                if not publication then return nil, publicationError end
                return publishLifecycleSource(playerSource, publication, false)
            end,
            rollback = function() return true end,
            unload = function(context)
                local playerSource = context and context.session and context.session.source
                local session = context and context.session
                if finiteInteger(playerSource, 1, 65534) then
                    cancelPendingForCharacter(playerSource,
                        type(session) == 'table' and session.characterId or nil,
                        'The callback character was unloaded.')
                end
                local entry
                if type(session) == 'table' and type(session.id) == 'string'
                    and finiteInteger(session.sourceGeneration, 1, 9007199254740991) then
                    local deliveryKey = ('%s:%d'):format(
                        session.id, session.sourceGeneration)
                    entry = lifecycleLoads[deliveryKey]
                    if entry then
                        local unloaded, unloadError = unloadLifecycleEntry(
                            deliveryKey, entry)
                        if not unloaded then return nil, unloadError end
                    end
                end
                if finiteInteger(playerSource, 1, 65534) then
                    lifecycleRefreshGeneration[playerSource] =
                        ((lifecycleRefreshGeneration[playerSource] or 0) + 1) & 0x7fffffff
                    lifecycleRefreshPending[playerSource] = nil
                end
                invalidateProjection(playerSource)
                return true
            end,
        })
        if not token then return nil, registrationError end
        lifecycleToken = token
        return token, nil
    end

    function adapter:registerLifecycle(toLegacyPlayerData, handlers)
        assert(isCallable(toLegacyPlayerData) and type(handlers) == 'table',
            'lifecycle mapping is invalid')
        for key, handler in pairs(handlers) do
            if key ~= 'loaded' and key ~= 'updated' and key ~= 'unloaded'
                or not isCallable(handler) then
                return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                    'The compatibility lifecycle handler definition is invalid.')
            end
        end
        if not handlers.loaded or not handlers.unloaded then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT',
                'Loaded and unloaded lifecycle handlers are required.')
        end
        if lifecycleDefinition then
            return nil, bridgeError('COMPAT_OWNER_CONFLICT',
                'The compatibility lifecycle is already registered.')
        end
        lifecycleDefinition = { mapper = toLegacyPlayerData, handlers = handlers }
        local token, bindError = bindLifecycle()
        if not token then return nil, bindError end
        local rehydrated, rehydrateError = rehydrateActiveLifecycle()
        if not rehydrated then return nil, rehydrateError end
        return token, nil
    end

    AddEventHandler('playerDropped', function()
        local playerSource = source
        buckets[playerSource] = nil
        pendingBySource[playerSource] = nil
        lifecycleRefreshGeneration[playerSource] =
            ((lifecycleRefreshGeneration[playerSource] or 0) + 1) & 0x7fffffff
        lifecycleRefreshPending[playerSource] = nil
        invalidateProjection(playerSource)
        projectionRevisions[playerSource] = nil
        local lifecycleKeys = {}
        for key, entry in pairs(lifecycleLoads) do
            if type(entry) == 'table' and entry.source == playerSource then
                lifecycleKeys[#lifecycleKeys + 1] = key
            end
        end
        table.sort(lifecycleKeys)
        for _, key in ipairs(lifecycleKeys) do
            local entry = lifecycleLoads[key]
            if entry then
                local unloaded, unloadError = unloadLifecycleEntry(key, entry)
                if not unloaded then
                    emitMetric('increment', 'compat_projection_update_failed_total', {
                        provider = framework,
                        code = type(unloadError) == 'table'
                            and boundedString(unloadError.code, 64) or 'UNKNOWN',
                    }, 1)
                end
            end
        end
        for key, item in pairs(pending) do
            if item.playerSource == playerSource then
                finishUsage(item.usageToken, 'denied', bridgeError(
                    'COMPAT_STALE_SESSION', 'The callback session disconnected.'))
                removePendingCallback(key)
            end
        end
    end)

    AddEventHandler('onResourceStop', function(stoppedResource)
        if stoppedResource == historicalResource then frameworkConflict = false end
        if stoppedResource == 'synex_core' then
            suspendLifecycleEntries(function() return true end)
            api = nil
            lifecycleToken = nil
            lifecycleRebindGeneration = lifecycleRebindGeneration + 1
            invalidateAllProjections()
            projectionRevisions = {}
            projectionInvalidationReady = false
            projectionInvalidationTokens = {}
            lifecycleRefreshPending = {}
            lifecycleRefreshGeneration = {}
            for _, item in pairs(pending) do
                finishUsage(item.usageToken, 'denied', bridgeError(
                    'COMPAT_STALE_SESSION', 'Core stopped during the callback.'))
            end
            pending = {}
            pendingBySource = {}
            pendingTotal = 0
        end
        if stoppedResource == resourceName then
            for key, item in pairs(pending) do
                finishUsage(item.usageToken, 'denied', bridgeError(
                    'COMPAT_CALLBACK_OWNER_STOPPED',
                    'The compatibility callback provider stopped.', true))
                removePendingCallback(key)
            end
            callbacks = {}
            callbackOwners = {}
            callbackRegistrations = 0
            callbackRegistrationsByOwner = {}
            buckets = {}
            usage = {}
            usageSize = 0
            warningTimes = {}
            return
        end
        for key, entry in pairs(callbacks) do
            if entry.owner == stoppedResource then
                callbacks[key] = nil
                if callbackOwners[entry.name] == stoppedResource then
                    callbackOwners[entry.name] = nil
                end
                callbackRegistrations = math.max(0, callbackRegistrations - 1)
                callbackRegistrationsByOwner[stoppedResource] = math.max(
                    0, (callbackRegistrationsByOwner[stoppedResource] or 1) - 1)
            end
        end
        if callbackRegistrationsByOwner[stoppedResource] == 0 then
            callbackRegistrationsByOwner[stoppedResource] = nil
        end
        for key, item in pairs(pending) do
            if item.owner == stoppedResource then
                finishUsage(item.usageToken, 'error', bridgeError(
                    'COMPAT_CALLBACK_OWNER_STOPPED',
                    'The compatibility callback owner stopped.', true))
                removePendingCallback(key)
                if sessionMatches(item.playerSource, item.sessionId,
                    item.sourceGeneration, item.characterId) then
                    TriggerClientEvent(responseEvent, item.playerSource, item.requestId,
                        false, bridgeError('COMPAT_CALLBACK_OWNER_STOPPED',
                            'The compatibility callback owner stopped.', true))
                end
            end
        end
        local prefix = stoppedResource .. ':'
        for key in pairs(usage) do
            if key:sub(1, #prefix) == prefix then usage[key] = nil; usageSize = math.max(0, usageSize - 1) end
        end
        for key in pairs(warningTimes) do
            if key:sub(1, #prefix) == prefix then warningTimes[key] = nil end
        end
        if stoppedResource ~= 'synex_core' then
            -- Re-evaluate every provider and consumer transition. The
            -- coordinator may transfer the shared QBCore family even when the
            -- stopped resource did not own this provider's local projection.
            local replacement, replacementError, disabled, coveredFamilies =
                lifecyclePublication(stoppedResource)
            if replacement then
                local replacementFailed = false
                for deliveryKey, entry in pairs(lifecycleLoads) do
                    if type(entry) == 'table' and entry.published ~= false then
                        local current = copyProjection(entry.playerData)
                        local previous = copyProjection(entry.playerData)
                        local updated, updateError
                        if current and previous then
                            updated, updateError = invokeLifecycleHandler('updated', {
                                source = entry.source,
                                consumer = replacement.consumer,
                                publication = replacement,
                                playerData = current,
                                previousPlayerData = previous,
                                topics = { 'synex.compat.consumer.stopped' },
                                fence = safeCopy(entry.fence),
                            })
                        end
                        if updated then
                            entry.consumer = replacement.consumer
                            entry.publication = replacement
                        else
                            replacementFailed = true
                            suspendLifecycleEntry(deliveryKey, entry)
                            emitMetric('increment',
                                'compat_projection_update_failed_total', {
                                    provider = framework,
                                    code = type(updateError) == 'table'
                                        and boundedString(updateError.code, 64)
                                        or 'COMPAT_PROJECTION_UNAVAILABLE',
                                }, 1)
                        end
                    end
                end
                if replacementFailed and queueLifecycleRefresh then
                    queueLifecycleRefresh('synex.compat.consumer.stopped')
                end
            else
                suspendLifecycleEntries(function() return true end,
                    disabled and coveredFamilies or nil)
                if replacementError then
                    emitMetric('increment',
                        'compat_projection_update_failed_total', {
                            provider = framework,
                            code = type(replacementError) == 'table'
                                and boundedString(replacementError.code, 64)
                                or 'UNKNOWN',
                        }, 1)
                end
            end
        end
    end)

    AddEventHandler('onResourceStart', function(startedResource)
        if startedResource == historicalResource then refreshFrameworkConflict() end
        if startedResource == 'synex_core' then
            api = nil
            lifecycleToken = nil
            lifecycleRebindGeneration = lifecycleRebindGeneration + 1
            local generation = lifecycleRebindGeneration
            invalidateAllProjections()
            projectionRevisions = {}
            projectionInvalidationReady = false
            projectionInvalidationTokens = {}
            lifecycleRefreshPending = {}
            lifecycleRefreshGeneration = {}
            local attempts = 0
            local function rebind()
                if generation ~= lifecycleRebindGeneration or lifecycleToken
                    or not lifecycleDefinition then return end
                attempts = attempts + 1
                local token = bindLifecycle()
                if token then
                    queueLifecycleRefresh('synex.core.restarted')
                    return
                end
                if attempts >= 20 then return end
                SetTimeout(250, rebind)
            end
            SetTimeout(0, rebind)
        else
            local shouldResume = false
            for _, entry in pairs(lifecycleLoads) do
                if type(entry) == 'table' and entry.published == false then
                    shouldResume = true
                    break
                end
            end
            if lifecycleDefinition then
                SetTimeout(0, function()
                    local rehydrated, rehydrateError = rehydrateActiveLifecycle()
                    if not rehydrated then
                        emitMetric('increment',
                            'compat_projection_update_failed_total', {
                                provider = framework,
                                code = type(rehydrateError) == 'table'
                                    and boundedString(rehydrateError.code, 64)
                                    or 'UNKNOWN',
                            }, 1)
                    end
                    if shouldResume and queueLifecycleRefresh then
                        queueLifecycleRefresh('synex.compat.consumer.started')
                    end
                end)
            end
        end
    end)

    registerUsageAdapter(adapter)
    return adapter
end

SynexBridgeNative = Native

return Native
