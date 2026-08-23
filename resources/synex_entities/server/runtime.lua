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
    local serviceToken
    local participantToken
    local driftScheduleToken
    local rpcTokens = {}
    local application = {}

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

        local ok, tokenOrError, provideError = foundation.protect(
            'core.services.provide',
            function()
                return api.Services.provide({
                    methods = {
                        getHealth = function()
                            return service.healthSnapshot()
                        end,
                        getControlSummary = service.getControlSummary,
                    },
                    capabilities = {
                        getControlSummary = 'synex.entities.read',
                        getHealth = 'synex.entities.health',
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

        local handlers = service.handlers()
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

    local function validateCharacterId(value)
        return type(value) == 'string' and #value >= 1 and #value <= 36
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function registerCoreIntegrations()
        local api = coreRef.value
        if not api or not api.Characters
            or not foundation.isCallable(api.Characters.registerLifecycleParticipant) then
            return foundation.failure('UNAVAILABLE', 'The Core character lifecycle is unavailable', true)
        end
        local token, participantError = api.Characters.registerLifecycleParticipant({
            name = resourceName,
            priority = 60,
            required = true,
            prepare = function(context)
                local characterId = context and context.character and context.character.id
                if not validateCharacterId(characterId) then
                    return foundation.failure('INVALID_CHARACTER', 'Character lifecycle context is invalid', false)
                end
                return service.getCharacterLifecycleSummary(characterId, context)
            end,
            rollback = function() return true end,
            unload = function(context)
                local characterId = context and (
                    context.character and context.character.id
                    or context.session and context.session.characterId
                )
                if not validateCharacterId(characterId) then
                    return foundation.failure('INVALID_CHARACTER', 'Character unload context is invalid', false)
                end
                return service.unloadCharacter(characterId)
            end,
            deletePreflight = function(context)
                local characterId = context and context.character and context.character.id
                if not validateCharacterId(characterId) then
                    return foundation.failure('INVALID_CHARACTER', 'Character deletion context is invalid', false)
                end
                local summary, summaryError = service.getCharacterLifecycleSummary(characterId, context)
                if not summary then return nil, summaryError end
                local retainedOwner, retainedError = api.Ids.next('retained')
                if not retainedOwner then return nil, retainedError end
                return {
                    action = 'retain',
                    metadata = {
                        retainedOwner = retainedOwner,
                        persistent = summary.persistent,
                        temporary = summary.runtimeTemporary,
                    },
                }
            end,
            deleteCommit = function(context)
                local plan = context and context.plan
                if type(plan) ~= 'table' or not validateCharacterId(plan.characterId) then
                    return foundation.failure('INVALID_DELETE_PLAN', 'Character deletion plan is invalid', false)
                end
                local metadata
                for _, action in ipairs(plan.actions or {}) do
                    if action.owner == resourceName and action.action == 'retain' then
                        metadata = action.metadata
                        break
                    end
                end
                local retainedOwner = type(metadata) == 'table' and metadata.retainedOwner or nil
                if type(retainedOwner) ~= 'string' or #retainedOwner < 1 or #retainedOwner > 64
                    or retainedOwner:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
                    return foundation.failure('INVALID_DELETE_PLAN', 'Entity retention metadata is invalid', false)
                end
                return service.applyCharacterDeletion(plan.characterId, retainedOwner, context)
            end,
        })
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

        local rehydrated, rehydrateError = service.rehydratePersistentEntities()
        if not rehydrated then
            foundation.setHealth('UNHEALTHY', rehydrateError.message)
            return
        end
        local registered, registerError = registerService()
        if not registered then
            foundation.setHealth('UNHEALTHY', registerError.message)
            return
        end
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
        service.playerDropped(playerSource)
    end

    function application.resourceStarted(startedResource)
        if startedResource ~= coreResource then
            return
        end
        coreRef.value = nil
        serviceToken = nil
        participantToken = nil
        driftScheduleToken = nil
        health.service = 'UNREGISTERED'
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
            driftScheduleToken = nil
            rpcTokens = {}
            health.service = 'UNREGISTERED'
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
    end

    return application
end
