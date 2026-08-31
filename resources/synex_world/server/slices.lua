SynexWorldSlices = {}

local Slices = SynexWorldSlices
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function Slices.create(options)
    local registry = assert(options.registry, 'world slices require a registry')
    local contextResolver = assert(options.contextResolver, 'world slices require context')
    local mapRegistry = assert(options.mapRegistry, 'world slices require maps')
    local getDoorState = assert(options.getDoorState, 'world slices require door state')
    local getState = assert(options.getState, 'world slices require world state')
    local getPlayers = assert(options.getPlayers, 'world slices require players')
    local getPlayer = assert(options.getPlayer, 'world slices require sessions')
    local getPosition = assert(options.getPosition, 'world slices require position')
    local getInstance = assert(options.getInstance, 'world slices require instances')
    local triggerClient = assert(options.triggerClient, 'world slices require client transport')
    local encode = assert(options.encode, 'world slices require JSON encoding')
    local presence = options.presence
    local observe = options.observe or function() end
    local subscriptions, revision, authorityGeneration = {}, 0, 0
    local stateIndex, stateIndexRevision = {}, -1
    local slices = {}

    local function stateScopeIdentity(scopeType, scopeRef)
        return tostring(scopeType) .. '\0' .. tostring(scopeRef or 'global')
    end

    local plural = { region = 'regions', location = 'locations', interior = 'interiors',
        room = 'rooms', zone = 'zones', anchor = 'anchors', door = 'doors', portal = 'portals' }

    local function safeRef(value)
        return value and { kind = value.kind, key = value.key, revision = value.revision } or nil
    end

    local instanceStates = { CREATING = true, READY = true, ACTIVE = true,
        DRAINING = true, CLOSED = true, FAILED = true }

    local function clientContext(value)
        local projected = Validation.copy(value)
        if value.instance == nil then return projected end
        local instance = value.instance
        local template, templateError = Validation.worldRef(instance.template, 'instance_template')
        if type(instance.instanceId) ~= 'string' or #instance.instanceId < 8
            or #instance.instanceId > 64
            or instance.instanceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or not template or not instanceStates[instance.state]
            or not Validation.isInteger(instance.revision, 1, 2147483647) then
            return nil, templateError or select(2, Validation.failure('UNAVAILABLE',
                'World instance context cannot be projected safely.', true))
        end
        projected.instance = {
            instanceId = instance.instanceId,
            template = template,
            state = instance.state,
            revision = instance.revision,
        }
        return projected
    end

    local function project(object, distance)
        local result = { kind = object.kind, key = object.key, revision = object.revision,
            label = object.label, parent = object.parent,
            tags = Validation.copy(object.tags or {}) }
        if object.position then result.position = Validation.copy(object.position) end
        if distance then result.distance = distance end
        if object.kind == 'anchor' then
            result.radius = object.radius
            result.entityRef = Validation.copy(object.entityRef)
        elseif object.kind == 'door' then
            local state, stateError = getDoorState(object.key)
            if not state then
                if stateError then return nil, stateError end
                return Validation.failure('UNAVAILABLE',
                    'World door state projection is unavailable.', true)
            end
            result.state, result.stateVersion = state.state, state.version
            result.leaves = {}
            for index, leaf in ipairs(object.leaves) do
                local hash = Validation.uint32(leaf.doorHash)
                    or Validation.doorHash(object.key, leaf.id)
                result.leaves[index] = { doorHash = hash, modelHash = leaf.model,
                    position = Validation.copy(leaf.position) }
            end
        elseif object.kind == 'portal' then
            result.portalType, result.enabled = object.portalType, object.enabled
            result.source = Validation.copy(object.source)
            result.position = object.source and Validation.copy(object.source.position) or nil
        end
        return result
    end

    local function contextSignature(context)
        local values = {}
        local function append(name, reference)
            values[#values + 1] = name .. '='
                .. (type(reference) == 'table' and tostring(reference.key or '') or '')
        end
        append('region', context and context.region)
        append('location', context and context.location)
        append('interior', context and context.interior)
        append('room', context and context.room)
        for _, field in ipairs({ 'regions', 'zones' }) do
            local keys = {}
            for _, reference in ipairs(context and context[field] or {}) do
                if type(reference) == 'table' and type(reference.key) == 'string' then
                    keys[#keys + 1] = reference.key
                end
            end
            table.sort(keys)
            values[#values + 1] = field .. '=' .. table.concat(keys, ',')
        end
        return table.concat(values, '|')
    end

    local function instanceSignature(instance)
        if not instance then return '-' end
        return table.concat({ tostring(instance.instanceId or ''),
            tostring(instance.revision or ''), tostring(instance.state or '') }, ':')
    end

    local function fingerprint(position, instance, context, registryRevision, mapGeneration)
        return math.floor(position.x / Limits.fineCellSize) .. ':'
            .. math.floor(position.y / Limits.fineCellSize) .. ':'
            .. math.floor(position.z / Limits.fineCellSize) .. ':'
            .. tostring(instance and instance.instanceId or '-') .. ':'
            .. tostring(registryRevision) .. ':' .. tostring(mapGeneration) .. ':'
            .. contextSignature(context)
    end

    local function withinMovementThreshold(origin, position)
        if type(origin) ~= 'table' then return false end
        local dx, dy, dz = position.x - origin.x, position.y - origin.y,
            position.z - origin.z
        return dx * dx + dy * dy + dz * dz
            < Limits.sliceMovementThreshold * Limits.sliceMovementThreshold
    end

    local function refreshStateIndex()
        local currentRevision = registry.currentRevision()
        if stateIndexRevision == currentRevision then return end
        local candidate = {}
        for _, definition in ipairs(registry.kindObjects('world_state_definition')) do
            local scope = candidate[definition.scope]
            if not scope then
                scope = { unparented = {}, byParent = {} }
                candidate[definition.scope] = scope
            end
            if definition.parent == nil then
                scope.unparented[#scope.unparented + 1] = definition
            else
                scope.byParent[definition.parent] = scope.byParent[definition.parent] or {}
                local entries = scope.byParent[definition.parent]
                entries[#entries + 1] = definition
            end
        end
        stateIndex, stateIndexRevision = candidate, currentRevision
    end

    local function relevantStateDefinitions(context, instance)
        refreshStateIndex()
        local projections, seenProjections = {}, {}
        local function append(entries, scopeRef)
            for _, definition in ipairs(entries or {}) do
                local identity = definition.key .. '\0' .. tostring(scopeRef or 'global')
                if not seenProjections[identity] then
                    seenProjections[identity] = true
                    projections[#projections + 1] = {
                        definition = definition, scopeRef = scopeRef,
                    }
                    if #projections > Limits.maximumSliceStates then return false end
                end
            end
            return true
        end
        local function appendHierarchy(scope, reference, scopeRef)
            if not reference or type(reference.key) ~= 'string' then return true end
            local current = registry.get(reference.key)
            local traversed = 0
            while current do
                if not append(scope.byParent[current.key], scopeRef) then return false end
                traversed = traversed + 1
                if traversed > 16 then return false end
                current = current.parent and registry.get(current.parent) or nil
            end
            return true
        end
        local globalScope = stateIndex.global
        if globalScope and not append(globalScope.unparented, nil) then return nil end

        local regionScope = stateIndex.region
        if regionScope then
            local regionRefs, seenRegions = {}, {}
            local function addRegion(reference)
                if type(reference) == 'table' and type(reference.key) == 'string'
                    and not seenRegions[reference.key] then
                    seenRegions[reference.key] = true
                    regionRefs[#regionRefs + 1] = reference
                end
            end
            addRegion(context.region)
            for _, reference in ipairs(context.regions or {}) do addRegion(reference) end
            table.sort(regionRefs, function(left, right) return left.key < right.key end)
            for _, reference in ipairs(regionRefs) do
                if not append(regionScope.unparented, reference.key)
                    or not appendHierarchy(regionScope, reference, reference.key) then return nil end
            end
        end

        for _, scopeName in ipairs({ 'location', 'interior', 'room' }) do
            local reference, scope = context[scopeName], stateIndex[scopeName]
            if reference and scope then
                if not append(scope.unparented, reference.key)
                    or not appendHierarchy(scope, reference, reference.key) then return nil end
            end
        end

        local instanceScope = stateIndex.instance
        if instanceScope and instance and type(instance.instanceId) == 'string' then
            if not append(instanceScope.unparented, instance.instanceId) then return nil end
            local templateRef = instance.template
            local template = templateRef and registry.get(templateRef.key, 'instance_template')
            local baseLocation = template and registry.get(template.baseLocation, 'location')
            if not appendHierarchy(instanceScope, baseLocation, instance.instanceId) then return nil end
        end
        table.sort(projections, function(left, right)
            return left.definition.key < right.definition.key
                or left.definition.key == right.definition.key
                    and tostring(left.scopeRef or '') < tostring(right.scopeRef or '')
        end)
        return projections
    end

    function slices.updateSource(source, force)
        local buildAuthorityGeneration = authorityGeneration
        local initialRegistryRevision = registry.currentRevision()
        local initialMapGeneration = mapRegistry.summary().generation
        local session, sessionError = getPlayer(source)
        if not session or session.state ~= 'ACTIVE' or type(session.id) ~= 'string'
            or type(session.characterId) ~= 'string' then
            subscriptions[source] = nil
            return nil, sessionError
        end
        local position, positionError = getPosition(source)
        if not position then return nil, positionError end
        local instance = getInstance(source)
        local context, contextError = contextResolver.resolve(position, instance)
        if not context then return nil, contextError end
        local buildRegistryRevision = registry.currentRevision()
        local buildMapGeneration = mapRegistry.summary().generation
        if buildRegistryRevision ~= initialRegistryRevision
            or buildMapGeneration ~= initialMapGeneration then
            return Validation.failure('STALE_RESOURCE',
                'World authority changed while client context was resolved.', true)
        end
        if presence then presence.observe(source, session, context,
            { traceId = 'world_presence_' .. source }) end
        local buildInstanceSignature = instanceSignature(instance)
        local currentFingerprint = fingerprint(position, instance, context,
            buildRegistryRevision, buildMapGeneration)
        local previous = subscriptions[source]
        if not force and previous and previous.fingerprint == currentFingerprint
            and previous.sourceGeneration == session.sourceGeneration
            and withinMovementThreshold(previous.origin, position) then return false end
        local nearby, nearbyError = contextResolver.queryNearby(position,
            Limits.sliceQueryRadius + Limits.sliceMovementThreshold,
            { availableOnly = true }, Limits.maximumSliceObjects)
        if not nearby then return nil, nearbyError end
        local projectedContext, projectionError = clientContext(context)
        if not projectedContext then return nil, projectionError end
        local payload = { schemaVersion = 1, context = projectedContext,
            bundleRevisions = {}, state = {}, regions = {}, locations = {}, interiors = {},
            rooms = {}, zones = {}, anchors = {}, doors = {}, portals = {} }
        local bundleSet, included = {}, {}
        for _, entry in ipairs(nearby) do
            local object = entry.object
            local list = plural[object.kind]
            if list and not included[object.key] then
                included[object.key] = true
                local projected, projectError = project(object, entry.distance)
                if not projected then return nil, projectError end
                payload[list][#payload[list] + 1] = projected
                bundleSet[object.bundleKey] = true
            end
        end
        for _, field in ipairs({ 'region', 'location', 'interior', 'room' }) do
            local ref = context[field]
            if ref and not included[ref.key] then
                local object = registry.get(ref.key)
                local list = object and plural[object.kind]
                if object and list then
                    local projected, projectError = project(object)
                    if not projected then return nil, projectError end
                    payload[list][#payload[list] + 1] = projected
                    included[object.key], bundleSet[object.bundleKey] = true, true
                end
            end
        end
        for key in pairs(bundleSet) do
            local bundle = registry.bundles()[key]
            if bundle then payload.bundleRevisions[key] = bundle.revision end
        end
        local projectedObjects = {}
        for key in pairs(included) do projectedObjects[#projectedObjects + 1] = registry.get(key) end
        if instance and instance.template and instance.template.key then
            local template = registry.get(instance.template.key, 'instance_template')
            if template then projectedObjects[#projectedObjects + 1] = template end
        end
        local requirementsError
        payload.ipls, payload.interiorSets, requirementsError =
            mapRegistry.clientRequirements(projectedObjects, instance)
        if not payload.ipls then return nil, requirementsError end
        local stateDefinitions = relevantStateDefinitions(context, instance)
        if not stateDefinitions then
            return Validation.failure('QUERY_LIMIT_EXCEEDED',
                'World client slice state limit was exceeded.', true)
        end
        local projectedStateScopes = {}
        for _, projection in ipairs(stateDefinitions) do
            local definition, scopeRef = projection.definition, projection.scopeRef
            projectedStateScopes[stateScopeIdentity(definition.scope, scopeRef)] = true
            local state, stateError = getState({
                key = definition.key, scopeRef = scopeRef,
            })
            if not state and stateError and stateError.code ~= 'WORLD_STATE_NOT_FOUND' then
                return nil, stateError
            end
            if state then
                payload.state[#payload.state + 1] = {
                    key = state.key, scope = Validation.copy(state.scope),
                    valueType = state.valueType,
                    value = Validation.copy(state.value), version = state.version,
                    definitionRevision = state.definitionRevision,
                    persistent = state.persistent,
                }
            end
        end
        local total = 0
        for _, key in pairs(plural) do total = total + #payload[key] end
        if total > Limits.maximumSliceObjects then
            return Validation.failure('QUERY_LIMIT_EXCEEDED', 'World client slice object limit was exceeded.', true)
        end
        revision = revision + 1
        if revision > 2147483647 then revision = 1 end
        payload.revision = revision
        local encodedOk, encoded = pcall(encode, payload)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > Limits.maximumSliceBytes then
            return Validation.failure('QUERY_LIMIT_EXCEEDED', 'World client slice byte limit was exceeded.', true)
        end
        local currentPosition, currentPositionError = getPosition(source)
        if not currentPosition then return nil, currentPositionError end
        local currentInstance = getInstance(source)
        local currentContext, currentContextError = contextResolver.resolve(
            currentPosition, currentInstance)
        if not currentContext then return nil, currentContextError end
        local finalRegistryRevision = registry.currentRevision()
        local finalMapGeneration = mapRegistry.summary().generation
        local finalFingerprint = fingerprint(currentPosition, currentInstance, currentContext,
            finalRegistryRevision, finalMapGeneration)
        if finalFingerprint ~= currentFingerprint
            or instanceSignature(currentInstance) ~= buildInstanceSignature
            or not withinMovementThreshold(position, currentPosition) then
            return Validation.failure('STALE_RESOURCE',
                'World authority changed while the client slice was built.', true)
        end
        local currentSession, currentSessionError = getPlayer(source)
        if not currentSession then return nil, currentSessionError end
        if currentSession.state ~= 'ACTIVE' or currentSession.id ~= session.id
            or currentSession.sourceGeneration ~= session.sourceGeneration then
            return Validation.failure('STALE_RESOURCE',
                'Player session changed while the World client slice was built.', true)
        end
        if registry.currentRevision() ~= buildRegistryRevision
            or mapRegistry.summary().generation ~= buildMapGeneration
            or instanceSignature(getInstance(source)) ~= buildInstanceSignature
            or authorityGeneration ~= buildAuthorityGeneration then
            return Validation.failure('STALE_RESOURCE',
                'World authority changed before the client slice was delivered.', true)
        end
        triggerClient(source, 'synex_world:client:replace_slice', payload)
        subscriptions[source] = { fingerprint = currentFingerprint,
            sourceGeneration = session.sourceGeneration, revision = revision,
            origin = Validation.copy(position),
            doors = {}, stateScopes = projectedStateScopes,
            bytes = #encoded, updatedAt = os.time() }
        for _, door in ipairs(payload.doors) do subscriptions[source].doors[door.key] = true end
        observe('slice', #encoded, total)
        return { source = source, revision = revision, bytes = #encoded, objects = total }
    end

    function slices.updateAll(force)
        local players = getPlayers()
        if not Validation.isDenseArray(players, Limits.maximumClientSlices) then
            return Validation.failure('UNAVAILABLE', 'World player snapshot exceeds its bound.', true)
        end
        local updated, failures = 0, 0
        for _, value in ipairs(players) do
            local source = tonumber(value)
            if Validation.isInteger(source, 1, 65535) then
                local result = slices.updateSource(source, force)
                if result then updated = updated + 1 elseif result == nil then failures = failures + 1 end
            end
        end
        return { updated = updated, failures = failures, players = #players }
    end

    function slices.doorChanged(key, state)
        authorityGeneration = authorityGeneration + 1
        if authorityGeneration > 2147483647 then authorityGeneration = 1 end
        revision = revision + 1
        if revision > 2147483647 then revision = 1 end
        local delivered = 0
        for source, subscription in pairs(subscriptions) do
            if subscription.doors[key] then
                triggerClient(source, 'synex_world:client:door_state', {
                    schemaVersion = 1, key = key, state = state.state,
                    stateVersion = state.version,
                    definitionRevision = state.definitionRevision,
                    revision = revision,
                })
                delivered = delivered + 1
            end
        end
        return delivered
    end

    function slices.stateChanged(state)
        if type(state) ~= 'table' or type(state.scope) ~= 'table'
            or type(state.scope.type) ~= 'string' then return 0 end
        authorityGeneration = authorityGeneration + 1
        if authorityGeneration > 2147483647 then authorityGeneration = 1 end
        local identity = stateScopeIdentity(state.scope.type, state.scope.ref)
        local invalidated = 0
        for _, subscription in pairs(subscriptions) do
            if state.scope.type == 'global' or subscription.stateScopes[identity] then
                subscription.fingerprint = nil
                invalidated = invalidated + 1
            end
        end
        return invalidated
    end

    function slices.remove(source)
        subscriptions[source] = nil
        if presence then presence.remove(source) end
    end
    function slices.invalidateAll()
        for _, subscription in pairs(subscriptions) do subscription.fingerprint = nil end
    end
    function slices.summary()
        local clients, bytes = 0, 0
        for _, subscription in pairs(subscriptions) do
            clients, bytes = clients + 1, bytes + subscription.bytes
        end
        return { clients = clients, bytes = bytes, revision = revision }
    end
    return slices
end
