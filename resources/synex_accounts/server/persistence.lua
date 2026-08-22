return function(Foundation, modules)
local domainError = Foundation.domainError
local uuidV4 = Foundation.uuidV4

local function createOxmysqlPort(deps)
    local jsonEncode = assert(deps.jsonEncode, 'oxmysql port requires jsonEncode')
    local jsonDecode = assert(deps.jsonDecode, 'oxmysql port requires jsonDecode')
    local random = assert(deps.random, 'oxmysql port requires random')

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

    local function withTransaction(handler)
        if type(MySQL.startTransaction) ~= 'function' then
            return nil, domainError('TRANSACTION_UNAVAILABLE', 'Interactive database transactions are unavailable.', true)
        end
        local committed = MySQL.startTransaction(handler)
        if committed ~= true then
            return nil, domainError('WRITE_CONFLICT', 'The account transaction could not be committed.', true)
        end
        return true, nil
    end

    local function replay(operationName, idempotencyKey, requestFingerprint)
        local row = one([[SELECT `operation_name`, `request_fingerprint`, `state`, `response_json`
            FROM `synex_account_operations` WHERE `idempotency_key` = ?]], { idempotencyKey })
        if not row then return nil, nil end
        if row.operation_name ~= operationName or row.request_fingerprint ~= requestFingerprint then
            return nil, domainError('IDEMPOTENCY_CONFLICT', 'The idempotency key was already used for a different request.')
        end
        if row.state ~= 'completed' or type(row.response_json) ~= 'string' then
            return nil, domainError('OPERATION_IN_PROGRESS', 'The idempotent operation has not completed.', true)
        end
        local response = jsonDecode(row.response_json)
        if type(response) ~= 'table' then
            return nil, domainError('DATABASE_ERROR', 'The stored idempotency response is invalid.')
        end
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
        jsonEncode = jsonEncode,
        jsonDecode = jsonDecode,
        random = random,
        domainError = domainError,
        uuidV4 = uuidV4,
        one = one,
        many = many,
        withTransaction = withTransaction,
        replay = replay,
        execute = execute,
        accountState = accountState,
        holdState = holdState,
        lockedAccountStatements = lockedAccountStatements,
        appendStatements = appendStatements
    }

    modules.accounts(port, context)
    modules.ledger(port, context)
    modules.holds(port, context)
    modules.access(port, context)
    modules.integrity(port, context)
    return port
end

return createOxmysqlPort
end
