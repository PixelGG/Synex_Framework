SynexEntityBootstrapConfig = {}

function SynexEntityBootstrapConfig.create(coreResource)
    assert(type(coreResource) == 'string', 'entity Core resource is required')
    local config = {
        authorityLeaseSeconds = math.max(10, math.min(
            GetConvarInt('synex_entities_authority_lease_seconds', 30), 300)),
        bucketCleanupTimeoutMs = 5000,
        bucketExpiryIntervalMs = 1000,
        bucketMin = math.max(1, math.min(
            GetConvarInt('synex_entities_bucket_min', 1000), 2147483647)),
        checkpointDebounceMs = math.max(1000, math.min(
            GetConvarInt('synex_entities_checkpoint_debounce_ms', 5000), 60000)),
        deleteTimeoutMs = 1000,
        driftIntervalMs = math.max(10000, math.min(
            GetConvarInt('synex_entities_drift_interval_ms', 60000), 3600000)),
        driftScanLimit = math.max(16, math.min(
            GetConvarInt('synex_entities_drift_scan_limit', 512), 5000)),
        maxBucketPlayers = math.max(1, math.min(
            GetConvarInt('synex_entities_max_bucket_players', 256), 2048)),
        maxBuckets = math.max(1, math.min(
            GetConvarInt('synex_entities_max_buckets', 1024), 10000)),
        maxEntities = math.max(1, math.min(
            GetConvarInt('synex_entities_max_entities', 4096), 20000)),
        rehydrateLimit = math.max(1, math.min(
            GetConvarInt('synex_entities_rehydrate_limit', 512), 5000)),
        recoveryBatchSize = math.max(1, math.min(
            GetConvarInt('synex_entities_recovery_batch_size', 16), 128)),
        recoveryBaseDelaySeconds = math.max(1, math.min(
            GetConvarInt('synex_entities_recovery_base_delay_seconds', 2), 3600)),
        recoveryIntervalMs = math.max(1000, math.min(
            GetConvarInt('synex_entities_recovery_interval_ms', 5000), 60000)),
        recoveryJitterSeconds = math.max(0, math.min(
            GetConvarInt('synex_entities_recovery_jitter_seconds', 2), 86400)),
        recoveryMaxAttempts = math.max(1, math.min(
            GetConvarInt('synex_entities_recovery_max_attempts', 5), 1000)),
        recoveryMaxDelaySeconds = math.max(1, math.min(
            GetConvarInt('synex_entities_recovery_max_delay_seconds', 60), 86400)),
        recoveryStormThreshold = math.max(2, math.min(
            GetConvarInt('synex_entities_recovery_storm_threshold', 8), 128)),
        recoveryWindowSeconds = math.max(1, math.min(
            GetConvarInt('synex_entities_recovery_window_seconds', 300), 86400)),
        serverScope = GetConvar('synex_entities_server_scope', 'default'),
        spawnTimeoutMs = math.max(250, math.min(
            GetConvarInt('synex_entities_spawn_timeout_ms', 2500), 10000)),
        waitStepMs = 25,
    }
    if type(config.serverScope) ~= 'string' or #config.serverScope < 1
        or #config.serverScope > 64
        or config.serverScope:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        error('synex_entities_server_scope is invalid', 0)
    end
    config.bucketMax = math.max(config.bucketMin, math.min(
        GetConvarInt('synex_entities_bucket_max', 999999), 2147483647))
    config.maxOwnerEntities = math.max(1, math.min(
        GetConvarInt('synex_entities_max_owner_entities', 1024), config.maxEntities))
    config.maxOwnerBuckets = math.max(1, math.min(
        GetConvarInt('synex_entities_max_owner_buckets', 128), config.maxBuckets))
    config.maxBucketEntities = math.max(1, math.min(
        GetConvarInt('synex_entities_max_bucket_entities', 512), config.maxEntities))
    config.maxLogicalOwnerEntities = math.max(1, math.min(
        GetConvarInt('synex_entities_max_logical_owner_entities',
            config.maxOwnerEntities), config.maxEntities))
    config.maxPersistentEntities = math.max(1, math.min(
        GetConvarInt('synex_entities_max_persistent_entities',
            config.maxEntities), config.maxEntities))
    config.maxTypeEntities = {
        object = math.max(1, math.min(GetConvarInt(
            'synex_entities_max_object_entities', config.maxEntities), config.maxEntities)),
        ped = math.max(1, math.min(GetConvarInt(
            'synex_entities_max_ped_entities', config.maxEntities), config.maxEntities)),
        vehicle = math.max(1, math.min(GetConvarInt(
            'synex_entities_max_vehicle_entities', config.maxEntities), config.maxEntities)),
    }
    config.spawnRateWindowMs = math.max(1000, math.min(GetConvarInt(
        'synex_entities_spawn_rate_window_ms', 60000), 3600000))
    config.spawnRateMaxScopes = math.max(64, math.min(GetConvarInt(
        'synex_entities_spawn_rate_max_scopes', 4096), 65536))
    config.spawnRateMaxEntries = math.max(1024, math.min(GetConvarInt(
        'synex_entities_spawn_rate_max_entries', 65536), 262144))
    config.spawnRateLimits = {
        object = math.max(1, math.min(GetConvarInt(
            'synex_entities_spawn_rate_object', 20), 10000)),
        ped = math.max(1, math.min(GetConvarInt(
            'synex_entities_spawn_rate_ped', 20), 10000)),
        vehicle = math.max(1, math.min(GetConvarInt(
            'synex_entities_spawn_rate_vehicle', 20), 10000)),
    }
    config.recoveryMaxDelaySeconds = math.max(
        config.recoveryBaseDelaySeconds, config.recoveryMaxDelaySeconds)
    config.recoveryJitterSeconds = math.min(
        config.recoveryJitterSeconds, config.recoveryMaxDelaySeconds)

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
            return exports[coreResource]:GetAPI(versionRange)
        end,
        getConvar = GetConvar,
        getEntityCoords = GetEntityCoords,
        getEntityHeading = GetEntityHeading,
        getEntityModel = GetEntityModel,
        getEntityRoutingBucket = GetEntityRoutingBucket,
        getEntityType = GetEntityType,
        getGameTimer = GetGameTimer,
        getPlayerName = GetPlayerName,
        getPlayerPed = GetPlayerPed,
        getPlayerRoutingBucket = GetPlayerRoutingBucket,
        getResourceState = GetResourceState,
        jsonDecode = json.decode,
        jsonEncode = json.encode,
        loadResourceFile = LoadResourceFile,
        networkGetEntityOwner = NetworkGetEntityOwner,
        networkGetNetworkIdFromEntity = NetworkGetNetworkIdFromEntity,
        setEntityOrphanMode = SetEntityOrphanMode,
        setEntityRoutingBucket = SetEntityRoutingBucket,
        setEntityState = function(handle, key, value, replicated)
            Entity(handle).state:set(key, value, replicated == true)
        end,
        setPlayerRoutingBucket = SetPlayerRoutingBucket,
        setRoutingBucketEntityLockdownMode = SetRoutingBucketEntityLockdownMode,
        setRoutingBucketPopulationEnabled = SetRoutingBucketPopulationEnabled,
        wait = Wait,
    }
    return { config = config, health = health, ports = ports }
end
