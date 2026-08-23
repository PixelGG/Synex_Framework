local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapRestart = function(deps)
    local foundation = assert(deps.foundation, 'bootstrap restart requires foundation')
    local logger = foundation.logger
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap restart requires runtime gate')
    local lifecycle = assert(deps.lifecycle, 'bootstrap restart requires lifecycle')
    local identity = assert(deps.identity, 'bootstrap restart requires identity')
    local persistence = assert(deps.persistence, 'bootstrap restart requires persistence')
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
    local preparation = { state = 'idle', report = nil }
    local controller = {}

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

    function controller:prepare()
        if preparation.state == 'prepared' then
            return foundation.copy(preparation.report), nil
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
            state = 'preparing', startedAt = foundation.utcIso(),
            restartCommand = 'restart ' .. coreResource
        }
        local connectionReport, evicted, stateReport = beginFence(
            'operator restart preparation',
            'Synex Core is preparing to restart. Please reconnect shortly.', failures)
        report.connections = connectionReport
        report.playerState = stateReport
        report.evictedPlayers = evicted or 0

        local invoked, terminalReport, terminalError = foundation.safeCall(
            drainQuiescedTerminals, 'restart preparation')
        if not invoked or not terminalReport then
            recordFailure(failures, 'deferral_drain', invoked and terminalError or nil)
        else
            report.deferrals = terminalReport
        end

        local statusSet, statusResult, statusError = foundation.safeCall(
            persistence.instances.setStatus, persistence.instances, 'stopping')
        if not statusSet or not statusResult then
            recordFailure(failures, 'instance_stopping', statusSet and statusError or nil)
        end

        local leasesInvoked, releaseReport, releaseError = foundation.safeCall(
            identity.connections.releaseQuiescedLeases, identity.connections)
        if not leasesInvoked or not releaseReport then
            recordFailure(failures, 'connection_lease_release', leasesInvoked and releaseError or nil)
        else
            report.connectionLeases = releaseReport
            if (releaseReport.leaseReleaseFailures or 0) > 0 then
                foundation.safeCall(logger.warn, logger,
                    'captured connection leases require authoritative restart cleanup', {
                        failures = releaseReport.leaseReleaseFailures
                    })
            end
        end

        report.owners = { quiesced = 0, failures = 0 }
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
                if #(ownerReport.abortErrors or {}) > 0
                    or #(ownerReport.cleanup and ownerReport.cleanup.errors or {}) > 0 then
                    report.owners.failures = report.owners.failures + 1
                    recordFailure(failures, 'owner_cleanup',
                        foundation.error('OWNER_CLEANUP_FAILED',
                            'An owner cleanup reported one or more failures.'))
                end
            end
        end
        for key in pairs(facadeCache) do facadeCache[key] = nil end

        local terminatedInvoked, terminated, terminationError = foundation.safeCall(
            persistence.instances.terminateLocalSessions,
            persistence.instances, 'synex_core restart prepared')
        if not terminatedInvoked or not terminated then
            recordFailure(failures, 'session_termination',
                terminatedInvoked and terminationError or nil)
        else
            report.durableAuthorityClosed = true
        end

        if #failures == 0 then
            local stoppedInvoked, stopped, stoppedError = foundation.safeCall(
                persistence.instances.setStatus, persistence.instances, 'stopped')
            if not stoppedInvoked or not stopped then
                recordFailure(failures, 'instance_stopped', stoppedInvoked and stoppedError or nil)
            end
        end

        if #failures > 0 then
            moveToStopping('restart preparation failed closed', failures)
            report.state = 'failed'
            report.completedAt = foundation.utcIso()
            report.failures = foundation.copy(failures)
            preparation = { state = 'failed', report = report }
            return nil, foundation.error('RESTART_PREPARATION_FAILED',
                'Core remains fail-closed because restart preparation did not complete.', {
                    retryable = true, details = { failures = #failures }
                })
        end

        moveToStopped('restart prepared', failures)
        if #failures > 0 then
            report.state = 'failed'
            report.completedAt = foundation.utcIso()
            report.failures = foundation.copy(failures)
            preparation = { state = 'failed', report = report }
            return nil, foundation.error('RESTART_PREPARATION_FAILED',
                'Durable cleanup completed, but the local lifecycle could not be finalized.', {
                    retryable = true, details = { failures = #failures }
                })
        end
        report.state = 'prepared'
        report.completedAt = foundation.utcIso()
        report.failures = {}
        preparation = { state = 'prepared', report = report }
        return foundation.copy(report), nil
    end

    function controller:handleRawStop()
        local failures = {}
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
