SynexEntityAuthorityService = {}
local STATUS = {
    active = 'ACTIVE',
    defined = 'DEFINED',
    deleted = 'DELETED',
    deleting = 'DELETING',
    dormant = 'DORMANT',
    failed = 'FAILED',
    orphaned = 'ORPHANED',
    recovering = 'RECOVERING',
    spawning = 'SPAWNING',
}
function SynexEntityAuthorityService.create(options)
    assert(type(options) == 'table', 'entity authority service options are required')
    local archetypes = assert(options.archetypes, 'entity archetype service is required')
    local authorityRepository = assert(options.authorityRepository,
        'entity authority repository is required')
    local checkpointGuard = assert(options.checkpointGuard,
        'entity checkpoint guard is required')
    local extensionRepository = assert(options.extensionRepository,
        'entity extension repository is required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity extension registry is required')
    local extensionOperations = assert(options.extensionOperations,
        'entity extension lifecycle operations are required')
    local entityRuntime = assert(options.entityRuntime, 'entity runtime is required')
    local legacyOperations = assert(options.legacyOperations,
        'legacy entity operations are required')
    local logicalOwner = assert(options.logicalOwner,
        'entity logical-owner service is required')
    local foundation = assert(options.foundation, 'entity foundation is required')
    local health = options.health
    local validation = assert(options.validation, 'entity validation is required')
    local registry = assert(options.registry, 'entity registry is required')
    local lanes = assert(options.lanes, 'entity mutation lanes are required')
    local observability = assert(options.observability,
        'entity observability is required')
    local coreRef = assert(options.coreRef, 'entity Core reference is required')
    local ports = assert(options.ports, 'entity ports are required')
    local config = assert(options.config, 'entity config is required')
    local resourceName = assert(options.resourceName, 'entity resource name is required')
    local spawnAdmission = assert(options.spawnAdmission, 'entity spawn admission is required')
    local service = {}
    local authority
    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end
    local function caller(context)
        return foundation.getCaller(context)
    end
    local function requireAuthority(context)
        if not authority or authority.invalid == true then
            return failure('CORE_UNAVAILABLE', 'Entity runtime authority is not initialized', true, context)
        end
        return authority
    end
    local function requireCapability(target, capability, operation, context)
        local api = coreRef.value
        if not api or type(api.Capabilities) ~= 'table'
            or not foundation.isCallable(api.Capabilities.checkResource) then
            return failure('CORE_UNAVAILABLE', 'The delegated capability gateway is unavailable', true, context)
        end
        local invoked, allowed, capabilityError = foundation.protect(
            'core.capabilities.' .. operation,
            function() return api.Capabilities.checkResource(target, capability, operation) end,
            context
        )
        if not invoked or allowed ~= true then
            observability.increment('entity_access_denials_total', { capability = capability }, 1)
            return nil, type(capabilityError) == 'table' and capabilityError or {
                code = 'FORBIDDEN',
                message = 'The resource lacks the required entity capability',
                retryable = false,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        return true
    end
    local function nextId(namespace, context)
        local api = coreRef.value
        if not api or type(api.Ids) ~= 'table' or not foundation.isCallable(api.Ids.next) then
            return failure('CORE_UNAVAILABLE', 'The Core ID service is unavailable', true, context)
        end
        local ok, value, operationError = foundation.protect(
            'core.ids.' .. namespace,
            function() return api.Ids.next(namespace) end,
            context
        )
        if not ok or value == nil then
            return nil, type(operationError) == 'table' and operationError or {
                code = 'UNAVAILABLE',
                message = 'The Core ID service failed',
                retryable = true,
            }
        end
        return value
    end
    local function idempotent(operation, request, context, handler)
        -- The original v1 spawn contract did not require a key. Preserve that
        -- compatibility path while all new mutation contracts remain replay-safe.
        if request.idempotencyKey == nil then return handler() end
        local api = coreRef.value
        if not api or type(api.Idempotency) ~= 'table'
            or not foundation.isCallable(api.Idempotency.run) then
            return failure('CORE_UNAVAILABLE', 'The Core idempotency service is unavailable', true, context)
        end
        return api.Idempotency.run(operation, request.idempotencyKey, {
            caller = context.caller,
            request = request,
        }, handler, {
            lockSeconds = 30,
            maximumRequestBytes = 49152,
            maximumResponseBytes = 32768,
            ttlSeconds = 86400,
        })
    end
    local function ensureSpawnCapabilities(invokingResource, normalized, context)
        local allowed, capabilityError = requireCapability(
            invokingResource,
            'synex.entities.spawn.' .. normalized.entityType,
            'entities.spawn.' .. normalized.entityType,
            context
        )
        if not allowed then return nil, capabilityError end
        if not normalized.archetype then
            return requireCapability(
                invokingResource,
                'synex.entities.spawn.raw',
                'entities.spawn.raw',
                context
            )
        end
        return true
    end

    local function normalizeDefinition(definition, bucketReference, binding)
        return {
            archetype = definition.archetype and {
                namespace = definition.archetype.namespace,
                schemaVersion = definition.archetype.schemaVersion,
                version = definition.archetype.schemaVersion,
            } or nil,
            binding = binding,
            bucket = bucketReference.id,
            bucketGeneration = bucketReference.generation,
            doorFlag = definition.doorFlag,
            entityType = definition.entityType,
            heading = definition.heading,
            model = definition.model,
            owner = definition.owner,
            pedType = definition.pedType,
            persistencePolicy = definition.persistencePolicy,
            persistent = true,
            persistentKey = definition.persistentKey,
            position = definition.position,
            recoveryPolicy = definition.recoveryPolicy,
            status = 'active',
            vehicleType = definition.vehicleType,
        }
    end

    local function activateReserved(normalized, reservation, invokingResource, context, recovered)
        normalized.version = reservation.version
        normalized.authorityLeaseGeneration = reservation.leaseGeneration
        local record, inspectionOrError = entityRuntime.create(
            normalized,
            reservation.entityId,
            reservation.generation,
            invokingResource,
            foundation.currentOwnerCycle(invokingResource)
        )
        if not record then
            local failureCode = type(inspectionOrError) == 'table'
                and inspectionOrError.code or 'SPAWN_FAILED'
            if not recovered then
                authorityRepository.markFailed(
                    reservation.entityId,
                    reservation.generation,
                    authority,
                    failureCode,
                    context
                )
            end
            observability.increment('entity_spawn_failures_total', { code = failureCode }, 1)
            return nil, inspectionOrError
        end
        local hydrated, hydrationError = extensionOperations.hydrate(record, context)
        if not hydrated then
            local deleted, deleteError = entityRuntime.delete(record, nil, 'activation_failed')
            if not deleted then
                entityRuntime.queueCleanup(record, 'entity.cleanup_after_hydration_failure',
                    deleteError, context)
            end
            if not recovered then
                authorityRepository.markFailed(
                    reservation.entityId,
                    reservation.generation,
                    authority,
                    type(hydrationError) == 'table'
                        and hydrationError.code or 'HYDRATION_FAILED',
                    context
                )
            end
            observability.increment('entity_spawn_failures_total', {
                code = type(hydrationError) == 'table'
                    and hydrationError.code or 'HYDRATION_FAILED',
            }, 1)
            return nil, hydrationError
        end
        local activated, activationError = authorityRepository.activate(
            record.entityId,
            record.generation,
            reservation.version,
            reservation.leaseGeneration,
            record.bucket,
            authority,
            context
        )
        if not activated then
            local deleted, deleteError = entityRuntime.delete(record)
            if not deleted then
                entityRuntime.queueCleanup(record, 'entity.cleanup_after_activation_failure',
                    deleteError, context)
            end
            if not recovered then
                authorityRepository.markFailed(
                    reservation.entityId,
                    reservation.generation,
                    authority,
                    type(activationError) == 'table'
                        and activationError.code or 'ACTIVATION_FAILED',
                    context
                )
            end
            return nil, activationError
        end
        registry.update(record.entityId, record.generation, {
            status = 'active',
            version = activated.version,
        })
        record.authorityLeaseGeneration = reservation.leaseGeneration
        if not recovered then
            observability.event('synex.entities.materialized', {
                entityId = record.entityId,
                generation = record.generation,
                resourceOwner = record.resourceOwner,
            }, context)
            observability.audit('entities.materialized', 'entity', record.entityId,
                { generation = record.generation,
                    resourceOwner = record.resourceOwner }, context)
            observability.audit('entities.spawned', 'entity', record.entityId, {
                entityType = record.entityType,
                generation = record.generation,
                resourceOwner = record.resourceOwner,
            }, context)
            observability.increment('entity_spawn_total',
                { entityType = record.entityType }, 1)
        end
        observability.gauge('entity_live_total', {}, registry.count())
        return record, inspectionOrError
    end

    function service.spawn(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(invokingResource, 5, context, false)
        if not allowed then return nil, rateError end
        local prepared, archetype, preparationError = archetypes.prepareSpawn(
            request, invokingResource, context)
        if not prepared then return nil, preparationError end
        local normalized, validationError = validation.validateSpawn(prepared)
        if not normalized then validationError.traceId = context.traceId return nil, validationError end
        if not normalized.persistent then
            return legacyOperations.spawn(prepared, context)
        end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        local owner, ownerError = logicalOwner.validate(
            normalized.owner, invokingResource, context)
        if not owner then return nil, ownerError end
        normalized.owner = owner
        local capability, capabilityError = ensureSpawnCapabilities(invokingResource, normalized, context)
        if not capability then return nil, capabilityError end
        local hookValue, hookError = observability.before(
            'synex.entities.before_entity_spawn',
            { caller = invokingResource, request = request },
            context
        )
        if not hookValue then return nil, hookError end
        local laneKey = normalized.binding and lanes.bindingKey(
            normalized.binding.namespace,
            normalized.binding.ref
        ) or ('persistent:' .. invokingResource .. ':' .. normalized.persistentKey)
        return idempotent('entity.spawn', request, context, function()
            return lanes.with(laneKey, 'spawn', context, function()
                local bucket, bucketError = entityRuntime.resolveBucket(
                    normalized.bucket,
                    normalized.bucketGeneration,
                    invokingResource,
                    true
                )
                if not bucket then bucketError.traceId = context.traceId return nil, bucketError end
                return spawnAdmission.withReservation(
                    invokingResource, normalized, context, function()
                local entityId, entityIdError = nextId('entity', context)
                if not entityId then return nil, entityIdError end
                local encoded
                if archetype then
                    local encodeError
                    encoded, encodeError = archetypes.descriptorJson(
                        normalized, archetype, context)
                    if not encoded then return nil, encodeError end
                end
                local reservation, reservationError = authorityRepository.reserve(
                    normalized,
                    entityId,
                    invokingResource,
                    current,
                    encoded,
                    context
                )
                if not reservation then return nil, reservationError end
                for _, tag in ipairs(normalized.tags or {}) do
                    local stored, tagError = extensionRepository.addTag(
                        entityId, reservation.generation, invokingResource, tag,
                        current, reservation.leaseGeneration, context
                    )
                    if not stored then
                        authorityRepository.markFailed(
                            entityId, reservation.generation, current,
                            type(tagError) == 'table' and tagError.code or 'TAG_WRITE_FAILED',
                            context
                        )
                        return nil, tagError
                    end
                end
                local record, inspection = activateReserved(
                    normalized, reservation, invokingResource, context, false
                )
                if not record then return nil, inspection end
                observability.event('synex.entities.created', {
                    entityId = record.entityId,
                    generation = record.generation,
                    resourceOwner = invokingResource,
                }, context)
                observability.audit('entities.created', 'entity', record.entityId, {
                    generation = record.generation,
                    persistencePolicy = record.persistencePolicy,
                    resourceOwner = invokingResource,
                }, context)
                if record.binding then
                    observability.audit('entities.binding_changed', 'entity',
                        record.entityId, { binding = record.binding,
                            generation = record.generation }, context)
                end
                return entityRuntime.snapshot(record, inspection)
                end, true)
            end)
        end)
        end)
    end

    local function observedCheckpoint(record, reasonCode, context)
        local inspected, inspectionError = entityRuntime.inspect(record)
        if not inspected then return nil, inspectionError end
        local positionOk, rawPosition = foundation.protect(
            'entity.checkpoint.position',
            function() return ports.getEntityCoords(record.handle) end,
            context
        )
        local headingOk, heading = foundation.protect(
            'entity.checkpoint.heading',
            function() return ports.getEntityHeading(record.handle) end,
            context
        )
        if not positionOk or not headingOk then
            return failure('UNAVAILABLE', 'The runtime transform could not be observed', true, context)
        end
        local position, positionError = validation.validatePosition({
            x = tonumber(rawPosition.x or rawPosition[1]),
            y = tonumber(rawPosition.y or rawPosition[2]),
            z = tonumber(rawPosition.z or rawPosition[3]),
        })
        if not position then return nil, positionError end
        heading = tonumber(heading)
        if not heading or heading ~= heading then
            return failure('INVALID_POSITION', 'The runtime heading is invalid', true, context)
        end
        return {
            bucket = inspected.bucket,
            heading = heading % 360.0,
            position = position,
            reasonCode = reasonCode,
        }
    end

    local function checkpointRecord(record, invokingResource, reasonCode, expectedVersion, context)
        if not record.persistent then
            return failure('INVALID_ARGUMENT', 'Only durable entities can be checkpointed', false, context)
        end
        if expectedVersion ~= nil and record.version ~= expectedVersion then
            return failure('CONCURRENT_MODIFICATION', 'The entity version changed', true, context)
        end
        local checkpointTicket, debounceError = checkpointGuard.check(
            record.entityId, record.generation, context)
        if not checkpointTicket then return nil, debounceError end
        local hookValue, hookError = observability.before(
            'synex.entities.before_entity_checkpoint',
            { entity = registry.entityRef(record), reasonCode = reasonCode },
            context
        )
        if not hookValue then return nil, hookError end
        local checkpoint, checkpointError = observedCheckpoint(record, reasonCode, context)
        if not checkpoint then return nil, checkpointError end
        local stored, storeError = extensionRepository.checkpoint(
            record.entityId,
            record.generation,
            record.version,
            invokingResource,
            authority,
            record.authorityLeaseGeneration,
            checkpoint,
            '{}',
            context
        )
        if not stored then return nil, storeError end
        checkpointGuard.commit(checkpointTicket)
        registry.move(record.entityId, record.generation, checkpoint.bucket, checkpoint.position)
        registry.update(record.entityId, record.generation, { version = stored.version })
        local checkpointId, checkpointIdError = nextId('checkpoint', context)
        if not checkpointId then return nil, checkpointIdError end
        observability.audit('entities.checkpointed', 'entity', record.entityId, {
            checkpointVersion = stored.checkpointVersion,
            generation = record.generation,
            reasonCode = reasonCode,
        }, context)
        return {
            checkpointId = checkpointId,
            checkpointedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            entity = registry.entityRef(record),
            version = stored.version,
        }
    end

    function service.checkpoint(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(invokingResource, 3, context, false)
        if not allowed then return nil, rateError end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        return idempotent('entity.checkpoint', request, context, function()
            local entityRef, refError = validation.validateEntityRef(request.entity)
            if not entityRef then return nil, refError end
            return lanes.with(lanes.entityKey(entityRef.entityId), 'checkpoint', context, function()
                local record, resolveError = entityRuntime.resolveOwned(
                    entityRef, invokingResource, context
                )
                if not record then return nil, resolveError end
                return checkpointRecord(
                    record, invokingResource, request.reasonCode, request.expectedVersion, context
                )
            end)
        end)
        end)
    end

    function service.delete(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        local record = registry.resolveRef(request, invokingResource)
        if not record then
            -- Dormant definitions are terminated through the authority repository.
            local definition, definitionError = authorityRepository.getById(request.entityId, context)
            if not definition then return nil, definitionError end
            if definition.resourceOwner ~= invokingResource
                or definition.generation ~= request.generation then
                return failure('STALE_ENTITY', 'The entity reference is stale or foreign', false, context)
            end
            local capability, capabilityError = requireCapability(
                invokingResource,
                'synex.entities.delete_persistent',
                'entities.delete_persistent',
                context
            )
            if not capability then return nil, capabilityError end
            local hookValue, hookError = observability.before(
                'synex.entities.before_entity_delete',
                { entity = request, reasonCode = 'synex.entities.deleted' },
                context
            )
            if not hookValue then return nil, hookError end
            local terminated, terminateError = extensionRepository.terminate(
                definition.entityId,
                definition.generation,
                invokingResource,
                authority,
                nil,
                'synex.entities.deleted',
                context
            )
            if not terminated then
                observability.increment('entity_delete_failures', {}, 1)
                return nil, terminateError
            end
            extensionOperations.cleanupEntity(
                definition.entityId, definition.generation, 'delete', context)
            checkpointGuard.clear(definition.entityId, definition.generation)
            observability.event('synex.entities.deleted', {
                entityId = definition.entityId,
                generation = definition.generation,
                resourceOwner = invokingResource,
            }, context)
            observability.audit('entities.deleted', 'entity', definition.entityId, {
                generation = definition.generation,
                resourceOwner = invokingResource,
            }, context)
            observability.increment('entity_delete_total', {}, 1)
            observability.gauge('entity_live_total', {}, registry.count())
            return { deleted = true, entityId = definition.entityId }
        end
        if not record.persistent then return legacyOperations.delete(request, context) end
        local capability, capabilityError = requireCapability(
            invokingResource,
            'synex.entities.delete_persistent',
            'entities.delete_persistent',
            context
        )
        if not capability then return nil, capabilityError end
        return lanes.with(lanes.entityKey(record.entityId), 'delete', context, function()
            local hookValue, hookError = observability.before(
                'synex.entities.before_entity_delete',
                { entity = request, reasonCode = 'synex.entities.deleted' },
                context
            )
            if not hookValue then return nil, hookError end
            local deleted, deleteError = entityRuntime.delete(record)
            if not deleted then
                observability.increment('entity_delete_failures_total', {}, 1)
                observability.increment('entity_delete_failures', {}, 1)
                return nil, deleteError
            end
            local terminated, terminateError = extensionRepository.terminate(
                record.entityId,
                record.generation,
                invokingResource,
                authority,
                record.authorityLeaseGeneration,
                'synex.entities.deleted',
                context
            )
            if not terminated then
                observability.increment('entity_delete_failures', {}, 1)
                return nil, terminateError
            end
            checkpointGuard.clear(record.entityId, record.generation)
            observability.event('synex.entities.deleted', {
                entityId = record.entityId,
                generation = record.generation,
                resourceOwner = invokingResource,
            }, context)
            observability.audit('entities.deleted', 'entity', record.entityId, {
                generation = record.generation,
                resourceOwner = invokingResource,
            }, context)
            observability.increment('entity_delete_total', {}, 1)
            observability.gauge('entity_live_total', {}, registry.count())
            return { deleted = true, entityId = record.entityId }
        end)
        end)
    end

    function service.ownerSet(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local entityRef, refError = validation.validateEntityRef(request.entity)
        if not entityRef then return nil, refError end
        local owner, ownerError = logicalOwner.validate(
            request.owner, invokingResource, context)
        if not owner then return nil, ownerError end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        return idempotent('entity.owner.set', request, context, function()
            return lanes.with(lanes.entityKey(entityRef.entityId), 'owner_set', context, function()
                local record, resolveError = entityRuntime.resolveOwned(
                    entityRef, invokingResource, context
                )
                if not record then return nil, resolveError end
                if record.version ~= request.expectedVersion then
                    return failure('CONCURRENT_MODIFICATION', 'The entity version changed', true, context)
                end
                local hookValue, hookError = observability.before(
                    'synex.entities.before_entity_owner_change',
                    { entity = entityRef, owner = owner, previousOwner = record.owner },
                    context
                )
                if not hookValue then return nil, hookError end
                local previousOwner = record.owner
                local changed, changeError = extensionRepository.changeOwner(
                    record.entityId,
                    record.generation,
                    invokingResource,
                    owner,
                    request.expectedVersion,
                    authority,
                    record.authorityLeaseGeneration,
                    request.reasonCode,
                    context
                )
                if not changed then return nil, changeError end
                local nextVersion = request.expectedVersion + 1
                registry.update(record.entityId, record.generation, {
                    owner = owner,
                    version = nextVersion,
                })
                observability.event('synex.entities.owner.changed', {
                    entityId = record.entityId,
                    generation = record.generation,
                    owner = owner,
                    previousOwner = previousOwner,
                }, context)
                observability.audit('entities.owner_changed', 'entity', record.entityId, {
                    owner = owner,
                    reasonCode = request.reasonCode,
                }, context)
                return {
                    changed = true,
                    entity = entityRef,
                    owner = owner,
                    version = nextVersion,
                }
            end)
        end)
        end)
    end

    function service.bindingGet(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local binding, bindingError = validation.validateBinding(request.binding, true)
        if not binding then return nil, bindingError end
        local definition, definitionError = authorityRepository.getByBinding(
            binding.namespace,
            binding.ref,
            context
        )
        if not definition then return nil, definitionError end
        if definition.resourceOwner ~= invokingResource then
            return failure('FOREIGN_RESOURCE_OWNER', 'The binding belongs to another resource', false, context)
        end
        local record = registry.byEntityId(definition.entityId)
        return {
            binding = binding,
            entity = {
                entityId = definition.entityId,
                generation = definition.generation,
            },
            materialized = record ~= nil and definition.status == 'active',
        }
    end

    SynexEntityAuthorityLifecycle.attach(service, {
        activateReserved = activateReserved,
        authorityRepository = authorityRepository,
        caller = caller,
        checkpointRecord = checkpointRecord,
        config = config,
        coreRef = coreRef,
        entityRuntime = entityRuntime,
        extensionRegistry = extensionRegistry,
        extensionOperations = extensionOperations,
        failure = failure,
        foundation = foundation,
        health = health,
        getAuthority = function() return authority end,
        idempotent = idempotent,
        lanes = lanes,
        nextId = nextId,
        normalizeDefinition = normalizeDefinition,
        observability = observability,
        getGameTimer = ports.getGameTimer,
        registry = registry,
        requireAuthority = requireAuthority,
        resourceName = resourceName,
        setAuthority = function(value) authority = value end,
        spawnAdmission = spawnAdmission,
        validation = validation,
    })
    return service
end
