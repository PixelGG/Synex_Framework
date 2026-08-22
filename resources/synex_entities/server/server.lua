local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'
local SERVICE_NAME = 'synex.entities'
local SERVICE_VERSION = '1.0.0'

local config = {
    bucketCleanupTimeoutMs = 5000,
    bucketMin = math.max(1, math.min(GetConvarInt('synex_entities_bucket_min', 1000), 2147483647)),
    deleteTimeoutMs = 1000,
    driftIntervalMs = math.max(10000, math.min(
        GetConvarInt('synex_entities_drift_interval_ms', 60000),
        3600000
    )),
    driftScanLimit = math.max(16, math.min(
        GetConvarInt('synex_entities_drift_scan_limit', 512),
        5000
    )),
    maxBucketPlayers = math.max(1, math.min(GetConvarInt('synex_entities_max_bucket_players', 256), 2048)),
    maxBuckets = math.max(1, math.min(GetConvarInt('synex_entities_max_buckets', 1024), 10000)),
    maxEntities = math.max(1, math.min(GetConvarInt('synex_entities_max_entities', 4096), 20000)),
    rehydrateLimit = math.max(1, math.min(GetConvarInt('synex_entities_rehydrate_limit', 512), 5000)),
    spawnTimeoutMs = 2500,
    waitStepMs = 25,
}
config.bucketMax = math.max(
    config.bucketMin,
    math.min(GetConvarInt('synex_entities_bucket_max', 999999), 2147483647)
)
config.maxOwnerEntities = math.max(
    1,
    math.min(GetConvarInt('synex_entities_max_owner_entities', 1024), config.maxEntities)
)
config.maxOwnerBuckets = math.max(
    1,
    math.min(GetConvarInt('synex_entities_max_owner_buckets', 128), config.maxBuckets)
)
config.maxBucketEntities = math.max(
    1,
    math.min(GetConvarInt('synex_entities_max_bucket_entities', 512), config.maxEntities)
)

local health = {
    state = 'STARTING',
    reason = 'Bootstrap pending',
    onesync = GetConvar('onesync', 'off'),
    persistence = 'UNKNOWN',
    service = 'UNREGISTERED',
}

local ports = {
    createObjectNoOffset = CreateObjectNoOffset,
    createPed = CreatePed,
    createThread = CreateThread,
    createVehicleServerSetter = CreateVehicleServerSetter,
    deleteEntity = DeleteEntity,
    doesEntityExist = DoesEntityExist,
    getCoreApi = function(versionRange)
        return exports[CORE_RESOURCE]:GetAPI(versionRange)
    end,
    getEntityModel = GetEntityModel,
    getEntityRoutingBucket = GetEntityRoutingBucket,
    getEntityType = GetEntityType,
    getGameTimer = GetGameTimer,
    getPlayerName = GetPlayerName,
    getPlayerRoutingBucket = GetPlayerRoutingBucket,
    getResourceState = GetResourceState,
    jsonDecode = json.decode,
    loadResourceFile = LoadResourceFile,
    networkGetEntityOwner = NetworkGetEntityOwner,
    networkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
    setEntityOrphanMode = SetEntityOrphanMode,
    setEntityRoutingBucket = SetEntityRoutingBucket,
    setPlayerRoutingBucket = SetPlayerRoutingBucket,
    setRoutingBucketEntityLockdownMode = SetRoutingBucketEntityLockdownMode,
    setRoutingBucketPopulationEnabled = SetRoutingBucketPopulationEnabled,
    wait = Wait,
}

local state = SynexEntityRegistry.newState()
local registry = state.entities
local coreRef = {}
local database = SynexEntityDatabase.createOxmysqlAdapter(MySQL)
local foundation = SynexEntityFoundation.create({
    errorSink = function(event)
        print(json.encode({
            level = 'error',
            event = 'unexpected_runtime_error',
            resource = RESOURCE_NAME,
            code = event.code,
            detail = event.detail,
            errorType = event.errorType,
            operation = event.operation,
            traceId = event.traceId,
        }))
    end,
    health = health,
    limits = config,
    ports = ports,
    registry = registry,
    resourceName = RESOURCE_NAME,
    state = state,
    validation = SynexEntityValidation,
})
local repository = SynexEntityRepository.create({
    database = database,
    foundation = foundation,
    health = health,
})
local entityRuntime = SynexEntityRuntime.create({
    config = config,
    foundation = foundation,
    ports = ports,
    registry = registry,
    state = state,
    validation = SynexEntityValidation,
})
local entityOperations = SynexEntityOperations.create({
    coreRef = coreRef,
    entityRuntime = entityRuntime,
    foundation = foundation,
    registry = registry,
    repository = repository,
    validation = SynexEntityValidation,
})
local bucketOperations = SynexEntityBucketOperations.create({
    config = config,
    coreRef = coreRef,
    entityRuntime = entityRuntime,
    foundation = foundation,
    ports = ports,
    registry = registry,
    repository = repository,
    state = state,
    validation = SynexEntityValidation,
})
local service = SynexEntityService.create({
    bucketOperations = bucketOperations,
    config = config,
    coreRef = coreRef,
    entityOperations = entityOperations,
    entityRuntime = entityRuntime,
    foundation = foundation,
    health = health,
    ports = ports,
    registry = registry,
    repository = repository,
    resourceName = RESOURCE_NAME,
    state = state,
    validation = SynexEntityValidation,
})
local application = SynexEntityApplication.create({
    coreRange = CORE_RANGE,
    coreRef = coreRef,
    coreResource = CORE_RESOURCE,
    foundation = foundation,
    health = health,
    ports = ports,
    resourceName = RESOURCE_NAME,
    service = service,
    serviceName = SERVICE_NAME,
    serviceVersion = SERVICE_VERSION,
})

foundation.setCleanupOwner(service.cleanupOwner)

CreateThread(function()
    local started = foundation.protect('application.start', application.start)
    if not started then
        foundation.setHealth('UNHEALTHY', 'Entity bootstrap failed unexpectedly')
    end
end)

AddEventHandler('playerDropped', function()
    application.playerDropped(source)
end)

AddEventHandler('onResourceStart', function(resourceName)
    application.resourceStarted(resourceName)
end)

AddEventHandler('onResourceStop', function(resourceName)
    application.resourceStopped(resourceName)
end)
