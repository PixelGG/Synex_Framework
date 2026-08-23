local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnections = function(deps)
    local platform = assert(deps.platform, 'identity connections requires platform')
    local foundation = assert(deps.foundation, 'identity connections requires foundation')
    local players = assert(deps.players, 'identity connections requires player registry')
    local owners = assert(deps.owners, 'identity connections requires owner registry')
    local lifecycle = assert(deps.lifecycle, 'identity connections requires lifecycle')
    local messaging = assert(deps.messaging, 'identity connections requires messaging')
    local stateService = deps.stateService or { purgePlayer = function() return { failures = {} }, nil end }
    local logger = foundation.logger
    local metrics = foundation.metrics
    local config = deps.config or {}
    if config.queueEnabled == true then
        assert(type(platform.setTimeout) == 'function',
            'identity connection queue requires timeout scheduling')
    end
    local leases = assert(deps.leases, 'identity connections requires cluster leases')
    local instances = assert(deps.instances, 'identity connections requires cluster instances')
    local characters = assert(deps.characters, 'identity connections requires character service')
    local userRepository = assert(deps.userRepository, 'identity connections requires user repository')
    local sessionRepository = assert(deps.sessionRepository, 'identity connections requires session repository')
    local accessRepository = assert(deps.accessRepository, 'identity connections requires access repository')
    local rateLimiter = assert(deps.rateLimiter, 'identity connections requires rate limiter')
    local invokeOwned = assert(deps.invokeOwned, 'identity connections requires owned invocation')
    local normalizeIdentifiers = assert(deps.normalizeIdentifiers, 'identity connections requires identifier normalization')
    local sha256 = assert(deps.sha256, 'identity connections requires SHA-256')
    local sessionTransitions = assert(deps.sessionTransitions, 'identity connections requires transition map')
    local transition = assert(deps.transition, 'identity connections requires session transitions')

    local gates = {}
    local gateSequence = 0
    local queueEntries = {}
    local queueSequence = 0
    local queueCount = 0
    local queueEntryCount = 0
    local queueGrantCount = 0
    local queueOrdered = {}
    local queueRanks = {}
    local queueRankTotal = 0
    local queueDirty = false
    local queueArbiterRunning = false
    local queueArbiterScheduled = false
    local queueGeneration = 0
    local queueLastArbitratedAt = nil
    local queueOldestQueuedAt = nil
    local admissionReservations = {}
    local admissionReservationCount = 0
    local reconnectGrace = {}
    local reconnectGraceSize = 0
    local queueStats = {
        admitted = 0, timedOut = 0, rejected = 0, peak = 0,
        arbiterRuns = 0, sorts = 0
    }
    local connectionPipeline, authority, maintenance = {}, nil, nil
    local function pendingDisconnectRetries()
        return maintenance and type(maintenance.pendingDisconnectRetries) == 'function'
            and maintenance:pendingDisconnectRetries() or 0
    end
    local ingress = factories.identityConnectionIngress({
        platform = platform, foundation = foundation,
        rateLimiter = rateLimiter, sha256 = sha256, config = config
    })
    local function logConnectionStage(...) return ingress:logStage(...) end
    local function identifierFingerprint(...) return ingress:identityFingerprint(...) end
    local joinClaims = factories.identityConnectionClaims({ foundation = foundation })

    local deadlineFields = {
        clusterLease = 'clusterLeaseDeadlineAt',
        admissionGateLease = 'admissionGateDeadlineAt'
    }
    local function recomputeAuthorityDeadline(connection)
        local deadline = nil
        for leaseField, deadlineField in pairs(deadlineFields) do
            if connection[leaseField] then
                local candidate = connection[deadlineField]
                if type(candidate) ~= 'number' then
                    connection.authorityDeadlineAt = nil
                    return nil
                end
                deadline = deadline == nil and candidate or math.min(deadline, candidate)
            end
        end
        connection.authorityDeadlineAt = deadline
        return deadline
    end
    local function refreshLeaseDeadline(connection, leaseField, attemptStartedAt)
        if type(connection) ~= 'table' or deadlineFields[leaseField] == nil
            or type(connection[leaseField]) ~= 'table'
            or type(attemptStartedAt) ~= 'number' then return nil end
        local ttlMs = math.max(5000,
            math.min(tonumber(connection[leaseField].ttlSeconds) or
                tonumber(config.clusterSessionLeaseSeconds) or 45, 300) * 1000)
        local heartbeatMs = math.max(1000,
            math.min(tonumber(config.clusterHeartbeatMs) or 10000, ttlMs - 1000))
        local marginMs = math.max(1000, math.min(ttlMs - 1000, heartbeatMs * 2))
        local deadline = attemptStartedAt + math.max(1000, ttlMs - marginMs)
        if deadline <= foundation.monotonicMs() then return nil end
        connection[deadlineFields[leaseField]] = deadline
        return recomputeAuthorityDeadline(connection)
    end
    local function clearLeaseDeadline(connection, leaseField)
        if type(connection) ~= 'table' or deadlineFields[leaseField] == nil then return end
        connection[deadlineFields[leaseField]] = nil
        recomputeAuthorityDeadline(connection)
    end

    local function releaseAdmission(connection)
        local connectionId = type(connection) == 'table' and connection.id or connection
        if type(connectionId) == 'string' and admissionReservations[connectionId] then
            admissionReservations[connectionId] = nil
            admissionReservationCount = math.max(0, admissionReservationCount - 1)
        end
        ingress:release(connection)
    end

    local function reserveAdmission(connection)
        local connectionId = type(connection) == 'table' and connection.id or connection
        if type(connectionId) == 'string' and not admissionReservations[connectionId] then
            admissionReservations[connectionId] = true
            admissionReservationCount = admissionReservationCount + 1
        end
    end

    local function removeQueueEntry(connection, reason)
        local connectionId = type(connection) == 'table' and connection.id or connection
        if type(connectionId) ~= 'string' then return false end
        local entry = queueEntries[connectionId]
        if not entry then return false end
        reason = reason or (authority and authority:isQuiesced() and 'quiesce' or 'clear')
        queueEntries[connectionId] = nil
        queueEntryCount = math.max(0, queueEntryCount - 1)
        queueRanks[connectionId] = nil
        if entry.state == 'granted' then
            queueGrantCount = math.max(0, queueGrantCount - 1)
        else
            queueCount = math.max(0, queueCount - 1)
        end
        queueRankTotal = queueCount
        queueDirty = true
        if entry.queuedAt == queueOldestQueuedAt then queueOldestQueuedAt = nil end
        if reason == 'admit' then
            queueStats.admitted = queueStats.admitted + 1
            foundation.safeCall(metrics.increment, metrics,
                'synex_connection_queue_total', { result = 'admitted' })
        else
            releaseAdmission(connectionId)
            if reason == 'timeout' then
                queueStats.timedOut = queueStats.timedOut + 1
                foundation.safeCall(metrics.increment, metrics,
                    'synex_connection_queue_total', { result = 'timeout' })
            end
        end
        if queueEntryCount == 0 then
            queueSequence = 0
            queueCount = 0
            queueGrantCount = 0
            queueOrdered = {}
            queueRanks = {}
            queueRankTotal = 0
            queueDirty = false
            queueOldestQueuedAt = nil
        end
        return true
    end

    local function pendingIsCurrent(connection)
        local pending = players:getPending(connection.tempSource)
        return pending ~= nil and pending.id == connection.id
    end

    local function syncPending(connection)
        return players:updatePending(connection.tempSource, function(candidate)
            if candidate.id ~= connection.id then error('pending connection identity changed') end
            candidate.state = connection.state
            candidate.userId = connection.userId
            candidate.priority = connection.priority
            candidate.reconnectGrace = connection.reconnectGrace
            candidate.admissionGateLease = foundation.copy(connection.admissionGateLease)
            candidate.clusterLease = foundation.copy(connection.clusterLease)
            candidate.admissionGateDeadlineAt = connection.admissionGateDeadlineAt
            candidate.clusterLeaseDeadlineAt = connection.clusterLeaseDeadlineAt
            candidate.authorityDeadlineAt = connection.authorityDeadlineAt
            candidate.acceptedAt = connection.acceptedAt
            candidate.expiresAt = connection.expiresAt
        end)
    end

    local function duplicatePolicy()
        if config.duplicatePolicy == 'replace_old' then return 'kick_old' end
        if config.duplicatePolicy == 'kick_old' or config.duplicatePolicy == 'allow' then return config.duplicatePolicy end
        return 'deny_new'
    end

    local function aceAllowed(playerSource, ace)
        if type(ace) ~= 'string' or ace == '' or type(platform.isPlayerAceAllowed) ~= 'function' then return false end
        local ok, allowed = foundation.safeCall(platform.isPlayerAceAllowed, playerSource, ace)
        return ok and allowed == true
    end

    local function releaseConnectionLease(connection)
        if type(connection) ~= 'table' then return true, nil end
        local firstError = nil
        local released = true
        for _, field in ipairs({ 'clusterLease', 'admissionGateLease' }) do
            local lease = connection[field]
            if lease then
                local invoked, value, err = foundation.safeCall(leases.release, leases, lease)
                if not invoked then
                    err = foundation.error('LEASE_RELEASE_FAILED',
                        'Connection authority could not be released.')
                    value = nil
                end
                local stale = type(err) == 'table' and err.code == 'LEASE_LOST'
                if value or stale then
                    connection[field] = nil
                    clearLeaseDeadline(connection, field)
                end
                if not value and not stale then
                    released = false
                    firstError = firstError or err
                    foundation.safeCall(logger.warn, logger, 'connection authority lease release failed', {
                        correlationId = connection.id,
                        leaseKind = field == 'admissionGateLease' and 'admission_gate' or 'session',
                        code = type(err) == 'table' and err.code or 'LEASE_RELEASE_FAILED'
                    })
                end
            end
        end
        return released and true or nil, firstError
    end

    local function releaseUncapturedConnectionLease(connection)
        if authority and authority:isLeaseCaptured(connection) then return true, nil end
        return releaseConnectionLease(connection)
    end

    local function abandonConnection(connection)
        removeQueueEntry(connection, 'abandon')
        releaseAdmission(connection)
        releaseUncapturedConnectionLease(connection)
    end

    local function recordReconnectGrace(userId)
        local ttl = math.max(0, math.min(tonumber(config.queueReconnectGraceMs) or 60000, 600000))
        if ttl == 0 or type(userId) ~= 'string' then return end
        if not reconnectGrace[userId] then
            reconnectGraceSize = reconnectGraceSize + 1
            if reconnectGraceSize > 2048 then
                local oldestUser, oldestAt = nil, nil
                for candidate, entry in pairs(reconnectGrace) do
                    if oldestAt == nil or entry.expiresAt < oldestAt then oldestUser, oldestAt = candidate, entry.expiresAt end
                end
                if oldestUser then reconnectGrace[oldestUser] = nil; reconnectGraceSize = reconnectGraceSize - 1 end
            end
        end
        reconnectGrace[userId] = { expiresAt = foundation.monotonicMs() + ttl }
    end

    local function connectionPriority(connection, userId)
        local priority = 0
        if connection.staff then priority = priority + math.max(1, math.min(tonumber(config.queueStaffPriority) or 1000, 100000)) end
        local grace = reconnectGrace[userId]
        if grace and grace.expiresAt > foundation.monotonicMs() then
            priority = priority + math.max(1, math.min(tonumber(config.queueReconnectPriority) or 500, 100000))
            connection.reconnectGrace = true
            reconnectGrace[userId] = nil
            reconnectGraceSize = math.max(0, reconnectGraceSize - 1)
        end
        return priority
    end
    local replacements = factories.identityConnectionReplacement({
        platform = platform,
        foundation = foundation,
        players = players,
        messaging = messaging,
        stateService = stateService,
        characters = characters,
        instanceId = deps.instanceId,
        sessionRepository = sessionRepository,
        releaseConnectionLease = releaseUncapturedConnectionLease,
        isQuiesced = function() return authority and authority:isQuiesced() or false end
    })
    function connectionPipeline:registerGate(owner, epoch, definition)
        if type(definition) ~= 'table' or type(definition.name) ~= 'string' or #definition.name < 3 or #definition.name > 96
            or definition.name:find('[%z\1-\31\127]') or type(definition.run) ~= 'function' then
            return nil, foundation.error('INVALID_GATE', 'Connection gate name and handler are required.')
        end
        local priority = definition.priority == nil and 0 or definition.priority
        local timeoutMs = definition.timeoutMs == nil and (config.gateTimeoutMs or 10000) or definition.timeoutMs
        if type(priority) ~= 'number' or math.type(priority) ~= 'integer' or priority < -1000 or priority > 1000
            or type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer' or timeoutMs < 100 or timeoutMs > 30000 then
            return nil, foundation.error('INVALID_GATE', 'Connection gate priority or timeout is invalid.')
        end
        gateSequence = gateSequence + 1
        local token = foundation.nextId('connection_gate')
        gates[token] = {
            owner = owner, epoch = epoch, token = token, name = definition.name, run = definition.run,
            priority = priority, sequence = gateSequence, timeoutMs = timeoutMs
        }
        local _, err = owners:track(owner, epoch, 'connection_gate', token, function() gates[token] = nil end)
        if err then gates[token] = nil return nil, err end
        return token, nil
    end
    local function orderedGates()
        local result = {}
        for _, gate in pairs(gates) do if owners:isCurrent(gate.owner, gate.epoch) then result[#result + 1] = gate end end
        table.sort(result, function(a, b)
            if a.priority == b.priority then return a.sequence < b.sequence end
            return a.priority < b.priority
        end)
        return result
    end

    local function runQueueArbiter(now)
        if queueArbiterRunning or queueEntryCount == 0
            or (authority and authority:isQuiesced()) then return false end
        local interval = math.max(250, math.min(tonumber(config.queueUpdateMs) or 1000, 5000))
        if queueLastArbitratedAt ~= nil and now - queueLastArbitratedAt < interval then return false end
        queueArbiterRunning = true
        queueLastArbitratedAt = now
        queueStats.arbiterRuns = queueStats.arbiterRuns + 1
        local invoked, arbitrationError = foundation.safeCall(function()
            local ordered = queueOrdered
            if queueDirty then
                ordered = {}
                for _, entry in pairs(queueEntries) do
                    if entry.state == 'waiting' then ordered[#ordered + 1] = entry end
                end
                table.sort(ordered, function(a, b)
                    if a.priority == b.priority then return a.sequence < b.sequence end
                    return a.priority > b.priority
                end)
                queueStats.sorts = queueStats.sorts + 1
            end

            local maximumActive = math.max(1, tonumber(config.maximumActiveSessions) or 128)
            local reserved = math.max(0,
                math.min(tonumber(config.queueReservedSlots) or 0, maximumActive - 1))
            local active = players:activeCount() + pendingDisconnectRetries()
            local waiting = {}
            local ranks = {}
            local oldest = nil
            for _, entry in ipairs(ordered) do
                if queueEntries[entry.connectionId] == entry and entry.state == 'waiting' then
                    local limit = entry.staff and maximumActive or maximumActive - reserved
                    if entry.deadline > now and active + admissionReservationCount < limit then
                        entry.state = 'granted'
                        entry.grantedAt = now
                        queueCount = math.max(0, queueCount - 1)
                        queueGrantCount = queueGrantCount + 1
                        reserveAdmission(entry.connectionId)
                    else
                        waiting[#waiting + 1] = entry
                        ranks[entry.connectionId] = #waiting
                        if oldest == nil or entry.queuedAt < oldest then oldest = entry.queuedAt end
                    end
                end
            end
            queueOrdered = waiting
            queueRanks = ranks
            queueRankTotal = #waiting
            queueOldestQueuedAt = oldest
            queueDirty = false
        end)
        queueArbiterRunning = false
        if not invoked then
            queueDirty = true
            foundation.safeCall(logger.error, logger, 'connection queue arbitration failed', {
                code = foundation.failureCode(arbitrationError, 'QUEUE_ARBITRATION_FAILED')
            })
            return false
        end
        return true
    end

    local function armQueueArbiter()
        if queueArbiterScheduled or queueCount == 0
            or (authority and authority:isQuiesced()) then return false end
        local interval = math.max(250, math.min(tonumber(config.queueUpdateMs) or 1000, 5000))
        local now = foundation.monotonicMs()
        local delay = queueLastArbitratedAt == nil and 0
            or math.max(0, interval - (now - queueLastArbitratedAt))
        local generation = queueGeneration
        queueArbiterScheduled = true
        platform.setTimeout(delay, function()
            if generation ~= queueGeneration then return end
            queueArbiterScheduled = false
            if queueCount == 0 or (authority and authority:isQuiesced()) then return end
            runQueueArbiter(foundation.monotonicMs())
            if queueCount > 0 then armQueueArbiter() end
        end)
        return true
    end

    local function waitForQueue(connection, terminal)
        local maximumActive = math.max(1, tonumber(config.maximumActiveSessions) or 128)
        local reserved = math.max(0, math.min(tonumber(config.queueReservedSlots) or 0, maximumActive - 1))
        local admissionLimit = connection.staff and maximumActive or maximumActive - reserved
        if config.queueEnabled ~= true then
            if players:activeCount() + pendingDisconnectRetries()
                + admissionReservationCount >= admissionLimit then
                queueStats.rejected = queueStats.rejected + 1
                return nil, foundation.error('SERVER_FULL', 'The server has reached its active session limit.', { retryable = true })
            end
            reserveAdmission(connection)
            return true, nil
        end
        if queueCount >= (config.maximumQueued or 128) then
            queueStats.rejected = queueStats.rejected + 1
            return nil, foundation.error('QUEUE_FULL', 'The connection queue is full.', { retryable = true })
        end
        local queuedAt = foundation.monotonicMs()
        queueSequence = queueSequence + 1
        queueEntries[connection.id] = {
            connectionId = connection.id, priority = connection.priority or 0, sequence = queueSequence,
            staff = connection.staff == true, state = 'waiting', queuedAt = queuedAt,
            deadline = queuedAt + (config.queueTimeoutMs or 120000)
        }
        queueCount = queueCount + 1
        queueEntryCount = queueEntryCount + 1
        queueRankTotal = queueCount
        queueDirty = true
        if queueOldestQueuedAt == nil then queueOldestQueuedAt = queuedAt end
        queueStats.peak = math.max(queueStats.peak, queueCount)
        armQueueArbiter()
        local lastPosition = nil
        while true do
            local entry = queueEntries[connection.id]
            if not entry then
                return nil, foundation.error('QUEUE_CANCELLED',
                    'The connection queue entry was cancelled.', { retryable = true })
            end
            if not pendingIsCurrent(connection) or (authority and authority:isQuiesced())
                or terminal.state ~= 'open' then
                removeQueueEntry(connection, 'cancel')
                return nil, foundation.error('QUEUE_CANCELLED',
                    'The connection queue wait was cancelled.', { retryable = true })
            end
            local now = foundation.monotonicMs()
            if now >= entry.deadline then
                removeQueueEntry(connection, 'timeout')
                return nil, foundation.error('QUEUE_TIMEOUT', 'The connection queue wait timed out.', { retryable = true })
            end
            if entry.state == 'granted' then
                removeQueueEntry(connection, 'admit')
                return true, nil
            end
            local position, total = queueRanks[connection.id], queueRankTotal
            if position ~= lastPosition then
                terminal:update(('Synex: queue position %d of %d'):format(position or total, total))
                lastPosition = position
            end
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
            terminal:afterTick()
            if terminal.state ~= 'open' then
                removeQueueEntry(connection, 'cancel')
                return nil, foundation.error('QUEUE_CANCELLED',
                    'The connection queue wait was cancelled.', { retryable = true })
            end
        end
    end

    authority = factories.identityConnectionAuthority({
        platform = platform, foundation = foundation, players = players, lifecycle = lifecycle,
        leases = leases, instances = instances, instanceId = deps.instanceId, config = config,
        duplicatePolicy = duplicatePolicy, joinClaims = joinClaims,
        clearQueueEntry = removeQueueEntry, releaseAdmission = releaseAdmission,
        releaseConnectionLease = releaseConnectionLease,
        refreshLeaseDeadline = refreshLeaseDeadline,
        syncPendingAuthority = syncPending,
        resetAdmissionState = function()
            while queueEntryCount > 0 do
                local connectionId = next(queueEntries)
                if not connectionId then break end
                removeQueueEntry(connectionId, 'reset')
            end
            queueEntries = {}
            queueSequence = 0
            queueCount = 0
            queueEntryCount = 0
            queueGrantCount = 0
            queueOrdered = {}
            queueRanks = {}
            queueRankTotal = 0
            queueDirty = false
            queueArbiterRunning = false
            queueArbiterScheduled = false
            queueGeneration = queueGeneration + 1
            queueLastArbitratedAt = nil
            queueOldestQueuedAt = nil
            admissionReservations = {}
            admissionReservationCount = 0
            ingress:quiesce()
        end,
        logConnectionStage = logConnectionStage
    })
    local terminals = factories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function(connection) return authority:acceptanceRejection(connection) end,
        logConnectionStage = logConnectionStage,
        onFinalized = function(connection, accepted)
            if accepted ~= true then ingress:release(connection) end
        end
    })
    local terminalQuiesceReport = { cancelled = 0, failures = 0 }

    local handleConnecting = factories.identityConnectionConnecting({
        platform = platform,
        foundation = foundation,
        players = players,
        lifecycle = lifecycle,
        config = config,
        ingress = ingress,
        terminals = terminals,
        authority = authority,
        normalizeIdentifiers = normalizeIdentifiers,
        identifierFingerprint = identifierFingerprint,
        userRepository = userRepository,
        accessRepository = accessRepository,
        connectionPriority = connectionPriority,
        syncPending = syncPending,
        waitForQueue = waitForQueue,
        releaseAdmission = releaseAdmission,
        abandonConnection = abandonConnection,
        orderedGates = orderedGates,
        invokeOwned = invokeOwned,
        releaseConnectionLease = releaseUncapturedConnectionLease,
        replacements = replacements,
        duplicatePolicy = duplicatePolicy,
        logConnectionStage = logConnectionStage,
        pendingIsCurrent = pendingIsCurrent,
        aceAllowed = aceAllowed
    })

    function connectionPipeline:handleConnecting(tempSource, playerName, deferrals)
        return handleConnecting(tempSource, playerName, deferrals)
    end

    local handleJoining = factories.identityConnectionJoin({
        platform = platform,
        foundation = foundation,
        players = players,
        lifecycle = lifecycle,
        rateLimiter = rateLimiter,
        userRepository = userRepository,
        sessionRepository = sessionRepository,
        normalizeIdentifiers = normalizeIdentifiers,
        identifierFingerprint = identifierFingerprint,
        transition = transition,
        leases = leases,
        joinClaims = joinClaims,
        isQuiesced = function() return authority:isQuiesced() end,
        logConnectionStage = logConnectionStage,
        releaseAdmission = releaseAdmission,
        releaseConnectionLease = releaseUncapturedConnectionLease,
        refreshLeaseDeadline = refreshLeaseDeadline,
        clearLeaseDeadline = clearLeaseDeadline,
        closeOrDeferSession = function(...)
            return maintenance:closeOrDefer(...)
        end,
        clearQueueEntry = removeQueueEntry
    })
    function connectionPipeline:handleJoining(finalSource, oldSource) return handleJoining(finalSource, oldSource) end

    function connectionPipeline:quiesce()
        local report, quiesceError = authority:quiesce()
        if not report then return nil, quiesceError end
        local cancelled = terminals:quiesce()
        terminalQuiesceReport.cancelled = terminalQuiesceReport.cancelled + cancelled.cancelled
        terminalQuiesceReport.failures = terminalQuiesceReport.failures + cancelled.failures
        report.cancelledDeferrals = terminalQuiesceReport.cancelled
        report.deferralFailures = terminalQuiesceReport.failures
        return report, nil
    end
    function connectionPipeline:drainQuiescedTerminals()
        if not authority:isQuiesced() then
            return nil, foundation.error('CORE_NOT_QUIESCED',
                'Connection authority must be quiesced before deferrals are drained.')
        end
        platform.defer()
        return terminals:flushQuiesced()
    end
    function connectionPipeline:flushReadyQuiescedTerminals()
        return terminals:flushReadyQuiesced()
    end
    function connectionPipeline:releaseQuiescedLeases() return authority:releaseQuiescedLeases() end

    maintenance = factories.identityConnectionMaintenance({
        platform = platform,
        foundation = foundation,
        players = players,
        lifecycle = lifecycle,
        messaging = messaging,
        stateService = stateService,
        config = config,
        leases = leases,
        instances = instances,
        characters = characters,
        sessionRepository = sessionRepository,
        sessionTransitions = sessionTransitions,
        transition = transition,
        rateLimiter = rateLimiter,
        joinClaims = joinClaims,
        logConnectionStage = logConnectionStage,
        releaseAdmission = releaseAdmission,
        releaseConnectionLease = releaseUncapturedConnectionLease,
        refreshLeaseDeadline = refreshLeaseDeadline,
        clearQueueEntry = removeQueueEntry,
        recordReconnectGrace = recordReconnectGrace,
        isQuiesced = function() return authority:isQuiesced() end,
        purgeReconnectGrace = function(now)
            for userId, entry in pairs(reconnectGrace) do
                if entry.expiresAt <= now then
                    reconnectGrace[userId] = nil
                    reconnectGraceSize = math.max(0, reconnectGraceSize - 1)
                end
            end
        end
    })
    function connectionPipeline:handleDropped(playerSource, reason)
        playerSource = tonumber(playerSource) or playerSource
        ingress:releaseSource(playerSource)
        return maintenance:handleDropped(playerSource, reason)
    end
    function connectionPipeline:purgeExpired(maximum) return maintenance:purgeExpired(maximum) end
    function connectionPipeline:reconcileClosures(maximum)
        return maintenance:reconcileClosures(maximum)
    end
    function connectionPipeline:heartbeat()
        if authority:isQuiesced() then return true, nil end
        local invoked, report, reconciliationError = foundation.safeCall(replacements.reconcile, replacements, 8)
        if not invoked or not report then
            foundation.safeCall(metrics.increment, metrics,
                'synex_replacement_close_reconciliation_total', { result = 'failed' })
            foundation.safeCall(logger.error, logger, 'replacement session close reconciliation failed', {
                code = invoked and reconciliationError and reconciliationError.code or 'RUNTIME_ERROR'
            })
        end
        if authority:isQuiesced() then return true, nil end
        return maintenance:heartbeat()
    end
    function connectionPipeline:snapshot()
        local now = foundation.monotonicMs()
        local oldestWaitMs = queueOldestQueuedAt
            and math.max(0, now - queueOldestQueuedAt) or 0
        return {
            quiesced = authority:isQuiesced(),
            openDeferrals = terminals:count(),
            enabled = config.queueEnabled == true,
            maintenance = config.maintenanceMode == true,
            queued = queueCount,
            granted = queueGrantCount,
            activeSessions = players:activeCount(),
            pendingDisconnectRetries = pendingDisconnectRetries(),
            maximumQueued = config.maximumQueued or 128,
            maximumActiveSessions = config.maximumActiveSessions or 128,
            reservedSlots = config.queueReservedSlots or 0,
            admissionReservations = admissionReservationCount,
            reconnectGraceEntries = reconnectGraceSize,
            oldestWaitMs = oldestWaitMs,
            admitted = queueStats.admitted,
            timedOut = queueStats.timedOut,
            rejected = queueStats.rejected,
            peak = queueStats.peak,
            arbiterRuns = queueStats.arbiterRuns,
            queueSorts = queueStats.sorts,
            duplicatePolicy = duplicatePolicy(),
            preAuth = ingress:snapshot()
        }
    end

    return connectionPipeline
end
