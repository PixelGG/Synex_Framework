SynexGroupsRegisterRuntime = function(options)
    local Foundation = assert(options.Foundation,
        'Groups runtime registration requires Foundation')
    local CoreBootstrap = assert(options.CoreBootstrap,
        'Groups runtime registration requires CoreBootstrap')
    local extensionRegistries = assert(options.extensionRegistries,
        'Groups runtime registration requires extension registries')
    local groupDeletions = assert(options.groupDeletions,
        'Groups runtime registration requires group deletions')
    local characterLifecycleParticipant = assert(options.characterLifecycleParticipant,
        'Groups runtime registration requires a character participant')
    local rebuildRuntimeCharacters = assert(options.rebuildRuntimeCharacters,
        'Groups runtime registration requires a runtime rebuild')
    local serviceDefinition = assert(options.serviceDefinition,
        'Groups runtime registration requires a service definition')
    local definitions = assert(options.definitions,
        'Groups runtime registration requires contract definitions')
    local methods = assert(options.methods,
        'Groups runtime registration requires service methods')
    local operationName = assert(options.operationName,
        'Groups runtime registration requires operation names')
    local scheduleWorkers = assert(options.scheduleWorkers,
        'Groups runtime registration requires worker scheduling')
    local outboxDispatcher = assert(options.outboxDispatcher,
        'Groups runtime registration requires an outbox dispatcher')
    local database = assert(options.database,
        'Groups runtime registration requires persistence')
    local runtimeIndex = assert(options.runtimeIndex,
        'Groups runtime registration requires a runtime index')
    local loadRuntimeCharacter = assert(options.loadRuntimeCharacter,
        'Groups runtime registration requires a character loader')
    local groupCreationApprovals = assert(options.groupCreationApprovals,
        'Groups runtime registration requires creation approvals')
    local acquireCoreApi = assert(options.acquireCoreApi,
        'Groups runtime registration requires Core acquisition')
    local setCurrentApi = assert(options.setCurrentApi,
        'Groups runtime registration requires an API writer')
    local controlProvider = assert(options.controlProvider,
        'Groups runtime registration requires the Control provider')
    local runtimeErrorSink = assert(options.runtimeErrorSink,
        'Groups runtime registration requires an error sink')
    local cache = assert(options.cache,
        'Groups runtime registration requires the cache')
    local observedExtensionOwnerEpochs = assert(options.observedExtensionOwnerEpochs,
        'Groups runtime registration requires observed owner epochs')
    local stoppedExtensionOwnerEpochHighWater = assert(
        options.stoppedExtensionOwnerEpochHighWater,
        'Groups runtime registration requires stopped owner epochs')
    local isExtensionOwnerRunning = assert(options.isExtensionOwnerRunning,
        'Groups runtime registration requires owner state inspection')

    local coreRebindGeneration = 1
    local coreRegistration
    coreRegistration = CoreBootstrap.createRegistration({
        serviceName = 'synex.groups', serviceVersion = Foundation.API_VERSION,
        isGenerationCurrent = function(generation)
            return generation == coreRebindGeneration
        end,
        prepare = function() return extensionRegistries:hydrate() end,
        deletionProvider = function(binding)
            local provider = groupDeletions:provider()
            provider.preflight = coreRegistration:guard(binding, provider.preflight)
            provider.execute = coreRegistration:guard(binding, provider.execute)
            return provider
        end,
        characterParticipant = function(binding)
            return characterLifecycleParticipant(binding, coreRegistration)
        end,
        rebuild = rebuildRuntimeCharacters,
        serviceDefinition = function(binding)
            return serviceDefinition(binding, coreRegistration)
        end,
        contracts = definitions,
        contractHandler = function(definition, binding)
            return coreRegistration:guard(
                binding, methods[operationName(definition.name)], 'DATABASE_ERROR')
        end,
        scheduleWorkers = function(api, binding, tokens, pendingCancellations)
            return scheduleWorkers(api, {
                outboxDispatcher = outboxDispatcher, database = database,
                runtimeIndex = runtimeIndex, loadRuntimeCharacter = loadRuntimeCharacter,
                groupCreationApprovals = groupCreationApprovals,
                groupDeletions = groupDeletions
            }, {
                tokens = tokens,
                pendingCancellations = pendingCancellations,
                isCurrent = function() return coreRegistration:isCurrent(binding) end,
                isReady = function() return coreRegistration:isReady(binding) end
            })
        end
    })

    local function startCoreBinding(generation, operation)
        CoreBootstrap.runWhenReady({
            acquire = acquireCoreApi,
            schedule = SetTimeout,
            isCurrent = function() return generation == coreRebindGeneration end,
            onReady = function(api)
                if generation ~= coreRebindGeneration then
                    return nil, Foundation.domainError('STALE_RESOURCE',
                        'The Groups Core binding generation is stale.', true)
                end
                setCurrentApi(api)
                local bound, bindingError = coreRegistration:bind(api, generation)
                if not bound then return nil, bindingError end
                local _, providerError = controlProvider:register(api)
                if providerError then
                    runtimeErrorSink({
                        operation = 'control_provider_register', traceId = 'unavailable',
                        code = providerError.code or 'CONTROL_PROVIDER_UNAVAILABLE'
                    })
                end
                return true
            end,
            onFailure = function(code, runtimeError)
                runtimeErrorSink({
                    operation = operation, traceId = 'unavailable',
                    code = type(runtimeError) == 'table' and runtimeError.code or code
                })
            end,
            failureCode = 'CORE_BINDING_FAILED',
            timeoutCode = 'CORE_BINDING_TIMEOUT',
            recoveryDelayMs = 5000
        })
    end

    startCoreBinding(coreRebindGeneration, 'resource_startup')

    local ownerCleanupGenerations = {}
    local function scheduleExtensionOwnerCleanup(resourceName, stoppedEpoch, generation, attempt)
        if ownerCleanupGenerations[resourceName] ~= generation then return end
        if (tonumber(attempt) or 0) > 0 and isExtensionOwnerRunning(resourceName) then return end
        local cleaned, cleanupError = extensionRegistries:disableOwner(
            resourceName, stoppedEpoch)
        if cleaned then return end
        runtimeErrorSink({
            operation = 'extension_owner_cleanup', traceId = 'unavailable',
            code = cleanupError and cleanupError.code or 'DATABASE_ERROR'
        })
        local exponent = math.min(tonumber(attempt) or 0, 5)
        local delay = math.min(1000 * (2 ^ exponent), 30000)
        SetTimeout(delay, function()
            scheduleExtensionOwnerCleanup(
                resourceName, stoppedEpoch, generation, exponent + 1)
        end)
    end

    AddEventHandler('onResourceStart', function(resourceName)
        if type(resourceName) == 'string' then
            ownerCleanupGenerations[resourceName] =
                (ownerCleanupGenerations[resourceName] or 0) + 1
        end
        if resourceName ~= 'synex_core' then return end
        coreRebindGeneration = coreRebindGeneration + 1
        coreRegistration:invalidate()
        local generation = coreRebindGeneration
        startCoreBinding(generation, 'core_restart_registration')
    end)

    AddEventHandler('onResourceStop', function(resourceName)
        if type(resourceName) ~= 'string' then return end
        if resourceName == 'synex_core' then
            coreRebindGeneration = coreRebindGeneration + 1
            setCurrentApi(nil)
            coreRegistration:invalidate()
            runtimeIndex:clear()
            cache:invalidate()
            database:clearDefinitionCache()
            for owner in pairs(observedExtensionOwnerEpochs) do
                observedExtensionOwnerEpochs[owner] = nil
            end
            for owner in pairs(stoppedExtensionOwnerEpochHighWater) do
                stoppedExtensionOwnerEpochHighWater[owner] = nil
            end
            return
        end
        if resourceName ~= 'synex_groups' then
            local generation = (ownerCleanupGenerations[resourceName] or 0) + 1
            ownerCleanupGenerations[resourceName] = generation
            local stoppedEpoch = observedExtensionOwnerEpochs[resourceName]
            observedExtensionOwnerEpochs[resourceName] = nil
            local epochError
            if stoppedEpoch == nil then
                stoppedEpoch, epochError = extensionRegistries:latestEpoch(resourceName)
            end
            if stoppedEpoch then
                local previousStoppedEpoch = stoppedExtensionOwnerEpochHighWater[resourceName]
                if previousStoppedEpoch == nil or stoppedEpoch > previousStoppedEpoch then
                    stoppedExtensionOwnerEpochHighWater[resourceName] = stoppedEpoch
                end
                scheduleExtensionOwnerCleanup(resourceName, stoppedEpoch, generation, 0)
            elseif epochError then
                runtimeErrorSink({
                    operation = 'extension_owner_epoch', traceId = 'unavailable',
                    code = epochError.code or 'DATABASE_ERROR'
                })
            end
        end
        cache:invalidate()
        if resourceName == 'synex_groups' then
            coreRegistration:invalidate()
            runtimeIndex:clear()
            database:clearDefinitionCache()
        end
    end)

    return true
end
