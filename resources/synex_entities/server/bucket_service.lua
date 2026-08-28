SynexEntityBucketOperations = {}

local BucketIdempotency = assert(SynexEntityBucketIdempotency,
    'bucket idempotency must be loaded first')

function SynexEntityBucketOperations.create(options)
    assert(type(options) == 'table', 'bucket operation options are required')
    local validation = assert(options.validation, 'bucket operations validation is required')
    local foundation = assert(options.foundation, 'bucket operations foundation is required')
    local authorityRepository = assert(options.authorityRepository,
        'bucket operations authority repository is required')
    local registry = assert(options.registry, 'bucket operations registry is required')
    local entityRuntime = assert(options.entityRuntime, 'bucket operations runtime is required')
    local lanes = assert(options.lanes, 'bucket operation lanes are required')
    local observability = assert(options.observability,
        'bucket operation observability is required')
    local policy = assert(options.policy, 'bucket operation policy is required')
    local getAuthority = assert(options.getAuthority,
        'bucket operation authority getter is required')
    local state = assert(options.state, 'bucket operations state is required')
    local coreRef = assert(options.coreRef, 'bucket operations coreRef is required')
    local ports = assert(options.ports, 'bucket operations ports are required')
    local config = assert(options.config, 'bucket operations config is required')
    local buckets = state.buckets
    local playerMemberships = state.playerMemberships
    local pendingEntityMoves = {}
    local pendingPlayerMoves = {}
    local nextBucketId = config.bucketMin
    local operations = {}

    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end

    local function idempotent(operation, request, context, caller, required, handler)
        local key = type(context) == 'table' and context.idempotencyKey or nil
        if key == nil then
            if required then
                return failure('INVALID_ARGUMENT',
                    'An idempotency key is required for this operation', false, context)
            end
            return handler()
        end
        if type(key) ~= 'string' or #key < 8 or #key > 36
            or key:match('^[A-Za-z0-9_.:%-]+$') == nil then
            return failure('INVALID_ARGUMENT', 'The idempotency key is invalid', false, context)
        end
        local scopedOperation = BucketIdempotency.operation(operation, caller)
        if not scopedOperation then
            return failure('INVALID_ARGUMENT',
                'The idempotency caller identity is invalid', false, context)
        end
        local api = coreRef.value
        if not api or type(api.Idempotency) ~= 'table'
            or not foundation.isCallable(api.Idempotency.run) then
            return failure('CORE_UNAVAILABLE',
                'The Core idempotency service is unavailable', true, context)
        end
        return api.Idempotency.run(scopedOperation, key, {
            caller = caller,
            request = request,
            version = type(context) == 'table' and context.version or nil,
        }, handler, {
            lockSeconds = 30,
            maximumRequestBytes = 16384,
            maximumResponseBytes = 16384,
            ttlSeconds = 86400,
        })
    end

    local function contractError(operationError, context)
        if type(operationError) ~= 'table'
            or type(context) ~= 'table' or context.version ~= '1.0.0' then
            return operationError
        end
        local aliases = {
            AUTHORITY_LEASE_CONFLICT = 'CONFLICT',
            BUCKET_CAPACITY_EXCEEDED = 'RATE_LIMITED',
            CONCURRENT_MODIFICATION = 'CONFLICT',
            CORE_UNAVAILABLE = 'UNAVAILABLE',
            ENTITY_NOT_MATERIALIZED = 'STALE_ENTITY',
            FOREIGN_RESOURCE_OWNER = 'FORBIDDEN',
            HOOK_REJECTED = 'FORBIDDEN',
            OPERATION_TIMEOUT = 'UNAVAILABLE',
        }
        if aliases[operationError.code] then
            operationError.code = aliases[operationError.code]
        end
        return operationError
    end

    local function plainObject(value, allowed, context)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then
            return failure('INVALID_ARGUMENT', 'request must be a plain object', false, context)
        end
        for key in pairs(value) do
            if not allowed[key] then
                return failure('INVALID_ARGUMENT', 'request contains an unknown field', false, context)
            end
        end
        return true
    end

    local function currentPlayerSession(source, context)
        local api = coreRef.value
        if not api or type(api.Players) ~= 'table'
            or not foundation.isCallable(api.Players.getBySource) then
            return failure('UNAVAILABLE',
                'The Core player session registry is unavailable', true, context)
        end
        local invoked, session, sessionError = foundation.protect(
            'core.players.get_by_source',
            function() return api.Players.getBySource(source) end,
            context
        )
        if not invoked then
            return nil, type(sessionError) == 'table' and sessionError or {
                code = 'UNAVAILABLE',
                message = 'The Core player session lookup failed',
                retryable = true,
            }
        end
        if session == nil and type(sessionError) == 'table' then
            return nil, sessionError
        end
        if type(session) ~= 'table' or type(session.id) ~= 'string'
            or #session.id < 8 or #session.id > 64
            or type(session.sourceGeneration) ~= 'number'
            or session.sourceGeneration % 1 ~= 0 or session.sourceGeneration < 1
            or session.sourceGeneration > 9007199254740991
            or tonumber(session.source) ~= source then
            return failure('NOT_FOUND',
                'The player has no current Core session', false, context)
        end
        return { id = session.id, sourceGeneration = session.sourceGeneration }
    end

    local function sameSession(membership, session)
        return membership and session
            and membership.sessionId == session.id
            and membership.sourceGeneration == session.sourceGeneration
    end

    local function allocateId(context)
        local attempts = 0
        local maximumAttempts = math.min(config.bucketMax - config.bucketMin + 1, 100000)
        local bucketId = nextBucketId
        while buckets[bucketId] and attempts < maximumAttempts do
            bucketId = bucketId >= config.bucketMax and config.bucketMin or bucketId + 1
            attempts = attempts + 1
        end
        if buckets[bucketId] then
            return failure('UNAVAILABLE', 'The managed bucket range is exhausted', true, context)
        end
        nextBucketId = bucketId >= config.bucketMax and config.bucketMin or bucketId + 1
        return bucketId
    end

    local function nextGeneration(context)
        local api = coreRef.value
        if not api or type(api.Ids) ~= 'table' or not foundation.isCallable(api.Ids.next) then
            return failure('UNAVAILABLE', 'The Core ID service is unavailable', true, context)
        end
        local invoked, value, operationError = foundation.protect(
            'core.ids.bucket', function() return api.Ids.next('bucket') end, context)
        if not invoked or value == nil then
            return nil, type(operationError) == 'table' and operationError or {
                code = 'UNAVAILABLE',
                message = 'The Core bucket generation service failed',
                retryable = true,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        local generation, generationError = validation.validateBucketGeneration(value)
        if not generation then
            generationError.traceId = type(context) == 'table' and context.traceId or nil
            return nil, generationError
        end
        return generation
    end

    local function applyPolicy(bucketId, normalized, context)
        local applied = foundation.protect('bucket.apply_policy', function()
            ports.setRoutingBucketEntityLockdownMode(bucketId, normalized.lockdown)
            ports.setRoutingBucketPopulationEnabled(bucketId, normalized.populationEnabled)
        end, context)
        if applied then return true end
        foundation.protect('bucket.rollback_policy', function()
            ports.setRoutingBucketPopulationEnabled(bucketId, true)
            ports.setRoutingBucketEntityLockdownMode(bucketId, 'inactive')
        end, context)
        return failure('UNAVAILABLE', 'The routing bucket policy could not be applied', true, context)
    end

    function operations.create(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local normalized, normalizeError = policy.normalizeCreate(request, context)
        if not normalized then return nil, normalizeError end
        local requireIdempotency = type(context) == 'table'
            and context.version == '2.0.0'
        return idempotent('bucket.create', request, context, caller,
            requireIdempotency, function()
            local allowed, rateError = foundation.takeRateLimit(caller, 3, context, false)
            if not allowed then return nil, rateError end
            return foundation.withOwnerMutation(caller, context, function()
            if foundation.tableCount(buckets) >= config.maxBuckets then
                return failure('UNAVAILABLE',
                    'The managed routing bucket limit has been reached', true, context)
            end
            local ownerCount = 0
            for _, bucket in pairs(buckets) do
                if bucket.resourceOwner == caller then ownerCount = ownerCount + 1 end
            end
            if ownerCount >= config.maxOwnerBuckets then
                return failure('RATE_LIMITED',
                    'The resource routing bucket limit has been reached', true, context)
            end
            local bucketId, idError = allocateId(context)
            if not bucketId then return nil, idError end
            local generation, generationError = nextGeneration(context)
            if not generation then return nil, generationError end
            local applied, applyError = applyPolicy(bucketId, normalized, context)
            if not applied then return nil, applyError end
            local bucket = {
                createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                destroying = false,
                entities = {},
                expiresAt = normalized.expiresAt,
                generation = generation,
                health = 'READY',
                id = bucketId,
                lockdown = normalized.lockdown,
                maxEntities = normalized.capacity.maxEntities,
                maxPlayers = normalized.capacity.maxPlayers,
                players = {},
                pendingSpawns = 0,
                populationEnabled = normalized.populationEnabled,
                profile = normalized.profile,
                purpose = normalized.purpose,
                resourceCycle = foundation.currentOwnerCycle(caller),
                resourceOwner = caller,
            }
            buckets[bucketId] = bucket
            observability.audit('entities.bucket_created', 'routing_bucket',
                tostring(bucketId), policy.snapshot(bucket), context)
            observability.increment('bucket_created_total', { profile = bucket.profile }, 1)
            if type(context) == 'table' and context.version == '1.0.0' then
                return {
                    bucket = bucketId,
                    generation = generation,
                    lockdown = 'strict',
                    populationEnabled = false,
                }
            end
            return policy.snapshot(bucket)
            end)
        end)
    end

    local function sourceReference(record, context)
        if record.bucket == 0 then return { bucket = 0, generation = 0 } end
        local source = buckets[record.bucket]
        if not source or source.generation == nil then
            return failure('STALE_BUCKET',
                'The entity source bucket is no longer managed', false, context)
        end
        return { bucket = source.id, generation = source.generation }
    end

    local function rollbackRuntime(record, previousBucket, context)
        pendingEntityMoves[record.handle] = {
            expiresAt = ports.getGameTimer() + 5000,
            generation = record.generation,
            target = previousBucket,
        }
        foundation.protect('entity.rollback_bucket_move', function()
            ports.setEntityRoutingBucket(record.handle, previousBucket)
        end, context)
        local actualBucket = entityRuntime.observeBucket(record.handle)
        if actualBucket ~= nil then entityRuntime.assignBucket(record, actualBucket) end
        local expected = pendingEntityMoves[record.handle]
        if expected and expected.seen and actualBucket == previousBucket then
            pendingEntityMoves[record.handle] = nil
        end
        if actualBucket ~= previousBucket then
            foundation.setHealth('DEGRADED', 'Persistent entity bucket rollback failed')
            return failure('UNAVAILABLE', 'The runtime bucket rollback failed', true, context)
        end
        return true
    end

    function operations.moveRecord(record, target, context, reasonCode)
        if target.destroying then
            return failure('STALE_BUCKET', 'The target bucket is being destroyed', true, context)
        end
        if record.bucket == target.id then
            local inspection, inspectionError = entityRuntime.inspect(record)
            if not inspection then return nil, inspectionError end
            return entityRuntime.snapshot(record, inspection)
        end
        if target.id > 0
            and foundation.tableCount(target.entities) >= target.maxEntities then
            return failure(type(context) == 'table' and context.version == '1.0.0'
                    and 'RATE_LIMITED' or 'BUCKET_CAPACITY_EXCEEDED',
                'The routing bucket entity capacity has been reached', true, context)
        end
        local previousRef, previousError = sourceReference(record, context)
        if not previousRef then return nil, previousError end
        local targetRef = { bucket = target.id, generation = target.generation }
        local hookValue, hookError = observability.before(
            'synex.entities.before_entity_bucket_move', {
                bucket = targetRef,
                entity = { entityId = record.entityId, generation = record.generation },
                previousBucket = previousRef,
                reasonCode = reasonCode or 'synex.entities.bucket_moved',
            }, context)
        if not hookValue then return nil, contractError(hookError, context) end

        local previousBucket = record.bucket
        pendingEntityMoves[record.handle] = {
            expiresAt = ports.getGameTimer() + 5000,
            generation = record.generation,
            target = target.id,
        }
        local moved = foundation.protect('entity.move_bucket', function()
            ports.setEntityRoutingBucket(record.handle, target.id)
        end, context)
        if not moved or entityRuntime.observeBucket(record.handle) ~= target.id then
            pendingEntityMoves[record.handle] = nil
            return failure('UNAVAILABLE',
                'The entity could not be moved to the routing bucket', true, context)
        end
        local assigned, assignmentError = entityRuntime.assignBucket(record, target.id)
        if not assigned then
            rollbackRuntime(record, previousBucket, context)
            return nil, assignmentError
        end
        local expected = pendingEntityMoves[record.handle]
        if expected and expected.seen then pendingEntityMoves[record.handle] = nil end

        if record.persistent then
            local authority = getAuthority()
            if not authority then
                rollbackRuntime(record, previousBucket, context)
                return failure('CORE_UNAVAILABLE',
                    'Entity runtime authority is not initialized', true, context)
            end
            local persisted, persistenceError = authorityRepository.moveBucket(
                record.entityId,
                record.generation,
                record.version,
                record.authorityLeaseGeneration,
                record.resourceOwner,
                target.id,
                authority,
                reasonCode or 'synex.entities.bucket_moved',
                context
            )
            if not persisted then
                rollbackRuntime(record, previousBucket, context)
                return nil, contractError(persistenceError, context)
            end
            record.version = persisted.version
        end

        local inspection, inspectionError = entityRuntime.inspect(record)
        if not inspection then return nil, inspectionError end
        local payload = {
            bucket = targetRef,
            entity = { entityId = record.entityId, generation = record.generation },
            previousBucket = previousRef,
            reasonCode = reasonCode or 'synex.entities.bucket_moved',
        }
        observability.event('synex.entities.bucket.changed', payload, context)
        observability.audit('entities.bucket_changed', 'entity', record.entityId, payload, context)
        observability.increment('bucket_entity_moves_total', {
            persistent = record.persistent and 'true' or 'false',
        }, 1)
        return entityRuntime.snapshot(record, inspection)
    end

    local function pendingMove(map, key)
        local pending = map[key]
        if pending and pending.expiresAt < ports.getGameTimer() then
            map[key], pending = nil, nil
        end
        return pending
    end

    function operations.observeEntityBucketChange(handle, bucketId, context)
        if type(handle) ~= 'number' or type(bucketId) ~= 'number'
            or bucketId % 1 ~= 0 or bucketId < 0 or bucketId > 2147483647 then
            return false
        end
        local record = registry.byHandle(handle)
        if not record then return false end
        local pending = pendingMove(pendingEntityMoves, handle)
        if pending and pending.generation == record.generation
            and pending.target == bucketId then
            pending.seen = true
            if record.bucket == bucketId then pendingEntityMoves[handle] = nil end
            return true
        end
        if bucketId == record.bucket then
            pendingEntityMoves[handle] = nil
            return true
        end

        local desiredBucket = record.bucket
        observability.audit('entities.bucket_move_rejected', 'entity', record.entityId, {
            observedBucket = bucketId,
            requiredBucket = desiredBucket,
        }, context)
        observability.increment('bucket_out_of_band_entity_moves_total', {}, 1)
        pendingEntityMoves[handle] = {
            expiresAt = ports.getGameTimer() + 5000,
            generation = record.generation,
            target = desiredBucket,
        }
        local reverted = foundation.protect('entity.revert_out_of_band_bucket', function()
            ports.setEntityRoutingBucket(handle, desiredBucket)
        end, context)
        if not reverted or entityRuntime.observeBucket(handle) ~= desiredBucket then
            foundation.setHealth('DEGRADED', 'OUT_OF_BAND_ENTITY_BUCKET_MOVE')
            return false
        end
        local expected = pendingEntityMoves[handle]
        if expected and expected.seen then pendingEntityMoves[handle] = nil end
        return true
    end

    function operations.moveEntity(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(caller, 2, context, false)
        if not allowed then return nil, rateError end
        local valid, requestError = plainObject(request, {
            bucket = true, bucketGeneration = true,
            entityId = true, generation = true,
        }, context)
        if not valid then return nil, requestError end
        return foundation.withOwnerMutation(caller, context, function()
            local moved, moveError = lanes.with(
                lanes.entityKey(request.entityId), 'bucket_move', context, function()
                local record, resolveError = entityRuntime.resolveOwned({
                    entityId = request.entityId,
                    generation = request.generation,
                }, caller, context)
                if not record then return nil, resolveError end
                local target, bucketError = entityRuntime.resolveBucket(
                    request.bucket, request.bucketGeneration, caller, true)
                if not target then
                    bucketError.traceId = type(context) == 'table' and context.traceId or nil
                    return nil, bucketError
                end
                return operations.moveRecord(
                    record, target, context, 'synex.entities.bucket_moved')
            end)
            if not moved then return nil, contractError(moveError, context) end
            return moved
        end)
    end

    function operations.movePlayerRecord(source, target, context, caller, cleanup)
        if target.destroying then
            return failure('STALE_BUCKET', 'The target bucket is being destroyed', true, context)
        end
        local membership = playerMemberships[source]
        local session, sessionError = currentPlayerSession(source, context)
        if not session then return nil, sessionError end
        local currentBucket = ports.getPlayerRoutingBucket(source)
        if membership and not sameSession(membership, session) then
            if buckets[membership.bucket] then
                buckets[membership.bucket].players[source] = nil
            end
            playerMemberships[source], membership = nil, nil
        end
        if membership and membership.resourceOwner ~= caller then
            return failure('FOREIGN_BUCKET',
                'The player bucket assignment belongs to another resource', false, context)
        end
        if not cleanup and membership
            and membership.resourceCycle ~= foundation.currentOwnerCycle(caller) then
            return failure('STALE_RESOURCE',
                'The player bucket assignment belongs to an earlier lifecycle', true, context)
        end
        if membership and membership.bucket ~= currentBucket then
            if buckets[membership.bucket] then
                buckets[membership.bucket].players[source] = nil
            end
            playerMemberships[source], membership = nil, nil
        end
        if currentBucket ~= 0 and not membership and not cleanup then
            return failure('FOREIGN_BUCKET',
                'The player is in an unmanaged routing bucket', false, context)
        end
        if target.id > 0 and currentBucket ~= target.id
            and foundation.tableCount(target.players) >= target.maxPlayers then
            return failure(type(context) == 'table' and context.version == '1.0.0'
                    and 'RATE_LIMITED' or 'BUCKET_CAPACITY_EXCEEDED',
                'The routing bucket player capacity has been reached', true, context)
        end
        if currentBucket ~= target.id then
            local currentSession, currentSessionError = currentPlayerSession(source, context)
            if not currentSession then return nil, currentSessionError end
            if currentSession.id ~= session.id
                or currentSession.sourceGeneration ~= session.sourceGeneration then
                return failure('STALE_RESOURCE',
                    'The player source was reused during the bucket move', true, context)
            end
            pendingPlayerMoves[source] = {
                expiresAt = ports.getGameTimer() + 5000,
                sessionId = session.id,
                sourceGeneration = session.sourceGeneration,
                target = target.id,
            }
            local moved = foundation.protect('player.move_bucket', function()
                ports.setPlayerRoutingBucket(source, target.id)
            end, context)
            if not moved or ports.getPlayerRoutingBucket(source) ~= target.id then
                pendingPlayerMoves[source] = nil
                return failure('UNAVAILABLE',
                    'The player could not be moved to the routing bucket', true, context)
            end
        end
        if membership and buckets[membership.bucket] then
            buckets[membership.bucket].players[source] = nil
        end
        if target.id == 0 then
            playerMemberships[source] = nil
        else
            target.players[source] = true
            playerMemberships[source] = {
                bucket = target.id,
                generation = target.generation,
                resourceCycle = foundation.currentOwnerCycle(caller),
                resourceOwner = caller,
                sessionId = session.id,
                sourceGeneration = session.sourceGeneration,
            }
        end
        local expected = pendingPlayerMoves[source]
        if expected and expected.seen then pendingPlayerMoves[source] = nil end
        observability.audit('entities.bucket_player_changed', 'player', tostring(source), {
            bucket = target.id,
            previousBucket = currentBucket,
        }, context)
        observability.increment('bucket_player_moves_total', {}, 1)
        return { bucket = target.id, source = source }
    end

    function operations.observePlayerBucketChange(source, bucketId, context)
        if type(source) ~= 'number' or type(bucketId) ~= 'number'
            or bucketId % 1 ~= 0 or bucketId < 0 or bucketId > 2147483647 then
            return false
        end
        local membership = playerMemberships[source]
        if not ports.getPlayerName(tostring(source)) then
            if membership and buckets[membership.bucket] then
                buckets[membership.bucket].players[source] = nil
            end
            playerMemberships[source], pendingPlayerMoves[source] = nil, nil
            return false
        end
        local session, sessionError = currentPlayerSession(source, context)
        if not session then
            foundation.setHealth('DEGRADED', type(sessionError) == 'table'
                and sessionError.code or 'PLAYER_SESSION_UNAVAILABLE')
            return false
        end
        if membership and not sameSession(membership, session) then
            if buckets[membership.bucket] then
                buckets[membership.bucket].players[source] = nil
            end
            playerMemberships[source], membership = nil, nil
        end
        local desiredBucket = membership and membership.bucket or 0
        local pending = pendingMove(pendingPlayerMoves, source)
        if pending and pending.target == bucketId
            and pending.sessionId == session.id
            and pending.sourceGeneration == session.sourceGeneration then
            pending.seen = true
            if desiredBucket == bucketId then pendingPlayerMoves[source] = nil end
            return true
        end
        if desiredBucket == bucketId then
            pendingPlayerMoves[source] = nil
            return true
        end
        observability.audit('entities.bucket_player_move_rejected', 'player',
            tostring(source), { observedBucket = bucketId, requiredBucket = desiredBucket }, context)
        observability.increment('bucket_out_of_band_player_moves_total', {}, 1)
        pendingPlayerMoves[source] = {
            expiresAt = ports.getGameTimer() + 5000,
            sessionId = session.id,
            sourceGeneration = session.sourceGeneration,
            target = desiredBucket,
        }
        local reverted = foundation.protect('player.revert_out_of_band_bucket', function()
            ports.setPlayerRoutingBucket(source, desiredBucket)
        end, context)
        if not reverted or ports.getPlayerRoutingBucket(source) ~= desiredBucket then
            foundation.setHealth('DEGRADED', 'OUT_OF_BAND_PLAYER_BUCKET_MOVE')
            return false
        end
        local expected = pendingPlayerMoves[source]
        if expected and expected.seen then pendingPlayerMoves[source] = nil end
        return true
    end

    function operations.playerDropped(source, context)
        local membership = playerMemberships[source]
        if not membership then
            pendingPlayerMoves[source] = nil
            return false
        end
        local active = ports.getPlayerName(tostring(source)) ~= nil
        local session = currentPlayerSession(source, context)
        if active then
            if not session or sameSession(membership, session) then return false end
        end
        if buckets[membership.bucket] then
            buckets[membership.bucket].players[source] = nil
        end
        playerMemberships[source], pendingPlayerMoves[source] = nil, nil
        return true
    end

    function operations.movePlayer(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local valid, requestError = plainObject(request, {
            bucket = true, bucketGeneration = true, source = true,
        }, context)
        if not valid then return nil, requestError end
        if type(request.source) ~= 'number' or request.source % 1 ~= 0
            or request.source < 1 or request.source > 65535 then
            return failure('INVALID_ARGUMENT', 'The player source is invalid', false, context)
        end
        return idempotent('bucket.move-player', request, context, caller, false, function()
            local allowed, rateError = foundation.takeRateLimit(caller, 1, context, false)
            if not allowed then return nil, rateError end
            if not ports.getPlayerName(tostring(request.source)) then
                return failure('NOT_FOUND', 'The player source is not connected', false, context)
            end
            return foundation.withOwnerMutation(caller, context, function()
            local moved, moveError = lanes.with('player:' .. tostring(request.source),
                'bucket_move_player', context, function()
                local target, bucketError = entityRuntime.resolveBucket(
                    request.bucket, request.bucketGeneration, caller, true)
                if not target then return nil, bucketError end
                return operations.movePlayerRecord(
                    request.source, target, context, caller, false)
            end)
            if not moved then return nil, contractError(moveError, context) end
            return moved
            end)
        end)
    end

    local shared = {
        buckets = buckets,
        config = config,
        entityRuntime = entityRuntime,
        failure = failure,
        foundation = foundation,
        lanes = lanes,
        observability = observability,
        playerMemberships = playerMemberships,
        policy = policy,
        ports = ports,
        registry = registry,
        contractError = contractError,
        validation = validation,
        idempotent = idempotent,
    }
    assert(type(SynexEntityBucketLifecycle) == 'table'
        and type(SynexEntityBucketLifecycle.attach) == 'function',
        'entity bucket lifecycle is required')
    SynexEntityBucketLifecycle.attach(operations, shared)
    return operations
end
