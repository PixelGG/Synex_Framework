return function(Foundation)
    local CoreBootstrap = {}
    local RETRY_DELAY_MS = 200
    local MAXIMUM_ATTEMPTS = 600
    local MINIMUM_RECOVERY_DELAY_MS = 1000
    local MAXIMUM_RECOVERY_DELAY_MS = 60000

    function CoreBootstrap.validateApi(api)
        return type(api) == 'table'
            and type(api.ownerEpoch) == 'number'
            and math.type(api.ownerEpoch) == 'integer' and api.ownerEpoch >= 1
            and api.Ids and Foundation.isCallable(api.Ids.next)
            and api.Events and Foundation.isCallable(api.Events.publishOutbox)
            and api.Scheduler and Foundation.isCallable(api.Scheduler.every)
            and Foundation.isCallable(api.Scheduler.cancel)
            and api.Characters and Foundation.isCallable(api.Characters.get)
            and Foundation.isCallable(api.Characters.getActive)
            and Foundation.isCallable(api.Characters.registerLifecycleParticipant)
            and api.Hooks and Foundation.isCallable(api.Hooks.run)
            and api.Audit and Foundation.isCallable(api.Audit.append)
            and api.Permissions and Foundation.isCallable(api.Permissions.check)
            and Foundation.isCallable(api.Permissions.evaluateRules)
            and api.Database and Foundation.isCallable(api.Database.null)
            and Foundation.isCallable(api.Database.read)
            and Foundation.isCallable(api.Database.write)
            and Foundation.isCallable(api.Database.transaction)
            and Foundation.isCallable(api.Database.maintenance)
            and api.DomainDeletions
            and Foundation.isCallable(api.DomainDeletions.registerProvider)
            and Foundation.isCallable(api.DomainDeletions.plan)
            and Foundation.isCallable(api.DomainDeletions.get)
            and Foundation.isCallable(api.DomainDeletions.process)
            and api.Services and Foundation.isCallable(api.Services.provide)
            and Foundation.isCallable(api.Services.setHealth)
            and api.RPC and Foundation.isCallable(api.RPC.registerServer)
            and Foundation.isCallable(api.RPC.registerNetwork)
    end

    local function retryable(runtimeError)
        return type(runtimeError) == 'table' and runtimeError.retryable == true
    end

    local function stageFailure(code, message, failure)
        if type(failure) == 'table' and type(failure.code) == 'string' then return failure end
        return Foundation.domainError(code, message, false)
    end

    local function invokeStage(callback, code, message)
        local invoked, value, runtimeError = pcall(callback)
        if not invoked then return nil, stageFailure(code, message, value) end
        if value == nil or value == false then
            return nil, stageFailure(code, message, runtimeError)
        end
        return value, nil
    end

    function CoreBootstrap.createRegistration(options)
        assert(type(options) == 'table', 'Core registration options are required')
        assert(type(options.prepare) == 'function', 'Core registration preparation is required')
        assert(type(options.deletionProvider) == 'function', 'Deletion provider factory is required')
        assert(type(options.characterParticipant) == 'function', 'Character participant factory is required')
        assert(type(options.rebuild) == 'function', 'Runtime rebuild handler is required')
        assert(type(options.serviceDefinition) == 'function', 'Service definition factory is required')
        assert(type(options.contractHandler) == 'function', 'Contract handler factory is required')
        assert(type(options.contracts) == 'table', 'Contract definitions are required')
        assert(type(options.scheduleWorkers) == 'function', 'Worker registration handler is required')
        assert(type(options.isGenerationCurrent) == 'function', 'Generation fence is required')
        assert(type(options.serviceName) == 'string' and type(options.serviceVersion) == 'string',
            'Service identity is required')
        local active
        local registration = {}

        function registration:isCurrent(binding)
            return active == binding and type(binding) == 'table'
                and options.isGenerationCurrent(binding.generation)
        end

        function registration:isReady(binding)
            return self:isCurrent(binding) and binding.ready == true
        end

        function registration:guard(binding, handler, errorCode)
            assert(Foundation.isCallable(handler), 'A callable guarded handler is required')
            return function(...)
                if not self:isReady(binding) then
                    return nil, Foundation.domainError(errorCode or 'CORE_UNAVAILABLE',
                        'The Groups Core binding is not ready.', true)
                end
                return handler(...)
            end
        end

        function registration:invalidate()
            local binding = active
            if not binding then return end
            binding.ready = false
            active = nil
            if binding.serviceToken and CoreBootstrap.validateApi(binding.api) then
                pcall(binding.api.Services.setHealth,
                    options.serviceName, options.serviceVersion, 'UNHEALTHY')
                for _, token in pairs(binding.workerTokens) do
                    pcall(binding.api.Scheduler.cancel, token)
                end
            end
        end

        function registration:bind(api, generation)
            if not CoreBootstrap.validateApi(api) then
                return nil, Foundation.domainError('CORE_UNAVAILABLE',
                    'synex_groups received an incomplete Synex Core API.', true)
            end
            if type(generation) ~= 'number' or math.type(generation) ~= 'integer'
                or generation < 1 or not options.isGenerationCurrent(generation) then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'The Groups Core binding generation is stale.', true)
            end
            if active and (active.generation ~= generation
                or active.ownerEpoch ~= api.ownerEpoch) then
                self:invalidate()
            end
            if not active then
                active = {
                    generation = generation,
                    ownerEpoch = api.ownerEpoch,
                    api = api,
                    ready = false,
                    rpcTokens = {},
                    workerTokens = {},
                    pendingWorkerCancellations = {}
                }
            else
                active.api = api
            end
            local binding = active
            if binding.ready then return true, nil end

            local value, runtimeError
            local function invoke(callback, code, message)
                if not self:isCurrent(binding) then
                    return nil, Foundation.domainError('STALE_RESOURCE',
                        'The Groups Core binding generation is stale.', true)
                end
                local result, resultError = invokeStage(callback, code, message)
                if not self:isCurrent(binding) then
                    return nil, Foundation.domainError('STALE_RESOURCE',
                        'The Groups Core binding generation is stale.', true)
                end
                return result, resultError
            end
            if not binding.prepared then
                value, runtimeError = invoke(function() return options.prepare(api, binding) end,
                    'GROUPS_PREPARATION_FAILED', 'Groups registration preparation failed.')
                if not value then return nil, runtimeError end
                binding.prepared = true
            end
            if not binding.deletionProviderToken then
                value, runtimeError = invoke(function()
                    return api.DomainDeletions.registerProvider(options.deletionProvider(binding))
                end, 'DELETION_PROVIDER_REGISTRATION_FAILED',
                    'The Groups deletion provider could not be registered.')
                if not value then return nil, runtimeError end
                binding.deletionProviderToken = value
            end
            if not binding.characterParticipantToken then
                value, runtimeError = invoke(function()
                    return api.Characters.registerLifecycleParticipant(
                        options.characterParticipant(binding))
                end, 'CHARACTER_PARTICIPANT_REGISTRATION_FAILED',
                    'The Groups character participant could not be registered.')
                if not value then return nil, runtimeError end
                binding.characterParticipantToken = value
            end
            if not binding.rebuilt then
                value, runtimeError = invoke(function() return options.rebuild(api, binding) end,
                    'RUNTIME_INDEX_REBUILD_FAILED',
                    'The Groups runtime index could not be rebuilt.')
                if not value then return nil, runtimeError end
                binding.rebuilt = true
            end
            if not binding.serviceToken then
                value, runtimeError = invoke(function()
                    return api.Services.provide(options.serviceDefinition(binding))
                end, 'SERVICE_REGISTRATION_FAILED', 'The Groups service could not be registered.')
                if not value then return nil, runtimeError end
                binding.serviceToken = value
            end
            if not binding.serviceUnhealthy then
                value, runtimeError = invoke(function()
                    return api.Services.setHealth(
                        options.serviceName, options.serviceVersion, 'UNHEALTHY')
                end, 'SERVICE_HEALTH_FAILED', 'The Groups service could not be fenced.')
                if not value then return nil, runtimeError end
                binding.serviceUnhealthy = true
            end
            for _, definition in ipairs(options.contracts) do
                local key = definition.name .. '@' .. definition.version
                if not binding.rpcTokens[key] then
                    value, runtimeError = invoke(function()
                        local register = definition.network == 'client-to-server'
                            and api.RPC.registerNetwork or api.RPC.registerServer
                        return register(definition,
                            options.contractHandler(definition, binding))
                    end, 'CONTRACT_REGISTRATION_FAILED',
                        'A Groups contract could not be registered.')
                    if not value then return nil, runtimeError end
                    binding.rpcTokens[key] = value
                end
            end
            if not binding.workersReady then
                value, runtimeError = invoke(function()
                    return options.scheduleWorkers(api, binding, binding.workerTokens,
                        binding.pendingWorkerCancellations)
                end, 'WORKER_REGISTRATION_FAILED', 'The Groups workers could not be registered.')
                if not value then return nil, runtimeError end
                binding.workersReady = true
            end
            value, runtimeError = invoke(function()
                return api.Services.setHealth(
                    options.serviceName, options.serviceVersion, 'HEALTHY')
            end, 'SERVICE_HEALTH_FAILED', 'The Groups service could not be activated.')
            if not value then return nil, runtimeError end
            binding.ready = true
            return true, nil
        end

        return registration
    end

    function CoreBootstrap.runWhenReady(options)
        assert(type(options) == 'table', 'Core bootstrap options are required')
        assert(type(options.acquire) == 'function', 'Core bootstrap requires API acquisition')
        assert(type(options.schedule) == 'function', 'Core bootstrap requires scheduling')
        assert(type(options.onReady) == 'function', 'Core bootstrap requires a ready handler')
        assert(type(options.onFailure) == 'function', 'Core bootstrap requires a failure handler')
        local maximumAttempts = options.maximumAttempts or MAXIMUM_ATTEMPTS
        assert(type(maximumAttempts) == 'number' and math.type(maximumAttempts) == 'integer'
            and maximumAttempts >= 1 and maximumAttempts <= MAXIMUM_ATTEMPTS,
            'Core bootstrap maximum attempts are invalid')
        local recoveryDelayMs = options.recoveryDelayMs
        assert(recoveryDelayMs == nil or type(recoveryDelayMs) == 'number'
            and math.type(recoveryDelayMs) == 'integer'
            and recoveryDelayMs >= MINIMUM_RECOVERY_DELAY_MS
            and recoveryDelayMs <= MAXIMUM_RECOVERY_DELAY_MS,
            'Core bootstrap recovery delay is invalid')
        local attempt = 0
        local run
        local function isCurrent()
            return options.isCurrent == nil or options.isCurrent()
        end
        local function fail(code, failure)
            if not isCurrent() then return end
            options.onFailure(code, failure)
        end
        local function retry(failure)
            if attempt >= maximumAttempts or not retryable(failure)
                or not isCurrent() then
                return false
            end
            options.schedule(RETRY_DELAY_MS, run)
            return true
        end
        local function recover(failure)
            if recoveryDelayMs == nil or not retryable(failure) or not isCurrent() then
                return false
            end
            options.schedule(recoveryDelayMs, function()
                if not isCurrent() then return end
                attempt = 0
                run()
            end)
            return true
        end
        local function exhausted(code, failure)
            recover(failure)
            fail(code, failure)
        end
        run = function()
            if not isCurrent() then return end
            attempt = attempt + 1
            local api, coreError = options.acquire()
            if api then
                local completed, ready, readyError = pcall(options.onReady, api)
                if completed and readyError == nil and ready ~= nil and ready ~= false then return end
                local failure = not completed and ready or readyError
                if completed and failure == nil then
                    failure = Foundation.domainError('GROUPS_READY_HANDLER_INVALID',
                        'The Groups ready handler did not confirm completion.', false)
                end
                if retry(failure) then return end
                exhausted(options.failureCode or 'GROUPS_STARTUP_FAILED', failure)
                return
            end
            if retry(coreError) then return end
            exhausted(options.timeoutCode or 'CORE_STARTUP_TIMEOUT', coreError)
        end
        options.schedule(0, run)
    end

    return CoreBootstrap
end
