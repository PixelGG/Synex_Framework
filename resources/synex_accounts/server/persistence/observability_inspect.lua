return function(port, context, helpers)
local Foundation = context.foundation
local domainError = context.domainError
local one = context.one
local many = context.many
local INSPECT_LIMIT = helpers.INSPECT_LIMIT
local decimal = helpers.decimal
local timestamp = helpers.timestamp
local bounded = helpers.bounded
local decimalFields = helpers.decimalFields

function port:inspectTransaction(transactionPublicId)
    if not Foundation.isUuid(transactionPublicId) then
        return nil, domainError('VALIDATION_FAILED',
            'A valid transaction public UUID is required.')
    end
    local transaction = one([[SELECT `transaction`.`public_id` AS `transaction_id`,
            `currency`.`public_id` AS `currency_id`, `currency`.`currency_code`,
            `currency`.`minor_unit`, `transaction`.`transaction_kind`,
            `transaction`.`posting_model`, CAST(`transaction`.`entry_count` AS CHAR)
                AS `entry_count`, `transaction`.`status`, `transaction`.`reason_code`,
            `transaction`.`source_resource`, `transaction`.`trace_id`,
            `transaction`.`reference_type`, `transaction`.`reference_id`,
            `transaction`.`actor_kind`,
            `transaction`.`actor_ref`, `operation`.`operation_name`,
            `operation`.`caller_resource`, `operation`.`caller_principal_kind`,
            `operation`.`caller_principal_ref`,
            DATE_FORMAT(`transaction`.`occurred_at`, '%Y-%m-%dT%H:%i:%s.%fZ')
                AS `occurred_at`,
            DATE_FORMAT(`transaction`.`posted_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `posted_at`
        FROM `synex_ledger_transactions` AS `transaction`
        INNER JOIN `synex_currencies` AS `currency`
            ON `currency`.`id` = `transaction`.`currency_id`
        INNER JOIN `synex_account_operations` AS `operation`
            ON `operation`.`id` = `transaction`.`operation_id`
        WHERE `transaction`.`public_id` = ?]], { transactionPublicId })
    if not transaction then
        return nil, domainError('TRANSACTION_NOT_FOUND', 'The transaction does not exist.')
    end
    local entryCount, entryCountError = decimal(transaction.entry_count, 'entry_count', false)
    if not entryCount then return nil, entryCountError end
    transaction.entry_count = entryCount
    transaction.minor_unit = tonumber(transaction.minor_unit)
    if transaction.minor_unit == nil or transaction.minor_unit < 0
        or transaction.minor_unit > 6 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The transaction currency minor-unit value is invalid.')
    end
    transaction.occurred_at, transaction.posted_at = timestamp(transaction.occurred_at),
        timestamp(transaction.posted_at)

    local entryRows = many([[SELECT `entry`.`public_id` AS `entry_id`,
            CAST(`entry`.`sequence_no` AS CHAR) AS `sequence`,
            `account`.`public_id` AS `account_id`, `account`.`account_role`,
            `owner`.`owner_kind`, `owner`.`owner_ref`,
            CAST(`entry`.`amount_minor` AS CHAR) AS `amount_minor`,
            DATE_FORMAT(`entry`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
        WHERE `transaction`.`public_id` = ?
        ORDER BY `entry`.`sequence_no` ASC LIMIT 17]], { transactionPublicId })
    local entries, entriesTruncated, entriesError = bounded(entryRows, INSPECT_LIMIT)
    if not entries then return nil, entriesError end
    for _, row in ipairs(entries) do
        local sequence, sequenceError = decimal(row.sequence, 'entry_sequence', false)
        if not sequence then return nil, sequenceError end
        local amount, amountError = decimal(row.amount_minor, 'entry_amount_minor', true)
        if not amount then return nil, amountError end
        row.sequence, row.amount_minor = sequence, amount
        row.created_at = timestamp(row.created_at)
    end

    local reversalRows = many([[SELECT `relation`.`public_id` AS `relation_id`,
            `original`.`public_id` AS `original_transaction_id`,
            `inverse`.`public_id` AS `reversal_transaction_id`,
            DATE_FORMAT(`relation`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
        FROM `synex_ledger_reversals` AS `relation`
        INNER JOIN `synex_ledger_transactions` AS `original`
            ON `original`.`id` = `relation`.`original_transaction_id`
        INNER JOIN `synex_ledger_transactions` AS `inverse`
            ON `inverse`.`id` = `relation`.`reversal_transaction_id`
        WHERE `original`.`public_id` = ? OR `inverse`.`public_id` = ?
        ORDER BY `relation`.`id` DESC LIMIT 2]], {
        transactionPublicId, transactionPublicId
    })
    for _, row in ipairs(reversalRows) do row.created_at = timestamp(row.created_at) end

    local refundRows = many([[SELECT `refund`.`public_id` AS `refund_id`,
            `original`.`public_id` AS `original_transaction_id`,
            `refunded`.`public_id` AS `refund_transaction_id`,
            CAST(`refund`.`sequence_no` AS CHAR) AS `sequence`,
            CAST(`refund`.`amount_minor` AS CHAR) AS `amount_minor`,
            CAST(`refund`.`cumulative_refunded_minor` AS CHAR)
                AS `cumulative_refunded_minor`, `refund`.`reason_code`,
            DATE_FORMAT(`refund`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
        FROM `synex_ledger_refunds` AS `refund`
        INNER JOIN `synex_ledger_transactions` AS `original`
            ON `original`.`id` = `refund`.`anchor_transaction_id`
        INNER JOIN `synex_ledger_transactions` AS `refunded`
            ON `refunded`.`id` = `refund`.`refund_transaction_id`
        WHERE `original`.`public_id` = ? OR `refunded`.`public_id` = ?
        ORDER BY `refund`.`id` DESC LIMIT 17]], { transactionPublicId, transactionPublicId })
    local refunds, refundsTruncated, refundsError = bounded(refundRows, INSPECT_LIMIT)
    if not refunds then return nil, refundsError end
    for _, row in ipairs(refunds) do
        local values, valuesError = decimalFields(row, {
            { 'sequence' }, { 'amount_minor' }, { 'cumulative_refunded_minor' },
        })
        if not values then return nil, valuesError end
        row.sequence, row.amount_minor = values.sequence, values.amount_minor
        row.cumulative_refunded_minor = values.cumulative_refunded_minor
        row.created_at = timestamp(row.created_at)
    end

    local eventRows = many([[SELECT `event_id`, `event_type`, `state`,
            CAST(`attempts` AS CHAR) AS `attempts`, `last_error_code`,
            DATE_FORMAT(`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
            DATE_FORMAT(`published_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `published_at`
        FROM `synex_account_outbox` WHERE `aggregate_id` = ?
        ORDER BY `id` DESC LIMIT 17]], { transactionPublicId })
    local events, eventsTruncated, eventsError = bounded(eventRows, INSPECT_LIMIT)
    if not events then return nil, eventsError end
    for _, row in ipairs(events) do
        local attempts, attemptsError = decimal(row.attempts, 'outbox_attempts', false)
        if not attempts then return nil, attemptsError end
        row.attempts = attempts
        row.created_at, row.published_at = timestamp(row.created_at), timestamp(row.published_at)
    end

    return {
        transaction = transaction,
        entries = { items = entries, truncated = entriesTruncated },
        reversals = reversalRows,
        refunds = { items = refunds, truncated = refundsTruncated },
        outbox = { items = events, truncated = eventsTruncated },
    }, nil
end

function port:inspectAccount(accountPublicId)
    if not Foundation.isUuid(accountPublicId) then
        return nil, domainError('VALIDATION_FAILED', 'A valid account public UUID is required.')
    end
    local account = one([[SELECT `account`.`public_id` AS `account_id`,
            `account`.`account_key`, `account`.`account_role`, `account`.`status`,
            `owner`.`owner_kind`, `owner`.`owner_ref`,
            `currency`.`public_id` AS `currency_id`, `currency`.`currency_code`,
            `currency`.`minor_unit`, CAST(`account`.`version` AS CHAR) AS `version`,
            CAST(`snapshot`.`sequence_no` AS CHAR) AS `snapshot_sequence`,
            CAST(`snapshot`.`booked_minor` AS CHAR) AS `booked_minor`,
            CAST(COALESCE((SELECT SUM(`hold`.`remaining_minor`)
                FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0)
                AS CHAR) AS `held_minor`,
            CAST(`snapshot`.`booked_minor` - COALESCE((
                SELECT SUM(`hold`.`remaining_minor`)
                FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0)
                AS CHAR) AS `available_minor`,
            CAST((SELECT COUNT(*) FROM `synex_account_access_grants` AS `grant`
                WHERE `grant`.`account_id` = `account`.`id`
                    AND `grant`.`status` = 'active' AND `grant`.`active_marker` = 1
                    AND `grant`.`valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`grant`.`valid_until` IS NULL
                        OR `grant`.`valid_until` > CURRENT_TIMESTAMP(6)))
                AS CHAR) AS `active_access_count`,
            CAST((SELECT COUNT(*) FROM `synex_account_restrictions` AS `restriction`
                WHERE `restriction`.`account_id` = `account`.`id`
                    AND `restriction`.`status` = 'active'
                    AND `restriction`.`active_marker` = 1
                    AND `restriction`.`valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`restriction`.`valid_until` IS NULL
                        OR `restriction`.`valid_until` > CURRENT_TIMESTAMP(6)))
                AS CHAR) AS `active_restriction_count`,
            DATE_FORMAT(`account`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
            DATE_FORMAT(`account`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`,
            DATE_FORMAT(`account`.`closed_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `closed_at`,
            DATE_FORMAT(`snapshot`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ')
                AS `snapshot_created_at`
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `account`.`currency_id`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`public_id` = ?]], { accountPublicId })
    if not account then
        return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.')
    end
    local values, valuesError = decimalFields(account, {
        { 'version' }, { 'snapshot_sequence' }, { 'booked_minor', true },
        { 'held_minor' }, { 'available_minor', true }, { 'active_access_count' },
        { 'active_restriction_count' },
    })
    if not values then return nil, valuesError end
    for key, value in pairs(values) do account[key] = value end
    account.minor_unit = tonumber(account.minor_unit)
    if account.minor_unit == nil or account.minor_unit < 0 or account.minor_unit > 6 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The account currency minor-unit value is invalid.')
    end
    account.created_at, account.updated_at = timestamp(account.created_at), timestamp(account.updated_at)
    account.closed_at, account.snapshot_created_at = timestamp(account.closed_at),
        timestamp(account.snapshot_created_at)

    local activityRows = many([[SELECT `transaction`.`public_id` AS `transaction_id`,
            `transaction`.`transaction_kind`, `transaction`.`reason_code`,
            `transaction`.`source_resource`, `transaction`.`trace_id`,
            CAST(`entry`.`sequence_no` AS CHAR) AS `entry_sequence`,
            CAST(`entry`.`amount_minor` AS CHAR) AS `amount_minor`,
            DATE_FORMAT(`transaction`.`occurred_at`, '%Y-%m-%dT%H:%i:%s.%fZ')
                AS `occurred_at`
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `account`.`public_id` = ?
        ORDER BY `transaction`.`id` DESC LIMIT 17]], { accountPublicId })
    local activity, activityTruncated, activityError = bounded(activityRows, INSPECT_LIMIT)
    if not activity then return nil, activityError end
    for _, row in ipairs(activity) do
        local itemValues, itemError = decimalFields(row, {
            { 'entry_sequence' }, { 'amount_minor', true },
        })
        if not itemValues then return nil, itemError end
        row.entry_sequence, row.amount_minor = itemValues.entry_sequence, itemValues.amount_minor
        row.occurred_at = timestamp(row.occurred_at)
    end

    local holdRows = many([[SELECT `hold`.`public_id` AS `hold_id`,
            `capture`.`public_id` AS `capture_account_id`, `hold`.`state`,
            `hold`.`capture_policy`, CAST(`hold`.`amount_minor` AS CHAR) AS `amount_minor`,
            CAST(`hold`.`captured_minor` AS CHAR) AS `captured_minor`,
            CAST(`hold`.`released_minor` AS CHAR) AS `released_minor`,
            CAST(`hold`.`remaining_minor` AS CHAR) AS `remaining_minor`,
            DATE_FORMAT(`hold`.`expires_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `expires_at`
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `hold`.`account_id`
        INNER JOIN `synex_accounts` AS `capture` ON `capture`.`id` = `hold`.`capture_account_id`
        WHERE `source`.`public_id` = ?
            AND `hold`.`state` IN ('active', 'partially_captured')
            AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)
        ORDER BY `hold`.`expires_at` ASC, `hold`.`id` ASC LIMIT 17]], { accountPublicId })
    local holds, holdsTruncated, holdsError = bounded(holdRows, INSPECT_LIMIT)
    if not holds then return nil, holdsError end
    for _, row in ipairs(holds) do
        local itemValues, itemError = decimalFields(row, {
            { 'amount_minor' }, { 'captured_minor' }, { 'released_minor' },
            { 'remaining_minor' },
        })
        if not itemValues then return nil, itemError end
        row.amount_minor, row.captured_minor = itemValues.amount_minor, itemValues.captured_minor
        row.released_minor, row.remaining_minor = itemValues.released_minor,
            itemValues.remaining_minor
        row.expires_at = timestamp(row.expires_at)
    end

    return {
        account = account,
        recent_activity = { items = activity, truncated = activityTruncated },
        active_holds = { items = holds, truncated = holdsTruncated },
    }, nil
end

end
