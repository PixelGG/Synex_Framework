local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimePersistenceControl = function(context)
    local foundation = context.foundation
    local database = context.database
    local instanceId = context.instanceId
    local metrics = context.metrics
    local affectedRows = context.affectedRows
    local capacityInteger = context.capacityInteger
    local emitControlCapacityMetrics = context.emitControlCapacityMetrics
    local requireBootAuthority = context.requireBootAuthority
    local instances = context.instances

    local function admissionGateAuthority(userId, lease, activeBootId)
        local name = type(lease) == 'table' and (lease.name or lease.leaseName) or nil
        if type(userId) ~= 'string' or #userId < 1 or #userId > 36
            or type(lease) ~= 'table' or name ~= 'admission:' .. userId
            or type(lease.owner) ~= 'string' or #lease.owner < 1 or #lease.owner > 96
            or lease.owner:sub(1, #instanceId + 1) ~= instanceId .. ':'
            or type(lease.fencingToken) ~= 'number'
            or math.type(lease.fencingToken) ~= 'integer' or lease.fencingToken < 1
            or lease.requesterInstanceId ~= instanceId
            or lease.requesterBootId ~= activeBootId then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority is missing or invalid.', { retryable = true })
        end
        return {
            name = name, owner = lease.owner, fencingToken = lease.fencingToken,
            requesterInstanceId = lease.requesterInstanceId,
            requesterBootId = lease.requesterBootId
        }, nil
    end

    local function lockAdmissionGate(query, gate, authorityGuard)
        local function current()
            local invoked, value = foundation.safeCall(authorityGuard)
            return invoked and value == true
        end
        if not current() then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission was cancelled.', { retryable = true })
        end
        local requester = query([[SELECT `requester`.`instance_id`
            FROM `synex_instances` AS `requester`
            INNER JOIN `synex_instance_boots` AS `boot`
                ON `boot`.`instance_id` = `requester`.`instance_id` AND `boot`.`boot_id` = ?
            WHERE `requester`.`instance_id` = ? AND `requester`.`status` = 'ready'
            FOR UPDATE]], { gate.requesterBootId, gate.requesterInstanceId }) or {}
        if not current() or not requester[1] then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission runtime authority changed.', { retryable = true })
        end
        local rows = query([[SELECT `owner_id`, `fencing_token`,
                (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
            FROM `synex_cluster_leases` WHERE `lease_name` = ? FOR UPDATE]],
            { gate.name }) or {}
        local row = rows[1]
        if not current() or not row or row.owner_id ~= gate.owner
            or tonumber(row.fencing_token) ~= gate.fencingToken
            or tonumber(row.valid) ~= 1 then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission lease changed.', { retryable = true })
        end
        return true, nil
    end

    function instances:hasOpenUserSessions(userId, remoteOnly, admissionLease, authorityGuard)
        if type(userId) ~= 'string' or #userId < 1 or #userId > 36
            or type(remoteOnly) ~= 'boolean' then
            return nil, foundation.error('INVALID_USER_ID',
                'Durable session admission requires a valid user query.')
        end
        if type(authorityGuard) ~= 'function' then
            return nil, foundation.error('CONTROL_AUTHORITY_REQUIRED',
                'Durable session admission requires a live authority guard.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local gate, gateError = admissionGateAuthority(userId, admissionLease, activeBootId)
        if not gate then return nil, gateError end
        local exists = false
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            local locked
            locked, domainError = lockAdmissionGate(query, gate, authorityGuard)
            if not locked then return false end
            local sql = [[SELECT `id` FROM `synex_sessions`
                FORCE INDEX (`idx_sessions_user_open`)
                WHERE `user_id` = ? AND `closed_at` IS NULL]]
            local parameters = { userId }
            if remoteOnly then
                sql = sql .. ' AND `server_instance_id` <> ?'
                parameters[#parameters + 1] = instanceId
            end
            local rows = query(sql
                .. ' ORDER BY `connected_at` ASC, `id` ASC LIMIT 1 FOR UPDATE', parameters) or {}
            local invoked, current = foundation.safeCall(authorityGuard)
            if not invoked or current ~= true then
                domainError = foundation.error('ADMISSION_GATE_LOST',
                    'Account admission changed during the durable session check.', {
                        retryable = true
                    })
                return false
            end
            exists = rows[1] ~= nil
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return exists, nil
    end

    function instances:requestRemoteKicks(userId, ttlSeconds, authorityGuard, admissionLease)
        if type(userId) ~= 'string' or #userId < 1 or #userId > 36 then
            return nil, foundation.error('INVALID_USER_ID', 'Remote session replacement requires a valid user ID.')
        end
        if type(authorityGuard) ~= 'function' then
            return nil, foundation.error('CONTROL_AUTHORITY_REQUIRED',
                'Remote session replacement requires a live admission authority guard.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local gate, gateError = admissionGateAuthority(userId, admissionLease, activeBootId)
        if not gate then return nil, gateError end
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
        local sessions = nil
        local selectionError = nil
        local selected, selectionTransactionError = database:withTransaction(function(query)
            local locked
            locked, selectionError = lockAdmissionGate(query, gate, authorityGuard)
            if not locked then return false end
            sessions = query([[SELECT `id`, `server_instance_id` FROM `synex_sessions`
                FORCE INDEX (`idx_sessions_user_open`)
                WHERE `user_id` = ? AND `server_instance_id` <> ? AND `closed_at` IS NULL
                ORDER BY `connected_at` ASC, `id` ASC LIMIT 32 FOR UPDATE]],
                { userId, instanceId }) or {}
            if not authorityIsCurrent() then
                selectionError = authorityError()
                return false
            end
            return true
        end)
        if not selected then return nil, selectionError or selectionTransactionError end
        local requested = 0
        for _, session in ipairs(sessions or {}) do
            if not authorityIsCurrent() then
                local expired, expiryError = expireIssuedRequests()
                if not expired then return nil, expiryError end
                return nil, authorityError()
            end
            local requestId = foundation.nextId('control')
            local issuedRequestId, issueError, ownedIssuedRequest = nil, nil, false
            local capacitySnapshot = nil
            local committed, transactionError = database:withTransaction(function(query)
                local locked
                locked, issueError = lockAdmissionGate(query, gate, authorityGuard)
                if not locked then return false end
                local target = query([[SELECT `id`, `server_instance_id` FROM `synex_sessions`
                    WHERE `id` = ? AND `closed_at` IS NULL FOR UPDATE]], { session.id }) or {}
                if not target[1] then return true end
                local targetInstanceId = target[1].server_instance_id
                if type(targetInstanceId) ~= 'string' or #targetInstanceId < 1
                    or #targetInstanceId > 36 or targetInstanceId == instanceId then
                    issueError = foundation.error('CONTROL_TARGET_INVALID',
                        'Remote session replacement found invalid target authority.')
                    return false
                end
                local pendingRows = query([[SELECT `request`.`request_id`,
                        `request`.`requested_by_instance_id`, `request`.`target_instance_id`,
                        (`request`.`expires_at` > CURRENT_TIMESTAMP(6)) AS `request_unexpired`,
                        EXISTS (
                            SELECT 1 FROM `synex_session_control_authority` AS `claim`
                            INNER JOIN `synex_instances` AS `requester`
                                ON `requester`.`instance_id` = `request`.`requested_by_instance_id`
                                    AND `requester`.`status` = 'ready'
                                    AND `request`.`created_at` >= `requester`.`started_at`
                            INNER JOIN `synex_instance_boots` AS `requester_boot`
                                ON `requester_boot`.`instance_id`
                                    = `request`.`requested_by_instance_id`
                                    AND `requester_boot`.`boot_id` = `claim`.`requester_boot_id`
                            WHERE `claim`.`request_id` = `request`.`request_id`
                        ) AS `requester_valid`
                    FROM `synex_session_control_requests` AS `request`
                        FORCE INDEX (`uq_session_control_active`)
                    WHERE `request`.`target_session_id` = ? AND `request`.`action` = 'kick'
                        AND `request`.`active_marker` = 1 AND `request`.`state` = 'pending'
                    LIMIT 2 FOR UPDATE]], { session.id }) or {}
                if #pendingRows > 1 then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The pending session-control identity is not unique.')
                    return false
                end
                local pending = pendingRows[1]
                local pendingRequester = pending and pending.requested_by_instance_id or nil
                if pending and (type(pending.request_id) ~= 'string'
                    or #pending.request_id < 1 or #pending.request_id > 36
                    or type(pendingRequester) ~= 'string' or #pendingRequester < 1
                    or #pendingRequester > 36) then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The pending session-control authority is malformed.')
                    return false
                end
                local exactPending = pending and pendingRequester == instanceId
                local validForeignPending = pending and pendingRequester ~= instanceId
                    and pending.target_instance_id == targetInstanceId
                    and tonumber(pending.request_unexpired) == 1
                    and tonumber(pending.requester_valid) == 1

                local globalRows = query([[SELECT `entry_count`, `global_limit`, `requester_limit`
                    FROM `synex_session_control_capacity`
                    WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
                local global = globalRows[1]
                local globalCount = global and capacityInteger(global.entry_count, 0) or nil
                local globalLimit = global and capacityInteger(global.global_limit, 1) or nil
                local requesterLimit = global and capacityInteger(global.requester_limit, 1) or nil
                if #globalRows ~= 1 or not globalCount or not globalLimit
                    or not requesterLimit or requesterLimit > globalLimit then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The persistent session-control capacity authority is missing or invalid.')
                    return false
                end

                local createsRequest = not exactPending and not validForeignPending
                local requesterIds = { instanceId }
                if validForeignPending then requesterIds = { pendingRequester } end
                if createsRequest and pendingRequester and pendingRequester ~= instanceId then
                    requesterIds[#requesterIds + 1] = pendingRequester
                end
                table.sort(requesterIds)
                local requesterCreated = 0
                local requesterCounts, lockedRequesterTotal = {}, 0
                for _, requesterId in ipairs(requesterIds) do
                    if createsRequest and requesterId == instanceId then
                        local insertedCounter = query([[INSERT IGNORE INTO
                                `synex_session_control_requester_capacity`
                                (`requested_by_instance_id`, `entry_count`) VALUES (?, 0)]],
                            { requesterId })
                        requesterCreated = affectedRows(insertedCounter)
                        if requesterCreated ~= 0 and requesterCreated ~= 1 then
                            issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                                'The requester session-control counter could not be initialized safely.')
                            return false
                        end
                    end
                    local requesterRows = query([[SELECT `requested_by_instance_id`, `entry_count`
                        FROM `synex_session_control_requester_capacity`
                        WHERE `requested_by_instance_id` = ? FOR UPDATE]], { requesterId }) or {}
                    local requesterRow = requesterRows[1]
                    local requesterCount = requesterRow
                        and capacityInteger(requesterRow.entry_count, 0) or nil
                    if #requesterRows ~= 1
                        or requesterRow.requested_by_instance_id ~= requesterId
                        or not requesterCount then
                        issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                            'A persistent session-control requester counter is missing or malformed.')
                        return false
                    end
                    requesterCounts[requesterId] = requesterCount
                    lockedRequesterTotal = lockedRequesterTotal + requesterCount
                end
                if lockedRequesterTotal > globalCount
                    or (pendingRequester and (requesterCounts[pendingRequester] or 0) < 1) then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'Persistent session-control counters do not represent the pending request.')
                    return false
                end

                local requesterCount = requesterCounts[instanceId]
                capacitySnapshot = {
                    global = globalCount,
                    requester = validForeignPending
                        and requesterCounts[pendingRequester] or requesterCount,
                    globalLimit = globalLimit,
                    requesterLimit = requesterLimit
                }
                if validForeignPending then
                    issuedRequestId = pending.request_id
                    return true
                end

                if exactPending then
                    local updatedPending = query([[UPDATE `synex_session_control_requests`
                        SET `target_instance_id` = ?, `reason` = 'duplicate session replaced',
                            `created_at` = CURRENT_TIMESTAMP(6),
                            `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                        WHERE `request_id` = ? AND `target_session_id` = ?
                            AND `requested_by_instance_id` = ? AND `action` = 'kick'
                            AND `state` = 'pending']],
                        { targetInstanceId, ttlSeconds, pending.request_id, session.id, instanceId })
                    if affectedRows(updatedPending) ~= 1 then
                        issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                            'The existing session-control request changed unexpectedly.')
                        return false
                    end
                    local authorityUpdated = affectedRows(query([[INSERT INTO
                            `synex_session_control_authority`
                            (`request_id`, `requester_boot_id`, `recorded_at`)
                        VALUES (?, ?, CURRENT_TIMESTAMP(6))
                        ON DUPLICATE KEY UPDATE `requester_boot_id` = VALUES(`requester_boot_id`),
                            `recorded_at` = CURRENT_TIMESTAMP(6)]],
                        { pending.request_id, activeBootId }))
                    if not authorityUpdated or authorityUpdated < 0 or authorityUpdated > 2 then
                        issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                            'The existing session-control authority could not be refreshed safely.')
                        return false
                    end
                    issuedRequestId = pending.request_id
                    ownedIssuedRequest = true
                    return true
                end

                local requesterHistory = query([[SELECT `request_id`
                    FROM `synex_session_control_requests`
                        FORCE INDEX (`idx_session_control_requester_pending`)
                    WHERE `requested_by_instance_id` = ? LIMIT 1]], { instanceId }) or {}
                if (requesterCreated == 1 and requesterHistory[1] ~= nil)
                    or (requesterCreated == 0 and requesterHistory[1] == nil)
                    or (requesterCreated == 0 and requesterCount < 1)
                    or (requesterCreated == 1 and requesterCount ~= 0) then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The requester session-control counter does not match retained history.')
                    return false
                end
                local staleTerminalized = false
                if pending then
                    local terminalized = query([[UPDATE `synex_session_control_requests`
                        SET `state` = 'expired', `completed_at` = CURRENT_TIMESTAMP(6)
                        WHERE `request_id` = ? AND `target_session_id` = ?
                            AND `requested_by_instance_id` = ? AND `action` = 'kick'
                            AND `state` = 'pending']],
                        { pending.request_id, session.id, pendingRequester })
                    if affectedRows(terminalized) ~= 1 then
                        issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                            'The stale session-control request changed unexpectedly.')
                        return false
                    end
                    staleTerminalized = true
                end

                local deniedScope = globalCount >= globalLimit and 'global'
                    or requesterCount >= requesterLimit and 'requester' or nil
                if deniedScope then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_EXCEEDED',
                        'Persistent session-control capacity is exhausted for this scope.', {
                            retryable = true, details = { scope = deniedScope }
                        })
                    if staleTerminalized and requesterCreated == 1 then
                        local removedCounter = query([[DELETE FROM
                                `synex_session_control_requester_capacity`
                            WHERE `requested_by_instance_id` = ? AND `entry_count` = 0]],
                            { instanceId })
                        if affectedRows(removedCounter) ~= 1 then
                            issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                                'An unused requester counter could not be removed exactly.')
                            return false
                        end
                    end
                    return staleTerminalized
                end
                local globalUpdated = query([[UPDATE `synex_session_control_capacity`
                    SET `entry_count` = `entry_count` + 1
                    WHERE `singleton_id` = 1 AND `entry_count` = ?
                        AND `entry_count` < `global_limit`
                        AND `entry_count` < 4294967295]], { globalCount })
                if affectedRows(globalUpdated) ~= 1 then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The global session-control counter changed unexpectedly.')
                    return false
                end
                local requesterUpdated = query([[UPDATE
                        `synex_session_control_requester_capacity`
                    SET `entry_count` = `entry_count` + 1
                    WHERE `requested_by_instance_id` = ? AND `entry_count` = ?
                        AND `entry_count` < ? AND `entry_count` < 4294967295]],
                    { instanceId, requesterCount, requesterLimit })
                if affectedRows(requesterUpdated) ~= 1 then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The requester session-control counter changed unexpectedly.')
                    return false
                end
                local insertedRequest = query([[INSERT INTO `synex_session_control_requests`
                    (`request_id`, `target_session_id`, `target_instance_id`,
                        `requested_by_instance_id`, `action`, `state`, `reason`, `expires_at`)
                    VALUES (?, ?, ?, ?, 'kick', 'pending', 'duplicate session replaced',
                        TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
                    { requestId, session.id, targetInstanceId, instanceId, ttlSeconds })
                if affectedRows(insertedRequest) ~= 1 then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The session-control request insert did not create exactly one row.')
                    return false
                end
                local insertedAuthority = query([[INSERT INTO
                        `synex_session_control_authority`
                        (`request_id`, `requester_boot_id`, `recorded_at`)
                    VALUES (?, ?, CURRENT_TIMESTAMP(6))]], { requestId, activeBootId })
                if affectedRows(insertedAuthority) ~= 1 then
                    issueError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'The session-control authority insert did not create exactly one row.')
                    return false
                end
                capacitySnapshot.global = globalCount + 1
                capacitySnapshot.requester = requesterCount + 1
                issuedRequestId = requestId
                ownedIssuedRequest = true
                return true
            end)
            emitControlCapacityMetrics(capacitySnapshot)
            if issueError or not committed then
                if issueError and issueError.code == 'SESSION_CONTROL_CAPACITY_EXCEEDED' then
                    metrics:increment('synex_session_control_capacity_denials_total', {
                        scope = issueError.details.scope
                    })
                elseif issueError and issueError.code == 'SESSION_CONTROL_CAPACITY_INVALID' then
                    metrics:increment('synex_session_control_capacity_denials_total', {
                        scope = 'integrity'
                    })
                end
                local expired, expiryError = expireIssuedRequests()
                if not expired then return nil, expiryError end
                return nil, issueError or transactionError
            end
            if issuedRequestId and ownedIssuedRequest then
                issuedRequestIds[#issuedRequestIds + 1] = issuedRequestId
            end
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
                `request`.`target_instance_id`, `request`.`action`, `request`.`reason`
            FROM `synex_session_control_requests` AS `request`
                FORCE INDEX (`idx_session_control_target_pending`)
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
            WHERE `request`.`target_instance_id` = ? AND `request`.`state` = 'pending'
                AND `request`.`expires_at` > CURRENT_TIMESTAMP(6)
                AND `session`.`server_instance_id` = `request`.`target_instance_id`
                AND `session`.`closed_at` IS NULL
                AND `requester`.`status` = 'ready'
                AND `request`.`created_at` >= `requester`.`started_at`
            ORDER BY `request`.`expires_at` ASC, `request`.`created_at` ASC,
                `request`.`request_id` ASC LIMIT 32]], { activeBootId, instanceId })
        if err then return nil, err end
        return rows or {}, nil
    end

    function instances:completeControl(control, dropAccepted)
        if type(control) ~= 'table' or type(dropAccepted) ~= 'boolean'
            or type(control.request_id) ~= 'string' or #control.request_id < 1
            or #control.request_id > 36
            or type(control.target_session_id) ~= 'string' or #control.target_session_id < 1
            or #control.target_session_id > 36
            or type(control.target_instance_id) ~= 'string'
            or control.target_instance_id ~= instanceId
            or control.action ~= 'kick' then
            return nil, foundation.error('INVALID_CONTROL_REQUEST',
                'Control request authority is invalid.')
        end
        local activeBootId, bootError = requireBootAuthority()
        if not activeBootId then return nil, bootError end
        local affected, err = database:update([[UPDATE `synex_session_control_requests` AS `request`
            INNER JOIN `synex_sessions` AS `session`
                ON `session`.`id` = `request`.`target_session_id`
            INNER JOIN `synex_instance_boots` AS `target_boot`
                ON `target_boot`.`instance_id` = `request`.`target_instance_id`
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
                AND `request`.`target_session_id` = ?
                AND `request`.`target_instance_id` = ? AND `request`.`action` = ?
                AND `request`.`expires_at` > CURRENT_TIMESTAMP(6)
                AND `session`.`server_instance_id` = `request`.`target_instance_id`
                AND (? = 1 OR `session`.`closed_at` IS NOT NULL)
                AND `requester`.`status` = 'ready'
                AND `request`.`created_at` >= `requester`.`started_at`]],
            { activeBootId, control.request_id, control.target_session_id,
                control.target_instance_id, control.action, dropAccepted and 1 or 0 })
        if err then return nil, err end
        return tonumber(affected) == 1, nil
    end
end
