return function(context)
local Foundation = context.foundation
local Domain = context.domain
local domainError = context.domainError
local txRows = context.txRows
local txOne = context.txOne
local jsonEncode = context.jsonEncode
local RESOURCE_LIMIT = 8

local behavioralSummarySql = [[SELECT
    CAST(CASE WHEN `activity`.`recent_transaction_count` >= 20
            AND `activity`.`baseline_transaction_count` >= 20
            AND `activity`.`recent_transaction_count` * 23
                >= `activity`.`baseline_transaction_count` * 4
        THEN 1 ELSE 0 END AS CHAR) AS `high_transaction_rate_count`,
    CAST(CASE WHEN `activity`.`reversal_transaction_count` >= 3
            AND `activity`.`total_volume_minor` > 0
            AND `activity`.`reversal_volume_minor` * 4
                >= `activity`.`total_volume_minor`
        THEN 1 ELSE 0 END AS CHAR) AS `large_reversal_volume_count`,
    CAST(CASE WHEN `activity`.`refund_transaction_count` >= 3
            AND `activity`.`total_volume_minor` > 0
            AND `activity`.`refund_volume_minor` * 4
                >= `activity`.`total_volume_minor`
        THEN 1 ELSE 0 END AS CHAR) AS `high_refund_ratio_count`,
    CAST(`activity`.`recent_transaction_count` AS CHAR) AS `recent_transaction_count`,
    CAST(`activity`.`baseline_transaction_count` AS CHAR) AS `baseline_transaction_count`,
    CAST(`activity`.`reversal_transaction_count` AS CHAR) AS `reversal_transaction_count`,
    CAST(`activity`.`refund_transaction_count` AS CHAR) AS `refund_transaction_count`,
    CAST(`activity`.`total_volume_minor` AS CHAR) AS `total_volume_minor`,
    CAST(`activity`.`reversal_volume_minor` AS CHAR) AS `reversal_volume_minor`,
    CAST(`activity`.`refund_volume_minor` AS CHAR) AS `refund_volume_minor`
FROM (SELECT
        COUNT(DISTINCT CASE WHEN `transaction`.`occurred_at`
            >= UTC_TIMESTAMP(6) - INTERVAL 1 HOUR THEN `transaction`.`id` END)
            AS `recent_transaction_count`,
        COUNT(DISTINCT CASE WHEN `transaction`.`occurred_at`
            < UTC_TIMESTAMP(6) - INTERVAL 1 HOUR THEN `transaction`.`id` END)
            AS `baseline_transaction_count`,
        COUNT(DISTINCT CASE WHEN `transaction`.`transaction_kind` = 'reversal'
            THEN `transaction`.`id` END) AS `reversal_transaction_count`,
        COUNT(DISTINCT CASE WHEN `transaction`.`transaction_kind` = 'refund'
            THEN `transaction`.`id` END) AS `refund_transaction_count`,
        COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
            THEN `entry`.`amount_minor` ELSE 0 END), 0) AS `total_volume_minor`,
        COALESCE(SUM(CASE WHEN `transaction`.`transaction_kind` = 'reversal'
                AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor` ELSE 0 END), 0)
            AS `reversal_volume_minor`,
        COALESCE(SUM(CASE WHEN `transaction`.`transaction_kind` = 'refund'
                AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor` ELSE 0 END), 0)
            AS `refund_volume_minor`
    FROM `synex_currencies` AS `currency`
    LEFT JOIN `synex_ledger_transactions` AS `transaction`
        ON `transaction`.`currency_id` = `currency`.`id`
        AND `transaction`.`status` = 'posted'
        AND `transaction`.`occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 24 HOUR
    LEFT JOIN `synex_ledger_entries` AS `entry`
        ON `entry`.`transaction_id` = `transaction`.`id`
    WHERE `currency`.`currency_code` = ?) AS `activity`]]

local largeMintSql = [[WITH `mint_activity` AS (
    SELECT `transaction`.`id`, `transaction`.`occurred_at`,
        SUM(CASE WHEN `account`.`account_role` = 'asset'
                AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor` ELSE 0 END)
            AS `amount_minor`
    FROM `synex_currencies` AS `currency`
    INNER JOIN `synex_ledger_transactions` AS `transaction`
        ON `transaction`.`currency_id` = `currency`.`id`
    INNER JOIN `synex_ledger_entries` AS `entry`
        ON `entry`.`transaction_id` = `transaction`.`id`
    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
    WHERE `currency`.`currency_code` = ? AND `transaction`.`status` = 'posted'
        AND `transaction`.`transaction_kind` = 'mint'
        AND `transaction`.`occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 30 DAY
    GROUP BY `transaction`.`id`, `transaction`.`occurred_at`
    HAVING SUM(CASE WHEN `account`.`account_role` = 'asset'
        AND `entry`.`amount_minor` > 0 THEN `entry`.`amount_minor` ELSE 0 END) > 0
), `baseline` AS (
    SELECT COUNT(*) AS `sample_count`, COALESCE(AVG(`amount_minor`), 0) AS `average_minor`
    FROM `mint_activity`
    WHERE `occurred_at` < UTC_TIMESTAMP(6) - INTERVAL 1 DAY
)
SELECT CAST(COUNT(*) AS CHAR) AS `large_mint_count`,
    CAST(COALESCE(MAX(`recent`.`amount_minor`), 0) AS CHAR) AS `maximum_minor`,
    CAST(COALESCE(MAX(`baseline`.`sample_count`), 0) AS CHAR) AS `baseline_sample_count`,
    CAST(COALESCE(FLOOR(MAX(`baseline`.`average_minor`)), 0) AS CHAR)
        AS `baseline_average_minor`
FROM `mint_activity` AS `recent`
CROSS JOIN `baseline`
WHERE `recent`.`occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 1 DAY
    AND `baseline`.`sample_count` >= 5
    AND `recent`.`amount_minor` >= `baseline`.`average_minor` * 10]]

local resourceSupplySpikeSql = [[WITH `supply_activity` AS (
    SELECT `transaction`.`id`, `transaction`.`source_resource`,
        `transaction`.`occurred_at`,
        SUM(CASE WHEN `transaction`.`transaction_kind` = 'mint'
                    AND `account`.`account_role` = 'asset' AND `entry`.`amount_minor` > 0
                THEN `entry`.`amount_minor`
                WHEN `transaction`.`transaction_kind` = 'burn'
                    AND `account`.`account_role` = 'asset' AND `entry`.`amount_minor` < 0
                THEN `entry`.`amount_minor` ELSE 0 END) AS `supply_delta_minor`
    FROM `synex_currencies` AS `currency`
    INNER JOIN `synex_ledger_transactions` AS `transaction`
        ON `transaction`.`currency_id` = `currency`.`id`
    INNER JOIN `synex_ledger_entries` AS `entry`
        ON `entry`.`transaction_id` = `transaction`.`id`
    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
    WHERE `currency`.`currency_code` = ? AND `transaction`.`status` = 'posted'
        AND `transaction`.`transaction_kind` IN ('mint', 'burn')
        AND `transaction`.`occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 24 HOUR
    GROUP BY `transaction`.`id`, `transaction`.`source_resource`, `transaction`.`occurred_at`
), `resource_activity` AS (
    SELECT `source_resource`,
        SUM(CASE WHEN `occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 1 HOUR
                AND `supply_delta_minor` > 0 THEN 1 ELSE 0 END) AS `recent_event_count`,
        SUM(CASE WHEN `occurred_at` < UTC_TIMESTAMP(6) - INTERVAL 1 HOUR
                AND `supply_delta_minor` > 0 THEN 1 ELSE 0 END) AS `baseline_event_count`,
        COALESCE(SUM(CASE WHEN `occurred_at` >= UTC_TIMESTAMP(6) - INTERVAL 1 HOUR
            THEN `supply_delta_minor` ELSE 0 END), 0) AS `recent_supply_minor`,
        COALESCE(SUM(CASE WHEN `occurred_at` < UTC_TIMESTAMP(6) - INTERVAL 1 HOUR
            THEN `supply_delta_minor` ELSE 0 END), 0) AS `baseline_supply_minor`
    FROM `supply_activity` GROUP BY `source_resource`
)
SELECT `source_resource`, CAST(`recent_event_count` AS CHAR) AS `recent_event_count`,
    CAST(`baseline_event_count` AS CHAR) AS `baseline_event_count`,
    CAST(`recent_supply_minor` AS CHAR) AS `recent_supply_minor`,
    CAST(`baseline_supply_minor` AS CHAR) AS `baseline_supply_minor`
FROM `resource_activity`
WHERE `recent_event_count` >= 3 AND `baseline_event_count` >= 5
    AND `recent_supply_minor` > 0 AND `baseline_supply_minor` > 0
    AND `recent_supply_minor` * 23 >= `baseline_supply_minor` * 4
ORDER BY `recent_supply_minor` DESC, `source_resource` ASC LIMIT 8]]

local function decimal(value)
    if value == nil then return '0' end
    local candidate = tostring(value)
    if candidate:match('^-?%d+$') == nil then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'An integrity aggregate is not an exact decimal integer.')
    end
    return candidate, nil
end

local function number(value)
    local candidate = tonumber(value)
    if not candidate or candidate ~= math.floor(candidate)
        or candidate < 0 or candidate > Foundation.MAX_MINOR then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'An integrity count is outside the supported range.')
    end
    return candidate, nil
end

local function appendFinding(report, rule, aggregateType, aggregateId, details)
    report.findings[#report.findings + 1] = {
        rule = rule,
        severity = 'warn',
        aggregate_type = aggregateType,
        aggregate_id = aggregateId,
        details_json = jsonEncode(details),
    }
    report.warn_count = report.warn_count + 1
    report.finding_count = #report.findings
    if report.status == 'healthy' then report.status = 'warn' end
end

return function(query, command, currency, report)
    local behavioral = txOne(query, behavioralSummarySql, { command.currencyCode })
    if not behavioral then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The behavioral economy summary is unavailable.')
    end
    local behavioralCounts = {}
    for _, field in ipairs({ 'high_transaction_rate_count',
        'large_reversal_volume_count', 'high_refund_ratio_count',
        'recent_transaction_count', 'baseline_transaction_count',
        'reversal_transaction_count', 'refund_transaction_count' }) do
        local value, valueError = number(behavioral[field])
        if value == nil then return nil, valueError end
        behavioralCounts[field] = value
    end
    for _, field in ipairs({ 'high_transaction_rate_count',
        'large_reversal_volume_count', 'high_refund_ratio_count' }) do
        if behavioralCounts[field] > 1 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'A behavioral economy rule returned an invalid decision.')
        end
    end
    local behavioralVolumes = {}
    for _, field in ipairs({ 'total_volume_minor', 'reversal_volume_minor',
        'refund_volume_minor' }) do
        local value, valueError = decimal(behavioral[field])
        if not value or value:sub(1, 1) == '-' then
            return nil, valueError or domainError('DATABASE_RESULT_INVALID',
                'A behavioral economy volume is invalid.')
        end
        behavioralVolumes[field] = value
    end
    if behavioralCounts.high_transaction_rate_count == 1 then
        appendFinding(report, 'economy.transaction_rate_spike', 'currency',
            currency.public_id, {
                recent_hours = 1,
                baseline_hours = 23,
                threshold_multiplier = 4,
                recent_transaction_count = tostring(
                    behavioralCounts.recent_transaction_count),
                baseline_transaction_count = tostring(
                    behavioralCounts.baseline_transaction_count),
            })
    end
    if behavioralCounts.large_reversal_volume_count == 1 then
        appendFinding(report, 'economy.large_reversal_volume', 'currency',
            currency.public_id, {
                window_hours = 24,
                threshold_percent = 25,
                transaction_count = tostring(
                    behavioralCounts.reversal_transaction_count),
                volume_minor = behavioralVolumes.reversal_volume_minor,
                total_volume_minor = behavioralVolumes.total_volume_minor,
            })
    end
    if behavioralCounts.high_refund_ratio_count == 1 then
        appendFinding(report, 'economy.high_refund_ratio', 'currency',
            currency.public_id, {
                window_hours = 24,
                threshold_percent = 25,
                transaction_count = tostring(
                    behavioralCounts.refund_transaction_count),
                volume_minor = behavioralVolumes.refund_volume_minor,
                total_volume_minor = behavioralVolumes.total_volume_minor,
            })
    end

    local largeMint = txOne(query, largeMintSql, { command.currencyCode })
    if not largeMint then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The large-mint economy summary is unavailable.')
    end
    local largeMintCount, largeMintCountError = number(largeMint.large_mint_count)
    if largeMintCount == nil then return nil, largeMintCountError end
    if largeMintCount > 0 then
        local maximumMinor, maximumError = decimal(largeMint.maximum_minor)
        if not maximumMinor or maximumMinor:sub(1, 1) == '-' then
            return nil, maximumError or domainError('DATABASE_RESULT_INVALID',
                'The large-mint maximum is invalid.')
        end
        local baselineSamples, samplesError = number(largeMint.baseline_sample_count)
        if baselineSamples == nil then return nil, samplesError end
        local baselineAverage, averageError = decimal(largeMint.baseline_average_minor)
        if not baselineAverage or baselineAverage:sub(1, 1) == '-' then
            return nil, averageError or domainError('DATABASE_RESULT_INVALID',
                'The large-mint baseline is invalid.')
        end
        appendFinding(report, 'economy.unusually_large_mint', 'currency',
            currency.public_id, {
                recent_hours = 24,
                baseline_days = 29,
                threshold_multiplier = 10,
                transaction_count = tostring(largeMintCount),
                maximum_minor = maximumMinor,
                baseline_sample_count = tostring(baselineSamples),
                baseline_average_minor = baselineAverage,
            })
    end

    local resourceSpikes = txRows(query, resourceSupplySpikeSql, {
        command.currencyCode
    })
    if #resourceSpikes > RESOURCE_LIMIT then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The resource supply-spike query exceeded its bounded result.')
    end
    for _, spike in ipairs(resourceSpikes) do
        if not Domain.validResourceName(spike.source_resource) then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'A resource supply-spike identifier is invalid.')
        end
        local recentEvents, recentEventsError = number(spike.recent_event_count)
        if recentEvents == nil then return nil, recentEventsError end
        local baselineEvents, baselineEventsError = number(spike.baseline_event_count)
        if baselineEvents == nil then return nil, baselineEventsError end
        local recentSupply, recentSupplyError = decimal(spike.recent_supply_minor)
        if not recentSupply or recentSupply:sub(1, 1) == '-' then
            return nil, recentSupplyError or domainError('DATABASE_RESULT_INVALID',
                'A recent resource supply aggregate is invalid.')
        end
        local baselineSupply, baselineSupplyError = decimal(spike.baseline_supply_minor)
        if not baselineSupply or baselineSupply:sub(1, 1) == '-' then
            return nil, baselineSupplyError or domainError('DATABASE_RESULT_INVALID',
                'A baseline resource supply aggregate is invalid.')
        end
        appendFinding(report, 'economy.resource_supply_spike', 'resource',
            spike.source_resource, {
                recent_hours = 1,
                baseline_hours = 23,
                threshold_multiplier = 4,
                recent_event_count = tostring(recentEvents),
                baseline_event_count = tostring(baselineEvents),
                recent_supply_minor = recentSupply,
                baseline_supply_minor = baselineSupply,
            })
    end
    table.sort(report.findings, function(left, right)
        if left.rule == right.rule then
            return tostring(left.aggregate_id) < tostring(right.aggregate_id)
        end
        return left.rule < right.rule
    end)
    return true, nil
end
end
