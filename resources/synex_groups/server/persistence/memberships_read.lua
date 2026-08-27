return function(Foundation)
local Shared = require('server.persistence.memberships_shared')(Foundation)
local lifecycleState = Shared.lifecycleState
local handlers = { read = {}, execute = {} }

local function membershipView(row)
    return {
        membership_id = row.membership_id,
        group_id = row.group_id,
        character_id = row.character_id,
        grade_id = row.grade_id,
        status = row.status,
        visibility = row.visibility,
        reports_to_public_id = row.reports_to_public_id,
        joined_at = row.joined_at and tostring(row.joined_at) or nil,
        left_at = row.left_at and tostring(row.left_at) or nil,
        version = tonumber(row.version)
    }
end

local function managementAccess(tx, request, runtime)
    for _, capability in ipairs({
        'synex.groups.directory.manage',
        'synex.groups.members.read'
    }) do
        local _, authorizationError = runtime.authorize(
            tx, request.group_id, request.actor_character_id,
            capability, 'group')
        if authorizationError == nil then return true, nil end
        if authorizationError.code ~= 'INSUFFICIENT_PERMISSION'
            and authorizationError.code ~= 'MEMBERSHIP_NOT_FOUND'
            and authorizationError.code ~= 'MEMBERSHIP_NOT_ACTIVE' then
            return nil, authorizationError
        end
    end
    return false, nil
end

function handlers.read.members_get(tx, request)
    local row = tx.one([[SELECT membership.public_id AS membership_id,
            group_record.public_id AS group_id, profile.character_id,
            grade.public_id AS grade_id,
            profile.lifecycle_state AS status, profile.visibility,
            reporting_manager.public_id AS reports_to_public_id,
            DATE_FORMAT(profile.joined_at,
                '%Y-%m-%dT%H:%i:%sZ') AS joined_at,
            DATE_FORMAT(profile.left_at, '%Y-%m-%dT%H:%i:%sZ') AS left_at,
            membership.version
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        LEFT JOIN synex_group_membership_grades AS assigned_grade
            ON assigned_grade.membership_id = membership.id
        LEFT JOIN synex_group_grades AS grade ON grade.id = assigned_grade.grade_id
        LEFT JOIN synex_group_reporting_edges AS reporting_edge
            ON reporting_edge.membership_id = membership.id
        LEFT JOIN synex_group_memberships AS reporting_manager
            ON reporting_manager.id = reporting_edge.manager_membership_id
        WHERE membership.public_id = ?]], { request.membership_id })
    if not row then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The membership does not exist.')
    end
    return membershipView(row), nil
end

function handlers.read.members_list(tx, request, runtime)
    local _, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.members.read', 'group')
    if authorizationError then return nil, authorizationError end
    local limit = tonumber(request.limit) or 50
    local result = tx.many([[SELECT membership.public_id AS membership_id,
            group_record.public_id AS group_id, profile.character_id,
            grade.public_id AS grade_id,
            profile.lifecycle_state AS status, profile.visibility,
            reporting_manager.public_id AS reports_to_public_id,
            DATE_FORMAT(profile.joined_at, '%Y-%m-%dT%H:%i:%sZ') AS joined_at,
            DATE_FORMAT(profile.left_at, '%Y-%m-%dT%H:%i:%sZ') AS left_at,
            membership.version
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        LEFT JOIN synex_group_membership_grades AS assigned_grade
            ON assigned_grade.membership_id = membership.id
        LEFT JOIN synex_group_grades AS grade ON grade.id = assigned_grade.grade_id
        LEFT JOIN synex_group_reporting_edges AS reporting_edge
            ON reporting_edge.membership_id = membership.id
        LEFT JOIN synex_group_memberships AS reporting_manager
            ON reporting_manager.id = reporting_edge.manager_membership_id
        WHERE group_record.public_id = ?
            AND (? IS NULL OR profile.lifecycle_state = ?)
            AND (? IS NULL OR membership.public_id > ?)
        ORDER BY membership.public_id ASC LIMIT ?]], {
        request.group_id,
        request.status and lifecycleState(request.status) or nil,
        request.status and lifecycleState(request.status) or nil,
        request.cursor, request.cursor, limit + 1
    })
    local items = {}
    for index = 1, math.min(#result, limit) do
        items[index] = membershipView(result[index])
    end
    return {
        items = items,
        next_cursor = #result > limit and items[#items].membership_id or nil,
        truncated = #result > limit
    }, nil
end

function handlers.read.directory_list(tx, request, runtime)
    local group, groupError = runtime.requireGroup(tx, request.group_id, false)
    if not group then return nil, groupError end

    local activeActorMembership = tx.one([[SELECT membership.id
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        WHERE membership.group_id = ? AND profile.character_id = ?
            AND profile.lifecycle_state = 'ACTIVE'
        LIMIT 1]], { group.id, request.actor_character_id })
    local isActiveMember = activeActorMembership ~= nil
    local canManage = false
    if isActiveMember then
        local access, accessError = managementAccess(tx, request, runtime)
        if access == nil then return nil, accessError end
        canManage = access
    end

    local limit = tonumber(request.limit) or 50
    local result = tx.many([[SELECT membership.public_id AS membership_id,
            group_record.public_id AS group_id, profile.character_id,
            profile.lifecycle_state AS status, profile.visibility,
            reporting_manager.public_id AS reports_to_public_id,
            DATE_FORMAT(profile.joined_at, '%Y-%m-%dT%H:%i:%sZ') AS joined_at,
            membership.version
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        LEFT JOIN synex_group_reporting_edges AS reporting_edge
            ON reporting_edge.membership_id = membership.id
        LEFT JOIN synex_group_memberships AS reporting_manager
            ON reporting_manager.id = reporting_edge.manager_membership_id
        WHERE membership.group_id = ?
            AND (? IS NULL OR membership.public_id > ?)
            AND (profile.visibility = 'public'
                OR (profile.character_id = ? AND profile.visibility <> 'server_only')
                OR (? = 1 AND profile.visibility = 'members')
                OR (? = 1 AND profile.visibility = 'management'))
        ORDER BY membership.public_id ASC LIMIT ?]], {
        group.id, request.cursor, request.cursor, request.actor_character_id,
        isActiveMember and 1 or 0, canManage and 1 or 0, limit + 1
    })
    local items = {}
    for index = 1, math.min(#result, limit) do
        items[index] = membershipView(result[index])
    end
    return {
        items = items,
        next_cursor = #result > limit and items[#items].membership_id or nil,
        truncated = #result > limit
    }, nil
end

return handlers
end
