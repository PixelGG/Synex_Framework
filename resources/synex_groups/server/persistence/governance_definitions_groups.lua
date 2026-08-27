return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local rejected = Shared.rejected
local isObject = Shared.isObject
local arrayLength = Shared.arrayLength
local closedObject = Shared.closedObject
local publicId = Shared.publicId
local canonical = Shared.canonical
local copyJson = Shared.copyJson
local CapabilityDefinitions = require(
    'server.persistence.governance_definitions_capabilities')(Foundation)
local DefinitionHierarchy = require(
    'server.persistence.governance_definitions_hierarchy')(Foundation)

local GROUP_FIELDS = {
    key = true, kind = true, type = true, slug = true, name = true,
    label = true, description = true, visibility = true, parent_key = true,
    metadata = true, grades = true, roles = true, capabilities = true
}
local VISIBILITIES = { public = true, internal = true, private = true, hidden = true }

local function validKey(value, minimum, maximum, pattern)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match(pattern) ~= nil
end

local function validText(value, minimum, maximum)
    local length = Foundation.characterLength(value)
    return length >= minimum and length <= maximum
        and value:find('[%z\1-\8\11\12\14-\31\127]') == nil
end

local function copyMetadata(value)
    if value == nil then return {}, nil end
    if not isObject(value) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'A static group metadata value must be an object.')
    end
    return copyJson(value, {
        maximumDepth = 8,
        maximumKeys = 128,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
end

local DefinitionNormalization = require(
    'server.persistence.governance_definitions_group_normalization')(Foundation, {
    arrayLength = arrayLength,
    closedObject = closedObject,
    validKey = validKey,
    validText = validText,
    capabilityDefinitions = CapabilityDefinitions
})
local normalizeGrades = DefinitionNormalization.grades
local normalizeRoles = DefinitionNormalization.roles

local function normalizeGroup(definition)
    local shaped, shapeError = closedObject(definition, GROUP_FIELDS,
        'A static group definition')
    if not shaped then return nil, shapeError end
    if definition.kind ~= nil and definition.kind ~= 'group'
        or not validKey(definition.key, 2, 96, '^[a-z][a-z0-9_.:%-]*$')
        or not validKey(definition.type, 2, 32, '^[a-z][a-z0-9_]*$')
        or not validKey(definition.slug, 3, 64, '^[a-z][a-z0-9_%-]*$')
        or not validText(definition.name, 1, 96)
        or not validText(definition.label, 1, 96)
        or definition.description ~= nil and not validText(definition.description, 0, 1024)
        or definition.visibility ~= nil and not VISIBILITIES[definition.visibility]
        or definition.parent_key ~= nil
            and not validKey(definition.parent_key, 2, 96, '^[a-z][a-z0-9_.:%-]*$') then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'A static group definition has an invalid field.')
    end
    if definition.parent_key == definition.key then
        return nil, Foundation.domainError('HIERARCHY_CYCLE',
            'A static group cannot be its own parent.')
    end
    local metadata, metadataError = copyMetadata(definition.metadata)
    if not metadata then return nil, metadataError end
    local grades, gradesError = normalizeGrades(definition.grades)
    if not grades then return nil, gradesError end
    local roles, rolesError = normalizeRoles(definition.roles)
    if not roles then return nil, rolesError end
    local capabilities, capabilityError = CapabilityDefinitions.normalize(
        definition.capabilities, 'group')
    if not capabilities then return nil, capabilityError end
    return {
        key = definition.key,
        kind = 'group',
        type = definition.type,
        slug = definition.slug,
        name = definition.name,
        label = definition.label,
        description = definition.description,
        visibility = definition.visibility or 'internal',
        parent_key = definition.parent_key,
        metadata = metadata,
        grades = grades,
        roles = roles,
        capabilities = capabilities
    }, nil
end

local function orderedGroups(plan, byKey)
    local ordered, state = {}, {}
    local function visit(item)
        if state[item.key] == 2 then return true, nil end
        if state[item.key] == 1 then
            return nil, Foundation.domainError('HIERARCHY_CYCLE',
                'Static group parent definitions contain a cycle.', false,
                { key = item.key })
        end
        state[item.key] = 1
        local parentKey = item.group and item.group.parent_key
        if parentKey ~= nil then
            local parent = byKey[parentKey]
            if not parent or parent.kind ~= 'group' then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'A static group parent must be another group in the same owner sync.', false,
                    { key = item.key, parent_key = parentKey })
            end
            local visited, visitError = visit(parent)
            if not visited then return nil, visitError end
        end
        state[item.key] = 2
        ordered[#ordered + 1] = item
        return true, nil
    end
    for _, item in ipairs(plan) do
        if item.kind == 'group' then
            local visited, visitError = visit(item)
            if not visited then return nil, visitError end
        end
    end
    return ordered, nil
end

local function issue(state, code, targetKind, targetRef, details)
    state.issues[#state.issues + 1] = {
        code = code,
        targetKind = targetKind or 'definition',
        targetRef = targetRef or '',
        details = details or {}
    }
end

local function sameScalar(left, right)
    if left == nil and right == nil then return true end
    return left == right
end

local function inspectGroup(tx, item, runtime, dryRun)
    local suffix = dryRun and '' or ' FOR UPDATE'
    local definition = item.group
    local state = { issues = {}, grades = {}, roles = {}, needsWrite = item.change ~= 'unchanged' }
    item.groupState = state
    state.type = tx.one([[SELECT `id`, `type_key`, `status`, `membership_limit`,
            `hierarchy_enabled`
        FROM `synex_group_types` WHERE `type_key` = ?]] .. suffix, { definition.type })
    if not state.type or state.type.status ~= 'active' then
        issue(state, 'GROUP_TYPE_UNAVAILABLE', 'definition', '', { type = definition.type })
        return state
    end
    if definition.parent_key ~= nil and tonumber(state.type.hierarchy_enabled) ~= 1 then
        issue(state, 'GROUP_HIERARCHY_DISABLED', 'definition', '', { type = definition.type })
    end
    local targetId = item.existing and tonumber(item.existing.target_group_id) or nil
    if not targetId then
        local collision = tx.one([[SELECT `id`, `public_id` FROM `synex_groups`
            WHERE `group_key` = ?]] .. suffix, { definition.slug })
        if collision then
            issue(state, 'GROUP_SLUG_CONFLICT', 'group', collision.public_id,
                { slug = definition.slug })
        end
        state.mode = 'create'
        state.needsWrite = true
        CapabilityDefinitions.inspect(tx, item, state, dryRun)
        return state
    end

    state.live = tx.one([[SELECT `group_record`.`id`, `group_record`.`public_id`,
            `group_record`.`group_key`, `group_record`.`display_name`,
            `group_record`.`group_type`, `group_record`.`status`,
            `group_record`.`metadata_json`, `group_record`.`version`,
            `profile`.`group_type_id`, `profile`.`slug`, `profile`.`name`,
            `profile`.`label`, `profile`.`description`, `profile`.`visibility`,
            `profile`.`creation_source`, `profile`.`dynamic`,
            `profile`.`lifecycle_state`, `profile`.`definition_key`,
            `profile`.`definition_digest`, `profile`.`metadata_json` AS `profile_metadata_json`,
            `profile`.`version` AS `profile_version`,
            `edge`.`parent_group_id`, `edge`.`version` AS `edge_version`
        FROM `synex_groups` AS `group_record`
        INNER JOIN `synex_group_organization_profiles` AS `profile`
            ON `profile`.`group_id` = `group_record`.`id`
        LEFT JOIN `synex_group_hierarchy_edges` AS `edge`
            ON `edge`.`child_group_id` = `group_record`.`id`
        WHERE `group_record`.`id` = ?]] .. suffix, { targetId })
    local live = state.live
    if not live then
        issue(state, 'DEFINITION_TARGET_MISSING')
        return state
    end
    if live.definition_key ~= item.publicId or live.creation_source ~= 'static'
        or tonumber(live.dynamic) ~= 0 then
        issue(state, 'DEFINITION_TARGET_OWNERSHIP_CONFLICT', 'group', live.public_id)
    end
    if live.status ~= 'active' or live.lifecycle_state ~= 'ACTIVE' then
        issue(state, 'DEFINITION_TARGET_INACTIVE', 'group', live.public_id,
            { status = live.status, lifecycle_state = live.lifecycle_state })
    end
    if live.group_type ~= definition.type or tonumber(live.group_type_id) ~= tonumber(state.type.id) then
        issue(state, 'GROUP_TYPE_CHANGE_REQUIRES_MIGRATION', 'group', live.public_id,
            { current_type = live.group_type, requested_type = definition.type })
    end
    local collision = tx.one([[SELECT `id`, `public_id` FROM `synex_groups`
        WHERE `group_key` = ? AND `id` <> ?]] .. suffix, { definition.slug, live.id })
    if collision then
        issue(state, 'GROUP_SLUG_CONFLICT', 'group', collision.public_id,
            { slug = definition.slug })
    end
    local version, profileVersion = tonumber(live.version), tonumber(live.profile_version)
    if not version or version ~= profileVersion then
        issue(state, 'DEFINITION_TARGET_VERSION_INVALID', 'group', live.public_id)
    end
    live.version, live.profile_version = version, profileVersion

    if not dryRun then
        tx.many([[SELECT `id` FROM `synex_group_grades`
            WHERE `group_id` = ? ORDER BY `id` ASC FOR UPDATE]], { live.id })
        tx.many([[SELECT `id` FROM `synex_group_roles`
            WHERE `group_id` = ? ORDER BY `id` ASC FOR UPDATE]], { live.id })
    end
    local gradeRows = tx.many([[SELECT `grade`.`id`, `grade`.`public_id`,
            `grade`.`grade_key`, `grade`.`display_name`, `grade`.`rank_value`,
            `grade`.`status`, `grade`.`version`, `control`.`member_limit`,
            `control`.`version` AS `control_version`,
            SUM(CASE WHEN `membership_profile`.`lifecycle_state` = 'ACTIVE'
                THEN 1 ELSE 0 END) AS `active_holders`,
            COUNT(DISTINCT CASE
                WHEN `membership_profile`.`lifecycle_state` NOT IN
                    ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
                THEN `assigned`.`membership_id` ELSE NULL END) AS `nonterminal_holders`,
            (SELECT COUNT(*) FROM `synex_group_invitations` AS `invitation`
                WHERE `invitation`.`grade_id` = `grade`.`id`
                    AND `invitation`.`status` = 'pending'
                    AND `invitation`.`expires_at` > CURRENT_TIMESTAMP(6))
                AS `pending_invitations`,
            (SELECT COUNT(*) FROM `synex_group_proposals` AS `proposal`
                WHERE `proposal`.`group_id` = `grade`.`group_id`
                    AND `proposal`.`proposal_type` = 'membership.set_grade'
                    AND `proposal`.`status` IN ('pending', 'approved')
                    AND `proposal`.`expires_at` > CURRENT_TIMESTAMP(6)
                    AND JSON_UNQUOTE(JSON_EXTRACT(
                        `proposal`.`payload_json`, '$.grade_id')) = `grade`.`public_id`)
                AS `pending_grade_proposals`
        FROM `synex_group_grades` AS `grade`
        INNER JOIN `synex_group_grade_controls` AS `control`
            ON `control`.`grade_id` = `grade`.`id`
        LEFT JOIN `synex_group_membership_grades` AS `assigned`
            ON `assigned`.`grade_id` = `grade`.`id`
        LEFT JOIN `synex_group_membership_profiles` AS `membership_profile`
            ON `membership_profile`.`membership_id` = `assigned`.`membership_id`
        WHERE `grade`.`group_id` = ?
        GROUP BY `grade`.`id`, `grade`.`public_id`, `grade`.`grade_key`,
            `grade`.`display_name`, `grade`.`rank_value`, `grade`.`status`,
            `grade`.`version`, `control`.`member_limit`, `control`.`version`
        ORDER BY `grade`.`id` ASC]], { live.id })
    for _, row in ipairs(gradeRows) do state.grades[row.grade_key] = row end
    local roleRows = tx.many([[SELECT `role`.`id`, `role`.`public_id`,
            `role`.`role_key`, `role`.`display_name`, `role`.`description`,
            `role`.`exclusivity`, `role`.`holder_limit`, `role`.`status`,
            `role`.`version`,
            SUM(CASE WHEN `assignment`.`status` = 'active'
                AND (`assignment`.`valid_until` IS NULL
                    OR `assignment`.`valid_until` > CURRENT_TIMESTAMP(6))
                THEN 1 ELSE 0 END) AS `active_holders`
        FROM `synex_group_roles` AS `role`
        LEFT JOIN `synex_group_membership_roles` AS `assignment`
            ON `assignment`.`role_id` = `role`.`id`
        WHERE `role`.`group_id` = ?
        GROUP BY `role`.`id`, `role`.`public_id`, `role`.`role_key`,
            `role`.`display_name`, `role`.`description`, `role`.`exclusivity`,
            `role`.`holder_limit`, `role`.`status`, `role`.`version`
        ORDER BY `role`.`id` ASC]], { live.id })
    for _, row in ipairs(roleRows) do state.roles[row.role_key] = row end

    local previousGrades, previousRoles = {}, {}
    if item.previousGroup then
        for _, grade in ipairs(item.previousGroup.grades) do previousGrades[grade.key] = true end
        for _, role in ipairs(item.previousGroup.roles) do previousRoles[role.key] = true end
    elseif item.existing and item.existing.target_group_id then
        issue(state, 'STORED_DEFINITION_INVALID', 'group', live.public_id)
    end
    local requestedGrades, requestedRoles = {}, {}
    for _, grade in ipairs(definition.grades) do
        requestedGrades[grade.key] = true
        local row = state.grades[grade.key]
        if not row then
            state.needsWrite = true
        elseif not previousGrades[grade.key] and row.status ~= 'disabled' then
            issue(state, 'GRADE_OWNERSHIP_CONFLICT', 'grade', row.public_id,
                { key = grade.key })
        elseif row then
            if tonumber(row.version) == nil
                or tonumber(row.version) ~= tonumber(row.control_version) then
                issue(state, 'GRADE_VERSION_INVALID', 'grade', row.public_id,
                    { key = grade.key })
            end
            local holders = tonumber(row.active_holders) or 0
            if grade.capacity ~= nil and holders > grade.capacity then
                issue(state, 'GRADE_CAPACITY_CONFLICT', 'grade', row.public_id,
                    { active_holders = holders, capacity = grade.capacity })
            end
            if grade.status == 'disabled' and holders > 0 then
                issue(state, 'GRADE_IN_USE', 'grade', row.public_id,
                    { active_holders = holders })
            end
            if row.display_name ~= grade.label or tonumber(row.rank_value) ~= grade.rank
                or tonumber(row.member_limit) ~= tonumber(grade.capacity)
                or row.status ~= grade.status then
                state.needsWrite = true
            end
        end
    end
    for key in pairs(previousGrades) do
        if not requestedGrades[key] then
            local row = state.grades[key]
            local holders = row and tonumber(row.nonterminal_holders)
            if holders == nil and row then holders = tonumber(row.active_holders) end
            holders = holders or 0
            local invitations = row and tonumber(row.pending_invitations) or 0
            local proposals = row and tonumber(row.pending_grade_proposals) or 0
            if not row or holders > 0 or invitations > 0 or proposals > 0 then
                issue(state, 'GRADE_REMOVAL_REQUIRES_MIGRATION',
                    row and 'grade' or 'definition', row and row.public_id or '', {
                        key = key,
                        nonterminal_holders = holders,
                        pending_invitations = invitations,
                        pending_grade_proposals = proposals
                    })
            elseif row.status ~= 'disabled' then
                state.retiredGrades = state.retiredGrades or {}
                state.retiredGrades[#state.retiredGrades + 1] = row
                state.needsWrite = true
            end
        end
    end
    for key, row in pairs(state.grades) do
        if not requestedGrades[key] and not previousGrades[key]
            and row.status ~= 'disabled' then
            issue(state, 'GRADE_OWNERSHIP_CONFLICT', 'grade', row.public_id,
                { key = key })
        end
    end
    for _, role in ipairs(definition.roles) do
        requestedRoles[role.key] = true
        local row = state.roles[role.key]
        if not row then
            state.needsWrite = true
        elseif not previousRoles[role.key] then
            issue(state, 'ROLE_OWNERSHIP_CONFLICT', 'role', row.public_id,
                { key = role.key })
        elseif row then
            local holders = tonumber(row.active_holders) or 0
            if role.capacity ~= nil and holders > role.capacity then
                issue(state, 'ROLE_CAPACITY_CONFLICT', 'role', row.public_id,
                    { active_holders = holders, capacity = role.capacity })
            end
            if role.status ~= 'active' and holders > 0 then
                issue(state, 'ROLE_IN_USE', 'role', row.public_id,
                    { active_holders = holders })
            end
            if role.exclusive and holders > 1 then
                issue(state, 'ROLE_EXCLUSIVE_CONFLICT', 'role', row.public_id,
                    { active_holders = holders })
            end
            local exclusivity = role.exclusive and 'group' or 'none'
            if row.display_name ~= role.label or not sameScalar(row.description, role.description)
                or row.exclusivity ~= exclusivity
                or tonumber(row.holder_limit) ~= tonumber(role.capacity)
                or row.status ~= role.status then
                state.needsWrite = true
            end
        end
    end
    for key in pairs(previousRoles) do
        if not requestedRoles[key] then
            local row = state.roles[key]
            issue(state, 'ROLE_REMOVAL_REQUIRES_MIGRATION',
                row and 'role' or 'definition', row and row.public_id or '', { key = key })
        end
    end
    for key, row in pairs(state.roles) do
        if not requestedRoles[key] and not previousRoles[key] then
            issue(state, 'ROLE_OWNERSHIP_CONFLICT', 'role', row.public_id,
                { key = key })
        end
    end
    local metadataJson = canonical(runtime, definition.metadata)
    state.metadataJson = metadataJson
    if live.group_key ~= definition.slug or live.display_name ~= definition.label
        or live.slug ~= definition.slug or live.name ~= definition.name
        or live.label ~= definition.label or not sameScalar(live.description, definition.description)
        or live.visibility ~= definition.visibility
        or live.metadata_json ~= metadataJson or live.profile_metadata_json ~= metadataJson
        or live.definition_digest ~= item.digest then
        state.needsWrite = true
    end
    state.mode = 'update'
    CapabilityDefinitions.inspect(tx, item, state, dryRun)
    return state
end

local function reconcileGroup(tx, item, runtime, parentItem)
    local definition, state = item.group, item.groupState
    local metadataJson, metadataError = canonical(runtime, definition.metadata)
    if not metadataJson then return nil, metadataError end
    local groupPublicId, before
    if state.mode == 'create' then
        groupPublicId, metadataError = publicId(runtime, 'groups_group')
        if not groupPublicId then return nil, metadataError end
        tx.query([[INSERT INTO `synex_groups`
            (`public_id`, `group_key`, `display_name`, `group_type`, `status`,
             `created_by_ref`, `metadata_json`, `version`)
            VALUES (?, ?, ?, ?, 'active', NULL, ?, 1)]],
            { groupPublicId, definition.slug, definition.label, definition.type, metadataJson })
        local stored = tx.one('SELECT `id` FROM `synex_groups` WHERE `public_id` = ? FOR UPDATE',
            { groupPublicId })
        if not stored or tonumber(stored.id) == nil then
            return rejected('DATABASE_RESULT_INVALID',
                'The static group could not be resolved after creation.', true)
        end
        item.targetGroupId = tonumber(stored.id)
        item.targetGroupPublicId = groupPublicId
        tx.query([[INSERT INTO `synex_group_organization_profiles`
            (`group_id`, `group_type_id`, `slug`, `visibility`, `creation_source`,
             `lifecycle_state`, `lifecycle_reason_code`, `state_changed_at`,
             `definition_key`, `definition_digest`, `name`, `label`, `description`,
             `dynamic`, `metadata_json`, `version`)
            VALUES (?, ?, ?, ?, 'static', 'ACTIVE', 'static_definition_applied',
                CURRENT_TIMESTAMP(6), ?, ?, ?, ?, ?, 0, ?, 1)]], {
            item.targetGroupId, state.type.id, definition.slug, definition.visibility,
            item.publicId, item.digest, definition.name, definition.label,
            definition.description, metadataJson
        })
        tx.query([[INSERT INTO `synex_group_hierarchy_closure`
            (`ancestor_group_id`, `descendant_group_id`, `depth`) VALUES (?, ?, 0)]],
            { item.targetGroupId, item.targetGroupId })
        tx.query([[INSERT INTO `synex_group_read_model_versions`
            (`group_id`, `model_version`, `invalidated_at`)
            VALUES (?, 1, CURRENT_TIMESTAMP(6))]], { item.targetGroupId })
    else
        local live = state.live
        item.targetGroupId = tonumber(live.id)
        item.targetGroupPublicId = live.public_id
        groupPublicId = live.public_id
        before = {
            slug = live.slug, name = live.name, label = live.label,
            visibility = live.visibility, definition_digest = live.definition_digest,
            version = tonumber(live.version)
        }
        if state.needsWrite then
            local groupUpdated = tx.affected([[UPDATE `synex_groups`
                SET `group_key` = ?, `display_name` = ?, `metadata_json` = ?,
                    `version` = `version` + 1
                WHERE `id` = ? AND `version` = ?]], {
                definition.slug, definition.label, metadataJson,
                live.id, live.version
            })
            local profileUpdated = tx.affected([[UPDATE `synex_group_organization_profiles`
                SET `slug` = ?, `name` = ?, `label` = ?, `description` = ?,
                    `visibility` = ?, `definition_digest` = ?, `metadata_json` = ?,
                    `lifecycle_reason_code` = 'static_definition_applied',
                    `state_changed_at` = CURRENT_TIMESTAMP(6),
                    `version` = `version` + 1
                WHERE `group_id` = ? AND `version` = ? AND `definition_key` = ?
                    AND `creation_source` = 'static' AND `dynamic` = 0]], {
                definition.slug, definition.name, definition.label, definition.description,
                definition.visibility, item.digest, metadataJson,
                live.id, live.profile_version, item.publicId
            })
            if groupUpdated ~= 1 or profileUpdated ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The static group changed during definition reconciliation.', true)
            end
        end
    end

    for _, grade in ipairs(definition.grades) do
        local row = state.grades[grade.key]
        if not row then
            local gradeId, gradeError = publicId(runtime, 'groups_grade')
            if not gradeId then return nil, gradeError end
            tx.query([[INSERT INTO `synex_group_grades`
                (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`,
                 `status`, `version`) VALUES (?, ?, ?, ?, ?, ?, 1)]], {
                gradeId, item.targetGroupId, grade.key, grade.label, grade.rank, grade.status
            })
            local stored = tx.one('SELECT `id` FROM `synex_group_grades` WHERE `public_id` = ? FOR UPDATE',
                { gradeId })
            if not stored then
                return rejected('DATABASE_RESULT_INVALID',
                    'A static group grade could not be resolved after creation.', true)
            end
            tx.query([[INSERT INTO `synex_group_grade_controls`
                (`grade_id`, `member_limit`, `promotion_requires_approval`, `version`)
                VALUES (?, ?, 0, 1)]], { stored.id, grade.capacity })
            state.grades[grade.key] = {
                id = tonumber(stored.id), public_id = gradeId,
                version = 1, control_version = 1
            }
        elseif row.display_name ~= grade.label or tonumber(row.rank_value) ~= grade.rank
            or tonumber(row.member_limit) ~= tonumber(grade.capacity) or row.status ~= grade.status then
            if tonumber(row.version) ~= tonumber(row.control_version)
                or tx.affected([[UPDATE `synex_group_grades`
                    SET `display_name` = ?, `rank_value` = ?, `status` = ?,
                        `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ?]], {
                    grade.label, grade.rank, grade.status, row.id, row.version
                }) ~= 1
                or tx.affected([[UPDATE `synex_group_grade_controls`
                    SET `member_limit` = ?, `version` = `version` + 1
                    WHERE `grade_id` = ? AND `version` = ?]], {
                    grade.capacity, row.id, row.control_version
                }) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'A static group grade changed during reconciliation.', true)
            end
        end
    end
    for _, row in ipairs(state.retiredGrades or {}) do
        if tonumber(row.version) ~= tonumber(row.control_version)
            or tx.affected([[UPDATE `synex_group_grades`
                SET `status` = 'disabled', `version` = `version` + 1
                WHERE `id` = ? AND `status` <> 'disabled' AND `version` = ?]], {
                row.id, row.version
            }) ~= 1
            or tx.affected([[UPDATE `synex_group_grade_controls`
                SET `member_limit` = NULL, `promotion_requires_approval` = 0,
                    `version` = `version` + 1
                WHERE `grade_id` = ? AND `version` = ?]], {
                row.id, row.control_version
            }) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A retired static group grade changed during reconciliation.', true)
        end
        row.status = 'disabled'
        row.member_limit = nil
        row.version = tonumber(row.version) + 1
        row.control_version = tonumber(row.control_version) + 1
    end
    for _, role in ipairs(definition.roles) do
        local row = state.roles[role.key]
        local exclusivity = role.exclusive and 'group' or 'none'
        if not row then
            local roleId, roleError = publicId(runtime, 'groups_role')
            if not roleId then return nil, roleError end
            tx.query([[INSERT INTO `synex_group_roles`
                (`public_id`, `group_id`, `role_key`, `display_name`, `description`,
                 `exclusivity`, `holder_limit`, `status`, `version`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
                roleId, item.targetGroupId, role.key, role.label, role.description,
                exclusivity, role.capacity, role.status
            })
            local stored = tx.one([[SELECT `id` FROM `synex_group_roles`
                WHERE `public_id` = ? FOR UPDATE]], { roleId })
            if not stored or tonumber(stored.id) == nil then
                return rejected('DATABASE_RESULT_INVALID',
                    'A static group role could not be resolved after creation.', true)
            end
            state.roles[role.key] = {
                id = tonumber(stored.id), public_id = roleId, version = 1
            }
        elseif row.display_name ~= role.label or not sameScalar(row.description, role.description)
            or row.exclusivity ~= exclusivity
            or tonumber(row.holder_limit) ~= tonumber(role.capacity) or row.status ~= role.status then
            if tx.affected([[UPDATE `synex_group_roles`
                SET `display_name` = ?, `description` = ?, `exclusivity` = ?,
                    `holder_limit` = ?, `status` = ?, `version` = `version` + 1
                WHERE `id` = ? AND `version` = ?]], {
                role.label, role.description, exclusivity, role.capacity,
                role.status, row.id, row.version
            }) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'A static group role changed during reconciliation.', true)
            end
            if row.exclusivity ~= exclusivity then
                tx.query([[UPDATE `synex_group_membership_roles`
                    SET `exclusive_role_id` = ?, `version` = `version` + 1
                    WHERE `role_id` = ? AND `status` = 'active']],
                    { role.exclusive and row.id or nil, row.id })
            end
        end
    end
    local capabilitiesApplied, capabilityError = CapabilityDefinitions.reconcile(
        tx, item, state)
    if not capabilitiesApplied then return nil, capabilityError end
    local parentApplied, parentError = DefinitionHierarchy.apply(tx, item, parentItem)
    if not parentApplied then return nil, parentError end
    if state.mode == 'update' and state.needsWrite then
        if tx.affected([[UPDATE `synex_group_read_model_versions`
            SET `model_version` = `model_version` + 1,
                `invalidated_at` = CURRENT_TIMESTAMP(6) WHERE `group_id` = ?]],
            { item.targetGroupId }) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The static group read model could not be invalidated.', true)
        end
    end
    local capabilityCount = #definition.capabilities
    for _, grade in ipairs(definition.grades) do
        capabilityCount = capabilityCount + #grade.capabilities
    end
    for _, role in ipairs(definition.roles) do
        capabilityCount = capabilityCount + #role.capabilities
    end
    local after = {
        definition_key = item.key,
        definition_digest = item.digest,
        slug = definition.slug,
        name = definition.name,
        label = definition.label,
        visibility = definition.visibility,
        parent_group_id = parentItem and parentItem.targetGroupPublicId or nil,
        capability_rules = capabilityCount,
        version = state.mode == 'create' and 1 or tonumber(state.live.version) + (state.needsWrite and 1 or 0)
    }
    return {
        targetGroupId = item.targetGroupId,
        targetGroupPublicId = item.targetGroupPublicId,
        effect = runtime.effect('definition.group.reconciled', 'group', groupPublicId,
            groupPublicId, nil, before, after, 'static_definition_applied'),
        summary = {
            group_id = groupPublicId,
            grades = #definition.grades,
            roles = #definition.roles,
            capability_rules = capabilityCount,
            parent_group_id = after.parent_group_id
        }
    }, nil
end

return {
    normalize = normalizeGroup,
    ordered = orderedGroups,
    inspect = inspectGroup,
    reconcile = reconcileGroup
}
end
