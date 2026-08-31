SynexInteractControlProvider = {}

local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')
local Foundation = assert(SynexInteractFoundation, 'interact foundation must be loaded first')

local INSPECT_INPUT = { fields = {{
    key = 'id', label = 'Namespaced key', source = 'id', type = 'string',
    format = 'identifier', required = true, minLength = 3, maxLength = 128,
}} }
local TRACE_INPUT = { fields = {{
    key = 'trace_id', label = 'Trace ID', source = 'filter', type = 'string',
    format = 'identifier', required = true, minLength = 8, maxLength = 64,
}} }
local MAXIMUM_GRAPH_EXECUTION_DETAILS = 32

local VIEWS = {
    { id = 'overview', label = 'Interaction overview', operation = 'summary',
        presentation = 'key-value', order = 10,
        description = 'Bounded bundle, smart-object, lease, session and graph totals.',
        accessClass = 'general' },
    { id = 'health', label = 'Interaction health', operation = 'health',
        presentation = 'key-value', order = 20,
        description = 'Current Core, World, Entities and UI dependency health.',
        accessClass = 'general' },
    { id = 'bundles', label = 'Bundles', operation = 'list', presentation = 'table',
        order = 30, description = 'Cursor-bounded active Interaction bundles and revisions.',
        accessClass = 'general' },
    { id = 'providers', label = 'Providers', operation = 'list', presentation = 'table',
        order = 40, description = 'Resource-owned candidate, condition and action providers.',
        accessClass = 'general' },
    { id = 'smart_objects', label = 'Smart objects', operation = 'list',
        presentation = 'table', order = 50,
        description = 'Bounded active Smart Object definitions and slot counts.',
        accessClass = 'general' },
    { id = 'slots', label = 'Slots', operation = 'list', presentation = 'table',
        order = 60, description = 'Current bounded slot reservation and occupancy pressure.',
        accessClass = 'general' },
    { id = 'active_leases', label = 'Active leases', operation = 'list',
        presentation = 'table', order = 70,
        description = 'Redacted actor-, target-, intent- and revision-bound lease aggregates.',
        accessClass = 'general' },
    { id = 'sessions', label = 'Interaction sessions', operation = 'list',
        presentation = 'table', order = 80,
        description = 'Bounded single- and multi-actor interaction sessions.',
        accessClass = 'general' },
    { id = 'graphs', label = 'Action graphs', operation = 'list', presentation = 'table',
        order = 90, description = 'Compiled graph definitions without domain request payloads.',
        accessClass = 'general' },
    { id = 'denials', label = 'Security denials', operation = 'list',
        presentation = 'table', order = 95,
        description = 'Bounded rejection codes without player or target identifiers.',
        accessClass = 'security' },
    { id = 'trace', label = 'Interaction trace replay', operation = 'list',
        presentation = 'timeline', order = 97,
        description = 'Exact development trace replay from the bounded in-process ring.',
        accessClass = 'audit', input = TRACE_INPUT },
    { id = 'object', label = 'Smart Object inspector', operation = 'inspect',
        presentation = 'detail', order = 100,
        description = 'Inspect one exact namespaced Smart Object without player data.',
        accessClass = 'general', input = INSPECT_INPUT },
    { id = 'graph', label = 'Graph inspector', operation = 'inspect',
        presentation = 'graph', order = 110,
        description = 'Inspect one compiled graph plus bounded redacted execution state.',
        accessClass = 'general', input = INSPECT_INPUT },
    { id = 'performance', label = 'Performance', operation = 'metrics',
        presentation = 'metrics', order = 120,
        description = 'Bounded sensor, candidate, lease, graph and evaluator metrics.',
        accessClass = 'general' },
    { id = 'findings', label = 'Findings', operation = 'findings',
        presentation = 'findings', order = 130,
        description = 'Bundle, provider, reservation, lease, lock and graph findings.',
        accessClass = 'general' },
}

function SynexInteractControlProvider.create(options)
    local registry = assert(options.registry, 'control provider requires registry')
    local authority = assert(options.authority, 'control provider requires authority')
    local slots = assert(options.slots, 'control provider requires slots')
    local sessions = assert(options.sessions, 'control provider requires sessions')
    local graph = assert(options.graph, 'control provider requires graph runtime')
    local diagnostics = assert(options.diagnostics, 'control provider requires diagnostics')
    local observability = assert(options.observability, 'control provider requires observability')
    local provider = {}

    local function exact(request, optional)
        if not Validation.exactObject(request or {}, { 'view' }, optional)
            or not Validation.text(request.view, 1, 64) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction control request is invalid.')
        end
        return request
    end
    local function empty(value)
        return value == nil or Validation.isPlainTable(value) and next(value) == nil
    end
    local function pageBounds(value)
        local cursor = value.cursor
        if type(cursor) == 'string' and cursor:match('^[0-9]+$') then
            cursor = tonumber(cursor)
        end
        if cursor ~= nil and not Validation.isInteger(cursor, 0, 1000000)
            or value.limit ~= nil and not Validation.isInteger(value.limit, 1, 100) then
            local _, operationError = Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction control pagination is invalid.')
            return nil, nil, operationError
        end
        return cursor, value.limit, nil
    end
    local function page(value, operationError)
        if not value then return nil, operationError end
        if value.nextCursor ~= nil then value.nextCursor = tostring(value.nextCursor) end
        return value, nil
    end
    local function graphProjection(definition)
        local nodes, edges, edgeCount, truncated = {}, {}, 0, false
        local function edge(from, to, relation)
            if to == nil then return end
            if edgeCount >= 256 then truncated = true; return end
            edgeCount = edgeCount + 1
            edges[edgeCount] = { from = from, to = to, relation = relation }
        end
        for _, nodeKey in ipairs(definition.nodeOrder or {}) do
            local node = definition.nodes[nodeKey]
            nodes[#nodes + 1] = {
                id = nodeKey, label = node.type, type = node.type,
                entry = nodeKey == definition.entry,
                terminal = node.type == 'complete' or node.type == 'fail',
                adapter = node.adapter,
            }
            edge(nodeKey, node.next, 'next')
            edge(nodeKey, node.thenNode, 'then')
            edge(nodeKey, node.elseNode, 'else')
            for _, child in ipairs(node.children or {}) do edge(nodeKey, child, 'child') end
            edge(nodeKey, node.cleanup, 'cleanup')
        end
        local executionPage = graph.list(nil, 100)
        local currentNodes, active, committed, executionDetails = {}, 0, 0, {}
        if executionPage then
            truncated = truncated or executionPage.hasMore == true
            for _, execution in ipairs(executionPage.items) do
                if execution.graph == definition.key then
                    active = active + 1
                    if execution.committed then committed = committed + 1 end
                    local current = execution.currentNode or 'pending'
                    currentNodes[current] = (currentNodes[current] or 0) + 1
                    if #executionDetails < MAXIMUM_GRAPH_EXECUTION_DETAILS then
                        local lease = authority.inspectSessionLeases(execution.sessionId)
                        if execution.leaseReleased then
                            lease = { state = 'RELEASED', activeLeaseCount = 0,
                                leaseStates = {}, scanComplete = true }
                        elseif type(lease) ~= 'table' then
                            lease = { state = 'UNAVAILABLE', activeLeaseCount = 0,
                                leaseStates = {}, scanComplete = false }
                        end
                        local channels = Validation.copy(execution.lockChannels) or {}
                        executionDetails[#executionDetails + 1] = {
                            state = execution.state, currentNode = current,
                            elapsedMs = execution.elapsedMs or 0,
                            committed = execution.committed == true,
                            participants = {
                                count = execution.participantCount or 0,
                                roles = Validation.copy(execution.participantRoles) or {},
                            },
                            locks = { count = #channels, channels = channels },
                            lease = lease,
                        }
                    else truncated = true end
                end
            end
        end
        return {
            nodes = nodes, edges = edges, graphKey = definition.key,
            entry = definition.entry, timeoutMs = definition.timeoutMs,
            runtime = { active = active, committed = committed,
                currentNodes = currentNodes,
                executions = executionDetails,
                scanComplete = executionPage ~= nil and not executionPage.hasMore },
            truncated = truncated,
        }
    end
    local operations = {}
    operations.summary = function(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'overview' then return nil, operationError or {
            code = 'INTERACT_INVALID_REQUEST', message = 'Overview view is invalid.' } end
        return diagnostics.summary()
    end
    operations.health = function(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'health' then return nil, operationError or {
            code = 'INTERACT_INVALID_REQUEST', message = 'Health view is invalid.' } end
        return diagnostics.health()
    end
    operations.list = function(request)
        local value, operationError = exact(request, { 'cursor', 'limit', 'filters', 'sort' })
        if not value then return nil, operationError end
        if not empty(value.sort) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction control lists do not accept arbitrary sorting.')
        end
        if value.view == 'trace' then
            if value.cursor ~= nil or not Validation.exactObject(value.filters or {},
                { 'trace_id' }) or not Validation.token(value.filters.trace_id, 8, 64) then
                return Validation.failure('INTERACT_INVALID_REQUEST',
                    'Interaction trace replay requires one exact trace ID.')
            end
            local replay, replayError = observability.replay(
                value.filters.trace_id, value.limit)
            if not replay then return nil, replayError end
            return { items = replay.frames, hasMore = replay.hasMore,
                truncated = replay.truncated, total = replay.total }, nil
        end
        if not empty(value.filters) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction control lists do not accept arbitrary filters.')
        end
        local cursor, limit, boundsError = pageBounds(value)
        if boundsError then return nil, boundsError end
        if value.view == 'bundles' or value.view == 'providers'
            or value.view == 'smart_objects' or value.view == 'graphs' then
            return page(registry.list(value.view, cursor, limit))
        elseif value.view == 'slots' then return page(slots.list(cursor, limit))
        elseif value.view == 'active_leases' then
            return page(authority.listLeases(cursor, limit))
        elseif value.view == 'sessions' then return page(sessions.list(cursor, limit))
        elseif value.view == 'denials' then return page(observability.denials(cursor, limit)) end
        return Validation.failure('INTERACT_INVALID_REQUEST',
            'Interaction control list view is invalid.')
    end
    operations.inspect = function(request)
        local value, operationError = exact(request, { 'id' })
        if not value or not Validation.identifier(value.id) then return nil, operationError or {
            code = 'INTERACT_INVALID_REQUEST', message = 'Inspector ID is invalid.' } end
        if value.view == 'object' then
            local object, objectError = registry.inspect('smart_object', value.id)
            if not object then return nil, objectError end
            local usage, usageError = slots.inspectObject(object.key, object.slotOrder or {})
            if not usage then return nil, usageError end
            local runtime, runtimeError = authority.inspectObject(object.key)
            if not runtime then return nil, runtimeError end
            runtime.slots = usage.items
            object.runtime = runtime
            return object, nil
        elseif value.view == 'graph' then
            local definition, definitionError = registry.inspect('graph', value.id)
            if not definition then return nil, definitionError end
            return graphProjection(definition), nil
        end
        return Validation.failure('INTERACT_INVALID_REQUEST',
            'Interaction inspector view is invalid.')
    end
    operations.metrics = function(request)
        local value, operationError = exact(request)
        if not value or value.view ~= 'performance' then return nil, operationError or {
            code = 'INTERACT_INVALID_REQUEST', message = 'Performance view is invalid.' } end
        local snapshot = observability.snapshot()
        snapshot.runtime = authority.snapshot()
        snapshot.graphs = graph.snapshot()
        snapshot.slots = slots.snapshot()
        return snapshot, nil
    end
    operations.findings = function(request)
        local value, operationError = exact(request,
            { 'cursor', 'limit', 'filters', 'sort' })
        if not value or value.view ~= 'findings' or value.cursor ~= nil
            or not empty(value.filters) or not empty(value.sort) then return nil,
                operationError or { code = 'INTERACT_INVALID_REQUEST',
                    message = 'Findings view is invalid.' } end
        if value.limit ~= nil and not Validation.isInteger(value.limit, 1, 100) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction findings limit is invalid.')
        end
        local report, reportError = diagnostics.doctor({ limit = value.limit })
        if not report then return nil, reportError end
        return { status = report.status, items = report.findings,
            hasMore = report.hasMore, truncated = report.truncated }, nil
    end

    local bounded = {}
    for name, handler in pairs(operations) do
        bounded[name] = function(...)
            local value, operationError = Foundation.protect(handler, ...)
            if value == nil then
                local public = Foundation.publicError(operationError)
                if public.code == 'INTERACT_INVALID_REQUEST' then
                    public.code = 'INVALID_ARGUMENT'
                end
                return nil, public
            end
            return value, nil
        end
    end
    function provider.register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not Foundation.isCallable(register) then return Validation.failure('INTERACT_UNAVAILABLE',
            'Core control-provider registry is unavailable.', true) end
        return register({ schemaVersion = 1, namespace = 'interact', label = 'Interact',
            category = 'foundation', version = '1.0.0', operations = bounded, views = VIEWS })
    end
    provider.views, provider.operations = VIEWS, operations
    return provider
end
