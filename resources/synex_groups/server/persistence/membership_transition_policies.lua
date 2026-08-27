return function(Foundation)
local Lifecycle = require 'server.domain.lifecycle'
local handlers = { read = {}, execute = {} }

local DEFAULT_CAPABILITY = 'synex.groups.members.manage'
local PREJOIN_STATES = {
    DRAFT = true,
    INVITED = true,
    APPLICANT = true,
    UNDER_REVIEW = true,
    APPROVED = true
}

local function rejected(code, message, retryable, details)
    return nil, Foundation.domainError(code, message, retryable, details), nil
end

local function integer(value, minimum)
    local numeric = tonumber(value)
    if not numeric or math.type(numeric) ~= 'integer' or numeric < (minimum or 1) then
        return nil
    end
    return numeric
end

local function exactCapability(value)
    if type(value) ~= 'string' or #value < 1 or #value > 96
        or value ~= value:lower() or value:sub(1, 1) == '.'
        or value:sub(-1) == '.' or value:find('..', 1, true)
        or value:find('*', 1, true) then
        return nil
    end
    local segments = 0
    for segment in value:gmatch('[^.]+') do
        segments = segments + 1
        if not segment:match('^[a-z][a-z0-9_%-]*$') then return nil end
    end
    return segments > 0 and value or nil
end

local function transitionStates(fromStatus, toStatus)
    local fromState = type(fromStatus) == 'string' and fromStatus:upper() or fromStatus
    local toState = type(toStatus) == 'string' and toStatus:upper() or toStatus
    local allowed, transitionError = Lifecycle.canTransition(
        'membership', fromState, toState)
    if not allowed then
        return nil, nil, Foundation.domainError('INVALID_TRANSITION',
            transitionError.message, false, transitionError.details)
    end
    if PREJOIN_STATES[fromState] or PREJOIN_STATES[toState] then
        return nil, nil, Foundation.domainError('INVALID_TRANSITION',
            'Pre-join membership states are controlled by invitation and application workflows.',
            false, { from = fromState, to = toState })
    end
    return fromState, toState, nil
end

local function compatibilityPolicy(groupId, fromState, toState)
    return {
        configured = false,
        group_id = groupId,
        from_status = fromState,
        to_status = toState,
        allowed = true,
        required_capability = DEFAULT_CAPABILITY,
        approval_required = false,
        reason_required = true
    }
end

local function storedBoolean(value)
    local numeric = integer(value, 0)
    if numeric ~= 0 and numeric ~= 1 then return nil end
    return numeric == 1
end

local function storedPolicy(row, groupId, internalGroupId, fromState, toState)
    if type(row) ~= 'table' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored membership transition policy is invalid.', true)
    end
    local rowId = integer(row.id)
    local rowGroupId = integer(row.group_id)
    local version = integer(row.version)
    local allowed = storedBoolean(row.allowed)
    local approvalRequired = storedBoolean(row.approval_required)
    local reasonRequired = storedBoolean(row.reason_required)
    local publicId = row.public_id
    if not rowId or rowGroupId ~= internalGroupId or not version
        or type(publicId) ~= 'string' or not Foundation.isPublicId(publicId)
        or publicId ~= publicId:lower()
        or not publicId:match('^[a-z][a-z0-9_]*$')
        or row.from_state ~= fromState or row.to_state ~= toState
        or allowed == nil or approvalRequired == nil or reasonRequired == nil
        or not exactCapability(row.required_capability) then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored membership transition policy is invalid.', true)
    end
    return {
        _internal_id = rowId,
        configured = true,
        policy_id = publicId,
        group_id = groupId,
        from_status = fromState,
        to_status = toState,
        allowed = allowed,
        required_capability = row.required_capability,
        approval_required = approvalRequired,
        reason_required = reasonRequired,
        version = version
    }, nil
end

local function publicPolicy(policy)
    return {
        configured = policy.configured,
        policy_id = policy.policy_id,
        group_id = policy.group_id,
        from_status = policy.from_status,
        to_status = policy.to_status,
        allowed = policy.allowed,
        required_capability = policy.required_capability,
        approval_required = policy.approval_required,
        reason_required = policy.reason_required,
        version = policy.version
    }
end

local function loadPolicy(tx, groupId, internalGroupId, fromState, toState, lock)
    local row = tx.one([[SELECT `policy`.`id`, `policy`.`public_id`,
            `policy`.`group_id`, `policy`.`from_state`, `policy`.`to_state`,
            `policy`.`allowed`, `policy`.`required_capability`,
            `policy`.`approval_required`, `policy`.`reason_required`,
            `policy`.`version`
        FROM `synex_group_membership_transition_policies` AS `policy`
        WHERE `policy`.`group_id` = ? AND `policy`.`from_state` = ?
            AND `policy`.`to_state` = ? LIMIT 1]]
            .. (lock and ' FOR UPDATE' or ''), {
        internalGroupId, fromState, toState
    })
    if not row then
        return compatibilityPolicy(groupId, fromState, toState), nil
    end
    return storedPolicy(row, groupId, internalGroupId, fromState, toState)
end

local function resolveMembershipTransitionPolicy(tx, input)
    if type(tx) ~= 'table' or type(tx.one) ~= 'function'
        or type(input) ~= 'table' or not Foundation.isPublicId(input.group_id)
        or not integer(input.internal_group_id) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The membership transition policy lookup is invalid.')
    end
    local fromState, toState, transitionError = transitionStates(
        input.from_status, input.to_status)
    if not fromState then return nil, transitionError end
    return loadPolicy(tx, input.group_id, integer(input.internal_group_id),
        fromState, toState, input.lock == true)
end

handlers.resolveMembershipTransitionPolicy = resolveMembershipTransitionPolicy

local function activeGroup(tx, request, runtime, lock)
    local group, groupError = runtime.requireGroup(tx, request.group_id, lock == true)
    if not group then return nil, groupError end
    local groupId = integer(group.id)
    if not groupId or group.status ~= 'active' or group.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError(groupId and 'GROUP_INACTIVE'
            or 'DATABASE_RESULT_INVALID', groupId
                and 'Membership transition policies require an active group.'
                or 'The stored group identity is invalid.', not groupId)
    end
    return group, nil
end

local function authorizePolicyManagement(tx, request, runtime)
    local authorized, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.policies.manage', 'group')
    if not authorized then
        return nil, authorizationError or Foundation.domainError(
            'INSUFFICIENT_PERMISSION',
            'The actor cannot manage membership transition policies.')
    end
    return true, nil
end

local function validateDefinition(request)
    if type(request.allowed) ~= 'boolean'
        or type(request.approval_required) ~= 'boolean'
        or type(request.reason_required) ~= 'boolean'
        or not exactCapability(request.required_capability) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Transition policies require boolean flags and an exact capability name.')
    end
    if request.expected_version ~= nil and not integer(request.expected_version) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'expected_version must be a positive integer when supplied.')
    end
    return {
        allowed = request.allowed,
        required_capability = request.required_capability,
        approval_required = request.approval_required,
        reason_required = request.reason_required
    }, nil
end

local function requireTypeStates(tx, internalGroupId, fromState, toState)
    local states = tx.one([[SELECT `from_allowed`.`state_key` AS `from_state`,
            `to_allowed`.`state_key` AS `to_state`
        FROM `synex_group_organization_profiles` AS `organization`
        INNER JOIN `synex_group_type_membership_states` AS `from_allowed`
            ON `from_allowed`.`group_type_id` = `organization`.`group_type_id`
            AND `from_allowed`.`state_key` = ?
        INNER JOIN `synex_group_membership_states` AS `from_definition`
            ON `from_definition`.`state_key` = `from_allowed`.`state_key`
            AND `from_definition`.`status` = 'active'
        INNER JOIN `synex_group_type_membership_states` AS `to_allowed`
            ON `to_allowed`.`group_type_id` = `organization`.`group_type_id`
            AND `to_allowed`.`state_key` = ?
        INNER JOIN `synex_group_membership_states` AS `to_definition`
            ON `to_definition`.`state_key` = `to_allowed`.`state_key`
            AND `to_definition`.`status` = 'active'
        WHERE `organization`.`group_id` = ? FOR UPDATE]], {
        fromState, toState, internalGroupId
    })
    if not states then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The organization type does not permit both transition states.', false, {
                from = fromState,
                to = toState
            })
    end
    if states.from_state ~= fromState or states.to_state ~= toState then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored organization type transition states are invalid.', true)
    end
    return true, nil
end

function handlers.read.members_transition_policy_get(tx, request, runtime)
    local authorized, authorizationError = authorizePolicyManagement(tx, request, runtime)
    if not authorized then return nil, authorizationError end
    local group, groupError = activeGroup(tx, request, runtime, false)
    if not group then return nil, groupError end
    local policy, policyError = resolveMembershipTransitionPolicy(tx, {
        group_id = request.group_id,
        internal_group_id = group.id,
        from_status = request.from_status,
        to_status = request.to_status,
        lock = false
    })
    if not policy then return nil, policyError end
    return publicPolicy(policy), nil
end

function handlers.execute.members_transition_policy_set(tx, request, runtime, context)
    local definition, definitionError = validateDefinition(request)
    if not definition then return nil, definitionError end
    local fromState, toState, transitionError = transitionStates(
        request.from_status, request.to_status)
    if not fromState then return nil, transitionError end
    local authorized, authorizationError = authorizePolicyManagement(tx, request, runtime)
    if not authorized then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = activeGroup(tx, request, runtime, true)
    if not group then return nil, groupError end
    local typeStatesReady, typeStatesError = requireTypeStates(
        tx, group.id, fromState, toState)
    if not typeStatesReady then return nil, typeStatesError end

    local existing, existingError = loadPolicy(
        tx, request.group_id, integer(group.id), fromState, toState, true)
    if not existing then return nil, existingError end
    local publicId, version
    if existing.configured then
        if request.expected_version == nil
            or request.expected_version ~= existing.version then
            return rejected('CONCURRENT_MODIFICATION',
                'Updating a transition policy requires its current expected_version.', true)
        end
        local changed = tx.affected([[UPDATE `synex_group_membership_transition_policies`
            SET `allowed` = ?, `required_capability` = ?,
                `approval_required` = ?, `reason_required` = ?,
                `updated_by_ref` = ?, `version` = `version` + 1
            WHERE `id` = ? AND `version` = ?]], {
            definition.allowed and 1 or 0,
            definition.required_capability,
            definition.approval_required and 1 or 0,
            definition.reason_required and 1 or 0,
            request.actor_character_id,
            existing._internal_id,
            existing.version
        })
        if changed ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The membership transition policy changed concurrently.', true)
        end
        publicId, version = existing.policy_id, existing.version + 1
    else
        if request.expected_version ~= nil and request.expected_version ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A new transition policy can only use expected_version 1.', true)
        end
        local allocated, allocationError = runtime.id('group_transition_policy')
        if not Foundation.isPublicId(allocated) or allocated ~= allocated:lower()
            or not allocated:match('^[a-z][a-z0-9_]*$') then
            return nil, allocationError or Foundation.domainError(
                'ID_ALLOCATION_FAILED',
                'A membership transition policy identifier could not be allocated.', true)
        end
        local inserted = tx.affected([[INSERT INTO
                `synex_group_membership_transition_policies`
            (`public_id`, `group_id`, `from_state`, `to_state`, `allowed`,
             `required_capability`, `approval_required`, `reason_required`,
             `updated_by_ref`, `version`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
            allocated, group.id, fromState, toState,
            definition.allowed and 1 or 0,
            definition.required_capability,
            definition.approval_required and 1 or 0,
            definition.reason_required and 1 or 0,
            request.actor_character_id
        })
        if inserted ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The membership transition policy could not be created.', true)
        end
        publicId, version = allocated, 1
    end

    local touched, touchError = runtime.touchGroup(tx, group.id)
    if not touched then return nil, touchError end
    local after = {
        configured = true,
        policy_id = publicId,
        group_id = request.group_id,
        from_status = fromState,
        to_status = toState,
        allowed = definition.allowed,
        required_capability = definition.required_capability,
        approval_required = definition.approval_required,
        reason_required = definition.reason_required,
        version = version
    }
    local response = runtime.success(
        publicId, 'membership_transition_policy', 'active', version)
    return response, nil, {
        runtime.effect('membership.transition_policy.changed',
            'membership_transition_policy', publicId, request.group_id,
            request.actor_character_id, publicPolicy(existing), after,
            request.reason, version)
    }
end

return handlers
end
