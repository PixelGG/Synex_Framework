SynexInteractEntityProjection = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded first')

local ENTITY_TYPES = { object = true, ped = true, vehicle = true }

function SynexInteractEntityProjection.create(options)
    options = options or {}
    local registry = assert(options.registry, 'entity projection requires registry')
    local getSession = assert(options.getSession, 'entity projection requires sessions')
    local actorSnapshot = assert(options.actorSnapshot,
        'entity projection requires actor snapshots')
    local getBucketFence = assert(options.getBucketFence,
        'entity projection requires bucket fences')
    local queryNearby = assert(options.queryNearby,
        'entity projection requires the Entities nearby query')
    local inspectEntity = assert(options.inspectEntity,
        'entity projection requires entity inspection')
    local projectionRevision = 0
    local selectorRevision = 0
    local selectors = { references = {}, archetypes = {}, models = {},
        archetypeModels = {}, count = 0 }
    local projection = {}

    local function currentSession(context, expected)
        if not Validation.isPlainTable(context)
            or not Validation.isInteger(context.source, 1, 65535)
            or not Validation.isInteger(context.sourceGeneration, 1)
            or not Validation.isPlainTable(context.session) then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction discovery session is unavailable.')
        end
        local session, sessionError = getSession(context.source)
        local fence = expected or context.session
        if not session or session.state ~= 'ACTIVE' or session.id ~= fence.id
            or session.source ~= context.source
            or session.sourceGeneration ~= context.sourceGeneration
            or session.sourceGeneration ~= fence.sourceGeneration
            or session.characterId ~= fence.characterId then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction discovery session changed.', false,
                sessionError and { cause = sessionError.code } or nil)
        end
        return session, nil
    end

    local function refreshSelectors(revision)
        if selectorRevision == revision then return selectors end
        local nextSelectors = { references = {}, archetypes = {}, models = {},
            archetypeModels = {}, count = 0 }
        local definitions = registry.slotDefinitions()
        if type(definitions) ~= 'table'
            or #definitions > Limits.maximumSmartObjects then
            return Validation.failure('INTERACT_PAYLOAD_TOO_LARGE',
                'The managed entity selector set exceeds its bound.')
        end
        for _, definition in ipairs(definitions) do
            local object = type(definition) == 'table' and definition.object or nil
            local binding = type(object) == 'table' and object.binding or nil
            if type(binding) == 'table' then
                if binding.type == 'entityRef' then
                    nextSelectors.references[binding.entityId .. '\0'
                        .. tostring(binding.generation)] = true
                    nextSelectors.count = nextSelectors.count + 1
                elseif binding.type == 'entityArchetype' or binding.type == 'entityBone' then
                    if binding.archetype ~= nil and binding.model ~= nil then
                        nextSelectors.archetypeModels[binding.archetype .. '\0'
                            .. tostring(binding.model)] = true
                    elseif binding.archetype ~= nil then
                        nextSelectors.archetypes[binding.archetype] = true
                    elseif binding.model ~= nil then
                        nextSelectors.models[binding.model] = true
                    end
                    nextSelectors.count = nextSelectors.count + 1
                end
            end
        end
        selectors, selectorRevision = nextSelectors, revision
        return selectors
    end

    local function selected(entity, currentSelectors)
        return currentSelectors.references[entity.entityId .. '\0'
                .. tostring(entity.generation)] == true
            or entity.archetype ~= nil
                and currentSelectors.archetypes[entity.archetype] == true
            or currentSelectors.models[entity.model] == true
            or entity.archetype ~= nil and currentSelectors.archetypeModels[
                entity.archetype .. '\0' .. tostring(entity.model)] == true
    end

    local function validManagedEntity(entity, bucket)
        return type(entity) == 'table' and entity.materialized == true
            and entity.bucket == bucket and ENTITY_TYPES[entity.entityType]
            and Validation.token(entity.entityId, 8, 64)
            and Validation.isInteger(entity.generation, 1)
            and Validation.isInteger(entity.netId, 1, 65535)
            and Validation.isInteger(entity.model, 0, 4294967295)
            and (entity.archetype == nil
                or Validation.semanticKey(entity.archetype, 128))
    end

    local function inspectManagedEntity(entity, bucket)
        local inspected = inspectEntity(entity.netId)
        if type(inspected) ~= 'table' or inspected.bucket ~= bucket
            or inspected.model ~= entity.model
            or inspected.entityType ~= entity.entityType
            or not Validation.vector3(inspected.position)
            or not Validation.isFinite(inspected.heading) then return nil end
        return inspected
    end

    local function actorFence(context)
        local session, sessionError = currentSession(context)
        if not session then return nil, sessionError end
        local expected = { id = session.id, sourceGeneration = session.sourceGeneration,
            characterId = session.characterId }
        local actor, actorError = actorSnapshot(context.source)
        if not actor then return nil, actorError end
        local fence, fenceError = getBucketFence({
            source = context.source, sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
        }, context)
        if not fence then
            return Validation.failure(
                type(fenceError) == 'table' and fenceError.code == 'RATE_LIMITED'
                    and 'INTERACT_RATE_LIMITED' or 'INTERACT_TARGET_STALE',
                'The player routing-bucket fence could not be resolved.',
                type(fenceError) ~= 'table' or fenceError.retryable ~= false)
        end
        session, sessionError = currentSession(context, expected)
        if not session then return nil, sessionError end
        if not Validation.exactObject(fence,
            { 'source', 'sessionId', 'sourceGeneration', 'bucket' })
            or fence.source ~= context.source or fence.sessionId ~= session.id
            or fence.sourceGeneration ~= session.sourceGeneration
            or not Validation.exactObject(fence.bucket, { 'bucket', 'generation' })
            or not Validation.isInteger(fence.bucket.bucket, 0, 2147483647)
            or fence.bucket.bucket ~= actor.bucket
            or fence.bucket.bucket == 0 and fence.bucket.generation ~= 0
            or fence.bucket.bucket > 0 and not Validation.token(
                fence.bucket.generation, 8, 64) then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The player routing-bucket fence is stale.', true)
        end
        return { session = session, expected = expected,
            actor = actor, fence = fence }, nil
    end

    function projection.resolveManaged(reference, maximumDistance, context)
        if not Validation.exactObject(reference, { 'entityId', 'generation' })
            or not Validation.token(reference.entityId, 8, 64)
            or not Validation.isInteger(reference.generation, 1)
            or not Validation.isFinite(maximumDistance) or maximumDistance < 0.25
            or maximumDistance > Limits.maximumAuthorityDistance then
            return Validation.failure('INTERACT_TARGET_INVALID',
                'The managed entity selector request is invalid.')
        end
        local fenced, fenceError = actorFence(context)
        if not fenced then return nil, fenceError end
        local nearby, queryError = queryNearby({
            position = fenced.actor.position, radius = maximumDistance,
            limit = Limits.maximumEntityProjection,
            bucket = Validation.copy(fenced.fence.bucket),
            filters = { materialized = true },
        }, context)
        if not nearby then
            return Validation.failure(
                type(queryError) == 'table' and queryError.code == 'RATE_LIMITED'
                    and 'INTERACT_RATE_LIMITED' or 'INTERACT_UNAVAILABLE',
                'The managed entity selector could not be queried.',
                type(queryError) ~= 'table' or queryError.retryable ~= false)
        end
        local session, sessionError = currentSession(context, fenced.expected)
        if not session then return nil, sessionError end
        local currentActor, actorError = actorSnapshot(context.source)
        if not currentActor then return nil, actorError end
        if currentActor.bucket ~= fenced.fence.bucket.bucket
            or not Validation.isPlainTable(nearby)
            or type(nearby.truncated) ~= 'boolean'
            or not Validation.array(nearby.items, Limits.maximumEntityProjection) then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The managed entity selector projection is stale.', true)
        end
        for _, candidate in ipairs(nearby.items) do
            local entity = type(candidate) == 'table' and candidate.entity or nil
            if validManagedEntity(entity, fenced.fence.bucket.bucket)
                and entity.entityId == reference.entityId
                and entity.generation == reference.generation then
                local inspected = inspectManagedEntity(entity, fenced.fence.bucket.bucket)
                if not inspected then
                    return Validation.failure('INTERACT_TARGET_STALE',
                        'The managed entity runtime identity changed.', true)
                end
                local position = Validation.vector3(inspected.position)
                local distance = Validation.distance(currentActor.position, position)
                if distance > maximumDistance then
                    return Validation.failure('INTERACT_LEASE_DENIED',
                        'The managed entity is outside the allowed range.')
                end
                session, sessionError = currentSession(context, fenced.expected)
                if not session then return nil, sessionError end
                local finalActor, finalActorError = actorSnapshot(context.source)
                if not finalActor then return nil, finalActorError end
                if finalActor.bucket ~= fenced.fence.bucket.bucket then
                    return Validation.failure('INTERACT_TARGET_STALE',
                        'The player routing bucket changed during validation.', true)
                end
                local finalDistance = Validation.distance(finalActor.position, position)
                if finalDistance > maximumDistance then
                    return Validation.failure('INTERACT_LEASE_DENIED',
                        'The managed entity is outside the allowed range.')
                end
                return { entity = Validation.copy(entity), position = position,
                    distance = finalDistance,
                    bucket = fenced.fence.bucket.bucket }, nil
            end
        end
        return Validation.failure('INTERACT_TARGET_STALE',
            'The managed entity is absent from the fenced nearby projection.', true)
    end

    function projection.snapshot(request, context)
        if not Validation.exactObject(request, { 'discoveryRevision' })
            or not Validation.isInteger(request.discoveryRevision, 1) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The managed entity discovery request is invalid.')
        end
        local revision = registry.currentRevision()
        if request.discoveryRevision ~= revision then
            return Validation.failure('INTERACT_DISCOVERY_STALE',
                'The interaction discovery revision is stale.', true)
        end
        local session, sessionError = currentSession(context)
        if not session then return nil, sessionError end
        local expected = { id = session.id, sourceGeneration = session.sourceGeneration,
            characterId = session.characterId }
        local currentSelectors, selectorError = refreshSelectors(revision)
        if not currentSelectors then return nil, selectorError end
        local actor, actorError = actorSnapshot(context.source)
        if not actor then return nil, actorError end
        local fence, fenceError = getBucketFence({
            source = context.source, sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
        }, context)
        if not fence then
            return Validation.failure(
                type(fenceError) == 'table' and fenceError.code == 'RATE_LIMITED'
                    and 'INTERACT_RATE_LIMITED' or 'INTERACT_TARGET_STALE',
                'The player routing-bucket fence could not be resolved.',
                type(fenceError) ~= 'table' or fenceError.retryable ~= false)
        end
        session, sessionError = currentSession(context, expected)
        if not session then return nil, sessionError end
        if not Validation.exactObject(fence,
            { 'source', 'sessionId', 'sourceGeneration', 'bucket' })
            or fence.source ~= context.source or fence.sessionId ~= session.id
            or fence.sourceGeneration ~= session.sourceGeneration
            or not Validation.exactObject(fence.bucket, { 'bucket', 'generation' })
            or not Validation.isInteger(fence.bucket.bucket, 0, 2147483647)
            or fence.bucket.bucket ~= actor.bucket
            or fence.bucket.bucket == 0 and fence.bucket.generation ~= 0
            or fence.bucket.bucket > 0 and not Validation.token(
                fence.bucket.generation, 8, 64) then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The player routing-bucket fence is stale.', true)
        end

        if currentSelectors.count == 0 then
            projectionRevision = projectionRevision + 1
            return { schemaVersion = 1, discoveryRevision = revision,
                projectionRevision = projectionRevision,
                sourceGeneration = session.sourceGeneration,
                bucket = fence.bucket.bucket,
                truncated = false, entities = {} }, nil
        end

        local nearby, queryError = queryNearby({
            position = actor.position,
            radius = Limits.maximumDiscoveryRadius,
            limit = Limits.maximumEntityProjection,
            bucket = Validation.copy(fence.bucket),
            filters = { materialized = true },
        }, context)
        if not nearby then
            return Validation.failure(
                type(queryError) == 'table' and queryError.code == 'RATE_LIMITED'
                    and 'INTERACT_RATE_LIMITED' or 'INTERACT_UNAVAILABLE',
                'The managed entity projection could not be queried.',
                type(queryError) ~= 'table' or queryError.retryable ~= false)
        end
        session, sessionError = currentSession(context, expected)
        if not session then return nil, sessionError end
        local currentActor, currentActorError = actorSnapshot(context.source)
        if not currentActor then return nil, currentActorError end
        if currentActor.bucket ~= fence.bucket.bucket then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The player routing bucket changed during discovery.', true)
        end
        if not Validation.isPlainTable(nearby)
            or type(nearby.truncated) ~= 'boolean'
            or not Validation.array(nearby.items, Limits.maximumEntityProjection) then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'The Entities nearby projection is invalid.', true)
        end

        local entities, seen = {}, {}
        for _, candidate in ipairs(nearby.items) do
            local entity = type(candidate) == 'table' and candidate.entity or nil
            if validManagedEntity(entity, fence.bucket.bucket)
                and selected(entity, currentSelectors) then
                local identity = entity.entityId .. '\0' .. tostring(entity.generation)
                if not seen[identity] then
                    local inspected = inspectManagedEntity(entity, fence.bucket.bucket)
                    if inspected then
                        seen[identity] = true
                        entities[#entities + 1] = {
                            entityRef = { entityId = entity.entityId,
                                generation = entity.generation },
                            netId = entity.netId, entityType = entity.entityType,
                            model = entity.model, archetype = entity.archetype,
                            bucket = entity.bucket,
                            position = Validation.copy(inspected.position),
                            heading = inspected.heading + 0.0,
                        }
                    end
                end
            end
        end
        table.sort(entities, function(left, right)
            local leftDistance = Validation.distance(currentActor.position, left.position)
            local rightDistance = Validation.distance(currentActor.position, right.position)
            return leftDistance < rightDistance or leftDistance == rightDistance
                and left.entityRef.entityId < right.entityRef.entityId
        end)
        while #entities > Limits.maximumEntityProjection do entities[#entities] = nil end
        session, sessionError = currentSession(context, expected)
        if not session then return nil, sessionError end
        projectionRevision = projectionRevision + 1
        return { schemaVersion = 1, discoveryRevision = revision,
            projectionRevision = projectionRevision,
            sourceGeneration = session.sourceGeneration,
            bucket = fence.bucket.bucket,
            truncated = nearby.truncated == true,
            entities = entities }, nil
    end

    return projection
end
