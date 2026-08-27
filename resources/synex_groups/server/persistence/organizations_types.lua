return function(Foundation)
local domainError = Foundation.domainError
local Shared = require('server.persistence.organizations_shared')(Foundation)
local rejected = Shared.rejected
local affectedRows = Shared.affectedRows
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local decodeMetadata = Shared.decodeMetadata
local encodeMetadata = Shared.encodeMetadata
local mutationResult = Shared.mutationResult
local execute = {}

local function persistPresets(tx, groupTypeId, grades, roles)
    tx.query('DELETE FROM `synex_group_type_default_grades` WHERE `group_type_id` = ?',
        { groupTypeId })
    for index, preset in ipairs(grades) do
        if affectedRows(tx.query([[INSERT INTO `synex_group_type_default_grades`
            (`group_type_id`, `grade_key`, `display_name`, `rank_value`,
             `member_limit`, `sort_order`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, 1)]], {
            groupTypeId, preset.key, preset.label, preset.rank,
            preset.capacity, index - 1
        })) ~= 1 then
            return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                'A default grade preset could not be persisted.', true)
        end
    end
    tx.query('DELETE FROM `synex_group_type_default_roles` WHERE `group_type_id` = ?',
        { groupTypeId })
    for index, preset in ipairs(roles) do
        if affectedRows(tx.query([[INSERT INTO `synex_group_type_default_roles`
            (`group_type_id`, `role_key`, `display_name`, `description`, `assignable`,
             `exclusive`, `holder_limit`, `sort_order`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
            groupTypeId, preset.key, preset.label, preset.description,
            preset.assignable == false and 0 or 1,
            preset.exclusive == true and 1 or 0,
            preset.capacity, index - 1
        })) ~= 1 then
            return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                'A default role preset could not be persisted.', true)
        end
    end
    return true, nil
end

function execute.types_register(tx, request, runtime, context)
    local owner = type(context) == 'table' and context.caller or nil
    local epoch = type(context) == 'table' and context.callerEpoch or nil
    if type(owner) ~= 'string' or #owner < 3 or #owner > 64
        or owner:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') == nil
        or type(epoch) ~= 'number' or math.type(epoch) ~= 'integer' or epoch < 1 then
        return rejected('RESOURCE_OWNER_INVALID', 'The group type owner is invalid.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if not Foundation.isCallable(runtime.requireRegistryOwnerSession) then
        return rejected('DATABASE_ERROR',
            'The group type synchronization boundary is unavailable.', true)
    end
    local synchronized, synchronizationError = runtime.requireRegistryOwnerSession(
        tx, owner, epoch)
    if not synchronized then return nil, synchronizationError, nil end
    if type(runtime.deferRegistry) ~= 'function' then
        return rejected('DATABASE_ERROR',
            'The group type registry commit coordinator is unavailable.', true)
    end
    local requestedVersion = tonumber(request.schema_version)
    if not requestedVersion or math.type(requestedVersion) ~= 'integer'
        or requestedVersion < 1 or requestedVersion > 2147483647 then
        return rejected('VALIDATION_FAILED', 'schema_version is invalid.')
    end
    local creationMode = request.dynamic_creation == false and 'static' or 'dynamic'
    local dynamicCreation = request.dynamic_creation == false and 0 or 1
    local createPermission = request.create_permission
        or 'synex.groups.create.' .. request.type
    if type(createPermission) ~= 'string' or #createPermission < 22
        or #createPermission > 96
        or createPermission:sub(1, 20) ~= 'synex.groups.create.'
        or createPermission:match('^[a-z][a-z0-9_.%-]*$') == nil
        or createPermission:find('..', 1, true)
        or createPermission:sub(-1) == '.'
        or createPermission == 'synex.groups.create.migration_pending' then
        return rejected('VALIDATION_FAILED',
            'The group type create permission is invalid.')
    end
    local requiredApprovals = request.required_approvals == nil
        and 0 or tonumber(request.required_approvals)
    local approvalPermission = request.approval_permission
        or 'synex.groups.create.approve.' .. request.type
    if not requiredApprovals or math.type(requiredApprovals) ~= 'integer'
        or requiredApprovals < 0 or requiredApprovals > 32 then
        return rejected('VALIDATION_FAILED',
            'The group type required approval count is invalid.')
    end
    if type(approvalPermission) ~= 'string' or #approvalPermission < 30
        or #approvalPermission > 96
        or approvalPermission:sub(1, 28) ~= 'synex.groups.create.approve.'
        or approvalPermission:match('^[a-z][a-z0-9_.%-]*$') == nil
        or approvalPermission:find('..', 1, true)
        or approvalPermission:sub(-1) == '.' then
        return rejected('VALIDATION_FAILED',
            'The group type approval permission is invalid.')
    end
    if request.max_members ~= nil and request.max_active_members ~= nil
        and request.max_active_members > request.max_members then
        return rejected('VALIDATION_FAILED',
            'max_active_members cannot exceed max_members.')
    end
    local defaultGrades = request.default_grades or {}
    local defaultRoles = request.default_roles or {}
    if type(defaultGrades) ~= 'table' or #defaultGrades > 32
        or type(defaultRoles) ~= 'table' or #defaultRoles > 32 then
        return rejected('VALIDATION_FAILED',
            'Default grade and role presets exceed supported bounds.')
    end
    local metadataOk, metadata = pcall(Foundation.copyPlain, request.metadata or {}, {
        maximumDepth = 8,
        maximumKeys = 128,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not metadataOk then
        return rejected('VALIDATION_FAILED', 'The group type metadata is invalid.')
    end
    if metadata.application_schema ~= nil then
        local applicationSchema, schemaError = runtime.applicationSchemas.validateSchema(
            metadata.application_schema)
        if not applicationSchema then return nil, schemaError, nil end
        metadata.application_schema = applicationSchema
    end
    local metadataJson, metadataError = encodeMetadata(runtime, metadata)
    if not metadataJson then return nil, metadataError, nil end

    local function resolveStates(values, tableName, keyColumn, errorCode)
        local resolved = {}
        if values == nil then
            local rows = tx.many(([=[SELECT `%s` AS `state_key` FROM `%s`
                WHERE `status` = 'active' ORDER BY `%s` ASC LIMIT 17 FOR UPDATE]=]):format(
                keyColumn, tableName, keyColumn))
            if type(rows) ~= 'table' or #rows == 0 or #rows > 16 then
                return nil, domainError(errorCode,
                    'The active state registry cannot be used for this group type.')
            end
            for index, row in ipairs(rows) do resolved[index] = row.state_key end
            return resolved, nil
        end
        if type(values) ~= 'table' or #values < 1 or #values > 16 then
            return nil, domainError(errorCode,
                'The group type state list must contain between one and sixteen states.')
        end
        local seen = {}
        for index, state in ipairs(values) do
            if type(state) ~= 'string' or seen[state] then
                return nil, domainError(errorCode,
                    'The group type state list contains an invalid or duplicate state.')
            end
            seen[state] = true
            local row = tx.one(([=[SELECT `%s` AS `state_key` FROM `%s`
                WHERE `%s` = ? AND `status` = 'active' FOR UPDATE]=]):format(
                keyColumn, tableName, keyColumn), { state })
            if not row then
                return nil, domainError(errorCode,
                    'The group type references an unknown or inactive state.', false,
                    { state = state })
            end
            resolved[index] = state
        end
        return resolved, nil
    end

    local membershipStates, membershipStateError = resolveStates(
        request.allowed_membership_states, 'synex_group_membership_states',
        'state_key', 'VALIDATION_FAILED')
    if not membershipStates then return nil, membershipStateError, nil end
    local dutyStates, dutyStateError = resolveStates(
        request.allowed_duty_states, 'synex_group_duty_states',
        'state_key', 'VALIDATION_FAILED')
    if not dutyStates then return nil, dutyStateError, nil end

    local existing = tx.one([[SELECT `id`, `public_id`, `owner_resource`, `owner_epoch`, `display_name`,
            `creation_mode`, `dynamic_creation`, `create_permission`,
            `required_approvals`, `approval_permission`,
            `membership_limit`, `active_membership_limit`, `schema_version`,
            `metadata_json`, `status`, `version`
        FROM `synex_group_types` WHERE `type_key` = ? FOR UPDATE]], { request.type })
    if existing then
        if existing.owner_resource ~= owner then
            return rejected('TYPE_OWNER_CONFLICT',
                'The group type is owned by another resource.')
        end
        local currentVersion = tonumber(existing.version)
        local currentSchemaVersion = tonumber(existing.schema_version)
        local currentEpoch = tonumber(existing.owner_epoch)
        if not currentVersion or not currentSchemaVersion or not currentEpoch then
            return rejected('DATABASE_RESULT_INVALID', 'The stored group type version is invalid.')
        end
        local storedMetadata, storedMetadataError = decodeMetadata(runtime, existing.metadata_json)
        if not storedMetadata then return nil, storedMetadataError, nil end
        local storedMetadataJson, storedMetadataEncodeError = encodeMetadata(runtime, storedMetadata)
        if not storedMetadataJson then return nil, storedMetadataEncodeError, nil end
        local storedMembershipStates = tx.many([[SELECT `state_key`
            FROM `synex_group_type_membership_states` WHERE `group_type_id` = ?
            ORDER BY `sort_order` ASC FOR UPDATE]], { existing.id })
        local storedDutyStates = tx.many([[SELECT `state_key`
            FROM `synex_group_type_duty_states` WHERE `group_type_id` = ?
            ORDER BY `state_key` ASC FOR UPDATE]], { existing.id })
        local storedDefaultGrades = tx.many([[SELECT `grade_key`, `display_name`,
                `rank_value`, `member_limit`, `sort_order`
            FROM `synex_group_type_default_grades` WHERE `group_type_id` = ?
            ORDER BY `sort_order` ASC FOR UPDATE]], { existing.id })
        local storedDefaultRoles = tx.many([[SELECT `role_key`, `display_name`,
                `description`, `assignable`, `exclusive`, `holder_limit`, `sort_order`
            FROM `synex_group_type_default_roles` WHERE `group_type_id` = ?
            ORDER BY `sort_order` ASC FOR UPDATE]], { existing.id })
        local sameMembershipStates = #storedMembershipStates == #membershipStates
        if sameMembershipStates then
            for index, state in ipairs(membershipStates) do
                if storedMembershipStates[index].state_key ~= state then
                    sameMembershipStates = false
                    break
                end
            end
        end
        local sortedDutyStates = {}
        for index, state in ipairs(dutyStates) do sortedDutyStates[index] = state end
        table.sort(sortedDutyStates)
        local sameDutyStates = #storedDutyStates == #sortedDutyStates
        if sameDutyStates then
            for index, state in ipairs(sortedDutyStates) do
                if storedDutyStates[index].state_key ~= state then
                    sameDutyStates = false
                    break
                end
            end
        end
        local sameDefaultGrades = #storedDefaultGrades == #defaultGrades
        if sameDefaultGrades then
            for index, preset in ipairs(defaultGrades) do
                local stored = storedDefaultGrades[index]
                if stored.grade_key ~= preset.key or stored.display_name ~= preset.label
                    or tonumber(stored.rank_value) ~= preset.rank
                    or tonumber(stored.member_limit) ~= tonumber(preset.capacity)
                    or tonumber(stored.sort_order) ~= index - 1 then
                    sameDefaultGrades = false
                    break
                end
            end
        end
        local sameDefaultRoles = #storedDefaultRoles == #defaultRoles
        if sameDefaultRoles then
            for index, preset in ipairs(defaultRoles) do
                local stored = storedDefaultRoles[index]
                if stored.role_key ~= preset.key or stored.display_name ~= preset.label
                    or stored.description ~= preset.description
                    or tonumber(stored.assignable) ~= (preset.assignable == false and 0 or 1)
                    or tonumber(stored.exclusive) ~= (preset.exclusive == true and 1 or 0)
                    or tonumber(stored.holder_limit) ~= tonumber(preset.capacity)
                    or tonumber(stored.sort_order) ~= index - 1 then
                    sameDefaultRoles = false
                    break
                end
            end
        end
        local same = existing.display_name == request.label
            and existing.creation_mode == creationMode
            and tonumber(existing.dynamic_creation) == dynamicCreation
            and existing.create_permission == createPermission
            and tonumber(existing.required_approvals) == requiredApprovals
            and existing.approval_permission == approvalPermission
            and tonumber(existing.membership_limit) == tonumber(request.max_members)
            and tonumber(existing.active_membership_limit)
                == tonumber(request.max_active_members)
            and storedMetadataJson == metadataJson
            and sameMembershipStates and sameDutyStates
            and sameDefaultGrades and sameDefaultRoles
        if requestedVersion == currentSchemaVersion and same then
            local version = currentVersion
            local effect
            if currentEpoch ~= epoch or existing.status ~= 'active' then
                if affectedRows(tx.query([[UPDATE `synex_group_types`
                        SET `owner_epoch` = ?, `status` = 'active', `version` = `version` + 1
                        WHERE `id` = ? AND `version` = ?]], {
                    epoch, existing.id, currentVersion
                })) ~= 1 then
                    return rejected('CONCURRENT_MODIFICATION',
                        'The group type owner epoch changed during registration.', true)
                end
                version = currentVersion + 1
                local reason, reasonError = checkedReason(runtime, nil, 'group_type_registered')
                if not reason then return nil, reasonError, nil end
                effect = runtime.effect('type.registered', 'group_type',
                    existing.public_id, nil, nil,
                    { schema_version = currentSchemaVersion, owner_epoch = currentEpoch,
                        status = existing.status, version = currentVersion },
                    { type = request.type, schema_version = requestedVersion,
                        owner_epoch = epoch, status = 'active', version = version },
                    reason, version)
            end
            local deferred, deferError = runtime.deferRegistry(context, 'groupTypes',
                owner, epoch, synchronized.generation, 'group_type:' .. request.type, {
                    publicId = existing.public_id, key = request.type, label = request.label,
                    schemaVersion = requestedVersion, maxMembers = request.max_members,
                    maxActiveMembers = request.max_active_members,
                    createPermission = createPermission,
                    requiredApprovals = requiredApprovals,
                    approvalPermission = approvalPermission,
                    version = version
                })
            if not deferred then return nil, deferError, nil end
            return mutationResult(runtime, existing.public_id, 'group_type', 'active',
                version, effect)
        end
        if requestedVersion <= currentSchemaVersion then
            return rejected('CONCURRENT_MODIFICATION', 'The group type schema version did not advance.', true,
                { expected_minimum = currentSchemaVersion + 1, actual = requestedVersion })
        end
        local updated = tx.query([[UPDATE `synex_group_types`
            SET `display_name` = ?, `creation_mode` = ?, `dynamic_creation` = ?,
                `create_permission` = ?, `required_approvals` = ?,
                `approval_permission` = ?, `membership_limit` = ?,
                `active_membership_limit` = ?, `schema_version` = ?, `metadata_json` = ?,
                `owner_epoch` = ?, `status` = 'active', `version` = `version` + 1
            WHERE `id` = ? AND `version` = ?]], {
            request.label, creationMode, dynamicCreation, createPermission,
            requiredApprovals, approvalPermission,
            request.max_members, request.max_active_members,
            requestedVersion, metadataJson, epoch, existing.id, currentVersion
        })
        if affectedRows(updated) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION', 'The group type changed during registration.', true)
        end
        tx.query('DELETE FROM `synex_group_type_membership_states` WHERE `group_type_id` = ?',
            { existing.id })
        for index, state in ipairs(membershipStates) do
            if affectedRows(tx.query([[INSERT INTO `synex_group_type_membership_states`
                (`group_type_id`, `state_key`, `sort_order`) VALUES (?, ?, ?)]],
                { existing.id, state, index - 1 })) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The group type membership states could not be replaced.', true)
            end
        end
        tx.query('DELETE FROM `synex_group_type_duty_states` WHERE `group_type_id` = ?',
            { existing.id })
        for _, state in ipairs(dutyStates) do
            if affectedRows(tx.query([[INSERT INTO `synex_group_type_duty_states`
                (`group_type_id`, `state_key`) VALUES (?, ?)]],
                { existing.id, state })) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The group type duty states could not be replaced.', true)
            end
        end
        local presetsPersisted, presetError = persistPresets(
            tx, existing.id, defaultGrades, defaultRoles)
        if not presetsPersisted then return nil, presetError, nil end
        local deferred, deferError = runtime.deferRegistry(context, 'groupTypes',
            owner, epoch, synchronized.generation, 'group_type:' .. request.type, {
                publicId = existing.public_id, key = request.type, label = request.label,
                schemaVersion = requestedVersion, maxMembers = request.max_members,
                maxActiveMembers = request.max_active_members,
                createPermission = createPermission,
                requiredApprovals = requiredApprovals,
                approvalPermission = approvalPermission,
                version = currentVersion + 1
            })
        if not deferred then return nil, deferError, nil end
        local reason, reasonError = checkedReason(runtime, nil, 'group_type_registered')
        if not reason then return nil, reasonError, nil end
        local effect = runtime.effect('type.registered', 'group_type',
            existing.public_id, nil, nil,
            { schema_version = currentSchemaVersion, version = currentVersion },
            { type = request.type, schema_version = requestedVersion,
                version = currentVersion + 1 }, reason)
        return mutationResult(runtime, existing.public_id, 'group_type', 'active',
            currentVersion + 1, effect)
    end

    local typeId, typeIdError = checkedId(runtime, 'groups_type')
    if not typeId then return nil, typeIdError, nil end
    local inserted = tx.query([[INSERT INTO `synex_group_types`
        (`public_id`, `type_key`, `owner_resource`, `owner_epoch`, `display_name`,
         `creation_mode`, `dynamic_creation`, `create_permission`, `primary_policy`,
         `required_approvals`, `approval_permission`,
         `membership_limit`, `active_membership_limit`, `schema_version`,
         `metadata_json`, `hierarchy_enabled`, `relationships_enabled`, `status`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'optional', ?, ?, ?, ?, ?, ?, 1, 1, 'active', 1)]], {
        typeId, request.type, owner, epoch, request.label, creationMode,
        dynamicCreation, createPermission, requiredApprovals, approvalPermission,
        request.max_members,
        request.max_active_members, requestedVersion, metadataJson
    })
    if affectedRows(inserted) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The group type could not be registered.', true)
    end
    local storedType = tx.one('SELECT `id` FROM `synex_group_types` WHERE `public_id` = ? FOR UPDATE',
        { typeId })
    if not storedType then
        return rejected('DATABASE_RESULT_INVALID', 'The registered group type could not be resolved.', true)
    end
    for index, state in ipairs(membershipStates) do
        if affectedRows(tx.query([[INSERT INTO `synex_group_type_membership_states`
            (`group_type_id`, `state_key`, `sort_order`) VALUES (?, ?, ?)]],
            { storedType.id, state, index - 1 })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The group type membership states could not be created.', true)
        end
    end
    for _, state in ipairs(dutyStates) do
        if affectedRows(tx.query([[INSERT INTO `synex_group_type_duty_states`
            (`group_type_id`, `state_key`) VALUES (?, ?)]],
            { storedType.id, state })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The group type duty states could not be created.', true)
        end
    end
    local presetsPersisted, presetError = persistPresets(
        tx, storedType.id, defaultGrades, defaultRoles)
    if not presetsPersisted then return nil, presetError, nil end
    local deferred, deferError = runtime.deferRegistry(context, 'groupTypes',
        owner, epoch, synchronized.generation, 'group_type:' .. request.type, {
            publicId = typeId, key = request.type, label = request.label,
            schemaVersion = requestedVersion, maxMembers = request.max_members,
            maxActiveMembers = request.max_active_members,
            createPermission = createPermission,
            requiredApprovals = requiredApprovals,
            approvalPermission = approvalPermission,
            version = 1
        })
    if not deferred then return nil, deferError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'group_type_registered')
    if not reason then return nil, reasonError, nil end
    local effect = runtime.effect('type.registered', 'group_type', typeId,
        nil, nil, nil, { type = request.type, schema_version = requestedVersion,
            version = 1 }, reason)
    return mutationResult(runtime, typeId, 'group_type', 'active', 1, effect)
end

return { execute = execute }
end
