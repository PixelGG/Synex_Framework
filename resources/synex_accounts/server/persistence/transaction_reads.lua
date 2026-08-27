return function(port, context)
local Foundation = context.foundation
local domainError = context.domainError
local one = context.one
local many = context.many

local publicActorKinds = {
    system = true,
    resource = true,
    user = true,
    character = true,
    group = true,
}

local function publicTraceId(row)
    if type(row.trace_id) == 'string' and #row.trace_id >= 8 and #row.trace_id <= 64 then
        return row.trace_id
    end
    return 'legacy:' .. tostring(row.public_id)
end

local function publicActor(row)
    if publicActorKinds[row.actor_kind] and type(row.actor_ref) == 'string'
        and #row.actor_ref >= 2 and #row.actor_ref <= 128 then
        return row.actor_kind, row.actor_ref
    end
    if row.actor_kind == 'operator' and type(row.actor_ref) == 'string'
        and #row.actor_ref >= 2 and #row.actor_ref <= 128 then
        return 'user', row.actor_ref
    end
    return 'resource', 'synex_accounts'
end
local function hydrateTransaction(row)
    if not row then return nil end
    local entries = many([[SELECT `entry`.`public_id` AS `entry_id`, `account`.`public_id` AS `account_id`,
            `entry`.`sequence_no` AS `sequence`, `entry`.`amount_minor`, `entry`.`metadata_json`
        FROM `synex_ledger_entries` AS `entry`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
        WHERE `entry`.`transaction_id` = ? ORDER BY `entry`.`sequence_no` ASC LIMIT 16]], { row.id })
    local outputEntries = {}
    for index, entry in ipairs(entries) do
        outputEntries[index] = {
            entry_id = entry.entry_id,
            account_id = entry.account_id,
            sequence = tonumber(entry.sequence),
            amount_minor = tonumber(entry.amount_minor),
            metadata_json = entry.metadata_json,
        }
    end
    local actorKind, actorRef = publicActor(row)
    return {
        transaction_id = row.public_id,
        currency_code = row.currency_code,
        transaction_kind = row.transaction_kind,
        reason_code = row.reason_code,
        reference = row.reference_text,
        reference_type = row.reference_type,
        reference_id = row.reference_id,
        actor_kind = actorKind,
        actor_ref = actorRef,
        source_resource = row.source_resource,
        trace_id = publicTraceId(row),
        status = row.status,
        posted_at = tostring(row.posted_at or row.occurred_at),
        entry_count = tonumber(row.entry_count),
        entries = outputEntries,
    }
end

local function transactionMetadata(row)
    return {
        transaction_id = row.public_id,
        currency_code = row.currency_code,
        transaction_kind = row.transaction_kind,
        reason_code = row.reason_code,
        source_resource = row.source_resource,
        trace_id = publicTraceId(row),
        status = row.status,
        posted_at = tostring(row.posted_at or row.occurred_at),
        entry_count = tonumber(row.entry_count),
        reference_type = row.reference_type,
        reference_id = row.reference_id,
    }
end

function port:getTransaction(transactionId, authority, accountId)
    if not Foundation.isUuid(accountId) then
        return nil, domainError('VALIDATION_FAILED',
            'An account scope is required for transaction history access.')
    end
    local scopedAccount, accountError = self:getAccount(accountId, authority, 'history.read')
    if not scopedAccount then return nil, accountError end
    local row = one([[SELECT `transaction`.*, `currency`.`currency_code`
        FROM `synex_ledger_transactions` AS `transaction`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
        WHERE `transaction`.`public_id` = ?
            AND EXISTS (SELECT 1 FROM `synex_ledger_entries` AS `scope_entry`
                INNER JOIN `synex_accounts` AS `scope_account`
                    ON `scope_account`.`id` = `scope_entry`.`account_id`
                WHERE `scope_entry`.`transaction_id` = `transaction`.`id`
                    AND `scope_account`.`public_id` = ?)]], { transactionId, accountId })
    if not row then return nil, domainError('TRANSACTION_NOT_FOUND', 'The transaction does not exist.') end
    return hydrateTransaction(row), nil
end

function port:listTransactions(filter)
    if not Foundation.isUuid(filter.accountId) then
        return nil, domainError('VALIDATION_FAILED',
            'An account scope is required for transaction history access.')
    end
    local scopedAccount, accountError = self:getAccount(
        filter.accountId, filter.authority, 'history.read')
    if not scopedAccount then return nil, accountError end
    local limit = math.max(1, math.min(tonumber(filter.limit) or 50, 50))
    local cursor = tonumber(filter.cursor) or 9223372036854775807
    local conditions, values = { '`transaction`.`id` < ?' }, { cursor }
    if filter.currencyCode then
        conditions[#conditions + 1] = '`currency`.`currency_code` = ?'
        values[#values + 1] = filter.currencyCode
    end
    if filter.reasonCode then
        conditions[#conditions + 1] = '`transaction`.`reason_code` = ?'
        values[#values + 1] = filter.reasonCode
    end
    if filter.accountId then
        conditions[#conditions + 1] = [[EXISTS (SELECT 1 FROM `synex_ledger_entries` AS `filter_entry`
            INNER JOIN `synex_accounts` AS `filter_account` ON `filter_account`.`id` = `filter_entry`.`account_id`
            WHERE `filter_entry`.`transaction_id` = `transaction`.`id` AND `filter_account`.`public_id` = ?)]]
        values[#values + 1] = filter.accountId
    end
    values[#values + 1] = limit
    local rows = many(([[SELECT `transaction`.*, `currency`.`currency_code`
        FROM `synex_ledger_transactions` AS `transaction`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `transaction`.`currency_id`
        WHERE %s ORDER BY `transaction`.`id` DESC LIMIT ?]]):format(table.concat(conditions, ' AND ')), values)
    local items = {}
    for index, row in ipairs(rows) do items[index] = transactionMetadata(row) end
    return { items = items, next_cursor = #rows == limit and tostring(rows[#rows].id) or nil }, nil
end

end
