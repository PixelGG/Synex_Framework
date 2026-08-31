SynexEntityApplication = {}

function SynexEntityApplication.create(options)
    assert(type(options) == 'table', 'entity application options are required')
    local resourceName = assert(options.resourceName, 'entity application resourceName is required')
    local coreResource = assert(options.coreResource, 'entity application coreResource is required')
    local coreRange = assert(options.coreRange, 'entity application coreRange is required')
    local serviceName = assert(options.serviceName, 'entity application serviceName is required')
    local serviceVersion = assert(options.serviceVersion, 'entity application serviceVersion is required')
    local foundation = assert(options.foundation, 'entity application foundation is required')
    local service = assert(options.service, 'entity application service is required')
    local coreRef = assert(options.coreRef, 'entity application coreRef is required')
    local ports = assert(options.ports, 'entity application ports are required')
    local health = assert(options.health, 'entity application health is required')
    local config = assert(options.config, 'entity application config is required')
    local lifecyclePolicy = assert(options.lifecyclePolicy,
        'entity application lifecycle policy is required')
    local controlProvider = assert(options.controlProvider,
        'entity application control provider is required')
    local serviceToken
    local participantToken
    local deletionProviderToken
    local bucketExpiryScheduleToken
    local driftScheduleToken
    local heartbeatScheduleToken
    local recoveryScheduleToken
    local rpcTokens = {}
    local application = {}

    local function registerControlProvider()
        local api = coreRef.value
        if type(api) ~= 'table' then
            health.controlProvider = 'UNAVAILABLE'
            return nil, { code = 'UNAVAILABLE', message = 'The Core API is unavailable', retryable = true }
        end
        local registered, metadata, registrationError = foundation.protect(
            'core.control_provider.register',
            function() return controlProvider.register(api) end
        )
        if not registered or not metadata then
            health.controlProvider = 'UNAVAILABLE'
            return nil, type(registrationError) == 'table' and registrationError
                or { code = 'UNAVAILABLE', message = 'The entity control provider is unavailable', retryable = true }
        end
        health.controlProvider = 'REGISTERED'
        return metadata
    end

    local function acquireCoreApi()
        if ports.getResourceState(coreResource) ~= 'started' then
            return foundation.failure('UNAVAILABLE', 'synex_core is not started', true)
        end

        local ok, apiOrError = foundation.protect(
            'core.get_api',
            function() return ports.getCoreApi(coreRange) end
        )
        if not ok or type(apiOrError) ~= 'table' then
            return foundation.failure('UNAVAILABLE', 'The Synex Core API is unavailable', true)
        end
        coreRef.value = apiOrError
        return apiOrError
    end

    local function registerService()
        local api = coreRef.value
        if not api then
            local _, apiError = acquireCoreApi()
            if apiError then
                return nil, apiError
            end
            api = coreRef.value
        end
        if type(api.Services) ~= 'table' or not foundation.isCallable(api.Services.provide) then
            return foundation.failure('UNAVAILABLE', 'The Core service registry is unavailable', true)
        end
        local function publicMethod(handler)
            return function(request, context)
                local value, operationError = handler(request, context)
                if value == nil and operationError ~= nil then
                    return nil, SynexEntityPublicErrors.sanitize(operationError)
                end
                return value
            end
        end

        local ok, tokenOrError, provideError = foundation.protect(
            'core.services.provide',
            function()
                return api.Services.provide({
                    methods = {
                        getHealth = function()
                            return service.healthSnapshot()
                        end,
                        getPlayerBucketFence = publicMethod(service.getPlayerBucketFence),
                        getControlSummary = publicMethod(service.getControlSummary),
                        getDiagnosticSnapshot = publicMethod(service.getDiagnosticSnapshot),
                        inspectEntity = publicMethod(service.inspectEntity),
                        queryByBucket = publicMethod(service.queryByBucket),
                        queryByOwner = publicMethod(service.queryByOwner),
                        queryByResource = publicMethod(service.queryByResource),
                    },
                    capabilities = {
                        getControlSummary = 'synex.entities.read',
                        getDiagnosticSnapshot = 'synex.entities.read',
                        getHealth = 'synex.entities.health',
                        getPlayerBucketFence = 'synex.entities.query',
                        inspectEntity = 'synex.entities.read',
                        queryByBucket = 'synex.entities.query',
                        queryByOwner = 'synex.entities.query',
                        queryByResource = 'synex.entities.query',
                    },
                    name = serviceName,
                    version = serviceVersion,
                })
            end
        )
        if not ok or tokenOrError == nil then
            return nil, type(provideError) == 'table' and provideError
                or { code = 'UNAVAILABLE', message = 'The entity service could not be registered', retryable = true }
        end
        serviceToken = tokenOrError

        if type(api.RPC) ~= 'table' or not foundation.isCallable(api.RPC.registerServer) then
            return foundation.failure('UNAVAILABLE', 'The Core contract registry is unavailable', true)
        end
        local encoded = ports.loadResourceFile(resourceName, 'contracts/entities.contracts.json')
        if type(encoded) ~= 'string' or encoded == '' then
            return foundation.failure(
                'UNAVAILABLE',
                'The entity contract collection could not be loaded',
                false
            )
        end
        local decodedOk, collection = foundation.protect(
            'contracts.decode',
            function() return ports.jsonDecode(encoded) end
        )
        if not decodedOk or type(collection) ~= 'table' or type(collection.contracts) ~= 'table' then
            return foundation.failure(
                'UNAVAILABLE',
                'The entity contract collection is invalid JSON',
                false
            )
        end

        local handlers = service.handlers(collection.contracts)
        rpcTokens = {}
        for _, definition in ipairs(collection.contracts) do
            local handler = handlers[definition.name]
            if not handler then
                return foundation.failure(
                    'UNAVAILABLE',
                    'An entity contract has no runtime handler',
                    false
                )
            end
            local registeredOk, tokenOrNil, registrationError = foundation.protect(
                'core.rpc.register',
                function() return api.RPC.registerServer(definition, handler) end
            )
            if not registeredOk or not tokenOrNil then
                return nil, type(registrationError) == 'table' and registrationError
                    or { code = 'UNAVAILABLE', message = 'An entity contract could not be registered', retryable = true }
            end
            rpcTokens[#rpcTokens + 1] = tokenOrNil
        end
        health.service = 'REGISTERED'
        return true
    end

    local function registerCoreIntegrations()
        local api = coreRef.value
        if not api or not api.Characters
            or not foundation.isCallable(api.Characters.registerLifecycleParticipant) then
            return foundation.failure('UNAVAILABLE', 'The Core character lifecycle is unavailable', true)
        end
        if not api.DomainDeletions
            or not foundation.isCallable(api.DomainDeletions.registerProvider) then
            return foundation.failure('UNAVAILABLE',
                'The Core domain deletion coordinator is unavailable', true)
        end
        local providerToken, providerError = api.DomainDeletions.registerProvider(
            lifecyclePolicy.groupDeletionProvider()
        )
        if not providerToken then return nil, providerError end
        deletionProviderToken = providerToken

        local token, participantError = api.Characters.registerLifecycleParticipant(
            lifecyclePolicy.characterParticipant()
        )
        if not token then return nil, participantError end
        participantToken = token

        if not api.Scheduler or not foundation.isCallable(api.Scheduler.every) then
            return foundation.failure('UNAVAILABLE', 'The Core scheduler is unavailable', true)
        end
        local scheduleToken, scheduleError = api.Scheduler.every(
            config.driftIntervalMs,
            function()
                local _, driftError = service.runDriftDetection()
                if driftError then
                    foundation.setHealth('DEGRADED', driftError.message)
                end
            end,
            { name = 'synex_entities.drift_detector' }
        )
        if not scheduleToken then return nil, scheduleError end
        driftScheduleToken = scheduleToken

        local heartbeatToken, heartbeatError = api.Scheduler.every(
            math.max(1000, math.floor(config.authorityLeaseSeconds * 1000 / 3)),
            function()
                local _, renewError = service.heartbeatAuthority({
                    caller = resourceName,
                    callerEpoch = api.ownerEpoch,
                    traceId = 'entity_heartbeat',
                })
                if renewError then
                    foundation.setHealth('DEGRADED', 'CLUSTER_LEASE_CONFLICT')
                end
            end,
            { name = 'synex_entities.authority_heartbeat' }
        )
        if not heartbeatToken then return nil, heartbeatError end
        heartbeatScheduleToken = heartbeatToken

        local recoveryToken, recoveryError = api.Scheduler.every(
            config.recoveryIntervalMs,
            function()
                local _, workerError = service.runRecovery({
                    caller = resourceName,
                    callerEpoch = api.ownerEpoch,
                    traceId = 'entity_recovery',
                })
                if workerError then
                    foundation.setHealth('DEGRADED', workerError.code or 'RECOVERY_FAILED')
                end
            end,
            { name = 'synex_entities.recovery' }
        )
        if not recoveryToken then return nil, recoveryError end
        recoveryScheduleToken = recoveryToken

        local expiryToken, expiryError = api.Scheduler.every(
            config.bucketExpiryIntervalMs,
            function()
                local _, workerError = service.expireBuckets({
                    caller = resourceName,
                    callerEpoch = api.ownerEpoch,
                    traceId = 'entity_bucket_expiry',
                })
                if workerError then
                    foundation.setHealth('DEGRADED',
                        workerError.code or 'BUCKET_EXPIRY_FAILED')
                end
            end,
            { name = 'synex_entities.bucket_expiry' }
        )
        if not expiryToken then return nil, expiryError end
        bucketExpiryScheduleToken = expiryToken
        return true
    end

    function application.start()
        if health.onesync ~= 'on' then
            foundation.setHealth('UNHEALTHY', "OneSync must be configured as 'on'")
            return
        end

        local api, apiError = acquireCoreApi()
        local attempts = 0
        while not api and attempts < 20 do
            attempts = attempts + 1
            ports.wait(250)
            api, apiError = acquireCoreApi()
        end
        if not api then
            foundation.setHealth('UNHEALTHY', apiError.message)
            return
        end

        local initialized, initializationError = service.initializeAuthority({
            caller = resourceName,
            callerEpoch = api.ownerEpoch,
            traceId = 'entity_bootstrap',
        })
        if not initialized then
            foundation.setHealth('UNHEALTHY', initializationError.message)
            return
        end
        local registered, registerError = registerService()
        if not registered then
            foundation.setHealth('UNHEALTHY', registerError.message)
            return
        end
        registerControlProvider()
        local integrated, integrationError = registerCoreIntegrations()
        if not integrated then
            foundation.setHealth('UNHEALTHY', integrationError.message)
            return
        end
        local _, driftError = service.runDriftDetection()
        if driftError then
            foundation.setHealth('DEGRADED', driftError.message)
        end
        if health.state == 'STARTING' then
            foundation.setHealth('READY', 'Entity foundation is ready')
        end
    end

    function application.playerDropped(playerSource)
        ports.createThread(function()
            ports.wait(0)
            service.playerDropped(playerSource)
        end)
    end

    function application.resourceStarted(startedResource)
        if startedResource ~= coreResource then
            return
        end
        coreRef.value = nil
        serviceToken = nil
        participantToken = nil
        deletionProviderToken = nil
        bucketExpiryScheduleToken = nil
        driftScheduleToken = nil
        heartbeatScheduleToken = nil
        recoveryScheduleToken = nil
        health.service = 'UNREGISTERED'
        health.controlProvider = 'UNREGISTERED'
        ports.createThread(function()
            local completed = foundation.protect('core.restart_registration', function()
                ports.wait(0)
                local _, apiError = acquireCoreApi()
                if apiError then
                    foundation.setHealth('DEGRADED', apiError.message)
                    return
                end
                local registered, registerError = registerService()
                if not registered then
                    foundation.setHealth('DEGRADED', registerError.message)
                    return
                end
                registerControlProvider()
                local initialized, initializationError = service.initializeAuthority({
                    caller = resourceName,
                    callerEpoch = coreRef.value.ownerEpoch,
                    traceId = 'entity_rebind',
                })
                if not initialized then
                    foundation.setHealth('DEGRADED', initializationError.message)
                    return
                end
                local integrated, integrationError = registerCoreIntegrations()
                if not integrated then
                    foundation.setHealth('DEGRADED', integrationError.message)
                    return
                end
                if health.persistence == 'READY' then
                    foundation.setHealth('READY', 'Entity foundation is ready')
                end
            end)
            if not completed then
                foundation.setHealth('DEGRADED', 'Core restart registration failed unexpectedly')
            end
        end)
    end

    function application.resourceStopped(stoppedResource)
        local stoppedCycle, mutationInFlight = foundation.advanceOwnerCycle(stoppedResource)

        if stoppedResource == coreResource then
            coreRef.value = nil
            serviceToken = nil
            participantToken = nil
            deletionProviderToken = nil
            bucketExpiryScheduleToken = nil
            driftScheduleToken = nil
            heartbeatScheduleToken = nil
            recoveryScheduleToken = nil
            rpcTokens = {}
            health.service = 'UNREGISTERED'
            health.controlProvider = 'UNREGISTERED'
            foundation.setHealth('DEGRADED', 'synex_core stopped')
        end

        if stoppedResource == resourceName then
            foundation.setHealth('STOPPING', 'Resource stop requested')
            service.stop()
            return
        end

        if not mutationInFlight then
            local cleaned = foundation.protect(
                'owner.cleanup_on_stop',
                function() return service.cleanupOwner(stoppedResource, stoppedCycle) end
            )
            if not cleaned then
                foundation.setHealth('DEGRADED', 'A stopped resource could not be cleaned up')
            end
        end
        service.cleanupExtensions(stoppedResource)
    end

    function application.entityRemoved(entityHandle)
        local completed = foundation.protect('runtime.entity_removed', function()
            return service.entityRemoved(entityHandle, {
                caller = resourceName,
                callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
                traceId = 'entity_removed',
            })
        end)
        if not completed then
            foundation.setHealth('DEGRADED', 'ENTITY_REMOVAL_RECONCILIATION_FAILED')
        end
    end

    function application.entityBucketChanged(entityHandle, bucketId, oldBucketId)
        service.entityBucketChanged(entityHandle, bucketId, oldBucketId)
    end

    function application.playerBucketChanged(playerSource, bucketId, oldBucketId)
        service.playerBucketChanged(playerSource, bucketId, oldBucketId)
    end

    return application
end
