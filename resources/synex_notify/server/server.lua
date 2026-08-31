local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local BRIDGE_RESOURCE = 'synex_bridge'
local coreRef = {}
local now = SynexNotifyFoundation.monotonicClock(GetGameTimer)
local utc = function() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

local function coreMethod(group, method, ...)
    local api = coreRef.value
    local namespace = type(api) == 'table' and api[group] or nil
    local handler = type(namespace) == 'table' and namespace[method] or nil
    if not SynexNotifyFoundation.isCallable(handler) then
        return SynexNotifyValidation.failure('NOTIFY_UNAVAILABLE',
            'Synex Core is unavailable.', true)
    end
    return handler(...)
end

local observability = SynexNotifyObservability.create({
    foundation = SynexNotifyFoundation,
    coreRef = coreRef,
    now = now,
})
local registry = SynexNotifyRegistry.create({
    foundation = SynexNotifyFoundation,
    now = now,
    utc = utc,
    nextId = function(namespace) return coreMethod('Ids', 'next', namespace) end,
    getSession = function(source) return coreMethod('Players', 'getBySource', source) end,
    checkPrivilege = function(resource, capability, operation)
        return coreMethod('Capabilities', 'checkResource', resource, capability, operation)
    end,
    isSystemPrincipal = function(resource)
        return resource == CORE_RESOURCE
    end,
    triggerClient = function(source, event, payload)
        TriggerClientEvent(event, source, payload)
        return true
    end,
    getPlayers = GetPlayers,
    getResourceState = GetResourceState,
    observability = observability,
})
local application
local service = SynexNotifyService.create({
    registry = registry,
    foundation = SynexNotifyFoundation,
    observability = observability,
    resolveOwnerEpoch = function(owner, callerEpoch)
        if application == nil then
            return SynexNotifyValidation.failure('NOTIFY_UNAVAILABLE',
                'The notification owner authority is unavailable.', true)
        end
        return application.resolveOwnerEpoch(owner, callerEpoch)
    end,
})
local controlProvider = SynexNotifyControlProvider.create({
    registry = registry,
    now = now,
    getResourceState = GetResourceState,
})
application = SynexNotifyApplication.create({
    resourceName = RESOURCE_NAME,
    coreResource = CORE_RESOURCE,
    bridgeResource = BRIDGE_RESOURCE,
    uiResource = 'synex_ui',
    coreRange = '^1.0.0',
    coreRef = coreRef,
    registry = registry,
    service = service,
    controlProvider = controlProvider,
    observability = observability,
    acquireCore = function(range) return exports[CORE_RESOURCE]:GetAPI(range) end,
    registerBridgeAdapter = function(definition, implementation)
        return exports[BRIDGE_RESOURCE]:RegisterCompatibilityAdapter(
            definition, implementation)
    end,
    loadResourceFile = LoadResourceFile,
    decode = json.decode,
    wait = Wait,
    createThread = CreateThread,
    getResourceState = GetResourceState,
})

exports('GetAPI', function(versionRange)
    local value, apiError = application.getAPI(versionRange)
    if value == nil then return false, apiError end
    return value, apiError
end)

CreateThread(function()
    local started, startError = SynexNotifyFoundation.protect(application.start)
    if not started then
        print(('[%s] Notify bootstrap failed: %s'):format(RESOURCE_NAME,
            type(startError) == 'table' and startError.code or 'NOTIFY_UNAVAILABLE'))
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
