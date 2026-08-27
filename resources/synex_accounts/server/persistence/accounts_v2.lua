return function(port, context)
local Foundation = context.foundation
local Engine = context.engine
local Domain = context.domain
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local txRows = context.txRows
local txOne = context.txOne

local ownerPermissions = {
    'access.manage', 'access.read', 'balance.read', 'close', 'deposit',
    'history.read', 'hold.capture', 'hold.create', 'hold.release',
    'settings.manage', 'transfer', 'withdraw'
}

local function accountReadState(accountId)
    local row = one([[SELECT `account`.`id`, `account`.`public_id`, `account`.`account_key`,
            `account`.`account_role`, `account`.`status`, `account`.`version`,
            `currency`.`currency_code`, `currency`.`minor_unit`, `currency`.`status` AS `currency_status`,
            `owner`.`owner_kind`, `owner`.`owner_ref`, `snapshot`.`sequence_no`,
            `snapshot`.`booked_minor`, `snapshot`.`created_at` AS `snapshot_created_at`,
            COALESCE((SELECT SUM(`hold`.`remaining_minor`) FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0) AS `reserved_minor`
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `account`.`currency_id`
        INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `account`.`public_id` = ?]], { accountId })
    if not row then return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.') end
    row.id = tonumber(row.id)
    row.booked_minor = tonumber(row.booked_minor)
    row.reserved_minor = tonumber(row.reserved_minor)
    row.available_minor = row.booked_minor and row.reserved_minor
        and row.booked_minor - row.reserved_minor or nil
    row.sequence_no = tonumber(row.sequence_no)
    row.version = tonumber(row.version)
    if not row.id or not row.booked_minor or not row.reserved_minor or not row.available_minor
        or not row.sequence_no or not row.version then
        return nil, domainError('DATABASE_RESULT_INVALID', 'The account read model is invalid.')
    end
    return row, nil
end

local function readAccess(account, authority, permission)
    local function query(sql, values) return many(sql, values) end
    return Engine:requireAccess(query, account, authority, permission)
end

function port:registerCurrencyV2(command)
    local currencyId = uuidV4(random)
    return Engine:mutation(command.operationName or 'currency_register', command, function(query, operationId)
        if txOne(query, [[SELECT `id` FROM `synex_currencies` WHERE `currency_code` = ? FOR UPDATE]],
            { command.currencyCode }) then
            return nil, domainError('CURRENCY_EXISTS', 'The currency code already exists.')
        end
        txRows(query, [[INSERT INTO `synex_currencies`
            (`public_id`, `currency_code`, `display_name`, `minor_unit`, `status`)
            VALUES (?, ?, ?, ?, 'active')]], {
            currencyId, command.currencyCode, command.displayName, command.minorUnit
        })
        local currency = txOne(query, [[SELECT `id` FROM `synex_currencies`
            WHERE `public_id` = ? FOR UPDATE]], { currencyId })
        txRows(query, [[INSERT INTO `synex_currency_system_topology`
            (`currency_id`, `topology_state`, `version`) VALUES (?, 'incomplete', 1)]], { currency.id })
        txRows(query, [[INSERT INTO `synex_economy_integrity_read_models`
            (`currency_id`, `model_version`, `cutoff_posting_id`, `transaction_count`, `posting_count`,
                `total_debit_minor`, `total_credit_minor`, `total_booked_minor`,
                `negative_asset_count`, `reserved_exceeds_booked_count`, `orphan_transaction_count`,
                `finding_count`, `status`, `generated_at`)
            VALUES (?, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 'healthy', CURRENT_TIMESTAMP(6))]], { currency.id })
        local response = {
            currency_id = currencyId,
            currency_code = command.currencyCode,
            display_name = command.displayName,
            minor_unit = command.minorUnit,
            status = 'active',
            topology_state = 'incomplete',
        }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.currency.registered', currencyId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:registerCurrency(command)
    command.operationName = 'register_currency'
    return self:registerCurrencyV2(command)
end

function port:getCurrency(identifier)
    local row = one([[SELECT `currency`.`public_id` AS `currency_id`, `currency`.`currency_code`,
            `currency`.`display_name`, `currency`.`minor_unit`, `currency`.`status`,
            `currency`.`precision_locked_at`, `topology`.`topology_state`,
            `mint`.`public_id` AS `mint_account_id`, `burn`.`public_id` AS `burn_account_id`
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `currency`.`id`
        LEFT JOIN `synex_accounts` AS `mint` ON `mint`.`id` = `topology`.`mint_account_id`
        LEFT JOIN `synex_accounts` AS `burn` ON `burn`.`id` = `topology`.`burn_account_id`
        WHERE `currency`.`currency_code` = ? OR `currency`.`public_id` = ?]], { identifier, identifier })
    if not row then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
    row.minor_unit = tonumber(row.minor_unit)
    row.precision_locked_at = row.precision_locked_at
        and tostring(row.precision_locked_at) or nil
    return row, nil
end

function port:listCurrencies(cursor, limit)
    limit = math.max(1, math.min(tonumber(limit) or 50, 100))
    local rows = many([[SELECT `currency`.`id`, `currency`.`public_id` AS `currency_id`,
            `currency`.`currency_code`, `currency`.`display_name`, `currency`.`minor_unit`,
            `currency`.`status`, `currency`.`precision_locked_at`,
            COALESCE(`topology`.`topology_state`, 'incomplete') AS `topology_state`
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `currency`.`id`
        WHERE `currency`.`id` > ? ORDER BY `currency`.`id` ASC LIMIT ?]], {
        tonumber(cursor) or 0, limit
    })
    local items = {}
    for index, row in ipairs(rows) do
        items[index] = {
            currency_id = row.currency_id, currency_code = row.currency_code,
            display_name = row.display_name, minor_unit = tonumber(row.minor_unit),
            status = row.status,
            precision_locked_at = row.precision_locked_at
                and tostring(row.precision_locked_at) or nil,
            topology_state = row.topology_state,
        }
    end
    return { items = items, next_cursor = #rows == limit and tostring(rows[#rows].id) or nil }, nil
end

function port:updateCurrency(command)
    return Engine:mutation('currency_update', command, function(query, operationId)
        local currency = txOne(query, [[SELECT * FROM `synex_currencies`
            WHERE `public_id` = ? FOR UPDATE]], { command.currencyId })
        if not currency then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        if command.minorUnit ~= nil and tonumber(currency.minor_unit) ~= command.minorUnit
            and currency.precision_locked_at ~= nil then
            return nil, domainError('CURRENCY_PRECISION_LOCKED',
                'Currency precision cannot change after financial state exists.')
        end
        txRows(query, [[UPDATE `synex_currencies` SET `display_name` = COALESCE(?, `display_name`),
                `minor_unit` = COALESCE(?, `minor_unit`), `status` = COALESCE(?, `status`)
            WHERE `id` = ?]], {
            command.displayName, command.minorUnit, command.status, currency.id
        })
        local response = {
            currency_id = command.currencyId,
            currency_code = currency.currency_code,
            display_name = command.displayName or currency.display_name,
            minor_unit = command.minorUnit or tonumber(currency.minor_unit),
            status = command.status or currency.status,
        }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.currency.updated', command.currencyId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:createAccountV2(command)
    local accountId, roleId, grantId = uuidV4(random), uuidV4(random), uuidV4(random)
    return Engine:mutation(command.operationName or 'account_create', command, function(query, operationId)
        if command.accountRole ~= 'asset'
            and (command.ownerKind ~= 'system'
                or command.ownerRef ~= command.authority.callerResource) then
            return nil, domainError('VALIDATION_FAILED',
                'Canonical currency system accounts require caller-owned system ownership.')
        end
        local currency = txOne(query, [[SELECT `id`, `currency_code`, `minor_unit`, `status`
            FROM `synex_currencies` WHERE `currency_code` = ? FOR UPDATE]], { command.currencyCode })
        if not currency then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        if currency.status ~= 'active' then
            return nil, domainError('CURRENCY_UNAVAILABLE', 'The currency is disabled.')
        end
        if command.accountKey and txOne(query, [[SELECT `id` FROM `synex_accounts`
            WHERE `currency_id` = ? AND `account_key` = ? FOR UPDATE]], {
            currency.id, command.accountKey
        }) then
            return nil, domainError('ACCOUNT_KEY_EXISTS', 'The currency account key already exists.')
        end
        local topology
        if command.accountRole == 'mint' or command.accountRole == 'burn' then
            topology = txOne(query, [[SELECT * FROM `synex_currency_system_topology`
                WHERE `currency_id` = ? FOR UPDATE]], { currency.id })
            if not topology then error('currency system topology is missing', 0) end
            local field = command.accountRole .. '_account_id'
            if topology[field] ~= nil then
                return nil, domainError('SYSTEM_ACCOUNT_EXISTS',
                    'The currency already has this system account role.')
            end
        end
        txRows(query, [[INSERT INTO `synex_accounts`
            (`public_id`, `currency_id`, `account_key`, `account_role`, `allow_negative`,
                `status`, `metadata_json`, `version`)
            VALUES (?, ?, ?, ?, ?, 'active', ?, 1)]], {
            accountId, currency.id, command.accountKey, command.accountRole,
            command.accountRole == 'mint' and 1 or 0, command.metadataJson or '{}'
        })
        local account = txOne(query, [[SELECT `id` FROM `synex_accounts`
            WHERE `public_id` = ? FOR UPDATE]], { accountId })
        txRows(query, [[INSERT INTO `synex_account_owners` (`account_id`, `owner_kind`, `owner_ref`)
            VALUES (?, ?, ?)]], { account.id, command.ownerKind, command.ownerRef })
        txRows(query, [[INSERT INTO `synex_account_balance_snapshots`
            (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
            VALUES (?, 0, 'opening', ?, 0, 0)]], { account.id, accountId })
        txRows(query, [[INSERT INTO `synex_account_access_roles`
            (`public_id`, `account_id`, `role_key`, `display_name`, `version`)
            VALUES (?, ?, 'owner', 'Owner', 1)]], { roleId, account.id })
        local role = txOne(query, [[SELECT `id` FROM `synex_account_access_roles`
            WHERE `public_id` = ? FOR UPDATE]], { roleId })
        for _, permission in ipairs(ownerPermissions) do
            txRows(query, [[INSERT INTO `synex_account_access_role_permissions`
                (`role_id`, `permission_key`) VALUES (?, ?)]], { role.id, permission })
        end
        txRows(query, [[INSERT INTO `synex_account_access_grants`
            (`public_id`, `account_id`, `role_id`, `principal_kind`, `principal_ref`,
                `status`, `active_marker`, `valid_from`, `valid_until`, `granted_by_ref`, `version`)
            VALUES (?, ?, ?, ?, ?, 'active', 1, CURRENT_TIMESTAMP(6), NULL, ?, 1)]], {
            grantId, account.id, role.id, command.ownerKind, command.ownerRef,
            command.authority.callerResource
        })
        txRows(query, [[INSERT INTO `synex_account_policies`
            (`account_id`, `operation_id`, `operation_mode`, `reason_code`, `source_resource`,
                `trace_id`, `actor_kind`, `actor_ref`, `version`)
            VALUES (?, ?, 'all', 'synex_accounts.policy', ?, ?, ?, ?, 1)]], {
            account.id, operationId, command.authority.callerResource, command.authority.traceId,
            command.authority.principalKind, command.authority.principalRef
        })
        if topology then
            local field = command.accountRole == 'mint' and 'mint_account_id' or 'burn_account_id'
            local sql = ([[UPDATE `synex_currency_system_topology` SET `%s` = ?,
                    `topology_state` = CASE WHEN `%s` IS NOT NULL THEN 'ready' ELSE 'incomplete' END,
                    `version` = `version` + 1, `updated_at` = CURRENT_TIMESTAMP(6)
                WHERE `currency_id` = ?]]):format(field,
                    command.accountRole == 'mint' and 'burn_account_id' or 'mint_account_id')
            txRows(query, sql, { account.id, currency.id })
        end
        local response = {
            account_id = accountId,
            currency_code = command.currencyCode,
            account_role = command.accountRole,
            owner_kind = command.ownerKind,
            owner_ref = command.ownerRef,
            status = 'active',
            booked_minor = 0,
            reserved_minor = 0,
            available_minor = 0,
            sequence = 0,
        }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.account.created', accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:createAccount(command)
    command.operationName = 'create'
    return self:createAccountV2(command)
end

function port:getAccount(accountId, authority, permission)
    local account, accountError = accountReadState(accountId)
    if not account then return nil, accountError end
    local _, accessError = readAccess(account, authority, permission or 'balance.read')
    if accessError then return nil, accessError end
    return Engine:publicAccount(account), nil
end

function port:getSnapshot(accountId, authority)
    return self:getAccount(accountId, authority, 'balance.read')
end

function port:getBalanceAt(accountId, at, authority)
    local account, accountError = accountReadState(accountId)
    if not account then return nil, accountError end
    local _, accessError = readAccess(account, authority, 'history.read')
    if accessError then return nil, accessError end
    local snapshot = one([[SELECT `sequence_no`, `booked_minor`, `reserved_minor`, `created_at`
        FROM `synex_account_balance_snapshots`
        WHERE `account_id` = ? AND `created_at` <= ?
        ORDER BY `created_at` DESC, `sequence_no` DESC LIMIT 1]], { account.id, at })
    if not snapshot then
        return nil, domainError('BALANCE_HISTORY_NOT_FOUND', 'No balance snapshot exists at that time.')
    end
    local booked, reserved = tonumber(snapshot.booked_minor), tonumber(snapshot.reserved_minor)
    return {
        account_id = accountId,
        at = tostring(at),
        snapshot_created_at = tostring(snapshot.created_at),
        booked_minor = booked,
        reserved_minor = reserved,
        available_minor = booked - reserved,
        sequence = tonumber(snapshot.sequence_no),
    }, nil
end

function port:listOwnerAccountsV2(ownerKind, ownerRef, authority, cursor, limit)
    if authority.principalKind ~= ownerKind or authority.principalRef ~= ownerRef then
        return nil, domainError('ACCOUNT_ACCESS_DENIED', 'Owner account discovery is denied.')
    end
    limit = math.max(1, math.min(tonumber(limit) or 50, 50))
    local rows = many([[SELECT `account`.`id`, `account`.`public_id`,
            `account`.`account_role`, `account`.`status`, `account`.`version`,
            `currency`.`currency_code`, `currency`.`minor_unit`,
            `owner`.`owner_kind`, `owner`.`owner_ref`, `snapshot`.`sequence_no`,
            `snapshot`.`booked_minor`, `snapshot`.`created_at` AS `snapshot_created_at`,
            COALESCE((SELECT SUM(`hold`.`remaining_minor`)
                FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0) AS `reserved_minor`
        FROM `synex_account_owners` AS `owner`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `owner`.`account_id`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `account`.`currency_id`
        INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ? AND `account`.`id` > ?
        ORDER BY `account`.`id` ASC LIMIT ?]], { ownerKind, ownerRef, tonumber(cursor) or 0, limit })
    local items = {}
    for _, row in ipairs(rows) do
        row.booked_minor = tonumber(row.booked_minor)
        row.reserved_minor = tonumber(row.reserved_minor)
        row.available_minor = row.booked_minor and row.reserved_minor
            and row.booked_minor - row.reserved_minor or nil
        row.sequence_no = tonumber(row.sequence_no)
        row.version = tonumber(row.version)
        if row.booked_minor == nil or row.reserved_minor == nil or row.available_minor == nil
            or row.sequence_no == nil or row.version == nil then
            return nil, domainError('DATABASE_RESULT_INVALID', 'An owner account read model is invalid.')
        end
        items[#items + 1] = Engine:publicAccount(row)
    end
    return { items = items, next_cursor = #rows == limit and tostring(rows[#rows].id) or nil }, nil
end

function port:listOwnerAccounts(ownerKind, ownerRef, authority)
    return self:listOwnerAccountsV2(ownerKind, ownerRef, authority, nil, 50)
end

local function changeStatus(portInstance, command, targetStatus)
    return Engine:mutation(command.operationName, command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query, { command.accountId })
        if not accounts then return nil, accountError end
        local account = accounts[command.accountId]
        local permission = targetStatus == 'closed' and 'close' or 'settings.manage'
        local _, accessError = Engine:requireAccess(query, account, command.authority, permission)
        if accessError then return nil, accessError end
        if command.expectedVersion ~= account.version then
            return nil, domainError('STALE_VERSION', 'The account version changed.', true)
        end
        if targetStatus == 'closed' then
            local closable, closureError = Engine:evaluateAccountClosure(query, account)
            if not closable then return nil, closureError end
        end
        local validTransition = (targetStatus == 'frozen' and account.status == 'active')
            or (targetStatus == 'active' and account.status == 'frozen')
            or (targetStatus == 'closed' and account.status ~= 'closed')
        if not validTransition then
            return nil, domainError('ACCOUNT_STATE_INVALID', 'The account status transition is invalid.')
        end
        txRows(query, [[UPDATE `synex_accounts` SET `status` = ?, `version` = `version` + 1,
                `closed_at` = CASE WHEN ? = 'closed' THEN CURRENT_TIMESTAMP(6) ELSE NULL END
            WHERE `id` = ? AND `version` = ?]], {
            targetStatus, targetStatus, account.id, account.version
        })
        local response = { account_id = command.accountId, previous_status = account.status,
            status = targetStatus, version = account.version + 1 }
        local eventType = targetStatus == 'active' and 'synex.accounts.account.unfrozen'
            or 'synex.accounts.account.' .. targetStatus
        local _, eventError = Engine:writeEvent(query, operationId, eventType,
            command.accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:freezeAccount(command) command.operationName = 'account_freeze' return changeStatus(self, command, 'frozen') end
function port:unfreezeAccount(command) command.operationName = 'account_unfreeze' return changeStatus(self, command, 'active') end
function port:closeAccount(command) command.operationName = 'account_close' return changeStatus(self, command, 'closed') end

function port:getPolicy(accountId, authority)
    local account, accountError = accountReadState(accountId)
    if not account then return nil, accountError end
    local _, accessError = readAccess(account, authority, 'settings.manage')
    if accessError then return nil, accessError end
    local policy = one([[SELECT `minimum_balance_minor`, `maximum_balance_minor`,
            `single_transfer_limit_minor`, `daily_outgoing_limit_minor`, `operation_mode`, `version`
        FROM `synex_account_policies` WHERE `account_id` = ?]], { account.id })
    local operationRows = many([[SELECT `operation_key` FROM `synex_account_policy_allowed_operations`
        WHERE `account_id` = ? ORDER BY `operation_key` ASC]], { account.id })
    local allowedOperations = {}
    for index, row in ipairs(operationRows) do allowedOperations[index] = row.operation_key end
    return {
        account_id = accountId,
        minimum_balance_minor = policy and tonumber(policy.minimum_balance_minor) or nil,
        maximum_balance_minor = policy and tonumber(policy.maximum_balance_minor) or nil,
        single_transfer_limit_minor = policy and tonumber(policy.single_transfer_limit_minor) or nil,
        daily_outgoing_limit_minor = policy and tonumber(policy.daily_outgoing_limit_minor) or nil,
        operation_mode = policy and policy.operation_mode or 'all',
        allowed_operations = allowedOperations,
        version = policy and tonumber(policy.version) or 1,
    }, nil
end

function port:setPolicy(command)
    return Engine:mutation('policy_set', command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query, { command.accountId })
        if not accounts then return nil, accountError end
        local account = accounts[command.accountId]
        local _, accessError = Engine:requireAccess(query, account, command.authority, 'settings.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        local _, reasonError = Engine:requireReason(query, command.reasonCode,
            command.authority, command.allowBuiltinReason)
        if reasonError then return nil, reasonError end
        local policy = txOne(query, [[SELECT `version` FROM `synex_account_policies`
            WHERE `account_id` = ? FOR UPDATE]], { account.id })
        if not policy or tonumber(policy.version) ~= command.expectedVersion then
            return nil, domainError('STALE_VERSION', 'The account policy version changed.', true)
        end
        txRows(query, [[UPDATE `synex_account_policies`
            SET `minimum_balance_minor` = ?, `maximum_balance_minor` = ?,
                `single_transfer_limit_minor` = ?, `daily_outgoing_limit_minor` = ?,
                `operation_mode` = ?, `operation_id` = ?, `reason_code` = ?,
                `source_resource` = ?, `trace_id` = ?, `actor_kind` = ?, `actor_ref` = ?,
                `version` = `version` + 1,
                `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `account_id` = ? AND `version` = ?]], {
            command.minimumBalanceMinor, command.maximumBalanceMinor,
            command.singleTransferLimitMinor, command.dailyOutgoingLimitMinor,
            command.operationMode, operationId, command.reasonCode,
            command.authority.callerResource, command.authority.traceId,
            command.authority.principalKind, command.authority.principalRef,
            account.id, command.expectedVersion
        })
        txRows(query, [[DELETE FROM `synex_account_policy_allowed_operations`
            WHERE `account_id` = ?]], { account.id })
        for _, operation in ipairs(command.allowedOperations or {}) do
            txRows(query, [[INSERT INTO `synex_account_policy_allowed_operations`
                (`account_id`, `operation_key`) VALUES (?, ?)]], { account.id, operation })
        end
        local response = {
            account_id = command.accountId,
            minimum_balance_minor = command.minimumBalanceMinor,
            maximum_balance_minor = command.maximumBalanceMinor,
            single_transfer_limit_minor = command.singleTransferLimitMinor,
            daily_outgoing_limit_minor = command.dailyOutgoingLimitMinor,
            operation_mode = command.operationMode,
            allowed_operations = command.allowedOperations or {},
            version = command.expectedVersion + 1,
        }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.policy.updated', command.accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:registerReason(command)
    return Engine:mutation('reason_register', command, function(query, operationId)
        if not Domain.validReasonCode(command.reasonCode)
            or command.reasonCode:sub(1, #command.authority.callerResource + 1)
                ~= command.authority.callerResource .. '.' then
            return nil, domainError('REASON_CODE_NAMESPACE_INVALID',
                'A reason code must be owned by the calling resource namespace.')
        end
        if txOne(query, [[SELECT `reason_code` FROM `synex_account_reason_codes`
            WHERE `reason_code` = ? FOR UPDATE]], { command.reasonCode }) then
            return nil, domainError('REASON_CODE_EXISTS', 'The reason code already exists.')
        end
        txRows(query, [[INSERT INTO `synex_account_reason_codes`
            (`reason_code`, `owner_resource`, `display_name`, `description`, `status`)
            VALUES (?, ?, ?, ?, 'active')]], {
            command.reasonCode, command.authority.callerResource,
            command.displayName, command.description
        })
        local response = { reason_code = command.reasonCode,
            owner_resource = command.authority.callerResource, display_name = command.displayName,
            description = command.description, status = 'active' }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.reason.registered', uuidV4(random), command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:getReason(reasonCode)
    local row = one([[SELECT `reason_code`, `owner_resource`,
            `display_name`, `description`, `status`, `created_at`, `updated_at`
        FROM `synex_account_reason_codes` WHERE `reason_code` = ?]], { reasonCode })
    if not row then return nil, domainError('REASON_CODE_NOT_FOUND', 'The reason code does not exist.') end
    row.created_at = row.created_at and tostring(row.created_at) or nil
    row.updated_at = row.updated_at and tostring(row.updated_at) or nil
    return row, nil
end

function port:listReasons(ownerResource, cursor, limit)
    limit = math.max(1, math.min(tonumber(limit) or 50, 100))
    local rows = many([[SELECT `reason_code`, `owner_resource`,
            `display_name`, `description`, `status`
        FROM `synex_account_reason_codes`
        WHERE `owner_resource` = ? AND `reason_code` > ? ORDER BY `reason_code` ASC LIMIT ?]], {
        ownerResource, type(cursor) == 'string' and cursor or '', limit
    })
    local items = {}
    for index, row in ipairs(rows) do
        items[index] = { reason_code = row.reason_code,
            owner_resource = row.owner_resource, display_name = row.display_name,
            description = row.description, status = row.status }
    end
    return { items = items, next_cursor = #rows == limit and rows[#rows].reason_code or nil }, nil
end

end
