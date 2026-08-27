return function(Foundation)
local Shared = require('server.persistence.workflows_shared')(Foundation)
local identifier = Shared.identifier
local updateOne = Shared.updateOne
local validWindow = Shared.validWindow
local handlers = { read = {}, execute = {} }

local function proposalTargetGroup(tx, action, payload)
    if action == 'group.update' or action == 'group.archive'
        or action == 'policy.set' then
        return payload.group_id
    end
    if action == 'membership.transition' or action == 'membership.set_grade'
        or action == 'membership.set_primary_grade'
        or action == 'role.assign' then
        local row = tx.one([[SELECT group_record.public_id
            FROM synex_group_memberships AS membership
            INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
            WHERE membership.public_id = ? FOR UPDATE]], { payload.membership_id })
        return row and row.public_id or nil
    end
    if action == 'role.remove' then
        local row = tx.one([[SELECT group_record.public_id
            FROM synex_group_membership_roles AS assigned
            INNER JOIN synex_group_memberships AS membership
                ON membership.id = assigned.membership_id
            INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
            WHERE assigned.public_id = ? FOR UPDATE]], { payload.membership_role_id })
        return row and row.public_id or nil
    end
    if action == 'relationship.update' then
        local row = tx.one([[SELECT source_group.public_id
            FROM synex_group_relationships AS relationship
            INNER JOIN synex_groups AS source_group
                ON source_group.id = relationship.source_group_id
            WHERE relationship.public_id = ? FOR UPDATE]], { payload.relationship_id })
        return row and row.public_id or nil
    end
    return nil
end

function handlers.execute.proposals_create(tx, request, runtime, context)
    local actor, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.approvals.manage', 'group')
    if not actor then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = runtime.requireGroup(tx, request.group_id, true)
    if not group then return nil, groupError end
    local valid, windowError = validWindow(tx, nil, request.expires_at)
    if not valid then return nil, windowError end
    local proposalId, idError = identifier(runtime, 'group_proposal')
    if not proposalId then return nil, idError end
    local proposalValid, proposalError = runtime.validateApproved(
        request.action, request.payload, request.actor_character_id,
        proposalId, request.reason)
    if not proposalValid then return nil, proposalError end
    local targetGroup = proposalTargetGroup(tx, request.action, request.payload)
    if targetGroup == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The proposal target could not be resolved inside its group scope.')
    end
    if targetGroup ~= request.group_id then
        return nil, Foundation.domainError('INVALID_SCOPE',
            'The proposal payload belongs to another group.')
    end
    local revision = tx.one([[SELECT model_version
        FROM synex_group_read_model_versions WHERE group_id = ? FOR UPDATE]], { group.id })
    if not revision or tonumber(revision.model_version) == nil then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The group permission revision is unavailable.', true)
    end
    tx.query([[INSERT INTO synex_group_proposals
        (public_id, group_id, proposal_type, payload_json, status,
         required_approvals, expected_group_version, created_by_membership_id,
         expires_at, executed_at, reason_code, version)
        VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, NULL, ?, 1)]], {
        proposalId, group.id, request.action, runtime.jsonEncode(request.payload),
        request.required_approvals, revision.model_version, actor.id, request.expires_at,
        runtime.reason(request.reason, 'proposal_created')
    })
    local response = runtime.success(proposalId, 'proposal', 'pending', 1)
    return response, nil, {
        runtime.effect('proposal.created', 'proposal', proposalId,
            request.group_id, request.actor_character_id, nil,
            { action = request.action, required_approvals = request.required_approvals,
                expected_group_version = tonumber(revision.model_version), version = 1 },
            request.reason, 1)
    }
end

local function decideProposal(tx, request, runtime, decision, context)
    local proposal = tx.one([[SELECT proposal.id, proposal.public_id,
            proposal.group_id, proposal.status, proposal.required_approvals,
            proposal.created_by_membership_id, proposal.version,
            proposal.proposal_type, proposal.payload_json,
            proposal.expected_group_version,
            CASE WHEN proposal.expires_at <= CURRENT_TIMESTAMP(6) THEN 1 ELSE 0 END AS expired,
            group_record.public_id AS group_public_id
        FROM synex_group_proposals AS proposal
        INNER JOIN synex_groups AS group_record ON group_record.id = proposal.group_id
        WHERE proposal.public_id = ? FOR UPDATE]], { request.proposal_id })
    if not proposal then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The proposal does not exist.')
    end
    local approver, authorizationError = runtime.authorize(
        tx, proposal.group_public_id, request.actor_character_id,
        'synex.groups.approvals.manage', 'group')
    if not approver then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if proposal.status ~= 'pending'
        or tonumber(proposal.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The proposal changed before this decision.', true)
    end
    if tonumber(proposal.expired) == 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The proposal has expired and cannot receive another decision.')
    end
    if approver.id == proposal.created_by_membership_id then
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'Proposal creators cannot approve or reject their own proposal.')
    end
    if tx.one([[SELECT id FROM synex_group_approvals
        WHERE proposal_id = ? AND approver_membership_id = ? FOR UPDATE]],
        { proposal.id, approver.id }) then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'This membership already submitted a decision for the proposal.', true)
    end
    local revision = tx.one([[SELECT model_version FROM synex_group_read_model_versions
        WHERE group_id = ? FOR UPDATE]], { proposal.group_id })
    tx.query([[INSERT INTO synex_group_approvals
        (proposal_id, approver_membership_id, decision, reason_code,
         permission_revision, version)
        VALUES (?, ?, ?, ?, ?, 1)]], {
        proposal.id, approver.id, decision,
        runtime.reason(request.reason, 'proposal_' .. decision),
        tonumber(revision and revision.model_version) or 1
    })
    local finalStatus = decision
    local targetEffects = {}
    if decision == 'approved' then
        local count = tx.one([[SELECT COUNT(*) AS count FROM synex_group_approvals
            WHERE proposal_id = ? AND decision = 'approved']], { proposal.id })
        if tonumber(count and count.count) < tonumber(proposal.required_approvals) then
            finalStatus = 'pending'
        else
            if not revision or tonumber(revision.model_version)
                ~= tonumber(proposal.expected_group_version) then
                return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                    'The group changed after the proposal was created.', true)
            end
            local decodedOk, decoded = pcall(runtime.jsonDecode, proposal.payload_json)
            local copiedOk, payload = false, nil
            if decodedOk then copiedOk, payload = pcall(Foundation.copyPlain, decoded) end
            if not decodedOk or not copiedOk or type(payload) ~= 'table' then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'The proposal payload could not be decoded safely.')
            end
            local currentApprovals = tx.many([[SELECT profile.character_id,
                    approval.permission_revision
                FROM synex_group_approvals AS approval
                INNER JOIN synex_group_membership_profiles AS profile
                    ON profile.membership_id = approval.approver_membership_id
                WHERE approval.proposal_id = ? AND approval.decision = 'approved'
                ORDER BY approval.id ASC FOR UPDATE]], { proposal.id })
            if #currentApprovals < tonumber(proposal.required_approvals) then
                return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                    'The proposal approval quorum changed before execution.', true)
            end
            for _, approval in ipairs(currentApprovals) do
                local stillAuthorized, currentAuthorizationError = runtime.authorize(
                    tx, proposal.group_public_id, approval.character_id,
                    'synex.groups.approvals.manage', 'group', {
                        parameters = {
                            proposal_id = proposal.public_id,
                            permission_revision = tonumber(approval.permission_revision)
                        }
                    })
                if not stillAuthorized then return nil, currentAuthorizationError end
            end
            local executionActor = request.actor_character_id
            if proposal.proposal_type == 'membership.set_primary_grade' then
                local target = tx.one([[SELECT `profile`.`character_id`
                    FROM `synex_group_memberships` AS `membership`
                    INNER JOIN `synex_group_membership_profiles` AS `profile`
                        ON `profile`.`membership_id` = `membership`.`id`
                    WHERE `membership`.`public_id` = ? FOR UPDATE]], {
                    payload.membership_id
                })
                if not target or not Foundation.isPublicId(target.character_id) then
                    return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
                        'The approved compatibility membership no longer exists.')
                end
                executionActor = target.character_id
            end
            local _, executionError, executionEffects = runtime.invokeApproved(
                tx, proposal.proposal_type, payload, executionActor,
                proposal.public_id, proposal.group_public_id,
                tonumber(proposal.version), request.reason, context)
            if executionError then return nil, executionError end
            targetEffects = type(executionEffects) == 'table' and executionEffects or {}
            if #targetEffects == 0 then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'The approved operation produced no auditable domain effect.', true)
            end
            for _, targetEffect in ipairs(targetEffects) do
                if type(targetEffect) ~= 'table'
                    or targetEffect.groupId ~= proposal.group_public_id then
                    return nil, Foundation.domainError('INVALID_SCOPE',
                        'The approved operation target does not belong to the proposal group.')
                end
            end
            finalStatus = 'executed'
        end
    end
    local nextVersion = tonumber(proposal.version) + 1
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_proposals
        SET status = ?, reason_code = ?,
            executed_at = CASE WHEN ? = 'executed' THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
            version = version + 1
        WHERE id = ? AND status = 'pending' AND version = ?]], {
        finalStatus, runtime.reason(request.reason, 'proposal_' .. decision), finalStatus,
        proposal.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local response = runtime.success(
        proposal.public_id, 'proposal', finalStatus, nextVersion)
    targetEffects[#targetEffects + 1] =
        runtime.effect('proposal.' .. (finalStatus == 'executed' and 'executed' or decision),
            'proposal', proposal.public_id,
            proposal.group_public_id, request.actor_character_id,
            { status = proposal.status, version = proposal.version },
            response, request.reason, nextVersion)
    return response, nil, targetEffects
end

function handlers.execute.proposals_approve(tx, request, runtime, context)
    return decideProposal(tx, request, runtime, 'approved', context)
end

function handlers.execute.proposals_reject(tx, request, runtime, context)
    return decideProposal(tx, request, runtime, 'rejected', context)
end

return handlers
end
