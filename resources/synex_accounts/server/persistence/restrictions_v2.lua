return function(port, context)
local Engine = context.engine
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local update = context.update
local txRows = context.txRows
local txOne = context.txOne

local function publicRestriction(row, effectiveStatus)
    return {
        restriction_id = row.public_id,
        account_id = row.account_public_id or row.account_id,
        restriction_kind = row.restriction_kind,
        status = effectiveStatus or row.status,
        reason_code = row.reason_code,
        reason_text = row.reason_text,
        source_resource = row.source_resource,
        trace_id = row.trace_id,
        actor_kind = row.actor_kind,
        actor_ref = row.actor_ref,
        valid_from = tostring(row.valid_from),
        valid_until = row.valid_until and tostring(row.valid_until) or nil,
        version = tonumber(row.version),
        terminal_at = row.terminal_at and tostring(row.terminal_at) or nil,
        termination_reason = row.termination_reason,
    }
end

function port:createRestriction(command)
    local restrictionId = uuidV4(random)
    return Engine:mutation('restriction_create', command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query, { command.accountId })
        if not accounts then return nil, accountError end
        local account = accounts[command.accountId]
        local _, accessError = Engine:requireAccess(query, account,
            command.authority, 'settings.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        local _, reasonError = Engine:requireReason(query, command.reasonCode,
            command.authority, command.allowBuiltinReason)
        if reasonError then return nil, reasonError end
        if txOne(query, [[SELECT `id` FROM `synex_account_restrictions`
            WHERE `account_id` = ? AND `restriction_kind` = ?
                AND `status` = 'active' AND `active_marker` = 1 FOR UPDATE]], {
            account.id, command.restrictionKind
        }) then
            return nil, domainError('ACCOUNT_RESTRICTION_EXISTS',
                'An active restriction of this kind already exists.')
        end
        txRows(query, [[INSERT INTO `synex_account_restrictions`
            (`public_id`, `operation_id`, `account_id`, `restriction_kind`, `status`,
                `active_marker`, `reason_code`, `reason_text`, `source_resource`, `trace_id`,
                `actor_kind`, `actor_ref`, `valid_from`, `valid_until`, `version`)
            VALUES (?, ?, ?, ?, 'active', 1, ?, ?, ?, ?, ?, ?,
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                CASE WHEN ? = 0 THEN NULL
                    ELSE TIMESTAMPADD(SECOND, ? + ?, CURRENT_TIMESTAMP(6)) END, 1)]], {
            restrictionId, operationId, account.id, command.restrictionKind,
            command.reasonCode, command.reasonText, command.authority.callerResource,
            command.authority.traceId, command.authority.principalKind,
            command.authority.principalRef, command.validFromSeconds or 0,
            command.validForSeconds or 0, command.validFromSeconds or 0,
            command.validForSeconds or 0
        })
        local inserted = txOne(query, [[SELECT `restriction`.*,
                `account`.`public_id` AS `account_public_id`
            FROM `synex_account_restrictions` AS `restriction`
            INNER JOIN `synex_accounts` AS `account`
                ON `account`.`id` = `restriction`.`account_id`
            WHERE `restriction`.`public_id` = ? FOR UPDATE]], { restrictionId })
        if not inserted then error('account restriction insert was not visible', 0) end
        local response = publicRestriction(inserted)
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.restriction.created', command.accountId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:revokeRestriction(command)
    return Engine:mutation('restriction_revoke', command, function(query, operationId)
        local restriction = txOne(query, [[SELECT `restriction`.*,
                `account`.`public_id` AS `account_public_id`
            FROM `synex_account_restrictions` AS `restriction`
            INNER JOIN `synex_accounts` AS `account`
                ON `account`.`id` = `restriction`.`account_id`
            WHERE `restriction`.`public_id` = ? FOR UPDATE]], { command.restrictionId })
        if not restriction then
            return nil, domainError('ACCOUNT_RESTRICTION_NOT_FOUND',
                'The account restriction does not exist.')
        end
        if restriction.status ~= 'active' then
            return nil, domainError('ACCOUNT_RESTRICTION_INACTIVE',
                'The account restriction is already terminal.')
        end
        if command.expectedVersion and tonumber(restriction.version) ~= command.expectedVersion then
            return nil, domainError('STALE_VERSION', 'The account restriction version changed.', true)
        end
        local accounts, accountError = Engine:loadAccounts(query,
            { restriction.account_public_id })
        if not accounts then return nil, accountError end
        local account = accounts[restriction.account_public_id]
        local _, accessError = Engine:requireAccess(query,
            account, command.authority, 'settings.manage')
        if accessError then return nil, accessError end
        local _, mutableError = Engine:requireMutableAccount(account)
        if mutableError then return nil, mutableError end
        local _, reasonError = Engine:requireReason(query, command.reasonCode,
            command.authority, command.allowBuiltinReason)
        if reasonError then return nil, reasonError end
        txRows(query, [[UPDATE `synex_account_restrictions`
            SET `status` = 'revoked', `active_marker` = NULL,
                `terminal_at` = CURRENT_TIMESTAMP(6), `termination_reason` = ?,
                `version` = `version` + 1, `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `id` = ? AND `status` = 'active' AND `version` = ?]], {
            command.reasonText, restriction.id, restriction.version
        })
        restriction.status = 'revoked'
        restriction.version = tonumber(restriction.version) + 1
        restriction.terminal_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
        restriction.termination_reason = command.reasonText
        local response = publicRestriction(restriction)
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.restriction.revoked', restriction.account_public_id,
            command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:getRestriction(restrictionId, authority)
    local row = one([[SELECT `restriction`.*,
            `account`.`id` AS `account_internal_id`,
            `account`.`public_id` AS `account_public_id`,
            `account`.`status` AS `account_status`,
            `owner`.`owner_kind`, `owner`.`owner_ref`
        FROM `synex_account_restrictions` AS `restriction`
        INNER JOIN `synex_accounts` AS `account`
            ON `account`.`id` = `restriction`.`account_id`
        INNER JOIN `synex_account_owners` AS `owner`
            ON `owner`.`account_id` = `account`.`id`
        WHERE `restriction`.`public_id` = ?]], { restrictionId })
    if not row then
        return nil, domainError('ACCOUNT_RESTRICTION_NOT_FOUND',
            'The account restriction does not exist.')
    end
    local query = function(sql, values) return many(sql, values) end
    local account = { id = tonumber(row.account_internal_id), public_id = row.account_public_id,
        status = row.account_status, owner_kind = row.owner_kind, owner_ref = row.owner_ref }
    local _, accessError = Engine:requireAccess(query, account, authority, 'settings.manage')
    if accessError then return nil, accessError end
    local status = row.status
    if status == 'active' and row.valid_until ~= nil then
        local expired = one([[SELECT (? <= CURRENT_TIMESTAMP(6)) AS `expired`]], { row.valid_until })
        if tonumber(expired and expired.expired) == 1 then status = 'expired' end
    end
    return publicRestriction(row, status), nil
end

function port:listRestrictions(accountId, authority, cursor, limit, status)
    local accounts, accountError = self:getAccount(accountId, authority, 'settings.manage')
    if not accounts then return nil, accountError end
    limit = math.max(1, math.min(tonumber(limit) or 50, 50))
    local rows = many([[SELECT `restriction`.*,
            `account`.`public_id` AS `account_public_id`,
            CASE WHEN `restriction`.`status` = 'active'
                    AND `restriction`.`valid_until` IS NOT NULL
                    AND `restriction`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN 'expired' ELSE `restriction`.`status` END AS `effective_status`
        FROM `synex_account_restrictions` AS `restriction`
        INNER JOIN `synex_accounts` AS `account`
            ON `account`.`id` = `restriction`.`account_id`
        WHERE `account`.`public_id` = ? AND `restriction`.`id` > ?
            AND (? IS NULL OR ? = CASE WHEN `restriction`.`status` = 'active'
                    AND `restriction`.`valid_until` IS NOT NULL
                    AND `restriction`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN 'expired' ELSE `restriction`.`status` END)
        ORDER BY `restriction`.`id` ASC LIMIT ?]], {
        accountId, tonumber(cursor) or 0, status, status, limit
    })
    local items = {}
    for _, row in ipairs(rows) do items[#items + 1] = publicRestriction(row, row.effective_status) end
    return {
        items = items,
        next_cursor = #rows == limit and tostring(rows[#rows].id) or nil,
    }, nil
end

function port:expireRestrictions(maximum)
    maximum = math.max(1, math.min(tonumber(maximum) or 25, 100))
    local rows = many([[SELECT `id` FROM `synex_account_restrictions`
        WHERE `status` = 'active' AND `valid_until` IS NOT NULL
            AND `valid_until` <= CURRENT_TIMESTAMP(6)
        ORDER BY `valid_until` ASC, `id` ASC LIMIT ?]], { maximum })
    local expired = 0
    for _, row in ipairs(rows) do
        local affected = update([[UPDATE `synex_account_restrictions`
            SET `status` = 'expired', `active_marker` = NULL,
                `terminal_at` = `valid_until`, `version` = `version` + 1,
                `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `id` = ? AND `status` = 'active'
                AND `valid_until` <= CURRENT_TIMESTAMP(6)]], { row.id })
        if tonumber(affected) == 1 then expired = expired + 1 end
    end
    return { inspected = #rows, expired = expired }, nil
end

end
