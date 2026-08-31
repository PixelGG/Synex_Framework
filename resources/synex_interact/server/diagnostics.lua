SynexInteractDiagnostics = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

local dependencyReasons = {
    synex_core = 'CORE_RUNTIME_UNAVAILABLE',
    synex_entities = 'ENTITY_PROVIDER_UNAVAILABLE',
    synex_world = 'WORLD_PROVIDER_UNAVAILABLE',
    synex_ui = 'UI_PROVIDER_UNAVAILABLE',
}

function SynexInteractDiagnostics.create(options)
    options = options or {}
    local registry = assert(options.registry, 'diagnostics requires registry')
    local authority = assert(options.authority, 'diagnostics requires authority')
    local slots = assert(options.slots, 'diagnostics requires slots')
    local sessions = assert(options.sessions, 'diagnostics requires sessions')
    local graph = assert(options.graph, 'diagnostics requires graph runtime')
    local locks = assert(options.locks, 'diagnostics requires actor locks')
    local observability = assert(options.observability, 'diagnostics requires observability')
    local getResourceState = options.getResourceState or GetResourceState
    local now = options.now or GetGameTimer
    local getBundleFailures = options.getBundleFailures or function()
        return { items = {}, total = 0, hasMore = false, truncated = false }, nil
    end
    local resolveWorldReference = options.resolveWorldReference
    if not Validation.isCallable(resolveWorldReference)
        and Validation.isCallable(options.resolveWorldAnchor) then
        resolveWorldReference = function(kind, key)
            if kind ~= 'anchor' then return nil end
            return options.resolveWorldAnchor(key)
        end
    end
    local diagnostics = {}

    local function resourceState(resource)
        local ok, state = pcall(getResourceState, resource)
        return ok and type(state) == 'string' and state or 'unknown'
    end

    function diagnostics.health()
        local reasons, dependencies, seen = {}, {}, {}
        local severity = 'READY'
        local function reason(code, unhealthy)
            if seen[code] then return end
            seen[code], reasons[#reasons + 1] = true, code
            if unhealthy then severity = 'UNHEALTHY'
            elseif severity == 'READY' then severity = 'DEGRADED' end
        end
        for _, resource in ipairs({ 'synex_core', 'synex_entities', 'synex_world', 'synex_ui' }) do
            local state = resourceState(resource)
            dependencies[resource] = state
            if state ~= 'started' then
                reason(dependencyReasons[resource], resource ~= 'synex_ui')
            end
        end
        local snapshot = authority.snapshot()
        if snapshot.maximumActiveLeases > 0
            and snapshot.activeLeases >= math.floor(snapshot.maximumActiveLeases * 0.9) then
            reason('LEASE_PRESSURE', false)
        end
        local signals = type(observability.healthSignals) == 'function'
            and observability.healthSignals() or {}
        if signals.graphExecutorFailure then reason('GRAPH_EXECUTOR_FAILURE', true) end
        if signals.providerFailure or signals.slowEvaluator then
            reason('PROVIDER_FAILURE', false)
        end
        if signals.sensorDegraded then reason('SENSOR_DEGRADED', false) end
        table.sort(reasons)
        return { status = severity, state = severity,
            reasons = reasons, dependencies = dependencies }, nil
    end

    function diagnostics.summary()
        local result = registry.snapshot()
        local lease, slot, session, execution, actorLock = authority.snapshot(),
            slots.snapshot(), sessions.snapshot(), graph.snapshot(), locks.snapshot()
        result.runtimeOnly, result.persistence = true, 'none'
        result.activeLeases = lease.activeLeases
        result.activeSessions = session.active
        result.activeExecutions = execution.active
        result.slotCount, result.reservations = slot.slots, slot.reservations
        result.actorLocks = actorLock.active
        result.health = diagnostics.health()
        return result, nil
    end

    function diagnostics.doctor(request)
        request = request or {}
        if not Validation.exactObject(request, {}, { 'limit' })
            or request.limit ~= nil and not Validation.isInteger(
                request.limit, 1, Limits.maximumDoctorFindings) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction doctor request is invalid.')
        end
        local maximum, findings, scanTruncated = request.limit or 100, {}, false
        local function add(code, severity, message, subject)
            if #findings >= maximum then scanTruncated = true; return end
            findings[#findings + 1] = {
                code = code, title = code, severity = severity,
                message = message, summary = message, subjectRef = subject,
            }
        end
        local health = diagnostics.health()
        for _, reason in ipairs(health.reasons) do
            local severity = (reason == 'UI_PROVIDER_UNAVAILABLE'
                or reason == 'LEASE_PRESSURE' or reason == 'PROVIDER_FAILURE'
                or reason == 'SENSOR_DEGRADED') and 'WARNING' or 'ERROR'
            add(reason, severity,
                'A required interaction runtime dependency or signal is not ready.')
        end

        local registrySnapshot = registry.snapshot()
        if registrySnapshot.bundles == 0 then
            add('INTERACT_NO_BUNDLES', 'INFO', 'No interaction bundles are active.')
        end
        if registrySnapshot.providers == 0 then
            add('INTERACT_NO_DYNAMIC_PROVIDERS', 'INFO',
                'No resource-owned dynamic candidate providers are active.')
        end

        local failurePage
        if Validation.isCallable(getBundleFailures) then
            local called, value = pcall(getBundleFailures, maximum)
            if called and type(value) == 'table' then failurePage = value end
        end
        if failurePage then
            scanTruncated = scanTruncated or failurePage.hasMore == true
                or failurePage.truncated == true
            for _, failure in ipairs(failurePage.items or {}) do
                add(failure.code or 'INTERACT_BUNDLE_REJECTED', 'ERROR',
                    'A declared Interaction bundle failed validation or atomic activation.',
                    tostring(failure.resource or 'unknown') .. ':'
                        .. tostring(failure.path or '<manifest>'))
            end
        end

        local bundlePage = registry.list('bundles', nil, 100)
        if bundlePage then
            scanTruncated = scanTruncated or bundlePage.hasMore == true
            for _, bundle in ipairs(bundlePage.items) do
                if resourceState(bundle.ownerResource) ~= 'started' then
                    add('INTERACT_RESOURCE_OWNER_LEAK', 'ERROR',
                        'An interaction bundle is retained for a stopped owner.', bundle.key)
                end
            end
        end
        local providerPage = registry.list('providers', nil, 100)
        if providerPage then
            scanTruncated = scanTruncated or providerPage.hasMore == true
            for _, provider in ipairs(providerPage.items) do
                if resourceState(provider.ownerResource) ~= 'started' then
                    add('INTERACT_RESOURCE_OWNER_LEAK', 'ERROR',
                        'An interaction provider is retained for a stopped owner.', provider.key)
                end
            end
        end
        local objectPage = registry.list('smart_objects', nil, 100)
        if objectPage then
            scanTruncated = scanTruncated or objectPage.hasMore == true
            for _, object in ipairs(objectPage.items) do
                if object.binding == 'dynamic' then
                    local definition = registry.inspect('smart_object', object.key)
                    local providerKey = definition and definition.binding
                        and definition.binding.provider
                    if providerKey and not registry.getProvider(providerKey) then
                        add('INTERACT_PROVIDER_MISSING', 'ERROR',
                            'A dynamic Smart Object provider is unavailable.', object.key)
                    end
                elseif (object.binding == 'worldAnchor' or object.binding == 'worldRef')
                    and resourceState('synex_world') == 'started'
                    and Validation.isCallable(resolveWorldReference) then
                    local definition = registry.inspect('smart_object', object.key)
                    local binding = definition and definition.binding or nil
                    local kind = binding and (binding.kind or 'anchor') or nil
                    local key = binding and binding.key or nil
                    local called, worldObject = pcall(resolveWorldReference, kind, key)
                    if not called or type(worldObject) ~= 'table'
                        or worldObject.kind ~= kind or worldObject.key ~= key then
                        add('INTERACT_WORLD_REFERENCE_MISSING', 'ERROR',
                            'A Smart Object references an unavailable World object.', object.key)
                    end
                end
            end
        end
        local graphPage = registry.list('graphs', nil, 100)
        if graphPage then
            scanTruncated = scanTruncated or graphPage.hasMore == true
            for _, graphItem in ipairs(graphPage.items) do
                local definition = registry.inspect('graph', graphItem.key)
                if definition then
                    for _, nodeKey in ipairs(definition.nodeOrder or {}) do
                        local node = definition.nodes[nodeKey]
                        if node.adapter and not registry.getAdapter(node.adapter) then
                            add('INTERACT_ACTION_ADAPTER_MISSING', 'ERROR',
                                'An Action Graph adapter is unavailable.', graphItem.key)
                            break
                        end
                    end
                end
            end
        end

        local slotSnapshot = slots.snapshot()
        if slotSnapshot.slots > 0
            and slotSnapshot.reserved + slotSnapshot.occupied + slotSnapshot.disabled
                >= slotSnapshot.slots then
            add('INTERACT_SLOT_PRESSURE', 'WARNING',
                'Every configured interaction slot is reserved, occupied or disabled.')
        end

        local sessionPage, executionPage = sessions.list(nil, 100), graph.list(nil, 100)
        if sessionPage and executionPage then
            scanTruncated = scanTruncated or sessionPage.hasMore == true
                or executionPage.hasMore == true
            if not sessionPage.hasMore and not executionPage.hasMore then
                local executionSessions, knownSessions = {}, {}
                for _, execution in ipairs(executionPage.items) do
                    executionSessions[execution.sessionId] = true
                end
                for _, session in ipairs(sessionPage.items) do
                    knownSessions[session.sessionId] = true
                    if session.state == 'RUNNING' and not executionSessions[session.sessionId] then
                        add('INTERACT_ORPHAN_SESSION', 'ERROR',
                            'A running interaction session has no graph execution.')
                    end
                    if resourceState(session.ownerResource) ~= 'started' then
                        add('INTERACT_RESOURCE_OWNER_LEAK', 'ERROR',
                        'An interaction session is retained for a stopped owner.')
                    end
                end
                local reservationPage = slots.listReservations(nil, 100)
                if reservationPage then
                    scanTruncated = scanTruncated or reservationPage.hasMore == true
                    if not reservationPage.hasMore then
                        for _, reservation in ipairs(reservationPage.items) do
                            if not knownSessions[reservation.sessionId] then
                                add('INTERACT_ORPHAN_RESERVATION', 'ERROR',
                                    'A slot reservation has no interaction session.')
                            elseif reservation.expiresAt <= now() then
                                add('INTERACT_STALE_RESERVATION', 'WARNING',
                                    'An expired slot reservation awaits bounded cleanup.')
                            end
                        end
                    end
                end
            end
        end
        local leasePage = authority.listLeases(nil, 100)
        if leasePage then
            scanTruncated = scanTruncated or leasePage.hasMore == true
            for _, lease in ipairs(leasePage.items) do
                if lease.expiresAt <= now() then
                    add('INTERACT_STALE_LEASE', 'WARNING',
                        'An expired interaction lease awaits bounded cleanup.')
                end
            end
        end
        local graphSnapshot, lockSnapshot = graph.snapshot(), locks.snapshot()
        if graphSnapshot.active == 0 and lockSnapshot.active > 0 then
            add('INTERACT_ACTOR_LOCK_LEAK', 'ERROR',
                'Actor locks remain while no Action Graph execution is active.')
        end

        local observation = observability.snapshot()
        if observation.denialRecords >= Limits.maximumDenialRecords then
            add('INTERACT_DENIAL_RING_FULL', 'INFO',
                'The bounded denial history has reached its retention limit.')
        end
        if observation.traceFrames >= observation.traceCapacity then
            add('INTERACT_TRACE_RING_FULL', 'INFO',
                'The development trace recorder is retaining its maximum bounded frame count.')
        end
        if observation.signals and observation.signals.slowEvaluator then
            add('INTERACT_SLOW_EVALUATOR', 'WARNING',
                'A condition evaluator exceeded its configured duration budget.')
        end
        if observation.signals and observation.signals.providerFailure then
            add('INTERACT_PROVIDER_FAILURE', 'WARNING',
                'A dynamic provider failed or exceeded its configured duration budget.')
        end
        if observation.clientSignals and observation.clientSignals.sensorDegraded then
            add('INTERACT_CLIENT_SENSOR_ADVISORY', 'INFO',
                'A client reported recent interaction transport failures; server health is unchanged.')
        end
        if observation.clientSignals and observation.clientSignals.providerFailure then
            add('INTERACT_CLIENT_PROVIDER_ADVISORY', 'INFO',
                'A client reported recent provider timeouts; server health is unchanged.')
        end
        if scanTruncated then
            add('INTERACT_DOCTOR_SCAN_TRUNCATED', 'INFO',
                'The bounded doctor scan has more runtime records than this pass inspected.')
        end

        local status = health.status
        for _, finding in ipairs(findings) do
            if finding.severity == 'ERROR' then status = 'UNHEALTHY'; break end
            if finding.severity == 'WARNING' and status == 'READY' then status = 'DEGRADED' end
        end
        return { status = status, findings = findings,
            hasMore = scanTruncated, truncated = scanTruncated }, nil
    end
    return diagnostics
end
