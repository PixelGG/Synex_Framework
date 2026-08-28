local RESOURCE = GetCurrentResourceName()
local V = SynexInteractValidation

local coreApi, coreError = exports['synex_core']:GetAPI('^1.0.0')
if not coreApi then
    error(('synex_interact: synex_core unavailable: %s'):format(coreError and coreError.code or 'unknown'))
end

local function coreMethod(group, method, ...)
    local container = coreApi[group]
    local fn = type(container) == 'table' and container[method] or nil
    if type(fn) ~= 'function' then
        return V.failure('INTERACT_CORE_UNAVAILABLE', ('Core method %s.%s is unavailable.'):format(group, method), true)
    end
    return fn(...)
end

local core = {
    playerBySource = function(source) return coreMethod('Players', 'getBySource', source) end,
    serviceCall = function(name, range, method, request, options)
        return coreMethod('Services', 'call', name, range, method, request, options or {})
    end,
    rpcCall = function(name, version, request, options)
        return coreMethod('RPC', 'call', name, version, request, options or {})
    end,
    checkResource = function(resource, capability, operation)
        return coreMethod('Capabilities', 'checkResource', resource, capability, operation)
    end,
    publish = function(topic, payload, context)
        return coreMethod('Events', 'publish', topic, payload, context or {})
    end,
}

local function nextId(namespace)
    return coreMethod('Ids', 'next', namespace)
end

local function monotonic()
    return GetGameTimer()
end

local function getPosition(source)
    if not V.isInteger(source, 1, 65535) then
        return V.failure('INTERACT_INVALID_ARGUMENT', 'Player source is invalid.')
    end
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then
        return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Server player position is unavailable.', true)
    end
    local coords = GetEntityCoords(ped)
    return V.vector3({ x = coords.x, y = coords.y, z = coords.z })
end

local function resolveEntityPosition(entityRef, traceId)
    if type(entityRef) ~= 'table' or type(entityRef.entityId) ~= 'string'
        or not V.isInteger(entityRef.generation, 1, 9007199254740991) then
        return V.failure('INTERACT_INVALID_ARGUMENT', 'EntityRef is invalid.')
    end
    local record, recordError = core.rpcCall('synex.entities.get', '1.0.0', {
        entityId = entityRef.entityId,
        generation = entityRef.generation,
    }, { traceId = traceId })
    if not record then return nil, recordError end
    local netId = record.netId or record.networkId
    if not V.isInteger(netId, 1, 65535) then
        return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Entity has no active network identity.', true)
    end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity <= 0 or not DoesEntityExist(entity) then
        return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Entity is not materialized on this server.', true)
    end
    local coords = GetEntityCoords(entity)
    return V.vector3({ x = coords.x, y = coords.y, z = coords.z })
end

local function mapDomainFailure(operationError)
    return V.failure('INTERACT_ACTION_FAILED', 'Interaction domain action failed.',
        type(operationError) == 'table' and operationError.retryable == true,
        type(operationError) == 'table' and { domainCode = operationError.code } or nil)
end

local registry = SynexInteractRegistry.create()
local leases = SynexInteractLeaseEngine.create({ now = monotonic, nextId = nextId })
local graphEngine = SynexInteractActionGraph.create({
    wait = Wait,
    handlers = {
        call = function(node, context)
            if type(node.service) ~= 'string' or type(node.method) ~= 'string'
                or type(node.capability) ~= 'string' then
                return V.failure('INTERACT_GRAPH_INVALID',
                    'Call node requires service, method, and delegated capability.')
            end
            local owner = context.object and context.object.ownerResource or nil
            local delegated, delegationError = core.checkResource(owner, node.capability,
                ('synex.interact.graph:%s:%s'):format(context.object.key, context.action.key))
            if not delegated then
                return V.failure('INTERACT_ACTION_FAILED',
                    'Interaction owner is not authorized for the delegated domain action.', false,
                    type(delegationError) == 'table' and { coreCode = delegationError.code } or nil)
            end
            local request = V.copy(node.request or {}) or {}
            request.interaction = {
                source = context.source,
                objectKey = context.object.key,
                actionKey = context.action.key,
                leaseId = context.lease.id,
                payload = V.copy(context.payload or {}),
            }
            local result, operationError = core.serviceCall(node.service, node.version or '^1.0.0',
                node.method, request, { traceId = context.traceId })
            if not result then return mapDomainFailure(operationError) end
            return result
        end,
        emit = function(node, context)
            if type(node.topic) ~= 'string' or #node.topic < 3 or #node.topic > 128 then
                return V.failure('INTERACT_GRAPH_INVALID', 'Emit node topic is invalid.')
            end
            local published, operationError = core.publish(node.topic, {
                source = context.source,
                ownerResource = context.object.ownerResource,
                objectKey = context.object.key,
                actionKey = context.action.key,
                leaseId = context.lease.id,
                payload = V.copy(node.payload or context.payload or {}),
            }, { traceId = context.traceId })
            if not published then return mapDomainFailure(operationError) end
            return true
        end,
        branch = function(node, context)
            if type(node.field) ~= 'string' or #node.field > 64 then
                return V.failure('INTERACT_GRAPH_INVALID', 'Branch field is invalid.')
            end
            local value = type(context.lastResult) == 'table' and context.lastResult[node.field] or nil
            return value == node.equals
        end,
    },
})

local service = SynexInteractService.create({
    registry = registry,
    leases = leases,
    graphs = graphEngine,
    core = core,
    getPosition = getPosition,
    resolveEntityPosition = resolveEntityPosition,
    now = monotonic,
})

local function metric(kind, name, labels, value)
    local metrics = coreApi.Metrics
    local fn = type(metrics) == 'table' and metrics[kind] or nil
    if type(fn) == 'function' then
        pcall(fn, 'synex_interact_' .. name, labels or {}, value)
    end
end

local function loadContracts()
    local encoded = LoadResourceFile(RESOURCE, 'contracts/interact.contracts.json')
    if type(encoded) ~= 'string' or #encoded < 2 then
        return V.failure('INTERACT_CORE_UNAVAILABLE', 'Interaction contract catalog is unavailable.')
    end
    local ok, collection = pcall(json.decode, encoded)
    if not ok or type(collection) ~= 'table' or type(collection.contracts) ~= 'table' then
        return V.failure('INTERACT_CORE_UNAVAILABLE', 'Interaction contract catalog is invalid.')
    end
    return collection.contracts
end

local networkHandlers = {
    ['synex.interact.candidates'] = function(request, context)
        if type(context) ~= 'table' or not V.isInteger(context.source, 1, 65535) then
            return V.failure('INTERACT_SESSION_INACTIVE', 'Interaction network context is unavailable.', true)
        end
        local value, operationError = service.candidates(context.source, request, context.traceId)
        metric('increment', 'candidate_requests_total', { result = value and 'success' or 'failure' }, 1)
        return value, operationError
    end,
    ['synex.interact.begin'] = function(request, context)
        if type(context) ~= 'table' or not V.isInteger(context.source, 1, 65535) then
            return V.failure('INTERACT_SESSION_INACTIVE', 'Interaction network context is unavailable.', true)
        end
        local value, operationError = service.begin(context.source, request, context.traceId)
        metric('increment', 'lease_requests_total', { result = value and 'success' or 'failure' }, 1)
        return value, operationError
    end,
    ['synex.interact.execute'] = function(request, context)
        if type(context) ~= 'table' or not V.isInteger(context.source, 1, 65535) then
            return V.failure('INTERACT_SESSION_INACTIVE', 'Interaction network context is unavailable.', true)
        end
        local value, operationError = service.execute(context.source, request, context.traceId)
        metric('increment', 'executions_total', { result = value and 'success' or 'failure' }, 1)
        return value, operationError
    end,
}

local contracts, contractsError = loadContracts()
if not contracts then error(contractsError.message) end
for _, contract in ipairs(contracts) do
    local handler = networkHandlers[contract.name]
    if type(handler) ~= 'function' then
        error(('synex_interact: missing network handler for %s'):format(tostring(contract.name)))
    end
    local _, registrationError = coreApi.RPC.registerNetwork(contract, handler)
    if registrationError then
        error(('synex_interact: failed to register %s: %s'):format(contract.name,
            registrationError.code or registrationError.message or 'unknown'))
    end
end

local serviceToken, serviceError = coreApi.Services.provide({
    name = 'synex.interact',
    version = '1.0.0',
    capabilities = {
        register = 'synex.interact.register',
        unregister = 'synex.interact.register',
        health = 'synex.interact.diagnostics.read',
    },
    methods = {
        register = function(request, context)
            if type(request) ~= 'table' or type(request.definitions) ~= 'table'
                or type(context) ~= 'table' or type(context.caller) ~= 'string' then
                return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction registration request is invalid.')
            end
            local result, operationError = service.register(context.caller, request.definitions, context.traceId)
            metric('increment', 'definitions_registered_total', { result = result and 'success' or 'failure' },
                result and result.count or 1)
            return result, operationError
        end,
        unregister = function(request, context)
            if type(request) ~= 'table' or next(request) ~= nil
                or type(context) ~= 'table' or type(context.caller) ~= 'string' then
                return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction unregister request is invalid.')
            end
            return service.unregisterOwner(context.caller)
        end,
        health = function(request)
            if type(request) ~= 'table' or next(request) ~= nil then
                return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction health request is invalid.')
            end
            return service.health()
        end,
    },
})
if not serviceToken then
    error(('synex_interact: service registration failed: %s'):format(serviceError and serviceError.code or 'unknown'))
end

local function authorizedOwner(owner)
    if type(owner) ~= 'string' or owner == '' then
        return V.failure('INTERACT_INVALID_OWNER', 'Interaction API requires an invoking resource.')
    end
    local allowed, operationError = coreApi.Capabilities.checkResource(owner,
        'synex.interact.register', 'synex.interact.register')
    if not allowed then
        return V.failure('INTERACT_ACCESS_DENIED', 'Resource is not permitted to register interactions.', false,
            type(operationError) == 'table' and { coreCode = operationError.code } or nil)
    end
    return owner
end

exports('GetAPI', function(versionRange)
    if versionRange ~= nil and versionRange ~= '^1.0.0' and versionRange ~= '1.0.0' then
        return V.failure('INTERACT_VERSION_UNSUPPORTED', 'Requested interaction API version is unsupported.')
    end
    local owner, ownerError = authorizedOwner(GetInvokingResource())
    if not owner then return nil, ownerError end
    return {
        version = '1.0.0',
        register = function(definitions)
            return service.register(owner, definitions, 'interact_export_register_' .. owner)
        end,
        unregister = function()
            return service.unregisterOwner(owner)
        end,
        getHealth = function()
            return service.health()
        end,
    }
end)

AddEventHandler('playerDropped', function()
    leases.releaseSource(source)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE then return end
    service.unregisterOwner(resource)
end)

metric('gauge', 'health', { state = 'ready' }, 1)
print(('[%s] READY: Context Sensor / Intent Engine / Smart Object registry / Interaction Leases / Action Graph foundation loaded.'):format(RESOURCE))
