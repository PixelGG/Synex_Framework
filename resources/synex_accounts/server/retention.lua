return function(Foundation)
local domainError = Foundation.domainError
local isCallable = Foundation.isCallable or function(value) return type(value) == 'function' end

local function affectedRows(result)
    if type(result) == 'number' and result == math.floor(result) and result >= 0 then
        return result
    end
    if type(result) == 'table' then
        local affected = tonumber(result.affectedRows)
        if affected and affected == math.floor(affected) and affected >= 0 then
            return affected
        end
    end
    return nil
end

local function createFinancialRetention(deps)
    local update = assert(deps.update, 'financial retention requires update')
    local withTransaction = deps.withTransaction
    local runtimeMysql = rawget(_G, 'MySQL')
    if not isCallable(withTransaction) and type(runtimeMysql) == 'table'
        and isCallable(runtimeMysql.startTransaction) then
        withTransaction = function(handler)
            local invoked, committed = pcall(runtimeMysql.startTransaction, handler)
            if not invoked or committed ~= true then
                return nil, domainError('RETENTION_DATABASE_ERROR',
                    'The financial archive transaction failed.', true)
            end
            return true, nil
        end
    end
    local policy = deps.policy
    if type(policy) ~= 'table'
        or (policy.mode ~= 'retain_forever' and policy.mode ~= 'archive')
        or type(policy.archiveAfterDays) ~= 'number'
        or math.type(policy.archiveAfterDays) ~= 'integer'
        or policy.archiveAfterDays < 1 or policy.archiveAfterDays > 36500
        or type(policy.batchSize) ~= 'number' or math.type(policy.batchSize) ~= 'integer'
        or policy.batchSize < 1 or policy.batchSize > 1000 then
        return nil, domainError('INVALID_RETENTION_POLICY', 'The financial retention policy is invalid.')
    end

    local archive = {}

    -- Compatibility path for pre-015 wiring. Production wiring supplies an
    -- interactive transaction and therefore uses the complete V2 archive.
    local function archiveLegacyPairBatch()
        local ok, archived = pcall(update, [[INSERT IGNORE INTO `synex_financial_transaction_archive`
            (`source_transaction_id`, `transaction_public_id`, `posting_public_id`,
                `operation_idempotency_key`, `operation_name`, `currency_code`, `currency_minor_unit`,
                `transaction_kind`, `reference_text`, `actor_ref`, `metadata_json`, `occurred_at`,
                `debit_account_public_id`, `credit_account_public_id`, `debit_minor`, `credit_minor`,
                `posting_created_at`, `archived_at`)
            SELECT `transaction`.`id`, `transaction`.`public_id`, `posting`.`public_id`,
                `operation`.`idempotency_key`, `operation`.`operation_name`, `currency`.`currency_code`,
                `currency`.`minor_unit`, `transaction`.`transaction_kind`, `transaction`.`reference_text`,
                `transaction`.`actor_ref`, `transaction`.`metadata_json`, `transaction`.`occurred_at`,
                `debit`.`public_id`, `credit`.`public_id`, `posting`.`debit_minor`, `posting`.`credit_minor`,
                `posting`.`created_at`, UTC_TIMESTAMP(6)
            FROM `synex_ledger_transactions` AS `transaction`
            INNER JOIN `synex_ledger_postings` AS `posting`
                ON `posting`.`transaction_id` = `transaction`.`id`
            INNER JOIN `synex_account_operations` AS `operation`
                ON `operation`.`id` = `transaction`.`operation_id`
            INNER JOIN `synex_currencies` AS `currency`
                ON `currency`.`id` = `transaction`.`currency_id`
            INNER JOIN `synex_accounts` AS `debit`
                ON `debit`.`id` = `posting`.`debit_account_id`
            INNER JOIN `synex_accounts` AS `credit`
                ON `credit`.`id` = `posting`.`credit_account_id`
            WHERE `transaction`.`occurred_at` < TIMESTAMPADD(DAY, -?, UTC_TIMESTAMP(6))
                AND NOT EXISTS (SELECT 1 FROM `synex_financial_transaction_archive` AS `archive`
                    WHERE `archive`.`source_transaction_id` = `transaction`.`id`)
            ORDER BY `transaction`.`id` ASC LIMIT ?]], {
            policy.archiveAfterDays, policy.batchSize
        })
        if not ok or type(archived) ~= 'number' or archived ~= math.floor(archived) or archived < 0 then
            return nil, domainError('RETENTION_DATABASE_ERROR', 'The financial archive batch failed.', true)
        end
        return {
            scope = 'financial', mode = 'archive', archiveVersion = 1,
            archiveAfterDays = policy.archiveAfterDays, batchSize = policy.batchSize,
            archived = archived, entriesArchived = archived * 2, sourceRowsDeleted = 0,
            batchExhausted = archived >= policy.batchSize
        }, nil
    end

    local function placeholders(count)
        local values = {}
        for index = 1, count do values[index] = '?' end
        return table.concat(values, ',')
    end

    local function archiveV2Batch()
        local report, retentionError
        local committed, transactionError = withTransaction(function(query)
            local function rows(sql, parameters)
                local value = query(sql, parameters or {})
                if type(value) ~= 'table' then
                    error('financial retention query returned an invalid result', 0)
                end
                return value
            end

            local candidates = rows([[SELECT `transaction`.`id`, `transaction`.`entry_count`
                FROM `synex_ledger_transactions` AS `transaction`
                INNER JOIN `synex_account_operations` AS `operation`
                    ON `operation`.`id` = `transaction`.`operation_id`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `transaction`.`currency_id`
                INNER JOIN `synex_ledger_entries` AS `entry`
                    ON `entry`.`transaction_id` = `transaction`.`id`
                INNER JOIN `synex_accounts` AS `account`
                    ON `account`.`id` = `entry`.`account_id`
                    AND `account`.`currency_id` = `transaction`.`currency_id`
                WHERE `transaction`.`status` = 'posted'
                    AND `transaction`.`posted_at` < TIMESTAMPADD(DAY, -?, UTC_TIMESTAMP(6))
                    AND NOT EXISTS (
                        SELECT 1 FROM `synex_financial_transaction_archive_v2` AS `archive`
                        WHERE `archive`.`source_transaction_id` = `transaction`.`id`)
                GROUP BY `transaction`.`id`, `transaction`.`entry_count`
                HAVING COUNT(`entry`.`id`) = `transaction`.`entry_count`
                    AND COUNT(`entry`.`id`) BETWEEN 2 AND 16
                    AND SUM(`entry`.`amount_minor`) = 0
                ORDER BY `transaction`.`id` ASC LIMIT ? FOR UPDATE]], {
                policy.archiveAfterDays, policy.batchSize
            })
            if #candidates == 0 then
                report = {
                    scope = 'financial', mode = 'archive', archiveVersion = 2,
                    archiveAfterDays = policy.archiveAfterDays, batchSize = policy.batchSize,
                    archived = 0, entriesArchived = 0, sourceRowsDeleted = 0,
                    batchExhausted = false
                }
                return true
            end

            local ids, expectedEntries = {}, 0
            for _, candidate in ipairs(candidates) do
                local id = tonumber(candidate.id)
                local entryCount = tonumber(candidate.entry_count)
                if not id or id ~= math.floor(id) or id < 1
                    or not entryCount or entryCount ~= math.floor(entryCount)
                    or entryCount < 2 or entryCount > 16 then
                    retentionError = domainError('RETENTION_SOURCE_INVALID',
                        'The financial archive source is invalid.')
                    return false
                end
                ids[#ids + 1] = id
                expectedEntries = expectedEntries + entryCount
            end
            local inClause = placeholders(#ids)
            local transactionParameters = {}
            for _, id in ipairs(ids) do transactionParameters[#transactionParameters + 1] = id end
            for _, id in ipairs(ids) do transactionParameters[#transactionParameters + 1] = id end

            local transactionInsert = rows(([[INSERT INTO `synex_financial_transaction_archive_v2`
                (`source_transaction_id`, `transaction_public_id`, `operation_idempotency_key`,
                    `operation_name`, `caller_resource`, `caller_principal_kind`,
                    `caller_principal_ref`, `currency_code`, `currency_minor_unit`,
                    `transaction_kind`, `posting_model`, `transaction_status`, `reason_code`,
                    `reference_type`, `reference_id`, `reference_text`, `actor_kind`, `actor_ref`,
                    `source_resource`, `trace_id`, `metadata_json`, `entry_count`,
                    `entry_sum_minor`, `source_schema_version`, `occurred_at`, `posted_at`,
                    `archived_at`)
                SELECT `transaction`.`id`, `transaction`.`public_id`,
                    `operation`.`idempotency_key`, `operation`.`operation_name`,
                    `operation`.`caller_resource`, `operation`.`caller_principal_kind`,
                    `operation`.`caller_principal_ref`, `currency`.`currency_code`,
                    `currency`.`minor_unit`, `transaction`.`transaction_kind`,
                    `transaction`.`posting_model`, `transaction`.`status`,
                    `transaction`.`reason_code`, `transaction`.`reference_type`,
                    `transaction`.`reference_id`, `transaction`.`reference_text`,
                    `transaction`.`actor_kind`, `transaction`.`actor_ref`,
                    `transaction`.`source_resource`,
                    COALESCE(`transaction`.`trace_id`, `operation`.`trace_id`),
                    `transaction`.`metadata_json`, `transaction`.`entry_count`,
                    `entry_sum`.`amount_minor`, 2, `transaction`.`occurred_at`,
                    `transaction`.`posted_at`, UTC_TIMESTAMP(6)
                FROM `synex_ledger_transactions` AS `transaction`
                INNER JOIN `synex_account_operations` AS `operation`
                    ON `operation`.`id` = `transaction`.`operation_id`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `transaction`.`currency_id`
                INNER JOIN (
                    SELECT `transaction_id`, SUM(`amount_minor`) AS `amount_minor`
                    FROM `synex_ledger_entries` WHERE `transaction_id` IN (%s)
                    GROUP BY `transaction_id`
                ) AS `entry_sum` ON `entry_sum`.`transaction_id` = `transaction`.`id`
                WHERE `transaction`.`id` IN (%s)
                ORDER BY `transaction`.`id` ASC]]):format(inClause, inClause), transactionParameters)
            if affectedRows(transactionInsert) ~= #ids then
                retentionError = domainError('RETENTION_ARCHIVE_INCOMPLETE',
                    'The financial transaction archive batch was incomplete.', true)
                return false
            end

            local entryInsert = rows(([[INSERT INTO `synex_financial_entry_archive_v2`
                (`archive_transaction_id`, `source_entry_id`, `entry_public_id`, `sequence_no`,
                    `account_public_id`, `account_role`, `amount_minor`, `metadata_json`,
                    `entry_created_at`, `archived_at`)
                SELECT `archive`.`id`, `entry`.`id`, `entry`.`public_id`, `entry`.`sequence_no`,
                    `account`.`public_id`, `account`.`account_role`, `entry`.`amount_minor`,
                    `entry`.`metadata_json`, `entry`.`created_at`, `archive`.`archived_at`
                FROM `synex_financial_transaction_archive_v2` AS `archive`
                INNER JOIN `synex_ledger_entries` AS `entry`
                    ON `entry`.`transaction_id` = `archive`.`source_transaction_id`
                INNER JOIN `synex_accounts` AS `account`
                    ON `account`.`id` = `entry`.`account_id`
                WHERE `archive`.`source_transaction_id` IN (%s)
                ORDER BY `archive`.`source_transaction_id` ASC, `entry`.`sequence_no` ASC]]):format(inClause), ids)
            if affectedRows(entryInsert) ~= expectedEntries then
                retentionError = domainError('RETENTION_ARCHIVE_INCOMPLETE',
                    'The financial entry archive batch was incomplete.', true)
                return false
            end

            local invalid = rows(([[SELECT `archive`.`source_transaction_id`
                FROM `synex_financial_transaction_archive_v2` AS `archive`
                LEFT JOIN `synex_financial_entry_archive_v2` AS `entry`
                    ON `entry`.`archive_transaction_id` = `archive`.`id`
                WHERE `archive`.`source_transaction_id` IN (%s)
                GROUP BY `archive`.`id`, `archive`.`source_transaction_id`,
                    `archive`.`entry_count`, `archive`.`entry_sum_minor`
                HAVING COUNT(`entry`.`id`) <> `archive`.`entry_count`
                    OR COALESCE(SUM(`entry`.`amount_minor`), 1) <> 0
                    OR `archive`.`entry_sum_minor` <> 0]]):format(inClause), ids)
            if #invalid ~= 0 then
                retentionError = domainError('RETENTION_ARCHIVE_INCOMPLETE',
                    'The financial archive verification failed.', true)
                return false
            end

            report = {
                scope = 'financial', mode = 'archive', archiveVersion = 2,
                archiveAfterDays = policy.archiveAfterDays, batchSize = policy.batchSize,
                archived = #ids, entriesArchived = expectedEntries, sourceRowsDeleted = 0,
                batchExhausted = #ids >= policy.batchSize
            }
            return true
        end)
        if committed then return report, nil end
        if retentionError then return nil, retentionError end
        return nil, transactionError or domainError('RETENTION_DATABASE_ERROR',
            'The financial archive batch failed.', true)
    end

    function archive:archiveBatch()
        if policy.mode ~= 'archive' then
            return {
                scope = 'financial', mode = 'retain_forever', archiveVersion = 2,
                skipped = true, archived = 0, entriesArchived = 0, sourceRowsDeleted = 0
            }, nil
        end
        if isCallable(withTransaction) then return archiveV2Batch() end
        return archiveLegacyPairBatch()
    end

    return archive, nil
end

return createFinancialRetention
end
