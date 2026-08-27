SynexEntityAuthorityDiagnosticsRepository = {}

function SynexEntityAuthorityDiagnosticsRepository.attach(repository, shared)
    assert(type(repository) == 'table', 'entity authority repository is required')
    assert(type(shared) == 'table', 'entity authority repository shared state is required')
    local atomic = assert(shared.atomic, 'entity authority atomic helper is required')
    local boundedInteger = assert(shared.boundedInteger,
        'entity authority integer helper is required')
    local invalid = assert(shared.invalid, 'entity authority validation helper is required')

    local function validCursor(value)
        return value == nil or (type(value) == 'string' and #value >= 1
            and #value <= 64
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil)
    end

    local function validRuntimeEntityIds(values)
        if values == nil then return true end
        if type(values) ~= 'table' or #values > 51 then return false end
        local seen, count = {}, 0
        for key, value in pairs(values) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #values
                or type(value) ~= 'string' or #value < 1 or #value > 64
                or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
                or seen[value] then return false end
            seen[value], count = true, count + 1
        end
        return count == #values
    end

    function repository.diagnosticSnapshot(request, authority, context)
        if type(request) ~= 'table' then
            return invalid('The entity diagnostic request is invalid', context)
        end
        local allowed = { afterEntityId = true, limit = true,
            recoveryAttemptThreshold = true, runtimeEntityIds = true }
        for key in pairs(request) do
            if type(key) ~= 'string' or not allowed[key] then
                return invalid('The entity diagnostic request contains an unknown field', context)
            end
        end
        if not boundedInteger(request.limit, 1, 50)
            or not validCursor(request.afterEntityId)
            or not validRuntimeEntityIds(request.runtimeEntityIds)
            or not boundedInteger(request.recoveryAttemptThreshold, 1, 1000) then
            return invalid('The entity diagnostic bounds are invalid', context)
        end
        if type(authority) ~= 'table'
            or type(authority.serverScope) ~= 'string' or #authority.serverScope < 1
            or #authority.serverScope > 64
            or type(authority.instanceId) ~= 'string' or #authority.instanceId < 3
            or #authority.instanceId > 96
            or not boundedInteger(authority.resourceEpoch, 1, 9007199254740991) then
            return invalid('The entity diagnostic authority is invalid', context)
        end

        return atomic('entities.diagnostic_snapshot', context, function(transaction)
            local pageLimit = request.limit + 1
            local definitions = transaction.many([[SELECT `entity_id`, `generation`,
                    `owner_type`, `owner_id`, `resource_owner`, `bucket_id`,
                    `persistence_policy`, `recovery_policy`, `server_scope`, `status`,
                    `version`, `recovery_attempt_count`, `recovery_circuit_state`,
                    `last_recovery_failure_code`, `next_recovery_at`
                FROM `synex_entities`
                WHERE `deleted_at` IS NULL AND (? IS NULL OR `entity_id` > ?)
                ORDER BY `entity_id` LIMIT ?]], {
                request.afterEntityId, request.afterEntityId, pageLimit,
            }, pageLimit)
            local duplicateBindings = transaction.many([[SELECT `binding_namespace`,
                    `binding_ref`, COUNT(*) AS `total`
                FROM `synex_entity_bindings` WHERE `released_at` IS NULL
                GROUP BY `binding_namespace`, `binding_ref`
                HAVING COUNT(*) > 1 ORDER BY `binding_namespace`, `binding_ref` LIMIT ?]], {
                request.limit,
            }, request.limit)
            local duplicatePersistentKeys = transaction.many([[SELECT `resource_owner`,
                    `persistent_key`, COUNT(*) AS `total`
                FROM `synex_entities` WHERE `persistent_key` IS NOT NULL
                GROUP BY `resource_owner`, `persistent_key`
                HAVING COUNT(*) > 1 ORDER BY `resource_owner`, `persistent_key` LIMIT ?]], {
                request.limit,
            }, request.limit)
            local invalidOwners = transaction.many([[SELECT `entity_id`, `owner_type`,
                    `owner_id`, `resource_owner`
                FROM `synex_entities`
                WHERE `deleted_at` IS NULL AND (`owner_type` NOT IN
                    ('character', 'group', 'resource', 'system', 'user')
                    OR `owner_id` = ''
                    OR `resource_owner` NOT REGEXP '^[a-z][a-z0-9_]{1,63}$')
                ORDER BY `entity_id` LIMIT ?]], { request.limit }, request.limit)
            local staleBindings = transaction.many([[SELECT b.`entity_id`,
                    b.`binding_namespace`, b.`binding_ref`
                FROM `synex_entity_bindings` b
                INNER JOIN `synex_entities` e ON e.`entity_id` = b.`entity_id`
                WHERE b.`released_at` IS NULL AND e.`deleted_at` IS NOT NULL
                ORDER BY b.`entity_id` LIMIT ?]], { request.limit }, request.limit)
            local recovery = transaction.many([[SELECT `entity_id`, `generation`, `status`,
                    `recovery_attempt_count`, `recovery_circuit_state`,
                    `last_recovery_failure_code`, `next_recovery_at`
                FROM `synex_entities`
                WHERE `deleted_at` IS NULL AND (`status` = 'failed'
                    OR `recovery_circuit_state` = 'paused'
                    OR `recovery_attempt_count` >= ?)
                ORDER BY `recovery_attempt_count` DESC, `entity_id` LIMIT ?]], {
                request.recoveryAttemptThreshold, request.limit,
            }, request.limit)
            local leaseConflicts = transaction.many([[SELECT l.`entity_id`,
                    l.`server_scope`, l.`instance_id`, l.`resource_epoch`,
                    l.`lease_generation`, l.`heartbeat_at`, l.`lease_until`, l.`version`
                FROM `synex_entity_authority_leases` l
                INNER JOIN `synex_entities` e ON e.`entity_id` = l.`entity_id`
                WHERE e.`deleted_at` IS NULL AND e.`server_scope` = ?
                    AND e.`status` IN ('active', 'spawning', 'recovering')
                    AND l.`lease_state` = 'active'
                    AND l.`lease_until` > CURRENT_TIMESTAMP(6)
                    AND (l.`instance_id` <> ? OR l.`resource_epoch` <> ?)
                ORDER BY l.`entity_id` LIMIT ?]], {
                authority.serverScope, authority.instanceId,
                authority.resourceEpoch, request.limit,
            }, request.limit)
            local schemaLimit = request.limit + 1
            local componentSchemas = transaction.many([[SELECT c.`entity_id`,
                    c.`component_namespace`, c.`owner_resource`, c.`schema_version`
                FROM `synex_entity_components` c
                INNER JOIN `synex_entities` e ON e.`entity_id` = c.`entity_id`
                WHERE e.`deleted_at` IS NULL
                ORDER BY c.`entity_id`, c.`component_namespace` LIMIT ?]], {
                schemaLimit,
            }, schemaLimit)
            local stateSchemas = transaction.many([[SELECT s.`entity_id`,
                    s.`state_key`, s.`owner_resource`, s.`schema_version`
                FROM `synex_entity_states` s
                INNER JOIN `synex_entities` e ON e.`entity_id` = s.`entity_id`
                WHERE e.`deleted_at` IS NULL
                ORDER BY s.`entity_id`, s.`state_key` LIMIT ?]], {
                schemaLimit,
            }, schemaLimit)
            local knownRuntimeEntities = {}
            if request.runtimeEntityIds and #request.runtimeEntityIds > 0 then
                local placeholders, parameters = {}, {}
                for index, entityId in ipairs(request.runtimeEntityIds) do
                    placeholders[index], parameters[index] = '?', entityId
                end
                parameters[#parameters + 1] = #request.runtimeEntityIds
                knownRuntimeEntities = transaction.many([[SELECT `entity_id`
                    FROM `synex_entities` WHERE `deleted_at` IS NULL
                        AND `entity_id` IN (]] .. table.concat(placeholders, ',')
                    .. [[) ORDER BY `entity_id` LIMIT ?]], parameters,
                    #request.runtimeEntityIds)
            end
            local counts = transaction.one([[SELECT
                    (SELECT COUNT(*) FROM `synex_entities`
                        WHERE `deleted_at` IS NULL) AS `definitions`,
                    (SELECT COUNT(*) FROM `synex_entity_bindings`
                        WHERE `released_at` IS NULL) AS `active_bindings`,
                    (SELECT COUNT(*) FROM `synex_entity_components`) AS `components`,
                    (SELECT COUNT(*) FROM `synex_entity_states`) AS `states`,
                    (SELECT COUNT(*) FROM `synex_entity_tags`) AS `tags`,
                    (SELECT COUNT(*) FROM `synex_entity_checkpoints`) AS `checkpoints`,
                    (SELECT COUNT(*) FROM `synex_entity_authority_leases`
                        WHERE `lease_state` = 'active'
                            AND `lease_until` > CURRENT_TIMESTAMP(6)) AS `live_leases`,
                    (SELECT COUNT(*) FROM `synex_entity_recovery_history`) AS `recovery_history`,
                    (SELECT COUNT(*) FROM `synex_entities`
                        WHERE `deleted_at` IS NULL AND `status`
                            IN ('active', 'orphaned', 'dormant', 'failed')) AS `spawn_outcomes`,
                    (SELECT COUNT(*) FROM `synex_entities`
                        WHERE `deleted_at` IS NULL AND `status` = 'failed'
                            AND `last_reason_code` = 'synex.entities.spawn_failed')
                        AS `failed_spawns`]], {})

            local schemaInspectionTruncated = #componentSchemas > request.limit
                or #stateSchemas > request.limit
            if #componentSchemas > request.limit then componentSchemas[#componentSchemas] = nil end
            if #stateSchemas > request.limit then stateSchemas[#stateSchemas] = nil end

            local truncated = #definitions > request.limit
            if truncated then definitions[#definitions] = nil end
            return {
                counts = counts or {},
                componentSchemas = componentSchemas,
                definitions = definitions,
                duplicateBindings = duplicateBindings,
                duplicatePersistentKeys = duplicatePersistentKeys,
                invalidOwners = invalidOwners,
                knownRuntimeEntities = knownRuntimeEntities,
                leaseConflicts = leaseConflicts,
                nextAfterEntityId = truncated and definitions[#definitions].entity_id or nil,
                recovery = recovery,
                sampledRuntimeEntityIds = request.runtimeEntityIds or {},
                schemaInspectionTruncated = schemaInspectionTruncated,
                staleBindings = staleBindings,
                stateSchemas = stateSchemas,
                truncated = truncated,
            }
        end)
    end

    return repository
end
