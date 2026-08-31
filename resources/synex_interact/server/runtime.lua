SynexInteractApplication = {}

local Foundation = assert(SynexInteractFoundation, 'interact foundation must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractApplication.create(options)
    options = options or {}
    local resourceName = assert(options.resourceName, 'application requires resource name')
    local coreResource = options.coreResource or 'synex_core'
    local coreRange = options.coreRange or '^1.0.0'
    local coreRef = assert(options.coreRef, 'application requires Core reference')
    local ownerEpochs = assert(options.ownerEpochs, 'application requires owner epochs')
    local registry = assert(options.registry, 'application requires registry')
    local authority = assert(options.authority, 'application requires authority')
    local graph = assert(options.graph, 'application requires graph runtime')
    local service = assert(options.service, 'application requires service')
    local diagnostics = assert(options.diagnostics, 'application requires diagnostics')
    local controlProvider = assert(options.controlProvider, 'application requires control provider')
    local bundleLoader = assert(options.bundleLoader, 'application requires bundle loader')
    local observability = assert(options.observability, 'application requires observability')
    local compatibility = assert(options.compatibility, 'application requires compatibility adapter')
    local bridgeResource = options.bridgeResource or 'synex_bridge'
    local registerBridgeAdapter = assert(options.registerBridgeAdapter,
        'application requires bridge adapter registration')
    local acquireCore = assert(options.acquireCore, 'application requires Core acquisition')
    local loadResourceFile = options.loadResourceFile or LoadResourceFile
    local decode = assert(options.decode, 'application requires JSON decoding')
    local getResourceState = options.getResourceState or GetResourceState
    local wait = options.wait or Wait
    local createThread = options.createThread or CreateThread
    local generation, binding, stopping = 0, nil, false
    local application = {}

    local function coreHealth(state, unresolved)
        if state == 'UNHEALTHY' then return 'UNHEALTHY' end
        if state == 'READY' and unresolved ~= true then return 'HEALTHY' end
        return 'DEGRADED'
    end

    local function clearRuntimeAuthority(reason)
        local owners = {}
        for owner, epoch in pairs(ownerEpochs) do
            owners[#owners + 1] = { owner = owner, epoch = epoch }
        end
        table.sort(owners, function(left, right) return left.owner < right.owner end)
        for _, record in ipairs(owners) do
            authority.revokeOwner(record.owner, record.epoch, reason)
            registry.cleanupOwner(record.owner, record.epoch)
            ownerEpochs[record.owner] = nil
        end
        authority.reconcileSlots()
        return #owners
    end

    local function completeApi(api)
        local function callable(group, method)
            return type(api[group]) == 'table' and Foundation.isCallable(api[group][method])
        end
        return type(api) == 'table' and Validation.isInteger(api.ownerEpoch, 1)
            and callable('Runtime', 'getSnapshot')
            and callable('Services', 'provide') and callable('Services', 'setHealth')
            and callable('Services', 'call')
            and callable('RPC', 'registerServer') and callable('RPC', 'registerNetwork')
            and callable('RPC', 'call') and callable('Scheduler', 'every')
            and callable('Ids', 'next') and callable('Players', 'getBySource')
            and callable('Capabilities', 'checkResource')
            and callable('Permissions', 'check')
            and callable('ControlProviders', 'register')
            and callable('Metrics', 'increment') and callable('Audit', 'append')
            and callable('Events', 'publish')
    end

    local function current(candidate)
        return not stopping and candidate == binding
            and candidate.generation == generation and coreRef.value == candidate.api
    end

    local function runtimeRecord(owner)
        local api = coreRef.value
        if not completeApi(api) then return Validation.failure('INTERACT_UNAVAILABLE',
            'Synex Core is unavailable.', true) end
        local snapshot, snapshotError = api.Runtime.getSnapshot()
        if not snapshot then return nil, snapshotError end
        for _, record in ipairs(snapshot.resources or {}) do
            if record.name == owner then return record, nil end
        end
        return Validation.failure('INTERACT_OWNER_STOPPED',
            'The interaction owner is not registered in Core.', true)
    end

    function application.resolveOwnerEpoch(owner, expectedEpoch)
        if not Validation.resourceName(owner) or getResourceState(owner) ~= 'started' then
            return Validation.failure('INTERACT_OWNER_STOPPED',
                'The interaction owner resource is not started.')
        end
        if expectedEpoch ~= nil then
            if not Validation.isInteger(expectedEpoch, 1) then
                return Validation.failure('INTERACT_OWNER_STALE',
                    'The interaction owner epoch is invalid.')
            end
            local previous = ownerEpochs[owner]
            if previous ~= nil and previous ~= expectedEpoch then
                authority.revokeOwner(owner, previous, 'OWNER_RESTARTED')
                registry.cleanupOwner(owner, previous)
            end
            ownerEpochs[owner] = expectedEpoch
            return expectedEpoch, nil
        end
        local record, recordError = runtimeRecord(owner)
        if not record then return nil, recordError end
        if record.state ~= 'STARTED' or not Validation.isInteger(record.epoch, 1) then
            return Validation.failure('INTERACT_OWNER_STOPPED',
                'The interaction owner is not active.')
        end
        return application.resolveOwnerEpoch(owner, record.epoch)
    end

    local function loadContracts()
        local encoded = loadResourceFile(resourceName, 'contracts/interact.contracts.json')
        if type(encoded) ~= 'string' or #encoded < 2 or #encoded > 262144 then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'Interaction contract bundle is unavailable.', true)
        end
        local ok, value = pcall(decode, encoded)
        if not ok or not Validation.isPlainTable(value) or value.schema ~= 1
            or value.domain ~= 'synex.interact' or not Validation.isPlainTable(value.contracts)
            or #value.contracts ~= 12 then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'Interaction contract bundle is invalid.', false)
        end
        local contracts = Validation.copy(value.contracts)
        if not contracts then return Validation.failure('INTERACT_UNAVAILABLE',
            'Interaction contract bundle contains unsupported values.', false) end
        return contracts, nil
    end

    local function registerContracts(candidate)
        if candidate.contractsReady then return true end
        local contracts, contractError = loadContracts()
        if not contracts then return nil, contractError end
        for _, definition in ipairs(contracts) do
            local key = definition.name .. '@' .. definition.version
            if not candidate.contractTokens[key] then
                local handler, handlerError = service.contractHandler(definition)
                if not handler then return nil, handlerError end
                local register = definition.network == 'client-to-server'
                    and candidate.api.RPC.registerNetwork or candidate.api.RPC.registerServer
                local token, registrationError = register(definition, handler)
                if not token then return nil, registrationError end
                candidate.contractTokens[key] = token
            end
        end
        candidate.contractsReady = true
        return true
    end

    local function schedule(candidate)
        if candidate.workerToken then return true end
        local ticks = 0
        local token, scheduleError = candidate.api.Scheduler.every(
            SynexInteractLimits.workerIntervalMs, function()
                if not current(candidate) or not candidate.ready then return end
                authority.expire(options.now())
                ticks = ticks + 1
                if ticks % 20 == 0 then
                    local summary = diagnostics.summary()
                    observability.gauge('active_leases', {}, summary.activeLeases)
                    observability.gauge('active_sessions', {}, summary.activeSessions)
                    observability.gauge('active_graphs', {}, summary.activeExecutions)
                    observability.gauge('active_reservations', {}, summary.reservations)
                end
                if ticks % 120 == 0 then
                    local report = diagnostics.doctor({ limit = 100 })
                    candidate.api.Services.setHealth('synex.interact', '1.0.0',
                        coreHealth(report.status, false))
                end
            end, { name = 'synex_interact.runtime' })
        if not token then return nil, scheduleError end
        candidate.workerToken = token
        return true
    end

    local function registerCompatibility(candidate)
        if candidate.bridgeToken or getResourceState(bridgeResource) ~= 'started' then return true end
        local token, adapterError = registerBridgeAdapter(
            compatibility.definition(), compatibility.implementation())
        if token then candidate.bridgeToken = token; return true end
        if type(adapterError) == 'table'
            and (adapterError.code == 'COMPAT_PROVIDER_DISABLED'
                or adapterError.code == 'COMPAT_CONSUMER_DENIED') then return true end
        return nil, adapterError
    end

    local function bind(api, expectedGeneration)
        if stopping or expectedGeneration ~= generation then return false end
        if not completeApi(api) then return Validation.failure('INTERACT_UNAVAILABLE',
            'Synex Core returned an incomplete Interaction API.', true) end
        local candidate = binding
        if not candidate or candidate.api ~= api or candidate.generation ~= expectedGeneration then
            candidate = { api = api, generation = expectedGeneration,
                contractTokens = {}, ready = false }
            binding = candidate
        end
        coreRef.value = api
        ownerEpochs[resourceName] = api.ownerEpoch
        if candidate.ready then return true end
        if not candidate.serviceToken then
            local token, operationError = api.Services.provide(service.serviceDefinition())
            if not token then return nil, operationError end
            candidate.serviceToken = token
        end
        local fenced, fenceError = api.Services.setHealth(
            'synex.interact', '1.0.0', 'UNHEALTHY')
        if not fenced then return nil, fenceError end
        local contractsReady, contractError = registerContracts(candidate)
        if not contractsReady then return nil, contractError end
        if not candidate.controlToken then
            local token, operationError = controlProvider.register(api)
            if not token then return nil, operationError end
            candidate.controlToken = token
        end
        local compatibilityReady, compatibilityError = registerCompatibility(candidate)
        if not compatibilityReady then return nil, compatibilityError end
        local discovered, discoveryError = bundleLoader.discoverAll({
            caller = resourceName, callerEpoch = api.ownerEpoch,
            traceId = 'interact_bootstrap_discovery',
        })
        if not discovered then return nil, discoveryError end
        authority.reconcileSlots()
        local scheduled, scheduleError = schedule(candidate)
        if not scheduled then return nil, scheduleError end
        local health = diagnostics.health()
        local state = coreHealth(health.state, #discovered.unresolved > 0)
        local ready, readyError = api.Services.setHealth('synex.interact', '1.0.0', state)
        if not ready then return nil, readyError end
        candidate.ready = true
        observability.event('synex.interact.ready', {
            schemaVersion = 1, discoveryRevision = registry.currentRevision(),
            unresolvedBundles = #discovered.unresolved,
        }, { traceId = 'interact_bootstrap' })
        return true
    end

    local function beginBinding()
        generation = generation + 1
        local expected = generation
        binding, coreRef.value = nil, nil
        createThread(function()
            local attempts = 0
            while not stopping and generation == expected do
                local ok, api = pcall(acquireCore, coreRange)
                local value, operationError
                if ok and completeApi(api) then value, operationError =
                    Foundation.protect(bind, api, expected) end
                if value then return end
                attempts = attempts + 1
                if type(operationError) == 'table' and operationError.retryable == false then
                    print(('[%s] Interaction bootstrap failed: %s'):format(
                        resourceName, tostring(operationError.code or 'INTERACT_UNAVAILABLE')))
                    return
                end
                wait(attempts < 40 and 250 or 5000)
            end
        end)
    end

    local function checkOwnerCapability(owner, capability, operation)
        if owner == resourceName then return true end
        local api = coreRef.value
        if not completeApi(api) then return Validation.failure('INTERACT_UNAVAILABLE',
            'Synex Core is unavailable.', true) end
        return api.Capabilities.checkResource(owner, capability, operation)
    end

    local function buildFacade(owner, epoch)
        local facade = { version = '1.0.0', ownerResource = owner, ownerEpoch = epoch,
            limits = { visibleIntents = SynexInteractLimits.maximumVisibleIntents,
                bundleSmartObjects = SynexInteractLimits.maximumBundleSmartObjects,
                bundleIntents = SynexInteractLimits.maximumBundleIntents,
                graphNodes = SynexInteractLimits.maximumGraphNodes } }
        local function guard(capability, operation, handler)
            return function(...)
                local currentEpoch, epochError = application.resolveOwnerEpoch(owner, epoch)
                if not currentEpoch then return false, Foundation.publicError(epochError) end
                local allowed, capabilityError = checkOwnerCapability(owner, capability, operation)
                if not allowed then return false, Foundation.publicError(capabilityError) end
                local value, operationError = Foundation.protect(handler, ...)
                if value == nil then return false, Foundation.publicError(operationError) end
                return value, nil
            end
        end
        facade.registerBundle = guard('synex.interact.bundle.register',
            'interaction bundle registration', function(bundle)
                local value, operationError = registry.register(owner, epoch, bundle)
                if value then authority.reconcileSlots() end
                return value, operationError
            end)
        facade.replaceBundle = guard('synex.interact.bundle.register',
            'interaction bundle replacement', function(bundle, expectedRevision)
                authority.revokeOwner(owner, epoch, 'BUNDLE_REPLACED')
                local value, operationError = registry.replace(owner, epoch,
                    bundle, expectedRevision)
                if value then authority.reconcileSlots() end
                return value, operationError
            end)
        facade.unregisterBundle = guard('synex.interact.bundle.register',
            'interaction bundle removal', function(key, expectedRevision)
                authority.revokeOwner(owner, epoch, 'BUNDLE_UNREGISTERED')
                local value, operationError = registry.unregister(owner, epoch,
                    key, expectedRevision)
                if value then authority.reconcileSlots() end
                return value, operationError
            end)
        facade.registerProvider = guard('synex.interact.provider.register',
            'interaction provider registration', function(definition, handler)
                return registry.registerProvider(owner, epoch, definition, handler)
            end)
        facade.registerEvaluator = guard('synex.interact.provider.register',
            'interaction evaluator registration', function(definition, handler)
                return registry.registerEvaluator(owner, epoch, definition, handler)
            end)
        facade.registerAdapter = guard('synex.interact.adapter.register',
            'interaction adapter registration', function(definition, handler)
                return registry.registerAdapter(owner, epoch, definition, handler)
            end)
        facade.inviteParticipant = guard('synex.interact.runtime.manage',
            'interaction participant invitation', function(request)
                return authority.inviteSession(request, owner, epoch)
            end)
        facade.renewLease = guard('synex.interact.runtime.manage',
            'interaction lease renewal', function(leaseId, extensionMs)
                return authority.renewLease(leaseId, extensionMs,
                    nil, owner, epoch)
            end)
        return facade
    end

    function application.getAPI(owner, range)
        if range ~= nil and range ~= '^1.0.0' and range ~= '1.0.0' then
            return Validation.failure('INTERACT_VERSION_UNSUPPORTED',
                'The requested Interaction API version is unsupported.')
        end
        if not binding or not binding.ready then return Validation.failure('INTERACT_NOT_READY',
            'The Interaction runtime is not ready.', true) end
        local epoch, epochError = application.resolveOwnerEpoch(owner)
        if not epoch then return nil, epochError end
        return buildFacade(owner, epoch), nil
    end

    function application.start()
        stopping = false
        beginBinding()
        return true
    end
    function application.stop()
        stopping, generation = true, generation + 1
        clearRuntimeAuthority('INTERACT_STOPPED')
        binding, coreRef.value = nil, nil
        return true
    end
    function application.playerDropped(source)
        authority.cleanupSource(source, 'PLAYER_DROPPED')
        observability.playerDropped(source)
        return true
    end
    function application.resourceStarted(resource)
        if resource == coreResource then beginBinding(); return true end
        if binding and binding.ready then
            createThread(function()
                wait(0)
                if resource == bridgeResource then
                    local registered, registrationError = registerCompatibility(binding)
                    if not registered then observability.denied(
                        'compatibility.register', registrationError) end
                end
                local record = runtimeRecord(resource)
                if record and type(record.manifest) == 'table'
                    and type(record.manifest.interactionBundles) == 'table'
                    and #record.manifest.interactionBundles > 0 then
                    application.resolveOwnerEpoch(resource, record.epoch)
                    bundleLoader.discoverResource(resource, {
                        caller = resourceName,
                        callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 1,
                        traceId = 'interact_resource_started',
                    })
                    authority.reconcileSlots()
                end
            end)
        end
        return true
    end
    function application.resourceStopped(resource)
        if resource == resourceName then return application.stop() end
        if resource == coreResource then
            generation = generation + 1
            clearRuntimeAuthority('CORE_STOPPED')
            binding, coreRef.value = nil, nil
            return true
        end
        if resource == bridgeResource and binding then binding.bridgeToken = nil end
        local epoch = ownerEpochs[resource]
        if epoch then
            authority.revokeOwner(resource, epoch, 'OWNER_STOPPED')
            bundleLoader.ownerStopped(resource, epoch, {
                traceId = 'interact_owner_stopped' })
            ownerEpochs[resource] = nil
            authority.reconcileSlots()
        end
        return true
    end
    function application.isReady() return binding ~= nil and binding.ready == true end
    return application
end
