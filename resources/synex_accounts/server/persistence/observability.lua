return function(port, context)
local Foundation = context.foundation
local domainError = context.domainError
local one = context.one
local many = context.many

local INSPECT_LIMIT = 16
local SUMMARY_PAGE_LIMIT = 8
local FINDING_LIMIT = 12
local CURRENCY_LIMIT = 12
local ATTRIBUTION_LIMIT = 4
local DOCTOR_LIMIT = 1000

local economyPeriods = {
    { key = '24h', interval = '1 DAY' },
    { key = '7d', interval = '7 DAY' },
    { key = '30d', interval = '30 DAY' },
}

local doctorChecks = {
    {
        key = 'currency_topology', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1
            FROM `synex_currencies` AS `currency`
            LEFT JOIN `synex_currency_system_topology` AS `topology`
                ON `topology`.`currency_id` = `currency`.`id`
            WHERE `topology`.`currency_id` IS NULL
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'mint_burn_topology', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1
            FROM `synex_currencies` AS `currency`
            INNER JOIN `synex_currency_system_topology` AS `topology`
                ON `topology`.`currency_id` = `currency`.`id`
            LEFT JOIN `synex_accounts` AS `mint`
                ON `mint`.`id` = `topology`.`mint_account_id`
            LEFT JOIN `synex_accounts` AS `burn`
                ON `burn`.`id` = `topology`.`burn_account_id`
            WHERE `currency`.`status` = 'active'
                AND (`topology`.`topology_state` <> 'ready'
                    OR `mint`.`id` IS NULL OR `mint`.`currency_id` <> `currency`.`id`
                    OR `mint`.`account_role` <> 'mint' OR `mint`.`status` = 'closed'
                    OR `burn`.`id` IS NULL OR `burn`.`currency_id` <> `currency`.`id`
                    OR `burn`.`account_role` <> 'burn' OR `burn`.`status` = 'closed'
                    OR `mint`.`id` = `burn`.`id`)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'ledger_zero_sum', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `transaction`.`id`
            FROM `synex_ledger_transactions` AS `transaction`
            LEFT JOIN `synex_ledger_entries` AS `entry`
                ON `entry`.`transaction_id` = `transaction`.`id`
            LEFT JOIN `synex_accounts` AS `account`
                ON `account`.`id` = `entry`.`account_id`
            WHERE `transaction`.`status` = 'posted'
            GROUP BY `transaction`.`id`, `transaction`.`currency_id`,
                `transaction`.`entry_count`
            HAVING COUNT(`entry`.`id`) <> `transaction`.`entry_count`
                OR COUNT(`entry`.`id`) NOT BETWEEN 2 AND 16
                OR COALESCE(SUM(`entry`.`amount_minor`), 1) <> 0
                OR SUM(`account`.`currency_id` IS NULL
                    OR `account`.`currency_id` <> `transaction`.`currency_id`) <> 0
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'snapshots', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `account`.`id`
            FROM `synex_accounts` AS `account`
            LEFT JOIN `synex_account_balance_snapshots` AS `snapshot`
                ON `snapshot`.`account_id` = `account`.`id`
                AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_balance_snapshots` AS `latest`
                    WHERE `latest`.`account_id` = `account`.`id`)
            WHERE `snapshot`.`id` IS NULL
                OR `snapshot`.`booked_minor` <> COALESCE((
                    SELECT SUM(`entry`.`amount_minor`)
                    FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`account_id` = `account`.`id`), 0)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'snapshot_reservations', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `account`.`id`
            FROM `synex_accounts` AS `account`
            INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
                ON `snapshot`.`account_id` = `account`.`id`
                AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_balance_snapshots` AS `latest`
                    WHERE `latest`.`account_id` = `account`.`id`)
            WHERE `snapshot`.`reserved_minor` <> COALESCE((
                    SELECT SUM(`hold`.`remaining_minor`)
                    FROM `synex_account_holds` AS `hold`
                    WHERE `hold`.`account_id` = `account`.`id`
                        AND `hold`.`state` IN ('active', 'partially_captured')
                        AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'holds', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1
            FROM `synex_account_holds` AS `hold`
            LEFT JOIN `synex_accounts` AS `source`
                ON `source`.`id` = `hold`.`account_id`
            LEFT JOIN `synex_accounts` AS `capture`
                ON `capture`.`id` = `hold`.`capture_account_id`
            WHERE `source`.`id` IS NULL OR `capture`.`id` IS NULL
                OR `source`.`currency_id` <> `capture`.`currency_id`
                OR `source`.`account_role` <> 'asset'
                OR `capture`.`account_role` <> 'asset'
                OR `hold`.`amount_minor` <> `hold`.`captured_minor`
                    + `hold`.`released_minor` + `hold`.`remaining_minor`
                OR (`hold`.`state` IN ('captured', 'released', 'expired')
                    AND (`hold`.`remaining_minor` <> 0 OR `hold`.`terminal_at` IS NULL))
                OR (`hold`.`state` IN ('active', 'partially_captured')
                    AND (`hold`.`remaining_minor` = 0 OR `hold`.`terminal_at` IS NOT NULL))
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'account_state', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `account`.`id`
            FROM `synex_accounts` AS `account`
            LEFT JOIN `synex_account_balance_snapshots` AS `snapshot`
                ON `snapshot`.`account_id` = `account`.`id`
                AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_balance_snapshots` AS `latest`
                    WHERE `latest`.`account_id` = `account`.`id`)
            WHERE (`account`.`status` = 'closed') <> (`account`.`closed_at` IS NOT NULL)
                OR (`account`.`account_role` = 'mint') <> (`account`.`allow_negative` = 1)
                OR (`account`.`status` = 'closed' AND COALESCE(`snapshot`.`booked_minor`, 0) <> 0)
                OR (`account`.`status` = 'closed' AND EXISTS (
                    SELECT 1 FROM `synex_account_holds` AS `hold`
                    WHERE `hold`.`account_id` = `account`.`id`
                        AND `hold`.`state` IN ('active', 'partially_captured')
                        AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)))
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'outbox_backlog', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1 FROM `synex_account_outbox`
            WHERE (`state` = 'pending'
                    AND `available_at` <= CURRENT_TIMESTAMP(6) - INTERVAL 5 MINUTE)
                OR (`state` = 'publishing'
                    AND (`locked_until` IS NULL OR `locked_until` <= CURRENT_TIMESTAMP(6)))
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'outbox_dead', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1 FROM `synex_account_outbox` WHERE `state` = 'dead' LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'expired_grants', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1 FROM `synex_account_access_grants`
            WHERE `status` = 'active' AND `active_marker` = 1
                AND `valid_until` IS NOT NULL
                AND `valid_until` <= CURRENT_TIMESTAMP(6)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'orphan_grants', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `grant`.`id`
            FROM `synex_account_access_grants` AS `grant`
            LEFT JOIN `synex_accounts` AS `account`
                ON `account`.`id` = `grant`.`account_id`
            LEFT JOIN `synex_account_access_roles` AS `role`
                ON `role`.`id` = `grant`.`role_id`
            WHERE `account`.`id` IS NULL OR `role`.`id` IS NULL
                OR `role`.`account_id` <> `grant`.`account_id`
                OR (`grant`.`status` = 'active' AND `grant`.`active_marker` <> 1)
                OR (`grant`.`status` <> 'active' AND `grant`.`active_marker` IS NOT NULL)
                OR `grant`.`valid_from` IS NULL
                OR (`grant`.`valid_until` IS NOT NULL
                    AND `grant`.`valid_until` <= `grant`.`valid_from`)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'idempotency_state', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1 FROM `synex_account_operations`
            WHERE (`state` = 'completed'
                    AND (`response_json` IS NULL OR `completed_at` IS NULL))
                OR (`state` = 'pending'
                    AND (`response_json` IS NOT NULL OR `completed_at` IS NOT NULL))
                OR `state` NOT IN ('pending', 'completed')
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'stale_idempotency', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT 1 FROM `synex_account_operations`
            WHERE `state` = 'pending'
                AND `created_at` <= CURRENT_TIMESTAMP(6) - INTERVAL 5 MINUTE
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'reconciliation_status', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `currency`.`id`
            FROM `synex_currencies` AS `currency`
            LEFT JOIN `synex_economy_integrity_read_models` AS `model`
                ON `model`.`currency_id` = `currency`.`id`
            WHERE `currency`.`status` = 'active'
                AND (`model`.`currency_id` IS NULL
                    OR `model`.`status` IN ('error', 'critical'))
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'anomaly_findings', severity = 'WARN',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `finding`.`id`
            FROM `synex_economy_anomaly_findings` AS `finding`
            INNER JOIN `synex_economy_reconciliation_runs` AS `run`
                ON `run`.`id` = `finding`.`run_id`
            WHERE `run`.`id` IN (SELECT MAX(`latest`.`id`)
                FROM `synex_economy_reconciliation_runs` AS `latest`
                WHERE `latest`.`status` <> 'running'
                GROUP BY `latest`.`currency_id`)
            LIMIT 1001
        ) AS `issues`]],
    },
    {
        key = 'character_group_references', severity = 'FAIL',
        sql = [[SELECT CAST(COUNT(*) AS CHAR) AS `count` FROM (
            SELECT `owner`.`account_id`
            FROM `synex_account_owners` AS `owner`
            WHERE `owner`.`owner_kind` IN ('character', 'group')
                AND (CHAR_LENGTH(`owner`.`owner_ref`) NOT BETWEEN 3 AND 48
                    OR `owner`.`owner_ref` NOT REGEXP
                        '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            UNION ALL
            SELECT `grant`.`id`
            FROM `synex_account_access_grants` AS `grant`
            WHERE `grant`.`principal_kind` IN ('character', 'group')
                AND (CHAR_LENGTH(`grant`.`principal_ref`) NOT BETWEEN 3 AND 48
                    OR `grant`.`principal_ref` NOT REGEXP
                        '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            UNION ALL
            SELECT `journal`.`version`
            FROM `synex_account_group_deletions` AS `journal`
            WHERE `journal`.`decision` = 'anonymize' AND `journal`.`state` = 'completed'
                AND (EXISTS (SELECT 1 FROM `synex_account_owners` AS `owner`
                        WHERE `owner`.`owner_kind` = 'group'
                            AND `owner`.`owner_ref` = `journal`.`group_ref`)
                    OR EXISTS (SELECT 1 FROM `synex_account_access_grants` AS `grant`
                        WHERE `grant`.`principal_kind` = 'group'
                            AND `grant`.`principal_ref` = `journal`.`group_ref`))
            LIMIT 1001
        ) AS `issues`]],
    },
}

local function decimal(value, label, signed)
    local candidate = value == nil and '0' or tostring(value)
    local valid = candidate:match('^%d+$') ~= nil
        or (signed == true and candidate:match('^%-%d+$') ~= nil)
    if not valid then
        return nil, domainError('DATABASE_RESULT_INVALID',
            ('The %s aggregate is not an exact decimal integer.'):format(label))
    end
    local negative = candidate:sub(1, 1) == '-'
    local digits = negative and candidate:sub(2) or candidate
    digits = digits:gsub('^0+', '')
    if digits == '' then return '0', nil end
    return (negative and '-' or '') .. digits, nil
end

local function timestamp(value)
    if value == nil then return nil end
    return tostring(value)
end

local function bounded(rows, maximum)
    if type(rows) ~= 'table' then
        return nil, nil, domainError('DATABASE_RESULT_INVALID',
            'An Accounts observability query returned an invalid row collection.')
    end
    local truncated = #rows > maximum
    while #rows > maximum do rows[#rows] = nil end
    return rows, truncated, nil
end

local function decimalFields(row, fields)
    local output = {}
    for _, definition in ipairs(fields) do
        local value, valueError = decimal(row and row[definition[1]], definition[1], definition[2])
        if not value then return nil, valueError end
        output[definition[1]] = value
    end
    return output, nil
end

local function readEconomyPeriod(period)
    local cutoff = 'UTC_TIMESTAMP(6) - INTERVAL ' .. period.interval
    local currencyRows = many(([[SELECT `currency`.`public_id` AS `currency_id`,
            `currency`.`currency_code`, `currency`.`minor_unit`,
            CAST(COUNT(DISTINCT `transaction`.`id`) AS CHAR) AS `transaction_count`,
            CAST(COUNT(`entry`.`id`) AS CHAR) AS `entry_count`,
            CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
                THEN `entry`.`amount_minor` ELSE 0 END), 0) AS CHAR)
                AS `transaction_volume_minor`,
            CAST(COALESCE(SUM(CASE
                WHEN `transaction`.`transaction_kind` = 'mint'
                    AND `account`.`account_role` = 'asset'
                    AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor`
                ELSE 0 END), 0) AS CHAR) AS `sources_minor`,
            CAST(COALESCE(SUM(CASE
                WHEN `transaction`.`transaction_kind` = 'burn'
                    AND `account`.`account_role` = 'asset'
                    AND `entry`.`amount_minor` < 0 THEN -`entry`.`amount_minor`
                ELSE 0 END), 0) AS CHAR) AS `sinks_minor`,
            CAST(COALESCE(SUM(CASE
                WHEN `transaction`.`transaction_kind` = 'mint'
                    AND `account`.`account_role` = 'asset'
                    AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor`
                WHEN `transaction`.`transaction_kind` = 'burn'
                    AND `account`.`account_role` = 'asset'
                    AND `entry`.`amount_minor` < 0 THEN `entry`.`amount_minor`
                ELSE 0 END), 0) AS CHAR) AS `net_inflation_minor`
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`currency_id` = `currency`.`id`
            AND `transaction`.`status` = 'posted'
            AND `transaction`.`occurred_at` >= %s
        LEFT JOIN `synex_ledger_entries` AS `entry`
            ON `entry`.`transaction_id` = `transaction`.`id`
        LEFT JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        GROUP BY `currency`.`id`, `currency`.`public_id`, `currency`.`currency_code`,
            `currency`.`minor_unit`
        ORDER BY `currency`.`currency_code` ASC LIMIT %d]]):format(
        cutoff, CURRENCY_LIMIT + 1))
    local currencies, currenciesTruncated, currenciesError = bounded(
        currencyRows, CURRENCY_LIMIT)
    if not currencies then return nil, currenciesError end

    local currenciesById = {}
    for _, row in ipairs(currencies) do
        local values, valuesError = decimalFields(row, {
            { 'transaction_count' }, { 'entry_count' }, { 'transaction_volume_minor' },
            { 'sources_minor' }, { 'sinks_minor' }, { 'net_inflation_minor', true },
        })
        if not values then return nil, valuesError end
        for key, value in pairs(values) do row[key] = value end
        row.minor_unit = tonumber(row.minor_unit)
        if row.minor_unit == nil or row.minor_unit < 0 or row.minor_unit > 6 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'An economy currency minor-unit value is invalid.')
        end
        row.reason_codes = { items = {}, truncated = false }
        row.resources = { items = {}, truncated = false }
        currenciesById[row.currency_id] = row
    end

    local reasonRows = many(([[SELECT `ranked`.`currency_id`, `ranked`.`reason_code`,
            `ranked`.`transaction_count`, `ranked`.`volume_minor`,
            `ranked`.`attribution_rank`
        FROM (SELECT `currency`.`public_id` AS `currency_id`,
                `transaction`.`reason_code`,
                CAST(COUNT(DISTINCT `transaction`.`id`) AS CHAR) AS `transaction_count`,
                CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
                    THEN `entry`.`amount_minor` ELSE 0 END), 0) AS CHAR) AS `volume_minor`,
                ROW_NUMBER() OVER (PARTITION BY `transaction`.`currency_id`
                    ORDER BY SUM(CASE WHEN `entry`.`amount_minor` > 0
                        THEN `entry`.`amount_minor` ELSE 0 END) DESC,
                        `transaction`.`reason_code` ASC) AS `attribution_rank`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency`
                ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_entries` AS `entry`
                ON `entry`.`transaction_id` = `transaction`.`id`
            WHERE `transaction`.`status` = 'posted'
                AND `transaction`.`occurred_at` >= %s
            GROUP BY `transaction`.`currency_id`, `currency`.`public_id`,
                `transaction`.`reason_code`) AS `ranked`
        WHERE `ranked`.`attribution_rank` <= %d
        ORDER BY `ranked`.`currency_id` ASC, `ranked`.`attribution_rank` ASC
        LIMIT %d]]):format(cutoff, ATTRIBUTION_LIMIT + 1,
        (CURRENCY_LIMIT + 1) * (ATTRIBUTION_LIMIT + 1)))
    for _, row in ipairs(reasonRows) do
        local values, valuesError = decimalFields(row, {
            { 'transaction_count' }, { 'volume_minor' },
        })
        if not values then return nil, valuesError end
        row.transaction_count, row.volume_minor = values.transaction_count, values.volume_minor
        local rank = tonumber(row.attribution_rank)
        if rank == nil or rank < 1 or rank > ATTRIBUTION_LIMIT + 1 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'An economy reason attribution rank is invalid.')
        end
        local currency = currenciesById[row.currency_id]
        if currency then
            if rank <= ATTRIBUTION_LIMIT then
                row.currency_id, row.attribution_rank = nil, nil
                currency.reason_codes.items[#currency.reason_codes.items + 1] = row
            else
                currency.reason_codes.truncated = true
            end
        end
    end

    local resourceRows = many(([[SELECT `ranked`.`currency_id`, `ranked`.`source_resource`,
            `ranked`.`transaction_count`, `ranked`.`volume_minor`,
            `ranked`.`attribution_rank`
        FROM (SELECT `currency`.`public_id` AS `currency_id`,
                `transaction`.`source_resource`,
                CAST(COUNT(DISTINCT `transaction`.`id`) AS CHAR) AS `transaction_count`,
                CAST(COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
                    THEN `entry`.`amount_minor` ELSE 0 END), 0) AS CHAR) AS `volume_minor`,
                ROW_NUMBER() OVER (PARTITION BY `transaction`.`currency_id`
                    ORDER BY SUM(CASE WHEN `entry`.`amount_minor` > 0
                        THEN `entry`.`amount_minor` ELSE 0 END) DESC,
                        `transaction`.`source_resource` ASC) AS `attribution_rank`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency`
                ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_entries` AS `entry`
                ON `entry`.`transaction_id` = `transaction`.`id`
            WHERE `transaction`.`status` = 'posted'
                AND `transaction`.`occurred_at` >= %s
            GROUP BY `transaction`.`currency_id`, `currency`.`public_id`,
                `transaction`.`source_resource`) AS `ranked`
        WHERE `ranked`.`attribution_rank` <= %d
        ORDER BY `ranked`.`currency_id` ASC, `ranked`.`attribution_rank` ASC
        LIMIT %d]]):format(cutoff, ATTRIBUTION_LIMIT + 1,
        (CURRENCY_LIMIT + 1) * (ATTRIBUTION_LIMIT + 1)))
    for _, row in ipairs(resourceRows) do
        local values, valuesError = decimalFields(row, {
            { 'transaction_count' }, { 'volume_minor' },
        })
        if not values then return nil, valuesError end
        row.transaction_count, row.volume_minor = values.transaction_count, values.volume_minor
        local rank = tonumber(row.attribution_rank)
        if rank == nil or rank < 1 or rank > ATTRIBUTION_LIMIT + 1 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'An economy resource attribution rank is invalid.')
        end
        local currency = currenciesById[row.currency_id]
        if currency then
            if rank <= ATTRIBUTION_LIMIT then
                row.currency_id, row.attribution_rank = nil, nil
                currency.resources.items[#currency.resources.items + 1] = row
            else
                currency.resources.truncated = true
            end
        end
    end

    return {
        period = period.key,
        currencies = { items = currencies, truncated = currenciesTruncated },
    }, nil
end

function port:getOperationalMetrics()
    local row = one([[SELECT
            CAST((SELECT COUNT(*) FROM `synex_account_holds`
                WHERE `state` IN ('active', 'partially_captured')
                    AND `expires_at` > CURRENT_TIMESTAMP(6)) AS CHAR) AS `holds_active`,
            CAST((SELECT COUNT(*) FROM `synex_account_holds`
                WHERE `state` IN ('active', 'partially_captured')
                    AND `expires_at` <= CURRENT_TIMESTAMP(6)) AS CHAR) AS `holds_expired`,
            CAST((SELECT COUNT(*) FROM `synex_account_outbox`
                WHERE `state` = 'pending') AS CHAR) AS `outbox_pending`,
            CAST((SELECT COUNT(*) FROM `synex_account_outbox`
                WHERE `state` = 'publishing') AS CHAR) AS `outbox_publishing`,
            CAST((SELECT COUNT(*) FROM `synex_account_outbox`
                WHERE `state` = 'dead') AS CHAR) AS `outbox_dead`,
            CAST((SELECT COALESCE(SUM(`model`.`finding_count`), 0)
                FROM `synex_economy_integrity_read_models` AS `model`)
                AS CHAR) AS `reconciliation_findings`]]) or {}
    return decimalFields(row, {
        { 'holds_active' }, { 'holds_expired' }, { 'outbox_pending' },
        { 'outbox_publishing' }, { 'outbox_dead' }, { 'reconciliation_findings' },
    })
end

function port:doctorAccounts()
    local checks, status = {}, 'PASS'
    for _, definition in ipairs(doctorChecks) do
        local row = one(definition.sql)
        local count, countError = decimal(row and row.count, definition.key, false)
        if not count then return nil, countError end
        local numeric = tonumber(count)
        local truncated = numeric == nil or numeric > DOCTOR_LIMIT
        if truncated then count = tostring(DOCTOR_LIMIT) end
        local checkStatus = count == '0' and 'PASS' or definition.severity
        if checkStatus == 'FAIL' then status = 'FAIL'
        elseif checkStatus == 'WARN' and status == 'PASS' then status = 'WARN' end
        checks[#checks + 1] = {
            key = definition.key,
            status = checkStatus,
            count = count,
            truncated = truncated,
        }
    end
    return {
        service = 'synex.accounts',
        schema_version = 2,
        status = status,
        checks = checks,
        repair_performed = false,
    }, nil
end

local helpers = {
    INSPECT_LIMIT = INSPECT_LIMIT,
    SUMMARY_PAGE_LIMIT = SUMMARY_PAGE_LIMIT,
    FINDING_LIMIT = FINDING_LIMIT,
    CURRENCY_LIMIT = CURRENCY_LIMIT,
    economyPeriods = economyPeriods,
    decimal = decimal,
    timestamp = timestamp,
    bounded = bounded,
    decimalFields = decimalFields,
    readEconomyPeriod = readEconomyPeriod,
}
require('server.persistence.observability_control')(port, context, helpers)
require('server.persistence.observability_inspect')(port, context, helpers)
port.getControlSummaryV3 = port.getAccountsControlSummary

end
