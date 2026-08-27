SynexEntityExtensionRepository = {}

function SynexEntityExtensionRepository.create(options)
    assert(type(options) == 'table', 'entity extension repository options are required')
    local database = assert(options.database, 'entity extension repository database is required')
    local foundation = assert(options.foundation, 'entity extension repository foundation is required')
    local health = assert(options.health, 'entity extension repository health is required')
    local repository = {}

    local function trace(context)
        local value = type(context) == 'table' and context.traceId or nil
        if type(value) ~= 'string' or #value < 8 or #value > 128
            or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return 'entity_trace'
        end
        return value
    end

    local function failure(caught, context)
        health.persistence = 'UNAVAILABLE'
        if type(caught) == 'table' and type(caught.code) == 'string' then
            caught.traceId = trace(context)
            return nil, caught
        end
        foundation.reportUnexpected('extension.repository', caught, context)
        return foundation.failure('PERSISTENCE_UNAVAILABLE',
            'Entity extension persistence is unavailable', true, context)
    end

    local function atomic(operation, context, handler)
        local options = {
            maximumRows = 256,
            maximumResultBytes = 1048576,
            maximumResponseBytes = 524288,
            maximumStatements = 128,
            timeoutMs = 15000,
        }
        local ok, value
        if type(context) == 'table' and context.idempotencyKey ~= nil then
            if type(database.transaction) ~= 'function' then
                return foundation.failure('CORE_UNAVAILABLE',
                    'Idempotent entity persistence requires the Core database port', true, context)
            end
            ok, value = pcall(database.transaction, {
                operation = operation,
                idempotencyKey = context.idempotencyKey,
                request = context.idempotencyRequest or {},
                maximumRequestBytes = 65536,
                maximumResponseBytes = options.maximumResponseBytes,
                maximumRows = options.maximumRows,
                maximumResultBytes = options.maximumResultBytes,
                maximumStatements = options.maximumStatements,
                timeoutMs = options.timeoutMs,
            }, handler)
        else
            ok, value = pcall(database.maintenance, operation, handler, options)
        end
        if not ok then return failure(value, context) end
        health.persistence = 'READY'
        return value
    end

    local function read(sql, parameters, context, maximumRows)
        local ok, rows = pcall(database.query, sql, parameters, {
            maximumRows = maximumRows or 100,
            maximumResultBytes = 1048576,
            timeoutMs = 15000,
        })
        if not ok then return failure(rows, context) end
        health.persistence = 'READY'
        return rows
    end

    local function lockOwned(
        transaction,
        entityId,
        caller,
        generation,
        authority,
        leaseGeneration
    )
        if type(authority) ~= 'table' or type(authority.instanceId) ~= 'string'
            or type(authority.serverScope) ~= 'string' or type(authority.token) ~= 'string'
            or type(authority.resourceEpoch) ~= 'number'
            or type(leaseGeneration) ~= 'number' then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The entity authority fence is invalid', retryable = true }
        end
        local row = transaction.one([[SELECT `generation`, `resource_owner`, `status`, `version`
            FROM `synex_entities` WHERE `entity_id` = ? AND `deleted_at` IS NULL
            FOR UPDATE]], { entityId })
        if not row then
            return nil, { code = 'ENTITY_NOT_FOUND', message = 'The entity definition does not exist', retryable = false }
        end
        if row.resource_owner ~= caller then
            return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The entity belongs to another resource', retryable = false }
        end
        if generation and tonumber(row.generation) ~= generation then
            return nil, { code = 'STALE_ENTITY', message = 'The entity generation is stale', retryable = false }
        end
        local lease = transaction.one([[SELECT `lease_generation`
            FROM `synex_entity_authority_leases`
            WHERE `entity_id` = ? AND `server_scope` = ? AND `instance_id` = ?
                AND `authority_token` = ? AND `resource_epoch` = ?
                AND `lease_generation` = ? AND `lease_state` = 'active'
                AND `lease_until` > CURRENT_TIMESTAMP(6) FOR UPDATE]], {
            entityId, authority.serverScope, authority.instanceId, authority.token,
            authority.resourceEpoch, leaseGeneration,
        })
        if not lease then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The entity authority lease is stale or foreign', retryable = true }
        end
        return row
    end

    function repository.getComponent(entityId, namespace, context)
        local rows, readError = read([[SELECT `component_namespace`, `owner_resource`,
                `schema_version`, `persistence_mode`, `payload_json`, `version`, `updated_at`
            FROM `synex_entity_components`
            WHERE `entity_id` = ? AND `component_namespace` = ? LIMIT 1]],
            { entityId, namespace }, context, 1)
        if not rows then return nil, readError end
        if not rows[1] then
            return foundation.failure('COMPONENT_NOT_FOUND', 'The entity component does not exist', false, context)
        end
        return {
            namespace = rows[1].component_namespace,
            ownerResource = rows[1].owner_resource,
            schemaVersion = tonumber(rows[1].schema_version),
            persistenceMode = rows[1].persistence_mode,
            payloadJson = rows[1].payload_json,
            version = tonumber(rows[1].version),
            updatedAt = rows[1].updated_at,
        }
    end

    function repository.countComponents(context)
        local rows, readError = read(
            [[SELECT COUNT(*) AS `total` FROM `synex_entity_components`]],
            {}, context, 1)
        if not rows then return nil, readError end
        local total = rows[1] and tonumber(rows[1].total) or nil
        if not total or total < 0 or total % 1 ~= 0
            or total > 9007199254740991 then
            return foundation.failure('PERSISTENCE_UNAVAILABLE',
                'The entity component count is invalid', true, context)
        end
        return total
    end

    function repository.getHydrationSnapshot(entityId, generation, context)
        local entityRows, entityError = read([[SELECT `entity_id`
            FROM `synex_entities` WHERE `entity_id` = ? AND `generation` = ?
                AND `deleted_at` IS NULL
                AND `status` IN ('active', 'spawning', 'recovering') LIMIT 1]],
            { entityId, generation }, context, 1)
        if not entityRows then return nil, entityError end
        if not entityRows[1] then
            return foundation.failure('STALE_ENTITY',
                'The hydration entity generation is stale', false, context)
        end
        local componentRows, componentError = read([[SELECT
                `component_namespace`, `owner_resource`, `schema_version`,
                `persistence_mode`, `payload_json`
            FROM `synex_entity_components`
            WHERE `entity_id` = ? AND `persistence_mode` = 'replicated'
                AND EXISTS (SELECT 1 FROM `synex_entities`
                    WHERE `entity_id` = ? AND `generation` = ?
                        AND `deleted_at` IS NULL
                        AND `status` IN ('active', 'spawning', 'recovering'))
            ORDER BY `component_namespace` LIMIT 65]], {
            entityId, entityId, generation,
        }, context, 65)
        if not componentRows then return nil, componentError end
        local stateRows, stateError = read([[SELECT
                `state_key`, `owner_resource`, `schema_version`, `authority_mode`,
                `replication_mode`, `value_json`
            FROM `synex_entity_states`
            WHERE `entity_id` = ? AND `replication_mode` = 'scoped'
                AND EXISTS (SELECT 1 FROM `synex_entities`
                    WHERE `entity_id` = ? AND `generation` = ?
                        AND `deleted_at` IS NULL
                        AND `status` IN ('active', 'spawning', 'recovering'))
            ORDER BY `state_key` LIMIT 65]], {
            entityId, entityId, generation,
        }, context, 65)
        if not stateRows then return nil, stateError end
        if #componentRows > 64 or #stateRows > 64 then
            return foundation.failure('ENTITY_QUOTA_EXCEEDED',
                'The entity hydration extension limit was exceeded', false, context)
        end
        local snapshot = { components = {}, states = {} }
        for _, row in ipairs(componentRows) do
            snapshot.components[#snapshot.components + 1] = {
                namespace = row.component_namespace,
                ownerResource = row.owner_resource,
                payloadJson = row.payload_json,
                persistenceMode = row.persistence_mode,
                schemaVersion = tonumber(row.schema_version),
            }
        end
        for _, row in ipairs(stateRows) do
            snapshot.states[#snapshot.states + 1] = {
                authority = row.authority_mode,
                key = row.state_key,
                ownerResource = row.owner_resource,
                replication = row.replication_mode,
                schemaVersion = tonumber(row.schema_version),
                valueJson = row.value_json,
            }
        end
        return snapshot
    end

    function repository.setComponent(
        entityId,
        generation,
        caller,
        component,
        payloadJson,
        expectedVersion,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.component_set', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local existing = transaction.one([[SELECT `owner_resource`, `version`
                FROM `synex_entity_components`
                WHERE `entity_id` = ? AND `component_namespace` = ? FOR UPDATE]],
                { entityId, component.namespace })
            if existing and existing.owner_resource ~= caller then
                return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The component belongs to another resource', retryable = false }
            end
            local currentVersion = existing and tonumber(existing.version) or 0
            if currentVersion ~= expectedVersion then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The component version is stale', retryable = true }
            end
            local affected
            if existing then
                affected = transaction.update([[UPDATE `synex_entity_components`
                    SET `schema_version` = ?, `persistence_mode` = ?, `payload_json` = ?,
                        `version` = `version` + 1
                    WHERE `entity_id` = ? AND `component_namespace` = ? AND `version` = ?]], {
                    component.schemaVersion, component.persistenceMode, payloadJson,
                    entityId, component.namespace, expectedVersion,
                })
            else
                affected = transaction.update([[INSERT INTO `synex_entity_components`
                    (`entity_id`, `component_namespace`, `owner_resource`, `schema_version`,
                        `persistence_mode`, `payload_json`, `version`)
                    VALUES (?, ?, ?, ?, ?, ?, 1)]], {
                    entityId, component.namespace, caller, component.schemaVersion,
                    component.persistenceMode, payloadJson,
                })
            end
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The component changed concurrently', retryable = true }
            end
            return { version = expectedVersion + 1 }
        end)
    end

    function repository.removeComponent(
        entityId,
        generation,
        caller,
        namespace,
        expectedVersion,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.component_remove', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local existing = transaction.one([[SELECT `owner_resource`, `version`
                FROM `synex_entity_components`
                WHERE `entity_id` = ? AND `component_namespace` = ? FOR UPDATE]],
                { entityId, namespace })
            if not existing then
                return nil, { code = 'COMPONENT_NOT_FOUND', message = 'The component does not exist', retryable = false }
            end
            if existing.owner_resource ~= caller then
                return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The component belongs to another resource', retryable = false }
            end
            if tonumber(existing.version) ~= expectedVersion then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The component version is stale', retryable = true }
            end
            local affected = transaction.update([[DELETE FROM `synex_entity_components`
                WHERE `entity_id` = ? AND `component_namespace` = ?
                    AND `owner_resource` = ? AND `version` = ?]],
                { entityId, namespace, caller, expectedVersion })
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The component changed concurrently', retryable = true }
            end
            return { removed = true }
        end)
    end

    function repository.getState(entityId, key, context)
        local rows, readError = read([[SELECT `state_key`, `owner_resource`, `schema_version`,
                `authority_mode`, `replication_mode`, `value_json`, `version`, `updated_at`
            FROM `synex_entity_states` WHERE `entity_id` = ? AND `state_key` = ? LIMIT 1]],
            { entityId, key }, context, 1)
        if not rows then return nil, readError end
        if not rows[1] then
            return foundation.failure('STATE_NOT_FOUND', 'The entity state value does not exist', false, context)
        end
        return {
            key = rows[1].state_key,
            ownerResource = rows[1].owner_resource,
            schemaVersion = tonumber(rows[1].schema_version),
            authority = rows[1].authority_mode,
            replication = rows[1].replication_mode,
            valueJson = rows[1].value_json,
            version = tonumber(rows[1].version),
            updatedAt = rows[1].updated_at,
        }
    end

    function repository.setState(
        entityId,
        generation,
        caller,
        stateValue,
        valueJson,
        expectedVersion,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.state_set', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local existing = transaction.one([[SELECT `owner_resource`, `version`
                FROM `synex_entity_states`
                WHERE `entity_id` = ? AND `state_key` = ? FOR UPDATE]],
                { entityId, stateValue.key })
            if existing and existing.owner_resource ~= caller then
                return nil, { code = 'FOREIGN_RESOURCE_OWNER', message = 'The state key belongs to another resource', retryable = false }
            end
            local currentVersion = existing and tonumber(existing.version) or 0
            if currentVersion ~= expectedVersion then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The state version is stale', retryable = true }
            end
            local affected
            if existing then
                affected = transaction.update([[UPDATE `synex_entity_states`
                    SET `schema_version` = ?, `authority_mode` = ?, `replication_mode` = ?,
                        `value_json` = ?, `version` = `version` + 1
                    WHERE `entity_id` = ? AND `state_key` = ? AND `version` = ?]], {
                    stateValue.schemaVersion, stateValue.authority, stateValue.replication,
                    valueJson, entityId, stateValue.key, expectedVersion,
                })
            else
                affected = transaction.update([[INSERT INTO `synex_entity_states`
                    (`entity_id`, `state_key`, `owner_resource`, `schema_version`,
                        `authority_mode`, `replication_mode`, `value_json`, `version`)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1)]], {
                    entityId, stateValue.key, caller, stateValue.schemaVersion,
                    stateValue.authority, stateValue.replication, valueJson,
                })
            end
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The state value changed concurrently', retryable = true }
            end
            return { version = expectedVersion + 1 }
        end)
    end

    function repository.listTags(entityId, context)
        local rows, readError = read([[SELECT `tag`, `owner_resource`, `created_at`
            FROM `synex_entity_tags` WHERE `entity_id` = ? ORDER BY `tag` LIMIT 65]],
            { entityId }, context, 65)
        if not rows then return nil, readError end
        if #rows > 64 then
            return foundation.failure('ENTITY_QUOTA_EXCEEDED', 'The entity tag limit was exceeded', false, context)
        end
        return rows
    end

    function repository.addTag(
        entityId,
        generation,
        caller,
        tag,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.tag_add', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local countRow = transaction.one([[SELECT COUNT(*) AS `total`
                FROM `synex_entity_tags` WHERE `entity_id` = ?]], { entityId })
            if not countRow or tonumber(countRow.total) >= 64 then
                return nil, { code = 'ENTITY_QUOTA_EXCEEDED', message = 'The entity tag limit has been reached', retryable = false }
            end
            local inserted = transaction.update([[INSERT IGNORE INTO `synex_entity_tags`
                (`entity_id`, `tag`, `owner_resource`) VALUES (?, ?, ?)]],
                { entityId, tag, caller })
            return { added = inserted == 1 }
        end)
    end

    function repository.removeTag(
        entityId,
        generation,
        caller,
        tag,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.tag_remove', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local removed = transaction.update([[DELETE FROM `synex_entity_tags`
                WHERE `entity_id` = ? AND `tag` = ? AND `owner_resource` = ?]],
                { entityId, tag, caller })
            return { removed = removed == 1 }
        end)
    end

    function repository.mutateTags(
        entityId,
        generation,
        caller,
        tags,
        mode,
        authority,
        leaseGeneration,
        context
    )
        return atomic('entities.tags_' .. mode, context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            local rows = transaction.query([[SELECT `tag`, `owner_resource`
                FROM `synex_entity_tags` WHERE `entity_id` = ?
                ORDER BY `tag` LIMIT 65]], { entityId }, 65)
            if type(rows) ~= 'table' or #rows > 64 then
                return nil, { code = 'ENTITY_QUOTA_EXCEEDED', message = 'The entity tag set is invalid', retryable = false }
            end
            local current = {}
            for _, row in ipairs(rows) do
                current[row.tag] = row.owner_resource
            end
            local changed = false
            if mode == 'add' then
                local additions = 0
                for _, tag in ipairs(tags) do
                    if current[tag] and current[tag] ~= caller then
                        return nil, { code = 'TAG_OWNERSHIP_DENIED', message = 'The tag belongs to another resource', retryable = false }
                    end
                    if not current[tag] then additions = additions + 1 end
                end
                if #rows + additions > 64 then
                    return nil, { code = 'ENTITY_QUOTA_EXCEEDED', message = 'The entity tag limit has been reached', retryable = false }
                end
                for _, tag in ipairs(tags) do
                    if not current[tag] then
                        local inserted = transaction.update([[INSERT INTO `synex_entity_tags`
                            (`entity_id`, `tag`, `owner_resource`) VALUES (?, ?, ?)]],
                            { entityId, tag, caller })
                        if inserted ~= 1 then
                            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity tags changed concurrently', retryable = true }
                        end
                        current[tag] = caller
                        changed = true
                    end
                end
            elseif mode == 'remove' then
                for _, tag in ipairs(tags) do
                    if current[tag] and current[tag] ~= caller then
                        return nil, { code = 'TAG_OWNERSHIP_DENIED', message = 'The tag belongs to another resource', retryable = false }
                    end
                    if current[tag] then
                        local removed = transaction.update([[DELETE FROM `synex_entity_tags`
                            WHERE `entity_id` = ? AND `tag` = ? AND `owner_resource` = ?]],
                            { entityId, tag, caller })
                        if removed ~= 1 then
                            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity tags changed concurrently', retryable = true }
                        end
                        current[tag] = nil
                        changed = true
                    end
                end
            else
                return nil, { code = 'INVALID_ARGUMENT', message = 'The tag mutation mode is invalid', retryable = false }
            end
            local resultTags = {}
            for tag in pairs(current) do resultTags[#resultTags + 1] = tag end
            table.sort(resultTags)
            return { changed = changed, tags = resultTags }
        end)
    end

    function repository.checkpoint(entityId, generation, version, caller, authority,
        leaseGeneration, checkpoint, stateJson, context)
        local traceId = trace(context)
        return atomic('entities.checkpoint', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            if tonumber(entity.version) ~= version or entity.status ~= 'active' then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The active entity version changed', retryable = true }
            end
            local existing = transaction.one([[SELECT `version` FROM `synex_entity_checkpoints`
                WHERE `entity_id` = ? FOR UPDATE]], { entityId })
            local checkpointVersion
            if existing then
                checkpointVersion = tonumber(existing.version) + 1
                local changed = transaction.update([[UPDATE `synex_entity_checkpoints`
                    SET `entity_generation` = ?, `position_x` = ?, `position_y` = ?,
                        `position_z` = ?, `heading` = ?, `bucket_id` = ?,
                        `generic_state_json` = ?, `source_resource` = ?, `reason_code` = ?,
                        `trace_id` = ?, `checkpointed_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `entity_id` = ? AND `version` = ?]], {
                    generation, checkpoint.position.x, checkpoint.position.y, checkpoint.position.z,
                    checkpoint.heading, checkpoint.bucket, stateJson, caller,
                    checkpoint.reasonCode, traceId, entityId, tonumber(existing.version),
                })
                if changed ~= 1 then return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The checkpoint changed concurrently', retryable = true } end
            else
                checkpointVersion = 1
                local inserted = transaction.update([[INSERT INTO `synex_entity_checkpoints`
                    (`entity_id`, `entity_generation`, `position_x`, `position_y`, `position_z`,
                        `heading`, `bucket_id`, `generic_state_json`, `source_resource`,
                        `reason_code`, `trace_id`, `version`)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
                    entityId, generation, checkpoint.position.x, checkpoint.position.y,
                    checkpoint.position.z, checkpoint.heading, checkpoint.bucket, stateJson,
                    caller, checkpoint.reasonCode, traceId,
                })
                if inserted ~= 1 then return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The checkpoint reservation failed', retryable = true } end
            end
            local entityChanged = transaction.update([[UPDATE `synex_entities`
                SET `position_x` = ?, `position_y` = ?, `position_z` = ?, `heading` = ?,
                    `bucket_id` = ?, `last_checkpoint_at` = CURRENT_TIMESTAMP(6),
                    `last_reason_code` = ?, `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ? AND `status` = 'active']], {
                checkpoint.position.x, checkpoint.position.y, checkpoint.position.z,
                checkpoint.heading, checkpoint.bucket, checkpoint.reasonCode, traceId,
                entityId, generation, version,
            })
            if entityChanged ~= 1 then return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity changed during checkpoint', retryable = true } end
            return { checkpointVersion = checkpointVersion, version = version + 1 }
        end)
    end

    function repository.changeOwner(entityId, generation, caller, owner, expectedVersion,
        authority, leaseGeneration, reasonCode, context)
        local traceId = trace(context)
        return atomic('entities.owner_change', context, function(transaction)
            local entity, entityError = lockOwned(transaction, entityId, caller,
                generation, authority, leaseGeneration)
            if not entity then return nil, entityError end
            if tonumber(entity.version) ~= expectedVersion then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity owner changed concurrently', retryable = true }
            end
            local affected = transaction.update([[UPDATE `synex_entities`
                SET `owner_type` = ?, `owner_id` = ?, `last_reason_code` = ?,
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `resource_owner` = ?
                    AND `version` = ? AND `deleted_at` IS NULL
                    AND `status` = 'active']], {
                owner.type, owner.id, reasonCode, traceId, entityId, generation,
                caller, expectedVersion,
            })
            if affected ~= 1 then
                return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity owner changed concurrently', retryable = true }
            end
            return true
        end)
    end

    function repository.terminate(entityId, generation, caller, authority,
        leaseGeneration, reasonCode, context)
        local traceId = trace(context)
        return atomic('entities.terminate', context, function(transaction)
            if type(authority) ~= 'table' then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The deletion authority is unavailable', retryable = true }
            end
            local entity = transaction.one([[SELECT `generation`, `resource_owner`, `status`, `version`
                FROM `synex_entities` WHERE `entity_id` = ? AND `deleted_at` IS NULL
                FOR UPDATE]], { entityId })
            if not entity then return nil, { code = 'ENTITY_NOT_FOUND', message = 'The entity definition does not exist', retryable = false } end
            if entity.resource_owner ~= caller or tonumber(entity.generation) ~= generation then
                return nil, { code = 'STALE_ENTITY', message = 'The entity generation is stale or foreign', retryable = false }
            end
            local lease = transaction.one([[SELECT `server_scope`, `instance_id`,
                    `authority_token`, `resource_epoch`, `lease_generation`
                FROM `synex_entity_authority_leases`
                WHERE `entity_id` = ? AND `lease_state` = 'active'
                    AND `lease_until` > CURRENT_TIMESTAMP(6) FOR UPDATE]], {
                entityId,
            })
            local exactLease = lease and lease.server_scope == authority.serverScope
                and lease.instance_id == authority.instanceId
                and lease.authority_token == authority.token
                and tonumber(lease.resource_epoch) == authority.resourceEpoch
                and tonumber(lease.lease_generation) == leaseGeneration
            local requiresLease = entity.status == 'active' or entity.status == 'spawning'
                or entity.status == 'recovering'
            if lease and not exactLease or requiresLease and not exactLease then
                return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'A live foreign or stale authority lease blocks deletion', retryable = true }
            end
            transaction.update([[DELETE FROM `synex_entity_components`
                WHERE `entity_id` = ?]], { entityId })
            transaction.update([[DELETE FROM `synex_entity_states`
                WHERE `entity_id` = ?]], { entityId })
            local changed = transaction.update([[UPDATE `synex_entities`
                SET `status` = 'deleted', `deleted_at` = CURRENT_TIMESTAMP(3),
                    `last_reason_code` = ?, `last_trace_id` = ?, `bucket_id` = 0,
                    `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `deleted_at` IS NULL]], {
                reasonCode, traceId, entityId, generation, tonumber(entity.version),
            })
            if changed ~= 1 then return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The entity changed during deletion', retryable = true } end
            transaction.update([[UPDATE `synex_entity_bindings`
                SET `released_at` = CURRENT_TIMESTAMP(6), `release_reason_code` = ?,
                    `version` = `version` + 1
                WHERE `entity_id` = ? AND `released_at` IS NULL]], { reasonCode, entityId })
            transaction.update([[UPDATE `synex_entity_authority_leases`
                SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
                    `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `lease_state` = 'active']], { traceId, entityId })
            return { deleted = true, version = tonumber(entity.version) + 1 }
        end)
    end

    function repository.query(filter, context)
        local clauses, parameters = { [[`deleted_at` IS NULL]] }, {}
        if filter.owner then
            clauses[#clauses + 1] = [[`owner_type` = ? AND `owner_id` = ?]]
            parameters[#parameters + 1] = filter.owner.type
            parameters[#parameters + 1] = filter.owner.id
        end
        if filter.resourceOwner then
            clauses[#clauses + 1] = [[`resource_owner` = ?]]
            parameters[#parameters + 1] = filter.resourceOwner
        end
        if filter.bucket ~= nil then
            clauses[#clauses + 1] = [[`bucket_id` = ?]]
            parameters[#parameters + 1] = filter.bucket
        end
        if filter.after then
            clauses[#clauses + 1] = [[`entity_id` > ?]]
            parameters[#parameters + 1] = filter.after
        end
        parameters[#parameters + 1] = filter.limit
        local sql = [[SELECT `entity_id`, `generation`, `entity_type`, `model`, `owner_type`,
                `owner_id`, `resource_owner`, `bucket_id`, `persistence_policy`,
                `recovery_policy`, `status`, `version`
            FROM `synex_entities` WHERE ]] .. table.concat(clauses, ' AND ')
            .. [[ ORDER BY `entity_id` LIMIT ?]]
        return read(sql, parameters, context, filter.limit)
    end

    return repository
end
