local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionAuthority = function(deps)
    local platform = assert(deps.platform, 'connection authority requires platform')
    local foundation = assert(deps.foundation, 'connection authority requires foundation')
    local players = assert(deps.players, 'connection authority requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection authority requires lifecycle')
    local leases = assert(deps.leases, 'connection authority requires cluster leases')
    local instances = assert(deps.instances, 'connection authority requires cluster instances')
    assert(type(instances.bootId) == 'function', 'connection authority requires boot authority')
    local instanceId = assert(deps.instanceId, 'connection authority requires an instance ID')
    local duplicatePolicy = assert(deps.duplicatePolicy, 'connection authority requires duplicate policy')
    local joinClaims = assert(deps.joinClaims, 'connection authority requires join claims')
    local clearQueueEntry = assert(deps.clearQueueEntry, 'connection authority requires queue cleanup')
    local releaseAdmission = assert(deps.releaseAdmission, 'connection authority requires admission release')
    local releaseConnectionLease = assert(deps.releaseConnectionLease, 'connection authority requires lease release')
    local resetAdmissionState = assert(deps.resetAdmissionState, 'connection authority requires admission reset')
    local logConnectionStage = assert(deps.logConnectionStage, 'connection authority requires stage telemetry')
    local config = deps.config or {}

    local quiesced = false
    local quiesceReport = nil
    local quiescedConnections = {}
    local capturedLeaseStates = {}
    local authority = {}

    function authority:isQuiesced()
        return quiesced
    end

    function authority:isLeaseCaptured(connection)
        return type(connection) == 'table' and type(connection.id) == 'string'
            and capturedLeaseStates[connection.id] ~= nil
    end

    function authority:acceptanceRejection(connection)
        local stopping = quiesced
        local admissionClosed = not lifecycle.core:canAdmitPlayers()
        local current = players:getPending(connection.tempSource)
        local pendingCurrent = current ~= nil and current.id == connection.id
        if not stopping and not admissionClosed and pendingCurrent then return nil, nil end
        if admissionClosed and not stopping and pendingCurrent then
            local removed = players:removePending(connection.tempSource)
            if removed then
                clearQueueEntry(removed)
                releaseAdmission(removed)
                releaseConnectionLease(removed)
            end
        end
        if stopping then
            return 'The Synex runtime is stopping. Please reconnect shortly.', 'CORE_STOPPING'
        end
        if admissionClosed then
            return 'The Synex runtime stopped accepting this connection. Please reconnect shortly.',
                'CORE_NOT_READY'
        end
        return 'The connection attempt was cancelled. Please reconnect.', 'CONNECTION_CANCELLED'
    end

    function authority:acquire(connection, userId)
        if quiesced then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime is stopping and cannot acquire session authority.')
        end
        local policy = duplicatePolicy()
        local leaseName = policy == 'allow'
            and ('session:' .. userId .. ':' .. connection.sessionId)
            or ('session:' .. userId)
        local leaseOwner = instanceId .. ':' .. connection.sessionId
        local activeBootId, bootError = instances:bootId()
        if not activeBootId then return nil, bootError end
        local lease, leaseError = leases:acquire(
            leaseName, leaseOwner, config.clusterSessionLeaseSeconds or 45, instanceId, activeBootId)
        if not lease then return nil, leaseError end
        connection.clusterLease = lease
        if quiesced then
            releaseConnectionLease(connection)
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime stopped while session authority was being acquired.')
        end
        return true, nil
    end

    function authority:acquireDuplicate(connection, userId, terminal)
        local policy = duplicatePolicy()
        if policy == 'allow' or policy == 'deny_new' then return self:acquire(connection, userId) end
        if quiesced or not lifecycle.core:canAdmitPlayers() then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime cannot request replacement authority while admission is closed.')
        end
        local requested, requestError = instances:requestRemoteKicks(
            userId,
            config.clusterSessionLeaseSeconds or 45,
            function() return not quiesced and lifecycle.core:canAdmitPlayers() end)
        if not requested then return nil, requestError end
        local deadline = foundation.monotonicMs() + math.min(config.queueTimeoutMs or 120000,
            (config.clusterSessionLeaseSeconds or 45) * 1000 + 5000)
        repeat
            local acquired, leaseError = self:acquire(connection, userId)
            if acquired then return true, nil end
            if not leaseError or (leaseError.code ~= 'LEASE_BUSY'
                and leaseError.code ~= 'MIGRATION_LEASE_BUSY') then
                return nil, leaseError
            end
            if foundation.monotonicMs() >= deadline then return nil, leaseError end
            terminal:update(requested > 0
                and 'Synex: replacing the existing cluster session...'
                or 'Synex: waiting for session authority...')
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
            terminal:afterTick()
            if terminal.state ~= 'open' then
                return nil, foundation.error('CORE_STOPPING',
                    'The Synex runtime stopped while replacement authority was pending.', { retryable = true })
            end
        until foundation.monotonicMs() >= deadline
        return nil, foundation.error('DUPLICATE_SESSION_TIMEOUT',
            'The existing cluster session did not release authority in time.', { retryable = true })
    end

    function authority:quiesce()
        if quiesced then return foundation.copy(quiesceReport), nil end
        quiesced = true
        local invalidatedClaims = joinClaims:invalidateAll()
        local removedConnections = {}
        for _, entry in ipairs(players:listPending()) do
            local current = players:getPending(entry.source)
            if current and current.id == entry.connection.id then
                local removed = players:removePending(entry.source)
                if removed then
                    clearQueueEntry(removed)
                    releaseAdmission(removed)
                    if removed.clusterLease then capturedLeaseStates[removed.id] = 'captured' end
                    removedConnections[#removedConnections + 1] = removed
                end
            end
        end
        resetAdmissionState()
        quiesceReport = {
            invalidatedClaims = invalidatedClaims,
            removedPending = #removedConnections,
            releasedLeases = 0,
            leaseReleaseFailures = 0
        }
        for _, connection in ipairs(removedConnections) do
            logConnectionStage(connection, 'pending_cancelled', 'CORE_QUIESCING', 'warn')
            quiescedConnections[#quiescedConnections + 1] = connection
        end
        return foundation.copy(quiesceReport), nil
    end

    function authority:releaseQuiescedLeases()
        if not quiesced then
            return nil, foundation.error('CORE_NOT_QUIESCED',
                'Connection authority must be quiesced before leases are released.')
        end
        local connections = quiescedConnections
        quiescedConnections = {}
        for _, connection in ipairs(connections) do
            if connection.clusterLease then
                capturedLeaseStates[connection.id] = 'releasing'
                local released = releaseConnectionLease(connection)
                capturedLeaseStates[connection.id] = released and 'released' or 'failed'
                if released then
                    quiesceReport.releasedLeases = quiesceReport.releasedLeases + 1
                else
                    quiesceReport.leaseReleaseFailures = quiesceReport.leaseReleaseFailures + 1
                end
            end
        end
        return foundation.copy(quiesceReport), nil
    end

    return authority
end
