SynexEntityBucketOperations = {}

function SynexEntityBucketOperations.create(options)
    assert(type(options) == 'table', 'bucket operation options are required')
    local validation = assert(options.validation, 'bucket operations validation is required')
    local foundation = assert(options.foundation, 'bucket operations foundation is required')
    local repository = assert(options.repository, 'bucket operations repository is required')
    local registry = assert(options.registry, 'bucket operations registry is required')
    local entityRuntime = assert(options.entityRuntime, 'bucket operations runtime is required')
    local state = assert(options.state, 'bucket operations state is required')
    local coreRef = assert(options.coreRef, 'bucket operations coreRef is required')
    local ports = assert(options.ports, 'bucket operations ports are required')
    local config = assert(options.config, 'bucket operations config is required')
    local buckets = state.buckets
    local playerMemberships = state.playerMemberships
    local nextBucketId = config.bucketMin
    local operations = {}

    function operations.create(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 3, context, false)
        if not allowed then
            return nil, rateError
        end
        return foundation.withOwnerMutation(caller, context, function()
            if type(request) ~= 'table' then
                return foundation.failure('INVALID_ARGUMENT', 'request must be an object', false, context)
            end
            for key in pairs(request) do
                if key ~= 'purpose' then
                    return foundation.failure(
                        'INVALID_ARGUMENT',
                        'request contains an unknown field',
                        false,
                        context
                    )
                end
            end
            if request.purpose ~= nil
                and (type(request.purpose) ~= 'string' or #request.purpose < 1
                    or #request.purpose > 64 or request.purpose:find('[%c]')) then
                return foundation.failure('INVALID_ARGUMENT', 'purpose is invalid', false, context)
            end
            if foundation.tableCount(buckets) >= config.maxBuckets then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The managed routing bucket limit has been reached',
                    true,
                    context
                )
            end
            local ownerBucketCount = 0
            for _, bucket in pairs(buckets) do
                if bucket.resourceOwner == caller then
                    ownerBucketCount = ownerBucketCount + 1
                end
            end
            if ownerBucketCount >= config.maxOwnerBuckets then
                return foundation.failure(
                    'RATE_LIMITED',
                    'The resource routing bucket limit has been reached',
                    true,
                    context
                )
            end

            local bucketId = nextBucketId
            local attempts = 0
            local maximumAttempts = math.min(config.bucketMax - config.bucketMin + 1, 100000)
            while buckets[bucketId] and attempts < maximumAttempts do
                bucketId = bucketId >= config.bucketMax and config.bucketMin or bucketId + 1
                attempts = attempts + 1
            end
            if buckets[bucketId] then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The managed bucket range is exhausted',
                    true,
                    context
                )
            end
            nextBucketId = bucketId >= config.bucketMax and config.bucketMin or bucketId + 1
            local api = coreRef.value
            if not api or type(api.Ids) ~= 'table' or not foundation.isCallable(api.Ids.next) then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The Core ID service is unavailable',
                    true,
                    context
                )
            end
            local generationOk, generationOrError, generationServiceError = foundation.protect(
                'core.ids.bucket',
                function() return api.Ids.next('bucket') end,
                context
            )
            if not generationOk or not generationOrError then
                if type(generationServiceError) == 'table' then
                    generationServiceError.traceId = context.traceId
                    return nil, generationServiceError
                end
                return foundation.failure(
                    'UNAVAILABLE',
                    'The Core bucket generation service failed',
                    true,
                    context
                )
            end
            local generation, generationError = validation.validateBucketGeneration(generationOrError)
            if not generation then
                generationError.traceId = context.traceId
                return nil, generationError
            end
            local configured = foundation.protect('bucket.apply_policy', function()
                ports.setRoutingBucketEntityLockdownMode(bucketId, 'strict')
                ports.setRoutingBucketPopulationEnabled(bucketId, false)
            end, context)
            if not configured then
                foundation.protect('bucket.rollback_policy', function()
                    ports.setRoutingBucketPopulationEnabled(bucketId, true)
                    ports.setRoutingBucketEntityLockdownMode(bucketId, 'inactive')
                end, context)
                return foundation.failure(
                    'UNAVAILABLE',
                    'The routing bucket policy could not be applied',
                    true,
                    context
                )
            end

            buckets[bucketId] = {
                entities = {},
                generation = generation,
                id = bucketId,
                players = {},
                purpose = request.purpose,
                resourceCycle = foundation.currentOwnerCycle(caller),
                resourceOwner = caller,
            }
            return {
                bucket = bucketId,
                generation = generation,
                lockdown = 'strict',
                populationEnabled = false,
            }
        end)
    end

    function operations.destroyRecord(bucket, persistChanges, cleanupDeadline)
        local records = registry.all()
        local cleanupError

        for _, record in ipairs(records) do
            if record.bucket == bucket.id and record.persistent then
                local inspection, inspectionError = entityRuntime.inspect(record)
                if not inspection then
                    if persistChanges then
                        return nil, inspectionError
                    end
                    registry.remove(record.entityId, record.generation)
                    bucket.entities[record.entityId] = nil
                    goto continue_persistent_cleanup
                end
                local previousVersion = record.version
                local moved = foundation.protect('bucket.move_persistent_to_default', function()
                    ports.setEntityRoutingBucket(record.handle, 0)
                end)
                if not moved or entityRuntime.observeBucket(record.handle) ~= 0 then
                    local _, moveError = foundation.failure(
                        'UNAVAILABLE',
                        'A persistent entity could not leave the routing bucket',
                        true
                    )
                    if persistChanges then
                        return nil, moveError
                    end
                    cleanupError = cleanupError or moveError
                    goto continue_persistent_cleanup
                end
                if persistChanges then
                    local updated, persistenceError = repository.updateBucket(
                        record.entityId,
                        previousVersion,
                        0
                    )
                    if updated ~= 1 then
                        foundation.protect('bucket.rollback_persistent_move', function()
                            ports.setEntityRoutingBucket(record.handle, bucket.id)
                        end)
                        local actualBucket = entityRuntime.observeBucket(record.handle)
                        if actualBucket ~= nil then
                            entityRuntime.assignBucket(record, actualBucket)
                        end
                        if actualBucket ~= bucket.id then
                            foundation.setHealth(
                                'DEGRADED',
                                'A persistent bucket move could not be rolled back'
                            )
                            return foundation.failure(
                                'UNAVAILABLE',
                                'The runtime bucket rollback failed',
                                true
                            )
                        end
                        if persistenceError then
                            return nil, persistenceError
                        end
                        return foundation.failure(
                            'CONFLICT',
                            'A persistent entity changed concurrently',
                            true
                        )
                    end
                    record.version = previousVersion + 1
                end
                entityRuntime.assignBucket(record, 0)
            end
            ::continue_persistent_cleanup::
        end

        for playerSource in pairs(bucket.players) do
            if ports.getPlayerName(tostring(playerSource)) then
                local currentBucket = ports.getPlayerRoutingBucket(playerSource)
                if currentBucket == bucket.id then
                    foundation.protect('bucket.return_player_to_default', function()
                        ports.setPlayerRoutingBucket(playerSource, 0)
                    end)
                end
            end
            playerMemberships[playerSource] = nil
        end

        for _, record in ipairs(records) do
            if record.bucket == bucket.id and not record.persistent then
                if cleanupDeadline and ports.getGameTimer() >= cleanupDeadline then
                    return foundation.failure(
                        'UNAVAILABLE',
                        'Routing bucket cleanup exceeded its deadline',
                        true
                    )
                end
                local inspection = entityRuntime.inspect(record)
                if inspection then
                    if persistChanges then
                        local deleted, deleteError = entityRuntime.delete(record, cleanupDeadline)
                        if not deleted then
                            foundation.setHealth('DEGRADED', deleteError.message)
                            cleanupError = cleanupError or deleteError
                        end
                    else
                        foundation.protect('bucket.delete_temporary', function()
                            ports.deleteEntity(record.handle)
                        end)
                        registry.remove(record.entityId, record.generation)
                    end
                else
                    registry.remove(record.entityId, record.generation)
                end
            end
        end

        if cleanupError then
            return nil, cleanupError
        end
        local reset = foundation.protect('bucket.reset_policy', function()
            ports.setRoutingBucketPopulationEnabled(bucket.id, true)
            ports.setRoutingBucketEntityLockdownMode(bucket.id, 'inactive')
        end)
        if not reset then
            foundation.setHealth('DEGRADED', 'A routing bucket policy could not be reset')
            return foundation.failure(
                'UNAVAILABLE',
                'The routing bucket policy could not be reset',
                true
            )
        end
        buckets[bucket.id] = nil
        return true
    end

    function operations.destroy(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 3, context, false)
        if not allowed then
            return nil, rateError
        end
        return foundation.withOwnerMutation(caller, context, function()
            if type(request) ~= 'table' then
                return foundation.failure('INVALID_ARGUMENT', 'request must be an object', false, context)
            end
            for key in pairs(request) do
                if key ~= 'bucket' and key ~= 'generation' then
                    return foundation.failure(
                        'INVALID_ARGUMENT',
                        'request contains an unknown field',
                        false,
                        context
                    )
                end
            end

            local bucket, bucketError = entityRuntime.resolveBucket(
                request.bucket,
                request.generation,
                caller,
                false
            )
            if not bucket then
                bucketError.traceId = context.traceId
                return nil, bucketError
            end
            local destroyed, destroyError = operations.destroyRecord(
                bucket,
                true,
                ports.getGameTimer() + config.bucketCleanupTimeoutMs
            )
            if not destroyed then
                destroyError.traceId = context.traceId
                return nil, destroyError
            end
            return { bucket = request.bucket, destroyed = true }
        end)
    end

    function operations.moveEntity(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 2, context, false)
        if not allowed then
            return nil, rateError
        end
        return foundation.withOwnerMutation(caller, context, function()
            if type(request) ~= 'table' then
                return foundation.failure('INVALID_ARGUMENT', 'request must be an object', false, context)
            end
            for key in pairs(request) do
                if key ~= 'bucket' and key ~= 'bucketGeneration'
                    and key ~= 'entityId' and key ~= 'generation' then
                    return foundation.failure(
                        'INVALID_ARGUMENT',
                        'request contains an unknown field',
                        false,
                        context
                    )
                end
            end

            local record, inspectionOrError = entityRuntime.resolveOwned({
                entityId = request.entityId,
                generation = request.generation,
            }, caller, context)
            if not record then
                return nil, inspectionOrError
            end
            local target, bucketError = entityRuntime.resolveBucket(
                request.bucket,
                request.bucketGeneration,
                caller,
                true
            )
            if not target then
                bucketError.traceId = context.traceId
                return nil, bucketError
            end
            if target.id > 0 and record.bucket ~= target.id
                and foundation.tableCount(target.entities) >= config.maxBucketEntities then
                return foundation.failure(
                    'RATE_LIMITED',
                    'The routing bucket entity limit has been reached',
                    true,
                    context
                )
            end

            local previousBucket = record.bucket
            local moved = foundation.protect('entity.move_bucket', function()
                ports.setEntityRoutingBucket(record.handle, target.id)
            end, context)
            if not moved or entityRuntime.observeBucket(record.handle) ~= target.id then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The entity could not be moved to the routing bucket',
                    true,
                    context
                )
            end
            entityRuntime.assignBucket(record, target.id)

            if record.persistent then
                local previousVersion = record.version
                local updated, persistenceError = repository.updateBucket(
                    record.entityId,
                    previousVersion,
                    target.id,
                    context
                )
                if updated ~= 1 then
                    foundation.protect('entity.rollback_bucket_move', function()
                        ports.setEntityRoutingBucket(record.handle, previousBucket)
                    end, context)
                    local actualBucket = entityRuntime.observeBucket(record.handle)
                    if actualBucket ~= nil then
                        entityRuntime.assignBucket(record, actualBucket)
                    end
                    if actualBucket ~= previousBucket then
                        foundation.setHealth(
                            'DEGRADED',
                            'A persistent entity move could not be rolled back'
                        )
                        return foundation.failure(
                            'UNAVAILABLE',
                            'The runtime bucket rollback failed',
                            true,
                            context
                        )
                    end
                    if persistenceError then
                        return nil, persistenceError
                    end
                    return foundation.failure(
                        'CONFLICT',
                        'The persistent entity changed concurrently',
                        true,
                        context
                    )
                end
                record.version = previousVersion + 1
            end

            local inspection, inspectionError = entityRuntime.inspect(record)
            if not inspection then
                inspectionError.traceId = context.traceId
                return nil, inspectionError
            end
            return entityRuntime.snapshot(record, inspection)
        end)
    end

    function operations.movePlayer(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 1, context, false)
        if not allowed then
            return nil, rateError
        end
        return foundation.withOwnerMutation(caller, context, function()
            if type(request) ~= 'table' then
                return foundation.failure('INVALID_ARGUMENT', 'request must be an object', false, context)
            end
            for key in pairs(request) do
                if key ~= 'bucket' and key ~= 'bucketGeneration' and key ~= 'source' then
                    return foundation.failure(
                        'INVALID_ARGUMENT',
                        'request contains an unknown field',
                        false,
                        context
                    )
                end
            end
            if type(request.source) ~= 'number' or request.source % 1 ~= 0
                or request.source < 1 or request.source > 65535
                or not ports.getPlayerName(tostring(request.source)) then
                return foundation.failure(
                    'NOT_FOUND',
                    'The player source is not connected',
                    false,
                    context
                )
            end

            local target, bucketError = entityRuntime.resolveBucket(
                request.bucket,
                request.bucketGeneration,
                caller,
                true
            )
            if not target then
                bucketError.traceId = context.traceId
                return nil, bucketError
            end
            local currentMembership = playerMemberships[request.source]
            local currentBucket = ports.getPlayerRoutingBucket(request.source)
            if currentMembership and currentMembership.resourceOwner ~= caller then
                return foundation.failure(
                    'FORBIDDEN',
                    'The player bucket assignment belongs to another resource',
                    false,
                    context
                )
            end
            if currentMembership
                and currentMembership.resourceCycle ~= foundation.currentOwnerCycle(caller) then
                return foundation.failure(
                    'STALE_RESOURCE',
                    'The player bucket assignment belongs to an earlier resource lifecycle',
                    true,
                    context
                )
            end
            if currentMembership and currentMembership.bucket ~= currentBucket then
                if buckets[currentMembership.bucket] then
                    buckets[currentMembership.bucket].players[request.source] = nil
                end
                playerMemberships[request.source] = nil
                currentMembership = nil
            end
            if currentBucket ~= 0 and not currentMembership then
                return foundation.failure(
                    'FORBIDDEN',
                    'The player is in an unmanaged routing bucket',
                    false,
                    context
                )
            end
            if target.id == 0 and not currentMembership then
                return { bucket = 0, source = request.source }
            end
            if target.id > 0 and currentBucket ~= target.id
                and foundation.tableCount(target.players) >= config.maxBucketPlayers then
                return foundation.failure(
                    'RATE_LIMITED',
                    'The routing bucket player limit has been reached',
                    true,
                    context
                )
            end

            local moved = foundation.protect('player.move_bucket', function()
                ports.setPlayerRoutingBucket(request.source, target.id)
            end, context)
            if not moved or ports.getPlayerRoutingBucket(request.source) ~= target.id then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The player could not be moved to the routing bucket',
                    true,
                    context
                )
            end

            if currentMembership and buckets[currentMembership.bucket] then
                buckets[currentMembership.bucket].players[request.source] = nil
            end
            if target.id == 0 then
                playerMemberships[request.source] = nil
            else
                target.players[request.source] = true
                playerMemberships[request.source] = {
                    bucket = target.id,
                    generation = target.generation,
                    resourceCycle = foundation.currentOwnerCycle(caller),
                    resourceOwner = caller,
                }
            end
            return { bucket = target.id, source = request.source }
        end)
    end

    return operations
end
