SynexEntityService = {}

function SynexEntityService.create(options)
    assert(type(options) == 'table', 'entity service options are required')
    local resourceName = assert(options.resourceName, 'entity service resourceName is required')
    local validation = assert(options.validation, 'entity service validation is required')
    local foundation = assert(options.foundation, 'entity service foundation is required')
    local repository = assert(options.repository, 'entity service repository is required')
    local registry = assert(options.registry, 'entity service registry is required')
    local entityRuntime = assert(options.entityRuntime, 'entity service runtime is required')
    local entityOperations = assert(options.entityOperations, 'entity operations are required')
    local bucketOperations = assert(options.bucketOperations, 'bucket operations are required')
    local authorityOperations = assert(options.authorityOperations,
        'entity authority operations are required')
    local extensionOperations = assert(options.extensionOperations,
        'entity extension operations are required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity extension registry is required')
    local queryOperations = assert(options.queryOperations,
        'entity query operations are required')
    local lanes = assert(options.lanes, 'entity mutation lanes are required')
    local observability = assert(options.observability,
        'entity observability is required')
    local publicErrors = assert(options.publicErrors,
        'entity public error boundary is required')
    local cleanupQueue = assert(options.cleanupQueue,
        'entity cleanup queue is required')
    local state = assert(options.state, 'entity service state is required')
    local ports = assert(options.ports, 'entity service ports are required')
    local config = assert(options.config, 'entity service config is required')
    local health = assert(options.health, 'entity service health is required')
    local coreRef = assert(options.coreRef, 'entity service coreRef is required')
    local playerBucketFence = SynexEntityPlayerBucketFence.create({
        coreRef = coreRef, foundation = foundation, ports = ports,
        state = state, validation = validation,
    })
    local securityReporting = SynexEntitySecurityReporting.create({
        coreRef = coreRef, foundation = foundation, resourceName = resourceName,
    })
    local buckets = state.buckets
    local playerMemberships = state.playerMemberships
    local service = {}
    local driftSqlBatchLimit = math.min(config.driftScanLimit, 512)
    local lastDrift = {
        state = 'not_run',
    }
    local driftPersistenceCursor = ''
    local driftRuntimeCursor = ''
    local function emitRuntimeGauges(componentCount)
        local bucketEntities, bucketPlayers = 0, 0
        for _, bucket in pairs(buckets) do
            bucketEntities = bucketEntities + foundation.tableCount(bucket.entities)
            bucketPlayers = bucketPlayers + foundation.tableCount(bucket.players)
        end
        observability.gauge('entity_live_total', {}, registry.count())
        observability.gauge('bucket_live_total', {}, foundation.tableCount(buckets))
        observability.gauge('bucket_entity_count', {}, bucketEntities)
        observability.gauge('bucket_player_count', {}, bucketPlayers)
        if componentCount ~= nil then
            observability.gauge('entity_component_count', {}, componentCount)
        end
    end
    local function auditDeniedAccess(contractName, operationError, context)
        if type(operationError) ~= 'table' then return end
        if operationError.code == 'AUTHORITY_LEASE_CONFLICT' then
            observability.increment('authority_lease_conflicts', {}, 1)
        end
        local action = ({
            FOREIGN_BUCKET = 'foreign_resource_access',
            FOREIGN_RESOURCE_OWNER = 'foreign_resource_access',
            STALE_ENTITY = 'stale_entity_access',
        })[operationError.code]
        if action then
            observability.audit('entities.' .. action, 'contract', contractName,
                { code = operationError.code }, context)
        end
        -- Entity authority has already failed closed. Security is an optional,
        -- fail-open observer and can never authorize this operation.
        securityReporting.reportDenial(contractName, operationError, context)
    end
    function service.healthSnapshot()
        return {
            status = ({ READY = 'HEALTHY', STARTING = 'INFO', DEGRADED = 'DEGRADED',
                UNHEALTHY = 'ERROR', STOPPING = 'UNAVAILABLE' })[health.state]
                or 'UNAVAILABLE',
            buckets = foundation.tableCount(buckets),
            entities = registry.count(),
            onesync = health.onesync,
            persistence = health.persistence,
            reason = health.reason,
            service = health.service,
            controlProvider = health.controlProvider or 'UNREGISTERED',
            state = health.state,
            drift = lastDrift,
            cleanup = cleanupQueue.snapshot(10),
            authority = authorityOperations.authoritySnapshot(),
            extensionRegistries = extensionRegistry.snapshot(),
            mutationLanes = lanes.snapshot(10),
        }
    end

    function service.getHealth(_, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then
            return nil, callerError
        end
        local allowed, rateError = foundation.takeRateLimit(caller, 1, context, true)
        if not allowed then
            return nil, rateError
        end
        return service.healthSnapshot()
    end

    function service.getPlayerBucketFence(request, context)
        return playerBucketFence.resolve(request, context)
    end

    function service.getControlSummary(request, context)
        if type(request) ~= 'table' or next(request) ~= nil then
            return foundation.failure('INVALID_ARGUMENT', 'Control summary request must be an empty object', false, context)
        end
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(caller, 2, context, true)
        if not allowed then return nil, rateError end

        local persistent, persistentError = repository.getPersistentSummary(context)
        if not persistent then return nil, persistentError end
        local runtime = {
            total = registry.count(),
            persistent = 0,
            temporary = 0,
        }
        for _, record in ipairs(registry.all()) do
            if record.persistent then runtime.persistent = runtime.persistent + 1
            else runtime.temporary = runtime.temporary + 1 end
        end
        return {
            health = service.healthSnapshot(),
            buckets = foundation.tableCount(buckets),
            runtime = runtime,
            persistent = persistent,
            drift = lastDrift,
            authority = authorityOperations.authoritySnapshot(),
            extensionRegistries = extensionRegistry.snapshot(),
            mutationLanes = lanes.snapshot(25),
            metrics = observability.snapshot(),
        }
    end

    function service.handlers(definitions)
        local publicError = publicErrors.compile(definitions)
        local durationMetrics = {
            ['synex.entities.checkpoint'] = 'entity_checkpoint_duration_ms',
            ['synex.entities.delete'] = 'entity_delete_duration_ms',
            ['synex.entities.dematerialize'] = 'entity_dematerialize_duration_ms',
            ['synex.entities.materialize'] = 'entity_materialize_duration_ms',
            ['synex.entities.spawn'] = 'entity_spawn_duration_ms',
        }
        local handlers = {
            ['synex.entities.bucket.create'] = bucketOperations.create,
            ['synex.entities.bucket.destroy'] = bucketOperations.destroy,
            ['synex.entities.bucket.get'] = queryOperations.bucketGet,
            ['synex.entities.bucket.move_entity'] = bucketOperations.moveEntity,
            ['synex.entities.bucket.move_player'] = bucketOperations.movePlayer,
            ['synex.entities.binding.get'] = authorityOperations.bindingGet,
            ['synex.entities.checkpoint'] = authorityOperations.checkpoint,
            ['synex.entities.context.validate'] = queryOperations.contextValidate,
            ['synex.entities.delete'] = authorityOperations.delete,
            ['synex.entities.dematerialize'] = authorityOperations.dematerialize,
            ['synex.entities.get'] = entityOperations.get,
            ['synex.entities.health'] = service.getHealth,
            ['synex.entities.materialize'] = authorityOperations.materialize,
            ['synex.entities.owner.set'] = authorityOperations.ownerSet,
            ['synex.entities.query.by_binding'] = queryOperations.byBinding,
            ['synex.entities.query.by_bucket'] = queryOperations.byBucket,
            ['synex.entities.query.by_net_id'] = queryOperations.byNetId,
            ['synex.entities.query.by_owner'] = queryOperations.byOwner,
            ['synex.entities.query.by_resource'] = queryOperations.byResource,
            ['synex.entities.query.nearby'] = queryOperations.nearby,
            ['synex.entities.resolve_persistent'] = entityOperations.resolvePersistent,
            ['synex.entities.spawn'] = authorityOperations.spawn,
        }
        for name, handler in pairs(extensionOperations.handlers()) do
            if handlers[name] then
                error(('duplicate entity handler: %s'):format(name), 0)
            end
            handlers[name] = handler
        end
        local guarded = {}
        for name, handler in pairs(handlers) do
            local contractName = name
            local contractHandler = handler
            guarded[contractName] = function(request, context)
                local metricName = durationMetrics[contractName]
                local finish = metricName and observability.timer() or nil
                local ok, value, operationError = xpcall(function()
                    return contractHandler(request, context)
                end, debug.traceback)
                if ok and value == nil then
                    auditDeniedAccess(contractName, operationError, context)
                    operationError = publicError(contractName, operationError, context)
                end
                if finish then
                    local code = ok and type(operationError) == 'table'
                        and operationError.code or ok and 'OK' or 'INTERNAL_ERROR'
                    if type(code) ~= 'string' or #code < 2 or #code > 64
                        or code:match('^[A-Z][A-Z0-9_]*$') == nil then code = 'UNKNOWN' end
                    local entityType = type(request) == 'table'
                        and request.entityType or nil
                    if entityType ~= 'vehicle' and entityType ~= 'ped'
                        and entityType ~= 'object' then entityType = 'unknown' end
                    local labels = {
                        code = code,
                        entityType = entityType,
                        result = ok and value ~= nil and 'success' or 'failure',
                    }
                    local elapsed = finish(metricName, labels)
                    if contractName == 'synex.entities.spawn' then
                        observability.observe('entity_spawn_duration', labels, elapsed)
                    end
                end
                local componentCount
                if ok and value ~= nil and (contractName == 'synex.entities.component.set'
                    or contractName == 'synex.entities.component.remove') then
                    componentCount = extensionOperations.componentCount(context)
                end
                emitRuntimeGauges(componentCount)
                if not ok then
                    foundation.reportUnexpected('contract.' .. contractName, value, context)
                    error(value, 0)
                end
                return value, operationError
            end
        end
        return guarded
    end

    function service.runDriftDetection()
        local scanAfter = driftPersistenceCursor
        local rows, queryError = repository.listForDrift(scanAfter, config.driftScanLimit + 1)
        if not rows then return nil, queryError end
        local wrapped = false
        if #rows == 0 and scanAfter ~= '' then
            scanAfter = ''
            wrapped = true
            rows, queryError = repository.listForDrift(scanAfter, config.driftScanLimit + 1)
            if not rows then return nil, queryError end
        end

        local truncated = #rows > config.driftScanLimit
        local databaseById = {}
        local orphanIds, orphanSeen = {}, {}
        local databaseWithoutRuntime = 0
        local inactiveOwners = {}
        local scanCount = math.min(#rows, config.driftScanLimit)
        local runtimeAll = registry.all()
        local runtimeBeforeScan = {}
        local runtimeStarted = driftRuntimeCursor == ''
        local runtimeTruncated = false
        for _, record in ipairs(runtimeAll) do
            if not runtimeStarted and record.entityId > driftRuntimeCursor then
                runtimeStarted = true
            end
            if runtimeStarted then
                if #runtimeBeforeScan >= config.driftScanLimit then
                    runtimeTruncated = true
                    break
                end
                runtimeBeforeScan[#runtimeBeforeScan + 1] = record
            end
        end
        if #runtimeBeforeScan == 0 and driftRuntimeCursor ~= '' then
            driftRuntimeCursor = ''
            for index = 1, math.min(#runtimeAll, config.driftScanLimit) do
                runtimeBeforeScan[index] = runtimeAll[index]
            end
            runtimeTruncated = #runtimeAll > #runtimeBeforeScan
        end
        if runtimeTruncated and #runtimeBeforeScan > 0 then
            driftRuntimeCursor = runtimeBeforeScan[#runtimeBeforeScan].entityId
        else
            driftRuntimeCursor = ''
        end
        local runtimeById = {}
        for _, record in ipairs(runtimeBeforeScan) do runtimeById[record.entityId] = record end
        local function markOrphan(entityId)
            if not orphanSeen[entityId] then
                orphanSeen[entityId] = true
                orphanIds[#orphanIds + 1] = entityId
            end
        end

        for index = 1, scanCount do
            local row = rows[index]
            databaseById[row.entity_id] = row
            local runtimeRecord = runtimeById[row.entity_id]
            if not runtimeRecord and row.status == 'active' then
                databaseWithoutRuntime = databaseWithoutRuntime + 1
                markOrphan(row.entity_id)
            end
            if row.status == 'active' and not foundation.isResourceActive(row.resource_owner) then
                inactiveOwners[row.resource_owner] = (inactiveOwners[row.resource_owner] or 0) + 1
                markOrphan(row.entity_id)
            end
        end

        if truncated then
            driftPersistenceCursor = rows[scanCount].entity_id
        else
            driftPersistenceCursor = ''
        end

        local persistentRuntimeIds = {}
        for _, record in ipairs(runtimeBeforeScan) do
            if record.persistent then persistentRuntimeIds[#persistentRuntimeIds + 1] = record.entityId end
        end
        for first = 1, #persistentRuntimeIds, driftSqlBatchLimit do
            local batch = {}
            for index = first, math.min(#persistentRuntimeIds, first + driftSqlBatchLimit - 1) do
                batch[#batch + 1] = persistentRuntimeIds[index]
            end
            local persistedRows, persistedError = repository.findForDriftByIds(batch)
            if not persistedRows then return nil, persistedError end
            for _, row in ipairs(persistedRows) do databaseById[row.entity_id] = row end
        end

        local runtimeWithoutPersistence = 0
        local staleMappings = 0
        local duplicatePersistentKeys = 0
        local persistentKeys = {}
        local generationMismatches = 0
        local invalidNetMappings = 0
        local wrongBuckets = 0
        local wrongModels = 0
        local wrongOwners = 0
        local wrongBindings = 0
        local wrongResourceOwners = 0
        local wrongTypes = 0
        local generationMismatchIds = {}
        local missingPersistenceIds = {}
        for _, record in ipairs(runtimeBeforeScan) do
            if record.persistent then
                local persisted = databaseById[record.entityId]
                if not persisted then
                    runtimeWithoutPersistence = runtimeWithoutPersistence + 1
                    missingPersistenceIds[record.entityId] = true
                elseif persisted and tonumber(persisted.generation) ~= record.generation then
                    generationMismatches = generationMismatches + 1
                    generationMismatchIds[record.entityId] = true
                    markOrphan(record.entityId)
                end
                if persisted then
                    if persisted.entity_type and persisted.entity_type ~= record.entityType then
                        wrongTypes = wrongTypes + 1
                    end
                    if persisted.model and tonumber(persisted.model) ~= record.model then
                        wrongModels = wrongModels + 1
                    end
                    if tonumber(persisted.bucket_id) ~= record.bucket then
                        wrongBuckets = wrongBuckets + 1
                    end
                    if persisted.resource_owner ~= record.resourceOwner then
                        wrongResourceOwners = wrongResourceOwners + 1
                    end
                    if not record.owner or persisted.owner_type ~= record.owner.type
                        or persisted.owner_id ~= record.owner.id then
                        wrongOwners = wrongOwners + 1
                    end
                    local storedHasBinding = persisted.binding_namespace ~= nil
                        or persisted.binding_ref ~= nil
                    local runtimeHasBinding = record.binding ~= nil
                    if storedHasBinding ~= runtimeHasBinding
                        or storedHasBinding and (
                            persisted.binding_namespace ~= record.binding.namespace
                            or persisted.binding_ref ~= record.binding.ref) then
                        wrongBindings = wrongBindings + 1
                    end
                end
                if record.persistentKey then
                    local persistentIdentity = record.resourceOwner .. ':' .. record.persistentKey
                    if persistentKeys[persistentIdentity] then
                        duplicatePersistentKeys = duplicatePersistentKeys + 1
                    else
                        persistentKeys[persistentIdentity] = true
                    end
                end
            end
            if registry.byNetId(record.netId) ~= record then
                invalidNetMappings = invalidNetMappings + 1
            end
            local forceDetach = generationMismatchIds[record.entityId]
                or missingPersistenceIds[record.entityId]
            local resolved = registry.resolve(record.entityId, record.generation)
            local verifiedRuntime = resolved and entityRuntime.inspect(record)
            local inspection = not forceDetach and verifiedRuntime
            if not inspection and not forceDetach then
                staleMappings = staleMappings + 1
            end
            if not inspection then
                -- A native handle may already have been recycled. Only alter its
                -- orphan mode after the runtime identity inspection succeeded.
                if record.persistent and verifiedRuntime then
                    foundation.protect('drift.set_orphan_mode', function()
                        ports.setEntityOrphanMode(record.handle, 2)
                    end)
                end
                if record.bucket > 0 and buckets[record.bucket] then
                    buckets[record.bucket].entities[record.entityId] = nil
                end
                registry.remove(record.entityId, record.generation)
                if record.persistent and databaseById[record.entityId] then
                    markOrphan(record.entityId)
                end
            end
        end

        local repaired = 0
        for first = 1, #orphanIds, driftSqlBatchLimit do
            local batch = {}
            for index = first, math.min(#orphanIds, first + driftSqlBatchLimit - 1) do
                batch[#batch + 1] = orphanIds[index]
            end
            local reconciliation, repairError = authorityOperations.reconcileMissingRuntime(
                batch,
                {
                    caller = resourceName,
                    callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
                    traceId = 'entity_drift_reconcile',
                }
            )
            if not reconciliation then return nil, repairError end
            repaired = repaired + reconciliation.released
        end
        local inactiveOwnerCount = foundation.tableCount(inactiveOwners)
        local anomalies = databaseWithoutRuntime + runtimeWithoutPersistence
            + staleMappings + generationMismatches + duplicatePersistentKeys + inactiveOwnerCount
            + invalidNetMappings + wrongBindings + wrongBuckets + wrongModels + wrongOwners
            + wrongResourceOwners + wrongTypes
        local previousDrift = lastDrift
        lastDrift = {
            state = anomalies > 0 and 'drift_detected' or 'consistent',
            checkedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            scannedPersistence = scanCount,
            scannedRuntime = #runtimeBeforeScan,
            runtimeTruncated = runtimeTruncated,
            truncated = truncated,
            scanCycleComplete = not truncated and not runtimeTruncated,
            wrapped = wrapped,
            databaseWithoutRuntime = databaseWithoutRuntime,
            runtimeWithoutPersistence = runtimeWithoutPersistence,
            staleMappings = staleMappings,
            generationMismatches = generationMismatches,
            invalidNetMappings = invalidNetMappings,
            duplicatePersistentKeys = duplicatePersistentKeys,
            wrongBindings = wrongBindings,
            wrongBuckets = wrongBuckets,
            wrongModels = wrongModels,
            wrongOwners = wrongOwners,
            wrongResourceOwners = wrongResourceOwners,
            wrongTypes = wrongTypes,
            inactiveOwners = inactiveOwnerCount,
            orphaned = repaired,
        }
        observability.gauge('drift_findings', {}, anomalies)
        observability.gauge('managed_entity_count', {}, registry.count())
        observability.gauge('orphan_count', {}, #orphanIds)
        local componentCount = extensionOperations.componentCount(context)
        emitRuntimeGauges(componentCount)

        if anomalies > 0 then
            foundation.setHealth('DEGRADED', 'DRIFT_DETECTED')
            local api = coreRef.value
            local changed = previousDrift.state ~= lastDrift.state
                or previousDrift.databaseWithoutRuntime ~= databaseWithoutRuntime
                or previousDrift.runtimeWithoutPersistence ~= runtimeWithoutPersistence
                or previousDrift.staleMappings ~= staleMappings
                or previousDrift.generationMismatches ~= generationMismatches
                or previousDrift.invalidNetMappings ~= invalidNetMappings
                or previousDrift.duplicatePersistentKeys ~= duplicatePersistentKeys
                or previousDrift.wrongBindings ~= wrongBindings
                or previousDrift.wrongBuckets ~= wrongBuckets
                or previousDrift.wrongModels ~= wrongModels
                or previousDrift.wrongOwners ~= wrongOwners
                or previousDrift.wrongResourceOwners ~= wrongResourceOwners
                or previousDrift.wrongTypes ~= wrongTypes
                or previousDrift.inactiveOwners ~= inactiveOwnerCount
            if changed and api and api.Audit and foundation.isCallable(api.Audit.append) then
                local invoked, auditResult = foundation.protect('drift.audit', function()
                    return api.Audit.append({
                        action = 'entities.drift_detected',
                        targetType = 'resource',
                        targetId = resourceName,
                        context = lastDrift,
                    })
                end)
                lastDrift.audit = invoked and auditResult and 'recorded' or 'unavailable'
            else
                lastDrift.audit = changed and 'unavailable' or 'unchanged'
            end
        elseif health.state == 'DEGRADED'
            and health.reason == 'DRIFT_DETECTED' then
            foundation.setHealth('READY', 'Entity foundation is ready')
        end
        return lastDrift
    end

    function service.cleanupOwner(owner, resourceCycle)
        local ownedBuckets = {}
        for _, bucket in pairs(buckets) do
            if bucket.resourceOwner == owner
                and (resourceCycle == nil or bucket.resourceCycle == resourceCycle) then
                ownedBuckets[#ownedBuckets + 1] = bucket
            end
        end
        for _, bucket in ipairs(ownedBuckets) do
            local destroyed, destroyError = bucketOperations.destroyRecord(
                bucket,
                ports.getGameTimer() + config.bucketCleanupTimeoutMs,
                {
                    caller = owner,
                    callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
                    traceId = 'entity_owner_bucket_cleanup',
                }
            )
            if not destroyed then
                foundation.setHealth('DEGRADED', destroyError.message)
            end
        end

        local context = {
            caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
            traceId = 'entity_owner_cleanup',
        }
        local result, cleanupError = authorityOperations.cleanupResourceOwner(
            owner, resourceCycle, context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
        return result, cleanupError
    end

    function service.playerDropped(playerSource)
        local result, operationError = bucketOperations.playerDropped(playerSource, {
            caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
            traceId = 'player_bucket_disconnect',
        })
        emitRuntimeGauges()
        return result, operationError
    end

    function service.entityBucketChanged(entityHandle, bucketId, oldBucketId)
        local result, operationError = bucketOperations.observeEntityBucketChange(entityHandle, bucketId, {
            caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
            traceId = 'entity_bucket_native_event',
        })
        emitRuntimeGauges()
        return result, operationError
    end

    function service.playerBucketChanged(playerSource, bucketId, oldBucketId)
        local result, operationError = bucketOperations.observePlayerBucketChange(playerSource, bucketId, {
            caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
            traceId = 'player_bucket_native_event',
        })
        emitRuntimeGauges()
        return result, operationError
    end

    function service.expireBuckets(context)
        local result, operationError = bucketOperations.expire(context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
        return result, operationError
    end

    function service.stop()
        local context = {
            caller = resourceName,
            callerEpoch = coreRef.value and coreRef.value.ownerEpoch or 0,
            traceId = 'entity_resource_stop',
        }
        local managedBuckets = {}
        for _, bucket in pairs(buckets) do
            managedBuckets[#managedBuckets + 1] = bucket
        end
        table.sort(managedBuckets, function(left, right) return left.id < right.id end)
        for _, bucket in ipairs(managedBuckets) do
            local destroyed, destroyError = bucketOperations.destroyRecord(
                bucket,
                ports.getGameTimer() + config.bucketCleanupTimeoutMs,
                context
            )
            if not destroyed then
                foundation.setHealth('DEGRADED', type(destroyError) == 'table'
                    and destroyError.code or 'BUCKET_RESOURCE_LEAK')
            end
        end
        local prepared, prepareError = authorityOperations.prepareStop(context)
        if not prepared then
            foundation.setHealth('DEGRADED', type(prepareError) == 'table'
                and prepareError.code or 'ENTITY_RESOURCE_LEAK')
        end
        for playerSource, membership in pairs(playerMemberships) do
            if ports.getPlayerName(tostring(playerSource))
                and ports.getPlayerRoutingBucket(playerSource) == membership.bucket then
                foundation.protect('stop.return_player_to_default', function()
                    ports.setPlayerRoutingBucket(playerSource, 0)
                end)
            end
            playerMemberships[playerSource] = nil
        end
        for bucketId in pairs(buckets) do
            foundation.protect('stop.reset_bucket_policy', function()
                ports.setRoutingBucketPopulationEnabled(bucketId, true)
                ports.setRoutingBucketEntityLockdownMode(bucketId, 'inactive')
            end)
        end
        cleanupQueue.process(context)
        authorityOperations.releaseAuthority('synex.entities.resource_stop', context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
    end

    function service.initializeAuthority(context)
        return authorityOperations.initialize(context)
    end

    function service.heartbeatAuthority(context)
        local result, heartbeatError = authorityOperations.heartbeat(context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
        return result, heartbeatError
    end

    function service.runRecovery(context)
        cleanupQueue.process(context)
        local result, recoveryError = authorityOperations.runRecovery(context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
        return result, recoveryError
    end

    function service.entityRemoved(entityHandle, context)
        local result, removalError = authorityOperations.entityRemoved(entityHandle, context)
        emitRuntimeGauges(extensionOperations.componentCount(context))
        return result, removalError
    end

    function service.cleanupExtensions(owner, ownerEpoch)
        local removed = extensionOperations.cleanupOwner(owner, ownerEpoch)
        emitRuntimeGauges(extensionOperations.componentCount({
            traceId = 'entity_extension_cleanup',
        }))
        return removed
    end

    function service.inspectEntity(request, context)
        return queryOperations.inspectEntity(request, context)
    end

    function service.queryByOwner(request, context)
        return queryOperations.byOwner(request, context)
    end

    function service.queryByResource(request, context)
        return queryOperations.byResource(request, context)
    end

    function service.queryByBucket(request, context)
        return queryOperations.byBucket(request, context)
    end

    function service.getDiagnosticSnapshot(request, context)
        local snapshot, diagnosticError = queryOperations.diagnosticSnapshot(
            request, authorityOperations.authoritySnapshot(), context)
        if not snapshot then return nil, diagnosticError end
        snapshot.cleanup = cleanupQueue.snapshot(50)
        if snapshot.cleanup.count > 0 then snapshot.status = 'DEGRADED' end
        emitRuntimeGauges(snapshot.counts and snapshot.counts.components or nil)
        return snapshot
    end

    return service
end
