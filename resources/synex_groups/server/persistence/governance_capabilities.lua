return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local MAXIMUM_TRACE_ITEMS = Shared.MAXIMUM_TRACE_ITEMS
local rejected = Shared.rejected
local publicId = Shared.publicId
local activeGroup = Shared.activeGroup
local reason = Shared.reason
local scopeName = Shared.scopeName
local boundedTrace = Shared.boundedTrace
local capabilityResult = Shared.capabilityResult
local handlers = { read = {}, execute = {} }

local function evaluateCapability(tx, request, runtime, context)
    if request.actor_character_id ~= nil
        and request.actor_character_id ~= request.character_id then
        local _, authorizationError = runtime.authorize(
            tx, request.group_id, request.actor_character_id,
            'synex.groups.capabilities.read', request.scope or 'group')
        if authorizationError then return nil, authorizationError end
    end
    local group, groupError = activeGroup(tx, runtime, request.group_id, false)
    if not group then return nil, groupError end
    local evaluation, evaluationError = runtime.evaluateCharacter(
        tx, request.group_id, request.character_id,
        request.capability, request.scope or 'group', false)
    if not evaluation then return nil, evaluationError end
    return capabilityResult(request, context, evaluation), nil
end

handlers.read.capabilities_check = evaluateCapability
handlers.read.capabilities_explain = evaluateCapability

function handlers.execute.delegations_create(tx, request, runtime, context)
    if request.capability:find('*', 1, true) then
        return rejected('VALIDATION_FAILED',
            'Wildcard capabilities cannot be delegated.')
    end
    local grantor, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.delegations.manage', request.scope or 'group')
    if not grantor then return nil, authorizationError end
    local group, groupError = activeGroup(tx, runtime, request.group_id, true)
    if not group then return nil, groupError end
    local capabilityOwner, capabilityError, capabilityEvaluation = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        request.capability, request.scope or 'group')
    if not capabilityOwner then
        return nil, capabilityError or Foundation.domainError('INSUFFICIENT_PERMISSION',
            'A capability can only be delegated by a character who currently owns it.')
    end
    if type(capabilityEvaluation) ~= 'table'
        or capabilityEvaluation.delegable ~= true then
        return rejected('INSUFFICIENT_PERMISSION',
            'The owned capability is not explicitly delegable.', false, {
                capability = request.capability,
                reason = 'CAPABILITY_NOT_DELEGABLE'
            })
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end

    local grantee, granteeError = runtime.requireMembership(
        tx, request.grantee_membership_id, true)
    if not grantee then return nil, granteeError end
    if grantee.group_id ~= group.id then
        return rejected('INVALID_SCOPE',
            'The delegation target must belong to the requested group.')
    end
    if grantee.lifecycle_state ~= 'ACTIVE' then
        return rejected('MEMBERSHIP_NOT_ACTIVE',
            'The delegation target membership must be active.')
    end
    if grantee.id == grantor.id then
        return rejected('VALIDATION_FAILED',
            'A membership cannot delegate a capability to itself.')
    end

    local window = tx.one([[SELECT CASE
            WHEN CAST(? AS DATETIME(6)) <= CURRENT_TIMESTAMP(6) THEN 0
            WHEN ? IS NOT NULL AND CAST(? AS DATETIME(6)) >= CAST(? AS DATETIME(6)) THEN 0
            ELSE 1 END AS valid]], {
        request.valid_until,
        request.valid_from, request.valid_from, request.valid_until
    })
    if not window or tonumber(window.valid) ~= 1 then
        return rejected('VALIDATION_FAILED',
            'The delegation window must end in the future and after its start.')
    end
    if tx.one([[SELECT id FROM synex_group_delegations
            WHERE grantee_membership_id = ? AND capability_pattern = ?
                AND scope_kind = ? AND scope_ref = ? AND status = 'active'
                AND valid_until > CURRENT_TIMESTAMP(6) FOR UPDATE]], {
        grantee.id, request.capability,
        request.scope == 'subtree' and 'custom' or 'group',
        request.scope == 'subtree' and 'subtree' or ''
    }) then
        return rejected('IDEMPOTENCY_CONFLICT',
            'An active equivalent delegation already exists.')
    end

    local delegationId, idError = publicId(runtime, 'group_delegation')
    if not delegationId then return nil, idError end
    tx.query([[INSERT INTO synex_group_delegations
        (public_id, group_id, grantor_membership_id, grantee_membership_id,
         capability_pattern, scope_kind, scope_ref, status, valid_from,
         valid_until, reason_code, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'active', COALESCE(CAST(? AS DATETIME(6)),
            CURRENT_TIMESTAMP(6)), CAST(? AS DATETIME(6)), ?, 1)]], {
        delegationId, group.id, grantor.id, grantee.id, request.capability,
        request.scope == 'subtree' and 'custom' or 'group',
        request.scope == 'subtree' and 'subtree' or '',
        request.valid_from, request.valid_until,
        reason(runtime, request.reason, 'delegation_created')
    })
    local touched, touchError = runtime.touchGroup(tx, group.id)
    if not touched then return nil, touchError end
    local response = runtime.success(delegationId, 'delegation', 'active', 1)
    return response, nil, {
        runtime.effect('delegation.created', 'delegation', delegationId,
            request.group_id, grantee.character_id, nil, {
                entity_id = delegationId,
                capability = request.capability,
                scope = request.scope or 'group',
                status = 'active',
                version = 1
            }, request.reason, 1)
    }
end

function handlers.execute.delegations_revoke(tx, request, runtime, context)
    local delegation = tx.one([[SELECT delegation.id, delegation.public_id,
            delegation.group_id, delegation.grantee_membership_id,
            delegation.capability_pattern, delegation.scope_kind,
            delegation.scope_ref, delegation.status, delegation.version,
            group_record.public_id AS group_public_id,
            profile.character_id
        FROM synex_group_delegations AS delegation
        INNER JOIN synex_groups AS group_record ON group_record.id = delegation.group_id
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = delegation.grantee_membership_id
        WHERE delegation.public_id = ? FOR UPDATE]], { request.delegation_id })
    if not delegation then
        return rejected('VALIDATION_FAILED', 'The delegation does not exist.')
    end
    local _, authorizationError = runtime.authorize(
        tx, delegation.group_public_id, request.actor_character_id,
        'synex.groups.delegations.manage', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local version = tonumber(delegation.version)
    if version ~= request.expected_version then
        return rejected('CONCURRENT_MODIFICATION',
            'The delegation version does not match expected_version.', true)
    end
    if delegation.status ~= 'active' then
        return rejected('INVALID_TRANSITION', 'Only an active delegation can be revoked.')
    end
    if tx.affected([[UPDATE synex_group_delegations
            SET status = 'revoked', revoked_at = CURRENT_TIMESTAMP(6),
                reason_code = ?, version = version + 1
            WHERE id = ? AND status = 'active' AND version = ?]], {
        reason(runtime, request.reason, 'delegation_revoked'),
        delegation.id, version
    }) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The delegation changed while it was being revoked.', true)
    end
    local touched, touchError = runtime.touchGroup(tx, delegation.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(
        request.delegation_id, 'delegation', 'revoked', version + 1)
    return response, nil, {
        runtime.effect('delegation.revoked', 'delegation', request.delegation_id,
            delegation.group_public_id, delegation.character_id,
            { status = 'active', version = version },
            { status = 'revoked', version = version + 1 },
            request.reason, version + 1)
    }
end

return handlers
end
