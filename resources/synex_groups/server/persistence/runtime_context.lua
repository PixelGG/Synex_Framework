return function(Foundation)
local function createRuntimeContextLoader(deps)
    deps = deps or {}
    local query = assert(Foundation.isCallable(deps.query) and deps.query,
        'groups runtime context loader requires query')
    local requestedMaximum = tonumber(deps.maximumMembershipsPerCharacter)
    if not requestedMaximum or math.type(requestedMaximum) ~= 'integer' then
        requestedMaximum = 1024
    end
    local maximumMemberships = math.max(1, math.min(requestedMaximum, 4096))
    local sql = ([[SELECT
            `profile`.`character_id`,
            `membership`.`public_id` AS `membership_id`,
            `group_record`.`public_id` AS `group_id`,
            `profile`.`lifecycle_state` AS `membership_state`,
            `session`.`public_id` AS `duty_session_id`,
            `session`.`state_key` AS `duty_state`,
            `session`.`version` AS `duty_version`,
            `assignment`.`public_id` AS `duty_assignment_id`,
            CASE WHEN `duty_state`.`status` = 'active'
                    AND `allowed_duty_state`.`state_key` IS NOT NULL
                    AND `duty_state`.`counts_as_on_duty` = 1
                THEN 1 ELSE 0 END AS `duty_counts_as_on_duty`
        FROM `synex_group_membership_profiles` AS `profile`
        INNER JOIN `synex_group_memberships` AS `membership`
            ON `membership`.`id` = `profile`.`membership_id`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `membership`.`group_id`
        INNER JOIN `synex_group_organization_profiles` AS `organization`
            ON `organization`.`group_id` = `group_record`.`id`
        LEFT JOIN `synex_group_duty_sessions` AS `session`
            ON `session`.`membership_id` = `membership`.`id`
            AND `session`.`status` = 'open'
        LEFT JOIN `synex_group_duty_states` AS `duty_state`
            ON `duty_state`.`state_key` = `session`.`state_key`
        LEFT JOIN `synex_group_type_duty_states` AS `allowed_duty_state`
            ON `allowed_duty_state`.`group_type_id` = `organization`.`group_type_id`
            AND `allowed_duty_state`.`state_key` = `session`.`state_key`
        LEFT JOIN `synex_group_assignments` AS `assignment`
            ON `assignment`.`id` = `session`.`assignment_id`
        WHERE `profile`.`character_id` = ?
            AND `membership`.`status` <> 'removed'
            AND `profile`.`lifecycle_state` IN
                ('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE')
            AND `organization`.`lifecycle_state` NOT IN
                ('ARCHIVED', 'DISSOLVING', 'DELETED')
        ORDER BY `membership`.`public_id` ASC
        LIMIT %d]]):format(maximumMemberships + 1)

    local function databaseError(message)
        return Foundation.domainError('DATABASE_ERROR', message, true)
    end

    local function rowCount(rows)
        local count, highest = 0, 0
        for key in next, rows do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
                return nil
            end
            count = count + 1
            highest = math.max(highest, key)
            if count > maximumMemberships then return count end
        end
        if highest ~= count then return nil end
        return count
    end

    local loader = {}

    function loader:loadCharacter(characterId)
        if not Foundation.isSubjectId(characterId) then
            return nil, Foundation.domainError('INVALID_CHARACTER',
                'The runtime context character identifier is invalid.')
        end
        local called, rows, queryError = pcall(query, sql, { characterId })
        if not called then
            return nil, type(rows) == 'table' and rows
                or databaseError('The character runtime context query failed.')
        end
        if called and rows == false and type(queryError) == 'table' then rows = nil end
        if rows == nil then
            return nil, type(queryError) == 'table' and queryError
                or databaseError('The character runtime context query failed.')
        end
        if type(rows) ~= 'table' then
            return nil, databaseError('The character runtime context query returned invalid rows.')
        end
        local count = rowCount(rows)
        if count == nil then
            return nil, databaseError(
                'The character runtime context query returned a malformed row collection.')
        end
        if count > maximumMemberships then
            return nil, Foundation.domainError('RUNTIME_INDEX_CAPACITY_EXCEEDED',
                'The character runtime context exceeds its membership bound.', false, {
                    characterId = characterId,
                    maximum = maximumMemberships
                })
        end
        local memberships, seenMemberships, seenSessions = {}, {}, {}
        for index, row in ipairs(rows) do
            if type(row) ~= 'table' or row.character_id ~= characterId
                or not Foundation.isPublicId(row.membership_id)
                or not Foundation.isPublicId(row.group_id)
                or (row.membership_state ~= 'PROBATION'
                    and row.membership_state ~= 'ACTIVE'
                    and row.membership_state ~= 'SUSPENDED'
                    and row.membership_state ~= 'LEAVE'
                    and row.membership_state ~= 'INACTIVE') then
                return nil, databaseError('The character runtime context contains an invalid row.')
            end
            if seenMemberships[row.membership_id] then
                return nil, databaseError('The character runtime context contains duplicate memberships.')
            end
            seenMemberships[row.membership_id] = true
            local membership = {
                membershipId = row.membership_id,
                groupId = row.group_id,
                characterId = characterId,
                lifecycleState = row.membership_state
            }
            if row.duty_session_id ~= nil then
                local version = tonumber(row.duty_version)
                if not Foundation.isPublicId(row.duty_session_id)
                    or type(row.duty_state) ~= 'string'
                    or not version or math.type(version) ~= 'integer' or version < 1
                    or (row.duty_assignment_id ~= nil
                        and not Foundation.isPublicId(row.duty_assignment_id))
                    or seenSessions[row.duty_session_id] then
                    return nil, databaseError(
                        'The character runtime context contains an invalid open duty session.')
                end
                seenSessions[row.duty_session_id] = true
                membership.dutySession = {
                    sessionId = row.duty_session_id,
                    state = row.duty_state,
                    countsAsOnDuty = row.duty_counts_as_on_duty == true
                        or tonumber(row.duty_counts_as_on_duty) == 1,
                    assignmentId = row.duty_assignment_id,
                    version = version
                }
            end
            memberships[#memberships + 1] = membership
        end
        return { characterId = characterId, memberships = memberships }, nil
    end

    return loader
end

return createRuntimeContextLoader
end
