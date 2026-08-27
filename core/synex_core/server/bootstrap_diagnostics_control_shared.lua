local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.createBootstrapControlShared = function(deps, shared)
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local controlProviders = deps.controlProviders
    local coreResource = deps.coreResource
    local requestKeysAllowed = assert(shared.requestKeysAllowed)

    local coreListViews = {
        resources = true,
        dependencies = true,
        contracts = true,
        capabilities = true,
        hooks = true,
        services = true,
        migrations = true,
        sessions = true,
        tracing = true,
        trace_detail = true,
        slow_queries = true
    }
    local coreInspectViews = {
        runtime = true,
        instances = true,
        health_timeline = true,
        rpc = true,
        database = true,
        session = true,
        characters = true,
        character = true,
        resource = true,
        contract = true,
        capability = true,
        dependency_impact = true,
        rpc_detail = true,
        hook_detail = true,
        service_detail = true,
        incident_window = true,
        compatibility = true
    }
    local coreInspectIdViews = {
        session = true,
        character = true,
        resource = true,
        contract = true,
        capability = true,
        dependency_impact = true,
        rpc_detail = true,
        hook_detail = true,
        service_detail = true
    }
    local function controlSeverity(status)
        if status == 'HEALTHY' or status == 'DEGRADED' then return status end
        if status == 'UNHEALTHY' or status == 'FAILED' then return 'ERROR' end
        return 'INFO'
    end
    local function controlLifecycleSnapshot()
        local source = lifecycle.core:snapshot()
        local components = {}
        for component in pairs(source.reasons or {}) do components[#components + 1] = component end
        table.sort(components)
        local reasons = {}
        for index = 1, math.min(#components, 64) do
            local component = components[index]
            local reason = source.reasons[component]
            reasons[#reasons + 1] = {
                component = tostring(component):sub(1, 64),
                status = tostring(reason.status or 'DEGRADED'):sub(1, 32),
                message = tostring(reason.reason or 'unspecified'):sub(1, 256)
            }
        end
        local transitions = {}
        local sourceTransitions = source.recentTransitions or {}
        local firstTransition = math.max(1, #sourceTransitions - 31)
        for index = firstTransition, #sourceTransitions do
            local transition = sourceTransitions[index]
            transitions[#transitions + 1] = {
                from = tostring(transition.from or ''):sub(1, 32),
                to = tostring(transition.to or ''):sub(1, 32),
                reason = tostring(transition.reason or ''):sub(1, 256),
                revision = transition.revision,
                at = transition.at
            }
        end
        return {
            state = tostring(source.state or 'UNKNOWN'):sub(1, 32),
            revision = source.revision,
            operational = source.operational == true,
            playerAdmission = source.playerAdmission == true,
            reasons = reasons,
            reasonsTruncated = #components > 64,
            recentTransitions = transitions,
            transitionsTruncated = #sourceTransitions > 32
        }, #components
    end
    local coreSearchKinds = {
        capability = true,
        character = true,
        contract = true,
        resource = true,
        session = true,
        trace = true,
        transaction = true,
        user = true
    }
    local function validCoreSearchValue(kind, value)
        if type(value) ~= 'string' or #value < 1 or #value > 128
            or value:find('[%z\1-\31\127]') then return false end
        if kind == 'capability' then
            return value:match('^[a-z][a-z0-9_]*[a-z0-9_.*%-]*$') ~= nil
                and not value:find('..', 1, true)
        end
        if kind == 'contract' then
            local name, version = value:match('^([a-z][a-z0-9_.%-]*)@(%d+%.%d+%.%d+)$')
            if name and version then return true end
            return value:match('^[a-z][a-z0-9_.%-]*$') ~= nil
        end
        if kind == 'resource' then return value:match('^[a-z][a-z0-9_.%-]*$') ~= nil end
        return value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end
    local function validateCoreSearch(request)
        if not requestKeysAllowed(request, {
            query = true,
            cursor = true,
            limit = true,
            filters = true,
            sort = true
        }) or type(request.query) ~= 'table'
            or not requestKeysAllowed(request.query, {
                kind = true,
                value = true,
                mode = true,
                generation = true
            }) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core search requires the closed query envelope.')
        end
        local query = request.query
        local mode = query.mode or 'exact'
        if not coreSearchKinds[query.kind]
            or not validCoreSearchValue(query.kind, query.value)
            or (mode ~= 'exact' and mode ~= 'prefix')
            or (mode == 'prefix' and #query.value < 2)
            or query.generation ~= nil then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core search query kind, value, mode, or generation is invalid.')
        end
        local limit = request.limit == nil and 25 or request.limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 50 then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core search limit must be an integer from 1 through 50.')
        end
        if request.cursor ~= nil and (type(request.cursor) ~= 'string'
            or #request.cursor < 1 or #request.cursor > 256
            or request.cursor:find('[%z\1-\31\127]')) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core search cursor is invalid.')
        end
        local filterCount = 0
        if request.filters ~= nil then
            if type(request.filters) ~= 'table' then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core search filters must be a bounded plain object.')
            end
            for key, value in pairs(request.filters) do
                filterCount = filterCount + 1
                local valueType = type(value)
                if filterCount > 8 or type(key) ~= 'string' or #key < 1 or #key > 48
                    or not key:match('^[a-z][a-zA-Z0-9_.%-]*$')
                    or (valueType ~= 'boolean' and valueType ~= 'number'
                        and (valueType ~= 'string' or #value > 128
                            or value:find('[%z\1-\31\127]'))) then
                    return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                        'Core search filters are invalid.')
                end
            end
        end
        if request.sort ~= nil and (type(request.sort) ~= 'table'
            or not requestKeysAllowed(request.sort, { field = true, direction = true })
            or type(request.sort.field) ~= 'string' or #request.sort.field < 1
            or #request.sort.field > 48
            or not request.sort.field:match('^[a-z][a-zA-Z0-9_.%-]*$')
            or (request.sort.direction ~= 'asc' and request.sort.direction ~= 'desc')) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core search sort is invalid.')
        end
        return {
            kind = query.kind,
            value = query.value,
            mode = mode,
            cursor = request.cursor,
            limit = limit,
            hasFilters = filterCount > 0,
            hasSort = request.sort ~= nil
        }, nil
    end
    local function unavailableSearch(search, status, reason)
        local sensitiveKind = search.kind == 'session' or search.kind == 'character'
            or search.kind == 'user' or search.kind == 'trace'
        return {
            kind = search.kind,
            mode = search.mode,
            value = sensitiveKind and 'exact-match' or search.value,
            status = status,
            reason = reason,
            items = {},
            nextCursor = nil,
            hasMore = false,
            truncated = false,
            payloadsExposed = false
        }, nil
    end
    local function validCoreLimit(value, maximum)
        return value == nil or type(value) == 'number' and math.type(value) == 'integer'
            and value >= 1 and value <= (maximum or 50)
    end
    local function emptyControlFilters(value)
        return value == nil or type(value) == 'table' and next(value) == nil
    end
    local function unavailableSection(view, reason)
        return {
            view = view,
            status = 'UNAVAILABLE',
            reason = reason,
            items = {},
            nextCursor = nil,
            hasMore = false,
            truncated = false
        }, nil
    end
    local function namedSearch(search, entries, keyFor, project, matchFor)
        local output = {}
        local hasMore = false
        local lastKey = nil
        for _, entry in ipairs(entries) do
            local key = keyFor(entry)
            local matchValue = matchFor and matchFor(entry) or key
            local matches = search.mode == 'exact' and matchValue == search.value
                or search.mode == 'prefix'
                    and matchValue:sub(1, #search.value) == search.value
            if matches and (search.cursor == nil or key > search.cursor) then
                if #output >= search.limit then
                    hasMore = true
                    break
                end
                output[#output + 1] = project(entry)
                lastKey = key
            end
        end
        return {
            kind = search.kind,
            mode = search.mode,
            value = search.value,
            status = 'AVAILABLE',
            items = output,
            nextCursor = hasMore and lastKey or nil,
            hasMore = hasMore,
            truncated = hasMore,
            payloadsExposed = false
        }
    end
    local function requiredInspectInput(label, format, minimumLength, maximumLength)
        return {
            fields = {{
                key = 'id',
                label = label,
                source = 'id',
                type = 'string',
                format = format,
                required = true,
                minLength = minimumLength or 1,
                maxLength = maximumLength or 128
            }}
        }
    end
    local function characterDomainRelations(characterId, context)
        local namespaces = { 'groups', 'accounts', 'entities' }
        local related = {}
        if not controlProviders or type(coreResource) ~= 'string' then
            for _, namespace in ipairs(namespaces) do
                related[namespace] = {
                    status = 'UNAVAILABLE', provider = namespace,
                    reason = 'CONTROL_PROVIDER_REGISTRY_UNAVAILABLE',
                    hasMore = false, truncated = false, linksExposed = false,
                }
            end
            return related
        end
        local callerEpoch = registries.owners:epoch(coreResource)
        if type(callerEpoch) ~= 'number' or math.type(callerEpoch) ~= 'integer'
            or callerEpoch < 1 then
            for _, namespace in ipairs(namespaces) do
                related[namespace] = {
                    status = 'UNAVAILABLE', provider = namespace,
                    reason = 'CORE_OWNER_EPOCH_UNAVAILABLE',
                    hasMore = false, truncated = false, linksExposed = false,
                }
            end
            return related
        end
        for _, namespace in ipairs(namespaces) do
            local timeoutMs = 125
            if type(context) == 'table' and type(context.deadlineAt) == 'number' then
                timeoutMs = math.min(timeoutMs,
                    math.floor(context.deadlineAt - foundation.monotonicMs() - 40))
            end
            if timeoutMs < 25 then
                related[namespace] = {
                    status = 'UNAVAILABLE', provider = namespace,
                    reason = 'CONTROL_PROVIDER_DEADLINE_EXHAUSTED',
                    hasMore = false, truncated = false, linksExposed = false,
                }
            else
                local envelope, providerError = controlProviders:invoke(
                    coreResource, callerEpoch, namespace, 'inspect', {
                        view = 'character_relations', id = characterId, limit = 8,
                    }, { timeoutMs = timeoutMs },
                    type(context) == 'table' and context.traceId or nil)
                local data = envelope and envelope.data or nil
                if type(data) == 'table' and type(data.items) == 'table'
                    and type(data.count) == 'number' then
                    related[namespace] = {
                        status = 'AVAILABLE', provider = namespace,
                        count = math.max(0, math.floor(data.count)),
                        hasMore = data.hasMore == true,
                        truncated = data.truncated == true or #data.items > 8,
                        linksExposed = false, payloadsExposed = false,
                    }
                else
                    related[namespace] = {
                        status = 'UNAVAILABLE', provider = namespace,
                        reason = providerError and providerError.code
                            or 'INVALID_CHARACTER_RELATION_RESPONSE',
                        retryable = providerError and providerError.retryable == true,
                        hasMore = false, truncated = false, linksExposed = false,
                    }
                end
            end
        end
        return related
    end

    return {
        coreListViews = coreListViews,
        coreInspectViews = coreInspectViews,
        coreInspectIdViews = coreInspectIdViews,
        controlSeverity = controlSeverity,
        controlLifecycleSnapshot = controlLifecycleSnapshot,
        validCoreSearchValue = validCoreSearchValue,
        validateCoreSearch = validateCoreSearch,
        unavailableSearch = unavailableSearch,
        validCoreLimit = validCoreLimit,
        emptyControlFilters = emptyControlFilters,
        unavailableSection = unavailableSection,
        namedSearch = namedSearch,
        requiredInspectInput = requiredInspectInput,
        characterDomainRelations = characterDomainRelations
    }
end
