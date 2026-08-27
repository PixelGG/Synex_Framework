return function(Foundation)
local domainError = Foundation.domainError
local Shared = require('server.persistence.organizations_shared')(Foundation)
local GROUP_VISIBILITY = Shared.GROUP_VISIBILITY
local RELATIONSHIP_STATUS = Shared.RELATIONSHIP_STATUS
local GRADE_STATUS = Shared.GRADE_STATUS
local ROLE_STATUS = Shared.ROLE_STATUS
local ACYCLIC_RELATIONSHIPS = Shared.ACYCLIC_RELATIONSHIPS
local MAXIMUM_HIERARCHY_DEPTH = Shared.MAXIMUM_HIERARCHY_DEPTH
local rejected = Shared.rejected
local affectedRows = Shared.affectedRows
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local authorize = Shared.authorize
local decodeMetadata = Shared.decodeMetadata
local encodeMetadata = Shared.encodeMetadata
local groupView = Shared.groupView
local loadGroupForUpdate = Shared.loadGroupForUpdate
local bumpReadModel = Shared.bumpReadModel
local mutationResult = Shared.mutationResult
local read = {}

function read.get(tx, request, runtime)
    local row = tx.one([[SELECT `group_record`.`public_id` AS `group_public_id`,
            `group_record`.`display_name`, `group_record`.`status`,
            `group_record`.`version`,
            DATE_FORMAT(`group_record`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
            DATE_FORMAT(`group_record`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`,
            `type_record`.`type_key`, `profile`.`slug`, `profile`.`name`, `profile`.`label`,
            `profile`.`description`, `profile`.`dynamic`, `profile`.`visibility`,
            `profile`.`lifecycle_state`,
            `parent`.`public_id` AS `parent_public_id`
        FROM `synex_groups` AS `group_record`
        INNER JOIN `synex_group_organization_profiles` AS `profile`
            ON `profile`.`group_id` = `group_record`.`id`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `profile`.`group_type_id`
        LEFT JOIN `synex_group_hierarchy_edges` AS `edge`
            ON `edge`.`child_group_id` = `group_record`.`id`
        LEFT JOIN `synex_groups` AS `parent` ON `parent`.`id` = `edge`.`parent_group_id`
        WHERE `group_record`.`public_id` = ?]], { request.group_id })
    if not row then return rejected('GROUP_NOT_FOUND', 'The organization does not exist.') end
    local value, viewError = groupView(runtime, row, true)
    if not value then return nil, viewError, nil end
    return value, nil, nil
end

function read.list(tx, request, runtime)
    local limit = request.limit == nil and 50 or tonumber(request.limit)
    if not limit or math.type(limit) ~= 'integer' or limit < 1 or limit > 100 then
        return rejected('VALIDATION_FAILED', 'limit must be an integer between 1 and 100.')
    end

    local clauses = {}
    local parameters = {}
    if request.type ~= nil then
        clauses[#clauses + 1] = '`type_record`.`type_key` = ?'
        parameters[#parameters + 1] = request.type
    end
    if request.status ~= nil then
        clauses[#clauses + 1] = '`profile`.`lifecycle_state` = ?'
        parameters[#parameters + 1] = request.status:upper()
    end
    if request.parent_group_id ~= nil then
        clauses[#clauses + 1] = '`parent`.`public_id` = ?'
        parameters[#parameters + 1] = request.parent_group_id
    end
    if request.cursor ~= nil then
        clauses[#clauses + 1] = '`group_record`.`public_id` > ?'
        parameters[#parameters + 1] = request.cursor
    end
    parameters[#parameters + 1] = limit + 1
    local where = #clauses > 0 and 'WHERE ' .. table.concat(clauses, ' AND ') or ''
    local rows = tx.many(([=[SELECT `group_record`.`public_id` AS `group_public_id`,
            `group_record`.`display_name`, `group_record`.`status`,
            `group_record`.`version`,
            DATE_FORMAT(`group_record`.`created_at`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `created_at`,
            DATE_FORMAT(`group_record`.`updated_at`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `updated_at`,
            `type_record`.`type_key`, `profile`.`slug`, `profile`.`name`, `profile`.`label`,
            `profile`.`description`, `profile`.`dynamic`, `profile`.`visibility`,
            `profile`.`lifecycle_state`,
            `parent`.`public_id` AS `parent_public_id`
        FROM `synex_groups` AS `group_record`
        INNER JOIN `synex_group_organization_profiles` AS `profile`
            ON `profile`.`group_id` = `group_record`.`id`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `profile`.`group_type_id`
        LEFT JOIN `synex_group_hierarchy_edges` AS `edge`
            ON `edge`.`child_group_id` = `group_record`.`id`
        LEFT JOIN `synex_groups` AS `parent` ON `parent`.`id` = `edge`.`parent_group_id`
        %s ORDER BY `group_record`.`public_id` ASC LIMIT ?]=]):format(where), parameters)
    if type(rows) ~= 'table' then
        return rejected('DATABASE_RESULT_INVALID', 'The organization list result is invalid.', true)
    end
    local truncated = #rows > limit
    local items = {}
    for index = 1, math.min(#rows, limit) do
        local item, itemError = groupView(runtime, rows[index], false)
        if not item then return nil, itemError, nil end
        items[index] = item
    end
    return {
        items = items,
        next_cursor = truncated and items[#items].group_id or nil,
        truncated = truncated
    }, nil, nil
end

return { read = read }
end
