return function(Foundation, modules)
local domainError = Foundation.domainError
local uuidV4 = Foundation.uuidV4
local evaluateCapabilityRules = Foundation.evaluateCapabilityRules

local function createOxmysqlPort(deps)
    local jsonEncode = assert(deps.jsonEncode, 'oxmysql port requires jsonEncode')
    local jsonDecode = assert(deps.jsonDecode, 'oxmysql port requires jsonDecode')
    local random = assert(deps.random, 'oxmysql port requires random')

    local function queryRows(sql, parameters)
        local rows = MySQL.query.await(sql, parameters or {})
        if type(rows) ~= 'table' then
            error('oxmysql query returned an invalid row collection', 0)
        end
        return rows
    end

    local function one(sql, parameters)
        return queryRows(sql, parameters)[1]
    end

    local function many(sql, parameters)
        return queryRows(sql, parameters)
    end

    local function withTransaction(handler)
        if type(MySQL.startTransaction) ~= 'function' then
            return nil, domainError('TRANSACTION_UNAVAILABLE', 'Interactive database transactions are unavailable.', true)
        end
        local committed = MySQL.startTransaction(handler)
        if committed ~= true then
            return nil, domainError('WRITE_CONFLICT', 'The group transaction could not be committed.', true)
        end
        return true, nil
    end

    local function replay(operationName, idempotencyKey, requestFingerprint)
        local row = one([[SELECT `operation_name`, `request_fingerprint`, `state`, `response_json`
            FROM `synex_group_operations` WHERE `idempotency_key` = ?]], { idempotencyKey })
        if not row then return nil, nil end
        if row.operation_name ~= operationName or row.request_fingerprint ~= requestFingerprint then
            return nil, domainError('IDEMPOTENCY_CONFLICT', 'The idempotency key was already used for a different request.')
        end
        if row.state ~= 'completed' or type(row.response_json) ~= 'string' then
            return nil, domainError('OPERATION_IN_PROGRESS', 'The idempotent operation has not completed.', true)
        end
        local response = jsonDecode(row.response_json)
        if type(response) ~= 'table' then
            return nil, domainError('DATABASE_ERROR', 'The stored idempotency response is invalid.')
        end
        return response, nil
    end

    local function execute(operationName, command, response, domainStatements)
        local previous, previousError = replay(operationName, command.idempotencyKey, command.fingerprint)
        if previous or previousError then return previous, previousError end

        local responseJson = jsonEncode(response)
        local statements = {
            {
                query = [[INSERT INTO `synex_group_operations`
                    (`idempotency_key`, `operation_name`, `request_fingerprint`, `state`)
                    VALUES (?, ?, ?, 'pending')]],
                values = { command.idempotencyKey, operationName, command.fingerprint }
            }
        }
        for _, statement in ipairs(domainStatements) do statements[#statements + 1] = statement end
        statements[#statements + 1] = {
            query = [[UPDATE `synex_group_operations`
                SET `state` = 'completed', `response_json` = ?, `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `idempotency_key` = ? AND `operation_name` = ? AND `state` = 'pending']],
            values = { responseJson, command.idempotencyKey, operationName }
        }

        local committed = MySQL.transaction.await(statements)
        if committed == true then return response, nil end
        previous, previousError = replay(operationName, command.idempotencyKey, command.fingerprint)
        if previous or previousError then return previous, previousError end
        return nil, domainError('WRITE_CONFLICT', 'The group write conflicted with current state.', true)
    end

    local port = {}

    function port:createGroup(command)
        local replayed, replayError = replay('create', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        if one('SELECT `public_id` FROM `synex_groups` WHERE `group_key` = ?', { command.groupKey }) then
            return nil, domainError('GROUP_EXISTS', 'A group already uses this group_key.')
        end
        local groupId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = { group_id = groupId, group_key = command.groupKey, status = 'active', version = 1 }
        local eventPayload = jsonEncode({
            group_id = groupId, group_key = command.groupKey, group_type = command.groupType,
            status = 'active', version = 1
        })
        return execute('create', command, response, {
            {
                query = [[INSERT INTO `synex_groups`
                    (`public_id`, `group_key`, `display_name`, `group_type`, `status`, `created_by_ref`, `metadata_json`, `version`)
                    VALUES (?, ?, ?, ?, 'active', ?, ?, 1)]],
                values = { groupId, command.groupKey, command.displayName, command.groupType, command.createdByRef, command.metadataJson }
            },
            {
                query = [[INSERT INTO `synex_group_grades`
                    (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
                    VALUES (?, (SELECT `id` FROM `synex_groups` WHERE `public_id` = ?),
                        'member', 'Member', 0, 'active', 1)]],
                values = { uuidV4(random), groupId }
            },
            {
                query = [[INSERT INTO `synex_group_read_model_versions` (`group_id`, `model_version`, `invalidated_at`)
                    VALUES ((SELECT `id` FROM `synex_groups` WHERE `public_id` = ?), 1, CURRENT_TIMESTAMP(6))]],
                values = { groupId }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.groups.created', 1, ?)]],
                values = { eventId, groupId, eventPayload }
            }
        })
    end

    function port:getGroup(groupId)
        local row = one([[SELECT `group`.`public_id`, `group`.`group_key`, `group`.`display_name`, `group`.`group_type`,
                `group`.`status`, `group`.`created_by_ref`, `group`.`metadata_json`, `group`.`version`,
                `group`.`created_at`, `group`.`updated_at`, `model`.`model_version`
            FROM `synex_groups` AS `group`
            INNER JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
            WHERE `group`.`public_id` = ?]], { groupId })
        if not row then return nil, domainError('GROUP_NOT_FOUND', 'The group does not exist.') end
        return {
            group_id = row.public_id,
            group_key = row.group_key,
            display_name = row.display_name,
            group_type = row.group_type,
            status = row.status,
            created_by_ref = row.created_by_ref,
            metadata_json = row.metadata_json,
            version = tonumber(row.version),
            read_model_version = tonumber(row.model_version),
            created_at = tostring(row.created_at),
            updated_at = tostring(row.updated_at)
        }, nil
    end

    function port:addMembership(command)
        local replayed, replayError = replay('add_membership', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local existing = one([[SELECT `m`.`public_id` FROM `synex_group_memberships` AS `m`
            INNER JOIN `synex_groups` AS `g` ON `g`.`id` = `m`.`group_id`
            WHERE `g`.`public_id` = ? AND `m`.`subject_kind` = ? AND `m`.`subject_ref` = ?]],
            { command.groupId, command.subjectKind, command.subjectId })
        if existing then
            return nil, domainError('MEMBERSHIP_EXISTS', 'The subject already has a membership in this group.')
        end
        if not one([[SELECT `grade`.`id` FROM `synex_group_grades` AS `grade`
                INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`
                WHERE `group`.`public_id` = ? AND `grade`.`grade_key` = ? AND `grade`.`status` = 'active']],
            { command.groupId, command.roleKey }) then
            return nil, domainError('GRADE_NOT_FOUND', 'The requested active grade does not exist in this group.')
        end
        local membershipId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = { membership_id = membershipId, group_id = command.groupId, status = 'active', version = 1 }
        local snapshot = jsonEncode({
            membership_id = membershipId, group_id = command.groupId, subject_kind = command.subjectKind,
            subject_id = command.subjectId, role_key = command.roleKey, status = 'active', version = 1
        })
        return execute('add_membership', command, response, {
            {
                query = 'SELECT `id` FROM `synex_groups` WHERE `public_id` = ? AND `status` = \'active\' FOR UPDATE',
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_memberships`
                    (`public_id`, `group_id`, `subject_kind`, `subject_ref`, `role_key`, `status`, `version`)
                    SELECT ?, `id`, ?, ?, ?, 'active', 1 FROM `synex_groups`
                    WHERE `public_id` = ? AND `status` = 'active']],
                values = { membershipId, command.subjectKind, command.subjectId, command.roleKey, command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_membership_grades`
                    (`membership_id`, `grade_id`, `assigned_by_ref`, `version`)
                    SELECT `membership`.`id`, `grade`.`id`, ?, 1
                    FROM `synex_group_memberships` AS `membership`
                    INNER JOIN `synex_group_grades` AS `grade`
                        ON `grade`.`group_id` = `membership`.`group_id` AND `grade`.`grade_key` = `membership`.`role_key`
                        AND `grade`.`status` = 'active'
                    WHERE `membership`.`public_id` = ?]],
                values = { command.actorRef, membershipId }
            },
            {
                query = [[INSERT INTO `synex_group_membership_events`
                    (`event_id`, `membership_id`, `membership_version`, `event_type`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `membership`.`id` FROM `synex_group_memberships` AS `membership`
                        INNER JOIN `synex_group_membership_grades` AS `assigned`
                            ON `assigned`.`membership_id` = `membership`.`id`
                        WHERE `membership`.`public_id` = ?), 1, 'added', ?, ?)]],
                values = { eventId, membershipId, command.actorRef, snapshot }
            },
            {
                query = [[UPDATE `synex_group_read_model_versions` AS `model`
                    INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `model`.`group_id`
                    SET `model`.`model_version` = `model`.`model_version` + 1,
                        `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group`.`public_id` = ?]],
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.groups.membership_added', 1, ?)]],
                values = { eventId, command.groupId, snapshot }
            }
        })
    end

    local function currentMembership(command)
        return one([[SELECT `m`.`id`, `m`.`public_id`, `m`.`role_key`, `m`.`status`, `m`.`version`
            FROM `synex_group_memberships` AS `m`
            INNER JOIN `synex_groups` AS `g` ON `g`.`id` = `m`.`group_id`
            WHERE `g`.`public_id` = ? AND `m`.`subject_kind` = ? AND `m`.`subject_ref` = ?]],
            { command.groupId, command.subjectKind, command.subjectId })
    end

    function port:changeMembership(command)
        local replayed, replayError = replay('change_membership', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local membership = currentMembership(command)
        if not membership then
            return nil, domainError('MEMBERSHIP_NOT_FOUND', 'The membership does not exist.')
        end
        if membership.status == 'removed' then return nil, domainError('MEMBERSHIP_REMOVED', 'A removed membership cannot be changed.') end
        if not one([[SELECT `grade`.`id` FROM `synex_group_grades` AS `grade`
                INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`
                WHERE `group`.`public_id` = ? AND `grade`.`grade_key` = ? AND `grade`.`status` = 'active']],
            { command.groupId, command.roleKey }) then
            return nil, domainError('GRADE_NOT_FOUND', 'The requested active grade does not exist in this group.')
        end
        local nextVersion = tonumber(membership.version) + 1
        local eventId = uuidV4(random)
        local response = {
            membership_id = membership.public_id, group_id = command.groupId,
            role_key = command.roleKey, status = membership.status, version = nextVersion
        }
        local snapshot = jsonEncode({
            membership_id = membership.public_id, group_id = command.groupId, subject_kind = command.subjectKind,
            subject_id = command.subjectId, role_key = command.roleKey, status = membership.status, version = nextVersion
        })
        return execute('change_membership', command, response, {
            {
                query = 'SELECT `id` FROM `synex_group_memberships` WHERE `id` = ? FOR UPDATE',
                values = { membership.id }
            },
            {
                query = [[UPDATE `synex_group_memberships` SET `role_key` = ?, `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `status` <> 'removed'
                        AND EXISTS (SELECT 1 FROM `synex_group_grades`
                            WHERE `group_id` = `synex_group_memberships`.`group_id`
                                AND `grade_key` = ? AND `status` = 'active')]],
                values = { command.roleKey, membership.id, membership.version, command.roleKey }
            },
            {
                query = [[UPDATE `synex_group_membership_grades` AS `assigned`
                    INNER JOIN `synex_group_grades` AS `grade`
                        ON `grade`.`group_id` = (SELECT `group_id` FROM `synex_group_memberships` WHERE `id` = ?)
                        AND `grade`.`grade_key` = ? AND `grade`.`status` = 'active'
                    SET `assigned`.`grade_id` = `grade`.`id`, `assigned`.`assigned_by_ref` = ?,
                        `assigned`.`version` = `assigned`.`version` + 1,
                        `assigned`.`assigned_at` = CURRENT_TIMESTAMP(6)
                    WHERE `assigned`.`membership_id` = ?]],
                values = { membership.id, command.roleKey, command.actorRef, membership.id }
            },
            {
                query = [[INSERT INTO `synex_group_membership_events`
                    (`event_id`, `membership_id`, `membership_version`, `event_type`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `membership`.`id` FROM `synex_group_memberships` AS `membership`
                        INNER JOIN `synex_group_membership_grades` AS `assigned`
                            ON `assigned`.`membership_id` = `membership`.`id`
                        INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`id` = `assigned`.`grade_id`
                        WHERE `membership`.`id` = ? AND `membership`.`version` = ?
                            AND `membership`.`role_key` = ? AND `grade`.`grade_key` = ?),
                        ?, 'role_changed', ?, ?)]],
                values = {
                    eventId, membership.id, nextVersion, command.roleKey, command.roleKey,
                    nextVersion, command.actorRef, snapshot
                }
            },
            {
                query = [[UPDATE `synex_group_read_model_versions` AS `model`
                    INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `model`.`group_id`
                    SET `model`.`model_version` = `model`.`model_version` + 1,
                        `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group`.`public_id` = ?]],
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.groups.membership_changed', 1, ?)]],
                values = { eventId, command.groupId, snapshot }
            }
        })
    end

    function port:removeMembership(command)
        local replayed, replayError = replay('remove_membership', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local membership = currentMembership(command)
        if not membership then
            return nil, domainError('MEMBERSHIP_NOT_FOUND', 'The membership does not exist.')
        end
        if membership.status == 'removed' then return nil, domainError('MEMBERSHIP_REMOVED', 'The membership is already removed.') end
        local nextVersion = tonumber(membership.version) + 1
        local eventId = uuidV4(random)
        local response = { membership_id = membership.public_id, group_id = command.groupId, status = 'removed', version = nextVersion }
        local snapshot = jsonEncode({
            membership_id = membership.public_id, group_id = command.groupId, subject_kind = command.subjectKind,
            subject_id = command.subjectId, role_key = membership.role_key, status = 'removed', version = nextVersion
        })
        return execute('remove_membership', command, response, {
            {
                query = 'SELECT `id` FROM `synex_group_memberships` WHERE `id` = ? FOR UPDATE',
                values = { membership.id }
            },
            {
                query = [[UPDATE `synex_group_memberships` SET `status` = 'removed', `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `status` <> 'removed']],
                values = { membership.id, membership.version }
            },
            {
                query = [[INSERT INTO `synex_group_membership_events`
                    (`event_id`, `membership_id`, `membership_version`, `event_type`, `actor_ref`, `snapshot_json`)
                    VALUES (?, (SELECT `id` FROM `synex_group_memberships`
                        WHERE `id` = ? AND `version` = ? AND `status` = 'removed'), ?, 'removed', ?, ?)]],
                values = { eventId, membership.id, nextVersion, nextVersion, command.actorRef, snapshot }
            },
            {
                query = [[UPDATE `synex_group_read_model_versions` AS `model`
                    INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `model`.`group_id`
                    SET `model`.`model_version` = `model`.`model_version` + 1,
                        `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group`.`public_id` = ?]],
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.groups.membership_removed', 1, ?)]],
                values = { eventId, command.groupId, snapshot }
            }
        })
    end

    function port:createGrade(command)
        local replayed, replayError = replay('create_grade', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local group = one('SELECT `id`, `status` FROM `synex_groups` WHERE `public_id` = ?', { command.groupId })
        if not group then return nil, domainError('GROUP_NOT_FOUND', 'The group does not exist.') end
        if group.status ~= 'active' then return nil, domainError('GROUP_UNAVAILABLE', 'The group is not active.') end
        local existing = one([[SELECT `grade`.`public_id` FROM `synex_group_grades` AS `grade`
            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`
            WHERE `group`.`public_id` = ? AND `grade`.`grade_key` = ?]], { command.groupId, command.gradeKey })
        if existing then
            return nil, domainError('GRADE_EXISTS', 'The group already has this grade_key.')
        end
        local gradeId = uuidV4(random)
        local eventId = uuidV4(random)
        local response = {
            grade_id = gradeId, group_id = command.groupId, grade_key = command.gradeKey,
            display_name = command.displayName, rank_value = command.rankValue, status = 'active', version = 1
        }
        local snapshot = jsonEncode(response)
        return execute('create_grade', command, response, {
            {
                query = 'SELECT `id` FROM `synex_groups` WHERE `public_id` = ? AND `status` = \'active\' FOR UPDATE',
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_grades`
                    (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
                    SELECT ?, `id`, ?, ?, ?, 'active', 1 FROM `synex_groups`
                    WHERE `public_id` = ? AND `status` = 'active']],
                values = { gradeId, command.gradeKey, command.displayName, command.rankValue, command.groupId }
            },
            {
                query = [[UPDATE `synex_group_read_model_versions` AS `model`
                    INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `model`.`group_id`
                    SET `model`.`model_version` = `model`.`model_version` + 1,
                        `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group`.`public_id` = ?]],
                values = { command.groupId }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, (SELECT `group`.`public_id` FROM `synex_groups` AS `group`
                        INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`group_id` = `group`.`id`
                        WHERE `grade`.`public_id` = ?), 'synex.groups.grade_created', 1, ?)]],
                values = { eventId, gradeId, snapshot }
            }
        })
    end

    function port:setGradeCapability(command)
        local replayed, replayError = replay('set_grade_capability', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local grade = one([[SELECT `grade`.`id`, `grade`.`public_id`, `group`.`public_id` AS `group_public_id`
                FROM `synex_group_grades` AS `grade`
                INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`
                WHERE `grade`.`public_id` = ? AND `grade`.`status` = 'active']], { command.gradeId })
        if not grade then return nil, domainError('GRADE_NOT_FOUND', 'The active grade does not exist.') end
        local existing = one([[SELECT `id` FROM `synex_group_grade_capabilities`
            WHERE `grade_id` = ? AND `capability_pattern` = ?]], { grade.id, command.capability })
        if not existing then
            local count = one('SELECT COUNT(*) AS `count` FROM `synex_group_grade_capabilities` WHERE `grade_id` = ?', { grade.id })
            if tonumber(count and count.count) >= 128 then
                return nil, domainError('GRADE_CAPABILITY_LIMIT', 'A grade supports at most 128 capability rules.')
            end
        end
        local eventId = uuidV4(random)
        local response = {
            grade_id = command.gradeId, group_id = grade.group_public_id,
            capability = command.capability, effect = command.effect
        }
        local snapshot = jsonEncode(response)
        return execute('set_grade_capability', command, response, {
            {
                query = 'SELECT `id` FROM `synex_group_grades` WHERE `id` = ? AND `status` = \'active\' FOR UPDATE',
                values = { grade.id }
            },
            {
                query = [[INSERT INTO `synex_group_grade_capabilities`
                    (`grade_id`, `capability_pattern`, `effect`, `version`)
                    VALUES (?, ?, ?, 1)
                    ON DUPLICATE KEY UPDATE `effect` = ?, `version` = `version` + 1,
                        `updated_at` = CURRENT_TIMESTAMP(6)]],
                values = { grade.id, command.capability, command.effect, command.effect }
            },
            {
                query = [[UPDATE `synex_group_read_model_versions` AS `model`
                    INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`group_id` = `model`.`group_id`
                    SET `model`.`model_version` = `model`.`model_version` + 1,
                        `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `grade`.`id` = ?]],
                values = { grade.id }
            },
            {
                query = [[INSERT INTO `synex_group_outbox`
                    (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                    VALUES (?, ?, 'synex.groups.grade_capability_set', 1, ?)]],
                values = { eventId, grade.group_public_id, snapshot }
            }
        })
    end

    function port:setPrimaryMembership(command)
        local replayed, replayError = replay('set_primary_membership', command.idempotencyKey, command.fingerprint)
        if replayed or replayError then return replayed, replayError end
        local membership = one([[SELECT `membership`.`id`, `membership`.`public_id`, `membership`.`status`,
                `group`.`public_id` AS `group_public_id`
            FROM `synex_group_memberships` AS `membership`
            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `membership`.`group_id`
            WHERE `group`.`public_id` = ? AND `membership`.`subject_kind` = ?
                AND `membership`.`subject_ref` = ?]], { command.groupId, command.subjectKind, command.subjectId })
        if not membership or membership.status ~= 'active' then
            return nil, domainError('MEMBERSHIP_NOT_FOUND', 'An active membership is required before it can become primary.')
        end
        local current = one([[SELECT `primary`.`membership_id`, `primary`.`version`,
                `membership`.`public_id`, `group`.`public_id` AS `group_public_id`
            FROM `synex_group_primary_memberships` AS `primary`
            INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`id` = `primary`.`membership_id`
            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `membership`.`group_id`
            WHERE `primary`.`subject_kind` = ? AND `primary`.`subject_ref` = ?]],
            { command.subjectKind, command.subjectId })
        local nextVersion = current and tonumber(current.version) + 1 or 1
        local eventId = uuidV4(random)
        local response = {
            membership_id = membership.public_id, group_id = membership.group_public_id,
            subject_kind = command.subjectKind, subject_id = command.subjectId,
            primary_version = nextVersion
        }
        local snapshot = jsonEncode(response)
        local statements = {
            {
                query = 'SELECT `id` FROM `synex_group_memberships` WHERE `id` = ? AND `status` = \'active\' FOR UPDATE',
                values = { membership.id }
            }
        }
        if current then
            statements[#statements + 1] = {
                query = [[UPDATE `synex_group_primary_memberships`
                    SET `membership_id` = ?, `assigned_by_ref` = ?, `version` = `version` + 1,
                        `assigned_at` = CURRENT_TIMESTAMP(6)
                    WHERE `subject_kind` = ? AND `subject_ref` = ? AND `version` = ?]],
                values = { membership.id, command.actorRef, command.subjectKind, command.subjectId, current.version }
            }
        else
            statements[#statements + 1] = {
                query = [[INSERT INTO `synex_group_primary_memberships`
                    (`subject_kind`, `subject_ref`, `membership_id`, `assigned_by_ref`, `version`)
                    VALUES (?, ?, ?, ?, 1)]],
                values = { command.subjectKind, command.subjectId, membership.id, command.actorRef }
            }
        end
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_group_primary_membership_events`
                (`event_id`, `subject_kind`, `subject_ref`, `previous_membership_id`, `membership_id`,
                    `primary_version`, `actor_ref`, `snapshot_json`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
            values = {
                eventId, command.subjectKind, command.subjectId, current and current.membership_id or nil,
                membership.id, nextVersion, command.actorRef, snapshot
            }
        }
        statements[#statements + 1] = {
            query = [[UPDATE `synex_group_read_model_versions` AS `model`
                INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`group_id` = `model`.`group_id`
                SET `model`.`model_version` = `model`.`model_version` + 1,
                    `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                WHERE `membership`.`id` IN (?, ?)]],
            values = { membership.id, current and current.membership_id or nil }
        }
        statements[#statements + 1] = {
            query = [[INSERT INTO `synex_group_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.groups.primary_membership_set', 1, ?)]],
            values = { eventId, membership.group_public_id, snapshot }
        }
        return execute('set_primary_membership', command, response, statements)
    end

    function port:getReadModel(groupId, subjectKind, subjectId)
        local membership = one([[SELECT `group`.`public_id` AS `group_public_id`, `group`.`group_key`,
                `model`.`model_version`, `model`.`invalidated_at`, `membership`.`public_id` AS `membership_public_id`,
                `membership`.`status` AS `membership_status`, `membership`.`version` AS `membership_version`,
                `grade`.`public_id` AS `grade_public_id`, `grade`.`grade_key`, `grade`.`display_name` AS `grade_display_name`,
                `grade`.`rank_value`, `grade`.`version` AS `grade_version`,
                CASE WHEN `primary`.`membership_id` = `membership`.`id` THEN 1 ELSE 0 END AS `is_primary`,
                `primary`.`version` AS `primary_version`
            FROM `synex_groups` AS `group`
            INNER JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
            INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`group_id` = `group`.`id`
                AND `membership`.`subject_kind` = ? AND `membership`.`subject_ref` = ?
            INNER JOIN `synex_group_membership_grades` AS `assigned` ON `assigned`.`membership_id` = `membership`.`id`
            INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`id` = `assigned`.`grade_id`
            LEFT JOIN `synex_group_primary_memberships` AS `primary`
                ON `primary`.`subject_kind` = `membership`.`subject_kind`
                AND `primary`.`subject_ref` = `membership`.`subject_ref`
            WHERE `group`.`public_id` = ? AND `membership`.`status` = 'active' AND `grade`.`status` = 'active']],
            { subjectKind, subjectId, groupId })
        if not membership then return nil, domainError('MEMBERSHIP_NOT_FOUND', 'The membership read model does not exist.') end
        local rules = many([[SELECT `capability_pattern`, `effect`, `version`
            FROM `synex_group_grade_capabilities`
            WHERE `grade_id` = (SELECT `id` FROM `synex_group_grades` WHERE `public_id` = ?)
            ORDER BY `capability_pattern` ASC LIMIT 129]], { membership.grade_public_id })
        if #rules > 128 then return nil, domainError('READ_MODEL_TOO_LARGE', 'The grade capability read model exceeds 128 rules.') end
        local capabilities = {}
        for _, rule in ipairs(rules) do
            capabilities[#capabilities + 1] = {
                capability = rule.capability_pattern, effect = rule.effect, version = tonumber(rule.version)
            }
        end
        return {
            group_id = membership.group_public_id, group_key = membership.group_key,
            read_model_version = tonumber(membership.model_version), invalidated_at = tostring(membership.invalidated_at),
            membership_id = membership.membership_public_id, membership_status = membership.membership_status,
            membership_version = tonumber(membership.membership_version), grade_id = membership.grade_public_id,
            grade_key = membership.grade_key, grade_display_name = membership.grade_display_name,
            rank_value = tonumber(membership.rank_value), grade_version = tonumber(membership.grade_version),
            is_primary = tonumber(membership.is_primary) == 1, primary_version = tonumber(membership.primary_version),
            capabilities = capabilities
        }, nil
    end

    function port:checkCapability(groupId, subjectKind, subjectId, capability)
        local model, modelError = self:getReadModel(groupId, subjectKind, subjectId)
        if not model then return nil, modelError end
        local allowed, denied, matched = evaluateCapabilityRules(model.capabilities, capability)
        return {
            group_id = groupId, membership_id = model.membership_id, grade_id = model.grade_id,
            capability = capability, allowed = allowed and not denied, denied = denied,
            read_model_version = model.read_model_version, matched_rules = matched
        }, nil
    end

    assert(type(modules) == 'table' and type(modules.observability) == 'function',
        'synex_groups persistence observability module is required')
    modules.observability(port, {
        domainError = domainError,
        jsonEncode = jsonEncode,
        many = many,
        one = one,
        random = random,
        uuidV4 = uuidV4,
        withTransaction = withTransaction,
    })

    return port
end

return createOxmysqlPort
end
