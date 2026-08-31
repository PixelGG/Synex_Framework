local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local coreRef, ownerEpochs = {}, {}
local now = SynexInteractFoundation.monotonicClock(GetGameTimer)
local authority, entityProjection, bundleLoader
local TargetSelector = assert(SynexInteractTargetSelector,
    'interact target selector must be loaded first')

local function coreMethod(group, method, ...)
    local api = coreRef.value
    local namespace = type(api) == 'table' and api[group] or nil
    local handler = type(namespace) == 'table' and namespace[method] or nil
    if not SynexInteractFoundation.isCallable(handler) then
        return SynexInteractValidation.failure('INTERACT_UNAVAILABLE',
            'Synex Core is unavailable.', true)
    end
    return handler(...)
end

local function ownerCurrent(owner, epoch)
    return ownerEpochs[owner] == epoch and GetResourceState(owner) == 'started'
end

local registry = SynexInteractRegistry.create({
    compiler = SynexInteractCompiler,
    isOwnerCurrent = ownerCurrent,
    onChanged = function(_, _, owner, epoch, reason)
        if authority then
            if reason == 'replaced' or reason == 'unregistered'
                or reason == 'owner_stopped' then
                authority.revokeOwner(owner, epoch,
                    reason == 'replaced' and 'BUNDLE_REPLACED' or 'OWNER_CHANGED')
            end
            authority.reconcileSlots()
        end
    end,
})

local observability = SynexInteractObservability.create({
    foundation = SynexInteractFoundation, coreRef = coreRef, now = now,
    traceEnabled = GetConvarInt('synex_interact_trace', 0) == 1,
})
local slots = SynexInteractSlots.create({ now = now })
local locks = SynexInteractActorLocks.create()
local sessions = SynexInteractSessions.create({ now = now })

local function vector(value)
    if value == nil then return nil end
    return SynexInteractValidation.vector3({
        x = tonumber(value.x or value[1]), y = tonumber(value.y or value[2]),
        z = tonumber(value.z or value[3]),
    })
end

local function playerPosition(source)
    local ped = GetPlayerPed(source)
    if type(ped) ~= 'number' or ped <= 0 or not DoesEntityExist(ped) then
        return SynexInteractValidation.failure('INTERACT_LEASE_DENIED',
            'The interaction actor ped is unavailable.', true)
    end
    local position = vector(GetEntityCoords(ped))
    if not position then return SynexInteractValidation.failure('INTERACT_LEASE_DENIED',
        'The interaction actor position is unavailable.', true) end
    return position, nil
end

local worldAuthority = SynexInteractWorldAuthority.create({
    getWorld = function(reference, context)
        return coreMethod('Services', 'call', 'synex.world', '^1.0.0',
            'get', { ref = reference, kind = reference.kind },
            { traceId = context.traceId, timeoutMs = 2000 })
    end,
    getWorldContext = function(source, context)
        return coreMethod('Services', 'call', 'synex.world', '^1.0.0',
            'getContext', { source = source },
            { traceId = context.traceId, timeoutMs = 2000 })
    end,
    getSession = function(source)
        return coreMethod('Players', 'getBySource', source)
    end,
    getPlayerPosition = playerPosition,
})

local function sessionStillCurrent(actor)
    local session, sessionError = coreMethod('Players', 'getBySource', actor.source)
    if not session or session.state ~= 'ACTIVE' or session.id ~= actor.sessionIdentity
        or session.sourceGeneration ~= actor.sourceGeneration
        or session.characterId ~= actor.characterId then
        return SynexInteractValidation.failure('INTERACT_LEASE_STALE',
            'The interaction actor session changed.', false)
    end
    return session, sessionError
end

local function validateWorldTarget(resolved, target, actor, context)
    return worldAuthority.validate(resolved, target, actor, context)
end

local function validateManagedEntity(resolved, target, actor, context)
    local reference = target.entityRef
    local current, sessionError = sessionStillCurrent(actor)
    if not current then return nil, sessionError end
    local fencedContext = {
        source = actor.source, sourceGeneration = actor.sourceGeneration,
        session = current, traceId = context.traceId,
    }
    local binding = resolved.object.binding
    local maximumDistance = resolved.intent.executionPolicy.maximumDistance
        or SynexInteractLimits.maximumAuthorityDistance
    local canonical, canonicalError = entityProjection.resolveManaged(
        reference, maximumDistance, fencedContext)
    if not canonical then return nil, canonicalError end
    if not TargetSelector.matchesManaged(binding, target, canonical.entity) then
        return SynexInteractValidation.failure('INTERACT_TARGET_INVALID',
            'The managed entity does not match the Smart Object selector.')
    end
    local validated, validationError = coreMethod('RPC', 'call',
        'synex.entities.context.validate', '1.0.0', {
            source = actor.source,
            entity = { entityId = reference.entityId, generation = reference.generation },
            requirements = {
                sameBucket = true,
                maxDistance = resolved.intent.executionPolicy.maximumDistance
                    or SynexInteractLimits.maximumAuthorityDistance,
                -- Interaction tags describe affordances; Entity tags are a separate domain.
                tags = {}, components = {},
            },
        }, { traceId = context.traceId, timeoutMs = 2000 })
    if not validated then return nil, validationError end
    current, sessionError = sessionStillCurrent(actor)
    if not current then return nil, sessionError end
    return { distance = validated.distance, revision = reference.generation,
        entity = canonical.entity, bucket = validated.bucket,
        position = canonical.position }, nil
end

local function validateAmbientEntity(resolved, target, actor)
    if resolved.intent.executionPolicy.managedOnly ~= false then
        return SynexInteractValidation.failure('INTERACT_TARGET_INVALID',
            'This interaction requires a managed EntityRef.')
    end
    local handle = NetworkGetEntityFromNetworkId(target.netId)
    if type(handle) ~= 'number' or handle <= 0 or not DoesEntityExist(handle) then
        return SynexInteractValidation.failure('INTERACT_TARGET_STALE',
            'The ambient network entity is unavailable.')
    end
    local actualModel = GetEntityModel(handle)
    if type(actualModel) == 'number' and actualModel < 0 then
        actualModel = actualModel + 4294967296
    end
    local nativeType = GetEntityType(handle)
    local actualType = ({ [1] = 'ped', [2] = 'vehicle', [3] = 'object' })[nativeType]
    local binding = resolved.object.binding
    if not TargetSelector.matchesAmbient(binding, target, {
        model = actualModel, entityType = actualType,
    }) then
        return SynexInteractValidation.failure('INTERACT_TARGET_INVALID',
            'The ambient entity selector is invalid or requires a managed EntityRef.')
    end
    if GetPlayerRoutingBucket(actor.source) ~= GetEntityRoutingBucket(handle) then
        return SynexInteractValidation.failure('INTERACT_TARGET_INVALID',
            'The actor and ambient entity are in different routing buckets.')
    end
    local actorPosition, positionError = playerPosition(actor.source)
    if not actorPosition then return nil, positionError end
    local targetPosition = vector(GetEntityCoords(handle))
    if not targetPosition then return SynexInteractValidation.failure('INTERACT_TARGET_STALE',
        'The ambient entity position is unavailable.') end
    return { distance = SynexInteractValidation.distance(actorPosition, targetPosition),
        revision = target.netId, position = targetPosition, model = actualModel }, nil
end

local function validateLocalTarget(resolved, target, actor, context)
    local binding = resolved.object.binding
    local targetPosition
    if target.kind == 'static' then targetPosition = binding.position
    elseif target.kind == 'dynamic' then
        local provider = registry.getProvider(binding.provider)
        if not provider or provider.owner ~= resolved.bundle.ownerResource
            or provider.epoch ~= resolved.bundle.ownerEpoch then
            return SynexInteractValidation.failure('INTERACT_PROVIDER_UNAVAILABLE',
                'The dynamic target provider is unavailable.', true)
        end
        local startedAt = now()
        local value, providerError = SynexInteractFoundation.boundedCall(provider.handler, {
            now = now, wait = Wait, spawn = CreateThread,
            timeoutMs = provider.definition.timeoutMs or SynexInteractLimits.providerTimeoutMs,
            timeoutCode = 'INTERACT_PROVIDER_TIMEOUT',
            timeoutMessage = 'The dynamic target provider timed out.', retryable = true,
        }, {
            phase = 'VALIDATE',
            target = SynexInteractValidation.copy(target), actor = {
                source = actor.source, sourceGeneration = actor.sourceGeneration,
                characterId = actor.characterId }, traceId = context.traceId })
        observability.observe('provider_duration_ms', {
            provider_kind = 'dynamic', outcome = value and 'success' or 'failure',
        }, math.max(0, now() - startedAt))
        if not value then return nil, providerError end
        targetPosition = value.position
    end
    targetPosition = SynexInteractValidation.vector3(targetPosition)
    if not targetPosition then return SynexInteractValidation.failure('INTERACT_TARGET_INVALID',
        'The canonical target transform is unavailable.') end
    local actorPosition, positionError = playerPosition(actor.source)
    if not actorPosition then return nil, positionError end
    return { distance = SynexInteractValidation.distance(actorPosition, targetPosition),
        revision = resolved.bundle.revision, position = targetPosition }, nil
end

local function validateTarget(resolved, target, actor, context)
    if target.kind == 'world' then return validateWorldTarget(resolved, target, actor, context)
    elseif target.kind == 'entity' then
        return validateManagedEntity(resolved, target, actor, context)
    elseif target.kind == 'ambient' then return validateAmbientEntity(resolved, target, actor)
    else return validateLocalTarget(resolved, target, actor, context) end
end

local function checkPolicy(actor, policy, resolved, context)
    if policy.requiredCapability ~= nil then
        local allowed, permissionError = coreMethod('Permissions', 'check',
            'character:' .. actor.characterId, policy.requiredCapability, {})
        if not allowed then return SynexInteractValidation.failure('INTERACT_LEASE_DENIED',
            'The actor does not have the required interaction permission.', false,
            permissionError and { source = 'rbac' } or nil) end
    end
    if policy.privileged then observability.audit('interact.privileged_attempt',
        'interaction_intent', resolved.intent.key,
        { bundleRevision = resolved.bundle.revision }, context) end
    return true, nil
end

local function checkAvailability(actor, resolved, slotClaims, phase, context)
    local policies = {{ policy = resolved.object.availabilityPolicy }}
    local seen = {}
    for _, claim in ipairs(slotClaims or {}) do
        if not seen[claim.slotKey] then
            seen[claim.slotKey] = true
            local slot = resolved.object.slots[claim.slotKey]
            if not slot then return SynexInteractValidation.failure(
                'INTERACT_SLOT_NOT_FOUND', 'The interaction slot is unavailable.') end
            policies[#policies + 1] = { policy = slot.availabilityPolicy,
                slotKey = claim.slotKey }
        end
    end
    for _, entry in ipairs(policies) do
        local policy = entry.policy or {}
        if policy.enabled == false then return SynexInteractValidation.failure(
            'INTERACT_SLOT_DISABLED', 'The interaction is currently disabled.') end
        if policy.evaluator ~= nil then
            local evaluator = registry.getEvaluator(policy.evaluator)
            if not evaluator or evaluator.owner ~= resolved.bundle.ownerResource
                or evaluator.epoch ~= resolved.bundle.ownerEpoch then
                return SynexInteractValidation.failure('INTERACT_EVALUATOR_UNAVAILABLE',
                    'The interaction availability evaluator is unavailable.', true)
            end
            local startedAt = now()
            local decision, evaluatorError = SynexInteractFoundation.boundedCall(
                evaluator.handler, {
                    now = now, wait = Wait, spawn = CreateThread,
                    timeoutMs = evaluator.definition.timeoutMs
                        or SynexInteractLimits.evaluatorTimeoutMs,
                    timeoutCode = 'INTERACT_EVALUATOR_TIMEOUT',
                    timeoutMessage = 'The interaction availability evaluator timed out.',
                    retryable = true,
                }, {
                    phase = phase, intentKey = resolved.intent.key,
                    objectKey = resolved.object.key, slotKey = entry.slotKey,
                    target = SynexInteractValidation.copy(
                        type(context) == 'table' and context.target or nil),
                    worldInstance = SynexInteractValidation.copy(
                        type(context) == 'table' and context.worldInstance or nil),
                    arguments = SynexInteractValidation.copy(policy.arguments or {}),
                    actor = { characterId = actor.characterId },
                    traceId = type(context) == 'table' and context.traceId or nil,
                })
            observability.observe('evaluator_duration_ms', {
                provider_kind = 'availability',
                outcome = type(decision) == 'boolean' and 'success' or 'failure',
            }, math.max(0, now() - startedAt))
            if type(decision) ~= 'boolean' then return nil, evaluatorError or {
                code = 'INTERACT_EVALUATOR_INVALID',
                message = 'The availability evaluator returned an invalid decision.',
                retryable = false,
            } end
            if not decision then return SynexInteractValidation.failure(
                'INTERACT_SLOT_DISABLED', 'The interaction is currently unavailable.') end
        end
    end
    return true, nil
end

authority = SynexInteractAuthority.create({
    registry = registry, slots = slots, sessions = sessions, locks = locks,
    now = now,
    nextId = function(namespace) return coreMethod('Ids', 'next', namespace) end,
    validateTarget = validateTarget, checkPolicy = checkPolicy,
    validateActorViability = function(actor)
        local ped = GetPlayerPed(actor.source)
        if type(ped) ~= 'number' or ped <= 0 or not DoesEntityExist(ped) then
            return false, { reason = 'ACTOR_DIED' }
        end
        local health = GetEntityHealth(ped)
        if not SynexInteractValidation.isFinite(health) or health <= 0 then
            return false, { reason = 'ACTOR_DIED' }
        end
        return true, nil
    end,
    checkAvailability = checkAvailability,
    observability = observability,
})
assert(authority.setCurrentSessionResolver(function(source)
    return coreMethod('Players', 'getBySource', source)
end))

local graph = SynexInteractActionGraph.create({
    registry = registry, now = now, slots = slots, locks = locks, sessions = sessions,
    observability = observability,
    nextId = function(namespace) return coreMethod('Ids', 'next', namespace) end,
    emit = function(source, payload)
        TriggerClientEvent('synex_interact:client:graph', source, payload)
        return true
    end,
    verify = function(kind, execution, node)
        local session = sessions.get(execution.sessionId)
        if not session then return SynexInteractValidation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        if kind == 'barrier' then return session.state == 'RUNNING', nil end
        local resolved, resolveError = registry.resolveIntent(
            execution.intentKey, execution.bundleRevision)
        if not resolved then return nil, resolveError end
        if kind == 'commit' then
            return authority.validateExecutionCommit(execution)
        end
        local participant
        local executionLease = authority.getLease(execution.leaseId)
        if executionLease then
            for _, role in pairs(session.roles) do
                local member = role.members[executionLease.actorKey]
                if member and member.ready ~= false then participant = member; break end
            end
        end
        if not participant then
            local roleKeys = {}
            for roleKey in pairs(session.roles) do roleKeys[#roleKeys + 1] = roleKey end
            table.sort(roleKeys, function(left, right)
                if left == 'operator' or right == 'operator' then
                    return left == 'operator' and right ~= 'operator'
                end
                return left < right
            end)
            for _, roleKey in ipairs(roleKeys) do
                local memberKeys = {}
                for actorKey, member in pairs(session.roles[roleKey].members) do
                    if member.ready ~= false then memberKeys[#memberKeys + 1] = actorKey end
                end
                table.sort(memberKeys)
                if #memberKeys > 0 then
                    participant = session.roles[roleKey].members[memberKeys[1]]
                    break
                end
            end
        end
        if not participant then return SynexInteractValidation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session has no participants.') end
        local playerSession, playerSessionError = coreMethod(
            'Players', 'getBySource', participant.source)
        if not playerSession or playerSession.state ~= 'ACTIVE'
            or playerSession.sourceGeneration ~= participant.sourceGeneration
            or playerSession.id ~= participant.sessionIdentity then
            return nil, playerSessionError or { code = 'INTERACT_LEASE_STALE',
                message = 'The graph participant session changed.', retryable = false }
        end
        local actorValue = { source = participant.source,
            sourceGeneration = participant.sourceGeneration,
            sessionIdentity = participant.sessionIdentity,
            characterId = playerSession.characterId,
            key = participant.key }
        if kind == 'condition' then
            local condition = node and node.condition
            if type(condition) ~= 'table' then return SynexInteractValidation.failure(
                'INTERACT_GRAPH_INVALID', 'Graph branch condition is unavailable.') end
            if condition.kind == 'evaluator' then
                local evaluator = registry.getEvaluator(condition.evaluator)
                if not evaluator or evaluator.owner ~= execution.ownerResource
                    or evaluator.epoch ~= execution.ownerEpoch then
                    return SynexInteractValidation.failure('INTERACT_EVALUATOR_UNAVAILABLE',
                        'The graph condition evaluator is unavailable.', true)
                end
                local startedAt = now()
                local decision, evaluatorError = SynexInteractFoundation.boundedCall(
                    evaluator.handler, {
                        now = now, wait = Wait, spawn = CreateThread,
                        timeoutMs = evaluator.definition.timeoutMs
                            or SynexInteractLimits.evaluatorTimeoutMs,
                        timeoutCode = 'INTERACT_EVALUATOR_TIMEOUT',
                        timeoutMessage = 'The interaction condition evaluator timed out.',
                        retryable = true,
                    }, {
                    phase = 'EXECUTION', executionId = execution.id,
                    sessionId = execution.sessionId,
                    target = SynexInteractValidation.copy(execution.target),
                    arguments = SynexInteractValidation.copy(condition.arguments or {}),
                    actor = { characterId = actorValue.characterId },
                    traceId = execution.traceId,
                    })
                observability.observe('evaluator_duration_ms', {
                    provider_kind = 'condition',
                    outcome = type(decision) == 'boolean' and 'success' or 'failure',
                }, math.max(0, now() - startedAt))
                if type(decision) ~= 'boolean' then return nil, evaluatorError or {
                    code = 'INTERACT_EVALUATOR_INVALID',
                    message = 'The graph condition evaluator returned an invalid decision.',
                    retryable = false }
                end
                return decision, nil
            end
            local observed = {
                ['target.kind'] = execution.target.kind,
                ['execution.committed'] = execution.committed,
                ['session.state'] = session.state,
            }
            local left = observed[condition.path]
            if condition.operator == 'eq' then return left == condition.value, nil
            elseif condition.operator == 'ne' then return left ~= condition.value, nil
            elseif condition.operator == 'truthy' then return not not left, nil
            elseif condition.operator == 'falsy' then return not left, nil end
            return SynexInteractValidation.failure('INTERACT_GRAPH_INVALID',
                'The graph condition path or operator is unsupported.')
        end
        if kind == 'event' then return SynexInteractValidation.failure('INTERACT_GRAPH_INVALID',
            'No typed event waiter was registered for this graph.') end
        if kind == 'verifyLease' then
            local lease = authority.getLease(execution.leaseId)
            return lease and lease.state == 'ACTIVE' and true or nil,
                lease and nil or { code = 'INTERACT_LEASE_STALE',
                    message = 'The graph lease is no longer active.', retryable = false }
        end
        if kind == 'verifyPolicy' then
            local allowed, policyError = checkPolicy(actorValue,
                resolved.intent.executionPolicy, resolved,
                { traceId = execution.traceId })
            if not allowed then return nil, policyError end
            return checkAvailability(actorValue, resolved, session.slotClaims or {},
                'GRAPH_VERIFY', { traceId = execution.traceId,
                    target = execution.target,
                    worldInstance = session.worldInstance })
        end
        local canonical, targetError = validateTarget(resolved, execution.target, actorValue,
            { traceId = execution.traceId })
        if not canonical then return nil, targetError end
        return authority.validateTargetFence(execution.leaseId, canonical)
    end,
    onFinished = function(execution, state)
        if authority then authority.finishExecution(execution, state) end
    end,
})
authority.setGraphRuntime(graph)

local diagnostics = SynexInteractDiagnostics.create({
    registry = registry, authority = authority, slots = slots, sessions = sessions,
    graph = graph, locks = locks, observability = observability,
    getResourceState = GetResourceState, now = now,
    getBundleFailures = function(limit)
        if bundleLoader then return bundleLoader.failures(limit) end
        return { items = {}, total = 0, hasMore = false, truncated = false }, nil
    end,
    resolveWorldReference = function(kind, key)
        if (kind ~= 'anchor' and kind ~= 'door' and kind ~= 'portal')
            or not SynexInteractValidation.identifier(key) then return nil end
        return coreMethod('Services', 'call', 'synex.world', '^1.0.0',
            'get', { key = key, kind = kind }, { timeoutMs = 2000 })
    end,
})
entityProjection = SynexInteractEntityProjection.create({
    registry = registry,
    getSession = function(source)
        return coreMethod('Players', 'getBySource', source)
    end,
    actorSnapshot = function(source)
        local position, positionError = playerPosition(source)
        if not position then return nil, positionError end
        local bucket = GetPlayerRoutingBucket(source)
        if not SynexInteractValidation.isInteger(bucket, 0, 2147483647) then
            return SynexInteractValidation.failure('INTERACT_TARGET_STALE',
                'The player routing bucket is unavailable.', true)
        end
        return { position = position, bucket = bucket }, nil
    end,
    getBucketFence = function(request, context)
        return coreMethod('Services', 'call', 'synex.entities', '^1.0.0',
            'getPlayerBucketFence', request,
            { traceId = context.traceId, timeoutMs = 2000 })
    end,
    queryNearby = function(request, context)
        return coreMethod('RPC', 'call', 'synex.entities.query.nearby',
            '1.0.0', request, { traceId = context.traceId, timeoutMs = 2000 })
    end,
    inspectEntity = function(netId)
        local handle = NetworkGetEntityFromNetworkId(netId)
        if type(handle) ~= 'number' or handle <= 0 or not DoesEntityExist(handle) then
            return nil
        end
        local model = GetEntityModel(handle)
        if type(model) == 'number' and model < 0 then model = model + 4294967296 end
        local position = vector(GetEntityCoords(handle))
        local bucket = GetEntityRoutingBucket(handle)
        local heading = GetEntityHeading(handle)
        local entityType = ({ [1] = 'ped', [2] = 'vehicle', [3] = 'object' })[
            GetEntityType(handle)]
        if not SynexInteractValidation.isInteger(model, 0, 4294967295)
            or not position
            or not SynexInteractValidation.isInteger(bucket, 0, 2147483647)
            or not SynexInteractValidation.isFinite(heading)
            or entityType == nil then return nil end
        return { model = model, position = position,
            bucket = bucket, heading = heading, entityType = entityType }
    end,
})
local service
local application
service = SynexInteractService.create({
    foundation = SynexInteractFoundation, registry = registry, authority = authority,
    graph = graph, observability = observability, diagnostics = diagnostics,
    entityProjection = entityProjection,
    resolveOwnerEpoch = function(owner, epoch)
        if not application then return SynexInteractValidation.failure('INTERACT_NOT_READY',
            'Interaction owner authority is not ready.', true) end
        return application.resolveOwnerEpoch(owner, epoch)
    end,
})
local controlProvider = SynexInteractControlProvider.create({
    registry = registry, authority = authority, slots = slots, sessions = sessions,
    graph = graph, diagnostics = diagnostics, observability = observability,
})
bundleLoader = SynexInteractBundleLoader.create({
    registry = registry, resourceName = RESOURCE_NAME,
    getRuntimeSnapshot = function() return coreMethod('Runtime', 'getSnapshot') end,
    checkCapability = function(resource, capability, operation)
        return coreMethod('Capabilities', 'checkResource', resource, capability, operation)
    end,
    loadResourceFile = LoadResourceFile, decode = json.decode,
    getResourceState = GetResourceState, observability = observability,
})
local compatibility = SynexInteractCompatibility.create()
application = SynexInteractApplication.create({
    resourceName = RESOURCE_NAME, coreResource = CORE_RESOURCE,
    coreRange = '^1.0.0', coreRef = coreRef, ownerEpochs = ownerEpochs,
    registry = registry, authority = authority, graph = graph, service = service,
    diagnostics = diagnostics, controlProvider = controlProvider,
    bundleLoader = bundleLoader, observability = observability, now = now,
    compatibility = compatibility, bridgeResource = 'synex_bridge',
    registerBridgeAdapter = function(definition, implementation)
        return exports.synex_bridge:RegisterCompatibilityAdapter(definition, implementation)
    end,
    acquireCore = function(range) return exports[CORE_RESOURCE]:GetAPI(range) end,
    loadResourceFile = LoadResourceFile, decode = json.decode,
    getResourceState = GetResourceState, wait = Wait, createThread = CreateThread,
})

exports('GetAPI', function(versionRange)
    local owner = GetInvokingResource()
    if type(owner) ~= 'string' or owner == '' then
        return false, { code = 'INTERACT_OWNER_STALE',
            message = 'Interaction API requires an invoking resource.', retryable = false }
    end
    local value, operationError = application.getAPI(owner, versionRange)
    if not value then return false, SynexInteractFoundation.publicError(operationError) end
    return value, nil
end)

CreateThread(function()
    local started, operationError = SynexInteractFoundation.protect(application.start)
    if not started then print(('[%s] Interaction bootstrap failed: %s'):format(
        RESOURCE_NAME, type(operationError) == 'table' and operationError.code
            or 'INTERACT_UNAVAILABLE')) end
end)

AddEventHandler('playerDropped', function() application.playerDropped(source) end)
AddEventHandler('onResourceStart', function(resource) application.resourceStarted(resource) end)
AddEventHandler('onResourceStop', function(resource) application.resourceStopped(resource) end)
