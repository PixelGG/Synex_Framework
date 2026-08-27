SynexEntityDiagnosticsAnalyzer = {}

local MATERIALIZED = { active = true, recovering = true, spawning = true }

function SynexEntityDiagnosticsAnalyzer.create(options)
    assert(type(options) == 'table', 'entity diagnostics analyzer options are required')
    local config = assert(options.config, 'entity diagnostics config is required')
    local entityRuntime = assert(options.entityRuntime, 'entity diagnostics runtime is required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity diagnostics extension registry is required')
    local foundation = assert(options.foundation, 'entity diagnostics foundation is required')
    local ports = assert(options.ports, 'entity diagnostics ports are required')
    local registry = assert(options.registry, 'entity diagnostics registry is required')
    local state = assert(options.state, 'entity diagnostics state is required')
    local analyzer = {}

    local function appendBounded(target, finding, limit)
        if #target >= limit then return false end
        target[#target + 1] = finding
        return true
    end

    local function observedConvar(name, fallback, context)
        if not foundation.isCallable(ports.getConvar) then return fallback end
        local observed, value = foundation.protect('entities.diagnostic.convar',
            function() return ports.getConvar(name, fallback) end, context)
        return observed and type(value) == 'string' and #value <= 256
            and value or fallback
    end

    local function schemaMismatches(rows, kind, limit)
        local findings = {}
        for _, row in ipairs(rows or {}) do
            local namespace = kind == 'component'
                and row.component_namespace or row.state_key
            local definition = kind == 'component'
                and extensionRegistry.getComponentSchema(namespace)
                or extensionRegistry.getStateSchema(namespace)
            local storedVersion = tonumber(row.schema_version)
            local registeredVersion = type(definition) == 'table'
                and tonumber(definition.schemaVersion) or nil
            local registeredOwner = type(definition) == 'table'
                and definition.ownerResource or nil
            if not definition or registeredVersion ~= storedVersion
                or registeredOwner ~= row.owner_resource then
                appendBounded(findings, {
                    code = not definition and string.upper(kind) .. '_SCHEMA_NOT_REGISTERED'
                        or string.upper(kind) .. '_SCHEMA_MISMATCH',
                    entityId = row.entity_id,
                    namespace = namespace,
                    ownerResource = row.owner_resource,
                    registeredOwner = registeredOwner,
                    registeredVersion = registeredVersion,
                    storedVersion = storedVersion,
                }, limit)
            end
        end
        return findings
    end

    function analyzer.runtimeEntityIds(limit)
        local records = registry.all()
        local ids = {}
        for _, record in ipairs(records) do
            if record.persistent == true then
                ids[#ids + 1] = record.entityId
                if #ids >= limit + 1 then break end
            end
        end
        return ids
    end

    function analyzer.analyze(snapshot, limit, context)
        local staleMappings, generationMismatches, netIdMismatches = {}, {}, {}
        local orphaned, resourceLeaks, bucketLeaks = {}, {}, {}
        local runtimeOrphans, bucketOwnerConflicts = {}, {}
        local bucketConflictSeen = {}
        local function bucketConflict(key, finding)
            if bucketConflictSeen[key] then return end
            bucketConflictSeen[key] = true
            appendBounded(bucketOwnerConflicts, finding, limit)
        end
        local knownRuntime = {}
        for _, row in ipairs(snapshot.knownRuntimeEntities or {}) do
            knownRuntime[row.entity_id] = true
        end

        for _, definition in ipairs(snapshot.definitions or {}) do
            local expectedGeneration = tonumber(definition.generation)
            local record = registry.byEntityId(definition.entity_id)
            if record and record.generation ~= expectedGeneration then
                appendBounded(generationMismatches, {
                    code = 'GENERATION_MISMATCH', entityId = definition.entity_id,
                    persistedGeneration = expectedGeneration,
                    runtimeGeneration = record.generation,
                }, limit)
            elseif MATERIALIZED[definition.status] then
                local runtime = record and entityRuntime.inspect(record) or nil
                if not runtime then
                    appendBounded(staleMappings, {
                        code = record and 'STALE_RUNTIME_MAPPING'
                            or 'MISSING_RUNTIME_MAPPING',
                        entityId = definition.entity_id,
                        generation = expectedGeneration,
                        status = definition.status,
                    }, limit)
                end
                if record then
                    local observed, runtimeIdentity = foundation.protect(
                        'entities.diagnostic.net_id',
                        function()
                            if not ports.doesEntityExist(record.handle) then
                                return { exists = false }
                            end
                            return { exists = true,
                                netId = ports.networkGetNetworkIdFromEntity(record.handle) }
                        end,
                        context)
                    if not observed or runtimeIdentity.exists
                        and runtimeIdentity.netId ~= record.netId then
                        appendBounded(netIdMismatches, {
                            code = observed and 'NET_ID_MISMATCH'
                                or 'NET_ID_INSPECTION_FAILED',
                            entityId = record.entityId,
                            expectedNetId = record.netId,
                            observedNetId = observed and runtimeIdentity.netId or nil,
                        }, limit)
                    end
                end
            elseif definition.status == 'orphaned' or definition.status == 'dormant'
                or definition.status == 'failed' then
                appendBounded(orphaned, {
                    entityId = definition.entity_id,
                    status = definition.status,
                }, limit)
            end
            local stateOk, resourceState = foundation.protect(
                'entities.diagnostic.resource_state',
                function() return ports.getResourceState(definition.resource_owner) end,
                context)
            local transient = definition.persistence_policy == 'temporary'
                or definition.persistence_policy == 'session'
            if (not stateOk or resourceState ~= 'started')
                and (MATERIALIZED[definition.status] or transient) then
                appendBounded(resourceLeaks, {
                    entityId = definition.entity_id,
                    resourceOwner = definition.resource_owner,
                    state = stateOk and resourceState or 'unknown',
                }, limit)
            end
            local bucket = tonumber(definition.bucket_id) or 0
            if bucket > 0 and not state.buckets[bucket] then
                appendBounded(bucketLeaks, {
                    bucket = bucket, entityId = definition.entity_id,
                }, limit)
            end
        end

        local runtimeRecords = registry.all()
        local persistentRuntimeRecords = {}
        for _, entityId in ipairs(snapshot.sampledRuntimeEntityIds or {}) do
            local record = registry.byEntityId(entityId)
            if record and record.persistent == true then
                persistentRuntimeRecords[#persistentRuntimeRecords + 1] = record
            end
        end
        for _, record in ipairs(persistentRuntimeRecords) do
            if not knownRuntime[record.entityId] then
                appendBounded(runtimeOrphans, {
                    code = 'RUNTIME_WITHOUT_PERSISTENT_DEFINITION',
                    entityId = record.entityId, generation = record.generation,
                    netId = record.netId,
                }, limit)
            end
        end
        for index = 1, math.min(#runtimeRecords, limit + 1) do
            local record = runtimeRecords[index]
            local bucket = record.bucket > 0 and state.buckets[record.bucket] or nil
            if bucket and bucket.resourceOwner ~= record.resourceOwner then
                bucketConflict('entity:' .. record.entityId .. ':' .. tostring(record.bucket), {
                    bucket = record.bucket, code = 'ENTITY_BUCKET_OWNER_CONFLICT',
                    entityId = record.entityId,
                    bucketOwner = bucket.resourceOwner,
                    entityOwner = record.resourceOwner,
                })
            end
        end
        local bucketEntityChecks = 0
        for bucketId, bucket in pairs(state.buckets) do
            if bucketEntityChecks >= limit + 1 then break end
            for entityId in pairs(bucket.entities or {}) do
                bucketEntityChecks = bucketEntityChecks + 1
                local record = registry.byEntityId(entityId)
                if not record or record.bucket ~= bucketId
                    or record.resourceOwner ~= bucket.resourceOwner then
                    bucketConflict('entity:' .. entityId .. ':' .. tostring(bucketId), {
                        bucket = bucketId,
                        code = not record and 'STALE_BUCKET_ENTITY_MEMBERSHIP'
                            or 'ENTITY_BUCKET_OWNER_CONFLICT',
                        entityId = entityId,
                        bucketOwner = bucket.resourceOwner,
                        entityOwner = record and record.resourceOwner or nil,
                    })
                end
                if bucketEntityChecks >= limit + 1 then break end
            end
        end
        local bucketPlayerChecks = 0
        for source, membership in pairs(state.playerMemberships or {}) do
            bucketPlayerChecks = bucketPlayerChecks + 1
            local bucket = state.buckets[membership.bucket]
            if not bucket or bucket.resourceOwner ~= membership.resourceOwner then
                bucketConflict('player:' .. tostring(source), {
                    bucket = membership.bucket,
                    code = not bucket and 'STALE_PLAYER_BUCKET_MEMBERSHIP'
                        or 'PLAYER_BUCKET_OWNER_CONFLICT',
                    source = source,
                    bucketOwner = bucket and bucket.resourceOwner or nil,
                    membershipOwner = membership.resourceOwner,
                })
            end
            if bucketPlayerChecks >= limit + 1 then break end
        end

        local componentSchemaMismatches = schemaMismatches(
            snapshot.componentSchemas, 'component', limit)
        local stateSchemaMismatches = schemaMismatches(
            snapshot.stateSchemas, 'state', limit)
        local counts = snapshot.counts or {}
        local definitions = tonumber(counts.definitions) or 0
        local pressure = config.maxEntities > 0 and definitions / config.maxEntities or 1
        local spawnOutcomes = tonumber(counts.spawn_outcomes) or 0
        local failedSpawns = tonumber(counts.failed_spawns) or 0
        local spawnFailureRate = {
            basis = 'current_terminal_materialization_state',
            failures = failedSpawns,
            observations = spawnOutcomes,
            rate = spawnOutcomes > 0 and failedSpawns / spawnOutcomes or 0,
        }
        local globalPolicy = {
            entityLockdown = observedConvar('sv_entityLockdown', '', context),
            filterRequestControl = observedConvar('sv_filterRequestControl', '', context),
            onesync = observedConvar('onesync', 'off', context),
            stateBagStrictMode = observedConvar('sv_stateBagStrictMode', '', context),
        }
        local recommendations = {}
        if globalPolicy.onesync ~= 'on' then
            recommendations[#recommendations + 1] = {
                code = 'ONESYNC_REQUIRED',
                message = "OneSync must be 'on' for synex_entities.",
            }
        end
        if globalPolicy.stateBagStrictMode == '' then
            recommendations[#recommendations + 1] = {
                code = 'STATE_BAG_POLICY_UNOBSERVED',
                message = 'Review state-bag policy before replicated entity state.',
            }
        end
        local categories = {
            bucketLeaks, bucketOwnerConflicts, componentSchemaMismatches,
            snapshot.duplicateBindings or {}, snapshot.duplicatePersistentKeys or {},
            generationMismatches, snapshot.invalidOwners or {},
            snapshot.leaseConflicts or {}, netIdMismatches, orphaned,
            snapshot.recovery or {}, resourceLeaks, runtimeOrphans,
            snapshot.staleBindings or {}, staleMappings, stateSchemaMismatches,
        }
        local hasFindings = pressure >= 0.9 or failedSpawns > 0
        for _, findings in ipairs(categories) do
            if #findings > 0 then hasFindings = true break end
        end
        return {
            bucketLeaks = bucketLeaks,
            bucketInspectionTruncated = bucketEntityChecks > limit
                or bucketPlayerChecks > limit,
            bucketOwnerConflicts = bucketOwnerConflicts,
            componentSchemaMismatches = componentSchemaMismatches,
            counts = {
                activeBindings = tonumber(counts.active_bindings) or 0,
                checkpoints = tonumber(counts.checkpoints) or 0,
                components = tonumber(counts.components) or 0,
                definitions = definitions,
                entityCapacity = config.maxEntities,
                entityPressure = pressure,
                liveLeases = tonumber(counts.live_leases) or 0,
                recoveryHistory = tonumber(counts.recovery_history) or 0,
                states = tonumber(counts.states) or 0,
                tags = tonumber(counts.tags) or 0,
            },
            duplicateBindings = snapshot.duplicateBindings,
            duplicatePersistentKeys = snapshot.duplicatePersistentKeys,
            generationMismatches = generationMismatches,
            globalPolicy = globalPolicy,
            invalidOwners = snapshot.invalidOwners,
            leaseConflicts = snapshot.leaseConflicts,
            netIdMismatches = netIdMismatches,
            nextCursor = snapshot.nextAfterEntityId,
            orphaned = orphaned,
            recovery = snapshot.recovery,
            recommendations = recommendations,
            resourceLeaks = resourceLeaks,
            runtimeOrphans = runtimeOrphans,
            schemaInspectionTruncated = snapshot.schemaInspectionTruncated == true,
            spawnFailureRate = spawnFailureRate,
            staleBindings = snapshot.staleBindings,
            staleMappings = staleMappings,
            stateSchemaMismatches = stateSchemaMismatches,
            status = hasFindings and 'DEGRADED' or 'READY',
            truncated = snapshot.truncated == true or #persistentRuntimeRecords > limit,
        }
    end

    return analyzer
end
