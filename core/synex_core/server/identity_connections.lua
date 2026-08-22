local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnections = function(deps)
    local platform = assert(deps.platform, 'identity connections requires platform')
    local foundation = assert(deps.foundation, 'identity connections requires foundation')
    local players = assert(deps.players, 'identity connections requires player registry')
    local owners = assert(deps.owners, 'identity connections requires owner registry')
    local lifecycle = assert(deps.lifecycle, 'identity connections requires lifecycle')
    local messaging = assert(deps.messaging, 'identity connections requires messaging')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local config = deps.config or {}
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
    local admissionReservations = {}
    local admissionReservationCount = 0
    local reconnectGrace = {}
    local reconnectGraceSize = 0
    local queueStats = { admitted = 0, timedOut = 0, rejected = 0, peak = 0 }
    local connectionPipeline, authority = {}, nil
    local joinClaims = factories.identityConnectionClaims({ foundation = foundation })
    local function clearQueueEntry(connection) if connection and connection.id then queueEntries[connection.id] = nil end end
    local function identifierFingerprint(identifiers)
        local canonical = {}
        for _, identifier in ipairs(identifiers or {}) do
            local normalized = identifier.normalized
            if type(normalized) ~= 'string' then
                normalized = type(identifier.type) == 'string' and type(identifier.value) == 'string'
                    and (identifier.type .. ':' .. identifier.value) or nil
            end
            if type(normalized) == 'string' and normalized ~= '' then
                canonical[#canonical + 1] = tostring(#normalized) .. ':' .. normalized
            end
        end
        if #canonical == 0 then return nil end
        table.sort(canonical)
        return sha256('synex-connection-identity-v1\0' .. table.concat(canonical, '\0'))
    end

    local function logConnectionStage(connection, stage, code, level)
        foundation.safeCall(function()
            local elapsedMs = math.max(0,
                foundation.monotonicMs() - (connection.receivedAt or foundation.monotonicMs()))
            local fields = {
                correlationId = connection.id,
                stage = stage,
                elapsedMs = elapsedMs,
                code = code
            }
            foundation.safeCall(metrics.increment, metrics, 'synex_connection_stage_total', { stage = stage })
            foundation.safeCall(metrics.observe, metrics, 'synex_connection_stage_elapsed_ms', { stage = stage }, elapsedMs)
            foundation.safeCall(logger[level or 'info'], logger, 'connection stage', fields)
        end)
    end

    local function releaseAdmission(connection)
        local connectionId = type(connection) == 'table' and connection.id or connection
        if type(connectionId) == 'string' and admissionReservations[connectionId] then
            admissionReservations[connectionId] = nil
            admissionReservationCount = math.max(0, admissionReservationCount - 1)
        end
    end

    local function reserveAdmission(connection)
        if not admissionReservations[connection.id] then
            admissionReservations[connection.id] = true
            admissionReservationCount = admissionReservationCount + 1
        end
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
            candidate.clusterLease = foundation.copy(connection.clusterLease)
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
        if connection and connection.clusterLease then
            local invoked, released, err = foundation.safeCall(leases.release, leases, connection.clusterLease)
            connection.clusterLease = nil
            if not invoked then
                err = foundation.error('LEASE_RELEASE_FAILED', 'Cluster session authority could not be released.')
                released = nil
            end
            if not released then
                foundation.safeCall(logger.warn, logger, 'cluster session lease release failed', {
                    correlationId = connection.id,
                    code = type(err) == 'table' and err.code or 'LEASE_RELEASE_FAILED'
                })
            end
            return released and true or nil, err
        end
        return true, nil
    end

    local function releaseUncapturedConnectionLease(connection)
        if authority and authority:isLeaseCaptured(connection) then return true, nil end
        return releaseConnectionLease(connection)
    end

    local function abandonConnection(connection)
        queueEntries[connection.id] = nil
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
        characters = characters,
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

    local function queuePosition(connectionId)
        local ordered = {}
        for _, entry in pairs(queueEntries) do ordered[#ordered + 1] = entry end
        table.sort(ordered, function(a, b)
            if a.priority == b.priority then return a.sequence < b.sequence end
            return a.priority > b.priority
        end)
        for index, entry in ipairs(ordered) do if entry.connectionId == connectionId then return index, #ordered end end
        return nil, #ordered
    end

    local function waitForQueue(connection, terminal)
        local maximumActive = math.max(1, tonumber(config.maximumActiveSessions) or 128)
        local reserved = math.max(0, math.min(tonumber(config.queueReservedSlots) or 0, maximumActive - 1))
        local admissionLimit = connection.staff and maximumActive or maximumActive - reserved
        if config.queueEnabled ~= true then
            if players:summary().activeSessions + admissionReservationCount >= admissionLimit then
                queueStats.rejected = queueStats.rejected + 1
                return nil, foundation.error('SERVER_FULL', 'The server has reached its active session limit.', { retryable = true })
            end
            reserveAdmission(connection)
            return true, nil
        end
        local queued = 0
        for _ in pairs(queueEntries) do queued = queued + 1 end
        if queued >= (config.maximumQueued or 128) then
            queueStats.rejected = queueStats.rejected + 1
            return nil, foundation.error('QUEUE_FULL', 'The connection queue is full.', { retryable = true })
        end
        queueSequence = queueSequence + 1
        queueEntries[connection.id] = {
            connectionId = connection.id, priority = connection.priority or 0, sequence = queueSequence,
            deadline = foundation.monotonicMs() + (config.queueTimeoutMs or 120000)
        }
        queueStats.peak = math.max(queueStats.peak, queued + 1)
        local lastPosition = nil
        while queueEntries[connection.id] do
            local position, total = queuePosition(connection.id)
            local active = players:summary().activeSessions + admissionReservationCount
            if position == 1 and active < admissionLimit then
                reserveAdmission(connection)
                queueEntries[connection.id] = nil
                queueStats.admitted = queueStats.admitted + 1
                metrics:increment('synex_connection_queue_total', { result = 'admitted' })
                return true, nil
            end
            if foundation.monotonicMs() >= queueEntries[connection.id].deadline then
                queueEntries[connection.id] = nil
                queueStats.timedOut = queueStats.timedOut + 1
                metrics:increment('synex_connection_queue_total', { result = 'timeout' })
                return nil, foundation.error('QUEUE_TIMEOUT', 'The connection queue wait timed out.', { retryable = true })
            end
            if position ~= lastPosition then
                terminal:update(('Synex: queue position %d of %d'):format(position or total, total))
                lastPosition = position
            end
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
            terminal:afterTick()
            if terminal.state ~= 'open' then
                return nil, foundation.error('QUEUE_CANCELLED',
                    'The connection queue wait was cancelled.', { retryable = true })
            end
        end
        return nil, foundation.error('QUEUE_CANCELLED', 'The connection queue entry was cancelled.', { retryable = true })
    end

    authority = factories.identityConnectionAuthority({
        platform = platform, foundation = foundation, players = players, lifecycle = lifecycle,
        leases = leases, instances = instances, instanceId = deps.instanceId, config = config,
        duplicatePolicy = duplicatePolicy, joinClaims = joinClaims,
        clearQueueEntry = clearQueueEntry, releaseAdmission = releaseAdmission,
        releaseConnectionLease = releaseConnectionLease,
        resetAdmissionState = function()
            queueEntries, admissionReservations = {}, {}
            admissionReservationCount = 0
        end,
        logConnectionStage = logConnectionStage
    })
    local terminals = factories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function(connection) return authority:acceptanceRejection(connection) end,
        logConnectionStage = logConnectionStage
    })
    local terminalQuiesceReport = { cancelled = 0, failures = 0 }

    function connectionPipeline:handleConnecting(tempSource, playerName, deferrals)
        tempSource = tonumber(tempSource) or tempSource
        local receivedAt = foundation.monotonicMs()
        local connection = {
            id = foundation.nextId('connection'), sessionId = foundation.nextId('session'),
            tempSource = tempSource, playerName = tostring(playerName or ''):sub(1, 96),
            state = 'CONNECTING', receivedAt = receivedAt, acceptedAt = nil,
            expiresAt = receivedAt + (config.pendingTtlMs or 120000), staff = false
        }
        local terminal = nil
        local function finish(...) return terminal and terminal:finish(...) end
        local function continuationIsCurrent()
            local reason, code = nil, nil
            if authority:isQuiesced() then
                reason, code = 'The Synex runtime is stopping. Please reconnect shortly.', 'CORE_STOPPING'
            elseif not lifecycle.core:canAdmitPlayers() then
                reason, code = 'The Synex runtime stopped accepting this connection. Please reconnect shortly.',
                    'CORE_NOT_READY'
            elseif not pendingIsCurrent(connection) then
                reason, code = 'The connection attempt was cancelled. Please reconnect.', 'CONNECTION_CANCELLED'
            else
                return true
            end
            local pending = players:getPending(tempSource)
            if pending and pending.id == connection.id then
                pending = players:removePending(tempSource)
            else
                pending = nil
            end
            abandonConnection(pending or connection)
            finish(reason, code)
            return false
        end
        local ok, runtimeError = foundation.safeCall(function()
            deferrals.defer()
            terminal = assert(terminals:open(connection, deferrals))
            platform.defer()
            terminal:arm()
            if terminal.state ~= 'open' then return end
            logConnectionStage(connection, 'received')
            if authority:isQuiesced() then
                finish('The Synex runtime is stopping. Please reconnect shortly.', 'CORE_STOPPING', true)
                return
            end
            if not lifecycle.core:canAdmitPlayers() then
                finish('The Synex runtime is not ready to admit players. Please reconnect shortly.', 'CORE_NOT_READY')
                return
            end
            local maintenanceBypass = aceAllowed(tempSource, config.maintenanceBypassAce or 'synex.maintenance.bypass')
            if config.maintenanceMode == true and not maintenanceBypass then
                finish(tostring(config.maintenanceMessage or 'Synex is currently in maintenance mode.'), 'MAINTENANCE')
                return
            end
            local rawIdentifiers = platform.getPlayerIdentifiers(tempSource)
            local identifiers = normalizeIdentifiers(rawIdentifiers)
            connection.identityFingerprint = identifierFingerprint(identifiers)
            connection.staff = maintenanceBypass or aceAllowed(tempSource, config.queueStaffAce or 'synex.queue.staff')
            local created = players:createPending(tempSource, connection)
            if not created then
                finish('A previous connection attempt is still being cleaned up. Please wait a moment and reconnect.',
                    'PENDING_CONNECTION_EXISTS')
                return
            end
            terminal:update('Synex: authenticating connection...')
            platform.defer()
            terminal:afterTick()
            if terminal.state ~= 'open' then return end
            if not continuationIsCurrent() then return end
            local user, authError = userRepository:authenticate(rawIdentifiers)
            if not continuationIsCurrent() then return end
            if not user then
                players:removePending(tempSource)
                local authenticationCode = authError and authError.code == 'IDENTIFIER_REQUIRED'
                    and 'IDENTIFIER_REQUIRED' or 'AUTHENTICATION_FAILED'
                local authenticationMessage = authenticationCode == 'IDENTIFIER_REQUIRED'
                    and 'No supported platform identifier was provided.' or 'Connection authentication failed. Please retry.'
                finish(authenticationMessage, authenticationCode)
                return
            end
            logConnectionStage(connection, 'identity_ok')
            local allowed, accessError = accessRepository:check(user.id, identifiers)
            if not continuationIsCurrent() then return end
            if not allowed then
                players:removePending(tempSource)
                local accessCode = accessError and accessError.code
                if accessCode == 'ACCESS_BANNED' then
                    finish(accessError.message or 'Access to this server is denied.', 'ACCESS_BANNED')
                elseif accessCode == 'ALLOWLIST_REQUIRED' then
                    finish('This server requires an active allowlist entry.', 'ALLOWLIST_REQUIRED')
                else
                    finish('The server could not verify access. Please retry shortly.', 'ACCESS_CHECK_FAILED')
                end
                return
            end
            logConnectionStage(connection, 'access_ok')
            local policy = duplicatePolicy()
            if policy == 'deny_new' and #players:sessionsByUser(user.id) > 0 then
                players:removePending(tempSource)
                finish('This account already has an active session.', 'DUPLICATE_SESSION')
                return
            end
            connection.userId = user.id
            connection.priority = connectionPriority(connection, user.id)
            local synced, syncError = syncPending(connection)
            if not synced then
                players:removePending(tempSource)
                logger:warn('pending connection state synchronization failed', {
                    correlationId = connection.id, code = syncError.code
                })
                finish('Synex could not maintain the pending connection state.', 'PENDING_STATE_FAILED')
                return
            end
            local admitted, queueError = waitForQueue(connection, terminal)
            if not continuationIsCurrent() then return end
            if not admitted then
                releaseAdmission(connection)
                players:removePending(tempSource)
                finish(queueError.message, queueError.code or 'QUEUE_REJECTED')
                return
            end
            if policy == 'deny_new' then
                local leased, leaseError = authority:acquireDuplicate(connection, user.id, terminal)
                if not continuationIsCurrent() then return end
                if not leased then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    logger:warn('duplicate session lease denied', {
                        correlationId = connection.id, code = leaseError and leaseError.code or 'UNKNOWN'
                    })
                    finish('This account already has an active session on the Synex cluster.', 'DUPLICATE_SESSION')
                    return
                end
                logConnectionStage(connection, 'lease_acquired')
                local leaseSynced, leaseSyncError = syncPending(connection)
                if not leaseSynced then
                    abandonConnection(connection)
                    players:removePending(tempSource)
                    logger:warn('pending cluster authority synchronization failed', {
                        correlationId = connection.id, code = leaseSyncError.code
                    })
                    finish('Synex could not maintain cluster session authority.', 'LEASE_STATE_FAILED')
                    return
                end
            end
            connection.state = 'AUTHENTICATING'
            local authenticating, authenticatingError = syncPending(connection)
            if not authenticating then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending authentication state synchronization failed', {
                    correlationId = connection.id, code = authenticatingError.code
                })
                finish('Synex could not maintain the pending authentication state.', 'PENDING_STATE_FAILED')
                return
            end
            for _, gate in ipairs(orderedGates()) do
                terminal:update(('Synex: %s...'):format(gate.name))
                platform.defer()
                terminal:afterTick()
                if terminal.state ~= 'open' then return end
                if not continuationIsCurrent() then return end
                local started = foundation.monotonicMs()
                local invoked, result, gateError = invokeOwned(gate, gate.run, foundation.readonly({
                    connectionId = connection.id, sessionId = connection.sessionId, tempSource = tempSource,
                    user = foundation.copy(user), identifiers = foundation.copy(identifiers)
                }))
                local elapsed = foundation.monotonicMs() - started
                if not continuationIsCurrent() then return end
                if not invoked or elapsed > gate.timeoutMs or result ~= true then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    releaseUncapturedConnectionLease(connection)
                    logger:warn('connection gate denied or failed', {
                        correlationId = connection.id, gate = gate.name, elapsedMs = elapsed,
                        code = type(gateError) == 'table' and gateError.code or 'CONNECTION_GATE_DENIED'
                    })
                    finish('Connection validation failed.', 'CONNECTION_GATE_DENIED')
                    return
                end
            end
            if policy == 'kick_old' then
                local replaced, replaceError = replacements:replace(user.id)
                if not continuationIsCurrent() then return end
                if not replaced then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    logger:error('local duplicate session replacement failed', {
                        correlationId = connection.id, code = replaceError and replaceError.code or 'UNKNOWN'
                    })
                    finish('The existing session could not be replaced safely. Please retry.', 'SESSION_REPLACE_FAILED')
                    return
                end
                local leased, leaseError = authority:acquireDuplicate(connection, user.id, terminal)
                if not continuationIsCurrent() then return end
                if not leased then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    logger:warn('cluster duplicate session replacement unavailable', {
                        correlationId = connection.id, code = leaseError and leaseError.code or 'UNKNOWN'
                    })
                    finish('The existing cluster session could not be replaced in time.', 'SESSION_REPLACE_TIMEOUT')
                    return
                end
                logConnectionStage(connection, 'lease_acquired')
                local leaseSynced, leaseSyncError = syncPending(connection)
                if not leaseSynced then
                    abandonConnection(connection)
                    players:removePending(tempSource)
                    logger:warn('pending replacement authority synchronization failed', {
                        correlationId = connection.id, code = leaseSyncError.code
                    })
                    finish('Synex could not maintain replacement authority.', 'LEASE_STATE_FAILED')
                    return
                end
            elseif policy == 'allow' then
                local leased, leaseError = authority:acquireDuplicate(connection, user.id, terminal)
                if not continuationIsCurrent() then return end
                if not leased then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    logger:error('parallel session authority failed', {
                        correlationId = connection.id, code = leaseError and leaseError.code or 'UNKNOWN'
                    })
                    finish('Synex could not establish cluster session authority.', 'LEASE_ACQUIRE_FAILED')
                    return
                end
                logConnectionStage(connection, 'lease_acquired')
                local leaseSynced, leaseSyncError = syncPending(connection)
                if not leaseSynced then
                    abandonConnection(connection)
                    players:removePending(tempSource)
                    logger:warn('pending parallel authority synchronization failed', {
                        correlationId = connection.id, code = leaseSyncError.code
                    })
                    finish('Synex could not maintain parallel session authority.', 'LEASE_STATE_FAILED')
                    return
                end
            end
            connection.state = 'AUTHENTICATED'
            connection.acceptedAt = foundation.monotonicMs()
            connection.expiresAt = connection.acceptedAt + (config.pendingTtlMs or 120000)
            local accepted, acceptanceError = syncPending(connection)
            if not accepted then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('accepted connection state synchronization failed', {
                    correlationId = connection.id, code = acceptanceError.code
                })
                finish('Synex could not finalize the pending connection.', 'PENDING_STATE_FAILED')
                return
            end
            finish()
        end)
        if not ok then
            if not (terminal and terminal.attempted and terminal.acceptance) then
                local pending = players:getPending(tempSource)
                if pending and pending.id == connection.id then pending = players:removePending(tempSource) else pending = nil end
                abandonConnection(pending or connection)
            end
            foundation.safeCall(logger.error, logger, 'connection pipeline failed', {
                correlationId = connection.id, code = 'CONNECTION_PIPELINE_FAILED'
            })
            if terminal and not terminal.attempted then
                foundation.safeCall(finish,
                    'An internal connection error occurred. Please retry. If it persists, contact the server team.',
                    'CONNECTION_PIPELINE_FAILED')
            end
            return nil, foundation.error('CONNECTION_PIPELINE_FAILED', 'The connection pipeline raised an exception.', {
                details = { runtimeType = type(runtimeError) }
            })
        end
        if terminal and terminal.state == 'failed' then
            return nil, foundation.error('DEFERRAL_TERMINATION_FAILED',
                'The Cfx connection deferral could not be finalized.')
        end
        return true, nil
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
        clearQueueEntry = clearQueueEntry
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

    local maintenance = factories.identityConnectionMaintenance({
        platform = platform,
        foundation = foundation,
        players = players,
        lifecycle = lifecycle,
        messaging = messaging,
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
        clearQueueEntry = clearQueueEntry,
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
    function connectionPipeline:handleDropped(playerSource, reason) return maintenance:handleDropped(playerSource, reason) end
    function connectionPipeline:purgeExpired(maximum) return maintenance:purgeExpired(maximum) end
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
        local queued, oldestWaitMs = 0, 0
        local now = foundation.monotonicMs()
        for _, entry in pairs(queueEntries) do
            queued = queued + 1
            oldestWaitMs = math.max(oldestWaitMs, math.max(0, (config.queueTimeoutMs or 120000) - (entry.deadline - now)))
        end
        return {
            quiesced = authority:isQuiesced(),
            openDeferrals = terminals:count(),
            enabled = config.queueEnabled == true,
            maintenance = config.maintenanceMode == true,
            queued = queued,
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
            duplicatePolicy = duplicatePolicy()
        }
    end

    return connectionPipeline
end
