return function(port, context)
local Foundation = context.foundation
local Domain = assert(context.domain, 'accounts engine requires domain rules')
local domainError = context.domainError
local uuidV4 = context.uuidV4
local one = context.one
local many = context.many
local jsonEncode = context.jsonEncode
local jsonDecode = context.jsonDecode
local random = context.random
local scopedReplay = context.scopedReplay
local withRetriableTransaction = context.withRetriableTransaction
local recordMetric = context.recordMetric or function() end

local Engine = {}

local legacyEvents = {
    ['synex.accounts.account.created'] = 'synex.accounts.created',
    ['synex.accounts.transaction.posted'] = 'synex.accounts.posted',
    ['synex.accounts.transaction.reversed'] = 'synex.accounts.transaction_reversed',
    ['synex.accounts.transaction.refunded'] = 'synex.accounts.transaction_refunded',
    ['synex.accounts.hold.created'] = 'synex.accounts.hold_created',
    ['synex.accounts.hold.captured'] = 'synex.accounts.hold_captured',
    ['synex.accounts.hold.released'] = 'synex.accounts.hold_released',
    ['synex.accounts.hold.expired'] = 'synex.accounts.hold_expired',
    ['synex.accounts.access.granted'] = 'synex.accounts.access_granted',
    ['synex.accounts.access.revoked'] = 'synex.accounts.access_revoked',
    ['synex.accounts.reconciliation.completed'] = 'synex.accounts.reconciliation_completed',
}

local permissionCompatibility = {
    ['balance.read'] = { ['balance.read'] = true, view = true },
    ['history.read'] = { ['history.read'] = true, history = true },
    deposit = { deposit = true },
    withdraw = { withdraw = true },
    transfer = { transfer = true },
    ['hold.create'] = { ['hold.create'] = true, transfer = true },
    ['hold.capture'] = { ['hold.capture'] = true, transfer = true },
    ['hold.release'] = { ['hold.release'] = true, transfer = true },
    ['access.read'] = { ['access.read'] = true, view = true, manage = true },
    ['access.manage'] = { ['access.manage'] = true, manage = true },
    ['settings.manage'] = { ['settings.manage'] = true, manage = true },
    close = { close = true },
}

local accountPolicyOperationKeys = {
    post = true, deposit = true, withdraw = true, transfer = true,
    mint = true, burn = true, reversal = true, refund = true,
    ['hold.create'] = true, ['hold.capture'] = true, ['hold.release'] = true,
}

local function txRows(query, sql, values)
    local rows = query(sql, values or {})
    if type(rows) ~= 'table' then
        error('accounts transaction query returned an invalid row collection', 0)
    end
    return rows
end

local function txOne(query, sql, values)
    return txRows(query, sql, values)[1]
end

local function integer(value, minimum, maximum)
    local converted = tonumber(value)
    if not converted or converted ~= math.floor(converted)
        or converted < minimum or converted > maximum then return nil end
    return converted
end

local function encoded(value)
    local ok, result = pcall(jsonEncode, value)
    if not ok or type(result) ~= 'string' or #result > 32768 then
        return nil, domainError('RESPONSE_TOO_LARGE', 'The financial response exceeds the bounded operation receipt.')
    end
    return result, nil
end

function Engine:mutation(operationName, command, handler)
    if type(command) ~= 'table' or type(command.authority) ~= 'table'
        or not Foundation.isUuid(command.idempotencyKey)
        or type(command.fingerprint) ~= 'string' or #command.fingerprint < 1
        or #command.fingerprint > 16384 then
        return nil, domainError('VALIDATION_FAILED', 'The scoped financial operation is invalid.')
    end
    local replayed, replayError = scopedReplay(command.authority, operationName,
        command.idempotencyKey, command.fingerprint)
    if replayed or replayError then return replayed, replayError end

    local result, domainFailure
    local committed, transactionError = withRetriableTransaction(function(query)
        result, domainFailure = nil, nil
        local existing = txOne(query, [[SELECT `id`, `request_fingerprint`, `state`, `response_json`
            FROM `synex_account_operations`
            WHERE `caller_resource` = ?
                AND `caller_principal_kind` = ? AND `caller_principal_ref` = ?
                AND `operation_name` = ? AND `idempotency_key` = ?
            FOR UPDATE]], {
            command.authority.callerResource, command.authority.principalKind,
            command.authority.principalRef, operationName, command.idempotencyKey
        })
        if existing then
            if existing.request_fingerprint ~= command.fingerprint then
                recordMetric('increment', 'synex_accounts_idempotency_conflicts_total', {
                    operation = operationName,
                })
                domainFailure = domainError('IDEMPOTENCY_CONFLICT',
                    'The scoped idempotency key was already used for a different request.')
                return false
            end
            if existing.state ~= 'completed' or type(existing.response_json) ~= 'string' then
                domainFailure = domainError('OPERATION_IN_PROGRESS',
                    'The scoped idempotent operation has not completed.', true)
                return false
            end
            local decoded, previous = pcall(jsonDecode, existing.response_json)
            if not decoded or type(previous) ~= 'table' then
                domainFailure = domainError('DATABASE_RESULT_INVALID',
                    'The stored idempotency response is invalid.')
                return false
            end
            result = previous
            recordMetric('increment', 'synex_accounts_idempotency_replays_total', {
                operation = operationName,
            })
            return true
        end

        txRows(query, [[INSERT INTO `synex_account_operations`
            (`idempotency_key`, `operation_name`, `request_fingerprint`, `state`,
                `caller_resource`, `caller_principal_kind`, `caller_principal_ref`, `trace_id`)
            VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)]], {
            command.idempotencyKey, operationName, command.fingerprint,
            command.authority.callerResource, command.authority.principalKind,
            command.authority.principalRef, command.authority.traceId
        })
        local operation = txOne(query, [[SELECT `id` FROM `synex_account_operations`
            WHERE `caller_resource` = ?
                AND `caller_principal_kind` = ? AND `caller_principal_ref` = ?
                AND `operation_name` = ? AND `idempotency_key` = ?
            FOR UPDATE]], {
            command.authority.callerResource, command.authority.principalKind,
            command.authority.principalRef, operationName, command.idempotencyKey
        })
        if not operation then error('scoped operation insert was not visible', 0) end

        result, domainFailure = handler(query, operation.id)
        if not result then return false end
        local responseJson, responseError = encoded(result)
        if not responseJson then domainFailure = responseError return false end
        local updated = txRows(query, [[UPDATE `synex_account_operations`
            SET `state` = 'completed', `response_json` = ?, `completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `id` = ? AND `state` = 'pending']], { responseJson, operation.id })
        if type(updated) == 'table' and updated.affectedRows ~= nil
            and tonumber(updated.affectedRows) ~= 1 then
            error('scoped operation receipt completion was fenced', 0)
        end
        return true
    end, {
        maximumAttempts = 3,
        traceId = command.authority.traceId,
        shouldRetry = function(_, _, failureKind)
            return domainFailure == nil
                and (failureKind == 'deadlock' or failureKind == 'lock_timeout')
        end,
    })
    if committed then return result, nil end
    if domainFailure then return nil, domainFailure end

    replayed, replayError = scopedReplay(command.authority, operationName,
        command.idempotencyKey, command.fingerprint)
    if replayed or replayError then return replayed, replayError end
    return nil, transactionError or domainError('WRITE_CONFLICT',
        'The financial operation conflicted with current state.', true)
end

function Engine:loadAccounts(query, publicIds)
    if type(publicIds) ~= 'table' or #publicIds < 1 or #publicIds > 16 then
        return nil, domainError('VALIDATION_FAILED', 'The account lock set is invalid.')
    end
    local sorted, seen = {}, {}
    for _, publicId in ipairs(publicIds) do
        if not Foundation.isUuid(publicId) or seen[publicId] then
            return nil, domainError('VALIDATION_FAILED', 'The account lock set contains invalid or duplicate identifiers.')
        end
        seen[publicId] = true
        sorted[#sorted + 1] = publicId
    end
    table.sort(sorted)
    local placeholders = {}
    for index = 1, #sorted do placeholders[index] = '?' end
    local sql = ([[SELECT `account`.`id`, `account`.`public_id`, `account`.`account_key`,
            `account`.`account_role`, `account`.`allow_negative`, `account`.`status`, `account`.`version`,
            `currency`.`id` AS `currency_id`, `currency`.`currency_code`, `currency`.`minor_unit`,
            `currency`.`status` AS `currency_status`, `owner`.`owner_kind`, `owner`.`owner_ref`,
            `snapshot`.`sequence_no`, `snapshot`.`booked_minor`, `snapshot`.`reserved_minor`,
            `snapshot`.`created_at` AS `snapshot_created_at`
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `account`.`currency_id`
        INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`public_id` IN (%s)
        ORDER BY `account`.`id` ASC FOR UPDATE]]):format(table.concat(placeholders, ','))
    local rows = txRows(query, sql, sorted)
    if #rows ~= #sorted then
        return nil, domainError('ACCOUNT_NOT_FOUND', 'One or more accounts do not exist.')
    end
    local accounts = {}
    for _, row in ipairs(rows) do
        local accountId = tonumber(row.id)
        local booked = integer(row.booked_minor, -Foundation.MAX_MINOR, Foundation.MAX_MINOR)
        local sequence = integer(row.sequence_no, 0, Foundation.MAX_MINOR)
        local version = integer(row.version, 1, Foundation.MAX_MINOR)
        if not accountId or not booked or not sequence or not version then
            return nil, domainError('DATABASE_RESULT_INVALID', 'An account state is invalid.')
        end
        local reservation = txOne(query, [[SELECT COALESCE(SUM(`remaining_minor`), 0) AS `reserved_minor`
            FROM `synex_account_holds`
            WHERE `account_id` = ? AND `state` IN ('active', 'partially_captured')
                AND `expires_at` > CURRENT_TIMESTAMP(6)]], { accountId })
        local reserved = integer(reservation and reservation.reserved_minor, 0, Foundation.MAX_MINOR)
        if not reserved then
            return nil, domainError('DATABASE_RESULT_INVALID', 'An account reservation state is invalid.')
        end
        row.id = accountId
        row.booked_minor = booked
        row.reserved_minor = reserved
        row.sequence_no = sequence
        row.version = version
        row.available_minor = booked - reserved
        accounts[row.public_id] = row
    end
    return accounts, nil
end

function Engine:requireMutableAccount(account)
    if type(account) ~= 'table' or type(account.status) ~= 'string' then
        return nil, domainError('DATABASE_RESULT_INVALID', 'The account state is invalid.')
    end
    if account.status == 'closed' then
        return nil, domainError('ACCOUNT_CLOSED', 'A closed account cannot be mutated.')
    end
    return true, nil
end

function Engine:evaluateAccountClosure(query, account)
    if type(account) ~= 'table' or type(account.id) ~= 'number' then
        return nil, domainError('ACCESS_CHECK_INVALID',
            'The account close preflight is invalid.')
    end
    local bookedMinor = integer(account.booked_minor, -Foundation.MAX_MINOR,
        Foundation.MAX_MINOR)
    local reservedMinor = integer(account.reserved_minor, 0, Foundation.MAX_MINOR)
    if not bookedMinor or not reservedMinor then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The account close state is invalid.')
    end
    if bookedMinor ~= 0 then
        return nil, domainError('ACCOUNT_BALANCE_NOT_ZERO',
            'An account must have zero balance before closing.')
    end
    if reservedMinor ~= 0 then
        return nil, domainError('ACCOUNT_HAS_ACTIVE_HOLDS',
            'An account with active holds cannot close.')
    end
    local refundLifecycle = txOne(query, [[SELECT `anchor`.`original_transaction_id`
        FROM `synex_ledger_refund_anchors` AS `anchor`
        INNER JOIN `synex_ledger_entries` AS `entry`
            ON `entry`.`transaction_id` = `anchor`.`original_transaction_id`
        WHERE `anchor`.`state` = 'open' AND `entry`.`account_id` = ?
            AND NOT EXISTS (SELECT 1 FROM `synex_ledger_reversals` AS `reversal`
                WHERE `reversal`.`original_transaction_id` = `anchor`.`original_transaction_id`)
        ORDER BY `anchor`.`original_transaction_id` ASC LIMIT 1]], { account.id })
    if refundLifecycle then
        return nil, domainError('ACCOUNT_LIFECYCLE_BLOCKED',
            'An open refund lifecycle blocks account closing.', false, {
                lifecycle = 'open_refund',
            })
    end
    return true, nil
end

function Engine:evaluateAccountOperation(query, account, operationKey, amountDelta,
    reservationReleaseMinor, lockDailyUsage)
    if type(account) ~= 'table' or type(account.id) ~= 'number'
        or not accountPolicyOperationKeys[operationKey]
        or (amountDelta == nil) ~= (operationKey == 'hold.release')
        or (amountDelta ~= nil and (type(amountDelta) ~= 'number'
            or math.type(amountDelta) ~= 'integer' or amountDelta == 0
            or amountDelta < -Foundation.MAX_MINOR
            or amountDelta > Foundation.MAX_MINOR)) then
        return nil, domainError('ACCESS_CHECK_INVALID',
            'The account operation preflight is invalid.')
    end
    local bookedMinor = integer(account.booked_minor, -Foundation.MAX_MINOR,
        Foundation.MAX_MINOR)
    local reservedMinor = integer(account.reserved_minor, 0, Foundation.MAX_MINOR)
    local releasedReservation = integer(reservationReleaseMinor or 0, 0,
        Foundation.MAX_MINOR)
    if not bookedMinor or not reservedMinor or not releasedReservation
        or releasedReservation > reservedMinor then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The account operation state is invalid.')
    end

    if amountDelta ~= nil then
        local restrictions = txRows(query, [[SELECT `restriction_kind`
            FROM `synex_account_restrictions`
            WHERE `account_id` = ? AND `status` = 'active'
                AND `valid_from` <= CURRENT_TIMESTAMP(6)
                AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6))]], {
            account.id
        })
        for _, restriction in ipairs(restrictions) do
            if restriction.restriction_kind == 'all_blocked'
                or (amountDelta < 0 and restriction.restriction_kind == 'outgoing_blocked')
                or (amountDelta > 0 and restriction.restriction_kind == 'incoming_blocked') then
                return nil, domainError('ACCOUNT_RESTRICTED',
                    'An account restriction blocks the transaction.')
            end
        end
    end

    local policy = txOne(query, [[SELECT `minimum_balance_minor`, `maximum_balance_minor`,
            `single_transfer_limit_minor`, `daily_outgoing_limit_minor`, `operation_mode`
        FROM `synex_account_policies` WHERE `account_id` = ?]], { account.id })
    local nextBooked = bookedMinor + (amountDelta or 0)
    if nextBooked < -Foundation.MAX_MINOR or nextBooked > Foundation.MAX_MINOR then
        return nil, domainError('AMOUNT_OUT_OF_RANGE',
            'The transaction exceeds safe balance bounds.')
    end
    if amountDelta ~= nil and amountDelta < 0 and account.account_role == 'asset'
        and nextBooked < reservedMinor - releasedReservation then
        return nil, domainError('INSUFFICIENT_FUNDS',
            'Available account funds are insufficient.')
    end
    if not policy then return true, nil end

    local minimum = policy.minimum_balance_minor ~= nil
        and tonumber(policy.minimum_balance_minor) or nil
    local maximum = policy.maximum_balance_minor ~= nil
        and tonumber(policy.maximum_balance_minor) or nil
    local single = policy.single_transfer_limit_minor ~= nil
        and tonumber(policy.single_transfer_limit_minor) or nil
    local daily = policy.daily_outgoing_limit_minor ~= nil
        and tonumber(policy.daily_outgoing_limit_minor) or nil
    if amountDelta ~= nil and minimum and nextBooked < minimum then
        return nil, domainError('MINIMUM_BALANCE_VIOLATION',
            'The account minimum balance policy was violated.')
    end
    if amountDelta ~= nil and maximum and nextBooked > maximum then
        return nil, domainError('MAXIMUM_BALANCE_VIOLATION',
            'The account maximum balance policy was violated.')
    end
    if amountDelta ~= nil and single and amountDelta < 0 and math.abs(amountDelta) > single then
        return nil, domainError('TRANSFER_LIMIT_EXCEEDED',
            'The single transaction limit was exceeded.')
    end
    if amountDelta ~= nil and daily and amountDelta < 0 and account.account_role == 'asset' then
        local lockSuffix = lockDailyUsage == true and ' FOR UPDATE' or ''
        local usage = txOne(query, [[SELECT `outgoing_minor`
            FROM `synex_account_policy_daily_usage`
            WHERE `account_id` = ? AND `usage_date` = UTC_DATE()]] .. lockSuffix, {
            account.id
        })
        local outgoing = tonumber(usage and usage.outgoing_minor) or 0
        if outgoing + math.abs(amountDelta) > daily then
            return nil, domainError('DAILY_LIMIT_EXCEEDED',
                'The daily outgoing limit was exceeded.')
        end
    end
    if policy.operation_mode == 'allowlist' and not txOne(query,
        [[SELECT `operation_key` FROM `synex_account_policy_allowed_operations`
            WHERE `account_id` = ? AND `operation_key` = ?]], {
            account.id, operationKey
        }) then
        return nil, domainError('OPERATION_NOT_ALLOWED',
            'The account policy does not allow this operation.')
    end
    return true, nil
end

function Engine:evaluateAccess(query, account, authority, permission, options)
    if type(account) ~= 'table' or type(authority) ~= 'table'
        or not permissionCompatibility[permission] then
        return nil, domainError('ACCESS_CHECK_INVALID', 'The account access check is invalid.')
    end
    options = type(options) == 'table' and options or {}
    local explanation = {
        accountId = account.public_id,
        principalKind = authority.principalKind,
        principalRef = authority.principalRef,
        permission = permission,
        accountState = account.status,
        resourceCapability = options.resourceCapability ~= false,
        owner = false,
        grantActive = false,
        permissionGranted = false,
        allowed = false,
        reason = 'MISSING_ACCOUNT_PERMISSION',
    }
    if account.owner_kind == authority.principalKind and account.owner_ref == authority.principalRef then
        explanation.owner = true
        explanation.permissionGranted = true
        explanation.allowed = true
        explanation.reason = 'OWNER'
        return explanation, nil
    end
    local rows = txRows(query, [[SELECT `grant`.`public_id` AS `grant_id`, `grant`.`version`,
            `grant`.`valid_from`, `grant`.`valid_until`, `role`.`public_id` AS `role_id`,
            `role`.`role_key`, `permission`.`permission_key`
        FROM `synex_account_access_grants` AS `grant`
        INNER JOIN `synex_account_access_roles` AS `role`
            ON `role`.`id` = `grant`.`role_id` AND `role`.`account_id` = `grant`.`account_id`
        INNER JOIN `synex_account_access_role_permissions` AS `permission`
            ON `permission`.`role_id` = `role`.`id`
        WHERE `grant`.`account_id` = ? AND `grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?
            AND `grant`.`status` = 'active' AND `grant`.`active_marker` = 1
            AND `grant`.`valid_from` <= CURRENT_TIMESTAMP(6)
            AND (`grant`.`valid_until` IS NULL OR `grant`.`valid_until` > CURRENT_TIMESTAMP(6))
        ORDER BY `permission`.`permission_key` ASC]], {
        account.id, authority.principalKind, authority.principalRef
    })
    local compatible = permissionCompatibility[permission]
    for _, row in ipairs(rows) do
        explanation.grantActive = true
        explanation.grantId = row.grant_id
        explanation.grantVersion = tonumber(row.version)
        explanation.roleId = row.role_id
        explanation.roleKey = row.role_key
        if compatible[row.permission_key] then explanation.permissionGranted = true end
    end
    if explanation.permissionGranted then
        explanation.allowed = true
        explanation.reason = 'ROLE_PERMISSION'
    elseif not explanation.grantActive then
        explanation.reason = 'NO_ACTIVE_GRANT'
    end
    return explanation, nil
end

function Engine:requireAccess(query, account, authority, permission)
    local explanation, accessError = self:evaluateAccess(query, account, authority, permission)
    if not explanation then return nil, accessError end
    if not explanation.allowed then
        return nil, domainError('ACCOUNT_ACCESS_DENIED', 'Account access is denied.', false, {
            reason = explanation.reason, permission = permission
        })
    end
    return explanation, nil
end

function Engine:requireReason(query, reasonCode, authority, allowBuiltin)
    if not Domain.validReasonCode(reasonCode) then
        return nil, domainError('VALIDATION_FAILED', 'reason_code is invalid.')
    end
    local row = txOne(query, [[SELECT `reason_code`, `owner_resource`, `status`
        FROM `synex_account_reason_codes` WHERE `reason_code` = ?]], { reasonCode })
    if not row or row.status ~= 'active' then
        return nil, domainError('REASON_CODE_NOT_FOUND', 'The financial reason code is not active.')
    end
    if row.owner_resource ~= authority.callerResource
        and not (allowBuiltin == true and row.owner_resource == 'synex_accounts') then
        return nil, domainError('REASON_CODE_NOT_OWNED',
            'The calling resource does not own the financial reason code.')
    end
    return row, nil
end

function Engine:writeEvent(query, operationId, eventType, aggregateId, command, payload)
    if not Foundation.isUuid(aggregateId) then
        return nil, domainError('EVENT_AGGREGATE_INVALID', 'The financial event aggregate is invalid.')
    end
    local payloadJson, payloadError = encoded(payload)
    if not payloadJson then return nil, payloadError end
    local eventId = uuidV4(random)
    txRows(query, [[INSERT INTO `synex_account_audit`
        (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`,
            `source_resource`, `trace_id`, `reference_type`, `reference_id`, `actor_kind`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        eventId, operationId, eventType, aggregateId, command.authority.principalRef, payloadJson,
        command.authority.callerResource, command.authority.traceId, command.referenceType,
        command.referenceId, command.authority.principalKind
    })
    txRows(query, [[INSERT INTO `synex_account_outbox`
        (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`, `trace_id`)
        VALUES (?, ?, ?, 2, ?, ?)]], {
        eventId, aggregateId, eventType, payloadJson, command.authority.traceId
    })
    local legacy = legacyEvents[eventType]
    if legacy then
        txRows(query, [[INSERT INTO `synex_account_outbox`
            (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`, `trace_id`)
            VALUES (?, ?, ?, 1, ?, ?)]], {
            uuidV4(random), aggregateId, legacy, payloadJson, command.authority.traceId
        })
    end
    return eventId, nil
end

function Engine:appendSnapshot(query, account, sourceKind, sourceRef, bookedMinor)
    local reservation = txOne(query, [[SELECT COALESCE(SUM(`remaining_minor`), 0) AS `reserved_minor`
        FROM `synex_account_holds`
        WHERE `account_id` = ? AND `state` IN ('active', 'partially_captured')
            AND `expires_at` > CURRENT_TIMESTAMP(6)]], { account.id })
    local reserved = integer(reservation and reservation.reserved_minor, 0, Foundation.MAX_MINOR)
    if not reserved or bookedMinor < -Foundation.MAX_MINOR or bookedMinor > Foundation.MAX_MINOR then
        return nil, domainError('AMOUNT_OUT_OF_RANGE', 'The account snapshot exceeds safe integer bounds.')
    end
    txRows(query, [[INSERT INTO `synex_account_balance_snapshots`
        (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
        VALUES (?, ?, ?, ?, ?, ?)]], {
        account.id, account.sequence_no + 1, sourceKind, sourceRef, bookedMinor, reserved
    })
    account.sequence_no = account.sequence_no + 1
    account.booked_minor = bookedMinor
    account.reserved_minor = reserved
    account.available_minor = bookedMinor - reserved
    return account, nil
end

function Engine:publicAccount(account)
    return {
        account_id = account.public_id,
        currency_code = account.currency_code,
        minor_unit = tonumber(account.minor_unit),
        account_role = account.account_role,
        owner_kind = account.owner_kind,
        owner_ref = account.owner_ref,
        status = account.status,
        booked_minor = account.booked_minor,
        reserved_minor = account.reserved_minor,
        available_minor = account.available_minor,
        sequence = account.sequence_no,
        version = account.version,
        snapshot_created_at = tostring(account.snapshot_created_at or ''),
    }
end

context.engine = Engine
context.txRows = txRows
context.txOne = txOne
context.integer = integer
context.encoded = encoded
end
