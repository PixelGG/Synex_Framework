local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapApiTracing = function(deps)
    local platform = assert(deps.platform, 'bootstrap API tracing requires platform')
    local foundation = assert(deps.foundation, 'bootstrap API tracing requires foundation')
    local registries = assert(deps.registries, 'bootstrap API tracing requires registries')
    local security = assert(deps.security, 'bootstrap API tracing requires security')
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap API tracing requires runtime gate')
    local ownerOperation = assert(deps.ownerOperation,
        'bootstrap API tracing requires owner operation boundary')
    local caller = assert(deps.caller, 'bootstrap API tracing requires caller')
    local epoch = assert(deps.epoch, 'bootstrap API tracing requires owner epoch')
    local coreResource = assert(deps.coreResource,
        'bootstrap API tracing requires core resource')

    local ownerByProvider = {
        qb = 'synex_bridge_qb',
        qbx = 'synex_bridge_qbx',
        esx = 'synex_bridge_esx'
    }
    local providerApis = {
        GetCoreObject = true,
        getSharedObject = true,
        GetPlayer = true,
        GetMoney = true,
        GetGroups = true,
        AddMoney = true,
        RemoveMoney = true,
        SetMoney = true,
        SetJob = true,
        SetGang = true,
        SetJobDuty = true,
        SetMetadata = true,
        RegisterCallback = true,
        TriggerCallback = true,
        GetCompatibilityUsage = true
    }
    local coordinatorApis = {
        InvokeAdapter = true,
        ResolveCatalog = true,
        InvokeCatalog = true
    }
    local secretFragments = {
        'password', 'passphrase', 'secret', 'credential', 'webhook',
        'privatekey', 'apikey', 'accesstoken', 'refreshtoken', 'license'
    }

    local function validTraceId(value)
        if type(value) ~= 'string' or #value < 8 or #value > 64
            or value:find('[%z\1-\31\127]')
            or not value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
            return false
        end
        local normalized = value:lower()
        for _, fragment in ipairs(secretFragments) do
            if normalized:find(fragment, 1, true) then return false end
        end
        return true
    end

    local function validContext(context)
        if type(context) ~= 'table' or getmetatable(context) ~= nil then return false end
        for key in pairs(context) do
            if key ~= 'operation' and key ~= 'traceId'
                and key ~= 'compatProvider' and key ~= 'consumer'
                and key ~= 'legacyApi' then return false end
        end
        local provider = context.compatProvider
        local consumer = context.consumer
        local legacyApi = context.legacyApi
        local operation = context.operation
        return ownerByProvider[provider] ~= nil
            and validTraceId(context.traceId)
            and type(consumer) == 'string' and #consumer >= 1 and #consumer <= 64
            and consumer ~= caller and consumer ~= coreResource
            and consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
            and type(legacyApi) == 'string' and #legacyApi >= 1 and #legacyApi <= 64
            and legacyApi:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
            and (providerApis[legacyApi] == true or coordinatorApis[legacyApi] == true)
            and type(operation) == 'string' and #operation <= 128
            and operation == ('compat.%s.%s'):format(provider, legacyApi)
    end

    local function callerOwnsOperation(context)
        if caller == 'synex_bridge' then
            return coordinatorApis[context.legacyApi] == true
        end
        return ownerByProvider[context.compatProvider] == caller
            and providerApis[context.legacyApi] == true
    end

    return {
        run = function(context, handler)
            if not validContext(context) or not foundation.isCallable(handler) then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Compatibility trace context or handler is invalid.')
            end
            if not callerOwnsOperation(context) then
                return nil, foundation.error('CAPABILITY_DENIED',
                    'The resource cannot write this compatibility trace.')
            end
            local available, availabilityError = runtimeGate:requireAvailable()
            if not available then return nil, availabilityError end
            if not registries.owners:isCurrent(caller, epoch) then
                return nil, foundation.error('STALE_RESOURCE',
                    'The calling resource restarted.')
            end
            local allowed, capabilityError = security.capabilities:check(
                caller, 'synex.tracing.write', {
                    traceId = context.traceId,
                    operation = context.operation
                })
            if not allowed then return nil, capabilityError end
            local state = platform.resourceState(context.consumer)
            if state ~= 'started' and state ~= 'starting' then
                return nil, foundation.error('CALLER_INVALID',
                    'The compatibility consumer is not active.')
            end
            return ownerOperation(caller, epoch, context.operation, handler,
                context.traceId, {
                    compatProvider = context.compatProvider,
                    consumer = context.consumer,
                    legacyApi = context.legacyApi
                })
        end
    }
end
