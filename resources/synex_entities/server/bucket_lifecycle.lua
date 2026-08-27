SynexEntityBucketLifecycle = {}

function SynexEntityBucketLifecycle.attach(operations, shared)
    assert(type(operations) == 'table', 'bucket lifecycle operations are required')
    assert(type(shared) == 'table', 'bucket lifecycle dependencies are required')
    local buckets = assert(shared.buckets, 'bucket lifecycle buckets are required')
    local config = assert(shared.config, 'bucket lifecycle config is required')
    local contractError = assert(shared.contractError,
        'bucket lifecycle contract error mapper is required')
    local entityRuntime = assert(shared.entityRuntime, 'bucket lifecycle runtime is required')
    local failure = assert(shared.failure, 'bucket lifecycle failure is required')
    local foundation = assert(shared.foundation, 'bucket lifecycle foundation is required')
    local lanes = assert(shared.lanes, 'bucket lifecycle lanes are required')
    local observability = assert(shared.observability,
        'bucket lifecycle observability is required')
    local playerMemberships = assert(shared.playerMemberships,
        'bucket lifecycle memberships are required')
    local policy = assert(shared.policy, 'bucket lifecycle policy is required')
    local ports = assert(shared.ports, 'bucket lifecycle ports are required')
    local registry = assert(shared.registry, 'bucket lifecycle registry is required')
    local validation = assert(shared.validation, 'bucket lifecycle validation is required')

    local function deadlineReached(deadline)
        return deadline ~= nil and ports.getGameTimer() >= deadline
    end

    local function returnPlayers(bucket, context)
        local sources = {}
        for source in pairs(bucket.players) do sources[#sources + 1] = source end
        table.sort(sources)
        for _, source in ipairs(sources) do
            if deadlineReached(context.deadline) then
                return failure('UNAVAILABLE',
                    'Routing bucket cleanup exceeded its deadline', true, context)
            end
            local membership = playerMemberships[source]
            if membership and membership.resourceOwner ~= bucket.resourceOwner then
                return failure('FOREIGN_BUCKET',
                    'A foreign player assignment blocks bucket cleanup', false, context)
            end
            if ports.getPlayerName(tostring(source))
                and ports.getPlayerRoutingBucket(source) == bucket.id then
                local moved, moveError = lanes.with('player:' .. tostring(source),
                    'bucket_destroy_player', context, function()
                        return operations.movePlayerRecord(
                            source,
                            { id = 0, generation = 0,
                                resourceOwner = bucket.resourceOwner },
                            context,
                            bucket.resourceOwner,
                            true
                        )
                    end)
                if not moved then return nil, moveError end
            else
                bucket.players[source] = nil
                playerMemberships[source] = nil
            end
        end
        return true
    end

    local function cleanupRecord(bucket, record, context)
        if record.resourceOwner ~= bucket.resourceOwner then
            return failure('FOREIGN_BUCKET',
                'A foreign entity blocks routing bucket cleanup', false, context)
        end
        if deadlineReached(context.deadline) then
            return failure('UNAVAILABLE',
                'Routing bucket cleanup exceeded its deadline', true, context)
        end
        return lanes.with(lanes.entityKey(record.entityId),
            'bucket_destroy', context, function()
            if record.persistent then
                return operations.moveRecord(record, {
                    id = 0,
                    generation = 0,
                    resourceOwner = bucket.resourceOwner,
                }, context, 'synex.entities.bucket_destroyed')
            end
            local deleted, deleteError = entityRuntime.delete(record, context.deadline)
            if not deleted then
                observability.increment('entity_delete_failures', {
                    lifecycle = 'bucket_destroy',
                }, 1)
                return nil, deleteError
            end
            observability.lifecycle('deleted', record,
                'synex.entities.bucket_destroyed', context)
            observability.increment('bucket_temporary_cleanup_total', {}, 1)
            observability.increment('entity_delete_total', {}, 1)
            observability.gauge('entity_live_total', {}, registry.count())
            return true
        end)
    end

    function operations.destroyRecord(bucket, cleanupDeadline, operationContext)
        if type(bucket) ~= 'table' or buckets[bucket.id] ~= bucket then
            return failure('BUCKET_NOT_FOUND', 'The managed routing bucket does not exist', false,
                operationContext)
        end
        local context = {
            caller = type(operationContext) == 'table' and operationContext.caller
                or bucket.resourceOwner,
            callerEpoch = type(operationContext) == 'table'
                and operationContext.callerEpoch or nil,
            deadline = cleanupDeadline,
            traceId = type(operationContext) == 'table' and operationContext.traceId
                or 'entity_bucket_cleanup',
        }
        bucket.destroying = true
        bucket.health = 'DEGRADED'
        if (bucket.pendingSpawns or 0) > 0 then
            return failure('CONFLICT',
                'Routing bucket spawn reservations are still active', true, context)
        end
        local returned, returnError = returnPlayers(bucket, context)
        if not returned then return nil, returnError end

        local records = registry.forBucket(bucket.id)
        table.sort(records, function(left, right) return left.entityId < right.entityId end)
        for _, record in ipairs(records) do
            local cleaned, cleanupError = cleanupRecord(bucket, record, context)
            if not cleaned then return nil, cleanupError end
        end
        if #registry.forBucket(bucket.id) ~= 0
            or foundation.tableCount(bucket.players) ~= 0 then
            return failure('UNAVAILABLE',
                'Routing bucket cleanup left tracked occupants', true, context)
        end

        local reset = foundation.protect('bucket.reset_policy', function()
            ports.setRoutingBucketPopulationEnabled(bucket.id, true)
            ports.setRoutingBucketEntityLockdownMode(bucket.id, 'inactive')
        end, context)
        if not reset then
            foundation.setHealth('DEGRADED', 'A routing bucket policy could not be reset')
            return failure('UNAVAILABLE',
                'The routing bucket policy could not be reset', true, context)
        end
        buckets[bucket.id] = nil
        observability.audit('entities.bucket_destroyed', 'routing_bucket',
            tostring(bucket.id), {
                generation = bucket.generation,
                purpose = bucket.purpose,
                resourceOwner = bucket.resourceOwner,
            }, context)
        observability.increment('bucket_destroyed_total', { profile = bucket.profile }, 1)
        return true
    end

    local function resolveDestroyTarget(request, caller, context)
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return failure('INVALID_ARGUMENT', 'request must be a plain object', false, context)
        end
        for key in pairs(request) do
            if key ~= 'bucket' and key ~= 'generation' then
                return failure('INVALID_ARGUMENT',
                    'request contains an unknown field', false, context)
            end
        end
        local reference, referenceError = validation.validateBucketReference(
            request.bucket, request.generation, false)
        if not reference then return nil, referenceError end
        local bucket = buckets[reference.id]
        if not bucket then
            return failure('BUCKET_NOT_FOUND',
                'Routing bucket is not managed by Synex', false, context)
        end
        if bucket.generation ~= reference.generation then
            return failure('STALE_BUCKET',
                'Routing bucket generation does not match', false, context)
        end
        if bucket.resourceOwner ~= caller then
            return failure('FOREIGN_BUCKET',
                'Routing bucket belongs to another resource', false, context)
        end
        if bucket.resourceCycle ~= foundation.currentOwnerCycle(caller) then
            return failure('STALE_BUCKET',
                'Routing bucket belongs to an earlier resource lifecycle', false, context)
        end
        return bucket
    end

    function operations.destroy(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(caller, 3, context, false)
        if not allowed then return nil, rateError end
        return foundation.withOwnerMutation(caller, context, function()
            local bucket, bucketError = resolveDestroyTarget(request, caller, context)
            if not bucket then return nil, bucketError end
            local destroyed, destroyError = operations.destroyRecord(
                bucket,
                ports.getGameTimer() + config.bucketCleanupTimeoutMs,
                context
            )
            if not destroyed then return nil, contractError(destroyError, context) end
            return { bucket = request.bucket, destroyed = true }
        end)
    end

    function operations.expire(context)
        local due = {}
        for _, bucket in pairs(buckets) do
            if policy.isExpired(bucket) then due[#due + 1] = bucket end
        end
        table.sort(due, function(left, right)
            if left.expiresAt == right.expiresAt then return left.id < right.id end
            return left.expiresAt < right.expiresAt
        end)
        local report = { expired = 0, failed = 0, remaining = math.max(0, #due - 16) }
        for index = 1, math.min(#due, 16) do
            local bucket = due[index]
            local internalContext = {
                caller = bucket.resourceOwner,
                callerEpoch = type(context) == 'table' and context.callerEpoch or nil,
                traceId = 'entity_bucket_expiry',
            }
            local destroyed, destroyError = foundation.withOwnerMutation(
                bucket.resourceOwner, internalContext, function()
                    return operations.destroyRecord(
                        bucket,
                        ports.getGameTimer() + config.bucketCleanupTimeoutMs,
                        internalContext
                    )
                end)
            if destroyed then report.expired = report.expired + 1
            else
                report.failed = report.failed + 1
                bucket.health = 'DEGRADED'
                foundation.setHealth('DEGRADED',
                    type(destroyError) == 'table' and destroyError.code
                        or 'BUCKET_EXPIRY_FAILED')
            end
        end
        return report
    end
end
