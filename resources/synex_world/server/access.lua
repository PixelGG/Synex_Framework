SynexWorldAccess = {}

local Access = SynexWorldAccess
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local function primitiveEqual(left, right)
    local leftType = type(left)
    return leftType == type(right)
        and (leftType == 'string' or leftType == 'number' or leftType == 'boolean'
            or left == nil) and left == right
end

function Access.create(options)
    local registry = assert(options.registry, 'world access requires a registry')
    local mapRegistry = assert(options.mapRegistry, 'world access requires a map registry')
    local getPlayer = assert(options.getPlayer, 'world access requires player sessions')
    local groupCapability = assert(options.groupCapability,
        'world access requires the Groups capability port')
    local groupExplain = options.groupExplain or groupCapability
    local getState = assert(options.getState, 'world access requires world state')
    local getDoorState = assert(options.getDoorState, 'world access requires door state')
    local getInstanceForSource = assert(options.getInstanceForSource,
        'world access requires instance membership')
    local access = {}

    local function currentMapGeneration()
        if type(mapRegistry.summary) ~= 'function' then
            return Validation.failure('UNAVAILABLE',
                'World map generation is unavailable during access evaluation.', true)
        end
        local summary = mapRegistry.summary()
        if not Validation.isPlainTable(summary)
            or not Validation.isInteger(summary.generation, 0, 2147483647) then
            return Validation.failure('UNAVAILABLE',
                'World map generation is invalid during access evaluation.', true)
        end
        return summary.generation
    end

    local function deny(reason, target, evaluation, retryable)
        evaluation[#evaluation + 1] = { gate = reason, decision = 'DENY' }
        return { decision = 'DENY', reason = reason,
            target = registry.ref(target), evaluation = evaluation,
            retryable = retryable == true }
    end

    local function actorFor(request)
        if request.source == nil then
            if type(request.characterId) ~= 'string' then
                return Validation.failure('WORLD_ACCESS_DENIED',
                    'World access requires an active player source.')
            end
            return { characterId = request.characterId }
        end
        if not Validation.isInteger(request.source, 1, 65535) then
            return Validation.failure('WORLD_ACCESS_DENIED', 'World player source is invalid.')
        end
        local session, sessionError = getPlayer(request.source)
        if not session then return nil, sessionError or { code = 'WORLD_ACCESS_DENIED' } end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string'
            or not Validation.isInteger(session.sourceGeneration, 1, 9007199254740991) then
            return Validation.failure('WORLD_ACCESS_DENIED',
                'World access requires an active character session.')
        end
        return { characterId = session.characterId, sessionId = session.id,
            source = session.source, sourceGeneration = session.sourceGeneration }
    end

    local function targetFor(request)
        if request.targetRef then return registry.resolve(request.targetRef) end
        if request.targetKey then return registry.get(request.targetKey) end
        return Validation.failure('WORLD_REFERENCE_INVALID', 'World access target is missing.')
    end

    local function revalidateActor(actor)
        if actor.source == nil then return true end
        local current, currentError = getPlayer(actor.source)
        if not current then
            if type(currentError) == 'table' and currentError.retryable == true then
                return nil, currentError
            end
            return Validation.failure('STALE_RESOURCE',
                'Player session changed while World access was evaluated.', true)
        end
        if current.state ~= 'ACTIVE' or current.id ~= actor.sessionId
            or current.characterId ~= actor.characterId
            or current.sourceGeneration ~= actor.sourceGeneration then
            return Validation.failure('STALE_RESOURCE',
                'Player session changed while World access was evaluated.', true)
        end
        return true
    end

    local function evaluate(request, context, explain, trusted)
        if not Validation.exactObject(request or {}, {
                targetRef = true, targetKey = true, source = true, characterId = true,
                instanceId = true,
            }) or (request.targetRef == nil) == (request.targetKey == nil)
            or (request.source == nil) == (request.characterId == nil)
            or request.characterId ~= nil and (type(request.characterId) ~= 'string'
                or #request.characterId < 1 or #request.characterId > 36
                or request.characterId:match('^[A-Za-z0-9_.:%-]+$') == nil)
            or request.instanceId ~= nil and (type(request.instanceId) ~= 'string'
                or #request.instanceId < 8 or #request.instanceId > 64
                or request.instanceId:match('^[A-Za-z0-9_.:%-]+$') == nil) then
            return Validation.failure('INVALID_ARGUMENT', 'World access request is invalid.')
        end
        local target, targetError = targetFor(request)
        if not target then return nil, targetError end
        local targetRef = registry.ref(target)
        local actor, actorError = actorFor(request)
        if not actor then return nil, actorError end
        local evaluation = {}
        local mapGeneration, mapGenerationError = currentMapGeneration()
        if mapGeneration == nil then return nil, mapGenerationError end
        local mapStatus = mapRegistry.objectAvailability(target)
        if not mapStatus.available then return deny('MAP_UNAVAILABLE', target, evaluation, true) end
        evaluation[#evaluation + 1] = { gate = 'map', decision = 'ALLOW' }

        local ignoreDisabled = trusted and trusted.ignoreDisabled == true
        if not ignoreDisabled and target.kind == 'portal' and target.enabled == false then
            return deny('TARGET_DISABLED', target, evaluation)
        end
        if not ignoreDisabled and target.kind == 'door' then
            local door, doorError = getDoorState(target.key)
            if not door then
                if doorError then return nil, doorError end
                return Validation.failure('UNAVAILABLE',
                    'World door state is unavailable during access evaluation.', true)
            end
            if door and door.state == 'DISABLED' then
                return deny('TARGET_DISABLED', target, evaluation)
            end
        end
        local policy = target.accessPolicy
        local sameInstanceId
        if policy and policy.requireSameInstance then
            if actor.source == nil then
                return deny('WRONG_INSTANCE', target, evaluation)
            end
            local membership = getInstanceForSource(actor.source)
            if not membership or request.instanceId ~= membership.instanceId then
                return deny('WRONG_INSTANCE', target, evaluation)
            end
            sameInstanceId = membership.instanceId
            evaluation[#evaluation + 1] = { gate = 'instance', decision = 'ALLOW' }
        end
        local stateEvidence = {}
        for _, requirement in ipairs(policy and policy.stateRequirements or {}) do
            local definition = registry.get(requirement.key, 'world_state_definition')
            local scopeRef = requirement.scopeRef
            if definition and definition.scope == 'global' then
                scopeRef = nil
            elseif definition and definition.scope == 'instance' then
                local membership = actor.source and getInstanceForSource(actor.source) or nil
                scopeRef = membership and membership.instanceId or nil
            elseif definition and scopeRef == nil then
                local candidate = target
                while candidate and candidate.kind ~= definition.scope do
                    candidate = candidate.parent and registry.get(candidate.parent) or nil
                end
                scopeRef = candidate and candidate.key or nil
            end
            if not definition or definition.scope ~= 'global' and scopeRef == nil then
                return deny(definition and definition.scope == 'instance'
                    and 'WRONG_INSTANCE' or 'OUT_OF_CONTEXT', target, evaluation)
            end
            local value, stateError = getState({ key = requirement.key, scopeRef = scopeRef })
            if not value then
                evaluation[#evaluation + 1] = { gate = 'state', key = requirement.key,
                    decision = 'DENY', reason = stateError and stateError.code or 'WORLD_STATE_NOT_FOUND' }
                return { decision = 'DENY', reason = 'WORLD_STATE_DENIED',
                    target = registry.ref(target), evaluation = evaluation }
            end
            stateEvidence[#stateEvidence + 1] = {
                definitionRef = registry.ref(definition), scopeRef = scopeRef,
                version = value.version, value = value.value,
            }
            local equals = primitiveEqual(value.value, requirement.value)
            local allowed
            if requirement.operator == 'equals' then
                allowed = equals
            else
                allowed = not equals
            end
            evaluation[#evaluation + 1] = { gate = 'state', key = requirement.key,
                decision = allowed and 'ALLOW' or 'DENY' }
            if not allowed then
                return { decision = 'DENY', reason = 'WORLD_STATE_DENIED',
                    target = registry.ref(target), evaluation = evaluation }
            end
        end
        if policy and policy.requiredCapability then
            local capabilityPort = explain and groupExplain or groupCapability
            local decision, capabilityError = capabilityPort({
                character_id = actor.characterId,
                group_id = policy.groupId,
                capability = policy.requiredCapability,
                scope = policy.scope,
            }, context)
            if not decision then
                evaluation[#evaluation + 1] = { gate = 'capability', decision = 'DENY',
                    reason = capabilityError and capabilityError.code or 'UNAVAILABLE' }
                return { decision = 'DENY', reason = 'MISSING_CAPABILITY',
                    target = registry.ref(target), evaluation = evaluation, retryable = true }
            end
            evaluation[#evaluation + 1] = { gate = 'capability',
                capability = policy.requiredCapability, decision = decision.decision,
                reason = decision.reason }
            if decision.decision ~= 'ALLOW' then
                return { decision = 'DENY', reason = 'MISSING_CAPABILITY',
                    target = registry.ref(target), evaluation = evaluation }
            end
        end
        for _, evidence in ipairs(stateEvidence) do
            local currentValue, currentValueError = getState({
                key = evidence.definitionRef.key, scopeRef = evidence.scopeRef,
            })
            if not currentValue then return nil, currentValueError end
            local currentDefinition, currentDefinitionError = registry.resolve(
                evidence.definitionRef, 'world_state_definition')
            if not currentDefinition then return nil, currentDefinitionError end
            if currentValue.definitionRevision ~= evidence.definitionRef.revision
                or currentValue.version ~= evidence.version
                or not primitiveEqual(currentValue.value, evidence.value) then
                return Validation.failure('STALE_RESOURCE',
                    'World state changed while access was evaluated.', true)
            end
        end
        local currentTarget, currentTargetError = registry.resolve(targetRef, target.kind)
        if not currentTarget then
            return nil, currentTargetError or select(2, Validation.failure('STALE_WORLD_REF',
                'World access target changed while access was evaluated.', true))
        end
        local currentMapGenerationValue, currentMapError = currentMapGeneration()
        if currentMapGenerationValue == nil then return nil, currentMapError end
        local currentMapStatus = mapRegistry.objectAvailability(currentTarget)
        if currentMapGenerationValue ~= mapGeneration then
            return Validation.failure('STALE_RESOURCE',
                'World map availability changed while access was evaluated.', true)
        end
        if not currentMapStatus.available then
            return deny('MAP_UNAVAILABLE', currentTarget, evaluation, true)
        end
        if sameInstanceId then
            local currentMembership = getInstanceForSource(actor.source)
            if not currentMembership or currentMembership.instanceId ~= sameInstanceId
                or request.instanceId ~= currentMembership.instanceId then
                return deny('WRONG_INSTANCE', currentTarget, evaluation)
            end
        end
        local currentActor, currentActorError = revalidateActor(actor)
        if not currentActor then return nil, currentActorError end
        return { decision = 'ALLOW', reason = 'ACCESS_GRANTED',
            target = targetRef, actor = actor, evaluation = evaluation }
    end

    function access.check(request, context)
        local result, accessError = evaluate(request, context, false)
        if not result then return nil, accessError end
        return { decision = result.decision, reason = result.reason,
            target = result.target, retryable = result.retryable == true }
    end

    function access.explain(request, context)
        return evaluate(request, context, true)
    end

    function access.checkDoorMutation(request, context)
        local result, accessError = evaluate(request, context, false,
            { ignoreDisabled = true })
        if not result then return nil, accessError end
        return { decision = result.decision, reason = result.reason,
            target = result.target, retryable = result.retryable == true }
    end
    return access
end
