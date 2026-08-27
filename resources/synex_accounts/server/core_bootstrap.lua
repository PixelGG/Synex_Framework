return function(Foundation)
local CoreBootstrap = {}

local RETRY_DELAY_MS = 200
local MAXIMUM_ATTEMPTS = 600
local MINIMUM_RECOVERY_DELAY_MS = 1000
local MAXIMUM_RECOVERY_DELAY_MS = 60000

local function callable(container, name)
    return type(container) == 'table' and Foundation.isCallable(container[name])
end

function CoreBootstrap.validateApi(api)
    return type(api) == 'table'
        and type(api.ownerEpoch) == 'number'
        and math.type(api.ownerEpoch) == 'integer' and api.ownerEpoch >= 1
        and callable(api.Runtime, 'getRetentionPolicy')
        and callable(api.Metrics, 'increment')
        and callable(api.Metrics, 'gauge')
        and callable(api.Metrics, 'observe')
        and callable(api.Capabilities, 'checkResource')
        and callable(api.Ids, 'next')
        and callable(api.Events, 'publishOutbox')
        and callable(api.Hooks, 'run')
        and callable(api.Audit, 'append')
        and callable(api.Scheduler, 'every')
        and callable(api.Scheduler, 'cancel')
        and callable(api.Characters, 'registerLifecycleParticipant')
        and callable(api.DomainDeletions, 'registerProvider')
        and callable(api.Services, 'provide')
        and callable(api.Services, 'setHealth')
        and callable(api.RPC, 'registerServer')
end

local function failure(code, message, candidate)
    if type(candidate) == 'table' and type(candidate.code) == 'string' then
        return candidate
    end
    return Foundation.domainError(code, message, false)
end

local function invoke(callback, code, message)
    local called, value, runtimeError = pcall(callback)
    if not called then return nil, failure(code, message, value) end
    if value == nil or value == false then
        return nil, failure(code, message, runtimeError)
    end
    return value, nil
end

function CoreBootstrap.createRegistration(options)
    assert(type(options) == 'table', 'Accounts registration options are required')
    assert(type(options.isGenerationCurrent) == 'function',
        'Accounts registration requires a generation fence')
    assert(type(options.serviceDefinition) == 'function',
        'Accounts registration requires a service definition factory')
    assert(type(options.contractHandler) == 'function',
        'Accounts registration requires a contract handler factory')
    assert(type(options.characterParticipant) == 'function',
        'Accounts registration requires a character participant factory')
    assert(type(options.deletionProvider) == 'function',
        'Accounts registration requires a deletion provider factory')
    assert(type(options.scheduleWorkers) == 'function',
        'Accounts registration requires a worker scheduler')
    assert(type(options.contracts) == 'table',
        'Accounts registration requires contract definitions')
    assert(type(options.serviceName) == 'string'
        and type(options.serviceVersion) == 'string',
        'Accounts registration requires a service identity')

    local active
    local registration = {}

    function registration:isCurrent(binding)
        return active == binding and type(binding) == 'table'
            and options.isGenerationCurrent(binding.generation)
    end

    function registration:isReady(binding)
        return self:isCurrent(binding) and binding.ready == true
    end

    function registration:guard(binding, handler, code)
        assert(Foundation.isCallable(handler), 'A callable Accounts handler is required')
        return function(...)
            if not self:isReady(binding) then
                return nil, Foundation.domainError(code or 'CORE_UNAVAILABLE',
                    'The Accounts Core binding is not ready.', true)
            end
            return handler(...)
        end
    end

    function registration:invalidate()
        local binding = active
        if not binding then return end
        binding.ready = false
        active = nil
        if CoreBootstrap.validateApi(binding.api) then
            if binding.serviceToken then
                pcall(binding.api.Services.setHealth,
                    options.serviceName, options.serviceVersion, 'UNHEALTHY')
            end
            for _, token in pairs(binding.workerTokens or {}) do
                pcall(binding.api.Scheduler.cancel, token)
            end
        end
    end

    function registration:bind(api, generation)
        if not CoreBootstrap.validateApi(api) then
            return nil, Foundation.domainError('CORE_UNAVAILABLE',
                'synex_accounts received an incomplete Synex Core API.', true)
        end
        if type(generation) ~= 'number' or math.type(generation) ~= 'integer'
            or generation < 1 or not options.isGenerationCurrent(generation) then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The Accounts Core binding generation is stale.', true)
        end
        if active and (active.generation ~= generation
            or active.ownerEpoch ~= api.ownerEpoch) then
            self:invalidate()
        end
        if not active then
            active = {
                api = api,
                generation = generation,
                ownerEpoch = api.ownerEpoch,
                ready = false,
                rpcTokens = {},
                workerTokens = {},
            }
        else
            active.api = api
        end
        local binding = active
        if binding.ready then return true, nil end

        local function stage(callback, code, message)
            if not self:isCurrent(binding) then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'The Accounts Core binding generation is stale.', true)
            end
            local value, runtimeError = invoke(callback, code, message)
            if not self:isCurrent(binding) then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'The Accounts Core binding generation is stale.', true)
            end
            return value, runtimeError
        end

        local value, runtimeError
        if not binding.deletionProviderToken then
            value, runtimeError = stage(function()
                return api.DomainDeletions.registerProvider(
                    options.deletionProvider(binding))
            end, 'DELETION_PROVIDER_REGISTRATION_FAILED',
            'The Accounts deletion provider could not be registered.')
            if not value then return nil, runtimeError end
            binding.deletionProviderToken = value
        end
        if not binding.characterParticipantToken then
            value, runtimeError = stage(function()
                return api.Characters.registerLifecycleParticipant(
                    options.characterParticipant(binding))
            end, 'CHARACTER_PARTICIPANT_REGISTRATION_FAILED',
            'The Accounts character participant could not be registered.')
            if not value then return nil, runtimeError end
            binding.characterParticipantToken = value
        end
        if not binding.serviceToken then
            value, runtimeError = stage(function()
                return api.Services.provide(options.serviceDefinition(binding))
            end, 'SERVICE_REGISTRATION_FAILED',
            'The Accounts service could not be registered.')
            if not value then return nil, runtimeError end
            binding.serviceToken = value
        end
        if not binding.serviceUnhealthy then
            value, runtimeError = stage(function()
                return api.Services.setHealth(
                    options.serviceName, options.serviceVersion, 'UNHEALTHY')
            end, 'SERVICE_HEALTH_FAILED',
            'The Accounts service could not be fenced.')
            if not value then return nil, runtimeError end
            binding.serviceUnhealthy = true
        end
        for _, definition in ipairs(options.contracts) do
            local key = definition.name .. '@' .. definition.version
            if not binding.rpcTokens[key] then
                value, runtimeError = stage(function()
                    return api.RPC.registerServer(definition,
                        options.contractHandler(definition, binding))
                end, 'CONTRACT_REGISTRATION_FAILED',
                'An Accounts contract could not be registered.')
                if not value then return nil, runtimeError end
                binding.rpcTokens[key] = value
            end
        end
        if not binding.workersReady then
            value, runtimeError = stage(function()
                return options.scheduleWorkers(api, binding, binding.workerTokens)
            end, 'WORKER_REGISTRATION_FAILED',
            'The Accounts workers could not be registered.')
            if not value then return nil, runtimeError end
            binding.workersReady = true
        end
        value, runtimeError = stage(function()
            return api.Services.setHealth(
                options.serviceName, options.serviceVersion, 'HEALTHY')
        end, 'SERVICE_HEALTH_FAILED',
        'The Accounts service could not be activated.')
        if not value then return nil, runtimeError end
        binding.ready = true
        return true, nil
    end

    return registration
end

function CoreBootstrap.runWhenReady(options)
    assert(type(options) == 'table', 'Accounts bootstrap options are required')
    assert(type(options.acquire) == 'function', 'Accounts bootstrap requires API acquisition')
    assert(type(options.schedule) == 'function', 'Accounts bootstrap requires a scheduler')
    assert(type(options.onReady) == 'function', 'Accounts bootstrap requires a ready handler')
    assert(type(options.onFailure) == 'function', 'Accounts bootstrap requires a failure handler')
    local maximumAttempts = options.maximumAttempts or MAXIMUM_ATTEMPTS
    local recoveryDelayMs = options.recoveryDelayMs
    assert(type(maximumAttempts) == 'number' and math.type(maximumAttempts) == 'integer'
        and maximumAttempts >= 1 and maximumAttempts <= MAXIMUM_ATTEMPTS,
        'Accounts bootstrap maximum attempts are invalid')
    assert(recoveryDelayMs == nil or type(recoveryDelayMs) == 'number'
        and math.type(recoveryDelayMs) == 'integer'
        and recoveryDelayMs >= MINIMUM_RECOVERY_DELAY_MS
        and recoveryDelayMs <= MAXIMUM_RECOVERY_DELAY_MS,
        'Accounts bootstrap recovery delay is invalid')

    local attempt = 0
    local run
    local function current()
        return options.isCurrent == nil or options.isCurrent()
    end
    local function retry(runtimeError)
        if attempt >= maximumAttempts or not current()
            or type(runtimeError) ~= 'table' or runtimeError.retryable ~= true then
            return false
        end
        options.schedule(RETRY_DELAY_MS, run)
        return true
    end
    local function fail(code, runtimeError)
        if not current() then return end
        if recoveryDelayMs and type(runtimeError) == 'table'
            and runtimeError.retryable == true then
            options.schedule(recoveryDelayMs, function()
                if not current() then return end
                attempt = 0
                run()
            end)
        end
        options.onFailure(code, runtimeError)
    end
    run = function()
        if not current() then return end
        attempt = attempt + 1
        local api, apiError = options.acquire()
        if not api then
            if not retry(apiError) then
                fail(options.timeoutCode or 'CORE_BINDING_TIMEOUT', apiError)
            end
            return
        end
        local called, ready, readyError = pcall(options.onReady, api)
        if called and ready ~= nil and ready ~= false and readyError == nil then return end
        local runtimeError = called and readyError or ready
        if runtimeError == nil then
            runtimeError = Foundation.domainError('ACCOUNTS_READY_HANDLER_INVALID',
                'The Accounts ready handler did not confirm completion.')
        end
        if not retry(runtimeError) then
            fail(options.failureCode or 'CORE_BINDING_FAILED', runtimeError)
        end
    end
    options.schedule(0, run)
end

return CoreBootstrap
end
