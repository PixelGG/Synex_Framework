local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identitySessionFencing = function(deps)
    local foundation = assert(deps.foundation, 'identity session fencing requires foundation')
    local database = assert(deps.database, 'identity session fencing requires database')
    local instanceId = assert(deps.instanceId, 'identity session fencing requires an instance ID')

    local function affectedRows(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end

    local function sessionAuthority(session)
        local lease = type(session) == 'table' and session.clusterLease or nil
        local name = type(lease) == 'table' and (lease.name or lease.leaseName) or nil
        if type(session) ~= 'table' or type(session.id) ~= 'string'
            or #session.id < 1 or #session.id > 36
            or type(name) ~= 'string' or #name < 9 or #name > 128
            or name:sub(1, 8) ~= 'session:'
            or type(lease.owner) ~= 'string' or #lease.owner < 1 or #lease.owner > 128
            or lease.owner ~= instanceId .. ':' .. session.id
            or type(lease.fencingToken) ~= 'number' or math.type(lease.fencingToken) ~= 'integer'
            or lease.fencingToken < 1 or lease.requesterInstanceId ~= instanceId
            or type(lease.requesterBootId) ~= 'string'
            or #lease.requesterBootId < 1 or #lease.requesterBootId > 36 then
            return nil, foundation.error('LEASE_LOST', 'Session authority is missing or invalid.', {
                retryable = true
            })
        end
        return {
            name = name, owner = lease.owner, fencingToken = lease.fencingToken,
            requesterInstanceId = lease.requesterInstanceId,
            requesterBootId = lease.requesterBootId
        }, nil
    end

    local function admissionGateAuthority(session)
        local lease = type(session) == 'table' and session.admissionGateLease or nil
        local name = type(lease) == 'table' and (lease.name or lease.leaseName) or nil
        if type(session) ~= 'table' or type(session.userId) ~= 'string'
            or #session.userId < 1 or #session.userId > 36
            or name ~= 'admission:' .. session.userId
            or type(lease.owner) ~= 'string' or #lease.owner < 1 or #lease.owner > 128
            or lease.owner ~= instanceId .. ':' .. session.id
            or type(lease.fencingToken) ~= 'number'
            or math.type(lease.fencingToken) ~= 'integer' or lease.fencingToken < 1
            or lease.requesterInstanceId ~= instanceId
            or type(lease.requesterBootId) ~= 'string'
            or #lease.requesterBootId < 1 or #lease.requesterBootId > 36 then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority is missing or invalid.', { retryable = true })
        end
        return {
            name = name, owner = lease.owner, fencingToken = lease.fencingToken,
            requesterInstanceId = lease.requesterInstanceId,
            requesterBootId = lease.requesterBootId
        }, nil
    end

    local function guardCurrent(authorityGuard)
        if authorityGuard == nil then return true end
        local invoked, current = foundation.safeCall(authorityGuard)
        return invoked and current == true
    end

    local function lockRuntimeAuthority(query, authority, authorityGuard)
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed before persistence.', { retryable = true })
        end
        local requester = query([[SELECT `status` FROM `synex_instances`
            WHERE `instance_id` = ? AND `status` = 'ready' FOR UPDATE]],
            { authority.requesterInstanceId }) or {}
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed during persistence.', { retryable = true })
        end
        if not requester[1] then
            return nil, foundation.error('LEASE_LOST',
                'Session requester authority changed before persistence.', { retryable = true })
        end
        local boot = query([[SELECT `boot_id` FROM `synex_instance_boots`
            WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
            { authority.requesterInstanceId, authority.requesterBootId }) or {}
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed during persistence.', { retryable = true })
        end
        if not boot[1] then
            return nil, foundation.error('LEASE_LOST',
                'Session boot authority changed before persistence.', { retryable = true })
        end
        local leaseRows = query([[SELECT `owner_id`, `fencing_token`,
                (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
            FROM `synex_cluster_leases` WHERE `lease_name` = ? FOR UPDATE]],
            { authority.name }) or {}
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed during persistence.', { retryable = true })
        end
        local current = leaseRows[1]
        if not current or current.owner_id ~= authority.owner
            or tonumber(current.fencing_token) ~= authority.fencingToken
            or tonumber(current.valid) ~= 1 then
            return nil, foundation.error('LEASE_LOST',
                'Session authority changed before persistence.', { retryable = true })
        end
        return true, nil
    end

    local function lockAdmissionGate(query, authority, authorityGuard)
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local admission authority changed before persistence.', { retryable = true })
        end
        local requester = query([[SELECT `status` FROM `synex_instances`
            WHERE `instance_id` = ? AND `status` = 'ready' FOR UPDATE]],
            { authority.requesterInstanceId }) or {}
        local boot = requester[1] and (query([[SELECT `boot_id` FROM `synex_instance_boots`
            WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
            { authority.requesterInstanceId, authority.requesterBootId }) or {}) or {}
        local rows = boot[1] and (query([[SELECT `owner_id`, `fencing_token`,
                (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
            FROM `synex_cluster_leases` WHERE `lease_name` = ? FOR UPDATE]],
            { authority.name }) or {}) or {}
        local current = rows[1]
        if not guardCurrent(authorityGuard) or not requester[1] or not boot[1]
            or not current or current.owner_id ~= authority.owner
            or tonumber(current.fencing_token) ~= authority.fencingToken
            or tonumber(current.valid) ~= 1 then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority changed before persistence.', { retryable = true })
        end
        return true, nil
    end

    local function lockedSessionMatches(row, session, expected)
        if type(row) ~= 'table' or row.closed_at ~= nil or row.id ~= session.id
            or row.user_id ~= session.userId or row.server_instance_id ~= instanceId
            or row.state ~= expected.state or row.character_id ~= expected.characterId
            or tonumber(row.version) ~= expected.version
            or tonumber(row.source_generation) ~= expected.sourceGeneration then
            return false
        end
        return expected.source == nil or tonumber(row.source_value) == tonumber(expected.source)
    end

    local repository = {}

    function repository:create(session)
        local authority, validationError = sessionAuthority(session)
        if not authority then return nil, validationError end
        local admission, admissionError = admissionGateAuthority(session)
        if not admission then return nil, admissionError end
        if admission.requesterBootId ~= authority.requesterBootId then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Admission and session authority belong to different runtime boots.', {
                    retryable = true
                })
        end
        local authorityError = nil
        local committed, transactionError = database:withTransaction(function(query)
            authorityError = nil
            local authorized
            authorized, authorityError = lockAdmissionGate(query, admission)
            if not authorized then return false end
            authorized, authorityError = lockRuntimeAuthority(query, authority)
            if not authorized then return false end
            query([[INSERT INTO `synex_sessions`
                (`id`, `user_id`, `server_instance_id`, `source_value`, `source_generation`, `state`,
                    `character_id`, `connected_at`, `last_seen_at`, `version`)
                VALUES (?, ?, ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6), ?)]], {
                session.id, session.userId, instanceId, session.source, session.sourceGeneration or 0,
                session.state, session.version or 1
            })
            local retired = query([[UPDATE `synex_cluster_leases`
                SET `owner_id` = 'retired',
                    `fencing_token` = CASE
                        WHEN `fencing_token` < 18446744073709551615
                            THEN `fencing_token` + 1
                        ELSE `fencing_token`
                    END,
                    `expires_at` = CURRENT_TIMESTAMP(6),
                    `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?
                    AND `expires_at` > CURRENT_TIMESTAMP(6)]], {
                admission.name, admission.owner, admission.fencingToken
            })
            if affectedRows(retired) ~= 1 then
                authorityError = foundation.error('ADMISSION_GATE_LOST',
                    'Account admission authority could not be retired atomically.', {
                        retryable = true
                    })
                return false
            end
            return true
        end)
        if not committed then return nil, authorityError or transactionError end
        return true, nil
    end

    function repository:lockCharacterSessions(query, session, characterId, expected,
        authorityGuard, activeErrorCode)
        local authority, authorityError = sessionAuthority(session)
        if not authority then return nil, authorityError end
        if type(expected) ~= 'table' or type(expected.state) ~= 'string'
            or type(expected.version) ~= 'number' or math.type(expected.version) ~= 'integer'
            or type(expected.sourceGeneration) ~= 'number'
            or math.type(expected.sourceGeneration) ~= 'integer' then
            return nil, foundation.error('SESSION_CONFLICT',
                'The expected durable session state is invalid.', { retryable = true })
        end
        local ownRows = query([[SELECT `id`, `user_id`, `server_instance_id`, `source_value`,
                `source_generation`, `state`, `character_id`, `version`, `closed_at`
            FROM `synex_sessions` WHERE `id` = ? FOR UPDATE]], { session.id }) or {}
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed while the caller session was locked.', {
                    retryable = true
                })
        end
        local own = ownRows[1]
        if not lockedSessionMatches(own, session, expected) then
            return nil, foundation.error('SESSION_CONFLICT',
                'The durable session changed before the character operation.', { retryable = true })
        end
        local conflicts = query([[SELECT `id` FROM `synex_sessions`
            FORCE INDEX (`idx_sessions_character_open`)
            WHERE `character_id` = ? AND `closed_at` IS NULL AND `id` <> ?
            ORDER BY `id` ASC LIMIT 1 FOR UPDATE]], { characterId, session.id }) or {}
        if not guardCurrent(authorityGuard) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Local session authority changed while character sessions were locked.', {
                    retryable = true
                })
        end
        if conflicts[1] then
            local code = activeErrorCode or 'CHARACTER_ALREADY_ACTIVE'
            return nil, foundation.error(code, code == 'CHARACTER_DELETE_BLOCKED'
                and 'The character is active in another open session.'
                or 'The character is active in another session.', { retryable = true })
        end
        local authorized
        authorized, authorityError = lockRuntimeAuthority(query, authority, authorityGuard)
        if not authorized then return nil, authorityError end
        return own, nil
    end

    function repository:activateCharacter(session, character, authorityGuard)
        if type(character) ~= 'table' or type(character.id) ~= 'string'
            or character.userId ~= session.userId or type(character.version) ~= 'number'
            or math.type(character.version) ~= 'integer' then
            return nil, foundation.error('CHARACTER_CONFLICT',
                'Character activation requires an exact owned character version.', { retryable = true })
        end
        local expected = {
            state = 'SELECTING_CHARACTER', characterId = nil,
            version = session.persistedVersion,
            source = session.persistedSource or session.source,
            sourceGeneration = session.persistedSourceGeneration or session.sourceGeneration
        }
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            domainError = nil
            local locked = query([[SELECT `id`, `user_id`, `version`, `status`, `deleted_at`
                FROM `synex_characters` WHERE `id` = ? FOR UPDATE]], { character.id }) or {}
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed while the character was locked.', { retryable = true })
                return false
            end
            local row = locked[1]
            if not row or row.user_id ~= session.userId or row.deleted_at ~= nil
                or row.status ~= 'active' then
                domainError = foundation.error('CHARACTER_NOT_FOUND',
                    'The character is no longer available.')
                return false
            end
            if tonumber(row.version) ~= character.version then
                domainError = foundation.error('CHARACTER_CONFLICT',
                    'The character changed during activation.', { retryable = true })
                return false
            end
            local own
            own, domainError = self:lockCharacterSessions(
                query, session, character.id, expected, authorityGuard)
            if not own then return false end
            local updated = query([[UPDATE `synex_sessions`
                SET `source_value` = COALESCE(?, `source_value`), `source_generation` = ?,
                    `state` = 'ACTIVE', `character_id` = ?, `last_seen_at` = CURRENT_TIMESTAMP(6),
                    `version` = ?
                WHERE `id` = ? AND `user_id` = ? AND `server_instance_id` = ?
                    AND `source_generation` = ? AND (? IS NULL OR `source_value` = ?)
                    AND `state` = 'SELECTING_CHARACTER' AND `character_id` IS NULL
                    AND `closed_at` IS NULL AND `version` = ?]], {
                session.source, session.sourceGeneration, character.id, session.version,
                session.id, session.userId, instanceId, expected.sourceGeneration,
                expected.source, expected.source, expected.version
            })
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed during character activation.', { retryable = true })
                return false
            end
            if affectedRows(updated) ~= 1 then
                domainError = foundation.error('SESSION_CONFLICT',
                    'The durable session changed during character activation.', { retryable = true })
                return false
            end
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return true, nil
    end

    function repository:updateFenced(session, expected, authorityGuard)
        local authority, validationError = sessionAuthority(session)
        if not authority then return nil, validationError end
        if type(expected) ~= 'table' or type(expected.state) ~= 'string'
            or type(expected.version) ~= 'number' or math.type(expected.version) ~= 'integer'
            or type(expected.sourceGeneration) ~= 'number'
            or math.type(expected.sourceGeneration) ~= 'integer' then
            return nil, foundation.error('SESSION_CONFLICT',
                'The expected durable session state is invalid.', { retryable = true })
        end
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            domainError = nil
            local rows = query([[SELECT `id`, `user_id`, `server_instance_id`, `source_value`,
                    `source_generation`, `state`, `character_id`, `version`, `closed_at`
                FROM `synex_sessions` WHERE `id` = ? FOR UPDATE]], { session.id }) or {}
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed while the durable session was locked.', {
                        retryable = true
                    })
                return false
            end
            local row = rows[1]
            local desiredSource = session.source or session.persistedSource or expected.source
            local desired = {
                state = session.state, characterId = session.characterId,
                version = session.version, source = desiredSource,
                sourceGeneration = session.sourceGeneration
            }
            local alreadyDurable = lockedSessionMatches(row, session, desired)
            if not alreadyDurable and not lockedSessionMatches(row, session, expected) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'The durable session changed concurrently.', { retryable = true })
                return false
            end
            local authorized
            authorized, domainError = lockRuntimeAuthority(query, authority, authorityGuard)
            if not authorized then return false end
            if alreadyDurable then return true end
            local updated = query([[UPDATE `synex_sessions`
                SET `source_value` = COALESCE(?, `source_value`), `source_generation` = ?,
                    `state` = ?, `character_id` = ?, `last_seen_at` = CURRENT_TIMESTAMP(6),
                    `version` = ?
                WHERE `id` = ? AND `user_id` = ? AND `server_instance_id` = ?
                    AND `source_generation` = ? AND (? IS NULL OR `source_value` = ?)
                    AND `state` = ? AND ((? IS NULL AND `character_id` IS NULL) OR `character_id` = ?)
                    AND `closed_at` IS NULL AND `version` = ?]], {
                session.source, session.sourceGeneration, session.state, session.characterId,
                session.version, session.id, session.userId, instanceId,
                expected.sourceGeneration, expected.source, expected.source, expected.state,
                expected.characterId, expected.characterId, expected.version
            })
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed during persistence.', { retryable = true })
                return false
            end
            if affectedRows(updated) ~= 1 then
                domainError = foundation.error('SESSION_CONFLICT',
                    'The durable session changed concurrently.', { retryable = true })
                return false
            end
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return true, nil
    end

    function repository:update(session, expected, authorityGuard)
        if type(expected) ~= 'table' then
            return nil, foundation.error('SESSION_FENCE_REQUIRED',
                'Session updates require an exact durable-state fence.')
        end
        return self:updateFenced(session, expected, authorityGuard)
    end

    function repository:getState(sessionId)
        local rows, err = database:query([[SELECT `user_id`, `server_instance_id`, `source_value`,
                `source_generation`, `state`, `character_id`, `version`, `closed_at`
            FROM `synex_sessions` WHERE `id` = ? LIMIT 1]], { sessionId })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        local version = tonumber(row.version)
        if type(row.state) ~= 'string' or not version or math.type(version) ~= 'integer' or version < 1 then
            return nil, foundation.error('INVALID_DATABASE_RESULT', 'The persisted session state is invalid.')
        end
        return {
            userId = row.user_id, serverInstanceId = row.server_instance_id,
            source = tonumber(row.source_value), sourceGeneration = tonumber(row.source_generation),
            state = row.state, characterId = row.character_id, version = version,
            closed = row.closed_at ~= nil
        }, nil
    end

    function repository:close(session, reason)
        if type(session) ~= 'table' or type(session.id) ~= 'string'
            or #session.id < 1 or #session.id > 36
            or type(session.userId) ~= 'string' or #session.userId < 1 or #session.userId > 36 then
            return nil, foundation.error('SESSION_CONFLICT',
                'Session closure requires an exact durable session identity.', { retryable = true })
        end
        local expectedGeneration = session.persistedSourceGeneration or session.sourceGeneration
        local expectedSource = session.persistedSource
        if expectedSource == nil then expectedSource = session.source end
        if type(expectedGeneration) ~= 'number' or math.type(expectedGeneration) ~= 'integer'
            or expectedGeneration < 0 or (expectedSource ~= nil and tonumber(expectedSource) == nil) then
            return nil, foundation.error('SESSION_CONFLICT',
                'Session closure requires an exact source generation.', { retryable = true })
        end
        local closeReason = tostring(reason or 'disconnected'):sub(1, 128)
        local lease = type(session.clusterLease) == 'table' and session.clusterLease or nil
        local leaseName = lease and (lease.name or lease.leaseName) or nil
        local exactLease = lease and type(leaseName) == 'string'
            and leaseName:sub(1, 8) == 'session:'
            and lease.owner == instanceId .. ':' .. session.id
            and type(lease.fencingToken) == 'number'
            and math.type(lease.fencingToken) == 'integer' and lease.fencingToken > 0
        local closureError = nil
        local leaseRetired = false
        local committed, transactionError = database:withTransaction(function(query)
            closureError = nil
            local rows = query([[SELECT `id`, `user_id`, `server_instance_id`, `source_value`,
                    `source_generation`, `closed_at`
                FROM `synex_sessions` WHERE `id` = ? FOR UPDATE]], { session.id }) or {}
            local row = rows[1]
            if not row or row.id ~= session.id or row.user_id ~= session.userId
                or row.server_instance_id ~= instanceId
                or tonumber(row.source_generation) ~= expectedGeneration
                or (expectedSource ~= nil and tonumber(row.source_value) ~= tonumber(expectedSource)) then
                closureError = foundation.error('SESSION_CONFLICT',
                    'The durable session changed before closure.', { retryable = true })
                return false
            end
            if row.closed_at == nil then
                local closed = query([[UPDATE `synex_sessions`
                    SET `state` = 'CLOSED', `closed_at` = CURRENT_TIMESTAMP(6), `close_reason` = ?,
                        `last_seen_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
                    WHERE `id` = ? AND `user_id` = ? AND `server_instance_id` = ?
                        AND `source_generation` = ? AND (? IS NULL OR `source_value` = ?)
                        AND `closed_at` IS NULL]], {
                    closeReason, session.id, session.userId, instanceId, expectedGeneration,
                    expectedSource, expectedSource
                })
                if affectedRows(closed) ~= 1 then
                    closureError = foundation.error('SESSION_CONFLICT',
                        'The durable session changed during closure.', { retryable = true })
                    return false
                end
            end
            if exactLease then
                local retired = query([[UPDATE `synex_cluster_leases`
                    SET `owner_id` = 'retired',
                        `fencing_token` = CASE
                            WHEN `fencing_token` < 18446744073709551615
                                THEN `fencing_token` + 1
                            ELSE `fencing_token`
                        END,
                        `expires_at` = CURRENT_TIMESTAMP(6),
                        `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                    WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?
                        AND `terminal_compaction_at` IS NULL]], {
                    leaseName, lease.owner, lease.fencingToken
                })
                local retiredCount = affectedRows(retired)
                if retiredCount ~= 0 and retiredCount ~= 1 then
                    closureError = foundation.error('DATABASE_RESULT_INVALID',
                        'Session lease retirement returned an invalid mutation count.', {
                            retryable = true
                        })
                    return false
                end
                leaseRetired = retiredCount == 1
            end
            return true
        end)
        if not committed then return nil, closureError or transactionError end
        if leaseRetired then session.clusterLease = nil end
        return true, nil
    end

    function repository:createCharacter(session, input, authorityGuard)
        if type(session) ~= 'table' or type(session.id) ~= 'string'
            or type(session.userId) ~= 'string' then
            return nil, foundation.error('SESSION_CONFLICT',
                'Character creation requires an exact caller session.', { retryable = true })
        end
        if type(input) ~= 'table' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Character input must be an object.')
        end
        local slot = tonumber(input.slot)
        if not slot or math.type(slot) ~= 'integer' or slot < 1 or slot > 32 then
            return nil, foundation.error('CHARACTER_SLOT_UNAVAILABLE',
                'The requested character slot is unavailable.')
        end
        local function validName(value)
            return type(value) == 'string' and #value >= 1 and #value <= 64
                and not value:find('[%z\1-\31\127]')
        end
        if not validName(input.firstName) or not validName(input.lastName) then
            return nil, foundation.error('INVALID_CHARACTER_NAME',
                'Character names must contain between 1 and 64 bytes without control characters.')
        end
        if input.dateOfBirth ~= nil and (type(input.dateOfBirth) ~= 'string'
            or not input.dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$')) then
            return nil, foundation.error('INVALID_DATE_OF_BIRTH',
                'Date of birth must use YYYY-MM-DD.')
        end
        local characterId = foundation.nextId('char')
        local expected = {
            state = 'SELECTING_CHARACTER', characterId = nil,
            version = session.persistedVersion,
            source = session.persistedSource or session.source,
            sourceGeneration = session.persistedSourceGeneration or session.sourceGeneration
        }
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            domainError = nil
            local slotRows = query([[SELECT `slot_limit` FROM `synex_character_slots`
                WHERE `user_id` = ? FOR UPDATE]], { session.userId }) or {}
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed while character slots were locked.', {
                        retryable = true
                    })
                return false
            end
            local slotLimit = slotRows[1] and tonumber(slotRows[1].slot_limit) or nil
            if not slotLimit or math.type(slotLimit) ~= 'integer' or slot > slotLimit then
                domainError = foundation.error('CHARACTER_SLOT_UNAVAILABLE',
                    'The requested character slot is unavailable.')
                return false
            end
            local activeSlot = query([[SELECT `id` FROM `synex_characters`
                WHERE `user_id` = ? AND `slot` = ? AND `deleted_at` IS NULL
                ORDER BY `id` ASC LIMIT 1 FOR UPDATE]], { session.userId, slot }) or {}
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed while the character slot was checked.', {
                        retryable = true
                    })
                return false
            end
            if activeSlot[1] then
                domainError = foundation.error('CHARACTER_SLOT_UNAVAILABLE',
                    'The requested character slot is unavailable.')
                return false
            end
            local own
            own, domainError = self:lockCharacterSessions(
                query, session, characterId, expected, authorityGuard)
            if not own then return false end
            local inserted = query([[INSERT INTO `synex_characters`
                (`id`, `user_id`, `slot`, `status`, `first_name`, `last_name`, `date_of_birth`,
                    `metadata_json`, `version`)
                VALUES (?, ?, ?, 'active', ?, ?, ?, '{}', 1)]], {
                characterId, session.userId, slot, input.firstName, input.lastName, input.dateOfBirth
            })
            if not guardCurrent(authorityGuard) then
                domainError = foundation.error('SESSION_CONFLICT',
                    'Local session authority changed during character creation.', { retryable = true })
                return false
            end
            if affectedRows(inserted) ~= 1 then
                domainError = foundation.error('CHARACTER_CREATE_FAILED',
                    'The character could not be created.', { retryable = true })
                return false
            end
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return {
            id = characterId, userId = session.userId, slot = slot, status = 'active',
            firstName = input.firstName, lastName = input.lastName,
            dateOfBirth = input.dateOfBirth, metadata = {}, version = 1
        }, nil
    end

    return repository
end
