return function(Foundation)
local handlers = { read = {}, execute = {} }
local MAXIMUM_PUBLIC_METADATA_BYTES = 16384

local function decodeObject(runtime, value, field)
    if type(value) == 'string' and #value > MAXIMUM_PUBLIC_METADATA_BYTES then
        return nil, Foundation.domainError('READ_MODEL_TOO_LARGE',
            field .. ' exceeds its supported read bound.')
    end
    if type(value) ~= 'string' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            field .. ' contains invalid JSON.', true)
    end
    local decodedOk, decoded = pcall(runtime.jsonDecode, value)
    if not decodedOk or type(decoded) ~= 'table'
        or Foundation.jsonContainerKind(decoded) == 'array' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            field .. ' contains invalid JSON.', true)
    end
    for key in next, decoded do
        if type(key) ~= 'string' then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                field .. ' must contain an object.', true)
        end
    end
    local copiedOk, copied = pcall(Foundation.copyPlain, decoded, {
        maximumDepth = 8,
        maximumKeys = 128,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not copiedOk then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            field .. ' exceeds its supported bound.', true)
    end
    return copied, nil
end

local function assignmentView(runtime, row, includeMetadata)
    local view = {
        assignment_id = row.assignment_id,
        group_id = row.group_id,
        parent_assignment_id = row.parent_assignment_id,
        name = row.name,
        type = row.assignment_type,
        status = row.status,
        member_limit = tonumber(row.member_limit),
        member_count = tonumber(row.member_count) or 0,
        starts_at = row.starts_at,
        ends_at = row.ends_at,
        version = tonumber(row.version)
    }
    if includeMetadata then
        local metadata, metadataError = decodeObject(
            runtime, row.metadata_json, 'Assignment metadata')
        if not metadata then return nil, metadataError end
        view.metadata = metadata
    end
    return view, nil
end

local function missingAssignment()
    return nil, Foundation.domainError('ASSIGNMENT_NOT_FOUND',
        'The assignment does not exist.')
end

local function concealedAssignmentAccess(accessError)
    if type(accessError) == 'table'
        and (accessError.retryable == true
            or accessError.code == 'CORE_UNAVAILABLE'
            or accessError.code == 'DATABASE_ERROR'
            or accessError.code == 'DATABASE_RESULT_INVALID') then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'Assignment access could not be evaluated.', true)
    end
    return missingAssignment()
end

function handlers.read.assignments_get(tx, request, runtime)
    local row = tx.one([[SELECT `assignment`.`public_id` AS `assignment_id`,
            `group_record`.`public_id` AS `group_id`,
            `parent`.`public_id` AS `parent_assignment_id`,
            `assignment`.`display_name` AS `name`,
            `assignment`.`assignment_type`, `assignment`.`status`,
            `assignment`.`member_limit`, `assignment`.`metadata_json`,
            DATE_FORMAT(`assignment`.`valid_from`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `starts_at`,
            DATE_FORMAT(`assignment`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `ends_at`,
            `assignment`.`version`,
            (SELECT COUNT(*) FROM `synex_group_assignment_members` AS `participant`
                WHERE `participant`.`assignment_id` = `assignment`.`id`
                    AND `participant`.`active_marker` = 1) AS `member_count`
        FROM `synex_group_assignments` AS `assignment`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `assignment`.`group_id`
        LEFT JOIN `synex_group_assignments` AS `parent`
            ON `parent`.`id` = `assignment`.`parent_assignment_id`
        WHERE `assignment`.`public_id` = ?]], { request.assignment_id })
    if not row then
        return missingAssignment()
    end
    local actor, authorizationError = runtime.authorize(
        tx, row.group_id, request.actor_character_id,
        'synex.groups.assignments.read', 'group')
    if not actor then return concealedAssignmentAccess(authorizationError) end
    return assignmentView(runtime, row, true)
end

function handlers.read.assignments_list(tx, request, runtime)
    local _, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.assignments.read', 'group')
    if authorizationError then return nil, authorizationError end
    local group, groupError = runtime.requireGroup(tx, request.group_id, false)
    if not group then return nil, groupError end
    local limit = tonumber(request.limit) or 40
    local rows = tx.many([[SELECT `assignment`.`public_id` AS `assignment_id`,
            `group_record`.`public_id` AS `group_id`,
            `parent`.`public_id` AS `parent_assignment_id`,
            `assignment`.`display_name` AS `name`,
            `assignment`.`assignment_type`, `assignment`.`status`,
            `assignment`.`member_limit`,
            DATE_FORMAT(`assignment`.`valid_from`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `starts_at`,
            DATE_FORMAT(`assignment`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `ends_at`,
            `assignment`.`version`,
            (SELECT COUNT(*) FROM `synex_group_assignment_members` AS `participant`
                WHERE `participant`.`assignment_id` = `assignment`.`id`
                    AND `participant`.`active_marker` = 1) AS `member_count`
        FROM `synex_group_assignments` AS `assignment`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `assignment`.`group_id`
        LEFT JOIN `synex_group_assignments` AS `parent`
            ON `parent`.`id` = `assignment`.`parent_assignment_id`
        WHERE `assignment`.`group_id` = ?
            AND (? IS NULL OR `assignment`.`status` = ?)
            AND (? IS NULL OR `assignment`.`public_id` > ?)
        ORDER BY `assignment`.`public_id` ASC LIMIT ?]], {
        group.id, request.status, request.status,
        request.cursor, request.cursor, limit + 1
    })
    local items = {}
    for index = 1, math.min(#rows, limit) do
        local item, itemError = assignmentView(runtime, rows[index], false)
        if not item then return nil, itemError end
        items[index] = item
    end
    return {
        items = items,
        next_cursor = #rows > limit and items[#items].assignment_id or nil,
        truncated = #rows > limit
    }, nil
end

local function dutyView(row)
    return {
        duty_session_id = row.duty_session_id,
        membership_id = row.membership_id,
        group_id = row.group_id,
        state = row.state,
        status = row.status,
        assignment_id = row.assignment_id,
        counts_as_on_duty = row.counts_as_on_duty == true
            or tonumber(row.counts_as_on_duty) == 1,
        started_at = row.started_at,
        ended_at = row.ended_at,
        version = tonumber(row.version)
    }
end

function handlers.read.duty_list(tx, request, runtime)
    local _, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.duty.read', 'group')
    if authorizationError then return nil, authorizationError end
    local group, groupError = runtime.requireGroup(tx, request.group_id, false)
    if not group then return nil, groupError end
    local limit = tonumber(request.limit) or 40
    local rows = tx.many([[SELECT `session`.`public_id` AS `duty_session_id`,
            `membership`.`public_id` AS `membership_id`,
            `group_record`.`public_id` AS `group_id`,
            `session`.`state_key` AS `state`, `session`.`status`,
            `assignment`.`public_id` AS `assignment_id`,
            CASE WHEN `state`.`status` = 'active'
                    AND `allowed_state`.`state_key` IS NOT NULL
                    AND `state`.`counts_as_on_duty` = 1
                THEN 1 ELSE 0 END AS `counts_as_on_duty`,
            DATE_FORMAT(`session`.`started_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `started_at`,
            DATE_FORMAT(`session`.`ended_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `ended_at`,
            `session`.`version`
        FROM `synex_group_duty_sessions` AS `session`
        INNER JOIN `synex_group_memberships` AS `membership`
            ON `membership`.`id` = `session`.`membership_id`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `membership`.`group_id`
        INNER JOIN `synex_group_organization_profiles` AS `organization`
            ON `organization`.`group_id` = `group_record`.`id`
        LEFT JOIN `synex_group_assignments` AS `assignment`
            ON `assignment`.`id` = `session`.`assignment_id`
        LEFT JOIN `synex_group_duty_states` AS `state`
            ON `state`.`state_key` = `session`.`state_key`
        LEFT JOIN `synex_group_type_duty_states` AS `allowed_state`
            ON `allowed_state`.`group_type_id` = `organization`.`group_type_id`
            AND `allowed_state`.`state_key` = `session`.`state_key`
        WHERE `membership`.`group_id` = ?
            AND (? IS NULL OR `session`.`status` = ?)
            AND (? IS NULL OR `membership`.`public_id` = ?)
            AND (? IS NULL OR `session`.`public_id` > ?)
        ORDER BY `session`.`public_id` ASC LIMIT ?]], {
        group.id, request.status, request.status,
        request.membership_id, request.membership_id,
        request.cursor, request.cursor, limit + 1
    })
    local items = {}
    for index = 1, math.min(#rows, limit) do
        items[index] = dutyView(rows[index])
    end
    return {
        items = items,
        next_cursor = #rows > limit and items[#items].duty_session_id or nil,
        truncated = #rows > limit
    }, nil
end

function handlers.read.self_snapshot(tx, request, runtime)
    local limit = tonumber(request.limit) or 8
    local rows = tx.many([[SELECT `membership`.`id` AS `membership_internal_id`,
            `membership`.`public_id` AS `membership_id`,
            `group_record`.`public_id` AS `group_id`,
            `group_record`.`display_name` AS `group_name`,
            `type_record`.`type_key` AS `group_type`,
            `profile`.`lifecycle_state` AS `membership_status`,
            `grade`.`public_id` AS `grade_id`, `grade`.`grade_key`,
            `grade`.`display_name` AS `grade_name`, `grade`.`rank_value` AS `grade_rank`,
            `session`.`public_id` AS `duty_session_id`,
            `session`.`state_key` AS `duty_state`,
            `assignment`.`public_id` AS `duty_assignment_id`,
            `session`.`version` AS `duty_version`,
            CASE WHEN `duty_state`.`status` = 'active'
                    AND `allowed_duty_state`.`state_key` IS NOT NULL
                    AND `duty_state`.`counts_as_on_duty` = 1
                THEN 1 ELSE 0 END AS `duty_counts_as_on_duty`
        FROM `synex_group_memberships` AS `membership`
        INNER JOIN `synex_group_membership_profiles` AS `profile`
            ON `profile`.`membership_id` = `membership`.`id`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `membership`.`group_id`
        INNER JOIN `synex_group_organization_profiles` AS `organization`
            ON `organization`.`group_id` = `group_record`.`id`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `organization`.`group_type_id`
        LEFT JOIN `synex_group_membership_grades` AS `membership_grade`
            ON `membership_grade`.`membership_id` = `membership`.`id`
        LEFT JOIN `synex_group_grades` AS `grade`
            ON `grade`.`id` = `membership_grade`.`grade_id` AND `grade`.`status` = 'active'
        LEFT JOIN `synex_group_duty_sessions` AS `session`
            ON `session`.`membership_id` = `membership`.`id` AND `session`.`status` = 'open'
        LEFT JOIN `synex_group_assignments` AS `assignment`
            ON `assignment`.`id` = `session`.`assignment_id`
        LEFT JOIN `synex_group_duty_states` AS `duty_state`
            ON `duty_state`.`state_key` = `session`.`state_key`
        LEFT JOIN `synex_group_type_duty_states` AS `allowed_duty_state`
            ON `allowed_duty_state`.`group_type_id` = `organization`.`group_type_id`
            AND `allowed_duty_state`.`state_key` = `session`.`state_key`
        WHERE `profile`.`character_id` = ?
            AND `profile`.`visibility` <> 'server_only'
            AND `membership`.`status` <> 'removed'
            AND `profile`.`lifecycle_state` NOT IN
                ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
            AND `organization`.`lifecycle_state` NOT IN
                ('ARCHIVED', 'DISSOLVING', 'DELETED')
            AND (? IS NULL OR `membership`.`public_id` > ?)
        ORDER BY `membership`.`public_id` ASC LIMIT ?]], {
        request.actor_character_id, request.cursor, request.cursor, limit + 1
    })
    local selectedCount = math.min(#rows, limit)
    local internalIds, byInternal = {}, {}
    for index = 1, selectedCount do
        local internalId = tonumber(rows[index].membership_internal_id)
        if not internalId or math.type(internalId) ~= 'integer' or internalId < 1 then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The self membership view contains an invalid identifier.', true)
        end
        internalIds[#internalIds + 1] = internalId
        byInternal[internalId] = { roles = {}, truncated = false }
    end
    if #internalIds > 0 then
        local placeholders = {}
        for index = 1, #internalIds do placeholders[index] = '?' end
        local roleRows = tx.many(([=[SELECT `ranked`.`membership_id`,
                `ranked`.`role_id`, `ranked`.`role_key`, `ranked`.`role_name`,
                `ranked`.`valid_until`
            FROM (SELECT `assignment`.`membership_id`,
                    `role`.`public_id` AS `role_id`, `role`.`role_key`,
                    `role`.`display_name` AS `role_name`,
                    DATE_FORMAT(`assignment`.`valid_until`,
                        '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `valid_until`,
                    ROW_NUMBER() OVER (PARTITION BY `assignment`.`membership_id`
                        ORDER BY `role`.`role_key`, `assignment`.`id`) AS `role_rank`
                FROM `synex_group_membership_roles` AS `assignment`
                INNER JOIN `synex_group_roles` AS `role`
                    ON `role`.`id` = `assignment`.`role_id`
                WHERE `assignment`.`membership_id` IN (%s)
                    AND `assignment`.`status` = 'active'
                    AND `assignment`.`valid_from` <= CURRENT_TIMESTAMP(6)
                    AND (`assignment`.`valid_until` IS NULL
                        OR `assignment`.`valid_until` > CURRENT_TIMESTAMP(6))
                    AND `role`.`status` = 'active') AS `ranked`
            WHERE `ranked`.`role_rank` <= 9
            ORDER BY `ranked`.`membership_id`, `ranked`.`role_rank`
            LIMIT 72]=]):format(table.concat(placeholders, ',')), internalIds)
        if #roleRows > #internalIds * 9 then
            return nil, Foundation.domainError('READ_MODEL_TOO_LARGE',
                'The self role view exceeds its supported bound.')
        end
        for _, role in ipairs(roleRows) do
            local bucket = byInternal[tonumber(role.membership_id)]
            if not bucket then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'The self role view references an unknown membership.', true)
            end
            if #bucket.roles < 8 then
                bucket.roles[#bucket.roles + 1] = {
                    role_id = role.role_id,
                    key = role.role_key,
                    name = role.role_name,
                    valid_until = role.valid_until
                }
            else
                bucket.truncated = true
            end
        end
    end
    local items = {}
    for index = 1, selectedCount do
        local row = rows[index]
        local bucket = byInternal[tonumber(row.membership_internal_id)]
        local item = {
            membership_id = row.membership_id,
            group = {
                group_id = row.group_id,
                type = row.group_type,
                name = row.group_name
            },
            status = row.membership_status,
            roles = bucket.roles,
            roles_truncated = bucket.truncated
        }
        if row.grade_id ~= nil then
            item.grade = {
                grade_id = row.grade_id,
                key = row.grade_key,
                name = row.grade_name,
                rank = tonumber(row.grade_rank)
            }
        end
        if row.duty_session_id ~= nil then
            item.duty = {
                duty_session_id = row.duty_session_id,
                state = row.duty_state,
                counts_as_on_duty = row.duty_counts_as_on_duty == true
                    or tonumber(row.duty_counts_as_on_duty) == 1,
                assignment_id = row.duty_assignment_id,
                version = tonumber(row.duty_version)
            }
        end
        items[index] = item
    end
    return {
        items = items,
        next_cursor = #rows > limit and items[#items].membership_id or nil,
        truncated = #rows > limit
    }, nil
end

function handlers.read.compatibility_snapshot(tx, request, runtime)
    local limit = tonumber(request.limit) or 8
    local snapshot, snapshotError = handlers.read.self_snapshot(tx, {
        actor_character_id = request.actor_character_id,
        cursor = request.cursor,
        limit = limit
    }, runtime)
    if not snapshot then return nil, snapshotError end
    if #snapshot.items == 0 then
        return { items = {}, next_cursor = snapshot.next_cursor, truncated = snapshot.truncated }, nil
    end

    local placeholders, parameters = {}, {}
    for index, item in ipairs(snapshot.items) do
        placeholders[index] = '?'
        parameters[index] = item.membership_id
    end
    parameters[#parameters + 1] = request.actor_character_id
    local rows = tx.many(([=[SELECT `membership`.`public_id` AS `membership_id`,
            `membership`.`version` AS `membership_version`,
            `profile`.`version` AS `membership_profile_version`,
            `organization`.`slug` AS `group_key`,
            `organization`.`label` AS `group_label`,
            `organization`.`version` AS `group_version`,
            CASE WHEN `primary_membership`.`membership_id` = `membership`.`id`
                THEN 1 ELSE 0 END AS `is_primary`,
            `primary_membership`.`version` AS `primary_version`
        FROM `synex_group_memberships` AS `membership`
        INNER JOIN `synex_group_membership_profiles` AS `profile`
            ON `profile`.`membership_id` = `membership`.`id`
        INNER JOIN `synex_group_organization_profiles` AS `organization`
            ON `organization`.`group_id` = `membership`.`group_id`
        LEFT JOIN `synex_group_primary_memberships_by_type` AS `primary_membership`
            ON `primary_membership`.`character_id` = `profile`.`character_id`
            AND `primary_membership`.`group_type_id` = `organization`.`group_type_id`
        WHERE `membership`.`public_id` IN (%s)
            AND `profile`.`character_id` = ?
        ORDER BY `membership`.`public_id` ASC
        LIMIT 8]=]):format(table.concat(placeholders, ',')), parameters)

    if #rows ~= #snapshot.items then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The compatibility membership view is incomplete.', true)
    end
    local detailsByMembership = {}
    for _, row in ipairs(rows) do
        if detailsByMembership[row.membership_id] ~= nil then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The compatibility membership view is ambiguous.', true)
        end
        local membershipVersion = tonumber(row.membership_version)
        local profileVersion = tonumber(row.membership_profile_version)
        local groupVersion = tonumber(row.group_version)
        local primaryVersion = row.primary_version ~= nil and tonumber(row.primary_version) or nil
        if type(row.membership_id) ~= 'string' or type(row.group_key) ~= 'string'
            or type(row.group_label) ~= 'string'
            or not membershipVersion or math.type(membershipVersion) ~= 'integer'
            or not profileVersion or math.type(profileVersion) ~= 'integer'
            or not groupVersion or math.type(groupVersion) ~= 'integer'
            or primaryVersion ~= nil and math.type(primaryVersion) ~= 'integer' then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The compatibility membership view contains invalid revisions.', true)
        end
        detailsByMembership[row.membership_id] = {
            membership_version = membershipVersion,
            membership_profile_version = profileVersion,
            group_version = groupVersion,
            primary_version = primaryVersion,
            group_key = row.group_key,
            group_label = row.group_label,
            is_primary = row.is_primary == true or tonumber(row.is_primary) == 1
        }
    end
    for _, item in ipairs(snapshot.items) do
        local detail = detailsByMembership[item.membership_id]
        if not detail then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The compatibility membership view references an unknown membership.', true)
        end
        item.membership_version = detail.membership_version
        item.membership_profile_version = detail.membership_profile_version
        item.group_version = detail.group_version
        item.primary_version = detail.primary_version
        item.is_primary = detail.is_primary
        item.group.key = detail.group_key
        item.group.label = detail.group_label
    end
    return snapshot, nil
end

return handlers
end
