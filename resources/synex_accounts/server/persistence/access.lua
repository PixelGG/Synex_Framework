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

function port:createAccessRole(command)
        local replayed, replayError = replay('create_access_role', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        if not one('SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?', { command.accountId }) then
            return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.')
        end
        if one([[SELECT `role`.`public_id` FROM `synex_account_access_roles` AS `role`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `role`.`account_id`
                WHERE `account`.`public_id` = ? AND `role`.`role_key` = ?]],
            { command.accountId, command.roleKey }) then
            return nil, domainError('ACCESS_ROLE_EXISTS', 'The account already has this access role.')
        end
        local roleId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            role_id = roleId, account_id = command.accountId, role_key = command.roleKey,
            display_name = command.displayName, permissions = command.permissions, version = 1
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_accounts` WHERE `public_id` = ? FOR UPDATE',
                values = { command.accountId }
            },
            {
                query = [[INSERT INTO `synex_account_access_roles`
                    (`public_id`, `account_id`, `role_key`, `display_name`, `version`)
                    SELECT ?, `id`, ?, ?, 1 FROM `synex_accounts` WHERE `public_id` = ?]],
                values = { roleId, command.roleKey, command.displayName, command.accountId }
            }
        }
        for _, permission in ipairs(command.permissions) do
            statements[#statements + 1] = {
                query = [[INSERT INTO `synex_account_access_role_permissions` (`role_id`, `permission_key`)
                    VALUES ((SELECT `id` FROM `synex_account_access_roles` WHERE `public_id` = ?), ?)]],
                values = { roleId, permission }
            }
        end
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_audit`
                (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                    'synex.accounts.access_role_created', ?, ?, ?)]],
            values = { eventId, command.idempotencyKey, command.accountId, command.actorRef, snapshot }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_account_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.accounts.access_role_created', 1, ?)]],
            values = { eventId, command.accountId, snapshot }
        }
        return execute('create_access_role', command, response, statements)
    end

    function port:grantAccess(command)
        local replayed, replayError = replay('grant_access', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local role = one([[SELECT `role`.`id`, `role`.`public_id`, `account`.`public_id` AS `account_public_id`
            FROM `synex_account_access_roles` AS `role`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `role`.`account_id`
            WHERE `role`.`public_id` = ? AND `account`.`public_id` = ?]], { command.roleId, command.accountId })
        if not role then return nil, domainError('ACCESS_ROLE_NOT_FOUND', 'The access role does not belong to the account.') end
        if one([[SELECT `public_id` FROM `synex_account_access_grants`
            WHERE `account_id` = (SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?)
                AND `principal_kind` = ? AND `principal_ref` = ? AND `active_marker` = 1]],
            { command.accountId, command.principalKind, command.principalRef }) then
            return nil, domainError('ACCESS_GRANT_EXISTS', 'The principal already has an active grant for this account.')
        end
        local grantId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            grant_id = grantId, account_id = command.accountId, role_id = command.roleId,
            principal_kind = command.principalKind, principal_ref = command.principalRef,
            status = 'active', version = 1, valid_for_seconds = command.validForSeconds
        }
        local snapshot = jsonEncode(response)
        return execute('grant_access', command, response, {
            {
                query = 'SELECT `id` FROM `synex_accounts` WHERE `public_id` = ? FOR UPDATE',
                values = { command.accountId }
            },
            {
                query = [[INSERT INTO `synex_account_access_grants`
                    (`public_id`, `account_id`, `role_id`, `principal_kind`, `principal_ref`, `status`,
                        `active_marker`, `valid_until`, `granted_by_ref`, `version`)
                    SELECT ?, `account`.`id`, `role`.`id`, ?, ?, 'active', 1,
                        CASE WHEN ? IS NULL THEN NULL ELSE TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)) END, ?, 1
                    FROM `synex_accounts` AS `account`
                    INNER JOIN `synex_account_access_roles` AS `role`
                        ON `role`.`account_id` = `account`.`id` AND `role`.`public_id` = ?
                    WHERE `account`.`public_id` = ?]],
                values = {
                    grantId, command.principalKind, command.principalRef, command.validForSeconds,
                    command.validForSeconds, command.actorRef, command.roleId, command.accountId
                }
            },
            {
                query = [[INSERT INTO `synex_account_audit`
                    (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `id` FROM `synex_account_operations` WHERE `idempotency_key` = ?),
                        'synex.accounts.access_granted', ?, ?, ?)]],
                values = { eventId, command.idempotencyKey, command.accountId, command.actorRef, snapshot }
            },
            {
                query = [[INSERT INTO `synex_account_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.accounts.access_granted', 1, ?)]],
                values = { eventId, command.accountId, snapshot }
            }
        })
    end

    function port:revokeAccess(command)
        local replayed, replayError = replay('revoke_access', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local grant = one([[SELECT `grant`.`id`, `grant`.`public_id`, `grant`.`status`, `grant`.`version`,
                `account`.`public_id` AS `account_public_id`, `role`.`public_id` AS `role_public_id`,
                `grant`.`principal_kind`, `grant`.`principal_ref`
            FROM `synex_account_access_grants` AS `grant`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `grant`.`account_id`
            INNER JOIN `synex_account_access_roles` AS `role` ON `role`.`id` = `grant`.`role_id`
            WHERE `grant`.`public_id` = ?]], { command.grantId })
        if not grant then return nil, domainError('ACCESS_GRANT_NOT_FOUND', 'The access grant does not exist.') end
        if grant.status ~= 'active' then
            return nil, domainError('ACCESS_GRANT_REVOKED', 'The access grant is already revoked.')
        end
        local eventId = uuidV4(random)
        local response = {
            grant_id = command.grantId, account_id = grant.account_public_id,
            role_id = grant.role_public_id, principal_kind = grant.principal_kind,
            principal_ref = grant.principal_ref, status = 'revoked', version = tonumber(grant.version) + 1
        }
        local snapshot = jsonEncode(response)
        return execute('revoke_access', command, response, {
            {
                query = 'SELECT `id` FROM `synex_account_access_grants` WHERE `id` = ? FOR UPDATE',
                values = { grant.id }
            },
            {
                query = [[UPDATE `synex_account_access_grants`
                    SET `status` = 'revoked', `active_marker` = NULL, `revoked_by_ref` = ?,
                        `revocation_reason` = ?, `revoked_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `status` = 'active' AND `active_marker` = 1]],
                values = { command.actorRef, command.reason, grant.id, grant.version }
            },
            {
                query = [[INSERT INTO `synex_account_audit`
                    (`event_id`, `operation_id`, `event_type`, `aggregate_id`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `operation`.`id` FROM `synex_account_operations` AS `operation`
                        INNER JOIN `synex_account_access_grants` AS `grant` ON `grant`.`public_id` = ?
                            AND `grant`.`status` = 'revoked' AND `grant`.`version` = ?
                        WHERE `operation`.`idempotency_key` = ?), 'synex.accounts.access_revoked', ?, ?, ?)]],
                values = {
                    eventId, command.grantId, tonumber(grant.version) + 1,
                    command.idempotencyKey, grant.account_public_id, command.actorRef, snapshot
                }
            },
            {
                query = [[INSERT INTO `synex_account_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.accounts.access_revoked', 1, ?)]],
                values = { eventId, grant.account_public_id, snapshot }
            }
        })
    end

    function port:getAccess(accountId, principalKind, principalRef)
        if not one('SELECT `id` FROM `synex_accounts` WHERE `public_id` = ?', { accountId }) then
            return nil, domainError('ACCOUNT_NOT_FOUND', 'The account does not exist.')
        end
        local rows = many([[SELECT `grant`.`public_id` AS `grant_public_id`, `grant`.`version` AS `grant_version`,
                `grant`.`valid_until`, `role`.`public_id` AS `role_public_id`, `role`.`role_key`,
                `role`.`display_name`, `permission`.`permission_key`
            FROM `synex_account_access_grants` AS `grant`
            INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `grant`.`account_id`
            INNER JOIN `synex_account_access_roles` AS `role` ON `role`.`id` = `grant`.`role_id`
            INNER JOIN `synex_account_access_role_permissions` AS `permission` ON `permission`.`role_id` = `role`.`id`
            WHERE `account`.`public_id` = ? AND `grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?
                AND `account`.`status` = 'active'
                AND `grant`.`status` = 'active' AND `grant`.`active_marker` = 1
                AND (`grant`.`valid_until` IS NULL OR `grant`.`valid_until` > CURRENT_TIMESTAMP(6))
            ORDER BY `permission`.`permission_key` ASC]], { accountId, principalKind, principalRef })
        if #rows == 0 then
            return {
                account_id = accountId, principal_kind = principalKind,
                principal_ref = principalRef, granted = false, permissions = {}
            }, nil
        end
        local permissions = {}
        for _, row in ipairs(rows) do permissions[#permissions + 1] = row.permission_key end
        return {
            account_id = accountId, principal_kind = principalKind, principal_ref = principalRef,
            granted = true, grant_id = rows[1].grant_public_id, grant_version = tonumber(rows[1].grant_version),
            role_id = rows[1].role_public_id, role_key = rows[1].role_key,
            role_display_name = rows[1].display_name, valid_until = rows[1].valid_until and tostring(rows[1].valid_until) or nil,
            permissions = permissions
        }, nil
    end
end
