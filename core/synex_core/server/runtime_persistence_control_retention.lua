local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimePersistenceControlRetention = function(context)
    local foundation = context.foundation
    local database = context.database
    local metrics = context.metrics
    local maintenanceBatchMaximum = context.maintenanceBatchMaximum
    local sessionControlRetentionDays = context.sessionControlRetentionDays
    local affectedRows = context.affectedRows
    local capacityInteger = context.capacityInteger
    local emitControlCapacityMetrics = context.emitControlCapacityMetrics
    local instances = context.instances

    function instances:compactTerminalControls(limit)
        limit = limit == nil and maintenanceBatchMaximum or limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 1000 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Session-control compaction limit must be an integer from 1 through 1000.')
        end
        local state = context.controlCompactionState
        local report = {
            state = state,
            selected = 0,
            authorityDeleted = 0,
            requestsDeleted = 0,
            legacyWithoutAuthority = 0,
            maximum = limit
        }
        local compactionError, capacitySnapshot = nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `request`.`request_id`,
                    `request`.`requested_by_instance_id`,
                    `authority`.`request_id` AS `authority_request_id`
                FROM `synex_session_control_requests` AS `request`
                    FORCE INDEX (`idx_session_control_terminal_retention`)
                LEFT JOIN `synex_session_control_authority` AS `authority`
                    ON `authority`.`request_id` = `request`.`request_id`
                WHERE `request`.`state` = ? AND `request`.`completed_at` IS NOT NULL
                    AND `request`.`completed_at`
                        <= TIMESTAMPADD(DAY, -?, CURRENT_TIMESTAMP(6))
                ORDER BY `request`.`completed_at` ASC, `request`.`request_id` ASC
                LIMIT ? FOR UPDATE]], { state, sessionControlRetentionDays, limit }) or {}
            if type(rows) ~= 'table' or #rows > limit then
                compactionError = foundation.error('SESSION_CONTROL_COMPACTION_INVALID',
                    'The terminal session-control queue returned an invalid batch.', {
                        retryable = true
                    })
                return false
            end
            report.selected = #rows
            if #rows == 0 then return true end

            local requestIds, requestPlaceholders = {}, {}
            local requesterCounts, requesterIds = {}, {}
            local expectedAuthorityRows, seenRequests = 0, {}
            for _, row in ipairs(rows) do
                local requestId = row.request_id
                local requesterId = row.requested_by_instance_id
                local authorityRequestId = row.authority_request_id
                if type(requestId) ~= 'string' or #requestId < 1 or #requestId > 36
                    or seenRequests[requestId]
                    or type(requesterId) ~= 'string' or #requesterId < 1
                    or #requesterId > 36
                    or (authorityRequestId ~= nil and authorityRequestId ~= requestId) then
                    compactionError = foundation.error('SESSION_CONTROL_COMPACTION_INVALID',
                        'The terminal session-control queue returned malformed authority.', {
                            retryable = true
                        })
                    return false
                end
                seenRequests[requestId] = true
                requestIds[#requestIds + 1] = requestId
                requestPlaceholders[#requestPlaceholders + 1] = '?'
                if authorityRequestId ~= nil then
                    expectedAuthorityRows = expectedAuthorityRows + 1
                end
                if requesterCounts[requesterId] == nil then
                    requesterCounts[requesterId] = 0
                    requesterIds[#requesterIds + 1] = requesterId
                end
                requesterCounts[requesterId] = requesterCounts[requesterId] + 1
            end
            table.sort(requesterIds)

            local globalRows = query([[SELECT `entry_count`, `global_limit`, `requester_limit`
                FROM `synex_session_control_capacity`
                WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
            local global = globalRows[1]
            local globalCount = global and capacityInteger(global.entry_count, 0) or nil
            local globalLimit = global and capacityInteger(global.global_limit, 1) or nil
            local requesterLimit = global and capacityInteger(global.requester_limit, 1) or nil
            if #globalRows ~= 1 or not globalCount or not globalLimit
                or not requesterLimit or requesterLimit > globalLimit
                or globalCount < #rows then
                compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                    'The global session-control counter cannot release the locked batch.')
                return false
            end

            local requesterPlaceholders = {}
            for _ = 1, #requesterIds do
                requesterPlaceholders[#requesterPlaceholders + 1] = '?'
            end
            local counterRows = query([[SELECT `requested_by_instance_id`, `entry_count`
                FROM `synex_session_control_requester_capacity`
                WHERE `requested_by_instance_id` IN (]]
                .. table.concat(requesterPlaceholders, ',')
                .. ') ORDER BY `requested_by_instance_id` ASC FOR UPDATE', requesterIds) or {}
            if #counterRows ~= #requesterIds then
                compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                    'A requester session-control counter is missing from the locked batch.')
                return false
            end
            local counterValues, lockedRequesterTotal = {}, 0
            for index, row in ipairs(counterRows) do
                local requesterId = row.requested_by_instance_id
                local count = capacityInteger(row.entry_count, 0)
                local releaseCount = requesterCounts[requesterId]
                if requesterId ~= requesterIds[index] or not count
                    or not releaseCount or count < releaseCount then
                    compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'A requester session-control counter cannot release its locked rows.')
                    return false
                end
                counterValues[requesterId] = count
                lockedRequesterTotal = lockedRequesterTotal + count
            end
            if lockedRequesterTotal > globalCount then
                compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                    'Requester session-control counters exceed global retained capacity.')
                return false
            end

            local childParameters = {}
            for _, requestId in ipairs(requestIds) do
                childParameters[#childParameters + 1] = requestId
            end
            childParameters[#childParameters + 1] = state
            childParameters[#childParameters + 1] = sessionControlRetentionDays
            local authorityDeleted = query([[DELETE `authority`
                FROM `synex_session_control_authority` AS `authority`
                INNER JOIN `synex_session_control_requests` AS `request`
                    ON `request`.`request_id` = `authority`.`request_id`
                WHERE `authority`.`request_id` IN (]]
                .. table.concat(requestPlaceholders, ',') .. [[)
                    AND `request`.`state` = ? AND `request`.`completed_at` IS NOT NULL
                    AND `request`.`completed_at`
                        <= TIMESTAMPADD(DAY, -?, CURRENT_TIMESTAMP(6))]], childParameters)
            if affectedRows(authorityDeleted) ~= expectedAuthorityRows then
                compactionError = foundation.error('SESSION_CONTROL_COMPACTION_INVALID',
                    'Terminal session-control child authority changed unexpectedly.', {
                        retryable = true
                    })
                return false
            end
            report.authorityDeleted = expectedAuthorityRows
            report.legacyWithoutAuthority = #rows - expectedAuthorityRows

            local parentParameters = {}
            for _, requestId in ipairs(requestIds) do
                parentParameters[#parentParameters + 1] = requestId
            end
            parentParameters[#parentParameters + 1] = state
            parentParameters[#parentParameters + 1] = sessionControlRetentionDays
            local requestsDeleted = query([[DELETE FROM `synex_session_control_requests`
                WHERE `request_id` IN (]] .. table.concat(requestPlaceholders, ',') .. [[)
                    AND `state` = ? AND `completed_at` IS NOT NULL
                    AND `completed_at`
                        <= TIMESTAMPADD(DAY, -?, CURRENT_TIMESTAMP(6))]], parentParameters)
            if affectedRows(requestsDeleted) ~= #rows then
                compactionError = foundation.error('SESSION_CONTROL_COMPACTION_INVALID',
                    'Terminal session-control parents changed unexpectedly.', {
                        retryable = true
                    })
                return false
            end
            report.requestsDeleted = #rows

            local globalUpdated = query([[UPDATE `synex_session_control_capacity`
                SET `entry_count` = `entry_count` - ?
                WHERE `singleton_id` = 1 AND `entry_count` = ? AND `entry_count` >= ?]],
                { #rows, globalCount, #rows })
            if affectedRows(globalUpdated) ~= 1 then
                compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                    'The global session-control counter changed during release.')
                return false
            end
            local highestRequesterRemaining = 0
            for _, requesterId in ipairs(requesterIds) do
                local count = counterValues[requesterId]
                local releaseCount = requesterCounts[requesterId]
                local remaining = count - releaseCount
                local requesterUpdated = query([[UPDATE
                        `synex_session_control_requester_capacity`
                    SET `entry_count` = `entry_count` - ?
                    WHERE `requested_by_instance_id` = ? AND `entry_count` = ?
                        AND `entry_count` >= ?]],
                    { releaseCount, requesterId, count, releaseCount })
                if affectedRows(requesterUpdated) ~= 1 then
                    compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                        'A requester session-control counter changed during release.')
                    return false
                end
                if remaining == 0 then
                    local removed = query([[DELETE FROM
                            `synex_session_control_requester_capacity`
                        WHERE `requested_by_instance_id` = ? AND `entry_count` = 0]],
                        { requesterId })
                    if affectedRows(removed) ~= 1 then
                        compactionError = foundation.error('SESSION_CONTROL_CAPACITY_INVALID',
                            'An empty requester session-control counter was not removed exactly.')
                        return false
                    end
                else
                    highestRequesterRemaining = math.max(highestRequesterRemaining, remaining)
                end
            end
            capacitySnapshot = {
                global = globalCount - #rows,
                requester = highestRequesterRemaining,
                globalLimit = globalLimit,
                requesterLimit = requesterLimit
            }
            return true
        end)
        emitControlCapacityMetrics(capacitySnapshot)
        if not committed then
            metrics:increment('synex_session_control_compaction_runs_total', {
                state = state, result = 'failed'
            })
            if compactionError and (compactionError.code == 'SESSION_CONTROL_CAPACITY_INVALID'
                or compactionError.code == 'SESSION_CONTROL_COMPACTION_INVALID') then
                metrics:increment('synex_session_control_capacity_denials_total', {
                    scope = 'integrity'
                })
            end
            return nil, compactionError or transactionError
        end
        context.controlCompactionState = state == 'completed' and 'expired' or 'completed'
        metrics:increment('synex_session_control_compaction_runs_total', {
            state = state, result = 'completed'
        })
        metrics:increment('synex_session_control_compacted_rows_total', {
            state = state
        }, report.requestsDeleted)
        return report, nil
    end
end
