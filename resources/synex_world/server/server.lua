local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'
local decodeJson = SynexWorldValidation.createJsonDecoder(json)

local coreRef = {}
local health = {
    state = 'STARTING', reasons = {}, revision = 0,
    startedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    persistence = 'STARTING', service = 'UNREGISTERED',
}

local function utc()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local now = SynexWorldValidation.monotonicClock(GetGameTimer)

local foundation = SynexWorldFoundation.create({
    health = health, encode = json.encode, now = now, utc = utc,
    resourceName = RESOURCE_NAME,
})
local observability = SynexWorldObservability.create({
    coreRef = coreRef, foundation = foundation, resourceName = RESOURCE_NAME,
})

local mapRegistry, stateEngine, doorEngine, slices, instances
local failedDoorRelocks = {}
local registry = SynexWorldRegistry.create({
    onActivated = function(bundle, replaced)
        health.revision = bundle.revision
        if mapRegistry then mapRegistry.refresh() end
        if slices then slices.invalidateAll() end
        observability.event('synex.world.bundle.activated', {
            key = bundle.key, revision = bundle.revision,
            ownerResource = bundle.ownerResource, replaced = replaced == true,
        }, { traceId = 'world_bundle_activated' })
    end,
    onDeactivated = function(bundle, reason)
        local templateKeys = {}
        for _, object in pairs(bundle.objects or {}) do
            if object.kind == 'world_state_definition' and stateEngine then
                stateEngine:purgeRuntime(object.key)
            elseif object.kind == 'door' and doorEngine then
                doorEngine:purgeRuntime(object.key)
            end
            if object.kind == 'instance_template' then
                templateKeys[#templateKeys + 1] = object.key
            end
        end
        if instances and #templateKeys > 0
            and SynexWorldFoundation.isCallable(instances.deactivateTemplates) then
            table.sort(templateKeys)
            local called, report, cleanupError = pcall(instances.deactivateTemplates,
                templateKeys, { caller = RESOURCE_NAME, callerEpoch = 1,
                    traceId = 'world_bundle_deactivated' })
            if not called or not report or (tonumber(report.failures) or 0) > 0
                or (tonumber(report.pending) or 0) > 0 then
                foundation.setHealth('DEGRADED', 'INSTANCE_TEMPLATE_CLEANUP_FAILED',
                    'One or more World instances await fail-safe template cleanup.')
                observability.event('synex.world.instance_template_cleanup_failed', {
                    bundleKey = bundle.key,
                    failures = report and report.failures or 1,
                    pending = report and report.pending or 1,
                    code = type(cleanupError) == 'table' and cleanupError.code or nil,
                }, { traceId = 'world_bundle_deactivated' })
            else
                foundation.clearHealth('INSTANCE_TEMPLATE_CLEANUP_FAILED')
            end
        end
        health.revision = registry and registry.currentRevision() or health.revision
        if mapRegistry then mapRegistry.refresh() end
        if slices then slices.invalidateAll() end
        observability.event('synex.world.bundle.deactivated', {
            key = bundle.key, revision = bundle.revision,
            ownerResource = bundle.ownerResource, reason = reason,
        }, { traceId = 'world_bundle_deactivated' })
    end,
})

mapRegistry = SynexWorldMapRegistry.create({
    registry = registry, getResourceState = GetResourceState,
})
local contextResolver = SynexWorldContext.create({
    registry = registry, mapRegistry = mapRegistry,
})

local function coreMethod(group, method, ...)
    local api = coreRef.value
    local container = type(api) == 'table' and api[group] or nil
    local handler = type(container) == 'table' and container[method] or nil
    if not SynexWorldFoundation.isCallable(handler) then
        return nil, { code = 'CORE_UNAVAILABLE',
            message = 'The Synex Core API is unavailable.', retryable = true }
    end
    return handler(...)
end

local dataPort = {
    null = function() return coreMethod('Database', 'null') end,
    read = function(request) return coreMethod('Database', 'read', request) end,
    write = function(request) return coreMethod('Database', 'write', request) end,
    transaction = function(request, handler)
        return coreMethod('Database', 'transaction', request, handler)
    end,
    maintenance = function(request, handler)
        return coreMethod('Database', 'maintenance', request, handler)
    end,
}
local database = SynexWorldDatabaseAdapter.create({ dataPort = dataPort })
local repository = SynexWorldRepository.create({
    database = database, jsonEncode = json.encode, jsonDecode = decodeJson,
})

local function nextId(namespace)
    return coreMethod('Ids', 'next', namespace)
end
local function getPlayer(source)
    return coreMethod('Players', 'getBySource', source)
end
local function getPosition(source)
    if not SynexWorldValidation.isInteger(source, 1, 65535) then
        return SynexWorldValidation.failure('INVALID_ARGUMENT', 'World player source is invalid.')
    end
    local ped = GetPlayerPed(source)
    if type(ped) ~= 'number' or ped <= 0 then
        return SynexWorldValidation.failure('UNAVAILABLE',
            'Server player position is temporarily unavailable.', true)
    end
    local coords = GetEntityCoords(ped)
    local point = (type(coords) == 'vector3' or type(coords) == 'table')
        and { x = coords.x, y = coords.y, z = coords.z } or nil
    return SynexWorldValidation.vector3(point, 'UNAVAILABLE')
end
local function callContract(name, version, request, options)
    return coreMethod('RPC', 'call', name, version, request, options or {})
end
local function groupCall(method, request, context)
    return coreMethod('Services', 'call', 'synex.groups', '^1.0.0',
        method, request, { traceId = context and context.traceId })
end
local function emit(topic, payload, context)
    return observability.event(topic, payload, context)
end
local function audit(action, targetType, targetId, payload, context)
    return observability.audit(action, targetType, targetId, payload, context)
end

local outbox = SynexWorldOutbox.create({
    database = database,
    publish = function(topic, payload, metadata)
        return coreMethod('Events', 'publishOutbox', topic, payload, metadata)
    end,
    jsonDecode = decodeJson,
})

stateEngine = SynexWorldStateEngine.create({
    repository = repository,
    resolveDefinition = function(key) return registry.get(key, 'world_state_definition') end,
    resolveScope = function(definition, scopeRef)
        if definition.scope == 'instance' then
            local instance = instances and instances.get(scopeRef) or nil
            if not instance or instance.state == 'CLOSED' then return nil end
            if definition.parent then
                local template = registry.get(instance.template.key, 'instance_template')
                local current = template and registry.get(template.baseLocation, 'location') or nil
                local matched = false
                while current do
                    if current.key == definition.parent then matched = true; break end
                    current = current.parent and registry.get(current.parent) or nil
                end
                if not matched then return nil end
            end
            return instance
        end
        local scope = registry.get(scopeRef, definition.scope)
        if not scope then return nil end
        if definition.parent then
            local current, matched = scope, false
            while current do
                if current.key == definition.parent then matched = true; break end
                current = current.parent and registry.get(current.parent) or nil
            end
            if not matched then return nil end
        end
        return scope
    end,
    jsonEncode = json.encode, newId = nextId, nowIso = utc,
    onChanged = function(record)
        observability.increment('state_change_total', {
            persistence = record.persistent and 'persistent' or 'runtime' }, 1)
        if not record.persistent then
            emit('synex.world.state.changed', record,
                { traceId = record.provenance and record.provenance.traceId })
        end
        if slices then slices.stateChanged(record) end
    end,
})
doorEngine = SynexWorldDoorEngine.create({
    repository = repository,
    resolveDefinition = function(key) return registry.get(key, 'door') end,
    newId = nextId, nowIso = utc, schemaVersion = SynexWorldLimits.schemaVersion,
    scheduler = {
        after = function(delay, handler, options)
            return coreMethod('Scheduler', 'after', delay, handler, options)
        end,
        cancel = function(token)
            return coreMethod('Scheduler', 'cancel', token)
        end,
    },
    onSchedulerError = function(failure)
        failedDoorRelocks[failure.key or 'unknown'] = true
        observability.increment('door_auto_relock_failure_total', {
            operation = failure.operation,
        }, 1)
        foundation.setHealth('DEGRADED', 'DOOR_AUTO_RELOCK_FAILED',
            'A scheduled World door relock requires operator attention.')
        audit('world.door_auto_relock_failed', 'world_door', failure.key or 'unknown',
            { code = failure.code, operation = failure.operation },
            { traceId = 'world_door_auto_relock' })
    end,
    onChanged = function(record)
        observability.increment('door_state_change_total', {
            persistence = record.persistent and 'persistent' or 'runtime' }, 1)
        if record.provenance
            and record.provenance.reasonCode == 'door.auto_relock' then
            failedDoorRelocks[record.key] = nil
            if next(failedDoorRelocks) == nil then
                foundation.clearHealth('DOOR_AUTO_RELOCK_FAILED')
            end
        end
        if slices then slices.doorChanged(record.key, record) end
        if not record.persistent then
            emit('synex.world.door.state_changed', record,
                { traceId = record.provenance and record.provenance.traceId })
        end
    end,
})

instances = SynexWorldInstances.create({
    registry = registry, mapRegistry = mapRegistry,
    callContract = callContract, getPlayer = getPlayer,
    nextId = nextId, now = now, utc = utc, emit = emit, audit = audit,
    triggerClient = function(source, event, payload) TriggerClientEvent(event, source, payload) end,
    onClosed = function(instanceId, _, context)
        local cleaned, cleanupError = stateEngine:purgeScope('instance', instanceId)
        if not cleaned then return nil, cleanupError end
        observability.increment('instance_state_cleanup_total', {},
            cleaned.runtimeRemoved + cleaned.persistentRemoved)
        if slices then slices.invalidateAll() end
        audit('world.instance_state_cleaned', 'world_instance', instanceId,
            cleaned, context)
        return true
    end,
    onCleanupError = function(failure)
        observability.increment('instance_state_cleanup_failure_total', {
            operation = failure.operation,
        }, 1)
        foundation.setHealth('DEGRADED', 'INSTANCE_STATE_CLEANUP_FAILED',
            'Instance-scoped World state cleanup is pending bounded retry.')
        audit('world.instance_state_cleanup_failed', 'world_instance',
            failure.instanceId, { code = failure.code },
            { traceId = 'world_instance_cleanup' })
    end,
})
local access = SynexWorldAccess.create({
    registry = registry, mapRegistry = mapRegistry, getPlayer = getPlayer,
    groupCapability = function(request, context)
        return groupCall('capabilities_check', request, context)
    end,
    groupExplain = function(request, context)
        return groupCall('capabilities_explain', request, context)
    end,
    getState = function(request) return stateEngine:get(request) end,
    getDoorState = function(key) return doorEngine:get({ key = key }) end,
    getInstanceForSource = function(source) return instances.getForSource(source) end,
})
local portals = SynexWorldPortals.create({
    registry = registry, mapRegistry = mapRegistry,
    contextResolver = contextResolver, access = access,
    instances = instances, getPlayer = getPlayer, getPlayerPosition = getPosition,
    nextId = nextId, now = now,
    triggerClient = function(source, event, payload) TriggerClientEvent(event, source, payload) end,
    emit = emit, audit = audit,
    expectTransition = function(grant, portal, context)
        local expectation, expectationError = coreMethod('Services', 'call',
            'synex.security', '^1.0.0', 'registerExpectation', {
                namespace = 'synex.world',
                kind = 'movement.teleport',
                subject = {
                    sessionId = grant.sessionId,
                    source = grant.source,
                    sourceGeneration = grant.sourceGeneration,
                    characterId = grant.characterId,
                },
                    constraintsJson = json.encode({
                        categories = { 'movement' },
                        detectors = { 'synex.security.movement' },
                        codes = { 'MOVEMENT_TELEPORT_ANOMALY' },
                        correlationKeys = { 'movement-teleport' },
                        maximumSeverity = 'HIGH',
                    }),
                reason = 'world.portal.transition',
                ttlMs = 8000,
            }, { traceId = context and context.traceId, timeoutMs = 1000 })
        if not expectation then
            observability.increment('security_expectation_failures_total', {
                code = type(expectationError) == 'table'
                    and expectationError.code or 'UNAVAILABLE',
            }, 1)
            return false
        end
        return true
    end,
})
local presence = SynexWorldPresence.create({
    now = now,
    emit = function(topic, payload, context)
        local kind, direction = topic:match('^synex%.world%.([a-z_]+)%.([a-z_]+)$')
        if kind and direction then
            observability.increment('context_change_total', {
                kind = kind, direction = direction,
            }, 1)
        end
        return emit(topic, payload, context)
    end,
})
slices = SynexWorldSlices.create({
    registry = registry, contextResolver = contextResolver, mapRegistry = mapRegistry,
    getDoorState = function(key) return doorEngine:get({ key = key }) end,
    getState = function(request) return stateEngine:get(request) end,
    getPlayers = GetPlayers, getPlayer = getPlayer, getPosition = getPosition,
    getInstance = function(source) return instances.getForSource(source) end,
    triggerClient = function(source, event, payload) TriggerClientEvent(event, source, payload) end,
    encode = json.encode, presence = presence,
    observe = function(kind, bytes, objects)
        observability.increment('client_slice_updates', { kind = kind }, 1)
        observability.observe('client_slice_bytes', {}, bytes)
        observability.observe('spatial_candidate_count', { operation = 'slice' }, objects)
    end,
})

local bundleLoader = SynexWorldBundleLoader.create({
    registry = registry,
    getRuntimeSnapshot = function() return coreMethod('Runtime', 'getSnapshot') end,
    checkCapability = function(resource, capability, operation)
        return coreMethod('Capabilities', 'checkResource', resource, capability, operation)
    end,
    loadResourceFile = LoadResourceFile, decode = decodeJson,
    getResourceState = GetResourceState, foundation = foundation,
    observability = observability,
})
local diagnostics = SynexWorldDiagnostics.create({
    foundation = foundation, registry = registry, mapRegistry = mapRegistry,
    instances = instances, slices = slices, outbox = outbox, database = database,
    getResourceState = GetResourceState,
    resolveEntity = function(reference)
        return callContract('synex.entities.get', '1.0.0', {
            entityId = reference.entityId, generation = reference.generation,
        }, { traceId = 'world_doctor_entity' })
    end,
    resolveBucket = function(reference)
        return callContract('synex.entities.bucket.get', '1.0.0', {
            bucket = { bucket = reference.bucket, generation = reference.generation },
        }, { traceId = 'world_doctor_bucket' })
    end,
})
local service = SynexWorldService.create({
    foundation = foundation, registry = registry, contextResolver = contextResolver,
    mapRegistry = mapRegistry, stateEngine = stateEngine, doorEngine = doorEngine,
    access = access, portals = portals, instances = instances,
    bundleLoader = bundleLoader, diagnostics = diagnostics,
    observability = observability, getPlayer = getPlayer,
    getPosition = getPosition, now = now,
})
local controlProvider = SynexWorldControlProvider.create({
    foundation = foundation, registry = registry, mapRegistry = mapRegistry,
    instances = instances, diagnostics = diagnostics, contextResolver = contextResolver,
    project = service.projectObject,
})
local application = SynexWorldApplication.create({
    resourceName = RESOURCE_NAME, coreResource = CORE_RESOURCE, coreRange = CORE_RANGE,
    coreRef = coreRef, foundation = foundation, health = health,
    service = service, controlProvider = controlProvider, bundleLoader = bundleLoader,
    mapRegistry = mapRegistry, slices = slices, presence = presence,
    instances = instances, portals = portals, outbox = outbox,
    diagnostics = diagnostics, observability = observability, registry = registry,
    loadResourceFile = LoadResourceFile, decode = decodeJson,
    acquireApi = function(range) return exports[CORE_RESOURCE]:GetAPI(range) end,
    wait = Wait, createThread = CreateThread,
})

CreateThread(function()
    local started, startError = foundation.protect('application.start', application.start,
        { traceId = 'world_start' })
    if started == nil and startError then
        foundation.setHealth('UNHEALTHY', 'WORLD_BOOTSTRAP_FAILED',
            'World bootstrap failed unexpectedly.')
    end
end)

AddEventHandler('playerDropped', function()
    application.playerDropped(source)
end)
AddEventHandler('onResourceStart', function(resource)
    application.resourceStarted(resource)
end)
AddEventHandler('onResourceStop', function(resource)
    application.resourceStopped(resource)
end)
