return function(Foundation)
local GradeHandlers = require('server.persistence.memberships_lifecycle')(Foundation).execute
local PrimaryHandlers = require('server.persistence.memberships_access')(Foundation).execute
local handlers = { read = {}, execute = {} }
local MAXIMUM_REVISION = 2147483647
local membershipStates = {
    DRAFT = true, INVITED = true, APPLICANT = true, UNDER_REVIEW = true,
    APPROVED = true, PROBATION = true, ACTIVE = true, SUSPENDED = true,
    LEAVE = true, INACTIVE = true, TERMINATED = true, BANNED = true,
    LEFT = true, ARCHIVED = true
}

local function boundedRows(rows)
    if type(rows) ~= 'table' then return nil end
    local count, maximum = 0, 0
    for key, row in next, rows do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1
            or type(row) ~= 'table' then return nil end
        count = count + 1
        maximum = math.max(maximum, key)
        if count > 2 then return nil end
    end
    if count ~= maximum then return nil end
    return count
end

local function revision(value, allowZero)
    local candidate = tonumber(value)
    if not candidate or math.type(candidate) ~= 'integer'
        or candidate < (allowZero and 0 or 1) or candidate > MAXIMUM_REVISION then
        return nil
    end
    return candidate
end

local function internalId(value)
    local candidate = tonumber(value)
    if not candidate or math.type(candidate) ~= 'integer'
        or candidate < 1 or candidate > 9007199254740991 then return nil end
    return candidate
end

local function databaseInvalid(message)
    return nil, Foundation.domainError('DATABASE_RESULT_INVALID', message, true)
end

local function exactOne(rows, missingCode, missingMessage, ambiguousMessage)
    local count = boundedRows(rows)
    if count == nil then return databaseInvalid('The compatibility lookup returned malformed rows.') end
    if count == 0 then return nil, Foundation.domainError(missingCode, missingMessage) end
    if count ~= 1 then return databaseInvalid(ambiguousMessage) end
    return rows[1], nil
end

local function legacyMembershipStatus(state)
    if state == 'SUSPENDED' or state == 'LEAVE' or state == 'INACTIVE' then
        return 'suspended'
    end
    if state == 'TERMINATED' or state == 'BANNED'
        or state == 'LEFT' or state == 'ARCHIVED' then return 'removed' end
    return 'active'
end

function handlers.read.compatibility_resolve_target(tx, request)
    local typeRows = tx.many([[SELECT `type_record`.`id` AS `group_type_internal_id`,
            `type_record`.`type_key`, `type_record`.`status`
        FROM `synex_group_types` AS `type_record`
        WHERE `type_record`.`type_key` = ?
        ORDER BY `type_record`.`id` ASC LIMIT 2]], { request.group_type })
    local groupType, typeError = exactOne(typeRows, 'GROUP_TYPE_NOT_FOUND',
        'The requested group type does not exist.',
        'The compatibility group-type lookup is ambiguous.')
    if not groupType then return nil, typeError end
    local groupTypeId = internalId(groupType.group_type_internal_id)
    if not groupTypeId or groupType.type_key ~= request.group_type
        or type(groupType.status) ~= 'string' then
        return databaseInvalid('The compatibility group-type lookup contains invalid data.')
    end
    if groupType.status ~= 'active' then
        return nil, Foundation.domainError('GROUP_TYPE_INACTIVE',
            'The requested group type is not active.')
    end

    local targetRows = tx.many([[SELECT `group_record`.`id` AS `group_internal_id`,
            `group_record`.`public_id` AS `group_id`,
            `group_record`.`group_key` AS `legacy_group_key`,
            `group_record`.`group_type` AS `legacy_group_type`,
            `group_record`.`status` AS `group_status`,
            `organization`.`slug` AS `group_key`,
            `organization`.`lifecycle_state` AS `group_lifecycle_state`,
            `grade`.`public_id` AS `grade_id`, `grade`.`status` AS `grade_status`
        FROM `synex_group_organization_profiles` AS `organization`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `organization`.`group_id`
        LEFT JOIN `synex_group_grades` AS `grade`
            ON `grade`.`group_id` = `group_record`.`id` AND `grade`.`grade_key` = ?
        WHERE `organization`.`group_type_id` = ? AND `organization`.`slug` = ?
        ORDER BY `group_record`.`id` ASC, `grade`.`id` ASC LIMIT 2]], {
        request.grade_key, groupTypeId, request.group_key
    })
    local target, groupError = exactOne(targetRows, 'GROUP_NOT_FOUND',
        'The requested group does not exist in that type.',
        'The compatibility group or grade lookup is ambiguous.')
    if not target then return nil, groupError end
    local groupInternalId = internalId(target.group_internal_id)
    if not groupInternalId or not Foundation.isPublicId(target.group_id)
        or target.group_key ~= request.group_key
        or target.legacy_group_key ~= request.group_key
        or target.legacy_group_type ~= request.group_type
        or type(target.group_status) ~= 'string'
        or type(target.group_lifecycle_state) ~= 'string' then
        return databaseInvalid('The compatibility group lookup contains inconsistent data.')
    end
    if target.group_status ~= 'active' or target.group_lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'The requested group is not active.')
    end
    if target.grade_id == nil or target.grade_status ~= 'active' then
        return nil, Foundation.domainError('GRADE_NOT_FOUND',
            'The requested active grade does not exist in that group.')
    end
    if not Foundation.isPublicId(target.grade_id) then
        return databaseInvalid('The compatibility grade lookup contains invalid data.')
    end

    local membershipRows = tx.many([[SELECT
            `membership`.`public_id` AS `membership_id`,
            `membership`.`version` AS `membership_version`,
            `membership`.`status` AS `membership_storage_status`,
            `profile`.`lifecycle_state` AS `membership_status`,
            CASE
                WHEN `primary_membership`.`membership_id` IS NULL THEN 'unassigned'
                WHEN `primary_membership`.`membership_id` = `membership`.`id` THEN 'selected'
                ELSE 'different'
            END AS `primary_state`,
            `primary_membership`.`version` AS `primary_version`,
            `session`.`public_id` AS `duty_session_id`,
            `session`.`state_key` AS `duty_state`,
            `session`.`status` AS `duty_status`,
            `session`.`version` AS `duty_version`,
            `duty_state`.`status` AS `duty_state_status`,
            `allowed_duty_state`.`state_key` AS `allowed_duty_state`
        FROM `synex_group_membership_profiles` AS `profile`
        INNER JOIN `synex_group_memberships` AS `membership`
            ON `membership`.`id` = `profile`.`membership_id`
            AND `membership`.`group_id` = `profile`.`group_id`
        LEFT JOIN `synex_group_primary_memberships_by_type` AS `primary_membership`
            ON `primary_membership`.`character_id` = `profile`.`character_id`
            AND `primary_membership`.`group_type_id` = ?
        LEFT JOIN `synex_group_duty_sessions` AS `session`
            ON `session`.`membership_id` = `membership`.`id` AND `session`.`status` = 'open'
        LEFT JOIN `synex_group_duty_states` AS `duty_state`
            ON `duty_state`.`state_key` = `session`.`state_key`
        LEFT JOIN `synex_group_type_duty_states` AS `allowed_duty_state`
            ON `allowed_duty_state`.`group_type_id` = ?
            AND `allowed_duty_state`.`state_key` = `session`.`state_key`
        WHERE `profile`.`group_id` = ? AND `profile`.`character_id` = ?
        ORDER BY `membership`.`id` ASC, `session`.`id` ASC LIMIT 2]], {
        groupTypeId, groupTypeId, groupInternalId, request.actor_character_id
    })
    local membershipCount = boundedRows(membershipRows)
    if membershipCount == nil then
        return databaseInvalid('The compatibility membership lookup returned malformed rows.')
    end
    if membershipCount > 1 then
        return databaseInvalid('The compatibility membership or duty lookup is ambiguous.')
    end
    local response = { group_id = target.group_id, grade_id = target.grade_id }
    if membershipCount == 0 then return response, nil end

    local membership = membershipRows[1]
    local membershipVersion = revision(membership.membership_version, false)
    local primaryVersion = membership.primary_version ~= nil
        and revision(membership.primary_version, false) or nil
    if not Foundation.isPublicId(membership.membership_id)
        or not membershipVersion or not membershipStates[membership.membership_status]
        or membership.membership_storage_status
            ~= legacyMembershipStatus(membership.membership_status)
        or (membership.primary_state ~= 'unassigned'
            and membership.primary_state ~= 'selected'
            and membership.primary_state ~= 'different')
        or membership.primary_state == 'unassigned' and membership.primary_version ~= nil
        or membership.primary_state ~= 'unassigned' and not primaryVersion then
        return databaseInvalid('The compatibility membership lookup contains invalid data.')
    end
    response.membership_id = membership.membership_id
    response.membership_status = membership.membership_status
    response.membership_version = membershipVersion
    response.primary_state = membership.primary_state
    if primaryVersion then response.primary_version = primaryVersion end

    if membership.duty_session_id ~= nil then
        local dutyVersion = revision(membership.duty_version, false)
        if not Foundation.isPublicId(membership.duty_session_id)
            or type(membership.duty_state) ~= 'string'
            or #membership.duty_state < 2 or #membership.duty_state > 32
            or not membership.duty_state:match('^[a-z][a-z0-9_%-]*$')
            or membership.duty_status ~= 'open'
            or membership.duty_state_status ~= 'active'
            or membership.allowed_duty_state ~= membership.duty_state
            or not dutyVersion then
            return databaseInvalid('The compatibility duty lookup contains invalid data.')
        end
        response.duty_session_id = membership.duty_session_id
        response.duty_state = membership.duty_state
        response.duty_version = dutyVersion
    elseif membership.duty_state ~= nil or membership.duty_status ~= nil
        or membership.duty_version ~= nil or membership.duty_state_status ~= nil
        or membership.allowed_duty_state ~= nil then
        return databaseInvalid('The compatibility duty lookup contains incomplete data.')
    end
    return response, nil
end

function handlers.execute.compatibility_set_primary_grade(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    if membership.character_id ~= request.actor_character_id
        or membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'Only the active affected character may change its primary grade target.')
    end
    local typeRecord = tx.one([[SELECT `type_record`.`id`, `type_record`.`status`,
            `organization`.`lifecycle_state`, `group_record`.`status` AS `group_status`
        FROM `synex_group_organization_profiles` AS `organization`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `organization`.`group_type_id`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `organization`.`group_id`
        WHERE `organization`.`group_id` = ? AND `type_record`.`type_key` = ?
        FOR UPDATE]], { membership.group_id, request.group_type })
    local groupTypeId = typeRecord and internalId(typeRecord.id) or nil
    if not groupTypeId then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The membership does not belong to the requested group type.')
    end
    if typeRecord.status ~= 'active' or typeRecord.lifecycle_state ~= 'ACTIVE'
        or typeRecord.group_status ~= 'active' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'The requested membership group is not active.')
    end
    local currentPrimary = tx.one([[SELECT `public_id`, `membership_id`, `version`
        FROM `synex_group_primary_memberships_by_type`
        WHERE `character_id` = ? AND `group_type_id` = ? FOR UPDATE]], {
        request.actor_character_id, groupTypeId
    })
    local currentPrimaryVersion = currentPrimary
        and revision(currentPrimary.version, false) or 0
    if currentPrimary and (not currentPrimaryVersion
        or not Foundation.isPublicId(currentPrimary.public_id)
        or not internalId(currentPrimary.membership_id)) then
        return databaseInvalid('The stored primary membership revision is invalid.')
    end
    if currentPrimaryVersion ~= request.expected_primary_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The primary membership version changed.', true)
    end

    local gradeResponse, gradeError, gradeEffects =
        GradeHandlers.members_set_grade(tx, request, runtime, context,
            'compatibility_set_primary_grade')
    if not gradeResponse then return nil, gradeError end
    if gradeResponse.entity_id == nil then return gradeResponse, gradeError, gradeEffects end
    local primaryResponse, primaryError, primaryEffects =
        PrimaryHandlers.members_set_primary(tx, request, runtime, context)
    if not primaryResponse then return nil, primaryError end
    if not Foundation.isPublicId(gradeResponse.entity_id)
        or not Foundation.isPublicId(primaryResponse.entity_id)
        or not revision(gradeResponse.version, false)
        or not revision(primaryResponse.version, false) then
        return databaseInvalid('The atomic compatibility mutation returned invalid revisions.')
    end
    local effects = {}
    for _, effect in ipairs(gradeEffects or {}) do effects[#effects + 1] = effect end
    for _, effect in ipairs(primaryEffects or {}) do effects[#effects + 1] = effect end
    return {
        membership_id = gradeResponse.entity_id,
        membership_version = tonumber(gradeResponse.version),
        grade_id = request.grade_id,
        primary_id = primaryResponse.entity_id,
        primary_version = tonumber(primaryResponse.version),
        replayed = false
    }, nil, effects
end

return handlers
end
