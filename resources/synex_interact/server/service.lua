SynexInteractService = {}

local Service = SynexInteractService
local V = SynexInteractValidation
local L = SynexInteractLimits
local Graph = SynexInteractActionGraph

function Service.create(options)
    local registry = assert(options.registry, 'interact service requires registry')
    local leases = assert(options.leases, 'interact service requires lease engine')
    local graphs = assert(options.graphs, 'interact service requires action graph engine')
    local core = assert(options.core, 'interact service requires core adapter')
    local getPosition = assert(options.getPosition, 'interact service requires server position resolver')
    local resolveEntityPosition = assert(options.resolveEntityPosition, 'interact service requires entity position resolver')
    local now = assert(options.now, 'interact service requires clock')
    local api = {}

    local function sessionForSource(source)
        local session, sessionError = core.playerBySource(source)
        if not session then
            return V.failure('INTERACT_SESSION_INACTIVE', 'Interaction requires an active Synex session.', true,
                type(sessionError) == 'table' and { coreCode = sessionError.code } or nil)
        end
        if session.state ~= 'ACTIVE' or type(session.id) ~= 'string'
            or type(session.characterId) ~= 'string'
            or not V.isInteger(session.sourceGeneration, 1, 9007199254740991) then
            return V.failure('INTERACT_SESSION_INACTIVE', 'Interaction requires an ACTIVE character session.', true)
        end
        return session
    end

    local function worldCall(method, request, traceId)
        return core.serviceCall('synex.world', '^1.0.0', method, request, { traceId = traceId })
    end

    local function entityQueryByNetId(netId, traceId)
        return core.rpcCall('synex.entities.query.by_net_id', '1.0.0', { netId = netId }, { traceId = traceId })
    end

    local function resolveStaticPosition(definition, traceId)
        if definition.position then return definition.position end
        if definition.anchorRef then
            local anchor, anchorError = worldCall('resolve', { ref = definition.anchorRef, kind = 'anchor' }, traceId)
            if not anchor then
                return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Interaction anchor is unavailable.', true,
                    type(anchorError) == 'table' and { worldCode = anchorError.code } or nil)
            end
            return anchor.position
        end
        return nil
    end

    local function resolveDefinitionPosition(definition, traceId)
        local position, positionError = resolveStaticPosition(definition, traceId)
        if position then return position end
        if positionError and not definition.entityRef then return nil, positionError end
        if definition.entityRef then
            local entityPosition, entityError = resolveEntityPosition(definition.entityRef, traceId)
            if not entityPosition then
                return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Interaction entity is unavailable.', true,
                    type(entityError) == 'table' and { entityCode = entityError.code } or nil)
            end
            return entityPosition
        end
        return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Interaction target has no authoritative position.', true)
    end

    local function hasCapability(session, capability, traceId)
        if capability == nil then return true end
        if type(capability) ~= 'string' or #capability < 3 or #capability > 128 then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction capability is invalid.')
        end
        local result, operationError = core.serviceCall('synex.groups', '^1.0.0', 'capabilities_check', {
            characterId = session.characterId,
            capability = capability,
        }, { traceId = traceId })
        if not result then
            return V.failure('INTERACT_ACCESS_UNAVAILABLE', 'Interaction authorization is temporarily unavailable.', true,
                type(operationError) == 'table' and { groupsCode = operationError.code } or nil)
        end
        if result.allowed ~= true then
            return V.failure('INTERACT_ACCESS_DENIED', 'Interaction capability was denied.')
        end
        return true
    end

    local function actionFor(definition, actionKey)
        for _, action in ipairs(definition.actions) do
            if action.key == actionKey then return action end
        end
        return nil
    end

    local function verifyDistance(source, definition, action, traceId)
        local playerPosition, playerError = getPosition(source)
        if not playerPosition then return nil, playerError end
        local targetPosition, targetError = resolveDefinitionPosition(definition, traceId)
        if not targetPosition then return nil, targetError end
        local maximum = math.min(action.maxDistance or 2.5, definition.radius or L.maximumCandidateRadius)
        local distanceSquared = V.distanceSquared(playerPosition, targetPosition)
        if distanceSquared > maximum * maximum then
            return V.failure('INTERACT_OUT_OF_RANGE', 'Interaction target is outside the authoritative range.')
        end
        return { player = playerPosition, target = targetPosition, distance = math.sqrt(distanceSquared) }
    end

    local function verifyWorldContext(source, expected, traceId)
        if expected == nil then return true end
        local verified, verifyError = worldCall('verifyContext', { source = source, expected = expected }, traceId)
        if not verified then
            return V.failure('INTERACT_CONTEXT_CHANGED', 'World context changed before the interaction.', true,
                type(verifyError) == 'table' and { worldCode = verifyError.code } or nil)
        end
        return verified
    end

    local function appendCandidate(items, seen, definition, action, distance, position, session, traceId)
        if distance > action.maxDistance then return end
        local candidateKey = definition.key .. '\0' .. action.key
        if seen[candidateKey] then return end
        if action.capability then
            local allowed = select(1, hasCapability(session, action.capability, traceId))
            if allowed ~= true then return end
        end
        seen[candidateKey] = true
        items[#items + 1] = {
            objectKey = definition.key,
            actionKey = action.key,
            label = action.label,
            description = action.description,
            icon = action.icon,
            priority = action.priority,
            maxDistance = action.maxDistance,
            distance = distance,
            position = V.copy(position or definition.position),
            entityRef = V.copy(definition.entityRef),
            anchorRef = V.copy(definition.anchorRef),
            revision = definition.revision,
        }
    end

    function api.register(owner, definitions, traceId)
        local resource, ownerError = V.resourceName(owner)
        if not resource then return nil, ownerError end
        if type(definitions) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction definitions are required.')
        end
        local enriched = V.copy(definitions)
        if type(enriched) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction definitions are not bounded JSON-like data.')
        end
        for _, definition in ipairs(enriched) do
            if definition.anchorRef and not definition.position then
                local anchor, anchorError = worldCall('resolve', { ref = definition.anchorRef, kind = 'anchor' }, traceId)
                if not anchor then
                    return V.failure('INTERACT_TARGET_UNAVAILABLE', 'Interaction anchor registration failed.', true,
                        type(anchorError) == 'table' and { worldCode = anchorError.code } or nil)
                end
                definition.position = anchor.position
            end
            for _, action in ipairs(type(definition.actions) == 'table' and definition.actions or {}) do
                if action.graph ~= nil then
                    local validated, graphError = Graph.validate(action.graph)
                    if not validated then return nil, graphError end
                    action.graph = validated
                end
            end
        end
        return registry.register(resource, enriched)
    end

    function api.unregisterOwner(owner)
        leases.releaseOwner(owner)
        return { removed = registry.unregisterOwner(owner) }
    end

    function api.candidates(source, request, traceId)
        request = request or {}
        local session, sessionError = sessionForSource(source)
        if not session then return nil, sessionError end
        local position, positionError = getPosition(source)
        if not position then return nil, positionError end
        local radius = request.radius or 6.0
        if not V.isFinite(radius) or radius <= 0 or radius > L.maximumCandidateRadius then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Candidate radius is invalid.')
        end
        if request.hitNetId ~= nil and not V.isInteger(request.hitNetId, 1, 65535) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Candidate hit Net ID is invalid.')
        end
        local nearby = registry.findNearby(position, radius, L.maximumCandidateResults)
        local items, seen = {}, {}
        for _, entry in ipairs(nearby) do
            local definition = entry.object
            local distance = math.sqrt(entry.distanceSquared)
            for _, action in ipairs(definition.actions) do
                appendCandidate(items, seen, definition, action, distance, definition.position, session, traceId)
            end
        end

        if request.hitNetId then
            local queried = select(1, entityQueryByNetId(request.hitNetId, traceId))
            local entity = type(queried) == 'table' and queried.entity or nil
            if type(entity) == 'table' and type(entity.entityId) == 'string'
                and V.isInteger(entity.generation, 1, 9007199254740991) then
                local targetPosition = nil
                local serverEntity = NetworkGetEntityFromNetworkId(request.hitNetId)
                if serverEntity and serverEntity > 0 and DoesEntityExist(serverEntity) then
                    local coords = GetEntityCoords(serverEntity)
                    targetPosition = select(1, V.vector3({ x = coords.x, y = coords.y, z = coords.z }))
                end
                if targetPosition then
                    local distance = math.sqrt(V.distanceSquared(position, targetPosition))
                    for _, definition in ipairs(registry.forEntity({
                        entityId = entity.entityId,
                        generation = entity.generation,
                    })) do
                        if distance <= math.min(radius, definition.radius) then
                            for _, action in ipairs(definition.actions) do
                                appendCandidate(items, seen, definition, action, distance,
                                    targetPosition, session, traceId)
                            end
                        end
                    end
                end
            end
        end

        table.sort(items, function(a, b)
            if a.priority ~= b.priority then return a.priority > b.priority end
            if a.distance ~= b.distance then return a.distance < b.distance end
            if a.objectKey ~= b.objectKey then return a.objectKey < b.objectKey end
            return a.actionKey < b.actionKey
        end)
        while #items > L.maximumCandidateResults do table.remove(items) end
        local worldContext = select(1, worldCall('getContext', { source = source }, traceId))
        return {
            items = items,
            worldContext = worldContext,
            registryRevision = registry.revision(),
            session = { id = session.id, sourceGeneration = session.sourceGeneration },
            serverTime = now(),
        }
    end

    function api.begin(source, request, traceId)
        if type(request) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction begin request is invalid.')
        end
        local definition = registry.get(request.objectKey)
        if not definition then return V.failure('INTERACT_NOT_FOUND', 'Interaction object does not exist.') end
        if request.revision ~= definition.revision then
            return V.failure('INTERACT_STALE_TARGET', 'Interaction definition changed.', true)
        end
        local action = actionFor(definition, request.actionKey)
        if not action then return V.failure('INTERACT_NOT_FOUND', 'Interaction action does not exist.') end
        local session, sessionError = sessionForSource(source)
        if not session then return nil, sessionError end
        local distance, distanceError = verifyDistance(source, definition, action, traceId)
        if not distance then return nil, distanceError end
        local contextVerified, contextError = verifyWorldContext(source, request.worldContext, traceId)
        if not contextVerified then return nil, contextError end
        local allowed, accessError = hasCapability(session, action.capability, traceId)
        if not allowed then return nil, accessError end
        local lease, leaseError = leases.acquire({
            source = source,
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            objectKey = definition.key,
            actionKey = action.key,
            ownerResource = definition.ownerResource,
            slot = action.slot,
            ttlSeconds = action.leaseSeconds,
            contextFingerprint = tostring(definition.revision) .. ':' .. session.id,
        })
        if not lease then return nil, leaseError end
        return {
            lease = lease,
            objectKey = definition.key,
            actionKey = action.key,
            ownerResource = definition.ownerResource,
            distance = distance.distance,
        }
    end

    function api.execute(source, request, traceId)
        if type(request) ~= 'table' or type(request.leaseId) ~= 'string' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction execute request is invalid.')
        end
        local session, sessionError = sessionForSource(source)
        if not session then return nil, sessionError end
        local lease, leaseError = leases.verify(request.leaseId, {
            source = source,
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            objectKey = request.objectKey,
            actionKey = request.actionKey,
        })
        if not lease then return nil, leaseError end
        local definition = registry.get(lease.objectKey)
        if not definition then
            leases.release(lease.id, 'TARGET_GONE')
            return V.failure('INTERACT_NOT_FOUND', 'Interaction target disappeared.')
        end
        local action = actionFor(definition, lease.actionKey)
        if not action then
            leases.release(lease.id, 'ACTION_GONE')
            return V.failure('INTERACT_NOT_FOUND', 'Interaction action disappeared.')
        end
        if lease.slotKey ~= definition.key .. '\0' .. action.slot then
            leases.release(lease.id, 'SLOT_CHANGED')
            return V.failure('INTERACT_LEASE_STALE', 'Interaction slot changed after lease acquisition.')
        end
        local distance, distanceError = verifyDistance(source, definition, action, traceId)
        if not distance then leases.release(lease.id, 'RANGE_FAILED'); return nil, distanceError end
        local allowed, accessError = hasCapability(session, action.capability, traceId)
        if not allowed then leases.release(lease.id, 'ACCESS_FAILED'); return nil, accessError end
        local result, executionError
        if action.graph then
            result, executionError = graphs.execute(action.graph, {
                source = source,
                session = session,
                lease = lease,
                object = V.copy(definition),
                action = V.copy(action),
                payload = V.copy(request.payload or {}),
                traceId = traceId,
            })
        else
            local published, publishError = core.publish('synex.interact.action.requested', {
                ownerResource = definition.ownerResource,
                objectKey = definition.key,
                actionKey = action.key,
                source = source,
                sessionId = session.id,
                sourceGeneration = session.sourceGeneration,
                leaseId = lease.id,
                payload = V.copy(request.payload or {}),
            }, { traceId = traceId })
            if not published then
                executionError = { code = 'INTERACT_ACTION_FAILED', message = 'Interaction action dispatch failed.', retryable = true,
                    details = type(publishError) == 'table' and { eventCode = publishError.code } or nil }
            else
                result = { state = 'DISPATCHED' }
            end
        end
        leases.release(lease.id, result and 'COMPLETED' or 'FAILED')
        if not result then
            if type(executionError) == 'table' and type(executionError.code) == 'string'
                and executionError.code:match('^INTERACT_') then
                return nil, executionError
            end
            return V.failure('INTERACT_ACTION_FAILED', 'Interaction action failed.', true,
                type(executionError) == 'table' and { domainCode = executionError.code } or nil)
        end
        return result
    end

    function api.health()
        return {
            state = 'READY',
            registryRevision = registry.revision(),
            definitions = #registry.list(),
            leases = leases.stats(),
        }
    end

    return api
end
