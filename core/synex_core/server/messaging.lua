local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.messaging = function(deps)
    local platform = assert(deps.platform, 'messaging requires platform')
    local foundation = assert(deps.foundation, 'messaging requires foundation')
    local contracts = assert(deps.contracts, 'messaging requires contracts')
    local security = assert(deps.security, 'messaging requires security')
    local owners = assert(deps.owners, 'messaging requires owner registry')
    local lifecycle = assert(deps.lifecycle, 'messaging requires lifecycle')
    local players = assert(deps.players, 'messaging requires player registry')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local protocol = deps.protocol or SynexProtocol
    local config = deps.config or {}
    local maximumTransportBytes = config.maximumPayloadBytes or protocol.limits.payloadBytes or 32768
    local maximumTimeoutMs = type(config.maximumTimeoutMs) == 'number'
        and math.type(config.maximumTimeoutMs) == 'integer'
        and config.maximumTimeoutMs >= 50 and config.maximumTimeoutMs <= 15000
        and config.maximumTimeoutMs or 15000
    local defaultTimeoutMs = type(config.timeoutMs) == 'number'
        and math.type(config.timeoutMs) == 'integer'
        and config.timeoutMs >= 50 and math.min(config.timeoutMs, maximumTimeoutMs)
        or math.min(5000, maximumTimeoutMs)

    local rpcHandlers = {}
    local subscriptions = {}
    local hooks = {}
    local subscriptionCounts = {}
    local hookCounts = {}
    local serviceCounts = {}
    local subscriptionCount = 0
    local hookCount = 0
    local serviceCount = 0
    local maximumRegistrationsPerOwner = 256
    local maximumRegistrationsPerRegistry = 4096
    local maximumServicesPerOwner = 128
    local maximumServices = 2048
    local services = {}
    local pendingOutbound = {}
    local activeInbound = {}
    local activeInboundCounts = {}
    local registrationSequence = 0
    local deprecatedUsage = {}
    local deprecatedUsageSize = 0
    local deprecatedWarnedAt = {}

    local function nextSequence()
        registrationSequence = registrationSequence + 1
        return registrationSequence
    end

    local function recordDeprecated(kind, name, version, caller)
        local callerName = tostring(caller or 'unknown'):sub(1, 64)
        local key = table.concat({ kind, name, version, callerName }, ':')
        local entry = deprecatedUsage[key]
        if not entry then
            if deprecatedUsageSize >= 1024 then
                local oldestKey, oldestAt = nil, nil
                for candidate, value in pairs(deprecatedUsage) do
                    if oldestAt == nil or value.lastUsedAtMs < oldestAt then oldestKey, oldestAt = candidate, value.lastUsedAtMs end
                end
                if oldestKey then deprecatedUsage[oldestKey] = nil; deprecatedWarnedAt[oldestKey] = nil; deprecatedUsageSize = deprecatedUsageSize - 1 end
            end
            entry = { kind = kind, name = name, version = version, caller = callerName, calls = 0 }
            deprecatedUsage[key] = entry
            deprecatedUsageSize = deprecatedUsageSize + 1
        end
        entry.calls = entry.calls + 1
        entry.lastUsedAt = foundation.utcIso()
        entry.lastUsedAtMs = foundation.monotonicMs()
        metrics:increment('synex_deprecated_api_calls_total', { kind = kind, name = name, caller = callerName })
        local warnedAt = deprecatedWarnedAt[key]
        if not warnedAt or entry.lastUsedAtMs - warnedAt >= 60000 then
            deprecatedWarnedAt[key] = entry.lastUsedAtMs
            logger:warn('deprecated Synex API used', { kind = kind, name = name, version = version, caller = callerName })
        end
    end

    local function deprecationSnapshot()
        local result = {}
        for _, entry in pairs(deprecatedUsage) do
            result[#result + 1] = {
                kind = entry.kind, name = entry.name, version = entry.version,
                caller = entry.caller, calls = entry.calls, lastUsedAt = entry.lastUsedAt
            }
        end
        table.sort(result, function(a, b)
            if a.name == b.name then return a.caller < b.caller end
            return a.name < b.name
        end)
        return result
    end

    local function validCapabilityName(value)
        return type(value) == 'string' and #value <= 128
            and value:match('^[a-z][a-z0-9%._%-]*$') ~= nil
            and value:match('[%._%-]$') == nil
            and value:match('[%._%-][%._%-]') == nil
    end

    local function validServiceName(value)
        return type(value) == 'string' and #value >= 7 and #value <= 128
            and value:match('^synex%.[a-z][a-z0-9%._%-]*$') ~= nil
            and value:match('[%._%-]$') == nil
            and value:match('[%._%-][%._%-]') == nil
    end

    local function track(owner, epoch, kind, token, cleanup)
        return owners:track(owner, epoch, kind, token, cleanup)
    end

    local validTransportValue

    local function beginInvocation(caller, callerEpoch, provider, providerEpoch)
        local invocation = { cancelled = false, reason = nil, tokens = {} }
        local function abort(reason)
            invocation.cancelled = true
            invocation.reason = tostring(reason or 'owner quiesced')
        end
        local function attach(owner, epoch)
            for _, existing in ipairs(invocation.tokens) do
                if existing.owner == owner and existing.epoch == epoch then return true, nil end
            end
            local token, err = owners:beginOperation(owner, epoch, abort)
            if not token then return nil, err end
            invocation.tokens[#invocation.tokens + 1] = { owner = owner, epoch = epoch, token = token }
            return true, nil
        end
        local attached, attachError = attach(provider, providerEpoch)
        if attached then attached, attachError = attach(caller, callerEpoch) end
        if not attached then
            for _, item in ipairs(invocation.tokens) do
                owners:finishOperation(item.owner, item.epoch, item.token)
            end
            return nil, attachError
        end
        return invocation, nil
    end

    local function finishInvocation(invocation)
        for _, item in ipairs(invocation.tokens) do
            owners:finishOperation(item.owner, item.epoch, item.token)
        end
    end

    local function invocationError(invocation, traceId)
        return foundation.error('REQUEST_ABORTED', 'The request was aborted while its owner was quiescing.', {
            traceId = traceId,
            retryable = true,
            details = { reason = invocation.reason }
        })
    end

    local function normalizeBoundedProviderError(candidate, traceId, declaredErrors)
        if type(candidate) ~= 'table' or getmetatable(candidate) ~= nil
            or not validTransportValue(candidate) then return nil end
        local encodedOk, encoded = pcall(platform.jsonEncode, candidate)
        if not encodedOk or type(encoded) ~= 'string'
            or #encoded > maximumTransportBytes then return nil end
        local allowedFields = { code = true, message = true, retryable = true, details = true }
        for key in pairs(candidate) do
            if type(key) ~= 'string' or not allowedFields[key] then return nil end
        end
        local code = rawget(candidate, 'code')
        local message = rawget(candidate, 'message')
        local retryable = rawget(candidate, 'retryable')
        local details = rawget(candidate, 'details')
        if type(code) ~= 'string' or #code < 2 or #code > 64
            or not code:match('^[A-Z][A-Z0-9_]+$')
            or type(message) ~= 'string' or #message < 1 or #message > 512
            or message:find('[%z\1-\31\127]')
            or (retryable ~= nil and type(retryable) ~= 'boolean')
            or (details ~= nil and (type(details) ~= 'table' or getmetatable(details) ~= nil)) then
            return nil
        end
        if declaredErrors ~= nil then
            local declared = false
            for _, declaredCode in ipairs(declaredErrors) do
                if declaredCode == code then declared = true break end
            end
            if not declared then return nil end
        end
        return foundation.error(code, message, {
            traceId = traceId,
            retryable = retryable == true,
            details = details ~= nil and foundation.copy(details) or nil
        })
    end

    local function normalizeProviderError(contract, candidate, traceId)
        return normalizeBoundedProviderError(candidate, traceId, contract.errors or {})
    end

    local function invokeHandler(entry, request, context)
        if not owners:isCurrent(entry.owner, entry.epoch) then
            return nil, foundation.error('PROVIDER_UNAVAILABLE', 'The contract provider restarted.', {
                traceId = context.traceId, retryable = true
            })
        end
        local handlerContext = foundation.copy(context)
        handlerContext.provider = entry.owner
        local started = foundation.monotonicMs()
        if context.deadlineAt and started >= context.deadlineAt then
            return nil, foundation.error('DEADLINE_EXCEEDED', 'The contract deadline expired before execution.', {
                traceId = context.traceId, retryable = true
            })
        end
        local invocation, invocationStartError = beginInvocation(
            context.caller, context.callerEpoch, entry.owner, entry.epoch
        )
        if not invocation then return nil, invocationStartError end
        local ok, value, handlerError = foundation.safeCall(function(candidate, readonlyContext)
            return foundation.withContext(handlerContext, entry.handler, candidate, readonlyContext)
        end, foundation.copy(request), foundation.readonly(handlerContext))
        finishInvocation(invocation)
        local duration = foundation.monotonicMs() - started
        metrics:increment('synex_contract_calls_total', { contract = entry.contract.name, ok = ok and handlerError == nil })
        metrics:gauge('synex_contract_last_duration_ms', { contract = entry.contract.name }, duration)
        metrics:observe('synex_contract_duration_ms', { contract = entry.contract.name }, duration)
        if invocation.cancelled then return nil, invocationError(invocation, context.traceId) end
        if not ok then
            logger:error('contract handler raised an error', {
                contract = entry.contract.name, provider = entry.owner,
                traceId = context.traceId, code = 'CONTRACT_HANDLER_EXCEPTION'
            })
            return nil, foundation.error('INTERNAL_ERROR', 'The contract provider failed.', { traceId = context.traceId })
        end
        if handlerError ~= nil then
            local normalizedError = normalizeProviderError(entry.contract, handlerError, context.traceId)
            if not normalizedError then
                logger:error('contract handler returned an invalid error', {
                    contract = entry.contract.name, provider = entry.owner,
                    traceId = context.traceId, code = 'INVALID_PROVIDER_ERROR'
                })
                return nil, foundation.error('INTERNAL_ERROR', 'The contract provider returned an invalid error.', { traceId = context.traceId })
            end
            return nil, normalizedError
        end
        if not owners:isCurrent(entry.owner, entry.epoch) then
            return nil, foundation.error('PROVIDER_RESTARTED', 'The provider restarted while processing the request.', {
                traceId = context.traceId, retryable = true
            })
        end
        if context.deadlineAt and foundation.monotonicMs() >= context.deadlineAt then
            return nil, foundation.error('DEADLINE_EXCEEDED', 'The contract deadline expired during execution.', {
                traceId = context.traceId, retryable = true
            })
        end
        local outputValid, outputFailure = validTransportValue(value)
        if not outputValid then
            if outputFailure == 'bytes' then
                logger:error('contract response exceeded transport bounds', {
                    contract = entry.contract.name, provider = entry.owner,
                    traceId = context.traceId, code = 'RESPONSE_TOO_LARGE'
                })
                return nil, foundation.error('RESPONSE_TOO_LARGE',
                    'The contract response exceeds the configured byte limit.', {
                        traceId = context.traceId
                    })
            end
            logger:error('contract response failed transport validation', {
                contract = entry.contract.name, provider = entry.owner,
                traceId = context.traceId, code = 'INVALID_PROVIDER_RESPONSE'
            })
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE',
                'The provider returned an invalid response.', {
                    traceId = context.traceId
                })
        end
        local encodedOk, encodedOutput = pcall(platform.jsonEncode, value)
        if not encodedOk or type(encodedOutput) ~= 'string' then
            logger:error('contract response could not be encoded', {
                contract = entry.contract.name, provider = entry.owner,
                traceId = context.traceId, code = 'INVALID_PROVIDER_RESPONSE'
            })
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE',
                'The provider returned an invalid response.', {
                    traceId = context.traceId
                })
        end
        if #encodedOutput > maximumTransportBytes then
            logger:error('contract response exceeded transport bounds', {
                contract = entry.contract.name, provider = entry.owner,
                traceId = context.traceId, code = 'RESPONSE_TOO_LARGE'
            })
            return nil, foundation.error('RESPONSE_TOO_LARGE',
                'The contract response exceeds the configured byte limit.', {
                    traceId = context.traceId
                })
        end
        local valid, outputError = contracts.registry:validateOutput(entry.contract, value)
        if not valid then
            logger:error('contract response failed validation', {
                contract = entry.contract.name, provider = entry.owner, traceId = context.traceId,
                finding = outputError.details
            })
            outputError.traceId = context.traceId
            return nil, outputError
        end
        return foundation.copy(value), nil
    end

    local gateway = {}
    function gateway:register(owner, epoch, contract, handler)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The contract provider restarted.', { retryable = true })
        end
        if not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_HANDLER', 'A callable contract handler is required.')
        end
        if type(contract) ~= 'table' or getmetatable(contract) ~= nil
            or rawget(contract, 'provider') ~= owner then
            return nil, foundation.error('PROVIDER_MISMATCH', 'The contract provider does not match the resource owner.')
        end
        local registered, contractError = contracts.registry:register(contract)
        if not registered then return nil, contractError end
        local key = registered.name .. '@' .. registered.version
        if rpcHandlers[key] then return nil, foundation.error('HANDLER_EXISTS', 'A handler already provides this contract version.') end
        local token = foundation.nextId('rpc_handler')
        local entry = { owner = owner, epoch = epoch, token = token, contract = registered, handler = handler }
        rpcHandlers[key] = entry
        local _, trackError = track(owner, epoch, 'rpc_handler', token, function()
            if rpcHandlers[key] == entry then rpcHandlers[key] = nil end
        end)
        if trackError then rpcHandlers[key] = nil return nil, trackError end
        return token, nil
    end

    function gateway:invoke(caller, callerEpoch, name, version, request, options)
        options = options or {}
        if not lifecycle.core:isOperational() and options.allowDuringBoot ~= true then
            return nil, foundation.error('NOT_READY', 'The Synex runtime is not ready.', { retryable = true })
        end
        if not owners:isCurrent(caller, callerEpoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The calling resource restarted.', { retryable = true })
        end
        local requestValid, requestFailure = validTransportValue(request)
        if not requestValid then
            local traceId = options.traceId or foundation.nextId('trace')
            if requestFailure == 'bytes' then
                return nil, foundation.error('PAYLOAD_TOO_LARGE',
                    'Contract request exceeds the configured byte limit.', {
                        traceId = traceId
                    })
            end
            return nil, foundation.error('INVALID_PAYLOAD',
                'Contract request must be bounded plain JSON data.', {
                    traceId = traceId
                })
        end
        local encodedOk, encodedRequest = pcall(platform.jsonEncode, request)
        if not encodedOk or type(encodedRequest) ~= 'string' then
            return nil, foundation.error('INVALID_PAYLOAD',
                'Contract request could not be encoded.', {
                    traceId = options.traceId or foundation.nextId('trace')
                })
        end
        if #encodedRequest > maximumTransportBytes then
            return nil, foundation.error('PAYLOAD_TOO_LARGE',
                'Contract request exceeds the configured byte limit.', {
                    traceId = options.traceId or foundation.nextId('trace')
                })
        end
        local contract, contractError = contracts.registry:resolve(name, version)
        if not contract then return nil, contractError end
        if contract.stability == 'deprecated' then recordDeprecated('contract', contract.name, contract.version, caller) end
        local key = contract.name .. '@' .. contract.version
        local entry = rpcHandlers[key]
        if not entry then return nil, foundation.error('PROVIDER_UNAVAILABLE', 'No healthy provider handles this contract.', { retryable = true }) end
        local traceId = options.traceId or foundation.nextId('trace')
        if contract.capability then
            local allowed, capabilityError = security.capabilities:check(caller, contract.capability, {
                traceId = traceId, operation = contract.name
            })
            if not allowed then return nil, capabilityError end
        end
        local valid, validationError = contracts.registry:validateInput(contract, request)
        if not valid then validationError.traceId = traceId return nil, validationError end
        local context = {
            traceId = traceId,
            caller = caller,
            callerEpoch = callerEpoch,
            contract = contract.name,
            version = contract.version,
            session = options.session,
            source = options.source,
            sourceGeneration = options.sourceGeneration,
            deadlineAt = options.deadlineAt,
            idempotencyKey = options.idempotencyKey
        }
        return invokeHandler(entry, request, context)
    end

    local eventBus = {}
    local outboxAuthorization = {}

    local function validEventReference(value, minimum, maximum)
        return type(value) == 'string' and #value >= minimum and #value <= maximum
            and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
    end

    validTransportValue = function(value)
        local active, keys, aggregateBytes, byteLimitExceeded = {}, 0, 0, false
        local maximumDepth = protocol.limits.tableDepth or 12
        local maximumKeys = protocol.limits.tableKeys or 512
        local maximumStringBytes = protocol.limits.stringBytes or 16384
        local function consumeBytes(amount)
            if amount > maximumTransportBytes - aggregateBytes then
                byteLimitExceeded = true
                return false
            end
            aggregateBytes = aggregateBytes + amount
            return true
        end
        local function inspect(candidate, depth)
            local candidateType = type(candidate)
            if candidateType == 'nil' then return consumeBytes(4) end
            if candidateType == 'boolean' then
                return consumeBytes(candidate and 4 or 5)
            end
            if candidateType == 'string' then
                return #candidate <= maximumStringBytes and consumeBytes(#candidate + 2)
            end
            if candidateType == 'number' then
                return candidate == candidate and candidate ~= math.huge
                    and candidate ~= -math.huge and consumeBytes(#tostring(candidate))
            end
            if candidateType ~= 'table' or getmetatable(candidate) ~= nil
                or depth > maximumDepth or active[candidate] then return false end
            if not consumeBytes(2) then return false end
            active[candidate] = true
            local keyType, count, maximumIndex = nil, 0, 0
            for key, child in pairs(candidate) do
                keys = keys + 1
                if keys > maximumKeys then active[candidate] = nil return false end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType ~= 'string' or #key > maximumStringBytes then
                    active[candidate] = nil
                    return false
                end
                if keyType and keyType ~= currentType then active[candidate] = nil return false end
                keyType = currentType
                count = count + 1
                if count > 1 and not consumeBytes(1) then
                    active[candidate] = nil
                    return false
                end
                if currentType == 'string' and not consumeBytes(#key + 3) then
                    active[candidate] = nil
                    return false
                end
                if not inspect(child, depth + 1) then active[candidate] = nil return false end
            end
            active[candidate] = nil
            return keyType ~= 'number' or maximumIndex == count
        end
        local valid = inspect(value, 1)
        return valid, not valid and byteLimitExceeded and 'bytes' or nil
    end

    local function registrationAvailable(counts, owner, total)
        return (counts[owner] or 0) < maximumRegistrationsPerOwner
            and total < maximumRegistrationsPerRegistry
    end

    local function removeSubscription(topic, token, entry)
        local entries = subscriptions[topic]
        if not entries or entries[token] ~= entry then return end
        entries[token] = nil
        subscriptionCount = math.max(0, subscriptionCount - 1)
        subscriptionCounts[entry.owner] = math.max(0, (subscriptionCounts[entry.owner] or 1) - 1)
        if subscriptionCounts[entry.owner] == 0 then subscriptionCounts[entry.owner] = nil end
        if next(entries) == nil then subscriptions[topic] = nil end
    end

    local function validateOutboxMetadata(metadata)
        if type(metadata) ~= 'table' or getmetatable(metadata) ~= nil then
            return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event metadata must be a plain object.')
        end
        local allowed = { eventId = true, aggregateId = true, schemaVersion = true, traceId = true }
        for key in pairs(metadata) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event metadata contains an unknown property.')
            end
        end
        if not validEventReference(metadata.eventId, 8, 36)
            or not validEventReference(metadata.aggregateId, 1, 128)
            or type(metadata.schemaVersion) ~= 'number' or math.type(metadata.schemaVersion) ~= 'integer'
            or metadata.schemaVersion < 1 or metadata.schemaVersion > 65535
            or (metadata.traceId ~= nil and not validEventReference(metadata.traceId, 8, 64)) then
            return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event identity or schema version is invalid.')
        end
        return foundation.copy(metadata), nil
    end
    function eventBus:subscribe(owner, epoch, topic, handler, options)
        if type(topic) ~= 'string' or #topic < 3 or #topic > 128
            or not topic:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$')
            or not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_SUBSCRIPTION', 'Topic and handler are invalid.')
        end
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The event subscriber restarted.')
        end
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_SUBSCRIPTION', 'Subscription options must be a plain object.')
        end
        for key in pairs(options) do
            if key ~= 'priority' then
                return nil, foundation.error('INVALID_SUBSCRIPTION', 'Subscription options contain an unknown property.')
            end
        end
        local priority = options.priority or 0
        if type(priority) ~= 'number' or math.type(priority) ~= 'integer'
            or priority < -1000 or priority > 1000 then
            return nil, foundation.error('INVALID_SUBSCRIPTION',
                'Subscription priority must be an integer from -1000 through 1000.')
        end
        local authorized, authorizationError = security.capabilities:canSubscribeEvent(owner, topic)
        if not authorized then return nil, authorizationError end
        if not registrationAvailable(subscriptionCounts, owner, subscriptionCount) then
            return nil, foundation.error('SUBSCRIPTION_LIMIT_REACHED',
                'The event subscription registration limit has been reached.')
        end
        local token = foundation.nextId('subscription')
        local entry = {
            owner = owner, epoch = epoch, token = token, handler = handler,
            priority = priority, sequence = nextSequence()
        }
        subscriptions[topic] = subscriptions[topic] or {}
        subscriptions[topic][token] = entry
        subscriptionCount = subscriptionCount + 1
        subscriptionCounts[owner] = (subscriptionCounts[owner] or 0) + 1
        local _, trackError = track(owner, epoch, 'subscription', token, function()
            removeSubscription(topic, token, entry)
        end)
        if trackError then removeSubscription(topic, token, entry) return nil, trackError end
        return token, nil
    end
    function eventBus:authorizePublisher(owner, epoch, topic)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The event publisher restarted.')
        end
        return security.capabilities:canPublishEvent(owner, topic)
    end
    local function publishEvent(owner, epoch, topic, payload, options)
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_EVENT', 'Domain event options must be a plain object.')
        end
        local outboxAuthorized = options.__outboxAuthorization == outboxAuthorization
        if not outboxAuthorized and (options.durable ~= nil or options.outbox ~= nil
            or options.eventId ~= nil or options.aggregateId ~= nil or options.schemaVersion ~= nil
            or options.__outboxAuthorization ~= nil) then
            return nil, foundation.error('DURABLE_EVENT_REQUIRES_OUTBOX', 'Durable events must be appended through a domain transaction and outbox.')
        end
        if type(topic) ~= 'string' or #topic < 3 or #topic > 128
            or not topic:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') then
            return nil, foundation.error('INVALID_EVENT', 'Domain event topics must be bounded namespaced identifiers.')
        end
        if not outboxAuthorized then
            for key in pairs(options) do
                if key ~= 'traceId' then
                    return nil, foundation.error('INVALID_EVENT', 'Domain event options contain an unknown property.')
                end
            end
            if options.traceId ~= nil and not validEventReference(options.traceId, 8, 64) then
                return nil, foundation.error('INVALID_EVENT', 'Domain event trace ID is invalid.')
            end
        end
        local authorized, authorizationError = eventBus:authorizePublisher(owner, epoch, topic)
        if not authorized then return nil, authorizationError end
        local payloadValid, payloadFailure = validTransportValue(payload)
        if not payloadValid then
            if payloadFailure == 'bytes' then
                return nil, foundation.error('EVENT_PAYLOAD_TOO_LARGE',
                    'Domain event payload exceeds the configured byte limit.')
            end
            return nil, foundation.error('INVALID_EVENT',
                'Domain event payload must be bounded plain JSON data.')
        end
        local encodedOk, encodedPayload = pcall(platform.jsonEncode, payload)
        if not encodedOk or type(encodedPayload) ~= 'string' then
            return nil, foundation.error('INVALID_EVENT', 'Domain event payload could not be encoded.')
        end
        if #encodedPayload > maximumTransportBytes then
            return nil, foundation.error('EVENT_PAYLOAD_TOO_LARGE', 'Domain event payload exceeds the configured byte limit.')
        end
        local ordered = {}
        for _, entry in pairs(subscriptions[topic] or {}) do ordered[#ordered + 1] = entry end
        table.sort(ordered, function(a, b)
            if a.priority == b.priority then return a.sequence < b.sequence end
            return a.priority > b.priority
        end)
        local report = { delivered = 0, failed = 0 }
        for _, entry in ipairs(ordered) do
            local consumerCurrent = owners:isCurrent(entry.owner, entry.epoch)
            local consumerAuthorized, consumerAuthorizationError = nil, nil
            if consumerCurrent then
                consumerAuthorized, consumerAuthorizationError = security.capabilities:canSubscribeEvent(
                    entry.owner, topic)
            end
            if not consumerCurrent or not consumerAuthorized then
                report.failed = report.failed + 1
                logger:error('domain event subscriber failed', {
                    topic = topic, subscriber = entry.owner,
                    code = not consumerCurrent and 'STALE_SUBSCRIBER'
                        or type(consumerAuthorizationError) == 'table'
                            and type(consumerAuthorizationError.code) == 'string'
                            and consumerAuthorizationError.code:sub(1, 64)
                        or 'SUBSCRIBER_UNAUTHORIZED'
                })
            else
                    local invocation = beginInvocation(owner, epoch, entry.owner, entry.epoch)
                    local ok, failureCode = false, 'SUBSCRIBER_OWNER_UNAVAILABLE'
                    if invocation then
                        local context = {
                            topic = topic, publisher = owner,
                            traceId = options.traceId or foundation.nextId('trace')
                        }
                        if outboxAuthorized then
                            context.durable = true
                            context.outbox = true
                            context.eventId = options.eventId
                            context.aggregateId = options.aggregateId
                            context.schemaVersion = options.schemaVersion
                        end
                        local invoked, result, handlerError = foundation.safeCall(
                            entry.handler, foundation.copy(payload), foundation.readonly(context))
                        finishInvocation(invocation)
                        if invocation.cancelled then
                            failureCode = 'REQUEST_ABORTED'
                        elseif not invoked then
                            failureCode = 'SUBSCRIBER_EXCEPTION'
                        elseif handlerError ~= nil then
                            failureCode = type(handlerError) == 'table' and type(handlerError.code) == 'string'
                                and handlerError.code:sub(1, 64) or 'SUBSCRIBER_ERROR'
                        elseif result == false then
                            failureCode = 'SUBSCRIBER_REJECTED'
                        else
                            ok = true
                        end
                    end
                    if ok then report.delivered = report.delivered + 1
                    else
                        report.failed = report.failed + 1
                        logger:error('domain event subscriber failed', {
                            topic = topic, subscriber = entry.owner, code = failureCode
                        })
                    end
            end
        end
        metrics:increment('synex_domain_events_total', { topic = topic }, 1)
        return report, nil
    end

    function eventBus:publish(owner, epoch, topic, payload, options)
        return publishEvent(owner, epoch, topic, payload, options)
    end

    function eventBus:publishOutbox(owner, epoch, topic, payload, metadata)
        local validated, validationError = validateOutboxMetadata(metadata)
        if not validated then return nil, validationError end
        validated.durable = true
        validated.outbox = true
        validated.__outboxAuthorization = outboxAuthorization
        local report, publishError = publishEvent(owner, epoch, topic, payload, validated)
        if not report then return nil, publishError end
        if report.failed > 0 then
            return nil, foundation.error('OUTBOX_DELIVERY_FAILED',
                'At least one durable event subscriber failed; the event must be retried.', {
                    retryable = true,
                    details = { delivered = report.delivered, failed = report.failed }
                })
        end
        return report, nil
    end
    function eventBus:snapshot()
        local result = {}
        for topic, entries in pairs(subscriptions) do
            local count = 0
            for _, entry in pairs(entries) do if owners:isCurrent(entry.owner, entry.epoch) then count = count + 1 end end
            result[#result + 1] = { topic = topic, subscribers = count }
        end
        table.sort(result, function(a, b) return a.topic < b.topic end)
        return result
    end

    local hookRegistry = {}
    local function ownsHookPolicyAuthority(owner, name)
        if owner == deps.coreResource then return true end
        if type(owner) ~= 'string' or not owner:match('^synex_[a-z0-9_]+$') then return false end
        local ownedPrefix = 'synex.' .. owner:sub(7) .. '.'
        return name:sub(1, #ownedPrefix) == ownedPrefix
    end
    local function removeHook(name, token, entry)
        local entries = hooks[name]
        if not entries or entries[token] ~= entry then return end
        entries[token] = nil
        hookCount = math.max(0, hookCount - 1)
        hookCounts[entry.owner] = math.max(0, (hookCounts[entry.owner] or 1) - 1)
        if hookCounts[entry.owner] == 0 then hookCounts[entry.owner] = nil end
        if next(entries) == nil then hooks[name] = nil end
    end
    function hookRegistry:register(owner, epoch, name, handler, options)
        if type(name) ~= 'string' or #name < 3 or #name > 128
            or not name:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$')
            or not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_HOOK', 'Hook names must be bounded namespaced identifiers and include a handler.')
        end
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The hook provider restarted.')
        end
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_HOOK', 'Hook options must be a plain object.')
        end
        local allowedOptions = { priority = true, required = true, timeoutMs = true }
        for key in pairs(options) do
            if type(key) ~= 'string' or not allowedOptions[key] then
                return nil, foundation.error('INVALID_HOOK', 'Hook options contain an unknown property.')
            end
        end
        local priority = options.priority or 0
        local timeoutMs = options.timeoutMs or 2000
        if type(priority) ~= 'number' or math.type(priority) ~= 'integer'
            or priority < -1000 or priority > 1000
            or type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < 50 or timeoutMs > 10000
            or (options.required ~= nil and type(options.required) ~= 'boolean') then
            return nil, foundation.error('INVALID_HOOK', 'Hook priority, timeout, or required flag is invalid.')
        end
        if options.required == true and not ownsHookPolicyAuthority(owner, name) then
            return nil, foundation.error('HOOK_POLICY_FORBIDDEN',
                'Only Core or the hook namespace owner may register a required policy hook.')
        end
        local authorized, authorizationError = security.capabilities:canRegisterHook(owner, name)
        if not authorized then return nil, authorizationError end
        if not registrationAvailable(hookCounts, owner, hookCount) then
            return nil, foundation.error('HOOK_LIMIT_REACHED',
                'The hook registration limit has been reached.')
        end
        local token = foundation.nextId('hook')
        local entry = {
            owner = owner, epoch = epoch, token = token, handler = handler,
            priority = priority, sequence = nextSequence(),
            required = options.required == true, timeoutMs = timeoutMs
        }
        hooks[name] = hooks[name] or {}
        hooks[name][token] = entry
        hookCount = hookCount + 1
        hookCounts[owner] = (hookCounts[owner] or 0) + 1
        local _, trackError = track(owner, epoch, 'hook', token, function()
            removeHook(name, token, entry)
        end)
        if trackError then removeHook(name, token, entry) return nil, trackError end
        return token, nil
    end
    function hookRegistry:run(owner, epoch, name, value, context)
        if not owners:isCurrent(owner, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The hook caller restarted.') end
        local authorized, authorizationError = security.capabilities:canRunHook(owner, name)
        if not authorized then return nil, authorizationError end
        local valueValid, valueFailure = validTransportValue(value)
        if not valueValid then
            if valueFailure == 'bytes' then
                return nil, foundation.error('HOOK_PAYLOAD_TOO_LARGE',
                    'Hook values exceed the configured byte limit.')
            end
            return nil, foundation.error('INVALID_HOOK',
                'Hook values must be bounded plain JSON data.')
        end
        local encodedValueOk, encodedValue = pcall(platform.jsonEncode, value)
        if not encodedValueOk or type(encodedValue) ~= 'string' then
            return nil, foundation.error('INVALID_HOOK', 'Hook values must be JSON encodable.')
        end
        if #encodedValue > maximumTransportBytes then
            return nil, foundation.error('HOOK_PAYLOAD_TOO_LARGE',
                'Hook values exceed the configured byte limit.')
        end
        local suppliedContext = context or {}
        local contextValid, contextFailure = validTransportValue(suppliedContext)
        if type(suppliedContext) ~= 'table' or getmetatable(suppliedContext) ~= nil
            or not contextValid then
            if contextFailure == 'bytes' then
                return nil, foundation.error('HOOK_CONTEXT_TOO_LARGE',
                    'Hook context exceeds the configured byte limit.')
            end
            return nil, foundation.error('INVALID_HOOK_CONTEXT',
                'Hook context must be bounded plain JSON data.')
        end
        local allowedContext = { traceId = true, timeoutMs = true, metadata = true }
        for field in pairs(suppliedContext) do
            if type(field) ~= 'string' or not allowedContext[field] then
                return nil, foundation.error('INVALID_HOOK_CONTEXT',
                    'Hook context contains an unsupported field.')
            end
        end
        local suppliedTraceId = rawget(suppliedContext, 'traceId')
        local suppliedTimeout = rawget(suppliedContext, 'timeoutMs')
        local suppliedMetadata = rawget(suppliedContext, 'metadata')
        if suppliedTraceId ~= nil and (type(suppliedTraceId) ~= 'string'
                or #suppliedTraceId < 8 or #suppliedTraceId > (protocol.limits.traceId or 64)
                or not suppliedTraceId:match('^[A-Za-z0-9_.:%-]+$'))
            or suppliedTimeout ~= nil and (type(suppliedTimeout) ~= 'number'
                or math.type(suppliedTimeout) ~= 'integer' or suppliedTimeout < 100
                or suppliedTimeout > maximumTimeoutMs)
            or suppliedMetadata ~= nil and type(suppliedMetadata) ~= 'table' then
            return nil, foundation.error('INVALID_HOOK_CONTEXT',
                'Hook context fields are invalid.')
        end
        local encodedContextOk, encodedContext = pcall(platform.jsonEncode, suppliedContext)
        if not encodedContextOk or type(encodedContext) ~= 'string' then
            return nil, foundation.error('INVALID_HOOK_CONTEXT',
                'Hook context could not be encoded.')
        end
        if #encodedContext > maximumTransportBytes then
            return nil, foundation.error('HOOK_CONTEXT_TOO_LARGE',
                'Hook context exceeds the configured byte limit.')
        end
        local ordered = {}
        for _, entry in pairs(hooks[name] or {}) do ordered[#ordered + 1] = entry end
        table.sort(ordered, function(a, b)
            if a.priority == b.priority then return a.sequence < b.sequence end
            return a.priority > b.priority
        end)
        local candidate = foundation.copy(value)
        local deadlineAt = foundation.monotonicMs()
            + (suppliedTimeout or defaultTimeoutMs)
        local hookContext = {
            caller = owner,
            callerEpoch = epoch,
            hook = name,
            traceId = suppliedTraceId or foundation.nextId('trace'),
            deadlineAt = deadlineAt,
            metadata = suppliedMetadata ~= nil and foundation.copy(suppliedMetadata) or nil
        }
        for _, entry in ipairs(ordered) do
            if foundation.monotonicMs() >= deadlineAt then
                return nil, foundation.error('DEADLINE_EXCEEDED',
                    'The hook deadline expired before execution.', {
                        traceId = hookContext.traceId, retryable = true
                    })
            end
            local providerCurrent = owners:isCurrent(entry.owner, entry.epoch)
            local providerAuthorized, providerAuthorizationError = nil, nil
            if providerCurrent then
                providerAuthorized, providerAuthorizationError = security.capabilities:canRegisterHook(
                    entry.owner, name)
            end
            if not providerCurrent or not providerAuthorized then
                local failureCode = not providerCurrent and 'STALE_HOOK_PROVIDER'
                    or type(providerAuthorizationError) == 'table'
                        and type(providerAuthorizationError.code) == 'string'
                        and providerAuthorizationError.code:sub(1, 64)
                    or 'HOOK_PROVIDER_UNAUTHORIZED'
                logger:error('hook provider unavailable', {
                    hook = name, owner = entry.owner, code = failureCode
                })
                if entry.required then
                    return nil, foundation.error('REQUIRED_HOOK_FAILED',
                        'A required hook provider is unavailable.', { retryable = true })
                end
            else
                local started = foundation.monotonicMs()
                local invocation = beginInvocation(owner, epoch, entry.owner, entry.epoch)
                local ok, result = false, nil
                if invocation then
                    ok, result = foundation.safeCall(entry.handler, foundation.copy(candidate), foundation.readonly(hookContext))
                    finishInvocation(invocation)
                    if invocation.cancelled then
                        if entry.required then return nil, invocationError(invocation, hookContext.traceId) end
                        ok, result = false, invocation.reason
                    end
                else
                    result = 'hook owner is quiescing'
                end
                local elapsed = foundation.monotonicMs() - started
                if foundation.monotonicMs() >= deadlineAt then
                    return nil, foundation.error('DEADLINE_EXCEEDED',
                        'The hook deadline expired during execution.', {
                            traceId = hookContext.traceId, retryable = true
                        })
                elseif not ok or elapsed > entry.timeoutMs then
                    logger:error('hook failed', {
                        hook = name, owner = entry.owner, elapsedMs = elapsed,
                        code = type(result) == 'table' and type(result.code) == 'string'
                            and result.code:sub(1, 64) or not ok and 'HOOK_EXCEPTION' or 'HOOK_TIMEOUT'
                    })
                    if entry.required then return nil, foundation.error('REQUIRED_HOOK_FAILED', 'A required hook failed.', { retryable = true }) end
                elseif type(result) ~= 'table' or getmetatable(result) ~= nil
                    or not validTransportValue(result) then
                    if entry.required then return nil, foundation.error('INVALID_HOOK_RESULT', 'A required hook returned an invalid result.') end
                else
                    local encodedResultOk, encodedResult = pcall(platform.jsonEncode, result)
                    if not encodedResultOk or type(encodedResult) ~= 'string'
                        or #encodedResult > maximumTransportBytes then
                        if entry.required then
                            return nil, foundation.error('INVALID_HOOK_RESULT',
                                'A required hook returned a result outside transport bounds.')
                        end
                        goto continue_hook
                    end
                    local action = rawget(result, 'action')
                    local allowedFields = action == 'allow' and { action = true }
                        or action == 'deny' and { action = true, code = true, message = true }
                        or action == 'patch' and { action = true, value = true }
                        or nil
                    local closed = allowedFields ~= nil
                    for key in pairs(result) do
                        if type(key) ~= 'string' or not allowedFields or not allowedFields[key] then
                            closed = false
                            break
                        end
                    end
                    if not closed then
                        if entry.required then
                            return nil, foundation.error('INVALID_HOOK_RESULT',
                                'A required hook returned an invalid result.')
                        end
                    elseif action == 'deny' then
                        if ownsHookPolicyAuthority(entry.owner, name) then
                            local code = rawget(result, 'code') or 'HOOK_DENIED'
                            local message = rawget(result, 'message') or 'The operation was denied by policy.'
                            if type(code) ~= 'string' or #code < 2 or #code > 64
                                or not code:match('^[A-Z][A-Z0-9_]+$')
                                or type(message) ~= 'string' or #message < 1 or #message > 512
                                or message:find('[%z\1-\31\127]') then
                                return nil, foundation.error('HOOK_DENIED',
                                    'The operation was denied by policy.')
                            end
                            return nil, foundation.error(code, message)
                        end
                    elseif action == 'patch' then
                        local patched = rawget(result, 'value')
                        if type(patched) ~= 'table' or getmetatable(patched) ~= nil then
                            if entry.required then
                                return nil, foundation.error('INVALID_HOOK_PATCH',
                                    'Hook patch must contain a plain object value.')
                            end
                            goto continue_hook
                        end
                        candidate = foundation.copy(patched)
                    end
                end
            end
            ::continue_hook::
        end
        if not validTransportValue(candidate) then
            return nil, foundation.error('INVALID_HOOK_PATCH',
                'The final hook value is outside transport bounds.')
        end
        local encodedCandidateOk, encodedCandidate = pcall(platform.jsonEncode, candidate)
        if not encodedCandidateOk or type(encodedCandidate) ~= 'string'
            or #encodedCandidate > maximumTransportBytes then
            return nil, foundation.error('INVALID_HOOK_PATCH',
                'The final hook value is outside transport bounds.')
        end
        return candidate, nil
    end
    function hookRegistry:snapshot()
        local result = {}
        for name, entries in pairs(hooks) do
            local count, required = 0, 0
            for _, entry in pairs(entries) do
                if owners:isCurrent(entry.owner, entry.epoch) then
                    count = count + 1
                    if entry.required then required = required + 1 end
                end
            end
            result[#result + 1] = { name = name, handlers = count, required = required }
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end

    local serviceRegistry = {}
    local function serviceKey(name, major) return name .. '@' .. tostring(major) end
    local function syncProviderHealth(entry)
        local synchronized, synchronizationError = deps.dependencies:setProviderHealth(
            entry.owner, entry.name, entry.version, entry.health, entry.circuit)
        if not synchronized then
            logger:error('service provider health synchronization failed', {
                service = entry.name,
                provider = entry.owner,
                code = synchronizationError.code
            })
        end
        return synchronized, synchronizationError
    end
    function serviceRegistry:provide(owner, epoch, definition)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The service provider restarted.', { retryable = true })
        end
        if type(definition) ~= 'table' or getmetatable(definition) ~= nil then
            return nil, foundation.error('INVALID_SERVICE', 'Service name, semantic version, and methods are required.')
        end
        local allowedDefinitionFields = {
            name = true, version = true, methods = true, capabilities = true,
            priority = true, stability = true
        }
        for field in pairs(definition) do
            if type(field) ~= 'string' or not allowedDefinitionFields[field] then
                return nil, foundation.error('INVALID_SERVICE',
                    'Service definitions contain an unsupported field.')
            end
        end
        if type(definition.name) ~= 'string' or type(definition.version) ~= 'string'
            or type(definition.methods) ~= 'table' or getmetatable(definition.methods) ~= nil
            or (definition.capabilities ~= nil and (type(definition.capabilities) ~= 'table'
                or getmetatable(definition.capabilities) ~= nil)) then
            return nil, foundation.error('INVALID_SERVICE',
                'Service name, semantic version, plain methods, and plain capabilities are required.')
        end
        if not validServiceName(definition.name) then
            return nil, foundation.error('INVALID_SERVICE', 'Service names must be bounded namespaced identifiers.')
        end
        local version = foundation.semver(definition.version)
        if not version then return nil, foundation.error('INVALID_SERVICE_VERSION', 'Service version must be semantic.') end
        local stability = definition.stability or 'stable'
        if stability ~= 'stable' and stability ~= 'experimental' and stability ~= 'deprecated' and stability ~= 'internal' then
            return nil, foundation.error('INVALID_SERVICE', 'Service stability is invalid.')
        end
        local priority = definition.priority == nil and 0 or definition.priority
        if type(priority) ~= 'number' or math.type(priority) ~= 'integer'
            or priority < -1000 or priority > 1000 then
            return nil, foundation.error('INVALID_SERVICE',
                'Service priority must be an integer from -1000 through 1000.')
        end
        local key = serviceKey(definition.name, version.major)
        local providers = services[key]
        if providers and providers[owner] then
            return nil, foundation.error('SERVICE_PROVIDER_EXISTS',
                'The resource already provides this service major.')
        end
        if (serviceCounts[owner] or 0) >= maximumServicesPerOwner
            or serviceCount >= maximumServices then
            return nil, foundation.error('SERVICE_REGISTRATION_LIMIT',
                'The service provider registration limit was reached.')
        end
        local registeredMethods, methodCapabilities = {}, {}
        local methodCount = 0
        for method, handler in pairs(definition.methods) do
            methodCount = methodCount + 1
            if methodCount > 64 then
                return nil, foundation.error('INVALID_SERVICE',
                    'A service may expose at most 64 methods.')
            end
            if type(method) ~= 'string' or #method < 1 or #method > 64
                or not method:match('^[a-z][a-zA-Z0-9_]*$')
                or not foundation.isCallable(handler) then
                return nil, foundation.error('INVALID_SERVICE_METHOD',
                    'Service methods must map valid names to callable handlers.')
            end
            local capability = type(definition.capabilities) == 'table' and definition.capabilities[method] or nil
            if capability ~= nil and not validCapabilityName(capability) then
                return nil, foundation.error('INVALID_SERVICE_CAPABILITY', 'Service method capabilities must be valid capability names.')
            end
            registeredMethods[method] = handler
            methodCapabilities[method] = capability
        end
        if methodCount == 0 then
            return nil, foundation.error('INVALID_SERVICE', 'A service must expose at least one method.')
        end
        local capabilityCount = 0
        for method in pairs(type(definition.capabilities) == 'table' and definition.capabilities or {}) do
            capabilityCount = capabilityCount + 1
            if capabilityCount > 64 then
                return nil, foundation.error('INVALID_SERVICE_CAPABILITY',
                    'A service may declare at most 64 method capabilities.')
            end
            if definition.methods[method] == nil then
                return nil, foundation.error('INVALID_SERVICE_CAPABILITY', 'Capability metadata references an unknown service method.')
            end
        end
        local token = foundation.nextId('service')
        local entry = {
            owner = owner, epoch = epoch, token = token, name = definition.name, version = definition.version,
            methods = registeredMethods, methodCapabilities = methodCapabilities,
            priority = priority,
            stability = stability,
            health = 'HEALTHY', failures = 0, circuit = 'CLOSED', openedAt = nil
        }
        providers = providers or {}
        services[key] = providers
        providers[owner] = entry
        serviceCounts[owner] = (serviceCounts[owner] or 0) + 1
        serviceCount = serviceCount + 1
        local function removeEntry()
            if services[key] and services[key][owner] == entry then
                services[key][owner] = nil
                serviceCounts[owner] = math.max(0, (serviceCounts[owner] or 1) - 1)
                if serviceCounts[owner] == 0 then serviceCounts[owner] = nil end
                serviceCount = math.max(0, serviceCount - 1)
                if next(services[key]) == nil then services[key] = nil end
            end
            deps.dependencies:removeProvider(owner, definition.name, definition.version)
        end
        local provided, provideError = deps.dependencies:provide(
            owner, definition.name, definition.version)
        if not provided then removeEntry() return nil, provideError end
        local synchronized, synchronizationError = syncProviderHealth(entry)
        if not synchronized then
            removeEntry()
            return nil, synchronizationError
        end
        local _, trackError = track(owner, epoch, 'service', token, function()
            removeEntry()
        end)
        if trackError then
            removeEntry()
            return nil, trackError
        end
        return token, nil
    end
    function serviceRegistry:setHealth(owner, epoch, name, versionValue, health)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The service provider restarted.')
        end
        if not validServiceName(name) then
            return nil, foundation.error('INVALID_SERVICE', 'Service names must be bounded namespaced identifiers.')
        end
        local version = foundation.semver(versionValue)
        if not version then
            return nil, foundation.error('INVALID_SERVICE_VERSION', 'Service version must be semantic.')
        end
        if health ~= 'HEALTHY' and health ~= 'DEGRADED' and health ~= 'UNHEALTHY' then
            return nil, foundation.error('INVALID_PROVIDER_HEALTH', 'Provider health is invalid.')
        end
        local entry = services[serviceKey(name, version.major)]
            and services[serviceKey(name, version.major)][owner] or nil
        if not entry or entry.epoch ~= epoch or entry.version ~= versionValue then
            return nil, foundation.error('PROVIDER_NOT_REGISTERED', 'The resource does not own this service version.')
        end
        entry.health = health
        local synchronized, synchronizationError = syncProviderHealth(entry)
        if not synchronized then return nil, synchronizationError end
        return true, nil
    end
    local function chooseProvider(name, range)
        local target = type(range) == 'string' and range:match('%d+%.%d+%.%d+') or nil
        local wanted = target and foundation.semver(target) or nil
        if not wanted then return nil end
        local candidates = {}
        for _, entry in pairs(services[serviceKey(name, wanted.major)] or {}) do
            if entry.circuit == 'OPEN' and entry.openedAt
                and foundation.monotonicMs() - entry.openedAt >= (config.circuitResetMs or 5000) then
                entry.circuit = 'HALF_OPEN'
                syncProviderHealth(entry)
            end
            if owners:isCurrent(entry.owner, entry.epoch) and entry.health ~= 'UNHEALTHY'
                and entry.circuit ~= 'OPEN' and foundation.semverSatisfies(entry.version, range) then
                candidates[#candidates + 1] = entry
            end
        end
        table.sort(candidates, function(a, b)
            if a.priority == b.priority then
                if a.version == b.version then return a.owner < b.owner end
                return foundation.semverCompare(
                    assert(foundation.semver(a.version)),
                    assert(foundation.semver(b.version))
                ) > 0
            end
            return a.priority > b.priority
        end)
        return candidates[1]
    end
    function serviceRegistry:call(caller, callerEpoch, name, range, method, request, context)
        if not owners:isCurrent(caller, callerEpoch) then return nil, foundation.error('STALE_RESOURCE', 'The service caller restarted.') end
        if not validServiceName(name) or type(range) ~= 'string' or #range < 1 or #range > 64
            or type(method) ~= 'string' or #method < 1 or #method > 64
            or not method:match('^[a-z][a-zA-Z0-9_]*$') then
            return nil, foundation.error('INVALID_SERVICE',
                'Service call identity is invalid.')
        end
        local requestValid, requestFailure = validTransportValue(request)
        if type(request) ~= 'table' or not requestValid then
            if requestFailure == 'bytes' then
                return nil, foundation.error('PAYLOAD_TOO_LARGE',
                    'Service request exceeds the configured byte limit.')
            end
            return nil, foundation.error('INVALID_ARGUMENT',
                'Service requests must be bounded plain JSON objects.')
        end
        local encodedOk, encodedRequest = pcall(platform.jsonEncode, request)
        if not encodedOk or type(encodedRequest) ~= 'string' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Service request could not be encoded.')
        end
        if #encodedRequest > (config.maximumPayloadBytes or protocol.limits.payloadBytes or 32768) then
            return nil, foundation.error('PAYLOAD_TOO_LARGE', 'Service request exceeds the configured byte limit.')
        end
        local provider = chooseProvider(name, range)
        if not provider then return nil, foundation.error('SERVICE_UNAVAILABLE', 'No compatible healthy service provider is available.', { retryable = true }) end
        if provider.stability == 'deprecated' then recordDeprecated('service', provider.name, provider.version, caller) end
        local handler = provider.methods[method]
        if not handler then return nil, foundation.error('SERVICE_METHOD_NOT_FOUND', 'The requested service method does not exist.') end
        local capability = provider.methodCapabilities[method]
        if caller ~= deps.coreResource and caller ~= provider.owner then
            if not capability then
                return nil, foundation.error('SERVICE_METHOD_PRIVATE', 'The requested service method is not exposed to other resources.')
            end
            local allowed, capabilityError = security.capabilities:check(caller, capability, {
                operation = name .. '.' .. method,
                traceId = type(context) == 'table' and context.traceId or nil
            })
            if not allowed then return nil, capabilityError end
        end
        local suppliedContext = context or {}
        local contextValid, contextFailure = validTransportValue(suppliedContext)
        if type(suppliedContext) ~= 'table' or getmetatable(suppliedContext) ~= nil
            or not contextValid then
            if contextFailure == 'bytes' then
                return nil, foundation.error('PAYLOAD_TOO_LARGE',
                    'Service context exceeds the configured byte limit.')
            end
            return nil, foundation.error('INVALID_SERVICE_CONTEXT',
                'Service context must be bounded plain JSON data.')
        end
        local allowedContext = {
            traceId = true, timeoutMs = true, idempotencyKey = true, metadata = true
        }
        for field in pairs(suppliedContext) do
            if type(field) ~= 'string' or not allowedContext[field] then
                return nil, foundation.error('INVALID_SERVICE_CONTEXT',
                    'Service context contains an unsupported field.')
            end
        end
        local suppliedTraceId = rawget(suppliedContext, 'traceId')
        local suppliedTimeout = rawget(suppliedContext, 'timeoutMs')
        local suppliedIdempotencyKey = rawget(suppliedContext, 'idempotencyKey')
        local suppliedMetadata = rawget(suppliedContext, 'metadata')
        if suppliedTraceId ~= nil and (type(suppliedTraceId) ~= 'string'
                or #suppliedTraceId < 8 or #suppliedTraceId > (protocol.limits.traceId or 64)
                or not suppliedTraceId:match('^[A-Za-z0-9_.:%-]+$'))
            or suppliedTimeout ~= nil and (type(suppliedTimeout) ~= 'number'
                or math.type(suppliedTimeout) ~= 'integer' or suppliedTimeout < 100
                or suppliedTimeout > maximumTimeoutMs)
            or suppliedIdempotencyKey ~= nil and (type(suppliedIdempotencyKey) ~= 'string'
                or #suppliedIdempotencyKey < 8
                or #suppliedIdempotencyKey > 128
                or not suppliedIdempotencyKey:match('^[A-Za-z0-9_.:%-]+$'))
            or suppliedMetadata ~= nil and type(suppliedMetadata) ~= 'table' then
            return nil, foundation.error('INVALID_SERVICE_CONTEXT',
                'Service context fields are invalid.')
        end
        local encodedContextOk, encodedContext = pcall(platform.jsonEncode, suppliedContext)
        if not encodedContextOk or type(encodedContext) ~= 'string' then
            return nil, foundation.error('INVALID_SERVICE_CONTEXT',
                'Service context could not be encoded.')
        end
        if #encodedContext > maximumTransportBytes then
            return nil, foundation.error('PAYLOAD_TOO_LARGE',
                'Service context exceeds the configured byte limit.')
        end
        local deadlineAt = foundation.monotonicMs()
            + (suppliedTimeout or defaultTimeoutMs)
        local serviceContext = {
            caller = caller,
            callerEpoch = callerEpoch,
            service = name,
            serviceVersion = provider.version,
            method = method,
            traceId = suppliedTraceId or foundation.nextId('trace'),
            deadlineAt = deadlineAt,
            idempotencyKey = suppliedIdempotencyKey,
            metadata = suppliedMetadata ~= nil and foundation.copy(suppliedMetadata) or nil
        }
        serviceContext.provider = provider.owner
        if foundation.monotonicMs() >= deadlineAt then
            return nil, foundation.error('DEADLINE_EXCEEDED',
                'The service deadline expired before execution.', {
                    traceId = serviceContext.traceId, retryable = true
                })
        end
        local invocation, invocationStartError = beginInvocation(caller, callerEpoch, provider.owner, provider.epoch)
        if not invocation then return nil, invocationStartError end
        local ok, value, handlerError = foundation.safeCall(function(candidate, readonlyContext)
            return foundation.withContext(serviceContext, handler, candidate, readonlyContext)
        end, foundation.copy(request), foundation.readonly(serviceContext))
        finishInvocation(invocation)
        if invocation.cancelled then return nil, invocationError(invocation, serviceContext.traceId) end
        if foundation.monotonicMs() >= deadlineAt then
            return nil, foundation.error('DEADLINE_EXCEEDED',
                'The service deadline expired during execution.', {
                    traceId = serviceContext.traceId, retryable = true
                })
        end
        if not ok or handlerError ~= nil then
            provider.failures = provider.failures + 1
            if provider.circuit == 'HALF_OPEN' or provider.failures >= 5 then
                provider.circuit = 'OPEN'
                provider.openedAt = foundation.monotonicMs()
            end
            syncProviderHealth(provider)
            local normalizedError = ok
                and normalizeBoundedProviderError(handlerError, serviceContext.traceId, nil) or nil
            local failureCode = not ok and 'SERVICE_PROVIDER_EXCEPTION'
                or normalizedError and normalizedError.code or 'INVALID_SERVICE_PROVIDER_ERROR'
            logger:error('service provider failed', {
                service = name, method = method, provider = provider.owner,
                traceId = serviceContext.traceId, code = failureCode
            })
            return nil, normalizedError or foundation.error('SERVICE_FAILED',
                'The service provider failed.', {
                    traceId = serviceContext.traceId, retryable = true
                })
        end
        if not validTransportValue(value) then
            provider.failures = provider.failures + 1
            if provider.circuit == 'HALF_OPEN' or provider.failures >= 5 then
                provider.circuit = 'OPEN'
                provider.openedAt = foundation.monotonicMs()
            end
            syncProviderHealth(provider)
            logger:error('service provider returned an invalid response', {
                service = name, method = method, provider = provider.owner,
                traceId = serviceContext.traceId, code = 'INVALID_SERVICE_PROVIDER_RESPONSE'
            })
            return nil, foundation.error('SERVICE_FAILED',
                'The service provider returned an invalid response.', {
                    traceId = serviceContext.traceId, retryable = true
                })
        end
        local encodedResponseOk, encodedResponse = pcall(platform.jsonEncode, value)
        if not encodedResponseOk or type(encodedResponse) ~= 'string'
            or #encodedResponse > maximumTransportBytes then
            provider.failures = provider.failures + 1
            if provider.circuit == 'HALF_OPEN' or provider.failures >= 5 then
                provider.circuit = 'OPEN'
                provider.openedAt = foundation.monotonicMs()
            end
            syncProviderHealth(provider)
            logger:error('service provider response exceeded transport bounds', {
                service = name, method = method, provider = provider.owner,
                traceId = serviceContext.traceId, code = 'SERVICE_RESPONSE_TOO_LARGE'
            })
            return nil, foundation.error('SERVICE_FAILED',
                'The service provider response exceeded transport bounds.', {
                    traceId = serviceContext.traceId, retryable = true
                })
        end
        provider.failures = 0
        provider.circuit = 'CLOSED'
        provider.openedAt = nil
        syncProviderHealth(provider)
        return foundation.copy(value), nil
    end
    function serviceRegistry:snapshot()
        local output = {}
        for key, providers in pairs(services) do
            output[key] = {}
            for owner, entry in pairs(providers) do
                output[key][owner] = { version = entry.version, stability = entry.stability, health = entry.health, circuit = entry.circuit }
            end
        end
        return output
    end

    local network = {}
    local function sessionStateAllowed(contract, candidate)
        if not contract.sessionStates or #contract.sessionStates == 0 then return true end
        for _, allowedState in ipairs(contract.sessionStates) do
            if allowedState == candidate.state then return true end
        end
        return false
    end
    local function sessionExplicitlyDenies(candidate, capability)
        if not capability then return false end
        for _, denied in ipairs(candidate.deniedPermissions or {}) do
            if type(denied) == 'string' and foundation.wildcardMatch(denied, capability) then
                return true
            end
        end
        return false
    end
    local function sendResponse(target, requestId, traceId, value, err)
        requestId = type(requestId) == 'string' and #requestId >= 1
            and #requestId <= (protocol.limits.requestId or 96)
            and requestId:match('^[A-Za-z0-9_.:%-]+$') and requestId or 'invalid'
        traceId = type(traceId) == 'string' and #traceId >= 8
            and #traceId <= (protocol.limits.traceId or 64)
            and traceId:match('^[A-Za-z0-9_.:%-]+$') and traceId or foundation.nextId('trace')
        local response = {
            wire = protocol.wire, requestId = requestId, traceId = traceId,
            ok = err == nil
        }
        if err == nil then
            response.value = value
        else
            response.error = {
                code = type(err.code) == 'string' and err.code:sub(1, 64) or 'INTERNAL_ERROR',
                message = type(err.message) == 'string' and err.message:sub(1, 512)
                    or 'The RPC request failed.',
                traceId = traceId,
                retryable = err.retryable == true
            }
        end
        local encodedOk, encoded = pcall(platform.jsonEncode, response)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > maximumTransportBytes then
            response = {
                wire = protocol.wire, requestId = requestId, traceId = traceId, ok = false,
                error = {
                    code = 'RESPONSE_TOO_LARGE',
                    message = 'RPC response exceeds the configured byte limit.',
                    traceId = traceId,
                    retryable = false
                }
            }
            local fallbackOk, fallback = pcall(platform.jsonEncode, response)
            if not fallbackOk or type(fallback) ~= 'string' or #fallback > maximumTransportBytes then
                logger:error('RPC response fallback could not be encoded safely', {
                    code = 'RESPONSE_TOO_LARGE', target = target, traceId = traceId
                })
                return nil
            end
        end
        platform.triggerClientEvent(protocol.events.response, target, response)
        return true
    end
    function network:bind()
        platform.onNet(protocol.events.request, function(envelope)
            local playerSource = source
            local session = players:getBySource(playerSource)
            local sourceGeneration = session and session.sourceGeneration or 'unauthenticated'
            local ingressBucketKey = session
                and ('rpc:%s:%s:ingress'):format(playerSource, sourceGeneration)
                or ('rpc-unauthenticated:%s:ingress'):format(playerSource)
            local ingressAllowed = security.rateLimiter:consume(
                ingressBucketKey, config.burst or 24, config.rate or 12, 1)
            if not ingressAllowed then return end
            local valid, envelopeError = security.validateNetworkEnvelope(
                envelope, maximumTimeoutMs)
            local plainEnvelope = type(envelope) == 'table' and getmetatable(envelope) == nil
            local traceId = plainEnvelope and rawget(envelope, 'traceId') or foundation.nextId('trace')
            local requestId = plainEnvelope and rawget(envelope, 'requestId') or 'invalid'
            if not valid then sendResponse(playerSource, requestId, traceId, nil, envelopeError) return end
            local payloadValid, payloadFailure = validTransportValue(envelope.payload)
            if not payloadValid then
                sendResponse(playerSource, requestId, traceId, nil, payloadFailure == 'bytes'
                    and foundation.error('PAYLOAD_TOO_LARGE',
                        'RPC payload exceeds the configured byte limit.')
                    or foundation.error('INVALID_PAYLOAD',
                        'RPC payload must be bounded plain JSON data.'))
                return
            end
            local encodedOk, encodedPayload = pcall(platform.jsonEncode, envelope.payload)
            if not encodedOk or type(encodedPayload) ~= 'string' then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('INVALID_PAYLOAD', 'RPC payload could not be encoded.'))
                return
            end
            if #encodedPayload > maximumTransportBytes then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('PAYLOAD_TOO_LARGE', 'RPC payload exceeds the configured byte limit.'))
                return
            end
            if not session then sendResponse(playerSource, requestId, traceId, nil, foundation.error('SESSION_REQUIRED', 'An active Synex session is required.')) return end
            local pendingKey = ('%s:%s:%s'):format(playerSource, session.sourceGeneration, envelope.requestId)
            if activeInbound[pendingKey] then sendResponse(playerSource, requestId, traceId, nil, foundation.error('DUPLICATE_REQUEST', 'The RPC request ID is already active.')) return end
            local sourceKey = ('%s:%s'):format(playerSource, session.sourceGeneration)
            if (activeInboundCounts[sourceKey] or 0) >= (config.maximumPendingPerSource or 16) then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('TOO_MANY_PENDING_REQUESTS', 'The source has too many active RPC requests.', { retryable = true }))
                return
            end
            local inboundEntry = {
                cancelled = false, sessionId = session.id,
                source = playerSource, generation = session.sourceGeneration
            }
            activeInbound[pendingKey] = inboundEntry
            activeInboundCounts[sourceKey] = (activeInboundCounts[sourceKey] or 0) + 1
            local inboundFinalized = false
            local function finalizeInbound()
                if inboundFinalized then return false end
                inboundFinalized = true
                if activeInbound[pendingKey] ~= inboundEntry then return false end
                activeInbound[pendingKey] = nil
                activeInboundCounts[sourceKey] = math.max(0,
                    (activeInboundCounts[sourceKey] or 1) - 1)
                if activeInboundCounts[sourceKey] == 0 then activeInboundCounts[sourceKey] = nil end
                return true
            end
            local function finishInbound(value, err)
                local owned = finalizeInbound()
                if not owned or inboundEntry.cancelled
                    or not players:isCurrent(session.id, playerSource, session.sourceGeneration) then
                    return false
                end
                sendResponse(playerSource, requestId, traceId, value, err)
                return true
            end
            local resolved, contract, contractError = foundation.safeCall(
                contracts.registry.resolve, contracts.registry,
                envelope.procedure, envelope.version)
            if not resolved then
                finishInbound(nil, foundation.error('INTERNAL_ERROR',
                    'The RPC contract could not be resolved safely.', {
                        traceId = traceId
                    }))
                return
            end
            if not contract then finishInbound(nil, contractError) return end
            if contract.network ~= 'client-to-server' then
                finishInbound(nil, foundation.error('NETWORK_ACCESS_DENIED',
                    'The contract is not client-callable.'))
                return
            end
            local contractBurst = contract.rateLimit and contract.rateLimit.capacity
                or config.burst or 24
            local contractRate = contract.rateLimit and contract.rateLimit.refillPerSecond
                or config.rate or 12
            local rateInvoked, allowed, rateError = foundation.safeCall(
                security.rateLimiter.consume, security.rateLimiter,
                ('rpc:%s:%s:%s@%s'):format(
                    playerSource, session.sourceGeneration, contract.name, contract.version),
                contractBurst, contractRate, 1)
            if not rateInvoked then
                finishInbound(nil, foundation.error('INTERNAL_ERROR',
                    'The RPC contract rate limit could not be evaluated safely.', {
                        traceId = traceId
                    }))
                return
            end
            if not allowed then finishInbound(nil, rateError) return end
            if not sessionStateAllowed(contract, session) then
                finishInbound(nil, foundation.error('INVALID_SESSION_STATE',
                    'The session state does not permit this operation.'))
                return
            end
            local permissionInvoked, permitted, permissionError = true, true, nil
            if contract.capability then
                permissionInvoked, permitted, permissionError = foundation.safeCall(
                    security.rbac.check, security.rbac,
                    'user:' .. tostring(session.userId), contract.capability,
                    session.deniedPermissions)
            end
            if activeInbound[pendingKey] ~= inboundEntry or inboundEntry.cancelled
                or not players:isCurrent(session.id, playerSource, session.sourceGeneration) then
                finalizeInbound()
                return
            end
            if not permissionInvoked then
                finishInbound(nil, foundation.error('INTERNAL_ERROR',
                    'The RPC permission could not be evaluated safely.', {
                        traceId = traceId
                    }))
                return
            end
            if not permitted then
                finishInbound(nil, permissionError
                    or foundation.error('PERMISSION_DENIED', 'The session is not permitted to perform this operation.'))
                return
            end
            -- Persistent RBAC checks may yield. Re-read every volatile session fact after
            -- the final yielding authorization step and use only that fresh snapshot.
            local currentSession = players:getBySource(playerSource)
            if type(currentSession) ~= 'table' or currentSession.id ~= session.id
                or currentSession.userId ~= session.userId
                or currentSession.source ~= playerSource
                or currentSession.sourceGeneration ~= session.sourceGeneration
                or not players:isCurrent(
                    currentSession.id, playerSource, currentSession.sourceGeneration) then
                finalizeInbound()
                return
            end
            if not sessionStateAllowed(contract, currentSession) then
                finishInbound(nil, foundation.error('INVALID_SESSION_STATE',
                    'The session state does not permit this operation.'))
                return
            end
            if sessionExplicitlyDenies(currentSession, contract.capability) then
                finishInbound(nil, foundation.error('PERMISSION_DENIED',
                    'The session is not permitted to perform this operation.'))
                return
            end
            session = currentSession
            local executionStartedAt = foundation.monotonicMs()
            local executionDeadlineAt = executionStartedAt
                + math.min(envelope.deadlineMs or defaultTimeoutMs, maximumTimeoutMs)
            if type(session.authorityDeadlineAt) == 'number' then
                executionDeadlineAt = math.min(
                    executionDeadlineAt, session.authorityDeadlineAt)
            end
            local invoked, value, invokeError = foundation.safeCall(function()
                return gateway:invoke(
                    deps.coreResource, owners:epoch(deps.coreResource), envelope.procedure,
                    envelope.version, envelope.payload, {
                        traceId = traceId, session = session, source = playerSource,
                        sourceGeneration = session.sourceGeneration,
                        deadlineAt = executionDeadlineAt,
                        idempotencyKey = envelope.idempotencyKey
                    })
            end)
            local owned = finalizeInbound()
            if not owned or inboundEntry.cancelled
                or not players:isCurrent(session.id, playerSource, session.sourceGeneration) then return end
            if not invoked then
                logger:error('RPC invocation failed unexpectedly', {
                    procedure = envelope.procedure, traceId = traceId,
                    code = 'RPC_INVOCATION_EXCEPTION'
                })
                value = nil
                invokeError = foundation.error('INTERNAL_ERROR',
                    'The RPC request failed internally.', { traceId = traceId })
            end
            sendResponse(playerSource, requestId, traceId, value, invokeError)
        end)
        platform.onNet(protocol.events.cancel, function(requestId)
            local playerSource = source
            local session = players:getBySource(playerSource)
            if not session or type(requestId) ~= 'string' or #requestId < 8
                or #requestId > (protocol.limits.requestId or 96)
                or not requestId:match('^[A-Za-z0-9_.:%-]+$') then return end
            local accepted = security.rateLimiter:consume(
                ('rpc-cancel:%s:%s:'):format(playerSource, session.sourceGeneration),
                config.burst or 24, config.rate or 12, 1)
            if not accepted then return end
            local pendingKey = ('%s:%s:%s'):format(playerSource, session.sourceGeneration, requestId)
            if activeInbound[pendingKey] then activeInbound[pendingKey].cancelled = true end
        end)
    end
    function network:purgeSource(playerSource, generation)
        if generation == nil then
            security.rateLimiter:purge(('rpc-unauthenticated:%s:'):format(playerSource))
            return
        end
        local prefix = ('%s:%s:'):format(playerSource, generation)
        for key, entry in pairs(activeInbound) do if key:sub(1, #prefix) == prefix then entry.cancelled = true; activeInbound[key] = nil end end
        for key, entry in pairs(pendingOutbound) do if key:sub(1, #prefix) == prefix then entry.cancelled = true; pendingOutbound[key] = nil end end
        security.rateLimiter:purge(
            ('rpc:%s:%s:'):format(playerSource, generation),
            ('rpc-unauthenticated:%s:'):format(playerSource))
        security.rateLimiter:purge(('rpc-cancel:%s:%s:'):format(playerSource, generation))
        activeInboundCounts[('%s:%s'):format(playerSource, generation)] = nil
    end
    function network:snapshot()
        local inbound, outbound, sources = 0, 0, 0
        for _ in pairs(activeInbound) do inbound = inbound + 1 end
        for _ in pairs(pendingOutbound) do outbound = outbound + 1 end
        for _ in pairs(activeInboundCounts) do sources = sources + 1 end
        return { activeInbound = inbound, pendingOutbound = outbound, activeSources = sources }
    end

    return {
        gateway = gateway,
        events = eventBus,
        hooks = hookRegistry,
        services = serviceRegistry,
        network = network,
        deprecations = { snapshot = deprecationSnapshot }
    }
end
