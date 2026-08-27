SynexEntityRepository = {}

local SELECT_PERSISTENT_BY_KEY = [[
    SELECT entity_id
    FROM synex_entities
    WHERE persistent_key = ?
    LIMIT 1
]]

local SELECT_PERSISTENT_FOR_REHYDRATE = [[
    SELECT entity_id, generation, persistent_key, entity_type, vehicle_type, model,
           position_x, position_y, position_z, heading, ped_type, door_flag,
           owner_type, owner_id, resource_owner, version
    FROM synex_entities
    WHERE deleted_at IS NULL AND status IN ('active', 'orphaned')
    ORDER BY entity_id
    LIMIT ?
]]

local SELECT_PERSISTENT_FOR_DRIFT = [[
    SELECT e.entity_id, e.generation, e.persistent_key, e.entity_type, e.model,
           e.owner_type, e.owner_id, e.resource_owner, e.bucket_id, e.status,
           e.version, b.binding_namespace, b.binding_ref
    FROM synex_entities e
    LEFT JOIN synex_entity_bindings b
        ON b.entity_id = e.entity_id AND b.released_at IS NULL
    WHERE e.deleted_at IS NULL AND e.status IN ('active', 'orphaned')
        AND e.entity_id > ?
    ORDER BY e.entity_id
    LIMIT ?
]]

local INSERT_PERSISTENT = [[
    INSERT INTO synex_entities (
        entity_id, generation, persistent_key, entity_type, vehicle_type, model,
        position_x, position_y, position_z, heading, ped_type, door_flag,
        owner_type, owner_id, resource_owner, bucket_id, status, version
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', 1)
]]

local UPDATE_REHYDRATED = [[
    UPDATE synex_entities
    SET generation = ?, bucket_id = 0, status = 'active', version = version + 1,
        updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND version = ? AND deleted_at IS NULL
]]

local CLAIM_PERSISTENT = [[
    UPDATE synex_entities
    SET status = 'active', version = version + 1, updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND version = ? AND deleted_at IS NULL AND status IN ('active', 'orphaned')
]]

local UPDATE_BUCKET = [[
    UPDATE synex_entities
    SET bucket_id = ?, version = version + 1, updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND version = ? AND deleted_at IS NULL AND status = 'active'
]]

local BEGIN_DELETE = [[
    UPDATE synex_entities
    SET status = 'deleting', version = version + 1, updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND version = ? AND deleted_at IS NULL AND status IN ('active', 'orphaned')
]]

local FINISH_DELETE = [[
    UPDATE synex_entities
    SET status = 'deleted', deleted_at = UTC_TIMESTAMP(3), version = version + 1,
        updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND status = 'deleting' AND deleted_at IS NULL
]]

local REVERT_DELETE = [[
    UPDATE synex_entities
    SET status = 'active', version = version + 1, updated_at = UTC_TIMESTAMP(3)
    WHERE entity_id = ? AND status = 'deleting' AND deleted_at IS NULL
]]

local RECONCILE_DELETING = [[
    UPDATE synex_entities
    SET updated_at = updated_at
    WHERE status = 'deleting' AND deleted_at IS NULL
]]

function SynexEntityRepository.create(options)
    assert(type(options) == 'table', 'entity repository options are required')
    local database = assert(options.database, 'entity repository database is required')
    local foundation = assert(options.foundation, 'entity repository foundation is required')
    local health = assert(options.health, 'entity repository health is required')
    local repository = {}

    local function portFailure(operation, caught, context)
        foundation.reportUnexpected(operation, caught, context)
        health.persistence = 'UNAVAILABLE'
        foundation.setHealth('UNHEALTHY', 'Entity persistence operation failed')
        return foundation.failure(
            'UNAVAILABLE',
            'Entity persistence is unavailable',
            true,
            context
        )
    end

    local function queryRows(operation, statement, parameters, context)
        local ok, rows = foundation.protect(operation, function()
            return database.query(statement, parameters)
        end, context)
        if not ok then
            health.persistence = 'UNAVAILABLE'
            foundation.setHealth('UNHEALTHY', 'Entity persistence query failed')
            return foundation.failure(
                'UNAVAILABLE',
                'Entity persistence is unavailable',
                true,
                context
            )
        end
        if type(rows) ~= 'table' then
            return portFailure(operation .. '.result', rows, context)
        end

        local count = 0
        local maximum = 0
        for index, row in pairs(rows) do
            if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or type(row) ~= 'table' then
                return portFailure(operation .. '.result', rows, context)
            end
            count = count + 1
            maximum = math.max(maximum, index)
        end
        if maximum ~= count then
            return portFailure(operation .. '.result', rows, context)
        end

        health.persistence = 'READY'
        return rows
    end

    local function updateCount(operation, statement, parameters, context, failureReason)
        local ok, affected = foundation.protect(operation, function()
            return database.update(statement, parameters)
        end, context)
        if not ok then
            health.persistence = 'UNAVAILABLE'
            foundation.setHealth('UNHEALTHY', failureReason or 'Entity persistence update failed')
            return foundation.failure(
                'UNAVAILABLE',
                'Entity persistence is unavailable',
                true,
                context
            )
        end
        if type(affected) ~= 'number' or affected ~= affected or affected % 1 ~= 0 or affected < 0 then
            return portFailure(operation .. '.result', affected, context)
        end

        health.persistence = 'READY'
        return affected
    end

    function repository.findPersistentByKey(persistentKey, context)
        return queryRows(
            'repository.find_persistent',
            SELECT_PERSISTENT_BY_KEY,
            { persistentKey },
            context
        )
    end

    function repository.listForRehydrate(limit, context)
        return queryRows(
            'repository.list_rehydrate',
            SELECT_PERSISTENT_FOR_REHYDRATE,
            { limit },
            context
        )
    end

    function repository.listForDrift(afterEntityId, limit, context)
        return queryRows(
            'repository.list_drift',
            SELECT_PERSISTENT_FOR_DRIFT,
            { afterEntityId, limit },
            context
        )
    end

    function repository.findForDriftByIds(entityIds, context)
        if #entityIds == 0 then return {} end
        local placeholders = {}
        for index = 1, #entityIds do placeholders[index] = '?' end
        -- Only the number of placeholders is assembled. Every identifier remains
        -- a positional value and the caller bounds each batch.
        local statement = [[SELECT e.entity_id, e.generation, e.persistent_key,
                e.entity_type, e.model, e.owner_type, e.owner_id,
                e.resource_owner, e.bucket_id, e.status, e.version,
                b.binding_namespace, b.binding_ref
            FROM synex_entities e
            LEFT JOIN synex_entity_bindings b
                ON b.entity_id = e.entity_id AND b.released_at IS NULL
            WHERE e.deleted_at IS NULL AND e.entity_id IN (]]
            .. table.concat(placeholders, ',') .. ')'
        return queryRows('repository.find_drift_ids', statement, entityIds, context)
    end

    function repository.insertPersistent(record, context)
        local doorFlagValue
        if record.doorFlag ~= nil then
            doorFlagValue = record.doorFlag and 1 or 0
        end
        return updateCount('repository.insert', INSERT_PERSISTENT, {
            record.entityId,
            record.generation,
            record.persistentKey,
            record.entityType,
            record.vehicleType,
            record.model,
            record.position.x,
            record.position.y,
            record.position.z,
            record.heading,
            record.pedType,
            doorFlagValue,
            record.owner.type,
            record.owner.id,
            record.resourceOwner,
            record.bucket,
        }, context, 'Entity persistence statement failed')
    end

    function repository.markRehydrated(entityId, generation, version, context)
        return updateCount(
            'repository.mark_rehydrated',
            UPDATE_REHYDRATED,
            { generation, entityId, version },
            context
        )
    end

    function repository.claimPersistent(entityId, version, context)
        return updateCount(
            'repository.claim',
            CLAIM_PERSISTENT,
            { entityId, version },
            context
        )
    end

    function repository.updateBucket(entityId, version, bucketId, context)
        return updateCount(
            'repository.update_bucket',
            UPDATE_BUCKET,
            { bucketId, entityId, version },
            context
        )
    end

    function repository.beginDelete(entityId, version, context)
        return updateCount(
            'repository.begin_delete',
            BEGIN_DELETE,
            { entityId, version },
            context
        )
    end

    function repository.finishDelete(entityId, context)
        return updateCount('repository.finish_delete', FINISH_DELETE, { entityId }, context)
    end

    function repository.revertDelete(entityId, context)
        return updateCount('repository.revert_delete', REVERT_DELETE, { entityId }, context)
    end

    function repository.reconcileDeleting(context)
        return updateCount('repository.reconcile_deleting', RECONCILE_DELETING, {}, context)
    end

    function repository.markOrphaned(records, context)
        local bucketCases = {}
        local placeholders = {}
        local parameters = {}
        for index, record in ipairs(records) do
            bucketCases[index] = 'WHEN ? THEN ?'
            placeholders[index] = '?'
            parameters[#parameters + 1] = record.entityId
            parameters[#parameters + 1] = record.bucket
        end
        for _, record in ipairs(records) do
            parameters[#parameters + 1] = record.entityId
        end

        -- Only fixed CASE/IN placeholder arity is assembled here; no record value
        -- or caller input becomes an SQL identifier or expression.
        local statement = [[
            UPDATE synex_entities
            SET bucket_id = CASE entity_id ]] .. table.concat(bucketCases, ' ') .. [[ ELSE bucket_id END,
                status = 'orphaned', version = version + 1,
                updated_at = UTC_TIMESTAMP(3)
            WHERE deleted_at IS NULL AND status IN ('active', 'orphaned')
                AND entity_id IN (]] .. table.concat(placeholders, ',') .. ')'
        return updateCount('repository.mark_orphaned', statement, parameters, context)
    end

    function repository.markDriftOrphans(entityIds, context)
        if #entityIds == 0 then return 0 end
        local placeholders = {}
        for index = 1, #entityIds do placeholders[index] = '?' end
        local statement = [[UPDATE synex_entities
            SET status = 'orphaned', version = version + 1, updated_at = UTC_TIMESTAMP(3)
            WHERE deleted_at IS NULL AND status = 'active'
                AND entity_id IN (]] .. table.concat(placeholders, ',') .. ')'
        return updateCount('repository.mark_drift_orphans', statement, entityIds, context)
    end

    function repository.retainCharacterEntities(characterId, retainedOwnerId, context)
        return updateCount('repository.retain_character_entities', [[UPDATE synex_entities
            SET owner_type = 'system', owner_id = ?, status = 'orphaned',
                version = version + 1, updated_at = UTC_TIMESTAMP(3)
            WHERE deleted_at IS NULL AND owner_type = 'character' AND owner_id = ?]],
            { retainedOwnerId, characterId }, context)
    end

    function repository.getCharacterOwnerSummary(characterId, context)
        local rows, queryError = queryRows('repository.character_owner_summary', [[SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                SUM(CASE WHEN status = 'orphaned' THEN 1 ELSE 0 END) AS orphaned
            FROM synex_entities
            WHERE deleted_at IS NULL AND owner_type = 'character' AND owner_id = ?]],
            { characterId }, context)
        if not rows then return nil, queryError end
        local row = rows[1] or {}
        return {
            total = tonumber(row.total) or 0,
            active = tonumber(row.active) or 0,
            orphaned = tonumber(row.orphaned) or 0,
        }
    end

    function repository.getPersistentSummary(context)
        local overview, overviewError = queryRows('repository.control_overview', [[SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                SUM(CASE WHEN status = 'orphaned' THEN 1 ELSE 0 END) AS orphaned,
                SUM(CASE WHEN status = 'deleting' THEN 1 ELSE 0 END) AS deleting,
                SUM(CASE WHEN status = 'deleted' THEN 1 ELSE 0 END) AS deleted
            FROM synex_entities]], {}, context)
        if not overview then return nil, overviewError end
        local byType, typeError = queryRows('repository.control_types', [[SELECT entity_type, status, COUNT(*) AS count
            FROM synex_entities GROUP BY entity_type, status
            ORDER BY entity_type ASC, status ASC LIMIT 24]], {}, context)
        if not byType then return nil, typeError end
        local byResource, resourceError = queryRows('repository.control_resources', [[SELECT resource_owner,
                SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active,
                SUM(CASE WHEN status = 'orphaned' THEN 1 ELSE 0 END) AS orphaned,
                COUNT(*) AS total
            FROM synex_entities WHERE deleted_at IS NULL
            GROUP BY resource_owner ORDER BY total DESC, resource_owner ASC LIMIT 24]], {}, context)
        if not byResource then return nil, resourceError end
        local row = overview[1] or {}
        return {
            total = tonumber(row.total) or 0,
            active = tonumber(row.active) or 0,
            orphaned = tonumber(row.orphaned) or 0,
            deleting = tonumber(row.deleting) or 0,
            deleted = tonumber(row.deleted) or 0,
            byType = byType,
            byResource = byResource,
        }
    end

    return repository
end
