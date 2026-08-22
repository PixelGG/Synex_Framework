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
    local buckets = state.buckets
    local runtime = {}

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
            return foundation.failure('NOT_FOUND', 'Routing bucket is not managed by Synex', false)
        end
        if bucket.generation ~= reference.generation then
            return foundation.failure('STALE_BUCKET', 'Routing bucket generation does not match', false)
        end
        if bucket.resourceOwner ~= resourceOwner then
            return foundation.failure('FORBIDDEN', 'Routing bucket belongs to another resource', false)
        end
        if bucket.resourceCycle ~= foundation.currentOwnerCycle(resourceOwner) then
            return foundation.failure(
                'STALE_BUCKET',
                'Routing bucket belongs to an earlier resource lifecycle',
                false
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
        record.bucket = bucketId
        if bucketId > 0 and buckets[bucketId] then
            buckets[bucketId].entities[record.entityId] = true
        end
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
            return foundation.failure('UNAVAILABLE', 'The server setter did not create an entity', true)
        end

        local deadline = ports.getGameTimer() + config.spawnTimeoutMs
        while not ports.doesEntityExist(handle) and ports.getGameTimer() < deadline do
            ports.wait(config.waitStepMs)
        end
        if not ports.doesEntityExist(handle) then
            foundation.protect('entity.delete_after_spawn_timeout', function()
                ports.deleteEntity(handle)
            end)
            return foundation.failure(
                'UNAVAILABLE',
                'The entity did not become available before the deadline',
                true
            )
        end

        local configured = foundation.protect('entity.apply_runtime_policy', function()
            ports.setEntityRoutingBucket(handle, normalized.bucket)
            ports.setEntityOrphanMode(handle, normalized.persistent and 2 or 0)
        end)
        if not configured then
            foundation.protect('entity.delete_after_policy_failure', function()
                ports.deleteEntity(handle)
            end)
            return foundation.failure('UNAVAILABLE', 'The entity runtime policy could not be applied', true)
        end

        local networked, netId = foundation.protect(
            'entity.resolve_network_id',
            function() return ports.networkGetNetworkIdFromEntity(handle) end
        )
        if not networked or type(netId) ~= 'number' or netId % 1 ~= 0
            or netId < 1 or netId > 65535 then
            foundation.protect('entity.delete_without_network_id', function()
                ports.deleteEntity(handle)
            end)
            return foundation.failure('UNAVAILABLE', 'The entity has no valid network ID', true)
        end

        local previousMapping = registry.byNetworkId(netId)
        if previousMapping then
            local previousInspection = runtime.inspect(previousMapping)
            if previousInspection then
                foundation.protect('entity.delete_duplicate_network_id', function()
                    ports.deleteEntity(handle)
                end)
                return foundation.failure(
                    'CONFLICT',
                    'The network ID is still mapped to a live entity',
                    true
                )
            end
            if previousMapping.bucket > 0 and buckets[previousMapping.bucket] then
                buckets[previousMapping.bucket].entities[previousMapping.entityId] = nil
            end
            registry.remove(previousMapping.entityId, previousMapping.generation)
            foundation.setHealth(
                'DEGRADED',
                'A stale runtime entity mapping was evicted after network ID reuse'
            )
        end

        local record = {
            bucket = normalized.bucket,
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
            position = normalized.position,
            resourceOwner = resourceOwner,
            resourceCycle = resourceCycle,
            vehicleType = normalized.vehicleType,
            version = normalized.version or 1,
        }
        local inserted, insertError = registry.insert(record)
        if not inserted then
            foundation.protect('entity.delete_after_registry_conflict', function()
                ports.deleteEntity(handle)
            end)
            return nil, insertError
        end

        if normalized.bucket > 0 and buckets[normalized.bucket] then
            buckets[normalized.bucket].entities[entityId] = true
        end
        local inspection, inspectionError = runtime.inspect(record)
        if not inspection then
            registry.remove(entityId, generation)
            foundation.protect('entity.delete_after_validation_failure', function()
                ports.deleteEntity(handle)
            end)
            return nil, inspectionError
        end
        return record, inspection
    end

    function runtime.delete(record, absoluteDeadline)
        local inspection, inspectionError = runtime.inspect(record)
        if not inspection then
            return nil, inspectionError
        end

        local requested = foundation.protect('entity.delete', function()
            ports.deleteEntity(record.handle)
        end)
        if not requested then
            return foundation.failure('UNAVAILABLE', 'The entity deletion request failed', true)
        end
        local deadline = math.min(
            ports.getGameTimer() + config.deleteTimeoutMs,
            absoluteDeadline or (ports.getGameTimer() + config.deleteTimeoutMs)
        )
        while ports.doesEntityExist(record.handle) and ports.getGameTimer() < deadline do
            ports.wait(config.waitStepMs)
        end
        if ports.doesEntityExist(record.handle) then
            return foundation.failure(
                'UNAVAILABLE',
                'The entity was not deleted before the deadline',
                true
            )
        end

        if record.bucket > 0 and buckets[record.bucket] then
            buckets[record.bucket].entities[record.entityId] = nil
        end
        return registry.remove(record.entityId, record.generation)
    end

    return runtime
end
