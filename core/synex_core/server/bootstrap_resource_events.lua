local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapResourceEvents = function(deps)
    local platform = assert(deps.platform, 'bootstrap resource events require platform')
    local foundation = assert(deps.foundation, 'bootstrap resource events require foundation')
    local coreResource = assert(deps.coreResource, 'bootstrap resource events require core resource')
    local logger = foundation.logger
    local messaging = assert(deps.messaging, 'bootstrap resource events require messaging')
    local identity = assert(deps.identity, 'bootstrap resource events require identity')
    local reloadSnapshots = assert(deps.reloadSnapshots,
        'bootstrap resource events require reload snapshots')
    local registries = assert(deps.registries, 'bootstrap resource events require registries')
    local lifecycle = assert(deps.lifecycle, 'bootstrap resource events require lifecycle')
    local ownerDrainTimeoutMs = deps.ownerDrainTimeoutMs or 250
    local ownerDrainPollMs = deps.ownerDrainPollMs or 10
    local facadeCache = assert(deps.facadeCache, 'bootstrap resource events require facade cache')
    local manifests = assert(deps.manifests, 'bootstrap resource events require manifests')
    local stateService = assert(deps.stateService, 'bootstrap resource events require state service')
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap resource events require runtime gate')
    local getAPIForCaller = assert(deps.getAPIForCaller,
        'bootstrap resource events require API lookup')
    local invokeForCaller = assert(deps.invokeForCaller,
        'bootstrap resource events require contract invocation')
    local guarded = assert(deps.guarded, 'bootstrap resource events require capability guard')
    local discoverResource = assert(deps.discoverResource,
        'bootstrap resource events require resource discovery')
    local invalidateResource = assert(deps.invalidateResource,
        'bootstrap resource events require resource invalidation')
    local ensureOwner = assert(deps.ensureOwner,
        'bootstrap resource events require owner discovery')
    local supportsStateHandoff = assert(deps.supportsStateHandoff,
        'bootstrap resource events require state handoff policy')
    local captureStateHandoff = assert(deps.captureStateHandoff,
        'bootstrap resource events require state capture')
    local restoreStateHandoff = assert(deps.restoreStateHandoff,
        'bootstrap resource events require state restore')
    local refreshDependencyHealth = assert(deps.refreshDependencyHealth,
        'bootstrap resource events require dependency health refresh')
    local restartController = assert(deps.restartController,
        'bootstrap resource events require restart controller')
    local commands = assert(deps.commands, 'bootstrap resource events require commands')
    local bound = false
    local events = {}

    local stateHandoffRestoreMaximumAttempts = 8
    local stateHandoffRestoreRetryMs = 50
    local stateHandoffMaximumValues = 512
    local stateHandoffMaximumBytes = deps.ownerSnapshotMaximumBytes or 65536

    local function evictFacade(resource)
        local cachePrefix = resource .. ':'
        for key in pairs(facadeCache) do
            if key:sub(1, #cachePrefix) == cachePrefix then facadeCache[key] = nil end
        end
    end

    local function newStateHandoffRecord(snapshot)
        return {
            version = 1,
            snapshot = snapshot,
            originEpoch = type(snapshot) == 'table' and snapshot.ownerEpoch or nil,
            state = 'pending',
            claimEpoch = nil,
            claimToken = 0,
            attempts = 0,
            lastErrorCode = nil
        }
    end

    local function stateHandoffRecord(resource)
        local record = reloadSnapshots[resource]
        if record == nil then return nil end
        if type(record) == 'table' and record.version == 1
            and type(record.snapshot) == 'table' then return record end

        -- Normalize an envelope left by an older in-process producer without
        -- consuming it. Invalid envelopes remain visible to the restore path
        -- and are quarantined there instead of disappearing silently.
        record = newStateHandoffRecord(record)
        reloadSnapshots[resource] = record
        return record
    end

    local function mergeStateHandoffSnapshots(
        resource, epoch, predecessor, current, tombstones)
        local function valuesFrom(snapshot)
            if type(snapshot) ~= 'table' or getmetatable(snapshot) ~= nil
                or snapshot.schemaVersion ~= 1 or snapshot.owner ~= resource
                or snapshot.ownerEpoch ~= epoch
                or type(snapshot.capturedAt) ~= 'string'
                or type(snapshot.values) ~= 'table'
                or getmetatable(snapshot.values) ~= nil then
                return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                    'A state handoff merge candidate is malformed.')
            end
            local count = 0
            for key in next, snapshot.values do
                count = count + 1
                if count > stateHandoffMaximumValues
                    or type(key) ~= 'number' or math.type(key) ~= 'integer'
                    or key < 1 or key > #snapshot.values then
                    return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                        'State handoff merge values must be a bounded dense array.')
                end
            end
            if count ~= #snapshot.values then
                return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                    'State handoff merge values must be a dense array.')
            end
            return snapshot.values, nil
        end

        local predecessorValues, predecessorError = valuesFrom(predecessor)
        if not predecessorValues then return nil, predecessorError end
        local currentValues, currentError = valuesFrom(current)
        if not currentValues then return nil, currentError end

        local entries, entryCount = {}, 0
        local function identity(entry)
            if type(entry) ~= 'table' or getmetatable(entry) ~= nil
                or type(entry.name) ~= 'string' or type(entry.scope) ~= 'string'
                or type(entry.subject) ~= 'string' then return nil end
            return ('%d:%s%d:%s%d:%s'):format(
                #entry.scope, entry.scope, #entry.subject, entry.subject,
                #entry.name, entry.name)
        end
        local function append(values, overlay)
            local seen = {}
            for _, entry in ipairs(values) do
                local key = identity(entry)
                if not key or seen[key] then
                    return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                        'State handoff merge values are malformed or duplicated.')
                end
                seen[key] = true
                local copied, value = foundation.safeCall(foundation.copy, entry)
                if not copied then
                    return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                        'A state handoff merge value could not be copied safely.')
                end
                if overlay or entries[key] == nil then
                    if entries[key] == nil
                        and entryCount >= stateHandoffMaximumValues then
                        return nil, foundation.error('SNAPSHOT_TOO_LARGE',
                            'Merged state handoff values exceed their count limit.')
                    end
                    if entries[key] == nil then entryCount = entryCount + 1 end
                    entries[key] = value
                end
            end
            return true, nil
        end
        local appended, appendError = append(predecessorValues, false)
        if not appended then return nil, appendError end
        if type(tombstones) ~= 'table' or getmetatable(tombstones) ~= nil then
            return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                'State handoff tombstones must be a bounded dense array.')
        end
        local tombstoneCount, seenTombstones = 0, {}
        for key, tombstone in next, tombstones do
            tombstoneCount = tombstoneCount + 1
            if tombstoneCount > stateHandoffMaximumValues
                or type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > #tombstones then
                return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                    'State handoff tombstones must be a bounded dense array.')
            end
            local tombstoneKey = identity(tombstone)
            if not tombstoneKey or seenTombstones[tombstoneKey] then
                return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                    'State handoff tombstones are malformed or duplicated.')
            end
            seenTombstones[tombstoneKey] = true
            if entries[tombstoneKey] ~= nil then
                entries[tombstoneKey] = nil
                entryCount = math.max(0, entryCount - 1)
            end
        end
        if tombstoneCount ~= #tombstones then
            return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                'State handoff tombstones must be a dense array.')
        end
        appended, appendError = append(currentValues, true)
        if not appended then return nil, appendError end
        local orderedEntries = {}
        for _, entry in pairs(entries) do
            orderedEntries[#orderedEntries + 1] = entry
        end
        table.sort(orderedEntries, function(left, right)
            if left.name ~= right.name then return left.name < right.name end
            if left.scope ~= right.scope then return left.scope < right.scope end
            return left.subject < right.subject
        end)
        local merged = {
            schemaVersion = 1,
            owner = resource,
            ownerEpoch = epoch,
            capturedAt = current.capturedAt,
            values = orderedEntries
        }
        local encoded, payload = foundation.safeCall(platform.jsonEncode, merged)
        if not encoded or type(payload) ~= 'string' then
            return nil, foundation.error('INVALID_STATE_SNAPSHOT',
                'Merged state handoff values could not be encoded safely.')
        end
        if #payload > stateHandoffMaximumBytes then
            return nil, foundation.error('SNAPSHOT_TOO_LARGE',
                'Merged state handoff values exceed their byte limit.')
        end
        return merged, nil
    end

    local function markStateHandoffPending(record, epoch)
        -- Fence the previous generation before copying or quiescing. A queued
        -- or yielding restore callback must stop owning this envelope before
        -- the current generation captures and merges its state.
        record.state = 'pending'
        record.claimEpoch = nil
        record.claimToken = (record.claimToken or 0) + 1
        local copied, snapshot = foundation.safeCall(foundation.copy, record.snapshot)
        if not copied or type(snapshot) ~= 'table' then
            record.state = 'quarantined'
            record.lastErrorCode = 'INVALID_STATE_SNAPSHOT'
            return false
        end
        -- A start that never completed restoration is a skipped handoff
        -- generation. Advance the trusted, in-memory predecessor fence so the
        -- same envelope remains eligible for the next activated owner epoch.
        snapshot.ownerEpoch = epoch
        record.snapshot = snapshot
        record.attempts = 0
        record.lastErrorCode = nil
        return true
    end

    local function stateHandoffClaimCurrent(resource, epoch, record, claimToken)
        return reloadSnapshots[resource] == record
            and record.state == 'claimed'
            and record.claimEpoch == epoch
            and record.claimToken == claimToken
    end

    local function quarantineStateHandoff(resource, epoch, record, code, message, claimToken)
        if reloadSnapshots[resource] ~= record then return end
        if claimToken ~= nil
            and not stateHandoffClaimCurrent(resource, epoch, record, claimToken) then return end
        record.state = 'quarantined'
        record.claimEpoch = nil
        record.lastErrorCode = code
        logger:error('resource state handoff quarantined', {
            resource = resource,
            epoch = epoch,
            code = code,
            message = message
        })
        if registries.owners:isCurrent(resource, epoch) then
            registries.resources:setState(resource, 'STARTED', {
                status = 'DEGRADED',
                reasons = { {
                    code = 'STATE_RESTORE_FAILED',
                    message = 'Reconstructable in-memory state could not be restored.'
                } }
            })
        end
    end

    local function claimStateHandoff(resource, epoch)
        local record = stateHandoffRecord(resource)
        if not record or record.state == 'quarantined' then return end
        if record.state == 'claimed' and record.claimEpoch == epoch then return end

        record.state = 'claimed'
        record.claimEpoch = epoch
        record.claimToken = (record.claimToken or 0) + 1
        record.attempts = 0
        record.lastErrorCode = nil
        local claimToken = record.claimToken
        local retryableCodes = {
            SNAPSHOT_STATE_UNAVAILABLE = true,
            STATE_REPLICATION_UNAVAILABLE = true
        }
        local scheduleAttempt
        scheduleAttempt = function(delayMs)
            local scheduled, scheduleFailure = foundation.safeCall(platform.setTimeout, delayMs, function()
                if not stateHandoffClaimCurrent(resource, epoch, record, claimToken) then return end
                if not registries.owners:isCurrent(resource, epoch) then
                    record.state = 'pending'
                    record.claimEpoch = nil
                    return
                end

                record.attempts = record.attempts + 1
                local restored, restoreError = lifecycle.reload:restore(
                    resource, epoch, record.snapshot, restoreStateHandoff)
                if not stateHandoffClaimCurrent(resource, epoch, record, claimToken) then return end
                if restored then
                    reloadSnapshots[resource] = nil
                    if restored.restored > 0 then
                        logger:info('resource state handoff restored', {
                            resource = resource,
                            originEpoch = record.originEpoch,
                            fromEpoch = restored.fromEpoch,
                            toEpoch = restored.toEpoch,
                            values = restored.restored
                        })
                    end
                    return
                end

                local code = foundation.failureCode(restoreError, 'SNAPSHOT_RESTORE_FAILED')
                record.lastErrorCode = code
                if retryableCodes[code]
                    and record.attempts < stateHandoffRestoreMaximumAttempts
                    and registries.owners:isCurrent(resource, epoch) then
                    scheduleAttempt(stateHandoffRestoreRetryMs)
                    return
                end
                quarantineStateHandoff(resource, epoch, record, code,
                    restoreError and restoreError.message
                        or 'The reconstructable state restore failed.', claimToken)
            end)
            if not scheduled
                and stateHandoffClaimCurrent(resource, epoch, record, claimToken) then
                quarantineStateHandoff(resource, epoch, record,
                    foundation.failureCode(scheduleFailure, 'STATE_RESTORE_SCHEDULE_FAILED'),
                    'The reconstructable state restore could not be scheduled.', claimToken)
            end
        end
        scheduleAttempt(0)
    end

    function events:bind()
        if bound then return true end
        bound = true
        platform.export('GetAPI', function(versionRange)
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            return getAPIForCaller(caller, versionRange)
        end)
        platform.export('Invoke', function(name, version, request, options)
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            return invokeForCaller(caller, name, version, request, options)
        end)
        platform.export('GetRuntimeStatus', function()
            local caller = platform.invokingResource()
            if type(caller) ~= 'string' or caller == '' then return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.') end
            local epoch, err = ensureOwner(caller)
            if not epoch then return nil, err end
            return guarded(caller, epoch, 'synex.runtime.read', 'GetRuntimeStatus', function() return lifecycle.core:snapshot(), nil end)
        end)
        messaging.network:bind()
        platform.addEventHandler('playerConnecting', function(name, setKickReason, deferrals)
            local tempSource = source
            local connectionSnapshot = identity.connections:snapshot()
            if connectionSnapshot.quiesced then
                foundation.safeCall(setKickReason,
                    'Synex [CORE_STOPPING]: The Synex runtime is stopping. Please reconnect shortly.')
                foundation.safeCall(platform.cancelEvent)
                return
            end
            local invoked, connected, connectionError = foundation.safeCall(
                identity.connections.handleConnecting, identity.connections, tempSource, name, deferrals)
            if not invoked or connected == nil then
                logger:error('playerConnecting handler failed', {
                    code = invoked and connectionError and connectionError.code or 'CONNECTION_HANDLER_FAILED'
                })
            end
        end)
        platform.addEventHandler('playerJoining', function(oldSource)
            local finalSource = source
            local invoked, joined = foundation.safeCall(
                identity.connections.handleJoining, identity.connections, finalSource, oldSource)
            if not invoked then
                foundation.safeCall(logger.error, logger,
                    'playerJoining handler failed', { code = 'JOIN_HANDLER_FAILED' })
            elseif joined == nil then
                logger:warn('playerJoining did not open a session', { code = 'SESSION_NOT_OPENED' })
            end
        end)
        platform.addEventHandler('playerDropped', function(reason)
            if type(restartController.isRawStopFenceActive) == 'function'
                and restartController:isRawStopFenceActive() then
                return
            end
            local playerSource = source
            local invoked = foundation.safeCall(
                identity.connections.handleDropped, identity.connections, playerSource, reason)
            if not invoked then logger:error('playerDropped handler failed', { code = 'DROP_HANDLER_FAILED' }) end
        end)
        platform.addEventHandler('onResourceStart', function(resource)
            if resource == coreResource then return end
            local available = runtimeGate:requireAvailable()
            if not available then return end
            local epoch = registries.owners:epoch(resource)
            local manifest = manifests[resource]
            local ownerError = nil
            if manifest and registries.owners:isCurrent(resource, epoch) then
                epoch, ownerError = ensureOwner(resource)
            else
                if registries.owners:isEpoch(resource, epoch) then
                    local cleanup = registries.owners:purge(
                        resource, epoch, 'resource start found an owner without a validated manifest')
                    if #cleanup.errors > 0 then
                        logger:error('stale resource owner cleanup completed with errors', {
                            resource = resource, report = cleanup
                        })
                    end
                end
                evictFacade(resource)
                manifest, ownerError = discoverResource(resource)
                if manifest then epoch, ownerError = ensureOwner(resource) end
            end
            if ownerError then
                logger:error('resource discovery or owner activation failed on start', {
                    resource = resource, code = ownerError.code, message = ownerError.message
                })
                local currentEpoch = registries.owners:epoch(resource)
                if registries.owners:isEpoch(resource, currentEpoch) then
                    registries.owners:purge(resource, currentEpoch, 'resource start validation failed')
                end
                invalidateResource(resource)
                evictFacade(resource)
                refreshDependencyHealth(resource)
                return
            end
            if manifest then
                registries.resources:setState(resource, 'STARTED', { status = 'HEALTHY', reasons = {} })
                refreshDependencyHealth()
                local handoff = stateHandoffRecord(resource)
                if handoff and supportsStateHandoff(resource) then
                    claimStateHandoff(resource, epoch)
                elseif handoff and handoff.state ~= 'quarantined' then
                    quarantineStateHandoff(resource, epoch, handoff,
                        'STATE_HANDOFF_UNSUPPORTED',
                        'The current resource manifest does not accept the pending state handoff.')
                end
            else
                refreshDependencyHealth(resource)
            end
        end)
        platform.addEventHandler('onResourceStop', function(resource)
            if resource == coreResource then
                restartController:handleRawStop()
                return
            end
            local epoch = registries.owners:epoch(resource)
            local report = { cleaned = 0, aborted = 0, errors = {} }
            if registries.owners:isEpoch(resource, epoch) then
                local pendingHandoff = stateHandoffRecord(resource)
                local mergePredecessor = nil
                if pendingHandoff and pendingHandoff.state ~= 'quarantined' then
                    if markStateHandoffPending(pendingHandoff, epoch) then
                        mergePredecessor = pendingHandoff
                    end
                end
                local options = {
                    timeoutMs = ownerDrainTimeoutMs,
                    pollMs = ownerDrainPollMs,
                    reason = 'resource stop'
                }
                if supportsStateHandoff(resource) then options.capture = captureStateHandoff end
                local quiesceReport, quiesceError = lifecycle.reload:quiesce(resource, epoch, options)
                if quiesceReport then
                    report = quiesceReport.cleanup
                    for _, abortError in ipairs(quiesceReport.abortErrors) do
                        report.errors[#report.errors + 1] = {
                            kind = 'operation_abort',
                            token = abortError.token,
                            code = abortError.code or 'OPERATION_ABORT_FAILED'
                        }
                    end
                    if quiesceReport.snapshot then
                        if mergePredecessor
                            and reloadSnapshots[resource] == mergePredecessor then
                            local currentTombstones, mergeError = {}, nil
                            if type(stateService.consumeOwnerCaptureTombstones) == 'function' then
                                local consumed, tombstones, tombstoneError = foundation.safeCall(
                                    stateService.consumeOwnerCaptureTombstones,
                                    stateService, resource, epoch, quiesceReport.snapshot)
                                if not consumed or not tombstones then
                                    mergeError = consumed and tombstoneError
                                        or foundation.error('INVALID_STATE_SNAPSHOT',
                                            'State handoff tombstones could not be consumed safely.')
                                else
                                    currentTombstones = tombstones
                                end
                            end
                            local merged = nil
                            if not mergeError then
                                merged, mergeError = mergeStateHandoffSnapshots(
                                    resource, epoch, mergePredecessor.snapshot,
                                    quiesceReport.snapshot, currentTombstones)
                            end
                            if merged then
                                local mergedRecord = newStateHandoffRecord(merged)
                                mergedRecord.originEpoch = mergePredecessor.originEpoch
                                    or mergedRecord.originEpoch
                                reloadSnapshots[resource] = mergedRecord
                            else
                                local copied, currentSnapshot = foundation.safeCall(
                                    foundation.copy, quiesceReport.snapshot)
                                mergePredecessor.currentSnapshot = copied
                                    and currentSnapshot or nil
                                mergePredecessor.currentTombstones = foundation.copy(
                                    currentTombstones)
                                quarantineStateHandoff(resource, epoch,
                                    mergePredecessor,
                                    foundation.failureCode(
                                        mergeError, 'STATE_HANDOFF_MERGE_FAILED'),
                                    mergeError and mergeError.message
                                        or 'State handoff snapshots could not be merged safely.')
                            end
                        else
                            reloadSnapshots[resource] = newStateHandoffRecord(
                                quiesceReport.snapshot)
                        end
                    end
                    if quiesceReport.timedOut then
                        logger:warn('resource drain timed out; pending owner work was aborted', {
                            resource = resource,
                            epoch = epoch,
                            aborted = quiesceReport.aborted,
                            timeoutMs = ownerDrainTimeoutMs
                        })
                    end
                    if quiesceReport.snapshotError then
                        if mergePredecessor
                            and reloadSnapshots[resource] == mergePredecessor then
                            quarantineStateHandoff(resource, epoch,
                                mergePredecessor,
                                foundation.failureCode(
                                    quiesceReport.snapshotError,
                                    'SNAPSHOT_CAPTURE_FAILED'),
                                quiesceReport.snapshotError.message)
                        else
                            logger:error('resource state handoff capture failed', {
                                resource = resource,
                                epoch = epoch,
                                code = quiesceReport.snapshotError.code,
                                message = quiesceReport.snapshotError.message
                            })
                        end
                    end
                else
                    logger:error('resource quiesce failed', {
                        resource = resource,
                        epoch = epoch,
                        code = quiesceError.code,
                        message = quiesceError.message
                    })
                    report = registries.owners:purge(resource, epoch, 'resource stop fallback cleanup')
                end
            end
            invalidateResource(resource)
            evictFacade(resource)
            registries.resources:setState(resource, 'STOPPED', {
                status = 'UNHEALTHY', reasons = { { code = 'RESOURCE_STOPPED', message = 'Resource is stopped.' } }
            })
            refreshDependencyHealth(resource)
            if #report.errors > 0 then logger:error('resource cleanup completed with errors', { resource = resource, report = report }) end
        end)
        commands:bind()
        return true
    end

    return events
end
