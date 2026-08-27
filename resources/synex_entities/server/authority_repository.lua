SynexEntityAuthorityRepository = {}

local ENTITY_SELECT = [[SELECT `entity_id`, `generation`, `persistent_key`, `entity_type`,
    `vehicle_type`, `model`, `position_x`, `position_y`, `position_z`, `heading`,
    `ped_type`, `door_flag`, `owner_type`, `owner_id`, `resource_owner`, `bucket_id`,
    `persistence_policy`, `recovery_policy`, `server_scope`, `status`, `version`,
    `archetype_namespace`, `archetype_schema_version`, `archetype_descriptor_json`,
    `recovery_attempt_count`, `recovery_window_started_at`, `recovery_circuit_state`,
    `last_recovery_failure_code`, `next_recovery_at`, DATE_FORMAT(COALESCE(
        `next_recovery_at`, CAST('1000-01-01 00:00:00.000000' AS DATETIME(6))),
        '%Y-%m-%d %H:%i:%s.%f') AS `recovery_due_at`,
    `last_reason_code`, `last_trace_id`, `last_materialized_at`,
    `last_checkpoint_at`, `created_at`, `updated_at`, `deleted_at`
    FROM `synex_entities`]]

function SynexEntityAuthorityRepository.create(options)
    assert(type(options) == 'table', 'entity authority repository options are required')
    local database = assert(options.database, 'entity authority repository database is required')
    local foundation = assert(options.foundation, 'entity authority repository foundation is required')
    local health = assert(options.health, 'entity authority repository health is required')
    local repository = {}

    local function safeTrace(context)
        local traceId = type(context) == 'table' and context.traceId or nil
        if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 128
            or traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return 'entity_trace'
        end
        return traceId
    end

    local function boundedInteger(value, minimum, maximum)
        return type(value) == 'number' and value % 1 == 0
            and value >= minimum and value <= maximum
    end

    local function safeReason(value)
        return type(value) == 'string' and #value >= 3 and #value <= 128
            and value:match('^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$') ~= nil
    end

    local function invalid(message, context)
        return foundation.failure('INVALID_ARGUMENT', message, false, context)
    end

    local ownerTypes = {
        character = true, group = true, resource = true, system = true, user = true,
    }

    local function validateOwner(ownerType, ownerId, context)
        if not ownerTypes[ownerType] or type(ownerId) ~= 'string'
            or #ownerId < 1 or #ownerId > 64 then
            return invalid('The logical owner identity is invalid', context)
        end
        return true
    end

    local function validateAuthority(authority, context)
        if type(authority) ~= 'table'
            or type(authority.serverScope) ~= 'string' or #authority.serverScope < 1
            or #authority.serverScope > 64
            or authority.serverScope:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or type(authority.instanceId) ~= 'string' or #authority.instanceId < 3
            or #authority.instanceId > 96
            or authority.instanceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or type(authority.token) ~= 'string' or #authority.token < 8
            or #authority.token > 96
            or authority.token:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or not boundedInteger(authority.resourceEpoch, 1, 9007199254740991)
            or not boundedInteger(authority.leaseSeconds, 1, 3600) then
            return invalid('The runtime authority fence is invalid', context)
        end
        return true
    end

    local recoveryHistoryRetentionSeconds = options.recoveryHistoryRetentionSeconds or 604800
    assert(boundedInteger(recoveryHistoryRetentionSeconds, 60, 31536000),
        'entity recovery history retention must be between 60 seconds and one year')
    local bootReconcileLimit = options.bootReconcileLimit or 128
    assert(boundedInteger(bootReconcileLimit, 1, 512),
        'entity boot reconciliation limit must be between 1 and 512')

    local function operationFailure(caught, context)
        health.persistence = 'UNAVAILABLE'
        if type(caught) == 'table' and type(caught.code) == 'string' then
            caught.traceId = safeTrace(context)
            return nil, caught
        end
        foundation.reportUnexpected('authority.repository', caught, context)
        return foundation.failure(
            'PERSISTENCE_UNAVAILABLE',
            'Entity persistence is unavailable',
            true,
            context
        )
    end

    local function atomic(operation, context, handler)
        local ok, value = pcall(database.maintenance, operation, handler, {
            maximumRows = 512,
            maximumResultBytes = 2097152,
            maximumResponseBytes = 1048576,
            maximumStatements = 256,
            timeoutMs = 15000,
        })
        if not ok then return operationFailure(value, context) end
        health.persistence = 'READY'
        return value
    end

    local function read(statement, parameters, context, maximumRows)
        local ok, rows = pcall(database.query, statement, parameters, {
            maximumRows = maximumRows or 256,
            maximumResultBytes = 2097152,
            timeoutMs = 15000,
        })
        if not ok then return operationFailure(rows, context) end
        if type(rows) ~= 'table' then return operationFailure(rows, context) end
        local maximum, count = 0, 0
        for key, row in pairs(rows) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1
                or type(row) ~= 'table' then
                return operationFailure(rows, context)
            end
            maximum = math.max(maximum, key)
            count = count + 1
        end
        if maximum ~= count then return operationFailure(rows, context) end
        health.persistence = 'READY'
        return rows
    end

    local function definition(row)
        if type(row) ~= 'table' then return nil end
        return {
            archetype = row.archetype_namespace and {
                namespace = row.archetype_namespace,
                schemaVersion = tonumber(row.archetype_schema_version),
                descriptorJson = row.archetype_descriptor_json,
            } or nil,
            bucket = tonumber(row.bucket_id) or 0,
            doorFlag = row.door_flag == 1 or row.door_flag == true,
            entityId = row.entity_id,
            entityType = row.entity_type,
            generation = tonumber(row.generation),
            heading = tonumber(row.heading),
            model = tonumber(row.model),
            owner = { type = row.owner_type, id = row.owner_id },
            pedType = row.ped_type and tonumber(row.ped_type) or nil,
            persistencePolicy = row.persistence_policy,
            persistent = row.persistence_policy == 'persistent'
                or row.persistence_policy == 'owner_lifetime',
            persistentKey = row.persistent_key,
            position = {
                x = tonumber(row.position_x),
                y = tonumber(row.position_y),
                z = tonumber(row.position_z),
            },
            recovery = {
                attempts = tonumber(row.recovery_attempt_count) or 0,
                circuit = row.recovery_circuit_state,
                dueAt = row.recovery_due_at,
                failureCode = row.last_recovery_failure_code,
                nextRetryAt = row.next_recovery_at,
                windowStartedAt = row.recovery_window_started_at,
            },
            recoveryPolicy = row.recovery_policy,
            resourceOwner = row.resource_owner,
            serverScope = row.server_scope,
            status = row.status,
            vehicleType = row.vehicle_type,
            version = tonumber(row.version),
        }
    end

    function repository.reserve(request, entityId, caller, authority, descriptorJson, context)
        local traceId = safeTrace(context)
        local doorFlagValue
        if request.doorFlag ~= nil then doorFlagValue = request.doorFlag and 1 or 0 end
        return atomic('entities.reserve', context, function(transaction)
            local inserted = transaction.update([[INSERT INTO `synex_entities` (
                `entity_id`, `generation`, `persistent_key`, `entity_type`, `vehicle_type`,
                `model`, `position_x`, `position_y`, `position_z`, `heading`, `ped_type`,
                `door_flag`, `owner_type`, `owner_id`, `resource_owner`, `bucket_id`,
                `persistence_policy`, `recovery_policy`, `server_scope`, `status`, `version`,
                `archetype_namespace`, `archetype_schema_version`,
                `archetype_descriptor_json`, `last_reason_code`, `last_trace_id`
            ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                'spawning', 1, ?, ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE `entity_id` = `entity_id`]], {
                entityId, request.persistentKey, request.entityType, request.vehicleType,
                request.model, request.position.x, request.position.y, request.position.z,
                request.heading, request.pedType,
                doorFlagValue,
                request.owner.type, request.owner.id, caller, request.bucket,
                request.persistencePolicy, request.recoveryPolicy, authority.serverScope,
                request.archetype and request.archetype.namespace or nil,
                request.archetype and request.archetype.schemaVersion or nil,
                descriptorJson, request.reasonCode, traceId,
            })
            if inserted ~= 0 and inserted ~= 1 then
                return nil, { code = 'CONFLICT', message = 'Entity reservation conflicted',
                    retryable = false, traceId = traceId }
            end
            local reserved = transaction.one([[SELECT `resource_owner`, `persistent_key`
                FROM `synex_entities` WHERE `entity_id` = ? LIMIT 1 FOR UPDATE]], {
                entityId,
            })
            if not reserved or reserved.resource_owner ~= caller
                or reserved.persistent_key ~= request.persistentKey or inserted == 0 then
                local keyed = request.persistentKey and transaction.one([[SELECT `entity_id`
                    FROM `synex_entities` WHERE `resource_owner` = ? AND `persistent_key` = ?
                    LIMIT 1 FOR UPDATE]], { caller, request.persistentKey }) or nil
                if keyed then
                    return nil, {
                        code = 'ENTITY_ALREADY_MATERIALIZED',
                        message = 'The namespaced persistent key is already reserved',
                        retryable = false,
                        traceId = traceId,
                    }
                end
                return nil, { code = 'CONFLICT', message = 'Entity identity reservation conflicted',
                    retryable = false, traceId = traceId }
            end
            if request.binding then
                local bindingInserted = transaction.update([[INSERT INTO `synex_entity_bindings`
                    (`entity_id`, `binding_namespace`, `binding_ref`, `owner_resource`)
                    VALUES (?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE `binding_id` = `binding_id`]], {
                    entityId, request.binding.namespace, request.binding.ref, caller,
                })
                local bound = transaction.one([[SELECT `entity_id`
                    FROM `synex_entity_bindings`
                    WHERE `binding_namespace` = ? AND `binding_ref` = ?
                        AND `released_at` IS NULL LIMIT 1 FOR UPDATE]], {
                    request.binding.namespace, request.binding.ref,
                })
                if bindingInserted ~= 1 or not bound or bound.entity_id ~= entityId then
                    return nil, { code = 'BINDING_CONFLICT',
                        message = 'The domain binding is already reserved', retryable = false,
                        traceId = traceId }
                end
            end
            local leaseInserted = transaction.update([[INSERT INTO `synex_entity_authority_leases`
                (`entity_id`, `server_scope`, `instance_id`, `authority_token`, `resource_epoch`,
                    `lease_generation`, `lease_state`, `claimed_at`, `heartbeat_at`,
                    `lease_until`, `last_trace_id`, `version`)
                VALUES (?, ?, ?, ?, ?, 1, 'active', CURRENT_TIMESTAMP(6),
                    CURRENT_TIMESTAMP(6), TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)), ?, 1)]], {
                entityId, authority.serverScope, authority.instanceId, authority.token,
                authority.resourceEpoch, authority.leaseSeconds, traceId,
            })
            if leaseInserted ~= 1 then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'Entity authority could not be reserved', retryable = true }
            end
            return {
                entityId = entityId,
                generation = 1,
                leaseGeneration = 1,
                status = 'spawning',
                version = 1,
            }
        end)
    end

    function repository.getById(entityId, context)
        local rows, queryError = read(ENTITY_SELECT .. [[ WHERE `entity_id` = ? LIMIT 1]],
            { entityId }, context, 1)
        if not rows then return nil, queryError end
        if not rows[1] then
            return foundation.failure('ENTITY_NOT_FOUND', 'The entity definition does not exist', false, context)
        end
        return definition(rows[1])
    end

    function repository.getByPersistentKey(caller, key, context)
        local rows, queryError = read(ENTITY_SELECT .. [[
            WHERE `resource_owner` = ? AND `persistent_key` = ? LIMIT 1]],
            { caller, key }, context, 1)
        if not rows then return nil, queryError end
        if not rows[1] then
            return foundation.failure('ENTITY_NOT_FOUND', 'The persistent entity does not exist', false, context)
        end
        return definition(rows[1])
    end

    function repository.getByBinding(namespace, reference, context)
        local rows, queryError = read(ENTITY_SELECT .. [[
            WHERE `entity_id` = (SELECT b.`entity_id` FROM `synex_entity_bindings` b
                WHERE b.`binding_namespace` = ? AND b.`binding_ref` = ?
                    AND b.`released_at` IS NULL LIMIT 1) LIMIT 1]],
            { namespace, reference }, context, 1)
        if not rows then return nil, queryError end
        if not rows[1] then
            return foundation.failure('ENTITY_NOT_FOUND', 'The active entity binding does not exist', false, context)
        end
        return definition(rows[1])
    end

    function repository.bindingFor(entityId, context)
        local rows, queryError = read([[SELECT `binding_namespace`, `binding_ref`,
                `owner_resource`, `version`, `created_at`
            FROM `synex_entity_bindings`
            WHERE `entity_id` = ? AND `released_at` IS NULL LIMIT 1]],
            { entityId }, context, 1)
        if not rows then return nil, queryError end
        if not rows[1] then return nil end
        return {
            namespace = rows[1].binding_namespace,
            ref = rows[1].binding_ref,
            ownerResource = rows[1].owner_resource,
            version = tonumber(rows[1].version),
        }
    end

    local function claimLease(transaction, entityId, authority, traceId)
        local lease = transaction.one([[SELECT `instance_id`, `authority_token`,
                `resource_epoch`, `lease_generation`, `lease_state`, `version`,
                (`lease_state` = 'active' AND `lease_until` > CURRENT_TIMESTAMP(6)) AS `lease_live`
            FROM `synex_entity_authority_leases`
            WHERE `entity_id` = ? FOR UPDATE]], { entityId })
        if lease and tonumber(lease.lease_live) == 1
            and (lease.instance_id ~= authority.instanceId
                or lease.authority_token ~= authority.token
                or tonumber(lease.resource_epoch) ~= authority.resourceEpoch) then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'Another runtime authority holds this entity', retryable = true }
        end
        local generation = lease and tonumber(lease.lease_generation) + 1 or 1
        local affected
        if lease then
            affected = transaction.update([[UPDATE `synex_entity_authority_leases`
                SET `server_scope` = ?, `instance_id` = ?, `authority_token` = ?,
                    `resource_epoch` = ?, `lease_generation` = ?, `lease_state` = 'active',
                    `claimed_at` = CURRENT_TIMESTAMP(6), `heartbeat_at` = CURRENT_TIMESTAMP(6),
                    `lease_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                    `released_at` = NULL, `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `version` = ?]], {
                authority.serverScope, authority.instanceId, authority.token,
                authority.resourceEpoch, generation, authority.leaseSeconds, traceId,
                entityId, tonumber(lease.version),
            })
        else
            affected = transaction.update([[INSERT INTO `synex_entity_authority_leases`
                (`entity_id`, `server_scope`, `instance_id`, `authority_token`, `resource_epoch`,
                    `lease_generation`, `lease_state`, `claimed_at`, `heartbeat_at`,
                    `lease_until`, `last_trace_id`, `version`)
                VALUES (?, ?, ?, ?, ?, 1, 'active', CURRENT_TIMESTAMP(6),
                    CURRENT_TIMESTAMP(6), TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)), ?, 1)]], {
                entityId, authority.serverScope, authority.instanceId, authority.token,
                authority.resourceEpoch, authority.leaseSeconds, traceId,
            })
        end
        if affected ~= 1 then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'Entity authority changed concurrently', retryable = true }
        end
        return generation
    end

    function repository.claimMaterialization(entityId, caller, authority, recovering, context)
        local traceId = safeTrace(context)
        return atomic('entities.claim_materialization', context, function(transaction)
            local row = transaction.one(ENTITY_SELECT .. [[ WHERE `entity_id` = ? FOR UPDATE]], { entityId })
            if not row or row.deleted_at ~= nil then
                return nil, { code = 'ENTITY_NOT_FOUND', message = 'The entity definition does not exist', retryable = false }
            end
            if row.resource_owner ~= caller then
                return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The entity belongs to another resource', retryable = false }
            end
            if row.server_scope ~= authority.serverScope then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The entity belongs to another server scope', retryable = false }
            end
            if row.status == 'active' or row.status == 'spawning' or row.status == 'recovering' then
                return nil, { code = 'ENTITY_ALREADY_MATERIALIZED', message = 'The entity is already materialized or in progress', retryable = true }
            end
            if row.status == 'deleted' or row.status == 'deleting' then
                return nil, { code = 'ENTITY_NOT_FOUND', message = 'The entity lifecycle is terminal', retryable = false }
            end
            if row.recovery_circuit_state == 'paused' and recovering then
                return nil, { code = 'RECOVERY_PAUSED', message = 'Automatic recovery is paused for this entity', retryable = false }
            end
            local leaseGeneration, leaseError = claimLease(transaction, entityId, authority, traceId)
            if not leaseGeneration then return nil, leaseError end
            local generation = tonumber(row.generation) + 1
            local status = recovering and 'recovering' or 'spawning'
            local updated = transaction.update([[UPDATE `synex_entities`
                SET `generation` = ?, `status` = ?, `bucket_id` = 0,
                    `recovery_circuit_state` = CASE WHEN ? = 1
                        THEN 'half_open' ELSE `recovery_circuit_state` END,
                    `last_reason_code` = ?, `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `version` = ? AND `status` = ?]], {
                generation, status, recovering and 1 or 0,
                recovering and 'synex.entities.recovery' or 'synex.entities.materialize',
                traceId, entityId, tonumber(row.version), row.status,
            })
            if updated ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity changed during materialization claim', retryable = true }
            end
            return {
                definition = definition(row),
                generation = generation,
                leaseGeneration = leaseGeneration,
                status = status,
                version = tonumber(row.version) + 1,
            }
        end)
    end

    function repository.activate(entityId, generation, version, leaseGeneration, bucket, authority, context)
        local traceId = safeTrace(context)
        return atomic('entities.activate', context, function(transaction)
            local entity = transaction.one([[SELECT `status`, `recovery_attempt_count`,
                    `version` FROM `synex_entities`
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `deleted_at` IS NULL AND `status` IN ('spawning', 'recovering')
                FOR UPDATE]], { entityId, generation, version })
            if not entity then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Entity activation changed concurrently', retryable = true }
            end
            local lease = transaction.one([[SELECT `lease_generation`, `version`
                FROM `synex_entity_authority_leases`
                WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                    AND `resource_epoch` = ? AND `lease_state` = 'active'
                    AND `lease_generation` = ? AND `lease_until` > CURRENT_TIMESTAMP(6)
                FOR UPDATE]], {
                entityId, authority.instanceId, authority.token, authority.resourceEpoch,
                leaseGeneration,
            })
            if not lease then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The materialization authority lease was lost', retryable = true }
            end
            local recovering = entity.status == 'recovering'
            local affected = transaction.update([[UPDATE `synex_entities`
                SET `status` = 'active', `bucket_id` = ?, `last_materialized_at` = CURRENT_TIMESTAMP(6),
                    `last_reason_code` = 'synex.entities.materialized', `last_trace_id` = ?,
                    `recovery_attempt_count` = CASE WHEN ? = 1
                        THEN `recovery_attempt_count` ELSE 0 END,
                    `recovery_window_started_at` = CASE WHEN ? = 1
                        THEN `recovery_window_started_at` ELSE NULL END,
                    `next_recovery_at` = CASE WHEN ? = 1
                        THEN `next_recovery_at` ELSE NULL END,
                    `recovery_circuit_state` = CASE WHEN ? = 1
                        THEN `recovery_circuit_state` ELSE 'closed' END,
                    `last_recovery_failure_code` = CASE WHEN ? = 1
                        THEN `last_recovery_failure_code` ELSE NULL END,
                    `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `status` = ?]], {
                bucket, traceId, recovering and 1 or 0, recovering and 1 or 0,
                recovering and 1 or 0, recovering and 1 or 0, recovering and 1 or 0,
                entityId, generation, version, entity.status,
            })
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Entity activation changed concurrently', retryable = true }
            end
            return {
                recovering = recovering,
                recoveryAttemptCount = tonumber(entity.recovery_attempt_count) or 0,
                version = version + 1,
            }
        end)
    end

    function repository.moveBucket(entityId, generation, version, leaseGeneration,
        resourceOwner, targetBucket, authority, reasonCode, context)
        if type(entityId) ~= 'string' or #entityId < 8 or #entityId > 64
            or not boundedInteger(generation, 1, 9007199254740991)
            or not boundedInteger(version, 1, 9007199254740991)
            or not boundedInteger(leaseGeneration, 1, 9007199254740991)
            or type(resourceOwner) ~= 'string' or #resourceOwner < 7 or #resourceOwner > 64
            or resourceOwner:match('^synex_[a-z0-9_]+$') == nil
            or not boundedInteger(targetBucket, 0, 2147483647)
            or not safeReason(reasonCode) then
            return invalid('The persistent bucket move fence is invalid', context)
        end
        local validAuthority, authorityError = validateAuthority(authority, context)
        if not validAuthority then return nil, authorityError end
        local traceId = safeTrace(context)
        return atomic('entities.move_bucket', context, function(transaction)
            local entity = transaction.one([[SELECT `status`, `resource_owner`, `bucket_id`,
                    `version` FROM `synex_entities`
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `deleted_at` IS NULL FOR UPDATE]], {
                entityId, generation, version,
            })
            if not entity then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity bucket changed concurrently', retryable = true }
            end
            if entity.resource_owner ~= resourceOwner then
                return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The entity belongs to another resource', retryable = false }
            end
            if entity.status ~= 'active' then
                return nil, { code = 'ENTITY_NOT_MATERIALIZED', message = 'The entity is not active', retryable = true }
            end
            local lease = transaction.one([[SELECT `lease_generation` FROM
                    `synex_entity_authority_leases`
                WHERE `entity_id` = ? AND `server_scope` = ? AND `instance_id` = ?
                    AND `authority_token` = ? AND `resource_epoch` = ?
                    AND `lease_generation` = ? AND `lease_state` = 'active'
                    AND `lease_until` > CURRENT_TIMESTAMP(6) FOR UPDATE]], {
                entityId, authority.serverScope, authority.instanceId, authority.token,
                authority.resourceEpoch, leaseGeneration,
            })
            if not lease then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The entity bucket move lost authority', retryable = true }
            end
            if tonumber(entity.bucket_id) == targetBucket then
                return { changed = false, version = version }
            end
            local affected = transaction.update([[UPDATE `synex_entities`
                SET `bucket_id` = ?, `last_reason_code` = ?, `last_trace_id` = ?,
                    `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `status` = 'active' AND `resource_owner` = ?]], {
                targetBucket, reasonCode, traceId, entityId, generation, version,
                resourceOwner,
            })
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity bucket changed concurrently', retryable = true }
            end
            return { changed = true, version = version + 1 }
        end)
    end

    function repository.release(entityId, generation, version, authority, nextStatus, reasonCode, context)
        local traceId = safeTrace(context)
        return atomic('entities.release', context, function(transaction)
            local entity = transaction.one([[SELECT `status`, `version` FROM `synex_entities`
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `deleted_at` IS NULL
                    AND `status` IN ('active', 'orphaned', 'recovering', 'spawning', 'failed')
                FOR UPDATE]], { entityId, generation, version })
            if not entity then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Entity release changed concurrently', retryable = true }
            end
            local lease = transaction.one([[SELECT `version`
                FROM `synex_entity_authority_leases`
                WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                    AND `resource_epoch` = ? AND `lease_state` = 'active'
                    AND `lease_until` > CURRENT_TIMESTAMP(6) FOR UPDATE]], {
                entityId, authority.instanceId, authority.token, authority.resourceEpoch,
            })
            if not lease then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'Entity release lost its authority fence', retryable = true }
            end
            local affected = transaction.update([[UPDATE `synex_entities`
                SET `status` = ?, `bucket_id` = 0, `last_reason_code` = ?,
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `status` = ?]], {
                nextStatus, reasonCode, traceId, entityId, generation, version, entity.status,
            })
            local released = transaction.update([[UPDATE `synex_entity_authority_leases`
                SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
                    `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `version` = ? AND `lease_state` = 'active']], {
                traceId, entityId, tonumber(lease.version),
            })
            if affected ~= 1 or released ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Entity release changed concurrently', retryable = true }
            end
            return { status = nextStatus, version = version + 1 }
        end)
    end

    function repository.markFailed(entityId, generation, authority, failureCode, context)
        local traceId = safeTrace(context)
        return atomic('entities.mark_failed', context, function(transaction)
            local entity = transaction.one([[SELECT `status`, `version` FROM `synex_entities`
                WHERE `entity_id` = ? AND `generation` = ? AND `deleted_at` IS NULL
                    AND `status` IN ('spawning', 'recovering') FOR UPDATE]], {
                entityId, generation,
            })
            if not entity then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The failed entity changed concurrently', retryable = true }
            end
            local lease = transaction.one([[SELECT `version`
                FROM `synex_entity_authority_leases`
                WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                    AND `resource_epoch` = ? AND `lease_state` = 'active' FOR UPDATE]], {
                entityId, authority.instanceId, authority.token, authority.resourceEpoch,
            })
            if not lease then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The failed spawn lost its authority lease', retryable = true }
            end
            local affected = transaction.update([[UPDATE `synex_entities`
                SET `status` = 'failed', `last_recovery_failure_code` = ?,
                    `last_reason_code` = 'synex.entities.spawn_failed', `last_trace_id` = ?,
                    `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ?
                    AND `version` = ? AND `status` = ?]], {
                failureCode, traceId, entityId, generation,
                tonumber(entity.version), entity.status,
            })
            local released = transaction.update([[UPDATE `synex_entity_authority_leases`
                SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
                    `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `version` = ? AND `lease_state` = 'active']], {
                traceId, entityId, tonumber(lease.version),
            })
            if affected ~= 1 or released ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The failed entity changed concurrently', retryable = true }
            end
            return true
        end)
    end

    function repository.definition(row)
        return definition(row)
    end

    local shared = {
        ENTITY_SELECT = ENTITY_SELECT,
        atomic = atomic,
        bootReconcileLimit = bootReconcileLimit,
        boundedInteger = boundedInteger,
        database = database,
        definition = definition,
        foundation = foundation,
        health = health,
        invalid = invalid,
        operationFailure = operationFailure,
        read = read,
        recoveryHistoryRetentionSeconds = recoveryHistoryRetentionSeconds,
        safeReason = safeReason,
        safeTrace = safeTrace,
        validateAuthority = validateAuthority,
        validateOwner = validateOwner,
    }

    assert(type(SynexEntityAuthorityRecoveryRepository) == 'table'
        and type(SynexEntityAuthorityRecoveryRepository.attach) == 'function',
        'entity authority recovery repository is required')
    assert(type(SynexEntityAuthorityInspectionRepository) == 'table'
        and type(SynexEntityAuthorityInspectionRepository.attach) == 'function',
        'entity authority inspection repository is required')
    assert(type(SynexEntityAuthorityDiagnosticsRepository) == 'table'
        and type(SynexEntityAuthorityDiagnosticsRepository.attach) == 'function',
        'entity authority diagnostics repository is required')
    SynexEntityAuthorityRecoveryRepository.attach(repository, shared)
    SynexEntityAuthorityInspectionRepository.attach(repository, shared)
    SynexEntityAuthorityDiagnosticsRepository.attach(repository, shared)
    return repository
end
