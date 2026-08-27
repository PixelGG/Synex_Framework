return function(port, context)
local Foundation = context.foundation
local Domain = context.domain
local Engine = context.engine
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local txRows = context.txRows
local txOne = context.txOne

local nonReversibleKinds = {
    burn = true,
    hold_capture = true,
    mint = true,
    refund = true,
    reversal = true,
}

local function publicEntries(entries)
    local result = {}
    for index, entry in ipairs(entries) do
        result[index] = {
            entry_id = entry.publicId,
            account_id = entry.accountId,
            sequence = entry.sequence,
            amount_minor = entry.amountMinor,
        }
    end
    return result
end

local function validateEntrySet(entries)
    if type(entries) ~= 'table' or #entries < 2 or #entries > 16 then
        return nil, domainError('VALIDATION_FAILED', 'A transaction requires two to sixteen postings.')
    end
    local total, seen = 0, {}
    for index, entry in ipairs(entries) do
        if type(entry) ~= 'table' or not Foundation.isUuid(entry.accountId)
            or seen[entry.accountId] or type(entry.amountMinor) ~= 'number'
            or math.type(entry.amountMinor) ~= 'integer' or entry.amountMinor == 0
            or entry.amountMinor < -Foundation.MAX_MINOR or entry.amountMinor > Foundation.MAX_MINOR
            or type(entry.metadataJson) ~= 'string' or #entry.metadataJson > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'A transaction posting is invalid.')
        end
        seen[entry.accountId] = true
        entry.sequence = index
        total = total + entry.amountMinor
    end
    if total ~= 0 then
        return nil, domainError('LEDGER_UNBALANCED', 'The signed posting sum must equal zero.')
    end
    return true, nil
end

local function legacyPair(entries)
    if #entries ~= 2 then return nil end
    local negative, positive
    for _, entry in ipairs(entries) do
        if entry.amountMinor < 0 then negative = entry else positive = entry end
    end
    if not negative or not positive or -negative.amountMinor ~= positive.amountMinor then return nil end
    return negative, positive
end

local function validateTopology(query, kind, accounts, entries)
    if kind ~= 'mint' and kind ~= 'burn' then
        for _, entry in ipairs(entries) do
            if accounts[entry.accountId].account_role ~= 'asset' then
                return nil, domainError('INVALID_LEDGER_ROLE',
                    'Normal financial transactions may use only asset accounts.')
            end
        end
        return true, nil
    end
    local currencyId = accounts[entries[1].accountId].currency_id
    local topology = txOne(query, [[SELECT `mint_account_id`, `burn_account_id`, `topology_state`
        FROM `synex_currency_system_topology` WHERE `currency_id` = ? FOR UPDATE]], { currencyId })
    if not topology or topology.topology_state ~= 'ready' then
        return nil, domainError('SYSTEM_TOPOLOGY_UNAVAILABLE',
            'The currency mint/burn topology is incomplete.')
    end
    local systemSeen, assetSeen = false, false
    for _, entry in ipairs(entries) do
        local account = accounts[entry.accountId]
        if kind == 'mint' then
            if account.account_role == 'mint' and account.id == tonumber(topology.mint_account_id)
                and entry.amountMinor < 0 then
                if systemSeen then return nil, domainError('INVALID_LEDGER_ROLE', 'Mint topology is ambiguous.') end
                systemSeen = true
            elseif account.account_role == 'asset' and entry.amountMinor > 0 then
                assetSeen = true
            else
                return nil, domainError('INVALID_LEDGER_ROLE', 'Mint postings violate the currency topology.')
            end
        else
            if account.account_role == 'burn' and account.id == tonumber(topology.burn_account_id)
                and entry.amountMinor > 0 then
                if systemSeen then return nil, domainError('INVALID_LEDGER_ROLE', 'Burn topology is ambiguous.') end
                systemSeen = true
            elseif account.account_role == 'asset' and entry.amountMinor < 0 then
                assetSeen = true
            else
                return nil, domainError('INVALID_LEDGER_ROLE', 'Burn postings violate the currency topology.')
            end
        end
    end
    if not systemSeen or not assetSeen then
        return nil, domainError('INVALID_LEDGER_ROLE', 'The currency system account is missing from the transaction.')
    end
    return true, nil
end

local function validatePolicies(query, accounts, entries, kind, reservationReleaseByAccount)
    local operationKey = ({
        debit = 'withdraw', credit = 'deposit', hold_capture = 'hold.capture'
    })[kind] or kind
    for _, entry in ipairs(entries) do
        local account = accounts[entry.accountId]
        local releasedReservation = tonumber(reservationReleaseByAccount
            and reservationReleaseByAccount[entry.accountId]) or 0
        local valid, policyError = Engine:evaluateAccountOperation(query, account,
            operationKey, entry.amountMinor, releasedReservation, true)
        if not valid then return nil, policyError end
    end
    return true, nil
end

local function validateExpectedSequences(accounts, publicIds, expectedSequences)
    if expectedSequences == nil then return true, nil end
    if type(expectedSequences) ~= 'table' then
        return nil, domainError('VALIDATION_FAILED',
            'Expected account sequences must be a bounded account map.')
    end
    for accountId, expected in pairs(expectedSequences) do
        if not accounts[accountId] or type(expected) ~= 'number'
            or math.type(expected) ~= 'integer' or expected < 0
            or expected > Foundation.MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED',
                'Expected account sequences must be non-negative JavaScript-safe integers.')
        end
    end
    for _, accountId in ipairs(publicIds) do
        local expected = expectedSequences[accountId]
        if expected ~= nil and accounts[accountId].sequence_no ~= expected then
            return nil, domainError('WRITE_CONFLICT',
                'An expected account sequence no longer matches current state.')
        end
    end
    return true, nil
end

function Engine:postWithin(query, operationId, command, specification)
    local entries = specification.entries
    local valid, validationError = validateEntrySet(entries)
    if not valid then return nil, validationError end
    local publicIds = {}
    for _, entry in ipairs(entries) do publicIds[#publicIds + 1] = entry.accountId end
    local accounts, accountError = self:loadAccounts(query, publicIds)
    if not accounts then return nil, accountError end
    local sequencesValid, sequenceError = validateExpectedSequences(
        accounts, publicIds, specification.expectedSequences)
    if not sequencesValid then return nil, sequenceError end

    local currencyId, currencyCode
    for _, entry in ipairs(entries) do
        local account = accounts[entry.accountId]
        if account.currency_status ~= 'active' then
            return nil, domainError('CURRENCY_UNAVAILABLE', 'The transaction currency is disabled.')
        end
        if not specification.allowFrozen and account.status ~= 'active'
            or specification.allowFrozen and account.status == 'closed' then
            return nil, domainError('ACCOUNT_UNAVAILABLE', 'An account does not permit this transaction.')
        end
        if currencyId and tostring(currencyId) ~= tostring(account.currency_id) then
            return nil, domainError('CURRENCY_MISMATCH', 'All transaction accounts must use the same currency.')
        end
        currencyId, currencyCode = account.currency_id, account.currency_code
    end
    if command.currencyCode ~= nil and command.currencyCode ~= currencyCode then
        return nil, domainError('CURRENCY_MISMATCH',
            'The requested currency does not match the transaction accounts.')
    end

    local _, reasonError = self:requireReason(query, command.reasonCode,
        command.authority, command.allowBuiltinReason)
    if reasonError then return nil, reasonError end
    local topologyValid, topologyError = validateTopology(query, specification.kind, accounts, entries)
    if not topologyValid then return nil, topologyError end

    for _, entry in ipairs(entries) do
        if entry.amountMinor < 0 and accounts[entry.accountId].account_role == 'asset' then
            local _, accessError = self:requireAccess(query, accounts[entry.accountId],
                command.authority, specification.permission or 'transfer')
            if accessError then return nil, accessError end
        end
    end
    local policiesValid, policyError = validatePolicies(query, accounts, entries,
        specification.kind, specification.reservationReleaseByAccount)
    if not policiesValid then return nil, policyError end
    for _, entry in ipairs(entries) do
        local account = accounts[entry.accountId]
        if entry.amountMinor < 0 and account.account_role == 'asset' then
            txRows(query, [[INSERT INTO `synex_account_policy_daily_usage`
                (`account_id`, `usage_date`, `outgoing_minor`, `operation_count`, `version`)
                VALUES (?, UTC_DATE(), ?, 1, 1)
                ON DUPLICATE KEY UPDATE `outgoing_minor` = `outgoing_minor` + VALUES(`outgoing_minor`),
                    `operation_count` = `operation_count` + 1, `version` = `version` + 1]], {
                account.id, math.abs(entry.amountMinor)
            })
        end
    end

    local transactionId = uuidV4(random)
    txRows(query, [[INSERT INTO `synex_ledger_transactions`
        (`public_id`, `operation_id`, `currency_id`, `transaction_kind`, `reference_text`,
            `actor_ref`, `metadata_json`, `source_resource`, `trace_id`, `reference_type`,
            `reference_id`, `actor_kind`, `reason_code`, `posting_model`, `entry_count`,
            `status`, `posted_at`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'multi_leg', ?, 'posted', CURRENT_TIMESTAMP(6))]], {
        transactionId, operationId, currencyId, specification.kind, command.reference,
        command.authority.principalRef, command.metadataJson or '{}', command.authority.callerResource,
        command.authority.traceId, command.referenceType, command.referenceId,
        command.authority.principalKind, command.reasonCode, #entries
    })
    local transaction = txOne(query, [[SELECT `id` FROM `synex_ledger_transactions`
        WHERE `public_id` = ? FOR UPDATE]], { transactionId })
    if not transaction then error('ledger transaction insert was not visible', 0) end

    for _, entry in ipairs(entries) do
        entry.publicId = uuidV4(random)
        txRows(query, [[INSERT INTO `synex_ledger_entries`
            (`public_id`, `transaction_id`, `account_id`, `sequence_no`, `amount_minor`, `metadata_json`)
            VALUES (?, ?, ?, ?, ?, ?)]], {
            entry.publicId, transaction.id, accounts[entry.accountId].id,
            entry.sequence, entry.amountMinor, entry.metadataJson or '{}'
        })
    end

    local negative, positive = legacyPair(entries)
    local postingId
    if negative and positive then
        postingId = uuidV4(random)
        txRows(query, [[INSERT INTO `synex_ledger_postings`
            (`public_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `debit_minor`, `credit_minor`)
            VALUES (?, ?, ?, ?, ?, ?)]], {
            postingId, transaction.id, accounts[negative.accountId].id, accounts[positive.accountId].id,
            -negative.amountMinor, positive.amountMinor
        })
    end

    if specification.beforeSnapshots then
        local prepared, preparationError = specification.beforeSnapshots(query, transaction.id, transactionId, accounts)
        if not prepared then return nil, preparationError end
    end
    for _, entry in ipairs(entries) do
        local account = accounts[entry.accountId]
        local _, snapshotError = self:appendSnapshot(query, account, 'ledger', transactionId,
            account.booked_minor + entry.amountMinor)
        if snapshotError then return nil, snapshotError end
    end

    if specification.refundableMinor then
        local anchor = accounts[specification.refundAnchorAccountId]
        if not anchor or type(specification.refundableMinor) ~= 'number'
            or math.type(specification.refundableMinor) ~= 'integer'
            or specification.refundableMinor < 1 or specification.refundableMinor > Foundation.MAX_MINOR then
            return nil, domainError('REFUND_ANCHOR_INVALID', 'The refundable transaction anchor is invalid.')
        end
        local anchorEntry
        for _, entry in ipairs(entries) do
            if entry.accountId == specification.refundAnchorAccountId then anchorEntry = entry break end
        end
        if not anchorEntry or anchorEntry.amountMinor >= 0
            or math.abs(anchorEntry.amountMinor) < specification.refundableMinor then
            return nil, domainError('REFUND_ANCHOR_INVALID', 'The refundable amount exceeds the anchor posting.')
        end
        txRows(query, [[INSERT INTO `synex_ledger_refund_anchors`
            (`original_transaction_id`, `anchor_account_id`, `refundable_minor`, `refunded_minor`,
                `state`, `source_resource`, `trace_id`, `metadata_json`, `version`)
            VALUES (?, ?, ?, 0, 'open', ?, ?, ?, 1)]], {
            transaction.id, anchor.id, specification.refundableMinor,
            command.authority.callerResource, command.authority.traceId, command.metadataJson or '{}'
        })
    end

    local response = {
        transaction_id = transactionId,
        transaction_kind = specification.kind,
        currency_code = currencyCode,
        entry_count = #entries,
        entries = publicEntries(entries),
        reason_code = command.reasonCode,
        source_resource = command.authority.callerResource,
        trace_id = command.authority.traceId,
    }
    if postingId then
        response.posting_id = postingId
        response.debit_account_id = negative.accountId
        response.credit_account_id = positive.accountId
        response.debit_minor = -negative.amountMinor
        response.credit_minor = positive.amountMinor
        response.amount_minor = positive.amountMinor
    end
    local eventType = specification.eventType or 'synex.accounts.transaction.posted'
    local _, eventError = self:writeEvent(query, operationId, eventType, transactionId, command, response)
    if eventError then return nil, eventError end
    txRows(query, [[UPDATE `synex_currencies`
        SET `precision_locked_at` = COALESCE(`precision_locked_at`, CURRENT_TIMESTAMP(6)),
            `precision_lock_transaction_id` = COALESCE(`precision_lock_transaction_id`, ?)
        WHERE `id` = ?]], { transaction.id, currencyId })
    response._internal_transaction_id = transaction.id
    return response, nil
end

local function stripInternal(response, legacyProjection)
    response._internal_transaction_id = nil
    if not legacyProjection then
        response.posting_id = nil
        response.debit_account_id = nil
        response.credit_account_id = nil
        response.debit_minor = nil
        response.credit_minor = nil
        response.amount_minor = nil
    end
    return response
end

function port:postTransaction(command)
    return Engine:mutation(command.operationName or 'post', command, function(query, operationId)
        local response, postError = Engine:postWithin(query, operationId, command, {
            entries = command.entries,
            kind = command.kind or 'post',
            permission = command.permission or 'transfer',
            refundableMinor = command.refundableMinor,
            refundAnchorAccountId = command.refundAnchorAccountId,
            expectedSequences = command.expectedSequences,
        })
        if not response then return nil, postError end
        return stripInternal(response, command.legacyProjection == true)
    end)
end

local function systemTransaction(portInstance, command, kind)
    return Engine:mutation(kind, command, function(query, operationId)
        local asset = txOne(query, [[SELECT `account`.`id`, `account`.`public_id`,
                `account`.`currency_id`, `account`.`account_role`,
                `system_account`.`public_id` AS `system_account_id`,
                `topology`.`topology_state`
            FROM `synex_accounts` AS `account`
            INNER JOIN `synex_currency_system_topology` AS `topology`
                ON `topology`.`currency_id` = `account`.`currency_id`
            LEFT JOIN `synex_accounts` AS `system_account`
                ON `system_account`.`id` = CASE WHEN ? = 'mint'
                    THEN `topology`.`mint_account_id` ELSE `topology`.`burn_account_id` END
            WHERE `account`.`public_id` = ? FOR UPDATE]], { kind, command.accountId })
        if not asset then return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.') end
        if asset.account_role ~= 'asset' or asset.topology_state ~= 'ready'
            or not Foundation.isUuid(asset.system_account_id) then
            return nil, domainError('SYSTEM_TOPOLOGY_UNAVAILABLE',
                'The currency mint/burn topology is incomplete.')
        end
        local entries
        if kind == 'mint' then
            entries = {
                { accountId = asset.system_account_id, amountMinor = -command.amountMinor,
                    metadataJson = '{}' },
                { accountId = command.accountId, amountMinor = command.amountMinor,
                    metadataJson = '{}' },
            }
        else
            entries = {
                { accountId = command.accountId, amountMinor = -command.amountMinor,
                    metadataJson = '{}' },
                { accountId = asset.system_account_id, amountMinor = command.amountMinor,
                    metadataJson = '{}' },
            }
        end
        local response, postError = Engine:postWithin(query, operationId, command, {
            entries = entries,
            kind = kind,
            permission = kind == 'mint' and 'deposit' or 'withdraw',
        })
        if not response then return nil, postError end
        return stripInternal(response, false)
    end)
end

function port:mintTransaction(command)
    return systemTransaction(self, command, 'mint')
end

function port:burnTransaction(command)
    return systemTransaction(self, command, 'burn')
end

-- Legacy pairwise APIs are adapters over the signed multi-leg engine. They
-- retain the old response projection while no longer writing an independent
-- financial truth.
function port:post(command)
    command.entries = {
        { accountId = command.sourceAccountId, amountMinor = -command.amountMinor, metadataJson = '{}' },
        { accountId = command.destinationAccountId, amountMinor = command.amountMinor, metadataJson = '{}' },
    }
    command.operationName = command.kind
    command.legacyProjection = true
    command.reasonCode = command.reasonCode or ('synex_accounts.legacy.' .. command.kind)
    command.allowBuiltinReason = true
    if command.kind == 'transfer' or command.kind == 'debit' or command.kind == 'credit' then
        command.refundableMinor = command.amountMinor
        command.refundAnchorAccountId = command.sourceAccountId
    end
    local response, responseError = self:postTransaction(command)
    if not response then return nil, responseError end
    return {
        transaction_id = response.transaction_id,
        posting_id = response.posting_id,
        transaction_kind = response.transaction_kind,
        debit_account_id = response.debit_account_id,
        credit_account_id = response.credit_account_id,
        debit_minor = response.debit_minor,
        credit_minor = response.credit_minor,
        currency_code = response.currency_code,
    }, nil
end

function port:reverseTransaction(command)
    return Engine:mutation(command.operationName or 'reverse', command, function(query, operationId)
        local original = txOne(query, [[SELECT `transaction`.`id`, `transaction`.`public_id`,
                `transaction`.`currency_id`, `transaction`.`transaction_kind`, `transaction`.`status`
            FROM `synex_ledger_transactions` AS `transaction`
            WHERE `transaction`.`public_id` = ? FOR UPDATE]], { command.transactionId })
        if not original then return nil, domainError('TRANSACTION_NOT_FOUND', 'The transaction does not exist.') end
        if original.status ~= 'posted' then
            return nil, domainError('TRANSACTION_NOT_POSTED', 'Only posted transactions can be reversed.')
        end
        if nonReversibleKinds[original.transaction_kind] then
            return nil, domainError('REVERSAL_NOT_ALLOWED',
                'System, hold-capture, refund, and reversal transactions cannot be reversed independently.')
        end
        local relationship = txOne(query, [[SELECT
                (SELECT COUNT(*) FROM `synex_ledger_reversals` WHERE `original_transaction_id` = ?) AS `reversed`,
                (SELECT COUNT(*) FROM `synex_ledger_reversals` WHERE `reversal_transaction_id` = ?) AS `is_reversal`]],
            { original.id, original.id })
        if tonumber(relationship and relationship.reversed) > 0 then
            return nil, domainError('TRANSACTION_ALREADY_REVERSED', 'The transaction was already reversed.')
        end
        if tonumber(relationship and relationship.is_reversal) > 0 then
            return nil, domainError('REVERSAL_OF_REVERSAL', 'A reversal transaction cannot be reversed.')
        end
        local refundState = txOne(query, [[SELECT `refunded_minor`
            FROM `synex_ledger_refund_anchors`
            WHERE `original_transaction_id` = ? FOR UPDATE]], { original.id })
        if refundState and tonumber(refundState.refunded_minor) > 0 then
            return nil, domainError('REVERSAL_NOT_ALLOWED',
                'A transaction with completed refunds cannot be reversed.')
        end
        local rows = txRows(query, [[SELECT `account`.`public_id` AS `account_id`,
                `entry`.`amount_minor`, `entry`.`metadata_json`
            FROM `synex_ledger_entries` AS `entry`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
            WHERE `entry`.`transaction_id` = ? ORDER BY `entry`.`sequence_no` ASC]], { original.id })
        local entries = {}
        for index, row in ipairs(rows) do
            entries[index] = { accountId = row.account_id, amountMinor = -tonumber(row.amount_minor),
                metadataJson = row.metadata_json or '{}', sequence = index }
        end
        local response, postError = Engine:postWithin(query, operationId, command, {
            entries = entries, kind = 'reversal', permission = 'transfer', allowFrozen = true,
            eventType = 'synex.accounts.transaction.reversed',
        })
        if not response then return nil, postError end
        local internalId = response._internal_transaction_id
        local reversalId = uuidV4(random)
        txRows(query, [[INSERT INTO `synex_ledger_reversals`
            (`public_id`, `original_transaction_id`, `reversal_transaction_id`, `reason`, `actor_ref`)
            VALUES (?, ?, ?, ?, ?)]], {
            reversalId, original.id, internalId, command.reference or command.reasonCode,
            command.authority.principalRef
        })
        response.reversal_id = reversalId
        response.original_transaction_id = command.transactionId
        return stripInternal(response, command.legacyProjection == true)
    end)
end

function port:reverse(command)
    command.operationName = 'reverse'
    command.legacyProjection = true
    command.reasonCode = command.reasonCode or 'synex_accounts.reversal'
    command.reference = command.reference or command.reason
    command.allowBuiltinReason = true
    local response, responseError = self:reverseTransaction(command)
    if not response then return nil, responseError end
    return {
        reversal_id = response.reversal_id,
        original_transaction_id = response.original_transaction_id,
        transaction_id = response.transaction_id,
        posting_id = response.posting_id,
        debit_account_id = response.debit_account_id,
        credit_account_id = response.credit_account_id,
        amount_minor = response.amount_minor,
        currency_code = response.currency_code,
    }, nil
end

function port:refundTransaction(command)
    return Engine:mutation(command.operationName or 'refund', command, function(query, operationId)
        local anchor = txOne(query, [[SELECT `anchor`.`original_transaction_id`, `anchor`.`anchor_account_id`,
                `anchor`.`refundable_minor`, `anchor`.`refunded_minor`, `anchor`.`state`, `anchor`.`version`,
                `transaction`.`public_id` AS `transaction_id`, `account`.`public_id` AS `anchor_account_id`
            FROM `synex_ledger_refund_anchors` AS `anchor`
            INNER JOIN `synex_ledger_transactions` AS `transaction`
                ON `transaction`.`id` = `anchor`.`original_transaction_id`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `anchor`.`anchor_account_id`
            WHERE `transaction`.`public_id` = ? FOR UPDATE]], { command.transactionId })
        if not anchor then
            return nil, domainError('TRANSACTION_NOT_REFUNDABLE', 'The transaction has no refund anchor.')
        end
        if anchor.state ~= 'open' then
            return nil, domainError('REFUND_LIMIT_EXCEEDED', 'The transaction is already fully refunded.')
        end
        if txOne(query, [[SELECT `id` FROM `synex_ledger_reversals`
            WHERE `original_transaction_id` = ? FOR UPDATE]], {
            anchor.original_transaction_id
        }) then
            return nil, domainError('TRANSACTION_NOT_REFUNDABLE',
                'A reversed transaction cannot be refunded.')
        end
        local expectedVersion = tonumber(command.expectedVersion)
        if expectedVersion and expectedVersion ~= tonumber(anchor.version) then
            return nil, domainError('STALE_VERSION', 'The refund anchor version changed.', true)
        end
        local originalRows = txRows(query, [[SELECT `account`.`public_id` AS `account_id`, `entry`.`amount_minor`
            FROM `synex_ledger_entries` AS `entry`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
            WHERE `entry`.`transaction_id` = ? ORDER BY `entry`.`sequence_no` ASC]], {
            anchor.original_transaction_id
        })
        local originalEntries = {}
        for index, row in ipairs(originalRows) do
            originalEntries[index] = { accountId = row.account_id, amountMinor = tonumber(row.amount_minor) }
        end
        local cumulativeRows = txRows(query, [[SELECT `account`.`public_id` AS `account_id`,
                COALESCE(SUM(ABS(`entry`.`amount_minor`)), 0) AS `refunded_minor`
            FROM `synex_ledger_refunds` AS `refund`
            INNER JOIN `synex_ledger_entries` AS `entry`
                ON `entry`.`transaction_id` = `refund`.`refund_transaction_id`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
            WHERE `refund`.`anchor_transaction_id` = ?
            GROUP BY `account`.`public_id`]], { anchor.original_transaction_id })
        local cumulative = {}
        for _, row in ipairs(cumulativeRows) do cumulative[row.account_id] = tonumber(row.refunded_minor) or 0 end
        local refundValid, refundError = Domain.validateRefund(originalEntries, command.entries,
            anchor.anchor_account_id, command.amountMinor, cumulative)
        if not refundValid then return nil, refundError end
        if tonumber(anchor.refunded_minor) + command.amountMinor > tonumber(anchor.refundable_minor) then
            return nil, domainError('REFUND_LIMIT_EXCEEDED', 'The cumulative refund exceeds the refundable amount.')
        end
        local response, postError = Engine:postWithin(query, operationId, command, {
            entries = command.entries, kind = 'refund', permission = 'transfer', allowFrozen = true,
            eventType = 'synex.accounts.transaction.refunded',
        })
        if not response then return nil, postError end
        local refundId = uuidV4(random)
        local sequenceRow = txOne(query, [[SELECT COALESCE(MAX(`sequence_no`), 0) + 1 AS `sequence_no`
            FROM `synex_ledger_refunds` WHERE `anchor_transaction_id` = ?]], {
            anchor.original_transaction_id
        })
        local cumulativeMinor = tonumber(anchor.refunded_minor) + command.amountMinor
        txRows(query, [[INSERT INTO `synex_ledger_refunds`
            (`public_id`, `anchor_transaction_id`, `refund_transaction_id`, `sequence_no`,
                `amount_minor`, `cumulative_refunded_minor`, `reason_code`)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], {
            refundId, anchor.original_transaction_id, response._internal_transaction_id,
            tonumber(sequenceRow.sequence_no), command.amountMinor, cumulativeMinor, command.reasonCode
        })
        txRows(query, [[UPDATE `synex_ledger_refund_anchors`
            SET `refunded_minor` = ?, `state` = ?, `version` = `version` + 1,
                `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `original_transaction_id` = ? AND `version` = ?]], {
            cumulativeMinor,
            cumulativeMinor == tonumber(anchor.refundable_minor) and 'exhausted' or 'open',
            anchor.original_transaction_id, anchor.version
        })
        response.refund_id = refundId
        response.original_transaction_id = command.transactionId
        response.refund_amount_minor = command.amountMinor
        response.cumulative_refunded_minor = cumulativeMinor
        response.refundable_minor = tonumber(anchor.refundable_minor)
        return stripInternal(response, false)
    end)
end
end
