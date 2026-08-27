local factories = assert(SynexCoreFactories, 'factories must be loaded first')
factories.bootstrap = function(deps)
    local platform = assert(deps.platform, 'bootstrap requires platform')
    local coreResource = platform.currentResource()
    local foundation = factories.foundation({
        platform = platform,
        nextId = deps.nextId,
        logger = deps.logger,
        metrics = deps.metrics
    })
    local logger = foundation.logger
    local configuration = factories.configuration({ foundation = foundation })
    local resourceManifest = factories.resourceManifest({ foundation = foundation })

    local defaultConfig, configReadError = foundation.loadJson(coreResource, 'config/default.json', {})
    if configReadError then error('unable to load config/default.json: ' .. configReadError) end
    local policy, policyReadError = foundation.loadJson(coreResource, 'config/capabilities.json', {})
    if policyReadError then error('unable to load config/capabilities.json: ' .. policyReadError) end
    defaultConfig.instanceId = platform.getConvar('synex_instance_id', defaultConfig.instanceId or '')
    defaultConfig.environment = platform.getConvar('synex_environment', defaultConfig.environment or 'production')
    local strict = platform.getConvar('synex_strict', defaultConfig.strict == false and '0' or '1')
    if strict ~= '0' and strict ~= '1' then error('synex_strict must be exactly 0 or 1') end
    defaultConfig.strict = strict == '1'
    local configValid, configError = configuration:validateRuntime(defaultConfig)
    if not configValid then
        error(('invalid config/default.json at %s: %s'):format(
            configError.details and configError.details.path or '$', configError.message
        ))
    end
    local policyValid, policyError = configuration:validateCapabilityPolicy(policy)
    if not policyValid then
        error(('invalid config/capabilities.json at %s: %s'):format(
            policyError.details and policyError.details.path or '$', policyError.message
        ))
    end
    local logConfigured, logConfigurationError = logger:configure(defaultConfig.logging.level)
    if not logConfigured then error(logConfigurationError.message) end
    if defaultConfig.instanceId == '' then
        if defaultConfig.strict and defaultConfig.environment == 'production' then
            error('synex_instance_id must be configured in strict production mode')
        end
        defaultConfig.instanceId = foundation.nextId('instance')
        logger:warn('using an ephemeral server instance ID', { environment = defaultConfig.environment })
    end
    foundation.configureIds(defaultConfig.instanceId)

    local effectiveConfig, effectiveConfigError = factories.runtimeConfiguration({
        platform = platform, configuration = configuration
    }):apply(defaultConfig)
    if not effectiveConfig then error(effectiveConfigError) end
    defaultConfig = effectiveConfig

    local manifests = {}
    local persistence = factories.persistence({
        platform = platform,
        foundation = foundation,
        config = defaultConfig.database,
        db = deps.db,
        instanceId = defaultConfig.instanceId,
        manifestSnapshot = function() return manifests end
    })
    local runtimePersistence = factories.runtimePersistence({
        foundation = foundation,
        platform = platform,
        database = persistence.database,
        instanceId = defaultConfig.instanceId,
        maintenanceBatchMaximum = defaultConfig.retention.batchSize,
        sessionControlRetentionDays = defaultConfig.retention.sessionControlAfterDays,
        maximumLocalSessions = defaultConfig.connections.maximumActiveSessions
            + defaultConfig.connections.maximumConcurrentConnections
    })
    persistence.instances = runtimePersistence.instances
    persistence.rbac = runtimePersistence.rbac
    local registries = factories.registries({ foundation = foundation })
    registries.owners:activate(coreResource)
    local lifecycle = factories.lifecycle({
        platform = platform,
        foundation = foundation,
        owners = registries.owners
    })
    local contractSystem = factories.contracts({
        foundation = foundation,
        protocol = SynexProtocol,
        generated = SynexGeneratedContracts
    })
    local security = factories.security({
        platform = platform,
        foundation = foundation,
        policy = policy,
        coreResource = coreResource,
        rbacStore = runtimePersistence.rbac
    })
    local messaging = factories.messaging({
        platform = platform,
        foundation = foundation,
        contracts = contractSystem,
        security = security,
        owners = registries.owners,
        players = registries.players,
        lifecycle = lifecycle,
        dependencies = lifecycle.dependencies,
        protocol = SynexProtocol,
        config = defaultConfig.rpc,
        coreResource = coreResource
    })
    local stateService = factories.state({
        platform = platform,
        foundation = foundation,
        contracts = contractSystem,
        owners = registries.owners,
        players = registries.players,
        security = security,
        coreResource = coreResource,
        replicate = deps.replicateState,
        replicationEnabled = defaultConfig.features.stateReplication
    })
    local identity = factories.identity({
        platform = platform,
        foundation = foundation,
        database = persistence.database,
        players = registries.players,
        owners = registries.owners,
        lifecycle = lifecycle,
        messaging = messaging,
        stateService = stateService,
        config = defaultConfig.connections,
        instanceId = defaultConfig.instanceId,
        coreResource = coreResource,
        leases = persistence.leases,
        instances = runtimePersistence.instances,
        rateLimiter = security.rateLimiter,
        sha256 = persistence.sha256
    })
    local reliability = factories.reliability({
        platform = platform,
        foundation = foundation,
        database = persistence.database,
        sha256 = persistence.sha256,
        instanceId = defaultConfig.instanceId,
        diagnosticBatchMaximum = defaultConfig.retention.batchSize,
        features = defaultConfig.features
    })
    local retention = factories.retention({
        foundation = foundation,
        database = persistence.database,
        config = defaultConfig.retention
    })
    local sagaRuntime = factories.sagaRuntime({
        platform = platform, foundation = foundation, sagas = reliability.sagas,
        audit = reliability.audit, leases = persistence.leases, owners = registries.owners,
        instances = runtimePersistence.instances,
        instanceId = defaultConfig.instanceId, enabled = defaultConfig.features.sagas
    })
    local auditConfigured, auditConfigurationError = security.capabilities:setAuditSink(function(entry)
        return reliability.audit:append(entry)
    end)
    if not auditConfigured then error(auditConfigurationError.message) end

    local runtime = {}
    local controlProviders = assert(factories.controlProviders({
        platform = platform,
        foundation = foundation,
        owners = registries.owners,
        coreResource = coreResource,
        manifestFor = function(resourceName) return manifests[resourceName] end
    }), 'bootstrap requires control providers')
    local dataPort = assert(factories.dataPort({
        platform = platform, foundation = foundation, database = persistence.database,
        owners = registries.owners, sha256 = persistence.sha256,
        manifestFor = function(resourceName) return manifests[resourceName] end
    }), 'bootstrap requires data port')
    local domainDeletion = assert(factories.domainDeletion({
        platform = platform, foundation = foundation, database = persistence.database,
        owners = registries.owners, leases = persistence.leases,
        instances = runtimePersistence.instances, sha256 = persistence.sha256,
        instanceId = defaultConfig.instanceId
    }), 'bootstrap requires domain deletion')
    local facadeCache = {}
    local reloadSnapshots = {}
    local runtimeGate = factories.runtimeGate({ foundation = foundation })
    local ownerDrainTimeoutMs = 250
    local ownerDrainPollMs = 10
    local ownerSnapshotMaximumBytes = 65536

    local discovery = factories.bootstrapDiscovery({
        platform = platform,
        foundation = foundation,
        resourceManifest = resourceManifest,
        security = security,
        registries = registries,
        lifecycle = lifecycle,
        stateService = stateService,
        manifests = manifests,
        controlProviders = controlProviders,
        runtimeGate = runtimeGate,
        ownerSnapshotMaximumBytes = ownerSnapshotMaximumBytes
    })
    local api = factories.bootstrapApi({
        platform = platform, foundation = foundation, registries = registries,
        security = security, identity = identity, contractSystem = contractSystem,
        messaging = messaging, coreResource = coreResource, runtime = runtime,
        stateService = stateService, lifecycle = lifecycle, reliability = reliability,
        sagaRuntime = sagaRuntime, defaultConfig = defaultConfig, facadeCache = facadeCache,
        runtimeGate = runtimeGate, ensureOwner = discovery.ensureOwner,
        dataPort = dataPort, domainDeletion = domainDeletion,
        controlProviders = controlProviders
    })
    factories.bootstrapDiagnostics({
        runtime = runtime,
        reloadSnapshots = reloadSnapshots,
        defaultConfig = defaultConfig,
        lifecycle = lifecycle,
        registries = registries,
        messaging = messaging,
        stateService = stateService,
        foundation = foundation,
        persistence = persistence,
        platform = platform,
        contractSystem = contractSystem,
        security = security,
        identity = identity,
        sagaRuntime = sagaRuntime,
        reliability = reliability,
        controlProviders = controlProviders,
        coreResource = coreResource
    })
    factories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        coreResource = coreResource, api = api, messaging = messaging,
        identity = identity, discovery = discovery, reloadSnapshots = reloadSnapshots,
        registries = registries, lifecycle = lifecycle,
        ownerDrainTimeoutMs = ownerDrainTimeoutMs, ownerDrainPollMs = ownerDrainPollMs,
        ownerSnapshotMaximumBytes = ownerSnapshotMaximumBytes, facadeCache = facadeCache,
        defaultConfig = defaultConfig, persistence = persistence, manifests = manifests,
        reliability = reliability, sagaRuntime = sagaRuntime, retention = retention,
        security = security, stateService = stateService, runtimeGate = runtimeGate,
        domainDeletion = domainDeletion, dataPort = dataPort
    })
    runtime.foundation, runtime.persistence = foundation, persistence
    runtime.registries, runtime.lifecycle = registries, lifecycle
    runtime.contracts, runtime.security = contractSystem, security
    runtime.messaging, runtime.identity = messaging, identity
    runtime.state, runtime.reliability = stateService, reliability
    runtime.sagas, runtime.retention = sagaRuntime, retention
    runtime.dataPort, runtime.domainDeletion = dataPort, domainDeletion
    runtime.controlProviders = controlProviders
    runtime.config = defaultConfig
    return runtime
end
