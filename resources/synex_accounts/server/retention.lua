return function(Foundation)
local domainError = Foundation.domainError

local function createFinancialRetention(deps)
    local update = assert(deps.update, 'financial retention requires update')
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

    function archive:archiveBatch()
        if policy.mode ~= 'archive' then
            return {
                scope = 'financial', mode = 'retain_forever', skipped = true,
                archived = 0, sourceRowsDeleted = 0
            }, nil
        end
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
            scope = 'financial', mode = 'archive', archiveAfterDays = policy.archiveAfterDays,
            batchSize = policy.batchSize, archived = archived, sourceRowsDeleted = 0,
            batchExhausted = archived >= policy.batchSize
        }, nil
    end

    return archive, nil
end

return createFinancialRetention
end
