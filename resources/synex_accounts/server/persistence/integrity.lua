return function(port, context)
    local jsonEncode = context.jsonEncode
    local jsonDecode = context.jsonDecode
    local random = context.random
    local domainError = context.domainError
    local uuidV4 = context.uuidV4
    local one = context.one
    local many = context.many
    local replay = context.replay
    local execute = context.execute
    local withTransaction = context.withTransaction

function port:runReconciliation(command)
        local replayed, replayError = replay('run_reconciliation', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local stats = one([[SELECT `currency`.`id` AS `currency_id`, `currency`.`public_id` AS `currency_public_id`,
                `currency`.`currency_code`, `model`.`model_version`,
                (SELECT CAST(COALESCE(MAX(`posting`.`id`), 0) AS CHAR) FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction`
                        ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id`) AS `cutoff_posting_id`,
                (SELECT CAST(COUNT(*) AS CHAR) FROM `synex_ledger_transactions` AS `transaction`
                    WHERE `transaction`.`currency_id` = `currency`.`id`) AS `transaction_count`,
                (SELECT CAST(COUNT(*) AS CHAR) FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction`
                        ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id`) AS `posting_count`,
                (SELECT CAST(COALESCE(SUM(`posting`.`debit_minor`), 0) AS CHAR)
                    FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction`
                        ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id`) AS `total_debit_minor`,
                (SELECT CAST(COALESCE(SUM(`posting`.`credit_minor`), 0) AS CHAR)
                    FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction`
                        ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id`) AS `total_credit_minor`,
                (SELECT CAST(COALESCE(SUM(`snapshot`.`booked_minor`), 0) AS CHAR)
                    FROM `synex_account_balance_snapshots` AS `snapshot`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `snapshot`.`account_id`
                    WHERE `account`.`currency_id` = `currency`.`id`
                        AND NOT EXISTS (SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
                            WHERE `newer`.`account_id` = `snapshot`.`account_id`
                                AND `newer`.`sequence_no` > `snapshot`.`sequence_no`)) AS `total_booked_minor`,
                (SELECT CAST(COUNT(*) AS CHAR) FROM `synex_account_balance_snapshots` AS `snapshot`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `snapshot`.`account_id`
                    WHERE `account`.`currency_id` = `currency`.`id` AND `account`.`account_role` = 'asset'
                        AND `snapshot`.`booked_minor` < 0
                        AND NOT EXISTS (SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
                            WHERE `newer`.`account_id` = `snapshot`.`account_id`
                                AND `newer`.`sequence_no` > `snapshot`.`sequence_no`)) AS `negative_asset_count`,
                (SELECT CAST(COUNT(*) AS CHAR) FROM `synex_account_balance_snapshots` AS `snapshot`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `snapshot`.`account_id`
                    WHERE `account`.`currency_id` = `currency`.`id` AND `account`.`account_role` = 'asset'
                        AND `snapshot`.`reserved_minor` > `snapshot`.`booked_minor`
                        AND NOT EXISTS (SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
                            WHERE `newer`.`account_id` = `snapshot`.`account_id`
                                AND `newer`.`sequence_no` > `snapshot`.`sequence_no`)) AS `reserved_exceeds_booked_count`,
                (SELECT CAST(COUNT(*) AS CHAR) FROM `synex_ledger_transactions` AS `transaction`
                    WHERE `transaction`.`currency_id` = `currency`.`id`
                        AND NOT EXISTS (SELECT 1 FROM `synex_ledger_postings` AS `posting`
                            WHERE `posting`.`transaction_id` = `transaction`.`id`)) AS `orphan_transaction_count`
            FROM `synex_currencies` AS `currency`
            INNER JOIN `synex_economy_integrity_read_models` AS `model` ON `model`.`currency_id` = `currency`.`id`
            WHERE `currency`.`currency_code` = ?]], { command.currencyCode })
        if not stats then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        local findings = {}
        local function addFinding(rule, details)
            findings[#findings + 1] = {
                id = uuidV4(random), rule = rule, severity = 'warn', details_json = jsonEncode(details)
            }
        end
        if tostring(stats.total_debit_minor) ~= tostring(stats.total_credit_minor) then
            addFinding('ledger_imbalance', { debit = tostring(stats.total_debit_minor), credit = tostring(stats.total_credit_minor) })
        end
        if tostring(stats.total_booked_minor):match('^%-?0+$') == nil then
            addFinding('snapshot_sum_drift', { total_booked_minor = tostring(stats.total_booked_minor) })
        end
        if tostring(stats.negative_asset_count) ~= '0' then
            addFinding('negative_asset_balance', { count = tostring(stats.negative_asset_count) })
        end
        if tostring(stats.reserved_exceeds_booked_count) ~= '0' then
            addFinding('reserved_exceeds_booked', { count = tostring(stats.reserved_exceeds_booked_count) })
        end
        if tostring(stats.orphan_transaction_count) ~= '0' then
            addFinding('orphan_transaction', { count = tostring(stats.orphan_transaction_count) })
        end
        local runId = uuidV4(random)
        local eventId = uuidV4(random)
        local nextVersion = tonumber(stats.model_version) + 1
        local status = #findings > 0 and 'warn' or 'healthy'
        local responseFindings = {}
        for _, finding in ipairs(findings) do
            responseFindings[#responseFindings + 1] = { rule = finding.rule, severity = finding.severity }
        end
        local response = {
            run_id = runId, currency_id = stats.currency_public_id, currency_code = stats.currency_code,
            model_version = nextVersion, cutoff_posting_id = tostring(stats.cutoff_posting_id),
            transaction_count = tostring(stats.transaction_count), posting_count = tostring(stats.posting_count),
            total_debit_minor = tostring(stats.total_debit_minor), total_credit_minor = tostring(stats.total_credit_minor),
            total_booked_minor = tostring(stats.total_booked_minor), status = status,
            finding_count = #findings, findings = responseFindings
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_currencies` WHERE `id` = ? FOR UPDATE',
                values = { stats.currency_id }
            },
            {
                query = [[UPDATE `synex_economy_integrity_read_models`
                    SET `model_version` = `model_version` + 1, `cutoff_posting_id` = ?,
                        `transaction_count` = ?, `posting_count` = ?, `total_debit_minor` = ?,
                        `total_credit_minor` = ?, `total_booked_minor` = ?, `negative_asset_count` = ?,
                        `reserved_exceeds_booked_count` = ?, `orphan_transaction_count` = ?,
                        `finding_count` = ?, `status` = ?, `generated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `currency_id` = ? AND `model_version` = ?]],
                values = {
                    stats.cutoff_posting_id, stats.transaction_count, stats.posting_count,
                    stats.total_debit_minor, stats.total_credit_minor, stats.total_booked_minor,
                    stats.negative_asset_count, stats.reserved_exceeds_booked_count,
                    stats.orphan_transaction_count, #findings, status, stats.currency_id, stats.model_version
                }
            },
            {
                query = [[INSERT INTO `synex_economy_reconciliation_runs`
                    (`public_id`, `operation_id`, `currency_id`, `model_version`, `cutoff_posting_id`,
                        `transaction_count`, `posting_count`, `total_debit_minor`, `total_credit_minor`,
                        `total_booked_minor`, `finding_count`, `status`, `requested_by_ref`)
                    SELECT ?, `operation`.`id`, `model`.`currency_id`, `model`.`model_version`,
                        `model`.`cutoff_posting_id`, `model`.`transaction_count`, `model`.`posting_count`,
                        `model`.`total_debit_minor`, `model`.`total_credit_minor`, `model`.`total_booked_minor`,
                        `model`.`finding_count`, `model`.`status`, ?
                    FROM `synex_economy_integrity_read_models` AS `model`
                    INNER JOIN `synex_account_operations` AS `operation` ON `operation`.`idempotency_key` = ?
                    WHERE `model`.`currency_id` = ? AND `model`.`model_version` = ?]],
                values = { runId, command.actorRef, command.idempotencyKey, stats.currency_id, nextVersion }
            }
        }
        for _, finding in ipairs(findings) do
            statements[#statements + 1] = {
                query = [[INSERT INTO `synex_economy_anomaly_findings`
                    (`public_id`, `run_id`, `rule_key`, `severity`, `aggregate_type`, `aggregate_id`, `details_json`)
                    VALUES (?, (SELECT `id` FROM `synex_economy_reconciliation_runs` WHERE `public_id` = ?),
                        ?, 'warn', 'currency', ?, ?)]],
                values = { finding.id, runId, finding.rule, stats.currency_public_id, finding.details_json }
            }
        end
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.reconciliation_completed',
                    (SELECT `public_id` FROM `synex_economy_reconciliation_runs` WHERE `public_id` = ?), ?, ?)]],
            values = { eventId, command.idempotencyKey, runId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.reconciliation_completed', 1, ?)]],
            values = { eventId, stats.currency_public_id, snapshot }
        }
        return execute('run_reconciliation', command, response, statements)
    end

    function port:getIntegrity(currencyCode)
        local model = one([[SELECT `currency`.`public_id` AS `currency_public_id`, `currency`.`currency_code`,
                `model`.`model_version`, CAST(`model`.`cutoff_posting_id` AS CHAR) AS `cutoff_posting_id`,
                CAST(`model`.`transaction_count` AS CHAR) AS `transaction_count`,
                CAST(`model`.`posting_count` AS CHAR) AS `posting_count`,
                CAST(`model`.`total_debit_minor` AS CHAR) AS `total_debit_minor`,
                CAST(`model`.`total_credit_minor` AS CHAR) AS `total_credit_minor`,
                CAST(`model`.`total_booked_minor` AS CHAR) AS `total_booked_minor`,
                CAST(`model`.`negative_asset_count` AS CHAR) AS `negative_asset_count`,
                CAST(`model`.`reserved_exceeds_booked_count` AS CHAR) AS `reserved_exceeds_booked_count`,
                CAST(`model`.`orphan_transaction_count` AS CHAR) AS `orphan_transaction_count`,
                `model`.`finding_count`, `model`.`status`, `model`.`generated_at`
            FROM `synex_economy_integrity_read_models` AS `model`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `model`.`currency_id`
            WHERE `currency`.`currency_code` = ?]], { currencyCode })
        if not model then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        local findings = many([[SELECT `finding`.`public_id`, `finding`.`rule_key`, `finding`.`severity`,
                `finding`.`aggregate_type`, `finding`.`aggregate_id`, `finding`.`details_json`, `finding`.`created_at`
            FROM `synex_economy_anomaly_findings` AS `finding`
            INNER JOIN `synex_economy_reconciliation_runs` AS `run` ON `run`.`id` = `finding`.`run_id`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `run`.`currency_id`
            WHERE `currency`.`currency_code` = ? AND `run`.`model_version` = ?
            ORDER BY `finding`.`id` ASC LIMIT 16]], { currencyCode, model.model_version })
        local outputFindings = {}
        for _, finding in ipairs(findings) do
            outputFindings[#outputFindings + 1] = {
                finding_id = finding.public_id, rule = finding.rule_key, severity = finding.severity,
                aggregate_type = finding.aggregate_type, aggregate_id = finding.aggregate_id,
                details_json = finding.details_json, created_at = tostring(finding.created_at)
            }
        end
        return {
            currency_id = model.currency_public_id, currency_code = model.currency_code,
            model_version = tonumber(model.model_version), cutoff_posting_id = tostring(model.cutoff_posting_id),
            transaction_count = tostring(model.transaction_count), posting_count = tostring(model.posting_count),
            total_debit_minor = tostring(model.total_debit_minor), total_credit_minor = tostring(model.total_credit_minor),
            total_booked_minor = tostring(model.total_booked_minor),
            negative_asset_count = tostring(model.negative_asset_count),
            reserved_exceeds_booked_count = tostring(model.reserved_exceeds_booked_count),
            orphan_transaction_count = tostring(model.orphan_transaction_count),
            finding_count = tonumber(model.finding_count), status = model.status,
            generated_at = tostring(model.generated_at), findings = outputFindings
        }, nil
    end

    function port:getCharacterLifecycleSummary(characterId)
        local row = one([[SELECT
                (SELECT COUNT(*) FROM `synex_account_owners` AS `owner`
                    WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?) AS `account_count`,
                (SELECT COUNT(*) FROM `synex_account_owners` AS `owner`
                    INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `owner`.`account_id`
                    WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?
                        AND `account`.`status` <> 'closed') AS `open_account_count`,
                (SELECT COUNT(*) FROM `synex_account_holds` AS `hold`
                    INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `hold`.`account_id`
                    WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?
                        AND NOT EXISTS (SELECT 1 FROM `synex_account_hold_events` AS `terminal`
                            WHERE `terminal`.`hold_id` = `hold`.`id` AND `terminal`.`terminal_marker` = 1))
                    AS `nonterminal_hold_count`,
                (SELECT COUNT(DISTINCT `grant`.`id`) FROM `synex_account_access_grants` AS `grant`
                    LEFT JOIN `synex_account_owners` AS `grant_owner`
                        ON `grant_owner`.`account_id` = `grant`.`account_id`
                    WHERE `grant`.`status` = 'active' AND (
                        (`grant`.`principal_kind` = 'character' AND `grant`.`principal_ref` = ?)
                        OR (`grant_owner`.`owner_kind` = 'character' AND `grant_owner`.`owner_ref` = ?)
                    )) AS `active_grant_count`]],
            { characterId, characterId, characterId, characterId, characterId })
        return {
            accounts = tonumber(row and row.account_count) or 0,
            openAccounts = tonumber(row and row.open_account_count) or 0,
            nonterminalHolds = tonumber(row and row.nonterminal_hold_count) or 0,
            activeGrants = tonumber(row and row.active_grant_count) or 0,
        }, nil
    end

    function port:applyCharacterDeletion(planId, characterId, anonymousRef)
        local existing = one([[SELECT `anonymous_ref`, `account_count`, `grant_count`, `state`
            FROM `synex_account_character_deletions` WHERE `plan_id` = ?]], { planId })
        if existing and existing.state == 'completed' then
            return {
                anonymousRef = existing.anonymous_ref,
                accounts = tonumber(existing.account_count) or 0,
                grants = tonumber(existing.grant_count) or 0,
                state = 'completed',
            }, nil
        end

        local operationKey = uuidV4(random)
        local eventId = uuidV4(random)
        local result
        local domainFailure
        local committed, transactionError = withTransaction(function(query)
            local journal = query([[SELECT `anonymous_ref`, `account_count`, `grant_count`, `state`
                FROM `synex_account_character_deletions` WHERE `plan_id` = ? FOR UPDATE]], { planId })
            if journal and journal[1] and journal[1].state == 'completed' then
                result = {
                    anonymousRef = journal[1].anonymous_ref,
                    accounts = tonumber(journal[1].account_count) or 0,
                    grants = tonumber(journal[1].grant_count) or 0,
                    state = 'completed',
                }
                return true
            end
            if not journal or not journal[1] then
                query([[INSERT INTO `synex_account_character_deletions`
                    (`plan_id`, `anonymous_ref`, `state`) VALUES (?, ?, 'pending')]],
                    { planId, anonymousRef })
            elseif journal[1].anonymous_ref ~= anonymousRef then
                domainFailure = domainError('DELETE_PLAN_CONFLICT', 'The deletion plan was replayed with different metadata.')
                return false
            end

            local accounts = query([[SELECT `account`.`id` FROM `synex_accounts` AS `account`
                INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
                WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ? FOR UPDATE]],
                { characterId }) or {}
            local holds = query([[SELECT COUNT(*) AS `count` FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `hold`.`account_id`
                WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?
                    AND NOT EXISTS (SELECT 1 FROM `synex_account_hold_events` AS `terminal`
                        WHERE `terminal`.`hold_id` = `hold`.`id` AND `terminal`.`terminal_marker` = 1)]],
                { characterId }) or {}
            if tonumber(holds[1] and holds[1].count) ~= 0 then
                domainFailure = domainError('CHARACTER_ACCOUNTS_HAVE_HOLDS',
                    'Character accounts still have non-terminal holds.', true)
                return false
            end
            local grants = query([[SELECT COUNT(DISTINCT `grant`.`id`) AS `count`
                FROM `synex_account_access_grants` AS `grant`
                LEFT JOIN `synex_account_owners` AS `grant_owner`
                    ON `grant_owner`.`account_id` = `grant`.`account_id`
                WHERE `grant`.`status` = 'active' AND (
                    (`grant`.`principal_kind` = 'character' AND `grant`.`principal_ref` = ?)
                    OR (`grant_owner`.`owner_kind` = 'character' AND `grant_owner`.`owner_ref` = ?)
                ) FOR UPDATE]], { characterId, characterId }) or {}
            local accountCount = #accounts
            local grantCount = tonumber(grants[1] and grants[1].count) or 0
            local response = {
                anonymousRef = anonymousRef,
                accounts = accountCount,
                grants = grantCount,
                state = 'completed',
            }
            local responseJson = jsonEncode(response)

            query([[UPDATE `synex_account_access_grants` AS `grant`
                LEFT JOIN `synex_account_owners` AS `grant_owner`
                    ON `grant_owner`.`account_id` = `grant`.`account_id`
                SET `grant`.`principal_ref` = CASE
                        WHEN `grant`.`principal_kind` = 'character' AND `grant`.`principal_ref` = ?
                            THEN ? ELSE `grant`.`principal_ref` END,
                    `grant`.`granted_by_ref` = CASE WHEN `grant`.`granted_by_ref` = ?
                        THEN ? ELSE `grant`.`granted_by_ref` END,
                    `grant`.`revoked_by_ref` = CASE WHEN `grant`.`status` = 'active'
                        THEN 'resource:synex_accounts' WHEN `grant`.`revoked_by_ref` = ?
                        THEN ? ELSE `grant`.`revoked_by_ref` END,
                    `grant`.`revocation_reason` = CASE WHEN `grant`.`status` = 'active'
                        THEN 'character_deleted' ELSE `grant`.`revocation_reason` END,
                    `grant`.`revoked_at` = COALESCE(`grant`.`revoked_at`, CURRENT_TIMESTAMP(6)),
                    `grant`.`status` = 'revoked', `grant`.`active_marker` = NULL,
                    `grant`.`version` = `grant`.`version` + 1
                WHERE (`grant`.`principal_kind` = 'character' AND `grant`.`principal_ref` = ?)
                    OR `grant`.`granted_by_ref` = ? OR `grant`.`revoked_by_ref` = ?
                    OR (`grant`.`status` = 'active' AND `grant_owner`.`owner_kind` = 'character'
                        AND `grant_owner`.`owner_ref` = ?)]], {
                    characterId, anonymousRef, characterId, anonymousRef,
                    characterId, anonymousRef, characterId, characterId, characterId, characterId
                })
            query([[UPDATE `synex_accounts` AS `account`
                INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
                SET `account`.`status` = 'closed', `account`.`closed_at` = CURRENT_TIMESTAMP(6),
                    `account`.`metadata_json` = '{}', `account`.`version` = `account`.`version` + 1
                WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?
                    AND `account`.`status` <> 'closed']], { characterId })
            query([[UPDATE `synex_account_owners`
                SET `owner_ref` = ? WHERE `owner_kind` = 'character' AND `owner_ref` = ?]],
                { anonymousRef, characterId })
            query([[INSERT INTO `synex_account_operations`
                (`idempotency_key`, `operation_name`, `request_fingerprint`, `state`, `response_json`, `completed_at`)
                VALUES (?, 'character_delete', ?, 'completed', ?, CURRENT_TIMESTAMP(6))]],
                { operationKey, 'plan:' .. planId, responseJson })
            query([[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.character_anonymized', ?, 'resource:synex_accounts', ?)]],
                { eventId, operationKey, anonymousRef, responseJson })
            query([[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.character_anonymized', 1, ?)]],
                { eventId, anonymousRef, responseJson })
            query([[UPDATE `synex_account_character_deletions`
                SET `account_count` = ?, `grant_count` = ?, `state` = 'completed',
                    `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `plan_id` = ? AND `anonymous_ref` = ? AND `state` = 'pending']],
                { accountCount, grantCount, planId, anonymousRef })
            result = response
            return true
        end)
        if not committed then return nil, domainFailure or transactionError end
        return result, nil
    end

    function port:getControlSummary()
        local overview = one([[SELECT
                (SELECT COUNT(*) FROM `synex_currencies`) AS `currencies`,
                (SELECT COUNT(*) FROM `synex_accounts`) AS `accounts`,
                (SELECT COUNT(*) FROM `synex_accounts` WHERE `status` = 'active') AS `active_accounts`,
                (SELECT COUNT(*) FROM `synex_ledger_transactions`) AS `transactions`,
                (SELECT COUNT(*) FROM `synex_account_holds` AS `hold`
                    WHERE NOT EXISTS (SELECT 1 FROM `synex_account_hold_events` AS `terminal`
                        WHERE `terminal`.`hold_id` = `hold`.`id` AND `terminal`.`terminal_marker` = 1))
                    AS `nonterminal_holds`,
                (SELECT COUNT(*) FROM `synex_economy_anomaly_findings` AS `finding`
                    INNER JOIN `synex_economy_reconciliation_runs` AS `run` ON `run`.`id` = `finding`.`run_id`
                    WHERE `run`.`id` IN (SELECT MAX(`latest`.`id`) FROM `synex_economy_reconciliation_runs` AS `latest`
                        GROUP BY `latest`.`currency_id`)) AS `current_anomalies`]]) or {}
        local currencies = many([[SELECT `currency`.`currency_code`, `currency`.`minor_unit`,
                CAST(COALESCE(SUM(CASE WHEN `account`.`account_role` = 'asset' THEN `latest`.`booked_minor` ELSE 0 END), 0) AS CHAR)
                    AS `circulation_minor`,
                CAST(COALESCE((SELECT SUM(`posting`.`credit_minor`) FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id` AND `transaction`.`transaction_kind` = 'mint'), 0) AS CHAR)
                    AS `minted_minor`,
                CAST(COALESCE((SELECT SUM(`posting`.`debit_minor`) FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id` AND `transaction`.`transaction_kind` = 'burn'), 0) AS CHAR)
                    AS `burned_minor`,
                CAST(COALESCE((SELECT SUM(`posting`.`debit_minor`) FROM `synex_ledger_postings` AS `posting`
                    INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`id` = `posting`.`transaction_id`
                    WHERE `transaction`.`currency_id` = `currency`.`id`), 0) AS CHAR) AS `volume_minor`
            FROM `synex_currencies` AS `currency`
            LEFT JOIN `synex_accounts` AS `account` ON `account`.`currency_id` = `currency`.`id`
            LEFT JOIN `synex_account_balance_snapshots` AS `latest` ON `latest`.`account_id` = `account`.`id`
                AND NOT EXISTS (SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
                    WHERE `newer`.`account_id` = `latest`.`account_id` AND `newer`.`sequence_no` > `latest`.`sequence_no`)
            GROUP BY `currency`.`id`, `currency`.`currency_code`, `currency`.`minor_unit`
            ORDER BY `currency`.`currency_code` ASC LIMIT 32]])
        local byKind = many([[SELECT `currency`.`currency_code`, `transaction`.`transaction_kind` AS `kind`,
                COUNT(*) AS `transactions`, CAST(SUM(`posting`.`debit_minor`) AS CHAR) AS `volume_minor`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `transaction`.`id`
            GROUP BY `currency`.`currency_code`, `transaction`.`transaction_kind`
            ORDER BY SUM(`posting`.`debit_minor`) DESC LIMIT 32]])
        local bySource = many([[SELECT `currency`.`currency_code`,
                CASE WHEN `transaction`.`actor_ref` LIKE 'resource:%'
                    THEN SUBSTRING(`transaction`.`actor_ref`, 10) ELSE 'other' END AS `resource`,
                COUNT(*) AS `transactions`, CAST(SUM(`posting`.`debit_minor`) AS CHAR) AS `volume_minor`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `transaction`.`id`
            GROUP BY `currency`.`currency_code`, `resource`
            ORDER BY SUM(`posting`.`debit_minor`) DESC LIMIT 16]])
        local byReason = many([[SELECT `currency`.`currency_code`,
                COALESCE(NULLIF(LEFT(`transaction`.`reference_text`, 64), ''), 'unspecified') AS `reason`,
                COUNT(*) AS `transactions`, CAST(SUM(`posting`.`debit_minor`) AS CHAR) AS `volume_minor`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `transaction`.`id`
            GROUP BY `currency`.`currency_code`, `reason`
            ORDER BY SUM(`posting`.`debit_minor`) DESC LIMIT 16]])
        local byHour = many([[SELECT DATE_FORMAT(`transaction`.`occurred_at`, '%Y-%m-%dT%H:00:00Z') AS `hour_utc`,
                `currency`.`currency_code`, COUNT(*) AS `transactions`,
                CAST(SUM(`posting`.`debit_minor`) AS CHAR) AS `volume_minor`
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_ledger_postings` AS `posting` ON `posting`.`transaction_id` = `transaction`.`id`
            WHERE `transaction`.`occurred_at` >= CURRENT_TIMESTAMP(6) - INTERVAL 24 HOUR
            GROUP BY `hour_utc`, `currency`.`currency_code`
            ORDER BY `hour_utc` DESC, `currency`.`currency_code` ASC LIMIT 48]])
        local byAccountType = many([[SELECT `currency`.`currency_code`,
                CONCAT(`debit`.`account_role`, '->', `credit`.`account_role`) AS `account_type`,
                COUNT(*) AS `transactions`, CAST(SUM(`posting`.`debit_minor`) AS CHAR) AS `volume_minor`
            FROM `synex_ledger_postings` AS `posting`
            INNER JOIN `synex_ledger_transactions` AS `transaction` ON `transaction`.`id` = `posting`.`transaction_id`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_accounts` AS `debit` ON `debit`.`id` = `posting`.`debit_account_id`
            INNER JOIN `synex_accounts` AS `credit` ON `credit`.`id` = `posting`.`credit_account_id`
            GROUP BY `currency`.`currency_code`, `account_type`
            ORDER BY SUM(`posting`.`debit_minor`) DESC LIMIT 24]])
        local integrity = many([[SELECT `currency`.`currency_code`, `model`.`status`, `model`.`model_version`,
                `model`.`finding_count`, CAST(`model`.`negative_asset_count` AS CHAR) AS `negative_asset_count`,
                CAST(`model`.`reserved_exceeds_booked_count` AS CHAR) AS `reserved_exceeds_booked_count`,
                CAST(`model`.`orphan_transaction_count` AS CHAR) AS `orphan_transaction_count`,
                `model`.`generated_at`
            FROM `synex_economy_integrity_read_models` AS `model`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `model`.`currency_id`
            ORDER BY `currency`.`currency_code` ASC LIMIT 32]])
        local anomalies = many([[SELECT `finding`.`rule_key` AS `rule`, `finding`.`severity`,
                `currency`.`currency_code`, `finding`.`details_json`, `finding`.`created_at`
            FROM `synex_economy_anomaly_findings` AS `finding`
            INNER JOIN `synex_economy_reconciliation_runs` AS `run` ON `run`.`id` = `finding`.`run_id`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `run`.`currency_id`
            ORDER BY `finding`.`id` DESC LIMIT 16]])
        return {
            overview = {
                currencies = tonumber(overview.currencies) or 0,
                accounts = tonumber(overview.accounts) or 0,
                activeAccounts = tonumber(overview.active_accounts) or 0,
                transactions = tonumber(overview.transactions) or 0,
                nonterminalHolds = tonumber(overview.nonterminal_holds) or 0,
                currentAnomalies = tonumber(overview.current_anomalies) or 0,
            },
            currencies = currencies,
            ledger = {
                byKind = byKind,
                byResource = bySource,
                byReason = byReason,
                byHourUtc = byHour,
                byAccountType = byAccountType,
            },
            integrity = integrity,
            anomalies = anomalies,
        }, nil
    end
end
