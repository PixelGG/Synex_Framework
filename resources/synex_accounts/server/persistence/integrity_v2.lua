return function(port, context)
local Engine = context.engine
local Foundation = context.foundation
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local txRows = context.txRows
local txOne = context.txOne
local jsonEncode = context.jsonEncode
local evaluateBehavior = assert(context.integrityBehavior,
    'integrity V2 requires behavioral integrity composition')
local legacyGetIntegrity = port.getIntegrity
local legacyRunReconciliation = port.runReconciliation

local countFields = {
    transaction_sum_violation_count = 'ledger.transaction_sum',
    snapshot_drift_count = 'snapshot.balance_drift',
    negative_asset_count = 'account.negative_asset',
    reserved_exceeds_booked_count = 'hold.reserved_exceeds_booked',
    invalid_hold_count = 'hold.invalid_state',
    refund_limit_violation_count = 'refund.limit_violation',
    invalid_reversal_count = 'reversal.invalid_relationship',
    invalid_topology_count = 'currency.invalid_topology',
    outbox_problem_count = 'outbox.delivery_problem',
    grant_problem_count = 'access.invalid_grant',
    orphan_transaction_count = 'ledger.orphan_transaction',
    sequence_problem_count = 'ledger.sequence_problem',
    idempotency_problem_count = 'idempotency.invalid_receipt',
}

local severity = {
    transaction_sum_violation_count = 'critical',
    invalid_topology_count = 'critical',
    snapshot_drift_count = 'error',
    refund_limit_violation_count = 'error',
    invalid_reversal_count = 'error',
    orphan_transaction_count = 'error',
    idempotency_problem_count = 'error',
    negative_asset_count = 'warn',
    reserved_exceeds_booked_count = 'warn',
    invalid_hold_count = 'warn',
    outbox_problem_count = 'warn',
    grant_problem_count = 'warn',
    sequence_problem_count = 'warn',
}

local publicCountFields = {
    'cutoff_transaction_id', 'cutoff_entry_id', 'transaction_count', 'entry_count',
    'account_count', 'transaction_sum_violation_count', 'snapshot_drift_count',
    'negative_asset_count', 'reserved_exceeds_booked_count', 'invalid_hold_count',
    'refund_limit_violation_count',
    'invalid_reversal_count', 'invalid_topology_count', 'outbox_problem_count',
    'grant_problem_count', 'orphan_transaction_count', 'sequence_problem_count',
    'idempotency_problem_count', 'info_count', 'warn_count', 'error_count',
    'critical_count', 'finding_count',
}

local v2ReportFields = {
    'run_id', 'currency_id', 'currency_code', 'model_version',
    'cutoff_transaction_id', 'cutoff_entry_id', 'transaction_count', 'entry_count',
    'account_count', 'total_entry_sum_minor', 'minted_minor', 'burned_minor',
    'net_supply_minor', 'total_booked_minor', 'active_held_minor',
    'transaction_sum_violation_count', 'snapshot_drift_count',
    'negative_asset_count', 'reserved_exceeds_booked_count', 'invalid_hold_count',
    'refund_limit_violation_count',
    'invalid_reversal_count', 'invalid_topology_count', 'outbox_problem_count',
    'grant_problem_count', 'orphan_transaction_count', 'sequence_problem_count',
    'idempotency_problem_count',
    'info_count', 'warn_count', 'error_count', 'critical_count', 'finding_count',
    'status', 'generated_at', 'started_at', 'completed_at', 'findings',
}

local function publicReport(report)
    local output = {}
    for _, key in ipairs(v2ReportFields) do
        if report[key] ~= nil then output[key] = report[key] end
    end
    for _, key in ipairs(publicCountFields) do
        if output[key] ~= nil then output[key] = tostring(output[key]) end
    end
    return output
end

local summarySql = [[SELECT
    (SELECT COALESCE(MAX(`transaction`.`id`), 0)
        FROM `synex_ledger_transactions` AS `transaction`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `cutoff_transaction_id`,
    (SELECT COALESCE(MAX(`entry`.`id`), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `cutoff_entry_id`,
    (SELECT COUNT(*) FROM `synex_ledger_transactions` AS `transaction`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND `transaction`.`status` = 'posted') AS `transaction_count`,
    (SELECT COUNT(*) FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `entry_count`,
    (SELECT COUNT(*) FROM `synex_accounts` AS `account`
        WHERE `account`.`currency_id` = `currency`.`id`) AS `account_count`,
    (SELECT COALESCE(SUM(`entry`.`amount_minor`), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `total_entry_sum_minor`,
    (SELECT COALESCE(SUM(CASE WHEN `entry`.`amount_minor` < 0
            THEN -`entry`.`amount_minor` ELSE 0 END), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `total_debit_minor`,
    (SELECT COALESCE(SUM(CASE WHEN `entry`.`amount_minor` > 0
            THEN `entry`.`amount_minor` ELSE 0 END), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`) AS `total_credit_minor`,
    (SELECT COALESCE(SUM(`entry`.`amount_minor`), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND `transaction`.`transaction_kind` = 'mint'
            AND `account`.`account_role` = 'asset' AND `entry`.`amount_minor` > 0) AS `minted_minor`,
    (SELECT COALESCE(SUM(-`entry`.`amount_minor`), 0)
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `entry`.`transaction_id`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND `transaction`.`transaction_kind` = 'burn'
            AND `account`.`account_role` = 'asset' AND `entry`.`amount_minor` < 0) AS `burned_minor`,
    (SELECT COALESCE(SUM(`snapshot`.`booked_minor`), 0)
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`currency_id` = `currency`.`id`
            AND `account`.`account_role` = 'asset') AS `total_booked_minor`,
    (SELECT COALESCE(SUM(`hold`.`remaining_minor`), 0)
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`account_id`
        WHERE `account`.`currency_id` = `currency`.`id`
            AND `hold`.`state` IN ('active', 'partially_captured')
            AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)) AS `active_held_minor`,
    (SELECT COUNT(*) FROM `synex_ledger_transactions` AS `transaction`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND `transaction`.`status` = 'posted'
            AND ((SELECT COUNT(*) FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`transaction_id` = `transaction`.`id`)
                        <> `transaction`.`entry_count`
                OR (SELECT COUNT(*) FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`transaction_id` = `transaction`.`id`) < 2
                OR COALESCE((SELECT SUM(`entry`.`amount_minor`)
                    FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`transaction_id` = `transaction`.`id`), 0) <> 0))
        AS `transaction_sum_violation_count`,
    (SELECT COUNT(*)
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`currency_id` = `currency`.`id`
            AND `snapshot`.`booked_minor` <> COALESCE((SELECT SUM(`entry`.`amount_minor`)
                FROM `synex_ledger_entries` AS `entry`
                WHERE `entry`.`account_id` = `account`.`id`), 0)) AS `snapshot_drift_count`,
    (SELECT COUNT(*)
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`currency_id` = `currency`.`id`
            AND `account`.`account_role` = 'asset' AND `snapshot`.`booked_minor` < 0)
        AS `negative_asset_count`,
    (SELECT COUNT(*)
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`currency_id` = `currency`.`id`
            AND `account`.`account_role` = 'asset'
            AND COALESCE((SELECT SUM(`hold`.`remaining_minor`)
                FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0)
                > `snapshot`.`booked_minor`) AS `reserved_exceeds_booked_count`,
    (SELECT COUNT(*) FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`account_id`
        WHERE `account`.`currency_id` = `currency`.`id`
            AND (`hold`.`amount_minor` <> `hold`.`captured_minor`
                    + `hold`.`released_minor` + `hold`.`remaining_minor`
                OR (`hold`.`state` IN ('captured', 'released', 'expired')
                    AND `hold`.`remaining_minor` <> 0)
                OR (`account`.`status` = 'closed'
                    AND `hold`.`state` IN ('active', 'partially_captured'))))
        AS `invalid_hold_count`,
    (SELECT COUNT(*) FROM `synex_ledger_refund_anchors` AS `anchor`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`id` = `anchor`.`original_transaction_id`
        LEFT JOIN (SELECT `anchor_transaction_id`, SUM(`amount_minor`) AS `total`,
                MAX(`cumulative_refunded_minor`) AS `maximum_cumulative`
            FROM `synex_ledger_refunds` GROUP BY `anchor_transaction_id`) AS `refund`
            ON `refund`.`anchor_transaction_id` = `anchor`.`original_transaction_id`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND (`anchor`.`refunded_minor` > `anchor`.`refundable_minor`
                OR `anchor`.`refunded_minor` <> COALESCE(`refund`.`total`, 0)
                OR COALESCE(`refund`.`maximum_cumulative`, 0) > `anchor`.`refundable_minor`))
        AS `refund_limit_violation_count`,
    (SELECT COUNT(*) FROM `synex_ledger_reversals` AS `reversal`
        INNER JOIN `synex_ledger_transactions` AS `original`
            ON `original`.`id` = `reversal`.`original_transaction_id`
        INNER JOIN `synex_ledger_transactions` AS `inverse`
            ON `inverse`.`id` = `reversal`.`reversal_transaction_id`
        WHERE `original`.`currency_id` = `currency`.`id`
            AND (`original`.`currency_id` <> `inverse`.`currency_id`
                OR `original`.`id` = `inverse`.`id`
                OR `inverse`.`transaction_kind` <> 'reversal')) AS `invalid_reversal_count`,
    (SELECT COUNT(*) FROM `synex_currencies` AS `topology_currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `topology_currency`.`id`
        LEFT JOIN `synex_accounts` AS `mint` ON `mint`.`id` = `topology`.`mint_account_id`
        LEFT JOIN `synex_accounts` AS `burn` ON `burn`.`id` = `topology`.`burn_account_id`
        WHERE `topology_currency`.`id` = `currency`.`id`
            AND (`topology`.`currency_id` IS NULL
                OR (`topology`.`topology_state` = 'ready'
                AND (`mint`.`id` IS NULL OR `mint`.`currency_id` <> `currency`.`id`
                    OR `mint`.`account_role` <> 'mint' OR `mint`.`status` = 'closed'
                    OR `burn`.`id` IS NULL OR `burn`.`currency_id` <> `currency`.`id`
                    OR `burn`.`account_role` <> 'burn' OR `burn`.`status` = 'closed'
                    OR `mint`.`id` = `burn`.`id`
                    OR COALESCE((SELECT `snapshot`.`booked_minor`
                        FROM `synex_account_balance_snapshots` AS `snapshot`
                        WHERE `snapshot`.`account_id` = `mint`.`id`
                        ORDER BY `snapshot`.`sequence_no` DESC LIMIT 1), 0) > 0
                    OR COALESCE((SELECT `snapshot`.`booked_minor`
                        FROM `synex_account_balance_snapshots` AS `snapshot`
                        WHERE `snapshot`.`account_id` = `burn`.`id`
                        ORDER BY `snapshot`.`sequence_no` DESC LIMIT 1), 0) < 0
                    OR COALESCE((SELECT SUM(`snapshot`.`booked_minor`)
                        FROM `synex_accounts` AS `asset`
                        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
                            ON `snapshot`.`account_id` = `asset`.`id`
                            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                                FROM `synex_account_balance_snapshots` AS `latest`
                                WHERE `latest`.`account_id` = `asset`.`id`)
                        WHERE `asset`.`currency_id` = `currency`.`id`
                            AND `asset`.`account_role` = 'asset'), 0)
                        + COALESCE((SELECT `snapshot`.`booked_minor`
                            FROM `synex_account_balance_snapshots` AS `snapshot`
                            WHERE `snapshot`.`account_id` = `mint`.`id`
                            ORDER BY `snapshot`.`sequence_no` DESC LIMIT 1), 0)
                        + COALESCE((SELECT `snapshot`.`booked_minor`
                            FROM `synex_account_balance_snapshots` AS `snapshot`
                            WHERE `snapshot`.`account_id` = `burn`.`id`
                             ORDER BY `snapshot`.`sequence_no` DESC LIMIT 1), 0) <> 0))))
        AS `invalid_topology_count`,
    (SELECT COUNT(*) FROM `synex_account_outbox` AS `outbox`
        WHERE `outbox`.`state` = 'dead') AS `outbox_problem_count`,
    (SELECT COUNT(*) FROM `synex_account_access_grants` AS `grant`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `grant`.`account_id`
        WHERE `account`.`currency_id` = `currency`.`id`
            AND ((`grant`.`status` = 'active' AND `grant`.`active_marker` <> 1)
                OR (`grant`.`status` <> 'active' AND `grant`.`active_marker` IS NOT NULL)
                OR (`grant`.`valid_until` IS NOT NULL
                    AND `grant`.`valid_until` <= `grant`.`valid_from`))) AS `grant_problem_count`,
    (SELECT COUNT(*) FROM `synex_ledger_transactions` AS `transaction`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND NOT EXISTS (SELECT 1 FROM `synex_ledger_entries` AS `entry`
                WHERE `entry`.`transaction_id` = `transaction`.`id`)) AS `orphan_transaction_count`,
    (SELECT COUNT(*) FROM `synex_ledger_transactions` AS `transaction`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND ((SELECT COALESCE(MIN(`entry`.`sequence_no`), 0)
                    FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`transaction_id` = `transaction`.`id`) <> 1
                OR (SELECT COALESCE(MAX(`entry`.`sequence_no`), 0)
                    FROM `synex_ledger_entries` AS `entry`
                    WHERE `entry`.`transaction_id` = `transaction`.`id`)
                    <> (SELECT COUNT(*) FROM `synex_ledger_entries` AS `entry`
                        WHERE `entry`.`transaction_id` = `transaction`.`id`)))
        AS `sequence_problem_count`,
    (SELECT COUNT(*) FROM `synex_account_operations` AS `operation`
        INNER JOIN `synex_ledger_transactions` AS `transaction`
            ON `transaction`.`operation_id` = `operation`.`id`
        WHERE `transaction`.`currency_id` = `currency`.`id`
            AND (`operation`.`state` <> 'completed' OR `operation`.`response_json` IS NULL))
        AS `idempotency_problem_count`
FROM `synex_currencies` AS `currency`
WHERE `currency`.`currency_code` = ?]]

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

local function subtractUnsigned(left, right)
    left = tostring(left):gsub('^0+', '')
    right = tostring(right):gsub('^0+', '')
    if left == '' then left = '0' end
    if right == '' then right = '0' end
    local negative = #left < #right or (#left == #right and left < right)
    if negative then left, right = right, left end
    local result, borrow, leftIndex, rightIndex = {}, 0, #left, #right
    while leftIndex > 0 do
        local digit = tonumber(left:sub(leftIndex, leftIndex)) - borrow
        local other = rightIndex > 0 and tonumber(right:sub(rightIndex, rightIndex)) or 0
        if digit < other then digit, borrow = digit + 10, 1 else borrow = 0 end
        result[#result + 1] = tostring(digit - other)
        leftIndex, rightIndex = leftIndex - 1, rightIndex - 1
    end
    while #result > 1 and result[#result] == '0' do result[#result] = nil end
    local output = {}
    for index = #result, 1, -1 do output[#output + 1] = result[index] end
    local value = table.concat(output)
    return negative and value ~= '0' and '-' .. value or value
end

local function normalize(row, currency)
    if not row then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
    local output = { currency_id = currency.public_id, currency_code = currency.currency_code }
    for _, key in ipairs({ 'cutoff_transaction_id', 'cutoff_entry_id', 'transaction_count',
        'entry_count', 'account_count', 'transaction_sum_violation_count',
        'snapshot_drift_count', 'negative_asset_count', 'reserved_exceeds_booked_count',
        'invalid_hold_count',
        'refund_limit_violation_count', 'invalid_reversal_count', 'invalid_topology_count',
        'outbox_problem_count', 'grant_problem_count', 'orphan_transaction_count',
        'sequence_problem_count', 'idempotency_problem_count' }) do
        output[key] = select(1, number(row[key]))
        if output[key] == nil then return nil, select(2, number(row[key])) end
    end
    for _, key in ipairs({ 'total_entry_sum_minor', 'total_debit_minor', 'total_credit_minor',
        'minted_minor', 'burned_minor',
        'total_booked_minor', 'active_held_minor' }) do
        output[key] = select(1, decimal(row[key]))
        if output[key] == nil then return nil, select(2, decimal(row[key])) end
    end
    output.net_supply_minor = subtractUnsigned(
        output.minted_minor, output.burned_minor)
    if not output.net_supply_minor or output.net_supply_minor:match('^-?%d+$') == nil then
        return nil, domainError('DATABASE_RESULT_INVALID', 'The supply aggregate is invalid.')
    end
    output.posting_count = output.entry_count
    output.cutoff_posting_id = output.cutoff_entry_id
    local counts = { info = 0, warn = 0, error = 0, critical = 0 }
    output.findings = {}
    for field, rule in pairs(countFields) do
        if output[field] > 0 then
            local level = severity[field]
            counts[level] = counts[level] + 1
            output.findings[#output.findings + 1] = {
                rule = rule, severity = level, aggregate_type = 'currency',
                aggregate_id = currency.public_id,
                details_json = jsonEncode({ count = output[field] }),
            }
        end
    end
    table.sort(output.findings, function(left, right) return left.rule < right.rule end)
    output.info_count, output.warn_count = counts.info, counts.warn
    output.error_count, output.critical_count = counts.error, counts.critical
    output.finding_count = #output.findings
    output.status = counts.critical > 0 and 'critical'
        or counts.error > 0 and 'error' or counts.warn > 0 and 'warn' or 'healthy'
    return output, nil
end

function port:runReconciliationV2(command)
    local runId = uuidV4(random)
    return Engine:mutation('integrity_reconcile', command, function(query, operationId)
        local currency = txOne(query, [[SELECT `id`, `public_id`, `currency_code`
            FROM `synex_currencies` WHERE `currency_code` = ? FOR UPDATE]], {
            command.currencyCode
        })
        if not currency then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        local summary = txOne(query, summarySql, { command.currencyCode })
        local report, reportError = normalize(summary, currency)
        if not report then return nil, reportError end

        local behaviorApplied, behaviorError = evaluateBehavior(
            query, command, currency, report)
        if not behaviorApplied then return nil, behaviorError end
        local model = txOne(query, [[SELECT `model_version`
            FROM `synex_economy_integrity_read_models`
            WHERE `currency_id` = ? FOR UPDATE]], { currency.id })
        local version = tonumber(model and model.model_version) or 0
        report.model_version = version + 1
        report.run_id = runId
        report.generated_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
        txRows(query, [[INSERT INTO `synex_economy_reconciliation_runs`
            (`public_id`, `operation_id`, `currency_id`, `model_version`, `cutoff_posting_id`,
                `cutoff_transaction_id`, `cutoff_entry_id`, `transaction_count`, `posting_count`,
                `entry_count`, `account_count`, `total_debit_minor`, `total_credit_minor`,
                `total_entry_sum_minor`, `minted_minor`, `burned_minor`, `net_supply_minor`,
                `total_booked_minor`, `active_held_minor`, `transaction_sum_violation_count`,
                `snapshot_drift_count`, `invalid_hold_count`, `refund_limit_violation_count`,
                `invalid_reversal_count`, `invalid_topology_count`, `outbox_problem_count`,
                `grant_problem_count`, `sequence_problem_count`, `idempotency_problem_count`,
                `info_count`, `warn_count`, `error_count`, `critical_count`, `finding_count`,
                `status`, `requested_by_ref`, `source_resource`, `trace_id`, `actor_kind`,
                `summary_json`, `started_at`, `completed_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))]], {
            runId, operationId, currency.id, report.model_version, report.cutoff_entry_id,
            report.cutoff_transaction_id, report.cutoff_entry_id, report.transaction_count,
            report.entry_count, report.entry_count, report.account_count,
            report.total_debit_minor, report.total_credit_minor,
            report.total_entry_sum_minor, report.minted_minor, report.burned_minor,
            report.net_supply_minor, report.total_booked_minor, report.active_held_minor,
            report.transaction_sum_violation_count, report.snapshot_drift_count,
            report.invalid_hold_count, report.refund_limit_violation_count,
            report.invalid_reversal_count, report.invalid_topology_count,
            report.outbox_problem_count, report.grant_problem_count,
            report.sequence_problem_count, report.idempotency_problem_count,
            report.info_count, report.warn_count, report.error_count,
            report.critical_count, report.finding_count, report.status,
            command.authority.principalRef, command.authority.callerResource,
            command.authority.traceId, command.authority.principalKind,
            jsonEncode(report)
        })
        local run = txOne(query, [[SELECT `id` FROM `synex_economy_reconciliation_runs`
            WHERE `public_id` = ? FOR UPDATE]], { runId })
        for _, finding in ipairs(report.findings) do
            local findingId = uuidV4(random)
            txRows(query, [[INSERT INTO `synex_economy_anomaly_findings`
                (`public_id`, `run_id`, `rule_key`, `severity`, `aggregate_type`,
                    `aggregate_id`, `details_json`)
                VALUES (?, ?, ?, ?, ?, ?, ?)]], {
                findingId, run.id, finding.rule, finding.severity,
                finding.aggregate_type, finding.aggregate_id, finding.details_json
            })
            finding.finding_id = findingId
            finding.created_at = report.generated_at
            local _, findingEventError = Engine:writeEvent(query, operationId,
                'synex.accounts.integrity.finding', findingId, command, {
                    finding_id = finding.finding_id,
                    run_id = runId,
                    currency_id = report.currency_id,
                    currency_code = report.currency_code,
                    model_version = report.model_version,
                    rule = finding.rule,
                    severity = finding.severity,
                    aggregate_type = finding.aggregate_type,
                    aggregate_id = finding.aggregate_id,
                    details_json = finding.details_json,
                    created_at = finding.created_at,
                })
            if findingEventError then return nil, findingEventError end
        end
        txRows(query, [[INSERT INTO `synex_economy_integrity_read_models`
            (`currency_id`, `model_version`, `cutoff_posting_id`, `cutoff_transaction_id`,
                `cutoff_entry_id`, `transaction_count`, `posting_count`, `entry_count`,
                `account_count`, `total_debit_minor`, `total_credit_minor`, `total_entry_sum_minor`,
                `minted_minor`, `burned_minor`, `net_supply_minor`, `total_booked_minor`,
                `active_held_minor`, `negative_asset_count`, `reserved_exceeds_booked_count`,
                `orphan_transaction_count`, `transaction_sum_violation_count`,
                `snapshot_drift_count`, `invalid_hold_count`, `refund_limit_violation_count`,
                `invalid_reversal_count`, `invalid_topology_count`, `outbox_problem_count`,
                `grant_problem_count`, `sequence_problem_count`, `idempotency_problem_count`,
                `info_count`, `warn_count`, `error_count`, `critical_count`, `finding_count`,
                `status`, `generated_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP(6))
            ON DUPLICATE KEY UPDATE `model_version` = VALUES(`model_version`),
                `cutoff_posting_id` = VALUES(`cutoff_posting_id`),
                `cutoff_transaction_id` = VALUES(`cutoff_transaction_id`),
                `cutoff_entry_id` = VALUES(`cutoff_entry_id`),
                `transaction_count` = VALUES(`transaction_count`),
                `posting_count` = VALUES(`posting_count`), `entry_count` = VALUES(`entry_count`),
                `account_count` = VALUES(`account_count`),
                `total_debit_minor` = VALUES(`total_debit_minor`),
                `total_credit_minor` = VALUES(`total_credit_minor`),
                `total_entry_sum_minor` = VALUES(`total_entry_sum_minor`),
                `minted_minor` = VALUES(`minted_minor`), `burned_minor` = VALUES(`burned_minor`),
                `net_supply_minor` = VALUES(`net_supply_minor`),
                `total_booked_minor` = VALUES(`total_booked_minor`),
                `active_held_minor` = VALUES(`active_held_minor`),
                `negative_asset_count` = VALUES(`negative_asset_count`),
                `reserved_exceeds_booked_count` = VALUES(`reserved_exceeds_booked_count`),
                `orphan_transaction_count` = VALUES(`orphan_transaction_count`),
                `transaction_sum_violation_count` = VALUES(`transaction_sum_violation_count`),
                `snapshot_drift_count` = VALUES(`snapshot_drift_count`),
                `invalid_hold_count` = VALUES(`invalid_hold_count`),
                `refund_limit_violation_count` = VALUES(`refund_limit_violation_count`),
                `invalid_reversal_count` = VALUES(`invalid_reversal_count`),
                `invalid_topology_count` = VALUES(`invalid_topology_count`),
                `outbox_problem_count` = VALUES(`outbox_problem_count`),
                `grant_problem_count` = VALUES(`grant_problem_count`),
                `sequence_problem_count` = VALUES(`sequence_problem_count`),
                `idempotency_problem_count` = VALUES(`idempotency_problem_count`),
                `info_count` = VALUES(`info_count`), `warn_count` = VALUES(`warn_count`),
                `error_count` = VALUES(`error_count`), `critical_count` = VALUES(`critical_count`),
                `finding_count` = VALUES(`finding_count`), `status` = VALUES(`status`),
                `generated_at` = VALUES(`generated_at`)]], {
            currency.id, report.model_version, report.cutoff_entry_id,
            report.cutoff_transaction_id, report.cutoff_entry_id,
            report.transaction_count, report.entry_count, report.entry_count,
            report.account_count, report.total_debit_minor, report.total_credit_minor,
            report.total_entry_sum_minor, report.minted_minor,
            report.burned_minor, report.net_supply_minor, report.total_booked_minor,
            report.active_held_minor, report.negative_asset_count,
            report.reserved_exceeds_booked_count,
            report.orphan_transaction_count, report.transaction_sum_violation_count,
            report.snapshot_drift_count, report.invalid_hold_count,
            report.refund_limit_violation_count, report.invalid_reversal_count,
            report.invalid_topology_count, report.outbox_problem_count,
            report.grant_problem_count, report.sequence_problem_count,
            report.idempotency_problem_count, report.info_count, report.warn_count,
            report.error_count, report.critical_count, report.finding_count, report.status
        })
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.reconciliation.completed', runId, command, report)
        if eventError then return nil, eventError end
        return publicReport(report), nil
    end)
end

local function readIntegrityReport(currencyCode)
    local currency = one([[SELECT `id`, `public_id`, `currency_code`
        FROM `synex_currencies` WHERE `currency_code` = ?]], { currencyCode })
    if not currency then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
    local row = one([[SELECT * FROM `synex_economy_integrity_read_models`
        WHERE `currency_id` = ?]], { currency.id })
    if not row then return nil, domainError('INTEGRITY_MODEL_NOT_FOUND',
        'No reconciliation model exists for this currency.') end
    local report = {
        currency_id = currency.public_id, currency_code = currency.currency_code,
        model_version = tonumber(row.model_version),
        cutoff_transaction_id = tostring(row.cutoff_transaction_id),
        cutoff_entry_id = tostring(row.cutoff_entry_id),
        transaction_count = tostring(row.transaction_count),
        entry_count = tostring(row.entry_count), account_count = tostring(row.account_count),
        total_entry_sum_minor = tostring(row.total_entry_sum_minor),
        total_debit_minor = tostring(row.total_debit_minor),
        total_credit_minor = tostring(row.total_credit_minor),
        minted_minor = tostring(row.minted_minor), burned_minor = tostring(row.burned_minor),
        net_supply_minor = tostring(row.net_supply_minor),
        total_booked_minor = tostring(row.total_booked_minor),
        active_held_minor = tostring(row.active_held_minor),
        transaction_sum_violation_count = tostring(row.transaction_sum_violation_count),
        snapshot_drift_count = tostring(row.snapshot_drift_count),
        negative_asset_count = tostring(row.negative_asset_count),
        reserved_exceeds_booked_count = tostring(row.reserved_exceeds_booked_count),
        invalid_hold_count = tostring(row.invalid_hold_count),
        refund_limit_violation_count = tostring(row.refund_limit_violation_count),
        invalid_reversal_count = tostring(row.invalid_reversal_count),
        invalid_topology_count = tostring(row.invalid_topology_count),
        outbox_problem_count = tostring(row.outbox_problem_count),
        grant_problem_count = tostring(row.grant_problem_count),
        orphan_transaction_count = tostring(row.orphan_transaction_count),
        sequence_problem_count = tostring(row.sequence_problem_count),
        idempotency_problem_count = tostring(row.idempotency_problem_count),
        info_count = tostring(row.info_count), warn_count = tostring(row.warn_count),
        error_count = tostring(row.error_count), critical_count = tostring(row.critical_count),
        finding_count = tostring(row.finding_count), status = row.status,
        generated_at = tostring(row.generated_at), findings = {},
    }
    local findings = many([[SELECT `finding`.`public_id` AS `finding_id`, `finding`.`rule_key` AS `rule`,
            `finding`.`severity`, `finding`.`aggregate_type`, `finding`.`aggregate_id`,
            `finding`.`details_json`, `finding`.`created_at`
        FROM `synex_economy_anomaly_findings` AS `finding`
        INNER JOIN `synex_economy_reconciliation_runs` AS `run`
            ON `run`.`id` = `finding`.`run_id`
        WHERE `run`.`currency_id` = ? AND `run`.`model_version` = ?
        ORDER BY `finding`.`severity` DESC, `finding`.`rule_key` ASC LIMIT 64]], {
        currency.id, report.model_version
    })
    for index, finding in ipairs(findings) do
        report.findings[index] = {
            finding_id = finding.finding_id, rule = finding.rule,
            severity = finding.severity, aggregate_type = finding.aggregate_type,
            aggregate_id = finding.aggregate_id, details_json = finding.details_json,
            created_at = tostring(finding.created_at),
        }
    end
    return report, nil
end

function port:getIntegrityInternal(currencyCode)
    return readIntegrityReport(currencyCode)
end

function port:getIntegrityV2(currencyCode)
    local report, reportError = readIntegrityReport(currencyCode)
    if not report then return nil, reportError end
    return publicReport(report), nil
end

port.getIntegrityLegacy = legacyGetIntegrity
port.runReconciliationLegacy = legacyRunReconciliation

end
