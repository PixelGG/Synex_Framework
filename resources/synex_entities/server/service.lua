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
    local state = assert(options.state, 'entity service state is required')
    local ports = assert(options.ports, 'entity service ports are required')
    local config = assert(options.config, 'entity service config is required')
    local health = assert(options.health, 'entity service health is required')
    local coreRef = assert(options.coreRef, 'entity service coreRef is required')
    local buckets = state.buckets
    local playerMemberships = state.playerMemberships
    local service = {}
    local driftSqlBatchLimit = math.min(config.driftScanLimit, 512)
    local lastDrift = {
        state = 'not_run',
    }
    local driftPersistenceCursor = ''

    function service.healthSnapshot()
        return {
            buckets = foundation.tableCount(buckets),
            entities = registry.count(),
            onesync = health.onesync,
            persistence = health.persistence,
            reason = health.reason,
            service = health.service,
            state = health.state,
            drift = lastDrift,
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
        }
    end

    function service.handlers()
        local handlers = {
            ['synex.entities.bucket.create'] = bucketOperations.create,
            ['synex.entities.bucket.destroy'] = bucketOperations.destroy,
            ['synex.entities.bucket.move_entity'] = bucketOperations.moveEntity,
            ['synex.entities.bucket.move_player'] = bucketOperations.movePlayer,
            ['synex.entities.delete'] = entityOperations.delete,
            ['synex.entities.get'] = entityOperations.get,
            ['synex.entities.health'] = service.getHealth,
            ['synex.entities.resolve_persistent'] = entityOperations.resolvePersistent,
            ['synex.entities.spawn'] = entityOperations.spawn,
        }
        local guarded = {}
        for name, handler in pairs(handlers) do
            local contractName = name
            local contractHandler = handler
            guarded[contractName] = function(request, context)
                local ok, value, operationError = xpcall(function()
                    return contractHandler(request, context)
                end, debug.traceback)
                if not ok then
                    foundation.reportUnexpected('contract.' .. contractName, value, context)
                    error(value, 0)
                end
                return value, operationError
            end
        end
        return guarded
    end

    function service.rehydratePersistentEntities()
        local reconciled, reconcileError = repository.reconcileDeleting()
        if reconciled == nil then
            return nil, reconcileError
        end
        local rows, queryError = repository.listForRehydrate(config.rehydrateLimit + 1)
        if not rows then
            return nil, queryError
        end

        local limited = #rows > config.rehydrateLimit
        for index = 1, math.min(#rows, config.rehydrateLimit) do
            local row = rows[index]
            local spawnRequest = {
                bucket = 0,
                bucketGeneration = 0,
                entityType = row.entity_type,
                heading = tonumber(row.heading),
                model = tonumber(row.model),
                owner = { id = row.owner_id, type = row.owner_type },
                persistent = true,
                persistentKey = row.persistent_key,
                position = {
                    x = tonumber(row.position_x),
                    y = tonumber(row.position_y),
                    z = tonumber(row.position_z),
                },
            }
            if row.entity_type == 'vehicle' then
                spawnRequest.vehicleType = row.vehicle_type
            elseif row.entity_type == 'ped' then
                spawnRequest.pedType = row.ped_type and tonumber(row.ped_type) or nil
            elseif row.entity_type == 'object' then
                spawnRequest.doorFlag = row.door_flag == 1 or row.door_flag == true
            end
            local normalized, validationError = validation.validateSpawn(spawnRequest)
            if normalized then
                normalized.version = tonumber(row.version)
                local generation = (tonumber(row.generation) or 0) + 1
                local record = entityRuntime.create(
                    normalized,
                    row.entity_id,
                    generation,
                    row.resource_owner
                )
                if record then
                    local updated = repository.markRehydrated(
                        row.entity_id,
                        generation,
                        tonumber(row.version)
                    )
                    if updated == 1 then
                        record.version = tonumber(row.version) + 1
                    else
                        entityRuntime.delete(record)
                        foundation.setHealth(
                            'DEGRADED',
                            'A persistent entity changed during rehydration'
                        )
                    end
                else
                    foundation.setHealth(
                        'DEGRADED',
                        'A persistent entity could not be rehydrated'
                    )
                end
            else
                foundation.setHealth('DEGRADED', validationError.message)
            end
            if index % 25 == 0 then
                ports.wait(config.waitStepMs)
            end
        end

        if limited then
            foundation.setHealth('DEGRADED', 'Persistent entity rehydration limit reached')
        end
        return true
    end

    function service.getCharacterLifecycleSummary(characterId, context)
        local persistent, persistentError = repository.getCharacterOwnerSummary(characterId, context)
        if not persistent then return nil, persistentError end
        local runtime = registry.forLogicalOwner('character', characterId)
        local summary = {
            persistent = persistent.total,
            runtime = #runtime,
            runtimePersistent = 0,
            runtimeTemporary = 0,
        }
        for _, record in ipairs(runtime) do
            if record.persistent then summary.runtimePersistent = summary.runtimePersistent + 1
            else summary.runtimeTemporary = summary.runtimeTemporary + 1 end
        end
        return summary
    end

    local function deleteTemporaryCharacterEntities(characterId)
        for _, record in ipairs(registry.forLogicalOwner('character', characterId)) do
            if not record.persistent then
                local removed, removeError = entityRuntime.delete(record)
                if not removed then
                    return nil, removeError
                end
            end
        end
        return true
    end

    function service.unloadCharacter(characterId)
        return deleteTemporaryCharacterEntities(characterId)
    end

    function service.applyCharacterDeletion(characterId, retainedOwnerId, context)
        local updated, updateError = repository.retainCharacterEntities(
            characterId,
            retainedOwnerId,
            context
        )
        if updated == nil then return nil, updateError end

        for _, record in ipairs(registry.forLogicalOwner('character', characterId)) do
            if record.persistent then
                record.owner = { type = 'system', id = retainedOwnerId }
                record.orphaning = true
                foundation.protect('character.set_durable_orphan_mode', function()
                    ports.setEntityOrphanMode(record.handle, 2)
                end, context)
                record.orphaning = false
                record.version = record.version + 1
            else
                local removed, removeError = entityRuntime.delete(record)
                if not removed then return nil, removeError end
            end
        end
        return { retained = updated }, nil
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
        local runtimeBeforeScan = registry.all()
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
                if record.persistentKey then
                    if persistentKeys[record.persistentKey] then
                        duplicatePersistentKeys = duplicatePersistentKeys + 1
                    else
                        persistentKeys[record.persistentKey] = true
                    end
                end
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
            local affected, repairError = repository.markDriftOrphans(batch)
            if affected == nil then return nil, repairError end
            repaired = repaired + affected
        end
        local inactiveOwnerCount = foundation.tableCount(inactiveOwners)
        local anomalies = databaseWithoutRuntime + runtimeWithoutPersistence
            + staleMappings + generationMismatches + duplicatePersistentKeys + inactiveOwnerCount
        local previousDrift = lastDrift
        lastDrift = {
            state = anomalies > 0 and 'drift_detected' or 'consistent',
            checkedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            scannedPersistence = scanCount,
            scannedRuntime = #runtimeBeforeScan,
            truncated = truncated,
            scanCycleComplete = not truncated,
            wrapped = wrapped,
            databaseWithoutRuntime = databaseWithoutRuntime,
            runtimeWithoutPersistence = runtimeWithoutPersistence,
            staleMappings = staleMappings,
            generationMismatches = generationMismatches,
            duplicatePersistentKeys = duplicatePersistentKeys,
            inactiveOwners = inactiveOwnerCount,
            orphaned = repaired,
        }

        if anomalies > 0 then
            foundation.setHealth('DEGRADED', 'Entity ownership or runtime drift was detected')
            local api = coreRef.value
            local changed = previousDrift.state ~= lastDrift.state
                or previousDrift.databaseWithoutRuntime ~= databaseWithoutRuntime
                or previousDrift.runtimeWithoutPersistence ~= runtimeWithoutPersistence
                or previousDrift.staleMappings ~= staleMappings
                or previousDrift.generationMismatches ~= generationMismatches
                or previousDrift.duplicatePersistentKeys ~= duplicatePersistentKeys
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
            and health.reason == 'Entity ownership or runtime drift was detected' then
            foundation.setHealth('READY', 'Entity foundation is ready')
        end
        return lastDrift
    end

    function service.cleanupOwner(owner, resourceCycle)
        local records = registry.forOwner(owner)
        local durableCleanup = {}
        local ownedBuckets = {}
        for _, bucket in pairs(buckets) do
            if bucket.resourceOwner == owner
                and (resourceCycle == nil or bucket.resourceCycle == resourceCycle) then
                ownedBuckets[#ownedBuckets + 1] = bucket
            end
        end
        for _, bucket in ipairs(ownedBuckets) do
            local destroyed, destroyError = bucketOperations.destroyRecord(bucket, false)
            if not destroyed then
                foundation.setHealth('DEGRADED', destroyError.message)
            end
        end

        for _, record in ipairs(records) do
            if (resourceCycle == nil or record.resourceCycle == resourceCycle) and record.persistent then
                record.resourceCycle = nil
                record.orphaning = true
                foundation.protect('entity.set_durable_orphan_mode', function()
                    ports.setEntityOrphanMode(record.handle, 2)
                end)
                if owner ~= resourceName then
                    durableCleanup[#durableCleanup + 1] = record
                else
                    record.orphaning = false
                end
            elseif (resourceCycle == nil or record.resourceCycle == resourceCycle)
                and not record.persistent then
                local inspection = entityRuntime.inspect(record)
                if inspection then
                    foundation.protect('entity.delete_owner_temporary', function()
                        ports.deleteEntity(record.handle)
                    end)
                end
                registry.remove(record.entityId, record.generation)
            end
        end

        if #durableCleanup > 0 then
            ports.createThread(function()
                local completed = foundation.protect('owner.persist_orphaned', function()
                    local updated = repository.markOrphaned(durableCleanup)
                    if updated == #durableCleanup then
                        for _, record in ipairs(durableCleanup) do
                            record.version = record.version + 1
                            record.orphaning = false
                        end
                    else
                        foundation.setHealth(
                            'DEGRADED',
                            'Persistent owner cleanup did not update every entity'
                        )
                    end
                end)
                if not completed then
                    foundation.setHealth(
                        'DEGRADED',
                        'Persistent owner cleanup failed unexpectedly'
                    )
                end
            end)
        end
    end

    function service.playerDropped(playerSource)
        local membership = playerMemberships[playerSource]
        if membership and buckets[membership.bucket] then
            buckets[membership.bucket].players[playerSource] = nil
        end
        playerMemberships[playerSource] = nil
    end

    function service.stop()
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
        for _, record in ipairs(registry.all()) do
            if ports.doesEntityExist(record.handle) then
                foundation.protect('stop.delete_entity', function()
                    ports.deleteEntity(record.handle)
                end)
            end
        end
    end

    return service
end
