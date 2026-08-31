SynexWorldPortals = {}

local Portals = SynexWorldPortals
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function Portals.create(options)
    local registry = assert(options.registry, 'world portals require a registry')
    local mapRegistry = assert(options.mapRegistry, 'world portals require maps')
    local contextResolver = assert(options.contextResolver, 'world portals require context')
    local access = assert(options.access, 'world portals require access')
    local instances = assert(options.instances, 'world portals require instances')
    local getPlayer = assert(options.getPlayer, 'world portals require player sessions')
    local getPlayerPosition = assert(options.getPlayerPosition, 'world portals require server position')
    local nextId = assert(options.nextId, 'world portals require IDs')
    local now = assert(options.now, 'world portals require monotonic time')
    local triggerClient = assert(options.triggerClient, 'world portals require client projection')
    local emit = options.emit or function() end
    local audit = options.audit or function() end
    local expectTransition = options.expectTransition or function() return true end
    local grants, grantOrder = {}, {}
    local grantHead = 1
    local grantCount = 0
    local maximumGrants = 4096
    local portals = {}

    local function distance(left, right)
        local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function activeSession(source, expected)
        local session, sessionError = getPlayer(source)
        if not session then return nil, sessionError end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string'
            or not Validation.isInteger(session.sourceGeneration, 1, 9007199254740991)
            or expected and (session.id ~= expected.sessionId
                or session.sourceGeneration ~= expected.sourceGeneration) then
            return Validation.failure('TRANSITION_DENIED',
                'Portal transition requires the same active player session.')
        end
        return session
    end

    local function sourceContext(portal, source, expected, contractContext)
        local session, sessionError = activeSession(source, expected)
        if not session then return nil, nil, sessionError end
        local position, positionError = getPlayerPosition(source)
        if not position then return nil, nil, positionError end
        if distance(position, portal.source.position) > portal.source.radius then
            audit('world.portal_transition_denied', 'portal', portal.key,
                { reason = 'PORTAL_TOO_FAR' }, contractContext)
            local _, portalError = Validation.failure('PORTAL_TOO_FAR',
                'Player is outside the portal source boundary.')
            return nil, nil, portalError
        end
        local fromContext, contextError = contextResolver.resolve(position,
            instances.getForSource(source))
        if not fromContext then return nil, nil, contextError end
        if portal.parent then
            local matched = false
            for _, field in ipairs({ 'room', 'interior', 'location', 'region' }) do
                if fromContext[field] and fromContext[field].key == portal.parent then
                    matched = true
                end
            end
            for _, ref in ipairs(fromContext.zones or {}) do
                if ref.key == portal.parent then matched = true end
            end
            if not matched then
                audit('world.portal_transition_denied', 'portal', portal.key,
                    { reason = 'OUT_OF_CONTEXT' }, contractContext)
                local _, portalError = Validation.failure('OUT_OF_CONTEXT',
                    'Player is not in the portal source context.')
                return nil, nil, portalError
            end
        end
        return session, fromContext
    end

    local function validateDestination(portal, fence, contractContext)
        local currentPortal, portalError = portal
        if fence then
            currentPortal, portalError = registry.resolve(fence.portal, 'portal')
            if not currentPortal then return nil, portalError end
        end
        local destinationObject, destinationError
        if fence and fence.destination then
            destinationObject, destinationError = registry.resolve(fence.destination)
        elseif currentPortal.destination.target then
            destinationObject, destinationError = registry.get(currentPortal.destination.target)
        elseif currentPortal.destination.instanceTemplate then
            destinationObject, destinationError = registry.get(
                currentPortal.destination.instanceTemplate, 'instance_template')
        end
        if (currentPortal.destination.target or currentPortal.destination.instanceTemplate)
            and not destinationObject then
            return nil, destinationError or select(2, Validation.failure(
                'WORLD_NOT_FOUND', 'World portal destination does not exist.'))
        end
        local baseLocation, baseError
        if destinationObject and destinationObject.kind == 'instance_template' then
            if fence and fence.baseLocation then
                baseLocation, baseError = registry.resolve(fence.baseLocation, 'location')
            else
                baseLocation, baseError = registry.get(destinationObject.baseLocation, 'location')
            end
            if not baseLocation then
                return nil, baseError or select(2, Validation.failure(
                    'WORLD_NOT_FOUND', 'World instance base location does not exist.'))
            end
        end
        if destinationObject then
            local destinationAvailability = mapRegistry.objectAvailability(destinationObject)
            if not destinationAvailability.available then
                audit('world.portal_transition_denied', 'portal', currentPortal.key,
                    { reason = 'MAP_PACKAGE_UNAVAILABLE' }, contractContext)
                return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                    'World portal destination map package is unavailable.', true)
            end
        end
        if baseLocation then
            local baseAvailability = mapRegistry.objectAvailability(baseLocation)
            if not baseAvailability.available then
                audit('world.portal_transition_denied', 'portal', currentPortal.key,
                    { reason = 'MAP_PACKAGE_UNAVAILABLE' }, contractContext)
                return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                    'World instance base map package is unavailable.', true)
            end
        end
        return {
            portal = currentPortal,
            destination = destinationObject,
            baseLocation = baseLocation,
            fence = fence or {
                portal = registry.ref(currentPortal),
                destination = destinationObject and registry.ref(destinationObject) or nil,
                baseLocation = baseLocation and registry.ref(baseLocation) or nil,
            },
        }
    end

    local function queuedGrantCount()
        return grantCount
    end

    local function compactGrantOrder()
        if grantHead > #grantOrder then
            grantOrder, grantHead = {}, 1
            return
        end
        if grantHead <= 1024 or grantHead <= #grantOrder / 2 then return end
        local compacted = {}
        for index = grantHead, #grantOrder do
            compacted[#compacted + 1] = grantOrder[index]
        end
        grantOrder, grantHead = compacted, 1
    end

    local function removeGrant(id)
        if grants[id] ~= nil then
            grants[id] = nil
            grantCount = math.max(0, grantCount - 1)
        end
    end

    local function enqueueGrant(grant)
        grant.queueToken = (grant.queueToken or 0) + 1
        grantOrder[#grantOrder + 1] = { id = grant.grantId, token = grant.queueToken }
    end

    local function grantSnapshot(grant)
        local result = Validation.copy(grant)
        result.pending, result.queueToken, result.rollbackKey = nil, nil, nil
        return result
    end

    local function instanceUsesTemplate(instance, template)
        local reference = type(instance) == 'table' and instance.template or nil
        return type(reference) == 'table' and reference.kind == 'instance_template'
            and reference.key == template.key and reference.revision == template.revision
    end

    local function pruneGrants()
        local current = now()
        while grantHead <= #grantOrder do
            local entry = grantOrder[grantHead]
            local grant = grants[entry.id]
            if grant and grant.queueToken == entry.token then
                if grant.pending then break end
                if not grant.used and current <= grant.expiresAtMs then break end
                removeGrant(entry.id)
            end
            grantHead = grantHead + 1
        end
        compactGrantOrder()
    end

    local function createGrant(portal, session, fromContext, destination, instance, pending)
        pruneGrants()
        if queuedGrantCount() >= maximumGrants then
            return Validation.failure('PORTAL_UNAVAILABLE', 'Portal transition capacity is exhausted.', true)
        end
        local grantId, idError = nextId('world_transition')
        if type(grantId) ~= 'string' or #grantId < 8 or #grantId > 36
            or grantId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return nil, idError or select(2, Validation.failure('PORTAL_UNAVAILABLE',
                'Portal transition identifier is unavailable.', true))
        end
        local rollbackKey, rollbackKeyError
        if pending then
            rollbackKey, rollbackKeyError = nextId('wprb')
            if type(rollbackKey) ~= 'string' or #rollbackKey < 8 or #rollbackKey > 36
                or rollbackKey:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
                or rollbackKey == grantId then
                return nil, rollbackKeyError or select(2, Validation.failure(
                    'PORTAL_UNAVAILABLE', 'Portal rollback identifier is unavailable.', true))
            end
        end
        local createdAt = now()
        local grant = { grantId = grantId, sessionId = session.id,
            source = session.source, sourceGeneration = session.sourceGeneration,
            characterId = session.characterId, portalRef = registry.ref(portal),
            fromContext = fromContext, destination = Validation.copy(destination),
            instanceId = instance and instance.instanceId or nil,
            createdAtMs = createdAt,
            expiresAtMs = pending and nil or createdAt + Limits.transitionGrantTtlMs,
            pending = pending == true, rollbackKey = rollbackKey, used = false }
        grants[grantId], grantCount = grant, grantCount + 1
        enqueueGrant(grant)
        return grantSnapshot(grant)
    end

    local function cancelGrant(grantId)
        removeGrant(grantId)
    end

    local function activateGrant(grantId, fromContext)
        local grant = grants[grantId]
        if not grant or not grant.pending then
            return Validation.failure('PORTAL_UNAVAILABLE',
                'Pending portal transition grant was lost.', true)
        end
        grant.pending = false
        grant.fromContext = Validation.copy(fromContext)
        grant.expiresAtMs = now() + Limits.transitionGrantTtlMs
        enqueueGrant(grant)
        return grantSnapshot(grant)
    end

    local function compensateJoinedInstance(instanceId, source, grantId,
            originalError, contractContext)
        local rollbackKey = grants[grantId] and grants[grantId].rollbackKey
        cancelGrant(grantId)
        if type(rollbackKey) ~= 'string' or #rollbackKey < 8 or #rollbackKey > 36
            or rollbackKey:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'Portal rollback identifier is unavailable.', true,
                { cause = originalError and originalError.code or 'UNAVAILABLE',
                    rollbackCause = 'CORE_UNAVAILABLE' })
        end
        local rollback, rollbackError = instances.leave({
            instanceId = instanceId,
            source = source,
            idempotencyKey = rollbackKey,
        }, contractContext)
        if rollback then return nil, originalError end
        audit('world.portal_transition_rollback_failed', 'world_instance', instanceId, {
            cause = originalError and originalError.code or 'UNAVAILABLE',
            rollbackCause = rollbackError and rollbackError.code or 'UNAVAILABLE',
        }, contractContext)
        return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
            'Portal transition failed after instance join and rollback failed.', true, {
                cause = originalError and originalError.code or 'UNAVAILABLE',
                rollbackCause = rollbackError and rollbackError.code or 'UNAVAILABLE',
            })
    end

    function portals.createGrant(portal, session, fromContext, destination, instance)
        return createGrant(portal, session, fromContext, destination, instance, false)
    end

    function portals.consumeGrant(grantId, source)
        local grant = grants[grantId]
        if not grant then return Validation.failure('TRANSITION_GRANT_EXPIRED',
            'World transition grant does not exist or expired.') end
        if grant.used then return Validation.failure('TRANSITION_GRANT_REPLAYED',
            'World transition grant was already consumed.') end
        if grant.pending then return Validation.failure('TRANSITION_DENIED',
            'World transition grant is not active.') end
        if now() > grant.expiresAtMs then
            removeGrant(grantId)
            return Validation.failure('TRANSITION_GRANT_EXPIRED', 'World transition grant expired.')
        end
        if source ~= grant.source then
            return Validation.failure('TRANSITION_DENIED', 'World transition grant belongs to another player.')
        end
        local session, sessionError = activeSession(source, grant)
        if not session then return nil, sessionError end
        local portal, portalError = registry.resolve(grant.portalRef, 'portal')
        if not portal then return nil, portalError end
        grant.used, grant.usedAtMs = true, now()
        return grantSnapshot(grant), portal
    end

    function portals.transition(request, contractContext)
        if not Validation.isPlainTable(request) or not Validation.isInteger(request.source, 1, 65535) then
            return Validation.failure('INVALID_ARGUMENT', 'Portal transition request is invalid.')
        end
        local portal, portalError
        if request.portalRef then portal, portalError = registry.resolve(request.portalRef, 'portal')
        elseif request.portalKey then portal, portalError = registry.get(request.portalKey, 'portal') end
        if not portal then
            if portalError and (portalError.code == 'STALE_WORLD_REF'
                or portalError.code == 'WORLD_REFERENCE_INVALID') then return nil, portalError end
            return Validation.failure('PORTAL_NOT_FOUND', 'World portal does not exist.')
        end
        if portal.enabled == false then return Validation.failure('PORTAL_UNAVAILABLE', 'World portal is disabled.') end
        local session, fromContext, sourceError = sourceContext(
            portal, request.source, nil, contractContext)
        if not session then return nil, sourceError end
        local expectedSession = { sessionId = session.id,
            sourceGeneration = session.sourceGeneration }
        local decision, accessError = access.check({ source = request.source,
            targetRef = registry.ref(portal), instanceId = request.instanceId }, contractContext)
        if not decision then return nil, accessError end
        if decision.decision ~= 'ALLOW' then
            audit('world.portal_transition_denied', 'portal', portal.key,
                { reason = decision.reason }, contractContext)
            return Validation.failure('TRANSITION_DENIED', 'World portal access was denied.',
                decision.retryable, { reason = decision.reason })
        end
        local destinationState, destinationError = validateDestination(
            portal, nil, contractContext)
        if not destinationState then return nil, destinationError end
        local destinationFence = destinationState.fence
        if portal.portalType == 'physical' then
            session, fromContext, sourceError = sourceContext(
                portal, request.source, expectedSession, contractContext)
            if not session then return nil, sourceError end
            destinationState, destinationError = validateDestination(
                portal, destinationFence, contractContext)
            if not destinationState then return nil, destinationError end
            portal = destinationState.portal
            local payload = { portal = registry.ref(portal), source = registry.ref(portal),
                destination = { target = portal.destination.target }, transitioned = true }
            emit('synex.world.portal.transitioned', payload, contractContext)
            return payload
        end
        local destination, instance
        if portal.portalType == 'teleport' then
            destination = Validation.copy(portal.destination.position)
            destination.heading = portal.destination.heading
        else
            if request.instanceId then
                instance = instances.get(request.instanceId)
                if not instance then
                    return Validation.failure('INSTANCE_NOT_FOUND',
                        'Requested World instance does not exist.')
                end
            else
                instance = instances.findReadyByTemplate(portal.destination.instanceTemplate,
                    contractContext.caller)
            end
            if instance and not instanceUsesTemplate(instance, destinationState.destination) then
                return Validation.failure('WRONG_INSTANCE',
                    'Requested World instance uses another template.')
            end
            if not instance then
                session, fromContext, sourceError = sourceContext(
                    portal, request.source, expectedSession, contractContext)
                if not session then return nil, sourceError end
                instance, accessError = instances.create({
                    templateKey = portal.destination.instanceTemplate,
                    idempotencyKey = request.idempotencyKey,
                }, contractContext)
                if not instance then return nil, accessError end
            end
            destination = portal.destination.entry or registry.get(
                portal.destination.instanceTemplate, 'instance_template').entry
        end
        session, fromContext, sourceError = sourceContext(
            portal, request.source, expectedSession, contractContext)
        if not session then return nil, sourceError end
        local grant, grantError
        if portal.portalType == 'instance' then
            decision, accessError = access.check({ source = request.source,
                targetRef = registry.ref(portal), instanceId = instance.instanceId },
                contractContext)
            if not decision then return nil, accessError end
            if decision.decision ~= 'ALLOW' then
                audit('world.portal_transition_denied', 'portal', portal.key,
                    { reason = decision.reason }, contractContext)
                return Validation.failure('TRANSITION_DENIED',
                    'World portal access changed before instance join.',
                    decision.retryable, { reason = decision.reason })
            end
            session, fromContext, sourceError = sourceContext(
                portal, request.source, expectedSession, contractContext)
            if not session then return nil, sourceError end
            destinationState, destinationError = validateDestination(
                portal, destinationFence, contractContext)
            if not destinationState then return nil, destinationError end
            portal = destinationState.portal
            if not instanceUsesTemplate(instance, destinationState.destination) then
                return Validation.failure('WRONG_INSTANCE',
                    'World instance template changed before join.')
            end
            grant, grantError = createGrant(portal, session, fromContext,
                destination, instance, true)
            if not grant then return nil, grantError end
            session, fromContext, sourceError = sourceContext(
                portal, request.source, expectedSession, contractContext)
            if not session then cancelGrant(grant.grantId); return nil, sourceError end
            destinationState, destinationError = validateDestination(
                portal, destinationFence, contractContext)
            if not destinationState then
                cancelGrant(grant.grantId)
                return nil, destinationError
            end
            instance, accessError = instances.join({ instanceId = instance.instanceId,
                source = request.source, idempotencyKey = request.idempotencyKey }, contractContext)
            if not instance then cancelGrant(grant.grantId); return nil, accessError end
            destinationState, destinationError = validateDestination(
                portal, destinationFence, contractContext)
            if not destinationState then
                return compensateJoinedInstance(instance.instanceId, request.source,
                    grant.grantId, destinationError, contractContext)
            end
            if not instanceUsesTemplate(instance, destinationState.destination) then
                local _, mismatchError = Validation.failure('WRONG_INSTANCE',
                    'World instance template changed during join.')
                return compensateJoinedInstance(instance.instanceId, request.source,
                    grant.grantId, mismatchError, contractContext)
            end
            local pendingGrantId = grant.grantId
            grant, grantError = activateGrant(pendingGrantId, fromContext)
            if not grant then
                return compensateJoinedInstance(instance.instanceId, request.source,
                    pendingGrantId, grantError, contractContext)
            end
        else
            grant, grantError = portals.createGrant(portal, session, fromContext,
                destination, instance)
            if not grant then return nil, grantError end
        end
        local consumed, consumedPortal = portals.consumeGrant(grant.grantId, request.source)
        if not consumed then
            if portal.portalType == 'instance' then
                return compensateJoinedInstance(instance.instanceId, request.source,
                    grant.grantId, consumedPortal, contractContext)
            end
            return nil, consumedPortal
        end
        -- Security is advisory here. World remains authoritative and a Security
        -- outage must never weaken or block an already validated transition.
        pcall(expectTransition, consumed, consumedPortal, contractContext)
        triggerClient(request.source, 'synex_world:client:apply_transition', {
            schemaVersion = 1, revision = portal.revision,
            grantId = consumed.grantId, destination = consumed.destination,
        })
        local payload = { portal = registry.ref(consumedPortal), grantId = consumed.grantId,
            instanceId = consumed.instanceId, transitioned = true }
        emit('synex.world.portal.transitioned', payload, contractContext)
        audit('world.portal_transition_completed', 'portal', portal.key,
            { instance = consumed.instanceId ~= nil }, contractContext)
        return payload
    end

    function portals.expire()
        pruneGrants()
        return queuedGrantCount()
    end
    return portals
end
