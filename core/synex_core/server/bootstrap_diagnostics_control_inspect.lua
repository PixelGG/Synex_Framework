local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.createBootstrapControlInspectOperation = function(deps, shared, control)
    local runtime = assert(deps.runtime, 'bootstrap diagnostics requires runtime')
    local defaultConfig = assert(deps.defaultConfig,
        'bootstrap diagnostics requires configuration')
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local persistence = assert(deps.persistence,
        'bootstrap diagnostics requires persistence')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local platform = assert(deps.platform, 'bootstrap diagnostics requires platform')
    local contractSystem = assert(deps.contractSystem,
        'bootstrap diagnostics requires contracts')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local identity = assert(deps.identity, 'bootstrap diagnostics requires identity')
    local reliability = deps.reliability
    local coreResource = deps.coreResource
    local boundedArray = assert(shared.boundedArray)
    local rpcHandlerSnapshot = assert(shared.rpcHandlerSnapshot)
    local rpcMetricRows = assert(shared.rpcMetricRows)
    local resourceManifestSummary = assert(shared.resourceManifestSummary)
    local dependencyImpact = assert(shared.dependencyImpact)
    local schemaSummary = assert(shared.schemaSummary)
    local selectedMetrics = assert(shared.selectedMetrics)
    local serviceSnapshot = assert(shared.serviceSnapshot)
    local safeSession = assert(shared.safeSession)
    local contractEntries = assert(shared.contractEntries)
    local boundedSortedStrings = assert(shared.boundedSortedStrings)
    local workerSnapshot = assert(shared.workerSnapshot)
    local requestKeysAllowed = assert(shared.requestKeysAllowed)
    local diagnosticsStartedAtMs = assert(shared.diagnosticsStartedAtMs)
    local controlLifecycleSnapshot = assert(control.controlLifecycleSnapshot)
    local controlSeverity = assert(control.controlSeverity)
    local characterDomainRelations = assert(control.characterDomainRelations)
    local coreInspectViews = assert(control.coreInspectViews)
    local coreInspectIdViews = assert(control.coreInspectIdViews)
    local validCoreLimit = assert(control.validCoreLimit)
    local emptyControlFilters = assert(control.emptyControlFilters)
    local unavailableSection = assert(control.unavailableSection)
    local maximumSafeMetricCounter = 9007199254740991

    local function databaseCounterProjection(snapshot, metricName, unavailableReason)
        local values = type(snapshot) == 'table' and snapshot.values or nil
        local prefix = metricName .. ':'
        local total, series, saturated = 0, 0, false
        if type(values) == 'table' then
            for key, value in pairs(values) do
                if type(key) == 'string' and key:sub(1, #prefix) == prefix
                    and type(value) == 'number' and value == value
                    and value >= 0 and value < math.huge then
                    local bounded = math.min(maximumSafeMetricCounter,
                        math.floor(value))
                    if total >= maximumSafeMetricCounter - bounded then
                        total, saturated = maximumSafeMetricCounter, true
                    else
                        total = total + bounded
                    end
                    series = series + 1
                end
            end
        end
        if series == 0 then
            return { status = 'UNAVAILABLE', reason = unavailableReason }
        end
        return {
            status = 'AVAILABLE', total = total, series = series,
            saturated = saturated
        }
    end

    return function(request, context)
        if not requestKeysAllowed(request, {
            view = true,
            limit = true,
            id = true,
            cursor = true,
            filters = true,
            sort = true
        })
            or not coreInspectViews[request.view] then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core inspect requires a supported section view.')
        end
        if not validCoreLimit(request.limit, 50)
            or (request.id ~= nil and (type(request.id) ~= 'string'
                or #request.id < 1 or #request.id > 128
                or request.id:find('[%z\1-\31\127]')))
            or (request.cursor ~= nil and (type(request.cursor) ~= 'string'
                or #request.cursor < 1 or #request.cursor > 20
                or not request.cursor:match('^[1-9]%d*$'))) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core inspect id, cursor, or limit is invalid.')
        end
        if request.cursor ~= nil and request.view ~= 'database' then
            return unavailableSection(request.view,
                'CORE_SECTION_CURSOR_UNAVAILABLE')
        end
        local capabilityResource = nil
        if request.view == 'capability' and type(request.filters) == 'table'
            and next(request.filters) ~= nil then
            if not requestKeysAllowed(request.filters, { resource = true })
                or type(request.filters.resource) ~= 'string'
                or #request.filters.resource < 2 or #request.filters.resource > 64
                or not request.filters.resource:match('^[a-z][a-z0-9_]*$') then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Capability explain accepts only one exact resource filter.')
            end
            capabilityResource = request.filters.resource
        elseif not emptyControlFilters(request.filters) then
            return unavailableSection(request.view,
                'CORE_SECTION_INSPECTION_UNAVAILABLE')
        end
        if request.sort ~= nil then
            return unavailableSection(request.view,
                'CORE_SECTION_INSPECTION_UNAVAILABLE')
        end
        if coreInspectIdViews[request.view] and request.id == nil then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'This Core inspector requires an exact bounded id.')
        end
        if not coreInspectIdViews[request.view] and request.id ~= nil then
            return unavailableSection(request.view,
                'CORE_SECTION_ID_INSPECTION_UNAVAILABLE')
        end
        if request.view == 'runtime' then
            local lifecycleSnapshot = controlLifecycleSnapshot()
            local coreRegistration = registries.resources:get(coreResource)
            local frameworkVersion = coreRegistration
                and coreRegistration.manifest
                and coreRegistration.manifest.version or nil
            local databaseHealth = runtime.databaseRuntimeHealth
            local databaseSnapshot = databaseHealth
                and databaseHealth:snapshot() or {
                    available = false,
                    status = 'UNAVAILABLE',
                    reason = 'DATABASE_RUNTIME_HEALTH_NOT_INITIALIZED'
                }
            local outboxSnapshot, outboxError = nil, nil
            if reliability and reliability.outbox
                and foundation.isCallable(reliability.outbox.snapshot) then
                outboxSnapshot, outboxError = reliability.outbox:snapshot({ limit = 10 })
            end
            return {
                view = 'runtime',
                frameworkVersion = frameworkVersion,
                apiVersion = SynexProtocol.api,
                wireVersion = SynexProtocol.wire,
                uptimeMs = math.max(0,
                    foundation.monotonicMs() - diagnosticsStartedAtMs),
                instanceId = defaultConfig.instanceId,
                environment = defaultConfig.environment,
                health = controlSeverity(lifecycle.core:healthStatus()),
                lifecycle = lifecycleSnapshot,
                cluster = persistence.instances:snapshot(),
                queue = identity.connections:snapshot(),
                schedules = lifecycle.scheduler:count(),
                workers = workerSnapshot(lifecycle.scheduler:snapshot(), 50),
                features = foundation.copy(defaultConfig.features),
                oneSync = type(platform.getConvar) == 'function'
                    and { status = 'OBSERVED', value = platform.getConvar('onesync', 'off') }
                    or { status = 'UNAVAILABLE', reason = 'CONVAR_READER_UNAVAILABLE' },
                database = databaseSnapshot,
                outbox = outboxSnapshot or {
                    status = 'UNAVAILABLE',
                    reason = outboxError and outboxError.code
                        or 'OUTBOX_BACKLOG_SNAPSHOT_UNAVAILABLE',
                    payloadsExposed = false,
                    headersExposed = false
                }
            }, nil
        end
        if request.view == 'instances' then
            local cluster = persistence.instances:snapshot()
            local instanceLifecycle, instanceReasonCount = controlLifecycleSnapshot()
            local persistedDetail, persistedError = nil, nil
            if foundation.isCallable(persistence.instances.detail) then
                persistedDetail, persistedError = persistence.instances:detail()
            end
            return {
                view = 'instances',
                status = controlSeverity(lifecycle.core:healthStatus()),
                current = {
                    id = defaultConfig.instanceId,
                    environment = defaultConfig.environment,
                    uptimeMs = math.max(0,
                        foundation.monotonicMs() - diagnosticsStartedAtMs),
                    persisted = persistedDetail or {
                        status = 'UNAVAILABLE',
                        reason = persistedError and persistedError.code
                            or 'INSTANCE_DETAIL_SNAPSHOT_UNAVAILABLE'
                    },
                    activeSessions = registries.players:summary().activeSessions,
                    lifecycle = {
                        state = instanceLifecycle.state,
                        revision = instanceLifecycle.revision,
                        operational = instanceLifecycle.operational,
                        playerAdmission = instanceLifecycle.playerAdmission,
                        reasonCount = instanceReasonCount,
                        reasonsTruncated = instanceLifecycle.reasonsTruncated
                    }
                },
                cluster = cluster,
                remoteInstanceDetails = {
                    status = 'UNAVAILABLE',
                    reason = 'REMOTE_INSTANCE_DETAIL_SNAPSHOT_UNAVAILABLE'
                }
            }, nil
        end
        if request.view == 'health_timeline' then
            local snapshot, reasonCount = controlLifecycleSnapshot()
            local timeline = {}
            for _, transition in ipairs(snapshot.recentTransitions) do
                timeline[#timeline + 1] = {
                    timestamp = transition.at,
                    status = transition.to,
                    label = ('%s to %s'):format(transition.from, transition.to),
                    detail = transition.reason,
                    revision = transition.revision
                }
            end
            return {
                view = 'health_timeline',
                status = controlSeverity(lifecycle.core:healthStatus()),
                state = snapshot.state,
                revision = snapshot.revision,
                operational = snapshot.operational,
                playerAdmission = snapshot.playerAdmission,
                activeReasons = boundedArray(snapshot.reasons, 32),
                items = timeline,
                hasMore = false,
                truncated = reasonCount > 32
                    or snapshot.transitionsTruncated
            }, nil
        end
        if request.view == 'incident_window' then
            local snapshot, reasonCount = controlLifecycleSnapshot()
            local unhealthyWorkers = {}
            local recentTransitions = {}
            local firstTransition = math.max(1, #snapshot.recentTransitions - 15)
            for index = firstTransition, #snapshot.recentTransitions do
                local transition = snapshot.recentTransitions[index]
                recentTransitions[#recentTransitions + 1] = {
                    timestamp = transition.at,
                    status = transition.to,
                    label = ('%s to %s'):format(transition.from, transition.to),
                    detail = transition.reason,
                    revision = transition.revision
                }
            end
            for _, worker in ipairs(lifecycle.scheduler:snapshot()) do
                if worker.health == 'DEGRADED' or worker.health == 'UNHEALTHY' then
                    unhealthyWorkers[#unhealthyWorkers + 1] = {
                        name = worker.name,
                        resource = worker.resource,
                        health = worker.health,
                        durationMs = worker.durationMs,
                        lastError = worker.lastError,
                        lastRun = worker.lastRun
                    }
                end
            end
            table.sort(unhealthyWorkers, function(left, right)
                return table.concat({ left.resource or '', left.name or '' }, '|')
                    < table.concat({ right.resource or '', right.name or '' }, '|')
            end)
            return {
                view = 'incident_window',
                status = controlSeverity(lifecycle.core:healthStatus()),
                state = snapshot.state,
                activeReasons = boundedArray(snapshot.reasons, 16),
                items = recentTransitions,
                unhealthyWorkers = boundedArray(unhealthyWorkers, 16),
                truncated = reasonCount > 16
                    or #snapshot.recentTransitions > 16
                    or #unhealthyWorkers > 16,
                persistedIncidentHistory = {
                    status = 'UNAVAILABLE',
                    reason = 'PERSISTED_INCIDENT_HISTORY_UNAVAILABLE'
                },
                crossProviderCorrelation = {
                    status = 'UNAVAILABLE',
                    reason = 'CROSS_PROVIDER_INCIDENT_CORRELATION_UNAVAILABLE'
                }
            }, nil
        end
        if request.view == 'resource' then
            local resource = registries.resources:get(request.id)
            if not resource then
                return nil, foundation.error('RESOURCE_NOT_FOUND',
                    'The requested Core resource is not registered.')
            end
            local reasonCount = 0
            for _ in pairs((resource.health and resource.health.reasons) or {}) do
                reasonCount = reasonCount + 1
            end
            local contracts = {}
            for _, contract in ipairs(contractEntries()) do
                if contract.provider == request.id then contracts[#contracts + 1] = contract end
            end
            local capabilityEntry = security.capabilities:snapshot()[request.id]
            local capabilitySummary = nil
            if capabilityEntry then
                local requested = {}
                for capability, enabled in pairs(capabilityEntry.requested or {}) do
                    if enabled then requested[#requested + 1] = capability end
                end
                table.sort(requested)
                local denied = security.capabilities:preflight(request.id)
                capabilitySummary = {
                    requested = boundedArray(requested, 24),
                    requestedCount = #requested,
                    denied = boundedArray(denied, 24),
                    deniedCount = #denied,
                    grantedCount = math.max(0, #requested - #denied),
                    truncated = #requested > 24 or #denied > 24
                }
            end
            local deprecatedUsage = {}
            for _, usage in ipairs(messaging.deprecations:snapshot()) do
                if usage.caller == request.id then
                    deprecatedUsage[#deprecatedUsage + 1] = usage
                end
            end
            local contractLimit = math.min(request.limit or 16, 16)
            return {
                view = 'resource',
                resource = {
                    name = resource.name,
                    state = resource.state,
                    epoch = resource.epoch,
                    health = {
                        status = resource.health and resource.health.status or 'UNKNOWN',
                        reasonCount = reasonCount
                    },
                    manifest = resourceManifestSummary(resource.manifest)
                },
                contracts = boundedArray(contracts, contractLimit),
                contractsTruncated = #contracts > contractLimit,
                capabilities = capabilitySummary,
                deprecations = boundedArray(deprecatedUsage, 24),
                deprecationsTruncated = #deprecatedUsage > 24,
                impact = dependencyImpact(request.id, false)
            }, nil
        end
        if request.view == 'dependency_impact' then
            if not registries.resources:get(request.id) then
                return nil, foundation.error('RESOURCE_NOT_FOUND',
                    'The requested dependency-impact resource is not registered.')
            end
            return dependencyImpact(request.id), nil
        end
        if request.view == 'contract' then
            local requestedName, requestedVersion = request.id:match(
                '^(.-)@(%d+%.%d+%.%d+)$')
            requestedName = requestedName or request.id
            local matches = {}
            for _, contract in ipairs(contractSystem.registry:list()) do
                if contract.name == requestedName
                    and (requestedVersion == nil or contract.version == requestedVersion) then
                    if requestedVersion == nil then
                        matches[#matches + 1] = {
                            name = contract.name,
                            version = contract.version,
                            provider = contract.provider,
                            kind = contract.kind,
                            network = contract.network,
                            stability = contract.stability
                        }
                    else
                        local consumers = {}
                        for _, resource in ipairs(registries.resources:list()) do
                            for _, consumed in ipairs(
                                ((resource.manifest or {}).contracts or {}).consume or {}) do
                                if consumed == contract.name then
                                    consumers[#consumers + 1] = resource.name
                                    break
                                end
                            end
                        end
                        table.sort(consumers)
                        local errors, errorsTruncated = boundedSortedStrings(
                            contract.errors, 32)
                        matches[#matches + 1] = {
                            name = contract.name,
                            version = contract.version,
                            provider = contract.provider,
                            kind = contract.kind,
                            domain = contract.domain,
                            network = contract.network,
                            stability = contract.stability,
                            capability = contract.capability,
                            input = schemaSummary(contract.input),
                            output = schemaSummary(contract.output),
                            errors = errors,
                            errorsTruncated = errorsTruncated,
                            consumers = boundedArray(consumers, 32),
                            consumersTruncated = #consumers > 32
                        }
                    end
                end
            end
            if #matches == 0 then
                return nil, foundation.error('CONTRACT_NOT_FOUND',
                    'The requested contract or version is not registered.')
            end
            local limit = request.limit or 25
            return {
                view = 'contract',
                id = request.id,
                contracts = boundedArray(matches, limit),
                truncated = #matches > limit
            }, nil
        end
        if request.view == 'capability' then
            local requesters = {}
            local capabilitySnapshot = security.capabilities:snapshot()
            for resource, entry in pairs(capabilitySnapshot) do
                if capabilityResource == nil or resource == capabilityResource then
                    local declared = (entry.requested or {})[request.id] == true
                    local reason = nil
                    if declared then
                        for _, finding in ipairs(
                            security.capabilities:preflight(resource)) do
                            if finding.capability == request.id then
                                reason = finding.reason
                                break
                            end
                        end
                    else
                        reason = 'undeclared'
                    end
                    requesters[#requesters + 1] = {
                        resource = resource,
                        capability = request.id,
                        declared = declared,
                        granted = declared and reason == nil,
                        explicitDeny = reason == 'denied',
                        effectiveResult = declared and reason == nil
                            and 'GRANTED' or 'DENIED',
                        status = declared and reason == nil and 'GRANTED' or 'DENIED',
                        reason = reason,
                        policy = {
                            allow = boundedArray((entry.policy or {}).allow or {}, 32),
                            deny = boundedArray((entry.policy or {}).deny or {}, 32)
                        }
                    }
                end
            end
            table.sort(requesters, function(left, right)
                return left.resource < right.resource
            end)
            if #requesters == 0 then
                return nil, foundation.error('CAPABILITY_NOT_FOUND',
                    capabilityResource and 'The requested resource is not registered.'
                        or 'No registered resource is available for this capability explain.')
            end
            local limit = request.limit or 25
            return {
                view = 'capability',
                capability = request.id,
                class = security.capabilities:class(request.id),
                items = boundedArray(requesters, limit),
                hasMore = false,
                truncated = #requesters > limit
            }, nil
        end
        if request.view == 'rpc_detail' then
            local handlers, available = rpcHandlerSnapshot()
            if not available then
                return unavailableSection('rpc_detail',
                    'RPC_HANDLER_DETAIL_SNAPSHOT_UNAVAILABLE')
            end
            local matches = {}
            for _, handler in ipairs(handlers) do
                if handler.key == request.id or handler.name == request.id then
                    matches[#matches + 1] = handler
                end
            end
            if #matches == 0 then
                return nil, foundation.error('RPC_NOT_FOUND',
                    'The requested RPC handler is not registered.')
            end
            return {
                view = 'rpc_detail',
                procedure = request.id,
                status = 'AVAILABLE',
                items = boundedArray(matches, request.limit or 25),
                truncated = #matches > (request.limit or 25),
                network = messaging.network:snapshot(),
                metrics = selectedMetrics({ 'synex_contract_' }, 96)
            }, nil
        end
        if request.view == 'hook_detail' then
            local match = nil
            for _, hook in ipairs(messaging.hooks:snapshot()) do
                if hook.name == request.id then match = hook break end
            end
            if not match then
                return nil, foundation.error('HOOK_NOT_FOUND',
                    'The requested hook is not present in the bounded registry snapshot.')
            end
            return {
                view = 'hook_detail',
                hook = {
                    name = match.name,
                    handlers = match.handlers,
                    required = match.required,
                    calls = match.calls,
                    successes = match.successes,
                    failures = match.failures,
                    timeouts = match.timeouts,
                    denials = match.denials,
                    slow = match.slow == true
                },
                handlerDetails = boundedArray(match.handlerDetails or {},
                    request.limit or 25),
                truncated = #(match.handlerDetails or {}) > (request.limit or 25),
                metrics = selectedMetrics({ 'synex_hook_' }, 96)
            }, nil
        end
        if request.view == 'service_detail' then
            local providers = (messaging.services:snapshot() or {})[request.id]
            if type(providers) ~= 'table' then
                return nil, foundation.error('SERVICE_NOT_FOUND',
                    'The requested service key is not present in the registry snapshot.')
            end
            local entries = serviceSnapshot({ [request.id] = providers },
                request.limit or 25)
            local consumers = {}
            for resource, requirements in pairs(
                (lifecycle.dependencies:snapshot() or {}).consumers or {}) do
                local requirement = requirements[request.id]
                if requirement then
                    consumers[#consumers + 1] = {
                        resource = resource,
                        range = requirement.range,
                        optional = requirement.optional == true,
                        critical = requirement.critical == true
                    }
                end
            end
            table.sort(consumers, function(left, right)
                return left.resource < right.resource
            end)
            local limit = request.limit or 25
            return {
                view = 'service_detail',
                service = request.id,
                items = entries.entries,
                consumers = boundedArray(consumers, limit),
                consumersTruncated = #consumers > limit,
                hasMore = false,
                truncated = entries.truncated or #consumers > limit
            }, nil
        end
        if request.view == 'rpc' then
            local handlers, available = rpcHandlerSnapshot()
            local rows = rpcMetricRows(handlers)
            local limit = request.limit or 25
            return {
                view = 'rpc',
                network = messaging.network:snapshot(),
                status = available and 'AVAILABLE' or 'UNAVAILABLE',
                reason = available and nil
                    or 'RPC_PROCEDURE_HISTORY_UNAVAILABLE',
                items = boundedArray(rows, limit),
                truncated = #rows > limit,
                metrics = selectedMetrics({ 'synex_contract_' }, 128)
            }, nil
        end
        if request.view == 'database' then
            local databaseHealth = runtime.databaseRuntimeHealth
            local databaseMetricSnapshot = foundation.metrics:snapshot()
            local slowQueries, slowQueryError = nil, nil
            if foundation.isCallable(persistence.database.slowQueries) then
                slowQueries, slowQueryError = persistence.database:slowQueries({
                    cursor = request.cursor,
                    limit = request.limit
                })
            end
            return {
                view = 'database',
                status = controlSeverity(lifecycle.core:healthStatus()),
                runtimeHealth = databaseHealth and databaseHealth:snapshot() or {
                    available = false,
                    status = 'UNAVAILABLE',
                    reason = 'DATABASE_RUNTIME_HEALTH_NOT_INITIALIZED'
                },
                metrics = selectedMetrics({ 'synex_db_' }, 128),
                deadlocks = databaseCounterProjection(databaseMetricSnapshot,
                    'synex_db_deadlocks_total',
                    'DATABASE_DEADLOCK_METRIC_NOT_OBSERVED'),
                retries = databaseCounterProjection(databaseMetricSnapshot,
                    'synex_db_deadlock_retries_total',
                    'DATABASE_DEADLOCK_RETRY_METRIC_NOT_OBSERVED'),
                timeouts = {
                    status = 'UNAVAILABLE',
                    reason = 'DATABASE_QUERY_TIMEOUT_TELEMETRY_UNAVAILABLE'
                },
                pool = {
                    status = 'UNAVAILABLE',
                    reason = 'DATABASE_POOL_SNAPSHOT_UNAVAILABLE'
                },
                slowQueryHistory = slowQueries or {
                    status = 'UNAVAILABLE',
                    reason = slowQueryError and slowQueryError.code
                        or 'SLOW_QUERY_HISTORY_UNAVAILABLE'
                }
            }, nil
        end
        if request.view == 'session' then
            local session = registries.players:getSession(request.id)
            if not session then
                return nil, foundation.error('SESSION_NOT_FOUND',
                    'The requested active session does not exist.')
            end
            return {
                view = 'session',
                session = safeSession(session),
                rawIdentifiersExposed = false
            }, nil
        end
        if request.view == 'characters' then
            return {
                view = 'characters',
                cache = identity.characters:cacheSnapshot(),
                identifiersExposed = false
            }, nil
        end
        if request.view == 'character' then
            local character, characterError = identity.characters:get(request.id)
            if not character then return nil, characterError end
            local activeSession = registries.players:getByCharacter(request.id)
            local auditResult, auditError = reliability.audit:search({
                kind = 'character', value = request.id, limit = 1
            })
            local latest = auditResult and auditResult.entries
                and auditResult.entries[1] or nil
            return {
                view = 'character',
                character = {
                    id = character.id,
                    userId = character.userId,
                    slot = character.slot,
                    status = character.status,
                    version = character.version
                },
                activeSession = activeSession and {
                    id = activeSession.id,
                    state = activeSession.state,
                    playerSource = activeSession.source,
                    sourceGeneration = activeSession.sourceGeneration
                } or nil,
                lifecycle = {
                    currentStatus = character.status,
                    version = character.version,
                    lastTransition = latest and {
                        status = 'AVAILABLE',
                        action = latest.action,
                        occurredAt = latest.occurredAt
                    } or {
                        status = 'UNAVAILABLE',
                        reason = auditError and auditError.code
                            or 'CHARACTER_TRANSITION_NOT_RECORDED'
                    }
                },
                relatedDomains = characterDomainRelations(request.id, context),
                personalProfileExposed = false,
                metadataExposed = false
            }, nil
        end
        local deprecations = messaging.deprecations:snapshot()
        return {
            view = 'compatibility',
            deprecations = boundedArray(deprecations, 50),
            truncated = #deprecations > 50
        }, nil
    end
end
