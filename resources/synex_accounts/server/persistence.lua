return function(Foundation, modules)
local domainError = Foundation.domainError
local uuidV4 = Foundation.uuidV4

local function createOxmysqlPort(deps)
    local jsonEncode = assert(deps.jsonEncode, 'oxmysql port requires jsonEncode')
    local jsonDecode = assert(deps.jsonDecode, 'oxmysql port requires jsonDecode')
    local random = assert(deps.random, 'oxmysql port requires random')
    local domain = deps.domain
    local metrics = type(deps.metrics) == 'table' and deps.metrics or nil
    local errorSink = Foundation.isCallable(deps.errorSink) and deps.errorSink or nil
    local wait = deps.wait or rawget(_G, 'Wait') or function() end

    local function recordMetric(method, name, labels, value)
        local writer = metrics and metrics[method] or nil
        if Foundation.isCallable(writer) then pcall(writer, name, labels, value) end
    end

    local function queryRows(sql, parameters)
        local rows = MySQL.query.await(sql, parameters or {})
        if type(rows) ~= 'table' then
            error('oxmysql query returned an invalid row collection', 0)
        end
        return rows
    end

    local function one(sql, parameters)
        return queryRows(sql, parameters)[1]
    end

    local function many(sql, parameters)
        return queryRows(sql, parameters)
    end

    local function update(sql, parameters)
        local affected = MySQL.update.await(sql, parameters or {})
        if type(affected) ~= 'number' or math.type(affected) ~= 'integer' or affected < 0 then
            error('oxmysql update returned an invalid affected-row count', 0)
        end
        return affected
    end

    local function classifyTransactionFailure(value)
        local detail
        if type(value) == 'table' then
            detail = tostring(value.code or value.message or ''):lower()
        else
            detail = tostring(value or ''):lower()
        end
        if detail:find('deadlock', 1, true) or detail:find('1213', 1, true)
            or detail:find('40001', 1, true) then return 'deadlock' end
        if detail:find('lock wait timeout', 1, true)
            or detail:find('1205', 1, true) then return 'lock_timeout' end
        return 'unclassified'
    end

    local function withTransaction(handler)
        if not Foundation.isCallable(MySQL.startTransaction) then
            return nil, domainError('TRANSACTION_UNAVAILABLE', 'Interactive database transactions are unavailable.', true)
        end
        local invoked, committed = pcall(MySQL.startTransaction, handler)
        if not invoked then
            local failureKind = classifyTransactionFailure(committed)
            if failureKind == 'deadlock' then
                recordMetric('increment', 'synex_accounts_deadlocks_total', {})
            elseif failureKind == 'lock_timeout' then
                recordMetric('increment', 'synex_accounts_lock_timeouts_total', {})
            end
            return nil, domainError('WRITE_CONFLICT',
                'The account transaction could not be committed.', true), failureKind
        end
        if committed ~= true then
            return nil, domainError('WRITE_CONFLICT',
                'The account transaction could not be committed.', true), 'aborted'
        end
        return true, nil, nil
    end

    local function withRetriableTransaction(handler, options)
        options = type(options) == 'table' and options or {}
        local maximumAttempts = math.max(1, math.min(tonumber(options.maximumAttempts) or 3, 5))
        for attempt = 1, maximumAttempts do
            local committed, transactionError, failureKind = withTransaction(function(query)
                return handler(query, attempt)
            end)
            if committed then return true, nil, attempt end
            if errorSink and (failureKind == 'deadlock' or failureKind == 'lock_timeout') then
                pcall(errorSink, {
                    operation = 'database_transaction',
                    code = failureKind == 'deadlock'
                        and 'DATABASE_DEADLOCK' or 'DATABASE_LOCK_TIMEOUT',
                    traceId = options.traceId or 'unavailable',
                })
            end
            local retryable = failureKind == 'deadlock' or failureKind == 'lock_timeout'
            if options.shouldRetry then
                retryable = options.shouldRetry(
                    attempt, transactionError, failureKind) == true
            end
            if not retryable then
                return nil, transactionError, attempt
            end
            if attempt < maximumAttempts then
                recordMetric('increment', 'synex_accounts_retries_total', {
                    operation = 'database_transaction', cause = failureKind,
                })
                local delay = math.min(80, (2 ^ (attempt - 1)) * 10 + random(0, 10))
                wait(delay)
            else
                return nil, transactionError, attempt
            end
        end
        return nil, domainError('WRITE_CONFLICT', 'The account transaction retry budget was exhausted.', true)
    end

    local function replay(operationName, idempotencyKey, requestFingerprint)
        local row = one([[SELECT `operation_name`, `request_fingerprint`, `state`, `response_json`
            FROM `synex_account_operations` WHERE `idempotency_key` = ?]], { idempotencyKey })
        if not row then return nil, nil end
        if row.operation_name ~= operationName or row.request_fingerprint ~= requestFingerprint then
            recordMetric('increment', 'synex_accounts_idempotency_conflicts_total', {
                operation = operationName,
            })
            return nil, domainError('IDEMPOTENCY_CONFLICT', 'The idempotency key was already used for a different request.')
        end
        if row.state ~= 'completed' or type(row.response_json) ~= 'string' then
            return nil, domainError('OPERATION_IN_PROGRESS', 'The idempotent operation has not completed.', true)
        end
        local response = jsonDecode(row.response_json)
        if type(response) ~= 'table' then
            return nil, domainError('DATABASE_ERROR', 'The stored idempotency response is invalid.')
        end
        recordMetric('increment', 'synex_accounts_idempotency_replays_total', {
            operation = operationName,
        })
        return response, nil
    end

    local function scopedReplay(authority, operationName, idempotencyKey, requestFingerprint)
        if type(authority) ~= 'table' or type(authority.callerResource) ~= 'string' then
            return nil, domainError('CALLER_CONTEXT_INVALID', 'The account operation caller is invalid.')
        end
        local row = one([[SELECT `request_fingerprint`, `state`, `response_json`
            FROM `synex_account_operations`
            WHERE `caller_resource` = ?
                AND `caller_principal_kind` = ? AND `caller_principal_ref` = ?
                AND `operation_name` = ? AND `idempotency_key` = ?]], {
            authority.callerResource, authority.principalKind, authority.principalRef,
            operationName, idempotencyKey
        })
        if not row then return nil, nil end
        if row.request_fingerprint ~= requestFingerprint then
            recordMetric('increment', 'synex_accounts_idempotency_conflicts_total', {
                operation = operationName,
            })
            return nil, domainError('IDEMPOTENCY_CONFLICT',
                'The scoped idempotency key was already used for a different request.')
        end
        if row.state ~= 'completed' or type(row.response_json) ~= 'string' then
            return nil, domainError('OPERATION_IN_PROGRESS',
                'The scoped idempotent operation has not completed.', true)
        end
        local decoded, response = pcall(jsonDecode, row.response_json)
        if not decoded or type(response) ~= 'table' or not Foundation.jsonContainerKind(response) then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The stored idempotency response is invalid.')
        end
        recordMetric('increment', 'synex_accounts_idempotency_replays_total', {
            operation = operationName,
        })
        return response, nil
    end

    local function execute(operationName, command, response, domainStatements)
        local previous, previousError = replay(operationName, command.idempotencyKey, command.fingerprint)
        if previous or previousError then return previous, previousError end

        local responseJson = jsonEncode(response)
        local statements = {
            {
                query = [[INSERT INTO `synex_account_operations`
                    (`idempotency_key`, `operation_name`, `request_fingerprint`, `state`)
                    VALUES (?, ?, ?, 'pending')]],
                values = { command.idempotencyKey, operationName, command.fingerprint }
            }
        }
        for _, statement in ipairs(domainStatements) do statements[#statements + 1] = statement end
        statements[#statements + 1] = {
            query = [[UPDATE `synex_account_operations`
                SET `state` = 'completed', `response_json` = ?, `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `idempotency_key` = ? AND `operation_name` = ? AND `state` = 'pending']],
            values = { responseJson, command.idempotencyKey, operationName }
        }

        local committed = MySQL.transaction.await(statements)
        if committed == true then return response, nil end
        previous, previousError = replay(operationName, command.idempotencyKey, command.fingerprint)
        if previous or previousError then return previous, previousError end
        return nil, domainError('WRITE_CONFLICT', 'The account write conflicted with current state.', true)
    end

    local function accountState(accountId)
        return one([[SELECT `a`.`id`, `a`.`public_id`, `a`.`account_key`, `a`.`account_role`, `a`.`allow_negative`,
                `a`.`status`, `a`.`version`, `c`.`currency_code`, `c`.`minor_unit`,
                `o`.`owner_kind`, `o`.`owner_ref`, `s`.`sequence_no`, `s`.`booked_minor`, `s`.`reserved_minor`,
                `s`.`created_at` AS `snapshot_created_at`
            FROM `synex_accounts` AS `a`
            INNER JOIN `synex_currencies` AS `c` ON `c`.`id` = `a`.`currency_id`
            INNER JOIN `synex_account_owners` AS `o` ON `o`.`account_id` = `a`.`id`
            INNER JOIN `synex_account_balance_snapshots` AS `s` ON `s`.`account_id` = `a`.`id`
                AND `s`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `a`.`id`)
            WHERE `a`.`public_id` = ?]], { accountId })
    end

    local function holdState(holdId)
        return one([[SELECT `h`.`id`, `h`.`public_id`, `source`.`public_id` AS `account_public_id`,
                `destination`.`public_id` AS `capture_account_public_id`, `h`.`amount_minor`,
                `h`.`reference_text`, `h`.`actor_ref`, `h`.`metadata_json`, `h`.`expires_at`, `h`.`created_at`,
                `event`.`event_type`, `event`.`event_id`, `event`.`occurred_at` AS `event_occurred_at`,
                CASE WHEN `event`.`event_type` = 'captured' THEN 'captured'
                    WHEN `event`.`event_type` = 'released' THEN 'released'
                    WHEN `h`.`expires_at` <= CURRENT_TIMESTAMP(6) THEN 'expired'
                    ELSE 'active' END AS `effective_state`
            FROM `synex_account_holds` AS `h`
            INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `h`.`account_id`
            INNER JOIN `synex_accounts` AS `destination` ON `destination`.`id` = `h`.`capture_account_id`
            INNER JOIN `synex_account_hold_events` AS `event` ON `event`.`hold_id` = `h`.`id`
                AND `event`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_hold_events` AS `latest` WHERE `latest`.`hold_id` = `h`.`id`)
            WHERE `h`.`public_id` = ?]], { holdId })
    end

    local function lockedAccountStatements(firstId, secondId)
        local lowerId, upperId = firstId, secondId
        if upperId < lowerId then lowerId, upperId = upperId, lowerId end
        return {
            {
                query = 'SELECT `id` FROM `synex_accounts` WHERE `public_id` = ? FOR UPDATE',
                values = { lowerId }
            },
            {
                query = 'SELECT `id` FROM `synex_accounts` WHERE `public_id` = ? FOR UPDATE',
                values = { upperId }
            },
            {
                query = [[SELECT `snapshot`.`id` FROM `synex_account_balance_snapshots` AS `snapshot`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `snapshot`.`account_id`
                    WHERE `account`.`public_id` = ?
                        AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                            FROM `synex_account_balance_snapshots` AS `latest`
                            WHERE `latest`.`account_id` = `account`.`id`)
                    FOR UPDATE]],
                values = { lowerId }
            },
            {
                query = [[SELECT `snapshot`.`id` FROM `synex_account_balance_snapshots` AS `snapshot`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `snapshot`.`account_id`
                    WHERE `account`.`public_id` = ?
                        AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                            FROM `synex_account_balance_snapshots` AS `latest`
                            WHERE `latest`.`account_id` = `account`.`id`)
                    FOR UPDATE]],
                values = { upperId }
            }
        }
    end

    local function appendStatements(target, source)
        for _, statement in ipairs(source) do target[#target + 1] = statement end
    end

    local port = {}

    local context = {
        foundation = Foundation,
        jsonEncode = jsonEncode,
        jsonDecode = jsonDecode,
        random = random,
        metrics = metrics,
        recordMetric = recordMetric,
        domain = domain,
        domainError = domainError,
        uuidV4 = uuidV4,
        one = one,
        many = many,
        update = update,
        withTransaction = withTransaction,
        withRetriableTransaction = withRetriableTransaction,
        replay = replay,
        scopedReplay = scopedReplay,
        execute = execute,
        accountState = accountState,
        holdState = holdState,
        lockedAccountStatements = lockedAccountStatements,
        appendStatements = appendStatements
    }

    if modules.engineShared then modules.engineShared(port, context) end
    modules.accounts(port, context)
    modules.ledger(port, context)
    modules.holds(port, context)
    modules.access(port, context)
    modules.integrity(port, context)
    if modules.accountsV2 then modules.accountsV2(port, context) end
    if modules.transactions then modules.transactions(port, context) end
    if modules.transactionReads then modules.transactionReads(port, context) end
    if modules.holdsV2 then modules.holdsV2(port, context) end
    if modules.accessV2 then modules.accessV2(port, context) end
    if modules.restrictionsV2 then modules.restrictionsV2(port, context) end
    if modules.integrityBehavior then
        context.integrityBehavior = modules.integrityBehavior(context)
    end
    if modules.engine then modules.engine(port, context) end
    if modules.integrityControl then modules.integrityControl(port, context) end
    if modules.observability then modules.observability(port, context) end
    if modules.lifecycle then modules.lifecycle(port, context) end
    return port
end

return createOxmysqlPort
end
