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
    local refreshLeaseDeadline = assert(deps.refreshLeaseDeadline,
        'connection authority requires local lease deadlines')
    local syncPendingAuthority = assert(deps.syncPendingAuthority,
        'connection authority requires pending authority publication')
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

    local function admissionOpen()
        return not quiesced and lifecycle.core:canAdmitPlayers()
    end

    local function leaseOwner(connection)
        return instanceId .. ':' .. connection.sessionId
    end

    local function sameLease(left, right)
        if type(left) ~= 'table' or type(right) ~= 'table' then return false end
        return (left.name or left.leaseName) == (right.name or right.leaseName)
            and left.owner == right.owner
            and left.fencingToken == right.fencingToken
    end

    local function connectionCurrent(connection)
        local current = type(connection) == 'table'
            and players:getPending(connection.tempSource) or nil
        return current ~= nil and current.id == connection.id
            and current.sessionId == connection.sessionId
            and (connection.userId == nil or current.userId == connection.userId)
    end

    function authority:renewAdmissionGate(connection)
        local gate = type(connection) == 'table' and connection.admissionGateLease or nil
        if not gate or not admissionOpen() or not connectionCurrent(connection) then
            return nil, foundation.error(quiesced and 'CORE_STOPPING' or 'ADMISSION_GATE_LOST',
                'Account admission authority is no longer current.', { retryable = true })
        end
        local attemptStartedAt = foundation.monotonicMs()
        local invoked, renewed, renewError = foundation.safeCall(leases.renew, leases, gate)
        if not invoked or not renewed or not admissionOpen() or not connectionCurrent(connection)
            or not sameLease(gate, connection.admissionGateLease) then
            return nil, type(renewError) == 'table' and renewError
                or foundation.error('ADMISSION_GATE_LOST',
                    'Account admission authority expired.', { retryable = true })
        end
        if not refreshLeaseDeadline(connection, 'admissionGateLease', attemptStartedAt) then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority has no safe local deadline.', { retryable = true })
        end
        local published, publishError = syncPendingAuthority(connection)
        if not published then
            return nil, publishError or foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority could not be published.', { retryable = true })
        end
        return true, nil
    end

    function authority:acquireAdmissionGate(connection, userId, terminal)
        if not admissionOpen() then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime cannot acquire account admission authority.')
        end
        if type(userId) ~= 'string' or #userId < 1 or #userId > 36 then
            return nil, foundation.error('INVALID_USER_ID',
                'Account admission requires a valid user ID.')
        end
        local name = 'admission:' .. userId
        local owner = leaseOwner(connection)
        local deadline = foundation.monotonicMs() + math.min(config.queueTimeoutMs or 120000,
            (config.pendingTtlMs or 120000))
        repeat
            local activeBootId, bootError = instances:bootId()
            if not activeBootId then return nil, bootError end
            local attemptStartedAt = foundation.monotonicMs()
            local lease, leaseError = leases:acquire(
                name, owner, config.clusterSessionLeaseSeconds or 45, instanceId, activeBootId)
            if lease then
                connection.admissionGateLease = lease
                if not refreshLeaseDeadline(
                    connection, 'admissionGateLease', attemptStartedAt) then
                    releaseConnectionLease(connection)
                    return nil, foundation.error('ADMISSION_GATE_LOST',
                        'Account admission authority has no safe local deadline.')
                end
                local published, publishError = syncPendingAuthority(connection)
                if not published then
                    releaseConnectionLease(connection)
                    return nil, publishError or foundation.error('ADMISSION_GATE_LOST',
                        'Account admission authority could not be published.')
                end
                if not admissionOpen() or not connectionCurrent(connection)
                    or (terminal and terminal.state ~= 'open') then
                    releaseConnectionLease(connection)
                    return nil, foundation.error('CORE_STOPPING',
                        'The Synex runtime stopped while admission authority was acquired.')
                end
                return true, nil
            end
            if not leaseError or (leaseError.code ~= 'LEASE_BUSY'
                and leaseError.code ~= 'MIGRATION_LEASE_BUSY') then
                return nil, leaseError
            end
            if foundation.monotonicMs() >= deadline then return nil, leaseError end
            if terminal then terminal:update('Synex: serializing account admission...') end
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
            if terminal then
                terminal:afterTick()
                if terminal.state ~= 'open' then
                    return nil, foundation.error('ADMISSION_GATE_CANCELLED',
                        'Account admission was cancelled while authority was pending.', {
                            retryable = true
                        })
                end
            end
            if not admissionOpen() then
                return nil, foundation.error('CORE_STOPPING',
                    'The Synex runtime stopped while admission authority was pending.')
            end
        until foundation.monotonicMs() >= deadline
        return nil, foundation.error('ADMISSION_GATE_TIMEOUT',
            'Account admission authority did not become available in time.', { retryable = true })
    end

    function authority:acquire(connection, userId, policy)
        if not admissionOpen() then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime is stopping and cannot acquire session authority.')
        end
        local gated, gateError = self:renewAdmissionGate(connection)
        if not gated then return nil, gateError end
        local leaseName = policy == 'allow'
            and ('session:' .. userId .. ':' .. connection.sessionId)
            or ('session:' .. userId)
        local leaseOwner = instanceId .. ':' .. connection.sessionId
        local activeBootId, bootError = instances:bootId()
        if not activeBootId then return nil, bootError end
        if not admissionOpen() or not connectionCurrent(connection) then
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority expired before session authority acquisition.', {
                    retryable = true
                })
        end
        local attemptStartedAt = foundation.monotonicMs()
        local lease, leaseError = leases:acquire(
            leaseName, leaseOwner, config.clusterSessionLeaseSeconds or 45, instanceId, activeBootId)
        if not lease then return nil, leaseError end
        if not admissionOpen() or not connectionCurrent(connection) then
            foundation.safeCall(leases.release, leases, lease)
            return nil, foundation.error('ADMISSION_GATE_LOST',
                'Account admission authority expired while session authority was acquired.', {
                    retryable = true
                })
        end
        connection.clusterLease = lease
        if not refreshLeaseDeadline(connection, 'clusterLease', attemptStartedAt) then
            releaseConnectionLease(connection)
            return nil, foundation.error('LEASE_LOST',
                'Session authority has no safe local deadline.', { retryable = true })
        end
        local published, publishError = syncPendingAuthority(connection)
        if not published then
            releaseConnectionLease(connection)
            return nil, publishError or foundation.error('LEASE_LOST',
                'Session authority could not be published.', { retryable = true })
        end
        if not admissionOpen() then
            releaseConnectionLease(connection)
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime stopped while session authority was being acquired.')
        end
        local stillGated, currentError = self:renewAdmissionGate(connection)
        if not stillGated then
            releaseConnectionLease(connection)
            return nil, currentError
        end
        return true, nil
    end

    function authority:acquireDuplicate(connection, userId, terminal, policy)
        policy = policy or duplicatePolicy()
        local gated, gateError = self:renewAdmissionGate(connection)
        if not gated then return nil, gateError end
        if policy == 'allow' then return self:acquire(connection, userId, policy) end
        if type(instances.hasOpenUserSessions) ~= 'function' then
            return nil, foundation.error('ADMISSION_CHECK_UNAVAILABLE',
                'Durable duplicate-session admission checks are unavailable.')
        end
        local gateSnapshot = foundation.copy(connection.admissionGateLease)
        local function guard()
            return admissionOpen() and connectionCurrent(connection)
                and sameLease(gateSnapshot, connection.admissionGateLease)
        end
        if policy == 'deny_new' then
            local exists, openError = instances:hasOpenUserSessions(
                userId, false, connection.admissionGateLease, guard)
            if exists == nil then return nil, openError end
            local current, currentError = self:renewAdmissionGate(connection)
            if not current then return nil, currentError end
            if exists then
                return nil, foundation.error('DUPLICATE_SESSION',
                    'The user already owns a durable open session.')
            end
            return self:acquire(connection, userId, policy)
        end
        if not admissionOpen() then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime cannot request replacement authority while admission is closed.')
        end
        local deadline = foundation.monotonicMs() + math.min(config.queueTimeoutMs or 120000,
            (config.clusterSessionLeaseSeconds or 45) * 1000 + 5000)
        repeat
            local current, currentError = self:renewAdmissionGate(connection)
            if not current then return nil, currentError end
            local requested, requestError = instances:requestRemoteKicks(
                userId, config.clusterSessionLeaseSeconds or 45, guard,
                connection.admissionGateLease)
            if not requested then return nil, requestError end
            current, currentError = self:renewAdmissionGate(connection)
            if not current then return nil, currentError end
            local durableOpen, openError = instances:hasOpenUserSessions(
                userId, false, connection.admissionGateLease, guard)
            if durableOpen == nil then return nil, openError end
            current, currentError = self:renewAdmissionGate(connection)
            if not current then return nil, currentError end
            local leaseError = nil
            if not durableOpen then
                local acquired
                acquired, leaseError = self:acquire(connection, userId, policy)
                if acquired then return true, nil end
                if not leaseError or (leaseError.code ~= 'LEASE_BUSY'
                    and leaseError.code ~= 'MIGRATION_LEASE_BUSY') then
                    return nil, leaseError
                end
            end
            if foundation.monotonicMs() >= deadline then break end
            if terminal then
                terminal:update((requested > 0 or durableOpen)
                    and 'Synex: replacing the existing cluster session...'
                    or 'Synex: waiting for session authority...')
            end
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
            if terminal then terminal:afterTick() end
            if terminal and terminal.state ~= 'open' then
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
                    if removed.clusterLease or removed.admissionGateLease then
                        capturedLeaseStates[removed.id] = 'captured'
                    end
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
            if connection.clusterLease or connection.admissionGateLease then
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
