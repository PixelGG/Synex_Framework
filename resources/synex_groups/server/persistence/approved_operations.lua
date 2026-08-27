return function(runtime, context)
local Foundation = assert(type(context) == 'table' and context.Foundation,
    'groups approved operations require Foundation')
local domainError = assert(type(context.domainError) == 'function' and context.domainError,
    'groups approved operations require domainError')
local canonicalEncode = assert(type(context.canonicalEncode) == 'function' and context.canonicalEncode,
    'groups approved operations require canonicalEncode')
local jsonDecode = assert(type(context.jsonDecode) == 'function' and context.jsonDecode,
    'groups approved operations require jsonDecode')
local validateOperation = assert(type(context.validateOperation) == 'function' and context.validateOperation,
    'groups approved operations require validateOperation')
local executeHandlers = assert(type(context.executeHandlers) == 'table' and context.executeHandlers,
    'groups approved operations require executeHandlers')
local approvedActions = {
    ['group.update'] = 'update',
    ['group.archive'] = 'archive',
    ['membership.transition'] = 'members_transition',
    ['membership.set_grade'] = 'members_set_grade',
    ['membership.set_primary_grade'] = 'compatibility_set_primary_grade',
    ['role.assign'] = 'roles_assign',
    ['role.remove'] = 'roles_remove',
    ['policy.set'] = 'policies_set',
    ['relationship.update'] = 'relationships_update'
}
local approvalSeal = {}
local function approvedRequest(action, payload, actorCharacterId, proposalId, reason)
    local operation = approvedActions[action]
    if type(operation) ~= 'string' or type(executeHandlers[operation]) ~= 'function' then
        return nil, domainError('VALIDATION_FAILED',
            'The proposal action is not supported by the Groups approval executor.')
    end
    local copiedOk, request = pcall(Foundation.copyPlain, payload)
    if not copiedOk or type(request) ~= 'table' then
        return nil, domainError('VALIDATION_FAILED',
            'The proposal payload is not a supported operation request.')
    end
    request.idempotency_key = 'proposal:' .. proposalId
    request.actor_character_id = actorCharacterId
    if request.reason == nil then request.reason = reason end
    local valid, validationError = validateOperation(operation, request)
    if not valid then return nil, validationError end
    return { operation = operation, request = request }, nil
end
function runtime.validateApproved(action, payload, actorCharacterId, proposalId, reason)
    local prepared, prepareError = approvedRequest(action, payload, actorCharacterId, proposalId, reason)
    if not prepared then return nil, prepareError end
    return true, nil
end
local function approvalError(message)
    return domainError('APPROVAL_REQUIRED', message or
        'The operation requires a currently approved Groups proposal.')
end
function runtime.resolveApprovedOperation(operationContext, expectedOperation, request, groupId)
    local grant = type(operationContext) == 'table'
        and rawget(operationContext, 'approvedOperation') or nil
    if grant == nil then return nil, nil end
    if type(grant) ~= 'table' or rawget(grant, 'seal') ~= approvalSeal
        or rawget(grant, 'operation') ~= expectedOperation
        or rawget(grant, 'groupId') ~= groupId
        or not Foundation.isPublicId(rawget(grant, 'proposalId')) then
        return nil, approvalError('The approved proposal binding is invalid.')
    end
    local encodedOk, fingerprint = pcall(canonicalEncode, request)
    if not encodedOk or fingerprint ~= rawget(grant, 'requestFingerprint') then
        return nil, approvalError(
            'The operation does not match the immutable approved proposal payload.')
    end
    return grant, nil
end
function runtime.verifyApprovedOperation(operationContext, expectedOperation, request, groupId)
    local grant, grantError = runtime.resolveApprovedOperation(
        operationContext, expectedOperation, request, groupId)
    if not grant then return nil, grantError or approvalError() end
    return true, nil, grant
end
function runtime.invokeApproved(tx, action, payload, actorCharacterId,
    proposalId, groupId, proposalVersion, reason, operationContext)
    local locked = tx.one([[SELECT `proposal`.`id`, `proposal`.`public_id`,
            `proposal`.`group_id`, `proposal`.`status`, `proposal`.`proposal_type`,
            `proposal`.`payload_json`, `proposal`.`required_approvals`,
            `proposal`.`version`, `group_record`.`public_id` AS `group_public_id`,
            (SELECT COUNT(*) FROM `synex_group_approvals` AS `approval`
                WHERE `approval`.`proposal_id` = `proposal`.`id`
                    AND `approval`.`decision` = 'approved') AS `approved_count`
        FROM `synex_group_proposals` AS `proposal`
        INNER JOIN `synex_groups` AS `group_record`
            ON `group_record`.`id` = `proposal`.`group_id`
        WHERE `proposal`.`public_id` = ? FOR UPDATE]], { proposalId })
    if type(locked) ~= 'table' or locked.public_id ~= proposalId
        or locked.group_public_id ~= groupId or locked.proposal_type ~= action
        or locked.status ~= 'pending'
        or tonumber(locked.version) ~= tonumber(proposalVersion)
        or tonumber(locked.required_approvals) == nil
        or tonumber(locked.approved_count) == nil
        or tonumber(locked.approved_count) < tonumber(locked.required_approvals) then
        return nil, approvalError(
            'The proposal is not the currently locked and approved operation.')
    end
    local decodedOk, durablePayload = pcall(jsonDecode, locked.payload_json)
    local copiedOk, boundedDurablePayload = false, nil
    if decodedOk then
        copiedOk, boundedDurablePayload = pcall(Foundation.copyPlain, durablePayload, {
            maximumDepth = 12,
            maximumKeys = 256,
            maximumStringBytes = 4096,
            preserveContainerKind = false
        })
    end
    local suppliedOk, suppliedFingerprint = pcall(canonicalEncode, payload)
    local durableOk, durableFingerprint = false, nil
    if copiedOk then
        durableOk, durableFingerprint = pcall(canonicalEncode, boundedDurablePayload)
    end
    if not decodedOk or not copiedOk or not suppliedOk or not durableOk
        or suppliedFingerprint ~= durableFingerprint then
        return nil, approvalError(
            'The proposal payload no longer matches its durable approved content.')
    end
    local prepared, prepareError = approvedRequest(
        action, payload, actorCharacterId, proposalId, reason)
    if not prepared then return nil, prepareError end
    local beforeExecution = operationContext and operationContext.beforeProposalExecute
    if not Foundation.isCallable(beforeExecution) then
        return nil, domainError('HOOK_REJECTED',
            'The required proposal execution hook is unavailable.', true)
    end
    local envelope = {
        proposal_id = proposalId,
        group_id = groupId,
        action = action,
        actor_character_id = actorCharacterId,
        payload = prepared.request,
        reason = reason
    }
    local canonicalBeforeOk, canonicalBefore = pcall(canonicalEncode, envelope)
    local hookCalled, hooked, hookError = pcall(beforeExecution, envelope)
    if hookCalled and hooked == false and type(hookError) == 'table' then hooked = nil end
    if not canonicalBeforeOk or not hookCalled or hooked == nil then
        return nil, hookError or domainError('HOOK_REJECTED',
            'The proposal execution hook rejected the approved operation.')
    end
    local hookCopyOk, boundedHooked = pcall(Foundation.copyPlain, hooked, {
        maximumDepth = 12,
        maximumKeys = 256,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    local canonicalAfterOk, canonicalAfter = false, nil
    if hookCopyOk then
        canonicalAfterOk, canonicalAfter = pcall(canonicalEncode, boundedHooked)
    end
    if not hookCopyOk or not canonicalAfterOk or canonicalAfter ~= canonicalBefore then
        return nil, domainError('HOOK_REJECTED',
            'The proposal execution hook cannot alter approved content.')
    end
    local handler = executeHandlers[prepared.operation]
    local approvalContext = {}
    for key, value in pairs(operationContext or {}) do approvalContext[key] = value end
    local fingerprintOk, requestFingerprint = pcall(canonicalEncode, prepared.request)
    if not fingerprintOk then
        return nil, approvalError('The approved operation payload cannot be bound safely.')
    end
    approvalContext.approvedOperation = {
        seal = approvalSeal,
        proposalId = proposalId,
        proposalInternalId = tonumber(locked.id),
        proposalVersion = tonumber(locked.version),
        groupId = groupId, action = action, operation = prepared.operation,
        requestFingerprint = requestFingerprint
    }
    return handler(tx, prepared.request, runtime, approvalContext)
end
return true
end
