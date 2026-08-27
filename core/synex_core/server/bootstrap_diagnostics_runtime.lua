local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapDiagnosticsRuntime = function(deps, shared)
    local runtime = assert(deps.runtime, 'bootstrap diagnostics requires runtime')
    local reloadSnapshots = assert(deps.reloadSnapshots,
        'bootstrap diagnostics requires reload snapshots')
    local defaultConfig = assert(deps.defaultConfig,
        'bootstrap diagnostics requires configuration')
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local stateService = assert(deps.stateService,
        'bootstrap diagnostics requires state service')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local persistence = assert(deps.persistence,
        'bootstrap diagnostics requires persistence')
    local platform = assert(deps.platform, 'bootstrap diagnostics requires platform')
    local contractSystem = assert(deps.contractSystem,
        'bootstrap diagnostics requires contracts')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local identity = assert(deps.identity, 'bootstrap diagnostics requires identity')
    local sagaRuntime = assert(deps.sagaRuntime,
        'bootstrap diagnostics requires saga runtime')
    local boundedArray = assert(shared.boundedArray)
    local contractEntries = assert(shared.contractEntries)
    local capabilityEntries = assert(shared.capabilityEntries)
    local resourceSnapshot = assert(shared.resourceSnapshot)
    local dependencySnapshot = assert(shared.dependencySnapshot)
    local rpcHandlerSnapshot = assert(shared.rpcHandlerSnapshot)
    local serviceSnapshot = assert(shared.serviceSnapshot)
    local selectedMetrics = assert(shared.selectedMetrics)
    local workerSnapshot = assert(shared.workerSnapshot)
    local providerDiscovery = assert(shared.providerDiscovery)

    function runtime:snapshot()
        local pendingHandoffs = 0
        for _ in pairs(reloadSnapshots) do pendingHandoffs = pendingHandoffs + 1 end
        return {
            apiVersion = SynexProtocol.api,
            wireVersion = SynexProtocol.wire,
            instanceId = defaultConfig.instanceId,
            environment = defaultConfig.environment,
            lifecycle = lifecycle.core:snapshot(),
            resources = registries.resources:list(),
            players = registries.players:summary(),
            services = messaging.services:snapshot(),
            dependencies = lifecycle.dependencies:snapshot(),
            states = stateService:snapshot(),
            schedules = lifecycle.scheduler:count(),
            workers = boundedArray(lifecycle.scheduler:snapshot(), 256),
            queue = identity.connections:snapshot(),
            characterCache = identity.characters:cacheSnapshot(),
            cluster = persistence.instances:snapshot(),
            permissions = security.rbac:snapshot(),
            deprecations = boundedArray(messaging.deprecations:snapshot(), 256),
            sagas = sagaRuntime:snapshot(),
            controlProviders = providerDiscovery(),
            features = foundation.copy(defaultConfig.features),
            reload = { pendingStateHandoffs = pendingHandoffs }
        }
    end

    function runtime:controlSnapshot()
        local contracts = contractEntries()
        local capabilities = capabilityEntries()
        local runtimeSnapshot = self:snapshot()
        local migrationSnapshot, migrationError = persistence.migrations:snapshot(256)
        local traceHistory = type(foundation.tracing) == 'table'
            and foundation.isCallable(foundation.tracing.list)
            and foundation.tracing:list({ limit = 1 }) or nil
        return {
            schemaVersion = 1,
            generatedAt = foundation.utcIso(),
            runtime = {
                apiVersion = runtimeSnapshot.apiVersion,
                wireVersion = runtimeSnapshot.wireVersion,
                instanceId = runtimeSnapshot.instanceId,
                environment = runtimeSnapshot.environment,
                lifecycle = runtimeSnapshot.lifecycle,
                cluster = runtimeSnapshot.cluster,
                queue = runtimeSnapshot.queue
            },
            resources = resourceSnapshot(runtimeSnapshot.resources, 256),
            dependencies = dependencySnapshot(runtimeSnapshot.dependencies, 512,
                runtimeSnapshot.resources),
            contracts = boundedArray(contracts, 256),
            capabilities = boundedArray(capabilities, 256),
            rpc = {
                network = messaging.network:snapshot(),
                handlers = boundedArray(rpcHandlerSnapshot(), 256)
            },
            events = boundedArray(messaging.events:snapshot(), 256),
            hooks = boundedArray(messaging.hooks:snapshot(), 256),
            services = serviceSnapshot(runtimeSnapshot.services, 512),
            database = selectedMetrics({ 'synex_db_' }, 128),
            migrations = migrationSnapshot or { available = false, error = migrationError and migrationError.code or 'UNAVAILABLE' },
            sessions = runtimeSnapshot.players,
            characters = { cache = runtimeSnapshot.characterCache },
            workers = workerSnapshot(runtimeSnapshot.workers, 256),
            audit = {
                search = { available = true, kinds = { 'trace', 'character', 'transaction', 'resource' }, maximumLimit = 64 },
                payloadsExposed = false
            },
            tracing = {
                auditCorrelation = true,
                spanStore = traceHistory ~= nil,
                retained = traceHistory and traceHistory.retained or 0,
                maximumRetained = traceHistory and traceHistory.maximumRetained or 0,
                payloadsExposed = false
            },
            compatibility = { deprecations = runtimeSnapshot.deprecations },
            controlProviders = runtimeSnapshot.controlProviders,
            sagas = runtimeSnapshot.sagas,
            security = {
                permissions = runtimeSnapshot.permissions,
                deprecations = runtimeSnapshot.deprecations,
                metrics = selectedMetrics({ 'synex_capability_', 'synex_rate_limit_', 'synex_rbac_' }, 128)
            },
            performance = selectedMetrics({ 'synex_contract_', 'synex_db_', 'synex_hook_' }, 192)
        }, nil
    end

    function runtime:doctor()
        local checks = {}
        local function add(name, status, detail)
            checks[#checks + 1] = { name = name, status = status, detail = detail }
        end
        local databaseValue, databaseError = persistence.database:scalar('SELECT 1', {})
        add('database', databaseError and 'FAIL' or 'PASS', databaseError and databaseError.code or tostring(databaseValue))
        local utcSession, utcSessionError = persistence.database:validateUtcSession()
        add('database-utc', utcSession and 'PASS' or 'FAIL',
            utcSession and 'CURRENT_TIMESTAMP resolves to UTC' or utcSessionError.code)
        local isolationLevels = {
            ['1'] = 'REPEATABLE READ',
            ['2'] = 'READ COMMITTED',
            ['3'] = 'READ UNCOMMITTED',
            ['4'] = 'SERIALIZABLE'
        }
        local isolationLevel = platform.getConvar('mysql_transaction_isolation_level', '2')
        local isolationName = isolationLevels[isolationLevel]
        add('database-transaction-isolation', isolationLevel == '2' and 'PASS' or 'FAIL',
            isolationName and ('current Cfx ConVar level %s (%s)'):format(isolationLevel, isolationName)
                or 'mysql_transaction_isolation_level must be an integer from 1 through 4')
        local dirtyMigrations, dirtyMigrationError = persistence.database:scalar([[SELECT COUNT(*)
            FROM `synex_schema_migration_attempts` WHERE `state` <> 'applied']], {})
        local dirtyCount = tonumber(dirtyMigrations) or 0
        add('migrations', dirtyMigrationError and 'FAIL' or (dirtyCount > 0 and 'FAIL' or 'PASS'),
            dirtyMigrationError and dirtyMigrationError.code or ('%d incomplete/failed attempt(s)'):format(dirtyCount))
        local oxmysqlVersion = platform.resourceMetadata('oxmysql', 'version', 0)
        local oxmysqlHealthy = type(oxmysqlVersion) == 'string'
            and foundation.semverSatisfies(oxmysqlVersion, '>=' .. (defaultConfig.database.minimumOxmysqlVersion or '2.14.1'))
        add('oxmysql', oxmysqlHealthy and 'PASS' or 'FAIL', tostring(oxmysqlVersion or 'unavailable'))
        local dependencyFindings = lifecycle.dependencies:validate()
        local dependencyFailure = false
        for _, finding in ipairs(dependencyFindings) do if finding.severity == 'error' then dependencyFailure = true break end end
        add('service-dependencies', dependencyFailure and 'FAIL' or (#dependencyFindings > 0 and 'WARN' or 'PASS'),
            ('%d finding(s)'):format(#dependencyFindings))
        local contractCount = #contractSystem.registry:list()
        add('contracts', contractCount > 0 and 'PASS' or 'FAIL', ('%d registered contract(s)'):format(contractCount))
        local lifecycleSnapshot = lifecycle.core:snapshot()
        local lifecycleReasonCount = 0
        for _ in pairs(lifecycleSnapshot.reasons or {}) do lifecycleReasonCount = lifecycleReasonCount + 1 end
        local lifecycleStatus = not lifecycleSnapshot.operational and 'FAIL'
            or (lifecycleSnapshot.state ~= 'READY' or lifecycleSnapshot.playerAdmission ~= true
                or lifecycleReasonCount > 0) and 'WARN' or 'PASS'
        add('lifecycle', lifecycleStatus,
            ('%s; admission=%s; %d health reason(s)'):format(
                lifecycleSnapshot.state,
                lifecycleSnapshot.playerAdmission == true and 'open' or 'blocked', lifecycleReasonCount))
        local cluster = persistence.instances:snapshot()
        add('cluster-instances', cluster.stale > 0 and 'WARN' or 'PASS',
            ('%d healthy, %d stale, %d total'):format(cluster.healthy, cluster.stale, cluster.total))
        local queue = identity.connections:snapshot()
        local players = registries.players:summary()
        local pendingProblem = players.expiredPendingConnections > 0 or players.pendingAgeCapped == true
        add('connection-queue', queue.queued >= queue.maximumQueued and 'FAIL' or (pendingProblem and 'WARN' or 'PASS'),
            ('%d/%d queued; policy=%s; %d pending; oldest=%dms%s; expired=%d'):format(
                queue.queued, queue.maximumQueued, queue.duplicatePolicy,
                players.pendingConnections, players.oldestPendingAgeMs,
                players.pendingAgeCapped and '+' or '', players.expiredPendingConnections))
        local rbac = security.rbac:snapshot()
        local rbacSummary, rbacSummaryError = persistence.rbac:summary()
        add('rbac', rbacSummaryError and 'FAIL' or (rbac.hydrated and rbac.persistent and 'PASS' or 'WARN'),
            rbacSummaryError and rbacSummaryError.code
                or ('%d%s role(s), %d%s active assignment(s), %d cached subject(s)'):format(
                    rbacSummary.roles, rbacSummary.rolesTruncated and '+' or '',
                    rbacSummary.activeAssignments,
                    rbacSummary.activeAssignmentsTruncated and '+' or '', rbac.cachedSubjects))
        local unhealthyWorkers = 0
        for _, worker in ipairs(lifecycle.scheduler:snapshot()) do
            if worker.health == 'DEGRADED' or worker.health == 'UNHEALTHY' then unhealthyWorkers = unhealthyWorkers + 1 end
        end
        add('workers', unhealthyWorkers > 0 and 'WARN' or 'PASS', ('%d unhealthy worker(s)'):format(unhealthyWorkers))
        local deprecated = messaging.deprecations:snapshot()
        add('deprecated-apis', #deprecated > 0 and 'WARN' or 'PASS', ('%d usage record(s)'):format(#deprecated))
        local sagaSnapshot = sagaRuntime:snapshot()
        local sagaPersistence = sagaSnapshot.persisted or {}
        add('saga-worker', sagaPersistence.available == false and 'WARN' or 'PASS',
            ('%d handler(s); %d%s persisted saga(s)'):format(
                #sagaSnapshot.handlers, tonumber(sagaPersistence.total) or 0,
                sagaPersistence.truncated and '+' or ''))
        local resources = registries.resources:summary()
        local resourceProblems = resources.degraded + resources.unhealthy + resources.unknown
        add('resource-health', resourceProblems > 0 and 'WARN' or 'PASS',
            ('%d healthy, %d degraded, %d unhealthy, %d unknown'):format(
                resources.healthy, resources.degraded, resources.unhealthy, resources.unknown))
        local overall = 'PASS'
        for _, check in ipairs(checks) do
            if check.status == 'FAIL' then overall = 'FAIL' break end
            if check.status == 'WARN' then overall = 'WARN' end
        end
        return { status = overall, generatedAt = foundation.utcIso(), checks = checks }, nil
    end

    return runtime
end
