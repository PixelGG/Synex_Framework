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

function execute.update(tx, request, runtime, context)
    local group, groupError = loadGroupForUpdate(tx, request.group_id)
    if not group then return nil, groupError, nil end
    local currentLifecycle = type(group.lifecycle_state) == 'string'
        and group.lifecycle_state:lower() or nil
    if currentLifecycle == 'draft' or currentLifecycle == 'suspended' then
        if type(runtime.checkCorePermission) ~= 'function' then
            return rejected('CORE_UNAVAILABLE',
                'The Core character permission boundary is unavailable.', true)
        end
        local permitted, permissionError = runtime.checkCorePermission(
            request.actor_character_id, 'synex.groups.update')
        if not permitted then
            return nil, permissionError or Foundation.domainError(
                'INSUFFICIENT_PERMISSION',
                'Activating a draft or suspended organization requires Core authority.'), nil
        end
    else
        local allowed, authorizationError = authorize(runtime, tx, request.group_id,
            request.actor_character_id, 'synex.groups.update',
            { kind = 'group', group_id = request.group_id })
        if not allowed then return nil, authorizationError, nil end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if currentLifecycle == 'archived' or currentLifecycle == 'dissolving'
        or currentLifecycle == 'deleted' then
        return rejected('GROUP_INACTIVE',
            'An archived, dissolving, or deleted organization cannot be updated.')
    end
    if group.version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION', 'The organization version has changed.', true,
            { expected = request.expected_version, actual = group.version })
    end
    local expectedStoredStatus = currentLifecycle == 'active' and 'active'
        or (currentLifecycle == 'draft' or currentLifecycle == 'suspended') and 'suspended'
        or nil
    if expectedStoredStatus == nil or group.status ~= expectedStoredStatus then
        return rejected('DATABASE_RESULT_INVALID',
            'The organization lifecycle state is inconsistent.', true)
    end
    local targetStatus = request.status and request.status:lower() or nil
    local transition
    if targetStatus ~= nil then
        local transitionError
        transition, transitionError = Lifecycle.transition(
            'group', currentLifecycle, targetStatus)
        if not transition then
            return rejected('INVALID_TRANSITION', transitionError.message, false,
                transitionError.details)
        end
        if targetStatus == 'archived' then
            return rejected('INVALID_TRANSITION',
                'Archive organizations through synex.groups.archive.')
        end
    end
    if (currentLifecycle == 'draft' or currentLifecycle == 'suspended')
        and targetStatus ~= 'active' then
        return rejected('GROUP_INACTIVE',
            'A draft or suspended organization can only be activated.')
    end
    if request.visibility ~= nil and not GROUP_VISIBILITY[request.visibility] then
        return rejected('VALIDATION_FAILED', 'The requested organization visibility is invalid.')
    end
    local hasChange = request.slug ~= nil or request.name ~= nil or request.label ~= nil
        or request.description ~= nil or request.visibility ~= nil
        or request.parent_group_id ~= nil or targetStatus ~= nil
    if not hasChange then
        return rejected('VALIDATION_FAILED', 'The organization update contains no mutable property.')
    end
    local releasePreviousSlug = false
    if request.slug ~= nil then
        if request.slug ~= group.slug then
            local reserved, reservationError = reserveSlug(
                tx, request.slug, 'group', group.group_public_id)
            if not reserved then return nil, reservationError, nil end
            releasePreviousSlug = true
        end
        local currentReservation, currentReservationError = requireSlugReservation(
            tx, group.slug, 'group', group.group_public_id)
        if not currentReservation then return nil, currentReservationError, nil end
    end

    local action = targetStatus == 'suspended' and 'group.suspended'
        or targetStatus == 'active' and currentLifecycle == 'draft' and 'group.activated'
        or targetStatus == 'active' and 'group.resumed' or 'group.updated'
    local reason, reasonError = checkedReason(runtime, request.reason,
        action:gsub('%.', '_'))
    if not reason then return nil, reasonError, nil end

    local previousParent = tx.one([[SELECT `parent`.`public_id` AS `public_id`
        FROM `synex_group_hierarchy_edges` AS `edge`
        INNER JOIN `synex_groups` AS `parent` ON `parent`.`id` = `edge`.`parent_group_id`
        WHERE `edge`.`child_group_id` = ? FOR UPDATE]], { group.id })
    if request.parent_group_id ~= nil then
        if tonumber(group.hierarchy_enabled) ~= 1 then
            return rejected('HIERARCHY_DISABLED',
                'The organization type does not permit a parent organization.')
        end
        if request.parent_group_id == request.group_id then
            return rejected('HIERARCHY_CYCLE', 'An organization cannot be its own parent.')
        end
        local parent = tx.one([[SELECT `group_record`.`id`, `group_record`.`status`,
                `profile`.`lifecycle_state`
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
        if tx.one([[SELECT 1 AS `creates_cycle` FROM `synex_group_hierarchy_closure`
            WHERE `ancestor_group_id` = ? AND `descendant_group_id` = ? FOR UPDATE]],
            { group.id, parent.id }) then
            return rejected('HIERARCHY_CYCLE',
                'The requested parent would create an organization cycle.')
        end
        local parentDepth = tx.one([[SELECT MAX(`depth`) AS `maximum_depth`
            FROM `synex_group_hierarchy_closure`
            WHERE `descendant_group_id` = ? FOR UPDATE]], { parent.id })
        local subtreeDepth = tx.one([[SELECT MAX(`depth`) AS `maximum_depth`
            FROM `synex_group_hierarchy_closure`
            WHERE `ancestor_group_id` = ? FOR UPDATE]], { group.id })
        if not parentDepth or not subtreeDepth
            or tonumber(parentDepth.maximum_depth) == nil
            or tonumber(subtreeDepth.maximum_depth) == nil then
            return rejected('HIERARCHY_INVALID', 'The organization hierarchy is incomplete.')
        end
        if tonumber(parentDepth.maximum_depth) + tonumber(subtreeDepth.maximum_depth) + 1
            > MAXIMUM_HIERARCHY_DEPTH then
            return rejected('HIERARCHY_DEPTH_EXCEEDED',
                'The organization hierarchy exceeds its supported depth.')
        end
        tx.many([[SELECT `ancestor_group_id`, `descendant_group_id`, `depth`
            FROM `synex_group_hierarchy_closure`
            WHERE `descendant_group_id` = ? OR `ancestor_group_id` = ? FOR UPDATE]],
            { group.id, group.id })
        tx.query([[DELETE `path` FROM `synex_group_hierarchy_closure` AS `path`
            INNER JOIN `synex_group_hierarchy_closure` AS `ancestor`
                ON `ancestor`.`ancestor_group_id` = `path`.`ancestor_group_id`
                AND `ancestor`.`descendant_group_id` = ?
            INNER JOIN `synex_group_hierarchy_closure` AS `subtree`
                ON `subtree`.`ancestor_group_id` = ?
                AND `subtree`.`descendant_group_id` = `path`.`descendant_group_id`
            WHERE `ancestor`.`ancestor_group_id` <> ?]], { group.id, group.id, group.id })
        tx.query([[INSERT INTO `synex_group_hierarchy_edges`
            (`child_group_id`, `parent_group_id`, `created_by_ref`, `reason_code`, `version`)
            VALUES (?, ?, ?, ?, 1)
            ON DUPLICATE KEY UPDATE `parent_group_id` = VALUES(`parent_group_id`),
                `created_by_ref` = VALUES(`created_by_ref`), `reason_code` = VALUES(`reason_code`),
                `version` = `version` + 1]],
            { group.id, parent.id, request.actor_character_id, reason })
        tx.query([[INSERT INTO `synex_group_hierarchy_closure`
            (`ancestor_group_id`, `descendant_group_id`, `depth`)
            SELECT `ancestor`.`ancestor_group_id`, `subtree`.`descendant_group_id`,
                `ancestor`.`depth` + `subtree`.`depth` + 1
            FROM `synex_group_hierarchy_closure` AS `ancestor`
            CROSS JOIN `synex_group_hierarchy_closure` AS `subtree`
            WHERE `ancestor`.`descendant_group_id` = ?
                AND `subtree`.`ancestor_group_id` = ?]], { parent.id, group.id })
    end

    local nextVersion = group.version + 1
    local targetLifecycle = targetStatus and targetStatus:upper() or nil
    local closedDutySessions = 0
    if targetStatus == 'suspended' then
        local insertedDutyEvents = tx.query([[INSERT INTO `synex_group_duty_events`
            (`event_id`, `duty_session_id`, `session_version`, `event_type`,
             `state_key`, `actor_ref`, `reason_code`, `assignment_id`, `metadata_json`)
            SELECT CONCAT('gduty_', SUBSTRING(SHA2(CONCAT(`session`.`public_id`,
                    ':group-suspended:', ?, ':', ?), 256), 1, 32)),
                `session`.`id`, `session`.`version` + 1, 'ended', `session`.`state_key`,
                ?, 'group_suspended', `session`.`assignment_id`, `session`.`metadata_json`
            FROM `synex_group_duty_sessions` AS `session`
            INNER JOIN `synex_group_memberships` AS `membership`
                ON `membership`.`id` = `session`.`membership_id`
            WHERE `membership`.`group_id` = ? AND `session`.`status` = 'open']], {
            request.group_id, nextVersion, request.actor_character_id, group.id
        })
        closedDutySessions = affectedRows(insertedDutyEvents)
        if closedDutySessions == nil then
            return rejected('DATABASE_RESULT_INVALID',
                'Open duty events could not be recorded before suspension.', true)
        end
        local closedDuty = tx.query([[UPDATE `synex_group_duty_sessions` AS `session`
            INNER JOIN `synex_group_memberships` AS `membership`
                ON `membership`.`id` = `session`.`membership_id`
            SET `session`.`status` = 'closed',
                `session`.`ended_at` = CURRENT_TIMESTAMP(6),
                `session`.`reason_code` = 'group_suspended',
                `session`.`version` = `session`.`version` + 1
            WHERE `membership`.`group_id` = ? AND `session`.`status` = 'open']],
            { group.id })
        if affectedRows(closedDuty) ~= closedDutySessions then
            return rejected('CONCURRENT_MODIFICATION',
                'Open duty sessions changed during organization suspension.', true)
        end
    end
    local groupUpdate = tx.query([[UPDATE `synex_groups`
        SET `status` = COALESCE(?, `status`),
            `group_key` = COALESCE(?, `group_key`),
            `display_name` = COALESCE(?, `display_name`),
            `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]],
        { targetStatus, request.slug, request.label, group.id, group.version })
    local profileUpdate = tx.query([[UPDATE `synex_group_organization_profiles`
        SET `lifecycle_state` = COALESCE(?, `lifecycle_state`),
            `slug` = COALESCE(?, `slug`), `name` = COALESCE(?, `name`),
            `label` = COALESCE(?, `label`), `description` = COALESCE(?, `description`),
            `visibility` = COALESCE(?, `visibility`),
            `lifecycle_reason_code` = ?,
            `state_changed_at` = CASE WHEN ? IS NULL THEN `state_changed_at`
                ELSE CURRENT_TIMESTAMP(6) END,
            `suspended_at` = CASE WHEN ? = 'SUSPENDED' THEN CURRENT_TIMESTAMP(6)
                WHEN ? = 'ACTIVE' THEN NULL ELSE `suspended_at` END,
            `version` = `version` + 1
        WHERE `group_id` = ? AND `version` = ?]],
        { targetLifecycle, request.slug, request.name, request.label, request.description,
            request.visibility, reason, targetLifecycle, targetLifecycle, targetLifecycle,
            group.id, group.profile_version })
    if affectedRows(groupUpdate) ~= 1 or affectedRows(profileUpdate) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization changed during the update.', true)
    end
    if releasePreviousSlug then
        local released, releaseError = releaseSlugReservation(
            tx, group.slug, 'group', group.group_public_id)
        if not released then return nil, releaseError, nil end
    end
    local bumped, bumpError = bumpReadModel(tx, group.id)
    if not bumped then return nil, bumpError, nil end
    local before = {
        slug = group.slug, name = group.name, label = group.label, description = group.description,
        status = currentLifecycle,
        visibility = group.visibility, parent_group_id = previousParent and previousParent.public_id,
        version = group.version
    }
    local after = {
        slug = request.slug or group.slug,
        name = request.name or group.name,
        label = request.label or group.label,
        description = request.description or group.description,
        status = targetStatus or currentLifecycle,
        visibility = request.visibility or group.visibility,
        parent_group_id = request.parent_group_id
            or previousParent and previousParent.public_id or nil,
        version = nextVersion
    }
    if targetStatus == 'suspended' then
        after.closed_duty_sessions = closedDutySessions
    end
    local effect = runtime.effect(action, 'group', request.group_id,
        request.group_id, request.actor_character_id, before, after, reason)
    return mutationResult(runtime, request.group_id, 'group',
        targetStatus or currentLifecycle, nextVersion, effect)
end

function execute.archive(tx, request, runtime, context)
    local group, groupError = loadGroupForUpdate(tx, request.group_id)
    if not group then return nil, groupError, nil end
    local currentLifecycle = type(group.lifecycle_state) == 'string'
        and group.lifecycle_state:lower() or nil
    if currentLifecycle == 'draft' or currentLifecycle == 'suspended' then
        if type(runtime.checkCorePermission) ~= 'function' then
            return rejected('CORE_UNAVAILABLE',
                'The Core character permission boundary is unavailable.', true)
        end
        local permitted, permissionError = runtime.checkCorePermission(
            request.actor_character_id, 'synex.groups.archive')
        if not permitted then
            return nil, permissionError or Foundation.domainError(
                'INSUFFICIENT_PERMISSION',
                'Archiving an inactive organization requires Core authority.'), nil
        end
    else
        local allowed, authorizationError = authorize(runtime, tx, request.group_id,
            request.actor_character_id, 'synex.groups.archive',
            { kind = 'group', group_id = request.group_id })
        if not allowed then return nil, authorizationError, nil end
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if group.version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION', 'The organization version has changed.', true,
            { expected = request.expected_version, actual = group.version })
    end
    if currentLifecycle == 'archived' or currentLifecycle == 'dissolving'
        or currentLifecycle == 'deleted' then
        return rejected('GROUP_INACTIVE',
            'The organization is already archived, dissolving, or deleted.')
    end
    local transition, transitionError = Lifecycle.transition(
        'group', currentLifecycle, 'archived')
    if not transition then
        return rejected('INVALID_TRANSITION', transitionError.message, false,
            transitionError.details)
    end
    local activeChild = tx.one([[SELECT `child`.`public_id`
        FROM `synex_group_hierarchy_edges` AS `edge`
        INNER JOIN `synex_groups` AS `child` ON `child`.`id` = `edge`.`child_group_id`
        WHERE `edge`.`parent_group_id` = ? AND `child`.`status` <> 'archived'
        ORDER BY `child`.`id` ASC LIMIT 1 FOR UPDATE]], { group.id })
    if activeChild then
        return rejected('GROUP_HAS_ACTIVE_CHILDREN',
            'The organization cannot be archived while it has active children.', false,
            { child_group_id = activeChild.public_id })
    end
    local activeMember = tx.one([[SELECT membership.public_id
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        WHERE membership.group_id = ?
            AND profile.lifecycle_state IN
                ('PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE')
        ORDER BY membership.id ASC LIMIT 1 FOR UPDATE]], { group.id })
    if activeMember then
        return rejected('GROUP_HAS_ACTIVE_MEMBERS',
            'Resolve every joined non-terminal membership before archiving the organization.', false,
            { membership_id = activeMember.public_id })
    end
    local activeRelationship = tx.one([[SELECT relationship.public_id
        FROM synex_group_relationships AS relationship
        WHERE (relationship.source_group_id = ? OR relationship.target_group_id = ?)
            AND relationship.status <> 'ended'
        ORDER BY relationship.id ASC LIMIT 1 FOR UPDATE]], { group.id, group.id })
    if activeRelationship then
        return rejected('GROUP_HAS_ACTIVE_RELATIONSHIPS',
            'End every organization relationship before archival.', false,
            { relationship_id = activeRelationship.public_id })
    end
    local activeWorkflow = tx.one([[SELECT 'assignment' AS blocker, public_id
        FROM synex_group_assignments
        WHERE group_id = ? AND status = 'active'
        ORDER BY id ASC LIMIT 1 FOR UPDATE]], { group.id })
        or tx.one([[SELECT 'invitation' AS blocker, public_id
            FROM synex_group_invitations
            WHERE group_id = ? AND status = 'pending'
            ORDER BY id ASC LIMIT 1 FOR UPDATE]], { group.id })
        or tx.one([[SELECT 'application' AS blocker, public_id
            FROM synex_group_applications
            WHERE group_id = ? AND status IN ('submitted', 'reviewing')
            ORDER BY id ASC LIMIT 1 FOR UPDATE]], { group.id })
    local approvedOperation, approvedContextError
    if Foundation.isCallable(runtime.resolveApprovedOperation) then
        approvedOperation, approvedContextError = runtime.resolveApprovedOperation(
            context, 'archive', request, request.group_id)
        if approvedContextError then return nil, approvedContextError, nil end
    end
    local executingProposalId = approvedOperation and approvedOperation.proposalId or nil
    if not activeWorkflow then
        if executingProposalId then
            activeWorkflow = tx.one([[SELECT 'proposal' AS blocker, public_id
                FROM synex_group_proposals
                WHERE group_id = ? AND status IN ('pending', 'approved') AND public_id <> ?
                ORDER BY id ASC LIMIT 1 FOR UPDATE]], { group.id, executingProposalId })
        else
            activeWorkflow = tx.one([[SELECT 'proposal' AS blocker, public_id
                FROM synex_group_proposals
                WHERE group_id = ? AND status IN ('pending', 'approved')
                ORDER BY id ASC LIMIT 1 FOR UPDATE]], { group.id })
        end
    end
    if activeWorkflow then
        return rejected('GROUP_HAS_ACTIVE_WORKFLOWS',
            'Resolve every active organization workflow before archival.', false, {
                entity_type = activeWorkflow.blocker,
                entity_id = activeWorkflow.public_id
            })
    end
    local reason, reasonError = checkedReason(runtime, request.reason, 'group_archived')
    if not reason then return nil, reasonError, nil end
    local nextVersion = group.version + 1
    local groupUpdate = tx.query([[UPDATE `synex_groups`
        SET `status` = 'archived', `version` = `version` + 1
        WHERE `id` = ? AND `version` = ?]], { group.id, group.version })
    local profileUpdate = tx.query([[UPDATE `synex_group_organization_profiles`
        SET `lifecycle_state` = 'ARCHIVED', `lifecycle_reason_code` = ?,
            `state_changed_at` = CURRENT_TIMESTAMP(6), `archived_at` = CURRENT_TIMESTAMP(6),
            `version` = `version` + 1
        WHERE `group_id` = ? AND `version` = ?]],
        { reason, group.id, group.profile_version })
    if affectedRows(groupUpdate) ~= 1 or affectedRows(profileUpdate) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION', 'The organization changed during archival.', true)
    end
    local bumped, bumpError = bumpReadModel(tx, group.id)
    if not bumped then return nil, bumpError, nil end
    local effect = runtime.effect('group.archived', 'group', request.group_id,
        request.group_id, request.actor_character_id,
        { status = currentLifecycle, version = group.version },
        { status = 'archived', version = nextVersion }, reason)
    return mutationResult(runtime, request.group_id, 'group', 'archived', nextVersion, effect)
end

return { execute = execute }
end
