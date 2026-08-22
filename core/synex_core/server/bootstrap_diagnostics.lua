local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapDiagnostics = function(deps)
    local runtime = assert(deps.runtime, 'bootstrap diagnostics requires runtime')
    local reloadSnapshots = assert(deps.reloadSnapshots, 'bootstrap diagnostics requires reload snapshots')
    local defaultConfig = assert(deps.defaultConfig, 'bootstrap diagnostics requires configuration')
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local stateService = assert(deps.stateService, 'bootstrap diagnostics requires state service')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local persistence = assert(deps.persistence, 'bootstrap diagnostics requires persistence')
    local platform = assert(deps.platform, 'bootstrap diagnostics requires platform')
    local contractSystem = assert(deps.contractSystem, 'bootstrap diagnostics requires contracts')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local identity = assert(deps.identity, 'bootstrap diagnostics requires identity')
    local sagaRuntime = assert(deps.sagaRuntime, 'bootstrap diagnostics requires saga runtime')

    local function boundedArray(values, maximum)
        local result = {}
        for index = 1, math.min(#values, maximum or 256) do result[index] = foundation.copy(values[index]) end
        return result
    end

    local function dependencySnapshot(graph, maximum)
        local entries = {}
        for service, providers in pairs((graph or {}).providers or {}) do
            for resource, version in pairs(providers) do
                entries[#entries + 1] = { direction = 'provide', resource = resource, service = service, version = version }
            end
        end
        for resource, requirements in pairs((graph or {}).consumers or {}) do
            for service, requirement in pairs(requirements) do
                entries[#entries + 1] = {
                    direction = 'require', resource = resource, service = service,
                    range = requirement.range, optional = requirement.optional == true
                }
            end
        end
        table.sort(entries, function(a, b)
            if a.resource == b.resource then
                if a.service == b.service then return a.direction < b.direction end
                return a.service < b.service
            end
            return a.resource < b.resource
        end)
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function serviceSnapshot(services, maximum)
        local entries = {}
        for key, providers in pairs(services or {}) do
            for resource, provider in pairs(providers) do
                entries[#entries + 1] = {
                    key = key, resource = resource, version = provider.version,
                    stability = provider.stability, health = provider.health, circuit = provider.circuit
                }
            end
        end
        table.sort(entries, function(a, b)
            if a.key == b.key then return a.resource < b.resource end
            return a.key < b.key
        end)
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function resourceSnapshot(resources, maximum)
        local entries = {}
        for _, resource in ipairs(resources or {}) do
            entries[#entries + 1] = {
                name = resource.name,
                state = resource.state,
                epoch = resource.epoch,
                version = resource.manifest and resource.manifest.version or nil,
                critical = resource.manifest and resource.manifest.critical == true or false,
                health = foundation.copy(resource.health)
            }
        end
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function workerSnapshot(workers, maximum)
        local entries = {}
        for _, worker in ipairs(workers or {}) do
            entries[#entries + 1] = {
                name = worker.name, resource = worker.resource, intervalMs = worker.intervalMs,
                recurring = worker.recurring, health = worker.health, lastRun = worker.lastRun,
                durationMs = worker.durationMs, lastError = worker.lastError, runs = worker.runs
            }
        end
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function selectedMetrics(prefixes, maximum)
        local snapshot = foundation.metrics:snapshot()
        local output = { values = {}, histograms = {}, truncated = false }
        local count = 0
        local function include(key)
            for _, prefix in ipairs(prefixes) do if key:sub(1, #prefix) == prefix then return true end end
            return false
        end
        local keys = {}
        for key in pairs(snapshot.values) do if include(key) then keys[#keys + 1] = { kind = 'values', key = key } end end
        for key in pairs(snapshot.histograms) do if include(key) then keys[#keys + 1] = { kind = 'histograms', key = key } end end
        table.sort(keys, function(a, b) if a.key == b.key then return a.kind < b.kind end return a.key < b.key end)
        for _, item in ipairs(keys) do
            count = count + 1
            if count > (maximum or 128) then output.truncated = true break end
            output[item.kind][item.key] = foundation.copy(snapshot[item.kind][item.key])
        end
        return output
    end

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
            features = foundation.copy(defaultConfig.features),
            reload = { pendingStateHandoffs = pendingHandoffs }
        }
    end

    function runtime:controlSnapshot()
        local contracts = {}
        for _, contract in ipairs(contractSystem.registry:list()) do
            contracts[#contracts + 1] = {
                name = contract.name,
                version = contract.version,
                provider = contract.provider,
                network = contract.network,
                stability = contract.stability,
                capability = contract.capability
            }
        end
        local capabilities = {}
        for resource, entry in pairs(security.capabilities:snapshot()) do
            local requested = {}
            for capability, enabled in pairs(entry.requested or {}) do if enabled then requested[#requested + 1] = capability end end
            table.sort(requested)
            capabilities[#capabilities + 1] = {
                resource = resource,
                requested = boundedArray(requested, 128),
                allow = boundedArray((entry.policy and entry.policy.allow) or {}, 128),
                deny = boundedArray((entry.policy and entry.policy.deny) or {}, 128)
            }
        end
        table.sort(capabilities, function(a, b) return a.resource < b.resource end)
        local runtimeSnapshot = self:snapshot()
        local migrationSnapshot, migrationError = persistence.migrations:snapshot(256)
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
            dependencies = dependencySnapshot(runtimeSnapshot.dependencies, 512),
            contracts = boundedArray(contracts, 256),
            capabilities = boundedArray(capabilities, 256),
            rpc = messaging.network:snapshot(),
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
            tracing = { auditCorrelation = true, spanStore = false },
            compatibility = { deprecations = runtimeSnapshot.deprecations },
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
                or ('%d role(s), %d active assignment(s), %d cached subject(s)'):format(
                    rbacSummary.roles, rbacSummary.activeAssignments, rbac.cachedSubjects))
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
            ('%d handler(s); %d persisted saga(s)'):format(#sagaSnapshot.handlers, tonumber(sagaPersistence.total) or 0))
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
