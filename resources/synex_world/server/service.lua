SynexWorldService = {}

local Service = SynexWorldService
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')
local Geometry = assert(SynexWorldGeometry, 'world geometry must be loaded first')

local objectKinds = {
    region = true, location = true, interior = true, room = true, zone = true,
    anchor = true, door = true, portal = true, instance_template = true,
    map_package = true, ipl_bundle = true, world_state_definition = true,
}

local function exact(candidate, allowed)
    return Validation.isPlainTable(candidate) and Validation.exactObject(candidate, allowed)
end

function Service.create(options)
    local foundation = assert(options.foundation, 'world service requires foundation')
    local registry = assert(options.registry, 'world service requires registry')
    local contextResolver = assert(options.contextResolver, 'world service requires context resolver')
    local mapRegistry = assert(options.mapRegistry, 'world service requires map registry')
    local stateEngine = assert(options.stateEngine, 'world service requires state engine')
    local doorEngine = assert(options.doorEngine, 'world service requires door engine')
    local access = assert(options.access, 'world service requires access engine')
    local portals = assert(options.portals, 'world service requires portal engine')
    local instances = assert(options.instances, 'world service requires instance engine')
    local bundleLoader = assert(options.bundleLoader, 'world service requires bundle loader')
    local diagnostics = assert(options.diagnostics, 'world service requires diagnostics')
    local observability = assert(options.observability, 'world service requires observability')
    local getPlayer = assert(options.getPlayer, 'world service requires player sessions')
    local getPosition = assert(options.getPosition, 'world service requires player positions')
    local now = assert(options.now, 'world service requires monotonic time')
    local rateBuckets, contractBuckets, contractBucketCount = {}, {}, 0
    local contractRates = {}
    local service = {}

    local function caller(context)
        if type(context) ~= 'table' then
            return Validation.failure('STALE_RESOURCE', 'World caller context is unavailable.', true)
        end
        local resource, resourceError = Validation.resourceName(context.caller)
        if not resource then return nil, resourceError end
        if not Validation.isInteger(context.callerEpoch, 1, 9007199254740991)
            or type(context.traceId) ~= 'string' or #context.traceId < 8
            or #context.traceId > 64 then
            return Validation.failure('STALE_RESOURCE', 'World caller lifecycle is invalid.', true)
        end
        return resource
    end

    local function activeSession(source, expected)
        local session, sessionError = getPlayer(source)
        if not session then
            if sessionError then return nil, sessionError end
            return Validation.failure('STALE_RESOURCE',
                'World player session is unavailable.', true)
        end
        if session.state ~= 'ACTIVE' or type(session.id) ~= 'string'
            or type(session.characterId) ~= 'string'
            or not Validation.isInteger(session.sourceGeneration, 1, 9007199254740991)
            or expected and (session.id ~= expected.id
                or session.sourceGeneration ~= expected.sourceGeneration) then
            return Validation.failure('STALE_RESOURCE',
                'World player session changed during the operation.', true)
        end
        return session
    end

    local function take(context, cost)
        local resource, callerError = caller(context)
        if not resource then return nil, callerError end
        local current = now()
        local bucket = rateBuckets[resource]
        if not bucket then
            if next(rateBuckets) and (function()
                local count = 0
                for _ in pairs(rateBuckets) do count = count + 1 end
                return count
            end)() >= 512 then
                return Validation.failure('RATE_LIMITED', 'World caller capacity is exhausted.', true)
            end
            bucket = { tokens = 120, updatedAt = current, epoch = context.callerEpoch }
            rateBuckets[resource] = bucket
        elseif bucket.epoch ~= context.callerEpoch then
            bucket.tokens, bucket.updatedAt, bucket.epoch = 120, current, context.callerEpoch
        end
        local elapsed = math.max(0, current - bucket.updatedAt)
        bucket.tokens = math.min(120, bucket.tokens + elapsed * 0.03)
        bucket.updatedAt = current
        if bucket.tokens < cost then
            return Validation.failure('RATE_LIMITED', 'World caller rate limit was exceeded.', true)
        end
        bucket.tokens = bucket.tokens - cost
        return resource
    end

    local function takeContract(context, operation)
        local resource, callerError = caller(context)
        if not resource then return nil, callerError end
        local rate = contractRates[operation]
        if not rate then
            return Validation.failure('UNAVAILABLE', 'World contract rate policy is unavailable.', true)
        end
        local key = resource .. '\0' .. operation
        local current = now()
        local bucket = contractBuckets[key]
        if not bucket then
            if contractBucketCount >= 4096 then
                return Validation.failure('RATE_LIMITED',
                    'World contract caller capacity is exhausted.', true)
            end
            bucket = { tokens = rate.capacity, updatedAt = current,
                epoch = context.callerEpoch, resource = resource }
            contractBuckets[key], contractBucketCount = bucket, contractBucketCount + 1
        elseif bucket.epoch ~= context.callerEpoch then
            bucket.tokens, bucket.updatedAt, bucket.epoch =
                rate.capacity, current, context.callerEpoch
        end
        local elapsed = math.max(0, current - bucket.updatedAt)
        bucket.tokens = math.min(rate.capacity,
            bucket.tokens + elapsed * rate.refillPerSecond / 1000)
        bucket.updatedAt = current
        if bucket.tokens < 1 then
            return Validation.failure('RATE_LIMITED',
                'World contract caller rate limit was exceeded.', true)
        end
        bucket.tokens = bucket.tokens - 1
        return resource
    end

    local function projection(object, detailed)
        if not object then return nil end
        local result = {
            kind = object.kind, key = object.key, revision = object.revision,
            label = object.label, parent = object.parent,
            tags = Validation.copy(object.tags or {}),
            ownerResource = object.ownerResource, bundleKey = object.bundleKey,
            mapPackages = Validation.copy(object.mapPackages or {}),
            iplBundles = Validation.copy(object.iplBundles or {}),
        }
        if detailed and object.geometry then result.geometry = Validation.copy(object.geometry) end
        if object.kind == 'anchor' then
            result.position, result.radius = Validation.copy(object.position), object.radius
            result.entityRef = Validation.copy(object.entityRef)
        elseif object.kind == 'door' then
            result.leaves = detailed and Validation.copy(object.leaves) or nil
            result.position, result.defaultState = Validation.copy(object.position), object.defaultState
            result.persistent, result.autoRelockSeconds = object.persistent, object.autoRelockSeconds
            result.accessPolicy = detailed and Validation.copy(object.accessPolicy) or nil
        elseif object.kind == 'portal' then
            result.portalType, result.enabled = object.portalType, object.enabled
            result.source = Validation.copy(object.source)
            result.destination = detailed and Validation.copy(object.destination) or nil
            result.accessPolicy = detailed and Validation.copy(object.accessPolicy) or nil
        elseif object.kind == 'instance_template' then
            result.baseLocation, result.entry, result.exit = object.baseLocation,
                Validation.copy(object.entry), Validation.copy(object.exit)
            result.capacity, result.ttlSeconds = object.capacity, object.ttlSeconds
            result.isolationProfile, result.cleanupPolicy = object.isolationProfile, object.cleanupPolicy
        elseif object.kind == 'map_package' then
            result.resourceName, result.packageType = object.resourceName, object.packageType
            result.expectedResourceState, result.required = object.expectedResourceState, object.required
            result.locations, result.dependencies = Validation.copy(object.locations),
                Validation.copy(object.dependencies)
            result.version = object.version
        elseif object.kind == 'ipl_bundle' then
            result.scope, result.ipls = object.scope, Validation.copy(object.ipls)
            result.interiorSets = Validation.copy(object.interiorSets)
        elseif object.kind == 'world_state_definition' then
            result.stateType, result.scope = object.stateType, object.scope
            result.persistence, result.schemaVersion = object.persistence, object.schemaVersion
            result.minimum, result.maximum, result.maxLength = object.minimum,
                object.maximum, object.maxLength
            result.allowed, result.default = Validation.copy(object.allowed),
                Validation.copy(object.default)
            if detailed then result.structuredSchema = Validation.copy(object.structuredSchema) end
        elseif object.kind == 'interior' then
            result.gameInteriorId = object.gameInteriorId
        elseif object.kind == 'room' then
            result.gameRoomKey = object.gameRoomKey
        end
        return result
    end

    local function filters(candidate)
        if candidate == nil then return {} end
        if not exact(candidate, { kind = true, tags = true, availableOnly = true })
            or candidate.kind ~= nil and not objectKinds[candidate.kind]
            or candidate.availableOnly ~= nil and type(candidate.availableOnly) ~= 'boolean' then
            return Validation.failure('INVALID_ARGUMENT', 'World query filters are invalid.')
        end
        local tags, tagsError = Validation.tags(candidate.tags)
        if not tags then return nil, tagsError end
        return { kind = candidate.kind, tags = tags,
            availableOnly = candidate.availableOnly ~= false }
    end

    local function queryResult(entries, metadata, nearby)
        local items = {}
        for index, entry in ipairs(entries) do
            if nearby then
                items[index] = { object = projection(entry.object, false), distance = entry.distance }
            else
                items[index] = projection(entry, false)
            end
        end
        return { items = items, candidates = metadata and metadata.candidates or #items,
            truncated = metadata and metadata.truncated == true or false,
            revision = registry.currentRevision() }
    end

    local function measured(name, handler)
        local started = os.clock()
        local value, operationError = handler()
        observability.increment('query_total', { operation = name,
            result = value and 'success' or 'failure' }, 1)
        observability.observe('query_duration', { operation = name },
            math.max(0, (os.clock() - started) * 1000))
        return value, operationError
    end

    function service.getHealth(request, context)
        if not exact(request or {}, {}) then
            return Validation.failure('INVALID_ARGUMENT', 'World health request must be empty.')
        end
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        return diagnostics.health()
    end

    function service.getControlSummary(request, context)
        if not exact(request or {}, {}) then
            return Validation.failure('INVALID_ARGUMENT', 'World summary request must be empty.')
        end
        local allowed, rateError = take(context, 2)
        if not allowed then return nil, rateError end
        return diagnostics.summary()
    end

    function service.resolve(request, context)
        if not exact(request, { ref = true, key = true, kind = true })
            or (request.ref == nil) == (request.key == nil)
            or request.kind ~= nil and not objectKinds[request.kind] then
            return Validation.failure('INVALID_ARGUMENT', 'World resolve request is invalid.')
        end
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        local object, resolveError
        if request.ref then object, resolveError = registry.resolve(request.ref, request.kind)
        else object, resolveError = registry.get(request.key, request.kind) end
        if not object then return nil, resolveError end
        return projection(object, true)
    end
    service.get = service.resolve

    function service.queryAt(request, context)
        if not exact(request, { position = true, filters = true, limit = true }) then
            return Validation.failure('INVALID_ARGUMENT', 'World point query is invalid.')
        end
        local allowed, rateError = take(context, 2)
        if not allowed then return nil, rateError end
        local queryFilters, filterError = filters(request.filters)
        if not queryFilters then return nil, filterError end
        local limit, limitError = Validation.limit(request.limit, 64, Limits.maximumQueryResults)
        if not limit then return nil, limitError end
        return measured('query_at', function()
            local entries, metadata = contextResolver.queryAt(request.position, queryFilters, limit)
            if not entries then return nil, metadata end
            return queryResult(entries, metadata, false)
        end)
    end

    function service.queryNearby(request, context)
        if not exact(request, { position = true, radius = true, filters = true, limit = true })
            or not Validation.isFinite(request.radius) or request.radius < 0
            or request.radius > Limits.maximumQueryRadius then
            return Validation.failure('INVALID_ARGUMENT', 'World nearby query is invalid.')
        end
        local allowed, rateError = take(context, 3)
        if not allowed then return nil, rateError end
        local queryFilters, filterError = filters(request.filters)
        if not queryFilters then return nil, filterError end
        local limit, limitError = Validation.limit(request.limit, 64, Limits.maximumQueryResults)
        if not limit then return nil, limitError end
        return measured('query_nearby', function()
            local entries, metadata = contextResolver.queryNearby(
                request.position, request.radius, queryFilters, limit)
            if not entries then return nil, metadata end
            return queryResult(entries, metadata, true)
        end)
    end

    function service.getContext(request, context)
        if not exact(request, { position = true, source = true })
            or (request.position == nil) == (request.source == nil) then
            return Validation.failure('INVALID_ARGUMENT', 'World context request is invalid.')
        end
        local allowed, rateError = take(context, 2)
        if not allowed then return nil, rateError end
        local position = request.position
        local instance
        local expectedSession
        if request.source ~= nil then
            if not Validation.isInteger(request.source, 1, 65535) then
                return Validation.failure('INVALID_ARGUMENT', 'World player source is invalid.')
            end
            local session, sessionError = activeSession(request.source)
            if not session then return nil, sessionError end
            expectedSession = { id = session.id,
                sourceGeneration = session.sourceGeneration }
            position, rateError = getPosition(request.source)
            if not position then return nil, rateError end
            instance, rateError = instances.getForSource(request.source, expectedSession)
            if rateError then return nil, rateError end
            session, sessionError = activeSession(request.source, expectedSession)
            if not session then return nil, sessionError end
        end
        return measured('context', function()
            local resolved, resolveError = contextResolver.resolve(position, instance)
            if not resolved then return nil, resolveError end
            if request.source ~= nil then
                local current, sessionError = activeSession(request.source, expectedSession)
                if not current then return nil, sessionError end
            end
            return resolved
        end)
    end

    function service.verifyContext(request, context)
        if not exact(request, { source = true, expected = true })
            or not Validation.isInteger(request.source, 1, 65535) then
            return Validation.failure('INVALID_ARGUMENT', 'World context verification is invalid.')
        end
        local allowed, rateError = take(context, 3)
        if not allowed then return nil, rateError end
        local session, sessionError = activeSession(request.source)
        if not session then return nil, sessionError end
        local expectedSession = { id = session.id,
            sourceGeneration = session.sourceGeneration }
        local position, positionError = getPosition(request.source)
        if not position then return nil, positionError end
        local instance, instanceError = instances.getForSource(
            request.source, expectedSession)
        if instanceError then return nil, instanceError end
        session, sessionError = activeSession(request.source, expectedSession)
        if not session then return nil, sessionError end
        local verified, verifyError = contextResolver.verify(
            request.expected, position, instance)
        if not verified then return nil, verifyError end
        session, sessionError = activeSession(request.source, expectedSession)
        if not session then return nil, sessionError end
        return verified
    end

    function service.getChildren(request, context)
        if not exact(request, { key = true, kind = true, limit = true })
            or request.kind ~= nil and not objectKinds[request.kind] then
            return Validation.failure('INVALID_ARGUMENT', 'World children request is invalid.')
        end
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        local parent, parentError = registry.get(request.key)
        if not parent then return nil, parentError end
        local limit, limitError = Validation.limit(request.limit, 64, Limits.maximumQueryResults)
        if not limit then return nil, limitError end
        local children = registry.children(parent.key, request.kind, limit + 1)
        local truncated = #children > limit
        if truncated then children[#children] = nil end
        local items = {}
        for index, object in ipairs(children) do
            items[index] = projection(object, false)
        end
        return { parent = registry.ref(parent), items = items,
            truncated = truncated, revision = registry.currentRevision() }
    end

    local function nearbyKind(kind, request, context)
        local candidate = Validation.copy(request or {}) or {}
        candidate.filters = candidate.filters or {}
        if candidate.filters.kind and candidate.filters.kind ~= kind then
            return Validation.failure('INVALID_ARGUMENT', 'World typed query kind conflicts with its endpoint.')
        end
        candidate.filters.kind = kind
        return service.queryNearby(candidate, context)
    end
    function service.getAnchors(request, context) return nearbyKind('anchor', request, context) end
    function service.getDoors(request, context) return nearbyKind('door', request, context) end
    function service.getPortals(request, context) return nearbyKind('portal', request, context) end

    function service.getState(request, context)
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        return stateEngine:get(request)
    end
    function service.getDoorState(request, context)
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        return doorEngine:get(request)
    end
    function service.checkAccess(request, context)
        local allowed, rateError = take(context, 2)
        if not allowed then return nil, rateError end
        return access.check(request, context)
    end
    function service.explainAccess(request, context)
        local allowed, rateError = take(context, 3)
        if not allowed then return nil, rateError end
        return access.explain(request, context)
    end

    function service.listBundles(request, context)
        if not exact(request or {}, { cursor = true, limit = true }) then
            return Validation.failure('INVALID_ARGUMENT', 'World bundle list request is invalid.')
        end
        local allowed, rateError = take(context, 1)
        if not allowed then return nil, rateError end
        local cursor, cursorError = Validation.cursor(request.cursor)
        if request.cursor ~= nil and not cursor then return nil, cursorError end
        local limit, limitError = Validation.limit(request.limit, 25, 100)
        if not limit then return nil, limitError end
        local items, nextCursor = registry.listBundles(cursor, limit)
        return { items = items, nextCursor = nextCursor,
            hasMore = nextCursor ~= nil, truncated = nextCursor ~= nil }
    end

    function service.registerBundle(request, context)
        if not exact(request, { path = true }) or type(request.path) ~= 'string' then
            return Validation.failure('INVALID_ARGUMENT', 'World bundle registration request is invalid.')
        end
        local owner, rateError = take(context, 8)
        if not owner then return nil, rateError end
        return bundleLoader.load(owner, request.path, false, context.callerEpoch, context)
    end
    function service.replaceBundle(request, context)
        if not exact(request, { path = true }) or type(request.path) ~= 'string' then
            return Validation.failure('INVALID_ARGUMENT', 'World bundle replacement request is invalid.')
        end
        local owner, rateError = take(context, 8)
        if not owner then return nil, rateError end
        return bundleLoader.load(owner, request.path, true, context.callerEpoch, context)
    end
    function service.unregisterBundle(request, context)
        if not exact(request, { key = true }) then
            return Validation.failure('INVALID_ARGUMENT', 'World bundle removal request is invalid.')
        end
        local owner, rateError = take(context, 8)
        if not owner then return nil, rateError end
        return bundleLoader.unload(owner, request.key, context.callerEpoch, context)
    end

    function service.doctor(request, context)
        if not exact(request or {}, { includePersistence = true, limit = true }) then
            return Validation.failure('INVALID_ARGUMENT', 'World doctor request is invalid.')
        end
        local allowed, rateError = take(context, 10)
        if not allowed then return nil, rateError end
        return diagnostics.doctor(request)
    end

    function service.contractHandlers(definitions)
        if not Validation.isDenseArray(definitions, 32) then
            return Validation.failure('UNAVAILABLE',
                'World contract rate policies are unavailable.', true)
        end
        local configuredRates = {}
        for _, definition in ipairs(definitions) do
            local rate = type(definition) == 'table' and definition.rateLimit or nil
            if type(definition) ~= 'table' or type(definition.name) ~= 'string'
                or configuredRates[definition.name] ~= nil
                or not exact(rate, { capacity = true, refillPerSecond = true })
                or not Validation.isInteger(rate.capacity, 1, 1000)
                or not Validation.isFinite(rate.refillPerSecond)
                or rate.refillPerSecond <= 0 or rate.refillPerSecond > 1000 then
                return Validation.failure('UNAVAILABLE',
                    'A World contract rate policy is invalid.', true)
            end
            configuredRates[definition.name] = {
                capacity = rate.capacity, refillPerSecond = rate.refillPerSecond,
            }
        end
        local function rejected(operation, targetType, targetId, operationError, context)
            observability.audit('world.privileged_request_rejected', targetType,
                targetId or 'world', {
                    operation = operation,
                    code = type(operationError) == 'table'
                        and operationError.code or 'UNAVAILABLE',
                }, context)
        end
        local handlers = {
            ['synex.world.state.set'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.state.set')
                if not allowed then
                    rejected('state.set', 'world_state', request and request.key,
                        rateError, context)
                    return nil, rateError
                end
                local result, operationError = stateEngine:set(request, context)
                if not result then
                    rejected('state.set', 'world_state', request and request.key,
                        operationError, context)
                    return nil, operationError
                end
                observability.audit('world.state_changed', 'world_state', result.key, {
                    scopeType = result.scope.type, version = result.version,
                    persistent = result.persistent,
                }, context)
                return result
            end,
            ['synex.world.door.set_state'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.door.set_state')
                if not allowed then
                    rejected('door.set_state', 'door', request and request.doorRef
                        and request.doorRef.key, rateError, context)
                    return nil, rateError
                end
                if not exact(request, { doorRef = true, source = true, instanceId = true,
                        state = true, expectedVersion = true, reasonCode = true,
                        idempotencyKey = true }) or request.doorRef == nil
                    or request.source ~= nil
                        and not Validation.isInteger(request.source, 1, 65535) then
                    local _, operationError = Validation.failure('INVALID_ARGUMENT',
                        'World door mutation request is invalid.')
                    rejected('door.set_state', 'door', request and request.doorRef
                        and request.doorRef.key, operationError, context)
                    return nil, operationError
                end
                local door, referenceError = registry.resolve(request.doorRef, 'door')
                if not door then
                    if type(referenceError) == 'table'
                        and referenceError.code == 'WORLD_NOT_FOUND' then
                        local _, translated = Validation.failure('DOOR_NOT_FOUND',
                            'World door does not exist.')
                        referenceError = translated
                    end
                    rejected('door.set_state', 'door', request and request.doorRef
                        and request.doorRef.key, referenceError, context)
                    return nil, referenceError
                end
                local availability = mapRegistry.objectAvailability(door)
                if not availability.available then
                    local _, operationError = Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                        'World door map package is unavailable.', true)
                    rejected('door.set_state', 'door', door.key, operationError, context)
                    return nil, operationError
                end
                if door.accessPolicy and request.source == nil then
                    local _, operationError = Validation.failure('WORLD_ACCESS_DENIED',
                        'World door policy requires an active player source.')
                    rejected('door.set_state', 'door', door.key, operationError, context)
                    return nil, operationError
                end
                local expectedSession
                if request.source ~= nil then
                    expectedSession, referenceError = activeSession(request.source)
                    if not expectedSession then
                        rejected('door.set_state', 'door', door.key, referenceError, context)
                        return nil, referenceError
                    end
                    local position, positionError = getPosition(request.source)
                    if not position then
                        rejected('door.set_state', 'door', door.key, positionError, context)
                        return nil, positionError
                    end
                    if not Geometry.contains(door.compiledGeometry, position, 0) then
                        local _, operationError = Validation.failure('OUT_OF_CONTEXT',
                            'Player is outside the World door boundary.')
                        rejected('door.set_state', 'door', door.key, operationError, context)
                        return nil, operationError
                    end
                    local decision, accessError = access.checkDoorMutation({
                        source = request.source, targetRef = request.doorRef,
                        instanceId = request.instanceId,
                    }, context)
                    if not decision or decision.decision ~= 'ALLOW' then
                        local _, operationError = Validation.failure('WORLD_ACCESS_DENIED',
                            'World door access was denied.',
                            decision and decision.retryable == true,
                            { reason = decision and decision.reason
                                or accessError and accessError.code })
                        rejected('door.set_state', 'door', door.key, operationError, context)
                        return nil, operationError
                    end
                end
                if expectedSession then
                    local currentPosition, positionError = getPosition(request.source)
                    if not currentPosition then
                        rejected('door.set_state', 'door', door.key, positionError, context)
                        return nil, positionError
                    end
                    local currentSession, sessionError = activeSession(request.source, expectedSession)
                    if not currentSession then
                        rejected('door.set_state', 'door', door.key, sessionError, context)
                        return nil, sessionError
                    end
                    if not Geometry.contains(door.compiledGeometry, currentPosition, 0) then
                        local _, operationError = Validation.failure('OUT_OF_CONTEXT',
                            'Player left the World door boundary while access was evaluated.')
                        rejected('door.set_state', 'door', door.key, operationError, context)
                        return nil, operationError
                    end
                end
                local currentDoor, currentDoorError = registry.resolve(request.doorRef, 'door')
                if not currentDoor then
                    rejected('door.set_state', 'door', door.key, currentDoorError, context)
                    return nil, currentDoorError
                end
                local result, operationError = doorEngine:setState({
                    key = currentDoor.key, expectedDefinitionRevision = request.doorRef.revision,
                    state = request.state,
                    expectedVersion = request.expectedVersion,
                    idempotencyKey = request.idempotencyKey,
                    reasonCode = request.reasonCode }, context)
                if not result then
                    rejected('door.set_state', 'door', door.key, operationError, context)
                    return nil, operationError
                end
                observability.audit('world.door_state_changed', 'door', result.key, {
                    state = result.state, version = result.version,
                    persistent = result.persistent,
                }, context)
                return result
            end,
            ['synex.world.portal.transition'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.portal.transition')
                if not allowed then
                    rejected('portal.transition', 'portal', request and request.portalRef
                        and request.portalRef.key, rateError, context)
                    return nil, rateError
                end
                local result, operationError = portals.transition(request, context)
                observability.increment('transition_total', {
                    outcome = result and 'completed' or 'denied',
                }, 1)
                if not result then
                    observability.increment('transition_denied_total', {
                        reason = type(operationError) == 'table'
                            and operationError.code or 'UNAVAILABLE',
                    }, 1)
                    rejected('portal.transition', 'portal', request and request.portalRef
                        and request.portalRef.key, operationError, context)
                end
                return result, operationError
            end,
            ['synex.world.instance.create'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.instance.create')
                if not allowed then
                    rejected('instance.create', 'world_instance', 'new', rateError, context)
                    return nil, rateError
                end
                local result, operationError = instances.create(request, context)
                if not result then
                    rejected('instance.create', 'world_instance', 'new',
                        operationError, context)
                end
                return result, operationError
            end,
            ['synex.world.instance.join'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.instance.join')
                if not allowed then
                    rejected('instance.join', 'world_instance', request and request.instanceId,
                        rateError, context)
                    return nil, rateError
                end
                local result, operationError = instances.join(request, context)
                if not result then
                    rejected('instance.join', 'world_instance', request and request.instanceId,
                        operationError, context)
                    return nil, operationError
                end
                observability.audit('world.instance_member_joined', 'world_instance',
                    result.instanceId, { revision = result.revision, members = result.members }, context)
                return result
            end,
            ['synex.world.instance.leave'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.instance.leave')
                if not allowed then
                    rejected('instance.leave', 'world_instance', request and request.instanceId,
                        rateError, context)
                    return nil, rateError
                end
                local result, operationError = instances.leave(request, context)
                if not result then
                    rejected('instance.leave', 'world_instance', request and request.instanceId,
                        operationError, context)
                    return nil, operationError
                end
                observability.audit('world.instance_member_left', 'world_instance',
                    result.instanceId, { revision = result.revision, members = result.members }, context)
                return result
            end,
            ['synex.world.instance.close'] = function(request, context)
                local allowed, rateError = takeContract(context, 'synex.world.instance.close')
                if not allowed then
                    rejected('instance.close', 'world_instance', request and request.instanceId,
                        rateError, context)
                    return nil, rateError
                end
                local result, operationError = instances.close(request, context)
                if not result then
                    rejected('instance.close', 'world_instance', request and request.instanceId,
                        operationError, context)
                end
                return result, operationError
            end,
        }
        for name in pairs(handlers) do
            if configuredRates[name] == nil then
                return Validation.failure('UNAVAILABLE',
                    'A World contract rate policy is missing.', true)
            end
        end
        contractRates = configuredRates
        return handlers
    end

    function service.serviceDefinition()
        return {
            name = 'synex.world', version = '1.0.0',
            capabilities = {
                getHealth = 'synex.world.diagnostics.read',
                getControlSummary = 'synex.world.diagnostics.read',
                resolve = 'synex.world.read', get = 'synex.world.read',
                queryAt = 'synex.world.query', queryNearby = 'synex.world.query',
                getContext = 'synex.world.query', verifyContext = 'synex.world.query',
                getChildren = 'synex.world.read', getAnchors = 'synex.world.query',
                getDoors = 'synex.world.query', getPortals = 'synex.world.query',
                getState = 'synex.world.state.read', getDoorState = 'synex.world.door.read',
                checkAccess = 'synex.world.read', explainAccess = 'synex.world.read',
                listBundles = 'synex.world.diagnostics.read', doctor = 'synex.world.diagnostics.read',
                registerBundle = 'synex.world.bundle.register',
                replaceBundle = 'synex.world.bundle.register',
                unregisterBundle = 'synex.world.bundle.register',
            },
            methods = {
                getHealth = service.getHealth, getControlSummary = service.getControlSummary,
                resolve = service.resolve, get = service.get,
                queryAt = service.queryAt, queryNearby = service.queryNearby,
                getContext = service.getContext, verifyContext = service.verifyContext,
                getChildren = service.getChildren, getAnchors = service.getAnchors,
                getDoors = service.getDoors, getPortals = service.getPortals,
                getState = service.getState, getDoorState = service.getDoorState,
                checkAccess = service.checkAccess, explainAccess = service.explainAccess,
                listBundles = service.listBundles, doctor = service.doctor,
                registerBundle = service.registerBundle, replaceBundle = service.replaceBundle,
                unregisterBundle = service.unregisterBundle,
            },
        }
    end

    function service.projectObject(object, detailed) return projection(object, detailed == true) end
    function service.removeCaller(resource)
        rateBuckets[resource] = nil
        for key, bucket in pairs(contractBuckets) do
            if bucket.resource == resource then
                contractBuckets[key], contractBucketCount = nil, contractBucketCount - 1
            end
        end
    end
    return service
end
