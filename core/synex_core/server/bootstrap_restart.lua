local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapRestart = function(deps)
    local foundation = assert(deps.foundation, 'bootstrap restart requires foundation')
    local logger = foundation.logger
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap restart requires runtime gate')
    local lifecycle = assert(deps.lifecycle, 'bootstrap restart requires lifecycle')
    local identity = assert(deps.identity, 'bootstrap restart requires identity')
    local persistence = assert(deps.persistence, 'bootstrap restart requires persistence')
    local database = persistence.database
    local registries = assert(deps.registries, 'bootstrap restart requires registries')
    local facadeCache = assert(deps.facadeCache, 'bootstrap restart requires facade cache')
    local stateService = deps.stateService or {
        purgeAllPlayers = function() return { players = 0, cleared = 0, replicated = 0, skipped = 0, failures = {} }, nil end
    }
    local coreResource = assert(deps.coreResource, 'bootstrap restart requires core resource')
    local evictConnectedPlayers = assert(deps.evictConnectedPlayers,
        'bootstrap restart requires player eviction')
    local drainQuiescedTerminals = assert(deps.drainQuiescedTerminals,
        'bootstrap restart requires deferral drain')
    local ownerDrainTimeoutMs = deps.ownerDrainTimeoutMs or 250
    local ownerDrainPollMs = deps.ownerDrainPollMs or 10
    local databaseDrainTimeoutMs = deps.databaseDrainTimeoutMs or 30000
    local databaseDrainPollMs = deps.databaseDrainPollMs or 10
    local preparation = { state = 'idle', report = nil }
    local rawStopFenceActive = false
    local controller = {}

    local function databaseGateAvailable()
        return type(database) == 'table'
            and type(database.beginDrain) == 'function'
            and type(database.waitForDrain) == 'function'
            and type(database.withControl) == 'function'
            and type(database.activity) == 'function'
    end

    local function recordFailure(failures, stage, err)
        local code = type(err) == 'table' and tostring(err.code or '') or ''
        if not code:match('^[A-Z0-9_]+$') then code = 'RESTART_STAGE_FAILED' end
        failures[#failures + 1] = { stage = stage, code = code }
        foundation.safeCall(logger.error, logger, 'core restart preparation stage failed', {
            stage = stage, code = code
        })
    end

    local function transition(target, reason, failures)
        local current = lifecycle.core:get()
        if current == target or current == 'STOPPED' then return true end
        local invoked, revision, transitionError = foundation.safeCall(
            lifecycle.core.transition, lifecycle.core, target, reason)
        if not invoked or not revision then
            recordFailure(failures, 'lifecycle_' .. target:lower(),
                invoked and transitionError or nil)
            return false
        end
        return true
    end

    local function beginFence(reason, playerReason, failures)
        foundation.safeCall(runtimeGate.stop, runtimeGate)
        foundation.safeCall(lifecycle.core.setCriticalFoundationsValidated, lifecycle.core, false)
        local current = lifecycle.core:get()
        if current == 'READY' or current == 'DEGRADED' or current == 'UNHEALTHY' then
            transition('QUIESCING', reason, failures)
        end
        local invoked, connectionReport, connectionError = foundation.safeCall(
            identity.connections.quiesce, identity.connections)
        if not invoked or not connectionReport then
            recordFailure(failures, 'connection_quiesce', invoked and connectionError or nil)
        end
        local stateInvoked, stateReport, stateError = foundation.safeCall(
            stateService.purgeAllPlayers, stateService)
        if not stateInvoked or not stateReport then
            recordFailure(failures, 'player_state_purge', stateInvoked and stateError or stateReport)
        elseif #(stateReport.failures or {}) > 0 then
            recordFailure(failures, 'player_state_purge', foundation.error(
                'PLAYER_STATE_PURGE_FAILED',
                'One or more replicated player state values could not be cleared.'))
        end
        local evicted, evictionError = evictConnectedPlayers(playerReason)
        if evicted == nil then recordFailure(failures, 'player_eviction', evictionError) end
        return connectionReport, evicted, stateReport
    end

    local function moveToStopping(reason, failures)
        local current = lifecycle.core:get()
        if current ~= 'STOPPING' and current ~= 'STOPPED' then
            transition('STOPPING', reason, failures)
        end
    end

    local function moveToStopped(reason, failures)
        moveToStopping(reason, failures)
        if lifecycle.core:get() == 'STOPPING' then transition('STOPPED', reason, failures) end
    end

    local function failPreparation(report, failures, preferredError, message, retryAllowed)
        moveToStopping('restart preparation failed closed', failures)
        report.state = 'failed'
        report.retryAllowed = retryAllowed == true
        report.completedAt = foundation.utcIso()
        report.failures = foundation.copy(failures)
        report.restartCommand = nil
        preparation = {
            state = retryAllowed == true and 'failed_retryable' or 'failed_terminal',
            report = report
        }
        if type(preferredError) == 'table'
            and preferredError.code == 'RESTART_DATABASE_DRAIN_TIMEOUT' then
            return nil, preferredError
        end
        return nil, foundation.error('RESTART_PREPARATION_FAILED', message, {
            retryable = retryAllowed == true, details = { failures = #failures }
        })
    end

    local function inspectScheduler(failures, report)
        if type(lifecycle.scheduler) ~= 'table'
            or type(lifecycle.scheduler.capacity) ~= 'function' then
            recordFailure(failures, 'scheduler_drain', foundation.error(
                'RESTART_SCHEDULER_EVIDENCE_INVALID',
                'The scheduler activity probe is unavailable.'))
            return
        end
        local invoked, capacity = foundation.safeCall(
            lifecycle.scheduler.capacity, lifecycle.scheduler)
        if not invoked or type(capacity) ~= 'table' then
            recordFailure(failures, 'scheduler_drain', foundation.error(
                'RESTART_SCHEDULER_EVIDENCE_INVALID',
                'The scheduler did not provide bounded restart evidence.'))
            return
        end
        local running = tonumber(capacity.runningHandlers)
        local detached = tonumber(capacity.detachedRunningHandlers)
        if not running or math.type(running) ~= 'integer' or running < 0
            or not detached or math.type(detached) ~= 'integer' or detached < 0
            or detached > running then
            recordFailure(failures, 'scheduler_drain', foundation.error(
                'RESTART_SCHEDULER_EVIDENCE_INVALID',
                'The scheduler returned invalid restart activity evidence.'))
            return
        end
        report.scheduler = {
            runningHandlers = running,
            detachedRunningHandlers = detached
        }
        if running > 0 or detached > 0 then
            recordFailure(failures, 'scheduler_drain', foundation.error(
                'RESTART_SCHEDULER_NOT_DRAINED',
                'One or more scheduler handlers remain active during restart preparation.', {
                    retryable = true,
                    details = { runningHandlers = running, detachedRunningHandlers = detached }
                }))
        end
    end

    local function inspectDatabaseActivity(failures, report)
        local invoked, activity = foundation.safeCall(database.activity, database)
        if not invoked or type(activity) ~= 'table'
            or activity.draining ~= true
            or type(activity.active) ~= 'number'
            or math.type(activity.active) ~= 'integer' or activity.active < 0 then
            recordFailure(failures, 'database_activity', foundation.error(
                'RESTART_DATABASE_EVIDENCE_INVALID',
                'The database runtime did not provide bounded restart evidence.'))
            return
        end
        report.databaseActivity = foundation.copy(activity)
        if activity.active > 0 then
            recordFailure(failures, 'database_activity', foundation.error(
                'RESTART_DATABASE_NOT_DRAINED',
                'Database activity resumed during restart preparation.', {
                    retryable = true,
                    details = { active = activity.active }
                }))
        end
    end

    function controller:prepare()
        if preparation.state == 'prepared' then
            return foundation.copy(preparation.report), nil
        end
        if preparation.state == 'failed_terminal' then
            return nil, foundation.error('RESTART_PREPARATION_RETRY_UNSAFE',
                'Restart preparation already crossed the owner teardown boundary. '
                    .. 'Use a controlled full FXServer-process restart.', {
                    retryable = false
                })
        end
        if preparation.state == 'preparing' then
            return nil, foundation.error('RESTART_PREPARATION_IN_PROGRESS',
                'Core restart preparation is already in progress.', { retryable = true })
        end
        if lifecycle.core:get() == 'STOPPED' then
            return nil, foundation.error('CORE_ALREADY_STOPPED',
                'The Core runtime is already stopped.')
        end
        preparation.state = 'preparing'
        local failures = {}
        local report = {
            state = 'preparing', startedAt = foundation.utcIso()
        }
        local connectionReport, evicted, stateReport = beginFence(
            'operator restart preparation',
            'Synex Core is preparing to restart. Please reconnect shortly.', failures)
        report.connections = connectionReport
        report.playerState = stateReport
        report.evictedPlayers = evicted or 0

        local databaseDrainStarted = false
        if not databaseGateAvailable() then
            recordFailure(failures, 'database_drain_fence', foundation.error(
                'RESTART_DATABASE_GATE_UNAVAILABLE',
                'The database restart activity gate is unavailable.'))
        else
            local drainFenceInvoked, drainFence, drainFenceError = foundation.safeCall(
                database.beginDrain, database)
            databaseDrainStarted = drainFenceInvoked and type(drainFence) == 'table'
                and drainFence.draining == true
                and type(drainFence.active) == 'number'
                and math.type(drainFence.active) == 'integer'
                and drainFence.active >= 0
            if not databaseDrainStarted then
                local fenceFailure = nil
                if not drainFenceInvoked then
                    fenceFailure = drainFence
                elseif drainFence == nil then
                    fenceFailure = drainFenceError
                else
                    fenceFailure = foundation.error(
                        'RESTART_DATABASE_EVIDENCE_INVALID',
                        'The database drain fence returned invalid activity evidence.')
                end
                recordFailure(failures, 'database_drain_fence',
                    fenceFailure)
            else
                report.databaseDrainFence = foundation.copy(drainFence)
            end
        end

        local invoked, terminalReport, terminalError = foundation.safeCall(
            drainQuiescedTerminals, 'restart preparation')
        if not invoked or not terminalReport then
            recordFailure(failures, 'deferral_drain', invoked and terminalError or nil)
        else
            report.deferrals = terminalReport
        end

        local databaseDrained = false
        local databaseDrainError = nil
        if databaseDrainStarted then
            local drainInvoked, drainReport, drainError = foundation.safeCall(
                database.waitForDrain, database, databaseDrainTimeoutMs, databaseDrainPollMs)
            if not drainInvoked or type(drainReport) ~= 'table'
                or drainReport.draining ~= true
                or drainReport.active ~= 0 then
                if not drainInvoked then
                    databaseDrainError = drainReport
                elseif drainReport == nil then
                    databaseDrainError = drainError
                else
                    databaseDrainError = foundation.error(
                        'RESTART_DATABASE_EVIDENCE_INVALID',
                        'The database drain returned invalid completion evidence.')
                end
                recordFailure(failures, 'database_drain', databaseDrainError)
            else
                databaseDrained = true
                report.databaseDrain = foundation.copy(drainReport)
            end
        end

        local ownerTeardownStarted = false
        report.owners = { quiesced = 0, failures = 0 }
        if databaseDrained then
            -- reload:quiesce purges an owner even when cancellation is only
            -- cooperative and its handler outlives the bounded wait. From
            -- this boundary onward a retry cannot reconstruct trustworthy
            -- pending-operation evidence, so every later failure is terminal
            -- for this Core process.
            ownerTeardownStarted = true
            for _, owner in ipairs(registries.owners:list()) do
                local ownerInvoked, ownerReport, ownerError = foundation.safeCall(
                    lifecycle.reload.quiesce, lifecycle.reload, owner.resource, owner.epoch, {
                        timeoutMs = ownerDrainTimeoutMs,
                        pollMs = ownerDrainPollMs,
                        reason = 'synex_core restart preparation'
                    })
                if not ownerInvoked or not ownerReport then
                    report.owners.failures = report.owners.failures + 1
                    recordFailure(failures, 'owner_quiesce', ownerInvoked and ownerError or nil)
                else
                    report.owners.quiesced = report.owners.quiesced + 1
                    if ownerReport.timedOut == true then
                        report.owners.failures = report.owners.failures + 1
                        recordFailure(failures, 'owner_drain', foundation.error(
                            'RESTART_OWNER_DRAIN_TIMEOUT',
                            'An owner still had running work when its restart drain expired.', {
                                retryable = true,
                                details = {
                                    resource = owner.resource,
                                    pendingAtStart = ownerReport.pendingAtStart,
                                    aborted = ownerReport.aborted
                                }
                            }))
                    elseif ownerReport.drainError ~= nil then
                        report.owners.failures = report.owners.failures + 1
                        recordFailure(failures, 'owner_drain', foundation.error(
                            'RESTART_OWNER_DRAIN_FAILED',
                            'An owner could not complete its bounded restart drain.', {
                                retryable = true,
                                details = {
                                    resource = owner.resource,
                                    cause = foundation.failureCode(
                                        ownerReport.drainError, 'DRAIN_WAIT_FAILED')
                                }
                            }))
                    elseif #(ownerReport.abortErrors or {}) > 0
                        or #(ownerReport.cleanup and ownerReport.cleanup.errors or {}) > 0 then
                        report.owners.failures = report.owners.failures + 1
                        recordFailure(failures, 'owner_cleanup',
                            foundation.error('OWNER_CLEANUP_FAILED',
                                'An owner cleanup reported one or more failures.'))
                    end
                end
            end
            for key in pairs(facadeCache) do facadeCache[key] = nil end
        end

        if databaseDrained then
            local statusSet, statusResult, statusError = foundation.safeCall(
                database.withControl, database, function()
                    return persistence.instances:setStatus('stopping')
                end)
            if not statusSet or not statusResult then
                recordFailure(failures, 'instance_stopping', statusSet and statusError or statusResult)
            end

            local leasesInvoked, releaseReport, releaseError = foundation.safeCall(
                database.withControl, database, function()
                    return identity.connections:releaseQuiescedLeases()
                end)
            if not leasesInvoked or not releaseReport then
                recordFailure(failures, 'connection_lease_release',
                    leasesInvoked and releaseError or releaseReport)
            else
                report.connectionLeases = releaseReport
                if (releaseReport.leaseReleaseFailures or 0) > 0 then
                    foundation.safeCall(logger.warn, logger,
                        'captured connection leases require authoritative restart cleanup', {
                            failures = releaseReport.leaseReleaseFailures
                        })
                end
            end

            local terminatedInvoked, terminated, terminationError = foundation.safeCall(
                database.withControl, database, function()
                    return persistence.instances:terminateLocalSessions(
                        'synex_core restart prepared')
                end)
            if not terminatedInvoked or not terminated then
                recordFailure(failures, 'session_termination',
                    terminatedInvoked and terminationError or terminated)
            else
                report.durableAuthorityClosed = true
            end

            inspectScheduler(failures, report)
            inspectDatabaseActivity(failures, report)

            if #failures == 0 then
                local stoppedInvoked, stopped, stoppedError = foundation.safeCall(
                    database.withControl, database, function()
                        return persistence.instances:setStatus('stopped')
                    end)
                if not stoppedInvoked or not stopped then
                    recordFailure(failures, 'instance_stopped',
                        stoppedInvoked and stoppedError or stopped)
                end
                inspectDatabaseActivity(failures, report)
            end
        end

        if #failures > 0 then
            return failPreparation(report, failures, databaseDrainError,
                'Core remains fail-closed because restart preparation did not complete.',
                not ownerTeardownStarted)
        end

        moveToStopped('restart prepared', failures)
        if #failures > 0 then
            return failPreparation(report, failures, nil,
                'Durable cleanup completed, but the local lifecycle could not be finalized.',
                false)
        end
        report.state = 'prepared'
        report.completedAt = foundation.utcIso()
        report.failures = {}
        report.restartCommand = 'restart ' .. coreResource
        preparation = { state = 'prepared', report = report }
        return foundation.copy(report), nil
    end

    function controller:isRawStopFenceActive()
        return rawStopFenceActive
    end

    function controller:handleRawStop()
        -- onResourceStop cannot wait for Cfx/oxmysql callbacks. DropPlayer may
        -- synchronously emit playerDropped, so fence that handler before any
        -- player is evicted and leave durable cleanup to next-boot recovery.
        rawStopFenceActive = true
        local failures = {}
        if not databaseGateAvailable() then
            recordFailure(failures, 'database_drain_fence', foundation.error(
                'RESTART_DATABASE_GATE_UNAVAILABLE',
                'The database restart activity gate is unavailable.'))
        else
            local drainInvoked, drainReport, drainError = foundation.safeCall(
                database.beginDrain, database)
            if not drainInvoked or type(drainReport) ~= 'table'
                or drainReport.draining ~= true
                or type(drainReport.active) ~= 'number'
                or math.type(drainReport.active) ~= 'integer'
                or drainReport.active < 0 then
                local failure = nil
                if not drainInvoked then
                    failure = drainReport
                elseif drainReport == nil then
                    failure = drainError
                else
                    failure = foundation.error(
                        'RESTART_DATABASE_EVIDENCE_INVALID',
                        'The database drain fence returned invalid activity evidence.')
                end
                recordFailure(failures, 'database_drain_fence',
                    failure)
            end
        end
        beginFence('resource stop',
            'Synex Core is restarting. Please reconnect shortly.', failures)
        if type(identity.connections.flushReadyQuiescedTerminals) == 'function' then
            local invoked, readyReport = foundation.safeCall(
                identity.connections.flushReadyQuiescedTerminals, identity.connections)
            if not invoked or not readyReport or (readyReport.failures or 0) > 0 then
                recordFailure(failures, 'ready_deferral_flush',
                    foundation.error('DEFERRAL_DRAIN_FAILED',
                        'One or more tick-ready connection deferrals could not be finalized.'))
            elseif (readyReport.remaining or 0) > 0 then
                foundation.safeCall(logger.warn, logger,
                    'connection deferrals remain for Cfx resource teardown', {
                        remaining = readyReport.remaining
                    })
            end
        end
        for key in pairs(facadeCache) do facadeCache[key] = nil end
        moveToStopped('resource stopped', failures)
        if #failures > 0 then
            foundation.safeCall(logger.error, logger,
                'synchronous core stop fence completed with failures', {
                    failures = #failures
                })
        end
        return { failures = #failures }, nil
    end

    return controller
end
