return function(Foundation)
local domainError = Foundation.domainError
local isUuid = Foundation.isUuid
local DEFAULT_BATCH_SIZE = 25
local MAXIMUM_BATCH_SIZE = 50
local MAXIMUM_PAYLOAD_BYTES = 32768
local CLAIM_LEASE_SECONDS = 60
local MAXIMUM_ATTEMPTS = 10
local MAXIMUM_BACKOFF_SECONDS = 300
local MAXIMUM_INSPECTION_ROWS = 50

local function validToken(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function integer(value, minimum, maximum)
    local converted = tonumber(value)
    if not converted or converted ~= math.floor(converted)
        or converted < minimum or converted > maximum then return nil end
    return converted
end

local function createOutboxDispatcher(deps)
    local update = assert(deps.update, 'account outbox dispatcher requires update')
    local query = assert(deps.query, 'account outbox dispatcher requires query')
    local jsonDecode = assert(deps.jsonDecode, 'account outbox dispatcher requires jsonDecode')
    local runtimeMysql = rawget(_G, 'MySQL')
    local withTransaction = deps.withTransaction
    if not Foundation.isCallable(withTransaction) and type(runtimeMysql) == 'table'
        and Foundation.isCallable(runtimeMysql.startTransaction) then
        withTransaction = function(handler)
            local invoked, committed = pcall(runtimeMysql.startTransaction, handler)
            if not invoked or committed ~= true then
                return nil, domainError('OUTBOX_RETRY_FAILED',
                    'The account outbox retry transaction failed.', true)
            end
            return true, nil
        end
    end
    local random = deps.random or math.random
    local recordAttempts = deps.recordAttempts == true
        or (deps.recordAttempts == nil and type(runtimeMysql) == 'table')
    local nowMilliseconds = deps.nowMilliseconds
    if type(nowMilliseconds) ~= 'function' then
        nowMilliseconds = function()
            local timer = rawget(_G, 'GetGameTimer')
            if Foundation.isCallable(timer) then
                local ok, value = pcall(timer)
                if ok and integer(value, 0, 2147483647) then return value end
            end
            return math.floor(os.clock() * 1000)
        end
    end

    local function runUpdate(sql, parameters)
        local ok, affected = pcall(update, sql, parameters)
        if not ok or type(affected) ~= 'number' or affected ~= math.floor(affected) or affected < 0 then
            return nil, domainError('OUTBOX_DATABASE_ERROR', 'The account outbox update failed.', true)
        end
        return affected, nil
    end

    local function runQuery(sql, parameters)
        local ok, rows = pcall(query, sql, parameters)
        if not ok or type(rows) ~= 'table' then
            return nil, domainError('OUTBOX_DATABASE_ERROR', 'The account outbox query failed.', true)
        end
        return rows, nil
    end

    local function elapsed(startedAt)
        local ok, finishedAt = pcall(nowMilliseconds)
        if not ok then return 0 end
        startedAt = integer(startedAt, 0, 2147483647) or finishedAt
        finishedAt = integer(finishedAt, 0, 2147483647) or startedAt
        return math.max(0, math.min(finishedAt - startedAt, 3600000))
    end

    local function recordAttempt(row, claimToken, outcome, failureCode, durationMs)
        if not recordAttempts then return true, nil end
        local affected, attemptError = runUpdate([[INSERT IGNORE INTO `synex_account_outbox_attempts`
            (`event_id`, `outbox_id`, `attempt_no`, `worker_id`, `outcome`,
                `error_code`, `duration_ms`)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], {
            row.event_id, row.id, row.attempts, claimToken, outcome,
            failureCode, durationMs
        })
        if not affected then
            return nil, domainError('OUTBOX_OBSERVABILITY_ERROR',
                'The account outbox attempt could not be recorded.', true)
        end
        if affected > 1 then
            return nil, domainError('OUTBOX_OBSERVABILITY_ERROR',
                'The account outbox attempt result was invalid.', true)
        end
        return true, nil
    end

    local function markFailure(row, claimToken, failureCode)
        local attempts = tonumber(row.attempts)
        local manualRetryCount = tonumber(row.manual_retry_count) or 0
        if not attempts or attempts ~= math.floor(attempts) or attempts < 1 or attempts > 65535 then
            attempts = MAXIMUM_ATTEMPTS
            failureCode = 'OUTBOX_INVALID_ROW'
        end
        if manualRetryCount ~= math.floor(manualRetryCount)
            or manualRetryCount < 0 or manualRetryCount > 6552 then
            manualRetryCount = 0
            attempts = MAXIMUM_ATTEMPTS
            failureCode = 'OUTBOX_INVALID_ROW'
        end
        local attemptInCycle = attempts - (manualRetryCount * MAXIMUM_ATTEMPTS)
        if attemptInCycle < 1 then
            attemptInCycle = MAXIMUM_ATTEMPTS
            failureCode = 'OUTBOX_INVALID_ROW'
        end
        local dead = attemptInCycle >= MAXIMUM_ATTEMPTS
        local delay = math.min(MAXIMUM_BACKOFF_SECONDS, 2 ^ math.min(attemptInCycle, 8))
        local state = dead and 'dead' or 'pending'
        local affected, updateError = runUpdate([[UPDATE `synex_account_outbox`
            SET `state` = ?, `available_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                `last_attempt_at` = CURRENT_TIMESTAMP(6), `last_error_code` = ?,
                `last_error_at` = CURRENT_TIMESTAMP(6),
                `dead_at` = CASE WHEN ? = 'dead' THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
                `locked_by` = NULL, `locked_until` = NULL
            WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]], {
            state, delay, failureCode, state, row.id, claimToken
        })
        if not affected then return nil, updateError end
        if affected ~= 1 then
            return nil, domainError('OUTBOX_CLAIM_LOST', 'The account outbox claim changed before retry state was saved.', true)
        end
        return { dead = dead, code = failureCode }, nil
    end

    local dispatcher = {}

    function dispatcher:dispatchBatch(claimToken, publish, options)
        if type(claimToken) ~= 'string' or #claimToken < 8 or #claimToken > 128
            or claimToken:match('^[a-z0-9_:%-]+$') == nil then
            return nil, domainError('INVALID_OUTBOX_CLAIM', 'The account outbox claim token is invalid.')
        end
        if type(publish) ~= 'function' then
            return nil, domainError('INVALID_OUTBOX_PUBLISHER', 'The account outbox publisher is required.')
        end
        options = type(options) == 'table' and options or {}
        local maximum = tonumber(options.maximum) or DEFAULT_BATCH_SIZE
        if maximum ~= math.floor(maximum) then
            return nil, domainError('INVALID_OUTBOX_BATCH', 'The account outbox batch size must be an integer.')
        end
        maximum = math.max(1, math.min(maximum, MAXIMUM_BATCH_SIZE))

        local recovered, resetError = runUpdate([[UPDATE `synex_account_outbox`
            SET `state` = 'pending', `locked_by` = NULL, `locked_until` = NULL,
                `last_error_code` = 'OUTBOX_CLAIM_EXPIRED',
                `last_error_at` = CURRENT_TIMESTAMP(6), `dead_at` = NULL
            WHERE `state` = 'publishing'
                AND (`locked_until` IS NULL OR `locked_until` <= CURRENT_TIMESTAMP(6))]], {})
        if not recovered then return nil, resetError end

        local _, claimError = runUpdate([[UPDATE `synex_account_outbox`
            SET `state` = 'publishing', `locked_by` = ?,
                `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                `attempts` = `attempts` + 1, `last_attempt_at` = CURRENT_TIMESTAMP(6)
            WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `id` ASC LIMIT ?]], { claimToken, CLAIM_LEASE_SECONDS, maximum })
        if claimError then return nil, claimError end

        local rows, readError = runQuery([[SELECT `id`, `event_id`, `aggregate_id`, `event_type`,
                `schema_version`, `trace_id`, `payload_json`, `attempts`, `manual_retry_count`
            FROM `synex_account_outbox`
            WHERE `state` = 'publishing' AND `locked_by` = ?
            ORDER BY `id` ASC LIMIT ?]], { claimToken, maximum })
        if not rows then return nil, readError end

        local report = {
            recovered = recovered,
            claimed = #rows,
            published = 0,
            retried = 0,
            dead = 0,
            failures = {}
        }
        for _, row in ipairs(rows) do
            local startedAt = nowMilliseconds()
            local rowId = tonumber(row.id)
            if not rowId or rowId ~= math.floor(rowId) or rowId < 1 then
                return nil, domainError('OUTBOX_INVALID_ROW', 'The account outbox returned an invalid row identifier.')
            end

            local renewed, renewError = runUpdate([[UPDATE `synex_account_outbox`
                SET `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                    AND `locked_until` > CURRENT_TIMESTAMP(6)]], {
                CLAIM_LEASE_SECONDS, rowId, claimToken
            })
            if not renewed then return nil, renewError end
            if renewed ~= 1 then
                return nil, domainError('OUTBOX_CLAIM_LOST', 'The account outbox claim expired before publication.', true)
            end

            local schemaVersion = tonumber(row.schema_version)
            local traceId = validToken(row.trace_id, 8, 64) and row.trace_id or row.event_id
            local validEnvelope = isUuid(row.event_id) and isUuid(row.aggregate_id)
                and type(row.event_type) == 'string' and #row.event_type >= 3 and #row.event_type <= 96
                and row.event_type:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') ~= nil
                and schemaVersion ~= nil and schemaVersion == math.floor(schemaVersion)
                and schemaVersion >= 1 and schemaVersion <= 65535
                and type(row.payload_json) == 'string' and #row.payload_json <= MAXIMUM_PAYLOAD_BYTES
            local decoded, payload = false, nil
            if validEnvelope then
                decoded, payload = pcall(jsonDecode, row.payload_json)
                decoded = decoded and type(payload) == 'table'
                    and Foundation.jsonContainerKind(payload) ~= nil
            end

            local published, publishResult, publishError = false, nil, nil
            if decoded then
                published, publishResult, publishError = pcall(publish, row.event_type, payload, {
                    traceId = traceId,
                    eventId = row.event_id,
                    aggregateId = row.aggregate_id,
                    schemaVersion = schemaVersion
                })
            end

            local delivered = type(publishResult) == 'table' and tonumber(publishResult.delivered) or nil
            local failed = type(publishResult) == 'table' and tonumber(publishResult.failed) or nil
            local validPublishResult = delivered ~= nil and failed ~= nil
                and delivered == math.floor(delivered) and failed == math.floor(failed)
                and delivered >= 0 and failed >= 0
            if published and publishError == nil and validPublishResult and failed == 0 then
                local affected, completionError = runUpdate([[UPDATE `synex_account_outbox`
                    SET `state` = 'published', `published_at` = CURRENT_TIMESTAMP(6),
                        `last_attempt_at` = CURRENT_TIMESTAMP(6),
                        `last_error_code` = NULL, `last_error_at` = NULL, `dead_at` = NULL,
                        `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                        AND `locked_until` > CURRENT_TIMESTAMP(6)]], { rowId, claimToken })
                if not affected then return nil, completionError end
                if affected ~= 1 then
                    return nil, domainError('OUTBOX_CLAIM_LOST', 'The account event was published after its claim expired.', true)
                end
                local recorded, recordError = recordAttempt(
                    row, claimToken, 'published', nil, elapsed(startedAt))
                if not recorded then return nil, recordError end
                report.published = report.published + 1
            else
                local code = not validEnvelope and 'OUTBOX_INVALID_ENVELOPE'
                    or not decoded and 'OUTBOX_INVALID_PAYLOAD'
                    or published and validPublishResult and failed > 0 and 'OUTBOX_SUBSCRIBER_FAILED'
                    or published and not validPublishResult and 'OUTBOX_INVALID_PUBLISH_RESULT'
                    or type(publishError) == 'table' and tostring(publishError.code or 'OUTBOX_PUBLISH_FAILED')
                    or 'OUTBOX_PUBLISH_FAILED'
                code = code:match('^[A-Z0-9_]+$') and code:sub(1, 64) or 'OUTBOX_PUBLISH_FAILED'
                local failure, failureError = markFailure(row, claimToken, code)
                if not failure then return nil, failureError end
                local outcome = failure.dead and 'dead' or 'retry'
                local recorded, recordError = recordAttempt(
                    row, claimToken, outcome, failure.code, elapsed(startedAt))
                if not recorded then return nil, recordError end
                if failure.dead then report.dead = report.dead + 1 else report.retried = report.retried + 1 end
                report.failures[#report.failures + 1] = { code = failure.code, dead = failure.dead }
            end
        end
        return report, nil
    end

    function dispatcher:health()
        local rows, healthError = runQuery([[SELECT
                SUM(`state` = 'pending') AS `pending_count`,
                SUM(`state` = 'publishing') AS `publishing_count`,
                SUM(`state` = 'published') AS `published_count`,
                SUM(`state` = 'dead') AS `dead_count`,
                MIN(CASE WHEN `state` = 'pending' THEN `created_at` ELSE NULL END)
                    AS `oldest_pending_at`,
                MAX(`last_error_at`) AS `last_error_at`
            FROM `synex_account_outbox`]], {})
        if not rows then return nil, healthError end
        local row = rows[1]
        if type(row) ~= 'table' then
            return nil, domainError('OUTBOX_DATABASE_ERROR',
                'The account outbox health result was invalid.', true)
        end
        return {
            pending = integer(row.pending_count, 0, Foundation.MAX_MINOR) or 0,
            publishing = integer(row.publishing_count, 0, Foundation.MAX_MINOR) or 0,
            published = integer(row.published_count, 0, Foundation.MAX_MINOR) or 0,
            dead = integer(row.dead_count, 0, Foundation.MAX_MINOR) or 0,
            oldestPendingAt = row.oldest_pending_at and tostring(row.oldest_pending_at) or nil,
            lastErrorAt = row.last_error_at and tostring(row.last_error_at) or nil,
        }, nil
    end

    function dispatcher:inspectDead(options)
        options = type(options) == 'table' and options or {}
        local maximum = integer(options.maximum or 25, 1, MAXIMUM_INSPECTION_ROWS)
        local beforeId = integer(options.beforeId or Foundation.MAX_MINOR, 1, Foundation.MAX_MINOR)
        if not maximum or not beforeId then
            return nil, domainError('INVALID_OUTBOX_INSPECTION',
                'The account outbox inspection cursor is invalid.')
        end
        local rows, inspectionError = runQuery([[SELECT `id`, `event_id`, `aggregate_id`,
                `event_type`, `schema_version`, `trace_id`, `attempts`, `manual_retry_count`,
                `last_attempt_at`, `last_error_code`, `last_error_at`, `dead_at`, `created_at`
            FROM `synex_account_outbox`
            WHERE `state` = 'dead' AND `id` < ?
            ORDER BY `id` DESC LIMIT ?]], { beforeId, maximum })
        if not rows then return nil, inspectionError end
        local inspected = {}
        for _, row in ipairs(rows) do
            local id = integer(row.id, 1, Foundation.MAX_MINOR)
            local attempts = integer(row.attempts, 0, 65535)
            local manualRetries = integer(row.manual_retry_count, 0, 65535)
            local schemaVersion = integer(row.schema_version, 1, 65535)
            if not id or not attempts or not manualRetries or not isUuid(row.event_id)
                or not isUuid(row.aggregate_id) or not schemaVersion
                or type(row.event_type) ~= 'string' or #row.event_type < 3
                or #row.event_type > 96
                or row.event_type:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') == nil then
                return nil, domainError('OUTBOX_INVALID_ROW',
                    'The account outbox inspection returned an invalid row.')
            end
            inspected[#inspected + 1] = {
                id = tostring(id), eventId = row.event_id, aggregateId = row.aggregate_id,
                eventType = row.event_type, schemaVersion = schemaVersion,
                traceId = validToken(row.trace_id, 8, 64) and row.trace_id or nil,
                attempts = attempts, manualRetryCount = manualRetries,
                lastAttemptAt = row.last_attempt_at and tostring(row.last_attempt_at) or nil,
                lastErrorCode = tostring(row.last_error_code or 'OUTBOX_FAILURE_UNKNOWN'),
                lastErrorAt = row.last_error_at and tostring(row.last_error_at) or nil,
                deadAt = row.dead_at and tostring(row.dead_at) or nil,
                createdAt = tostring(row.created_at or ''),
            }
        end
        return { items = inspected, maximum = maximum }, nil
    end

    function dispatcher:requestRetry(command)
        if not Foundation.isCallable(withTransaction) then
            return nil, domainError('OUTBOX_RETRY_UNAVAILABLE',
                'Transactional outbox retry is unavailable.', true)
        end
        if type(command) ~= 'table' or not isUuid(command.eventId)
            or not validToken(command.idempotencyKey, 8, 128)
            or type(command.requestedByResource) ~= 'string'
            or #command.requestedByResource < 2 or #command.requestedByResource > 64
            or command.requestedByResource:match('^[a-z][a-z0-9_]*$') == nil
            or (command.requestedByRef ~= nil
                and not validToken(command.requestedByRef, 1, 128))
            or type(command.reason) ~= 'string' or #command.reason < 1 or #command.reason > 256
            or command.reason:match('%S') == nil or command.reason:match('%c') ~= nil then
            return nil, domainError('INVALID_OUTBOX_RETRY',
                'The account outbox retry request is invalid.')
        end

        local result, operationError
        local committed, transactionError = withTransaction(function(transactionQuery)
            local function rows(sql, values)
                local value = transactionQuery(sql, values or {})
                if type(value) ~= 'table' then error('outbox retry query returned an invalid result', 0) end
                return value
            end
            local previous = rows([[SELECT `request`.`public_id`, `request`.`outbox_id`,
                    `request`.`state`, `request`.`failure_code`, `request`.`completed_at`,
                    `request`.`requested_by_ref`, `request`.`reason`, `outbox`.`event_id`
                FROM `synex_account_outbox_retry_requests` AS `request`
                INNER JOIN `synex_account_outbox` AS `outbox`
                    ON `outbox`.`id` = `request`.`outbox_id`
                WHERE `request`.`requested_by_resource` = ?
                    AND `request`.`idempotency_key` = ? FOR UPDATE]], {
                command.requestedByResource, command.idempotencyKey
            })[1]
            if previous then
                if previous.event_id ~= command.eventId
                    or tostring(previous.reason or '') ~= command.reason
                    or previous.requested_by_ref ~= command.requestedByRef then
                    operationError = domainError('OUTBOX_RETRY_IDEMPOTENCY_CONFLICT',
                        'The scoped retry key belongs to a different outbox event.')
                    return false
                end
                if previous.state == 'applied' then
                    result = { retryRequestId = previous.public_id, eventId = command.eventId,
                        accepted = true, replayed = true }
                    return true
                end
                operationError = domainError(
                    previous.state == 'pending' and 'OUTBOX_RETRY_IN_PROGRESS' or 'OUTBOX_RETRY_REJECTED',
                    'The scoped account outbox retry request is not applicable.',
                    previous.state == 'pending')
                return false
            end

            local event = rows([[SELECT `id`, `event_id`, `state`, `attempts`, `manual_retry_count`
                FROM `synex_account_outbox` WHERE `event_id` = ? FOR UPDATE]], {
                command.eventId
            })[1]
            if not event then
                operationError = domainError('OUTBOX_EVENT_NOT_FOUND',
                    'The account outbox event does not exist.')
                return false
            end
            local manualRetryCount = integer(event.manual_retry_count, 0, 65535)
            local attempts = integer(event.attempts, 1, 65535)
            if event.state ~= 'dead' or not manualRetryCount or not attempts
                or manualRetryCount >= 6552 or attempts >= 65535 then
                operationError = domainError('OUTBOX_EVENT_NOT_RETRYABLE',
                    'The account outbox event is not eligible for a manual retry.')
                return false
            end

            local requestId = Foundation.uuidV4(random)
            rows([[INSERT INTO `synex_account_outbox_retry_requests`
                (`public_id`, `outbox_id`, `idempotency_key`, `requested_by_resource`,
                    `requested_by_ref`, `reason`, `state`)
                VALUES (?, ?, ?, ?, ?, ?, 'pending')]], {
                requestId, event.id, command.idempotencyKey, command.requestedByResource,
                command.requestedByRef, command.reason
            })
            local retried = rows([[UPDATE `synex_account_outbox`
                SET `state` = 'pending',
                    `available_at` = CURRENT_TIMESTAMP(6), `locked_by` = NULL,
                    `locked_until` = NULL, `published_at` = NULL,
                    `last_attempt_at` = NULL, `last_error_code` = NULL,
                    `last_error_at` = NULL, `dead_at` = NULL,
                    `manual_retry_count` = `manual_retry_count` + 1
                WHERE `id` = ? AND `state` = 'dead'
                    AND `attempts` < 65535 AND `manual_retry_count` < 6552]], {
                event.id
            })
            if integer(retried.affectedRows, 0, 1) ~= 1 then
                error('outbox manual retry state transition was fenced', 0)
            end
            local completed = rows([[UPDATE `synex_account_outbox_retry_requests`
                SET `state` = 'applied', `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `public_id` = ? AND `state` = 'pending']], { requestId })
            if integer(completed.affectedRows, 0, 1) ~= 1 then
                error('outbox manual retry request completion was fenced', 0)
            end
            result = { retryRequestId = requestId, eventId = command.eventId,
                accepted = true, replayed = false }
            return true
        end)
        if committed then return result, nil end
        if operationError then return nil, operationError end
        return nil, transactionError or domainError('OUTBOX_RETRY_FAILED',
            'The account outbox retry request could not be committed.', true)
    end

    return dispatcher
end

return createOutboxDispatcher
end
