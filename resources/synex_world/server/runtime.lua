SynexWorldApplication = {}

local Foundation = assert(SynexWorldFoundation, 'world foundation must be loaded first')
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local idempotencyOperations = {
    ['synex.world.state.set'] = 'a',
    ['synex.world.door.set_state'] = 'b',
    ['synex.world.portal.transition'] = 'c',
    ['synex.world.instance.create'] = 'd',
    ['synex.world.instance.join'] = 'e',
    ['synex.world.instance.leave'] = 'f',
    ['synex.world.instance.close'] = 'g',
}

local lifecycleScopedIdempotency = {
    ['synex.world.state.set'] = true,
    ['synex.world.door.set_state'] = true,
    ['synex.world.portal.transition'] = true,
    ['synex.world.instance.create'] = true,
    ['synex.world.instance.join'] = true,
    ['synex.world.instance.leave'] = true,
    ['synex.world.instance.close'] = true,
}

local base36Digits = '0123456789abcdefghijklmnopqrstuvwxyz'

local function encodeIdempotencyCaller(caller)
    local digits = {}
    for index = 7, #caller do
        local byte = caller:byte(index)
        if byte >= 97 and byte <= 122 then
            digits[#digits + 1] = byte - 96
        elseif byte >= 48 and byte <= 57 then
            digits[#digits + 1] = byte - 21
        elseif byte == 95 then
            digits[#digits + 1] = 37
        else
            return nil
        end
    end
    if #digits < 1 or #digits > 58 then return nil end

    -- Resource suffixes are base-38 digits 1..37. Long division converts the
    -- arbitrary-precision value to Core's operation-safe base-36 alphabet.
    -- Excluding zero as an input digit preserves leading characters exactly.
    local encoded = {}
    while #digits > 0 do
        local quotient, carry = {}, 0
        for _, digit in ipairs(digits) do
            local current = carry * 38 + digit
            local divided = math.floor(current / 36)
            carry = current - divided * 36
            if #quotient > 0 or divided > 0 then
                quotient[#quotient + 1] = divided
            end
        end
        encoded[#encoded + 1] = base36Digits:sub(carry + 1, carry + 1)
        digits = quotient
    end
    if #encoded > 60 then return nil end
    local reversed = {}
    for index = #encoded, 1, -1 do reversed[#reversed + 1] = encoded[index] end
    return table.concat(reversed)
end

function SynexWorldApplication.create(options)
    local resourceName = assert(options.resourceName, 'world application requires resource name')
    local coreResource = assert(options.coreResource, 'world application requires Core resource')
    local coreRange = assert(options.coreRange, 'world application requires Core range')
    local coreRef = assert(options.coreRef, 'world application requires Core reference')
    local foundation = assert(options.foundation, 'world application requires foundation')
    local health = assert(options.health, 'world application requires health')
    local service = assert(options.service, 'world application requires service')
    local controlProvider = assert(options.controlProvider,
        'world application requires control provider')
    local bundleLoader = assert(options.bundleLoader, 'world application requires bundle loader')
    local mapRegistry = assert(options.mapRegistry, 'world application requires maps')
    local slices = assert(options.slices, 'world application requires slices')
    local presence = assert(options.presence, 'world application requires presence')
    local instances = assert(options.instances, 'world application requires instances')
    local portals = assert(options.portals, 'world application requires portals')
    local outbox = assert(options.outbox, 'world application requires outbox')
    local diagnostics = assert(options.diagnostics, 'world application requires diagnostics')
    local observability = assert(options.observability, 'world application requires observability')
    local loadResourceFile = assert(options.loadResourceFile,
        'world application requires resource file access')
    local decode = assert(options.decode, 'world application requires JSON decoding')
    local acquireApi = assert(options.acquireApi, 'world application requires Core acquisition')
    local wait = assert(options.wait, 'world application requires wait')
    local createThread = assert(options.createThread, 'world application requires threads')
    local generation, binding, stopping = 0, nil, false
    local registryIncarnationBound = false
    local idempotencyIncarnation = nil
    local workerFailures = {}
    local application = {}

    local function completeApi(api)
        local function callable(group, method)
            return type(api[group]) == 'table' and Foundation.isCallable(api[group][method])
        end
        return type(api) == 'table' and type(api.ownerEpoch) == 'number'
            and api.ownerEpoch % 1 == 0 and api.ownerEpoch >= 1
            and callable('Runtime', 'getSnapshot')
            and callable('Services', 'provide') and callable('Services', 'setHealth')
            and callable('RPC', 'registerServer') and callable('RPC', 'call')
            and callable('Scheduler', 'after') and callable('Scheduler', 'every')
            and callable('Scheduler', 'cancel')
            and callable('Idempotency', 'run')
            and callable('Ids', 'next') and callable('Players', 'getBySource')
            and callable('Capabilities', 'checkResource')
            and callable('Events', 'publish') and callable('Events', 'publishOutbox')
            and callable('Metrics', 'increment') and callable('Audit', 'append')
            and callable('ControlProviders', 'register')
            and callable('Database', 'null') and callable('Database', 'read')
            and callable('Database', 'write') and callable('Database', 'transaction')
            and callable('Database', 'maintenance')
    end

    local function current(candidate)
        return type(candidate) == 'table' and not stopping and binding == candidate
            and candidate.generation == generation
            and coreRef.value == candidate.api
    end

    local function desiredServiceHealth()
        if health.state == 'READY' then return 'HEALTHY' end
        if health.state == 'DEGRADED' then return 'DEGRADED' end
        return 'UNHEALTHY'
    end

    local reconcilingServiceHealth = false
    local function reconcileServiceHealth(required)
        local api = coreRef.value
        if not api or type(api.Services) ~= 'table'
            or not Foundation.isCallable(api.Services.setHealth) then
            if required then
                return nil, { code = 'CORE_UNAVAILABLE',
                    message = 'World service health cannot be reconciled.', retryable = true }
            end
            return false
        end
        if reconcilingServiceHealth then return true end
        reconcilingServiceHealth = true
        local called, result, operationError = pcall(api.Services.setHealth,
            'synex.world', '1.0.0', desiredServiceHealth())
        reconcilingServiceHealth = false
        if called and result then return true end
        if required then
            return nil, type(operationError) == 'table' and operationError or {
                code = 'CORE_UNAVAILABLE',
                message = 'World service health reconciliation failed.', retryable = true,
            }
        end
        return false
    end

    if Foundation.isCallable(foundation.onHealthChanged) then
        foundation.onHealthChanged(function() reconcileServiceHealth(false) end)
    end

    local function reconcileTemplateHealth(context)
        if not Foundation.isCallable(instances.reconcileTemplateAvailability) then return true end
        local report, operationError = instances.reconcileTemplateAvailability(
            function(template)
                local availability = mapRegistry.objectAvailability(template)
                return type(availability) == 'table' and availability.available == true
            end, context)
        if not report then
            foundation.setHealth('DEGRADED', 'INSTANCE_TEMPLATE_CLEANUP_FAILED',
                'World instance template cleanup could not be reconciled.')
            return nil, operationError
        end
        if (tonumber(report.failures) or 0) > 0
            or (tonumber(report.pending) or 0) > 0 then
            foundation.setHealth('DEGRADED', 'INSTANCE_TEMPLATE_CLEANUP_FAILED',
                'One or more World instances await fail-safe template cleanup.')
        else
            foundation.clearHealth('INSTANCE_TEMPLATE_CLEANUP_FAILED')
        end
        return report
    end

    local function reconcileMapHealth(summary, context)
        if type(summary) ~= 'table' then
            return nil, { code = 'MAP_PACKAGE_UNAVAILABLE',
                message = 'World map package state is unavailable.', retryable = true }
        end
        if (tonumber(summary.requiredUnavailable) or 0) > 0 then
            foundation.setHealth('DEGRADED', 'MAP_PACKAGE_UNAVAILABLE',
                'One or more required World map packages are unavailable.')
        else
            foundation.clearHealth('MAP_PACKAGE_UNAVAILABLE')
        end
        local templates, templateError = reconcileTemplateHealth(context)
        if not templates then return nil, templateError end
        return summary
    end

    local function loadContracts()
        local encoded = loadResourceFile(resourceName, 'contracts/world.contracts.json')
        if type(encoded) ~= 'string' or #encoded < 2 then
            return nil, { code = 'UNAVAILABLE',
                message = 'World contract collection is unavailable.', retryable = false }
        end
        local ok, collection = pcall(decode, encoded)
        if not ok or type(collection) ~= 'table' or type(collection.contracts) ~= 'table' then
            return nil, { code = 'UNAVAILABLE',
                message = 'World contract collection is invalid.', retryable = false }
        end
        return collection.contracts
    end

    local function mappedIdempotencyError(operationError)
        local code = type(operationError) == 'table' and operationError.code or nil
        if code == 'IDEMPOTENCY_CONFLICT' then
            return select(2, Validation.failure('CONCURRENT_MODIFICATION',
                'The idempotency key was already used with a different World request.'))
        end
        if code == 'IDEMPOTENCY_IN_PROGRESS' or code == 'IDEMPOTENCY_RACE' then
            return select(2, Validation.failure('CONCURRENT_MODIFICATION',
                'The idempotent World operation is already in progress.', true))
        end
        if code == 'IDEMPOTENCY_CAPACITY_EXCEEDED' then
            return select(2, Validation.failure('RATE_LIMITED',
                'World idempotency capacity is exhausted.'))
        end
        if code == 'INVALID_IDEMPOTENCY_INPUT' or code == 'INVALID_IDEMPOTENCY_OPTIONS'
            or code == 'INVALID_JSON_VALUE' or code == 'JSON_ENCODING_FAILED'
            or code == 'PAYLOAD_TOO_LARGE' then
            return select(2, Validation.failure('INVALID_ARGUMENT',
                'The World idempotency request is invalid.'))
        end
        if type(code) == 'string' and code:match('^IDEMPOTENCY_') then
            return select(2, Validation.failure('UNAVAILABLE',
                'The durable World idempotency result is unavailable.',
                operationError.retryable == true))
        end
        return operationError
    end

    local function runIdempotent(candidate, definition, request, context, handler)
        local code = idempotencyOperations[definition.name]
        local caller = type(context) == 'table'
            and select(1, Validation.resourceName(context.caller)) or nil
        local key = type(request) == 'table' and request.idempotencyKey or nil
        if not code or not caller or type(key) ~= 'string' or #key < 8 or #key > 36
            or key:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return Validation.failure('INVALID_ARGUMENT',
                'World contract idempotency identity is invalid.')
        end
        local copiedRequest = foundation.copy(request)
        if type(copiedRequest) ~= 'table' then
            return Validation.failure('INVALID_ARGUMENT',
                'World contract idempotency request is invalid.')
        end
        copiedRequest.idempotencyKey = nil
        local encodedCaller = encodeIdempotencyCaller(caller)
        local operation = encodedCaller and code .. '.' .. encodedCaller or nil
        if not operation or #operation > 64 then
            return Validation.failure('INVALID_ARGUMENT',
                'World contract idempotency caller is invalid.')
        end
        -- The caller also remains in the request fingerprint as a defense in
        -- depth against any future namespace encoder regression.
        local fingerprint = { caller = caller, request = copiedRequest }
        -- Every mutation may project process-local state, one-shot client grants
        -- or bucket membership. Bind its fingerprint to this World incarnation
        -- so Core can never replay an earlier process' success as current truth.
        if lifecycleScopedIdempotency[definition.name] then
            if type(idempotencyIncarnation) ~= 'string' then
                return Validation.failure('CORE_UNAVAILABLE',
                    'World mutation idempotency is not initialized.', true)
            end
            fingerprint.worldIncarnation = idempotencyIncarnation
        end
        local value, operationError, metadata = candidate.api.Idempotency.run(
            operation, key, fingerprint, handler, {
                lockSeconds = 60,
                ttlSeconds = 604800,
                maximumRequestBytes = 65536,
                maximumResponseBytes = 65536,
            })
        if not value then return nil, mappedIdempotencyError(operationError) end
        local response = foundation.copy(value)
        if type(response) ~= 'table' or type(metadata) ~= 'table'
            or type(metadata.replayed) ~= 'boolean' then
            return Validation.failure('UNAVAILABLE',
                'The durable World idempotency response is invalid.', true)
        end
        response.replayed = metadata.replayed
        return response
    end

    local function registerContracts(candidate)
        local definitions, definitionError = loadContracts()
        if not definitions then return nil, definitionError end
        local handlers, handlerError = service.contractHandlers(definitions)
        if not handlers then return nil, handlerError end
        for _, definition in ipairs(definitions) do
            local handler = handlers[definition.name]
            if not Foundation.isCallable(handler)
                or definition.idempotent == true
                    and idempotencyOperations[definition.name] == nil
                or idempotencyOperations[definition.name] ~= nil
                    and definition.idempotent ~= true then
                return nil, { code = 'UNAVAILABLE',
                    message = 'A World contract has no bounded idempotent runtime handler.',
                    retryable = false }
            end
            local key = definition.name .. '@' .. definition.version
            if not candidate.rpcTokens[key] then
                local token, registrationError = candidate.api.RPC.registerServer(definition,
                    function(request, context)
                        if not current(candidate) or candidate.ready ~= true then
                            return nil, { code = 'STALE_RESOURCE',
                                message = 'The World Core binding is not ready.', retryable = true }
                        end
                        local execute = function()
                            return foundation.protect('contract.' .. definition.name,
                                function() return handler(request, context) end, context)
                        end
                        local value, operationError
                        if definition.idempotent == true then
                            value, operationError = runIdempotent(candidate,
                                definition, request, context, execute)
                        else
                            value, operationError = execute()
                        end
                        if value == nil then return nil, foundation.publicError(operationError) end
                        return value
                    end)
                if not token then return nil, registrationError end
                candidate.rpcTokens[key] = token
            end
        end
        return true
    end

    local function schedule(candidate, delay, name, handler)
        if candidate.workerTokens[name] then return true end
        local token, scheduleError = candidate.api.Scheduler.every(delay, function()
            if not current(candidate) or candidate.ready ~= true then return end
            local value, operationError = foundation.protect('worker.' .. name, handler,
                { traceId = 'world_' .. name })
            if value == nil and operationError then
                workerFailures[name] = true
                foundation.setHealth('DEGRADED', 'WORLD_WORKER_FAILURE',
                    'A bounded World worker failed.')
            else
                workerFailures[name] = nil
                if next(workerFailures) == nil then
                    foundation.clearHealth('WORLD_WORKER_FAILURE')
                end
            end
        end, { name = 'synex_world.' .. name })
        if not token then return nil, scheduleError end
        candidate.workerTokens[name] = token
        return true
    end

    local function scheduleWorkers(candidate)
        local workers = {
            { 1000, 'outbox', function()
                local claim, claimError = candidate.api.Ids.next('outbox_claim')
                if not claim then return nil, claimError end
                return outbox:dispatchBatch(claim, { maximum = 25 })
            end },
            { 1000, 'slices', function() return slices.updateAll(false) end },
            { 2000, 'maps', function()
                local before = mapRegistry.summary().generation
                local summary = mapRegistry.refresh()
                if summary.generation ~= before then slices.invalidateAll() end
                return reconcileMapHealth(summary, { traceId = 'world_maps' })
            end },
            { 1000, 'portal_grants', function() return { active = portals.expire() } end },
            { 5000, 'instance_expiry', function()
                local context = { traceId = 'world_instance_expiry' }
                local closed = instances.expire(context)
                local cleanup = Foundation.isCallable(instances.retryClosedCleanup)
                    and instances.retryClosedCleanup(25, context)
                    or { attempted = 0, completed = 0, failures = 0, pending = 0 }
                local bucketRecovery = Foundation.isCallable(instances.retryBucketRecovery)
                    and instances.retryBucketRecovery(25, context)
                    or { attempted = 0, completed = 0, failures = 0, pending = 0 }
                if not cleanup then
                    foundation.setHealth('DEGRADED', 'INSTANCE_STATE_CLEANUP_FAILED',
                        'Instance-scoped World state cleanup retry failed.')
                elseif (tonumber(cleanup.pending) or 0) > 0 then
                    foundation.setHealth('DEGRADED', 'INSTANCE_STATE_CLEANUP_FAILED',
                        'Instance-scoped World state cleanup is pending retry.')
                else
                    foundation.clearHealth('INSTANCE_STATE_CLEANUP_FAILED')
                end
                if not bucketRecovery or (tonumber(bucketRecovery.pending) or 0) > 0 then
                    foundation.setHealth('DEGRADED', 'INSTANCE_BUCKET_RECOVERY_FAILED',
                        'World instance bucket cleanup is pending bounded recovery.')
                else
                    foundation.clearHealth('INSTANCE_BUCKET_RECOVERY_FAILED')
                end
                return { closed = closed, stateCleanup = cleanup,
                    bucketRecovery = bucketRecovery }
            end },
            { 5000, 'metrics', function()
                observability.runtimeGauges(options.registry, instances, slices)
                return true
            end },
            { 30000, 'doctor', function()
                local report, doctorError = diagnostics.doctor({
                    includePersistence = true, limit = 100 })
                if not report then return nil, doctorError end
                if report.status == 'DEGRADED' then
                    foundation.setHealth('DEGRADED', 'WORLD_DOCTOR_FINDINGS',
                        'World doctor reported actionable findings.')
                else
                    foundation.clearHealth('WORLD_DOCTOR_FINDINGS')
                end
                return report
            end },
        }
        for _, worker in ipairs(workers) do
            local registered, workerError = schedule(candidate,
                worker[1], worker[2], worker[3])
            if not registered then return nil, workerError end
        end
        return true
    end

    local function bind(api, expectedGeneration)
        if stopping or expectedGeneration ~= generation then return false end
        if not completeApi(api) then
            return nil, { code = 'UNAVAILABLE',
                message = 'Synex Core returned an incomplete World API.', retryable = true }
        end
        local candidate = binding
        if type(candidate) ~= 'table' or candidate.api ~= api
            or candidate.generation ~= expectedGeneration then
            candidate = { api = api, generation = expectedGeneration,
                rpcTokens = {}, workerTokens = {} }
            binding = candidate
        end
        coreRef.value = api
        if candidate.ready then return true end
        health.persistence, health.service = 'READY', 'REGISTERING'

        if not registryIncarnationBound
            and type(options.registry.bindIncarnation) == 'function' then
            local bound, bindError = options.registry.bindIncarnation(api.ownerEpoch)
            if not bound then return nil, bindError end
            registryIncarnationBound = true
        end

        if idempotencyIncarnation == nil then
            local incarnation, incarnationError = api.Ids.next('world_idempotency')
            if type(incarnation) ~= 'string' or #incarnation < 8 or #incarnation > 128
                or incarnation:find('[%z\1-\31\127]') then
                return nil, type(incarnationError) == 'table' and incarnationError or {
                    code = 'CORE_UNAVAILABLE',
                    message = 'World resource incarnation could not be allocated.',
                    retryable = true,
                }
            end
            idempotencyIncarnation = incarnation
        end

        if not candidate.serviceToken then
            local serviceToken, serviceError = api.Services.provide(service.serviceDefinition())
            if not serviceToken then return nil, serviceError end
            candidate.serviceToken = serviceToken
        end
        if not candidate.serviceFenced then
            local unhealthy, healthError = api.Services.setHealth(
                'synex.world', '1.0.0', 'UNHEALTHY')
            if not unhealthy then return nil, healthError end
            candidate.serviceFenced = true
        end
        if not candidate.discovery then
            local discovered, discoveryError = bundleLoader.discoverAll({
                caller = resourceName, callerEpoch = api.ownerEpoch,
                traceId = 'world_bootstrap_discovery' })
            if not discovered then return nil, discoveryError end
            candidate.discovery = discovered
            local mapsReady, mapError = reconcileMapHealth(mapRegistry.refresh(),
                { traceId = 'world_bootstrap_maps' })
            if not mapsReady then return nil, mapError end
            slices.invalidateAll()
        end
        local contractsReady, contractsError = registerContracts(candidate)
        if not contractsReady then return nil, contractsError end
        if not candidate.providerToken then
            local providerToken, providerError = controlProvider.register(api)
            if not providerToken then return nil, providerError end
            candidate.providerToken = providerToken
        end
        local workersReady, workersError = scheduleWorkers(candidate)
        if not workersReady then return nil, workersError end
        local discovered = candidate.discovery
        if #discovered.unresolved > 0 then
            foundation.setHealth('DEGRADED', 'WORLD_DEPENDENCY_MISSING',
                'One or more declared World bundles could not be activated.')
        else
            foundation.clearHealth('WORLD_DEPENDENCY_MISSING')
        end
        foundation.clearHealth('CORE_UNAVAILABLE')
        foundation.clearHealth('WORLD_BOOTSTRAP_FAILED')
        if next(health.reasons) == nil then foundation.setHealth('READY', nil) end
        local healthy, readyError = reconcileServiceHealth(true)
        if not healthy then return nil, readyError end
        health.service = 'REGISTERED'
        candidate.ready = true
        return true
    end

    local function beginBinding()
        generation = generation + 1
        local expectedGeneration = generation
        binding, coreRef.value = nil, nil
        health.service = 'UNREGISTERED'
        createThread(function()
            local attempts, prolonged = 0, false
            while not stopping and expectedGeneration == generation do
                if stopping or expectedGeneration ~= generation then return end
                local ok, api = pcall(acquireApi, coreRange)
                local lastError
                if ok and completeApi(api) then
                    local bound, bindError = foundation.protect('core.bind',
                        function() return bind(api, expectedGeneration) end,
                        { traceId = 'world_core_bind' })
                    if bound then return end
                    lastError = bindError
                else
                    lastError = api
                end
                if type(lastError) == 'table' and lastError.retryable == false then
                    foundation.setHealth('UNHEALTHY', 'WORLD_BOOTSTRAP_FAILED',
                        'World bootstrap failed with a non-retryable error.')
                    print(('[%s] World bootstrap failed: %s'):format(resourceName,
                        tostring(lastError.code or 'UNAVAILABLE')))
                    return
                end
                attempts = attempts + 1
                if attempts >= 40 and not prolonged then
                    prolonged = true
                    foundation.setHealth('UNHEALTHY', 'CORE_UNAVAILABLE',
                        'Synex Core could not be bound to World; retrying in the background.')
                end
                wait(prolonged and 5000 or 250)
            end
        end)
    end

    local function cleanup(operation, handler, context)
        local _, operationError = foundation.protect(operation, handler, context)
        return operationError == nil
    end

    function application.start()
        stopping = false
        beginBinding()
        return true
    end

    function application.playerDropped(source)
        local context = { traceId = 'world_player_dropped' }
        local completed = cleanup('player_drop.slices',
            function() return slices.remove(source) end, context)
        completed = cleanup('player_drop.presence',
            function() return presence.remove(source) end, context) and completed
        completed = cleanup('player_drop.instances',
            function() return instances.playerDropped(source) end, context) and completed
        if not completed then
            foundation.setHealth('DEGRADED', 'WORLD_PLAYER_CLEANUP_FAILED',
                'One or more World player cleanup stages failed.')
        end
        return completed
    end

    function application.resourceStarted(startedResource)
        if startedResource == resourceName then return end
        if startedResource == coreResource then
            beginBinding()
            return
        end
        local candidate = binding
        if not current(candidate) or candidate.ready ~= true then return end
        createThread(function()
            wait(0)
            if not current(candidate) or candidate.ready ~= true then return end
            local context = {
                caller = resourceName, callerEpoch = candidate.api.ownerEpoch,
                traceId = 'world_resource_started',
            }
            local reconciliation, discoveryError = foundation.protect(
                'resource_start.discovery', function()
                    local report, reportError = bundleLoader.discoverResource(
                        startedResource, context)
                    if not report and (type(reportError) ~= 'table'
                        or reportError.code ~= 'WORLD_DEPENDENCY_MISSING') then
                        return nil, reportError
                    end
                    return bundleLoader.discoverAll(context)
                end, context)
            local mapsReady, mapError = foundation.protect('resource_start.maps', function()
                return reconcileMapHealth(mapRegistry.refresh(), context)
            end, context)
            slices.invalidateAll()
            if not mapsReady then
                foundation.setHealth('DEGRADED', 'MAP_PACKAGE_UNAVAILABLE',
                    'World map package state could not be reconciled.')
                return nil, mapError
            end
            if not reconciliation or #reconciliation.unresolved > 0 then
                foundation.setHealth('DEGRADED', 'WORLD_DEPENDENCY_MISSING',
                    'One or more declared World bundles could not be activated.')
                return nil, discoveryError
            end
            foundation.clearHealth('WORLD_DEPENDENCY_MISSING')
            return reconciliation
        end)
    end

    function application.resourceStopped(stoppedResource)
        if stoppedResource == resourceName then
            stopping = true
            generation = generation + 1
            foundation.setHealth('STOPPING', nil)
            local completed = true
            local cursor
            repeat
                local records, nextCursor = instances.list(cursor or '', 100)
                for _, instance in ipairs(records) do
                    if instance.state ~= 'CLOSED' then
                        completed = cleanup('resource_stop.instance_close', function()
                            return instances.close({ instanceId = instance.instanceId }, {
                                caller = resourceName,
                                callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 1,
                                traceId = 'world_resource_stop',
                            })
                        end, { traceId = 'world_resource_stop' }) and completed
                    end
                end
                cursor = nextCursor
            until cursor == nil
            health.service = 'UNREGISTERED'
            binding, coreRef.value = nil, nil
            return completed
        end
        if stoppedResource == coreResource then
            generation = generation + 1
            binding, coreRef.value = nil, nil
            health.service = 'UNREGISTERED'
            foundation.setHealth('DEGRADED', 'CORE_UNAVAILABLE', 'Synex Core stopped.')
            return true
        end
        local context = { caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 1,
            traceId = 'world_owner_stopped' }
        local bundleReport
        local completed = cleanup('owner_stop.bundles', function()
            local value, operationError = bundleLoader.ownerStopped(
                stoppedResource, nil, context)
            bundleReport = value
            return value, operationError
        end, context)
        completed = cleanup('owner_stop.instances', function()
            return instances.ownerStopped(stoppedResource, 9007199254740991, context)
        end, context) and completed
        completed = cleanup('owner_stop.caller', function()
            return service.removeCaller(stoppedResource)
        end, context) and completed
        completed = cleanup('owner_stop.maps', function()
            return reconcileMapHealth(mapRegistry.refresh(), context)
        end, context) and completed
        completed = cleanup('owner_stop.slices', slices.invalidateAll, context) and completed
        if type(bundleReport) == 'table'
            and (tonumber(bundleReport.dependents) or 0) > 0 then
            foundation.setHealth('DEGRADED', 'WORLD_DEPENDENCY_MISSING',
                'Stopped World ownership deactivated dependent bundles.')
        end
        if not completed then
            foundation.setHealth('DEGRADED', 'WORLD_OWNER_CLEANUP_FAILED',
                'One or more stopped World owner cleanup stages failed.')
        end
        return completed
    end

    return application
end
