local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapLifecycle = function(deps)
    local runtime = assert(deps.runtime, 'bootstrap lifecycle requires runtime')
    local platform = assert(deps.platform, 'bootstrap lifecycle requires platform')
    local foundation = assert(deps.foundation, 'bootstrap lifecycle requires foundation')
    local coreResource = assert(deps.coreResource, 'bootstrap lifecycle requires core resource')
    local logger = foundation.logger
    local api = assert(deps.api, 'bootstrap lifecycle requires API')
    local messaging = assert(deps.messaging, 'bootstrap lifecycle requires messaging')
    local identity = assert(deps.identity, 'bootstrap lifecycle requires identity')
    local discovery = assert(deps.discovery, 'bootstrap lifecycle requires discovery')
    local reloadSnapshots = assert(deps.reloadSnapshots, 'bootstrap lifecycle requires reload snapshots')
    local registries = assert(deps.registries, 'bootstrap lifecycle requires registries')
    local lifecycle = assert(deps.lifecycle, 'bootstrap lifecycle requires lifecycle')
    local ownerDrainTimeoutMs = deps.ownerDrainTimeoutMs or 250
    local ownerDrainPollMs = deps.ownerDrainPollMs or 10
    local facadeCache = assert(deps.facadeCache, 'bootstrap lifecycle requires facade cache')
    local defaultConfig = assert(deps.defaultConfig, 'bootstrap lifecycle requires configuration')
    local persistence = assert(deps.persistence, 'bootstrap lifecycle requires persistence')
    local manifests = assert(deps.manifests, 'bootstrap lifecycle requires manifests')
    local reliability = assert(deps.reliability, 'bootstrap lifecycle requires reliability')
    local sagaRuntime = assert(deps.sagaRuntime, 'bootstrap lifecycle requires saga runtime')
    local retention = assert(deps.retention, 'bootstrap lifecycle requires retention')
    local security = assert(deps.security, 'bootstrap lifecycle requires security')
    local stateService = deps.stateService or {
        purgeAllPlayers = function() return { players = 0, cleared = 0, replicated = 0, skipped = 0, failures = {} }, nil end
    }
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap lifecycle requires runtime gate')
    local getAPIForCaller = assert(api.getAPIForCaller, 'bootstrap lifecycle requires API lookup')
    local invokeForCaller = assert(api.invokeForCaller, 'bootstrap lifecycle requires contract invocation')
    local guarded = assert(api.guarded, 'bootstrap lifecycle requires capability guard')
    local registerCoreContracts = assert(api.registerCoreContracts, 'bootstrap lifecycle requires core contracts')
    local registerCoreServices = assert(api.registerCoreServices, 'bootstrap lifecycle requires core services')
    local discoverResource = assert(discovery.discoverResource, 'bootstrap lifecycle requires resource discovery')
    local invalidateResource = assert(discovery.invalidateResource, 'bootstrap lifecycle requires resource invalidation')
    local discoverAll = assert(discovery.discoverAll, 'bootstrap lifecycle requires full discovery')
    local validateActive = assert(discovery.validateActive, 'bootstrap lifecycle requires live validation')
    local ensureOwner = assert(discovery.ensureOwner, 'bootstrap lifecycle requires owner discovery')
    local supportsStateHandoff = assert(discovery.supportsStateHandoff, 'bootstrap lifecycle requires state handoff policy')
    local captureStateHandoff = assert(discovery.captureStateHandoff, 'bootstrap lifecycle requires state capture')
    local restoreStateHandoff = assert(discovery.restoreStateHandoff, 'bootstrap lifecycle requires state restore')
    local commands = factories.commands({
        platform = platform, foundation = foundation, runtime = runtime, lifecycle = lifecycle,
        registries = registries, identity = identity, persistence = persistence,
        reliability = reliability, messaging = messaging, security = security, coreResource = coreResource
    })
    local dependencyAffectedResources = {}
    local enforceCriticalResources = false
    local instanceStatusInitialized = false
    local instanceRegisteredDuringBoot = false
    local lastInstanceStatus = nil
    local function raiseBootFailure(failure, fallbackCode)
        if type(failure) == 'table' then error(failure, 0) end
        error(foundation.error(fallbackCode, 'The current core boot step failed.'), 0)
    end

    local function evictConnectedPlayers(reason)
        local listed, connectedPlayers = foundation.safeCall(platform.getPlayers)
        if not listed or type(connectedPlayers) ~= 'table' then
            return nil, foundation.error('PLAYER_ENUMERATION_FAILED',
                'Connected players could not be enumerated during the core lifecycle.')
        end
        local dropped, failures = 0, 0
        for _, playerSource in ipairs(connectedPlayers) do
            local numericSource = tonumber(playerSource)
            if not numericSource or numericSource < 1 or numericSource % 1 ~= 0 then
                failures = failures + 1
            else
                local disconnected = foundation.safeCall(platform.dropPlayer, numericSource, reason)
                if disconnected then dropped = dropped + 1 else failures = failures + 1 end
            end
        end
        if dropped > 0 then
            logger:warn('disconnected players without current runtime authority', { count = dropped })
        end
        if failures > 0 then
            return nil, foundation.error('PLAYER_DISCONNECT_FAILED',
                'One or more connected players could not be disconnected.', {
                    details = { failures = failures }
                })
        end
        return dropped, nil
    end

    local function drainQuiescedTerminals(context)
        if type(identity.connections.drainQuiescedTerminals) ~= 'function' then return true, nil end
        local invoked, report, drainError = foundation.safeCall(
            identity.connections.drainQuiescedTerminals, identity.connections)
        if not invoked or not report then
            return nil, drainError or foundation.error('DEFERRAL_DRAIN_FAILED',
                ('Connection deferrals could not be drained during %s.'):format(context))
        end
        if (report.failures or 0) > 0 or (report.remaining or 0) > 0 then
            return nil, foundation.error('DEFERRAL_DRAIN_INCOMPLETE',
                ('Connection deferrals remained open during %s.'):format(context), {
                    details = { failures = report.failures or 0, remaining = report.remaining or 0 }
                })
        end
        return report, nil
    end

    local function synchronizeCoreResourceHealth()
        local registered = registries.resources:get(coreResource)
        if not registered then return true, nil end
        local snapshot = lifecycle.core:snapshot()
        local status = lifecycle.core:healthStatus()
        local reasons = {}
        local components = {}
        for component in pairs(snapshot.reasons) do components[#components + 1] = component end
        table.sort(components)
        for _, component in ipairs(components) do
            local reason = snapshot.reasons[component]
            reasons[#reasons + 1] = {
                component = component,
                status = reason.status,
                message = reason.reason
            }
        end
        if status ~= 'HEALTHY' and status ~= 'UNKNOWN' and #reasons == 0 then
            reasons[1] = {
                component = snapshot.state == 'READY' and 'player-admission' or 'lifecycle',
                status = status,
                message = snapshot.state == 'READY' and 'player admission is disabled' or snapshot.state
            }
        end
        return registries.resources:setState(coreResource,
            snapshot.operational and 'STARTED' or registered.state,
            { status = status, reasons = reasons })
    end

    local healthObserved, healthObserverError = lifecycle.core:setHealthObserver(synchronizeCoreResourceHealth)
    if not healthObserved then error(healthObserverError.message) end

    local function desiredInstanceHealthStatus()
        local snapshot = lifecycle.core:snapshot()
        if not snapshot.operational then return nil end
        if snapshot.state ~= 'READY' then return 'degraded' end
        for component in pairs(snapshot.reasons) do
            if component ~= 'instance-status' then return 'degraded' end
        end
        if snapshot.playerAdmission ~= true and snapshot.reasons['instance-status'] == nil then
            return 'degraded'
        end
        return 'ready'
    end

    local function synchronizeInstanceHealthStatus()
        if not instanceStatusInitialized then return nil end
        local desiredStatus = desiredInstanceHealthStatus()
        if not desiredStatus then return nil end
        local synchronizationPending = lifecycle.core:snapshot().reasons['instance-status'] ~= nil
        if desiredStatus == lastInstanceStatus and not synchronizationPending then return nil end
        local synchronized, synchronizationError = persistence.instances:setStatus(desiredStatus)
        if synchronized then
            lastInstanceStatus = desiredStatus
            lifecycle.core:setHealth('instance-status', 'HEALTHY')
            return nil
        end
        local failure = synchronizationError
            or foundation.error('INSTANCE_STATUS_SYNC_FAILED', 'The cluster instance status could not be synchronized.')
        lifecycle.core:setHealth('instance-status', 'DEGRADED',
            'cluster instance lifecycle status could not be synchronized')
        logger:error('instance lifecycle status synchronization failed', {
            status = desiredStatus,
            code = failure.code
        })
        return failure
    end

    local function refreshDependencyHealth(inactiveResource)
        local findings = validateActive(inactiveResource, enforceCriticalResources)
        local critical = 0
        local byResource = {}
        for _, finding in ipairs(findings) do
            local resource = finding.resource or finding.consumer
            if resource then
                byResource[resource] = byResource[resource] or {}
                byResource[resource][#byResource[resource] + 1] = foundation.copy(finding)
            end
            if finding.severity == 'error' then critical = critical + 1 end
        end
        for resource, reasons in pairs(byResource) do
            local registered = registries.resources:get(resource)
            local unhealthy = false
            for _, reason in ipairs(reasons) do
                if reason.severity == 'error' then unhealthy = true break end
            end
            if registered then registries.resources:setState(resource, registered.state, {
                status = unhealthy and 'UNHEALTHY' or 'DEGRADED', reasons = reasons
            }) end
            dependencyAffectedResources[resource] = true
        end
        for resource in pairs(dependencyAffectedResources) do
            if byResource[resource] == nil then
                local registered = registries.resources:get(resource)
                local state = resource == inactiveResource and 'stopped' or platform.resourceState(resource)
                local active = state == 'started' or state == 'starting'
                if registered and active then
                    local managedHealth = true
                    for _, reason in ipairs((registered.health and registered.health.reasons) or {}) do
                        if reason.kind ~= 'dependency' and reason.kind ~= 'resource-dependency'
                            and reason.kind ~= 'provider'
                            and reason.kind ~= 'resource'
                            and reason.kind ~= 'capability' then
                            managedHealth = false
                            break
                        end
                    end
                    if managedHealth then
                        registries.resources:setState(resource, registered.state, {
                            status = 'HEALTHY', reasons = {}
                        })
                    end
                    dependencyAffectedResources[resource] = nil
                end
            end
        end
        lifecycle.core:setHealth('runtime-dependencies', critical > 0 and 'DEGRADED' or 'HEALTHY',
            critical > 0 and ('%d critical live validation finding(s)'):format(critical) or nil)
        local current = lifecycle.core:get()
        if critical > 0 and current == 'READY' then
            lifecycle.core:transition('DEGRADED', 'critical live dependency or capability validation failed')
        elseif critical == 0 and current == 'DEGRADED'
            and next(lifecycle.core:snapshot().reasons) == nil then
            lifecycle.core:transition('READY', 'live dependency and capability validation recovered')
        end
        local currentAfterRefresh = lifecycle.core:get()
        local instanceStatusError = synchronizeInstanceHealthStatus()
        lifecycle.core:setCriticalFoundationsValidated(
            instanceStatusInitialized and instanceStatusError == nil
                and enforceCriticalResources and critical == 0
                and currentAfterRefresh == 'READY'
                and next(lifecycle.core:snapshot().reasons) == nil)
        if instanceStatusError == nil then
            instanceStatusError = synchronizeInstanceHealthStatus()
            if instanceStatusError then lifecycle.core:setCriticalFoundationsValidated(false) end
        end
        local _, registryHealthError = synchronizeCoreResourceHealth()
        if registryHealthError then return findings, critical, registryHealthError end
        return findings, critical, instanceStatusError
    end

    function runtime:refreshDependencyHealth(inactiveResource)
        return refreshDependencyHealth(inactiveResource)
    end

    local restartController = assert(factories.bootstrapRestart({
        foundation = foundation,
        runtimeGate = runtimeGate,
        lifecycle = lifecycle,
        identity = identity,
        persistence = persistence,
        registries = registries,
        facadeCache = facadeCache,
        coreResource = coreResource,
        stateService = stateService,
        evictConnectedPlayers = evictConnectedPlayers,
        drainQuiescedTerminals = drainQuiescedTerminals,
        ownerDrainTimeoutMs = ownerDrainTimeoutMs,
        ownerDrainPollMs = ownerDrainPollMs
    }))

    function runtime:prepareRestart()
        return restartController:prepare()
    end

    local resourceEvents = factories.bootstrapResourceEvents({
        platform = platform,
        foundation = foundation,
        coreResource = coreResource,
        messaging = messaging,
        identity = identity,
        reloadSnapshots = reloadSnapshots,
        registries = registries,
        lifecycle = lifecycle,
        ownerDrainTimeoutMs = ownerDrainTimeoutMs,
        ownerDrainPollMs = ownerDrainPollMs,
        ownerSnapshotMaximumBytes = deps.ownerSnapshotMaximumBytes,
        facadeCache = facadeCache,
        manifests = manifests,
        stateService = stateService,
        runtimeGate = runtimeGate,
        getAPIForCaller = getAPIForCaller,
        invokeForCaller = invokeForCaller,
        guarded = guarded,
        discoverResource = discoverResource,
        invalidateResource = invalidateResource,
        ensureOwner = ensureOwner,
        supportsStateHandoff = supportsStateHandoff,
        captureStateHandoff = captureStateHandoff,
        restoreStateHandoff = restoreStateHandoff,
        refreshDependencyHealth = refreshDependencyHealth,
        restartController = restartController,
        commands = commands
    })

    function runtime:bind()
        return resourceEvents:bind()
    end

    local function advance(target, operation)
        local _, transitionError = lifecycle.core:transition(target, operation)
        if transitionError then error(transitionError.message) end
    end

    local function failClosedBootRuntime()
        runtimeGate:fail()
        enforceCriticalResources = false
        lifecycle.core:setCriticalFoundationsValidated(false)
        local quiesced, quiesceResult, quiesceError = foundation.safeCall(
            identity.connections.quiesce, identity.connections)
        if not quiesced or not quiesceResult then
            foundation.safeCall(logger.error, logger, 'boot failure connection quiesce failed', {
                code = quiesced and quiesceError and quiesceError.code or 'RUNTIME_ERROR'
            })
        end
        local _, evictionError = evictConnectedPlayers(
            'Synex Core failed to start. Please reconnect after the server is repaired.')
        if evictionError then
            foundation.safeCall(logger.error, logger, 'boot failure player eviction failed', {
                code = evictionError.code
            })
        end
        local _, drainError = drainQuiescedTerminals('boot failure')
        if drainError then
            foundation.safeCall(logger.error, logger, 'boot failure connection deferral drain failed', {
                code = drainError.code
            })
        end
        for _, owner in ipairs(registries.owners:list()) do
            local report = registries.owners:purge(
                owner.resource, owner.epoch, 'synex_core boot failed')
            if #report.errors > 0 then
                foundation.safeCall(logger.error, logger, 'boot failure owner purge completed with errors', {
                    resource = owner.resource, errors = #report.errors
                })
            end
        end
        for key in pairs(facadeCache) do facadeCache[key] = nil end
    end

    function runtime:start()
        runtimeGate:beginBoot()
        instanceRegisteredDuringBoot = false
        local bootStage = 'configure'
        local bootResource = nil
        local ok, err = xpcall(function()
            advance('CONFIGURING', 'configuration loaded')
            bootStage = 'evict_connected_players'
            local _, evictionError = evictConnectedPlayers('Synex Core restarted. Please reconnect.')
            if evictionError then raiseBootFailure(evictionError, 'PLAYER_EVICTION_FAILED') end
            bootStage = 'enter_database_connecting'
            advance('DATABASE_CONNECTING', 'connecting database')
            bootStage = 'validate_oxmysql_version'
            local oxmysqlVersion = platform.resourceMetadata('oxmysql', 'version', 0)
            local minimumOxmysqlVersion = defaultConfig.database.minimumOxmysqlVersion or '2.14.1'
            if type(oxmysqlVersion) ~= 'string' or not foundation.semverSatisfies(oxmysqlVersion, '>=' .. minimumOxmysqlVersion) then
                raiseBootFailure(nil, 'OXMYSQL_VERSION_UNSUPPORTED')
            end
            bootStage = 'validate_database_utc'
            local utcSession, utcSessionError = persistence.database:validateUtcSession()
            if not utcSession then raiseBootFailure(utcSessionError, 'DATABASE_UTC_VALIDATION_FAILED') end
            bootStage = 'bootstrap_migration_schema'
            local bootstrapped, bootstrapError = persistence.migrations:bootstrap()
            if not bootstrapped then raiseBootFailure(bootstrapError, 'MIGRATION_BOOTSTRAP_FAILED') end
            bootStage = 'enter_migrating'
            advance('MIGRATING', 'database connected')
            bootStage = 'acquire_migration_lease'
            local lease, leaseError = persistence.migrations:acquireLease()
            if not lease then raiseBootFailure(leaseError, 'MIGRATION_LEASE_ACQUIRE_FAILED') end
            bootStage = 'discover_resources'
            local discovered, discoveryError = discoverAll()
            if not discovered then raiseBootFailure(discoveryError, 'RESOURCE_DISCOVERY_FAILED') end
            if not manifests[coreResource] then
                raiseBootFailure(foundation.error('CORE_MANIFEST_UNAVAILABLE',
                    'The Synex Core resource manifest was not discovered.'), 'CORE_MANIFEST_UNAVAILABLE')
            end
            local names = {}
            for name in pairs(manifests) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                bootStage = 'apply_migrations'
                bootResource = name
                local applied, migrationError = persistence.migrations:apply(name, manifests[name].migrations)
                if not applied then raiseBootFailure(migrationError, 'MIGRATION_APPLY_FAILED') end
            end
            bootResource = nil
            bootStage = 'release_migration_lease'
            local released, releaseError = persistence.migrations:releaseLease()
            if not released then raiseBootFailure(releaseError, 'MIGRATION_LEASE_RELEASE_FAILED') end
            bootStage = 'register_instance'
            local instanceRegistered, instanceRegistrationError = persistence.instances:register(defaultConfig.instanceName)
            if not instanceRegistered then raiseBootFailure(instanceRegistrationError, 'INSTANCE_REGISTRATION_FAILED') end
            instanceRegisteredDuringBoot = true
            bootStage = 'terminate_local_sessions'
            local terminated, terminationError = persistence.instances:terminateLocalSessions('synex_core restarted')
            if not terminated then raiseBootFailure(terminationError, 'SESSION_TERMINATION_FAILED') end
            bootStage = 'seed_source_generation'
            local sourceGenerationFloor, sourceGenerationError = persistence.instances:sourceGenerationFloor()
            if sourceGenerationFloor == nil then
                raiseBootFailure(sourceGenerationError, 'SOURCE_GENERATION_READ_FAILED')
            end
            local sourceGenerationSeeded, sourceGenerationSeedError =
                registries.players:seedSourceGeneration(sourceGenerationFloor)
            if not sourceGenerationSeeded then
                raiseBootFailure(sourceGenerationSeedError, 'SOURCE_GENERATION_SEED_FAILED')
            end
            bootStage = 'hydrate_rbac'
            local rbacHydrated, rbacHydrationError = security.rbac:hydrate()
            if not rbacHydrated then raiseBootFailure(rbacHydrationError, 'RBAC_HYDRATION_FAILED') end
            bootStage = 'enter_resource_discovery'
            advance('DISCOVERING_RESOURCES', 'migrations applied')
            bootStage = 'enter_contract_validation'
            advance('VALIDATING_CONTRACTS', 'resource manifests discovered')
            -- Generated contracts were validated when the registry was constructed.
            bootStage = 'enter_capability_validation'
            advance('VALIDATING_CAPABILITIES', 'contracts validated')
            bootStage = 'enter_service_startup'
            advance('STARTING_SERVICES', 'capabilities and dependencies validated')
            bootStage = 'register_core_contracts'
            local registered, registrationError = registerCoreContracts()
            if not registered then raiseBootFailure(registrationError, 'CORE_CONTRACT_REGISTRATION_FAILED') end
            bootStage = 'register_core_services'
            local serviceToken, serviceRegistrationError = registerCoreServices()
            if not serviceToken then
                raiseBootFailure(serviceRegistrationError, 'CORE_SERVICE_REGISTRATION_FAILED')
            end
            bootStage = 'validate_runtime_dependencies'
            local _, criticalFindings = refreshDependencyHealth()
            if criticalFindings > 0 then
                raiseBootFailure(nil, 'CRITICAL_DEPENDENCY_UNAVAILABLE')
            end
            local coreEpoch = registries.owners:epoch(coreResource)
            local function scheduleEvery(intervalMs, handler, name)
                local token, scheduleError = lifecycle.scheduler:every(
                    coreResource, coreEpoch, intervalMs, handler, { name = name })
                if not token then raiseBootFailure(scheduleError, 'SCHEDULER_REGISTRATION_FAILED') end
                return token
            end
            bootStage = 'start_runtime_workers'
            if defaultConfig.features.durableEvents then
                scheduleEvery(1000, function()
                    local report, dispatchError = reliability.outbox:dispatchBatch(function(event)
                        if type(event.producerResource) ~= 'string' then
                            return nil, foundation.error('OUTBOX_PRODUCER_UNAVAILABLE',
                                'The durable event has no attributable producer.')
                        end
                        local producerEpoch = registries.owners:epoch(event.producerResource)
                        local _, eventError = messaging.events:publishOutbox(
                            event.producerResource, producerEpoch, event.eventType, event.payload, {
                                traceId = event.headers and event.headers.traceId,
                                eventId = event.eventId,
                                aggregateId = event.aggregateId,
                                schemaVersion = event.schemaVersion
                            })
                        return eventError == nil, eventError
                    end, 25)
                    if dispatchError then return nil, dispatchError end
                    return report ~= nil, nil
                end, 'core.outbox.dispatch')
            end
            if defaultConfig.features.sagas then
                scheduleEvery(1000, function()
                    return sagaRuntime:dispatchBatch(10)
                end, 'core.sagas.dispatch')
            end
            if reliability.idempotency
                and type(reliability.idempotency.compactExpired) == 'function' then
                scheduleEvery(defaultConfig.retention.workerIntervalMs, function()
                    local report, compactionError = reliability.idempotency:compactExpired(
                        defaultConfig.retention.batchSize or 250)
                    if compactionError then return nil, compactionError end
                    return report ~= nil, nil
                end, 'core.idempotency.compact_expired')
            end
            local outboxRetention = defaultConfig.retention
                and defaultConfig.retention.outbox or nil
            if defaultConfig.features.durableEvents and outboxRetention
                and reliability.outbox
                and type(reliability.outbox.compactTerminal) == 'function' then
                scheduleEvery(defaultConfig.retention.workerIntervalMs, function()
                    local report, compactionError = reliability.outbox:compactTerminal(
                        defaultConfig.retention.batchSize or 250, outboxRetention)
                    if compactionError then return nil, compactionError end
                    return report ~= nil, nil
                end, 'core.outbox.compact_terminal')
            end
            if persistence.instances
                and type(persistence.instances.compactTerminalControls) == 'function' then
                scheduleEvery(defaultConfig.retention.workerIntervalMs, function()
                    local report, compactionError = persistence.instances:compactTerminalControls(
                        defaultConfig.retention.batchSize or 250)
                    if compactionError then return nil, compactionError end
                    return report ~= nil, nil
                end, 'core.session_controls.compact_terminal')
            end
            if persistence.leases and type(persistence.leases.compactTerminal) == 'function' then
                scheduleEvery(5000, function()
                    if type(persistence.leases.retireExpiredAuthority) == 'function' then
                        local retirement, retirementError = persistence.leases:retireExpiredAuthority(250)
                        if retirementError then return nil, retirementError end
                        if not retirement then return nil, foundation.error(
                            'LEASE_RETIREMENT_FAILED',
                            'Expired session authority retirement returned no report.') end
                    end
                    local report, compactionError = persistence.leases:compactTerminal(250)
                    if compactionError then return nil, compactionError end
                    return report ~= nil, nil
                end, 'core.leases.compact_terminal')
            end
            if type(stateService.retryReplicationCleanup) == 'function' then
                scheduleEvery(5000, function()
                    local report, cleanupError = stateService:retryReplicationCleanup(64)
                    if cleanupError then return nil, cleanupError end
                    return report ~= nil, nil
                end, 'core.state.replication_cleanup')
            end
            if defaultConfig.retention.audit.mode == 'archive' then
                scheduleEvery(defaultConfig.retention.workerIntervalMs, function()
                    return retention.audit:archiveBatch()
                end, 'core.retention.audit_archive')
            end
            scheduleEvery(5000, function()
                return identity.characters:reconcileDeletions(10)
            end, 'core.characters.delete_reconciliation')
            scheduleEvery(5000, function()
                return identity.characters:reconcileUnloads(10)
            end, 'core.characters.unload_reconciliation')
            scheduleEvery(defaultConfig.connections.clusterHeartbeatMs or 10000, function()
                return identity.connections:heartbeat()
            end, 'core.cluster.heartbeat')
            scheduleEvery(5000, function()
                local _, _, healthError = refreshDependencyHealth()
                if healthError then return nil, healthError end
                return true, nil
            end, 'core.runtime.dependency_health')
            enforceCriticalResources = true
            lifecycle.core:setCriticalFoundationsValidated(false)
            local _, postBootCritical = refreshDependencyHealth()
            bootStage = 'enter_runtime_state'
            advance(postBootCritical > 0 and 'DEGRADED' or 'READY',
                postBootCritical > 0
                    and 'kernel services started; critical foundations are pending'
                    or 'kernel services and critical foundations started')
            local instanceStatus = postBootCritical > 0 and 'degraded' or 'ready'
            bootStage = 'persist_instance_status'
            local instanceReady, instanceReadyError = persistence.instances:setStatus(instanceStatus)
            if not instanceReady then raiseBootFailure(instanceReadyError, 'INSTANCE_STATUS_WRITE_FAILED') end
            lastInstanceStatus = instanceStatus
            instanceStatusInitialized = true
            lifecycle.core:setCriticalFoundationsValidated(
                postBootCritical == 0 and lifecycle.core:get() == 'READY'
                    and next(lifecycle.core:snapshot().reasons) == nil)
            bootStage = 'synchronize_resource_health'
            local _, coreHealthError = synchronizeCoreResourceHealth()
            if coreHealthError then raiseBootFailure(coreHealthError, 'CORE_HEALTH_SYNC_FAILED') end
            logger:info('Synex core kernel services started', {
                apiVersion = SynexProtocol.api,
                instanceId = defaultConfig.instanceId,
                state = lifecycle.core:get()
            })
            runtimeGate:open()
        end, debug.traceback)
        if not ok then
            failClosedBootRuntime()
            local current = lifecycle.core:get()
            if current ~= 'FAILED' and current ~= 'STOPPING' and current ~= 'STOPPED' then
                lifecycle.core:transition('FAILED', 'boot failure')
            end
            foundation.safeCall(persistence.migrations.releaseLease, persistence.migrations)
            if instanceRegisteredDuringBoot then
                foundation.safeCall(persistence.instances.setStatus, persistence.instances, 'stopping')
                if type(identity.connections.releaseQuiescedLeases) == 'function' then
                    foundation.safeCall(identity.connections.releaseQuiescedLeases, identity.connections)
                end
                local terminationCalled, terminated = foundation.safeCall(
                    persistence.instances.terminateLocalSessions,
                    persistence.instances, 'synex_core boot failed')
                if terminationCalled and terminated then
                    foundation.safeCall(persistence.instances.setStatus, persistence.instances, 'stopped')
                end
            end
            foundation.safeCall(synchronizeCoreResourceHealth)
            foundation.safeCall(logger.fatal, logger, 'Synex core failed to start', {
                code = foundation.failureCode(err, 'CORE_BOOT_EXCEPTION'),
                stage = bootStage,
                resource = bootResource,
                failureType = type(err)
            })
            return nil, foundation.error('BOOT_FAILED', 'Synex core failed to start.')
        end
        return true, nil
    end

    return runtime
end
