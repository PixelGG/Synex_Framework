return function(port, context)
    local jsonEncode = context.jsonEncode
    local random = context.random
    local domainError = context.domainError
    local uuidV4 = context.uuidV4
    local one = context.one
    local many = context.many
    local replay = context.replay
    local execute = context.execute
    local accountState = context.accountState

function port:registerCurrency(command)
        local replayed, replayError = replay('register_currency', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        if one('SELECT `public_id` FROM `synex_currencies` WHERE `currency_code` = ?', { command.currencyCode }) then
            return nil, domainError('CURRENCY_EXISTS', 'The currency is already registered.')
        end
        local currencyId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            currency_id = currencyId, currency_code = command.currencyCode,
            display_name = command.displayName, minor_unit = command.minorUnit, status = 'active'
        }
        local snapshot = jsonEncode(response)
        return execute('register_currency', command, response, {
            {
                query = [[INSERT INTO `synex_currencies`
                    (`public_id`, `currency_code`, `display_name`, `minor_unit`, `status`)
                    VALUES (?, ?, ?, ?, 'active')]],
                values = { currencyId, command.currencyCode, command.displayName, command.minorUnit }
            },
            {
                query = [[INSERT INTO `synex_economy_integrity_read_models`
                    (`currency_id`, `model_version`, `cutoff_posting_id`, `transaction_count`, `posting_count`,
                        `total_debit_minor`, `total_credit_minor`, `total_booked_minor`, `negative_asset_count`,
                        `reserved_exceeds_booked_count`, `orphan_transaction_count`, `finding_count`, `status`)
                    VALUES ((SELECT `id` FROM `synex_currencies` WHERE `public_id` = ?),
                        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 'healthy')]],
                values = { currencyId }
            },
            {
                query = [[INSERT INTO `synex_account_audit`
                    (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                        'synex.accounts.currency_registered', ?, ?, ?)]],
                values = { eventId, command.idempotencyKey, currencyId, command.actorRef, snapshot }
            },
            {
                query = [[INSERT INTO `synex_account_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.accounts.currency_registered', 1, ?)]],
                values = { eventId, currencyId, snapshot }
            }
        })
    end

    function port:createAccount(command)
        local replayed, replayError = replay('create', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local currency = one('SELECT `id`, `status` FROM `synex_currencies` WHERE `currency_code` = ?', { command.currencyCode })
        if not currency then return nil, domainError('CURRENCY_NOT_FOUND', 'The currency does not exist.') end
        if currency.status ~= 'active' then return nil, domainError('CURRENCY_UNAVAILABLE', 'The currency is not active.') end
        if command.accountKey and one([[SELECT `a`.`public_id` FROM `synex_accounts` AS `a`
                INNER JOIN `synex_currencies` AS `c` ON `c`.`id` = `a`.`currency_id`
                WHERE `c`.`currency_code` = ? AND `a`.`account_key` = ?]],
            { command.currencyCode, command.accountKey }) then
            return nil, domainError('ACCOUNT_KEY_EXISTS', 'The account_key already exists for this currency.')
        end
        local accountId = uuidV4(random)
        local ownerRoleId = uuidV4(random)
        local ownerGrantId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            account_id = accountId, currency_code = command.currencyCode, account_role = command.accountRole,
            owner_kind = command.ownerKind, owner_ref = command.ownerRef, status = 'active',
            booked_minor = 0, reserved_minor = 0, available_minor = 0, sequence = 0
        }
        local snapshot = jsonEncode(response)
        return execute('create', command, response, {
            {
                query = [[INSERT INTO `synex_accounts`
                    (`public_id`, `currency_id`, `account_key`, `account_role`, `allow_negative`, `status`, `metadata_json`, `version`)
                    SELECT ?, `id`, ?, ?, ?, 'active', ?, 1 FROM `synex_currencies`
                    WHERE `currency_code` = ? AND `status` = 'active']],
                values = {
                    accountId, command.accountKey, command.accountRole,
                    command.accountRole == 'mint' and 1 or 0, command.metadataJson, command.currencyCode
                }
            },
            {
                query = [[INSERT INTO `synex_account_owners` (`account_id`, `owner_kind`, `owner_ref`)
                    VALUES ((SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?), ?, ?)]],
                values = { accountId, command.ownerKind, command.ownerRef }
            },
            {
                query = [[INSERT INTO `synex_account_access_roles`
                    (`public_id`, `account_id`, `role_key`, `display_name`, `version`)
                    VALUES (?, (SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?), 'owner', 'Owner', 1)]],
                values = { ownerRoleId, accountId }
            },
            {
                query = [[INSERT INTO `synex_account_access_role_permissions` (`role_id`, `permission_key`)
                    SELECT `role`.`id`, `permission`.`permission_key`
                    FROM `synex_account_access_roles` AS `role`
                    CROSS JOIN (SELECT 'view' AS `permission_key` UNION ALL SELECT 'deposit'
                        UNION ALL SELECT 'withdraw' UNION ALL SELECT 'transfer' UNION ALL SELECT 'history'
                        UNION ALL SELECT 'manage' UNION ALL SELECT 'close') AS `permission`
                    WHERE `role`.`public_id` = ?]],
                values = { ownerRoleId }
            },
            {
                query = [[INSERT INTO `synex_account_access_grants`
                    (`public_id`, `account_id`, `role_id`, `principal_kind`, `principal_ref`, `status`,
                        `active_marker`, `valid_until`, `granted_by_ref`, `version`)
                    SELECT ?, `account`.`id`, `role`.`id`, ?, ?, 'active', 1, NULL, ?, 1
                    FROM `synex_accounts` AS `account`
                    INNER JOIN `synex_account_access_roles` AS `role`
                        ON `role`.`account_id` = `account`.`id` AND `role`.`public_id` = ?
                    WHERE `account`.`public_id` = ?]],
                values = { ownerGrantId, command.ownerKind, command.ownerRef, command.actorRef, ownerRoleId, accountId }
            },
            {
                query = [[INSERT INTO `synex_account_balance_snapshots`
                    (`account_id`, `sequence_no`, `source_kind`, `source_ref`, `booked_minor`, `reserved_minor`)
                    VALUES ((SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?), 0, 'opening', ?, 0, 0)]],
                values = { accountId, accountId }
            },
            {
                query = [[INSERT INTO `synex_account_audit`
                    (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                        'synex.accounts.created', ?, ?, ?)]],
                values = { eventId, command.idempotencyKey, accountId, command.actorRef, snapshot }
            },
            {
                query = [[INSERT INTO `synex_account_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.accounts.created', 1, ?)]],
                values = { eventId, accountId, snapshot }
            }
        })
    end

    function port:getSnapshot(accountId)
        local row = accountState(accountId)
        if not row then return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.') end
        local booked = tonumber(row.booked_minor)
        local reserved = tonumber(row.reserved_minor)
        return {
            account_id = row.public_id, account_key = row.account_key, currency_code = row.currency_code,
            minor_unit = tonumber(row.minor_unit), account_role = row.account_role,
            owner_kind = row.owner_kind, owner_ref = row.owner_ref, status = row.status,
            booked_minor = booked, reserved_minor = reserved, available_minor = booked - reserved,
            sequence = tonumber(row.sequence_no), version = tonumber(row.version),
            snapshot_created_at = tostring(row.snapshot_created_at)
        }, nil
    end

    function port:listOwnerAccounts(ownerKind, ownerRef)
        local rows = many([[SELECT `account`.`public_id`, `account`.`account_key`,
                `currency`.`currency_code`, `currency`.`minor_unit`, `snapshot`.`booked_minor`,
                `snapshot`.`reserved_minor`, `snapshot`.`sequence_no`, `account`.`version`
            FROM `synex_accounts` AS `account`
            INNER JOIN `synex_account_owners` AS `owner` ON `owner`.`account_id` = `account`.`id`
            INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `account`.`currency_id`
            INNER JOIN `synex_account_balance_snapshots` AS `snapshot`
                ON `snapshot`.`account_id` = `account`.`id`
                AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                    FROM `synex_account_balance_snapshots` AS `latest`
                    WHERE `latest`.`account_id` = `account`.`id`)
            WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ?
                AND `account`.`status` = 'active' AND `account`.`account_role` = 'asset'
                AND `currency`.`currency_code` IN ('cash', 'bank')
            ORDER BY CASE `currency`.`currency_code` WHEN 'cash' THEN 0 ELSE 1 END,
                `account`.`public_id` ASC
            LIMIT 65]], { ownerKind, ownerRef })
        local result = {}
        for index = 1, math.min(#rows, 64) do
            local row = rows[index]
            local booked = tonumber(row.booked_minor) or 0
            local reserved = tonumber(row.reserved_minor) or 0
            result[index] = {
                account_id = row.public_id,
                account_key = row.account_key,
                currency_code = row.currency_code,
                minor_unit = tonumber(row.minor_unit),
                booked_minor = booked,
                reserved_minor = reserved,
                available_minor = booked - reserved,
                sequence = tonumber(row.sequence_no),
                version = tonumber(row.version),
            }
        end
        return { accounts = result, truncated = #rows > 64 }, nil
    end
end
