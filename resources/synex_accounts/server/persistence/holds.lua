return function(port, context)
    local jsonEncode = context.jsonEncode
    local random = context.random
    local domainError = context.domainError
    local uuidV4 = context.uuidV4
    local replay = context.replay
    local execute = context.execute
    local accountState = context.accountState
    local holdState = context.holdState
    local lockedAccountStatements = context.lockedAccountStatements
    local appendStatements = context.appendStatements

function port:createHold(command)
        local replayed, replayError = replay('create_hold', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local source = accountState(command.accountId)
        local destination = accountState(command.captureAccountId)
        if not source or not destination then return nil, domainError('ACCOUNT_NOT_FOUND', 'One or both hold accounts do not exist.') end
        if source.status ~= 'active' or destination.status ~= 'active'
            or source.account_role ~= 'asset' or destination.account_role ~= 'asset' then
            return nil, domainError('ACCOUNT_UNAVAILABLE', 'Hold accounts must be active asset accounts.')
        end
        if source.currency_code ~= destination.currency_code then
            return nil, domainError('CURRENCY_MISMATCH', 'Hold accounts must use the same currency.')
        end
        if tonumber(source.booked_minor) - tonumber(source.reserved_minor) < command.amountMinor then
            return nil, domainError('INSUFFICIENT_FUNDS', 'The account has insufficient available funds for the hold.')
        end

        local holdId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            hold_id = holdId, account_id = command.accountId, capture_account_id = command.captureAccountId,
            amount_minor = command.amountMinor, currency_code = source.currency_code, state = 'active',
            expires_in_seconds = command.expiresInSeconds
        }
        local snapshot = jsonEncode(response)
        local statements = lockedAccountStatements(command.accountId, command.captureAccountId)
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_holds`
                (`public_id`, `operation_id`, `account_id`, `capture_account_id`, `amount_minor`,
                    `reference_text`, `actor_ref`, `metadata_json`, `expires_at`)
                SELECT ?, `operation`.`id`, `source`.`id`, `destination`.`id`, ?, ?, ?, ?,
                    TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                FROM `synex_accounts` AS `source`
                INNER JOIN `synex_accounts` AS `destination` ON `destination`.`public_id` = ?
                    AND `destination`.`currency_id` = `source`.`currency_id`
                    AND `destination`.`status` = 'active' AND `destination`.`account_role` = 'asset'
                INNER JOIN `synex_account_operations` AS `operation` ON `operation`.`idempotency_key` = ?
                INNER JOIN `synex_account_balance_snapshots` AS `balance` ON `balance`.`account_id` = `source`.`id`
                    AND `balance`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `source`.`id`)
                WHERE `source`.`public_id` = ? AND `source`.`status` = 'active' AND `source`.`account_role` = 'asset'
                    AND `balance`.`booked_minor` - `balance`.`reserved_minor` >= ?]],
            values = {
                holdId, command.amountMinor, command.reference, command.actorRef, command.metadataJson,
                command.expiresInSeconds, command.captureAccountId, command.idempotencyKey,
                command.accountId, command.amountMinor
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_hold_events`
                (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`, `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_holds` WHERE `public_id` = ?),
                    1, 'created', NULL, NULL, ?, ?)]],
            values = { eventId, holdId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'hold', ?,
                    `previous`.`booked_minor`, `previous`.`reserved_minor` + ?
                FROM `synex_accounts` AS `account`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                INNER JOIN `synex_account_hold_events` AS `event` ON `event`.`event_id` = ?
                WHERE `account`.`public_id` = ?]],
            values = { eventId, command.amountMinor, eventId, command.accountId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.hold_created',
                    (SELECT `hold`.`public_id` FROM `synex_account_hold_events` AS `event`
                        INNER JOIN `synex_account_holds` AS `hold` ON `hold`.`id` = `event`.`hold_id`
                        WHERE `event`.`event_id` = ?), ?, ?)]],
            values = { eventId, command.idempotencyKey, eventId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.hold_created', 1, ?)]],
            values = { eventId, holdId, snapshot }
        }
        return execute('create_hold', command, response, statements)
    end

    function port:getHold(holdId)
        local row = holdState(holdId)
        if not row then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
        return {
            hold_id = row.public_id, account_id = row.account_public_id,
            capture_account_id = row.capture_account_public_id, amount_minor = tonumber(row.amount_minor),
            state = row.effective_state, reference = row.reference_text, actor_ref = row.actor_ref,
            metadata_json = row.metadata_json, expires_at = tostring(row.expires_at),
            created_at = tostring(row.created_at), event_id = row.event_id,
            event_occurred_at = tostring(row.event_occurred_at)
        }, nil
    end

    function port:captureHold(command)
        local replayed, replayError = replay('capture_hold', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local hold = holdState(command.holdId)
        if not hold then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
        if hold.effective_state == 'expired' then return nil, domainError('HOLD_EXPIRED', 'The hold has expired.') end
        if hold.effective_state ~= 'active' then return nil, domainError('HOLD_TERMINAL', 'The hold is already terminal.') end

        local transactionId = uuidV4(random)
        local postingId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            hold_id = command.holdId, state = 'captured', transaction_id = transactionId,
            posting_id = postingId, debit_account_id = hold.account_public_id,
            credit_account_id = hold.capture_account_public_id, amount_minor = tonumber(hold.amount_minor)
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_account_holds` WHERE `public_id` = ? FOR UPDATE',
                values = { command.holdId }
            }
        }
        appendStatements(statements, lockedAccountStatements(hold.account_public_id, hold.capture_account_public_id))
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_transactions`
                (`public_id`, `operation_id`, `currency_id`, `transaction_kind`, `reference_text`, `actor_ref`, `metadata_json`)
                SELECT ?, `operation`.`id`, `source`.`currency_id`, 'hold_capture', ?, ?, ?
                FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `hold`.`account_id`
                    AND `source`.`status` = 'active' AND `source`.`account_role` = 'asset'
                INNER JOIN `synex_accounts` AS `destination` ON `destination`.`id` = `hold`.`capture_account_id`
                    AND `destination`.`status` = 'active' AND `destination`.`account_role` = 'asset'
                    AND `destination`.`currency_id` = `source`.`currency_id`
                INNER JOIN `synex_account_operations` AS `operation` ON `operation`.`idempotency_key` = ?
                INNER JOIN `synex_account_balance_snapshots` AS `balance` ON `balance`.`account_id` = `source`.`id`
                    AND `balance`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `source`.`id`)
                WHERE `hold`.`public_id` = ? AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)
                    AND `balance`.`booked_minor` >= `hold`.`amount_minor`
                    AND `balance`.`reserved_minor` >= `hold`.`amount_minor`
                    AND NOT EXISTS (SELECT 1 FROM `synex_account_hold_events` AS `terminal`
                        WHERE `terminal`.`hold_id` = `hold`.`id` AND `terminal`.`terminal_marker` = 1)]],
            values = {
                transactionId, command.reference, command.actorRef, command.metadataJson,
                command.idempotencyKey, command.holdId
            }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_ledger_postings`
                (`public_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `debit_minor`, `credit_minor`)
                VALUES (?, (SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ?),
                    (SELECT `account_id` FROM `synex_account_holds` WHERE `public_id` = ?),
                    (SELECT `capture_account_id` FROM `synex_account_holds` WHERE `public_id` = ?),
                    (SELECT `amount_minor` FROM `synex_account_holds` WHERE `public_id` = ?),
                    (SELECT `amount_minor` FROM `synex_account_holds` WHERE `public_id` = ?))]],
            values = { postingId, transactionId, command.holdId, command.holdId, command.holdId, command.holdId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` - `hold`.`amount_minor`,
                    `previous`.`reserved_minor` - `hold`.`amount_minor`
                FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`account_id`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`public_id` = ?
                WHERE `hold`.`public_id` = ?]],
            values = { transactionId, transactionId, command.holdId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'ledger', ?,
                    `previous`.`booked_minor` + `hold`.`amount_minor`, `previous`.`reserved_minor`
                FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`capture_account_id`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`public_id` = ?
                WHERE `hold`.`public_id` = ?]],
            values = { transactionId, transactionId, command.holdId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_hold_events`
                (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`, `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_holds` WHERE `public_id` = ?), 2, 'captured', 1,
                    (SELECT `id` FROM `synex_ledger_transactions` WHERE `public_id` = ?), ?, ?)]],
            values = { eventId, command.holdId, transactionId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.hold_captured',
                    (SELECT `hold`.`public_id` FROM `synex_account_hold_events` AS `event`
                        INNER JOIN `synex_account_holds` AS `hold` ON `hold`.`id` = `event`.`hold_id`
                        WHERE `event`.`event_id` = ?), ?, ?)]],
            values = { eventId, command.idempotencyKey, eventId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.hold_captured', 1, ?)]],
            values = { eventId, command.holdId, snapshot }
        }
        return execute('capture_hold', command, response, statements)
    end

    function port:releaseHold(command)
        local replayed, replayError = replay('release_hold', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local hold = holdState(command.holdId)
        if not hold then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
        if hold.effective_state == 'captured' or hold.effective_state == 'released' then
            return nil, domainError('HOLD_TERMINAL', 'The hold is already terminal.')
        end

        local eventId = uuidV4(random)
        local response = {
            hold_id = command.holdId, state = 'released', account_id = hold.account_public_id,
            amount_minor = tonumber(hold.amount_minor)
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_account_holds` WHERE `public_id` = ? FOR UPDATE',
                values = { command.holdId }
            }
        }
        appendStatements(statements, lockedAccountStatements(hold.account_public_id, hold.capture_account_public_id))
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_hold_events`
                (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`, `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
                SELECT ?, `hold`.`id`, 2, 'released', 1, NULL, ?, ? FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`public_id` = ?
                    AND NOT EXISTS (SELECT 1 FROM `synex_account_hold_events` AS `terminal`
                        WHERE `terminal`.`hold_id` = `hold`.`id` AND `terminal`.`terminal_marker` = 1)]],
            values = { eventId, command.actorRef, snapshot, command.holdId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_balance_snapshots`
                (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                SELECT `account`.`id`, `previous`.`sequence_no` + 1, 'hold', ?,
                    `previous`.`booked_minor`, `previous`.`reserved_minor` - `hold`.`amount_minor`
                FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`account_id`
                INNER JOIN `synex_account_balance_snapshots` AS `previous` ON `previous`.`account_id` = `account`.`id`
                    AND `previous`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                        FROM `synex_account_balance_snapshots` AS `latest` WHERE `latest`.`account_id` = `account`.`id`)
                INNER JOIN `synex_account_hold_events` AS `event` ON `event`.`event_id` = ?
                WHERE `hold`.`public_id` = ? AND `previous`.`reserved_minor` >= `hold`.`amount_minor`]],
            values = { eventId, eventId, command.holdId }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.hold_released',
                    (SELECT `hold`.`public_id` FROM `synex_account_hold_events` AS `event`
                        INNER JOIN `synex_account_holds` AS `hold` ON `hold`.`id` = `event`.`hold_id`
                        WHERE `event`.`event_id` = ?), ?, ?)]],
            values = { eventId, command.idempotencyKey, eventId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.hold_released', 1, ?)]],
            values = { eventId, command.holdId, snapshot }
        }
        return execute('release_hold', command, response, statements)
    end
end
