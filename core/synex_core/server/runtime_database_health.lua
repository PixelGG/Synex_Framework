local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimeDatabaseHealth = function(deps)
    local foundation = assert(deps.foundation, 'runtime database health requires foundation')
    local lifecycle = assert(deps.lifecycle, 'runtime database health requires lifecycle')
    local database = assert(deps.database, 'runtime database health requires database')
    local synchronizeInstanceHealthStatus = assert(deps.synchronizeInstanceHealthStatus,
        'runtime database health requires instance status synchronization')
    local completeRecovery = assert(deps.completeRecovery,
        'runtime database health requires recovery reconciliation')
    local setTimeout = deps.setTimeout
    local logger = foundation.logger
    local healthyProbeIntervalMs = 1000
    local outageProbeIntervalMs = 5000
    local maximumProbeBackoffMs = 15000
    local probeWatchdogMs = 5000
    local recoverySuccessThreshold = 2
    local available = true
    local consecutiveFailures = 0
    local consecutiveRecoverySuccesses = 0
    local nextProbeAt = 0
    local activeProbe = nil
    local probeSequence = 0
    local controller = {}

    local function timeoutFailure()
        return foundation.error('DATABASE_HEALTH_PROBE_TIMEOUT',
            'The runtime database health probe exceeded its fail-closed deadline.', {
                retryable = true
            })
    end

    local function transitionUnavailable(failure, failureAlreadyCounted)
        consecutiveRecoverySuccesses = 0
        if failureAlreadyCounted ~= true then
            consecutiveFailures = math.min(consecutiveFailures + 1, 16)
            local backoffMultiplier = 2 ^ math.min(consecutiveFailures - 1, 2)
            nextProbeAt = foundation.monotonicMs()
                + math.min(outageProbeIntervalMs * backoffMultiplier, maximumProbeBackoffMs)
        end
        local wasAvailable = available
        available = false
        lifecycle.core:setCriticalFoundationsValidated(false)
        lifecycle.core:setHealth('database-runtime', 'UNHEALTHY',
            'runtime database validation failed')
        if lifecycle.core:get() == 'READY' then
            lifecycle.core:transition('DEGRADED', 'runtime database validation failed')
        end
        if wasAvailable then
            logger:error('runtime database became unavailable', {
                code = foundation.failureCode(failure, 'DATABASE_RUNTIME_UNAVAILABLE')
            })
        end
        return nil, foundation.error('DATABASE_RUNTIME_UNAVAILABLE',
            'The runtime database health check failed.', { retryable = true })
    end

    function controller:isAvailable()
        return available
    end

    function controller:snapshot()
        return {
            available = available,
            consecutiveFailures = consecutiveFailures,
            consecutiveRecoverySuccesses = consecutiveRecoverySuccesses,
            recoverySuccessThreshold = recoverySuccessThreshold,
            probeInProgress = activeProbe ~= nil,
            probeWatchdogMs = probeWatchdogMs
        }
    end

    function controller:probe(force)
        local current = lifecycle.core:get()
        if current ~= 'READY' and current ~= 'DEGRADED' then return true, nil end
        if activeProbe ~= nil then return true, nil, 'suspended' end
        local now = foundation.monotonicMs()
        if force ~= true and now < nextProbeAt then
            return true, nil, available and 'cached' or 'suspended'
        end

        probeSequence = probeSequence + 1
        local probe = {
            sequence = probeSequence,
            startedAt = now,
            timedOut = false,
            timeoutCounted = false
        }
        activeProbe = probe
        local function expireProbe()
            if activeProbe ~= probe or probe.timedOut then return end
            probe.timedOut = true
            probe.timeoutCounted = true
            transitionUnavailable(timeoutFailure())
        end
        local function isCurrentProbe()
            if activeProbe ~= probe then return false, 'stale' end
            if probe.timedOut then return false, 'timeout' end
            local state = lifecycle.core:get()
            if state ~= 'READY' and state ~= 'DEGRADED' then return false, 'inactive' end
            if foundation.monotonicMs() - probe.startedAt >= probeWatchdogMs then
                expireProbe()
                return false, 'timeout'
            end
            return true, nil
        end
        local function finishStaleProbe()
            if activeProbe == probe then activeProbe = nil end
            if probe.timedOut then
                return nil, foundation.error('DATABASE_RUNTIME_UNAVAILABLE',
                    'The runtime database health check failed.', { retryable = true })
            end
            return true, nil, 'suspended'
        end
        local function failProbe(failure)
            if activeProbe == probe then activeProbe = nil end
            return transitionUnavailable(failure, probe.timeoutCounted)
        end
        if not foundation.isCallable(setTimeout) then
            activeProbe = nil
            return transitionUnavailable(foundation.error('DATABASE_HEALTH_WATCHDOG_UNAVAILABLE',
                'The runtime database health watchdog is unavailable.'))
        end
        local timerArmed, timerFailure = foundation.safeCall(setTimeout, probeWatchdogMs, function()
            local state = lifecycle.core:get()
            if state == 'READY' or state == 'DEGRADED' then expireProbe() end
        end)
        if not timerArmed then
            activeProbe = nil
            return transitionUnavailable(timerFailure)
        end

        local validationCallOk, valid, validationError = foundation.safeCall(function()
            return database:validateUtcSession()
        end)
        if not isCurrentProbe() then return finishStaleProbe() end
        if not validationCallOk then return failProbe(valid) end
        if not valid then return failProbe(validationError) end

        consecutiveFailures = 0
        nextProbeAt = foundation.monotonicMs() + healthyProbeIntervalMs
        if available then
            activeProbe = nil
            return true, nil
        end

        local synchronizationCallOk, synchronizationError = foundation.safeCall(
            synchronizeInstanceHealthStatus)
        if not isCurrentProbe() then return finishStaleProbe() end
        if not synchronizationCallOk or synchronizationError ~= nil then
            return failProbe(synchronizationError)
        end
        consecutiveRecoverySuccesses = consecutiveRecoverySuccesses + 1
        if consecutiveRecoverySuccesses < recoverySuccessThreshold then
            activeProbe = nil
            return true, nil
        end

        local refreshCallOk, refreshError = foundation.safeCall(function()
            local recovered, recoveryError = completeRecovery(isCurrentProbe)
            if not recovered then
                return recoveryError or foundation.error('DATABASE_RECOVERY_FAILED',
                    'The runtime database recovery reconciliation failed.', { retryable = true })
            end
            return nil
        end)
        if not isCurrentProbe() then return finishStaleProbe() end
        if not refreshCallOk or refreshError ~= nil then return failProbe(refreshError) end
        consecutiveRecoverySuccesses = 0
        available = true
        activeProbe = nil
        logger:info('runtime database health recovered', {
            recoverySuccessThreshold = recoverySuccessThreshold
        })
        return true, nil
    end

    return controller
end
