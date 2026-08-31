SynexInteractAuthority = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')
local Foundation = assert(SynexInteractFoundation, 'interact foundation must be loaded first')
local TargetSelector = assert(SynexInteractTargetSelector,
    'interact target selector must be loaded first')

local terminalLeaseStates = {
    COMPLETED = true, CANCELLED = true, EXPIRED = true, REVOKED = true, FAILED = true,
}

function SynexInteractAuthority.create(options)
    options = options or {}
    local registry = assert(options.registry, 'authority requires the interaction registry')
    local slots = assert(options.slots, 'authority requires slot state')
    local sessions = assert(options.sessions, 'authority requires session state')
    local locks = assert(options.locks, 'authority requires actor locks')
    local now = assert(options.now, 'authority requires monotonic time')
    local nextId = assert(options.nextId, 'authority requires IDs')
    local validateTarget = assert(options.validateTarget, 'authority requires target validation')
    local validateActorViability = assert(options.validateActorViability,
        'authority requires actor viability validation')
    assert(Validation.isCallable(validateActorViability),
        'authority requires callable actor viability validation')
    local checkPolicy = options.checkPolicy or function() return true end
    local checkAvailability = options.checkAvailability or function() return true end
    local currentSessionResolver = options.currentSessionResolver
    local observability = assert(options.observability, 'authority requires observability')
    local requestRate = Foundation.tokenBucket(now, 6, 2)
    local activationRate = Foundation.tokenBucket(now, 8, 3)
    local leases, leaseCount, actorLeaseCount = {}, 0, {}
    local viabilityHead, viabilityCursor = nil, nil
    local pendingLeaseAdmissions, pendingActorAdmissions = 0, {}
    local graphRuntime = nil
    local authority = {}

    local function trackLease(lease)
        if viabilityHead == nil then
            lease.viabilityPrevious, lease.viabilityNext = lease.id, lease.id
            viabilityHead, viabilityCursor = lease.id, lease.id
            return
        end
        local head = leases[viabilityHead]
        local tail = head and leases[head.viabilityPrevious] or nil
        if not head or not tail then
            lease.viabilityPrevious, lease.viabilityNext = lease.id, lease.id
            viabilityHead, viabilityCursor = lease.id, lease.id
            return
        end
        lease.viabilityPrevious, lease.viabilityNext = tail.id, head.id
        tail.viabilityNext, head.viabilityPrevious = lease.id, lease.id
    end

    local function recordLeaseExpiry(lease)
        if not lease or lease.expiryRecorded then return false end
        lease.expiryRecorded = true
        observability.increment('lease_expired_total', {}, 1)
        return true
    end

    local function actor(context)
        local session = type(context) == 'table' and context.session or nil
        local source = type(context) == 'table' and context.source or nil
        local sourceGeneration = type(context) == 'table' and context.sourceGeneration or nil
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or session.source ~= source or session.sourceGeneration ~= sourceGeneration
            or not Validation.isInteger(source, 1, 65535)
            or not Validation.isInteger(sourceGeneration, 1)
            or not Validation.token(session.id, 8, 96)
            or not Validation.token(session.characterId, 3, 96) then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction actor session is unavailable.')
        end
        return {
            source = source, sourceGeneration = sourceGeneration,
            sessionIdentity = session.id, characterId = session.characterId,
            userId = session.userId,
            key = tostring(source) .. ':' .. tostring(sourceGeneration),
        }, nil
    end

    local function actorViable(actorValue, failureCode)
        local viable, evidence = Foundation.protect(validateActorViability, {
            source = actorValue.source,
            sourceGeneration = actorValue.sourceGeneration,
            sessionIdentity = actorValue.sessionIdentity,
            characterId = actorValue.characterId,
            actorKey = actorValue.key,
        })
        if viable == true then return true, nil end
        local reason = type(evidence) == 'table' and evidence.reason or nil
        if type(evidence) == 'table' and type(evidence.details) == 'table' then
            reason = evidence.details.reason or reason
        end
        if reason ~= 'ACTOR_DIED' then reason = 'ACTOR_DIED' end
        return Validation.failure(failureCode or 'INTERACT_LEASE_REVOKED',
            'The interaction actor is no longer viable.', false,
            { reason = reason })
    end

    local function allocate(namespace)
        local value, operationError = nextId(namespace)
        if not Validation.token(value, 8, 96) then
            return nil, operationError or {
                code = 'INTERACT_UNAVAILABLE', message = 'Interaction ID allocation failed.',
                retryable = true,
            }
        end
        return value, nil
    end

    local function claimLeaseAdmission(actorValue)
        local actorPending = pendingActorAdmissions[actorValue.key] or 0
        if leaseCount + pendingLeaseAdmissions >= Limits.maximumActiveLeases
            or (actorLeaseCount[actorValue.key] or 0) + actorPending
                >= Limits.maximumActorLeases then
            return Validation.failure('INTERACT_ACTOR_BUSY',
                'The actor has too many active interaction leases.')
        end
        pendingLeaseAdmissions = pendingLeaseAdmissions + 1
        pendingActorAdmissions[actorValue.key] = actorPending + 1
        return true, nil
    end

    local function releaseLeaseAdmission(actorValue)
        pendingLeaseAdmissions = math.max(0, pendingLeaseAdmissions - 1)
        local remaining = math.max(0,
            (pendingActorAdmissions[actorValue.key] or 1) - 1)
        pendingActorAdmissions[actorValue.key] = remaining > 0 and remaining or nil
    end

    local function reservationUsedByAnotherLease(reservationId, excludedLeaseId)
        for id, candidate in pairs(leases) do
            if id ~= excludedLeaseId and candidate.reservationId == reservationId
                and not terminalLeaseStates[candidate.state] then return true end
        end
        return false
    end

    local function releaseLease(lease, state, reason, preserveReservation)
        if not lease or terminalLeaseStates[lease.state] then return false end
        lease.state, lease.reason, lease.terminalAt = state, reason, now()
        if not preserveReservation
            and not reservationUsedByAnotherLease(lease.reservationId, lease.id) then
            slots.release(lease.reservationId)
        end
        actorLeaseCount[lease.actorKey] = math.max(0,
            (actorLeaseCount[lease.actorKey] or 1) - 1)
        if lease.viabilityPrevious and lease.viabilityNext then
            if lease.viabilityNext == lease.id then
                viabilityHead, viabilityCursor = nil, nil
            else
                local previous = leases[lease.viabilityPrevious]
                local following = leases[lease.viabilityNext]
                if previous then previous.viabilityNext = lease.viabilityNext end
                if following then following.viabilityPrevious = lease.viabilityPrevious end
                if viabilityHead == lease.id then viabilityHead = lease.viabilityNext end
                if viabilityCursor == lease.id then viabilityCursor = lease.viabilityNext end
            end
            lease.viabilityPrevious, lease.viabilityNext = nil, nil
        end
        leases[lease.id], leaseCount = nil, math.max(0, leaseCount - 1)
        return true
    end

    local function releaseSessionLeases(sessionId, state, reason)
        local ids = {}
        for id, lease in pairs(leases) do
            if lease.sessionId == sessionId then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do releaseLease(leases[id], state, reason) end
        return #ids
    end

    local function activeSessionLease(sessionId)
        for id, lease in pairs(leases) do
            if lease.sessionId == sessionId and not terminalLeaseStates[lease.state] then
                return id
            end
        end
        return nil
    end

    local function cancelRuntimeSession(session, reason)
        if not session then return false end
        sessions.finish(session.id, 'CANCELLING', reason)
        releaseSessionLeases(session.id, 'CANCELLED', reason)
        slots.cleanupSession(session.id)
        locks.release(session.id)
        if graphRuntime and Validation.isCallable(graphRuntime.cancel) then
            Foundation.protect(graphRuntime.cancel, session.id, reason)
        end
        sessions.remove(session.id)
        return true
    end

    local function cancelNonViableActor(actorValue, operationError)
        local affected = sessions.findActor(actorValue.key)
        local changed = 0
        for _, session in ipairs(affected) do
            if cancelRuntimeSession(session, 'ACTOR_DIED') then changed = changed + 1 end
        end
        local ids = {}
        for id, lease in pairs(leases) do
            if lease.actorKey == actorValue.key then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do
            if releaseLease(leases[id], 'REVOKED', 'ACTOR_DIED') then changed = changed + 1 end
        end
        locks.cleanupActor(actorValue.key)
        if changed > 0 then
            observability.increment('cancellation_total', { reason = 'ACTOR_DIED' }, 1)
        end
        observability.denied('actor.viability', operationError)
        return nil, operationError
    end

    local function applyParticipantLoss(session, actorKey, result, reason, leaseState)
        local participant = result.participant
        local sharedReservation = session
            and participant.reservationId == session.reservationId
        local preserveReservation = result.policy == 'REPLACE'
            or sharedReservation and result.state ~= 'CANCELLING'
        local released = participant.leaseId
            and releaseLease(leases[participant.leaseId], leaseState or 'CANCELLED', reason,
                preserveReservation)
        if not released and participant.reservationId and not preserveReservation then
            slots.release(participant.reservationId)
        end
        if graphRuntime and Validation.isCallable(graphRuntime.participantLeft) then
            Foundation.protect(graphRuntime.participantLeft, session.id, actorKey,
                result.policy, activeSessionLease(session.id), reason)
        end
        if result.state == 'CANCELLING' then
            cancelRuntimeSession(session, reason)
        end
        return true
    end

    local function rejectLease(lease, state, reason, operationError, participantScoped)
        local session = lease and sessions.get(lease.sessionId) or nil
        if participantScoped and session then
            local result = sessions.leave(session.id, lease.actorKey, reason)
            if result then
                applyParticipantLoss(session, lease.actorKey, result, reason, state)
            else
                releaseLease(lease, state, reason)
            end
        elseif session then
            cancelRuntimeSession(session, reason)
        else
            releaseLease(lease, state, reason)
        end
        return nil, operationError
    end

    local function bindingMatches(resolved, target)
        return TargetSelector.matchesTarget(
            resolved.object.binding, resolved.object.key, target)
    end

    local function roles(resolved)
        local result = {}
        for _, role in ipairs(resolved.intent.participants or {}) do
            result[#result + 1] = {
                role = role.role, required = role.required,
                capacity = role.capacity or 1,
                lossPolicy = role.lossPolicy
                    or resolved.graph.participantLossPolicy or 'ABORT',
                slotKey = role.slotKey, lateJoin = role.lateJoin == true,
            }
        end
        return result
    end

    local function initialRole(resolved)
        for _, role in ipairs(resolved.intent.participants or {}) do
            if role.required and role.role == 'operator' then return role end
        end
        for _, role in ipairs(resolved.intent.participants or {}) do
            if role.required then return role end
        end
        return nil
    end

    local function sessionSlotClaims(resolved, selectedRole, requestedSlotKey)
        if requestedSlotKey ~= nil and (type(requestedSlotKey) ~= 'string'
            or resolved.object.slots[requestedSlotKey] == nil) then
            return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                'The requested participant slot is unavailable.')
        end
        local unitsBySlot = {}
        for _, participant in ipairs(resolved.intent.participants or {}) do
            if participant.required then
            local declaredSlotKey = participant.slotKey or resolved.intent.slotSelector
            local slotKey = declaredSlotKey
                or resolved.object.slotOrder[1]
            if selectedRole and participant.role == selectedRole.role
                and requestedSlotKey ~= nil then
                if declaredSlotKey ~= nil and requestedSlotKey ~= declaredSlotKey then
                    return Validation.failure('INTERACT_LEASE_DENIED',
                        'The requested slot does not match the canonical participant slot.')
                end
                slotKey = requestedSlotKey
            end
            if type(slotKey) ~= 'string' or resolved.object.slots[slotKey] == nil then
                return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                    'A required participant slot is unavailable.')
            end
            local units = (unitsBySlot[slotKey] or 0) + (participant.capacity or 1)
            if units > 32 then
                return Validation.failure('INTERACT_RESERVATION_INVALID',
                    'The participant slot capacity cannot be represented safely.')
            end
            unitsBySlot[slotKey] = units
            end
        end
        local keys, claims = {}, {}
        for key in pairs(unitsBySlot) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            claims[#claims + 1] = {
                objectKey = resolved.object.key,
                slotKey = key,
                units = unitsBySlot[key],
            }
        end
        if #claims == 0 then
            return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                'No participant slots are declared for the interaction.')
        end
        return claims, nil
    end

    local function participantSlotClaims(resolved, participant, requestedSlotKey)
        if type(participant) ~= 'table' then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant role is unavailable.')
        end
        local declaredSlotKey = participant.slotKey or resolved.intent.slotSelector
        if requestedSlotKey ~= nil and (type(requestedSlotKey) ~= 'string'
            or resolved.object.slots[requestedSlotKey] == nil) then
            return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                'The requested participant slot is unavailable.')
        end
        if requestedSlotKey ~= nil and declaredSlotKey ~= nil
            and requestedSlotKey ~= declaredSlotKey then
            return Validation.failure('INTERACT_LEASE_DENIED',
                'The requested slot does not match the canonical participant slot.')
        end
        local slotKey = requestedSlotKey or declaredSlotKey
            or resolved.object.slotOrder[1]
        if type(slotKey) ~= 'string' or resolved.object.slots[slotKey] == nil then
            return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                'The participant slot is unavailable.')
        end
        return {{ objectKey = resolved.object.key, slotKey = slotKey, units = 1 }}, nil
    end

    local function validateResolvedTarget(resolved, target, actorValue, context)
        if not bindingMatches(resolved, target) then
            return Validation.failure('INTERACT_TARGET_INVALID',
                'The target does not match the canonical Smart Object binding.')
        end
        local value, operationError = validateTarget(resolved, target, actorValue, context)
        if not value then return nil, operationError end
        if not Validation.isFinite(value.distance) or value.distance < 0
            or not Validation.isInteger(value.revision, 1, Limits.maximumSafeInteger)
            or value.distance > (resolved.intent.executionPolicy.maximumDistance
                or Limits.maximumAuthorityDistance) then
            return Validation.failure('INTERACT_LEASE_DENIED',
                'The interaction target evidence is invalid or outside the allowed range.')
        end
        return value, nil
    end

    local function validateAvailability(resolved, slotClaims, actorValue, phase,
        target, canonical, context)
        local allowed, operationError = checkAvailability(actorValue, resolved,
            slotClaims, phase, {
                traceId = type(context) == 'table' and context.traceId or nil,
                target = Validation.copy(target),
                worldInstance = Validation.copy(
                    type(canonical) == 'table' and canonical.worldInstance or nil),
            })
        if allowed ~= true then
            return nil, operationError or {
                code = 'INTERACT_SLOT_DISABLED',
                message = 'The interaction is not currently available.',
                retryable = false,
            }
        end
        return true, nil
    end

    local function recheckActor(expected, context)
        local currentContext = context
        if Validation.isCallable(currentSessionResolver) then
            local currentSession, sessionError = Foundation.protect(
                currentSessionResolver, expected.source)
            if not currentSession then return nil, sessionError or {
                code = 'INTERACT_LEASE_STALE',
                message = 'The interaction actor session is unavailable.', retryable = false,
            } end
            currentContext = {
                source = expected.source,
                sourceGeneration = currentSession.sourceGeneration,
                session = currentSession,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        local currentActor, actorError = actor(currentContext)
        if not currentActor then return nil, actorError end
        if currentActor.key ~= expected.key
            or currentActor.sessionIdentity ~= expected.sessionIdentity
            or currentActor.characterId ~= expected.characterId then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction actor changed while the request was evaluated.')
        end
        return currentActor, currentContext
    end

    local function sameWorldInstance(expected, current)
        if expected == nil or current == nil then return expected == current end
        if expected == false or current == false then return expected == current end
        return type(expected) == 'table' and type(current) == 'table'
            and expected.instanceId == current.instanceId
            and expected.revision == current.revision
            and expected.state == current.state
            and type(expected.template) == 'table'
            and type(current.template) == 'table'
            and expected.template.kind == current.template.kind
            and expected.template.key == current.template.key
            and expected.template.revision == current.template.revision
    end

    local function validateWorldInstanceFence(expected, canonical)
        local current = type(canonical) == 'table' and canonical.worldInstance or nil
        if not sameWorldInstance(expected, current) then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The authoritative World instance changed during the interaction.')
        end
        return true, nil
    end

    local function refreshAuthority(expectedResolved, target, expectedActor, context,
        expectedTargetRevision, expectedWorldInstance, enforceWorldFence,
        viabilityFailureCode)
        local currentActor, currentContext = recheckActor(expectedActor, context)
        if not currentActor then return nil, currentContext end
        local currentResolved, resolveError = registry.resolveIntent(
            expectedResolved.intent.key, expectedResolved.bundle.revision)
        if not currentResolved
            or currentResolved.bundle.key ~= expectedResolved.bundle.key
            or currentResolved.bundle.ownerResource ~= expectedResolved.bundle.ownerResource
            or currentResolved.bundle.ownerEpoch ~= expectedResolved.bundle.ownerEpoch
            or currentResolved.object.key ~= expectedResolved.object.key
            or currentResolved.graph.key ~= expectedResolved.graph.key then
            return nil, resolveError or { code = 'INTERACT_INTENT_STALE',
                message = 'The interaction definition changed.', retryable = false }
        end
        local dependenciesReady, dependencyError =
            registry.validateRuntimeDependencies(currentResolved)
        if not dependenciesReady then return nil, dependencyError end

        -- This is intentionally the last potentially yielding authority lookup.
        -- Policy/evaluator calls performed by the caller cannot carry stale target,
        -- distance, World or entity-generation evidence into a mutation.
        local canonical, targetError = validateResolvedTarget(
            currentResolved, target, currentActor, currentContext)
        if not canonical then return nil, targetError end
        if expectedTargetRevision ~= nil
            and canonical.revision ~= expectedTargetRevision then
            return Validation.failure('INTERACT_TARGET_STALE',
                'The interaction target revision changed during authorization.')
        end
        if enforceWorldFence then
            local fenced, fenceError = validateWorldInstanceFence(
                expectedWorldInstance, canonical)
            if not fenced then return nil, fenceError end
        end
        local viable, viabilityError = actorViable(
            currentActor, viabilityFailureCode)
        if not viable then
            return cancelNonViableActor(currentActor, viabilityError)
        end
        return {
            actor = currentActor,
            resolved = currentResolved,
            canonical = canonical,
            context = currentContext,
        }, nil
    end

    function authority.setGraphRuntime(value)
        graphRuntime = value
        if type(value) == 'table' and Validation.isCallable(value.setLeaseReleaser) then
            local installed, installError = Foundation.protect(value.setLeaseReleaser,
                function(sessionId, leaseId, reason)
                    local requested = leases[leaseId]
                    if requested and requested.sessionId ~= sessionId then
                        return Validation.failure('INTERACT_LEASE_STALE',
                            'The graph lease does not belong to this interaction session.')
                    end
                    return { released = releaseSessionLeases(sessionId,
                        'COMPLETED', reason or 'GRAPH_RELEASED') }, nil
                end)
            if not installed then graphRuntime = nil; return nil, installError end
        end
        return true
    end

    function authority.setCurrentSessionResolver(handler)
        if handler ~= nil and not Validation.isCallable(handler) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The current-session resolver is invalid.')
        end
        currentSessionResolver = handler
        return true
    end

    function authority.reconcileSlots()
        local records = registry.slotDefinitions()
        slots.reconcile(records)
        return slots.snapshot()
    end

    local function requestLeaseClaimed(request, context, actorValue)
        if not Validation.exactObject(request, { 'intent', 'target', 'clientRevision' }, { 'slotKey' })
            or not Validation.exactObject(request.intent, { 'key', 'revision' })
            or not Validation.identifier(request.intent.key)
            or not Validation.isInteger(request.intent.revision, 1)
            or request.clientRevision ~= registry.currentRevision() then
            return Validation.failure('INTERACT_INTENT_STALE',
                'The interaction discovery revision is stale.')
        end
        local resolved, resolveError = registry.resolveIntent(
            request.intent.key, request.intent.revision)
        if not resolved then observability.denied('lease.request', resolveError); return nil, resolveError end
        local dependenciesReady, dependencyError = registry.validateRuntimeDependencies(resolved)
        if not dependenciesReady then
            observability.denied('lease.request', dependencyError)
            return nil, dependencyError
        end
        local target, targetError = Validation.target(request.target)
        if not target then observability.denied('lease.request', targetError); return nil, targetError end
        local role = initialRole(resolved)
        if not role then return Validation.failure('INTERACT_BUNDLE_INVALID',
            'The interaction has no required participant role.') end
        local slotClaims, claimsError = sessionSlotClaims(
            resolved, role, request.slotKey)
        if not slotClaims then
            observability.denied('lease.request', claimsError)
            return nil, claimsError
        end
        local canonical, validationError = validateResolvedTarget(
            resolved, target, actorValue, context)
        if not canonical then observability.denied('lease.request', validationError); return nil, validationError end
        local policyAllowed, policyError = checkPolicy(actorValue,
            resolved.intent.executionPolicy, resolved, context)
        if not policyAllowed then
            policyError = policyError or { code = 'INTERACT_LEASE_DENIED',
                message = 'Interaction policy denied the actor.', retryable = false }
            observability.denied('lease.request', policyError)
            return nil, policyError
        end
        local available, availabilityError = validateAvailability(
            resolved, slotClaims, actorValue, 'REQUEST', target, canonical, context)
        if not available then
            observability.denied('lease.request', availabilityError)
            return nil, availabilityError
        end
        local sessionId, sessionIdError = allocate('interact_session')
        if not sessionId then return nil, sessionIdError end
        local leaseId, leaseIdError = allocate('interact_lease')
        if not leaseId then return nil, leaseIdError end
        local nonce, nonceError = allocate('interact_nonce')
        if not nonce then return nil, nonceError end
        local reservationId, reservationIdError = allocate('interact_reservation')
        if not reservationId then return nil, reservationIdError end
        local refreshed, refreshError = refreshAuthority(resolved, target,
            actorValue, context, canonical.revision, canonical.worldInstance, true,
            'INTERACT_LEASE_DENIED')
        if not refreshed then return nil, refreshError end
        actorValue, resolved, canonical = refreshed.actor,
            refreshed.resolved, refreshed.canonical
        local policy = resolved.intent.executionPolicy
        local ttl = policy.leaseTtlMs or Limits.leaseRequestTtlMs
        local maximumLifetime = policy.maximumLifetimeMs or Limits.leaseMaximumLifetimeMs
        local timestamp = now()
        local created, createError = sessions.create({ sessionId = sessionId,
            ownerResource = resolved.bundle.ownerResource,
            ownerEpoch = resolved.bundle.ownerEpoch, bundleKey = resolved.bundle.key,
            bundleRevision = resolved.bundle.revision, intentKey = resolved.intent.key,
            target = target, roles = roles(resolved), reservationId = reservationId,
            slotClaims = slotClaims,
            worldInstance = canonical.worldInstance,
            expiresAt = timestamp + maximumLifetime })
        if not created then return nil, createError end
        local reservation, reservationError = slots.reserve({
            reservationId = reservationId, sessionId = sessionId,
            actorKey = actorValue.key,
            slotClaims = slotClaims,
            expiresAt = timestamp + math.min(maximumLifetime, Limits.reservationTtlMs),
            ownerResource = resolved.bundle.ownerResource,
            ownerEpoch = resolved.bundle.ownerEpoch,
            bundleRevision = resolved.bundle.revision,
        })
        if not reservation then sessions.remove(sessionId); return nil, reservationError end
        local participant, joinError = sessions.join(sessionId, actorValue,
            role.role, leaseId, reservationId)
        if not participant then slots.release(reservationId); sessions.remove(sessionId); return nil, joinError end
        local lease = {
            id = leaseId, nonce = nonce, state = 'ISSUED', sessionId = sessionId,
            actorKey = actorValue.key, source = actorValue.source,
            sourceGeneration = actorValue.sourceGeneration,
            sessionIdentity = actorValue.sessionIdentity,
            characterId = actorValue.characterId,
            intentKey = resolved.intent.key, objectKey = resolved.object.key,
            target = target,
            targetRevision = canonical.revision,
            worldInstance = Validation.copy(canonical.worldInstance),
            bundleKey = resolved.bundle.key, bundleRevision = resolved.bundle.revision,
            ownerResource = resolved.bundle.ownerResource, ownerEpoch = resolved.bundle.ownerEpoch,
            reservationId = reservationId, role = role.role,
            slotClaims = Validation.copy(slotClaims),
            issuedAt = timestamp, expiresAt = timestamp + ttl,
            activationDeadline = timestamp + math.min(ttl, Limits.leaseActivationTtlMs),
            maximumLifetimeAt = timestamp + maximumLifetime, consumed = false,
            renewalExtensionMs = ttl,
            traceId = context.traceId,
        }
        leases[lease.id], leaseCount = lease, leaseCount + 1
        trackLease(lease)
        actorLeaseCount[lease.actorKey] = (actorLeaseCount[lease.actorKey] or 0) + 1
        observability.increment('lease_total', { outcome = 'issued' }, 1)
        observability.trace(context.traceId, { phase = 'lease_issued', intent = lease.intentKey,
            revision = lease.bundleRevision })
        return {
            leaseId = lease.id, nonce = lease.nonce, state = 'ISSUED',
            intent = { key = lease.intentKey, revision = lease.bundleRevision },
            expiresAt = lease.expiresAt, sessionId = lease.sessionId,
            requiredParticipants = (function()
                local result = {}
                for _, definition in ipairs(resolved.intent.participants) do
                    if definition.required then result[#result + 1] = definition.role end
                end
                return result
            end)(),
        }, nil
    end

    function authority.requestLease(request, context)
        local actorValue, actorError = actor(context)
        if not actorValue then
            observability.denied('lease.request', actorError)
            return nil, actorError
        end
        local viable, viabilityError = actorViable(
            actorValue, 'INTERACT_LEASE_DENIED')
        if not viable then return cancelNonViableActor(actorValue, viabilityError) end
        local allowed, rateError = requestRate.take(actorValue.key, 1)
        if not allowed then
            observability.denied('lease.request', rateError)
            return nil, rateError
        end
        local claimed, claimError = claimLeaseAdmission(actorValue)
        if not claimed then return nil, claimError end
        local value, operationError = Foundation.protect(
            requestLeaseClaimed, request, context, actorValue)
        releaseLeaseAdmission(actorValue)
        return value, operationError
    end

    local function activateLeaseClaimed(request, context, actorValue, lease)
        local resolved, resolveError = registry.resolveIntent(
            lease.intentKey, lease.bundleRevision)
        if not resolved or resolved.bundle.ownerEpoch ~= lease.ownerEpoch then
            return rejectLease(lease, 'REVOKED', 'DEFINITION_CHANGED',
                resolveError or { code = 'INTERACT_LEASE_STALE',
                    message = 'The interaction definition changed.', retryable = false }, false)
        end
        local dependenciesReady, dependencyError = registry.validateRuntimeDependencies(resolved)
        if not dependenciesReady then
            return rejectLease(lease, 'REVOKED', 'DEPENDENCY_UNAVAILABLE',
                dependencyError, false)
        end
        local canonical, targetError = validateResolvedTarget(
            resolved, lease.target, actorValue, context)
        if not canonical then
            return rejectLease(lease, 'REVOKED', 'TARGET_CHANGED', targetError, false)
        end
        local worldFence, worldFenceError = validateWorldInstanceFence(
            lease.worldInstance, canonical)
        if not worldFence then
            return rejectLease(lease, 'REVOKED', 'WORLD_INSTANCE_CHANGED',
                worldFenceError, false)
        end
        local policyAllowed, policyError = checkPolicy(actorValue,
            resolved.intent.executionPolicy, resolved, context)
        if not policyAllowed then
            return rejectLease(lease, 'REVOKED', 'POLICY_CHANGED', policyError or {
                code = 'INTERACT_LEASE_DENIED',
                message = 'Interaction policy no longer permits the actor.', retryable = false,
            }, true)
        end
        local session = sessions.get(lease.sessionId)
        local available, availabilityError = validateAvailability(
            resolved, lease.slotClaims or {}, actorValue,
            'ACTIVATE', lease.target, canonical, context)
        if not available then
            return rejectLease(lease, 'REVOKED', 'AVAILABILITY_CHANGED',
                availabilityError, true)
        end
        local refreshed, refreshError = refreshAuthority(resolved, lease.target,
            actorValue, context, lease.targetRevision, lease.worldInstance, true,
            'INTERACT_LEASE_REVOKED')
        if not refreshed then
            return rejectLease(lease, 'REVOKED', 'AUTHORITY_CHANGED',
                refreshError, true)
        end
        local latest = refreshed.resolved
        actorValue, canonical = refreshed.actor, refreshed.canonical
        if latest.bundle.ownerEpoch ~= lease.ownerEpoch then
            return rejectLease(lease, 'REVOKED', 'DEFINITION_CHANGED',
                { code = 'INTERACT_LEASE_STALE',
                    message = 'The interaction definition changed.', retryable = false }, false)
        end
        local currentSession = sessions.get(lease.sessionId)
        local currentReservation, reservationError = slots.getReservation(
            lease.reservationId, lease.sessionId)
        if not currentSession or currentSession ~= session then
            return rejectLease(lease, 'REVOKED', 'SESSION_CHANGED', {
                code = 'INTERACT_LEASE_STALE',
                message = 'The interaction session changed.', retryable = false,
            }, true)
        end
        if not currentReservation or lease.expiresAt <= now()
            or lease.maximumLifetimeAt <= now() then
            return rejectLease(lease, 'REVOKED', 'SLOT_OR_LEASE_CHANGED',
                reservationError or { code = 'INTERACT_LEASE_EXPIRED',
                    message = 'The interaction lease expired during activation.',
                    retryable = false }, true)
        end
        lease.state = 'ACTIVE'
        local ready, readyError = sessions.markReady(lease.sessionId, lease.actorKey)
        if not ready then
            return rejectLease(lease, 'FAILED', 'SESSION_INVALID', readyError, false)
        end
        session = sessions.get(lease.sessionId)
        if not session then
            return rejectLease(lease, 'FAILED', 'SESSION_INVALID', {
                code = 'INTERACT_SESSION_NOT_FOUND',
                message = 'The interaction session is unavailable.', retryable = false,
            }, false)
        end
        local separateReservation = lease.reservationId ~= session.reservationId
        if separateReservation then
            local occupied, occupyError = slots.occupy(
                lease.reservationId, lease.sessionId, session.expiresAt)
            if not occupied then
                sessions.discard(session.id, lease.actorKey)
                releaseLease(lease, 'FAILED', 'SLOT_LOST')
                return nil, occupyError
            end
        end
        local responseState = ready.state == 'RUNNING' and 'RUNNING'
            or ready.ready and 'READY' or 'WAITING'
        if ready.state == 'RUNNING' then
            if not graphRuntime or not Validation.isCallable(graphRuntime.participantJoined) then
                sessions.discard(session.id, lease.actorKey)
                releaseLease(lease, 'FAILED', 'GRAPH_JOIN_UNAVAILABLE')
                return Validation.failure('INTERACT_UNAVAILABLE',
                    'The Action Graph cannot admit a late participant.', true)
            end
            local admitted, admissionError = graphRuntime.participantJoined(
                session.id, lease.actorKey)
            if not admitted then
                sessions.discard(session.id, lease.actorKey)
                releaseLease(lease, 'FAILED', 'ACTOR_LOCK_CONFLICT')
                return nil, admissionError
            end
        elseif ready.ready then
            if not session then
                return rejectLease(lease, 'FAILED', 'SESSION_INVALID', {
                    code = 'INTERACT_SESSION_NOT_FOUND',
                    message = 'The interaction session is unavailable.', retryable = false,
                }, false)
            end
            local occupied, occupyError = slots.occupy(
                session.reservationId, lease.sessionId, session.expiresAt)
            if not occupied then
                cancelRuntimeSession(session, 'SLOT_LOST')
                return nil, occupyError
            end
            if not graphRuntime then
                cancelRuntimeSession(session, 'GRAPH_UNAVAILABLE')
                return Validation.failure('INTERACT_UNAVAILABLE',
                    'The Action Graph runtime is unavailable.', true) end
            local started, startError
            if session.executionId and Validation.isCallable(graphRuntime.resume) then
                started, startError = graphRuntime.resume(session, resolved, lease, context)
            elseif session.executionId then
                cancelRuntimeSession(session, 'GRAPH_RESUME_UNAVAILABLE')
                return Validation.failure('INTERACT_UNAVAILABLE',
                    'The Action Graph cannot resume replacement participants.', true)
            else
                started, startError = graphRuntime.start(session, resolved, lease, context)
            end
            if not started then cancelRuntimeSession(session, 'GRAPH_START_FAILED'); return nil, startError end
            responseState = started.state
        end
        observability.increment('lease_activation_total', { outcome = 'accepted' }, 1)
        return { accepted = true, leaseId = lease.id,
            sessionId = lease.sessionId, state = responseState }, nil
    end

    function authority.activateLease(request, context)
        local actorValue, actorError = actor(context)
        if not actorValue then return nil, actorError end
        local allowed, rateError = activationRate.take(actorValue.key, 1)
        if not allowed then return nil, rateError end
        local lease = type(request) == 'table' and leases[request.leaseId] or nil
        if not lease or lease.actorKey ~= actorValue.key
            or lease.sessionIdentity ~= actorValue.sessionIdentity then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction lease is unavailable.')
        end
        if terminalLeaseStates[lease.state] or lease.expiresAt <= now()
            or lease.activationDeadline <= now() then
            recordLeaseExpiry(lease)
            local _, operationError = Validation.failure(
                'INTERACT_LEASE_EXPIRED', 'The interaction lease expired.')
            return rejectLease(lease, 'EXPIRED', 'LEASE_EXPIRED',
                operationError, true)
        end
        if lease.state ~= 'ISSUED' or lease.consumed
            or request.nonce ~= lease.nonce then
            return Validation.failure('INTERACT_LEASE_REPLAYED',
                'The interaction lease activation was already consumed.')
        end
        local viable, viabilityError = actorViable(
            actorValue, 'INTERACT_LEASE_REVOKED')
        if not viable then return cancelNonViableActor(actorValue, viabilityError) end

        -- Consume the one-time nonce before the first potentially yielding target,
        -- policy or availability call. A concurrent replay can no longer pass the
        -- preflight window while this activation is in progress.
        lease.consumed, lease.nonce, lease.state = true, nil, 'ACTIVATING'
        local value, operationError = Foundation.protect(
            activateLeaseClaimed, request, context, actorValue, lease)
        if value == nil and leases[lease.id] == lease and lease.state == 'ACTIVATING' then
            return rejectLease(lease, 'FAILED', 'ACTIVATION_FAILED',
                operationError or { code = 'INTERACT_UNAVAILABLE',
                    message = 'The interaction activation failed.', retryable = true }, true)
        end
        return value, operationError
    end

    function authority.inviteSession(request, ownerResource, ownerEpoch)
        if not Validation.exactObject(request or {},
                { 'sessionId', 'role', 'source' }, { 'ttlMs' })
            or not Validation.token(request.sessionId, 8, 96)
            or not Validation.text(request.role, 1, 32)
            or not Validation.isInteger(request.source, 1, 65535)
            or request.ttlMs ~= nil and not Validation.isInteger(
                request.ttlMs, 500, Limits.sessionInvitationTtlMs)
            or not Validation.resourceName(ownerResource)
            or not Validation.isInteger(ownerEpoch, 1) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The participant invitation request is invalid.')
        end
        local session = sessions.get(request.sessionId)
        if not session or session.ownerResource ~= ownerResource
            or session.ownerEpoch ~= ownerEpoch
            or session.state ~= 'WAITING' and session.state ~= 'RUNNING'
            or session.expiresAt <= now() then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session is unavailable to this owner incarnation.')
        end
        local role = session.roles[request.role]
        local replacing = role and role.replacementReservationId ~= nil
        if not role or role.count >= role.capacity
            or session.executionId ~= nil and not replacing
                and (role.required or not role.lateJoin) then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant role is unavailable.')
        end
        if not Validation.isCallable(currentSessionResolver) then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'The player session authority is unavailable.', true)
        end
        local playerSession, playerError = Foundation.protect(
            currentSessionResolver, request.source)
        if not playerSession or playerSession.state ~= 'ACTIVE'
            or playerSession.source ~= request.source
            or not Validation.isInteger(playerSession.sourceGeneration, 1)
            or not Validation.token(playerSession.id, 8, 96) then
            return nil, playerError or { code = 'INTERACT_PARTICIPANT_DENIED',
                message = 'The invited player session is unavailable.', retryable = false }
        end
        local invitationId, idError = allocate('interact_invitation')
        if not invitationId then return nil, idError end

        -- ID allocation may yield. Fence both owner-session and invited actor again
        -- before publishing the bearer token.
        if sessions.get(session.id) ~= session or session.ownerResource ~= ownerResource
            or session.ownerEpoch ~= ownerEpoch then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session changed while the invitation was issued.')
        end
        local currentPlayer, currentError = Foundation.protect(
            currentSessionResolver, request.source)
        if not currentPlayer or currentPlayer.state ~= 'ACTIVE'
            or currentPlayer.id ~= playerSession.id
            or currentPlayer.sourceGeneration ~= playerSession.sourceGeneration then
            return nil, currentError or { code = 'INTERACT_PARTICIPANT_DENIED',
                message = 'The invited player session changed.', retryable = false }
        end
        if sessions.get(session.id) ~= session or session.ownerResource ~= ownerResource
            or session.ownerEpoch ~= ownerEpoch
            or session.state ~= 'WAITING' and session.state ~= 'RUNNING' then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session changed while the invitation was issued.')
        end
        local timestamp = now()
        local expiresAt = math.min(session.expiresAt,
            timestamp + (request.ttlMs or Limits.sessionInvitationTtlMs))
        local invitation, invitationError = sessions.invite(session.id, {
            id = invitationId, role = request.role, source = request.source,
            sourceGeneration = currentPlayer.sourceGeneration,
            sessionIdentity = currentPlayer.id,
            ownerResource = ownerResource, ownerEpoch = ownerEpoch,
            expiresAt = expiresAt,
        })
        if not invitation then return nil, invitationError end
        return { sessionId = session.id, invitationId = invitation.id,
            role = invitation.role, expiresAt = invitation.expiresAt }, nil
    end

    local function joinSessionClaimed(request, context, actorValue)
        if not Validation.exactObject(request or {},
                { 'sessionId', 'role', 'invitationId' })
            or not Validation.token(request.sessionId, 8, 96)
            or not Validation.text(request.role, 1, 32)
            or not Validation.token(request.invitationId, 8, 96) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The participant join request is invalid.')
        end
        local session = sessions.get(request.sessionId)
        if not session then return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local resolved, resolveError = registry.resolveIntent(
            session.intentKey, session.bundleRevision)
        if not resolved then return nil, resolveError end
        if resolved.bundle.key ~= session.bundleKey
            or resolved.bundle.ownerResource ~= session.ownerResource
            or resolved.bundle.ownerEpoch ~= session.ownerEpoch then
            return Validation.failure('INTERACT_INTENT_STALE',
                'The interaction session definition changed.')
        end
        local role
        for _, definition in ipairs(resolved.intent.participants) do
            if definition.role == request.role then role = definition; break end
        end
        if not role then return Validation.failure('INTERACT_PARTICIPANT_DENIED',
            'The requested participant role is unavailable.') end
        if session.state ~= 'WAITING' and session.state ~= 'RUNNING' then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session is unavailable.')
        end
        local roleState = session.roles[role.role]
        local replacing = roleState and roleState.replacementReservationId ~= nil
        local executionStarted = session.executionId ~= nil
        if executionStarted and not replacing
            and (role.required or role.lateJoin ~= true) then
            return Validation.failure('INTERACT_PARTICIPANT_DENIED',
                'The participant role does not allow late join.')
        end
        local invitation, invitationError = sessions.getInvitation(
            session.id, request.invitationId, actorValue, role.role)
        if not invitation then return nil, invitationError end
        local roleClaims, roleClaimsError
        if role.required then roleClaims = Validation.copy(session.slotClaims or {})
        else roleClaims, roleClaimsError = participantSlotClaims(resolved, role, nil) end
        if not roleClaims then return nil, roleClaimsError end
        local dependenciesReady, dependencyError =
            registry.validateRuntimeDependencies(resolved)
        if not dependenciesReady then return nil, dependencyError end
        local canonical, targetError = validateResolvedTarget(
            resolved, session.target, actorValue, context)
        if not canonical then return nil, targetError end
        local worldFence, worldFenceError = validateWorldInstanceFence(
            session.worldInstance, canonical)
        if not worldFence then return nil, worldFenceError end
        local policyAllowed, policyError = checkPolicy(actorValue,
            resolved.intent.executionPolicy, resolved, context)
        if not policyAllowed then return nil, policyError or {
            code = 'INTERACT_LEASE_DENIED',
            message = 'Interaction policy denied the participant.', retryable = false,
        } end
        local available, availabilityError = validateAvailability(
            resolved, roleClaims, actorValue, 'JOIN',
            session.target, canonical, context)
        if not available then return nil, availabilityError end
        local leaseId, leaseError = allocate('interact_lease')
        if not leaseId then return nil, leaseError end
        local nonce, nonceError = allocate('interact_nonce')
        if not nonce then return nil, nonceError end
        local reservationId = role.required and session.reservationId
            or roleState and roleState.replacementReservationId or nil
        local createdReservation = reservationId == nil
        if reservationId == nil then
            local allocationError
            reservationId, allocationError = allocate('interact_reservation')
            if not reservationId then return nil, allocationError end
        end
        local refreshed, refreshError = refreshAuthority(resolved, session.target,
            actorValue, context, canonical.revision, session.worldInstance, true,
            'INTERACT_LEASE_DENIED')
        if not refreshed then return nil, refreshError end
        actorValue, resolved, canonical = refreshed.actor,
            refreshed.resolved, refreshed.canonical
        if sessions.get(session.id) ~= session
            or session.bundleKey ~= resolved.bundle.key
            or session.ownerResource ~= resolved.bundle.ownerResource
            or session.ownerEpoch ~= resolved.bundle.ownerEpoch then
            return Validation.failure('INTERACT_INTENT_STALE',
                'The interaction session definition changed.')
        end
        local consumed, consumeError = sessions.consumeInvitation(
            session.id, request.invitationId, actorValue, role.role)
        if not consumed then return nil, consumeError end
        local timestamp = now()
        if createdReservation then
            local reservation, reservationError = slots.reserve({
                reservationId = reservationId, sessionId = session.id,
                actorKey = actorValue.key, slotClaims = roleClaims,
                expiresAt = timestamp + math.min(session.expiresAt - timestamp,
                    Limits.reservationTtlMs), ownerResource = session.ownerResource,
                ownerEpoch = session.ownerEpoch, bundleRevision = session.bundleRevision,
            })
            if not reservation then return nil, reservationError end
        else
            local reservation, slotError = slots.getReservation(reservationId, session.id)
            if not reservation or reservation.state ~= 'RESERVED'
                and reservation.state ~= 'OCCUPIED' then
                return nil, slotError or { code = 'INTERACT_SLOT_LOST',
                    message = 'The interaction slot reservation is unavailable.', retryable = false }
            end
        end
        local member, joinError = sessions.join(session.id, actorValue,
            role.role, leaseId, reservationId)
        if not member then
            if createdReservation then slots.release(reservationId) end
            return nil, joinError
        end
        local policy = resolved.intent.executionPolicy
        local ttl = policy.leaseTtlMs or Limits.leaseRequestTtlMs
        local lease = {
            id = leaseId, nonce = nonce, state = 'ISSUED', sessionId = session.id,
            actorKey = actorValue.key, source = actorValue.source,
            sourceGeneration = actorValue.sourceGeneration,
            sessionIdentity = actorValue.sessionIdentity,
            characterId = actorValue.characterId, intentKey = session.intentKey,
            objectKey = resolved.object.key,
            target = Validation.copy(session.target), targetRevision = canonical.revision,
            worldInstance = Validation.copy(canonical.worldInstance),
            bundleKey = session.bundleKey,
            bundleRevision = session.bundleRevision,
            ownerResource = session.ownerResource, ownerEpoch = session.ownerEpoch,
            reservationId = reservationId, role = role.role,
            slotClaims = Validation.copy(roleClaims),
            issuedAt = timestamp, expiresAt = timestamp + ttl,
            activationDeadline = timestamp + math.min(ttl, Limits.leaseActivationTtlMs),
            maximumLifetimeAt = session.expiresAt, consumed = false,
            renewalExtensionMs = ttl,
            traceId = context.traceId,
        }
        leases[lease.id], leaseCount = lease, leaseCount + 1
        trackLease(lease)
        actorLeaseCount[lease.actorKey] = (actorLeaseCount[lease.actorKey] or 0) + 1
        return { sessionId = session.id, leaseId = lease.id, nonce = lease.nonce,
            role = lease.role, state = 'WAITING' }, nil
    end

    function authority.joinSession(request, context)
        local actorValue, actorError = actor(context)
        if not actorValue then return nil, actorError end
        local viable, viabilityError = actorViable(
            actorValue, 'INTERACT_LEASE_DENIED')
        if not viable then return cancelNonViableActor(actorValue, viabilityError) end
        local claimed, claimError = claimLeaseAdmission(actorValue)
        if not claimed then return nil, claimError end
        local value, operationError = Foundation.protect(
            joinSessionClaimed, request, context, actorValue)
        releaseLeaseAdmission(actorValue)
        return value, operationError
    end

    function authority.leaveSession(request, context)
        local actorValue, actorError = actor(context)
        if not actorValue then return nil, actorError end
        local result, leaveError = sessions.leave(request.sessionId,
            actorValue.key, 'PARTICIPANT_LEFT')
        if not result then return nil, leaveError end
        local session = sessions.get(request.sessionId)
        applyParticipantLoss(session, actorValue.key, result, 'PARTICIPANT_LEFT')
        return { sessionId = request.sessionId, left = true }, nil
    end

    function authority.cancelSession(request, context)
        local actorValue, actorError = actor(context)
        if not actorValue then return nil, actorError end
        local session = sessions.get(request.sessionId)
        if not session then return Validation.failure('INTERACT_SESSION_NOT_FOUND',
            'The interaction session is unavailable.') end
        local member = false
        for _, candidate in ipairs(sessions.findActor(actorValue.key)) do
            if candidate.id == session.id then member = true; break end
        end
        if not member then return Validation.failure('INTERACT_LEASE_STALE',
            'The actor does not own this interaction session.') end
        cancelRuntimeSession(session, request.reason)
        observability.increment('cancellation_total', { reason = request.reason }, 1)
        return { sessionId = session.id, cancelled = true }, nil
    end

    function authority.renewLease(leaseId, extensionMs, context, ownerResource, ownerEpoch)
        if not Validation.token(leaseId, 8, 96)
            or not Validation.isInteger(extensionMs, 100, 10000) then
            return Validation.failure('INTERACT_INVALID_REQUEST', 'Lease renewal duration is invalid.')
        end
        local lease = leases[leaseId]
        if ownerResource ~= nil and (not lease
            or lease.ownerResource ~= ownerResource
            or lease.ownerEpoch ~= ownerEpoch) then
            return Validation.failure('INTERACT_OWNER_STALE',
                'The interaction lease does not belong to this resource incarnation.')
        end
        local renewalContext = context
        if lease and (type(renewalContext) ~= 'table'
                or type(renewalContext.session) ~= 'table')
            and Validation.isCallable(currentSessionResolver) then
            local resolvedSession, sessionError = Foundation.protect(
                currentSessionResolver, lease.source)
            if not resolvedSession then return nil, sessionError or {
                code = 'INTERACT_LEASE_STALE',
                message = 'The interaction actor session is unavailable.', retryable = false,
            } end
            renewalContext = {
                source = lease.source,
                sourceGeneration = resolvedSession.sourceGeneration,
                session = resolvedSession,
                traceId = type(context) == 'table' and context.traceId or nil,
            }
        end
        local actorValue, actorError = actor(renewalContext)
        if not actorValue then return nil, actorError end
        if not lease or lease.actorKey ~= actorValue.key
            or lease.sessionIdentity ~= actorValue.sessionIdentity
            or lease.source ~= actorValue.source
            or lease.sourceGeneration ~= actorValue.sourceGeneration
            or lease.state ~= 'ACTIVE' then
            return Validation.failure('INTERACT_LEASE_STALE', 'The interaction lease is unavailable.')
        end
        local viable, viabilityError = actorViable(
            actorValue, 'INTERACT_LEASE_REVOKED')
        if not viable then return cancelNonViableActor(actorValue, viabilityError) end
        local timestamp = now()
        local function reject(reason, operationError)
            local session = sessions.get(lease.sessionId)
            if session then cancelRuntimeSession(session, reason)
            else releaseLease(lease, 'REVOKED', reason) end
            observability.denied('lease.renew', operationError)
            return nil, operationError
        end
        local function rejectParticipant(reason, operationError)
            local session = sessions.get(lease.sessionId)
            local result = session and sessions.leave(
                session.id, lease.actorKey, reason) or nil
            if result then applyParticipantLoss(session, lease.actorKey, result, reason)
            else releaseLease(lease, 'REVOKED', reason) end
            observability.denied('lease.renew', operationError)
            return nil, operationError
        end
        if lease.expiresAt <= timestamp or lease.maximumLifetimeAt <= timestamp then
            recordLeaseExpiry(lease)
            return rejectParticipant('LEASE_EXPIRED', {
                code = 'INTERACT_LEASE_EXPIRED',
                message = 'The interaction lease expired.', retryable = false,
            })
        end
        local session = sessions.get(lease.sessionId)
        local member
        if session then
            for _, role in pairs(session.roles or {}) do
                local candidate = role.members and role.members[actorValue.key]
                if candidate and candidate.leaseId == lease.id
                    and candidate.sessionIdentity == actorValue.sessionIdentity
                    and candidate.sourceGeneration == actorValue.sourceGeneration then
                    member = candidate
                    break
                end
            end
        end
        if not session or not member
            or session.state ~= 'WAITING' and session.state ~= 'READY'
                and session.state ~= 'RUNNING'
            or session.ownerResource ~= lease.ownerResource
            or session.ownerEpoch ~= lease.ownerEpoch
            or session.bundleKey ~= lease.bundleKey
            or session.bundleRevision ~= lease.bundleRevision
            or session.intentKey ~= lease.intentKey then
            return reject('SESSION_CHANGED', {
                code = 'INTERACT_LEASE_STALE',
                message = 'The interaction session changed.', retryable = false,
            })
        end
        local reservation, reservationError = slots.getReservation(
            lease.reservationId, session.id)
        if not reservation then return reject('SLOT_LOST', reservationError) end
        local resolved, resolveError = registry.resolveIntent(
            lease.intentKey, lease.bundleRevision)
        if not resolved or resolved.bundle.key ~= lease.bundleKey
            or resolved.bundle.ownerResource ~= lease.ownerResource
            or resolved.bundle.ownerEpoch ~= lease.ownerEpoch then
            return reject('DEFINITION_CHANGED', resolveError or {
                code = 'INTERACT_INTENT_STALE',
                message = 'The interaction definition changed.', retryable = false,
            })
        end
        local dependenciesReady, dependencyError =
            registry.validateRuntimeDependencies(resolved)
        if not dependenciesReady then
            return reject('DEPENDENCY_UNAVAILABLE', dependencyError)
        end
        local canonical, targetError = validateResolvedTarget(
            resolved, lease.target, actorValue, renewalContext)
        if not canonical then return reject('TARGET_CHANGED', targetError) end
        if canonical.revision ~= lease.targetRevision then
            return reject('TARGET_STATE_CHANGED', {
                code = 'INTERACT_TARGET_STALE',
                message = 'The interaction target revision changed.', retryable = false,
            })
        end
        local worldFence, worldFenceError = validateWorldInstanceFence(
            lease.worldInstance, canonical)
        if not worldFence then
            return reject('WORLD_INSTANCE_CHANGED', worldFenceError)
        end
        local policyAllowed, policyError = checkPolicy(actorValue,
            resolved.intent.executionPolicy, resolved, renewalContext)
        if not policyAllowed then
            return rejectParticipant('CAPABILITY_REVOKED', policyError or {
                code = 'INTERACT_LEASE_DENIED',
                message = 'Interaction policy no longer permits the actor.', retryable = false,
            })
        end
        local available, availabilityError = validateAvailability(
            resolved, lease.slotClaims or {}, actorValue, 'RENEW',
            lease.target, canonical, renewalContext)
        if not available then
            return rejectParticipant('AVAILABILITY_CHANGED', availabilityError)
        end
        local refreshed, refreshError = refreshAuthority(resolved, lease.target,
            actorValue, renewalContext, lease.targetRevision,
            lease.worldInstance, true, 'INTERACT_LEASE_REVOKED')
        if not refreshed then
            return rejectParticipant('AUTHORITY_CHANGED', refreshError)
        end
        actorValue, canonical = refreshed.actor, refreshed.canonical
        local latest = refreshed.resolved
        local currentSession = sessions.get(lease.sessionId)
        local currentReservation, currentReservationError = slots.getReservation(
            lease.reservationId, lease.sessionId)
        if latest.bundle.key ~= lease.bundleKey
            or latest.bundle.ownerResource ~= lease.ownerResource
            or latest.bundle.ownerEpoch ~= lease.ownerEpoch
            or currentSession ~= session or currentSession.intentKey ~= lease.intentKey
            or currentSession.bundleRevision ~= lease.bundleRevision then
            return reject('DEFINITION_CHANGED', {
                code = 'INTERACT_INTENT_STALE',
                message = 'The interaction definition changed during renewal.', retryable = false,
            })
        end
        if not currentReservation then
            return reject('SLOT_LOST', currentReservationError)
        end
        timestamp = now()
        if lease.expiresAt <= timestamp or lease.maximumLifetimeAt <= timestamp then
            recordLeaseExpiry(lease)
            return rejectParticipant('LEASE_EXPIRED', {
                code = 'INTERACT_LEASE_EXPIRED',
                message = 'The interaction lease expired during renewal.', retryable = false,
            })
        end
        lease.expiresAt = math.min(lease.maximumLifetimeAt, timestamp + extensionMs)
        if lease.expiresAt <= timestamp then
            recordLeaseExpiry(lease)
            return reject('LEASE_EXPIRED', {
                code = 'INTERACT_LEASE_EXPIRED',
                message = 'The interaction lease maximum lifetime was reached.', retryable = false,
            })
        end
        observability.increment('lease_renewal_total', { outcome = 'accepted' }, 1)
        return { leaseId = lease.id, expiresAt = lease.expiresAt,
            capped = lease.expiresAt == lease.maximumLifetimeAt }, nil
    end

    function authority.expire(timestamp)
        local checked, seen = 0, {}
        while viabilityCursor ~= nil
            and checked < Limits.maximumActorViabilityChecksPerTick do
            local lease = leases[viabilityCursor]
            if not lease or seen[lease.id] then break end
            seen[lease.id] = true
            viabilityCursor = lease.viabilityNext
            checked = checked + 1
            local actorValue = {
                source = lease.source,
                sourceGeneration = lease.sourceGeneration,
                sessionIdentity = lease.sessionIdentity,
                characterId = lease.characterId,
                key = lease.actorKey,
            }
            local viable, viabilityError = actorViable(
                actorValue, 'INTERACT_LEASE_REVOKED')
            if not viable then cancelNonViableActor(actorValue, viabilityError) end
        end
        -- Long-running Action Graphs renew server-side. No client heartbeat or
        -- bearer-only service call is trusted; every renewal executes the full
        -- actor, definition, target, World, policy, availability and slot fence.
        local renewalIds = {}
        for id, lease in pairs(leases) do
            local session = sessions.get(lease.sessionId)
            local lead = math.min(1000,
                math.max(Limits.workerIntervalMs * 2,
                    math.floor((lease.renewalExtensionMs or 1000) / 2)))
            if lease.state == 'ACTIVE' and session and session.state == 'RUNNING'
                and lease.expiresAt > timestamp
                and lease.maximumLifetimeAt > timestamp
                and lease.expiresAt - timestamp <= lead then
                renewalIds[#renewalIds + 1] = id
            end
        end
        table.sort(renewalIds)
        for _, id in ipairs(renewalIds) do
            local lease = leases[id]
            if lease then authority.renewLease(id,
                lease.renewalExtensionMs or 1000, nil) end
        end
        sessions.expireInvitations(timestamp)
        local ids = {}
        for id, lease in pairs(leases) do
            if lease.expiresAt <= timestamp or lease.maximumLifetimeAt <= timestamp then ids[#ids + 1] = id end
        end
        local affectedSessions = {}
        for _, id in ipairs(ids) do
            local lease = leases[id]
            if lease then
                recordLeaseExpiry(lease)
                local session = sessions.get(lease.sessionId)
                affectedSessions[lease.sessionId] = true
                if session then
                    local result = sessions.leave(session.id, lease.actorKey, 'LEASE_EXPIRED')
                    if result then applyParticipantLoss(session, lease.actorKey,
                        result, 'LEASE_EXPIRED')
                    else releaseLease(lease, 'EXPIRED', 'LEASE_EXPIRED') end
                else releaseLease(lease, 'EXPIRED', 'LEASE_EXPIRED') end
            end
        end
        for sessionId in pairs(affectedSessions) do
            local session = sessions.get(sessionId)
            if session and not session.executionId and not activeSessionLease(sessionId) then
                slots.cleanupSession(sessionId)
                sessions.remove(sessionId)
            end
        end
        for _, session in ipairs(sessions.expired(timestamp)) do
            cancelRuntimeSession(session, 'TIMEOUT')
        end
        slots.expire(timestamp)
        return #ids
    end

    function authority.finishExecution(execution, state)
        local leaseState = state == 'COMPLETED' and 'COMPLETED'
            or state == 'FAILED' and 'FAILED'
            or state == 'TIMED_OUT' and 'EXPIRED' or 'CANCELLED'
        releaseSessionLeases(execution.sessionId, leaseState, state)
        slots.cleanupSession(execution.sessionId)
        sessions.remove(execution.sessionId)
        return true
    end

    function authority.revokeOwner(owner, epoch, reason)
        if graphRuntime then graphRuntime.cancelOwner(owner, epoch, reason or 'OWNER_STOPPED') end
        local affected = sessions.findOwner(owner, epoch)
        for _, session in ipairs(affected) do
            cancelRuntimeSession(session, reason or 'OWNER_STOPPED')
        end
        local orphanIds = {}
        for id, lease in pairs(leases) do
            if lease.ownerResource == owner and (epoch == nil or lease.ownerEpoch == epoch)
                and sessions.get(lease.sessionId) == nil then
                orphanIds[#orphanIds + 1] = id
            end
        end
        for _, id in ipairs(orphanIds) do
            releaseLease(leases[id], 'REVOKED', reason or 'OWNER_STOPPED')
        end
        authority.reconcileSlots()
        return #affected + #orphanIds
    end

    function authority.cleanupActor(source, sourceGeneration, reason)
        local key = tostring(source) .. ':' .. tostring(sourceGeneration)
        local affected = sessions.findActor(key)
        for _, session in ipairs(affected) do
            local result = sessions.leave(session.id, key, reason or 'PLAYER_DROPPED')
            if result then applyParticipantLoss(session, key, result,
                reason or 'PLAYER_DROPPED') end
        end
        local ids = {}
        for id, lease in pairs(leases) do if lease.actorKey == key then ids[#ids + 1] = id end end
        for _, id in ipairs(ids) do releaseLease(leases[id], 'REVOKED', reason or 'PLAYER_DROPPED') end
        locks.cleanupActor(key); requestRate.purge(key); activationRate.purge(key)
        return #affected
    end

    function authority.cleanupSource(source, reason)
        local generations = {}
        for _, lease in pairs(leases) do
            if lease.source == source then generations[lease.sourceGeneration] = true end
        end
        for _, record in ipairs(sessions.findSource(source)) do
            generations[record.sourceGeneration] = true
        end
        local removed = 0
        for generation in pairs(generations) do
            removed = removed + authority.cleanupActor(source, generation,
                reason or 'PLAYER_DROPPED')
        end
        return removed
    end

    local function countedRows(values, field)
        local keys, rows = {}, {}
        for key in pairs(values) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            rows[#rows + 1] = { [field] = key, count = values[key] }
        end
        return rows
    end

    function authority.inspectObject(objectKey)
        if not Validation.identifier(objectKey) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The Smart Object inspector key is invalid.')
        end
        local actors, states, roles, activeLeaseCount = {}, {}, {}, 0
        for _, lease in pairs(leases) do
            if lease.objectKey == objectKey and not terminalLeaseStates[lease.state] then
                activeLeaseCount = activeLeaseCount + 1
                actors[lease.actorKey] = true
                states[lease.state] = (states[lease.state] or 0) + 1
                roles[lease.role] = (roles[lease.role] or 0) + 1
            end
        end
        local activeActorCount = 0
        for _ in pairs(actors) do activeActorCount = activeActorCount + 1 end
        return {
            activeLeaseCount = activeLeaseCount,
            activeActorCount = activeActorCount,
            leaseStates = countedRows(states, 'state'),
            roles = countedRows(roles, 'role'),
            scanComplete = true,
        }, nil
    end

    function authority.inspectSessionLeases(sessionId)
        if not Validation.token(sessionId, 8, 96) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The interaction session inspector key is invalid.')
        end
        local states, count, nearestExpiryAt = {}, 0, nil
        for _, lease in pairs(leases) do
            if lease.sessionId == sessionId and not terminalLeaseStates[lease.state] then
                count = count + 1
                states[lease.state] = (states[lease.state] or 0) + 1
                nearestExpiryAt = nearestExpiryAt == nil and lease.expiresAt
                    or math.min(nearestExpiryAt, lease.expiresAt)
            end
        end
        local state, distinct = count == 0 and 'UNAVAILABLE' or nil, 0
        for candidate in pairs(states) do state, distinct = candidate, distinct + 1 end
        if distinct > 1 then state = 'MULTIPLE' end
        return {
            state = state, activeLeaseCount = count,
            leaseStates = countedRows(states, 'state'),
            nearestExpiryAt = nearestExpiryAt, scanComplete = true,
        }, nil
    end

    local function sessionParticipantSignature(session)
        local values = {}
        for _, role in pairs(session.roles or {}) do
            for actorKey, member in pairs(role.members or {}) do
                if member.ready ~= false then
                    values[#values + 1] = actorKey .. ':' .. tostring(member.leaseId)
                end
            end
        end
        table.sort(values)
        return table.concat(values, '|')
    end

    function authority.validateExecutionCommit(execution)
        if type(execution) ~= 'table' or not Validation.token(execution.id, 8, 96)
            or not Validation.token(execution.sessionId, 8, 96)
            or not Validation.token(execution.leaseId, 8, 96) then
            return Validation.failure('INTERACT_GRAPH_INVALID',
                'The Action Graph commit identity is invalid.')
        end
        local timestamp = now()
        local session = sessions.get(execution.sessionId)
        local resolved, resolveError = registry.resolveIntent(
            execution.intentKey, execution.bundleRevision)
        if not session or session.state ~= 'RUNNING'
            or session.executionId ~= execution.id
            or session.ownerResource ~= execution.ownerResource
            or session.ownerEpoch ~= execution.ownerEpoch
            or session.bundleRevision ~= execution.bundleRevision
            or session.intentKey ~= execution.intentKey
            or not resolved
            or resolved.bundle.ownerResource ~= execution.ownerResource
            or resolved.bundle.ownerEpoch ~= execution.ownerEpoch
            or resolved.graph.key ~= execution.graphKey then
            return nil, resolveError or { code = 'INTERACT_LEASE_STALE',
                message = 'The interaction execution authority changed.', retryable = false }
        end
        local dependenciesReady, dependencyError =
            registry.validateRuntimeDependencies(resolved)
        if not dependenciesReady then return nil, dependencyError end
        if not Validation.isCallable(currentSessionResolver) then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'The player session authority is unavailable.', true)
        end

        local signature = sessionParticipantSignature(session)
        local participants = {}
        for _, role in pairs(session.roles or {}) do
            for actorKey, member in pairs(role.members or {}) do
                if member.ready ~= false then
                    local lease = leases[member.leaseId]
                    if not lease or lease.state ~= 'ACTIVE'
                        or lease.sessionId ~= session.id
                        or lease.actorKey ~= actorKey
                        or lease.source ~= member.source
                        or lease.sourceGeneration ~= member.sourceGeneration
                        or lease.sessionIdentity ~= member.sessionIdentity
                        or lease.ownerResource ~= execution.ownerResource
                        or lease.ownerEpoch ~= execution.ownerEpoch
                        or lease.bundleRevision ~= execution.bundleRevision
                        or lease.expiresAt <= timestamp
                        or lease.maximumLifetimeAt <= timestamp then
                        return Validation.failure('INTERACT_LEASE_STALE',
                            'A participant lease is no longer valid for commit.')
                    end
                    local reservation, reservationError = slots.getReservation(
                        lease.reservationId, session.id)
                    if not reservation or reservation.state ~= 'OCCUPIED' then
                        return nil, reservationError or { code = 'INTERACT_SLOT_LOST',
                            message = 'A commit reservation is no longer occupied.',
                            retryable = false }
                    end
                    local playerSession, playerError = Foundation.protect(
                        currentSessionResolver, member.source)
                    if not playerSession or playerSession.state ~= 'ACTIVE'
                        or playerSession.source ~= member.source
                        or playerSession.sourceGeneration ~= member.sourceGeneration
                        or playerSession.id ~= member.sessionIdentity
                        or playerSession.characterId ~= lease.characterId then
                        return nil, playerError or { code = 'INTERACT_LEASE_STALE',
                            message = 'A participant player session changed before commit.',
                            retryable = false }
                    end
                    participants[#participants + 1] = {
                        member = member, actorKey = actorKey, lease = lease,
                        actor = {
                            source = member.source,
                            sourceGeneration = member.sourceGeneration,
                            sessionIdentity = member.sessionIdentity,
                            characterId = playerSession.characterId,
                            userId = playerSession.userId,
                            key = actorKey,
                        },
                        context = {
                            source = member.source,
                            sourceGeneration = member.sourceGeneration,
                            session = playerSession,
                            traceId = execution.traceId,
                        },
                    }
                    local participant = participants[#participants]
                    local viable, viabilityError = actorViable(
                        participant.actor, 'INTERACT_LEASE_REVOKED')
                    if not viable then
                        return cancelNonViableActor(
                            participant.actor, viabilityError)
                    end
                end
            end
        end
        if #participants == 0 then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction session has no active participants.')
        end
        table.sort(participants, function(left, right)
            return left.actorKey < right.actorKey
        end)

        for _, participant in ipairs(participants) do
            local policyAllowed, policyError = checkPolicy(participant.actor,
                resolved.intent.executionPolicy, resolved, participant.context)
            if not policyAllowed then return nil, policyError or {
                code = 'INTERACT_LEASE_DENIED',
                message = 'Interaction policy denied the commit.', retryable = false,
            } end
            local canonical, targetError = validateResolvedTarget(resolved,
                participant.lease.target, participant.actor, participant.context)
            if not canonical then return nil, targetError end
            local available, availabilityError = validateAvailability(resolved,
                participant.lease.slotClaims or {}, participant.actor,
                'COMMIT', participant.lease.target, canonical, participant.context)
            if not available then return nil, availabilityError end

            -- Availability/evaluator calls may yield; reacquire all canonical
            -- target evidence and actor identity before the commit can proceed.
            local refreshed, refreshError = refreshAuthority(resolved,
                participant.lease.target, participant.actor, participant.context,
                participant.lease.targetRevision,
                participant.lease.worldInstance, true, 'INTERACT_LEASE_REVOKED')
            if not refreshed then return nil, refreshError end
            local owned, lockError = locks.owns(participant.actorKey,
                execution.lockChannels or {}, session.id, execution.id)
            if not owned then return nil, lockError end
        end

        -- All calls below are yield-free and form the final mutation fence.
        if sessions.get(session.id) ~= session or session.state ~= 'RUNNING'
            or session.executionId ~= execution.id
            or sessionParticipantSignature(session) ~= signature then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The participant set changed before commit.')
        end
        timestamp = now()
        for _, participant in ipairs(participants) do
            local viable, viabilityError = actorViable(
                participant.actor, 'INTERACT_LEASE_REVOKED')
            if not viable then
                return cancelNonViableActor(participant.actor, viabilityError)
            end
            local lease = leases[participant.lease.id]
            local reservation, reservationError = slots.getReservation(
                participant.lease.reservationId, session.id)
            if lease ~= participant.lease or lease.state ~= 'ACTIVE'
                or lease.expiresAt <= timestamp or lease.maximumLifetimeAt <= timestamp
                or not reservation or reservation.state ~= 'OCCUPIED' then
                return nil, reservationError or { code = 'INTERACT_LEASE_STALE',
                    message = 'A commit lease or reservation changed.', retryable = false }
            end
            local owned, lockError = locks.owns(participant.actorKey,
                execution.lockChannels or {}, session.id, execution.id)
            if not owned then return nil, lockError end
        end
        return true, nil
    end

    function authority.getLease(id) return leases[id] end
    function authority.validateTargetFence(leaseId, canonical)
        local lease = leases[leaseId]
        if not lease or terminalLeaseStates[lease.state] then
            return Validation.failure('INTERACT_LEASE_STALE',
                'The interaction lease is unavailable.')
        end
        return validateWorldInstanceFence(lease.worldInstance, canonical)
    end
    function authority.listLeases(cursor, limit)
        local values = {}
        for _, lease in pairs(leases) do
            values[#values + 1] = { state = lease.state, intent = lease.intentKey,
                ownerResource = lease.ownerResource, bundleRevision = lease.bundleRevision,
                issuedAt = lease.issuedAt, expiresAt = lease.expiresAt,
                role = lease.role }
        end
        table.sort(values, function(left, right)
            if left.issuedAt == right.issuedAt then return left.intent < right.intent end
            return left.issuedAt < right.issuedAt
        end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + size - 1) do items[#items + 1] = values[index] end
        local hasMore = start + #items - 1 < #values
        return { items = items, nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end
    function authority.snapshot()
        local actors = 0
        for _, count in pairs(actorLeaseCount) do if count > 0 then actors = actors + 1 end end
        return { activeLeases = leaseCount, actorsWithLeases = actors,
            maximumActiveLeases = Limits.maximumActiveLeases }
    end
    return authority
end
