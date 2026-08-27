return function(Foundation)
local POLICY_EFFECTS = { allow = true, deny = true }
local POLICY_STATUS = { active = true, disabled = true, retired = true }
-- Public policy definitions intentionally expose only subjects for which the
-- evaluator has a concrete, group-scoped principal. Resource authority is
-- enforced separately by Core before the Groups policy layer is reached.
local POLICY_SUBJECTS = { character = true, membership = true }
local POLICY_SCOPES = { global = true, group = true, relationship = true, assignment = true, custom = true }
local ATTRIBUTE_TYPES = {
    string = true, integer = true, decimal = true,
    boolean = true, datetime = true, json = true
}
local ATTRIBUTE_VISIBILITY = {
    public = true, members = true, management = true, staff = true,
    hidden = true, server_only = true, private = true
}
local DEFINITION_KINDS = {
    group = true, group_type = true, relation_type = true,
    attribute_schema = true, duty_state = true
}
local MAXIMUM_TRACE_ITEMS = 128

local function rejected(code, message, retryable, details)
    return nil, Foundation.domainError(code, message, retryable, details), nil
end

local function isObject(value)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'array' then return false end
    for key in next, value do
        if type(key) ~= 'string' then return false end
    end
    return true
end

local function arrayLength(value, maximum)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'object' then return nil end
    local count, highest = 0, 0
    for key in next, value do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
        count = count + 1
        if count > maximum then return nil end
        highest = math.max(highest, key)
    end
    if count ~= highest then return nil end
    return count
end

local function closedObject(value, allowed, message)
    if not isObject(value) then
        return nil, Foundation.domainError('VALIDATION_FAILED', message .. ' must be an object.')
    end
    for key in next, value do
        if not allowed[key] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                message .. ' contains an unknown property.', false, { property = tostring(key) })
        end
    end
    return true, nil
end

local function publicId(runtime, namespace)
    local identifier, identifierError = runtime.id(namespace)
    if not Foundation.isPublicId(identifier) then
        return nil, identifierError or Foundation.domainError('DATABASE_ERROR',
            'A Groups public identifier could not be allocated.', true)
    end
    return identifier, nil
end

local function activeGroup(tx, runtime, groupId, lock)
    local group, groupError = runtime.requireGroup(tx, groupId, lock == true)
    if not group then return nil, groupError end
    if group.status ~= 'active' or group.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'The Groups governance operation requires an active group.')
    end
    return group, nil
end

local function reason(runtime, value, fallback)
    local normalized = runtime.reason(value, fallback)
    if type(normalized) ~= 'string' or #normalized < 2 or #normalized > 64 then
        return fallback
    end
    return normalized
end

local function canonical(runtime, value)
    local encodedOk, encoded = pcall(
        Foundation.createCanonicalEncoder(runtime.jsonEncode), value)
    if not encodedOk or type(encoded) ~= 'string' then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The supplied JSON value exceeds the supported bounds.')
    end
    return encoded, nil
end

local function copyJson(value, limits)
    local copiedOk, copied = pcall(Foundation.copyPlain, value, limits or {
        maximumDepth = 8,
        maximumKeys = 256,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not copiedOk then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The supplied JSON value exceeds the supported bounds.')
    end
    return copied, nil
end

local function scopeName(scope)
    return scope == 'subtree' and 'subtree' or 'group'
end

local function boundedTrace(source, additions)
    local result = {}
    for _, entry in ipairs(source or {}) do
        if #result >= MAXIMUM_TRACE_ITEMS then break end
        result[#result + 1] = entry
    end
    for _, entry in ipairs(additions or {}) do
        if #result >= MAXIMUM_TRACE_ITEMS then break end
        result[#result + 1] = entry
    end
    return result
end

local function capabilityResult(request, context, evaluation, trace, override)
    local decision = evaluation.allowed and 'ALLOW' or 'DENY'
    local reasonCode = evaluation.reason or 'NO_MATCHING_ALLOW'
    if override then
        decision = override.decision or decision
        reasonCode = override.reason or reasonCode
    end
    local traceId = type(context) == 'table' and context.traceId or nil
    if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 64 then
        traceId = 'groups_trace_unavailable'
    end
    return {
        decision = decision,
        reason = reasonCode,
        character_id = request.character_id or request.actor_character_id,
        group_id = request.group_id,
        capability = request.capability or request.action,
        scope = scopeName(request.scope),
        delegable = evaluation.delegable == true,
        trace_id = traceId,
        evaluation = boundedTrace(evaluation.trace, trace)
    }
end

local function scalarEquals(left, right)
    return type(left) == type(right) and left == right
end

local function ownerContext(context, requestedOwner)
    local owner = type(context) == 'table' and context.caller or nil
    local epoch = type(context) == 'table' and context.callerEpoch or nil
    if type(owner) ~= 'string' or #owner < 3 or #owner > 64
        or not owner:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
        or type(epoch) ~= 'number' or math.type(epoch) ~= 'integer' or epoch < 1 then
        return nil, nil, Foundation.domainError('VALIDATION_FAILED',
            'The resource owner context is invalid.')
    end
    if requestedOwner ~= nil and requestedOwner ~= owner then
        return nil, nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'A resource cannot register Groups definitions for another owner.')
    end
    return owner, epoch, nil
end

local function registerOwned(registry, owner, epoch, key, value)
    local _, lookupError, metadata = registry:get(key)
    if metadata then
        if metadata.owner ~= owner then
            return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
                'The registry key is owned by another resource.')
        end
        local removed, removeError = registry:remove(
            metadata.owner, metadata.epoch, key, metadata.token)
        if not removed then
            return nil, removeError or Foundation.domainError('CONCURRENT_MODIFICATION',
                'The registry entry changed while it was being replaced.', true)
        end
    elseif lookupError and lookupError.code ~= 'REGISTRY_KEY_NOT_FOUND' then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The registry key is invalid.')
    end
    local registered, registrationError = registry:register(owner, epoch, key, value)
    if not registered then
        return nil, registrationError or Foundation.domainError('CONCURRENT_MODIFICATION',
            'The registry entry could not be installed.', true)
    end
    return registered, nil
end

return {
    POLICY_EFFECTS = POLICY_EFFECTS,
    POLICY_STATUS = POLICY_STATUS,
    POLICY_SUBJECTS = POLICY_SUBJECTS,
    POLICY_SCOPES = POLICY_SCOPES,
    ATTRIBUTE_TYPES = ATTRIBUTE_TYPES,
    ATTRIBUTE_VISIBILITY = ATTRIBUTE_VISIBILITY,
    DEFINITION_KINDS = DEFINITION_KINDS,
    MAXIMUM_TRACE_ITEMS = MAXIMUM_TRACE_ITEMS,
    rejected = rejected,
    isObject = isObject,
    arrayLength = arrayLength,
    closedObject = closedObject,
    publicId = publicId,
    activeGroup = activeGroup,
    reason = reason,
    canonical = canonical,
    copyJson = copyJson,
    scopeName = scopeName,
    boundedTrace = boundedTrace,
    capabilityResult = capabilityResult,
    scalarEquals = scalarEquals,
    ownerContext = ownerContext,
    registerOwned = registerOwned,
}
end
