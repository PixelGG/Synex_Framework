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
    local getAPIForCaller = assert(api.getAPIForCaller, 'bootstrap lifecycle requires API lookup')
    local invokeForCaller = assert(api.invokeForCaller, 'bootstrap lifecycle requires contract invocation')
    local guarded = assert(api.guarded, 'bootstrap lifecycle requires capability guard')
    local registerCoreContracts = assert(api.registerCoreContracts, 'bootstrap lifecycle requires core contracts')
    local registerCoreServices = assert(api.registerCoreServices, 'bootstrap lifecycle requires core services')
    local discoverResource = assert(discovery.discoverResource, 'bootstrap lifecycle requires resource discovery')
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
    local bound = false
    local dependencyAffectedResources = {}
    local enforceCriticalResources = false
    local instanceStatusInitialized = false
    local lastInstanceStatus = nil

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

    function runtime:bind()
        if bound then return true end
        bound = true
        platform.export('GetAPI', function(versionRange)
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            return getAPIForCaller(caller, versionRange)
        end)
        platform.export('Invoke', function(name, version, request, options)
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            return invokeForCaller(caller, name, version, request, options)
        end)
        platform.export('GetRuntimeStatus', function()
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            local epoch, err = ensureOwner(caller)
            if not epoch then return nil, err end
            return guarded(caller, epoch, 'synex.runtime.read', 'GetRuntimeStatus', function() return lifecycle.core:snapshot(), nil end)
        end)
        messaging.network:bind()
        platform.registerNetEvent('playerJoining')
        platform.addEventHandler('playerConnecting', function(name, _, deferrals)
            local tempSource = source
            local invoked, connected, connectionError = foundation.safeCall(
                identity.connections.handleConnecting, identity.connections, tempSource, name, deferrals)
            if not invoked or connected == nil then
                logger:error('playerConnecting handler failed', {
                    code = invoked and connectionError and connectionError.code or 'CONNECTION_HANDLER_FAILED'
                })
            end
        end)
        platform.addEventHandler('playerJoining', function(oldSource)
            local finalSource = source
            local invoked, joined = foundation.safeCall(
                identity.connections.handleJoining, identity.connections, finalSource, oldSource)
            if not invoked then
                foundation.safeCall(logger.error, logger,
                    'playerJoining handler failed', { code = 'JOIN_HANDLER_FAILED' })
            elseif joined == nil then
                logger:warn('playerJoining did not open a session', { code = 'SESSION_NOT_OPENED' })
            end
        end)
        platform.addEventHandler('playerDropped', function(reason)
            local playerSource = source
            local invoked = foundation.safeCall(
                identity.connections.handleDropped, identity.connections, playerSource, reason)
            if not invoked then logger:error('playerDropped handler failed', { code = 'DROP_HANDLER_FAILED' }) end
        end)
        platform.addEventHandler('onResourceStart', function(resource)
            if resource == coreResource then return end
            local manifest, err = discoverResource(resource)
            if err then logger:error('resource discovery failed on start', { resource = resource, code = err.code, message = err.message }) return end
            if manifest then
                local epoch = registries.owners:epoch(resource)
                if not registries.owners:isCurrent(resource, epoch) then
                    epoch = registries.owners:activate(resource)
                end
                registries.resources:setState(resource, 'STARTED', { status = 'HEALTHY', reasons = {} })
                refreshDependencyHealth()
                local snapshot = reloadSnapshots[resource]
                if snapshot then
                    reloadSnapshots[resource] = nil
                    platform.setTimeout(0, function()
                        if not registries.owners:isCurrent(resource, epoch) then return end
                        local restored, restoreError = lifecycle.reload:restore(resource, epoch, snapshot, restoreStateHandoff)
                        if not restored then
                            logger:error('resource state handoff rejected', {
                                resource = resource,
                                epoch = epoch,
                                code = restoreError.code,
                                message = restoreError.message
                            })
                            registries.resources:setState(resource, 'STARTED', {
                                status = 'DEGRADED',
                                reasons = { {
                                    code = 'STATE_RESTORE_FAILED',
                                    message = 'Reconstructable in-memory state could not be restored.'
                                } }
                            })
                        elseif restored.restored > 0 then
                            logger:info('resource state handoff restored', {
                                resource = resource,
                                fromEpoch = restored.fromEpoch,
                                toEpoch = restored.toEpoch,
                                values = restored.restored
                            })
                        end
                    end)
                end
            end
        end)
        platform.addEventHandler('onResourceStop', function(resource)
            if resource == coreResource then
                local _, stoppingError = persistence.instances:setStatus('stopping')
                if stoppingError then logger:error('instance stopping status failed', { code = stoppingError.code }) end
                local current = lifecycle.core:get()
                if current == 'READY' or current == 'DEGRADED' or current == 'UNHEALTHY' then
                    lifecycle.core:transition('QUIESCING', 'resource stop')
                    current = lifecycle.core:get()
                end
                for _, owner in ipairs(registries.owners:list()) do
                    if owner.resource ~= coreResource then
                        lifecycle.reload:quiesce(owner.resource, owner.epoch, {
                            timeoutMs = 0,
                            pollMs = ownerDrainPollMs,
                            reason = 'synex_core stopping'
                        })
                    end
                end
                local coreEpoch = registries.owners:epoch(coreResource)
                if registries.owners:isEpoch(coreResource, coreEpoch) then
                    lifecycle.reload:quiesce(coreResource, coreEpoch, {
                        timeoutMs = 0,
                        pollMs = ownerDrainPollMs,
                        reason = 'synex_core stopping'
                    })
                end
                current = lifecycle.core:get()
                if current ~= 'STOPPING' and current ~= 'STOPPED' then lifecycle.core:transition('STOPPING', 'resource stop') end
                if lifecycle.core:get() == 'STOPPING' then lifecycle.core:transition('STOPPED', 'resource stopped') end
                local _, stoppedError = persistence.instances:setStatus('stopped')
                if stoppedError then logger:error('instance stopped status failed', { code = stoppedError.code }) end
                return
            end
            reloadSnapshots[resource] = nil
            local epoch = registries.owners:epoch(resource)
            local report = { cleaned = 0, aborted = 0, errors = {} }
            if registries.owners:isEpoch(resource, epoch) then
                local options = {
                    timeoutMs = ownerDrainTimeoutMs,
                    pollMs = ownerDrainPollMs,
                    reason = 'resource stop'
                }
                if supportsStateHandoff(resource) then options.capture = captureStateHandoff end
                local quiesceReport, quiesceError = lifecycle.reload:quiesce(resource, epoch, options)
                if quiesceReport then
                    report = quiesceReport.cleanup
                    for _, abortError in ipairs(quiesceReport.abortErrors) do
                        report.errors[#report.errors + 1] = {
                            kind = 'operation_abort',
                            token = abortError.token,
                            error = abortError.error
                        }
                    end
                    if quiesceReport.snapshot then reloadSnapshots[resource] = quiesceReport.snapshot end
                    if quiesceReport.timedOut then
                        logger:warn('resource drain timed out; pending owner work was aborted', {
                            resource = resource,
                            epoch = epoch,
                            aborted = quiesceReport.aborted,
                            timeoutMs = ownerDrainTimeoutMs
                        })
                    end
                    if quiesceReport.snapshotError then
                        logger:error('resource state handoff capture failed', {
                            resource = resource,
                            epoch = epoch,
                            code = quiesceReport.snapshotError.code,
                            message = quiesceReport.snapshotError.message
                        })
                    end
                else
                    logger:error('resource quiesce failed', {
                        resource = resource,
                        epoch = epoch,
                        code = quiesceError.code,
                        message = quiesceError.message
                    })
                    report = registries.owners:purge(resource, epoch, 'resource stop fallback cleanup')
                end
            end
            local cachePrefix = resource .. ':'
            for key in pairs(facadeCache) do if key:sub(1, #cachePrefix) == cachePrefix then facadeCache[key] = nil end end
            registries.resources:setState(resource, 'STOPPED', {
                status = 'UNHEALTHY', reasons = { { code = 'RESOURCE_STOPPED', message = 'Resource is stopped.' } }
            })
            refreshDependencyHealth(resource)
            if #report.errors > 0 then logger:error('resource cleanup completed with errors', { resource = resource, report = report }) end
        end)
        commands:bind()
        return true
    end

    local function advance(target, operation)
        local _, transitionError = lifecycle.core:transition(target, operation)
        if transitionError then error(transitionError.message) end
    end

    function runtime:start()
        local ok, err = xpcall(function()
            advance('CONFIGURING', 'configuration loaded')
            advance('DATABASE_CONNECTING', 'connecting database')
            local oxmysqlVersion = platform.resourceMetadata('oxmysql', 'version', 0)
            local minimumOxmysqlVersion = defaultConfig.database.minimumOxmysqlVersion or '2.14.1'
            if type(oxmysqlVersion) ~= 'string' or not foundation.semverSatisfies(oxmysqlVersion, '>=' .. minimumOxmysqlVersion) then
                error(('oxmysql %s or newer is required; detected %s'):format(minimumOxmysqlVersion, tostring(oxmysqlVersion)))
            end
            local utcSession, utcSessionError = persistence.database:validateUtcSession()
            if not utcSession then error(utcSessionError.message) end
            local bootstrapped, bootstrapError = persistence.migrations:bootstrap()
            if not bootstrapped then error(bootstrapError.message) end
            advance('MIGRATING', 'database connected')
            local lease, leaseError = persistence.migrations:acquireLease()
            if not lease then error(leaseError.message) end
            local discovered, discoveryError = discoverAll()
            if not discovered then error(discoveryError.message) end
            local names = {}
            for name in pairs(manifests) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local applied, migrationError = persistence.migrations:apply(name, manifests[name].migrations)
                if not applied then error(migrationError.message) end
            end
            local released, releaseError = persistence.migrations:releaseLease()
            if not released then error(releaseError.message) end
            local instanceRegistered, instanceRegistrationError = persistence.instances:register(defaultConfig.instanceName)
            if not instanceRegistered then error(instanceRegistrationError.message) end
            local rbacHydrated, rbacHydrationError = security.rbac:hydrate()
            if not rbacHydrated then error(rbacHydrationError.message) end
            advance('DISCOVERING_RESOURCES', 'migrations applied')
            advance('VALIDATING_CONTRACTS', 'resource manifests discovered')
            -- Generated contracts were validated when the registry was constructed.
            advance('VALIDATING_CAPABILITIES', 'contracts validated')
            advance('STARTING_SERVICES', 'capabilities and dependencies validated')
            local registered, registrationError = registerCoreContracts()
            if not registered then error(registrationError.message) end
            local serviceToken, serviceRegistrationError = registerCoreServices()
            if not serviceToken then error(serviceRegistrationError.message) end
            local _, criticalFindings = refreshDependencyHealth()
            if criticalFindings > 0 then error('critical Synex live dependencies, providers, or capability grants are unavailable') end
            local coreEpoch = registries.owners:epoch(coreResource)
            local function scheduleEvery(intervalMs, handler, name)
                local token, scheduleError = lifecycle.scheduler:every(
                    coreResource, coreEpoch, intervalMs, handler, { name = name })
                if not token then error(scheduleError.message) end
                return token
            end
            if defaultConfig.features.durableEvents then
                scheduleEvery(1000, function()
                    local report, dispatchError = reliability.outbox:dispatchBatch(function(event)
                        local _, eventError = messaging.events:publishOutbox(
                            coreResource, coreEpoch, event.eventType, event.payload, {
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
            advance(postBootCritical > 0 and 'DEGRADED' or 'READY',
                postBootCritical > 0
                    and 'kernel services started; critical foundations are pending'
                    or 'kernel services and critical foundations started')
            local instanceStatus = postBootCritical > 0 and 'degraded' or 'ready'
            local instanceReady, instanceReadyError = persistence.instances:setStatus(instanceStatus)
            if not instanceReady then error(instanceReadyError.message) end
            lastInstanceStatus = instanceStatus
            instanceStatusInitialized = true
            lifecycle.core:setCriticalFoundationsValidated(
                postBootCritical == 0 and lifecycle.core:get() == 'READY'
                    and next(lifecycle.core:snapshot().reasons) == nil)
            local _, coreHealthError = synchronizeCoreResourceHealth()
            if coreHealthError then error(coreHealthError.message) end
            logger:info('Synex core kernel services started', {
                apiVersion = SynexProtocol.api,
                instanceId = defaultConfig.instanceId,
                state = lifecycle.core:get()
            })
        end, debug.traceback)
        if not ok then
            persistence.migrations:releaseLease()
            persistence.instances:setStatus('degraded')
            local current = lifecycle.core:get()
            if current ~= 'FAILED' and current ~= 'STOPPING' and current ~= 'STOPPED' then lifecycle.core:transition('FAILED', 'boot failure') end
            synchronizeCoreResourceHealth()
            logger:fatal('Synex core failed to start', { error = tostring(err) })
            return nil, foundation.error('BOOT_FAILED', 'Synex core failed to start.')
        end
        return true, nil
    end

    return runtime
end
