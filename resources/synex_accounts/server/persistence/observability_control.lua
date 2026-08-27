return function(port, context, helpers)
local domainError = context.domainError
local one = context.one
local many = context.many
local SUMMARY_PAGE_LIMIT = helpers.SUMMARY_PAGE_LIMIT
local FINDING_LIMIT = helpers.FINDING_LIMIT
local CURRENCY_LIMIT = helpers.CURRENCY_LIMIT
local economyPeriods = helpers.economyPeriods
local decimal = helpers.decimal
local timestamp = helpers.timestamp
local bounded = helpers.bounded
local decimalFields = helpers.decimalFields
local readEconomyPeriod = helpers.readEconomyPeriod

function port:getAccountsControlSummary()
    local generated = one([[SELECT DATE_FORMAT(UTC_TIMESTAMP(6),
        '%Y-%m-%dT%H:%i:%s.%fZ') AS `generated_at`]]) or {}
    local overview = one([[SELECT
            CAST((SELECT COUNT(*) FROM `synex_currencies`) AS CHAR) AS `currencies`,
            CAST((SELECT COUNT(*) FROM `synex_accounts`) AS CHAR) AS `accounts`,
            CAST((SELECT COUNT(*) FROM `synex_ledger_transactions`
                WHERE `status` = 'posted') AS CHAR) AS `transactions`,
            CAST((SELECT COUNT(*) FROM `synex_ledger_entries`) AS CHAR) AS `entries`,
            CAST((SELECT COUNT(*) FROM `synex_account_holds`
                WHERE `state` IN ('active', 'partially_captured')
                    AND `expires_at` > CURRENT_TIMESTAMP(6)) AS CHAR) AS `active_holds`,
            CAST((SELECT COUNT(*) FROM `synex_account_access_grants`
                WHERE `status` = 'active' AND `active_marker` = 1
                    AND `valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6)))
                AS CHAR) AS `active_grants`,
            CAST((SELECT COUNT(*) FROM `synex_economy_reconciliation_runs`)
                AS CHAR) AS `reconciliations`,
            CAST((SELECT COUNT(*) FROM `synex_economy_anomaly_findings`)
                AS CHAR) AS `anomalies`]]) or {}
    local overviewValues, overviewError = decimalFields(overview, {
        { 'currencies' }, { 'accounts' }, { 'transactions' }, { 'entries' },
        { 'active_holds' }, { 'active_grants' }, { 'reconciliations' }, { 'anomalies' },
    })
    if not overviewValues then return nil, overviewError end

    local currencyRows = many([[SELECT `currency`.`public_id` AS `currency_id`,
            `currency`.`currency_code`, `currency`.`display_name`, `currency`.`minor_unit`,
            `currency`.`status`,
            DATE_FORMAT(`currency`.`precision_locked_at`, '%Y-%m-%dT%H:%i:%s.%fZ')
                AS `precision_locked_at`,
            `topology`.`topology_state`, `mint`.`public_id` AS `mint_account_id`,
            `burn`.`public_id` AS `burn_account_id`, `model`.`status` AS `integrity_status`,
            CAST(`model`.`model_version` AS CHAR) AS `model_version`,
            CAST(`model`.`finding_count` AS CHAR) AS `finding_count`,
            DATE_FORMAT(`model`.`generated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `generated_at`
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `currency`.`id`
        LEFT JOIN `synex_accounts` AS `mint` ON `mint`.`id` = `topology`.`mint_account_id`
        LEFT JOIN `synex_accounts` AS `burn` ON `burn`.`id` = `topology`.`burn_account_id`
        LEFT JOIN `synex_economy_integrity_read_models` AS `model`
            ON `model`.`currency_id` = `currency`.`id`
        ORDER BY `currency`.`currency_code` ASC LIMIT 13]])
    local currencies, currenciesTruncated, currenciesError = bounded(currencyRows, CURRENCY_LIMIT)
    if not currencies then return nil, currenciesError end
    for _, row in ipairs(currencies) do
        row.minor_unit = tonumber(row.minor_unit)
        if row.minor_unit == nil or row.minor_unit < 0 or row.minor_unit > 6 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'A currency minor-unit value is invalid.')
        end
        if row.model_version ~= nil then
            local modelVersion, modelVersionError = decimal(
                row.model_version, 'model_version', false)
            if not modelVersion then return nil, modelVersionError end
            row.model_version = modelVersion
        end
        if row.finding_count ~= nil then
            local findingCount, findingCountError = decimal(
                row.finding_count, 'finding_count', false)
            if not findingCount then return nil, findingCountError end
            row.finding_count = findingCount
        end
        row.precision_locked_at = timestamp(row.precision_locked_at)
        row.generated_at = timestamp(row.generated_at)
    end

    local accountDimensions = many([[SELECT 'status' AS `dimension`, `status` AS `value`,
            CAST(COUNT(*) AS CHAR) AS `count` FROM `synex_accounts` GROUP BY `status`
        UNION ALL
        SELECT 'role', `account_role`, CAST(COUNT(*) AS CHAR)
            FROM `synex_accounts` GROUP BY `account_role`
        UNION ALL
        SELECT 'owner_kind', `owner_kind`, CAST(COUNT(*) AS CHAR)
            FROM `synex_account_owners` GROUP BY `owner_kind`
        ORDER BY `dimension` ASC, `value` ASC LIMIT 16]])
    for _, row in ipairs(accountDimensions) do
        local count, countError = decimal(row.count, 'account_dimension_count', false)
        if not count then return nil, countError end
        row.count = count
    end

    local ledger = one([[SELECT
            CAST(COUNT(DISTINCT `transaction`.`id`) AS CHAR) AS `transaction_count`,
            CAST(COUNT(`entry`.`id`) AS CHAR) AS `entry_count`,
            CAST(COALESCE(SUM(`entry`.`amount_minor`), 0) AS CHAR) AS `entry_sum_minor`,
            CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
                THEN `entry`.`amount_minor` ELSE 0 END), 0) AS CHAR) AS `credit_minor`,
            CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` < 0
                THEN -`entry`.`amount_minor` ELSE 0 END), 0) AS CHAR) AS `debit_minor`,
            CAST((SELECT COUNT(*) FROM (
                SELECT `candidate`.`id`
                FROM `synex_ledger_transactions` AS `candidate`
                LEFT JOIN `synex_ledger_entries` AS `candidate_entry`
                    ON `candidate_entry`.`transaction_id` = `candidate`.`id`
                WHERE `candidate`.`status` = 'posted'
                GROUP BY `candidate`.`id`, `candidate`.`entry_count`
                HAVING COUNT(`candidate_entry`.`id`) <> `candidate`.`entry_count`
                    OR COUNT(`candidate_entry`.`id`) NOT BETWEEN 2 AND 16
                    OR COALESCE(SUM(`candidate_entry`.`amount_minor`), 1) <> 0
            ) AS `violations`) AS CHAR) AS `zero_sum_violations`
        FROM `synex_ledger_transactions` AS `transaction`
        LEFT JOIN `synex_ledger_entries` AS `entry`
            ON `entry`.`transaction_id` = `transaction`.`id`
        WHERE `transaction`.`status` = 'posted']]) or {}
    local ledgerValues, ledgerError = decimalFields(ledger, {
        { 'transaction_count' }, { 'entry_count' }, { 'entry_sum_minor', true },
        { 'credit_minor' }, { 'debit_minor' }, { 'zero_sum_violations' },
    })
    if not ledgerValues then return nil, ledgerError end

    local transactionKinds = many([[SELECT `transaction`.`transaction_kind` AS `kind`,
            CAST(COUNT(DISTINCT `transaction`.`id`) AS CHAR) AS `transaction_count`,
            CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
                THEN `entry`.`amount_minor` ELSE 0 END), 0) AS CHAR) AS `volume_minor`
        FROM `synex_ledger_transactions` AS `transaction`
        LEFT JOIN `synex_ledger_entries` AS `entry`
            ON `entry`.`transaction_id` = `transaction`.`id`
        WHERE `transaction`.`status` = 'posted'
        GROUP BY `transaction`.`transaction_kind`
        ORDER BY `transaction`.`transaction_kind` ASC LIMIT 16]])
    for _, row in ipairs(transactionKinds) do
        local values, valuesError = decimalFields(row, {
            { 'transaction_count' }, { 'volume_minor' },
        })
        if not values then return nil, valuesError end
        row.transaction_count, row.volume_minor = values.transaction_count, values.volume_minor
    end

    local holdRows = many([[SELECT `state`, CAST(COUNT(*) AS CHAR) AS `count`,
            CAST(COALESCE(SUM(`remaining_minor`), 0) AS CHAR) AS `remaining_minor`
        FROM `synex_account_holds` GROUP BY `state` ORDER BY `state` ASC LIMIT 8]])
    for _, row in ipairs(holdRows) do
        local values, valuesError = decimalFields(row, {
            { 'count' }, { 'remaining_minor' },
        })
        if not values then return nil, valuesError end
        row.count, row.remaining_minor = values.count, values.remaining_minor
    end

    local accessRows = many([[SELECT `principal_kind`, `status`,
            CAST(COUNT(*) AS CHAR) AS `count`
        FROM `synex_account_access_grants`
        GROUP BY `principal_kind`, `status`
        ORDER BY `principal_kind` ASC, `status` ASC LIMIT 16]])
    for _, row in ipairs(accessRows) do
        local count, countError = decimal(row.count, 'access_count', false)
        if not count then return nil, countError end
        row.count = count
    end
    local accessTotals = one([[SELECT
            CAST((SELECT COUNT(*) FROM `synex_account_access_roles`)
                AS CHAR) AS `roles`,
            CAST((SELECT COUNT(*) FROM `synex_account_access_grants`
                WHERE `status` = 'active' AND `valid_until` IS NOT NULL
                    AND `valid_until` <= CURRENT_TIMESTAMP(6))
                AS CHAR) AS `expired_active_grants`,
            CAST((SELECT COUNT(*) FROM `synex_account_restrictions`
                WHERE `status` = 'active' AND `active_marker` = 1
                    AND `valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6)))
                AS CHAR) AS `active_restrictions`]]) or {}
    local accessValues, accessError = decimalFields(accessTotals, {
        { 'roles' }, { 'expired_active_grants' }, { 'active_restrictions' },
    })
    if not accessValues then return nil, accessError end

    local integrityRows = many([[SELECT `currency`.`currency_code`, `model`.`status`,
            CAST(`model`.`model_version` AS CHAR) AS `model_version`,
            CAST(`model`.`finding_count` AS CHAR) AS `finding_count`,
            CAST(`model`.`total_entry_sum_minor` AS CHAR) AS `entry_sum_minor`,
            CAST(`model`.`minted_minor` AS CHAR) AS `minted_minor`,
            CAST(`model`.`burned_minor` AS CHAR) AS `burned_minor`,
            CAST(`model`.`net_supply_minor` AS CHAR) AS `net_supply_minor`,
            CAST(`model`.`total_booked_minor` AS CHAR) AS `total_booked_minor`,
            CAST(`model`.`active_held_minor` AS CHAR) AS `active_held_minor`,
            CAST(`model`.`transaction_sum_violation_count` AS CHAR)
                AS `ledger_problem_count`,
            CAST(`model`.`snapshot_drift_count` AS CHAR) AS `snapshot_problem_count`,
            CAST(`model`.`invalid_hold_count` AS CHAR) AS `hold_problem_count`,
            CAST(`model`.`invalid_topology_count` AS CHAR) AS `topology_problem_count`,
            CAST(`model`.`outbox_problem_count` AS CHAR) AS `outbox_problem_count`,
            CAST(`model`.`grant_problem_count` AS CHAR) AS `access_problem_count`,
            CAST(`model`.`idempotency_problem_count` AS CHAR)
                AS `idempotency_problem_count`,
            DATE_FORMAT(`model`.`generated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `generated_at`
        FROM `synex_economy_integrity_read_models` AS `model`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `model`.`currency_id`
        ORDER BY `currency`.`currency_code` ASC LIMIT 13]])
    local integrityModels, integrityTruncated, integrityError = bounded(
        integrityRows, CURRENCY_LIMIT)
    if not integrityModels then return nil, integrityError end
    for _, row in ipairs(integrityModels) do
        local values, valuesError = decimalFields(row, {
            { 'model_version' }, { 'finding_count' }, { 'entry_sum_minor', true },
            { 'minted_minor' }, { 'burned_minor' }, { 'net_supply_minor', true },
            { 'total_booked_minor', true }, { 'active_held_minor' },
            { 'ledger_problem_count' }, { 'snapshot_problem_count' },
            { 'hold_problem_count' }, { 'topology_problem_count' },
            { 'outbox_problem_count' }, { 'access_problem_count' },
            { 'idempotency_problem_count' },
        })
        if not values then return nil, valuesError end
        for key, value in pairs(values) do row[key] = value end
        row.generated_at = timestamp(row.generated_at)
    end

    local reconciliationRows = many([[SELECT `run`.`public_id` AS `run_id`,
            `currency`.`currency_code`, CAST(`run`.`model_version` AS CHAR) AS `model_version`,
            `run`.`status`, CAST(`run`.`finding_count` AS CHAR) AS `finding_count`,
            DATE_FORMAT(`run`.`started_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `started_at`,
            DATE_FORMAT(`run`.`completed_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `completed_at`
        FROM `synex_economy_reconciliation_runs` AS `run`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `run`.`currency_id`
        ORDER BY `run`.`id` DESC LIMIT 9]])
    local reconciliations, reconciliationsTruncated, reconciliationsError = bounded(
        reconciliationRows, SUMMARY_PAGE_LIMIT)
    if not reconciliations then return nil, reconciliationsError end
    for _, row in ipairs(reconciliations) do
        local values, valuesError = decimalFields(row, {
            { 'model_version' }, { 'finding_count' },
        })
        if not values then return nil, valuesError end
        row.model_version, row.finding_count = values.model_version, values.finding_count
        row.started_at, row.completed_at = timestamp(row.started_at), timestamp(row.completed_at)
    end

    local anomalyRows = many([[SELECT `finding`.`public_id` AS `finding_id`,
            `currency`.`currency_code`, `finding`.`rule_key` AS `rule`,
            `finding`.`severity`, `finding`.`aggregate_type`, `finding`.`aggregate_id`,
            DATE_FORMAT(`finding`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
        FROM `synex_economy_anomaly_findings` AS `finding`
        INNER JOIN `synex_economy_reconciliation_runs` AS `run`
            ON `run`.`id` = `finding`.`run_id`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `run`.`currency_id`
        WHERE `run`.`id` IN (SELECT MAX(`latest`.`id`)
            FROM `synex_economy_reconciliation_runs` AS `latest`
            WHERE `latest`.`status` <> 'running' GROUP BY `latest`.`currency_id`)
        ORDER BY `finding`.`id` DESC LIMIT 13]])
    local anomalies, anomaliesTruncated, anomaliesError = bounded(anomalyRows, FINDING_LIMIT)
    if not anomalies then return nil, anomaliesError end
    for _, row in ipairs(anomalies) do row.created_at = timestamp(row.created_at) end

    local outbox = one([[SELECT
            CAST(SUM(`state` = 'pending') AS CHAR) AS `pending`,
            CAST(SUM(`state` = 'publishing') AS CHAR) AS `publishing`,
            CAST(SUM(`state` = 'published') AS CHAR) AS `published`,
            CAST(SUM(`state` = 'dead') AS CHAR) AS `dead`,
            CAST(COALESCE(SUM(`attempts`), 0) AS CHAR) AS `attempts`,
            DATE_FORMAT(MIN(CASE WHEN `state` IN ('pending', 'publishing')
                THEN `created_at` END), '%Y-%m-%dT%H:%i:%s.%fZ') AS `oldest_pending_at`
        FROM `synex_account_outbox`]]) or {}
    local outboxValues, outboxError = decimalFields(outbox, {
        { 'pending' }, { 'publishing' }, { 'published' }, { 'dead' }, { 'attempts' },
    })
    if not outboxValues then return nil, outboxError end
    outboxValues.oldest_pending_at = timestamp(outbox.oldest_pending_at)

    local economy = {}
    for _, period in ipairs(economyPeriods) do
        local periodSummary, periodError = readEconomyPeriod(period)
        if not periodSummary then return nil, periodError end
        economy[#economy + 1] = periodSummary
    end

    return {
        service = 'synex.accounts',
        schema_version = 2,
        generated_at = timestamp(generated.generated_at),
        overview = overviewValues,
        currencies = { items = currencies, truncated = currenciesTruncated },
        accounts = { dimensions = accountDimensions },
        ledger = ledgerValues,
        transactions = { by_kind = transactionKinds },
        holds = { by_state = holdRows },
        access = { totals = accessValues, by_principal = accessRows },
        integrity = { models = integrityModels, truncated = integrityTruncated },
        reconciliation = { items = reconciliations, truncated = reconciliationsTruncated },
        anomalies = { items = anomalies, truncated = anomaliesTruncated },
        economy = { periods = economy },
        outbox = outboxValues,
    }, nil
end

end
