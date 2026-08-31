SynexInteractCompiler = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')
local Compiler = SynexInteractCompiler

local bindingTypes = {
    worldAnchor = true,
    worldRef = true,
    entityRef = true,
    entityArchetype = true,
    entityBone = true,
    staticTransform = true,
    dynamic = true,
}

local slotStates = { FREE = true, DISABLED = true }
local triggers = { primary = true, secondary = true, automatic = true }
local participantLossPolicies = { ABORT = true, CONTINUE = true, REPLACE = true }
local graphTypes = {
    sequence = true, branch = true, parallel = true, race = true,
    barrier = true, timeout = true, retry = true, wait = true,
    verifyLease = true, verifyContext = true, verifyTarget = true,
    verifyPolicy = true, faceTarget = true, moveToSlot = true,
    animation = true, scenario = true, progress = true, sound = true,
    interactionCue = true, serviceCall = true, contractCall = true,
    awaitEvent = true, participantBarrier = true, stopAnimation = true,
    releaseSlot = true, releaseLease = true, releaseLocks = true,
    removeTemporaryEntity = true, commit = true, complete = true, fail = true,
}

local presentationTypes = {
    faceTarget = true, moveToSlot = true, animation = true, scenario = true,
    progress = true, sound = true, interactionCue = true, stopAnimation = true,
}
local progressModes = { determinate = true, indeterminate = true, timed = true }

local terminalTypes = { complete = true, fail = true }
local cleanupNodes = {
    stopAnimation = true, releaseSlot = true, releaseLease = true,
    releaseLocks = true, removeTemporaryEntity = true,
}

local cancellationBooleanKeys = {
    'cancelOnMove', 'cancelOnDamage', 'cancelOnDeath', 'cancelOnRagdoll',
    'cancelOnVehicleChange', 'cancelOnTargetMove', 'cancelOnTargetLoss',
    'cancelOnWorldChange',
}
local cancellationOptionalKeys = {
    'cancelOnMove', 'cancelOnDamage', 'cancelOnDeath', 'cancelOnRagdoll',
    'cancelOnVehicleChange', 'cancelOnTargetMove', 'cancelOnTargetLoss',
    'cancelOnWorldChange', 'actorMoveDistance', 'targetMoveDistance',
    'cancelDistance', 'distanceHysteresis', 'distanceGraceMs',
    'targetLossGraceMs',
}
local cancellationDefaults = {
    cancelOnMove = false,
    cancelOnDamage = false,
    cancelOnDeath = false,
    cancelOnRagdoll = false,
    cancelOnVehicleChange = false,
    cancelOnTargetMove = false,
    cancelOnTargetLoss = false,
    cancelOnWorldChange = false,
}

local diagnosticCodes = {
    ['Interaction bundle keys must be unique and namespaced.'] = 'INTERACT_DUPLICATE_KEY',
    ['A Smart Object binding is invalid.'] = 'INTERACT_UNKNOWN_BINDING',
    ['World Anchor binding key is invalid.'] = 'INTERACT_BROKEN_REFERENCE',
    ['World reference binding is invalid.'] = 'INTERACT_BROKEN_REFERENCE',
    ['EntityRef binding is invalid.'] = 'INTERACT_BROKEN_REFERENCE',
    ['An interaction slot is invalid.'] = 'INTERACT_INVALID_SLOT',
    ['Interaction slot bounds are invalid.'] = 'INTERACT_INVALID_SLOT',
    ['Interaction slot tags are invalid.'] = 'INTERACT_INVALID_SLOT',
    ['A Smart Object requires at least one slot.'] = 'INTERACT_INVALID_SLOT',
    ['Smart Object slot keys must be unique.'] = 'INTERACT_SLOT_CONFLICT',
    ['Action Graph nodes are invalid or duplicated.'] = 'INTERACT_DUPLICATE_KEY',
    ['Action Graph entry is missing.'] = 'INTERACT_GRAPH_MISSING_ENTRY',
    ['Action Graph contains a broken node reference.'] = 'INTERACT_BROKEN_REFERENCE',
    ['Action Graph cleanup references must begin with a cleanup-safe node.'] =
        'INTERACT_MISSING_CLEANUP',
    ['Unbounded Action Graph cycles are forbidden.'] = 'INTERACT_GRAPH_CYCLE',
    ['Action Graph contains an unreachable node.'] = 'INTERACT_UNREACHABLE_NODE',
    ['Smart Object activity references are invalid.'] = 'INTERACT_BROKEN_REFERENCE',
    ['Intent object, slot or graph references are invalid.'] = 'INTERACT_BROKEN_REFERENCE',
    ['Intent participant slot reference is invalid.'] = 'INTERACT_INVALID_SLOT',
}

local function invalid(message, details, diagnosticCode)
    local normalized = Validation.copy(details or {}) or {}
    normalized.diagnosticCode = diagnosticCode or diagnosticCodes[message]
        or 'INTERACT_BUNDLE_REJECTED'
    return Validation.failure('INTERACT_BUNDLE_INVALID', message, false, normalized)
end

local function compileCancellationPolicy(value)
    if value == nil then return {}, nil end
    if not Validation.exactObject(value, {}, cancellationOptionalKeys) then
        return invalid('An interaction cancellation policy is invalid.')
    end
    for _, key in ipairs(cancellationBooleanKeys) do
        if value[key] ~= nil and type(value[key]) ~= 'boolean' then
            return invalid('Interaction cancellation flags must be boolean.', { field = key })
        end
    end
    if value.actorMoveDistance ~= nil and (not Validation.isFinite(value.actorMoveDistance)
            or value.actorMoveDistance < 0.05
            or value.actorMoveDistance > Limits.maximumAuthorityDistance)
        or value.targetMoveDistance ~= nil and (not Validation.isFinite(value.targetMoveDistance)
            or value.targetMoveDistance < 0.05
            or value.targetMoveDistance > Limits.maximumAuthorityDistance)
        or value.cancelDistance ~= nil and (not Validation.isFinite(value.cancelDistance)
            or value.cancelDistance < 0.25
            or value.cancelDistance > Limits.maximumAuthorityDistance)
        or value.distanceHysteresis ~= nil and (not Validation.isFinite(value.distanceHysteresis)
            or value.distanceHysteresis < 0 or value.distanceHysteresis > 5)
        or value.distanceGraceMs ~= nil
            and not Validation.isInteger(value.distanceGraceMs, 0, 10000)
        or value.targetLossGraceMs ~= nil
            and not Validation.isInteger(value.targetLossGraceMs, 0, 10000) then
        return invalid('Interaction cancellation policy bounds are invalid.')
    end
    return Validation.copy(value), nil
end

local function compileAvailabilityPolicy(value)
    value = value or {}
    if not Validation.exactObject(value, {}, { 'enabled', 'evaluator', 'arguments' })
        or value.enabled ~= nil and type(value.enabled) ~= 'boolean'
        or value.evaluator ~= nil and not Validation.identifier(value.evaluator)
        or value.arguments ~= nil and not Validation.isPlainTable(value.arguments) then
        return invalid('An interaction availability policy is invalid.')
    end
    local arguments = Validation.copy(value.arguments or {})
    if arguments == nil then return invalid('Interaction availability arguments are invalid.') end
    return {
        enabled = value.enabled ~= false,
        evaluator = value.evaluator,
        arguments = arguments,
    }, nil
end

local function compileConcurrencyPolicy(value)
    value = value or {}
    if not Validation.exactObject(value, {}, { 'mode' })
        or value.mode ~= nil and value.mode ~= 'slot'
            and value.mode ~= 'exclusive' then
        return invalid('A Smart Object concurrency policy is invalid.')
    end
    return { mode = value.mode or 'slot' }, nil
end

local function mergedCancellationPolicy(graphPolicy, intentPolicy, maximumDistance)
    local result = Validation.copy(cancellationDefaults)
    for key, value in pairs(graphPolicy or {}) do result[key] = value end
    for key, value in pairs(intentPolicy or {}) do result[key] = value end
    if result.cancelOnMove and result.actorMoveDistance == nil then
        result.actorMoveDistance = 0.75
    end
    if result.cancelOnTargetMove and result.targetMoveDistance == nil then
        result.targetMoveDistance = 0.50
    end
    if result.cancelOnTargetLoss and result.targetLossGraceMs == nil then
        result.targetLossGraceMs = 500
    end
    if result.cancelDistance ~= nil then
        if result.distanceHysteresis == nil then
            local authorityDistance = maximumDistance or Limits.maximumAuthorityDistance
            result.distanceHysteresis = math.min(0.25,
                result.cancelDistance * 0.25,
                math.max(0, authorityDistance - result.cancelDistance))
        end
        if result.distanceGraceMs == nil then result.distanceGraceMs = 250 end
        if result.distanceHysteresis >= result.cancelDistance then
            return invalid('Cancellation distance hysteresis must be smaller than its distance.')
        end
        if result.cancelDistance + result.distanceHysteresis
            > (maximumDistance or Limits.maximumAuthorityDistance) then
            return invalid('Cancellation distance and hysteresis cannot exceed the authoritative maximum distance.')
        end
    elseif intentPolicy and (intentPolicy.distanceHysteresis ~= nil
            or intentPolicy.distanceGraceMs ~= nil)
        or graphPolicy and (graphPolicy.distanceHysteresis ~= nil
            or graphPolicy.distanceGraceMs ~= nil) then
        return invalid('Cancellation distance tuning requires cancelDistance.')
    end
    return result, nil
end

local function keyedArray(value, maximum, keyName, validator)
    local items = Validation.array(value, maximum)
    if not items then return invalid('An interaction bundle collection is invalid.') end
    local result, order = {}, {}
    for _, item in ipairs(items) do
        if not Validation.isPlainTable(item) or not Validation.identifier(item[keyName])
            or result[item[keyName]] ~= nil then
            return invalid('Interaction bundle keys must be unique and namespaced.')
        end
        local normalized, itemError = validator(item)
        if not normalized then return nil, itemError end
        result[normalized[keyName]] = normalized
        order[#order + 1] = normalized[keyName]
    end
    table.sort(order)
    return result, order
end

local function compileBinding(value)
    if not Validation.exactObject(value, { 'type' }, {
        'key', 'entityId', 'generation', 'archetype', 'model', 'bone',
        'position', 'heading', 'provider', 'bindingKey', 'tags', 'kind',
    }) or not bindingTypes[value.type] then
        return invalid('A Smart Object binding is invalid.')
    end
    if value.type == 'worldAnchor' then
        if not Validation.identifier(value.key) then return invalid('World Anchor binding key is invalid.') end
    elseif value.type == 'worldRef' then
        if (value.kind ~= 'anchor' and value.kind ~= 'door' and value.kind ~= 'portal')
            or not Validation.identifier(value.key) then
            return invalid('World reference binding is invalid.')
        end
    elseif value.type == 'entityRef' then
        if not Validation.token(value.entityId, 8, 64)
            or not Validation.isInteger(value.generation, 1) then
            return invalid('EntityRef binding is invalid.')
        end
    elseif value.type == 'entityArchetype' or value.type == 'entityBone' then
        if value.archetype ~= nil and not Validation.semanticKey(value.archetype)
            or value.model ~= nil and not Validation.isInteger(value.model, 0, 4294967295)
            or value.archetype == nil and value.model == nil then
            return invalid('Entity archetype binding is invalid.', nil,
                'INTERACT_INVALID_ENTITY_ARCHETYPE')
        end
        if value.type == 'entityBone' and not Validation.text(value.bone, 1, 64) then
            return invalid('Entity bone binding is invalid.', nil,
                'INTERACT_INVALID_BONE')
        end
    elseif value.type == 'staticTransform' then
        if not Validation.vector3(value.position)
            or value.heading ~= nil and not Validation.isFinite(value.heading) then
            return invalid('Static transform binding is invalid.')
        end
    elseif value.type == 'dynamic' then
        if not Validation.identifier(value.provider)
            or not Validation.token(value.bindingKey, 3, 128) then
            return invalid('Dynamic binding is invalid.')
        end
    end
    local tags = value.tags or {}
    if not Validation.array(tags, 16, function(tag) return Validation.semanticKey(tag, 64) end) then
        return invalid('Binding tags are invalid.')
    end
    return Validation.copy(value), nil
end

local function compileSlot(value)
    if not Validation.exactObject(value, { 'key' }, {
        'localTransform', 'approachTransform', 'interactionRadius',
        'facingTolerance', 'tags', 'capacity', 'initialState', 'availabilityPolicy',
    }) or not Validation.text(value.key, 1, 64)
        or value.key:match('^[a-z][a-zA-Z0-9_.%-]*$') == nil then
        return invalid('An interaction slot is invalid.')
    end
    local function transform(candidate)
        if not Validation.exactObject(candidate, { 'position' }, { 'heading' })
            or not Validation.vector3(candidate.position)
            or candidate.heading ~= nil and not Validation.isFinite(candidate.heading) then return nil end
        return Validation.copy(candidate)
    end
    if value.localTransform ~= nil and not transform(value.localTransform)
        or value.approachTransform ~= nil and not transform(value.approachTransform)
        or value.interactionRadius ~= nil and (not Validation.isFinite(value.interactionRadius)
            or value.interactionRadius < 0.25 or value.interactionRadius > Limits.maximumAuthorityDistance)
        or value.facingTolerance ~= nil and (not Validation.isFinite(value.facingTolerance)
            or value.facingTolerance < 0 or value.facingTolerance > 180)
        or value.capacity ~= nil and not Validation.isInteger(value.capacity, 1, 32)
        or value.initialState ~= nil and not slotStates[value.initialState] then
        return invalid('Interaction slot bounds are invalid.')
    end
    if value.tags ~= nil and not Validation.array(value.tags, 16,
        function(tag) return Validation.semanticKey(tag, 64) end) then
        return invalid('Interaction slot tags are invalid.')
    end
    local availabilityPolicy, availabilityError =
        compileAvailabilityPolicy(value.availabilityPolicy)
    if not availabilityPolicy then return nil, availabilityError end
    return {
        key = value.key,
        localTransform = transform(value.localTransform or {
            position = { x = 0.0, y = 0.0, z = 0.0 },
        }),
        approachTransform = value.approachTransform and transform(value.approachTransform) or nil,
        interactionRadius = value.interactionRadius or 2.0,
        facingTolerance = value.facingTolerance or 90.0,
        tags = Validation.copy(value.tags or {}),
        capacity = value.capacity or 1,
        initialState = value.initialState or 'FREE',
        availabilityPolicy = availabilityPolicy,
    }, nil
end

local function compileObject(value)
    if not Validation.exactObject(value, { 'key', 'binding', 'slots', 'activities' }, {
        'tags', 'availabilityPolicy', 'concurrencyPolicy', 'presentation',
    }) then return invalid('A Smart Object definition is invalid.') end
    local binding, bindingError = compileBinding(value.binding)
    if not binding then return nil, bindingError end
    local slots, slotOrder = {}, {}
    local slotItems = Validation.array(value.slots, Limits.maximumSlotsPerObject)
    if not slotItems or #slotItems == 0 then return invalid('A Smart Object requires at least one slot.') end
    for _, slotValue in ipairs(slotItems) do
        local slot, slotError = compileSlot(slotValue)
        if not slot then return nil, slotError end
        if slots[slot.key] then return invalid('Smart Object slot keys must be unique.') end
        slots[slot.key], slotOrder[#slotOrder + 1] = slot, slot.key
    end
    table.sort(slotOrder)
    local activities = Validation.array(value.activities, Limits.maximumActivitiesPerObject,
        function(key) return Validation.identifier(key) end)
    if not activities or #activities == 0 then
        return invalid('A Smart Object requires at least one activity.')
    end
    local tags = Validation.array(value.tags or {}, 32,
        function(tag) return Validation.semanticKey(tag, 64) end)
    if not tags then return invalid('Smart Object tags are invalid.') end
    local availabilityPolicy, availabilityError =
        compileAvailabilityPolicy(value.availabilityPolicy)
    if not availabilityPolicy then return nil, availabilityError end
    local concurrencyPolicy, concurrencyError =
        compileConcurrencyPolicy(value.concurrencyPolicy)
    if not concurrencyPolicy then return nil, concurrencyError end
    return {
        key = value.key, binding = binding, slots = slots, slotOrder = slotOrder,
        activities = Validation.copy(activities), tags = Validation.copy(tags),
        availabilityPolicy = availabilityPolicy,
        concurrencyPolicy = concurrencyPolicy,
        presentation = Validation.copy(value.presentation or {}),
    }, nil
end

local function compileCondition(value)
    if not Validation.exactObject(value, { 'kind' }, { 'path', 'operator', 'value', 'evaluator', 'arguments' }) then
        return invalid('An interaction condition is invalid.')
    end
    if value.kind == 'declarative' then
        if not Validation.text(value.path, 3, 128)
            or not ({ eq = true, ne = true, lt = true, lte = true, gt = true,
                gte = true, truthy = true, falsy = true, contains = true })[value.operator] then
            return invalid('A declarative interaction condition is invalid.')
        end
    elseif value.kind == 'evaluator' then
        if not Validation.identifier(value.evaluator) then
            return invalid('A custom condition evaluator reference is invalid.')
        end
    else return invalid('An interaction condition kind is unsupported.') end
    return Validation.copy(value), nil
end

local function compileIntent(value)
    if not Validation.exactObject(value, {
        'key', 'smartObjectKey', 'verb', 'label', 'basePriority', 'trigger',
        'visibilityConditions', 'executionPolicy', 'actionGraphRef', 'presentation',
    }, { 'slotSelector', 'icon', 'specificity', 'participants' })
        or not Validation.identifier(value.smartObjectKey)
        or not Validation.text(value.verb, 1, 48)
        or not Validation.text(value.label, 1, 96)
        or not Validation.isFinite(value.basePriority) or value.basePriority < -100
        or value.basePriority > 100 or not triggers[value.trigger]
        or not Validation.identifier(value.actionGraphRef) then
        return invalid('An intent definition is invalid.')
    end
    if value.slotSelector ~= nil and (not Validation.text(value.slotSelector, 1, 64)
        or value.slotSelector:match('^[a-z][a-zA-Z0-9_.%-]*$') == nil) then
        return invalid('An intent slot selector is invalid.')
    end
    local rawConditions = Validation.array(value.visibilityConditions,
        Limits.maximumConditionsPerIntent)
    if not rawConditions then return invalid('Intent visibility conditions are invalid.') end
    local conditions = {}
    for index, raw in ipairs(rawConditions) do
        local condition, conditionError = compileCondition(raw)
        if not condition then return nil, conditionError end
        conditions[index] = condition
    end
    local policy = value.executionPolicy
    if not Validation.exactObject(policy, {}, {
        'requiredCapability', 'maximumDistance', 'managedOnly', 'leaseTtlMs',
        'maximumLifetimeMs', 'lockChannels', 'cancel', 'privileged',
    }) or policy.requiredCapability ~= nil and not Validation.permission(policy.requiredCapability)
        or policy.maximumDistance ~= nil and (not Validation.isFinite(policy.maximumDistance)
            or policy.maximumDistance < 0.25 or policy.maximumDistance > Limits.maximumAuthorityDistance)
        or policy.leaseTtlMs ~= nil and not Validation.isInteger(policy.leaseTtlMs, 500, 10000)
        or policy.maximumLifetimeMs ~= nil and not Validation.isInteger(
            policy.maximumLifetimeMs, 1000, Limits.leaseMaximumLifetimeMs)
        or policy.lockChannels ~= nil and not Validation.array(policy.lockChannels,
            Limits.maximumLocksPerGraph, function(channel)
                return type(channel) == 'string' and ({
                    ['actor.movement'] = true, ['actor.hands'] = true,
                    ['actor.weapon'] = true, ['actor.fullbody'] = true,
                    ['actor.camera'] = true, ['actor.input'] = true,
                    ['ui.primary'] = true,
                })[channel] == true
            end) then return invalid('Intent execution policy is invalid.') end
    local cancellation, cancellationError = compileCancellationPolicy(policy.cancel)
    if not cancellation then return nil, cancellationError end
    local compiledPolicy = Validation.copy(policy)
    compiledPolicy.cancel = cancellation
    local participants = value.participants or {
        { role = 'operator', required = true, slotKey = value.slotSelector },
    }
    if not Validation.array(participants, Limits.maximumParticipants, function(participant)
        return Validation.exactObject(participant, { 'role', 'required' }, {
            'slotKey', 'capacity', 'lossPolicy', 'lateJoin',
        }) and Validation.text(participant.role, 1, 32)
            and type(participant.required) == 'boolean'
            and (participant.lateJoin == nil or type(participant.lateJoin) == 'boolean')
            and not (participant.required and participant.lateJoin == true)
            and (participant.slotKey == nil or Validation.text(participant.slotKey, 1, 64))
            and (participant.capacity == nil or Validation.isInteger(participant.capacity, 1, 8))
            and (participant.lossPolicy == nil or participantLossPolicies[participant.lossPolicy])
    end) then return invalid('Intent participant policy is invalid.') end
    local roleNames, participantCapacity, requiredRoles = {}, 0, 0
    for _, participant in ipairs(participants) do
        if roleNames[participant.role] then
            return invalid('Intent participant roles must be unique.')
        end
        roleNames[participant.role] = true
        participantCapacity = participantCapacity + (participant.capacity or 1)
        if participant.required then requiredRoles = requiredRoles + 1 end
    end
    if participantCapacity > Limits.maximumSessionParticipants or requiredRoles == 0 then
        return invalid('Intent participant capacity exceeds the session bound.')
    end
    return {
        key = value.key, smartObjectKey = value.smartObjectKey,
        verb = value.verb, label = value.label, icon = value.icon,
        basePriority = value.basePriority, specificity = value.specificity or 0,
        trigger = value.trigger, slotSelector = value.slotSelector,
        visibilityConditions = conditions,
        executionPolicy = compiledPolicy,
        actionGraphRef = value.actionGraphRef,
        presentation = Validation.copy(value.presentation),
        participants = Validation.copy(participants),
    }, nil
end

local function compileGraph(value)
    if not Validation.exactObject(value, { 'key', 'entry', 'nodes' }, {
        'locks', 'timeoutMs', 'cancelPolicy', 'participantLossPolicy',
    }) or not Validation.text(value.entry, 1, 64)
        or value.timeoutMs ~= nil and not Validation.isInteger(
            value.timeoutMs, 100, Limits.graphMaximumTimeoutMs)
        or value.locks ~= nil and not Validation.array(value.locks,
            Limits.maximumLocksPerGraph, function(channel)
                return type(channel) == 'string' and #channel <= 64
            end) then return invalid('An Action Graph definition is invalid.') end
    local cancellation, cancellationError = compileCancellationPolicy(value.cancelPolicy)
    if not cancellation then return nil, cancellationError end
    local nodes, order = {}, {}
    local items = Validation.array(value.nodes, Limits.maximumGraphNodes)
    if not items or #items == 0 then return invalid('An Action Graph requires nodes.') end
    for _, raw in ipairs(items) do
        if not Validation.exactObject(raw, { 'key', 'type' }, {
            'next', 'children', 'thenNode', 'elseNode', 'condition', 'durationMs',
            'timeoutMs', 'maxAttempts', 'backoffMs', 'retryableErrors', 'adapter',
            'service', 'version', 'method', 'request', 'contract', 'presentation',
            'roles', 'commitKey', 'code', 'cleanup',
        }) or not Validation.text(raw.key, 1, 64)
            or raw.key:match('^[A-Za-z][A-Za-z0-9_.%-]*$') == nil
            or not graphTypes[raw.type] or nodes[raw.key] then
            return invalid('Action Graph nodes are invalid or duplicated.')
        end
        if raw.next ~= nil and not Validation.text(raw.next, 1, 64)
            or raw.children ~= nil and not Validation.array(raw.children,
                Limits.maximumGraphBranches, function(key) return Validation.text(key, 1, 64) end)
            or raw.type == 'wait' and not Validation.isInteger(raw.durationMs, 0, 60000)
            or raw.type == 'progress' and raw.durationMs ~= nil
                and not Validation.isInteger(raw.durationMs, 0, 60000)
            or raw.type == 'timeout' and not Validation.isInteger(
                raw.timeoutMs, 100, Limits.graphMaximumTimeoutMs)
            or raw.timeoutMs ~= nil and (raw.type == 'serviceCall'
                    or raw.type == 'contractCall' or raw.type == 'awaitEvent'
                    or raw.type == 'commit' or raw.type == 'removeTemporaryEntity')
                and not Validation.isInteger(raw.timeoutMs, 1,
                    Limits.graphMaximumTimeoutMs)
            or (raw.type == 'serviceCall' or raw.type == 'contractCall'
                    or raw.type == 'awaitEvent' or raw.type == 'removeTemporaryEntity')
                and not Validation.identifier(raw.adapter)
            or raw.service ~= nil and not Validation.apiName(raw.service)
            or raw.method ~= nil and not Validation.methodName(raw.method)
            or raw.contract ~= nil and not Validation.apiName(raw.contract)
            or raw.version ~= nil and type(raw.version) ~= 'string'
                and not Validation.isInteger(raw.version, 1, 1000)
            or type(raw.version) == 'string' and (not Validation.text(raw.version, 1, 64)
                or raw.version:match('^[0-9]+%.[0-9]+%.[0-9]+$') == nil)
            or raw.retryableErrors ~= nil and not Validation.array(raw.retryableErrors, 32,
                function(code) return Validation.errorCode(code) end)
            or raw.roles ~= nil and not Validation.array(raw.roles,
                Limits.maximumParticipants, function(role)
                    return Validation.text(role, 1, 32)
                end)
            or raw.commitKey ~= nil and not Validation.token(raw.commitKey, 3, 128)
            or raw.code ~= nil and not Validation.errorCode(raw.code)
            or presentationTypes[raw.type] and not Validation.isPlainTable(raw.presentation or {}) then
            return invalid('An Action Graph node policy is invalid.', { node = raw.key })
        end
        if raw.type == 'retry' and (not Validation.isInteger(
                raw.maxAttempts, 1, Limits.maximumRetryAttempts)
            or raw.backoffMs ~= nil
                and not Validation.isInteger(raw.backoffMs, 0, 10000)) then
            return invalid('Action Graph retries must be explicitly bounded.',
                { node = raw.key }, 'INTERACT_UNBOUNDED_RETRY')
        end
        if (raw.type == 'sequence' or raw.type == 'parallel' or raw.type == 'race')
                and (raw.children == nil or #raw.children == 0)
            or (raw.type == 'retry' or raw.type == 'timeout')
                and (raw.children == nil or #raw.children ~= 1)
            or raw.type == 'branch' and (raw.thenNode == nil or raw.elseNode == nil
                or not Validation.isPlainTable(raw.condition))
            or raw.type == 'serviceCall' and (raw.service == nil
                or raw.version == nil or raw.method == nil)
            or raw.type == 'contractCall' and raw.contract == nil
            or raw.type == 'awaitEvent' and (raw.contract == nil or raw.timeoutMs == nil)
            or terminalTypes[raw.type] and raw.next ~= nil then
            return invalid('An Action Graph control node is incomplete.', { node = raw.key })
        end
        local normalized = Validation.copy(raw)
        if raw.type == 'progress' then
            local presentation = raw.presentation or {}
            if not Validation.exactObject(presentation, {}, {
                    'label', 'text', 'mode', 'value', 'maximum', 'durationMs',
                    'cancellable',
                })
                or presentation.label ~= nil
                    and not Validation.text(presentation.label, 1, 120)
                or presentation.text ~= nil
                    and not Validation.text(presentation.text, 1, 120)
                or presentation.label ~= nil and presentation.text ~= nil
                or presentation.mode ~= nil and not progressModes[presentation.mode]
                or presentation.cancellable ~= nil
                    and type(presentation.cancellable) ~= 'boolean'
                or presentation.durationMs ~= nil
                    and not Validation.isInteger(presentation.durationMs, 1, 60000)
                or raw.durationMs ~= nil and presentation.durationMs ~= nil
                    and raw.durationMs ~= presentation.durationMs then
                return invalid('An Action Graph progress presentation is invalid.', {
                    node = raw.key,
                })
            end
            local mode = presentation.mode
                or ((raw.durationMs or presentation.durationMs or 0) > 0
                    and 'timed' or 'indeterminate')
            local duration = raw.durationMs or presentation.durationMs or 0
            if mode == 'determinate' and (not Validation.isFinite(presentation.value)
                    or not Validation.isFinite(presentation.maximum)
                    or presentation.maximum <= 0
                    or presentation.maximum > Limits.maximumSafeInteger
                    or presentation.value < 0
                    or presentation.value > presentation.maximum)
                or mode ~= 'determinate'
                    and (presentation.value ~= nil or presentation.maximum ~= nil)
                or mode == 'timed' and duration < 1 then
                return invalid('An Action Graph progress presentation is invalid.', {
                    node = raw.key,
                })
            end
            normalized.presentation = Validation.copy(presentation) or {}
            normalized.presentation.mode = mode
        end
        if raw.type == 'branch' then
            local condition, conditionError = compileCondition(raw.condition)
            if not condition then return nil, conditionError end
            normalized.condition = condition
        end
        nodes[raw.key] = normalized
        order[#order + 1] = raw.key
    end
    if not nodes[value.entry] then return invalid('Action Graph entry is missing.') end
    local references = {}
    local function addReference(from, to)
        if to ~= nil then references[#references + 1] = { from = from, to = to } end
    end
    for _, key in ipairs(order) do
        local node = nodes[key]
        addReference(key, node.next)
        addReference(key, node.thenNode)
        addReference(key, node.elseNode)
        for _, child in ipairs(node.children or {}) do addReference(key, child) end
        if node.cleanup ~= nil then addReference(key, node.cleanup) end
    end
    for _, reference in ipairs(references) do
        if not nodes[reference.to] then
            return invalid('Action Graph contains a broken node reference.', reference)
        end
    end
    for _, key in ipairs(order) do
        local cleanup = nodes[key].cleanup
        if cleanup ~= nil and not cleanupNodes[nodes[cleanup].type]
            and nodes[cleanup].type ~= 'sequence' then
            return invalid('Action Graph cleanup references must begin with a cleanup-safe node.', {
                node = key, cleanup = cleanup,
            })
        end
    end
    local visiting, visited, reachable = {}, {}, {}
    local function walk(key, depth)
        if depth > Limits.maximumGraphDepth then return nil, 'depth' end
        if visiting[key] then return nil, 'cycle' end
        if visited[key] then return true end
        visiting[key], reachable[key] = true, true
        local node = nodes[key]
        local targets = {}
        if node.next then targets[#targets + 1] = node.next end
        if node.thenNode then targets[#targets + 1] = node.thenNode end
        if node.elseNode then targets[#targets + 1] = node.elseNode end
        for _, child in ipairs(node.children or {}) do targets[#targets + 1] = child end
        if node.cleanup then targets[#targets + 1] = node.cleanup end
        for _, target in ipairs(targets) do
            local ok, reason = walk(target, depth + 1)
            if not ok then return nil, reason end
        end
        visiting[key], visited[key] = nil, true
        return true
    end
    local valid, reason = walk(value.entry, 1)
    if not valid then return invalid(reason == 'cycle'
        and 'Unbounded Action Graph cycles are forbidden.'
        or 'Action Graph depth exceeds its bound.') end
    for _, key in ipairs(order) do
        if not reachable[key] then return invalid('Action Graph contains an unreachable node.', { node = key }) end
    end

    local flowMemo = {}
    local analyzeFlow
    local function mergeFlow(target, source)
        if source.complete then target.complete = true end
        if source.failed then target.failed = true end
        if source.normal then target.normal = true end
    end
    local function followNext(flow, nextKey)
        local result = { complete = flow.complete == true, failed = flow.failed == true }
        if flow.normal then
            if nextKey then mergeFlow(result, analyzeFlow(nextKey))
            else result.normal = true end
        end
        return result
    end
    analyzeFlow = function(key)
        if flowMemo[key] then return flowMemo[key] end
        local node, flow = nodes[key], {}
        if node.type == 'complete' then
            flow.complete = true
        elseif node.type == 'fail' then
            flow.failed = true
        elseif node.type == 'sequence' then
            flow.normal = true
            for _, child in ipairs(node.children or {}) do
                if flow.normal then
                    flow.normal = nil
                    mergeFlow(flow, analyzeFlow(child))
                end
            end
        elseif node.type == 'branch' then
            mergeFlow(flow, analyzeFlow(node.thenNode))
            mergeFlow(flow, analyzeFlow(node.elseNode))
        elseif node.type == 'parallel' then
            flow.normal = true
            for _, child in ipairs(node.children or {}) do
                local childFlow = analyzeFlow(child)
                if childFlow.complete then flow.complete = true end
                if childFlow.failed then flow.failed = true end
                if not childFlow.normal then flow.normal = nil end
            end
        elseif node.type == 'race' then
            local everyChildCanFail = true
            for _, child in ipairs(node.children or {}) do
                local childFlow = analyzeFlow(child)
                if childFlow.complete then flow.complete = true end
                if childFlow.normal then flow.normal = true end
                if not childFlow.failed then everyChildCanFail = false end
            end
            if everyChildCanFail then flow.failed = true end
        elseif node.type == 'retry' or node.type == 'timeout' then
            mergeFlow(flow, analyzeFlow(node.children[1]))
            if node.type == 'timeout' then flow.failed = true end
        else
            flow.normal = true
        end
        local result = followNext(flow, node.next)
        flowMemo[key] = result
        return result
    end
    local rootFlow = analyzeFlow(value.entry)
    if rootFlow.normal then
        return invalid('Every successful Action Graph path must reach an explicit complete terminal.')
    end
    if not rootFlow.complete and not rootFlow.failed then
        return invalid('Action Graph requires a reachable runtime terminal node.')
    end
    table.sort(order)
    return {
        key = value.key, entry = value.entry, nodes = nodes, nodeOrder = order,
        locks = Validation.copy(value.locks or {}),
        timeoutMs = value.timeoutMs or Limits.graphMaximumTimeoutMs,
        cancelPolicy = cancellation,
        participantLossPolicy = value.participantLossPolicy or 'ABORT',
    }, nil
end

function Compiler.compile(value, owner, ownerEpoch)
    if not Validation.resourceName(owner) or not Validation.isInteger(ownerEpoch, 1)
        or not Validation.exactObject(value, {
            'schemaVersion', 'key', 'revision', 'smartObjects', 'intents', 'graphs',
        }, { 'metadata' }) or value.schemaVersion ~= 1
        or not Validation.identifier(value.key)
        or not Validation.isInteger(value.revision, 1) then
        return invalid('Interaction bundle identity is invalid.')
    end
    if value.key:sub(1, #owner + 1) ~= owner .. ':' then
        return invalid('Interaction bundle keys must use their owner namespace.')
    end
    local objects, objectOrder = keyedArray(value.smartObjects,
        Limits.maximumBundleSmartObjects, 'key', compileObject)
    if not objects then return nil, objectOrder end
    local intents, intentOrder = keyedArray(value.intents,
        Limits.maximumBundleIntents, 'key', compileIntent)
    if not intents then return nil, intentOrder end
    local graphs, graphOrder = keyedArray(value.graphs,
        Limits.maximumBundleGraphs, 'key', compileGraph)
    if not graphs then return nil, graphOrder end
    for _, key in ipairs(objectOrder) do
        local object = objects[key]
        if object.binding.type == 'dynamic'
            and object.binding.provider:sub(1, #owner + 1) ~= owner .. ':' then
            return invalid('Dynamic bindings must use a provider owned by their bundle resource.', {
                smartObject = object.key, provider = object.binding.provider,
            })
        end
        for _, policy in ipairs((function()
            local values = { object.availabilityPolicy }
            for _, slotKey in ipairs(object.slotOrder) do
                values[#values + 1] = object.slots[slotKey].availabilityPolicy
            end
            return values
        end)()) do
            if policy.evaluator ~= nil
                and policy.evaluator:sub(1, #owner + 1) ~= owner .. ':' then
                return invalid('Availability evaluators must use their bundle owner namespace.', {
                    smartObject = object.key, evaluator = policy.evaluator,
                })
            end
        end
        for _, intentKey in ipairs(object.activities) do
            local intent = intents[intentKey]
            if not intent or intent.smartObjectKey ~= object.key then
                return invalid('Smart Object activity references are invalid.', {
                    smartObject = object.key, intent = intentKey,
                })
            end
        end
    end
    for _, key in ipairs(intentOrder) do
        local intent, object = intents[key], objects[intents[key].smartObjectKey]
        local graph = graphs[intent.actionGraphRef]
        if not object or not graph
            or intent.slotSelector ~= nil and object.slots[intent.slotSelector] == nil then
            return invalid('Intent object, slot or graph references are invalid.', { intent = key })
        end
        for _, participant in ipairs(intent.participants) do
            local slotKey = participant.slotKey or intent.slotSelector
            if slotKey ~= nil and object.slots[slotKey] == nil then
                return invalid('Intent participant slot reference is invalid.', {
                    intent = key, role = participant.role,
                })
            end
        end
        local cancelPolicy, cancelError = mergedCancellationPolicy(graph.cancelPolicy,
            intent.executionPolicy.cancel, intent.executionPolicy.maximumDistance)
        if not cancelPolicy then return nil, cancelError end
        intent.executionPolicy.cancel = Validation.copy(intent.executionPolicy.cancel or {})
        intent.cancelPolicy = cancelPolicy
        for _, condition in ipairs(intent.visibilityConditions) do
            if condition.kind == 'evaluator'
                and condition.evaluator:sub(1, #owner + 1) ~= owner .. ':' then
                return invalid('Visibility evaluators must use their bundle owner namespace.', {
                    intent = key, evaluator = condition.evaluator,
                })
            end
        end
    end
    for _, graphKey in ipairs(graphOrder) do
        for _, nodeKey in ipairs(graphs[graphKey].nodeOrder) do
            local condition = graphs[graphKey].nodes[nodeKey].condition
            if condition and condition.kind == 'evaluator'
                and condition.evaluator:sub(1, #owner + 1) ~= owner .. ':' then
                return invalid('Graph evaluators must use their bundle owner namespace.', {
                    graph = graphKey, node = nodeKey, evaluator = condition.evaluator,
                })
            end
        end
    end
    local discovery = {}
    for _, objectKey in ipairs(objectOrder) do
        local object, projectedIntents = objects[objectKey], {}
        for _, intentKey in ipairs(object.activities) do
            local intent = intents[intentKey]
            projectedIntents[#projectedIntents + 1] = {
                key = intent.key, revision = value.revision, verb = intent.verb,
                label = intent.label, icon = intent.icon,
                basePriority = intent.basePriority, specificity = intent.specificity,
                trigger = intent.trigger, slotSelector = intent.slotSelector,
                visibilityConditions = Validation.copy(intent.visibilityConditions),
                cancelPolicy = Validation.copy(intent.cancelPolicy),
                presentation = Validation.copy(intent.presentation),
            }
        end
        discovery[#discovery + 1] = {
            key = object.key, revision = value.revision,
            binding = Validation.copy(object.binding), tags = Validation.copy(object.tags),
            slots = (function()
                local values = {}
                for _, slotKey in ipairs(object.slotOrder) do
                    local slot = object.slots[slotKey]
                    values[#values + 1] = {
                        key = slot.key, localTransform = Validation.copy(slot.localTransform),
                        interactionRadius = slot.interactionRadius,
                        facingTolerance = slot.facingTolerance,
                        tags = Validation.copy(slot.tags), initialState = slot.initialState,
                    }
                end
                return values
            end)(),
            intents = projectedIntents,
            presentation = Validation.copy(object.presentation),
        }
    end
    return {
        schemaVersion = 1, key = value.key, revision = value.revision,
        ownerResource = owner, ownerEpoch = ownerEpoch,
        objects = objects, objectOrder = objectOrder,
        intents = intents, intentOrder = intentOrder,
        graphs = graphs, graphOrder = graphOrder,
        discovery = discovery, metadata = Validation.copy(value.metadata or {}),
    }, nil
end

function Compiler.graphTypes() return Validation.copy(graphTypes) end
