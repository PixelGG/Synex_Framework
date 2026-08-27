return function(port, context)
local one = context.one
local many = context.many
local legacyGetControlSummary = port.getControlSummary

function port:getControlSummaryV2()
    local overview = one([[SELECT
            (SELECT COUNT(*) FROM `synex_currencies`) AS `currencies`,
            (SELECT COUNT(*) FROM `synex_accounts`) AS `accounts`,
            (SELECT COUNT(*) FROM `synex_accounts` WHERE `status` = 'active') AS `active_accounts`,
            (SELECT COUNT(*) FROM `synex_accounts` WHERE `status` = 'frozen') AS `frozen_accounts`,
            (SELECT COUNT(*) FROM `synex_accounts` WHERE `status` = 'closed') AS `closed_accounts`,
            (SELECT COUNT(*) FROM `synex_ledger_transactions`
                WHERE `status` = 'posted') AS `transactions`,
            (SELECT COUNT(*) FROM `synex_ledger_entries`) AS `entries`,
            (SELECT COUNT(*) FROM `synex_account_holds`
                WHERE `state` IN ('active', 'partially_captured')
                    AND `expires_at` > CURRENT_TIMESTAMP(6)) AS `active_holds`,
            (SELECT COUNT(*) FROM `synex_account_holds`
                WHERE `state` IN ('active', 'partially_captured')
                    AND `expires_at` <= CURRENT_TIMESTAMP(6)) AS `expired_holds`,
            (SELECT COUNT(*) FROM `synex_account_access_grants`
                WHERE `status` = 'active' AND `active_marker` = 1
                    AND `valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6)))
                AS `active_grants`,
            (SELECT COUNT(*) FROM `synex_account_restrictions`
                WHERE `status` = 'active' AND `active_marker` = 1
                    AND `valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6)))
                AS `active_restrictions`,
            (SELECT COUNT(*) FROM `synex_economy_reconciliation_runs`) AS `reconciliations`,
            (SELECT COUNT(*) FROM `synex_economy_anomaly_findings` AS `finding`
                INNER JOIN `synex_economy_reconciliation_runs` AS `run`
                    ON `run`.`id` = `finding`.`run_id`
                WHERE `run`.`id` IN (SELECT MAX(`latest`.`id`)
                    FROM `synex_economy_reconciliation_runs` AS `latest`
                    GROUP BY `latest`.`currency_id`)) AS `current_anomalies`]]) or {}
    local currencyRows = many([[SELECT `currency`.`currency_code`, `currency`.`status`,
            `currency`.`precision_locked_at`, `topology`.`topology_state`,
            `model`.`model_version`, `model`.`status` AS `integrity_status`,
            `model`.`finding_count`, `model`.`generated_at`
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `currency`.`id`
        LEFT JOIN `synex_economy_integrity_read_models` AS `model`
            ON `model`.`currency_id` = `currency`.`id`
        ORDER BY `currency`.`currency_code` ASC LIMIT 100]])
    local currencies = {}
    for index, row in ipairs(currencyRows) do
        currencies[index] = {
            currency_code = row.currency_code,
            status = row.status,
            precision_locked_at = row.precision_locked_at
                and tostring(row.precision_locked_at) or nil,
            topology_state = row.topology_state,
            model_version = row.model_version and tonumber(row.model_version) or nil,
            integrity_status = row.integrity_status,
            finding_count = row.finding_count and tonumber(row.finding_count) or nil,
            generated_at = row.generated_at and tostring(row.generated_at) or nil,
        }
    end
    local outbox = one([[SELECT
            SUM(`state` = 'pending') AS `pending`, SUM(`state` = 'publishing') AS `publishing`,
            SUM(`state` = 'published') AS `published`, SUM(`state` = 'dead') AS `dead`,
            MIN(CASE WHEN `state` IN ('pending', 'publishing') THEN `created_at` END) AS `oldest_pending_at`
        FROM `synex_account_outbox`]]) or {}
    local operations = one([[SELECT
            SUM(`state` = 'pending') AS `pending`, SUM(`state` = 'completed') AS `completed`,
            SUM(`state` = 'failed') AS `failed`
        FROM `synex_account_operations`]]) or {}
    return {
        service = 'synex.accounts', schema_version = 2,
        overview = {
            currencies = tonumber(overview.currencies) or 0,
            accounts = tonumber(overview.accounts) or 0,
            active_accounts = tonumber(overview.active_accounts) or 0,
            frozen_accounts = tonumber(overview.frozen_accounts) or 0,
            closed_accounts = tonumber(overview.closed_accounts) or 0,
            transactions = tonumber(overview.transactions) or 0,
            entries = tonumber(overview.entries) or 0,
            active_holds = tonumber(overview.active_holds) or 0,
            expired_holds = tonumber(overview.expired_holds) or 0,
            active_grants = tonumber(overview.active_grants) or 0,
            active_restrictions = tonumber(overview.active_restrictions) or 0,
            reconciliations = tonumber(overview.reconciliations) or 0,
            current_anomalies = tonumber(overview.current_anomalies) or 0,
        },
        currencies = currencies,
        outbox = { pending = tonumber(outbox.pending) or 0,
            publishing = tonumber(outbox.publishing) or 0,
            published = tonumber(outbox.published) or 0,
            dead = tonumber(outbox.dead) or 0,
            oldest_pending_at = outbox.oldest_pending_at and tostring(outbox.oldest_pending_at) or nil },
        idempotency = { pending = tonumber(operations.pending) or 0,
            completed = tonumber(operations.completed) or 0,
            failed = tonumber(operations.failed) or 0 },
    }, nil
end

port.getControlSummaryLegacy = legacyGetControlSummary

end
