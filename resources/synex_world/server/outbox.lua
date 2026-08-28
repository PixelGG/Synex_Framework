SynexWorldOutbox = {}

local Outbox = SynexWorldOutbox
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local DEFAULT_BATCH_SIZE = 25
local MAXIMUM_BATCH_SIZE = 50
local MAXIMUM_RECOVERY_ROWS = 200
local MAXIMUM_PAYLOAD_BYTES = 32 * 1024
local MAXIMUM_ATTEMPTS = 10
local CLAIM_LEASE_SECONDS = 60
local MAXIMUM_BACKOFF_SECONDS = 300
local MAXIMUM_SAFE_INTEGER = 9007199254740991

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function outboxFailure(code, message, retryable, details)
    return Validation.failure(code, message, retryable, details)
end

local function errorValue(code, message, retryable, details)
    local _, candidate = outboxFailure(code, message, retryable, details)
    return candidate
end

local function validReference(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function sanitizeFailureCode(value)
    if type(value) ~= 'string' or #value < 3 or #value > 64
        or value:match('^[A-Z][A-Z0-9_]*$') == nil then
        return 'OUTBOX_PUBLISH_FAILED'
    end
    return value
end

local function copyPayload(value, depth, active, budget)
    local valueType = type(value)
    if valueType == 'nil' or valueType == 'boolean' or valueType == 'string' then return value end
    if valueType == 'number' then
        if not Validation.isFinite(value) then error('invalid number', 0) end
        return value
    end
    if valueType ~= 'table' or depth > 8 then error('invalid payload container', 0) end
    active, budget = active or {}, budget or { entries = 0 }
    if active[value] then error('cyclic payload', 0) end
    active[value] = true
    local copied, key, count, maximumIndex, keyKind = {}, nil, 0, 0, nil
    while true do
        key = next(value, key)
        if key == nil then break end
        count, budget.entries = count + 1, budget.entries + 1
        if budget.entries > 256 then error('payload item limit', 0) end
        local currentKind = type(key)
        if currentKind == 'number' then
            if math.type(key) ~= 'integer' or key < 1 then error('invalid array key', 0) end
            maximumIndex = math.max(maximumIndex, key)
        elseif currentKind == 'string' then
            if #key < 1 or #key > 128 or key:find('[%z\1-\31]') then
                error('invalid object key', 0)
            end
        else
            error('invalid key', 0)
        end
        if keyKind and keyKind ~= currentKind then error('mixed payload container', 0) end
        keyKind = currentKind
        copied[key] = copyPayload(rawget(value, key), depth + 1, active, budget)
    end
    if keyKind == 'number' and maximumIndex ~= count then error('sparse payload array', 0) end
    active[value] = nil
    return copied
end

function Outbox.create(options)
    options = type(options) == 'table' and options or {}
    local database, publish, jsonDecode = options.database, options.publish, options.jsonDecode
    if type(database) ~= 'table' or not callable(database.maintenance)
        or not callable(database.read) or not callable(publish) or not callable(jsonDecode) then
        error('world outbox requires a database adapter, publisher, and JSON decoder', 0)
    end
    local dispatcher = {}

    local function maintenance(operation, handler, maximumRows, maximumStatements)
        local value, operationError = database:maintenance(operation, handler, {
            maximumRows = maximumRows or MAXIMUM_BATCH_SIZE,
            maximumResultBytes = 2 * 1024 * 1024,
            maximumResponseBytes = 2 * 1024 * 1024,
            maximumStatements = maximumStatements or 4,
            timeoutMs = 15000,
        })
        if not value then return nil, operationError end
        return value
    end

    local function update(operation, sql, parameters)
        local affected, updateError = maintenance(operation, function(transaction)
            return transaction.affected(sql, parameters), nil
        end, 1, 1)
        if not affected then return nil, updateError end
        if not Validation.isInteger(affected, 0, 1) then
            return outboxFailure('OUTBOX_DATABASE_ERROR',
                'World outbox update returned an invalid result.', true)
        end
        return affected
    end

    local function claim(claimToken, maximum)
        local result, claimError = maintenance('world.outbox.claim', function(transaction)
            local recovered = transaction.affected([[UPDATE `synex_world_outbox`
                SET `state` = 'pending', `available_at` = CURRENT_TIMESTAMP(6),
                    `locked_by` = NULL, `locked_until` = NULL,
                    `last_error_code` = 'OUTBOX_CLAIM_EXPIRED'
                WHERE `state` = 'publishing'
                    AND (`locked_until` IS NULL OR `locked_until` <= CURRENT_TIMESTAMP(6))
                ORDER BY `id` ASC LIMIT ?]], { MAXIMUM_RECOVERY_ROWS })
            transaction.affected([[UPDATE `synex_world_outbox`
                SET `state` = 'publishing', `locked_by` = ?,
                    `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                    `attempts` = `attempts` + 1, `last_error_code` = NULL
                WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP(6)
                ORDER BY `id` ASC LIMIT ?]], { claimToken, CLAIM_LEASE_SECONDS, maximum })
            local rows = transaction.many([[SELECT `id`, `event_id`, `aggregate_id`,
                    `event_type`, `schema_version`, `payload_json`, `trace_id`, `attempts`
                FROM `synex_world_outbox`
                WHERE `state` = 'publishing' AND `locked_by` = ?
                ORDER BY `id` ASC LIMIT ?]], { claimToken, maximum }, maximum)
            return { recovered = recovered, rows = rows }, nil
        end, maximum, 3)
        if not result then return nil, claimError end
        if type(result) ~= 'table' or not Validation.isInteger(result.recovered, 0,
                MAXIMUM_RECOVERY_ROWS) or type(result.rows) ~= 'table'
            or #result.rows > maximum then
            return outboxFailure('OUTBOX_DATABASE_ERROR',
                'World outbox claim returned an invalid result.', true)
        end
        return result
    end

    local function decodeRow(row, claimToken)
        local rowId, schemaVersion, attempts = integer(row.id, 1, 9007199254740991),
            integer(row.schema_version, 1, 65535), integer(row.attempts, 1, 65535)
        if not rowId or not schemaVersion or not attempts
            or not validReference(row.event_id, 8, 36)
            or not validReference(row.aggregate_id, 1, 128)
            or type(row.event_type) ~= 'string' or #row.event_type < 3
            or #row.event_type > 96
            or row.event_type:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') == nil
            or not validReference(row.trace_id, 8, 64)
            or type(row.payload_json) ~= 'string' or #row.payload_json < 2
            or #row.payload_json > MAXIMUM_PAYLOAD_BYTES then
            return nil, errorValue('OUTBOX_INVALID_ENVELOPE',
                'World outbox row is malformed and cannot be published.')
        end
        local decoded, payload = pcall(jsonDecode, row.payload_json)
        if decoded then decoded, payload = pcall(copyPayload, payload, 0) end
        if not decoded or type(payload) ~= 'table' then
            return nil, errorValue('OUTBOX_INVALID_PAYLOAD',
                'World outbox payload is invalid and cannot be published.')
        end
        return {
            id = rowId,
            eventId = row.event_id,
            aggregateId = row.aggregate_id,
            eventType = row.event_type,
            schemaVersion = schemaVersion,
            traceId = row.trace_id,
            attempts = attempts,
            claimToken = claimToken,
            payload = payload,
        }
    end

    local function markFailure(row, failureCode)
        local dead = row.attempts >= MAXIMUM_ATTEMPTS
        local delay = math.min(MAXIMUM_BACKOFF_SECONDS, 2 ^ math.min(row.attempts, 8))
        local affected, updateError = update('world.outbox.retry', [[UPDATE `synex_world_outbox`
            SET `state` = ?, `available_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                `locked_by` = NULL, `locked_until` = NULL, `last_error_code` = ?
            WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]], {
            dead and 'dead' or 'pending', delay, sanitizeFailureCode(failureCode),
            row.id, row.claimToken,
        })
        if not affected then return nil, updateError end
        if affected ~= 1 then
            return outboxFailure('OUTBOX_CLAIM_LOST',
                'World outbox claim changed before retry state was saved.', true)
        end
        return { dead = dead, code = sanitizeFailureCode(failureCode) }
    end

    function dispatcher:dispatchBatch(claimToken, optionsValue)
        if not validReference(claimToken, 8, 128) then
            return outboxFailure('INVALID_OUTBOX_CLAIM', 'World outbox claim token is invalid.')
        end
        optionsValue = type(optionsValue) == 'table' and optionsValue or {}
        local maximum = optionsValue.maximum or DEFAULT_BATCH_SIZE
        if not Validation.isInteger(maximum, 1, MAXIMUM_BATCH_SIZE) then
            return outboxFailure('INVALID_OUTBOX_BATCH', 'World outbox batch size is invalid.')
        end
        local claimed, claimError = claim(claimToken, maximum)
        if not claimed then return nil, claimError end
        local report = {
            delivery = 'at-least-once',
            recovered = claimed.recovered,
            claimed = #claimed.rows,
            published = 0,
            retried = 0,
            dead = 0,
            failures = {},
        }
        for _, rawRow in ipairs(claimed.rows) do
            local row, rowError = decodeRow(rawRow, claimToken)
            if not row then
                local fallback = {
                    id = integer(rawRow.id, 1, 9007199254740991),
                    attempts = integer(rawRow.attempts, 1, 65535) or MAXIMUM_ATTEMPTS,
                    claimToken = claimToken,
                }
                if not fallback.id then return nil, rowError end
                local failure, failureError = markFailure(fallback, rowError.code)
                if not failure then return nil, failureError end
                report[failure.dead and 'dead' or 'retried'] =
                    report[failure.dead and 'dead' or 'retried'] + 1
                report.failures[#report.failures + 1] = failure
            else
                local renewed, renewError = update('world.outbox.renew', [[UPDATE `synex_world_outbox`
                    SET `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                        AND `locked_until` > CURRENT_TIMESTAMP(6)]], {
                    CLAIM_LEASE_SECONDS, row.id, claimToken,
                })
                if not renewed then return nil, renewError end
                if renewed ~= 1 then
                    return outboxFailure('OUTBOX_CLAIM_LOST',
                        'World outbox claim expired before publication.', true)
                end
                local published, publishResult, publishError = pcall(publish,
                    row.eventType, row.payload, {
                        traceId = row.traceId,
                        eventId = row.eventId,
                        aggregateId = row.aggregateId,
                        schemaVersion = row.schemaVersion,
                    })
                local delivered = type(publishResult) == 'table'
                    and integer(publishResult.delivered, 0, 9007199254740991) or nil
                local failed = type(publishResult) == 'table'
                    and integer(publishResult.failed, 0, 9007199254740991) or nil
                if published and publishError == nil and delivered and failed == 0 then
                    local affected, completionError = update('world.outbox.complete',
                        [[UPDATE `synex_world_outbox`
                            SET `state` = 'published', `published_at` = CURRENT_TIMESTAMP(6),
                                `locked_by` = NULL, `locked_until` = NULL,
                                `last_error_code` = NULL
                            WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?
                                AND `locked_until` > CURRENT_TIMESTAMP(6)]],
                        { row.id, claimToken })
                    if not affected then return nil, completionError end
                    if affected ~= 1 then
                        return outboxFailure('OUTBOX_CLAIM_LOST',
                            'World event was delivered after its claim expired.', true)
                    end
                    report.published = report.published + 1
                else
                    local code = published and type(publishError) == 'table'
                            and publishError.code
                        or published and delivered ~= nil and failed and failed > 0
                            and 'OUTBOX_SUBSCRIBER_FAILED'
                        or published and 'OUTBOX_INVALID_PUBLISH_RESULT'
                        or 'OUTBOX_PUBLISH_FAILED'
                    local failure, failureError = markFailure(row, code)
                    if not failure then return nil, failureError end
                    report[failure.dead and 'dead' or 'retried'] =
                        report[failure.dead and 'dead' or 'retried'] + 1
                    report.failures[#report.failures + 1] = failure
                end
            end
        end
        return report
    end

    function dispatcher:status()
        local rows, readError = database:read([[SELECT `state`, COUNT(*) AS `entries`,
                COALESCE(MAX(`attempts`), 0) AS `maximum_attempts`
            FROM `synex_world_outbox` GROUP BY `state` ORDER BY `state` ASC]], {}, {
            maximumRows = 4, maximumResultBytes = 16384,
        })
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > 4 then
            return outboxFailure('OUTBOX_DATABASE_ERROR',
                'World outbox status returned an invalid result.', true)
        end
        local result = { pending = 0, publishing = 0, published = 0, dead = 0,
            maximumAttempts = 0 }
        for _, row in ipairs(rows) do
            local entries, attempts = integer(row.entries, 0, MAXIMUM_SAFE_INTEGER),
                integer(row.maximum_attempts, 0, 65535)
            if result[row.state] == nil or not entries or not attempts then
                return outboxFailure('OUTBOX_DATABASE_ERROR',
                    'World outbox status contains an invalid row.', true)
            end
            result[row.state] = entries
            result.maximumAttempts = math.max(result.maximumAttempts, attempts)
        end
        result.delivery = 'at-least-once'
        return result
    end

    return dispatcher
end
