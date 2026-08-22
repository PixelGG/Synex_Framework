local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityRepository = function(deps)
    local platform = assert(deps.platform, 'identity repository requires platform')
    local foundation = assert(deps.foundation, 'identity repository requires foundation')
    local database = assert(deps.database, 'identity repository requires database')
    local players = assert(deps.players, 'identity repository requires player registry')
    local config = deps.config or {}
    local normalizeIdentifiers = assert(deps.normalizeIdentifiers, 'identity repository requires identifier normalization')

    local userRepository = {}
    function userRepository:findByIdentifiers(identifiers)
        if #identifiers == 0 then return nil, nil end
        local conditions, parameters = {}, {}
        for _, identifier in ipairs(identifiers) do
            conditions[#conditions + 1] = '(`i`.`identifier_type` = ? AND `i`.`identifier_value` = ?)'
            parameters[#parameters + 1] = identifier.type
            parameters[#parameters + 1] = identifier.value
        end
        local sql = [[SELECT DISTINCT `u`.`id`, `u`.`status`, `u`.`locale`, `u`.`metadata_json`, `u`.`version`,
            `u`.`created_at`, `u`.`updated_at`, `u`.`deleted_at`
            FROM `synex_identifiers` AS `i`
            INNER JOIN `synex_users` AS `u` ON `u`.`id` = `i`.`user_id`
            WHERE ]] .. table.concat(conditions, ' OR ') .. ' ORDER BY `u`.`created_at` ASC LIMIT 2'
        local rows, err = database:query(sql, parameters)
        if err then return nil, err end
        if rows and #rows > 1 then return nil, foundation.error('IDENTIFIER_CONFLICT', 'Identifiers resolve to multiple users.') end
        if not rows or not rows[1] then return nil, nil end
        local user = rows[1]
        if type(user.metadata_json) == 'string' then
            local ok, metadata = pcall(platform.jsonDecode, user.metadata_json)
            user.metadata = ok and metadata or {}
        else user.metadata = {} end
        user.metadata_json = nil
        return user, nil
    end

    function userRepository:create(identifiers)
        if #identifiers == 0 then return nil, foundation.error('IDENTIFIER_REQUIRED', 'At least one supported identifier is required.') end
        local userId = foundation.nextId('usr')
        local statements = {
            {
                query = [[INSERT INTO `synex_users` (`id`, `status`, `locale`, `metadata_json`, `version`)
                    VALUES (?, 'active', 'en', '{}', 1)]],
                values = { userId }
            },
            {
                query = [[INSERT INTO `synex_character_slots` (`user_id`, `slot_limit`, `version`)
                    VALUES (?, 1, 1)]],
                values = { userId }
            }
        }
        for _, identifier in ipairs(identifiers) do
            statements[#statements + 1] = {
                query = [[INSERT INTO `synex_identifiers`
                    (`user_id`, `identifier_type`, `identifier_value`, `verified_at`, `first_seen_at`, `last_seen_at`)
                    VALUES (?, ?, ?, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))]],
                values = { userId, identifier.type, identifier.value }
            }
        end
        local committed, transactionError = database:transaction(statements)
        if not committed then
            local raced, lookupError = self:findByIdentifiers(identifiers)
            if raced then return raced, nil end
            return nil, lookupError or transactionError
        end
        return { id = userId, status = 'active', locale = 'en', metadata = {}, version = 1 }, nil
    end

    function userRepository:touchIdentifiers(userId, identifiers)
        for _, identifier in ipairs(identifiers) do
            local _, err = database:update([[INSERT INTO `synex_identifiers`
                (`user_id`, `identifier_type`, `identifier_value`, `verified_at`, `first_seen_at`, `last_seen_at`)
                VALUES (?, ?, ?, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))
                ON DUPLICATE KEY UPDATE `last_seen_at` = CURRENT_TIMESTAMP(6)]],
                { userId, identifier.type, identifier.value })
            if err then return nil, err end
        end
        return true, nil
    end

    function userRepository:authenticate(rawIdentifiers)
        local identifiers = normalizeIdentifiers(rawIdentifiers)
        if #identifiers == 0 then return nil, foundation.error('IDENTIFIER_REQUIRED', 'No supported platform identifier was provided.') end
        local user, lookupError = self:findByIdentifiers(identifiers)
        if lookupError then return nil, lookupError end
        if not user then user, lookupError = self:create(identifiers) end
        if not user then return nil, lookupError end
        if user.status ~= 'active' then return nil, foundation.error('USER_DISABLED', 'This user is not allowed to connect.') end
        local touched, touchError = self:touchIdentifiers(user.id, identifiers)
        if not touched then return nil, touchError end
        local verified, verificationError = self:findByIdentifiers(identifiers)
        if verificationError then return nil, verificationError end
        if not verified or verified.id ~= user.id then
            return nil, foundation.error('IDENTIFIER_CONFLICT', 'Identifier ownership changed during authentication.')
        end
        for _, identifier in ipairs(identifiers) do players:bindIdentifier(identifier.normalized, user.id) end
        return foundation.copy(user), nil
    end

    local sessionRepository = {}
    function sessionRepository:create(session)
        local _, err = database:insert([[INSERT INTO `synex_sessions`
            (`id`, `user_id`, `server_instance_id`, `source_value`, `source_generation`, `state`, `character_id`, `connected_at`, `last_seen_at`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), ?)]], {
            session.id, session.userId, deps.instanceId, session.source, session.sourceGeneration or 0, session.state, session.version or 1
        })
        return err and nil or true, err
    end
    function sessionRepository:update(session)
        local affected, err = database:update([[UPDATE `synex_sessions`
            SET `source_value` = ?, `source_generation` = ?, `state` = ?, `character_id` = ?,
                `last_seen_at` = CURRENT_TIMESTAMP(6), `version` = ?
            WHERE `id` = ? AND `version` = ?]], {
            session.source, session.sourceGeneration or 0, session.state, session.characterId,
            session.version, session.id, session.persistedVersion or math.max(1, (session.version or 1) - 1)
        })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then return nil, foundation.error('SESSION_CONFLICT', 'The session changed concurrently.', { retryable = true }) end
        return true, nil
    end
    function sessionRepository:getState(sessionId)
        local rows, err = database:query([[SELECT `state`, `character_id`, `version`
            FROM `synex_sessions` WHERE `id` = ? LIMIT 1]], { sessionId })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        local version = tonumber(row.version)
        if type(row.state) ~= 'string' or not version or math.type(version) ~= 'integer' or version < 1 then
            return nil, foundation.error('INVALID_DATABASE_RESULT', 'The persisted session state is invalid.')
        end
        return { state = row.state, characterId = row.character_id, version = version }, nil
    end
    function sessionRepository:close(session, reason)
        local affected, err = database:update([[UPDATE `synex_sessions`
            SET `state` = 'CLOSED', `closed_at` = CURRENT_TIMESTAMP(6), `close_reason` = ?,
                `last_seen_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
            WHERE `id` = ? AND `closed_at` IS NULL]], { tostring(reason or 'disconnected'):sub(1, 128), session.id })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then
            return nil, foundation.error('SESSION_CONFLICT', 'The session was already closed or changed concurrently.', {
                retryable = true
            })
        end
        return true, nil
    end

    local accessRepository = {}
    local function validAccessId(value)
        return type(value) == 'string' and #value >= 8 and #value <= 36
            and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
    end

    local function validAccessReason(value)
        return type(value) == 'string' and #value >= 1 and #value <= 512
            and not value:find('[%z\1-\31\127]')
    end

    local function validExpiry(value)
        return value == nil or (type(value) == 'string' and #value == 19
            and value:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$') ~= nil)
    end

    local function normalizedExpiry(value)
        if value == nil then return nil end
        local normalized = tostring(value):sub(1, 19)
        if #normalized ~= 19 then return normalized end
        return normalized:sub(1, 10) .. ' ' .. normalized:sub(12)
    end

    local function sameAccessTarget(row, request, persistedReason)
        return row.revoked_at == nil
            and tostring(row.user_id or '') == request.userId
            and normalizedExpiry(row.expires_at) == normalizedExpiry(request.expiresAt)
            and persistedReason == request.reason
    end

    local function validateAccessRequest(request, required, optional)
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Access management requires a plain request object.')
        end
        local allowed = {}
        for _, key in ipairs(required) do allowed[key] = true; if request[key] == nil then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'A required access-management field is missing.')
        end end
        for _, key in ipairs(optional or {}) do allowed[key] = true end
        for key in pairs(request) do if type(key) ~= 'string' or not allowed[key] then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Access-management request contains an unknown field.')
        end end
        return true, nil
    end

    local function validateAccessContext(context)
        if type(context) ~= 'table' or type(context.actor) ~= 'string' or #context.actor < 1
            or #context.actor > 128 or context.actor:find('[%z\1-\31\127]')
            or (context.actorType ~= 'resource' and context.actorType ~= 'system')
            or type(context.traceId) ~= 'string' or #context.traceId < 8 or #context.traceId > 64
            or not context.traceId:match('^[A-Za-z0-9_.:%-]+$') then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT', 'Access-management audit context is invalid.')
        end
        return true, nil
    end

    local function encodeAudit(value)
        if value == nil then return nil, nil end
        local ok, encoded = pcall(platform.jsonEncode, value)
        if not ok or type(encoded) ~= 'string' or #encoded > 8192 then
            return nil, foundation.error('AUDIT_ENCODING_FAILED', 'Access-management audit data could not be encoded.')
        end
        return encoded, nil
    end

    local function insertAccessAudit(query, action, targetType, targetId, context, before, after, reason)
        local beforeJson, beforeError = encodeAudit(before)
        if beforeError then return nil, beforeError end
        local afterJson, afterError = encodeAudit(after)
        if afterError then return nil, afterError end
        local contextJson, contextError = encodeAudit({ reason = reason })
        if contextError then return nil, contextError end
        query([[INSERT INTO `synex_audit_log`
            (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
            foundation.nextId('audit'), context.traceId, context.actorType, context.actor, action, targetType, targetId,
            beforeJson, afterJson, contextJson
        })
        return true, nil
    end

    function accessRepository:check(userId, identifiers)
        local identifierConditions, parameters = {}, { userId }
        for _, identifier in ipairs(identifiers) do
            identifierConditions[#identifierConditions + 1] = '(`identifier_type` = ? AND `identifier_value` = ?)'
            parameters[#parameters + 1] = identifier.type
            parameters[#parameters + 1] = identifier.value
        end
        local identifierTarget = #identifierConditions > 0 and (' OR `identifier_id` IN (SELECT `id` FROM `synex_identifiers` WHERE ' .. table.concat(identifierConditions, ' OR ') .. ')') or ''
        local bans, banError = database:query([[SELECT `reason`, `expires_at` FROM `synex_access_bans`
            WHERE `revoked_at` IS NULL AND (`expires_at` IS NULL OR `expires_at` > CURRENT_TIMESTAMP(6))
                AND (`user_id` = ?]] .. identifierTarget .. ') LIMIT 1', parameters)
        if banError then return nil, banError end
        if bans and bans[1] then return nil, foundation.error('ACCESS_BANNED', tostring(bans[1].reason or 'Access denied.')) end
        if config.allowlistRequired == true then
            local entries, allowlistError = database:query([[SELECT `id` FROM `synex_allowlist_entries`
                WHERE `revoked_at` IS NULL AND (`expires_at` IS NULL OR `expires_at` > CURRENT_TIMESTAMP(6))
                    AND (`user_id` = ?]] .. identifierTarget .. ') LIMIT 1', parameters)
            if allowlistError then return nil, allowlistError end
            if not entries or not entries[1] then return nil, foundation.error('ALLOWLIST_REQUIRED', 'This server requires an allowlist entry.') end
        end
        return true, nil
    end

    function accessRepository:ban(request, context)
        local valid, requestError = validateAccessRequest(request, { 'id', 'userId', 'reason' }, { 'expiresAt' })
        if not valid then return nil, requestError end
        local contextValid, contextError = validateAccessContext(context)
        if not contextValid then return nil, contextError end
        if not validAccessId(request.id) or not validAccessId(request.userId)
            or not validAccessReason(request.reason) or not validExpiry(request.expiresAt) then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Ban identity, reason, or expiry is invalid.')
        end
        local result, domainError, auditError
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `user_id`, `reason`, `expires_at`, `revoked_at`
                FROM `synex_access_bans` WHERE `id` = ? FOR UPDATE]], { request.id }) or {}
            if rows[1] then
                if sameAccessTarget(rows[1], request, tostring(rows[1].reason or '')) then
                    result = {
                        id = request.id, userId = request.userId, state = 'active',
                        expiresAt = request.expiresAt
                    }
                    return true
                end
                domainError = foundation.error('ACCESS_ENTRY_CONFLICT', 'The ban ID already exists.')
                return false
            end
            local after = { id = request.id, userId = request.userId, state = 'active', expiresAt = request.expiresAt }
            query([[INSERT INTO `synex_access_bans`
                (`id`, `user_id`, `identifier_id`, `reason`, `issued_by_ref`, `expires_at`)
                VALUES (?, ?, NULL, ?, ?, ?)]], {
                request.id, request.userId, request.reason, context.actor, request.expiresAt
            })
            local audited
            audited, auditError = insertAccessAudit(query, 'access.ban', 'access_ban', request.id,
                context, nil, after, request.reason)
            if not audited then return false end
            result = after
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, transactionError end
        return result, nil
    end

    function accessRepository:unban(request, context)
        local valid, requestError = validateAccessRequest(request, { 'id', 'reason' })
        if not valid then return nil, requestError end
        local contextValid, contextError = validateAccessContext(context)
        if not contextValid then return nil, contextError end
        if not validAccessId(request.id) or not validAccessReason(request.reason) then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Ban ID or revocation reason is invalid.')
        end
        local result, domainError, auditError
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `user_id`, `reason`, `expires_at`, `revoked_at`
                FROM `synex_access_bans` WHERE `id` = ? FOR UPDATE]], { request.id }) or {}
            local row = rows[1]
            if not row then domainError = foundation.error('ACCESS_ENTRY_NOT_FOUND', 'The ban does not exist.'); return false end
            if row.revoked_at ~= nil then result = { id = request.id, state = 'revoked' }; return true end
            local before = { id = request.id, userId = row.user_id, state = 'active',
                expiresAt = row.expires_at and tostring(row.expires_at) or nil }
            result = { id = request.id, userId = row.user_id, state = 'revoked' }
            query([[UPDATE `synex_access_bans` SET `revoked_at` = CURRENT_TIMESTAMP(6),
                `revoked_by_ref` = ?, `revocation_reason` = ? WHERE `id` = ? AND `revoked_at` IS NULL]],
                { context.actor, request.reason, request.id })
            local audited
            audited, auditError = insertAccessAudit(query, 'access.unban', 'access_ban', request.id,
                context, before, result, request.reason)
            if not audited then return false end
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, transactionError end
        return result, nil
    end

    function accessRepository:allow(request, context)
        local valid, requestError = validateAccessRequest(request, { 'id', 'userId', 'reason' }, { 'expiresAt' })
        if not valid then return nil, requestError end
        local contextValid, contextError = validateAccessContext(context)
        if not contextValid then return nil, contextError end
        if not validAccessId(request.id) or not validAccessId(request.userId)
            or not validAccessReason(request.reason) or not validExpiry(request.expiresAt) then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Allowlist identity, reason, or expiry is invalid.')
        end
        local result, domainError, auditError
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `entry`.`user_id`, `entry`.`expires_at`, `entry`.`revoked_at`,
                    (SELECT `audit`.`context_json` FROM `synex_audit_log` AS `audit`
                        WHERE `audit`.`action` = 'access.allow'
                            AND `audit`.`target_type` = 'allowlist_entry'
                            AND `audit`.`target_id` = `entry`.`id`
                        ORDER BY `audit`.`id` ASC LIMIT 1) AS `audit_context_json`
                FROM `synex_allowlist_entries` AS `entry` WHERE `entry`.`id` = ? FOR UPDATE]],
                { request.id }) or {}
            if rows[1] then
                local decodedOk, auditContext = pcall(platform.jsonDecode,
                    rows[1].audit_context_json or '')
                local persistedReason = decodedOk and type(auditContext) == 'table'
                    and auditContext.reason or nil
                if sameAccessTarget(rows[1], request, persistedReason) then
                    result = {
                        id = request.id, userId = request.userId, state = 'active',
                        expiresAt = request.expiresAt
                    }
                    return true
                end
                domainError = foundation.error('ACCESS_ENTRY_CONFLICT', 'The allowlist ID already exists.')
                return false
            end
            result = { id = request.id, userId = request.userId, state = 'active', expiresAt = request.expiresAt }
            query([[INSERT INTO `synex_allowlist_entries`
                (`id`, `user_id`, `identifier_id`, `granted_by_ref`, `expires_at`)
                VALUES (?, ?, NULL, ?, ?)]], { request.id, request.userId, context.actor, request.expiresAt })
            local audited
            audited, auditError = insertAccessAudit(query, 'access.allow', 'allowlist_entry', request.id,
                context, nil, result, request.reason)
            if not audited then return false end
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, transactionError end
        return result, nil
    end

    function accessRepository:revokeAllowlist(request, context)
        local valid, requestError = validateAccessRequest(request, { 'id', 'reason' })
        if not valid then return nil, requestError end
        local contextValid, contextError = validateAccessContext(context)
        if not contextValid then return nil, contextError end
        if not validAccessId(request.id) or not validAccessReason(request.reason) then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Allowlist ID or revocation reason is invalid.')
        end
        local result, domainError, auditError
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `user_id`, `expires_at`, `revoked_at`
                FROM `synex_allowlist_entries` WHERE `id` = ? FOR UPDATE]], { request.id }) or {}
            local row = rows[1]
            if not row then
                domainError = foundation.error('ACCESS_ENTRY_NOT_FOUND', 'The allowlist entry does not exist.')
                return false
            end
            if row.revoked_at ~= nil then result = { id = request.id, state = 'revoked' }; return true end
            local before = { id = request.id, userId = row.user_id, state = 'active',
                expiresAt = row.expires_at and tostring(row.expires_at) or nil }
            result = { id = request.id, userId = row.user_id, state = 'revoked' }
            query([[UPDATE `synex_allowlist_entries` SET `revoked_at` = CURRENT_TIMESTAMP(6),
                `revoked_by_ref` = ? WHERE `id` = ? AND `revoked_at` IS NULL]], { context.actor, request.id })
            local audited
            audited, auditError = insertAccessAudit(query, 'access.allow.revoke', 'allowlist_entry', request.id,
                context, before, result, request.reason)
            if not audited then return false end
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, transactionError end
        return result, nil
    end

    function accessRepository:list(request)
        local valid, requestError = validateAccessRequest(request, { 'userId' }, { 'limit' })
        if not valid then return nil, requestError end
        local limit = request.limit == nil and 25 or request.limit
        if not validAccessId(request.userId) or type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 64 then
            return nil, foundation.error('INVALID_ACCESS_REQUEST', 'Access-list user or limit is invalid.')
        end
        local bans, banError = database:query([[SELECT `id`, `reason`, `issued_by_ref`, `expires_at`, `revoked_at`
            FROM `synex_access_bans` WHERE `user_id` = ? ORDER BY `created_at` DESC, `id` DESC LIMIT ?]],
            { request.userId, limit + 1 })
        if not bans then return nil, banError end
        local allowed, allowError = database:query([[SELECT `id`, `granted_by_ref`, `expires_at`, `revoked_at`
            FROM `synex_allowlist_entries` WHERE `user_id` = ? ORDER BY `created_at` DESC, `id` DESC LIMIT ?]],
            { request.userId, limit + 1 })
        if not allowed then return nil, allowError end
        local function bounded(rows, actorField)
            local entries = {}
            for index = 1, math.min(#rows, limit) do
                local row = rows[index]
                entries[index] = {
                    id = row.id, reason = row.reason, actor = row[actorField],
                    expiresAt = row.expires_at and tostring(row.expires_at) or nil,
                    state = row.revoked_at == nil and 'active' or 'revoked'
                }
            end
            return { entries = entries, truncated = #rows > limit }
        end
        return { userId = request.userId, bans = bounded(bans, 'issued_by_ref'),
            allowlist = bounded(allowed, 'granted_by_ref') }, nil
    end

    local characterRepository = {}
    local function characterFromRow(row)
        local ok, metadata = pcall(platform.jsonDecode, row.metadata_json or '{}')
        return {
            id = row.id, userId = row.user_id, slot = tonumber(row.slot), status = row.status,
            firstName = row.first_name, lastName = row.last_name, dateOfBirth = row.date_of_birth,
            metadata = ok and metadata or {}, version = tonumber(row.version)
        }
    end
    function characterRepository:create(userId, input)
        local slotRows, slotError = database:query([[SELECT `slot_limit` FROM `synex_character_slots`
            WHERE `user_id` = ? LIMIT 1]], { userId })
        if slotError then return nil, slotError end
        local slotLimit = slotRows and slotRows[1] and tonumber(slotRows[1].slot_limit) or 1
        local slot = tonumber(input.slot)
        if not slot or math.type(slot) ~= 'integer' or slot < 1 or slot > slotLimit then
            return nil, foundation.error('CHARACTER_SLOT_UNAVAILABLE', 'The requested character slot is unavailable.')
        end
        local function validName(value)
            return type(value) == 'string' and #value >= 1 and #value <= 64
                and not value:find('[%z\1-\31\127]')
        end
        if not validName(input.firstName) or not validName(input.lastName) then
            return nil, foundation.error('INVALID_CHARACTER_NAME', 'Character names must contain between 1 and 64 bytes without control characters.')
        end
        if input.dateOfBirth ~= nil and (type(input.dateOfBirth) ~= 'string' or not input.dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$')) then
            return nil, foundation.error('INVALID_DATE_OF_BIRTH', 'Date of birth must use YYYY-MM-DD.')
        end
        local characterId = foundation.nextId('char')
        local inserted, insertError = database:insert([[INSERT INTO `synex_characters`
            (`id`, `user_id`, `slot`, `status`, `first_name`, `last_name`, `date_of_birth`, `metadata_json`, `version`)
            VALUES (?, ?, ?, 'active', ?, ?, ?, '{}', 1)]], {
            characterId, userId, slot, input.firstName, input.lastName, input.dateOfBirth
        })
        if insertError then return nil, insertError end
        if inserted == nil then return nil, foundation.error('CHARACTER_CREATE_FAILED', 'The character could not be created.') end
        return {
            id = characterId, userId = userId, slot = slot, status = 'active',
            firstName = input.firstName, lastName = input.lastName,
            dateOfBirth = input.dateOfBirth, metadata = {}, version = 1
        }, nil
    end
    function characterRepository:list(userId)
        local rows, err = database:query([[SELECT `id`, `user_id`, `slot`, `status`, `first_name`, `last_name`,
            `date_of_birth`, `metadata_json`, `version`, `created_at`, `updated_at`
            FROM `synex_characters` WHERE `user_id` = ? AND `deleted_at` IS NULL ORDER BY `slot` ASC]], { userId })
        if err then return nil, err end
        local result = {}
        for _, row in ipairs(rows or {}) do
            result[#result + 1] = characterFromRow(row)
        end
        return result, nil
    end
    function characterRepository:get(characterId)
        if type(characterId) ~= 'string' or #characterId < 1 or #characterId > 36 then
            return nil, foundation.error('INVALID_CHARACTER_ID', 'Character ID is invalid.')
        end
        local rows, err = database:query([[SELECT `id`, `user_id`, `slot`, `status`, `first_name`, `last_name`,
            `date_of_birth`, `metadata_json`, `version` FROM `synex_characters`
            WHERE `id` = ? AND `deleted_at` IS NULL LIMIT 1]], { characterId })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, foundation.error('CHARACTER_NOT_FOUND', 'The character does not exist.') end
        if row.status ~= 'active' then return nil, foundation.error('CHARACTER_UNAVAILABLE', 'The character is not active.') end
        return characterFromRow(row), nil
    end
    function characterRepository:getOwned(userId, characterId)
        local rows, err = database:query([[SELECT `id`, `user_id`, `slot`, `status`, `first_name`, `last_name`,
            `date_of_birth`, `metadata_json`, `version` FROM `synex_characters`
            WHERE `id` = ? AND `user_id` = ? AND `deleted_at` IS NULL LIMIT 1]], { characterId, userId })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, foundation.error('CHARACTER_NOT_FOUND', 'The character does not belong to this user.') end
        if row.status ~= 'active' then return nil, foundation.error('CHARACTER_UNAVAILABLE', 'The character is not active.') end
        return characterFromRow(row), nil
    end

    return {
        access = accessRepository,
        characters = characterRepository,
        sessions = sessionRepository,
        users = userRepository
    }
end
