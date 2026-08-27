return function(Foundation)
local domainError = Foundation.domainError
local Shared = require('server.persistence.organizations_shared')(Foundation)
local GROUP_VISIBILITY, RELATIONSHIP_STATUS = Shared.GROUP_VISIBILITY, Shared.RELATIONSHIP_STATUS
local RELATIONSHIP_EFFECTIVE_STATUS = {
    pending = true,
    active = true,
    suspended = true,
    ended = true
}
local GRADE_STATUS, ROLE_STATUS = Shared.GRADE_STATUS, Shared.ROLE_STATUS
local ACYCLIC_RELATIONSHIPS, MAXIMUM_HIERARCHY_DEPTH =
    Shared.ACYCLIC_RELATIONSHIPS, Shared.MAXIMUM_HIERARCHY_DEPTH
local MAXIMUM_RELATIONSHIP_METADATA_BYTES = 16384
local rejected, affectedRows = Shared.rejected, Shared.affectedRows
local checkedId, checkedReason = Shared.checkedId, Shared.checkedReason
local authorize, decodeMetadata = Shared.authorize, Shared.decodeMetadata
local encodeMetadata, groupView = Shared.encodeMetadata, Shared.groupView
local loadGroupForUpdate, bumpReadModel = Shared.loadGroupForUpdate, Shared.bumpReadModel
local mutationResult = Shared.mutationResult
local read = {}
local execute = {}
local function relationshipView(runtime, row, includeMetadata)
    local version = tonumber(row.version)
    local status = row.effective_status or row.status
    if not Foundation.isPublicId(row.relationship_id)
        or not Foundation.isPublicId(row.source_group_id)
        or not Foundation.isPublicId(row.target_group_id)
        or type(row.relation_type) ~= 'string'
        or #row.relation_type < 1 or #row.relation_type > 64
        or row.relation_type:match('^[a-z][a-z0-9_.:%-]*$') == nil
        or (row.direction ~= 'directed' and row.direction ~= 'symmetric')
        or not RELATIONSHIP_EFFECTIVE_STATUS[status]
        or type(row.valid_from) ~= 'string' or row.valid_from == ''
        or row.valid_until ~= nil and type(row.valid_until) ~= 'string'
        or row.effective_ended_at ~= nil and type(row.effective_ended_at) ~= 'string'
        or row.ended_at ~= nil and type(row.ended_at) ~= 'string'
        or type(row.created_at) ~= 'string' or row.created_at == ''
        or type(row.updated_at) ~= 'string' or row.updated_at == ''
        or not version or math.type(version) ~= 'integer' or version < 1 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored relationship is invalid.', true)
    end
    local value = {
        relationship_id = row.relationship_id, source_group_id = row.source_group_id,
        target_group_id = row.target_group_id, relation_type = row.relation_type,
        direction = row.direction, status = status,
        valid_from = row.valid_from, valid_until = row.valid_until,
        ended_at = row.effective_ended_at or row.ended_at, version = version,
        created_at = row.created_at, updated_at = row.updated_at
    }
    if includeMetadata then
        if type(row.metadata_json) ~= 'string'
            or #row.metadata_json > MAXIMUM_RELATIONSHIP_METADATA_BYTES then
            return nil, domainError('READ_MODEL_TOO_LARGE',
                'The relationship metadata exceeds its supported read bound.')
        end
        local metadata, metadataError = decodeMetadata(runtime, row.metadata_json)
        if not metadata then return nil, metadataError end
        value.metadata = metadata
    end
    return value, nil
end
local function authorizeRelationshipRead(tx, request, runtime, relationshipId)
    return authorize(runtime, tx, request.group_id, request.actor_character_id,
        'synex.groups.relationships.read', {
            kind = 'relationship', group_id = request.group_id,
            relationship_id = relationshipId
        })
end
function read.relationships_get(tx, request, runtime)
    if not Foundation.isPublicId(request.group_id)
        or not Foundation.isPublicId(request.relationship_id)
        or not Foundation.isSubjectId(request.actor_character_id) then
        return rejected('VALIDATION_FAILED', 'The relationship read identity is invalid.')
    end
    local allowed, authorizationError = authorizeRelationshipRead(
        tx, request, runtime, request.relationship_id)
    if not allowed then return nil, authorizationError, nil end
    local row = tx.one([[SELECT `relationship`.`public_id` AS `relationship_id`,
            `source`.`public_id` AS `source_group_id`,
            `target`.`public_id` AS `target_group_id`,
            `type_record`.`type_key` AS `relation_type`, `type_record`.`direction`,
            `relationship`.`status`,
            CASE WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_from` > CURRENT_TIMESTAMP(6)
                THEN 'pending'
                WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_until` IS NOT NULL
                    AND `relationship`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN 'ended' ELSE `relationship`.`status` END AS `effective_status`,
            DATE_FORMAT(`relationship`.`valid_from`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_from`,
            DATE_FORMAT(`relationship`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_until`,
            DATE_FORMAT(`relationship`.`ended_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `ended_at`,
            DATE_FORMAT(CASE WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_until` IS NOT NULL
                    AND `relationship`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN `relationship`.`valid_until` ELSE `relationship`.`ended_at` END,
                '%Y-%m-%dT%H:%i:%s.%fZ') AS `effective_ended_at`,
            `relationship`.`metadata_json`, `relationship`.`version`,
            DATE_FORMAT(`relationship`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
            DATE_FORMAT(`relationship`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`
        FROM `synex_group_relationships` AS `relationship`
        INNER JOIN `synex_groups` AS `source`
            ON `source`.`id` = `relationship`.`source_group_id`
        INNER JOIN `synex_groups` AS `target`
            ON `target`.`id` = `relationship`.`target_group_id`
        INNER JOIN `synex_group_relation_types` AS `type_record`
            ON `type_record`.`id` = `relationship`.`relation_type_id`
        WHERE `relationship`.`public_id` = ?
            AND (`source`.`public_id` = ? OR `target`.`public_id` = ?)]], {
        request.relationship_id, request.group_id, request.group_id
    })
    if not row then
        return rejected('RELATIONSHIP_NOT_FOUND',
            'The relationship does not exist in the requested organization scope.')
    end
    local value, viewError = relationshipView(runtime, row, true)
    if not value then return nil, viewError, nil end
    return value, nil, nil
end
function read.relationships_list(tx, request, runtime)
    if not Foundation.isPublicId(request.group_id)
        or not Foundation.isSubjectId(request.actor_character_id)
        or request.cursor ~= nil and not Foundation.isPublicId(request.cursor)
        or request.relation_type ~= nil and (type(request.relation_type) ~= 'string'
            or #request.relation_type < 1 or #request.relation_type > 64
            or request.relation_type:match('^[a-z][a-z0-9_.:%-]*$') == nil)
        or request.status ~= nil and not RELATIONSHIP_EFFECTIVE_STATUS[request.status]
        or request.direction ~= nil and request.direction ~= 'any'
            and request.direction ~= 'outgoing' and request.direction ~= 'incoming' then
        return rejected('VALIDATION_FAILED', 'The relationship list filter is invalid.')
    end
    local limit = request.limit == nil and 40 or tonumber(request.limit)
    if not limit or math.type(limit) ~= 'integer' or limit < 1 or limit > 40 then
        return rejected('VALIDATION_FAILED', 'limit must be an integer between 1 and 40.')
    end
    local allowed, authorizationError = authorizeRelationshipRead(tx, request, runtime)
    if not allowed then return nil, authorizationError, nil end
    local group = tx.one([[SELECT `id` FROM `synex_groups`
        WHERE `public_id` = ? LIMIT 1]], { request.group_id })
    local groupInternalId = group and tonumber(group.id)
    if not groupInternalId or math.type(groupInternalId) ~= 'integer' or groupInternalId < 1 then
        return rejected('GROUP_NOT_FOUND', 'The organization does not exist.')
    end
    local direction = request.direction or 'any'
    local clauses, parameters = {}, {}
    if direction == 'outgoing' then
        clauses[1] = '`relationship`.`source_group_id` = ?'
        parameters[1] = groupInternalId
    elseif direction == 'incoming' then
        clauses[1] = '`relationship`.`target_group_id` = ?'
        parameters[1] = groupInternalId
    else
        clauses[1] = '(`relationship`.`source_group_id` = ? OR `relationship`.`target_group_id` = ?)'
        parameters[1], parameters[2] = groupInternalId, groupInternalId
    end
    if request.relation_type ~= nil then
        clauses[#clauses + 1] = '`type_record`.`type_key` = ?'
        parameters[#parameters + 1] = request.relation_type
    end
    if request.status ~= nil then
        clauses[#clauses + 1] = [[CASE WHEN `relationship`.`status` IN ('active', 'suspended')
                AND `relationship`.`valid_from` > CURRENT_TIMESTAMP(6)
            THEN 'pending'
            WHEN `relationship`.`status` IN ('active', 'suspended')
                AND `relationship`.`valid_until` IS NOT NULL
                AND `relationship`.`valid_until` <= CURRENT_TIMESTAMP(6)
            THEN 'ended' ELSE `relationship`.`status` END = ?]]
        parameters[#parameters + 1] = request.status
    end
    if request.cursor ~= nil then
        clauses[#clauses + 1] = '`relationship`.`public_id` > ?'
        parameters[#parameters + 1] = request.cursor
    end
    parameters[#parameters + 1] = limit + 1
    local rows = tx.many(([=[SELECT `relationship`.`public_id` AS `relationship_id`,
            `source`.`public_id` AS `source_group_id`,
            `target`.`public_id` AS `target_group_id`,
            `type_record`.`type_key` AS `relation_type`, `type_record`.`direction`,
            `relationship`.`status`,
            CASE WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_from` > CURRENT_TIMESTAMP(6)
                THEN 'pending'
                WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_until` IS NOT NULL
                    AND `relationship`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN 'ended' ELSE `relationship`.`status` END AS `effective_status`,
            DATE_FORMAT(`relationship`.`valid_from`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `valid_from`,
            DATE_FORMAT(`relationship`.`valid_until`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `valid_until`,
            DATE_FORMAT(`relationship`.`ended_at`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `ended_at`,
            DATE_FORMAT(CASE WHEN `relationship`.`status` IN ('active', 'suspended')
                    AND `relationship`.`valid_until` IS NOT NULL
                    AND `relationship`.`valid_until` <= CURRENT_TIMESTAMP(6)
                THEN `relationship`.`valid_until` ELSE `relationship`.`ended_at` END,
                '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `effective_ended_at`,
            `relationship`.`version`,
            DATE_FORMAT(`relationship`.`created_at`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `created_at`,
            DATE_FORMAT(`relationship`.`updated_at`, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ') AS `updated_at`
        FROM `synex_group_relationships` AS `relationship`
        INNER JOIN `synex_groups` AS `source`
            ON `source`.`id` = `relationship`.`source_group_id`
        INNER JOIN `synex_groups` AS `target`
            ON `target`.`id` = `relationship`.`target_group_id`
        INNER JOIN `synex_group_relation_types` AS `type_record`
            ON `type_record`.`id` = `relationship`.`relation_type_id`
        WHERE %s ORDER BY `relationship`.`public_id` ASC LIMIT ?]=]):format(
        table.concat(clauses, ' AND ')), parameters)
    if type(rows) ~= 'table' or #rows > limit + 1 then
        return rejected('DATABASE_RESULT_INVALID',
            'The relationship list result is invalid.', true)
    end
    local truncated = #rows > limit
    local items = {}
    for index = 1, math.min(#rows, limit) do
        local item, itemError = relationshipView(runtime, rows[index], false)
        if not item then return nil, itemError, nil end
        items[index] = item
    end
    return {
        items = items,
        next_cursor = truncated and items[#items].relationship_id or nil,
        truncated = truncated
    }, nil, nil
end
function execute.relationships_create(tx, request, runtime, context)
    local allowed, authorizationError = authorize(runtime, tx, request.source_group_id,
        request.actor_character_id, 'synex.groups.relationships.manage', {
            kind = 'relationship', group_id = request.source_group_id,
            target_group_id = request.target_group_id, relation_type = request.relation_type
        })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if request.source_group_id == request.target_group_id then
        return rejected('RELATIONSHIP_INVALID',
            'An organization cannot have a relationship with itself.')
    end
    local groups = tx.many([[SELECT `group_record`.`id`, `group_record`.`public_id`,
            `group_record`.`status`, `profile`.`lifecycle_state`,
            `type_record`.`relationships_enabled`
        FROM `synex_groups` AS `group_record`
        INNER JOIN `synex_group_organization_profiles` AS `profile`
            ON `profile`.`group_id` = `group_record`.`id`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `profile`.`group_type_id`
        WHERE `group_record`.`public_id` IN (?, ?)
        ORDER BY `group_record`.`public_id` ASC FOR UPDATE]],
        { request.source_group_id, request.target_group_id })
    if type(groups) ~= 'table' or #groups ~= 2 then
        return rejected('GROUP_NOT_FOUND', 'A relationship organization does not exist.')
    end
    local byPublicId = {}
    for _, row in ipairs(groups) do byPublicId[row.public_id] = row end
    local source = byPublicId[request.source_group_id]
    local target = byPublicId[request.target_group_id]
    if not source or not target then
        return rejected('GROUP_NOT_FOUND', 'A relationship organization does not exist.')
    end
    if source.status ~= 'active' or target.status ~= 'active'
        or source.lifecycle_state ~= 'ACTIVE' or target.lifecycle_state ~= 'ACTIVE' then
        return rejected('GROUP_INACTIVE', 'Both relationship organizations must be active.')
    end
    if tonumber(source.relationships_enabled) ~= 1 then
        return rejected('RELATIONSHIPS_DISABLED',
            'The source organization type does not permit relationships.')
    end
    local relationType = tx.one([[SELECT `id`, `type_key`, `direction`, `status`
        FROM `synex_group_relation_types` WHERE `type_key` = ? FOR UPDATE]],
        { request.relation_type })
    if not relationType then
        return rejected('RELATIONSHIP_TYPE_NOT_FOUND', 'The relationship type does not exist.')
    end
    if relationType.status ~= 'active' then
        return rejected('RELATIONSHIP_TYPE_INACTIVE', 'The relationship type is not active.')
    end
    local duplicate
    if relationType.direction == 'symmetric' then
        duplicate = tx.one([[SELECT `public_id` FROM `synex_group_relationships`
            WHERE `relation_type_id` = ? AND `status` = 'active'
                AND ((`source_group_id` = ? AND `target_group_id` = ?)
                    OR (`source_group_id` = ? AND `target_group_id` = ?))
            FOR UPDATE]], {
            relationType.id, source.id, target.id, target.id, source.id
        })
    else
        duplicate = tx.one([[SELECT `public_id` FROM `synex_group_relationships`
            WHERE `relation_type_id` = ? AND `source_group_id` = ?
                AND `target_group_id` = ? AND `status` = 'active' FOR UPDATE]],
            { relationType.id, source.id, target.id })
    end
    if duplicate then
        return rejected('RELATIONSHIP_EXISTS', 'The active relationship already exists.')
    end
    if ACYCLIC_RELATIONSHIPS[relationType.type_key] then
        local path = tx.one([[WITH RECURSIVE `relation_path` AS (
                SELECT `target_group_id` AS `group_id`, 1 AS `depth`
                FROM `synex_group_relationships`
                WHERE `relation_type_id` = ? AND `source_group_id` = ? AND `status` = 'active'
                UNION DISTINCT
                SELECT `relationship`.`target_group_id`, `path`.`depth` + 1
                FROM `relation_path` AS `path`
                INNER JOIN `synex_group_relationships` AS `relationship`
                    ON `relationship`.`source_group_id` = `path`.`group_id`
                    AND `relationship`.`relation_type_id` = ?
                    AND `relationship`.`status` = 'active'
                WHERE `path`.`depth` < ?
            )
            SELECT `group_id`, `depth` FROM `relation_path`
            WHERE `group_id` = ? OR `depth` = ? ORDER BY `depth` ASC LIMIT 1]], {
            relationType.id, target.id, relationType.id,
            MAXIMUM_HIERARCHY_DEPTH, source.id, MAXIMUM_HIERARCHY_DEPTH
        })
        if path and tonumber(path.group_id) == tonumber(source.id) then
            return rejected('RELATIONSHIP_CYCLE',
                'The requested relationship would create a cycle.')
        end
        if path then
            return rejected('RELATIONSHIP_GRAPH_TOO_DEEP',
                'The relationship graph exceeds its supported depth.')
        end
    end
    if request.valid_until ~= nil then
        local window = tx.one([[SELECT CASE
            WHEN CAST(? AS DATETIME(6)) IS NOT NULL
                AND CAST(? AS DATETIME(6)) > COALESCE(CAST(? AS DATETIME(6)), CURRENT_TIMESTAMP(6))
            THEN 1 ELSE 0 END AS `valid_window`]],
            { request.valid_until, request.valid_until, request.valid_from })
        if not window or tonumber(window.valid_window) ~= 1 then
            return rejected('RELATIONSHIP_INVALID', 'The relationship validity window is invalid.')
        end
    end
    local relationshipId, relationshipIdError = checkedId(runtime, 'groups_relation')
    if not relationshipId then return nil, relationshipIdError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'relationship_created')
    if not reason then return nil, reasonError, nil end
    local metadataJson, metadataError = encodeMetadata(runtime, request.metadata or {})
    if not metadataJson then return nil, metadataError, nil end
    if #metadataJson > MAXIMUM_RELATIONSHIP_METADATA_BYTES then
        return rejected('VALIDATION_FAILED',
            'Relationship metadata exceeds its supported 16 KiB bound.')
    end
    local inserted = tx.query([[INSERT INTO `synex_group_relationships`
        (`public_id`, `relation_type_id`, `source_group_id`, `target_group_id`,
         `status`, `valid_from`, `valid_until`, `created_by_ref`, `reason_code`,
         `metadata_json`, `version`)
        VALUES (?, ?, ?, ?, 'active', COALESCE(CAST(? AS DATETIME(6)), CURRENT_TIMESTAMP(6)),
            CAST(? AS DATETIME(6)), ?, ?, ?, 1)]], {
        relationshipId, relationType.id, source.id, target.id,
        request.valid_from, request.valid_until, request.actor_character_id, reason, metadataJson
    })
    if affectedRows(inserted) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The relationship could not be created.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, source.id)
    if not bumped then return nil, bumpError, nil end
    bumped, bumpError = bumpReadModel(tx, target.id)
    if not bumped then return nil, bumpError, nil end
    local after = {
        relationship_id = relationshipId, source_group_id = source.public_id,
        target_group_id = target.public_id, relation_type = relationType.type_key,
        metadata = request.metadata or {}, status = 'active', version = 1
    }
    local effect = runtime.effect('relationship.created', 'relationship',
        relationshipId, request.source_group_id, request.actor_character_id,
        nil, after, reason)
    return mutationResult(runtime, relationshipId, 'relationship', 'active', 1, effect)
end
function execute.relationships_update(tx, request, runtime, context)
    local relationship = tx.one([[SELECT `relationship`.`id`, `relationship`.`public_id`,
            `relationship`.`source_group_id`, `relationship`.`target_group_id`,
            `relationship`.`status`, `relationship`.`valid_from`,
            `relationship`.`valid_until`, `relationship`.`version`,
            `source`.`public_id` AS `source_public_id`,
            `target`.`public_id` AS `target_public_id`,
            `type_record`.`type_key`
        FROM `synex_group_relationships` AS `relationship`
        INNER JOIN `synex_groups` AS `source` ON `source`.`id` = `relationship`.`source_group_id`
        INNER JOIN `synex_groups` AS `target` ON `target`.`id` = `relationship`.`target_group_id`
        INNER JOIN `synex_group_relation_types` AS `type_record`
            ON `type_record`.`id` = `relationship`.`relation_type_id`
        WHERE `relationship`.`public_id` = ? FOR UPDATE]], { request.relationship_id })
    if not relationship then
        return rejected('RELATIONSHIP_NOT_FOUND', 'The relationship does not exist.')
    end
    local allowed, authorizationError = authorize(runtime, tx,
        relationship.source_public_id, request.actor_character_id,
        'synex.groups.relationships.manage', {
            kind = 'relationship', group_id = relationship.source_public_id,
            relationship_id = request.relationship_id,
            target_group_id = relationship.target_public_id
        })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local version = tonumber(relationship.version)
    if version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION', 'The relationship version has changed.', true,
            { expected = request.expected_version, actual = version })
    end
    if not RELATIONSHIP_STATUS[request.status] then
        return rejected('RELATIONSHIP_INVALID', 'The requested relationship status is invalid.')
    end
    if relationship.status == 'ended' then
        return rejected('INVALID_TRANSITION', 'An ended relationship cannot be changed.')
    end
    if request.valid_until ~= nil then
        local window = tx.one([[SELECT CASE
            WHEN CAST(? AS DATETIME(6)) IS NOT NULL
                AND CAST(? AS DATETIME(6)) > `valid_from` THEN 1 ELSE 0 END AS `valid_window`
            FROM `synex_group_relationships` WHERE `id` = ?]],
            { request.valid_until, request.valid_until, relationship.id })
        if not window or tonumber(window.valid_window) ~= 1 then
            return rejected('RELATIONSHIP_INVALID', 'The relationship validity window is invalid.')
        end
    end
    local reason, reasonError = checkedReason(runtime, request.reason, 'relationship_changed')
    if not reason then return nil, reasonError, nil end
    local nextVersion = version + 1
    local updated = tx.query([[UPDATE `synex_group_relationships`
        SET `status` = ?, `valid_until` = COALESCE(CAST(? AS DATETIME(6)), `valid_until`),
            `ended_at` = CASE WHEN ? = 'ended' THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
            `reason_code` = ?, `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]], {
        request.status, request.valid_until, request.status, reason,
        relationship.id, version
    })
    if affectedRows(updated) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The relationship changed during the update.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, relationship.source_group_id)
    if not bumped then return nil, bumpError, nil end
    bumped, bumpError = bumpReadModel(tx, relationship.target_group_id)
    if not bumped then return nil, bumpError, nil end
    local before = { status = relationship.status, valid_until = relationship.valid_until, version = version }
    local after = { status = request.status,
        valid_until = request.valid_until or relationship.valid_until, version = nextVersion }
    local effect = runtime.effect('relationship.changed', 'relationship',
        request.relationship_id, relationship.source_public_id,
        request.actor_character_id, before, after, reason)
    return mutationResult(runtime, request.relationship_id, 'relationship',
        request.status, nextVersion, effect)
end
function execute.grades_create(tx, request, runtime, context)
    local allowed, authorizationError = authorize(runtime, tx, request.group_id,
        request.actor_character_id, 'synex.groups.grades.manage',
        { kind = 'group', group_id = request.group_id, rank = request.rank })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = loadGroupForUpdate(tx, request.group_id)
    if not group then return nil, groupError, nil end
    if group.status ~= 'active' then
        return rejected('GROUP_INACTIVE', 'The organization is not active.')
    end
    if tx.one([[SELECT `id` FROM `synex_group_grades`
        WHERE `group_id` = ? AND `grade_key` = ? FOR UPDATE]], { group.id, request.key }) then
        return rejected('GRADE_EXISTS', 'The organization grade already exists.')
    end
    local gradeId, gradeIdError = checkedId(runtime, 'groups_grade')
    if not gradeId then return nil, gradeIdError, nil end
    if affectedRows(tx.query([[INSERT INTO `synex_group_grades`
        (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
        VALUES (?, ?, ?, ?, ?, 'active', 1)]],
        { gradeId, group.id, request.key, request.label, request.rank })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization grade could not be created.', true)
    end
    local storedGrade = tx.one('SELECT `id` FROM `synex_group_grades` WHERE `public_id` = ? FOR UPDATE',
        { gradeId })
    if not storedGrade or affectedRows(tx.query([[INSERT INTO `synex_group_grade_controls`
        (`grade_id`, `member_limit`, `promotion_requires_approval`, `version`)
        VALUES (?, ?, 0, 1)]], { storedGrade and storedGrade.id, request.capacity })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization grade controls could not be created.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, group.id)
    if not bumped then return nil, bumpError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'grade_created')
    if not reason then return nil, reasonError, nil end
    local after = { grade_id = gradeId, key = request.key, label = request.label,
        rank = request.rank, capacity = request.capacity, status = 'active', version = 1 }
    local effect = runtime.effect('grade.created', 'grade', gradeId,
        request.group_id, request.actor_character_id, nil, after, reason)
    return mutationResult(runtime, gradeId, 'grade', 'active', 1, effect)
end
function execute.grades_update(tx, request, runtime, context)
    local grade = tx.one([[SELECT `grade`.`id`, `grade`.`public_id`, `grade`.`group_id`,
            `grade`.`display_name`, `grade`.`rank_value`, `grade`.`status`, `grade`.`version`,
            `control`.`member_limit`, `control`.`version` AS `control_version`,
            `group_record`.`public_id` AS `group_public_id`, `group_record`.`status` AS `group_status`
        FROM `synex_group_grades` AS `grade`
        INNER JOIN `synex_group_grade_controls` AS `control` ON `control`.`grade_id` = `grade`.`id`
        INNER JOIN `synex_groups` AS `group_record` ON `group_record`.`id` = `grade`.`group_id`
        WHERE `grade`.`public_id` = ? FOR UPDATE]], { request.grade_id })
    if not grade then return rejected('GRADE_NOT_FOUND', 'The organization grade does not exist.') end
    local allowed, authorizationError = authorize(runtime, tx, grade.group_public_id,
        request.actor_character_id, 'synex.groups.grades.manage', {
            kind = 'grade', group_id = grade.group_public_id, grade_id = request.grade_id,
            current_rank = tonumber(grade.rank_value), target_rank = request.rank
        })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local version = tonumber(grade.version)
    if version ~= tonumber(request.expected_version) or tonumber(grade.control_version) ~= version then
        return rejected('CONCURRENT_MODIFICATION', 'The organization grade version has changed.', true,
            { expected = request.expected_version, actual = version })
    end
    if grade.group_status ~= 'active' then
        return rejected('GROUP_INACTIVE', 'The organization is not active.')
    end
    if request.status ~= nil and not GRADE_STATUS[request.status] then
        return rejected('VALIDATION_FAILED', 'The requested grade status is invalid.')
    end
    local holder = tx.one([[SELECT COUNT(*) AS `active_holders`
        FROM `synex_group_membership_grades` AS `assigned`
        INNER JOIN `synex_group_membership_profiles` AS `profile`
            ON `profile`.`membership_id` = `assigned`.`membership_id`
        WHERE `assigned`.`grade_id` = ? AND `profile`.`lifecycle_state` = 'ACTIVE' FOR UPDATE]],
        { grade.id }) or {}
    local activeHolders = tonumber(holder.active_holders) or 0
    if request.capacity ~= nil and activeHolders > request.capacity then
        return rejected('GRADE_CAPACITY_REACHED',
            'The requested grade capacity is below its active holder count.', false,
            { active_holders = activeHolders })
    end
    if request.status == 'disabled' and activeHolders > 0 then
        return rejected('GRADE_IN_USE', 'A grade with active holders cannot be disabled.')
    end
    local reason, reasonError = checkedReason(runtime, request.reason, 'grade_changed')
    if not reason then return nil, reasonError, nil end
    local nextVersion = version + 1
    local updated = tx.query([[UPDATE `synex_group_grades`
        SET `display_name` = COALESCE(?, `display_name`),
            `rank_value` = COALESCE(?, `rank_value`),
            `status` = COALESCE(?, `status`), `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]],
        { request.label, request.rank, request.status, grade.id, version })
    local controls = tx.query([[UPDATE `synex_group_grade_controls`
        SET `member_limit` = COALESCE(?, `member_limit`), `version` = `version` + 1
        WHERE `grade_id` = ? AND `version` = ?]],
        { request.capacity, grade.id, version })
    if affectedRows(updated) ~= 1 or affectedRows(controls) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The grade changed during the update.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, grade.group_id)
    if not bumped then return nil, bumpError, nil end
    local before = { label = grade.display_name, rank = tonumber(grade.rank_value),
        capacity = tonumber(grade.member_limit), status = grade.status, version = version }
    local after = { label = request.label or grade.display_name,
        rank = request.rank or tonumber(grade.rank_value), capacity = request.capacity or tonumber(grade.member_limit),
        status = request.status or grade.status, version = nextVersion }
    local effect = runtime.effect('grade.changed', 'grade', request.grade_id,
        grade.group_public_id, request.actor_character_id, before, after, reason)
    return mutationResult(runtime, request.grade_id, 'grade', after.status, nextVersion, effect)
end
function execute.roles_create(tx, request, runtime, context)
    local allowed, authorizationError = authorize(runtime, tx, request.group_id,
        request.actor_character_id, 'synex.groups.roles.manage',
        { kind = 'group', group_id = request.group_id })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = loadGroupForUpdate(tx, request.group_id)
    if not group then return nil, groupError, nil end
    if group.status ~= 'active' then
        return rejected('GROUP_INACTIVE', 'The organization is not active.')
    end
    if tx.one([[SELECT `id` FROM `synex_group_roles`
        WHERE `group_id` = ? AND `role_key` = ? FOR UPDATE]], { group.id, request.key }) then
        return rejected('ROLE_EXISTS', 'The organization role already exists.')
    end
    local roleId, roleIdError = checkedId(runtime, 'groups_role')
    if not roleId then return nil, roleIdError, nil end
    local roleStatus = request.assignable == false and 'disabled' or 'active'
    local exclusivity = request.exclusive == true and 'group' or 'none'
    local inserted = tx.query([[INSERT INTO `synex_group_roles`
        (`public_id`, `group_id`, `role_key`, `display_name`, `description`,
         `exclusivity`, `holder_limit`, `status`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
        roleId, group.id, request.key, request.label, request.description,
        exclusivity, request.capacity, roleStatus
    })
    if affectedRows(inserted) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization role could not be created.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, group.id)
    if not bumped then return nil, bumpError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'role_created')
    if not reason then return nil, reasonError, nil end
    local after = { role_id = roleId, key = request.key, label = request.label,
        description = request.description, assignable = roleStatus == 'active',
        exclusive = exclusivity == 'group', capacity = request.capacity,
        status = roleStatus, version = 1 }
    local effect = runtime.effect('role.created', 'role', roleId,
        request.group_id, request.actor_character_id, nil, after, reason)
    return mutationResult(runtime, roleId, 'role', roleStatus, 1, effect)
end
function execute.roles_update(tx, request, runtime, context)
    local role = tx.one([[SELECT `role`.`id`, `role`.`public_id`, `role`.`group_id`,
            `role`.`display_name`, `role`.`description`, `role`.`exclusivity`,
            `role`.`holder_limit`, `role`.`status`, `role`.`version`,
            `group_record`.`public_id` AS `group_public_id`, `group_record`.`status` AS `group_status`
        FROM `synex_group_roles` AS `role`
        INNER JOIN `synex_groups` AS `group_record` ON `group_record`.`id` = `role`.`group_id`
        WHERE `role`.`public_id` = ? FOR UPDATE]], { request.role_id })
    if not role then return rejected('ROLE_NOT_FOUND', 'The organization role does not exist.') end
    local targetStatus = request.status
    local assignableStatus = request.assignable ~= nil
        and (request.assignable and 'active' or 'disabled') or nil
    local allowed, authorizationError = authorize(runtime, tx, role.group_public_id,
        request.actor_character_id, 'synex.groups.roles.manage',
        { kind = 'role', group_id = role.group_public_id, role_id = request.role_id })
    if not allowed then return nil, authorizationError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if assignableStatus ~= nil then
        if targetStatus ~= nil and targetStatus ~= assignableStatus then
            return rejected('VALIDATION_FAILED',
                'assignable conflicts with the requested role status.')
        end
        targetStatus = assignableStatus
    end
    local version = tonumber(role.version)
    if version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION', 'The organization role version has changed.', true,
            { expected = request.expected_version, actual = version })
    end
    if role.group_status ~= 'active' then
        return rejected('GROUP_INACTIVE', 'The organization is not active.')
    end
    if request.status ~= nil and not ROLE_STATUS[request.status] then
        return rejected('VALIDATION_FAILED', 'The requested role status is invalid.')
    end
    local holder = tx.one([[SELECT COUNT(*) AS `active_holders`
        FROM `synex_group_membership_roles`
        WHERE `role_id` = ? AND `status` = 'active'
            AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6)) FOR UPDATE]],
        { role.id }) or {}
    local activeHolders = tonumber(holder.active_holders) or 0
    local targetExclusive = request.exclusive == nil
        and role.exclusivity == 'group' or request.exclusive == true
    if targetExclusive and activeHolders > 1 then
        return rejected('ROLE_EXCLUSIVE_CONFLICT',
            'An exclusive role cannot retain multiple active holders.', false,
            { active_holders = activeHolders })
    end
    if request.capacity ~= nil and activeHolders > request.capacity then
        return rejected('MEMBER_LIMIT_REACHED',
            'The requested role capacity is below its active holder count.', false,
            { active_holders = activeHolders })
    end
    if targetStatus ~= nil and targetStatus ~= 'active' and activeHolders > 0 then
        return rejected('ROLE_IN_USE', 'A role with active holders cannot be disabled or retired.')
    end
    local reason, reasonError = checkedReason(runtime, request.reason, 'role_changed')
    if not reason then return nil, reasonError, nil end
    local nextVersion = version + 1
    local updated = tx.query([[UPDATE `synex_group_roles`
        SET `display_name` = COALESCE(?, `display_name`),
            `description` = COALESCE(?, `description`),
            `exclusivity` = COALESCE(?, `exclusivity`),
            `holder_limit` = COALESCE(?, `holder_limit`),
            `status` = COALESCE(?, `status`), `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]], {
        request.label, request.description,
        request.exclusive == nil and nil or targetExclusive and 'group' or 'none',
        request.capacity, targetStatus, role.id, version
    })
    if affectedRows(updated) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The role changed during the update.', true)
    end
    if request.exclusive ~= nil then
        tx.query([[UPDATE `synex_group_membership_roles`
            SET `exclusive_role_id` = ?, `version` = `version` + 1
            WHERE `role_id` = ? AND `status` = 'active']],
            { targetExclusive and role.id or nil, role.id })
    end
    local bumped, bumpError = bumpReadModel(tx, role.group_id)
    if not bumped then return nil, bumpError, nil end
    local before = { label = role.display_name, description = role.description,
        exclusive = role.exclusivity == 'group', capacity = tonumber(role.holder_limit),
        status = role.status, version = version }
    local after = { label = request.label or role.display_name,
        description = request.description or role.description,
        assignable = (targetStatus or role.status) == 'active', exclusive = targetExclusive,
        capacity = request.capacity or tonumber(role.holder_limit),
        status = targetStatus or role.status, version = nextVersion }
    local effect = runtime.effect('role.changed', 'role', request.role_id,
        role.group_public_id, request.actor_character_id, before, after, reason)
    return mutationResult(runtime, request.role_id, 'role', after.status, nextVersion, effect)
end
return { read = read, execute = execute }
end
