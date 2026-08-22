local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimePersistence = function(deps)
    local foundation = assert(deps.foundation, 'runtime persistence requires foundation')
    local database = assert(deps.database, 'runtime persistence requires database')
    local platform = assert(deps.platform, 'runtime persistence requires platform')
    local instanceId = assert(deps.instanceId, 'runtime persistence requires an instance ID')
    local metrics = foundation.metrics
    local bootId = nil
    local bootRegistered = false

    local function requireBootAuthority()
        if not bootRegistered then
            return nil, foundation.error('INSTANCE_BOOT_NOT_REGISTERED',
                'The runtime boot generation is not registered.')
        end
        return bootId, nil
    end

    local instanceSnapshot = {
        localInstanceId = instanceId,
        status = 'starting',
        healthy = 0,
        stale = 0,
        total = 0,
        pendingControlRequests = 0,
        refreshedAt = nil
    }
    local instances = {}

    function instances:register(name)
        if type(name) ~= 'string' or #name < 1 or #name > 96 or name:find('[%z\1-\31\127]') then
            return nil, foundation.error('INVALID_INSTANCE_NAME', 'Instance name must be a bounded printable string.')
        end
        local candidateBootId = foundation.nextId('boot')
        if type(candidateBootId) ~= 'string' or #candidateBootId < 1 or #candidateBootId > 36 then
            return nil, foundation.error('INVALID_BOOT_ID', 'The runtime boot generation is invalid.')
        end
        bootRegistered = false
        bootId = nil
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
        bootId = candidateBootId
        bootRegistered = true
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
        local leaseOwnerPrefix = instanceId .. ':'
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
            query([[UPDATE `synex_cluster_leases` AS `lease`
                SET `lease`.`expires_at` = CURRENT_TIMESTAMP(6)
                WHERE LEFT(`lease`.`lease_name`, 8) = 'session:'
                    AND LEFT(`lease`.`owner_id`, ?) = ?]],
                { #leaseOwnerPrefix, leaseOwnerPrefix })
            query([[UPDATE `synex_session_control_requests` AS `request`
                INNER JOIN `synex_sessions` AS `session` ON `session`.`id` = `request`.`target_session_id`
                SET `request`.`state` = 'expired', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `request`.`state` = 'pending'
                    AND (`request`.`requested_by_instance_id` = ? OR `session`.`server_instance_id` = ?)]],
                { instanceId, instanceId })
            query([[UPDATE `synex_sessions` AS `session`
                SET `session`.`state` = 'CLOSED', `session`.`closed_at` = CURRENT_TIMESTAMP(6),
                    `session`.`close_reason` = ?, `session`.`version` = `session`.`version` + 1
                WHERE `session`.`server_instance_id` = ? AND `session`.`closed_at` IS NULL]],
                { reason, instanceId })
            return true
        end)
        if not terminated then return nil, authorityError or terminationError end
        metrics:increment('synex_local_session_termination_total', { result = 'complete' })
        return true, nil
    end

    function instances:sourceGenerationFloor()
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local rows, err = database:query([[SELECT COALESCE(MAX(`session`.`source_generation`), 0)
                AS `source_generation_floor`
            FROM `synex_instance_boots` AS `boot`
            LEFT JOIN `synex_sessions` AS `session`
                ON `session`.`server_instance_id` = `boot`.`instance_id`
            WHERE `boot`.`instance_id` = ? AND `boot`.`boot_id` = ?
            GROUP BY `boot`.`instance_id`]], { instanceId, activeBootId })
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
        local _, staleError = database:update([[UPDATE `synex_instances` AS `candidate`
            INNER JOIN `synex_instance_boots` AS `authority`
                ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
            SET `candidate`.`status` = 'stale', `candidate`.`version` = `candidate`.`version` + 1
            WHERE `candidate`.`instance_id` <> ? AND `candidate`.`status` NOT IN ('stale', 'stopped')
                AND `candidate`.`heartbeat_at` < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))]],
            { instanceId, activeBootId, instanceId, staleSeconds })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if staleError then return nil, staleError end
        local _, sessionError = database:update([[UPDATE `synex_sessions` AS `session`
            INNER JOIN `synex_instances` AS `instance` ON `instance`.`instance_id` = `session`.`server_instance_id`
            INNER JOIN `synex_instance_boots` AS `authority`
                ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
            SET `session`.`state` = 'CLOSED', `session`.`closed_at` = CURRENT_TIMESTAMP(6),
                `session`.`close_reason` = 'instance heartbeat expired', `session`.`version` = `session`.`version` + 1
            WHERE `session`.`closed_at` IS NULL AND `instance`.`status` = 'stale'
                AND `session`.`last_seen_at` < TIMESTAMPADD(SECOND, -?, CURRENT_TIMESTAMP(6))]],
            { instanceId, activeBootId, staleSeconds })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if sessionError then return nil, sessionError end
        local _, expiredError = database:update([[UPDATE `synex_session_control_requests` AS `request`
            INNER JOIN `synex_instances` AS `requester`
                ON `requester`.`instance_id` = `request`.`requested_by_instance_id`
            INNER JOIN `synex_instance_boots` AS `authority`
                ON `authority`.`instance_id` = ? AND `authority`.`boot_id` = ?
            LEFT JOIN `synex_session_control_authority` AS `request_claim`
                ON `request_claim`.`request_id` = `request`.`request_id`
            LEFT JOIN `synex_instance_boots` AS `requester_boot`
                ON `requester_boot`.`instance_id` = `requester`.`instance_id`
            SET `request`.`state` = 'expired', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `request`.`state` = 'pending'
                AND (`request`.`expires_at` <= CURRENT_TIMESTAMP(6)
                    OR `requester`.`status` <> 'ready'
                    OR `request`.`created_at` < `requester`.`started_at`
                    OR `request_claim`.`request_id` IS NULL
                    OR `requester_boot`.`boot_id` IS NULL
                    OR `request_claim`.`requester_boot_id` <> `requester_boot`.`boot_id`)]],
            { instanceId, activeBootId })
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if expiredError then return nil, expiredError end
        local rows, summaryError = database:query([[SELECT
                COUNT(*) AS `total_count`,
                SUM(CASE WHEN `status` IN ('starting', 'ready', 'degraded') THEN 1 ELSE 0 END) AS `healthy_count`,
                SUM(CASE WHEN `status` = 'stale' THEN 1 ELSE 0 END) AS `stale_count`
            FROM `synex_instances`]], {})
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if summaryError then return nil, summaryError end
        local pending, pendingError = database:scalar([[SELECT COUNT(*)
            FROM `synex_session_control_requests` WHERE `state` = 'pending']], {})
        if not authorityGuard() then return foundation.copy(instanceSnapshot), nil end
        if pendingError then return nil, pendingError end
        local summary = rows and rows[1] or {}
        instanceSnapshot.total = tonumber(summary.total_count) or 0
        instanceSnapshot.healthy = tonumber(summary.healthy_count) or 0
        instanceSnapshot.stale = tonumber(summary.stale_count) or 0
        instanceSnapshot.pendingControlRequests = tonumber(pending) or 0
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

    function instances:requestRemoteKicks(userId, ttlSeconds, authorityGuard)
        if type(userId) ~= 'string' or #userId < 1 or #userId > 36 then
            return nil, foundation.error('INVALID_USER_ID', 'Remote session replacement requires a valid user ID.')
        end
        if type(authorityGuard) ~= 'function' then
            return nil, foundation.error('CONTROL_AUTHORITY_REQUIRED',
                'Remote session replacement requires a live admission authority guard.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local function authorityIsCurrent()
            local invoked, current = foundation.safeCall(authorityGuard)
            return invoked and current == true
        end
        local function authorityError()
            return foundation.error('CORE_STOPPING',
                'Remote session replacement was cancelled because admission authority changed.')
        end
        local issuedRequestIds = {}
        local function expireIssuedRequests()
            if #issuedRequestIds == 0 then return true, nil end
            local placeholders = {}
            for _ = 1, #issuedRequestIds do placeholders[#placeholders + 1] = '?' end
            local parameters = { activeBootId, instanceId }
            for _, requestId in ipairs(issuedRequestIds) do parameters[#parameters + 1] = requestId end
            local _, expiryError = database:update([[UPDATE `synex_session_control_requests` AS `request`
                INNER JOIN `synex_session_control_authority` AS `request_claim`
                    ON `request_claim`.`request_id` = `request`.`request_id`
                        AND `request_claim`.`requester_boot_id` = ?
                INNER JOIN `synex_instance_boots` AS `boot`
                    ON `boot`.`instance_id` = `request`.`requested_by_instance_id`
                        AND `boot`.`boot_id` = `request_claim`.`requester_boot_id`
                SET `request`.`state` = 'expired', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `request`.`requested_by_instance_id` = ? AND `request`.`state` = 'pending'
                    AND `request`.`request_id` IN (]]
                .. table.concat(placeholders, ',') .. ')', parameters)
            if expiryError then return nil, expiryError end
            return true, nil
        end
        if not authorityIsCurrent() then return nil, authorityError() end
        ttlSeconds = math.max(10, math.min(math.floor(tonumber(ttlSeconds) or 45), 300))
        local sessions, queryError = database:query([[SELECT `id` FROM `synex_sessions`
            WHERE `user_id` = ? AND `server_instance_id` <> ? AND `closed_at` IS NULL
            ORDER BY `connected_at` ASC LIMIT 32]], { userId, instanceId })
        if queryError then return nil, queryError end
        local requested = 0
        for _, session in ipairs(sessions or {}) do
            if not authorityIsCurrent() then
                local expired, expiryError = expireIssuedRequests()
                if not expired then return nil, expiryError end
                return nil, authorityError()
            end
            local requestId = foundation.nextId('control')
            local issuedRequestId, issueError = nil, nil
            local committed, transactionError = database:withTransaction(function(query)
                local requester = query([[SELECT `requester`.`instance_id`
                    FROM `synex_instances` AS `requester`
                    INNER JOIN `synex_instance_boots` AS `boot`
                        ON `boot`.`instance_id` = `requester`.`instance_id` AND `boot`.`boot_id` = ?
                    WHERE `requester`.`instance_id` = ? AND `requester`.`status` = 'ready'
                    FOR UPDATE]], { activeBootId, instanceId }) or {}
                if not requester[1] then issueError = authorityError(); return false end
                local target = query([[SELECT `id` FROM `synex_sessions`
                    WHERE `id` = ? AND `closed_at` IS NULL FOR UPDATE]], { session.id }) or {}
                if not target[1] then return true end
                local pending = query([[SELECT `request_id` FROM `synex_session_control_requests`
                    WHERE `target_session_id` = ? AND `action` = 'kick' AND `state` = 'pending'
                    LIMIT 1 FOR UPDATE]], { session.id }) or {}
                issuedRequestId = pending[1] and pending[1].request_id or requestId
                if pending[1] then
                    query([[UPDATE `synex_session_control_requests`
                        SET `requested_by_instance_id` = ?, `reason` = 'duplicate session replaced',
                            `created_at` = CURRENT_TIMESTAMP(6),
                            `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                        WHERE `request_id` = ? AND `state` = 'pending']],
                        { instanceId, ttlSeconds, issuedRequestId })
                else
                    query([[INSERT INTO `synex_session_control_requests`
                        (`request_id`, `target_session_id`, `requested_by_instance_id`, `action`, `state`,
                            `reason`, `expires_at`)
                        VALUES (?, ?, ?, 'kick', 'pending', 'duplicate session replaced',
                            TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
                        { issuedRequestId, session.id, instanceId, ttlSeconds })
                end
                query([[INSERT INTO `synex_session_control_authority`
                    (`request_id`, `requester_boot_id`, `recorded_at`)
                    VALUES (?, ?, CURRENT_TIMESTAMP(6))
                    ON DUPLICATE KEY UPDATE `requester_boot_id` = VALUES(`requester_boot_id`),
                        `recorded_at` = CURRENT_TIMESTAMP(6)]], { issuedRequestId, activeBootId })
                return true
            end)
            if issueError or not committed then
                local expired, expiryError = expireIssuedRequests()
                if not expired then return nil, expiryError end
                return nil, issueError or transactionError
            end
            if issuedRequestId then issuedRequestIds[#issuedRequestIds + 1] = issuedRequestId end
            if not authorityIsCurrent() then
                local expired, expiryError = expireIssuedRequests()
                if not expired then return nil, expiryError end
                return nil, authorityError()
            end
            if issuedRequestId then requested = requested + 1 end
        end
        metrics:increment('synex_cluster_control_requests_total', { action = 'kick' }, requested)
        return requested, nil
    end

    function instances:pendingLocalControls()
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local rows, err = database:query([[SELECT `request`.`request_id`, `request`.`target_session_id`,
                `request`.`action`, `request`.`reason`
            FROM `synex_session_control_requests` AS `request`
            INNER JOIN `synex_sessions` AS `session` ON `session`.`id` = `request`.`target_session_id`
            INNER JOIN `synex_instance_boots` AS `target_boot`
                ON `target_boot`.`instance_id` = `session`.`server_instance_id`
                    AND `target_boot`.`boot_id` = ?
            INNER JOIN `synex_instances` AS `requester`
                ON `requester`.`instance_id` = `request`.`requested_by_instance_id`
            INNER JOIN `synex_session_control_authority` AS `request_claim`
                ON `request_claim`.`request_id` = `request`.`request_id`
            INNER JOIN `synex_instance_boots` AS `requester_boot`
                ON `requester_boot`.`instance_id` = `requester`.`instance_id`
                    AND `requester_boot`.`boot_id` = `request_claim`.`requester_boot_id`
            WHERE `request`.`state` = 'pending' AND `request`.`expires_at` > CURRENT_TIMESTAMP(6)
                AND `session`.`server_instance_id` = ? AND `session`.`closed_at` IS NULL
                AND `requester`.`status` = 'ready'
                AND `request`.`created_at` >= `requester`.`started_at`
            ORDER BY `request`.`created_at` ASC LIMIT 32]], { activeBootId, instanceId })
        if err then return nil, err end
        return rows or {}, nil
    end

    function instances:completeControl(requestId)
        if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 36 then
            return nil, foundation.error('INVALID_CONTROL_REQUEST', 'Control request ID is invalid.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local affected, err = database:update([[UPDATE `synex_session_control_requests` AS `request`
            INNER JOIN `synex_sessions` AS `session`
                ON `session`.`id` = `request`.`target_session_id`
            INNER JOIN `synex_instance_boots` AS `target_boot`
                ON `target_boot`.`instance_id` = `session`.`server_instance_id`
                    AND `target_boot`.`boot_id` = ?
            INNER JOIN `synex_instances` AS `requester`
                ON `requester`.`instance_id` = `request`.`requested_by_instance_id`
            INNER JOIN `synex_session_control_authority` AS `request_claim`
                ON `request_claim`.`request_id` = `request`.`request_id`
            INNER JOIN `synex_instance_boots` AS `requester_boot`
                ON `requester_boot`.`instance_id` = `requester`.`instance_id`
                    AND `requester_boot`.`boot_id` = `request_claim`.`requester_boot_id`
            SET `request`.`state` = 'completed', `request`.`completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `request`.`request_id` = ? AND `request`.`state` = 'pending'
                AND `request`.`expires_at` > CURRENT_TIMESTAMP(6)
                AND `session`.`server_instance_id` = ? AND `session`.`closed_at` IS NULL
                AND `requester`.`status` = 'ready'
                AND `request`.`created_at` >= `requester`.`started_at`]],
            { activeBootId, requestId, instanceId })
        if err then return nil, err end
        return tonumber(affected) == 1, nil
    end

    function instances:snapshot()
        return foundation.copy(instanceSnapshot)
    end

    local rbac = {}

    local function encodeAudit(value)
        if value == nil then return nil, nil end
        local ok, encoded = pcall(platform.jsonEncode, value)
        if not ok or type(encoded) ~= 'string' or #encoded > 16384 then
            return nil, foundation.error('AUDIT_ENCODING_FAILED', 'RBAC audit data could not be encoded.')
        end
        return encoded, nil
    end

    local function auditParameters(action, targetType, targetId, context, before, after)
        local beforeJson, beforeError = encodeAudit(before)
        if beforeError then return nil, beforeError end
        local afterJson, afterError = encodeAudit(after)
        if afterError then return nil, afterError end
        local contextJson, contextError = encodeAudit({ reason = context.reason })
        if contextError then return nil, contextError end
        return {
            foundation.nextId('audit'), context.traceId, context.actorType or 'resource', context.actor,
            action, targetType, targetId, beforeJson, afterJson, contextJson
        }, nil
    end

    local function normalizedPermissionRows(rows)
        local permissions = {}
        for _, row in ipairs(rows or {}) do
            permissions[#permissions + 1] = { permission = row.permission_key, effect = row.effect }
        end
        return permissions
    end

    function rbac:loadRoles()
        return database:query([[SELECT `role`.`role_name`, `role`.`version`,
                `permission`.`permission_key`, `permission`.`effect`
            FROM `synex_rbac_roles` AS `role`
            LEFT JOIN `synex_rbac_role_permissions` AS `permission`
                ON `permission`.`role_name` = `role`.`role_name`
            ORDER BY `role`.`role_name`, `permission`.`permission_key`, `permission`.`effect`]], {})
    end

    function rbac:defineRole(name, permissions, context)
        local auditError
        local committed, err = database:withTransaction(function(query)
            local roleRows = query('SELECT `version` FROM `synex_rbac_roles` WHERE `role_name` = ? FOR UPDATE', { name }) or {}
            local currentPermissions = roleRows[1] and (query([[SELECT `permission_key`, `effect`
                FROM `synex_rbac_role_permissions` WHERE `role_name` = ?
                ORDER BY `permission_key`, `effect`]], { name }) or {}) or {}
            local before = roleRows[1] and {
                version = tonumber(roleRows[1].version) or 1,
                permissions = normalizedPermissionRows(currentPermissions)
            } or nil
            local after = {
                version = before and before.version + 1 or 1,
                permissions = foundation.copy(permissions)
            }
            local auditValues
            auditValues, auditError = auditParameters('rbac.role.define', 'rbac_role', name, context, before, after)
            if not auditValues then return false end
            query([[INSERT INTO `synex_rbac_roles` (`role_name`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { name })
            query('DELETE FROM `synex_rbac_role_permissions` WHERE `role_name` = ?', { name })
            for _, permission in ipairs(permissions) do
                query([[INSERT INTO `synex_rbac_role_permissions`
                    (`role_name`, `permission_key`, `effect`) VALUES (?, ?, ?)]],
                    { name, permission.permission, permission.effect })
            end
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            return true
        end)
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return true, nil
    end

    function rbac:assign(subject, role, context)
        local auditError
        local committed, err = database:withTransaction(function(query)
            local rows = query([[SELECT `assigned_by_ref`, `expires_at` FROM `synex_rbac_subject_roles`
                WHERE `subject_ref` = ? AND `role_name` = ? FOR UPDATE]], { subject, role }) or {}
            local before = rows[1] and {
                role = role, assigned = true, expiresAt = rows[1].expires_at and tostring(rows[1].expires_at) or nil
            } or { role = role, assigned = false }
            local after = { role = role, assigned = true, expiresAt = context.expiresAt }
            local auditValues
            auditValues, auditError = auditParameters(
                'rbac.assignment.assign', 'rbac_subject', subject, context, before, after)
            if not auditValues then return false end
            query([[INSERT INTO `synex_rbac_subject_roles`
                (`subject_ref`, `role_name`, `assigned_by_ref`, `expires_at`)
                VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `assigned_by_ref` = VALUES(`assigned_by_ref`),
                    `assigned_at` = CURRENT_TIMESTAMP(6), `expires_at` = VALUES(`expires_at`)]],
                { subject, role, context.actor, context.expiresAt })
            query([[INSERT INTO `synex_rbac_subject_versions` (`subject_ref`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { subject })
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            return true
        end)
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return true, nil
    end

    function rbac:revoke(subject, role, context)
        local auditError, domainError
        local committed, err = database:withTransaction(function(query)
            local rows = query([[SELECT `assigned_by_ref`, `expires_at` FROM `synex_rbac_subject_roles`
                WHERE `subject_ref` = ? AND `role_name` = ? FOR UPDATE]], { subject, role }) or {}
            if not rows[1] then
                domainError = foundation.error('ROLE_ASSIGNMENT_NOT_FOUND', 'The role assignment does not exist.')
                return false
            end
            local before = {
                role = role, assigned = true, expiresAt = rows[1].expires_at and tostring(rows[1].expires_at) or nil
            }
            local auditValues
            auditValues, auditError = auditParameters('rbac.assignment.revoke', 'rbac_subject', subject,
                context, before, { role = role, assigned = false })
            if not auditValues then return false end
            query('DELETE FROM `synex_rbac_subject_roles` WHERE `subject_ref` = ? AND `role_name` = ?',
                { subject, role })
            query([[INSERT INTO `synex_rbac_subject_versions` (`subject_ref`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { subject })
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return true, nil
    end

    function rbac:loadSubject(subject)
        local version, versionError = database:scalar(
            'SELECT `version` FROM `synex_rbac_subject_versions` WHERE `subject_ref` = ?', { subject })
        if versionError then return nil, versionError end
        local rows, roleError = database:query([[SELECT `role_name` FROM `synex_rbac_subject_roles`
            WHERE `subject_ref` = ? AND (`expires_at` IS NULL OR `expires_at` > CURRENT_TIMESTAMP(6))
            ORDER BY `role_name`]], { subject })
        if roleError then return nil, roleError end
        local roles = {}
        for _, row in ipairs(rows or {}) do roles[#roles + 1] = row.role_name end
        return { version = tonumber(version) or 0, roles = roles }, nil
    end

    function rbac:summary()
        local rows, err = database:query([[SELECT
                (SELECT COUNT(*) FROM `synex_rbac_roles`) AS `role_count`,
                (SELECT COUNT(*) FROM `synex_rbac_subject_roles`
                    WHERE `expires_at` IS NULL OR `expires_at` > CURRENT_TIMESTAMP(6)) AS `assignment_count`]], {})
        if err then return nil, err end
        local row = rows and rows[1] or {}
        return { roles = tonumber(row.role_count) or 0, activeAssignments = tonumber(row.assignment_count) or 0 }, nil
    end

    return { instances = instances, rbac = rbac }
end
