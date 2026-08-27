return function(port, context)
local Foundation = context.foundation
local Engine = context.engine
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local txRows = context.txRows
local txOne = context.txOne

local function permissionList(query, roleInternalId)
    local rows = txRows(query, [[SELECT `permission_key`
        FROM `synex_account_access_role_permissions`
        WHERE `role_id` = ? ORDER BY `permission_key` ASC]], { roleInternalId })
    local result = {}
    for index, row in ipairs(rows) do result[index] = row.permission_key end
    return result
end

function port:createAccessRoleV2(command)
    local roleId = uuidV4(random)
    return Engine:mutation(command.operationName or 'access_role_create', command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query, { command.accountId })
        if not accounts then return nil, accountError end
        local account = accounts[command.accountId]
        local _, accessError = Engine:requireAccess(query, account, command.authority, 'access.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        if txOne(query, [[SELECT `id` FROM `synex_account_access_roles`
            WHERE `account_id` = ? AND `role_key` = ? FOR UPDATE]], {
            account.id, command.roleKey
        }) then
            return nil, domainError('ACCESS_ROLE_EXISTS', 'The account access role already exists.')
        end
        txRows(query, [[INSERT INTO `synex_account_access_roles`
            (`public_id`, `account_id`, `role_key`, `display_name`, `version`)
            VALUES (?, ?, ?, ?, 1)]], { roleId, account.id, command.roleKey, command.displayName })
        local role = txOne(query, [[SELECT `id` FROM `synex_account_access_roles`
            WHERE `public_id` = ? FOR UPDATE]], { roleId })
        for _, permission in ipairs(command.permissions) do
            txRows(query, [[INSERT INTO `synex_account_access_role_permissions`
                (`role_id`, `permission_key`) VALUES (?, ?)]], { role.id, permission })
        end
        local response = { role_id = roleId, account_id = command.accountId,
            role_key = command.roleKey, display_name = command.displayName,
            permissions = command.permissions, version = 1 }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.access.role.created', command.accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:createAccessRole(command)
    command.operationName = 'create_access_role'
    return self:createAccessRoleV2(command)
end

function port:grantAccessV2(command)
    local grantId = uuidV4(random)
    return Engine:mutation(command.operationName or 'access_grant', command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query, { command.accountId })
        if not accounts then return nil, accountError end
        local account = accounts[command.accountId]
        local _, accessError = Engine:requireAccess(query, account, command.authority, 'access.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        local role = txOne(query, [[SELECT `id`, `public_id`, `role_key` FROM `synex_account_access_roles`
            WHERE `public_id` = ? AND `account_id` = ? FOR UPDATE]], { command.roleId, account.id })
        if not role then return nil, domainError('ACCESS_ROLE_NOT_FOUND', 'The account access role does not exist.') end
        local active = txOne(query, [[SELECT `id` FROM `synex_account_access_grants`
            WHERE `account_id` = ? AND `principal_kind` = ? AND `principal_ref` = ?
                AND `status` = 'active' AND `active_marker` = 1 FOR UPDATE]], {
            account.id, command.principalKind, command.principalRef
        })
        if active then return nil, domainError('ACCESS_GRANT_EXISTS', 'The principal already has an active account grant.') end
        txRows(query, [[INSERT INTO `synex_account_access_grants`
            (`public_id`, `account_id`, `role_id`, `principal_kind`, `principal_ref`,
                `status`, `active_marker`, `valid_from`, `valid_until`, `granted_by_ref`, `version`)
            VALUES (?, ?, ?, ?, ?, 'active', 1,
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                CASE WHEN ? = 0 THEN NULL
                    ELSE TIMESTAMPADD(SECOND, ? + ?, CURRENT_TIMESTAMP(6)) END,
                ?, 1)]], {
            grantId, account.id, role.id, command.principalKind, command.principalRef,
            command.validFromSeconds or 0, command.validForSeconds or 0,
            command.validFromSeconds or 0, command.validForSeconds or 0,
            command.authority.callerResource
        })
        local response = { grant_id = grantId, account_id = command.accountId,
            role_id = command.roleId, principal_kind = command.principalKind,
            principal_ref = command.principalRef, status = 'active', version = 1,
            valid_from_seconds = command.validFromSeconds or 0,
            valid_for_seconds = command.validForSeconds }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.access.granted', command.accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:grantAccess(command)
    command.operationName = 'grant_access'
    command.validFromSeconds = command.validFromSeconds or 0
    local response, responseError = self:grantAccessV2(command)
    if not response then return nil, responseError end
    return {
        grant_id = response.grant_id, account_id = response.account_id,
        role_id = response.role_id, principal_kind = response.principal_kind,
        principal_ref = response.principal_ref, status = response.status,
        version = response.version, valid_for_seconds = response.valid_for_seconds,
    }, nil
end

function port:revokeAccessV2(command)
    return Engine:mutation(command.operationName or 'access_revoke', command, function(query, operationId)
        local grant = txOne(query, [[SELECT `grant`.*, `account`.`public_id` AS `account_public_id`,
                `role`.`public_id` AS `role_public_id`
            FROM `synex_account_access_grants` AS `grant`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `grant`.`account_id`
            INNER JOIN `synex_account_access_roles` AS `role` ON `role`.`id` = `grant`.`role_id`
            WHERE `grant`.`public_id` = ? FOR UPDATE]], { command.grantId })
        if not grant then return nil, domainError('ACCESS_GRANT_NOT_FOUND', 'The account access grant does not exist.') end
        if grant.status ~= 'active' then
            return nil, domainError('ACCESS_GRANT_INACTIVE', 'The account access grant is not active.')
        end
        if command.expectedVersion and tonumber(grant.version) ~= command.expectedVersion then
            return nil, domainError('STALE_VERSION', 'The access grant version changed.', true)
        end
        local accounts, accountError = Engine:loadAccounts(query, { grant.account_public_id })
        if not accounts then return nil, accountError end
        local account = accounts[grant.account_public_id]
        local _, accessError = Engine:requireAccess(query, account,
            command.authority, 'access.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        txRows(query, [[UPDATE `synex_account_access_grants`
            SET `status` = 'revoked', `active_marker` = NULL, `revoked_by_ref` = ?,
                `revocation_reason` = ?, `revoked_at` = CURRENT_TIMESTAMP(6),
                `version` = `version` + 1
            WHERE `id` = ? AND `status` = 'active' AND `version` = ?]], {
            command.authority.callerResource, command.reason, grant.id, grant.version
        })
        local response = { grant_id = command.grantId, account_id = grant.account_public_id,
            role_id = grant.role_public_id, principal_kind = grant.principal_kind,
            principal_ref = grant.principal_ref, status = 'revoked',
            version = tonumber(grant.version) + 1 }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.access.revoked', grant.account_public_id, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:revokeAccess(command)
    command.operationName = 'revoke_access'
    return self:revokeAccessV2(command)
end

local function accountStateForAccess(accountId)
    local row = one([[SELECT `account`.`id`, `account`.`public_id`, `account`.`account_role`,
            `account`.`status`,
            `owner`.`owner_kind`, `owner`.`owner_ref`, `snapshot`.`booked_minor`,
            COALESCE((SELECT SUM(`hold`.`remaining_minor`) FROM `synex_account_holds` AS `hold`
                WHERE `hold`.`account_id` = `account`.`id`
                    AND `hold`.`state` IN ('active', 'partially_captured')
                    AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)), 0) AS `reserved_minor`
        FROM `synex_accounts` AS `account`
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
    row.available_minor = row.booked_minor - row.reserved_minor
    return row, nil
end

function port:checkAccess(command)
    local account, accountError = accountStateForAccess(command.accountId)
    if not account then return nil, accountError end
    local function query(sql, values) return many(sql, values) end
    if command.authority then
        local _, callerError = Engine:requireAccess(query, account, command.authority, 'access.read')
        if callerError then return nil, callerError end
    end
    local target = { principalKind = command.principalKind, principalRef = command.principalRef }
    local explanation, accessError = Engine:evaluateAccess(query, account, target,
        command.permission, { resourceCapability = command.resourceCapability })
    if not explanation then return nil, accessError end
    local frozenOperationAllowed = command.operation == 'balance.read'
        or command.operation == 'history.read' or command.operation == 'access.read'
        or command.operation == 'access.manage' or command.operation == 'settings.manage'
        or command.operation == 'close' or command.operation == 'hold.release'
        or command.operation == 'reversal' or command.operation == 'refund'
    if command.resourceCapability == false then
        explanation.allowed = false
        explanation.reason = 'RESOURCE_CAPABILITY_DENIED'
    elseif account.status == 'closed' then
        explanation.allowed = false
        explanation.reason = 'ACCOUNT_CLOSED'
    elseif account.status == 'frozen' and not frozenOperationAllowed then
        explanation.allowed = false
        explanation.reason = 'ACCOUNT_FROZEN'
    end
    if explanation.allowed and command.preflightRequired == true then
        if command.amountRequired == true and command.amountMinor == nil then
            explanation.allowed = false
            explanation.reason = 'PREFLIGHT_AMOUNT_REQUIRED'
        elseif command.amountRequired == true and command.direction == nil then
            explanation.allowed = false
            explanation.reason = 'PREFLIGHT_DIRECTION_REQUIRED'
        else
            local delta = command.amountMinor and (command.direction == 'outgoing'
                and -command.amountMinor or command.amountMinor) or nil
            local release = command.operation == 'hold.capture'
                and command.amountMinor or 0
            local permitted, policyError = Engine:evaluateAccountOperation(query,
                account, command.operation, delta, release, false)
            if not permitted then
                explanation.allowed = false
                explanation.reason = policyError.code
            end
        end
    end
    if explanation.allowed and command.operation == 'close' then
        local closable, closureError = Engine:evaluateAccountClosure(query, account)
        if not closable then
            explanation.allowed = false
            explanation.reason = closureError.code
        end
    end
    explanation.bookedMinor = account.booked_minor
    explanation.reservedMinor = account.reserved_minor
    explanation.availableMinor = account.available_minor
    return explanation, nil
end

function port:getAccess(accountId, principalKind, principalRef, authority)
    local command = { accountId = accountId, principalKind = principalKind,
        principalRef = principalRef, permission = 'balance.read', authority = authority }
    local summary, summaryError = self:checkAccess(command)
    if not summary then return nil, summaryError end
    local rows = many([[SELECT `grant`.`public_id` AS `grant_id`, `grant`.`version` AS `grant_version`,
            `grant`.`valid_from`, `grant`.`valid_until`, `role`.`public_id` AS `role_id`,
            `role`.`role_key`, `role`.`display_name` AS `role_display_name`,
            `permission`.`permission_key`
        FROM `synex_account_access_grants` AS `grant`
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `grant`.`account_id`
        INNER JOIN `synex_account_access_roles` AS `role` ON `role`.`id` = `grant`.`role_id`
        INNER JOIN `synex_account_access_role_permissions` AS `permission`
            ON `permission`.`role_id` = `role`.`id`
        WHERE `account`.`public_id` = ? AND `grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?
            AND `grant`.`status` = 'active' AND `grant`.`active_marker` = 1
            AND `grant`.`valid_from` <= CURRENT_TIMESTAMP(6)
            AND (`grant`.`valid_until` IS NULL OR `grant`.`valid_until` > CURRENT_TIMESTAMP(6))
        ORDER BY `permission`.`permission_key` ASC]], { accountId, principalKind, principalRef })
    local permissions = {}
    for _, row in ipairs(rows) do permissions[#permissions + 1] = row.permission_key end
    local first = rows[1]
    return {
        account_id = accountId, principal_kind = principalKind, principal_ref = principalRef,
        granted = summary.owner or first ~= nil,
        grant_id = first and first.grant_id or nil,
        grant_version = first and tonumber(first.grant_version) or nil,
        role_id = first and first.role_id or nil, role_key = first and first.role_key or (summary.owner and 'owner' or nil),
        role_display_name = first and first.role_display_name or (summary.owner and 'Owner' or nil),
        valid_until = first and first.valid_until and tostring(first.valid_until) or nil,
        permissions = permissions,
    }, nil
end

end
