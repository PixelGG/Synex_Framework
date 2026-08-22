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

    local rpcHandlers = {}
    local subscriptions = {}
    local hooks = {}
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
                contract = entry.contract.name, provider = entry.owner, traceId = context.traceId, error = tostring(value)
            })
            return nil, foundation.error('INTERNAL_ERROR', 'The contract provider failed.', { traceId = context.traceId })
        end
        if handlerError ~= nil then
            if type(handlerError) ~= 'table' or type(handlerError.code) ~= 'string' then
                logger:error('contract handler returned an invalid error', { contract = entry.contract.name, provider = entry.owner, traceId = context.traceId })
                return nil, foundation.error('INTERNAL_ERROR', 'The contract provider returned an invalid error.', { traceId = context.traceId })
            end
            handlerError.traceId = context.traceId
            return nil, handlerError
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
        if type(handler) ~= 'function' then return nil, foundation.error('INVALID_HANDLER', 'A contract handler function is required.') end
        if contract.provider ~= owner then return nil, foundation.error('PROVIDER_MISMATCH', 'The contract provider does not match the resource owner.') end
        local registered, contractError = contracts.registry:register(contract)
        if not registered and contractError.code ~= 'CONTRACT_EXISTS' then return nil, contractError end
        local key = contract.name .. '@' .. contract.version
        if rpcHandlers[key] then return nil, foundation.error('HANDLER_EXISTS', 'A handler already provides this contract version.') end
        local token = foundation.nextId('rpc_handler')
        local entry = { owner = owner, epoch = epoch, token = token, contract = foundation.copy(contract), handler = handler }
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
        if not validEventReference(metadata.eventId, 8, 64)
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
            or not topic:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') or type(handler) ~= 'function' then
            return nil, foundation.error('INVALID_SUBSCRIPTION', 'Topic and handler are invalid.')
        end
        local token = foundation.nextId('subscription')
        local entry = {
            owner = owner, epoch = epoch, token = token, handler = handler,
            priority = math.floor((options and options.priority) or 0), sequence = nextSequence()
        }
        subscriptions[topic] = subscriptions[topic] or {}
        subscriptions[topic][token] = entry
        local _, trackError = track(owner, epoch, 'subscription', token, function()
            if subscriptions[topic] then subscriptions[topic][token] = nil end
        end)
        if trackError then subscriptions[topic][token] = nil return nil, trackError end
        return token, nil
    end
    local function publishEvent(owner, epoch, topic, payload, options)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The event publisher restarted.')
        end
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
        local encodedOk, encodedPayload = pcall(platform.jsonEncode, payload)
        if not encodedOk or type(encodedPayload) ~= 'string' then
            return nil, foundation.error('INVALID_EVENT', 'Domain event payload could not be encoded.')
        end
        if #encodedPayload > (config.maximumPayloadBytes or protocol.limits.payloadBytes or 32768) then
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
            if owners:isCurrent(entry.owner, entry.epoch) then
                local invocation = beginInvocation(owner, epoch, entry.owner, entry.epoch)
                local ok, err = false, nil
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
                        entry.handler, foundation.copy(payload), context)
                    finishInvocation(invocation)
                    if invocation.cancelled then
                        ok, err = false, invocation.reason
                    elseif not invoked then
                        ok, err = false, result
                    elseif handlerError ~= nil then
                        ok, err = false, handlerError
                    elseif result == false then
                        ok, err = false, 'subscriber rejected event'
                    else
                        ok = true
                    end
                else
                    err = 'subscriber owner is quiescing'
                end
                if ok then report.delivered = report.delivered + 1
                else
                    report.failed = report.failed + 1
                    logger:error('domain event subscriber failed', { topic = topic, subscriber = entry.owner, error = tostring(err) })
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
    function hookRegistry:register(owner, epoch, name, handler, options)
        if type(name) ~= 'string' or #name < 3 or #name > 128
            or not name:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') or type(handler) ~= 'function' then
            return nil, foundation.error('INVALID_HOOK', 'Hook names must be bounded namespaced identifiers and include a handler.')
        end
        options = options or {}
        local token = foundation.nextId('hook')
        local entry = {
            owner = owner, epoch = epoch, token = token, handler = handler,
            priority = math.floor(options.priority or 0), sequence = nextSequence(),
            required = options.required == true, timeoutMs = math.max(50, math.min(options.timeoutMs or 2000, 10000))
        }
        hooks[name] = hooks[name] or {}
        hooks[name][token] = entry
        local _, trackError = track(owner, epoch, 'hook', token, function()
            if hooks[name] then hooks[name][token] = nil end
        end)
        if trackError then hooks[name][token] = nil return nil, trackError end
        return token, nil
    end
    function hookRegistry:run(owner, epoch, name, value, context)
        if not owners:isCurrent(owner, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The hook caller restarted.') end
        local ordered = {}
        for _, entry in pairs(hooks[name] or {}) do ordered[#ordered + 1] = entry end
        table.sort(ordered, function(a, b)
            if a.priority == b.priority then return a.sequence < b.sequence end
            return a.priority > b.priority
        end)
        local candidate = foundation.copy(value)
        local suppliedContext = type(context) == 'table' and context or {}
        local hookContext = {
            caller = owner,
            callerEpoch = epoch,
            hook = name,
            traceId = type(suppliedContext.traceId) == 'string' and suppliedContext.traceId or foundation.nextId('trace'),
            deadlineAt = suppliedContext.deadlineAt,
            metadata = type(suppliedContext.metadata) == 'table' and foundation.copy(suppliedContext.metadata) or nil
        }
        for _, entry in ipairs(ordered) do
            if owners:isCurrent(entry.owner, entry.epoch) then
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
                if not ok or elapsed > entry.timeoutMs then
                    logger:error('hook failed', { hook = name, owner = entry.owner, elapsedMs = elapsed, error = tostring(result) })
                    if entry.required then return nil, foundation.error('REQUIRED_HOOK_FAILED', 'A required hook failed.', { retryable = true }) end
                elseif type(result) ~= 'table' or (result.action ~= 'allow' and result.action ~= 'deny' and result.action ~= 'patch') then
                    if entry.required then return nil, foundation.error('INVALID_HOOK_RESULT', 'A required hook returned an invalid result.') end
                elseif result.action == 'deny' then
                    return nil, foundation.error(result.code or 'HOOK_DENIED', result.message or 'The operation was denied by policy.')
                elseif result.action == 'patch' then
                    if type(result.value) ~= 'table' then return nil, foundation.error('INVALID_HOOK_PATCH', 'Hook patch must contain an object value.') end
                    candidate = foundation.copy(result.value)
                end
            end
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
            entry.owner, entry.name, entry.health, entry.circuit)
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
        if type(definition) ~= 'table' or type(definition.name) ~= 'string' or type(definition.version) ~= 'string' or type(definition.methods) ~= 'table' then
            return nil, foundation.error('INVALID_SERVICE', 'Service name, semantic version, and methods are required.')
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
        local key = serviceKey(definition.name, version.major)
        services[key] = services[key] or {}
        if services[key][owner] then return nil, foundation.error('SERVICE_PROVIDER_EXISTS', 'The resource already provides this service major.') end
        local methodCapabilities = {}
        for method, handler in pairs(definition.methods) do
            if type(method) ~= 'string' or #method < 1 or #method > 64
                or not method:match('^[a-z][a-zA-Z0-9_]*$') or type(handler) ~= 'function' then
                return nil, foundation.error('INVALID_SERVICE_METHOD', 'Service methods must map valid names to functions.')
            end
            local capability = type(definition.capabilities) == 'table' and definition.capabilities[method] or nil
            if capability ~= nil and not validCapabilityName(capability) then
                return nil, foundation.error('INVALID_SERVICE_CAPABILITY', 'Service method capabilities must be valid capability names.')
            end
            methodCapabilities[method] = capability
        end
        for method in pairs(type(definition.capabilities) == 'table' and definition.capabilities or {}) do
            if definition.methods[method] == nil then
                return nil, foundation.error('INVALID_SERVICE_CAPABILITY', 'Capability metadata references an unknown service method.')
            end
        end
        local token = foundation.nextId('service')
        local entry = {
            owner = owner, epoch = epoch, token = token, name = definition.name, version = definition.version,
            methods = definition.methods, methodCapabilities = methodCapabilities,
            priority = math.floor(definition.priority or 0),
            stability = stability,
            health = 'HEALTHY', failures = 0, circuit = 'CLOSED', openedAt = nil
        }
        services[key][owner] = entry
        deps.dependencies:provide(owner, definition.name, definition.version)
        local synchronized, synchronizationError = syncProviderHealth(entry)
        if not synchronized then
            services[key][owner] = nil
            deps.dependencies:removeProvider(owner, definition.name)
            return nil, synchronizationError
        end
        local _, trackError = track(owner, epoch, 'service', token, function()
            if services[key] and services[key][owner] == entry then services[key][owner] = nil end
            deps.dependencies:removeProvider(owner, definition.name)
        end)
        if trackError then
            services[key][owner] = nil
            deps.dependencies:removeProvider(owner, definition.name)
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
        if type(request) ~= 'table' then return nil, foundation.error('INVALID_ARGUMENT', 'Service requests must be objects.') end
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
        local suppliedContext = type(context) == 'table' and context or {}
        local serviceContext = {
            caller = caller,
            callerEpoch = callerEpoch,
            service = name,
            serviceVersion = provider.version,
            method = method,
            traceId = type(suppliedContext.traceId) == 'string' and suppliedContext.traceId or foundation.nextId('trace'),
            deadlineAt = suppliedContext.deadlineAt,
            idempotencyKey = suppliedContext.idempotencyKey,
            metadata = type(suppliedContext.metadata) == 'table' and foundation.copy(suppliedContext.metadata) or nil
        }
        serviceContext.provider = provider.owner
        local invocation, invocationStartError = beginInvocation(caller, callerEpoch, provider.owner, provider.epoch)
        if not invocation then return nil, invocationStartError end
        local ok, value, handlerError = foundation.safeCall(function(candidate, readonlyContext)
            return foundation.withContext(serviceContext, handler, candidate, readonlyContext)
        end, foundation.copy(request), foundation.readonly(serviceContext))
        finishInvocation(invocation)
        if invocation.cancelled then return nil, invocationError(invocation, serviceContext.traceId) end
        if not ok or handlerError then
            provider.failures = provider.failures + 1
            if provider.circuit == 'HALF_OPEN' or provider.failures >= 5 then
                provider.circuit = 'OPEN'
                provider.openedAt = foundation.monotonicMs()
            end
            syncProviderHealth(provider)
            logger:error('service provider failed', { service = name, method = method, provider = provider.owner, error = tostring(ok and handlerError or value) })
            return nil, type(handlerError) == 'table' and handlerError or foundation.error('SERVICE_FAILED', 'The service provider failed.', { retryable = true })
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
    local function sendResponse(target, requestId, traceId, value, err)
        local response = {
            wire = protocol.wire, requestId = requestId, traceId = traceId,
            ok = err == nil
        }
        if err == nil then
            response.value = value
        else
            response.error = {
                code = err.code,
                message = err.message,
                traceId = traceId,
                retryable = err.retryable == true
            }
        end
        platform.triggerClientEvent(protocol.events.response, target, response)
    end
    function network:bind()
        platform.onNet(protocol.events.request, function(envelope)
            local playerSource = source
            local valid, envelopeError = security.validateNetworkEnvelope(envelope)
            local traceId = type(envelope) == 'table' and envelope.traceId or foundation.nextId('trace')
            local requestId = type(envelope) == 'table' and envelope.requestId or 'invalid'
            if not valid then sendResponse(playerSource, requestId, traceId, nil, envelopeError) return end
            local encodedOk, encodedPayload = pcall(platform.jsonEncode, envelope.payload)
            if not encodedOk or type(encodedPayload) ~= 'string' then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('INVALID_PAYLOAD', 'RPC payload could not be encoded.'))
                return
            end
            if #encodedPayload > (config.maximumPayloadBytes or protocol.limits.payloadBytes or 32768) then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('PAYLOAD_TOO_LARGE', 'RPC payload exceeds the configured byte limit.'))
                return
            end
            local session = players:getBySource(playerSource)
            if not session then sendResponse(playerSource, requestId, traceId, nil, foundation.error('SESSION_REQUIRED', 'An active Synex session is required.')) return end
            local pendingKey = ('%s:%s:%s'):format(playerSource, session.sourceGeneration, envelope.requestId)
            if activeInbound[pendingKey] then sendResponse(playerSource, requestId, traceId, nil, foundation.error('DUPLICATE_REQUEST', 'The RPC request ID is already active.')) return end
            local sourceKey = ('%s:%s'):format(playerSource, session.sourceGeneration)
            if (activeInboundCounts[sourceKey] or 0) >= (config.maximumPendingPerSource or 16) then
                sendResponse(playerSource, requestId, traceId, nil, foundation.error('TOO_MANY_PENDING_REQUESTS', 'The source has too many active RPC requests.', { retryable = true }))
                return
            end
            local allowed, rateError = security.rateLimiter:consume(
                ('rpc:%s:%s:%s'):format(playerSource, session.sourceGeneration, envelope.procedure),
                config.burst or 24, config.rate or 12, 1)
            if not allowed then sendResponse(playerSource, requestId, traceId, nil, rateError) return end
            local contract, contractError = contracts.registry:resolve(envelope.procedure, envelope.version)
            if not contract then sendResponse(playerSource, requestId, traceId, nil, contractError) return end
            if contract.network ~= 'client-to-server' then sendResponse(playerSource, requestId, traceId, nil, foundation.error('NETWORK_ACCESS_DENIED', 'The contract is not client-callable.')) return end
            local stateAllowed = not contract.sessionStates or #contract.sessionStates == 0
            for _, candidate in ipairs(contract.sessionStates or {}) do if candidate == session.state then stateAllowed = true break end end
            if not stateAllowed then sendResponse(playerSource, requestId, traceId, nil, foundation.error('INVALID_SESSION_STATE', 'The session state does not permit this operation.')) return end
            local permitted, permissionError = true, nil
            if contract.capability then
                permitted, permissionError = security.rbac:check(
                    'user:' .. tostring(session.userId), contract.capability, session.deniedPermissions)
            end
            if not permitted then
                sendResponse(playerSource, requestId, traceId, nil, permissionError
                    or foundation.error('PERMISSION_DENIED', 'The session is not permitted to perform this operation.'))
                return
            end
            activeInbound[pendingKey] = { cancelled = false, sessionId = session.id, source = playerSource, generation = session.sourceGeneration }
            activeInboundCounts[sourceKey] = (activeInboundCounts[sourceKey] or 0) + 1
            local value, invokeError = gateway:invoke(deps.coreResource, owners:epoch(deps.coreResource), envelope.procedure, envelope.version,
                envelope.payload, {
                    traceId = traceId, session = session, source = playerSource,
                    sourceGeneration = session.sourceGeneration,
                    deadlineAt = foundation.monotonicMs() + (envelope.deadlineMs or config.timeoutMs or 5000),
                    idempotencyKey = envelope.idempotencyKey
                })
            local active = activeInbound[pendingKey]
            activeInbound[pendingKey] = nil
            activeInboundCounts[sourceKey] = math.max(0, (activeInboundCounts[sourceKey] or 1) - 1)
            if activeInboundCounts[sourceKey] == 0 then activeInboundCounts[sourceKey] = nil end
            if not active or active.cancelled or not players:isCurrent(session.id, playerSource, session.sourceGeneration) then return end
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
        local prefix = ('%s:%s:'):format(playerSource, generation)
        for key, entry in pairs(activeInbound) do if key:sub(1, #prefix) == prefix then entry.cancelled = true; activeInbound[key] = nil end end
        for key, entry in pairs(pendingOutbound) do if key:sub(1, #prefix) == prefix then entry.cancelled = true; pendingOutbound[key] = nil end end
        security.rateLimiter:purge(('rpc:%s:%s:'):format(playerSource, generation))
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
