local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.createBootstrapControlQueryOperations = function(deps, shared, control)
    local defaultConfig = assert(deps.defaultConfig,
        'bootstrap diagnostics requires configuration')
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local persistence = assert(deps.persistence,
        'bootstrap diagnostics requires persistence')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local identity = assert(deps.identity, 'bootstrap diagnostics requires identity')
    local reliability = deps.reliability
    local boundedArray = assert(shared.boundedArray)
    local resourceDependencyCycles = assert(shared.resourceDependencyCycles)
    local dependencySnapshot = assert(shared.dependencySnapshot)
    local serviceSnapshot = assert(shared.serviceSnapshot)
    local resourceSnapshot = assert(shared.resourceSnapshot)
    local selectedMetrics = assert(shared.selectedMetrics)
    local contractEntries = assert(shared.contractEntries)
    local capabilityEntries = assert(shared.capabilityEntries)
    local safeSession = assert(shared.safeSession)
    local requestKeysAllowed = assert(shared.requestKeysAllowed)
    local paginated = assert(shared.paginated)
    local providerDiscovery = assert(shared.providerDiscovery)
    local controlLifecycleSnapshot = assert(control.controlLifecycleSnapshot)
    local controlSeverity = assert(control.controlSeverity)
    local coreListViews = assert(control.coreListViews)
    local validCoreLimit = assert(control.validCoreLimit)
    local emptyControlFilters = assert(control.emptyControlFilters)
    local unavailableSection = assert(control.unavailableSection)
    local validateCoreSearch = assert(control.validateCoreSearch)
    local unavailableSearch = assert(control.unavailableSearch)
    local namedSearch = assert(control.namedSearch)

    local operations = {
        summary = function(request)
            if not requestKeysAllowed(request, { view = true, limit = true })
                or (request.view ~= nil and request.view ~= 'overview')
                or not validCoreLimit(request.limit, 32) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core summary accepts only the overview view and a limit through 32.')
            end
            local discovery = providerDiscovery()
            local providerEntries = {}
            local providerLimit = request.limit or 32
            for index, provider in ipairs(discovery.providers or {}) do
                if index > providerLimit then break end
                providerEntries[#providerEntries + 1] = {
                    namespace = provider.namespace,
                    label = provider.label,
                    resource = provider.resource,
                    health = provider.health,
                    circuit = provider.circuit and provider.circuit.state or 'OPEN'
                }
            end
            local lifecycleSnapshot, lifecycleReasonCount = controlLifecycleSnapshot()
            local resourceSummary = registries.resources:summary()
            local sessionSummary = registries.players:summary()
            local attention = {}
            for index = 1, math.min(#lifecycleSnapshot.reasons, 16) do
                attention[#attention + 1] = foundation.copy(
                    lifecycleSnapshot.reasons[index])
            end
            return {
                view = 'overview',
                status = controlSeverity(lifecycle.core:healthStatus()),
                runtime = {
                    apiVersion = SynexProtocol.api,
                    wireVersion = SynexProtocol.wire,
                    state = lifecycleSnapshot.state,
                    playerAdmission = lifecycleSnapshot.playerAdmission == true,
                    environment = defaultConfig.environment,
                    instanceId = defaultConfig.instanceId
                },
                resources = resourceSummary,
                sessions = sessionSummary,
                providers = providerEntries,
                attention = attention,
                truncated = #(discovery.providers or {}) > providerLimit
                    or lifecycleReasonCount > 16
            }, nil
        end,
        health = function(request)
            if not requestKeysAllowed(request, { view = true, limit = true })
                or (request.view ~= nil and request.view ~= 'health')
                or not validCoreLimit(request.limit, 32) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core health accepts only the health view.')
            end
            local snapshot, reasonCount = controlLifecycleSnapshot()
            return {
                status = controlSeverity(lifecycle.core:healthStatus()),
                state = snapshot.state,
                operational = snapshot.operational == true,
                playerAdmission = snapshot.playerAdmission == true,
                reasons = math.min(64, reasonCount),
                truncated = reasonCount > 64
            }, nil
        end,
        list = function(request)
            if not requestKeysAllowed(request, {
                view = true,
                limit = true,
                cursor = true,
                filters = true,
                sort = true
            }) or not coreListViews[request.view] then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core list requires a supported view, limit, and cursor.')
            end
            if request.view == 'trace_detail' then
                if request.sort ~= nil
                    or not requestKeysAllowed(request.filters, { trace_id = true })
                    or type(request.filters.trace_id) ~= 'string'
                    or #request.filters.trace_id < 1
                    or #request.filters.trace_id > 128
                    or request.filters.trace_id:find('[%z\1-\31\127]')
                    or not request.filters.trace_id:match(
                        '^[A-Za-z0-9][A-Za-z0-9_.:@%-]*$') then
                    return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                        'Trace detail requires one exact bounded trace id filter.')
                end
                if type(foundation.tracing) ~= 'table'
                    or not foundation.isCallable(foundation.tracing.detail) then
                    return unavailableSection('trace_detail',
                        'TRACE_HISTORY_UNAVAILABLE')
                end
                local detail, traceError = foundation.tracing:detail(
                    request.filters.trace_id, {
                        cursor = request.cursor,
                        limit = request.limit
                    })
                if not detail then return nil, traceError end
                detail.view = 'trace_detail'
                detail.auditCorrelation = true
                detail.spanStore = true
                return detail, nil
            end
            if not emptyControlFilters(request.filters) or request.sort ~= nil then
                return unavailableSection(request.view,
                    'CORE_LIST_FILTERING_UNAVAILABLE')
            end
            if request.view == 'tracing' then
                if type(foundation.tracing) ~= 'table'
                    or not foundation.isCallable(foundation.tracing.list) then
                    return unavailableSection('tracing',
                        'TRACE_HISTORY_UNAVAILABLE')
                end
                local page, traceError = foundation.tracing:list({
                    cursor = request.cursor,
                    limit = request.limit
                })
                if not page then return nil, traceError end
                page.view = 'tracing'
                page.auditCorrelation = true
                page.spanStore = true
                return page, nil
            end
            if request.view == 'slow_queries' then
                if not foundation.isCallable(persistence.database.slowQueries) then
                    return unavailableSection('slow_queries',
                        'SLOW_QUERY_HISTORY_UNAVAILABLE')
                end
                local page, slowQueryError = persistence.database:slowQueries({
                    cursor = request.cursor,
                    limit = request.limit
                })
                if not page then return nil, slowQueryError end
                page.view = 'slow_queries'
                return page, nil
            end
            if request.view == 'migrations' then
                local page, migrationError = persistence.migrations:details({
                    cursor = request.cursor,
                    limit = request.limit
                })
                if not page then return nil, migrationError end
                page.view = 'migrations'
                return page, nil
            end
            if request.view == 'sessions' then
                local page, pageError = registries.players:listSessions({
                    cursor = request.cursor,
                    limit = request.limit
                })
                if not page then return nil, pageError end
                local items = {}
                for index, session in ipairs(page.items) do
                    items[index] = safeSession(session)
                end
                return {
                    view = 'sessions',
                    status = 'AVAILABLE',
                    summary = registries.players:summary(),
                    items = items,
                    limit = page.limit,
                    nextCursor = page.nextCursor,
                    hasMore = page.hasMore == true,
                    truncated = page.truncated == true,
                    pagination = { status = 'AVAILABLE', kind = 'keyset' },
                    identifiersExposed = false
                }, nil
            end
            local entries, keyFor
            if request.view == 'resources' then
                entries = resourceSnapshot(registries.resources:list(), 256).entries
                keyFor = function(entry) return entry.name end
            elseif request.view == 'dependencies' then
                entries = dependencySnapshot(lifecycle.dependencies:snapshot(), 512,
                    registries.resources:list()).entries
                keyFor = function(entry)
                    return table.concat({
                        entry.resource or '', entry.service or entry.dependency or '',
                        entry.direction or '', entry.dependencyClass or '', entry.major or ''
                    }, '|')
                end
            elseif request.view == 'contracts' then
                entries = contractEntries()
                keyFor = function(entry)
                    return table.concat({
                        entry.name or '', entry.version or ''
                    }, '|')
                end
            elseif request.view == 'capabilities' then
                entries = capabilityEntries()
                keyFor = function(entry) return entry.resource end
            elseif request.view == 'hooks' then
                entries = boundedArray(messaging.hooks:snapshot(), 256)
                keyFor = function(entry) return entry.name end
            else
                entries = serviceSnapshot(messaging.services:snapshot(), 512).entries
                keyFor = function(entry)
                    return table.concat({ entry.key or '', entry.resource or '' }, '|')
                end
            end
            local page, pageError = paginated(entries, request, keyFor)
            if not page then return nil, pageError end
            page.view = request.view
            if request.view == 'dependencies' then
                local nodes, edges, observed = {}, {}, {}
                local function addNode(id, label, kind)
                    if observed[id] then return end
                    observed[id] = true
                    nodes[#nodes + 1] = { id = id, label = label, type = kind }
                end
                for _, entry in ipairs(page.items) do
                    local resourceId = 'resource:' .. tostring(entry.resource or 'unknown')
                    addNode(resourceId, entry.resource or 'unknown', 'resource')
                    if entry.direction == 'resource' then
                        local dependencyId = 'resource:'
                            .. tostring(entry.dependency or 'unknown')
                        addNode(dependencyId, entry.dependency or 'unknown', 'resource')
                        edges[#edges + 1] = {
                            from = resourceId,
                            to = dependencyId,
                            type = entry.dependencyClass or 'required'
                        }
                    else
                        local serviceId = 'service:'
                            .. tostring(entry.service or 'unknown')
                        addNode(serviceId, entry.service or 'unknown', 'service')
                        edges[#edges + 1] = {
                            from = resourceId,
                            to = serviceId,
                            type = entry.direction == 'provide' and 'provider'
                                or entry.optional == true and 'optional' or 'required'
                        }
                    end
                end
                page.nodes = nodes
                page.edges = edges
                page.items = nil
                page.cycleDetection = resourceDependencyCycles(
                    registries.resources:list())
            end
            return page, nil
        end,
        search = function(request)
            local search, validationError = validateCoreSearch(request)
            if not search then return nil, validationError end
            if search.hasFilters or search.hasSort then
                return unavailableSearch(search, 'UNAVAILABLE',
                    'CORE_SEARCH_FILTERING_UNAVAILABLE')
            end
            if search.kind == 'user' then
                if search.mode ~= 'exact' or search.cursor ~= nil then
                    return unavailableSearch(search, 'UNAVAILABLE',
                        'USER_SEARCH_REQUIRES_EXACT_ID')
                end
                local sessions = registries.players:sessionsByUser(search.value)
                local items = {}
                for index = 1, math.min(#sessions, search.limit) do
                    local session = sessions[index]
                    items[#items + 1] = {
                        kind = 'user-session',
                        value = 'exact-match',
                        sessionId = session.id,
                        state = session.state,
                        playerSource = session.source,
                        sourceGeneration = session.sourceGeneration,
                        hasCharacter = session.characterId ~= nil
                    }
                end
                return {
                    kind = 'user',
                    mode = 'exact',
                    value = 'exact-match',
                    status = 'AVAILABLE',
                    items = items,
                    nextCursor = nil,
                    hasMore = false,
                    truncated = #sessions > search.limit,
                    payloadsExposed = false,
                    userIdentifierExposed = false
                }, nil
            end
            if search.kind == 'session' then
                if search.mode ~= 'exact' or search.cursor ~= nil then
                    return unavailableSearch(search, 'UNAVAILABLE',
                        'SESSION_SEARCH_REQUIRES_EXACT_ID')
                end
                local session = registries.players:getSession(search.value)
                return {
                    kind = 'session',
                    mode = 'exact',
                    value = 'exact-match',
                    status = 'AVAILABLE',
                    items = session and {{
                        kind = 'session',
                        value = 'exact-match',
                        sessionId = session.id,
                        state = session.state,
                        playerSource = session.source,
                        sourceGeneration = session.sourceGeneration,
                        hasCharacter = session.characterId ~= nil
                    }} or {},
                    nextCursor = nil,
                    hasMore = false,
                    truncated = false,
                    payloadsExposed = false
                }, nil
            end
            if search.kind == 'character' then
                if search.mode ~= 'exact' or search.cursor ~= nil then
                    return unavailableSearch(search, 'UNAVAILABLE',
                        'CHARACTER_SEARCH_REQUIRES_EXACT_ID')
                end
                local character, characterError = identity.characters:get(search.value)
                if not character and characterError
                    and characterError.code ~= 'CHARACTER_NOT_FOUND'
                    and characterError.code ~= 'CHARACTER_UNAVAILABLE' then
                    return nil, characterError
                end
                local activeSession = character
                    and registries.players:getByCharacter(character.id) or nil
                return {
                    kind = 'character',
                    mode = 'exact',
                    value = 'exact-match',
                    status = 'AVAILABLE',
                    items = character and {{
                        kind = 'character',
                        value = 'exact-match',
                        characterId = character.id,
                        slot = character.slot,
                        status = character.status,
                        active = activeSession ~= nil
                    }} or {},
                    nextCursor = nil,
                    hasMore = false,
                    truncated = false,
                    payloadsExposed = false
                }, nil
            end
            if search.kind == 'resource' then
                return namedSearch(search, registries.resources:list(),
                    function(entry) return entry.name end,
                    function(entry)
                        return {
                            kind = 'resource',
                            value = entry.name,
                            resource = entry.name,
                            state = entry.state,
                            health = entry.health and entry.health.status or 'UNKNOWN',
                            version = entry.manifest and entry.manifest.version or nil
                        }
                    end), nil
            end
            if search.kind == 'contract' then
                return namedSearch(search, contractEntries(),
                    function(entry)
                        return table.concat({ entry.name, entry.version }, '|')
                    end,
                    function(entry)
                        return {
                            kind = 'contract',
                            value = entry.name,
                            name = entry.name,
                            version = entry.version,
                            provider = entry.provider,
                            stability = entry.stability
                        }
                    end,
                    function(entry) return entry.name end), nil
            end
            if search.kind == 'capability' then
                local names = {}
                local observed = {}
                for _, entry in pairs(security.capabilities:snapshot()) do
                    for capability, enabled in pairs(entry.requested or {}) do
                        if enabled and not observed[capability] then
                            observed[capability] = true
                            names[#names + 1] = { name = capability }
                        end
                    end
                end
                table.sort(names, function(left, right) return left.name < right.name end)
                return namedSearch(search, names,
                    function(entry) return entry.name end,
                    function(entry)
                        return {
                            kind = 'capability',
                            value = entry.name,
                            capability = entry.name
                        }
                    end), nil
            end
            if search.kind == 'trace' and type(foundation.tracing) == 'table'
                and foundation.isCallable(foundation.tracing.list) then
                local spans, traceError = foundation.tracing:list({
                    traceId = search.value,
                    cursor = search.cursor,
                    limit = search.limit
                })
                if not spans then return nil, traceError end
                if (spans.matched or 0) > 0 then
                    local items = {}
                    for _, span in ipairs(spans.items) do
                        items[#items + 1] = {
                            kind = 'trace-span',
                            value = 'exact-match',
                            cursor = span.cursor,
                            spanId = span.spanId,
                            parentSpanId = span.parentSpanId,
                            childSpanIds = span.childSpanIds,
                            resource = span.resource,
                            operation = span.operation,
                            durationMs = span.durationMs,
                            status = span.status,
                            errorCode = span.errorCode,
                            timestamp = span.timestamp
                        }
                    end
                    return {
                        kind = 'trace',
                        mode = 'exact',
                        value = 'exact-match',
                        status = 'AVAILABLE',
                        items = items,
                        nextCursor = spans.nextCursor,
                        hasMore = spans.hasMore,
                        truncated = spans.truncated,
                        pagination = { status = 'AVAILABLE', kind = 'keyset' },
                        auditCorrelation = {
                            status = 'NOT_QUERIED',
                            reason = 'RETAINED_SPAN_MATCH'
                        },
                        payloadsExposed = false,
                        traceValueExposed = false
                    }, nil
                end
            end
            if search.mode ~= 'exact' then
                return unavailableSearch(search, 'UNAVAILABLE',
                    'AUDIT_PREFIX_SEARCH_UNAVAILABLE')
            end
            local result, searchError = reliability.audit:search({
                kind = search.kind,
                value = search.value,
                limit = search.limit,
                cursor = search.cursor
            })
            if not result then return nil, searchError end
            return {
                kind = search.kind,
                mode = search.mode,
                value = (search.kind == 'user' or search.kind == 'trace')
                    and 'exact-match' or search.value,
                status = 'AVAILABLE',
                items = result.entries,
                nextCursor = result.nextCursor,
                hasMore = result.hasMore == true,
                truncated = result.truncated == true,
                pagination = { status = 'AVAILABLE', kind = 'keyset' },
                payloadsExposed = false
            }, nil
        end,
        metrics = function(request)
            if not requestKeysAllowed(request, {
                view = true,
                limit = true,
                cursor = true,
                filters = true,
                sort = true
            }) or request.view ~= 'performance'
                or not validCoreLimit(request.limit, 50) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core metrics supports only the performance view.')
            end
            if not emptyControlFilters(request.filters) or request.sort ~= nil then
                return unavailableSection(request.view,
                    'CORE_METRIC_FILTERING_UNAVAILABLE')
            end
            if request.cursor ~= nil and (type(request.cursor) ~= 'string'
                or #request.cursor < 1 or #request.cursor > 20
                or not request.cursor:match('^[1-9]%d*$')) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core performance cursor is invalid.')
            end
            local slowQueries, slowQueryError = nil, nil
            if foundation.isCallable(persistence.database.slowQueries) then
                slowQueries, slowQueryError = persistence.database:slowQueries({
                    cursor = request.cursor,
                    limit = request.limit
                })
            end
            return {
                view = 'performance',
                metrics = selectedMetrics({
                    'synex_contract_',
                    'synex_control_provider_',
                    'synex_db_',
                    'synex_hook_'
                }, 192),
                slowQueryHistory = slowQueries or {
                    status = 'UNAVAILABLE',
                    reason = slowQueryError and slowQueryError.code
                        or 'SLOW_QUERY_HISTORY_UNAVAILABLE'
                }
            }, nil
        end,
    }
    return operations
end
