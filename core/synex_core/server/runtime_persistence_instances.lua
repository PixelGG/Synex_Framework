local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimePersistenceInstances = function(context)
    local foundation = context.foundation
    local database = context.database
    local instanceId = context.instanceId
    local metrics = context.metrics
    local maintenanceBatchMaximum = context.maintenanceBatchMaximum
    local maximumLocalSessions = context.maximumLocalSessions
    local affectedRows = context.affectedRows
    local validateMaintenanceBatch = context.validateMaintenanceBatch
    local validateBoundedMutation = context.validateBoundedMutation
    local requireBootAuthority = context.requireBootAuthority
    local instanceSnapshot = context.instanceSnapshot
    local instances = context.instances

    function instances:register(name)
        if type(name) ~= 'string' or #name < 1 or #name > 96 or name:find('[%z\1-\31\127]') then
            return nil, foundation.error('INVALID_INSTANCE_NAME', 'Instance name must be a bounded printable string.')
        end
        local candidateBootId = foundation.nextId('boot')
        if type(candidateBootId) ~= 'string' or #candidateBootId < 1 or #candidateBootId > 36 then
            return nil, foundation.error('INVALID_BOOT_ID', 'The runtime boot generation is invalid.')
        end
        context.bootRegistered = false
        context.bootId = nil
        local registered, err = database:transaction({
            {
                query = [[INSERT INTO `synex_instances`
                    (`instance_id`, `name`, `started_at`, `heartbeat_at`, `status`, `version`)
                    VALUES (?, ?, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), 'starting', 1)
                    ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `started_at` = CURRENT_TIMESTAMP(6),
                        `heartbeat_at` = CURRENT_TIMESTAMP(6), `status` = 'starting', `version` = `version` + 1]],
                values = { instanceId, name }
            },
            {
                query = [[INSERT INTO `synex_instance_boots` (`instance_id`, `boot_id`, `registered_at`)
                    VALUES (?, ?, CURRENT_TIMESTAMP(6))
                    ON DUPLICATE KEY UPDATE `boot_id` = VALUES(`boot_id`),
                        `registered_at` = CURRENT_TIMESTAMP(6)]],
                values = { instanceId, candidateBootId }
            }
        })
        if not registered then return nil, err end
        context.bootId = candidateBootId
        context.bootRegistered = true
        context.controlAuditCursor = ''
        instanceSnapshot.status = 'starting'
        instanceSnapshot.refreshedAt = foundation.utcIso()
        return true, nil
    end

    function instances:bootId()
        return requireBootAuthority()
    end

    function instances:terminateLocalSessions(reason)
        if type(reason) ~= 'string' or #reason < 1 or #reason > 128 or reason:find('[%z\1-\31\127]') then
            return nil, foundation.error('INVALID_CLOSE_REASON',
                'Local session termination requires a bounded printable reason.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local leaseOwnerLowerBound = instanceId .. ':'
        local leaseOwnerUpperBound = instanceId .. ';'
        local maximumConnectionLeases = maximumLocalSessions * 2
        local authorityError = nil
        local terminated, terminationError = database:withTransaction(function(query)
            local authority = query([[SELECT `boot_id` FROM `synex_instance_boots`
                WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
                { instanceId, activeBootId }) or {}
            if not authority[1] then
                authorityError = foundation.error('INSTANCE_BOOT_AUTHORITY_LOST',
                    'The runtime boot generation no longer owns the instance.')
                return false
            end
            local leaseRows, seenLeases = {}, {}
            for _, leaseKind in ipairs({ 'admission', 'session' }) do
                local remaining = maximumConnectionLeases + 1 - #leaseRows
                local kindRows = query([[SELECT `lease_name`, `owner_id`,
                        CAST(`fencing_token` AS CHAR) AS `fencing_token`,
                        `lease_authority_kind`
                    FROM `synex_cluster_leases`
                        FORCE INDEX (`idx_cluster_leases_authority_owner`)
                    WHERE `lease_authority_kind` = ?
                        AND `terminal_compaction_at` IS NULL
                        AND `owner_id` >= ? AND `owner_id` < ?
                    ORDER BY `owner_id` ASC, `lease_name` ASC
                    LIMIT ? FOR UPDATE]], {
                    leaseKind, leaseOwnerLowerBound, leaseOwnerUpperBound, remaining
                })
                if type(kindRows) ~= 'table' or #kindRows > remaining then
                    authorityError = foundation.error('DATABASE_RESULT_INVALID',
                        'Local connection lease recovery returned an invalid candidate batch.', {
                            retryable = true
                        })
                    return false
                end
                for _, lease in ipairs(kindRows) do leaseRows[#leaseRows + 1] = lease end
                if #leaseRows > maximumConnectionLeases then
                    authorityError = foundation.error('RUNTIME_MUTATION_BOUND_INVALID',
                        'Local connection lease recovery exceeded its configured bound.', {
                            retryable = true,
                            details = { operation = 'terminate_local_connection_leases' }
                        })
                    return false
                end
            end
            for _, lease in ipairs(leaseRows) do
                local leaseKind = type(lease) == 'table'
                    and lease.lease_authority_kind or nil
                local leasePrefix = type(leaseKind) == 'string' and leaseKind .. ':' or nil
                local fencingToken = type(lease) == 'table' and lease.fencing_token or nil
                if type(lease) ~= 'table' or type(lease.lease_name) ~= 'string'
                    or type(leasePrefix) ~= 'string'
                    or #lease.lease_name <= #leasePrefix or #lease.lease_name > 96
                    or lease.lease_name:sub(1, #leasePrefix) ~= leasePrefix
                    or type(lease.owner_id) ~= 'string'
                    or #lease.owner_id < 1 or #lease.owner_id > 96
                    or lease.owner_id < leaseOwnerLowerBound or lease.owner_id >= leaseOwnerUpperBound
                    or (lease.lease_authority_kind ~= 'session'
                        and lease.lease_authority_kind ~= 'admission')
                    or type(fencingToken) ~= 'string'
                    or not fencingToken:match('^[1-9][0-9]*$') or #fencingToken > 20
                    or (#fencingToken == 20 and fencingToken > '18446744073709551615')
                    or seenLeases[lease.lease_name] then
                    authorityError = foundation.error('DATABASE_RESULT_INVALID',
                        'Local connection lease recovery returned an invalid candidate batch.', {
                            retryable = true
                        })
                    return false
                end
                seenLeases[lease.lease_name] = true
            end
            if #leaseRows > 0 then
                local names, placeholders = {}, {}
                for index, lease in ipairs(leaseRows) do
                    names[index], placeholders[index] = lease.lease_name, '?'
                end
                local expiredLeases = query([[UPDATE `synex_cluster_leases`
                        FORCE INDEX (`PRIMARY`)
                    SET `owner_id` = 'retired',
                        `fencing_token` = CASE
                            WHEN `fencing_token` < 18446744073709551615
                                THEN `fencing_token` + 1
                            ELSE `fencing_token`
                        END,
                        `expires_at` = CURRENT_TIMESTAMP(6),
                        `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                    WHERE `terminal_compaction_at` IS NULL
                        AND `lease_name` IN (]] .. table.concat(placeholders, ',') .. ')', names)
                local retiredLeaseCount, leaseBoundError = validateBoundedMutation(
                    expiredLeases, maximumConnectionLeases,
                    'terminate_local_connection_leases')
                if leaseBoundError then authorityError = leaseBoundError return false end
                if retiredLeaseCount ~= #leaseRows then
                    authorityError = foundation.error('DATABASE_RESULT_INVALID',
                        'Local connection lease recovery did not match the locked candidate batch.', {
                            retryable = true
                        })
                    return false
                end
            end
            for _, leaseKind in ipairs({ 'admission', 'session' }) do
                local residual = query([[SELECT `lease_name`
                    FROM `synex_cluster_leases`
                        FORCE INDEX (`idx_cluster_leases_authority_owner`)
                    WHERE `lease_authority_kind` = ?
                        AND `terminal_compaction_at` IS NULL
                        AND `owner_id` >= ? AND `owner_id` < ?
                    ORDER BY `owner_id` ASC, `lease_name` ASC
                    LIMIT 1 FOR UPDATE]], {
                    leaseKind, leaseOwnerLowerBound, leaseOwnerUpperBound
                })
                if type(residual) ~= 'table' or #residual > 1 or residual[1] ~= nil then
                    authorityError = foundation.error('DATABASE_RESULT_INVALID',
                        'Local connection lease recovery left residual runtime authority.', {
                            retryable = true
                        })
                    return false
                end
            end
            local expiredControls = query([[UPDATE `synex_session_control_requests` AS `request`
                INNER JOIN (
                    SELECT `bounded_control`.`request_id` FROM (
                        SELECT `candidate`.`request_id`
                        FROM (
                            (SELECT `outgoing`.`request_id`, `outgoing`.`created_at`
                                FROM `synex_session_control_requests` AS `outgoing`
                                    FORCE INDEX (`idx_session_control_requester_pending`)
                                WHERE `outgoing`.`requested_by_instance_id` = ?
                                    AND `outgoing`.`state` = 'pending'
                                ORDER BY `outgoing`.`created_at` ASC,
                                    `outgoing`.`request_id` ASC LIMIT ?)
                            UNION
                            (SELECT `incoming`.`request_id`, `incoming`.`created_at`
                                FROM `synex_session_control_requests` AS `incoming`
                                    FORCE INDEX (`idx_session_control_target_pending`)
                                WHERE `incoming`.`state` = 'pending'
                                    AND `incoming`.`target_instance_id` = ?
                                ORDER BY `incoming`.`expires_at` ASC,
                                    `incoming`.`created_at` ASC,
                                    `incoming`.`request_id` ASC LIMIT ?)
                        ) AS `candidate`
                        ORDER BY `candidate`.`created_at` ASC,
                            `candidate`.`request_id` ASC LIMIT ?
                    ) AS `bounded_control`
                ) AS `selected_control`
                    ON `selected_control`.`request_id` = `request`.`request_id`
                SET `request`.`state` = 'expired', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `request`.`state` = 'pending'
                    AND (`request`.`requested_by_instance_id` = ?
                        OR `request`.`target_instance_id` = ?)]], {
                instanceId, maintenanceBatchMaximum,
                instanceId, maintenanceBatchMaximum, maintenanceBatchMaximum,
                instanceId, instanceId
            })
            local _, controlBoundError = validateMaintenanceBatch(
                expiredControls, 'terminate_local_session_controls')
            if controlBoundError then authorityError = controlBoundError return false end
            local closedSessions = query([[UPDATE `synex_sessions` AS `session`
                SET `session`.`state` = 'CLOSED', `session`.`closed_at` = CURRENT_TIMESTAMP(6),
                    `session`.`close_reason` = ?, `session`.`version` = `session`.`version` + 1
                WHERE `session`.`server_instance_id` = ? AND `session`.`closed_at` IS NULL]],
                { reason, instanceId })
            local _, sessionBoundError = validateBoundedMutation(
                closedSessions, maximumLocalSessions, 'terminate_local_sessions')
            if sessionBoundError then authorityError = sessionBoundError return false end
            return true
        end)
        if not terminated then return nil, authorityError or terminationError end
        metrics:increment('synex_local_session_termination_total', { result = 'complete' })
        return true, nil
    end

    function instances:sourceGenerationFloor()
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local rows, err = database:query([[SELECT COALESCE((
                SELECT `session`.`source_generation`
                FROM `synex_sessions` AS `session`
                WHERE `session`.`server_instance_id` = `boot`.`instance_id`
                ORDER BY `session`.`source_generation` DESC LIMIT 1
            ), 0) AS `source_generation_floor`
            FROM `synex_instance_boots` AS `boot`
            WHERE `boot`.`instance_id` = ? AND `boot`.`boot_id` = ? LIMIT 1]],
            { instanceId, activeBootId })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then
            return nil, foundation.error('INSTANCE_BOOT_AUTHORITY_LOST',
                'The runtime boot generation no longer owns the instance.')
        end
        local generation = row and tonumber(row.source_generation_floor) or nil
        if not generation or math.type(generation) ~= 'integer'
            or generation < 0 or generation > 9007199254740990 then
            return nil, foundation.error('INVALID_SOURCE_GENERATION',
                'The persisted source generation floor is invalid.')
        end
        return generation, nil
    end

    function instances:setStatus(status)
        local allowed = { starting = true, ready = true, degraded = true, stopping = true, stopped = true, stale = true }
        if not allowed[status] then return nil, foundation.error('INVALID_INSTANCE_STATUS', 'Instance status is invalid.') end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local affected, err = database:update([[UPDATE `synex_instances` AS `instance`
            INNER JOIN `synex_instance_boots` AS `boot`
                ON `boot`.`instance_id` = `instance`.`instance_id` AND `boot`.`boot_id` = ?
            SET `instance`.`status` = ?, `instance`.`heartbeat_at` = CURRENT_TIMESTAMP(6),
                `instance`.`version` = `instance`.`version` + 1
            WHERE `instance`.`instance_id` = ?
                AND (CASE
                    WHEN ? IN ('ready', 'degraded') THEN `instance`.`status` NOT IN ('stopping', 'stopped')
                    WHEN ? IN ('starting', 'stopping', 'stale') THEN `instance`.`status` <> 'stopped'
                    ELSE TRUE
                END)]], { activeBootId, status, instanceId, status, status })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then
            return nil, foundation.error('INSTANCE_NOT_REGISTERED', 'The runtime instance is not registered.', { retryable = true })
        end
        instanceSnapshot.status = status
        if status == 'starting' or status == 'ready' or status == 'degraded' then
            instanceSnapshot.total = math.max(1, instanceSnapshot.total)
            instanceSnapshot.healthy = math.max(1, instanceSnapshot.healthy)
        end
        instanceSnapshot.refreshedAt = foundation.utcIso()
        return true, nil
    end

    function instances:heartbeat(staleSeconds, authorityGuard)
        authorityGuard = type(authorityGuard) == 'function' and authorityGuard or function() return true end
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        staleSeconds = math.max(10, math.min(math.floor(tonumber(staleSeconds) or 45), 300))
        local recoveryStatus = instanceSnapshot.status
        local updated, updateError = database:update([[UPDATE `synex_instances` AS `instance`
            INNER JOIN `synex_instance_boots` AS `boot`
                ON `boot`.`instance_id` = `instance`.`instance_id` AND `boot`.`boot_id` = ?
            SET `instance`.`heartbeat_at` = CURRENT_TIMESTAMP(6),
                `instance`.`status` = CASE WHEN `instance`.`status` = 'stale' THEN ? ELSE `instance`.`status` END,
                `instance`.`version` = `instance`.`version` + 1
            WHERE `instance`.`instance_id` = ? AND `instance`.`status` NOT IN ('stopping', 'stopped')]],
            { activeBootId, recoveryStatus, instanceId })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if updateError then return nil, updateError end
        if tonumber(updated) ~= 1 then
            return nil, foundation.error('INSTANCE_HEARTBEAT_REJECTED', 'The instance heartbeat was rejected.', { retryable = true })
        end
        local staleUpdated, staleError = database:update([[UPDATE `synex_instances` AS `candidate`
            INNER JOIN (
                SELECT `bounded_instance`.`instance_id` FROM (
                    SELECT `stale_candidate`.`instance_id`
                    FROM `synex_instances` AS `stale_candidate`
                    WHERE `stale_candidate`.`instance_id` <> ?
                        AND `stale_candidate`.`status` NOT IN ('stale', 'stopped')
                        AND `stale_candidate`.`heartbeat_at`
                            < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))
                    ORDER BY `stale_candidate`.`heartbeat_at` ASC,
                        `stale_candidate`.`instance_id` ASC LIMIT ?
                ) AS `bounded_instance`
            ) AS `selected_instance`
                ON `selected_instance`.`instance_id` = `candidate`.`instance_id`
            INNER JOIN `synex_instance_boots` AS `authority`
                ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
            SET `candidate`.`status` = 'stale', `candidate`.`version` = `candidate`.`version` + 1
            WHERE `candidate`.`instance_id` <> ? AND `candidate`.`status` NOT IN ('stale', 'stopped')
                AND `candidate`.`heartbeat_at` < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))]],
            { instanceId, staleSeconds, maintenanceBatchMaximum,
                instanceId, activeBootId, instanceId, staleSeconds })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if staleError then return nil, staleError end
        local _, staleBatchError = validateMaintenanceBatch(staleUpdated, 'stale_instances')
        if staleBatchError then return nil, staleBatchError end
        local sessionsClosed, sessionFailure = 0, nil
        local sessionsCleaned, sessionError = database:withTransaction(function(query)
            sessionFailure = nil
            local authority = query([[SELECT `boot_id` FROM `synex_instance_boots`
                WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
                { instanceId, activeBootId }) or {}
            if not authorityGuard() then return false end
            if not authority[1] then
                sessionFailure = foundation.error('INSTANCE_BOOT_AUTHORITY_LOST',
                    'Stale session cleanup lost runtime boot authority.', { retryable = true })
                return false
            end
            local rows = query([[SELECT `stale_session`.`id`, `stale_session`.`user_id`,
                    `stale_session`.`server_instance_id`
                FROM `synex_sessions` AS `stale_session`
                    FORCE INDEX (`idx_sessions_open_heartbeat_expiry`)
                INNER JOIN `synex_instances` AS `stale_instance`
                    ON `stale_instance`.`instance_id` = `stale_session`.`server_instance_id`
                WHERE `stale_session`.`closed_at` IS NULL
                    AND `stale_instance`.`status` = 'stale'
                    AND `stale_session`.`last_seen_at`
                        < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))
                ORDER BY `stale_session`.`last_seen_at` ASC,
                    `stale_session`.`id` ASC LIMIT ? FOR UPDATE]],
                { staleSeconds, maintenanceBatchMaximum }) or {}
            if not authorityGuard() then return false end
            if type(rows) ~= 'table' or #rows > maintenanceBatchMaximum then
                sessionFailure = foundation.error('MAINTENANCE_BATCH_INVALID',
                    'Stale session cleanup returned an invalid candidate batch.', {
                        retryable = true
                    })
                return false
            end
            if #rows == 0 then return true end
            local ids, placeholders, seen = {}, {}, {}
            for index, row in ipairs(rows) do
                if type(row) ~= 'table' or type(row.id) ~= 'string'
                    or #row.id < 1 or #row.id > 36 or seen[row.id]
                    or type(row.user_id) ~= 'string' or #row.user_id < 1 or #row.user_id > 36
                    or type(row.server_instance_id) ~= 'string'
                    or #row.server_instance_id < 1 or #row.server_instance_id > 36 then
                    sessionFailure = foundation.error('DATABASE_RESULT_INVALID',
                        'Stale session cleanup returned an invalid durable session identity.', {
                            retryable = true
                        })
                    return false
                end
                seen[row.id] = true
                ids[index], placeholders[index] = row.id, '?'
            end
            local leaseParameters = {}
            for _, id in ipairs(ids) do leaseParameters[#leaseParameters + 1] = id end
            leaseParameters[#leaseParameters + 1] = staleSeconds
            local retiredLeases = query([[UPDATE `synex_cluster_leases` AS `lease`
                INNER JOIN `synex_sessions` AS `session`
                    ON `session`.`id` IN (]] .. table.concat(placeholders, ',') .. [[)
                        AND `session`.`closed_at` IS NULL
                        AND `session`.`last_seen_at`
                            < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))
                        AND `lease`.`owner_id`
                            = CONCAT(`session`.`server_instance_id`, ':', `session`.`id`)
                        AND `lease`.`lease_name` IN (
                            CONCAT('session:', `session`.`user_id`),
                            CONCAT('session:', `session`.`user_id`, ':', `session`.`id`)
                        )
                INNER JOIN `synex_instances` AS `stale_instance`
                    ON `stale_instance`.`instance_id` = `session`.`server_instance_id`
                        AND `stale_instance`.`status` = 'stale'
                SET `lease`.`owner_id` = 'retired',
                    `lease`.`fencing_token` = CASE
                        WHEN `lease`.`fencing_token` < 18446744073709551615
                            THEN `lease`.`fencing_token` + 1
                        ELSE `lease`.`fencing_token`
                    END,
                    `lease`.`expires_at` = CURRENT_TIMESTAMP(6),
                    `lease`.`terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease`.`terminal_compaction_at` IS NULL]], leaseParameters)
            if not authorityGuard() then return false end
            local _, leaseBatchError = validateBoundedMutation(
                retiredLeases, #rows * 2, 'stale_session_leases')
            if leaseBatchError then sessionFailure = leaseBatchError return false end
            local closeParameters = {}
            for _, id in ipairs(ids) do closeParameters[#closeParameters + 1] = id end
            closeParameters[#closeParameters + 1] = staleSeconds
            local closed = query([[UPDATE `synex_sessions` AS `session`
                INNER JOIN `synex_instances` AS `stale_instance`
                    ON `stale_instance`.`instance_id` = `session`.`server_instance_id`
                        AND `stale_instance`.`status` = 'stale'
                SET `session`.`state` = 'CLOSED',
                    `session`.`closed_at` = CURRENT_TIMESTAMP(6),
                    `session`.`close_reason` = 'instance heartbeat expired',
                    `session`.`version` = `session`.`version` + 1
                WHERE `session`.`closed_at` IS NULL AND `session`.`id` IN (]]
                .. table.concat(placeholders, ',') .. [[)
                    AND `session`.`last_seen_at`
                        < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))]], closeParameters)
            if not authorityGuard() then return false end
            sessionsClosed = affectedRows(closed)
            if not sessionsClosed or math.type(sessionsClosed) ~= 'integer'
                or sessionsClosed ~= #rows then
                sessionFailure = foundation.error('MAINTENANCE_BATCH_INVALID',
                    'Stale session cleanup did not close the exact locked batch.', {
                        retryable = true
                    })
                return false
            end
            return true
        end)
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if not sessionsCleaned then return nil, sessionFailure or sessionError end
        local _, sessionBatchError = validateMaintenanceBatch(sessionsClosed, 'stale_sessions')
        if sessionBatchError then return nil, sessionBatchError end
        local controlsExpired, expiredError = database:update([[UPDATE `synex_session_control_requests` AS `request`
            INNER JOIN (
                SELECT `bounded_request`.`request_id` FROM (
                    SELECT `candidate_request`.`request_id`
                    FROM `synex_session_control_requests` AS `candidate_request`
                        FORCE INDEX (`idx_session_control_dispatch`)
                    WHERE `candidate_request`.`state` = 'pending'
                        AND `candidate_request`.`expires_at` <= CURRENT_TIMESTAMP(6)
                    ORDER BY `candidate_request`.`expires_at` ASC,
                        `candidate_request`.`target_session_id` ASC LIMIT ?
                ) AS `bounded_request`
            ) AS `selected_request`
                ON `selected_request`.`request_id` = `request`.`request_id`
            INNER JOIN `synex_instance_boots` AS `authority`
                ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
            SET `request`.`state` = 'expired', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `request`.`state` = 'pending'
                AND `request`.`expires_at` <= CURRENT_TIMESTAMP(6)]],
            { maintenanceBatchMaximum, instanceId, activeBootId })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if expiredError then return nil, expiredError end
        local _, controlBatchError = validateMaintenanceBatch(
            controlsExpired, 'expired_session_control_requests')
        if controlBatchError then return nil, controlBatchError end
        local auditRows, auditError = database:query([[SELECT `request_id`
            FROM `synex_session_control_requests`
                FORCE INDEX (`idx_session_control_state_scan`)
            WHERE `state` = 'pending' AND `request_id` > ?
            ORDER BY `request_id` ASC LIMIT ?]], {
            context.controlAuditCursor, maintenanceBatchMaximum
        })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if auditError then return nil, auditError end
        if type(auditRows) ~= 'table' or #auditRows > maintenanceBatchMaximum then
            return nil, foundation.error('CLUSTER_CONTROL_SCAN_INVALID',
                'The bounded control-authority scan is invalid.', { retryable = true })
        end
        if #auditRows == 0 then
            context.controlAuditCursor = ''
        else
            local requestIds, placeholders, seen = {}, {}, {}
            for index, row in ipairs(auditRows) do
                local requestId = type(row) == 'table' and row.request_id or nil
                if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 36
                    or requestId:find('[%z\1-\31\127]') or seen[requestId]
                    or (index > 1 and requestIds[index - 1] >= requestId) then
                    return nil, foundation.error('CLUSTER_CONTROL_SCAN_INVALID',
                        'The bounded control-authority scan returned an invalid identity.', {
                            retryable = true
                        })
                end
                seen[requestId] = true
                requestIds[index] = requestId
                placeholders[index] = '?'
            end
            local auditParameters = { instanceId, activeBootId }
            for _, requestId in ipairs(requestIds) do
                auditParameters[#auditParameters + 1] = requestId
            end
            local invalidControls, invalidControlError = database:update([[
                UPDATE `synex_session_control_requests` AS `request`
                INNER JOIN `synex_instances` AS `requester`
                    ON `requester`.`instance_id` = `request`.`requested_by_instance_id`
                INNER JOIN `synex_instance_boots` AS `authority`
                    ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
                LEFT JOIN `synex_session_control_authority` AS `request_claim`
                    ON `request_claim`.`request_id` = `request`.`request_id`
                LEFT JOIN `synex_instance_boots` AS `requester_boot`
                    ON `requester_boot`.`instance_id` = `requester`.`instance_id`
                SET `request`.`state` = 'expired',
                    `request`.`completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `request`.`state` = 'pending'
                    AND `request`.`request_id` IN (]] .. table.concat(placeholders, ',') .. [[)
                    AND (`requester`.`status` <> 'ready'
                        OR `request`.`created_at` < `requester`.`started_at`
                        OR `request_claim`.`request_id` IS NULL
                        OR `requester_boot`.`boot_id` IS NULL
                        OR `request_claim`.`requester_boot_id` <> `requester_boot`.`boot_id`)]],
                auditParameters)
            if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
            if invalidControlError then return nil, invalidControlError end
            local invalidCount, invalidBatchError = validateMaintenanceBatch(
                invalidControls, 'invalid_session_control_requests')
            if invalidBatchError or invalidCount > #requestIds then
                return nil, invalidBatchError or foundation.error('MAINTENANCE_BATCH_INVALID',
                    'Runtime maintenance exceeded its bounded control scan.', {
                        retryable = true,
                        details = { operation = 'invalid_session_control_requests' }
                    })
            end
            context.controlAuditCursor = requestIds[#requestIds]
        end
        local rows, summaryError = database:query([[SELECT `status`
            FROM `synex_instances`
            ORDER BY `instance_id` ASC LIMIT ?]], { maintenanceBatchMaximum + 1 })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if summaryError then return nil, summaryError end
        if type(rows) ~= 'table' or #rows > maintenanceBatchMaximum + 1 then
            return nil, foundation.error('CLUSTER_SUMMARY_INVALID',
                'The bounded cluster instance summary is invalid.', { retryable = true })
        end
        local healthy, stale = 0, 0
        local summaryCount = math.min(#rows, maintenanceBatchMaximum)
        for index = 1, summaryCount do
            local row = rows[index]
            local status = type(row) == 'table' and row.status or nil
            if status == 'starting' or status == 'ready' or status == 'degraded' then
                healthy = healthy + 1
            elseif status == 'stale' then
                stale = stale + 1
            elseif status ~= 'stopping' and status ~= 'stopped' then
                return nil, foundation.error('CLUSTER_SUMMARY_INVALID',
                    'The bounded cluster instance summary contains an invalid status.', {
                        retryable = true
                    })
            end
        end
        local pending, pendingError = database:scalar([[SELECT COUNT(*) FROM (
                SELECT `request_id` FROM `synex_session_control_requests`
                WHERE `state` = 'pending'
                ORDER BY `expires_at` ASC, `target_session_id` ASC LIMIT ?
            ) AS `bounded_pending_requests`]], { maintenanceBatchMaximum + 1 })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if pendingError then return nil, pendingError end
        pending = tonumber(pending)
        if not pending or math.type(pending) ~= 'integer'
            or pending < 0 or pending > maintenanceBatchMaximum + 1 then
            return nil, foundation.error('CLUSTER_SUMMARY_INVALID',
                'The bounded pending control summary is invalid.', { retryable = true })
        end
        instanceSnapshot.total = summaryCount
        instanceSnapshot.healthy = healthy
        instanceSnapshot.stale = stale
        instanceSnapshot.pendingControlRequests = math.min(pending, maintenanceBatchMaximum)
        instanceSnapshot.instanceSummaryTruncated = #rows > maintenanceBatchMaximum
        instanceSnapshot.pendingControlRequestsTruncated = pending > maintenanceBatchMaximum
        instanceSnapshot.refreshedAt = foundation.utcIso()
        metrics:gauge('synex_cluster_instances', { status = 'healthy' }, instanceSnapshot.healthy)
        metrics:gauge('synex_cluster_instances', { status = 'stale' }, instanceSnapshot.stale)
        return foundation.copy(instanceSnapshot), nil
    end

    function instances:touchSessions(sessionIds, authorityGuard)
        if type(sessionIds) ~= 'table' then return nil, foundation.error('INVALID_ARGUMENT', 'Session IDs must be an array.') end
        if #sessionIds == 0 then return true, nil end
        authorityGuard = type(authorityGuard) == 'function' and authorityGuard or function() return true end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local offset = 1
        while offset <= #sessionIds do
            if not authorityGuard() then return true, nil end
            local parameters = { activeBootId, instanceId }
            local placeholders = {}
            local maximum = math.min(offset + 99, #sessionIds)
            for index = offset, maximum do
                local sessionId = sessionIds[index]
                if type(sessionId) ~= 'string' or #sessionId < 1 or #sessionId > 36 then
                    return nil, foundation.error('INVALID_SESSION_ID', 'Session heartbeat contains an invalid ID.')
                end
                placeholders[#placeholders + 1] = '?'
                parameters[#parameters + 1] = sessionId
            end
            local _, err = database:update([[UPDATE `synex_sessions` AS `session`
                INNER JOIN `synex_instance_boots` AS `boot`
                    ON `boot`.`instance_id` = `session`.`server_instance_id` AND `boot`.`boot_id` = ?
                SET `session`.`last_seen_at` = CURRENT_TIMESTAMP(6)
                WHERE `session`.`server_instance_id` = ? AND `session`.`closed_at` IS NULL
                    AND `session`.`id` IN (]]
                .. table.concat(placeholders, ',') .. ')', parameters)
            if not authorityGuard() then return true, nil end
            if err then return nil, err end
            offset = maximum + 1
        end
        return true, nil
    end

    function instances:snapshot()
        return foundation.copy(instanceSnapshot)
    end
end
