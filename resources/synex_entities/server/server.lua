local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'
local SERVICE_NAME = 'synex.entities'
local SERVICE_VERSION = '1.0.0'

local bootstrap = SynexEntityBootstrapConfig.create(CORE_RESOURCE)
local config = bootstrap.config
local health = bootstrap.health
local ports = bootstrap.ports

local state = SynexEntityRegistry.newState()
local registry = state.entities
local coreRef = {}
local database = SynexEntityDatabase.createCoreAdapter(coreRef)
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
    config = config,
    foundation = foundation,
    health = health,
})
local authorityRepository = SynexEntityAuthorityRepository.create({
    database = database,
    foundation = foundation,
    health = health,
})
local extensionRepository = SynexEntityExtensionRepository.create({
    database = database,
    foundation = foundation,
    health = health,
})
local extensionRegistry = SynexEntityExtensionRegistry.create({})
local jsonValues = SynexEntityJsonValues.create({ foundation = foundation, ports = ports })
local archetypes = SynexEntityArchetypes.create({
    extensionRegistry = extensionRegistry,
    foundation = foundation,
    jsonValues = jsonValues,
    ports = ports,
    validation = SynexEntityValidation,
})
local logicalOwner = SynexEntityLogicalOwner.create({
    coreRef = coreRef, foundation = foundation,
    validation = SynexEntityValidation,
})
local checkpointGuard = SynexEntityCheckpointGuard.create({
    debounceMs = config.checkpointDebounceMs, getGameTimer = ports.getGameTimer,
    maximumEntries = config.maxEntities,
})
local lanes = SynexEntityMutationLanes.create({
    foundation = foundation, ports = ports,
})
local observability = SynexEntityObservability.create({
    coreRef = coreRef, foundation = foundation, ports = ports,
    resourceName = RESOURCE_NAME,
})
local cleanupQueue = SynexEntityCleanupQueue.create({
    config = config, foundation = foundation, health = health, observability = observability, ports = ports,
})
local spawnAdmission = SynexEntitySpawnAdmission.create({
    config = config,
    observability = observability,
    ports = ports,
    registry = registry,
    state = state,
})
local authorityOperations
local extensionOperations = SynexEntityExtensions.create({
    archetypes = archetypes,
    coreRef = coreRef,
    currentAuthority = function() return authorityOperations
        and authorityOperations.currentAuthority() end,
    extensionRegistry = extensionRegistry,
    foundation = foundation,
    jsonValues = jsonValues,
    lanes = lanes,
    observability = observability,
    ports = ports,
    repository = extensionRepository,
    registry = registry,
    resourceName = RESOURCE_NAME,
    validation = SynexEntityValidation,
})
local entityRuntime = SynexEntityRuntime.create({
    cleanupEntity = extensionOperations.cleanupEntity,
    cleanupQueue = cleanupQueue,
    config = config,
    foundation = foundation,
    ports = ports,
    registry = registry,
    state = state,
    validation = SynexEntityValidation,
})
local entityOperations = SynexEntityOperations.create({
    coreRef = coreRef, entityRuntime = entityRuntime, foundation = foundation,
    logicalOwner = logicalOwner, observability = observability,
    registry = registry, repository = repository, spawnAdmission = spawnAdmission,
    validation = SynexEntityValidation,
})
authorityOperations = SynexEntityAuthorityService.create({
    archetypes = archetypes,
    authorityRepository = authorityRepository,
    checkpointGuard = checkpointGuard,
    config = config,
    coreRef = coreRef,
    entityRuntime = entityRuntime,
    extensionRegistry = extensionRegistry,
    extensionOperations = extensionOperations,
    extensionRepository = extensionRepository,
    foundation = foundation,
    health = health,
    lanes = lanes,
    legacyOperations = entityOperations,
    logicalOwner = logicalOwner,
    observability = observability,
    ports = ports,
    registry = registry,
    resourceName = RESOURCE_NAME,
    spawnAdmission = spawnAdmission,
    validation = SynexEntityValidation,
})
local bucketPolicy = SynexEntityBucketPolicy.create({ config = config, foundation = foundation })
local bucketOperations = SynexEntityBucketOperations.create({
    authorityRepository = authorityRepository,
    config = config,
    coreRef = coreRef,
    entityRuntime = entityRuntime,
    foundation = foundation,
    getAuthority = authorityOperations.currentAuthority,
    lanes = lanes,
    observability = observability,
    policy = bucketPolicy,
    ports = ports,
    registry = registry,
    state = state,
    validation = SynexEntityValidation,
})
local queryOperations = SynexEntityQueryService.create({
    authorityRepository = authorityRepository,
    bucketPolicy = bucketPolicy,
    config = config,
    entityRuntime = entityRuntime,
    extensionRegistry = extensionRegistry,
    extensionRepository = extensionRepository,
    foundation = foundation,
    ports = ports,
    registry = registry,
    state = state,
    validation = SynexEntityValidation,
})
local lifecyclePolicy = SynexEntityLifecyclePolicy.create({
    authorityRepository = authorityRepository,
    config = config,
    entityRuntime = entityRuntime,
    foundation = foundation,
    observability = observability,
    ports = ports,
    registry = registry,
    resourceName = RESOURCE_NAME,
})
local service = SynexEntityService.create({
    authorityOperations = authorityOperations,
    bucketOperations = bucketOperations,
    cleanupQueue = cleanupQueue,
    config = config,
    coreRef = coreRef,
    entityOperations = entityOperations,
    entityRuntime = entityRuntime,
    extensionOperations = extensionOperations,
    extensionRegistry = extensionRegistry,
    foundation = foundation,
    health = health,
    ports = ports,
    publicErrors = SynexEntityPublicErrors,
    lanes = lanes,
    observability = observability,
    queryOperations = queryOperations,
    registry = registry,
    repository = repository,
    resourceName = RESOURCE_NAME,
    state = state,
    validation = SynexEntityValidation,
})
local controlProvider = SynexEntityControlProvider.create({
    authorityRepository = authorityRepository, bucketPolicy = bucketPolicy,
    config = config, coreRef = coreRef, database = database, foundation = foundation,
    queryOperations = queryOperations, registry = registry, service = service,
    spawnAdmission = spawnAdmission, state = state,
})
local application = SynexEntityApplication.create({
    config = config, coreRange = CORE_RANGE, coreRef = coreRef, coreResource = CORE_RESOURCE,
    controlProvider = controlProvider, foundation = foundation, health = health,
    lifecyclePolicy = lifecyclePolicy, ports = ports, resourceName = RESOURCE_NAME,
    service = service, serviceName = SERVICE_NAME, serviceVersion = SERVICE_VERSION,
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

AddEventHandler('entityRemoved', function(entityHandle)
    application.entityRemoved(entityHandle)
end)

AddEventHandler('onEntityBucketChange', function(entityHandle, bucketId, oldBucketId)
    application.entityBucketChanged(entityHandle, bucketId, oldBucketId)
end)

AddEventHandler('onPlayerBucketChange', function(playerSource, bucketId, oldBucketId)
    application.playerBucketChanged(playerSource, bucketId, oldBucketId)
end)
