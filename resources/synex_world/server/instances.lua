SynexWorldInstances = {}

local Instances = SynexWorldInstances
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function validReference(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

function Instances.create(options)
    local registry = assert(options.registry, 'world instances require a registry')
    local mapRegistry = assert(options.mapRegistry, 'world instances require maps')
    local callContract = assert(options.callContract, 'world instances require entity contracts')
    local getPlayer = assert(options.getPlayer, 'world instances require player sessions')
    local nextId = assert(options.nextId, 'world instances require IDs')
    local now = assert(options.now, 'world instances require monotonic time')
    local utc = assert(options.utc, 'world instances require UTC time')
    local triggerClient = assert(options.triggerClient,
        'world instances require client projection')
    local emit = options.emit or function() end
    local audit = options.audit or function() end
    local onClosed, onCleanupError = options.onClosed, options.onCleanupError
    if onClosed ~= nil and not callable(onClosed)
        or onCleanupError ~= nil and not callable(onCleanupError) then
        error('world instance cleanup dependencies are invalid', 0)
    end
    local records, sourceMembership, sourceMutations, pendingTemplateCleanup = {}, {}, {}, {}
    local pendingExitGrants, mutationExitGrants, pendingExitGrantCount = {}, {}, 0
    local maximumPendingExitGrants = 4096
    local orderedIds, closedHead, closedTail, closedCount, liveCount = {}, nil, nil, 0, 0
    local pendingClosedCleanup, cleanupHead, cleanupTail, pendingCleanupCount = {}, nil, nil, 0
    local pendingBucketRecovery, bucketRecoveryHead, bucketRecoveryTail = {}, nil, nil
    local pendingBucketRecoveryCount = 0
    local maximumClosedInstances = Validation.isInteger(options.maximumClosedInstances,
        1, Limits.maximumClosedInstances) and options.maximumClosedInstances
        or Limits.maximumClosedInstances
    local statistics = { total = 0, creating = 0, ready = 0, active = 0,
        draining = 0, closed = 0, failed = 0, members = 0 }
    local instances = {}
    local snapshot

    local function cancelExitGrant(grantId)
        local grant = pendingExitGrants[grantId]
        if not grant then return false end
        pendingExitGrants[grantId] = nil
        pendingExitGrantCount = pendingExitGrantCount - 1
        local owned = mutationExitGrants[grant.mutation]
        if owned then
            owned[grantId] = nil
            if next(owned) == nil then mutationExitGrants[grant.mutation] = nil end
        end
        return true
    end

    local function cancelMutationExitGrants(token)
        local owned = mutationExitGrants[token]
        if not owned then return end
        local grantIds = {}
        for grantId in pairs(owned) do grantIds[#grantIds + 1] = grantId end
        for _, grantId in ipairs(grantIds) do cancelExitGrant(grantId) end
        mutationExitGrants[token] = nil
    end

    local function allocateExitIdentifier(namespace)
        local identifier, identifierError = nextId(namespace)
        if not validReference(identifier, 8, 36) then
            return nil, identifierError or select(2, Validation.failure(
                'CORE_UNAVAILABLE', 'World exit transition identifier is unavailable.', true))
        end
        return identifier
    end

    local function reserveExitGrant(record, source, membership, destination, fence)
        if pendingExitGrantCount >= maximumPendingExitGrants then
            return Validation.failure('QUERY_LIMIT_EXCEEDED',
                'World exit transition capacity is exhausted.', true)
        end
        local grantId, grantError = allocateExitIdentifier('wxg')
        if not grantId then return nil, grantError end
        local moveKey, moveError = allocateExitIdentifier('wxm')
        if not moveKey then return nil, moveError end
        local rollbackKey, rollbackError = allocateExitIdentifier('wxr')
        if not rollbackKey then return nil, rollbackError end
        if grantId == moveKey or grantId == rollbackKey or moveKey == rollbackKey
            or pendingExitGrants[grantId] ~= nil then
            return Validation.failure('CORE_UNAVAILABLE',
                'World exit transition identifiers are not unique.', true)
        end
        local mutation = record.mutation
        local grant = {
            grantId = grantId, moveKey = moveKey, rollbackKey = rollbackKey,
            mutation = mutation, instanceId = record.instanceId, source = source,
            sessionId = membership.sessionId,
            sourceGeneration = membership.sourceGeneration,
            templateRef = Validation.copy(record.templateRef),
            destination = Validation.copy(destination), fence = fence,
        }
        pendingExitGrants[grantId] = grant
        pendingExitGrantCount = pendingExitGrantCount + 1
        local owned = mutationExitGrants[mutation]
        if not owned then owned = {}; mutationExitGrants[mutation] = owned end
        owned[grantId] = true
        return grant
    end

    local function consumeExitGrant(grant)
        if pendingExitGrants[grant.grantId] ~= grant then
            return Validation.failure('TRANSITION_GRANT_REPLAYED',
                'World exit transition grant is no longer active.')
        end
        cancelExitGrant(grant.grantId)
        return grant
    end

    local function orderedPosition(id)
        local low, high = 1, #orderedIds + 1
        while low < high do
            local middle = math.floor((low + high) / 2)
            if middle <= #orderedIds and orderedIds[middle] < id then low = middle + 1
            else high = middle end
        end
        return low
    end

    local function removeOrdered(id)
        local position = orderedPosition(id)
        if orderedIds[position] == id then table.remove(orderedIds, position) end
    end

    local function evictClosedHistory()
        while closedCount > maximumClosedInstances do
            local oldest = closedHead
            closedHead = oldest.closedNext
            if closedHead then closedHead.closedPrevious = nil else closedTail = nil end
            oldest.closedPrevious, oldest.closedNext = nil, nil
            closedCount = closedCount - 1
            if records[oldest.instanceId] == oldest and oldest.state == 'CLOSED' then
                records[oldest.instanceId] = nil
                pendingTemplateCleanup[oldest.instanceId] = nil
                removeOrdered(oldest.instanceId)
                statistics.total = statistics.total - 1
                statistics.closed = statistics.closed - 1
            end
        end
    end

    local function rememberClosed(record)
        record.closedPrevious, record.closedNext = closedTail, nil
        if closedTail then closedTail.closedNext = record else closedHead = record end
        closedTail, closedCount = record, closedCount + 1
        evictClosedHistory()
    end

    local function transition(record, nextState)
        local previous = record.state
        if previous == nextState then return end
        statistics[previous:lower()] = statistics[previous:lower()] - 1
        statistics[nextState:lower()] = statistics[nextState:lower()] + 1
        record.state = nextState
        if previous ~= 'CLOSED' and nextState == 'CLOSED' then
            liveCount = liveCount - 1
            rememberClosed(record)
        end
    end

    local function registerRecord(record)
        if records[record.instanceId] ~= nil then return false end
        records[record.instanceId] = record
        table.insert(orderedIds, orderedPosition(record.instanceId), record.instanceId)
        statistics.total, statistics.creating = statistics.total + 1,
            statistics.creating + 1
        liveCount = liveCount + 1
        return true
    end

    local function withMutation(record, sources, handler)
        if record.mutation ~= nil then
            return Validation.failure('CONCURRENT_MODIFICATION',
                'World instance is already being changed.', true)
        end
        local token, acquired, seen = {}, {}, {}
        for _, source in ipairs(sources or {}) do
            if not seen[source] and sourceMutations[source] ~= nil then
                return Validation.failure('CONCURRENT_MODIFICATION',
                    'World instance player is already being changed.', true)
            end
            if not seen[source] then acquired[#acquired + 1], seen[source] = source, true end
        end
        for _, source in ipairs(acquired) do
            sourceMutations[source] = token
        end
        record.mutation = token
        local called, result, operationError = pcall(handler)
        cancelMutationExitGrants(token)
        if record.mutation == token then record.mutation = nil end
        for _, source in ipairs(acquired) do
            if sourceMutations[source] == token then sourceMutations[source] = nil end
        end
        if not called then
            return Validation.failure('UNAVAILABLE',
                'World instance operation failed unexpectedly.', true)
        end
        return result, operationError
    end

    local function reportCleanupError(instanceId, operationError)
        if not onCleanupError then return end
        local code = type(operationError) == 'table' and operationError.code or nil
        if type(code) ~= 'string' or #code < 1 or #code > 64 then
            code = 'INSTANCE_CLEANUP_CALLBACK_FAILED'
        end
        pcall(onCleanupError, { operation = 'instance.on_closed',
            instanceId = instanceId, code = code })
    end

    local function removeClosedCleanup(entry)
        if entry.previous then entry.previous.next = entry.next else cleanupHead = entry.next end
        if entry.next then entry.next.previous = entry.previous else cleanupTail = entry.previous end
        pendingClosedCleanup[entry.instanceId] = nil
        entry.previous, entry.next = nil, nil
        pendingCleanupCount = pendingCleanupCount - 1
    end

    local function rotateClosedCleanup(entry)
        if cleanupTail == entry then return end
        if entry.previous then entry.previous.next = entry.next else cleanupHead = entry.next end
        if entry.next then entry.next.previous = entry.previous end
        entry.previous, entry.next = cleanupTail, nil
        if cleanupTail then cleanupTail.next = entry else cleanupHead = entry end
        cleanupTail = entry
    end

    local function enqueueClosedCleanup(instanceId, closedSnapshot, context)
        if pendingClosedCleanup[instanceId] then return true end
        if pendingCleanupCount >= Limits.maximumPendingInstanceCleanups then return false end
        local entry = { instanceId = instanceId,
            snapshot = Validation.copy(closedSnapshot),
            context = { traceId = context and context.traceId },
            previous = cleanupTail }
        if cleanupTail then cleanupTail.next = entry else cleanupHead = entry end
        cleanupTail, pendingClosedCleanup[instanceId] = entry, entry
        pendingCleanupCount = pendingCleanupCount + 1
        return true
    end

    local function runClosedCleanup(instanceId, closedSnapshot, context)
        if not onClosed then return true end
        local called, callbackResult, callbackError = pcall(onClosed,
            instanceId, Validation.copy(closedSnapshot), context)
        if called and callbackResult ~= false
            and (callbackResult ~= nil or callbackError == nil) then return true end
        return false, called and callbackError or callbackResult
    end

    local function removeBucketRecovery(entry)
        if entry.previous then entry.previous.next = entry.next
        else bucketRecoveryHead = entry.next end
        if entry.next then entry.next.previous = entry.previous
        else bucketRecoveryTail = entry.previous end
        pendingBucketRecovery[entry.instanceId] = nil
        entry.previous, entry.next = nil, nil
        pendingBucketRecoveryCount = pendingBucketRecoveryCount - 1
    end

    local function rotateBucketRecovery(entry)
        if bucketRecoveryTail == entry then return end
        if entry.previous then entry.previous.next = entry.next
        else bucketRecoveryHead = entry.next end
        if entry.next then entry.next.previous = entry.previous end
        entry.previous, entry.next = bucketRecoveryTail, nil
        if bucketRecoveryTail then bucketRecoveryTail.next = entry
        else bucketRecoveryHead = entry end
        bucketRecoveryTail = entry
    end

    local function enqueueBucketRecovery(record, phase, context, notifyClosed,
            transitionedMembers)
        local existing = pendingBucketRecovery[record.instanceId]
        if existing then
            if phase == 'create' then existing.phase = 'create' end
            existing.notifyClosed = existing.notifyClosed or notifyClosed == true
            existing.transitionedMembers = math.max(existing.transitionedMembers or 0,
                transitionedMembers or 0)
            return true
        end
        if pendingBucketRecoveryCount >= Limits.maximumPendingInstanceCleanups then
            return false
        end
        local entry = { instanceId = record.instanceId, phase = phase,
            notifyClosed = notifyClosed == true,
            transitionedMembers = transitionedMembers or 0,
            traceId = context and context.traceId, previous = bucketRecoveryTail }
        if bucketRecoveryTail then bucketRecoveryTail.next = entry
        else bucketRecoveryHead = entry end
        bucketRecoveryTail = entry
        pendingBucketRecovery[record.instanceId] = entry
        pendingBucketRecoveryCount = pendingBucketRecoveryCount + 1
        return true
    end

    local function terminalClose(record, transitionedMembers, context, notifyClosed)
        record.bucketRef, record.failure = nil, nil
        transition(record, 'CLOSED')
        record.revision = record.revision + 1
        pendingTemplateCleanup[record.instanceId] = nil
        local closedSnapshot = snapshot(record)
        closedSnapshot.transitionedMembers = transitionedMembers or 0
        if notifyClosed then
            local cleaned, cleanupError = runClosedCleanup(
                record.instanceId, closedSnapshot, context)
            if not cleaned then
                if not enqueueClosedCleanup(record.instanceId, closedSnapshot, context) then
                    cleanupError = { code = 'INSTANCE_CLEANUP_QUEUE_EXHAUSTED' }
                end
                reportCleanupError(record.instanceId, cleanupError)
            end
            emit('synex.world.instance.closed', closedSnapshot, context)
            audit('world.instance_closed', 'world_instance', record.instanceId,
                closedSnapshot, context)
        end
        return closedSnapshot
    end

    local function startEmptyTimer(record)
        if record.cleanupPolicy == 'empty_ttl' and next(record.members) == nil then
            record.expiresAtMs = now() + record.emptyTtlSeconds * 1000
        else
            record.expiresAtMs = nil
        end
    end

    snapshot = function(record, includeMembers)
        local members = 0
        for _ in pairs(record.members) do members = members + 1 end
        local value = { instanceId = record.instanceId,
            template = Validation.copy(record.templateRef), ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch, state = record.state, capacity = record.capacity,
            members = members, createdAt = record.createdAt, expiresAtMs = record.expiresAtMs,
            revision = record.revision, cleanupPolicy = record.cleanupPolicy,
            bucketRef = Validation.copy(record.bucketRef) }
        if includeMembers then
            value.memberSources = {}
            for source in pairs(record.members) do value.memberSources[#value.memberSources + 1] = source end
            table.sort(value.memberSources)
        end
        return value
    end

    local function currentSession(source, expected)
        local session, sessionError = getPlayer(source)
        if not session then
            if type(sessionError) == 'table' and sessionError.retryable == true then
                return nil, sessionError
            end
            return Validation.failure('STALE_RESOURCE',
                'Player session changed during world instance operation.')
        end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string'
            or expected and (session.id ~= expected.sessionId
                or session.sourceGeneration ~= expected.sourceGeneration) then
            return Validation.failure('STALE_RESOURCE', 'Player session changed during world instance operation.')
        end
        return session
    end

    local function owned(record, context, allowWorldLifecycle)
        local caller, callerEpoch = context and context.caller,
            context and context.callerEpoch
        if allowWorldLifecycle and caller == 'synex_world' then return true end
        if type(caller) ~= 'string'
            or not Validation.isInteger(callerEpoch, 1, 9007199254740991) then
            return Validation.failure('STALE_RESOURCE',
                'World instance caller lifecycle is invalid.')
        end
        if caller == record.ownerResource and callerEpoch ~= record.ownerEpoch then
            return Validation.failure('STALE_RESOURCE',
                'World instance caller epoch is stale.')
        end
        if caller ~= record.ownerResource then
            return Validation.failure('WORLD_ACCESS_DENIED',
                'World instance belongs to another resource.')
        end
        return true
    end

    local function removeMembership(record, source)
        if record.members[source] ~= nil then
            statistics.members = statistics.members - 1
        end
        record.members[source], sourceMembership[source] = nil, nil
        if next(record.members) == nil and record.state == 'ACTIVE' then
            transition(record, 'READY')
            record.revision = record.revision + 1
            startEmptyTimer(record)
        end
    end

    local function restoreMembership(record, source, membership)
        if record.members[source] ~= nil or sourceMembership[source] ~= nil then
            return Validation.failure('CONCURRENT_MODIFICATION',
                'World instance membership changed during exit compensation.', true)
        end
        record.members[source] = membership
        sourceMembership[source] = record.instanceId
        statistics.members = statistics.members + 1
        record.expiresAtMs = nil
        if record.state == 'READY' then
            transition(record, 'ACTIVE')
            record.revision = record.revision + 1
        end
        return true
    end

    local function currentRegistryRevision()
        if not callable(registry.currentRevision) then return 0 end
        local revision = registry.currentRevision()
        return Validation.isInteger(revision, 0, 2147483647) and revision or nil
    end

    local function currentMapGeneration()
        if type(mapRegistry) ~= 'table' or not callable(mapRegistry.summary) then return nil end
        local summary = mapRegistry.summary()
        return Validation.isPlainTable(summary)
            and Validation.isInteger(summary.generation, 0, 2147483647)
            and summary.generation or nil
    end

    local function prepareTemplateFence(record, allowUnavailable)
        local activeTemplate, templateError = registry.resolve(
            record.templateRef, 'instance_template')
        if not activeTemplate and not allowUnavailable then
            return nil, templateError or select(2, Validation.failure(
                'STALE_WORLD_REF', 'World instance template changed before exit.'))
        end
        local checkedTemplate = activeTemplate or record.template
        local availability = mapRegistry.objectAvailability(checkedTemplate)
        if not Validation.isPlainTable(availability) then
            return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                'World instance exit map availability is unknown.', true)
        end
        if not allowUnavailable and availability.available ~= true then
            return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                'World instance exit map package is unavailable.', true)
        end
        local registryRevision, mapGeneration = currentRegistryRevision(),
            currentMapGeneration()
        if registryRevision == nil or mapGeneration == nil then
            return Validation.failure('UNAVAILABLE',
                'World instance exit lifecycle fence is unavailable.', true)
        end
        return {
            templateActive = activeTemplate ~= nil,
            templateRef = Validation.copy(record.templateRef),
            registryRevision = registryRevision, mapGeneration = mapGeneration,
            requireAvailability = not allowUnavailable,
            bucket = record.bucketRef and record.bucketRef.bucket,
            bucketGeneration = record.bucketRef and record.bucketRef.generation,
        }
    end

    local function prepareExitFence(record, allowUnavailable)
        local destination, destinationError = Validation.vector3(record.exit)
        if not destination then return nil, destinationError end
        local fence, fenceError = prepareTemplateFence(record, allowUnavailable)
        if not fence then return nil, fenceError end
        return fence, destination
    end

    local function revalidateTemplateFence(record, fence)
        if not record.bucketRef or record.bucketRef.bucket ~= fence.bucket
            or record.bucketRef.generation ~= fence.bucketGeneration then
            return Validation.failure('CONCURRENT_MODIFICATION',
                'World instance bucket changed during operation.', true)
        end
        if currentRegistryRevision() ~= fence.registryRevision
            or currentMapGeneration() ~= fence.mapGeneration then
            return Validation.failure('STALE_WORLD_REF',
                'World definitions changed during instance exit.', true)
        end
        if fence.templateActive then
            local template, templateError = registry.resolve(
                fence.templateRef, 'instance_template')
            if not template then return nil, templateError end
            if fence.requireAvailability then
                local availability = mapRegistry.objectAvailability(template)
                if not Validation.isPlainTable(availability)
                    or availability.available ~= true then
                    return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                        'World instance exit map package changed.', true)
                end
            end
        end
        return true
    end

    local function revalidateExitFence(record, source, membership, fence)
        if record.members[source] ~= membership then
            return Validation.failure('CONCURRENT_MODIFICATION',
                'World instance membership changed during exit.', true)
        end
        return revalidateTemplateFence(record, fence)
    end

    local function compensateExit(record, grant, context)
        local session, sessionError = currentSession(grant.source, {
            sessionId = grant.sessionId,
            sourceGeneration = grant.sourceGeneration,
        })
        if not session then return nil, sessionError end
        if not record.bucketRef or record.bucketRef.bucket ~= grant.fence.bucket
            or record.bucketRef.generation ~= grant.fence.bucketGeneration then
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'World instance exit compensation bucket changed.', true)
        end
        local rolledBack, rollbackError = callContract(
            'synex.entities.bucket.move_player', '1.0.0', {
                source = grant.source, bucket = grant.fence.bucket,
                bucketGeneration = grant.fence.bucketGeneration,
            }, { traceId = context and context.traceId,
                idempotencyKey = grant.rollbackKey })
        if not rolledBack then
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'World instance exit compensation failed.', true,
                { cause = rollbackError and rollbackError.code })
        end
        return true
    end

    local function transitionMemberToExit(record, source, membership, context,
            allowUnavailable)
        local fence, destination = prepareExitFence(record, allowUnavailable)
        if not fence then return nil, destination end
        local current, currentError = currentSession(source, membership)
        if not current then return nil, currentError end
        local grant, grantError = reserveExitGrant(record, source, membership,
            destination, fence)
        if not grant then return nil, grantError end
        local moved, moveError = callContract(
            'synex.entities.bucket.move_player', '1.0.0', {
                source = source, bucket = 0, bucketGeneration = 0,
            }, { traceId = context and context.traceId,
                idempotencyKey = grant.moveKey })
        if not moved then
            cancelExitGrant(grant.grantId)
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'Player could not leave the world instance.', true,
                { cause = moveError and moveError.code })
        end
        current, currentError = currentSession(source, membership)
        if not current then
            cancelExitGrant(grant.grantId)
            if type(currentError) == 'table' and currentError.code == 'STALE_RESOURCE' then
                removeMembership(record, source)
                return nil, currentError, true
            end
            local rolledBack, rollbackError = compensateExit(record, grant, context)
            if not rolledBack then return nil, rollbackError end
            return nil, currentError
        end
        local fenced, fenceError = revalidateExitFence(record, source, membership, fence)
        if not fenced then
            cancelExitGrant(grant.grantId)
            local rolledBack, rollbackError = compensateExit(record, grant, context)
            if not rolledBack then return nil, rollbackError end
            return nil, fenceError
        end
        local consumed, consumeError = consumeExitGrant(grant)
        if not consumed then
            local rolledBack, rollbackError = compensateExit(record, grant, context)
            if not rolledBack then return nil, rollbackError end
            return nil, consumeError
        end
        removeMembership(record, source)
        local projected = pcall(triggerClient, source,
            'synex_world:client:apply_transition', {
                schemaVersion = Limits.schemaVersion,
                revision = grant.templateRef.revision,
                grantId = grant.grantId,
                destination = Validation.copy(grant.destination),
            })
        if not projected then
            local rolledBack, rollbackError = compensateExit(record, grant, context)
            if rolledBack then
                local restored, restoreError = restoreMembership(record, source, membership)
                if not restored then return nil, restoreError end
            end
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'World instance exit projection failed.', true,
                { cause = rollbackError and rollbackError.code })
        end
        audit('world.instance_member_exit_applied', 'world_instance',
            record.instanceId, { source = source, template = grant.templateRef }, context)
        return grant
    end

    function instances.create(request, context)
        if not Validation.exactObject(request or {}, {
                templateRef = true, templateKey = true, capacity = true,
                idempotencyKey = true,
            }) or (request.templateRef == nil) == (request.templateKey == nil)
            or request.capacity ~= nil and not Validation.isInteger(
                request.capacity, 1, Limits.maximumInstanceMembers)
            or not validReference(request.idempotencyKey, 8, 36) then
            return Validation.failure('INVALID_ARGUMENT', 'World instance request is invalid.')
        end
        if liveCount + pendingCleanupCount >= Limits.maximumInstances then
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE', 'World instance capacity is exhausted.', true)
        end
        local template, templateError
        if request.templateRef then
            template, templateError = registry.resolve(request.templateRef, 'instance_template')
        else
            template, templateError = registry.get(request.templateKey, 'instance_template')
        end
        if not template then
            if templateError then return nil, templateError end
            return Validation.failure('WORLD_NOT_FOUND',
                'World instance template does not exist.')
        end
        local templateAvailability = mapRegistry.objectAvailability(template)
        if not Validation.isPlainTable(templateAvailability)
            or templateAvailability.available ~= true then
            return Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                'World instance template map package is unavailable.', true)
        end
        local caller = context and context.caller
        local callerEpoch = context and context.callerEpoch
        if type(caller) ~= 'string' or not Validation.isInteger(callerEpoch, 1, 9007199254740991) then
            return Validation.failure('STALE_RESOURCE', 'World instance caller lifecycle is invalid.')
        end
        local instanceId, idError = nextId('world_instance')
        if not validReference(instanceId, 8, 64) then
            return nil, idError or select(2, Validation.failure('CORE_UNAVAILABLE',
                'World instance identifier is unavailable.', true))
        end
        local templateRef = registry.ref(template)
        local exit = Validation.vector3(template.exit)
        if not Validation.isPlainTable(templateRef) or not exit then
            return Validation.failure('WORLD_REFERENCE_INVALID',
                'World instance template exit is invalid.')
        end
        local createRegistryRevision, createMapGeneration = currentRegistryRevision(),
            currentMapGeneration()
        if createRegistryRevision == nil or createMapGeneration == nil then
            return Validation.failure('UNAVAILABLE',
                'World instance creation lifecycle fence is unavailable.', true)
        end
        local createKey, createKeyError = allocateExitIdentifier('wxbc')
        if not createKey then return nil, createKeyError end
        local destroyKey, destroyKeyError = allocateExitIdentifier('wxbd')
        if not destroyKey then return nil, destroyKeyError end
        if createKey == destroyKey then
            return Validation.failure('CORE_UNAVAILABLE',
                'World bucket operation identifiers are not unique.', true)
        end
        local bucketRequest = {
            profile = template.isolationProfile,
            purpose = ('world:%s'):format(instanceId):sub(1, 64),
            lockdown = template.isolationProfile == 'custom' and 'strict' or nil,
            populationEnabled = false,
            capacity = { maxPlayers = math.min(request.capacity or template.capacity,
                template.capacity), maxEntities = 1000 },
        }
        local record = { instanceId = instanceId, template = template,
            templateRef = Validation.copy(templateRef), exit = exit,
            createKey = createKey, destroyKey = destroyKey,
            bucketRequest = bucketRequest,
            ownerResource = caller, ownerEpoch = callerEpoch, state = 'CREATING',
            members = {}, capacity = math.min(request.capacity or template.capacity, template.capacity),
            createdAt = utc(), createdAtMs = now(), revision = 1,
            cleanupPolicy = template.cleanupPolicy,
            emptyTtlSeconds = template.cleanupPolicy == 'empty_ttl'
                and template.ttlSeconds or nil,
            expiresAtMs = nil, mutation = {} }
        if not registerRecord(record) then
            return Validation.failure('CONCURRENT_MODIFICATION',
                'World instance identifier is already active.', true)
        end
        local bucketResult, bucketError = callContract('synex.entities.bucket.create', '2.0.0',
            Validation.copy(record.bucketRequest), {
                traceId = context.traceId, idempotencyKey = record.createKey })
        if not bucketResult or not Validation.isPlainTable(bucketResult.bucket) then
            record.mutation = nil
            record.failure = bucketError and bucketError.code or 'UNAVAILABLE'
            if bucketResult == nil and type(bucketError) == 'table'
                and bucketError.retryable == false then
                terminalClose(record, 0, context, false)
            else
                transition(record, 'FAILED')
                record.revision = record.revision + 1
                if not enqueueBucketRecovery(record, 'create', context, false, 0) then
                    record.failure = 'INSTANCE_CLEANUP_QUEUE_EXHAUSTED'
                end
            end
            if record.cancelled == true then
                return Validation.failure('STALE_RESOURCE',
                    'World instance owner stopped while bucket creation was reconciled.', true)
            end
            return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'World instance routing bucket could not be created.', true)
        end
        record.bucketRef = { bucket = bucketResult.bucket.bucket,
            generation = bucketResult.bucket.generation }
        if record.cancelled == true then
            local destroyed, destroyError = callContract(
                'synex.entities.bucket.destroy', '1.0.0', {
                    bucket = record.bucketRef.bucket, generation = record.bucketRef.generation,
                }, { traceId = context.traceId,
                    idempotencyKey = record.destroyKey })
            if not destroyed then
                record.mutation = nil
                record.failure = destroyError and destroyError.code or 'UNAVAILABLE'
                transition(record, 'FAILED')
                record.revision = record.revision + 1
                if not enqueueBucketRecovery(record, 'destroy', context, false, 0) then
                    record.failure = 'INSTANCE_CLEANUP_QUEUE_EXHAUSTED'
                end
                return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                    'Cancelled World instance bucket cleanup failed.', true)
            end
            record.mutation = nil
            terminalClose(record, 0, context, false)
            return Validation.failure('STALE_RESOURCE',
                'World instance owner stopped while the instance was created.', true)
        end
        local currentTemplate, currentTemplateError = registry.resolve(
            templateRef, 'instance_template')
        local currentAvailability = currentTemplate
            and mapRegistry.objectAvailability(currentTemplate) or nil
        local creationError
        if currentRegistryRevision() ~= createRegistryRevision
            or currentMapGeneration() ~= createMapGeneration
            or not currentTemplate then
            creationError = currentTemplateError or select(2, Validation.failure(
                'STALE_WORLD_REF', 'World instance template changed during creation.', true))
        elseif not Validation.isPlainTable(currentAvailability)
            or currentAvailability.available ~= true then
            creationError = select(2, Validation.failure('MAP_PACKAGE_UNAVAILABLE',
                'World instance template map package changed during creation.', true))
        end
        if creationError then
            local destroyed, destroyError = callContract(
                'synex.entities.bucket.destroy', '1.0.0', {
                    bucket = record.bucketRef.bucket, generation = record.bucketRef.generation,
                }, { traceId = context.traceId,
                    idempotencyKey = record.destroyKey })
            record.mutation = nil
            record.revision = record.revision + 1
            if not destroyed then
                record.failure = destroyError and destroyError.code or 'UNAVAILABLE'
                transition(record, 'FAILED')
                if not enqueueBucketRecovery(record, 'destroy', context, false, 0) then
                    record.failure = 'INSTANCE_CLEANUP_QUEUE_EXHAUSTED'
                end
                return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                    'Stale World instance bucket compensation failed.', true,
                    { cause = creationError.code,
                        rollbackCause = destroyError and destroyError.code })
            end
            terminalClose(record, 0, context, false)
            return nil, creationError
        end
        record.mutation = nil
        transition(record, 'READY')
        record.revision = 2
        startEmptyTimer(record)
        emit('synex.world.instance.created', snapshot(record), context)
        audit('world.instance_created', 'world_instance', instanceId, snapshot(record), context)
        return snapshot(record)
    end

    function instances.join(request, context)
        if not Validation.exactObject(request or {}, {
                instanceId = true, source = true, idempotencyKey = true,
            }) or not validReference(request.instanceId, 8, 64)
            or not Validation.isInteger(request.source, 1, 65535)
            or not validReference(request.idempotencyKey, 8, 36) then
            return Validation.failure('INVALID_ARGUMENT', 'World instance join request is invalid.')
        end
        local record = records[request.instanceId]
        if not record then return Validation.failure('INSTANCE_NOT_FOUND', 'World instance does not exist.') end
        local authorized, ownershipError = owned(record, context, false)
        if not authorized then return nil, ownershipError end
        return withMutation(record, { request.source }, function()
            if record.state ~= 'READY' and record.state ~= 'ACTIVE' then
                return Validation.failure('INSTANCE_CLOSED',
                    'World instance does not accept members.')
            end
            local existing = sourceMembership[request.source]
            if existing and existing ~= record.instanceId then
                return Validation.failure('WRONG_INSTANCE',
                    'Player already belongs to another world instance.')
            end
            local recordedMembership = record.members[request.source]
            if recordedMembership then
                local current, currentError = currentSession(request.source, recordedMembership)
                if current then return snapshot(record) end
                if type(currentError) ~= 'table' or currentError.code ~= 'STALE_RESOURCE' then
                    return nil, currentError
                end
                removeMembership(record, request.source)
            end
            local memberCount = 0
            for _ in pairs(record.members) do memberCount = memberCount + 1 end
            if memberCount >= record.capacity then
                return Validation.failure('INSTANCE_FULL', 'World instance is full.')
            end
            local templateFence, templateFenceError = prepareTemplateFence(record, false)
            if not templateFence then return nil, templateFenceError end
            local session, sessionError = currentSession(request.source)
            if not session then return nil, sessionError end
            local expected = { sessionId = session.id,
                sourceGeneration = session.sourceGeneration }
            local moveKey, moveKeyError = allocateExitIdentifier('wxjm')
            if not moveKey then return nil, moveKeyError end
            local rollbackKey, rollbackKeyError = allocateExitIdentifier('wxjr')
            if not rollbackKey then return nil, rollbackKeyError end
            if moveKey == rollbackKey then
                return Validation.failure('CORE_UNAVAILABLE',
                    'World join transition identifiers are not unique.', true)
            end
            local moveRequest = {
                    source = request.source, bucket = record.bucketRef.bucket,
                    bucketGeneration = record.bucketRef.generation,
                }
            local function moveIntoInstance()
                return callContract('synex.entities.bucket.move_player', '1.0.0',
                    moveRequest, { traceId = context.traceId,
                        idempotencyKey = moveKey })
            end
            local moved, moveError = moveIntoInstance()
            if not moved and type(moveError) == 'table'
                and moveError.retryable == true then
                moved, moveError = moveIntoInstance()
            end
            if not moved then return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                'Player could not enter the world instance.', true,
                { cause = moveError and moveError.code }) end
            local current, currentError = currentSession(request.source, expected)
            if not current then
                local rolledBack, rollbackError = callContract(
                    'synex.entities.bucket.move_player', '1.0.0', {
                        source = request.source, bucket = 0, bucketGeneration = 0,
                    }, { traceId = context.traceId,
                        idempotencyKey = rollbackKey })
                if not rolledBack then
                    return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                        'Player session changed and the instance move could not be rolled back.', true,
                        { cause = currentError and currentError.code,
                            rollbackCause = rollbackError and rollbackError.code })
                end
                return nil, currentError
            end
            local fenced, fencedError = revalidateTemplateFence(record, templateFence)
            if not fenced then
                local rolledBack, rollbackError = callContract(
                    'synex.entities.bucket.move_player', '1.0.0', {
                        source = request.source, bucket = 0, bucketGeneration = 0,
                    }, { traceId = context.traceId,
                        idempotencyKey = rollbackKey })
                if not rolledBack then
                    return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                        'Stale World instance join could not be rolled back.', true,
                        { cause = fencedError and fencedError.code,
                            rollbackCause = rollbackError and rollbackError.code })
                end
                return nil, fencedError
            end
            record.members[request.source] = { sessionId = current.id,
                sourceGeneration = current.sourceGeneration,
                characterId = current.characterId, joinedAtMs = now() }
            sourceMembership[request.source] = record.instanceId
            statistics.members = statistics.members + 1
            record.expiresAtMs = nil
            transition(record, 'ACTIVE')
            record.revision = record.revision + 1
            return snapshot(record)
        end)
    end

    function instances.leave(request, context)
        if not Validation.exactObject(request or {}, {
                instanceId = true, source = true, idempotencyKey = true,
            }) or request.instanceId ~= nil
                and not validReference(request.instanceId, 8, 64)
            or not Validation.isInteger(request.source, 1, 65535)
            or not validReference(request.idempotencyKey, 8, 36) then
            return Validation.failure('INVALID_ARGUMENT', 'World instance leave request is invalid.')
        end
        local instanceId = request.instanceId or sourceMembership[request.source]
        local record = instanceId and records[instanceId] or nil
        if not record then return Validation.failure('INSTANCE_NOT_FOUND', 'World instance does not exist.') end
        local authorized, ownershipError = owned(record, context, false)
        if not authorized then return nil, ownershipError end
        return withMutation(record, { request.source }, function()
            local membership = record.members[request.source]
            if not membership then return Validation.failure('INSTANCE_NOT_FOUND',
                'Player is not in the world instance.') end
            local current, currentError = currentSession(request.source, membership)
            if not current then
                if type(currentError) == 'table' and currentError.code == 'STALE_RESOURCE' then
                    removeMembership(record, request.source)
                end
                return nil, currentError
            end
            local grant, transitionError = transitionMemberToExit(record,
                request.source, membership, context, false)
            if not grant then return nil, transitionError end
            local result = snapshot(record)
            result.transitioned, result.grantId = true, grant.grantId
            return result
        end)
    end

    function instances.close(request, context)
        if not Validation.exactObject(request or {}, {
                instanceId = true, idempotencyKey = true,
            }) or not validReference(request.instanceId, 8, 64)
            or request.idempotencyKey ~= nil
                and not validReference(request.idempotencyKey, 8, 36) then
            return Validation.failure('INVALID_ARGUMENT', 'World instance close request is invalid.')
        end
        local record = records[request.instanceId]
        if not record then return Validation.failure('INSTANCE_NOT_FOUND', 'World instance does not exist.') end
        local authorized, ownershipError = owned(record, context, true)
        if not authorized then return nil, ownershipError end
        if record.state == 'CLOSED' then
            pendingTemplateCleanup[record.instanceId] = nil
            return snapshot(record)
        end
        if record.state == 'CREATING' then
            record.cancelled = true
            transition(record, 'DRAINING')
            record.revision = record.revision + 1
            return snapshot(record)
        end
        local sources = {}; for source in pairs(record.members) do sources[#sources + 1] = source end
        table.sort(sources)
        return withMutation(record, sources, function()
            transition(record, 'DRAINING')
            record.revision = record.revision + 1
            record.expiresAtMs = nil
            local transitionedMembers = 0
            for _, source in ipairs(sources) do
                local current, currentError = currentSession(source, record.members[source])
                local moved, moveError, detached = true
                if current then
                    moved, moveError, detached = transitionMemberToExit(record, source,
                        record.members[source], context, true)
                    if moved then transitionedMembers = transitionedMembers + 1 end
                elseif type(currentError) ~= 'table'
                    or currentError.code ~= 'STALE_RESOURCE' then
                    moved, moveError = nil, currentError
                else
                    removeMembership(record, source)
                end
                if not moved then
                    if detached == true then goto continue_member end
                    record.failure = moveError and moveError.code or 'UNAVAILABLE'
                    transition(record, 'FAILED')
                    record.revision = record.revision + 1
                    return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                        'World instance member cleanup failed.', true,
                        { cause = moveError and moveError.code })
                end
                ::continue_member::
            end
            local destroyed, destroyError = true, nil
            if record.bucketRef ~= nil then
                destroyed, destroyError = callContract(
                    'synex.entities.bucket.destroy', '1.0.0', {
                    bucket = record.bucketRef.bucket, generation = record.bucketRef.generation,
                }, { traceId = context and context.traceId,
                        idempotencyKey = record.destroyKey })
            end
            if not destroyed then
                record.failure = destroyError and destroyError.code or 'UNAVAILABLE'
                transition(record, 'FAILED')
                record.revision = record.revision + 1
                if not enqueueBucketRecovery(record, 'destroy', context, true,
                        transitionedMembers) then
                    record.failure = 'INSTANCE_CLEANUP_QUEUE_EXHAUSTED'
                end
                return Validation.failure('INSTANCE_BUCKET_UNAVAILABLE',
                    'World instance bucket cleanup failed.', true)
            end
            local queuedRecovery = pendingBucketRecovery[record.instanceId]
            if queuedRecovery then removeBucketRecovery(queuedRecovery) end
            return terminalClose(record, transitionedMembers, context, true)
        end)
    end

    local function templateCleanup(context)
        local ids = {}
        for id in pairs(pendingTemplateCleanup) do ids[#ids + 1] = id end
        table.sort(ids)
        local closed, failures = 0, {}
        for _, id in ipairs(ids) do
            local record = records[id]
            if not record or record.state == 'CLOSED' then
                pendingTemplateCleanup[id] = nil
            else
                local result, closeError = instances.close({ instanceId = id,
                    idempotencyKey = nil }, {
                    caller = 'synex_world', callerEpoch = 1,
                    traceId = context and context.traceId,
                })
                if result and result.state == 'CLOSED' then
                    closed = closed + 1
                elseif not result then
                    local code = type(closeError) == 'table' and closeError.code
                        or 'INSTANCE_BUCKET_UNAVAILABLE'
                    failures[#failures + 1] = { instanceId = id,
                        templateKey = record.template.key, code = code }
                    pcall(audit, 'world.instance_template_cleanup_failed',
                        'world_instance', id, failures[#failures], context)
                end
            end
        end
        local pending = 0
        for _ in pairs(pendingTemplateCleanup) do pending = pending + 1 end
        return { attempted = #ids, closed = closed, failures = #failures,
            pending = pending, failureDetails = failures }
    end

    function instances.deactivateTemplates(templateKeys, context)
        if type(templateKeys) ~= 'table' then
            return Validation.failure('INVALID_ARGUMENT',
                'World instance template cleanup keys are invalid.')
        end
        local selected, selectedCount = {}, 0
        for _, key in ipairs(templateKeys) do
            if validReference(key, 3, Limits.maximumKeyLength) and not selected[key] then
                selected[key], selectedCount = true, selectedCount + 1
                if selectedCount > Limits.maximumObjects then
                    return Validation.failure('QUERY_LIMIT_EXCEEDED',
                        'World instance template cleanup exceeds its bound.', true)
                end
            end
        end
        local matched = 0
        for id, record in pairs(records) do
            if record.state ~= 'CLOSED' and selected[record.template.key] then
                if not pendingTemplateCleanup[id] then matched = matched + 1 end
                pendingTemplateCleanup[id] = true
            end
        end
        local report = templateCleanup(context)
        report.matched = matched
        return report
    end

    function instances.reconcileTemplateAvailability(isAvailable, context)
        if not callable(isAvailable) then
            return Validation.failure('INVALID_ARGUMENT',
                'World instance template availability resolver is invalid.')
        end
        local checked, matched = 0, 0
        for id, record in pairs(records) do
            if record.state ~= 'CLOSED' then
                checked = checked + 1
                local called, available = pcall(isAvailable, record.template)
                if not called or available ~= true then
                    if not pendingTemplateCleanup[id] then matched = matched + 1 end
                    pendingTemplateCleanup[id] = true
                end
            end
        end
        local report = templateCleanup(context)
        report.checked, report.matched = checked, matched
        return report
    end

    function instances.retryTemplateCleanup(context)
        return templateCleanup(context)
    end

    function instances.retryClosedCleanup(maximum, context)
        maximum = Validation.isInteger(maximum, 1, 100) and maximum or 25
        local entries, entry = {}, cleanupHead
        while entry and #entries < maximum do
            entries[#entries + 1], entry = entry, entry.next
        end
        local completed, failures = 0, 0
        for _, candidate in ipairs(entries) do
            local callbackContext = { traceId = context and context.traceId
                or candidate.context.traceId }
            local cleaned, cleanupError = runClosedCleanup(candidate.instanceId,
                candidate.snapshot, callbackContext)
            if cleaned then
                removeClosedCleanup(candidate)
                completed = completed + 1
            else
                rotateClosedCleanup(candidate)
                failures = failures + 1
                reportCleanupError(candidate.instanceId, cleanupError)
            end
        end
        return { attempted = #entries, completed = completed,
            failures = failures, pending = pendingCleanupCount }
    end

    function instances.retryBucketRecovery(maximum, context)
        maximum = Validation.isInteger(maximum, 1, 100) and maximum or 25
        local entries, entry = {}, bucketRecoveryHead
        while entry and #entries < maximum do
            entries[#entries + 1], entry = entry, entry.next
        end
        local completed, failures = 0, 0
        for _, candidate in ipairs(entries) do
            local record = records[candidate.instanceId]
            if not record or record.state == 'CLOSED' and record.bucketRef == nil then
                removeBucketRecovery(candidate)
                completed = completed + 1
            else
                local recovered, recoveryError = pcall(function()
                    if candidate.phase == 'create' then
                        local created, createError = callContract(
                            'synex.entities.bucket.create', '2.0.0',
                            Validation.copy(record.bucketRequest), {
                                traceId = context and context.traceId or candidate.traceId,
                                idempotencyKey = record.createKey,
                            })
                        if not created or not Validation.isPlainTable(created.bucket) then
                            if not created and type(createError) == 'table'
                                and createError.retryable == false then
                                terminalClose(record, 0, context, false)
                                return true
                            end
                            return nil, createError or { code = 'UNAVAILABLE' }
                        end
                        record.bucketRef = { bucket = created.bucket.bucket,
                            generation = created.bucket.generation }
                        candidate.phase = 'destroy'
                    end
                    if record.bucketRef ~= nil then
                        local destroyed, destroyError = callContract(
                            'synex.entities.bucket.destroy', '1.0.0', {
                                bucket = record.bucketRef.bucket,
                                generation = record.bucketRef.generation,
                            }, { traceId = context and context.traceId or candidate.traceId,
                                idempotencyKey = record.destroyKey })
                        if not destroyed then return nil, destroyError end
                    end
                    terminalClose(record, candidate.transitionedMembers,
                        context, candidate.notifyClosed)
                    return true
                end)
                if recovered and recoveryError == true then
                    removeBucketRecovery(candidate)
                    completed = completed + 1
                else
                    rotateBucketRecovery(candidate)
                    failures = failures + 1
                    local operationError = recovered and recoveryError or {
                        code = 'UNAVAILABLE', retryable = true,
                    }
                    record.failure = type(operationError) == 'table'
                        and operationError.code or 'UNAVAILABLE'
                    pcall(audit, 'world.instance_bucket_recovery_failed',
                        'world_instance', record.instanceId, {
                            phase = candidate.phase, code = record.failure,
                        }, context)
                end
            end
        end
        return { attempted = #entries, completed = completed,
            failures = failures, pending = pendingBucketRecoveryCount }
    end

    function instances.get(instanceId)
        local record = records[instanceId]
        return record and snapshot(record) or nil
    end
    function instances.getForSource(source, expected)
        local record = records[sourceMembership[source]]
        if not record then return nil end
        local membership = record and record.members[source] or nil
        if expected ~= nil and (not membership
            or membership.sessionId ~= (expected.sessionId or expected.id)
            or membership.sourceGeneration ~= expected.sourceGeneration) then
            return Validation.failure('STALE_RESOURCE',
                'World instance membership belongs to another player session.', true)
        end
        return record and snapshot(record) or nil
    end
    function instances.findReadyByTemplate(templateKey, ownerResource)
        local ids = {}
        for id, record in pairs(records) do
            if record.template.key == templateKey and record.ownerResource == ownerResource
                and (record.state == 'READY' or record.state == 'ACTIVE') then ids[#ids + 1] = id end
        end
        table.sort(ids)
        return ids[1] and records[ids[1]] and snapshot(records[ids[1]]) or nil
    end
    function instances.ownerStopped(ownerResource, ownerEpoch, context)
        local ids = {}
        for id, record in pairs(records) do
            if record.ownerResource == ownerResource and record.ownerEpoch <= ownerEpoch
                and record.state ~= 'CLOSED' then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local firstError
        for _, id in ipairs(ids) do
            local _, closeError = instances.close({ instanceId = id }, {
                caller = 'synex_world', callerEpoch = 1,
                traceId = context and context.traceId,
            })
            if closeError and firstError == nil then firstError = closeError end
        end
        if firstError then return nil, firstError end
        return #ids
    end
    function instances.playerDropped(source)
        local id = sourceMembership[source]
        local record = id and records[id]
        if record then
            removeMembership(record, source)
        end
    end
    function instances.expire(context)
        local current, ids = now(), {}
        for id, record in pairs(records) do
            if record.cleanupPolicy == 'empty_ttl'
                and record.state ~= 'CLOSED' and record.state ~= 'FAILED'
                and next(record.members) == nil and record.expiresAtMs
                and current >= record.expiresAtMs then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local closed = 0
        for _, id in ipairs(ids) do
            local result = instances.close({ instanceId = id }, {
                caller = 'synex_world', callerEpoch = 1,
                traceId = context and context.traceId,
            })
            if result then closed = closed + 1 end
        end
        return closed
    end
    function instances.list(cursor, limit)
        cursor = type(cursor) == 'string' and cursor or ''
        limit = Validation.isInteger(limit, 1, Limits.maximumQueryResults) and limit or 50
        local position = orderedPosition(cursor)
        while orderedIds[position] and orderedIds[position] <= cursor do position = position + 1 end
        local result = {}
        while orderedIds[position] and #result < limit do
            local record = records[orderedIds[position]]
            if record then result[#result + 1] = snapshot(record) end
            position = position + 1
        end
        return result, orderedIds[position] and result[#result].instanceId or nil
    end
    function instances.summary()
        local result = Validation.copy(statistics)
        result.live, result.closedRetained = liveCount, closedCount
        result.pendingStateCleanups = pendingCleanupCount
        result.pendingBucketRecoveries = pendingBucketRecoveryCount
        result.pendingExitTransitions = pendingExitGrantCount
        return result
    end
    return instances
end
