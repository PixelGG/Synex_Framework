SynexSecurityApplication = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')

function SynexSecurityApplication.create(options)
    options = options or {}
    local resourceName = assert(options.resourceName,
        'security application requires resource name')
    local coreResource = options.coreResource or 'synex_core'
    local coreRange = options.coreRange or '^1.0.0'
    local coreRef = assert(options.coreRef, 'security application requires Core reference')
    local service = assert(options.service, 'security application requires service')
    local controlProvider = assert(options.controlProvider,
        'security application requires control provider')
    local expectations = assert(options.expectations,
        'security application requires expectations')
    local acquireCore = assert(options.acquireCore,
        'security application requires Core acquisition')
    local loadResourceFile = options.loadResourceFile or LoadResourceFile
    local decode = assert(options.decode, 'security application requires JSON decoding')
    local getResourceState = options.getResourceState or GetResourceState
    local wait = options.wait or Wait
    local createThread = options.createThread or CreateThread
    local onCoreReady = Validation.isCallable(options.onCoreReady)
        and options.onCoreReady or function() return true end
    local onCoreUnavailable = Validation.isCallable(options.onCoreUnavailable)
        and options.onCoreUnavailable or function() return true end
    local onTick = Validation.isCallable(options.onTick)
        and options.onTick or function() return true end
    local onDomainEvent = Validation.isCallable(options.onDomainEvent)
        and options.onDomainEvent or function() return true end
    local topics = options.topics or {
        'synex.entities.bucket.changed',
        'synex.entities.created',
        'synex.entities.deleted',
        'synex.entities.dematerialized',
        'synex.entities.materialized',
        'synex.entities.owner.changed',
        'synex.world.portal.transitioned',
    }
    local ownerEpochs = options.ownerEpochs or {}
    local binding, generation, stopping = nil, 0, false
    local application = {}

    local function completeCore(api)
        return type(api) == 'table'
            and Validation.isInteger(api.ownerEpoch, 1, Limits.maximumSafeInteger)
            and type(api.Services) == 'table'
            and Validation.isCallable(api.Services.provide)
            and Validation.isCallable(api.Services.setHealth)
            and type(api.RPC) == 'table'
            and Validation.isCallable(api.RPC.registerServer)
            and Validation.isCallable(api.RPC.registerNetwork)
            and type(api.Scheduler) == 'table'
            and Validation.isCallable(api.Scheduler.every)
            and type(api.ControlProviders) == 'table'
            and Validation.isCallable(api.ControlProviders.register)
            and type(api.Ids) == 'table' and Validation.isCallable(api.Ids.next)
            and type(api.Players) == 'table'
            and Validation.isCallable(api.Players.getBySource)
            and type(api.Metrics) == 'table'
            and Validation.isCallable(api.Metrics.increment)
            and Validation.isCallable(api.Metrics.gauge)
            and Validation.isCallable(api.Metrics.observe)
            and type(api.Audit) == 'table' and Validation.isCallable(api.Audit.append)
            and type(api.Events) == 'table'
            and Validation.isCallable(api.Events.publish)
            and Validation.isCallable(api.Events.subscribe)
            and type(api.Database) == 'table'
            and Validation.isCallable(api.Database.null)
            and Validation.isCallable(api.Database.read)
            and Validation.isCallable(api.Database.write)
            and Validation.isCallable(api.Database.transaction)
            and Validation.isCallable(api.Database.maintenance)
            and type(api.Access) == 'table' and Validation.isCallable(api.Access.ban)
            and type(api.Diagnostics) == 'table'
            and Validation.isCallable(api.Diagnostics.getSecurityFindings)
    end

    local function current(candidate)
        return not stopping and type(candidate) == 'table'
            and binding == candidate and candidate.generation == generation
            and coreRef.value == candidate.api
    end

    local function plainJsonCopy(value)
        local seen, entries = {}, 0
        local function copy(candidate, depth)
            local kind = type(candidate)
            if candidate == nil or kind == 'boolean' or kind == 'string' then
                return candidate
            end
            if kind == 'number' then
                if not Validation.isFinite(candidate) then error('non-finite JSON number', 0) end
                return candidate
            end
            if kind ~= 'table' or depth > 24 or seen[candidate] then
                error('unsupported JSON container', 0)
            end
            local metadata = getmetatable(candidate)
            if metadata ~= nil then
                if type(metadata) ~= 'table'
                    or metadata.__jsontype ~= 'object'
                        and metadata.__jsontype ~= 'array' then
                    error('unsupported JSON metadata', 0)
                end
                for key in next, metadata do
                    if key ~= '__jsontype' then error('decorated JSON metadata', 0) end
                end
            end
            seen[candidate] = true
            local result = {}
            for key, child in next, candidate do
                entries = entries + 1
                if entries > 16384 or type(key) ~= 'string'
                    and not Validation.isInteger(key, 1, 16384) then
                    seen[candidate] = nil
                    error('JSON container bound exceeded', 0)
                end
                result[key] = copy(child, depth + 1)
            end
            seen[candidate] = nil
            return result
        end
        return copy(value, 1)
    end

    local function loadContracts()
        local raw = loadResourceFile(resourceName,
            'contracts/security.contracts.json')
        if not Validation.text(raw, 2, 262144) then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'The security contract bundle is unavailable.')
        end
        local decoded, bundle = pcall(decode, raw)
        if not decoded then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'The security contract bundle is invalid.')
        end
        local copied, plain = pcall(plainJsonCopy, bundle)
        if not copied or type(plain) ~= 'table' or plain.schema ~= 1
            or plain.domain ~= 'synex.security'
            or type(plain.contracts) ~= 'table' or #plain.contracts ~= 8 then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'The security contract bundle is invalid.')
        end
        return plain.contracts, nil
    end

    local function registerContracts(candidate)
        local definitions, definitionError = loadContracts()
        if not definitions then return nil, definitionError end
        candidate.contractTokens = candidate.contractTokens or {}
        for _, definition in ipairs(definitions) do
            local key = definition.name .. '@' .. definition.version
            if candidate.contractTokens[key] == nil then
                local handler, handlerError = service.contractHandler(definition)
                if not handler then return nil, handlerError end
                local register = definition.network == 'client-to-server'
                    and candidate.api.RPC.registerNetwork
                    or candidate.api.RPC.registerServer
                local token, tokenError = register(definition, handler)
                if not token then return nil, tokenError end
                candidate.contractTokens[key] = token
            end
        end
        return true, nil
    end

    local function registerSubscriptions(candidate)
        candidate.subscriptionTokens = candidate.subscriptionTokens or {}
        for _, topic in ipairs(topics) do
            if candidate.subscriptionTokens[topic] == nil then
                local token, subscriptionError = candidate.api.Events.subscribe(
                    topic, function(payload, context)
                        local value, operationError = Foundation.protect(
                            onDomainEvent, topic, payload, context)
                        if value == nil then return nil, Foundation.publicError(operationError) end
                        return value
                    end, { priority = -50 })
                if not token then return nil, subscriptionError end
                candidate.subscriptionTokens[topic] = token
            end
        end
        return true, nil
    end

    local function registerWorker(candidate)
        if candidate.workerToken ~= nil then return true end
        local token, workerError = candidate.api.Scheduler.every(1000, function()
            if not current(candidate) or candidate.ready ~= true then return true end
            local value, operationError = Foundation.protect(onTick, candidate.api)
            if value == nil then
                candidate.api.Services.setHealth(
                    'synex.security', '1.0.0', 'DEGRADED')
                return nil, Foundation.publicError(operationError)
            end
            return value
        end, { name = 'synex_security.runtime' })
        if not token then return nil, workerError end
        candidate.workerToken = token
        return true, nil
    end

    local function bind(api, expectedGeneration)
        if stopping or generation ~= expectedGeneration or not completeCore(api) then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'Synex Core returned an incomplete Security API.', true)
        end
        local candidate = binding
        if type(candidate) ~= 'table' or candidate.api ~= api
            or candidate.generation ~= expectedGeneration then
            candidate = {
                api = api,
                generation = expectedGeneration,
                ready = false,
                contractTokens = {},
                subscriptionTokens = {},
            }
            binding = candidate
        end
        coreRef.value = api
        ownerEpochs[resourceName] = api.ownerEpoch
        if candidate.ready then return true, nil end
        if candidate.serviceToken == nil then
            local serviceToken, serviceError = api.Services.provide(
                service.serviceDefinition())
            if not serviceToken then return nil, serviceError end
            candidate.serviceToken = serviceToken
        end
        local unhealthy, healthError = api.Services.setHealth(
            'synex.security', '1.0.0', 'UNHEALTHY')
        if not unhealthy then return nil, healthError end
        local contractsReady, contractsError = registerContracts(candidate)
        if not contractsReady then return nil, contractsError end
        if candidate.providerToken == nil then
            local providerToken, providerError = controlProvider.register(api)
            if not providerToken then return nil, providerError end
            candidate.providerToken = providerToken
        end
        local subscriptionsReady, subscriptionError = registerSubscriptions(candidate)
        if not subscriptionsReady then return nil, subscriptionError end
        local workerReady, workerError = registerWorker(candidate)
        if not workerReady then return nil, workerError end
        if candidate.initialized ~= true then
            local initialized, initializationError = Foundation.protect(onCoreReady, api)
            if initialized == nil or initialized == false then
                return nil, initializationError or {
                    code = 'SECURITY_UNAVAILABLE',
                    message = 'Security runtime initialization failed.',
                    retryable = true,
                }
            end
            candidate.initialized = true
        end
        candidate.ready = true
        local healthy, readyError = api.Services.setHealth(
            'synex.security', '1.0.0', 'HEALTHY')
        if not healthy then candidate.ready = false; return nil, readyError end
        return true, nil
    end

    local function beginBinding()
        generation = generation + 1
        local expectedGeneration = generation
        binding, coreRef.value = nil, nil
        createThread(function()
            local attempts = 0
            while not stopping and generation == expectedGeneration do
                local acquired, api, acquireError = pcall(acquireCore, coreRange)
                local bound, bindError
                if acquired and completeCore(api) then
                    bound, bindError = Foundation.protect(
                        bind, api, expectedGeneration)
                    if bound then return end
                else
                    bindError = acquireError or api
                end
                attempts = attempts + 1
                if type(bindError) == 'table' and bindError.retryable == false then
                    print(('[%s] Security bootstrap failed: %s'):format(
                        resourceName, tostring(bindError.code or 'SECURITY_UNAVAILABLE')))
                    return
                end
                wait(attempts < 40 and 250 or 5000)
            end
        end)
    end

    function application.activateOwner(owner, epoch)
        if not Validation.resourceName(owner)
            or not Validation.isInteger(epoch, 1, Limits.maximumSafeInteger)
            or getResourceState(owner) ~= 'started'
                and getResourceState(owner) ~= 'starting' then
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security owner is not active.', true)
        end
        local previous = ownerEpochs[owner]
        if previous ~= nil and previous > epoch then
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security owner epoch is stale.', true)
        end
        if previous ~= nil and previous < epoch then
            expectations.revokeOwner(owner, previous)
        end
        ownerEpochs[owner] = epoch
        return expectations.activateOwner(owner, epoch)
    end

    function application.ownerCurrent(owner, epoch)
        local state = getResourceState(owner)
        return ownerEpochs[owner] == epoch
            and (state == 'started' or state == 'starting')
    end

    function application.ready()
        return current(binding) and binding.ready == true
    end

    function application.start()
        stopping = false
        beginBinding()
        return true
    end

    function application.resourceStarted(startedResource)
        if startedResource == coreResource then beginBinding() end
    end

    function application.resourceStopped(stoppedResource)
        if stoppedResource == resourceName then
            stopping = true
            generation = generation + 1
            binding, coreRef.value = nil, nil
            return true
        end
        if stoppedResource == coreResource then
            generation = generation + 1
            binding, coreRef.value = nil, nil
            Foundation.protect(onCoreUnavailable)
            return true
        end
        local epoch = ownerEpochs[stoppedResource]
        if epoch ~= nil then
            expectations.revokeOwner(stoppedResource, epoch)
            ownerEpochs[stoppedResource] = nil
        end
        return true
    end

    application.completeCore = completeCore
    return application
end
