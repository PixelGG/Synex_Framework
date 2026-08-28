SynexWorldControlProvider = {}

local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local VIEWS = {
    { id = 'overview', label = 'World overview', operation = 'summary',
        presentation = 'key-value', order = 10,
        description = 'Bounded World registry, map, instance, slice, and persistence totals.',
        accessClass = 'general' },
    { id = 'health', label = 'World health', operation = 'health',
        presentation = 'key-value', order = 20,
        description = 'Current World authority and dependency health.', accessClass = 'general' },
    { id = 'bundles', label = 'Bundles', operation = 'list', presentation = 'table',
        order = 30, description = 'Cursor-based active World bundles.', accessClass = 'general' },
    { id = 'map_packages', label = 'Map packages', operation = 'list', presentation = 'table',
        order = 40, description = 'Bounded map availability and semantic outage impact.',
        accessClass = 'general' },
    { id = 'regions', label = 'Regions', operation = 'list', presentation = 'table',
        order = 50, description = 'Cursor-based semantic regions.', accessClass = 'general' },
    { id = 'locations', label = 'Locations', operation = 'list', presentation = 'table',
        order = 60, description = 'Cursor-based semantic locations.', accessClass = 'general' },
    { id = 'interiors', label = 'Interiors', operation = 'list', presentation = 'table',
        order = 70, description = 'Cursor-based semantic interiors.', accessClass = 'general' },
    { id = 'rooms', label = 'Rooms', operation = 'list', presentation = 'table',
        order = 80, description = 'Cursor-based semantic rooms.', accessClass = 'general' },
    { id = 'zones', label = 'Zones', operation = 'list', presentation = 'table',
        order = 90, description = 'Cursor-based compiled zones.', accessClass = 'general' },
    { id = 'anchors', label = 'Anchors', operation = 'list', presentation = 'table',
        order = 100, description = 'Cursor-based semantic anchors.', accessClass = 'general' },
    { id = 'doors', label = 'Doors', operation = 'list', presentation = 'table',
        order = 110, description = 'Cursor-based logical doors.', accessClass = 'general' },
    { id = 'portals', label = 'Portals', operation = 'list', presentation = 'table',
        order = 120, description = 'Cursor-based World portals.', accessClass = 'general' },
    { id = 'instances', label = 'Instances', operation = 'list', presentation = 'table',
        order = 130, description = 'Bounded semantic instance lifecycle state.', accessClass = 'general' },
    { id = 'state', label = 'State definitions', operation = 'list', presentation = 'table',
        order = 140, description = 'Cursor-based World state schemas without values.', accessClass = 'general' },
    { id = 'spatial_index', label = 'Spatial index', operation = 'metrics',
        presentation = 'metrics', order = 150,
        description = 'Measured cells, candidates, queries, and slice pressure.', accessClass = 'general' },
    { id = 'world_object', label = 'World inspector', operation = 'inspect',
        presentation = 'detail', order = 160,
        description = 'Inspect one exact namespaced World object.', accessClass = 'general' },
    { id = 'world_graph', label = 'World graph', operation = 'inspect',
        presentation = 'graph', order = 170,
        description = 'Bounded parent/child graph for one World object.', accessClass = 'general' },
    { id = 'point', label = 'Point inspector', operation = 'inspect',
        presentation = 'detail', order = 180,
        description = 'Resolve a bounded semantic context at one point.', accessClass = 'general' },
    { id = 'search', label = 'World search', operation = 'search',
        presentation = 'table', order = 190,
        description = 'Exact lookup by namespaced World key.', accessClass = 'general',
        search = { kinds = { { id = 'world_object', modes = { 'exact' },
            accessClass = 'general' } } } },
    { id = 'findings', label = 'Findings', operation = 'findings',
        presentation = 'findings', order = 200,
        description = 'Bounded World doctor findings.', accessClass = 'general' },
}

local kindByView = {
    map_packages = 'map_package', regions = 'region', locations = 'location',
    interiors = 'interior', rooms = 'room', zones = 'zone', anchors = 'anchor',
    doors = 'door', portals = 'portal', state = 'world_state_definition',
}

function SynexWorldControlProvider.create(options)
    local foundation = assert(options.foundation, 'world control provider requires foundation')
    local registry = assert(options.registry, 'world control provider requires registry')
    local mapRegistry = assert(options.mapRegistry, 'world control provider requires maps')
    local instances = assert(options.instances, 'world control provider requires instances')
    local diagnostics = assert(options.diagnostics, 'world control provider requires diagnostics')
    local contextResolver = assert(options.contextResolver,
        'world control provider requires context resolver')
    local project = assert(options.project, 'world control provider requires object projection')
    local provider = {}

    local function failure(message)
        return Validation.failure('INVALID_ARGUMENT', message)
    end
    local function request(candidate, allowed, required)
        if not Validation.isPlainTable(candidate) then return failure('World control request is invalid.') end
        local map = {}
        for _, key in ipairs(allowed) do map[key] = true end
        if not Validation.exactObject(candidate, map) then
            return failure('World control request contains unsupported fields.')
        end
        for _, key in ipairs(required or {}) do
            if candidate[key] == nil then return failure('World control request is incomplete.') end
        end
        return candidate
    end
    local function empty(value) return value == nil or Validation.isPlainTable(value) and next(value) == nil end
    local function page(items, nextCursor)
        return { items = items, nextCursor = nextCursor, hasMore = nextCursor ~= nil,
            truncated = nextCursor ~= nil }
    end

    local handlers = {}
    handlers.summary = function(value)
        local candidate, candidateError = request(value, { 'view', 'limit' }, { 'view' })
        if not candidate then return nil, candidateError end
        if candidate.view ~= 'overview' or candidate.limit ~= nil
            and not Validation.isInteger(candidate.limit, 1, 25) then
            return failure('World summary view is invalid.')
        end
        return diagnostics.summary()
    end
    handlers.health = function(value)
        local candidate, candidateError = request(value, { 'view' }, { 'view' })
        if not candidate then return nil, candidateError end
        if candidate.view ~= 'health' then return failure('World health view is invalid.') end
        return diagnostics.health()
    end
    handlers.list = function(value)
        local candidate, candidateError = request(value,
            { 'view', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
        if not candidate then return nil, candidateError end
        if not empty(candidate.filters) or not empty(candidate.sort) then
            return failure('World list filters are not supported by this bounded view.')
        end
        local cursor, cursorError = Validation.cursor(candidate.cursor)
        if candidate.cursor ~= nil and not cursor then return nil, cursorError end
        local limit, limitError = Validation.limit(candidate.limit, 25, 100)
        if not limit then return nil, limitError end
        if candidate.view == 'bundles' then
            local items, nextCursor = registry.listBundles(cursor, limit)
            return page(items, nextCursor)
        end
        if candidate.view == 'instances' then
            local items, nextCursor = instances.list(cursor, limit)
            return page(items, nextCursor)
        end
        local kind = kindByView[candidate.view]
        if not kind then return failure('World list view is invalid.') end
        local objects, nextCursor = registry.listObjects(kind, cursor, limit)
        local items, coldImpactAnalyses = {}, 0
        for index, object in ipairs(objects) do
            items[index] = project(object, false)
            if kind == 'map_package' then
                items[index].availability = mapRegistry.get(object.key)
                local impact, impactError
                if type(mapRegistry.cachedImpact) == 'function' then
                    impact, impactError = mapRegistry.cachedImpact(object.key, 8)
                end
                if impact == nil and impactError == nil and coldImpactAnalyses < 2 then
                    coldImpactAnalyses = coldImpactAnalyses + 1
                    impact, impactError = mapRegistry.impact(object.key, 8)
                end
                items[index].impact = impact
                items[index].impactPending = impact == nil and impactError == nil
                items[index].impactUnavailable = impactError and impactError.code or nil
            end
        end
        local result = page(items, nextCursor)
        if kind == 'map_package' then
            result.coldImpactAnalyses = coldImpactAnalyses
            result.impactComplete = true
            for _, item in ipairs(items) do
                if item.impactPending or item.impactUnavailable then
                    result.impactComplete = false
                    break
                end
            end
        end
        return result
    end
    handlers.inspect = function(value)
        local candidate, candidateError = request(value,
            { 'view', 'id', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
        if not candidate then return nil, candidateError end
        if candidate.cursor ~= nil or not empty(candidate.sort) then
            return failure('World inspection bounds are invalid.')
        end
        if candidate.view == 'point' then
            if candidate.id ~= nil or not Validation.isPlainTable(candidate.filters)
                or not Validation.exactObject(candidate.filters, { x = true, y = true, z = true }) then
                return failure('World point inspection is invalid.')
            end
            local limit, limitError = Validation.limit(candidate.limit, 32, 64)
            if not limit then return nil, limitError end
            local context, contextError = contextResolver.resolve(candidate.filters)
            if not context then return nil, contextError end
            local nearby, nearbyError = contextResolver.queryNearby(candidate.filters, 25,
                {}, limit)
            if not nearby then return nil, nearbyError end
            local items = {}
            for index, entry in ipairs(nearby) do
                items[index] = { object = project(entry.object, false), distance = entry.distance }
            end
            return { context = context, nearby = items }
        end
        if type(candidate.id) ~= 'string' or not empty(candidate.filters) then
            return failure('World object inspection is invalid.')
        end
        local object, objectError = registry.get(candidate.id)
        if not object then return nil, objectError end
        if candidate.view == 'world_object' then
            if candidate.limit ~= nil then
                return failure('World object inspection does not accept a result limit.')
            end
            return project(object, true)
        end
        if candidate.view == 'world_graph' then
            local limit, limitError = Validation.limit(candidate.limit, 64, 100)
            if not limit then return nil, limitError end
            local children = registry.children(object.key, nil, limit + 1)
            local truncated = #children > limit
            if truncated then children[#children] = nil end
            local nodes = { { id = object.key, kind = object.kind,
                label = object.label or object.key } }
            local edges = {}
            if object.parent then
                local parent = registry.objects()[object.parent]
                nodes[#nodes + 1] = { id = object.parent,
                    kind = parent and parent.kind or 'unavailable',
                    label = parent and (parent.label or parent.key) or object.parent }
                edges[#edges + 1] = { from = object.parent, to = object.key,
                    relation = 'contains' }
            end
            for _, child in ipairs(children) do
                nodes[#nodes + 1] = { id = child.key, kind = child.kind,
                    label = child.label or child.key }
                edges[#edges + 1] = { from = object.key, to = child.key,
                    relation = 'contains' }
            end
            return { nodes = nodes, edges = edges, truncated = truncated }
        end
        return failure('World inspection view is invalid.')
    end
    handlers.search = function(value)
        local candidate, candidateError = request(value,
            { 'query', 'cursor', 'limit', 'filters', 'sort' }, { 'query' })
        if not candidate then return nil, candidateError end
        if not Validation.isPlainTable(candidate.query)
            or not Validation.exactObject(candidate.query,
                { kind = true, value = true, mode = true })
            or candidate.query.kind ~= 'world_object' or candidate.query.mode ~= 'exact'
            or candidate.cursor ~= nil or not empty(candidate.filters) or not empty(candidate.sort) then
            return failure('World search supports exact World keys only.')
        end
        local limit, limitError = Validation.limit(candidate.limit, 1, 100)
        if not limit then return nil, limitError end
        local object, objectError = registry.get(candidate.query.value)
        if not object then return nil, objectError end
        return page({ project(object, false) }, nil)
    end
    handlers.metrics = function(value)
        local candidate, candidateError = request(value, { 'view', 'limit' }, { 'view' })
        if not candidate then return nil, candidateError end
        if candidate.view ~= 'spatial_index' or candidate.limit ~= nil then
            return failure('World metrics view is invalid.')
        end
        local summary = diagnostics.summary()
        return { spatial = summary.spatial, slices = summary.slices,
            objects = summary.objects, bundles = summary.bundles, counts = summary.counts }
    end
    handlers.findings = function(value)
        local candidate, candidateError = request(value,
            { 'view', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
        if not candidate then return nil, candidateError end
        if candidate.view ~= 'findings' or candidate.cursor ~= nil
            or not empty(candidate.filters) or not empty(candidate.sort) then
            return failure('World findings view is invalid.')
        end
        local limit, limitError = Validation.limit(candidate.limit, 50, 100)
        if not limit then return nil, limitError end
        return diagnostics.doctor({ limit = limit,
            includePersistence = true })
    end

    local bounded = {}
    for operation, handler in pairs(handlers) do
        bounded[operation] = function(...)
            local ok, result, operationError = pcall(handler, ...)
            if not ok then
                return nil, { code = 'UNAVAILABLE',
                    message = 'The World control read is unavailable.', retryable = true }
            end
            return result, operationError
        end
    end

    function provider.register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not SynexWorldFoundation.isCallable(register) then
            return Validation.failure('UNAVAILABLE',
                'The Core control-provider registry is unavailable.', true)
        end
        return register({ schemaVersion = 1, namespace = 'world', label = 'World',
            category = 'foundation', version = '1.0.0', operations = bounded, views = VIEWS })
    end
    provider.views = VIEWS
    provider.operations = handlers
    return provider
end
