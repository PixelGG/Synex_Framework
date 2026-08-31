SynexInteractWorldAuthority = {}

local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded before World authority')

local WORLD_KINDS = { anchor = true, door = true, portal = true }

local function normalizeWorldInstance(value)
    if value == nil then return false, nil end
    if not Validation.exactObject(value,
            { 'instanceId', 'revision', 'template', 'state' })
        or not Validation.token(value.instanceId, 8, 64)
        or not Validation.isInteger(value.revision, 1, 2147483647)
        or value.state ~= 'ACTIVE'
        or not Validation.exactObject(value.template, { 'kind', 'key', 'revision' })
        or value.template.kind ~= 'instance_template'
        or not Validation.identifier(value.template.key)
        or not Validation.isInteger(value.template.revision, 1, 2147483647) then
        return Validation.failure('INTERACT_TARGET_STALE',
            'The authoritative World instance is not active or canonical.')
    end
    return {
        instanceId = value.instanceId,
        revision = value.revision,
        template = {
            kind = value.template.kind,
            key = value.template.key,
            revision = value.template.revision,
        },
        state = value.state,
    }, nil
end

function SynexInteractWorldAuthority.create(options)
    options = options or {}
    local getWorld = assert(options.getWorld, 'World authority requires object resolution')
    local getWorldContext = assert(options.getWorldContext,
        'World authority requires context resolution')
    local getSession = assert(options.getSession, 'World authority requires player sessions')
    local getPlayerPosition = assert(options.getPlayerPosition,
        'World authority requires player positions')
    local authority = {}

    local function currentSession(actor)
        if not Validation.isPlainTable(actor)
            or not Validation.isInteger(actor.source, 1, 65535)
            or not Validation.isInteger(actor.sourceGeneration, 1)
            or not Validation.token(actor.sessionIdentity, 8, 96)
            or not Validation.token(actor.characterId, 3, 96) then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction actor session is invalid.')
        end
        local session, sessionError = getSession(actor.source)
        if not session or session.state ~= 'ACTIVE'
            or session.source ~= actor.source
            or session.sourceGeneration ~= actor.sourceGeneration
            or session.id ~= actor.sessionIdentity
            or session.characterId ~= actor.characterId then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction actor session changed.', false,
                type(sessionError) == 'table' and { cause = sessionError.code } or nil)
        end
        return session, nil
    end

    local function positionFor(object, kind, actorPosition)
        local position = Validation.vector3(object.position)
        if position then return position end
        if kind == 'door' and type(object.leaves) == 'table' then
            local nearestDistance
            for _, leaf in ipairs(object.leaves) do
                local candidate = type(leaf) == 'table'
                    and Validation.vector3(leaf.position) or nil
                if candidate then
                    local distance = Validation.distance(actorPosition, candidate)
                    if nearestDistance == nil or distance < nearestDistance then
                        position, nearestDistance = candidate, distance
                    end
                end
            end
        elseif kind == 'portal' and type(object.source) == 'table' then
            position = Validation.vector3(object.source.position)
        end
        return position
    end

    function authority.validate(_, target, actor, context)
        local reference = type(target) == 'table' and target.worldRef or nil
        local kind = type(reference) == 'table' and (reference.kind or 'anchor') or nil
        if type(target) ~= 'table' or target.kind ~= 'world'
            or not Validation.exactObject(reference, { 'key', 'revision' }, { 'kind' })
            or not WORLD_KINDS[kind] or not Validation.identifier(reference.key)
            or not Validation.isInteger(reference.revision, 1) then
            return Validation.failure('INTERACT_TARGET_INVALID',
                'The World target reference is invalid.')
        end
        local canonicalRef = {
            kind = kind,
            key = reference.key,
            revision = reference.revision,
        }
        local session, sessionError = currentSession(actor)
        if not session then return nil, sessionError end
        local worldContext, worldError = getWorldContext(actor.source, context)
        local copiedContext = Validation.copy(worldContext)
        if not copiedContext then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'The authoritative World context is unavailable.',
                type(worldError) ~= 'table' or worldError.retryable ~= false)
        end
        local worldInstance, instanceError = normalizeWorldInstance(copiedContext.instance)
        if worldInstance == nil then return nil, instanceError end

        -- Resolve the canonical object after the potentially yielding World-context
        -- lookup. This keeps stale revisions from surviving an asynchronous policy
        -- boundary immediately before distance evidence is sampled.
        local object, objectError = getWorld(canonicalRef, context)
        if not object then
            local unavailable = type(objectError) == 'table'
                and (objectError.code == 'UNAVAILABLE'
                    or objectError.code == 'RATE_LIMITED'
                    or objectError.code == 'STALE_RESOURCE')
            return Validation.failure(unavailable and 'INTERACT_UNAVAILABLE'
                    or 'INTERACT_TARGET_STALE',
                unavailable and 'The World authority is unavailable.'
                    or 'The World reference is stale.',
                unavailable or type(objectError) ~= 'table'
                    or objectError.retryable ~= false)
        end
        if type(object) ~= 'table' or object.kind ~= canonicalRef.kind
            or object.key ~= canonicalRef.key
            or object.revision ~= canonicalRef.revision then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The World reference is stale.')
        end
        session, sessionError = currentSession(actor)
        if not session then return nil, sessionError end

        -- Position is deliberately the last external authority read. A movement
        -- that happens while World/context resolution yields cannot reuse the old
        -- pre-yield coordinates.
        local actorPosition, positionError = getPlayerPosition(actor.source)
        actorPosition = Validation.vector3(actorPosition)
        if not actorPosition then
            return nil, positionError or select(2, Validation.failure(
                'INTERACT_LEASE_DENIED',
                'The interaction actor position is unavailable.', true))
        end
        local targetPosition = positionFor(object, kind, actorPosition)
        if not targetPosition then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The World reference has no authoritative interaction position.')
        end
        return {
            distance = Validation.distance(actorPosition, targetPosition),
            revision = object.revision,
            position = targetPosition,
            worldContext = copiedContext,
            -- `false` fences the public world and remains distinct from a
            -- non-World target, which has no World authority evidence.
            worldInstance = worldInstance,
        }, nil
    end

    return authority
end
