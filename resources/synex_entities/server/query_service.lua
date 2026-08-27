SynexEntityQueryService = {}
local STATUS = {
    active = 'ACTIVE', defined = 'DEFINED', deleted = 'DELETED',
    deleting = 'DELETING', dormant = 'DORMANT', failed = 'FAILED',
    orphaned = 'ORPHANED', recovering = 'RECOVERING', spawning = 'SPAWNING',
}
function SynexEntityQueryService.create(options)
    assert(type(options) == 'table', 'entity query service options are required')
    local authorityRepository = assert(options.authorityRepository,
        'entity query authority repository is required')
    local extensionRepository = assert(options.extensionRepository,
        'entity query extension repository is required')
    local foundation = assert(options.foundation, 'entity query foundation is required')
    local validation = assert(options.validation, 'entity query validation is required')
    local registry = assert(options.registry, 'entity query registry is required')
    local entityRuntime = assert(options.entityRuntime, 'entity query runtime is required')
    local bucketPolicy = assert(options.bucketPolicy, 'entity query bucket policy is required')
    local state = assert(options.state, 'entity query state is required')
    local ports = assert(options.ports, 'entity query ports are required')
    local config = assert(options.config, 'entity query config is required')
    local diagnosticAnalyzer = options.diagnosticAnalyzer
        or SynexEntityDiagnosticsAnalyzer.create({
            config = config,
            entityRuntime = entityRuntime,
            extensionRegistry = assert(options.extensionRegistry,
                'entity query extension registry is required'),
            foundation = foundation,
            ports = ports,
            registry = registry,
            state = state,
        })
    local service = {}
    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end
    local function begin(context, cost)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(caller, cost or 1, context, true)
        if not allowed then return nil, rateError end
        return caller
    end
    local function entityRef(record)
        return { entityId = record.entityId, generation = record.generation }
    end

    local function runtimeView(record)
        local inspection = entityRuntime.inspect(record)
        if not inspection then return nil end
        return {
            archetype = record.archetype and record.archetype.namespace or nil,
            binding = record.binding and {
                namespace = record.binding.namespace,
                ref = record.binding.ref,
            } or nil,
            bucket = record.bucket,
            entityId = record.entityId,
            entityType = record.entityType,
            generation = record.generation,
            materialized = true,
            model = record.model,
            netId = record.netId,
            networkOwner = inspection.networkOwner,
            owner = record.owner,
            persistent = record.persistent == true,
            resourceOwner = record.resourceOwner,
            status = STATUS[record.status] or 'ACTIVE',
        }
    end

    local function definitionView(definition, binding)
        local runtime = registry.byEntityId(definition.entityId, definition.generation)
        if runtime then
            local materialized = runtimeView(runtime)
            if materialized then return materialized end
        end
        return {
            archetype = definition.archetype and definition.archetype.namespace or nil,
            binding = binding and { namespace = binding.namespace, ref = binding.ref } or nil,
            bucket = definition.bucket or 0,
            entityId = definition.entityId,
            entityType = definition.entityType,
            generation = definition.generation,
            materialized = false,
            model = definition.model,
            owner = definition.owner,
            persistent = definition.persistent == true,
            resourceOwner = definition.resourceOwner,
            status = STATUS[definition.status] or string.upper(definition.status or 'defined'),
        }
    end

    local function hasType(filters, entityType)
        if not filters or not filters.entityTypes then return true end
        for _, value in ipairs(filters.entityTypes) do
            if value == entityType then return true end
        end
        return false
    end

    local function matchesBasic(record, filters)
        if not filters then return true end
        if filters.persistent ~= nil and record.persistent ~= filters.persistent then return false end
        if filters.materialized ~= nil and filters.materialized ~= true then return false end
        if not hasType(filters, record.entityType) then return false end
        local archetype = record.archetype and record.archetype.namespace or nil
        if filters.archetype and archetype ~= filters.archetype then return false end
        if filters.tags then
            local present = {}
            for _, tag in ipairs(record.tags or {}) do present[tag] = true end
            for _, tag in ipairs(filters.tags) do
                if not present[tag] then return false end
            end
        end
        return true
    end

    local function validatePageRequest(request, selector, context)
        if type(request) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'The entity query must be an object', false, context)
        end
        local allowed = { cursor = true, filters = true, limit = true }
        allowed[selector] = true
        for key in pairs(request) do
            if type(key) ~= 'string' or not allowed[key] then
                return failure('INVALID_ARGUMENT', 'The entity query contains an unknown field', false, context)
            end
        end
        if type(request.limit) ~= 'number' or request.limit % 1 ~= 0
            or request.limit < 1 or request.limit > 64 then
            return failure('INVALID_ARGUMENT', 'The entity query limit is invalid', false, context)
        end
        if request.cursor ~= nil and (type(request.cursor) ~= 'string'
            or #request.cursor < 1 or #request.cursor > 64
            or request.cursor:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil) then
            return failure('INVALID_ARGUMENT', 'The entity query cursor is invalid', false, context)
        end
        local filters = request.filters
        if filters == nil then return true end
        if type(filters) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'The entity query filters are invalid', false, context)
        end
        local filterFields = {
            archetype = true, entityTypes = true, materialized = true,
            persistent = true, tags = true,
        }
        for key in pairs(filters) do
            if type(key) ~= 'string' or not filterFields[key] then
                return failure('INVALID_ARGUMENT', 'The entity query filters contain an unknown field', false, context)
            end
        end
        if filters.persistent ~= nil and type(filters.persistent) ~= 'boolean' then
            return failure('INVALID_ARGUMENT', 'The durability filter is invalid', false, context)
        end
        if filters.materialized ~= nil and type(filters.materialized) ~= 'boolean' then
            return failure('INVALID_ARGUMENT', 'The materialization filter is invalid', false, context)
        end
        if filters.archetype ~= nil and (type(filters.archetype) ~= 'string'
            or #filters.archetype < 3 or #filters.archetype > 128
            or filters.archetype:match('^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$') == nil) then
            return failure('INVALID_ARGUMENT', 'The archetype filter is invalid', false, context)
        end
        local allowedTypes = { object = true, ped = true, vehicle = true }
        for name, values in pairs({ entityTypes = filters.entityTypes, tags = filters.tags }) do
            if values ~= nil then
                if type(values) ~= 'table' then
                    return failure('INVALID_ARGUMENT', 'An entity array filter is invalid', false, context)
                end
                local maximum = name == 'entityTypes' and 3 or 16
                local seen, count = {}, 0
                for index, value in ipairs(values) do
                    local valid = name == 'entityTypes' and allowedTypes[value]
                        or (type(value) == 'string' and #value >= 3 and #value <= 64
                            and value:match('^[a-z][a-z0-9_.-]+$') ~= nil)
                    if index > maximum or not valid or seen[value] then
                        return failure('INVALID_ARGUMENT', 'An entity array filter is invalid', false, context)
                    end
                    seen[value], count = true, index
                end
                for key in pairs(values) do
                    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > count then
                        return failure('INVALID_ARGUMENT', 'An entity array filter is invalid', false, context)
                    end
                end
            end
        end
        return true
    end

    local function matchesTags(entityId, required, context)
        if not required or #required == 0 then return true end
        local rows, rowsError = extensionRepository.listTags(entityId, context)
        if not rows then return nil, rowsError end
        local present = {}
        for _, row in ipairs(rows) do present[row.tag] = true end
        for _, tag in ipairs(required) do
            if not present[tag] then return false end
        end
        return true
    end

    local function durablePage(request, selector, context)
        local filters = request.filters or {}
        local budget = math.min(128, math.max(32, request.limit * 2))
        local cursor = request.cursor
        local items, scanned = {}, 0
        while scanned < budget do
            local batch = math.min(100, budget - scanned)
            local query = {
                afterEntityId = cursor,
                archetypeNamespace = filters.archetype,
                entityTypes = filters.entityTypes and #filters.entityTypes > 0
                    and filters.entityTypes or nil,
                limit = batch,
                materialized = filters.materialized,
                persistent = filters.persistent,
            }
            for key, value in pairs(selector) do query[key] = value end
            local page, pageError = authorityRepository.queryDefinitions(query, context)
            if not page then return nil, pageError end
            local lastScanned
            for _, definition in ipairs(page.items) do
                scanned = scanned + 1
                lastScanned = definition.entityId
                local matched, tagError = matchesTags(
                    definition.entityId, filters.tags, context)
                if matched == nil then return nil, tagError end
                if matched then
                    if #items >= request.limit then
                        return {
                            items = items,
                            nextCursor = items[#items].entityId,
                            truncated = true,
                        }
                    end
                    local binding, bindingError = authorityRepository.bindingFor(
                        definition.entityId, context)
                    if bindingError then return nil, bindingError end
                    local view = definitionView(definition, binding)
                    if view then items[#items + 1] = view end
                end
            end
            if page.nextAfterEntityId == nil then
                return { items = items, truncated = false }
            end
            cursor = lastScanned or page.nextAfterEntityId
        end
        return {
            items = items,
            nextCursor = cursor,
            truncated = true,
        }
    end

    local function pageRecords(records, request)
        table.sort(records, function(left, right) return left.entityId < right.entityId end)
        local items, started = {}, request.cursor == nil
        local more = false
        for _, record in ipairs(records) do
            if not started and record.entityId > request.cursor then started = true end
            if started and matchesBasic(record, request.filters) then
                if #items >= request.limit then more = true break end
                local view = runtimeView(record)
                if view then items[#items + 1] = view end
            end
        end
        return {
            items = items,
            nextCursor = more and items[#items] and items[#items].entityId or nil,
            truncated = more,
        }
    end

    function service.byNetId(request, context)
        local allowed, beginError = begin(context, 1)
        if not allowed then return nil, beginError end
        local record, resolveError = registry.byNetId(request.netId)
        if not record then
            return failure('ENTITY_NOT_FOUND', 'The network ID is not managed', false, context)
        end
        local view = runtimeView(record)
        if not view then
            return failure('STALE_ENTITY', 'The network ID mapping is stale', false, context)
        end
        return { entity = view }
    end

    function service.byOwner(request, context)
        local allowed, beginError = begin(context, 2)
        if not allowed then return nil, beginError end
        local valid, requestError = validatePageRequest(request, 'owner', context)
        if not valid then return nil, requestError end
        local owner, ownerError = validation.validateOwner(request.owner)
        if not owner then return nil, ownerError end
        return durablePage(request, { ownerType = owner.type, ownerId = owner.id }, context)
    end

    function service.byResource(request, context)
        local allowed, beginError = begin(context, 2)
        if not allowed then return nil, beginError end
        local valid, requestError = validatePageRequest(request, 'resource', context)
        if not valid then return nil, requestError end
        local resource, resourceError = validation.validateCaller(request.resource)
        if not resource then return nil, resourceError end
        return durablePage(request, { resourceOwner = resource }, context)
    end

    function service.byBucket(request, context)
        local allowed, beginError = begin(context, 2)
        if not allowed then return nil, beginError end
        local valid, requestError = validatePageRequest(request, 'bucket', context)
        if not valid then return nil, requestError end
        if type(request.bucket) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'The bucket reference is invalid', false, context)
        end
        local reference, referenceError = validation.validateBucketReference(
            request.bucket.bucket, request.bucket.generation, true)
        if not reference then return nil, referenceError end
        if reference.id > 0 then
            local managed = state.buckets[reference.id]
            if not managed then
                return failure('BUCKET_NOT_FOUND',
                    'The managed bucket does not exist', false, context)
            end
            if managed.generation ~= reference.generation then
                return failure('STALE_BUCKET',
                    'The managed bucket reference is stale', false, context)
            end
        end
        return durablePage(request, { bucket = reference.id }, context)
    end

    function service.byBinding(request, context)
        local allowed, beginError = begin(context, 1)
        if not allowed then return nil, beginError end
        local binding, bindingError = validation.validateBinding(request.binding, true)
        if not binding then return nil, bindingError end
        local definition, definitionError = authorityRepository.getByBinding(
            binding.namespace,
            binding.ref,
            context
        )
        if not definition then return nil, definitionError end
        return { binding = binding, entity = definitionView(definition, binding) }
    end

    function service.nearby(request, context)
        local allowed, beginError = begin(context, 3)
        if not allowed then return nil, beginError end
        local position, positionError = validation.validatePosition(request.position)
        if not position then return nil, positionError end
        local bucket = request.bucket and request.bucket.bucket or 0
        if request.bucket then
            local reference, referenceError = validation.validateBucketReference(
                request.bucket.bucket,
                request.bucket.generation,
                true
            )
            if not reference then return nil, referenceError end
            if reference.id > 0 then
                local managed = state.buckets[reference.id]
                if not managed then
                    return failure('BUCKET_NOT_FOUND',
                        'The managed bucket does not exist', false, context)
                end
                if managed.generation ~= reference.generation then
                    return failure('STALE_BUCKET', 'The managed bucket reference is stale', false, context)
                end
            end
            bucket = reference.id
        end
        local nearby, nearbyError = registry.nearby(
            position,
            request.radius,
            bucket,
            math.min(request.limit * 4, 256)
        )
        if not nearby then return nil, nearbyError end
        local items = {}
        for _, candidate in ipairs(nearby) do
            local record = candidate.record or registry.byEntityId(candidate.entityId)
            if record and matchesBasic(record, request.filters) then
                local view = runtimeView(record)
                if view then
                    items[#items + 1] = {
                        distance = math.sqrt(candidate.distanceSquared),
                        entity = view,
                    }
                    if #items >= request.limit then break end
                end
            end
        end
        return { items = items, truncated = #nearby > #items and #items >= request.limit }
    end

    function service.bucketGet(request, context)
        local allowed, beginError = begin(context, 1)
        if not allowed then return nil, beginError end
        if type(request) ~= 'table' or type(request.bucket) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'The bucket reference is invalid', false, context)
        end
        local reference, referenceError = validation.validateBucketReference(
            request.bucket.bucket, request.bucket.generation, true)
        if not reference then return nil, referenceError end
        local bucketId = reference.id
        if bucketId == 0 then
            return {
                bucket = { bucket = 0, generation = 0 },
                capacity = {
                    maxEntities = math.min(config.maxEntities, 10000),
                    maxPlayers = math.min(config.maxBucketPlayers, 2048),
                },
                createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                entities = #registry.forBucket(0),
                health = 'READY',
                lockdown = 'inactive',
                ownerResource = 'synex_core',
                players = 0,
                populationEnabled = true,
                profile = 'custom',
                purpose = 'default_world',
            }
        end
        local bucket = state.buckets[bucketId]
        if not bucket then
            return failure('BUCKET_NOT_FOUND', 'The managed bucket does not exist', false, context)
        end
        if bucket.generation ~= reference.generation then
            return failure('STALE_BUCKET',
                'The managed bucket reference is stale', false, context)
        end
        return bucketPolicy.snapshot(bucket)
    end

    local function distance(left, right)
        local x, y, z = left.x - right.x, left.y - right.y, left.z - right.z
        return math.sqrt(x * x + y * y + z * z)
    end

    function service.contextValidate(request, context)
        local allowed, beginError = begin(context, 3)
        if not allowed then return nil, beginError end
        if not ports.getPlayerName(tostring(request.source)) then
            return failure('INTERACTION_CONTEXT_INVALID', 'The player source is not active', false, context)
        end
        local entityReference, refError = validation.validateEntityRef(request.entity)
        if not entityReference then return nil, refError end
        local record, resolveError = registry.resolveRef(entityReference)
        if not record then return nil, resolveError end
        local inspection, inspectionError = entityRuntime.inspect(record)
        if not inspection then
            return failure('ENTITY_NOT_MATERIALIZED',
                'The interaction target is not materialized', false, context)
        end
        local playerBucket = ports.getPlayerRoutingBucket(request.source)
        if request.requirements.sameBucket and playerBucket ~= inspection.bucket then
            return failure('BUCKET_MISMATCH',
                'The player and entity are not in the same routing bucket', false, context)
        end
        local ped = ports.getPlayerPed(request.source)
        if type(ped) ~= 'number' or ped <= 0 or not ports.doesEntityExist(ped) then
            return failure('INTERACTION_CONTEXT_INVALID', 'The player ped is unavailable', true, context)
        end
        local playerPosition = ports.getEntityCoords(ped)
        local entityPosition = ports.getEntityCoords(record.handle)
        local observedPlayer, playerError = validation.validatePosition({
            x = tonumber(playerPosition.x or playerPosition[1]),
            y = tonumber(playerPosition.y or playerPosition[2]),
            z = tonumber(playerPosition.z or playerPosition[3]),
        })
        if not observedPlayer then return nil, playerError end
        local observedEntity, entityError = validation.validatePosition({
            x = tonumber(entityPosition.x or entityPosition[1]),
            y = tonumber(entityPosition.y or entityPosition[2]),
            z = tonumber(entityPosition.z or entityPosition[3]),
        })
        if not observedEntity then return nil, entityError end
        local measured = distance(observedPlayer, observedEntity)
        if measured > request.requirements.maxDistance then
            return failure('DISTANCE_INVALID',
                'The player is outside the allowed interaction distance', false, context)
        end
        if request.requirements.owner then
            local requiredOwner, ownerError = validation.validateOwner(request.requirements.owner)
            if not requiredOwner then return nil, ownerError end
            if not record.owner or record.owner.type ~= requiredOwner.type
                or record.owner.id ~= requiredOwner.id then
                return failure('INTERACTION_CONTEXT_INVALID',
                    'The entity logical owner does not match', false, context)
            end
        end
        local tagRows, tagError = extensionRepository.listTags(record.entityId, context)
        if not tagRows then return nil, tagError end
        local availableTags = {}
        for _, row in ipairs(tagRows) do availableTags[row.tag] = true end
        local matchedTags = {}
        for _, tag in ipairs(request.requirements.tags or {}) do
            if not availableTags[tag] then
                return failure('INTERACTION_CONTEXT_INVALID',
                    'A required entity tag is missing', false, context)
            end
            matchedTags[#matchedTags + 1] = tag
        end
        local matchedComponents = {}
        for _, namespace in ipairs(request.requirements.components or {}) do
            local component = extensionRepository.getComponent(
                record.entityId,
                namespace,
                context
            )
            if not component then
                return failure('INTERACTION_CONTEXT_INVALID',
                    'A required entity component is missing', false, context)
            end
            matchedComponents[#matchedComponents + 1] = namespace
        end
        return {
            bucket = {
                bucket = inspection.bucket,
                generation = inspection.bucket == 0 and 0
                    or (state.buckets[inspection.bucket]
                        and state.buckets[inspection.bucket].generation or 0),
            },
            distance = measured,
            entity = entityReference,
            matchedComponents = matchedComponents,
            matchedTags = matchedTags,
            valid = true,
        }
    end

    function service.inspectEntity(request, context)
        local entityId = type(request) == 'table' and request.entityId or request
        local recoveryLimit = type(request) == 'table' and request.recoveryLimit or 10
        if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64
            or entityId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or type(recoveryLimit) ~= 'number' or recoveryLimit % 1 ~= 0
            or recoveryLimit < 1 or recoveryLimit > 25 then
            return failure('INVALID_ARGUMENT', 'The entity inspection request is invalid', false, context)
        end
        if type(request) == 'table' then
            for key in pairs(request) do
                if key ~= 'entityId' and key ~= 'recoveryLimit' then
                    return failure('INVALID_ARGUMENT', 'The entity inspection request contains an unknown field', false, context)
                end
            end
            local allowed, beginError = begin(context, 2)
            if not allowed then return nil, beginError end
        end
        local persisted, persistedError = authorityRepository.inspectEntity(entityId, context)
        if not persisted then return nil, persistedError end
        local authority, authorityError = authorityRepository.inspectAuthority(entityId, context)
        if authorityError then return nil, authorityError end
        local recovery, recoveryError = authorityRepository.inspectRecovery(
            entityId, recoveryLimit, context)
        if not recovery then return nil, recoveryError end
        local tags, tagsError = extensionRepository.listTags(entityId, context)
        if not tags then return nil, tagsError end
        local runtime = registry.byEntityId(entityId, persisted.definition.generation)
        local authorityView = authority and {
            entityId = authority.entity_id,
            heartbeatAt = authority.heartbeat_at,
            instanceId = authority.instance_id,
            leaseGeneration = tonumber(authority.lease_generation),
            leaseLive = tonumber(authority.lease_live) == 1,
            leaseState = authority.lease_state,
            leaseUntil = authority.lease_until,
            resourceEpoch = tonumber(authority.resource_epoch),
            serverScope = authority.server_scope,
            version = tonumber(authority.version),
        } or nil
        return {
            authority = authorityView,
            binding = persisted.binding,
            checkpoint = persisted.checkpoint,
            counts = persisted.counts,
            definition = definitionView(persisted.definition, persisted.binding),
            persistence = persisted.definition,
            recovery = recovery,
            runtime = runtime and runtimeView(runtime) or nil,
            tags = tags,
        }
    end

    function service.diagnosticSnapshot(request, authority, context)
        request = type(request) == 'table' and request or {}
        for key in pairs(request) do
            if key ~= 'cursor' and key ~= 'limit' and key ~= 'recoveryAttemptThreshold' then
                return failure('INVALID_ARGUMENT', 'The entity diagnostic request contains an unknown field', false, context)
            end
        end
        local limit = request.limit or 25
        local threshold = request.recoveryAttemptThreshold
            or math.max(2, math.min(config.recoveryMaxAttempts or 5, 1000))
        if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 50
            or type(threshold) ~= 'number' or threshold % 1 ~= 0
            or threshold < 1 or threshold > 1000 then
            return failure('INVALID_ARGUMENT', 'The entity diagnostic bounds are invalid', false, context)
        end
        local allowed, beginError = begin(context, 3)
        if not allowed then return nil, beginError end
        local snapshot, snapshotError = authorityRepository.diagnosticSnapshot({
            afterEntityId = request.cursor,
            limit = limit,
            recoveryAttemptThreshold = threshold,
            runtimeEntityIds = diagnosticAnalyzer.runtimeEntityIds(limit),
        }, authority, context)
        if not snapshot then return nil, snapshotError end
        return diagnosticAnalyzer.analyze(snapshot, limit, context)
    end

    return service
end
