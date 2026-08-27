return function(Foundation)
local domainError = Foundation.domainError
local isPublicId = Foundation.isPublicId
local DEFAULT_BATCH_SIZE = 25
local MAXIMUM_BATCH_SIZE = 50
local MAXIMUM_PAYLOAD_BYTES = 32768
local CLAIM_LEASE_SECONDS = 60
local MAXIMUM_ATTEMPTS = 10
local MAXIMUM_BACKOFF_SECONDS = 300
local MAXIMUM_CONTEXT_BYTES = 4096

local function validTraceId(value)
    return type(value) == 'string' and #value >= 8 and #value <= 64
        and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
end

local function createOutboxDispatcher(deps)
    local update = assert(deps.update, 'group outbox dispatcher requires update')
    local query = assert(deps.query, 'group outbox dispatcher requires query')
    local jsonDecode = assert(deps.jsonDecode, 'group outbox dispatcher requires jsonDecode')

    local function runUpdate(sql, parameters)
        local ok, affected = pcall(update, sql, parameters)
        if not ok or type(affected) ~= 'number' or affected ~= math.floor(affected) or affected < 0 then
            return nil, domainError('OUTBOX_DATABASE_ERROR', 'The group outbox update failed.', true)
        end
        return affected, nil
    end

    local function runQuery(sql, parameters)
        local ok, rows = pcall(query, sql, parameters)
        if not ok or type(rows) ~= 'table' then
            return nil, domainError('OUTBOX_DATABASE_ERROR', 'The group outbox query failed.', true)
        end
        return rows, nil
    end

    local function markFailure(row, claimToken, failureCode)
        local attempts = tonumber(row.attempts)
        if not attempts or attempts ~= math.floor(attempts) or attempts < 1 or attempts > 65535 then
            attempts = MAXIMUM_ATTEMPTS
            failureCode = 'OUTBOX_INVALID_ROW'
        end
        local dead = attempts >= MAXIMUM_ATTEMPTS
        local delay = math.min(MAXIMUM_BACKOFF_SECONDS, 2 ^ math.min(attempts, 8))
        local affected, updateError = runUpdate([[UPDATE `synex_group_outbox`
            SET `state` = ?, `available_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                `locked_by` = NULL, `locked_until` = NULL
            WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]], {
            dead and 'dead' or 'pending', delay, row.id, claimToken
        })
        if not affected then return nil, updateError end
        if affected ~= 1 then
            return nil, domainError('OUTBOX_CLAIM_LOST', 'The group outbox claim changed before retry state was saved.', true)
        end
        return { dead = dead, code = failureCode }, nil
    end

    local function traceIdFor(row)
        if validTraceId(row.correlation_id) then return row.correlation_id end
        if type(row.context_json) == 'string'
            and #row.context_json <= MAXIMUM_CONTEXT_BYTES then
            local decodedOk, decoded = pcall(jsonDecode, row.context_json)
            if decodedOk then
                local copiedOk, context = pcall(Foundation.copyPlain, decoded, {
                    maximumDepth = 4,
                    maximumKeys = 16,
                    maximumStringBytes = 256,
                    preserveContainerKind = false
                })
                if copiedOk and type(context) == 'table'
                    and validTraceId(context.traceId) then
                    return context.traceId
                end
            end
        end
        return row.event_id
    end

    local dispatcher = {}

    function dispatcher:dispatchBatch(claimToken, publish, options)
        if type(claimToken) ~= 'string' or #claimToken < 8 or #claimToken > 128
            or claimToken:match('^[a-z0-9_:%-]+$') == nil then
            return nil, domainError('INVALID_OUTBOX_CLAIM', 'The group outbox claim token is invalid.')
        end
        if type(publish) ~= 'function' then
            return nil, domainError('INVALID_OUTBOX_PUBLISHER', 'The group outbox publisher is required.')
        end
        options = type(options) == 'table' and options or {}
        local maximum = tonumber(options.maximum) or DEFAULT_BATCH_SIZE
        if maximum ~= math.floor(maximum) then
            return nil, domainError('INVALID_OUTBOX_BATCH', 'The group outbox batch size must be an integer.')
        end
        maximum = math.max(1, math.min(maximum, MAXIMUM_BATCH_SIZE))

        local recovered, resetError = runUpdate([[UPDATE `synex_group_outbox`
            SET `state` = 'pending', `locked_by` = NULL, `locked_until` = NULL
            WHERE `state` = 'publishing'
                AND (`locked_until` IS NULL OR `locked_until` <= CURRENT_TIMESTAMP(6))]], {})
        if not recovered then return nil, resetError end

        local _, claimError = runUpdate([[UPDATE `synex_group_outbox`
            SET `state` = 'publishing', `locked_by` = ?,
                `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                `attempts` = `attempts` + 1
            WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `id` ASC LIMIT ?]], { claimToken, CLAIM_LEASE_SECONDS, maximum })
        if claimError then return nil, claimError end

        local rows, readError = runQuery([[SELECT `outbox`.`id`, `outbox`.`event_id`,
                `outbox`.`aggregate_id`, `outbox`.`event_type`, `outbox`.`schema_version`,
                `outbox`.`payload_json`, `outbox`.`attempts`,
                `history`.`correlation_id`, `history`.`context_json`
            FROM `synex_group_outbox` AS `outbox`
            LEFT JOIN `synex_group_domain_history` AS `history`
                ON `history`.`event_id` = `outbox`.`event_id`
            WHERE `outbox`.`state` = 'publishing' AND `outbox`.`locked_by` = ?
            ORDER BY `outbox`.`id` ASC LIMIT ?]], { claimToken, maximum })
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
            local rowId = tonumber(row.id)
            if not rowId or rowId ~= math.floor(rowId) or rowId < 1 then
                return nil, domainError('OUTBOX_INVALID_ROW', 'The group outbox returned an invalid row identifier.')
            end

            local renewed, renewError = runUpdate([[UPDATE `synex_group_outbox`
                SET `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                    AND `locked_until` > CURRENT_TIMESTAMP(6)]], {
                CLAIM_LEASE_SECONDS, rowId, claimToken
            })
            if not renewed then return nil, renewError end
            if renewed ~= 1 then
                return nil, domainError('OUTBOX_CLAIM_LOST', 'The group outbox claim expired before publication.', true)
            end

            local schemaVersion = tonumber(row.schema_version)
            local validEnvelope = isPublicId(row.event_id) and isPublicId(row.aggregate_id)
                and type(row.event_type) == 'string' and #row.event_type >= 3 and #row.event_type <= 96
                and row.event_type:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') ~= nil
                and schemaVersion ~= nil and schemaVersion == math.floor(schemaVersion)
                and schemaVersion >= 1 and schemaVersion <= 65535
                and type(row.payload_json) == 'string' and #row.payload_json <= MAXIMUM_PAYLOAD_BYTES
            local decoded, payload = false, nil
            if validEnvelope then
                decoded, payload = pcall(jsonDecode, row.payload_json)
                if decoded then
                    decoded, payload = pcall(Foundation.copyPlain, payload)
                end
                decoded = decoded and type(payload) == 'table'
            end

            local published, publishResult, publishError = false, nil, nil
            if decoded then
                published, publishResult, publishError = pcall(publish, row.event_type, payload, {
                    traceId = traceIdFor(row),
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
                local affected, completionError = runUpdate([[UPDATE `synex_group_outbox`
                    SET `state` = 'published', `published_at` = CURRENT_TIMESTAMP(6),
                        `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                        AND `locked_until` > CURRENT_TIMESTAMP(6)]], { rowId, claimToken })
                if not affected then return nil, completionError end
                if affected ~= 1 then
                    return nil, domainError('OUTBOX_CLAIM_LOST', 'The group event was published after its claim expired.', true)
                end
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
                if failure.dead then report.dead = report.dead + 1 else report.retried = report.retried + 1 end
                report.failures[#report.failures + 1] = { code = failure.code, dead = failure.dead }
            end
        end
        return report, nil
    end

    return dispatcher
end

return createOutboxDispatcher
end
