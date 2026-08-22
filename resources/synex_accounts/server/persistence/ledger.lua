return function(port, context)
    local jsonEncode = context.jsonEncode
    local random = context.random
    local domainError = context.domainError
    local uuidV4 = context.uuidV4
    local one = context.one
    local replay = context.replay
    local execute = context.execute
    local accountState = context.accountState
    local lockedAccountStatements = context.lockedAccountStatements
    local appendStatements = context.appendStatements

local function validatePostingState(command, source, destination)
        if not source or not destination then return nil, domainError('ACCOUNT_NOT_FOUND', 'One or both accounts do not exist.') end
        if source.status ~= 'active' or destination.status ~= 'active' then
            return nil, domainError('ACCOUNT_UNAVAILABLE', 'Both accounts must be active.')
        end
        if source.currency_code ~= destination.currency_code then
            return nil, domainError('CURRENCY_MISMATCH', 'Both accounts must use the same currency.')
        end
        if command.kind == 'mint' then
            if source.account_role ~= 'mint' or destination.account_role ~= 'asset' then
                return nil, domainError('INVALID_LEDGER_ROLE', 'Mint requires a mint source and asset destination.')
            end
        elseif command.kind == 'burn' then
            if source.account_role ~= 'asset' or destination.account_role ~= 'burn' then
                return nil, domainError('INVALID_LEDGER_ROLE', 'Burn requires an asset source and burn destination.')
            end
        elseif source.account_role ~= 'asset' or destination.account_role ~= 'asset' then
            return nil, domainError('INVALID_LEDGER_ROLE', 'Transfer, debit, and credit require asset accounts.')
        end
        local available = tonumber(source.booked_minor) - tonumber(source.reserved_minor)
        if tonumber(source.allow_negative) ~= 1 and available < command.amountMinor then
            return nil, domainError('INSUFFICIENT_FUNDS', 'The debit account has insufficient available funds.')
        end
        return true, nil
    end

    function port:post(command)
        local replayed, replayError = replay(command.kind, command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local source = accountState(command.sourceAccountId)
        local destination = accountState(command.destinationAccountId)
        local valid, stateError = validatePostingState(command, source, destination)
        if not valid then return nil, stateError end

        local transactionId = uuidV4(random)
        local postingId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            transaction_id = transactionId, posting_id = postingId, transaction_kind = command.kind,
            debit_account_id = command.sourceAccountId, credit_account_id = command.destinationAccountId,
            debit_minor = command.amountMinor, credit_minor = command.amountMinor,
            currency_code = source.currency_code
        }
        local snapshot = jsonEncode(response)
        local statements = lockedAccountStatements(command.sourceAccountId, command.destinationAccountId)
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_transactions`
                (`public_id`, `operation_id`, `currency_id`, `transaction_kind`, `reference_text`, `actor_ref`, `metadata_json`)
                SELECT ?, `operation`.`id`, `source`.`currency_id`, ?, ?, ?, ?
                FROM `synex_accounts` AS `source`
                INNER JOIN `synex_accounts` AS `destination` ON `destination`.`public_id` = ?
                    AND `destination`.`currency_id` = `source`.`currency_id` AND `destination`.`status` = 'active'
                INNER JOIN `synex_account_operations` AS `operation` ON `operation`.`idempotency_key` = ?
                INNER JOIN `synex_account_balance_snapshots` AS `balance` ON `balance`.`account_id` = `source`.`id`
                    AND `balance`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `source`.`id`)
                WHERE `source`.`public_id` = ? AND `source`.`status` = 'active'
                    AND (`source`.`allow_negative` = 1 OR `balance`.`booked_minor` - `balance`.`reserved_minor` >= ?)
                    AND ((? IN ('transfer', 'debit', 'credit') AND `source`.`account_role` = 'asset' AND `destination`.`account_role` = 'asset')
                        OR (? = 'mint' AND `source`.`account_role` = 'mint' AND `destination`.`account_role` = 'asset')
                        OR (? = 'burn' AND `source`.`account_role` = 'asset' AND `destination`.`account_role` = 'burn'))]],
            values = {
                transactionId, command.kind, command.reference, command.actorRef, command.metadataJson,
                command.destinationAccountId, command.idempotencyKey, command.sourceAccountId, command.amountMinor,
                command.kind, command.kind, command.kind
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_postings`
                (`public_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `debit_minor`, `credit_minor`)
                VALUES (?, (SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ?),
                    (SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?),
                    (SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?), ?, ?)]],
            values = {
                postingId, transactionId, command.sourceAccountId, command.destinationAccountId,
                command.amountMinor, command.amountMinor
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` - ?, `previous`.`reserved_minor`
                FROM `synex_accounts` AS `account`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                WHERE `account`.`public_id` = ?]],
            values = { transactionId, command.amountMinor, command.sourceAccountId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` + ?, `previous`.`reserved_minor`
                FROM `synex_accounts` AS `account`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                WHERE `account`.`public_id` = ?]],
            values = { transactionId, command.amountMinor, command.destinationAccountId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    ?, ?, ?, ?)]],
            values = {
                eventId, command.idempotencyKey, 'synex.accounts.' .. command.kind,
                transactionId, command.actorRef, snapshot
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, ?, 1, ?)]],
            values = { eventId, transactionId, 'synex.accounts.' .. command.kind, snapshot }
        }
        return execute(command.kind, command, response, statements)
    end

function port:reverse(command)
        local replayed, replayError = replay('reverse', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local original = one([[SELECT `transaction`.`id`, `transaction`.`public_id`, `transaction`.`currency_id`,
                `currency`.`currency_code`, `posting`.`debit_account_id`, `posting`.`credit_account_id`,
                `posting`.`debit_minor`, `debit`.`public_id` AS `debit_public_id`,
                `credit`.`public_id` AS `credit_public_id`,
                `existing`.`public_id` AS `existing_reversal_id`, `parent`.`public_id` AS `parent_reversal_id`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `transaction`.`id`
            INNER JOIN `synex_accounts` AS `debit` ON `debit`.`id` = `posting`.`debit_account_id`
            INNER JOIN `synex_accounts` AS `credit` ON `credit`.`id` = `posting`.`credit_account_id`
            LEFT JOIN `synex_ledger_reversals` AS `existing` ON `existing`.`original_transaction_id` = `transaction`.`id`
            LEFT JOIN `synex_ledger_reversals` AS `parent` ON `parent`.`reversal_transaction_id` = `transaction`.`id`
            WHERE `transaction`.`public_id` = ?]], { command.transactionId })
        if not original then return nil, domainError('TRANSACTION_NOT_FOUND', 'The ledger transaction does not exist.') end
        if original.existing_reversal_id then return nil, domainError('TRANSACTION_ALREADY_REVERSED', 'The transaction already has a reversal.') end
        if original.parent_reversal_id then return nil, domainError('REVERSAL_NOT_REVERSIBLE', 'A reversal transaction cannot itself be reversed.') end
        local source = accountState(original.credit_public_id)
        local destination = accountState(original.debit_public_id)
        local amount = tonumber(original.debit_minor)
        if not source or not destination or source.status ~= 'active' or destination.status ~= 'active' then
            return nil, domainError('ACCOUNT_UNAVAILABLE', 'Both reversal accounts must be active.')
        end
        if tonumber(source.allow_negative) ~= 1
            and tonumber(source.booked_minor) - tonumber(source.reserved_minor) < amount then
            return nil, domainError('INSUFFICIENT_FUNDS', 'The reversal source has insufficient available funds.')
        end

        local reversalId = uuidV4(random)
        local transactionId = uuidV4(random)
        local postingId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            reversal_id = reversalId, original_transaction_id = command.transactionId,
            transaction_id = transactionId, posting_id = postingId,
            debit_account_id = original.credit_public_id, credit_account_id = original.debit_public_id,
            amount_minor = amount, currency_code = original.currency_code
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ? FOR UPDATE',
                values = { command.transactionId }
            }
        }
        appendStatements(statements, lockedAccountStatements(original.credit_public_id, original.debit_public_id))
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_transactions`
                (`public_id`, `operation_id`, `currency_id`, `transaction_kind`, `reference_text`, `actor_ref`, `metadata_json`)
                SELECT ?, `operation`.`id`, `original`.`currency_id`, 'transfer', ?, ?, ?
                FROM `synex_ledger_transactions` AS `original`
                INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `original`.`id`
                INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `posting`.`credit_account_id`
                    AND `source`.`status` = 'active'
                INNER JOIN `synex_accounts` AS `destination` ON `destination`.`id` = `posting`.`debit_account_id`
                    AND `destination`.`status` = 'active'
                INNER JOIN `synex_account_operations` AS `operation` ON `operation`.`idempotency_key` = ?
                INNER JOIN `synex_account_balance_snapshots` AS `balance` ON `balance`.`account_id` = `source`.`id`
                    AND `balance`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `source`.`id`)
                WHERE `original`.`public_id` = ?
                    AND (`source`.`allow_negative` = 1
                        OR `balance`.`booked_minor` - `balance`.`reserved_minor` >= `posting`.`debit_minor`)
                    AND NOT EXISTS (SELECT 1 FROM `synex_ledger_reversals`
                        WHERE `original_transaction_id` = `original`.`id` OR `reversal_transaction_id` = `original`.`id`)]],
            values = {
                transactionId, command.reason, command.actorRef, command.metadataJson,
                command.idempotencyKey, command.transactionId
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_postings`
                (`public_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `debit_minor`, `credit_minor`)
                SELECT ?, `reversal`.`id`, `posting`.`credit_account_id`, `posting`.`debit_account_id`,
                    `posting`.`credit_minor`, `posting`.`debit_minor`
                FROM `synex_ledger_transactions` AS `original`
                INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `original`.`id`
                INNER JOIN `synex_ledger_transactions` AS `reversal` ON `reversal`.`public_id` = ?
                WHERE `original`.`public_id` = ?]],
            values = { postingId, transactionId, command.transactionId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_reversals`
                (`public_id`, `original_transaction_id`, `reversal_transaction_id`, `reason`, `actor_ref`)
                VALUES (?, (SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ?),
                    (SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ?), ?, ?)]],
            values = { reversalId, command.transactionId, transactionId, command.reason, command.actorRef }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` - `posting`.`debit_minor`, `previous`.`reserved_minor`
                FROM `synex_ledger_reversals` AS `link`
                INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `link`.`reversal_transaction_id`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `posting`.`debit_account_id`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                WHERE `link`.`public_id` = ?]],
            values = { transactionId, reversalId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` + `posting`.`credit_minor`, `previous`.`reserved_minor`
                FROM `synex_ledger_reversals` AS `link`
                INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `link`.`reversal_transaction_id`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `posting`.`credit_account_id`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                WHERE `link`.`public_id` = ?]],
            values = { transactionId, reversalId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.transaction_reversed', ?, ?, ?)]],
            values = { eventId, command.idempotencyKey, transactionId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.transaction_reversed', 1, ?)]],
            values = { eventId, transactionId, snapshot }
        }
        return execute('reverse', command, response, statements)
    end
end
