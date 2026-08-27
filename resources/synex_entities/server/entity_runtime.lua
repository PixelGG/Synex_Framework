SynexEntityRuntime = {}

local ENTITY_TYPE_IDS = { ped = 1, vehicle = 2, object = 3 }

function SynexEntityRuntime.create(options)
    assert(type(options) == 'table', 'entity runtime options are required')
    local validation = assert(options.validation, 'entity runtime validation is required')
    local foundation = assert(options.foundation, 'entity runtime foundation is required')
    local registry = assert(options.registry, 'entity runtime registry is required')
    local state = assert(options.state, 'entity runtime state is required')
    local ports = assert(options.ports, 'entity runtime ports are required')
    local config = assert(options.config, 'entity runtime config is required')
    local cleanupQueue = assert(options.cleanupQueue, 'entity runtime cleanup queue is required')
    local cleanupEntity = options.cleanupEntity
    local buckets = state.buckets
    local runtime = {}

    local function cleanupUnregistered(
        handle, expected, expectedNetId, operation, verifyIdentity
    )
        if not ports.doesEntityExist(handle) then return true end
        if verifyIdentity then
            local inspected, actual = foundation.protect(operation .. '.inspect', function()
                return {
                    entityType = ports.getEntityType(handle),
                    model = ports.getEntityModel(handle),
                    netId = ports.networkGetNetworkIdFromEntity(handle),
                }
            end)
            if not inspected then
                return foundation.failure('DELETE_FAILED',
                    'The cleanup candidate could not be safely inspected', true)
            end
            local expectedType = ENTITY_TYPE_IDS[expected.entityType]
            local actualModel = validation.normalizeHash(actual.model)
            if actual.entityType ~= expectedType or actualModel ~= expected.model
                or (expectedNetId and actual.netId ~= expectedNetId) then
                -- The queued handle has been recycled. Never delete its replacement.
                return true
            end
        end
        foundation.protect(operation, function() ports.deleteEntity(handle) end)
        local deadline = ports.getGameTimer() + config.deleteTimeoutMs
        while ports.doesEntityExist(handle) and ports.getGameTimer() < deadline do
            ports.wait(config.waitStepMs)
        end
        if ports.doesEntityExist(handle) then
            return foundation.failure('DELETE_FAILED',
                'The cleanup candidate remains in the runtime', true)
        end
        return true
    end

    local function queueUnregistered(handle, expected, expectedNetId, operation)
        return cleanupQueue.enqueue({
            bucket = expected.bucket,
            code = 'DELETE_FAILED',
            entityType = expected.entityType,
            handle = handle,
            model = expected.model,
            netId = expectedNetId,
            operation = operation,
        }, function()
            return cleanupUnregistered(handle, expected, expectedNetId, operation, true)
        end)
    end

    local function compensateUnregistered(handle, operation, expected, expectedNetId)
        -- The first attempt still owns the handle returned by the spawn native.
        -- Retry attempts verify identity because handles may be recycled later.
        local cleaned = cleanupUnregistered(handle, expected, expectedNetId, operation, false)
        if cleaned then return true end
        queueUnregistered(handle, expected, expectedNetId, operation)
        return false
    end

    local function detach(record, mode)
        local removed, removeError = registry.remove(record.entityId, record.generation)
        if not removed then return nil, removeError end
        if not foundation.isCallable(cleanupEntity) then return removed end
        local invoked, cleaned, cleanupError = foundation.protect(
            'entity.component_cleanup',
            function()
                return cleanupEntity(record.entityId, record.generation, mode)
            end
        )
        if not invoked or not cleaned then
            foundation.setHealth('DEGRADED', 'A removed entity left runtime component state')
            if type(cleanupError) == 'table' then return nil, cleanupError end
            return foundation.failure('UNAVAILABLE',
                'Runtime component cleanup failed', true)
        end
        return removed
    end

    function runtime.resolveBucket(bucketId, generation, resourceOwner, allowDefault)
        local reference, referenceError = validation.validateBucketReference(
            bucketId,
            generation,
            allowDefault
        )
        if not reference then
            return nil, referenceError
        end
        if reference.id == 0 then
            return { id = 0, generation = 0, resourceOwner = resourceOwner }
        end

        local bucket = buckets[reference.id]
        if not bucket then
            return foundation.failure('BUCKET_NOT_FOUND', 'Routing bucket is not managed by Synex', false)
        end
        if bucket.generation ~= reference.generation then
            return foundation.failure('STALE_BUCKET', 'Routing bucket generation does not match', false)
        end
        if bucket.resourceOwner ~= resourceOwner then
            return foundation.failure('FOREIGN_BUCKET', 'Routing bucket belongs to another resource', false)
        end
        if bucket.resourceCycle ~= foundation.currentOwnerCycle(resourceOwner) then
            return foundation.failure(
                'STALE_BUCKET',
                'Routing bucket belongs to an earlier resource lifecycle',
                false
            )
        end
        if bucket.destroying then
            return foundation.failure(
                'STALE_BUCKET',
                'Routing bucket cleanup is in progress',
                true
            )
        end
        return bucket
    end

    function runtime.inspect(record)
        if not record or not ports.doesEntityExist(record.handle) then
            return foundation.failure('STALE_ENTITY', 'The runtime entity no longer exists', false)
        end

        local ok, inspection = foundation.protect('entity.inspect', function()
            return {
                bucket = ports.getEntityRoutingBucket(record.handle),
                entityType = ports.getEntityType(record.handle),
                model = ports.getEntityModel(record.handle),
                netId = ports.networkGetNetworkIdFromEntity(record.handle),
                networkOwner = ports.networkGetEntityOwner(record.handle),
            }
        end)
        if not ok then
            return foundation.failure('STALE_ENTITY', 'The runtime entity could not be inspected', false)
        end

        local actualModel = validation.normalizeHash(inspection.model)
        if inspection.entityType ~= ENTITY_TYPE_IDS[record.entityType]
            or actualModel ~= record.model
            or inspection.bucket ~= record.bucket
            or inspection.netId ~= record.netId
            or type(inspection.networkOwner) ~= 'number'
            or inspection.networkOwner % 1 ~= 0
            or inspection.networkOwner < -1
            or inspection.networkOwner > 65535 then
            return foundation.failure(
                'STALE_ENTITY',
                'The runtime mapping no longer matches the registered entity',
                false
            )
        end
        return inspection
    end

    function runtime.resolveOwned(request, caller, context)
        if type(request) ~= 'table' then
            return foundation.failure('INVALID_ARGUMENT', 'request must be an object', false, context)
        end
        for key in pairs(request) do
            if key ~= 'entityId' and key ~= 'generation' then
                return foundation.failure(
                    'INVALID_ARGUMENT',
                    'request contains an unknown field',
                    false,
                    context
                )
            end
        end

        local entityId, entityIdError = validation.validateEntityId(request.entityId)
        if not entityId then
            entityIdError.traceId = context and context.traceId
            return nil, entityIdError
        end
        local generation, generationError = validation.validateGeneration(request.generation)
        if not generation then
            generationError.traceId = context and context.traceId
            return nil, generationError
        end

        local record, registryError = registry.resolve(entityId, generation, caller)
        if not record then
            registryError.traceId = context and context.traceId
            return nil, registryError
        end
        if record.resourceCycle ~= foundation.currentOwnerCycle(caller) then
            return foundation.failure(
                'STALE_RESOURCE',
                'The entity belongs to an earlier resource lifecycle',
                false,
                context
            )
        end
        local inspection, inspectionError = runtime.inspect(record)
        if not inspection then
            inspectionError.traceId = context and context.traceId
            return nil, inspectionError
        end
        return record, inspection
    end

    function runtime.snapshot(record, inspection)
        return {
            bucket = record.bucket,
            entityId = record.entityId,
            entityType = record.entityType,
            generation = record.generation,
            model = record.model,
            netId = record.netId,
            networkOwner = inspection.networkOwner,
            persistent = record.persistent,
        }
    end

    function runtime.observeBucket(handle)
        local ok, bucketId = foundation.protect(
            'entity.observe_bucket',
            function() return ports.getEntityRoutingBucket(handle) end
        )
        if not ok or type(bucketId) ~= 'number' or bucketId % 1 ~= 0
            or bucketId < 0 or bucketId > 2147483647 then
            return nil
        end
        return bucketId
    end

    function runtime.assignBucket(record, bucketId)
        if record.bucket > 0 and buckets[record.bucket] then
            buckets[record.bucket].entities[record.entityId] = nil
        end
        local moved, moveError = registry.move(
            record.entityId,
            record.generation,
            bucketId,
            record.position
        )
        if not moved then return nil, moveError end
        if bucketId > 0 and buckets[bucketId] then
            buckets[bucketId].entities[record.entityId] = true
        end
        return moved
    end

    function runtime.create(normalized, entityId, generation, resourceOwner, resourceCycle)
        local created, handle = foundation.protect('entity.create', function()
            if normalized.entityType == 'vehicle' then
                return ports.createVehicleServerSetter(
                    normalized.model,
                    normalized.vehicleType,
                    normalized.position.x,
                    normalized.position.y,
                    normalized.position.z,
                    normalized.heading
                )
            elseif normalized.entityType == 'ped' then
                return ports.createPed(
                    normalized.pedType,
                    normalized.model,
                    normalized.position.x,
                    normalized.position.y,
                    normalized.position.z,
                    normalized.heading,
                    true,
                    true
                )
            end
            return ports.createObjectNoOffset(
                normalized.model,
                normalized.position.x,
                normalized.position.y,
                normalized.position.z,
                true,
                true,
                normalized.doorFlag
            )
        end)
        if not created or type(handle) ~= 'number' or handle % 1 ~= 0 or handle <= 0 then
            return foundation.failure('SPAWN_FAILED', 'The server setter did not create an entity', true)
        end

        local deadline = ports.getGameTimer() + (normalized.timeoutMs or config.spawnTimeoutMs)
        while not ports.doesEntityExist(handle) and ports.getGameTimer() < deadline do
            ports.wait(config.waitStepMs)
        end
        if not ports.doesEntityExist(handle) then
            compensateUnregistered(handle, 'entity.delete_after_spawn_timeout', normalized)
            return foundation.failure(
                'SPAWN_TIMEOUT',
                'The entity did not become available before the deadline',
                true
            )
        end

        local configured = foundation.protect('entity.apply_runtime_policy', function()
            ports.setEntityRoutingBucket(handle, normalized.bucket)
            ports.setEntityOrphanMode(handle, normalized.persistent and 2 or 0)
        end)
        if not configured then
            compensateUnregistered(handle, 'entity.delete_after_policy_failure', normalized)
            return foundation.failure('SPAWN_FAILED', 'The entity runtime policy could not be applied', true)
        end

        local networked, netId = foundation.protect(
            'entity.resolve_network_id',
            function() return ports.networkGetNetworkIdFromEntity(handle) end
        )
        if not networked or type(netId) ~= 'number' or netId % 1 ~= 0
            or netId < 1 or netId > 65535 then
            compensateUnregistered(handle, 'entity.delete_without_network_id', normalized)
            return foundation.failure('SPAWN_FAILED', 'The entity has no valid network ID', true)
        end

        local previousMapping = registry.byNetworkId(netId)
        if previousMapping then
            local previousInspection = runtime.inspect(previousMapping)
            if previousInspection then
                compensateUnregistered(handle, 'entity.delete_duplicate_network_id', normalized, netId)
                return foundation.failure(
                    'CONFLICT',
                    'The network ID is still mapped to a live entity',
                    true
                )
            end
            if previousMapping.bucket > 0 and buckets[previousMapping.bucket] then
                buckets[previousMapping.bucket].entities[previousMapping.entityId] = nil
            end
            detach(previousMapping, 'network_reuse')
            foundation.setHealth(
                'DEGRADED',
                'A stale runtime entity mapping was evicted after network ID reuse'
            )
        end

        local record = {
            bucket = normalized.bucket,
            binding = normalized.binding,
            doorFlag = normalized.doorFlag,
            entityId = entityId,
            entityType = normalized.entityType,
            generation = generation,
            handle = handle,
            heading = normalized.heading,
            model = normalized.model,
            netId = netId,
            owner = normalized.owner,
            pedType = normalized.pedType,
            persistent = normalized.persistent,
            persistentKey = normalized.persistentKey,
            persistencePolicy = normalized.persistencePolicy,
            position = normalized.position,
            recoveryPolicy = normalized.recoveryPolicy,
            resourceOwner = resourceOwner,
            resourceCycle = resourceCycle,
            status = normalized.status or 'active',
            archetype = normalized.archetype,
            authorityLeaseGeneration = normalized.authorityLeaseGeneration,
            tags = normalized.tags or {},
            vehicleType = normalized.vehicleType,
            version = normalized.version or 1,
        }
        local inserted, insertError = registry.insert(record)
        if not inserted then
            compensateUnregistered(handle, 'entity.delete_after_registry_conflict', normalized, netId)
            return nil, insertError
        end

        if normalized.bucket > 0 and buckets[normalized.bucket] then
            buckets[normalized.bucket].entities[entityId] = true
        end
        local inspection, inspectionError = runtime.inspect(record)
        if not inspection then
            detach(record, 'spawn_rollback')
            compensateUnregistered(handle, 'entity.delete_after_validation_failure', normalized, netId)
            return nil, inspectionError
        end
        return record, inspection
    end

    function runtime.delete(record, absoluteDeadline, cleanupMode)
        if not record or not ports.doesEntityExist(record.handle) then
            if record then return detach(record, cleanupMode or 'entity_removed') end
            return foundation.failure('ENTITY_NOT_FOUND', 'The runtime entity is not registered', false)
        end
        local inspection, inspectionError = runtime.inspect(record)
        if not inspection then
            -- The handle can be recycled. Detach the stale Synex mapping without
            -- deleting the unrelated runtime entity now occupying that handle.
            local detached, detachError = detach(record, cleanupMode or 'entity_removed')
            if not detached then return nil, detachError or inspectionError end
            return detached
        end

        -- The Cfx entityRemoved event may run before this synchronous delete
        -- path has committed its durable lifecycle transition. Mark deliberate
        -- removals so the event observer cannot race the fenced caller.
        record.deletionRequested = true
        local requested = foundation.protect('entity.delete', function()
            ports.deleteEntity(record.handle)
        end)
        if not requested then
            record.deletionRequested = nil
            return foundation.failure('DELETE_FAILED', 'The entity deletion request failed', true)
        end
        local deadline = math.min(
            ports.getGameTimer() + config.deleteTimeoutMs,
            absoluteDeadline or (ports.getGameTimer() + config.deleteTimeoutMs)
        )
        while ports.doesEntityExist(record.handle) and ports.getGameTimer() < deadline do
            ports.wait(config.waitStepMs)
        end
        if ports.doesEntityExist(record.handle) then
            record.deletionRequested = nil
            return foundation.failure(
                'DELETE_FAILED',
                'The entity was not deleted before the deadline',
                true
            )
        end

        if record.bucket > 0 and buckets[record.bucket] then
            buckets[record.bucket].entities[record.entityId] = nil
        end
        return detach(record, cleanupMode or 'delete')
    end

    function runtime.queueCleanup(record, operation, cleanupError, context)
        if type(record) ~= 'table' then
            return foundation.failure('INVALID_ARGUMENT',
                'The cleanup record is invalid', false, context)
        end
        return cleanupQueue.enqueue({
            bucket = record.bucket,
            code = type(cleanupError) == 'table' and cleanupError.code or 'DELETE_FAILED',
            entityId = record.entityId,
            entityType = record.entityType,
            generation = record.generation,
            handle = record.handle,
            model = record.model,
            netId = record.netId,
            operation = operation,
            resourceOwner = record.resourceOwner,
        }, function()
            return runtime.delete(record, nil, 'cleanup_retry')
        end, context)
    end

    return runtime
end
