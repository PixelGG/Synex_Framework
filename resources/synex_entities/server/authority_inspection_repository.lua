SynexEntityAuthorityInspectionRepository = {}

function SynexEntityAuthorityInspectionRepository.attach(repository, shared)
    assert(type(repository) == 'table', 'entity authority repository is required')
    assert(type(shared) == 'table', 'entity authority repository shared state is required')
    local ENTITY_SELECT = assert(shared.ENTITY_SELECT, 'entity authority select is required')
    local atomic = assert(shared.atomic, 'entity authority atomic helper is required')
    local boundedInteger = assert(shared.boundedInteger, 'entity authority integer helper is required')
    local definition = assert(shared.definition, 'entity authority definition mapper is required')
    local invalid = assert(shared.invalid, 'entity authority validation helper is required')
    local read = assert(shared.read, 'entity authority read helper is required')
    local safeReason = assert(shared.safeReason, 'entity authority reason helper is required')
    local safeTrace = assert(shared.safeTrace, 'entity authority trace helper is required')
    local validateAuthority = assert(shared.validateAuthority, 'entity authority fence helper is required')
    local validateOwner = assert(shared.validateOwner, 'entity authority owner helper is required')
    local bootReconcileLimit = assert(shared.bootReconcileLimit,
        'entity boot reconciliation limit is required')
    local recoveryHistoryRetentionSeconds = assert(shared.recoveryHistoryRetentionSeconds,
        'entity recovery history retention is required')

function repository.getOwnerDeletionSummary(ownerType, ownerId, context)
    local valid, ownerError = validateOwner(ownerType, ownerId, context)
    if not valid then return nil, ownerError end
    local rows, readError = read([[SELECT COUNT(*) AS `total`,
            SUM(CASE WHEN `status` IN ('spawning', 'active', 'recovering')
                THEN 1 ELSE 0 END) AS `materialized`,
            SUM(CASE WHEN `persistence_policy` = 'temporary' THEN 1 ELSE 0 END)
                AS `temporary`,
            SUM(CASE WHEN `persistence_policy` = 'session' THEN 1 ELSE 0 END)
                AS `session`,
            SUM(CASE WHEN `persistence_policy` = 'persistent' THEN 1 ELSE 0 END)
                AS `persistent`,
            SUM(CASE WHEN `persistence_policy` = 'owner_lifetime' THEN 1 ELSE 0 END)
                AS `owner_lifetime`
        FROM `synex_entities`
        WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL]], {
        ownerType, ownerId,
    }, context, 1)
    if not rows then return nil, readError end
    local row = rows[1] or {}
    return {
        materialized = tonumber(row.materialized) or 0,
        ownerLifetime = tonumber(row.owner_lifetime) or 0,
        persistent = tonumber(row.persistent) or 0,
        session = tonumber(row.session) or 0,
        temporary = tonumber(row.temporary) or 0,
        total = tonumber(row.total) or 0,
    }
end

function repository.applyOwnerDeletion(
    ownerType, ownerId, mode, replacementOwner, reasonCode, limit, context
)
    local valid, ownerError = validateOwner(ownerType, ownerId, context)
    if not valid then return nil, ownerError end
    if (mode ~= 'block' and mode ~= 'retain' and mode ~= 'delete')
        or not safeReason(reasonCode) or not boundedInteger(limit, 1, 64) then
        return invalid('The owner deletion request is invalid', context)
    end
    if mode == 'retain' then
        if type(replacementOwner) ~= 'table' then
            return invalid('Retained entities require a replacement owner', context)
        end
        local replacementValid, replacementError = validateOwner(
            replacementOwner.type, replacementOwner.id, context
        )
        if not replacementValid then return nil, replacementError end
        if replacementOwner.type == ownerType and replacementOwner.id == ownerId then
            return invalid('The replacement owner must differ from the deleted owner', context)
        end
    end
    local traceId = safeTrace(context)
    return atomic('entities.owner_deletion', context, function(transaction)
        local rows = transaction.many([[SELECT `entity_id`, `status`
            FROM `synex_entities`
            WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL
            ORDER BY `entity_id` LIMIT ? FOR UPDATE]], {
            ownerType, ownerId, limit,
        }, limit)
        if #rows == 0 then
            return { affected = 0, blocked = false, complete = true, entityIds = {}, remaining = 0 }
        end
        if mode == 'block' then
            local count = transaction.one([[SELECT COUNT(*) AS `total`
                FROM `synex_entities`
                WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL]], {
                ownerType, ownerId,
            })
            return {
                affected = 0,
                blocked = true,
                complete = false,
                entityIds = {},
                remaining = count and tonumber(count.total) or #rows,
            }
        end

        local entityIds, placeholders = {}, {}
        for index, row in ipairs(rows) do
            entityIds[index] = row.entity_id
            placeholders[index] = '?'
        end
        local idList = table.concat(placeholders, ',')
        local entityParameters
        local entitySql
        if mode == 'retain' then
            entitySql = [[UPDATE `synex_entities`
                SET `owner_type` = ?, `owner_id` = ?,
                    `generation` = `generation` + 1,
                    `status` = CASE WHEN `status` IN ('defined', 'dormant')
                        THEN 'dormant' ELSE 'orphaned' END,
                    `bucket_id` = 0, `last_reason_code` = ?, `last_trace_id` = ?,
                    `version` = `version` + 1
                WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL
                    AND `entity_id` IN (]] .. idList .. ')'
            entityParameters = {
                replacementOwner.type, replacementOwner.id, reasonCode, traceId,
                ownerType, ownerId,
            }
        else
            entitySql = [[UPDATE `synex_entities`
                SET `status` = 'deleted', `deleted_at` = CURRENT_TIMESTAMP(3),
                    `bucket_id` = 0, `last_reason_code` = ?, `last_trace_id` = ?,
                    `version` = `version` + 1
                WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL
                    AND `entity_id` IN (]] .. idList .. ')'
            entityParameters = { reasonCode, traceId, ownerType, ownerId }
        end
        for _, entityId in ipairs(entityIds) do
            entityParameters[#entityParameters + 1] = entityId
        end
        local affected = transaction.update(entitySql, entityParameters)
        if affected ~= #entityIds then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Owner deletion entities changed concurrently', retryable = true }
        end

        local leaseParameters = { traceId }
        for _, entityId in ipairs(entityIds) do
            leaseParameters[#leaseParameters + 1] = entityId
        end
        transaction.update([[UPDATE `synex_entity_authority_leases`
            SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
                `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
                `last_trace_id` = ?, `version` = `version` + 1
            WHERE `entity_id` IN (]] .. idList .. [[) AND `lease_state` = 'active']],
            leaseParameters)

        if mode == 'delete' then
            local bindingParameters = { reasonCode }
            for _, entityId in ipairs(entityIds) do
                bindingParameters[#bindingParameters + 1] = entityId
            end
            transaction.update([[UPDATE `synex_entity_bindings`
                SET `released_at` = CURRENT_TIMESTAMP(6), `release_reason_code` = ?,
                    `version` = `version` + 1
                WHERE `entity_id` IN (]] .. idList .. [[) AND `released_at` IS NULL]],
                bindingParameters)
        end

        local remaining = transaction.one([[SELECT COUNT(*) AS `total`
            FROM `synex_entities`
            WHERE `owner_type` = ? AND `owner_id` = ? AND `deleted_at` IS NULL]], {
            ownerType, ownerId,
        })
        local remainingCount = remaining and tonumber(remaining.total) or 0
        return {
            affected = affected,
            blocked = false,
            complete = remainingCount == 0,
            entityIds = entityIds,
            remaining = remainingCount,
        }
    end)
end

function repository.inspectAuthority(entityId, context)
    if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64 then
        return invalid('The authority inspection entity is invalid', context)
    end
    local rows, readError = read([[SELECT `entity_id`, `server_scope`, `instance_id`,
            `authority_token`, `resource_epoch`, `lease_generation`, `lease_state`,
            `claimed_at`, `heartbeat_at`, `lease_until`, `released_at`, `version`,
            (`lease_state` = 'active' AND `lease_until` > CURRENT_TIMESTAMP(6)) AS `lease_live`
        FROM `synex_entity_authority_leases` WHERE `entity_id` = ? LIMIT 1]], {
        entityId,
    }, context, 1)
    if not rows then return nil, readError end
    return rows[1]
end

function repository.inspectRecovery(entityId, limit, context)
    if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64
        or not boundedInteger(limit, 1, 50) then
        return invalid('The recovery inspection request is invalid', context)
    end
    return read([[SELECT `recovery_id`, `entity_id`, `entity_generation`,
            `lease_generation`, `attempt_number`, `outcome`, `instance_id`,
            `failure_code`, `next_retry_at`, `duration_ms`, `trace_id`,
            `occurred_at`, `retain_until`
        FROM `synex_entity_recovery_history`
        WHERE `entity_id` = ? ORDER BY `recovery_id` DESC LIMIT ?]], {
        entityId, limit,
    }, context, limit)
end

function repository.inspectEntity(entityId, context)
    if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64 then
        return invalid('The entity inspection identity is invalid', context)
    end
    return atomic('entities.inspect', context, function(transaction)
        local entity = transaction.one(ENTITY_SELECT .. [[ WHERE `entity_id` = ? LIMIT 1]], {
            entityId,
        })
        if not entity then
            return nil, { code = 'ENTITY_NOT_FOUND', message = 'The entity definition does not exist', retryable = false }
        end
        local binding = transaction.one([[SELECT `binding_namespace`, `binding_ref`,
                `owner_resource`, `version`, `created_at`
            FROM `synex_entity_bindings`
            WHERE `entity_id` = ? AND `released_at` IS NULL LIMIT 1]], { entityId })
        local counts = transaction.one([[SELECT
                (SELECT COUNT(*) FROM `synex_entity_components` WHERE `entity_id` = ?) AS `components`,
                (SELECT COUNT(*) FROM `synex_entity_states` WHERE `entity_id` = ?) AS `states`,
                (SELECT COUNT(*) FROM `synex_entity_tags` WHERE `entity_id` = ?) AS `tags`]], {
            entityId, entityId, entityId,
        })
        local checkpoint = transaction.one([[SELECT `entity_generation`, `bucket_id`,
                `source_resource`, `reason_code`, `trace_id`, `version`, `checkpointed_at`
            FROM `synex_entity_checkpoints` WHERE `entity_id` = ? LIMIT 1]], { entityId })
        local lease = transaction.one([[SELECT `server_scope`, `instance_id`,
                `resource_epoch`, `lease_generation`, `lease_state`, `heartbeat_at`,
                `lease_until`, `released_at`, `version`,
                (`lease_state` = 'active' AND `lease_until` > CURRENT_TIMESTAMP(6)) AS `lease_live`
            FROM `synex_entity_authority_leases` WHERE `entity_id` = ? LIMIT 1]], {
            entityId,
        })
        return {
            authority = lease,
            binding = binding,
            checkpoint = checkpoint,
            counts = {
                components = counts and tonumber(counts.components) or 0,
                states = counts and tonumber(counts.states) or 0,
                tags = counts and tonumber(counts.tags) or 0,
            },
            definition = definition(entity),
        }
    end)
end

function repository.queryDefinitions(filter, context)
    if type(filter) ~= 'table' or not boundedInteger(filter.limit, 1, 100) then
        return invalid('The entity definition query is invalid', context)
    end
    local clauses, parameters = {}, {}
    if filter.includeDeleted ~= true then clauses[#clauses + 1] = '`deleted_at` IS NULL' end
    if filter.ownerType ~= nil or filter.ownerId ~= nil then
        local ownerValid, ownerError = validateOwner(filter.ownerType, filter.ownerId, context)
        if not ownerValid then return nil, ownerError end
        clauses[#clauses + 1] = '`owner_type` = ? AND `owner_id` = ?'
        parameters[#parameters + 1] = filter.ownerType
        parameters[#parameters + 1] = filter.ownerId
    end
    if filter.resourceOwner ~= nil then
        if type(filter.resourceOwner) ~= 'string' or #filter.resourceOwner < 2
            or #filter.resourceOwner > 64 then
            return invalid('The entity resource filter is invalid', context)
        end
        clauses[#clauses + 1] = '`resource_owner` = ?'
        parameters[#parameters + 1] = filter.resourceOwner
    end
    if filter.serverScope ~= nil then
        if type(filter.serverScope) ~= 'string' or #filter.serverScope < 1
            or #filter.serverScope > 64 then
            return invalid('The entity scope filter is invalid', context)
        end
        clauses[#clauses + 1] = '`server_scope` = ?'
        parameters[#parameters + 1] = filter.serverScope
    end
    if filter.bucket ~= nil then
        if not boundedInteger(filter.bucket, 0, 2147483647) then
            return invalid('The entity bucket filter is invalid', context)
        end
        clauses[#clauses + 1] = '`bucket_id` = ?'
        parameters[#parameters + 1] = filter.bucket
    end
    if filter.entityTypes ~= nil then
        if type(filter.entityTypes) ~= 'table' then
            return invalid('The entity type filters are invalid', context)
        end
        local allowedTypes = { object = true, ped = true, vehicle = true }
        local seenTypes, placeholders, count = {}, {}, 0
        for index, entityType in ipairs(filter.entityTypes) do
            if index > 3 or not allowedTypes[entityType] or seenTypes[entityType] then
                return invalid('The entity type filters are invalid', context)
            end
            seenTypes[entityType] = true
            placeholders[index] = '?'
            parameters[#parameters + 1] = entityType
            count = index
        end
        for key in pairs(filter.entityTypes) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > count then
                return invalid('The entity type filters are invalid', context)
            end
        end
        if count < 1 then return invalid('The entity type filters are invalid', context) end
        clauses[#clauses + 1] = '`entity_type` IN (' .. table.concat(placeholders, ',') .. ')'
    end
    if filter.persistencePolicy ~= nil then
        local policies = {
            owner_lifetime = true, persistent = true, session = true, temporary = true,
        }
        if not policies[filter.persistencePolicy] then
            return invalid('The entity persistence filter is invalid', context)
        end
        clauses[#clauses + 1] = '`persistence_policy` = ?'
        parameters[#parameters + 1] = filter.persistencePolicy
    end
    if filter.persistent ~= nil then
        if type(filter.persistent) ~= 'boolean' then
            return invalid('The entity durability filter is invalid', context)
        end
        clauses[#clauses + 1] = filter.persistent
            and "`persistence_policy` IN ('persistent', 'owner_lifetime')"
            or "`persistence_policy` IN ('temporary', 'session')"
    end
    if filter.archetypeNamespace ~= nil then
        if type(filter.archetypeNamespace) ~= 'string'
            or #filter.archetypeNamespace < 3 or #filter.archetypeNamespace > 128
            or filter.archetypeNamespace:match('^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$') == nil then
            return invalid('The entity archetype filter is invalid', context)
        end
        clauses[#clauses + 1] = '`archetype_namespace` = ?'
        parameters[#parameters + 1] = filter.archetypeNamespace
    end
    if filter.materialized ~= nil then
        if type(filter.materialized) ~= 'boolean' then
            return invalid('The entity materialization filter is invalid', context)
        end
        clauses[#clauses + 1] = filter.materialized
            and "`status` IN ('active', 'spawning', 'recovering')"
            or "`status` NOT IN ('active', 'spawning', 'recovering')"
    end
    local statuses = {
        defined = true, spawning = true, active = true, orphaned = true,
        recovering = true, dormant = true, deleting = true, deleted = true, failed = true,
    }
    if filter.status ~= nil then
        if not statuses[filter.status] then
            return invalid('The entity status filter is invalid', context)
        end
        clauses[#clauses + 1] = '`status` = ?'
        parameters[#parameters + 1] = filter.status
    end
    if filter.afterEntityId ~= nil then
        if type(filter.afterEntityId) ~= 'string' or #filter.afterEntityId < 1
            or #filter.afterEntityId > 64 then
            return invalid('The entity query cursor is invalid', context)
        end
        clauses[#clauses + 1] = '`entity_id` > ?'
        parameters[#parameters + 1] = filter.afterEntityId
    end
    if #clauses == 0 then clauses[1] = '1 = 1' end
    parameters[#parameters + 1] = filter.limit
    local rows, readError = read(ENTITY_SELECT .. ' WHERE '
        .. table.concat(clauses, ' AND ') .. [[ ORDER BY `entity_id` LIMIT ?]],
        parameters, context, filter.limit)
    if not rows then return nil, readError end
    local items = {}
    for index, row in ipairs(rows) do items[index] = definition(row) end
    return {
        items = items,
        nextAfterEntityId = #items == filter.limit and items[#items].entityId or nil,
    }
end

    return repository
end
