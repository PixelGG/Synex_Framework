SynexEntityOperations = {}

function SynexEntityOperations.create(options)
    assert(type(options) == 'table', 'entity operation options are required')
    local validation = assert(options.validation, 'entity operations validation is required')
    local foundation = assert(options.foundation, 'entity operations foundation is required')
    local repository = assert(options.repository, 'entity operations repository is required')
    local registry = assert(options.registry, 'entity operations registry is required')
    local entityRuntime = assert(options.entityRuntime, 'entity operations runtime is required')
    local coreRef = assert(options.coreRef, 'entity operations coreRef is required')
    local operations = {}

    function operations.spawn(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 4, context, false)
        if not allowed then
            return nil, rateError
        end

        return foundation.withOwnerMutation(caller, context, function()
            local normalized, validationError = validation.validateSpawn(request)
            if not normalized then
                validationError.traceId = context.traceId
                return nil, validationError
            end
            return foundation.withSpawnReservation(caller, normalized.bucket, context, function()
                local bucket, bucketError = entityRuntime.resolveBucket(
                    normalized.bucket,
                    normalized.bucketGeneration,
                    caller,
                    true
                )
                if not bucket then
                    bucketError.traceId = context.traceId
                    return nil, bucketError
                end

                if normalized.persistent then
                    local existing, queryError = repository.findPersistentByKey(
                        normalized.persistentKey,
                        context
                    )
                    if not existing then
                        return nil, queryError
                    end
                    if existing[1] then
                        return foundation.failure(
                            'CONFLICT',
                            'persistentKey is already registered',
                            false,
                            context
                        )
                    end
                end

                local api = coreRef.value
                if not api or type(api.Ids) ~= 'table' or type(api.Ids.next) ~= 'function' then
                    return foundation.failure(
                        'UNAVAILABLE',
                        'The Core ID service is unavailable',
                        true,
                        context
                    )
                end
                local idOk, entityIdOrError, idError = foundation.protect(
                    'core.ids.entity',
                    function() return api.Ids.next('entity') end,
                    context
                )
                if not idOk or not entityIdOrError then
                    if type(idError) == 'table' then
                        idError.traceId = context.traceId
                        return nil, idError
                    end
                    return foundation.failure(
                        'UNAVAILABLE',
                        'The Core ID service failed',
                        true,
                        context
                    )
                end
                local entityId, entityIdError = validation.validateEntityId(entityIdOrError)
                if not entityId then
                    entityIdError.traceId = context.traceId
                    return nil, entityIdError
                end

                local record, inspectionOrError = entityRuntime.create(
                    normalized,
                    entityId,
                    1,
                    caller,
                    foundation.currentOwnerCycle(caller)
                )
                if not record then
                    inspectionOrError.traceId = context.traceId
                    return nil, inspectionOrError
                end

                if normalized.persistent then
                    local inserted, persistenceError = repository.insertPersistent(record, context)
                    if inserted ~= 1 then
                        entityRuntime.delete(record)
                        if persistenceError then
                            return nil, persistenceError
                        end
                        return foundation.failure(
                            'CONFLICT',
                            'The persistent entity could not be inserted',
                            true,
                            context
                        )
                    end
                end
                return entityRuntime.snapshot(record, inspectionOrError)
            end)
        end)
    end

    function operations.get(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 1, context, true)
        if not allowed then
            return nil, rateError
        end

        local record, inspectionOrError = entityRuntime.resolveOwned(request, caller, context)
        if not record then
            return nil, inspectionOrError
        end
        return entityRuntime.snapshot(record, inspectionOrError)
    end

    function operations.resolvePersistent(request, context)
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
                if key ~= 'persistentKey' then
                    return foundation.failure(
                        'INVALID_ARGUMENT',
                        'request contains an unknown field',
                        false,
                        context
                    )
                end
            end
            local persistentKey, validationError = validation.validatePersistentKey(request.persistentKey)
            if not persistentKey then
                validationError.traceId = context.traceId
                return nil, validationError
            end
            local record, registryError = registry.byPersistentKey(persistentKey, caller)
            if not record then
                registryError.traceId = context.traceId
                return nil, registryError
            end
            if record.orphaning then
                return foundation.failure(
                    'UNAVAILABLE',
                    'The persistent entity is still completing owner cleanup',
                    true,
                    context
                )
            end
            local callerCycle = foundation.currentOwnerCycle(caller)
            if record.resourceCycle ~= nil and record.resourceCycle ~= callerCycle then
                return foundation.failure(
                    'STALE_RESOURCE',
                    'The persistent entity is bound to an earlier resource lifecycle',
                    true,
                    context
                )
            end
            local inspection, inspectionError = entityRuntime.inspect(record)
            if not inspection then
                inspectionError.traceId = context.traceId
                return nil, inspectionError
            end
            if record.resourceCycle == nil then
                local previousVersion = record.version
                local claimed, persistenceError = repository.claimPersistent(
                    record.entityId,
                    previousVersion,
                    context
                )
                if claimed ~= 1 then
                    if persistenceError then
                        return nil, persistenceError
                    end
                    return foundation.failure(
                        'CONFLICT',
                        'The persistent entity changed while it was being claimed',
                        true,
                        context
                    )
                end
                record.version = previousVersion + 1
            end
            record.resourceCycle = callerCycle
            return entityRuntime.snapshot(record, inspection)
        end)
    end

    function operations.delete(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 2, context, false)
        if not allowed then
            return nil, rateError
        end

        return foundation.withOwnerMutation(caller, context, function()
            local record, inspectionOrError = entityRuntime.resolveOwned(request, caller, context)
            if not record then
                return nil, inspectionOrError
            end

            if record.persistent then
                local updated, persistenceError = repository.beginDelete(
                    record.entityId,
                    record.version,
                    context
                )
                if updated ~= 1 then
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
            end

            local deleted, deleteError = entityRuntime.delete(record)
            if not deleted then
                if record.persistent then
                    local reverted = repository.revertDelete(record.entityId, context)
                    if reverted == 1 then
                        record.version = record.version + 2
                    else
                        foundation.setHealth('DEGRADED', 'A failed entity deletion could not be reverted')
                    end
                end
                deleteError.traceId = context.traceId
                return nil, deleteError
            end

            if record.persistent then
                local finished, persistenceError = repository.finishDelete(record.entityId, context)
                if finished ~= 1 then
                    if persistenceError then
                        return nil, persistenceError
                    end
                    foundation.setHealth(
                        'DEGRADED',
                        'A deleted runtime entity remains pending in persistence'
                    )
                    return foundation.failure(
                        'CONFLICT',
                        'Persistent deletion finalization changed concurrently',
                        true,
                        context
                    )
                end
            end
            return { deleted = true, entityId = record.entityId }
        end)
    end

    return operations
end
