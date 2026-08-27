SynexEntityAuthorityLifecycle = {}

function SynexEntityAuthorityLifecycle.attach(service, options)
    assert(type(service) == 'table', 'entity authority service is required')
    assert(type(options) == 'table', 'entity authority lifecycle options are required')
    local activateReserved = assert(options.activateReserved,
        'entity activation helper is required')
    local authorityRepository = assert(options.authorityRepository,
        'entity authority repository is required')
    local checkpointRecord = assert(options.checkpointRecord,
        'entity checkpoint helper is required')
    local config = assert(options.config, 'entity lifecycle config is required')
    local coreRef = assert(options.coreRef, 'entity lifecycle Core reference is required')
    local entityRuntime = assert(options.entityRuntime, 'entity lifecycle runtime is required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity extension registry is required')
    local extensionOperations = assert(options.extensionOperations,
        'entity extension lifecycle operations are required')
    local failure = assert(options.failure, 'entity lifecycle failure helper is required')
    local foundation = assert(options.foundation, 'entity lifecycle foundation is required')
    local health = options.health
    local getGameTimer = assert(options.getGameTimer,
        'entity lifecycle monotonic clock is required')
    local getAuthority = assert(options.getAuthority,
        'entity lifecycle authority reader is required')
    local idempotent = assert(options.idempotent,
        'entity lifecycle idempotency helper is required')
    local lanes = assert(options.lanes, 'entity lifecycle mutation lanes are required')
    local nextId = assert(options.nextId, 'entity lifecycle ID helper is required')
    local normalizeDefinition = assert(options.normalizeDefinition,
        'entity definition normalizer is required')
    local observability = assert(options.observability,
        'entity lifecycle observability is required')
    local registry = assert(options.registry, 'entity lifecycle registry is required')
    local resourceName = assert(options.resourceName,
        'entity lifecycle resource name is required')
    local setAuthority = assert(options.setAuthority,
        'entity lifecycle authority writer is required')
    local spawnAdmission = assert(options.spawnAdmission,
        'entity lifecycle spawn admission is required')
    local validation = assert(options.validation, 'entity lifecycle validation is required')
    local caller = assert(options.caller, 'entity lifecycle caller helper is required')
    local requireAuthority = assert(options.requireAuthority,
        'entity lifecycle authority guard is required')

    local function recoveryDuration(startedAt)
        local current = tonumber(getGameTimer())
        if type(startedAt) ~= 'number' or not current then return 0 end
        local elapsed = current - startedAt
        if elapsed < 0 then elapsed = elapsed + 4294967296 end
        return math.max(0, math.min(3600000, math.floor(elapsed)))
    end

    local function recoveryPolicy(durationMs)
        return {
            baseDelaySeconds = config.recoveryBaseDelaySeconds,
            durationMs = durationMs,
            jitterSeconds = config.recoveryJitterSeconds,
            maxAttempts = config.recoveryMaxAttempts,
            maxDelaySeconds = config.recoveryMaxDelaySeconds,
            windowSeconds = config.recoveryWindowSeconds,
        }
    end

    local function recoveryFailureCode(value)
        local code = type(value) == 'table' and value.code or nil
        if type(code) == 'string' and #code >= 3 and #code <= 64
            and code:match('^[A-Z][A-Z0-9_]*$') ~= nil then return code end
        return 'SPAWN_FAILED'
    end

    local function findDefinition(target, context)
        if type(target) ~= 'table' then
            return failure('INVALID_ARGUMENT',
                'Materialization target must be an object', false, context)
        end
        if target.entityId then
            local entityId, entityIdError = validation.validateEntityId(target.entityId)
            if not entityId then return nil, entityIdError end
            return authorityRepository.getById(entityId, context)
        end
        local binding, bindingError = validation.validateBinding(target.binding, true)
        if not binding then return nil, bindingError end
        return authorityRepository.getByBinding(binding.namespace, binding.ref, context)
    end

    local function observeReconciliation(reconciled, context)
        local orphaned = tonumber(reconciled and reconciled.orphaned) or 0
        if orphaned < 1 then return end
        observability.increment('entity_orphaned_total', {}, orphaned)
        observability.audit('entities.orphaned', 'server_scope', config.serverScope, {
            count = orphaned, reasonCode = 'synex.entities.boot_reconciled',
        }, context)
    end
    function service.initialize(context)
        local api = coreRef.value
        if not api or type(api.Runtime) ~= 'table'
            or not foundation.isCallable(api.Runtime.getSnapshot) then
            return failure('CORE_UNAVAILABLE',
                'The Core runtime snapshot is unavailable', true, context)
        end
        local snapshot, snapshotError = api.Runtime.getSnapshot()
        if not snapshot then return nil, snapshotError end
        local instanceId = snapshot.instanceId or snapshot.instance_id
        if type(instanceId) ~= 'string' or #instanceId < 8 or #instanceId > 128 then
            return failure('CORE_UNAVAILABLE',
                'The Core runtime instance identity is invalid', true, context)
        end
        local token, tokenError = nextId('entity_authority', context)
        if not token then return nil, tokenError end
        local authority = {
            instanceId = instanceId,
            leaseSeconds = config.authorityLeaseSeconds,
            resourceEpoch = api.ownerEpoch,
            serverScope = config.serverScope,
            token = token,
        }
        setAuthority(authority)
        extensionRegistry.beginOwner(resourceName, api.ownerEpoch)
        local reconciled, reconciliationError = authorityRepository.reconcileBootAuthority(
            authority.serverScope,
            authority,
            context
        )
        if not reconciled then
            setAuthority(nil)
            return nil, reconciliationError
        end
        if reconciled.conflicts > 0 then
            foundation.setHealth('DEGRADED', 'CLUSTER_LEASE_CONFLICT')
            observability.increment('authority_lease_conflicts', {}, reconciled.conflicts)
        elseif reconciled.remaining > 0 then
            foundation.setHealth('DEGRADED', 'AUTHORITY_RECONCILIATION_BACKLOG')
        end
        observeReconciliation(reconciled, context)
        return { authority = authority, reconciliation = reconciled }
    end
    function service.authoritySnapshot()
        local authority = getAuthority()
        if not authority then return { state = 'UNINITIALIZED' } end
        return {
            instanceId = authority.instanceId,
            leaseSeconds = authority.leaseSeconds,
            resourceEpoch = authority.resourceEpoch,
            serverScope = authority.serverScope,
            state = 'ACTIVE',
        }
    end

    -- Internal server composition port. It is not published through
    -- synex.entities@1 or bound to a contract.
    function service.currentAuthority()
        return getAuthority()
    end

    function service.materialize(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(invokingResource, 5, context, false)
        if not allowed then return nil, rateError end
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        return idempotent('entity.materialize', request, context, function()
            local definition, definitionError = findDefinition(request.target, context)
            if not definition then return nil, definitionError end
            local laneKey = lanes.entityKey(definition.entityId)
            return lanes.with(laneKey, 'materialize', context, function()
                local bucketReference, bucketError = validation.validateBucketReference(
                    request.spawnContext.bucket.bucket,
                    request.spawnContext.bucket.generation,
                    true
                )
                if not bucketReference then return nil, bucketError end
                local bucket, resolvedError = entityRuntime.resolveBucket(
                    bucketReference.id,
                    bucketReference.generation,
                    invokingResource,
                    true
                )
                if not bucket then return nil, resolvedError end
                local admissionCandidate = normalizeDefinition(
                    definition, bucketReference, nil)
                local hookValue, hookError = observability.before('synex.entities.before_entity_spawn',
                    { caller = invokingResource, request = request }, context)
                if not hookValue then return nil, hookError end
                return spawnAdmission.withReservation(
                    invokingResource, admissionCandidate, context, function()
                local claimed, claimError = authorityRepository.claimMaterialization(
                    definition.entityId,
                    invokingResource,
                    current,
                    request.spawnContext.recoveryMode == 'automatic',
                    context
                )
                if not claimed then return nil, claimError end
                if claimed.generation ~= definition.generation then
                    observability.increment('entity_generation_changes', {}, 1)
                end
                local binding, bindingError = authorityRepository.bindingFor(
                    definition.entityId,
                    context
                )
                if bindingError then return nil, bindingError end
                local normalized = normalizeDefinition(claimed.definition, bucketReference, binding)
                local record, inspection = activateReserved(normalized, {
                    entityId = definition.entityId,
                    generation = claimed.generation,
                    leaseGeneration = claimed.leaseGeneration,
                    version = claimed.version,
                }, invokingResource, context,
                    request.spawnContext.recoveryMode == 'automatic')
                if not record then return nil, inspection end
                return {
                    entity = registry.entityRef(record),
                    materialized = true,
                    netId = record.netId,
                    networkOwner = inspection.networkOwner,
                }
                end)
            end)
        end)
        end)
    end

    function service.dematerialize(request, context)
        local invokingResource, callerError = caller(context)
        if not invokingResource then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(invokingResource, 4, context, false)
        if not allowed then return nil, rateError end
        return foundation.withOwnerEpoch(invokingResource, context, function()
        return idempotent('entity.dematerialize', request, context, function()
            local entityRef, refError = validation.validateEntityRef(request.entity)
            if not entityRef then return nil, refError end
            return lanes.with(lanes.entityKey(entityRef.entityId),
                'dematerialize', context, function()
                local record, resolveError = entityRuntime.resolveOwned(
                    entityRef, invokingResource, context
                )
                if not record then return nil, resolveError end
                if not record.persistent then
                    return failure('INVALID_ARGUMENT',
                        'Temporary entities cannot be dematerialized', false, context)
                end
                local checkpointId
                if request.policy == 'checkpoint' then
                    local checkpoint, checkpointError = checkpointRecord(
                        record, invokingResource, request.reasonCode, nil, context
                    )
                    if not checkpoint then return nil, checkpointError end
                    checkpointId = checkpoint.checkpointId
                end
                local version = record.version
                local deleted, deleteError = entityRuntime.delete(record, nil, 'dematerialize')
                if not deleted then return nil, deleteError end
                local released, releaseError = authorityRepository.release(
                    record.entityId,
                    record.generation,
                    version,
                    getAuthority(),
                    'dormant',
                    request.reasonCode,
                    context
                )
                if not released then
                    foundation.setHealth('DEGRADED',
                        'A dematerialized entity could not release its persistence lease')
                    return nil, releaseError
                end
                observability.event('synex.entities.dematerialized', {
                    entityId = record.entityId,
                    generation = record.generation,
                    resourceOwner = record.resourceOwner,
                }, context)
                observability.audit('entities.dematerialized', 'entity', record.entityId, {
                    generation = record.generation,
                    policy = request.policy,
                    reasonCode = request.reasonCode,
                }, context)
                return {
                    checkpointId = checkpointId,
                    dematerialized = true,
                    entity = entityRef,
                    status = 'DORMANT',
                }
            end)
        end)
        end)
    end

    function service.heartbeat(context)
        local current = getAuthority()
        if not current or current.invalid == true then
            local initialized, initializationError = service.initialize(context)
            if not initialized then return nil, initializationError end
            return { reinitialized = true, renewed = 0 }
        end
        local renewed, renewError = authorityRepository.heartbeat(current, context)
        if not renewed then return nil, renewError end
        observability.gauge('entity_authority_leases', {}, renewed.renewed)
        local managed = {}
        for _, record in ipairs(registry.all()) do
            if record.persistent and record.authorityLeaseGeneration ~= nil then
                managed[#managed + 1] = record
            end
        end
        if renewed.renewed ~= #managed then
            current.invalid = true
            setAuthority(nil)
            local detached, failed = 0, 0
            for _, record in ipairs(managed) do
                local removed, removeError = entityRuntime.delete(record)
                if removed then
                    detached = detached + 1
                else
                    failed = failed + 1
                    entityRuntime.queueCleanup(record,
                        'entity.cleanup_after_authority_loss', removeError, context)
                end
            end
            foundation.setHealth('DEGRADED', 'AUTHORITY_LEASE_CONFLICT')
            observability.increment('authority_lease_conflicts', {}, 1)
            observability.gauge('managed_entity_count', {}, registry.count())
            local _, conflictError = failure('AUTHORITY_LEASE_CONFLICT',
                'The runtime authority lease set no longer matches managed entities',
                true, context)
            conflictError.details = {
                detached = detached,
                expected = #managed,
                failed = failed,
                renewed = renewed.renewed,
            }
            return nil, conflictError
        end
        return renewed
    end

    function service.releaseAuthority(reasonCode, context)
        local authority = getAuthority()
        if not authority then return { released = 0 } end
        local released, releaseError = authorityRepository.releaseAuthority(
            authority,
            reasonCode or 'synex.entities.resource_stop',
            context
        )
        setAuthority(nil)
        return released, releaseError
    end

    function service.recoverOne(definition, context)
        local finish = observability.timer()
        local values = table.pack(xpcall(function()
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        return lanes.with(lanes.entityKey(definition.entityId),
            'recover', context, function()
            local startedAt = tonumber(getGameTimer()) or 0
            local hookValue, hookError = observability.before(
                'synex.entities.before_entity_recovery',
                { entityId = definition.entityId, generation = definition.generation },
                context
            )
            if not hookValue then return nil, hookError end
            local recoveryBucket = { id = 0, generation = 0 }
            local admissionCandidate = normalizeDefinition(
                definition, recoveryBucket, nil)
            return spawnAdmission.withReservation(
                definition.resourceOwner, admissionCandidate, context, function()
            local claimed, claimError = authorityRepository.claimMaterialization(
                definition.entityId,
                definition.resourceOwner,
                current,
                true,
                context
            )
            if not claimed then return nil, claimError end
            if claimed.generation ~= definition.generation then
                observability.increment('entity_generation_changes', {}, 1)
            end
            local binding = authorityRepository.bindingFor(definition.entityId, context)
            local normalized = normalizeDefinition(claimed.definition, {
                -- Dynamic bucket generations are intentionally not durable.
                -- Recovery returns to the safe default world unless a caller
                -- explicitly materializes into a current managed bucket.
                id = 0,
                generation = 0,
            }, binding)
            local record, inspection = activateReserved(normalized, {
                entityId = definition.entityId,
                generation = claimed.generation,
                leaseGeneration = claimed.leaseGeneration,
                version = claimed.version,
            }, definition.resourceOwner, context, true)
            local durationMs = recoveryDuration(startedAt)
            if not record then
                local recorded, recordError = authorityRepository.recordRecoveryFailure(
                    definition.entityId,
                    claimed.generation,
                    current,
                    recoveryFailureCode(inspection),
                    recoveryPolicy(durationMs),
                    context
                )
                if not recorded then return nil, recordError end
                return nil, inspection
            end
            local recorded, recordError = authorityRepository.recordRecoverySuccess(
                definition.entityId,
                claimed.generation,
                current,
                durationMs,
                context
            )
            if not recorded then
                local deleted, deleteError = entityRuntime.delete(
                    record, nil, 'activation_failed')
                if not deleted then
                    entityRuntime.queueCleanup(record,
                        'entity.cleanup_after_recovery_commit_failure',
                        deleteError, context)
                end
                authorityRepository.recordRecoveryFailure(
                    definition.entityId, claimed.generation, current,
                    recoveryFailureCode(recordError), recoveryPolicy(durationMs), context)
                return nil, recordError
            end
            local updated, updateError = registry.update(
                record.entityId, record.generation, { version = recorded.version })
            if not updated then return nil, updateError end
            observability.event('synex.entities.recovered', {
                entityId = record.entityId,
                generation = record.generation,
                resourceOwner = record.resourceOwner,
            }, context)
            observability.audit('entities.recovered', 'entity', record.entityId, {
                generation = record.generation,
                resourceOwner = record.resourceOwner,
            }, context)
            observability.increment('entity_recovered_total', {
                entityType = record.entityType,
            }, 1)
            observability.gauge('entity_live_total', {}, registry.count())
            return true
            end)
        end)
        end, debug.traceback))
        local ok, value, operationError = values[1], values[2], values[3]
        local code = ok and type(operationError) == 'table'
            and operationError.code or ok and 'OK' or 'INTERNAL_ERROR'
        if type(code) ~= 'string' or #code < 2 or #code > 64
            or code:match('^[A-Z][A-Z0-9_]*$') == nil then code = 'UNKNOWN' end
        local entityType = type(definition) == 'table' and definition.entityType or nil
        if entityType ~= 'vehicle' and entityType ~= 'ped'
            and entityType ~= 'object' then entityType = 'unknown' end
        finish('entity_recovery_duration_ms', {
            code = code,
            entityType = entityType,
            result = ok and value ~= nil and 'success' or 'failure',
        })
        if not ok then error(value, 0) end
        return value, operationError
    end

    function service.runRecovery(context)
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        local reconciled, reconciliationError = authorityRepository.reconcileBootAuthority(
            current.serverScope, current, context)
        if not reconciled then return nil, reconciliationError end
        observeReconciliation(reconciled, context)
        observability.gauge('authority_reconciliation_backlog', {},
            reconciled.remaining or 0)
        observability.increment('authority_reconciled_total', {},
            reconciled.reconciled or 0)
        if (reconciled.remaining or 0) > 0 then
            foundation.setHealth('DEGRADED', 'AUTHORITY_RECONCILIATION_BACKLOG')
        elseif health and health.reason == 'AUTHORITY_RECONCILIATION_BACKLOG' then
            foundation.setHealth('READY', 'Entity authority reconciliation is current')
        end
        local retention, retentionError = authorityRepository.purgeRecoveryHistory(
            math.min(config.recoveryBatchSize, 100), context)
        if not retention then return nil, retentionError end
        observability.increment('entity_recovery_history_purged_total', {},
            retention.purged or 0)
        observability.gauge('entity_recovery_history_backlog', {},
            retention.remaining or 0)
        local rows, listError = authorityRepository.listRecoverable(
            current.serverScope,
            nil,
            nil,
            config.recoveryBatchSize,
            context
        )
        if not rows then return nil, listError end
        local recovered, failed = 0, 0
        for _, row in ipairs(rows) do
            local definition = authorityRepository.definition(row)
            local ok, recoveryError = service.recoverOne(definition, context)
            if ok then
                recovered = recovered + 1
            else
                failed = failed + 1
                local failureCode = type(recoveryError) == 'table'
                    and recoveryError.code or 'UNKNOWN'
                observability.increment('entity_recovery_failed_total', {
                    code = failureCode,
                }, 1)
                observability.audit('entities.recovery_failed', 'entity',
                    definition.entityId, { code = failureCode,
                        generation = definition.generation }, context)
            end
        end
        observability.gauge('entity_recovery_backlog', {}, math.max(0, #rows - recovered))
        if failed >= config.recoveryStormThreshold then
            foundation.setHealth('DEGRADED', 'RECOVERY_STORM')
        end
        return {
            attempted = #rows,
            failed = failed,
            purged = retention.purged or 0,
            reconciled = reconciled.reconciled or 0,
            reconciliationRemaining = reconciled.remaining or 0,
            recovered = recovered,
            retentionRemaining = retention.remaining or 0,
        }
    end

    function service.reconcileMissingRuntime(entityIds, context)
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        if type(entityIds) ~= 'table' or #entityIds > config.driftScanLimit then
            return failure('INVALID_ARGUMENT',
                'The drift reconciliation batch is invalid', false, context)
        end
        local report = { conflicted = 0, orphaned = 0, released = 0, skipped = 0 }
        for _, entityId in ipairs(entityIds) do
            local definition, definitionError = authorityRepository.getById(entityId, context)
            if not definition then return nil, definitionError end
            if definition.status ~= 'active' or registry.byEntityId(entityId) then
                report.skipped = report.skipped + 1
            else
                local released, releaseError = lanes.with(
                    lanes.entityKey(entityId),
                    'drift_reconcile',
                    context,
                    function()
                        if registry.byEntityId(entityId) then return 'skipped' end
                        return authorityRepository.release(
                            definition.entityId,
                            definition.generation,
                            definition.version,
                            current,
                            definition.recoveryPolicy == 'automatic'
                                and 'orphaned' or 'dormant',
                            'synex.entities.drift_runtime_missing',
                            context
                        )
                    end
                )
                if released == 'skipped' then
                    report.skipped = report.skipped + 1
                elseif not released then
                    report.conflicted = report.conflicted + 1
                    report.lastError = type(releaseError) == 'table'
                        and releaseError.code or 'CONCURRENT_MODIFICATION'
                else
                    report.released = report.released + 1
                    if definition.recoveryPolicy == 'automatic' then
                        report.orphaned = report.orphaned + 1
                        observability.lifecycle('orphaned', definition,
                            'synex.entities.drift_runtime_missing', context)
                        observability.increment('entity_orphaned_total', {}, 1)
                    end
                end
            end
        end
        return report
    end

    function service.cleanupResourceOwner(ownerResource, ownerCycle, context)
        local current, authorityError = requireAuthority(context)
        if not current then return nil, authorityError end
        local report = { dormant = 0, failed = 0, removed = 0, skipped = 0 }
        for _, record in ipairs(registry.forResource(ownerResource)) do
            if ownerCycle ~= nil and record.resourceCycle ~= ownerCycle then
                report.skipped = report.skipped + 1
            else
                local cleaned, cleanupError = lanes.with(
                    lanes.entityKey(record.entityId),
                    'resource_cleanup',
                    context,
                    function()
                        local version = record.version
                        local removed, removeError = entityRuntime.delete(record, nil, 'resource_stop')
                        if not removed then return nil, removeError end
                        if not record.persistent then
                            observability.lifecycle('deleted', record,
                                'synex.entities.resource_stopped', context)
                            return 'removed'
                        end
                        local released, releaseError = authorityRepository.release(
                            record.entityId,
                            record.generation,
                            version,
                            current,
                            'dormant',
                            'synex.entities.resource_stopped',
                            context
                        )
                        if not released then return nil, releaseError end
                        observability.lifecycle('dematerialized', record,
                            'synex.entities.resource_stopped', context)
                        return 'dormant'
                    end
                )
                if not cleaned then
                    report.failed = report.failed + 1
                    if registry.byEntityId(record.entityId) == record then
                        entityRuntime.queueCleanup(record,
                            'entity.cleanup_after_resource_stop', cleanupError, context)
                    end
                    foundation.setHealth('DEGRADED', 'ENTITY_RESOURCE_LEAK')
                    observability.increment('entity_delete_failures', {
                        lifecycle = 'resource_stop',
                    }, 1)
                    report.lastError = type(cleanupError) == 'table'
                        and cleanupError.code or 'DELETE_FAILED'
                elseif cleaned == 'dormant' then
                    report.dormant = report.dormant + 1
                else
                    report.removed = report.removed + 1
                    observability.increment('entity_delete_total', {
                        lifecycle = 'resource_stop',
                    }, 1)
                end
            end
        end
        return report
    end

    function service.prepareStop(context)
        local owners, seen = {}, {}
        for _, record in ipairs(registry.all()) do
            if not seen[record.resourceOwner] then
                seen[record.resourceOwner] = true
                owners[#owners + 1] = record.resourceOwner
            end
        end
        table.sort(owners)
        local report = { dormant = 0, failed = 0, removed = 0 }
        for _, ownerResource in ipairs(owners) do
            local ownerReport, cleanupError = service.cleanupResourceOwner(
                ownerResource,
                nil,
                context
            )
            if not ownerReport then return nil, cleanupError end
            report.dormant = report.dormant + ownerReport.dormant
            report.failed = report.failed + ownerReport.failed
            report.removed = report.removed + ownerReport.removed
        end
        return report
    end

    function service.entityRemoved(handle, context)
        local record = registry.byHandle(handle)
        if not record then return false end
        if record.deletionRequested then return false end
        local inspection = entityRuntime.inspect(record)
        if inspection then return false end
        local removed, removeError = registry.remove(record.entityId, record.generation)
        if not removed then return nil, removeError end
        local cleaned, cleanupError = extensionOperations.cleanupEntity(
            record.entityId, record.generation, 'entity_removed', context)
        if not cleaned then return nil, cleanupError end
        if record.persistent then
            local orphaned = record.recoveryPolicy == 'automatic'
            local released, releaseError = authorityRepository.release(
                record.entityId,
                record.generation,
                record.version,
                getAuthority(),
                orphaned and 'orphaned' or 'dormant',
                'synex.entities.runtime_removed',
                context
            )
            if not released then
                foundation.setHealth('DEGRADED',
                    'A removed persistent entity lost its authority fence')
                return nil, releaseError
            end
            observability.lifecycle(orphaned and 'orphaned' or 'dematerialized',
                record, 'synex.entities.runtime_removed', context)
            if orphaned then observability.increment('entity_orphaned_total', {}, 1) end
        end
        return true
    end

    return service
end
