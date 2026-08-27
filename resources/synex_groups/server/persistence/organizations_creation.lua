return function(Foundation)
local Shared = require('server.persistence.organizations_shared')(Foundation)
local Lifecycle = require 'server.domain.lifecycle'
local GROUP_VISIBILITY = Shared.GROUP_VISIBILITY
local MAXIMUM_HIERARCHY_DEPTH = Shared.MAXIMUM_HIERARCHY_DEPTH
local rejected = Shared.rejected
local affectedRows = Shared.affectedRows
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local authorize = Shared.authorize
local encodeMetadata = Shared.encodeMetadata
local loadGroupForUpdate = Shared.loadGroupForUpdate
local reserveSlug = Shared.reserveSlug
local requireSlugReservation = Shared.requireSlugReservation
local transferSlugReservation = Shared.transferSlugReservation
local releaseSlugReservation = Shared.releaseSlugReservation
local bumpReadModel = Shared.bumpReadModel
local mutationResult = Shared.mutationResult
local execute = {}

function execute.create(tx, request, runtime, context)
    local groupType = tx.one([[SELECT `id`, `type_key`, `creation_mode`, `dynamic_creation`,
            `create_permission`, `membership_limit`, `active_membership_limit`,
            `required_approvals`, `approval_permission`, `schema_version`,
            `hierarchy_enabled`, `status`, `version`
        FROM `synex_group_types` WHERE `type_key` = ? FOR UPDATE]], { request.type })
    if not groupType then
        return rejected('GROUP_TYPE_NOT_FOUND', 'The requested organization type does not exist.')
    end
    if groupType.status ~= 'active' then
        return rejected('GROUP_TYPE_INACTIVE', 'The requested organization type is not active.')
    end
    local dynamic = request.dynamic ~= false
    if not dynamic then
        return rejected('STATIC_DEFINITION_REQUIRED',
            'Static organizations must be reconciled through definitions.sync.')
    end
    if dynamic and tonumber(groupType.dynamic_creation) ~= 1 then
        return rejected('GROUP_TYPE_STATIC',
            'This organization type does not permit dynamic creation.')
    end
    if type(runtime.checkCorePermission) ~= 'function' then
        return rejected('CORE_UNAVAILABLE',
            'The Core character permission boundary is unavailable.', true)
    end
    if type(groupType.create_permission) ~= 'string'
        or #groupType.create_permission < 22 or #groupType.create_permission > 96
        or groupType.create_permission:sub(1, 20) ~= 'synex.groups.create.'
        or groupType.create_permission:match('^[a-z][a-z0-9_.%-]*$') == nil
        or groupType.create_permission:find('..', 1, true)
        or groupType.create_permission:sub(-1) == '.'
        or groupType.create_permission == 'synex.groups.create.migration_pending' then
        return rejected('DATABASE_RESULT_INVALID',
            'The organization type create authority is invalid.', true)
    end
    local requiredApprovals = tonumber(groupType.required_approvals) or 0
    local approvalPermission = groupType.approval_permission
        or 'synex.groups.create.approve.' .. request.type
    local typeSchemaVersion = tonumber(groupType.schema_version) or 1
    local typeVersion = tonumber(groupType.version)
    if math.type(requiredApprovals) ~= 'integer' or requiredApprovals < 0
        or requiredApprovals > 32 or math.type(typeSchemaVersion) ~= 'integer'
        or typeSchemaVersion < 1 or not typeVersion
        or math.type(typeVersion) ~= 'integer' or typeVersion < 1
        or type(approvalPermission) ~= 'string' or #approvalPermission < 30
        or #approvalPermission > 96
        or approvalPermission:sub(1, 28) ~= 'synex.groups.create.approve.'
        or approvalPermission:match('^[a-z][a-z0-9_.%-]*$') == nil
        or approvalPermission:find('..', 1, true)
        or approvalPermission:sub(-1) == '.' then
        return rejected('DATABASE_RESULT_INVALID',
            'The organization type creation approval policy is invalid.', true)
    end
    local approvedCreation = type(context) == 'table'
        and type(context.approvedCreation) == 'table'
        and context.approvedCreation or nil
    if approvedCreation then
        if requiredApprovals < 1 or approvedCreation.permissionsRevalidated ~= true
            or approvedCreation.creationRequestId == nil
            or tonumber(approvedCreation.groupTypeId) ~= tonumber(groupType.id)
            or tonumber(approvedCreation.typeSchemaVersion) ~= typeSchemaVersion
            or tonumber(approvedCreation.typeVersion) ~= typeVersion
            or approvedCreation.creatorPermission ~= groupType.create_permission
            or tonumber(approvedCreation.requiredApprovals) ~= requiredApprovals
            or approvedCreation.approvalPermission ~= approvalPermission then
            return rejected('CREATION_POLICY_CHANGED',
                'The approved organization request no longer matches its type policy.')
        end
    end
    local permissionError
    if not approvedCreation then
        local permitted
        permitted, permissionError = runtime.checkCorePermission(
            request.actor_character_id, groupType.create_permission)
        if not permitted then
            return nil, permissionError or Foundation.domainError(
                'INSUFFICIENT_PERMISSION',
                'The actor character may not create this organization type.'), nil
        end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local pendingRequestJson
    if requiredApprovals > 0 and not approvedCreation then
        pendingRequestJson, permissionError = encodeMetadata(runtime, request)
        if not pendingRequestJson then return nil, permissionError, nil end
        local replay = tx.one([[SELECT `public_id`, `request_json`, `status`, `version`
            FROM `synex_group_creation_requests`
            WHERE `requested_by_ref` = ? AND `idempotency_key` = ? FOR UPDATE]], {
            request.actor_character_id, request.idempotency_key
        })
        if replay then
            if replay.request_json ~= pendingRequestJson then
                return rejected('IDEMPOTENCY_CONFLICT',
                    'The organization creation key was already used for another request.')
            end
            return {
                entity_id = replay.public_id,
                entity_type = 'group_creation_request',
                status = replay.status,
                version = tonumber(replay.version),
                replayed = true
            }, nil, {}
        end
    end
    if not tx.one([[SELECT `state_key` FROM `synex_group_type_membership_states`
        WHERE `group_type_id` = ? AND `state_key` = 'ACTIVE' FOR UPDATE]], { groupType.id }) then
        return rejected('INVALID_TRANSITION',
            'This organization type does not permit an active founding membership.')
    end
    local membershipLimit = tonumber(groupType.membership_limit)
    if membershipLimit and membershipLimit < 1 then
        return rejected('MEMBER_LIMIT_REACHED',
            'The organization type cannot accept its founding member.')
    end
    local activeMembershipLimit = tonumber(groupType.active_membership_limit)
    if activeMembershipLimit and activeMembershipLimit < 1 then
        return rejected('MEMBER_LIMIT_REACHED',
            'The organization type cannot activate its founding member.')
    end
    local visibility = request.visibility or 'internal'
    if not GROUP_VISIBILITY[visibility] then
        return rejected('VALIDATION_FAILED', 'The requested organization visibility is invalid.')
    end
    if tx.one('SELECT `id` FROM `synex_groups` WHERE `group_key` = ? FOR UPDATE',
        { request.slug }) then
        return rejected('GROUP_EXISTS', 'An organization already uses this slug.')
    end
    local activeCreation = tx.one([[SELECT `public_id`
        FROM `synex_group_creation_requests` WHERE `active_slug` = ? FOR UPDATE]],
        { request.slug })
    if activeCreation and (not approvedCreation
        or activeCreation.public_id ~= approvedCreation.creationRequestId) then
        return rejected('GROUP_EXISTS',
            'An active organization creation request already reserves this slug.')
    end
    local approvedSlugReservation
    if approvedCreation then
        approvedSlugReservation, permissionError = requireSlugReservation(
            tx, request.slug, 'creation_request', approvedCreation.creationRequestId)
        if not approvedSlugReservation then return nil, permissionError, nil end
    end
    local lifecycleState = request.status and request.status:upper() or 'ACTIVE'
    if lifecycleState ~= 'DRAFT' and lifecycleState ~= 'ACTIVE' then
        return rejected('INVALID_TRANSITION',
            'An organization can only be created as draft or active.')
    end
    local storedStatus = lifecycleState == 'ACTIVE' and 'active' or 'suspended'

    local parent
    local parentAncestors
    if request.parent_group_id ~= nil then
        if tonumber(groupType.hierarchy_enabled) ~= 1 then
            return rejected('HIERARCHY_DISABLED',
                'The organization type does not permit a parent organization.')
        end
        parent = tx.one([[SELECT `group_record`.`id`, `group_record`.`public_id`,
                `group_record`.`status`, `profile`.`lifecycle_state`
            FROM `synex_groups` AS `group_record`
            INNER JOIN `synex_group_organization_profiles` AS `profile`
                ON `profile`.`group_id` = `group_record`.`id`
            WHERE `group_record`.`public_id` = ? FOR UPDATE]], { request.parent_group_id })
        if not parent then
            return rejected('PARENT_GROUP_NOT_FOUND', 'The parent organization does not exist.')
        end
        if parent.status ~= 'active' or parent.lifecycle_state ~= 'ACTIVE' then
            return rejected('PARENT_GROUP_INACTIVE', 'The parent organization is not active.')
        end
        parentAncestors = tx.many([[SELECT `ancestor_group_id`, `depth`
            FROM `synex_group_hierarchy_closure`
            WHERE `descendant_group_id` = ? ORDER BY `depth` ASC FOR UPDATE]], { parent.id })
        if type(parentAncestors) ~= 'table' or #parentAncestors == 0 then
            return rejected('HIERARCHY_INVALID',
                'The parent organization hierarchy is incomplete.')
        end
        local maximumDepth = 0
        for _, ancestor in ipairs(parentAncestors) do
            maximumDepth = math.max(maximumDepth, tonumber(ancestor.depth) or MAXIMUM_HIERARCHY_DEPTH)
        end
        if maximumDepth + 1 > MAXIMUM_HIERARCHY_DEPTH then
            return rejected('HIERARCHY_DEPTH_EXCEEDED',
                'The organization hierarchy exceeds its supported depth.')
        end
    end

    local defaultGrades = tx.many([[SELECT `grade_key`, `display_name`, `rank_value`,
            `member_limit`, `sort_order`
        FROM `synex_group_type_default_grades` WHERE `group_type_id` = ?
        ORDER BY `sort_order` ASC LIMIT 33 FOR UPDATE]], { groupType.id })
    local defaultRoles = tx.many([[SELECT `role_key`, `display_name`, `description`,
            `assignable`, `exclusive`, `holder_limit`, `sort_order`
        FROM `synex_group_type_default_roles` WHERE `group_type_id` = ?
        ORDER BY `sort_order` ASC LIMIT 33 FOR UPDATE]], { groupType.id })
    if type(defaultGrades) ~= 'table' or #defaultGrades > 32
        or type(defaultRoles) ~= 'table' or #defaultRoles > 32 then
        return rejected('DATABASE_RESULT_INVALID',
            'The organization type creation presets exceed supported bounds.', true)
    end
    for _, preset in ipairs(defaultGrades) do
        if preset.grade_key == 'owner' or tonumber(preset.rank_value) == 32767 then
            return rejected('DATABASE_RESULT_INVALID',
                'A default grade conflicts with the reserved owner recovery grade.', true)
        end
    end
    if requiredApprovals > 0 and not approvedCreation then
        local creationRequestId, creationRequestError = checkedId(
            runtime, 'groups_creation')
        if not creationRequestId then return nil, creationRequestError, nil end
        local reason, reasonError = checkedReason(
            runtime, nil, 'group_creation_requested')
        if not reason then return nil, reasonError, nil end
        local reservation, reservationError = reserveSlug(
            tx, request.slug, 'creation_request', creationRequestId)
        if not reservation then return nil, reservationError, nil end
        local inserted = tx.query([[INSERT INTO `synex_group_creation_requests`
            (`public_id`, `group_type_id`, `requested_by_ref`, `idempotency_key`,
             `requested_slug`, `request_json`, `required_approvals`, `approval_count`,
             `creator_permission`, `approval_permission`, `type_schema_version`,
             `type_version`, `status`, `expires_at`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 'pending',
                TIMESTAMPADD(HOUR, 48, CURRENT_TIMESTAMP(6)), 1)]], {
            creationRequestId, groupType.id, request.actor_character_id,
            request.idempotency_key, request.slug, pendingRequestJson,
            requiredApprovals, groupType.create_permission, approvalPermission,
            typeSchemaVersion, typeVersion
        })
        if affectedRows(inserted) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The organization creation request could not be persisted.', true)
        end
        local after = {
            creation_request_id = creationRequestId,
            requested_by_character_id = request.actor_character_id,
            group_type = request.type,
            slug = request.slug,
            status = 'pending',
            required_approvals = requiredApprovals,
            approval_count = 0,
            version = 1
        }
        local effect = runtime.effect('group.creation_requested',
            'group_creation_request', creationRequestId, nil,
            request.actor_character_id, nil, after, reason, 1)
        return {
            entity_id = creationRequestId,
            entity_type = 'group_creation_request',
            status = 'pending',
            version = 1,
            replayed = false
        }, nil, { effect }
    end
    for _, preset in ipairs(defaultGrades) do
        local presetId, presetIdError = checkedId(runtime, 'groups_grade')
        if not presetId then return nil, presetIdError, nil end
        preset.publicId = presetId
    end
    for _, preset in ipairs(defaultRoles) do
        local presetId, presetIdError = checkedId(runtime, 'groups_role')
        if not presetId then return nil, presetIdError, nil end
        preset.publicId = presetId
    end

    local groupId, groupIdError = checkedId(runtime, 'groups_group')
    if not groupId then return nil, groupIdError, nil end
    if not approvedCreation then
        local reservation, reservationError = reserveSlug(
            tx, request.slug, 'group', groupId)
        if not reservation then return nil, reservationError, nil end
    end
    local gradeId, gradeIdError = checkedId(runtime, 'groups_grade')
    if not gradeId then return nil, gradeIdError, nil end
    local membershipId, membershipIdError = checkedId(runtime, 'groups_member')
    if not membershipId then return nil, membershipIdError, nil end
    local membershipEventId, membershipEventError = checkedId(runtime, 'groups_event')
    if not membershipEventId then return nil, membershipEventError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'group_created')
    if not reason then return nil, reasonError, nil end
    local metadataJson, metadataError = encodeMetadata(runtime, request.metadata or {})
    if not metadataJson then return nil, metadataError, nil end

    local inserted = tx.query([[INSERT INTO `synex_groups`
        (`public_id`, `group_key`, `display_name`, `group_type`, `status`,
         `created_by_ref`, `metadata_json`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)]], {
        groupId, request.slug, request.label, request.type,
        storedStatus, request.actor_character_id, metadataJson
    })
    if affectedRows(inserted) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization could not be created.', true)
    end
    local storedGroup = tx.one('SELECT `id` FROM `synex_groups` WHERE `public_id` = ? FOR UPDATE',
        { groupId })
    if not storedGroup then
        return rejected('DATABASE_RESULT_INVALID',
            'The created organization could not be resolved.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_organization_profiles`
        (`group_id`, `group_type_id`, `slug`, `name`, `label`, `description`,
         `dynamic`, `metadata_json`, `visibility`, `creation_source`,
         `lifecycle_state`, `lifecycle_reason_code`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
        storedGroup.id, groupType.id, request.slug, request.name, request.label,
        request.description, dynamic and 1 or 0, metadataJson, visibility,
        dynamic and 'dynamic' or 'static', lifecycleState, reason
    })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization profile could not be created.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_hierarchy_closure`
        (`ancestor_group_id`, `descendant_group_id`, `depth`) VALUES (?, ?, 0)]],
        { storedGroup.id, storedGroup.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization hierarchy could not be initialized.', true)
    end
    if parent then
        if affectedRows(tx.query([[INSERT INTO `synex_group_hierarchy_edges`
            (`child_group_id`, `parent_group_id`, `created_by_ref`, `reason_code`, `version`)
            VALUES (?, ?, ?, ?, 1)]], {
            storedGroup.id, parent.id, request.actor_character_id, reason
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION', 'The parent organization could not be assigned.', true)
        end
        local closureInsert = tx.query([[INSERT INTO `synex_group_hierarchy_closure`
            (`ancestor_group_id`, `descendant_group_id`, `depth`)
            SELECT `ancestor_group_id`, ?, `depth` + 1
            FROM `synex_group_hierarchy_closure` WHERE `descendant_group_id` = ?]],
            { storedGroup.id, parent.id })
        if affectedRows(closureInsert) ~= #parentAncestors then
            return rejected('CONCURRENT_MODIFICATION',
                'The parent organization closure could not be established.', true)
        end
    end

    if affectedRows(tx.query([[INSERT INTO `synex_group_grades`
        (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
        VALUES (?, ?, 'owner', 'Owner', 32767, 'active', 1)]],
        { gradeId, storedGroup.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding owner grade could not be created.', true)
    end
    local ownerGrade = tx.one('SELECT `id` FROM `synex_group_grades` WHERE `public_id` = ? FOR UPDATE',
        { gradeId })
    if not ownerGrade then
        return rejected('DATABASE_RESULT_INVALID', 'The founding owner grade could not be resolved.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_grade_controls`
        (`grade_id`, `member_limit`, `promotion_requires_approval`, `version`)
        VALUES (?, 1, 0, 1)]], { ownerGrade.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding owner controls could not be created.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_grade_capabilities`
        (`grade_id`, `capability_pattern`, `effect`, `version`)
        VALUES (?, 'synex.groups.*', 'allow', 1)]], { ownerGrade.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding owner capability could not be created.', true)
    end
    local ownerCapability = tx.one([[SELECT `id` FROM `synex_group_grade_capabilities`
        WHERE `grade_id` = ? AND `capability_pattern` = 'synex.groups.*' FOR UPDATE]],
        { ownerGrade.id })
    if not ownerCapability or affectedRows(tx.query([[INSERT INTO `synex_group_grade_capability_scopes`
        (`grade_capability_id`, `scope_kind`, `scope_ref`, `version`)
        VALUES (?, 'group', '', 1)]], { ownerCapability and ownerCapability.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding owner scope could not be created.', true)
    end

    for _, preset in ipairs(defaultGrades) do
        if affectedRows(tx.query([[INSERT INTO `synex_group_grades`
            (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`,
             `status`, `version`) VALUES (?, ?, ?, ?, ?, 'active', 1)]], {
            preset.publicId, storedGroup.id, preset.grade_key,
            preset.display_name, preset.rank_value
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A default organization grade could not be created.', true)
        end
        local storedPreset = tx.one([[SELECT `id` FROM `synex_group_grades`
            WHERE `public_id` = ? FOR UPDATE]], { preset.publicId })
        if not storedPreset or affectedRows(tx.query([[INSERT INTO `synex_group_grade_controls`
            (`grade_id`, `member_limit`, `promotion_requires_approval`, `version`)
            VALUES (?, ?, 0, 1)]], {
            storedPreset and storedPreset.id, preset.member_limit
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'Default organization grade controls could not be created.', true)
        end
    end
    for _, preset in ipairs(defaultRoles) do
        local roleStatus = tonumber(preset.assignable) == 0 and 'disabled' or 'active'
        local exclusivity = tonumber(preset.exclusive) == 1 and 'group' or 'none'
        if affectedRows(tx.query([[INSERT INTO `synex_group_roles`
            (`public_id`, `group_id`, `role_key`, `display_name`, `description`,
             `exclusivity`, `holder_limit`, `status`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
            preset.publicId, storedGroup.id, preset.role_key, preset.display_name,
            preset.description, exclusivity, preset.holder_limit, roleStatus
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A default organization role could not be created.', true)
        end
    end

    if affectedRows(tx.query([[INSERT INTO `synex_group_memberships`
        (`public_id`, `group_id`, `subject_kind`, `subject_ref`, `role_key`, `status`, `version`)
        VALUES (?, ?, 'character', ?, 'owner', 'active', 1)]],
        { membershipId, storedGroup.id, request.actor_character_id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding membership could not be created.', true)
    end
    local founderMembership = tx.one([[SELECT `id` FROM `synex_group_memberships`
        WHERE `public_id` = ? FOR UPDATE]], { membershipId })
    if not founderMembership then
        return rejected('DATABASE_RESULT_INVALID', 'The founding membership could not be resolved.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_membership_profiles`
        (`membership_id`, `group_id`, `character_id`, `lifecycle_state`, `visibility`,
         `joined_at`, `lifecycle_reason_code`, `version`)
        VALUES (?, ?, ?, 'ACTIVE', 'management', CURRENT_TIMESTAMP(6), ?, 1)]],
        { founderMembership.id, storedGroup.id, request.actor_character_id, reason })) ~= 1
        or affectedRows(tx.query([[INSERT INTO `synex_group_membership_grades`
            (`membership_id`, `grade_id`, `assigned_by_ref`, `version`)
            VALUES (?, ?, ?, 1)]],
            { founderMembership.id, ownerGrade.id, request.actor_character_id })) ~= 1
        or affectedRows(tx.query([[INSERT INTO `synex_group_reporting_closure`
            (`manager_membership_id`, `report_membership_id`, `depth`) VALUES (?, ?, 0)]],
            { founderMembership.id, founderMembership.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding membership state could not be initialized.', true)
    end
    if type(runtime.enforceMembershipActivation) ~= 'function' then
        return rejected('DATABASE_ERROR',
            'The founding membership attribute invariant is unavailable.', true)
    end
    local activationAllowed, activationError = runtime.enforceMembershipActivation(tx, {
        id = founderMembership.id,
        group_id = storedGroup.id,
        character_id = request.actor_character_id
    }, runtime)
    if not activationAllowed then return nil, activationError, nil end
    local membershipSnapshot, snapshotError = encodeMetadata(runtime, {
        membership_id = membershipId,
        group_id = groupId,
        character_id = request.actor_character_id,
        grade_id = gradeId,
        lifecycle_state = 'ACTIVE',
        version = 1
    })
    if not membershipSnapshot then return nil, snapshotError, nil end
    if affectedRows(tx.query([[INSERT INTO `synex_group_membership_events`
        (`event_id`, `membership_id`, `membership_version`, `event_type`, `actor_ref`, `snapshot_json`)
        VALUES (?, ?, 1, 'added', ?, ?)]], {
        membershipEventId, founderMembership.id, request.actor_character_id, membershipSnapshot
    })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The founding membership event could not be recorded.', true)
    end
    if affectedRows(tx.query([[INSERT INTO `synex_group_read_model_versions`
        (`group_id`, `model_version`, `invalidated_at`)
        VALUES (?, 1, CURRENT_TIMESTAMP(6))]], { storedGroup.id })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization read model could not be initialized.', true)
    end
    if approvedCreation then
        local transferred, transferError = transferSlugReservation(
            tx, request.slug, 'creation_request', approvedCreation.creationRequestId,
            'group', groupId, approvedSlugReservation.version)
        if not transferred then return nil, transferError, nil end
    end

    local after = {
        group_id = groupId, type = request.type, parent_group_id = request.parent_group_id,
        slug = request.slug, name = request.name, label = request.label,
        status = lifecycleState:lower(), visibility = visibility, dynamic = dynamic, version = 1,
        founder_membership_id = membershipId, owner_grade_id = gradeId,
        default_grade_count = #defaultGrades, default_role_count = #defaultRoles
    }
    local response = runtime.success(groupId, 'group', lifecycleState:lower(), 1)
    if type(response) ~= 'table' then
        return rejected('RUNTIME_RESULT_INVALID',
            'The organization runtime returned an invalid mutation result.', true)
    end
    local founder = {
        membership_id = membershipId,
        group_id = groupId,
        character_id = request.actor_character_id,
        lifecycle_state = 'ACTIVE',
        grade_id = gradeId,
        version = 1
    }
    return response, nil, {
        runtime.effect('group.created', 'group', groupId,
            groupId, request.actor_character_id, nil, after, reason, 1),
        runtime.effect('membership.activated', 'membership', membershipId,
            groupId, request.actor_character_id, nil, founder, reason, 1)
    }
end

return { execute = execute }
end
