SynexEntityAuthorityRecoveryRepository = {}

function SynexEntityAuthorityRecoveryRepository.attach(repository, shared)
    assert(type(repository) == 'table', 'entity authority repository is required')
    assert(type(shared) == 'table', 'entity authority repository shared state is required')
    local ENTITY_SELECT = assert(shared.ENTITY_SELECT, 'entity authority select is required')
    local atomic = assert(shared.atomic, 'entity authority atomic helper is required')
    local boundedInteger = assert(shared.boundedInteger, 'entity authority integer helper is required')
    local database = assert(shared.database, 'entity authority database is required')
    local definition = assert(shared.definition, 'entity authority definition mapper is required')
    local invalid = assert(shared.invalid, 'entity authority validation helper is required')
    local health = assert(shared.health, 'entity authority health state is required')
    local operationFailure = assert(shared.operationFailure,
        'entity authority persistence failure helper is required')
    local read = assert(shared.read, 'entity authority read helper is required')
    local safeReason = assert(shared.safeReason, 'entity authority reason helper is required')
    local safeTrace = assert(shared.safeTrace, 'entity authority trace helper is required')
    local validateAuthority = assert(shared.validateAuthority, 'entity authority fence helper is required')
    local validateOwner = assert(shared.validateOwner, 'entity authority owner helper is required')
    local bootReconcileLimit = assert(shared.bootReconcileLimit,
        'entity boot reconciliation limit is required')
    local recoveryHistoryRetentionSeconds = assert(shared.recoveryHistoryRetentionSeconds,
        'entity recovery history retention is required')

function repository.reconcileBootAuthority(serverScope, authority, context)
    local valid, authorityError = validateAuthority(authority, context)
    if not valid then return nil, authorityError end
    if serverScope ~= authority.serverScope then
        return invalid('Boot reconciliation scope does not match runtime authority', context)
    end
    local traceId = safeTrace(context)
    return atomic('entities.boot_authority_reconcile', context, function(transaction)
        local conflicts = transaction.one([[SELECT COUNT(*) AS `total`
            FROM `synex_entities` e
            INNER JOIN `synex_entity_authority_leases` l ON l.`entity_id` = e.`entity_id`
            WHERE e.`server_scope` = ? AND e.`deleted_at` IS NULL
                AND e.`status` IN ('active', 'spawning', 'recovering')
                AND l.`lease_state` = 'active' AND l.`lease_until` > CURRENT_TIMESTAMP(6)
                AND (l.`instance_id` <> ? OR l.`authority_token` <> ?
                    OR l.`resource_epoch` <> ?)]], {
            serverScope, authority.instanceId, authority.token, authority.resourceEpoch,
        })
        local rows = transaction.many([[SELECT e.`entity_id`, e.`status`, e.`recovery_policy`
            FROM `synex_entities` e
            WHERE e.`server_scope` = ? AND e.`deleted_at` IS NULL
                AND e.`status` IN ('active', 'spawning', 'recovering')
                AND NOT EXISTS (SELECT 1 FROM `synex_entity_authority_leases` l
                    WHERE l.`entity_id` = e.`entity_id` AND l.`lease_state` = 'active'
                        AND l.`lease_until` > CURRENT_TIMESTAMP(6))
            ORDER BY e.`entity_id` LIMIT ? FOR UPDATE]], {
            serverScope, bootReconcileLimit,
        }, bootReconcileLimit)
        if #rows == 0 then
            return {
                conflicts = conflicts and tonumber(conflicts.total) or 0,
                orphaned = 0,
                reconciled = 0,
                remaining = 0,
            }
        end
        local placeholders, parameters, orphaned = {}, { traceId }, 0
        for index, row in ipairs(rows) do
            placeholders[index] = '?'
            parameters[#parameters + 1] = row.entity_id
            if row.recovery_policy == 'automatic' then orphaned = orphaned + 1 end
        end
        parameters[#parameters + 1] = serverScope
        local changed = transaction.update([[UPDATE `synex_entities`
            SET `status` = CASE WHEN `recovery_policy` = 'automatic'
                    THEN 'orphaned' ELSE 'dormant' END,
                `bucket_id` = 0,
                `last_reason_code` = 'synex.entities.boot_reconciled',
                `last_trace_id` = ?, `version` = `version` + 1
            WHERE `entity_id` IN (]] .. table.concat(placeholders, ',') .. [[)
                AND `server_scope` = ? AND `deleted_at` IS NULL
                AND `status` IN ('active', 'spawning', 'recovering')
                AND NOT EXISTS (SELECT 1 FROM `synex_entity_authority_leases` l
                    WHERE l.`entity_id` = `synex_entities`.`entity_id`
                        AND l.`lease_state` = 'active'
                        AND l.`lease_until` > CURRENT_TIMESTAMP(6))]], parameters)
        if changed ~= #rows then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Boot authority reconciliation changed concurrently', retryable = true }
        end
        local remaining = transaction.one([[SELECT COUNT(*) AS `total`
            FROM `synex_entities` e
            WHERE e.`server_scope` = ? AND e.`deleted_at` IS NULL
                AND e.`status` IN ('active', 'spawning', 'recovering')
                AND NOT EXISTS (SELECT 1 FROM `synex_entity_authority_leases` l
                    WHERE l.`entity_id` = e.`entity_id` AND l.`lease_state` = 'active'
                        AND l.`lease_until` > CURRENT_TIMESTAMP(6))]], { serverScope })
        return {
            conflicts = conflicts and tonumber(conflicts.total) or 0,
            orphaned = orphaned,
            reconciled = changed,
            remaining = remaining and tonumber(remaining.total) or 0,
        }
    end)
end

function repository.heartbeat(authority, context)
    local valid, authorityError = validateAuthority(authority, context)
    if not valid then return nil, authorityError end
    local ok, affected = pcall(database.update, [[UPDATE `synex_entity_authority_leases`
        SET `heartbeat_at` = CURRENT_TIMESTAMP(6),
            `lease_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
            `version` = `version` + 1
        WHERE `instance_id` = ? AND `authority_token` = ? AND `resource_epoch` = ?
            AND `server_scope` = ? AND `lease_state` = 'active'
            AND `lease_until` > CURRENT_TIMESTAMP(6)]], {
        authority.leaseSeconds, authority.instanceId, authority.token,
        authority.resourceEpoch, authority.serverScope,
    })
    if not ok then return operationFailure(affected, context) end
    health.persistence = 'READY'
    return { renewed = affected }
end

function repository.releaseAuthority(authority, reasonCode, context)
    local valid, authorityError = validateAuthority(authority, context)
    if not valid then return nil, authorityError end
    if not safeReason(reasonCode) then
        return invalid('Authority release requires a namespaced reason code', context)
    end
    local traceId = safeTrace(context)
    local ok, affected = pcall(database.update, [[UPDATE `synex_entity_authority_leases`
        SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
            `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
            `last_trace_id` = ?, `version` = `version` + 1
        WHERE `instance_id` = ? AND `authority_token` = ? AND `resource_epoch` = ?
            AND `server_scope` = ? AND `lease_state` = 'active']], {
        traceId, authority.instanceId, authority.token, authority.resourceEpoch,
        authority.serverScope,
    })
    if not ok then return operationFailure(affected, context) end
    health.persistence = 'READY'
    return { reasonCode = reasonCode, released = affected }
end

function repository.recordRecoveryFailure(
    entityId, generation, authority, failureCode, policy, context
)
    local valid, authorityError = validateAuthority(authority, context)
    if not valid then return nil, authorityError end
    if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64
        or not boundedInteger(generation, 1, 9007199254740991)
        or type(failureCode) ~= 'string' or #failureCode < 3 or #failureCode > 64
        or failureCode:match('^[A-Z][A-Z0-9_]*$') == nil then
        return invalid('The recovery failure identity is invalid', context)
    end
    if type(policy) ~= 'table'
        or not boundedInteger(policy.maxAttempts, 1, 1000)
        or not boundedInteger(policy.windowSeconds, 1, 86400)
        or not boundedInteger(policy.baseDelaySeconds, 1, 3600)
        or not boundedInteger(policy.maxDelaySeconds, policy.baseDelaySeconds, 86400)
        or not boundedInteger(policy.jitterSeconds, 0, policy.maxDelaySeconds)
        or (policy.durationMs ~= nil
            and not boundedInteger(policy.durationMs, 0, 3600000)) then
        return invalid('The recovery backoff policy is invalid', context)
    end

    local traceId = safeTrace(context)
    return atomic('entities.recovery_failure', context, function(transaction)
        local entity = transaction.one([[SELECT `generation`, `status`, `recovery_policy`,
                `recovery_attempt_count`, `recovery_circuit_state`, `version`,
                (`recovery_window_started_at` IS NOT NULL
                    AND `recovery_window_started_at` >
                        TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))) AS `window_live`
            FROM `synex_entities`
            WHERE `entity_id` = ? AND `deleted_at` IS NULL FOR UPDATE]], {
            policy.windowSeconds, entityId,
        })
        if not entity then
            return nil, { code = 'ENTITY_NOT_FOUND', message = 'The recovery entity does not exist', retryable = false }
        end
        if tonumber(entity.generation) ~= generation or entity.status ~= 'recovering' then
            return nil, { code = 'STALE_ENTITY', message = 'The recovery entity generation is stale', retryable = false }
        end
        if entity.recovery_policy ~= 'automatic' then
            return nil, { code = 'RECOVERY_FAILED', message = 'Automatic recovery is not enabled for this entity', retryable = false }
        end
        if entity.recovery_circuit_state == 'paused' then
            return nil, { code = 'RECOVERY_PAUSED', message = 'Automatic recovery is paused for this entity', retryable = false }
        end

        local lease = transaction.one([[SELECT `lease_generation`, `version`
            FROM `synex_entity_authority_leases`
            WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                AND `resource_epoch` = ? AND `server_scope` = ?
                AND `lease_state` = 'active' AND `lease_until` > CURRENT_TIMESTAMP(6)
            FOR UPDATE]], {
            entityId, authority.instanceId, authority.token, authority.resourceEpoch,
            authority.serverScope,
        })
        if not lease then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The recovery authority lease was lost', retryable = true }
        end

        local windowLive = tonumber(entity.window_live) == 1
        local attempts = windowLive
            and math.min(1000, (tonumber(entity.recovery_attempt_count) or 0) + 1)
            or 1
        local paused = attempts >= policy.maxAttempts
        local delaySeconds
        if not paused then
            delaySeconds = policy.baseDelaySeconds
            for _ = 2, attempts do
                if delaySeconds >= policy.maxDelaySeconds then break end
                delaySeconds = math.min(policy.maxDelaySeconds, delaySeconds * 2)
            end
            local seed = generation + attempts
            for index = 1, #entityId do
                seed = (seed * 33 + entityId:byte(index)) % 2147483647
            end
            local jitter = policy.jitterSeconds == 0
                and 0 or seed % (policy.jitterSeconds + 1)
            delaySeconds = math.min(policy.maxDelaySeconds, delaySeconds + jitter)
        end

        local entityChanged
        if paused then
            entityChanged = transaction.update([[UPDATE `synex_entities`
                SET `status` = 'failed', `recovery_attempt_count` = ?,
                    `recovery_window_started_at` = CASE WHEN ? = 1
                        THEN `recovery_window_started_at` ELSE CURRENT_TIMESTAMP(6) END,
                    `next_recovery_at` = NULL, `recovery_circuit_state` = 'paused',
                    `last_recovery_failure_code` = ?,
                    `last_reason_code` = 'synex.entities.recovery_failed',
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `status` = 'recovering']], {
                attempts, windowLive and 1 or 0, failureCode, traceId,
                entityId, generation, tonumber(entity.version),
            })
        else
            entityChanged = transaction.update([[UPDATE `synex_entities`
                SET `status` = 'failed', `recovery_attempt_count` = ?,
                    `recovery_window_started_at` = CASE WHEN ? = 1
                        THEN `recovery_window_started_at` ELSE CURRENT_TIMESTAMP(6) END,
                    `next_recovery_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                    `recovery_circuit_state` = 'open',
                    `last_recovery_failure_code` = ?,
                    `last_reason_code` = 'synex.entities.recovery_failed',
                    `last_trace_id` = ?, `version` = `version` + 1
                WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                    AND `status` = 'recovering']], {
                attempts, windowLive and 1 or 0, delaySeconds, failureCode, traceId,
                entityId, generation, tonumber(entity.version),
            })
        end
        if entityChanged ~= 1 then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The recovery entity changed concurrently', retryable = true }
        end

        local outcome = paused and 'paused' or 'failed'
        local historyInserted = transaction.update([[INSERT INTO `synex_entity_recovery_history`
            (`entity_id`, `entity_generation`, `lease_generation`, `attempt_number`,
                `outcome`, `instance_id`, `failure_code`, `next_retry_at`, `duration_ms`,
                `trace_id`, `details_json`, `occurred_at`, `retain_until`)
            SELECT `entity_id`, `generation`, ?, ?, ?, ?, ?, `next_recovery_at`, ?, ?,
                JSON_OBJECT('delaySeconds', ?, 'windowReset', ?), CURRENT_TIMESTAMP(6),
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
            FROM `synex_entities` WHERE `entity_id` = ? AND `generation` = ?]], {
            tonumber(lease.lease_generation), attempts, outcome, authority.instanceId,
            failureCode, policy.durationMs, traceId, delaySeconds,
            windowLive and 0 or 1, recoveryHistoryRetentionSeconds, entityId, generation,
        })
        if historyInserted ~= 1 then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The recovery history could not be recorded', retryable = true }
        end

        local leaseReleased = transaction.update([[UPDATE `synex_entity_authority_leases`
            SET `lease_state` = 'released', `heartbeat_at` = CURRENT_TIMESTAMP(6),
                `lease_until` = CURRENT_TIMESTAMP(6), `released_at` = CURRENT_TIMESTAMP(6),
                `last_trace_id` = ?, `version` = `version` + 1
            WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                AND `resource_epoch` = ? AND `server_scope` = ?
                AND `lease_generation` = ? AND `version` = ?
                AND `lease_state` = 'active']], {
            traceId, entityId, authority.instanceId, authority.token,
            authority.resourceEpoch, authority.serverScope,
            tonumber(lease.lease_generation), tonumber(lease.version),
        })
        if leaseReleased ~= 1 then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The recovery lease changed during failure handling', retryable = true }
        end
        return {
            attempts = attempts,
            circuit = paused and 'paused' or 'open',
            delaySeconds = delaySeconds,
            status = 'failed',
            version = tonumber(entity.version) + 1,
        }
    end)
end

function repository.recordRecoverySuccess(
    entityId, generation, authority, durationMs, context
)
    local valid, authorityError = validateAuthority(authority, context)
    if not valid then return nil, authorityError end
    if type(entityId) ~= 'string' or #entityId < 1 or #entityId > 64
        or not boundedInteger(generation, 1, 9007199254740991)
        or not boundedInteger(durationMs, 0, 3600000) then
        return invalid('The recovery success identity is invalid', context)
    end
    local traceId = safeTrace(context)
    return atomic('entities.recovery_success', context, function(transaction)
        local entity = transaction.one([[SELECT `status`, `recovery_attempt_count`, `version`
            FROM `synex_entities`
            WHERE `entity_id` = ? AND `generation` = ? AND `deleted_at` IS NULL
                AND `status` IN ('active', 'recovering') FOR UPDATE]], {
            entityId, generation,
        })
        if not entity then
            return nil, { code = 'STALE_ENTITY', message = 'The recovered entity generation is stale', retryable = false }
        end
        local lease = transaction.one([[SELECT `lease_generation`
            FROM `synex_entity_authority_leases`
            WHERE `entity_id` = ? AND `instance_id` = ? AND `authority_token` = ?
                AND `resource_epoch` = ? AND `server_scope` = ?
                AND `lease_state` = 'active' AND `lease_until` > CURRENT_TIMESTAMP(6)
            FOR UPDATE]], {
            entityId, authority.instanceId, authority.token, authority.resourceEpoch,
            authority.serverScope,
        })
        if not lease then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', message = 'The recovered entity lost authority', retryable = true }
        end
        local attempts = math.max(1, tonumber(entity.recovery_attempt_count) or 0)
        local historyInserted = transaction.update([[INSERT INTO `synex_entity_recovery_history`
            (`entity_id`, `entity_generation`, `lease_generation`, `attempt_number`,
                `outcome`, `instance_id`, `failure_code`, `next_retry_at`, `duration_ms`,
                `trace_id`, `details_json`, `occurred_at`, `retain_until`)
            VALUES (?, ?, ?, ?, 'recovered', ?, NULL, NULL, ?, ?,
                JSON_OBJECT('attempts', ?), CURRENT_TIMESTAMP(6),
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]], {
            entityId, generation, tonumber(lease.lease_generation), attempts,
            authority.instanceId, durationMs, traceId, attempts,
            recoveryHistoryRetentionSeconds,
        })
        if historyInserted ~= 1 then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The recovery history could not be recorded', retryable = true }
        end
        local entityChanged = transaction.update([[UPDATE `synex_entities`
            SET `recovery_attempt_count` = 0, `recovery_window_started_at` = NULL,
                `next_recovery_at` = NULL, `recovery_circuit_state` = 'closed',
                `last_recovery_failure_code` = NULL,
                `last_reason_code` = 'synex.entities.recovered', `last_trace_id` = ?,
                `version` = `version` + 1
            WHERE `entity_id` = ? AND `generation` = ? AND `version` = ?
                AND `status` = ?]], {
            traceId, entityId, generation, tonumber(entity.version), entity.status,
        })
        if entityChanged ~= 1 then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'The recovered entity changed concurrently', retryable = true }
        end
        return { attempts = attempts, status = entity.status, version = tonumber(entity.version) + 1 }
    end)
end

function repository.listRecoverable(
    serverScope, afterDueAt, afterEntityId, limit, context
)
    if type(serverScope) ~= 'string' or #serverScope < 1 or #serverScope > 64
        or not boundedInteger(limit, 1, 100) then
        return invalid('The recovery page request is invalid', context)
    end
    local hasCursor = afterDueAt ~= nil or afterEntityId ~= nil
    if hasCursor and (type(afterDueAt) ~= 'string' or #afterDueAt ~= 26
        or afterDueAt:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d[.]%d%d%d%d%d%d$') == nil
        or type(afterEntityId) ~= 'string' or #afterEntityId < 1
        or #afterEntityId > 64) then
        return invalid('The recovery page cursor is invalid', context)
    end
    local sql = ENTITY_SELECT .. [[ WHERE `server_scope` = ? AND `deleted_at` IS NULL
        AND `recovery_policy` = 'automatic' AND `recovery_circuit_state` <> 'paused'
        AND `status` IN ('orphaned', 'failed')
        AND (`next_recovery_at` IS NULL OR `next_recovery_at` <= CURRENT_TIMESTAMP(6))]]
    local parameters = { serverScope }
    if hasCursor then
        sql = sql .. [[ AND (COALESCE(`next_recovery_at`,
                CAST('1000-01-01 00:00:00.000000' AS DATETIME(6))) > ?
            OR (COALESCE(`next_recovery_at`,
                CAST('1000-01-01 00:00:00.000000' AS DATETIME(6))) = ?
                AND `entity_id` > ?))]]
        parameters[#parameters + 1] = afterDueAt
        parameters[#parameters + 1] = afterDueAt
        parameters[#parameters + 1] = afterEntityId
    end
    sql = sql .. [[ ORDER BY COALESCE(`next_recovery_at`,
        CAST('1000-01-01 00:00:00.000000' AS DATETIME(6))), `entity_id` LIMIT ?]]
    parameters[#parameters + 1] = limit
    return read(sql, parameters, context, limit)
end

function repository.purgeRecoveryHistory(limit, context)
    if not boundedInteger(limit, 1, 100) then
        return invalid('The recovery retention batch is invalid', context)
    end
    return atomic('entities.recovery_retention', context, function(transaction)
        local rows = transaction.many([[SELECT `recovery_id`
            FROM `synex_entity_recovery_history`
            WHERE `retain_until` <= CURRENT_TIMESTAMP(6)
            ORDER BY `retain_until`, `recovery_id` LIMIT ? FOR UPDATE]], { limit }, limit)
        if #rows == 0 then return { purged = 0, remaining = 0 } end
        local ids, placeholders = {}, {}
        for index, row in ipairs(rows) do
            ids[index] = tonumber(row.recovery_id)
            placeholders[index] = '?'
        end
        local purged = transaction.update([[DELETE FROM `synex_entity_recovery_history`
            WHERE `recovery_id` IN (]] .. table.concat(placeholders, ',') .. [[)
                AND `retain_until` <= CURRENT_TIMESTAMP(6)]], ids)
        if purged ~= #ids then
            return nil, { code = 'CONCURRENT_MODIFICATION', message = 'Recovery retention changed concurrently', retryable = true }
        end
        local remaining = transaction.one([[SELECT COUNT(*) AS `total`
            FROM `synex_entity_recovery_history`
            WHERE `retain_until` <= CURRENT_TIMESTAMP(6)]], {})
        return { purged = purged, remaining = remaining and tonumber(remaining.total) or 0 }
    end)
end

    return repository
end
