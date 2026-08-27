return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local arrayLength = Shared.arrayLength
local closedObject = Shared.closedObject

local RULE_FIELDS = {
    capability = true, effect = true, scope = true, delegable = true
}
local EFFECTS = { allow = true, deny = true }
local SCOPES = { group = true, subtree = true }

local function validCapability(value)
    if type(value) ~= 'string' or #value < 1 or #value > 96
        or value ~= value:lower() or value:sub(1, 1) == '.'
        or value:sub(-1) == '.' or value:find('..', 1, true) then
        return false
    end
    local base = value
    if value:sub(-2) == '.*' then
        base = value:sub(1, -3)
    elseif value:find('*', 1, true) then
        return false
    end
    local count = 0
    for segment in base:gmatch('[^.]+') do
        count = count + 1
        if not segment:match('^[a-z][a-z0-9_%-]*$') then return false end
    end
    return count > 0
end

local function normalizeRules(value, sourceKind)
    if value == nil then return {}, nil end
    local count = arrayLength(value, 64)
    if count == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Static capability rules must be a bounded dense array.')
    end
    local rules, seen = {}, {}
    for index = 1, count do
        local entry = value[index]
        local shaped, shapeError = closedObject(entry, RULE_FIELDS,
            'A static ' .. sourceKind .. ' capability rule')
        if not shaped then return nil, shapeError end
        local scope = entry.scope or 'group'
        if not validCapability(entry.capability) or not EFFECTS[entry.effect]
            or not SCOPES[scope] or entry.delegable ~= nil
                and type(entry.delegable) ~= 'boolean'
            or entry.effect == 'deny' and entry.delegable == true
            or seen[entry.capability] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A static capability rule is invalid or duplicates a capability.', false,
                { source_kind = sourceKind, index = index })
        end
        seen[entry.capability] = true
        rules[index] = {
            capability = entry.capability,
            effect = entry.effect,
            scope = scope,
            delegable = entry.delegable == true
        }
    end
    return rules, nil
end

local function storageScope(rule)
    if rule.scope == 'group' then return 'group', '' end
    return 'custom', 'subtree'
end

local function ruleKey(sourceKind, capability, scopeKind, scopeRef)
    local scope = scopeKind == 'subtree'
        or scopeKind == 'custom' and scopeRef == 'subtree'
    if not scope and (scopeKind ~= 'group' or scopeRef ~= '') then
        return nil
    end
    return sourceKind .. ':' .. capability .. ':' .. (scope and 'subtree' or 'group')
end

local function requestedKey(sourceKind, rule)
    return sourceKind .. ':' .. rule.capability .. ':' .. rule.scope
end

local function addRows(state, sourceKind, sourceKey, rows)
    local target = state.capabilityRules[sourceKind]
    target[sourceKey] = target[sourceKey] or {}
    for _, row in ipairs(rows) do
        local key = ruleKey(sourceKind, row.capability_pattern,
            row.scope_kind, row.scope_ref)
        if key == nil or target[sourceKey][key] ~= nil then
            state.capabilityAmbiguous = true
        else
            target[sourceKey][key] = row
        end
    end
end

local function previousRules(item, sourceKind, sourceKey)
    local previous = item.previousGroup
    if not previous then return {} end
    if sourceKind == 'group' then return previous.capabilities or {} end
    local sources = sourceKind == 'grade' and previous.grades or previous.roles
    for _, source in ipairs(sources or {}) do
        if source.key == sourceKey then return source.capabilities or {} end
    end
    return {}
end

local function requestedRules(item, sourceKind, sourceKey)
    if sourceKind == 'group' then return item.group.capabilities or {} end
    local sources = sourceKind == 'grade' and item.group.grades or item.group.roles
    for _, source in ipairs(sources) do
        if source.key == sourceKey then return source.capabilities or {} end
    end
    return {}
end

local function inspectSource(item, state, sourceKind, sourceKey)
    local live = state.capabilityRules[sourceKind][sourceKey] or {}
    local previous, requested = {}, {}
    for _, rule in ipairs(previousRules(item, sourceKind, sourceKey)) do
        previous[requestedKey(sourceKind, rule)] = true
    end
    for _, rule in ipairs(requestedRules(item, sourceKind, sourceKey)) do
        local key = requestedKey(sourceKind, rule)
        requested[key] = true
        local row = live[key]
        if row == nil then
            state.needsWrite = true
        elseif not previous[key] then
            state.issues[#state.issues + 1] = {
                code = 'CAPABILITY_OWNERSHIP_CONFLICT',
                targetKind = sourceKind, targetRef = row.source_public_id or '',
                details = { source_key = sourceKey, capability = rule.capability,
                    scope = rule.scope }
            }
        else
            local delegable = tonumber(row.delegable) == 1
            if row.effect ~= rule.effect or delegable ~= rule.delegable then
                state.needsWrite = true
            end
            if sourceKind == 'grade' and (tonumber(row.version) == nil
                or tonumber(row.version) ~= tonumber(row.scope_version)) then
                state.issues[#state.issues + 1] = {
                    code = 'CAPABILITY_VERSION_INVALID', targetKind = sourceKind,
                    targetRef = row.source_public_id or '',
                    details = { source_key = sourceKey, capability = rule.capability }
                }
            end
        end
    end
    for _, rule in ipairs(previousRules(item, sourceKind, sourceKey)) do
        local key = requestedKey(sourceKind, rule)
        if not requested[key] then
            local row = live[key]
            state.issues[#state.issues + 1] = {
                code = 'CAPABILITY_REMOVAL_REQUIRES_MIGRATION',
                targetKind = sourceKind, targetRef = row and row.source_public_id or '',
                details = { source_key = sourceKey, capability = rule.capability,
                    scope = rule.scope }
            }
        end
    end
    for key, row in pairs(live) do
        if not requested[key] and not previous[key] then
            state.issues[#state.issues + 1] = {
                code = 'CAPABILITY_OWNERSHIP_CONFLICT',
                targetKind = sourceKind, targetRef = row.source_public_id or '',
                details = { source_key = sourceKey,
                    capability = row.capability_pattern }
            }
        end
    end
end

local function inspect(tx, item, state, dryRun)
    state.capabilityRules = { group = {}, grade = {}, role = {} }
    if state.mode == 'create' or not state.live then return true, nil end
    local suffix = dryRun and '' or ' FOR UPDATE'
    local groupRows = tx.many([[SELECT `rule`.`id`, `rule`.`capability_pattern`,
            `rule`.`effect`, `rule`.`scope_kind`, `rule`.`scope_ref`,
            `rule`.`delegable`, `rule`.`version`,
            `group_record`.`public_id` AS `source_public_id`
        FROM `synex_group_default_capabilities` AS `rule`
        INNER JOIN `synex_groups` AS `group_record` ON `group_record`.`id` = `rule`.`group_id`
        WHERE `rule`.`group_id` = ? ORDER BY `rule`.`id` ASC LIMIT 257]] .. suffix,
        { state.live.id })
    if #groupRows > 256 then
        state.issues[#state.issues + 1] = {
            code = 'CAPABILITY_MODEL_TOO_LARGE', targetKind = 'group',
            targetRef = state.live.public_id, details = {}
        }
        return true, nil
    end
    addRows(state, 'group', item.key, groupRows)

    local gradeRows = tx.many([[SELECT `rule`.`id`, `rule`.`capability_pattern`,
            `rule`.`effect`, `scope`.`scope_kind`, `scope`.`scope_ref`,
            `rule`.`delegable`, `rule`.`version`, `scope`.`version` AS `scope_version`,
            `grade`.`grade_key` AS `source_key`, `grade`.`public_id` AS `source_public_id`
        FROM `synex_group_grade_capabilities` AS `rule`
        LEFT JOIN `synex_group_grade_capability_scopes` AS `scope`
            ON `scope`.`grade_capability_id` = `rule`.`id`
        INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`id` = `rule`.`grade_id`
        WHERE `grade`.`group_id` = ? ORDER BY `rule`.`id` ASC LIMIT 4097]] .. suffix,
        { state.live.id })
    local roleRows = tx.many([[SELECT `rule`.`id`, `rule`.`capability_pattern`,
            `rule`.`effect`, `rule`.`scope_kind`, `rule`.`scope_ref`,
            `rule`.`delegable`, `rule`.`version`, `role`.`role_key` AS `source_key`,
            `role`.`public_id` AS `source_public_id`
        FROM `synex_group_role_capabilities` AS `rule`
        INNER JOIN `synex_group_roles` AS `role` ON `role`.`id` = `rule`.`role_id`
        WHERE `role`.`group_id` = ? ORDER BY `rule`.`id` ASC LIMIT 4097]] .. suffix,
        { state.live.id })
    if #gradeRows > 4096 or #roleRows > 4096 then
        state.issues[#state.issues + 1] = {
            code = 'CAPABILITY_MODEL_TOO_LARGE', targetKind = 'group',
            targetRef = state.live.public_id, details = {}
        }
        return true, nil
    end
    local gradeBuckets, roleBuckets = {}, {}
    for _, row in ipairs(gradeRows) do
        gradeBuckets[row.source_key] = gradeBuckets[row.source_key] or {}
        gradeBuckets[row.source_key][#gradeBuckets[row.source_key] + 1] = row
    end
    for _, row in ipairs(roleRows) do
        roleBuckets[row.source_key] = roleBuckets[row.source_key] or {}
        roleBuckets[row.source_key][#roleBuckets[row.source_key] + 1] = row
    end
    for _, grade in ipairs(item.group.grades) do
        addRows(state, 'grade', grade.key, gradeBuckets[grade.key] or {})
    end
    for _, role in ipairs(item.group.roles) do
        addRows(state, 'role', role.key, roleBuckets[role.key] or {})
    end
    if state.capabilityAmbiguous then
        state.issues[#state.issues + 1] = {
            code = 'CAPABILITY_SCOPE_AMBIGUOUS', targetKind = 'group',
            targetRef = state.live.public_id, details = {}
        }
    end
    inspectSource(item, state, 'group', item.key)
    for _, grade in ipairs(item.group.grades) do
        inspectSource(item, state, 'grade', grade.key)
    end
    for _, role in ipairs(item.group.roles) do
        inspectSource(item, state, 'role', role.key)
    end
    return true, nil
end

local function insertRule(tx, sourceKind, sourceId, rule)
    local scopeKind, scopeRef = storageScope(rule)
    if sourceKind == 'group' then
        return tx.affected([[INSERT INTO `synex_group_default_capabilities`
            (`group_id`, `capability_pattern`, `effect`, `scope_kind`, `scope_ref`,
             `delegable`, `version`) VALUES (?, ?, ?, ?, ?, ?, 1)]],
            { sourceId, rule.capability, rule.effect, scopeKind, scopeRef,
                rule.delegable and 1 or 0 }) == 1
    end
    if sourceKind == 'role' then
        return tx.affected([[INSERT INTO `synex_group_role_capabilities`
            (`role_id`, `capability_pattern`, `effect`, `scope_kind`, `scope_ref`,
             `delegable`, `version`) VALUES (?, ?, ?, ?, ?, ?, 1)]],
            { sourceId, rule.capability, rule.effect, scopeKind, scopeRef,
                rule.delegable and 1 or 0 }) == 1
    end
    if tx.affected([[INSERT INTO `synex_group_grade_capabilities`
        (`grade_id`, `capability_pattern`, `effect`, `delegable`, `version`)
        VALUES (?, ?, ?, ?, 1)]],
        { sourceId, rule.capability, rule.effect, rule.delegable and 1 or 0 }) ~= 1 then
        return false
    end
    local stored = tx.one([[SELECT `id` FROM `synex_group_grade_capabilities`
        WHERE `grade_id` = ? AND `capability_pattern` = ? FOR UPDATE]],
        { sourceId, rule.capability })
    return stored ~= nil and tx.affected([[INSERT INTO `synex_group_grade_capability_scopes`
        (`grade_capability_id`, `scope_kind`, `scope_ref`, `version`)
        VALUES (?, ?, ?, 1)]], { stored and stored.id, scopeKind, scopeRef }) == 1
end

local function updateRule(tx, sourceKind, row, rule)
    if sourceKind == 'group' then
        return tx.affected([[UPDATE `synex_group_default_capabilities`
            SET `effect` = ?, `delegable` = ?, `version` = `version` + 1
            WHERE `id` = ? AND `version` = ?]],
            { rule.effect, rule.delegable and 1 or 0, row.id, row.version }) == 1
    end
    if sourceKind == 'role' then
        return tx.affected([[UPDATE `synex_group_role_capabilities`
            SET `effect` = ?, `delegable` = ?, `version` = `version` + 1
            WHERE `id` = ? AND `version` = ?]],
            { rule.effect, rule.delegable and 1 or 0, row.id, row.version }) == 1
    end
    local changed = tx.affected([[UPDATE `synex_group_grade_capabilities`
        SET `effect` = ?, `delegable` = ?, `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]],
        { rule.effect, rule.delegable and 1 or 0, row.id, row.version })
    if changed ~= 1 then return false end
    local scopeKind, scopeRef = storageScope(rule)
    return tx.affected([[UPDATE `synex_group_grade_capability_scopes`
        SET `scope_kind` = ?, `scope_ref` = ?, `version` = `version` + 1
        WHERE `grade_capability_id` = ? AND `version` = ?]],
        { scopeKind, scopeRef, row.id, row.scope_version }) == 1
end

local function reconcileSource(tx, item, state, sourceKind, sourceKey, sourceId)
    local live = state.capabilityRules[sourceKind][sourceKey] or {}
    for _, rule in ipairs(requestedRules(item, sourceKind, sourceKey)) do
        local row = live[requestedKey(sourceKind, rule)]
        local changed = row and (row.effect ~= rule.effect
            or (tonumber(row.delegable) == 1) ~= rule.delegable)
        local ok = true
        if row == nil then
            ok = sourceId ~= nil and insertRule(tx, sourceKind, sourceId, rule)
        elseif changed then
            ok = updateRule(tx, sourceKind, row, rule)
        end
        if not ok then
            return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                'A static capability rule changed during reconciliation.', true, {
                    source_kind = sourceKind, source_key = sourceKey,
                    capability = rule.capability
                })
        end
    end
    return true, nil
end

local function reconcile(tx, item, state)
    local ok, reconcileError = reconcileSource(
        tx, item, state, 'group', item.key, item.targetGroupId)
    if not ok then return nil, reconcileError end
    for _, grade in ipairs(item.group.grades) do
        local source = state.grades[grade.key]
        ok, reconcileError = reconcileSource(
            tx, item, state, 'grade', grade.key, source and source.id)
        if not ok then return nil, reconcileError end
    end
    for _, role in ipairs(item.group.roles) do
        local source = state.roles[role.key]
        ok, reconcileError = reconcileSource(
            tx, item, state, 'role', role.key, source and source.id)
        if not ok then return nil, reconcileError end
    end
    return true, nil
end

return { normalize = normalizeRules, inspect = inspect, reconcile = reconcile }
end
