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
    local invokeOwned = assert(deps.invokeOwned, 'identity connections requires owned invocation')
    local normalizeIdentifiers = assert(deps.normalizeIdentifiers, 'identity connections requires identifier normalization')
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
    local connectionPipeline = {}

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
            local _, err = leases:release(connection.clusterLease)
            if err then logger:warn('cluster session lease release failed', { sessionId = connection.sessionId, code = err.code }) end
            connection.clusterLease = nil
            return err == nil, err
        end
        return true, nil
    end

    local function abandonConnection(connection)
        queueEntries[connection.id] = nil
        releaseAdmission(connection)
        releaseConnectionLease(connection)
    end

    local function acquireConnectionLease(connection, userId)
        local policy = duplicatePolicy()
        local leaseName = policy == 'allow'
            and ('session:' .. userId .. ':' .. connection.sessionId)
            or ('session:' .. userId)
        local leaseOwner = deps.instanceId .. ':' .. connection.sessionId
        local lease, leaseError = leases:acquire(leaseName, leaseOwner, config.clusterSessionLeaseSeconds or 45)
        if not lease then return nil, leaseError end
        connection.clusterLease = lease
        return true, nil
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

    local function replaceLocalSessions(userId)
        for _, session in ipairs(players:sessionsByUser(userId)) do
            if session.state == 'ACTIVE' then
                local unloaded, unloadError = characters:unload(session.id, 'duplicate session replaced')
                if not unloaded then return nil, unloadError end
            end
            local current = players:getSession(session.id) or session
            local closed, closeError = sessionRepository:close(current, 'duplicate session replaced')
            if not closed then return nil, closeError end
            messaging.network:purgeSource(current.source, current.sourceGeneration)
            releaseConnectionLease(current)
            players:removeSession(current.id)
            if current.source ~= nil then
                platform.dropPlayer(current.source, 'This session was replaced by a newer connection.')
            end
        end
        return true, nil
    end

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

    local function waitForQueue(connection, deferrals)
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
                deferrals.update(('Synex: queue position %d of %d'):format(position or total, total))
                lastPosition = position
            end
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
        end
        return nil, foundation.error('QUEUE_CANCELLED', 'The connection queue entry was cancelled.', { retryable = true })
    end

    local function acquireDuplicateAuthority(connection, userId, deferrals)
        local policy = duplicatePolicy()
        if policy == 'allow' or policy == 'deny_new' then return acquireConnectionLease(connection, userId) end
        local requested, requestError = instances:requestRemoteKicks(userId, config.clusterSessionLeaseSeconds or 45)
        if not requested then return nil, requestError end
        local deadline = foundation.monotonicMs() + math.min(config.queueTimeoutMs or 120000,
            (config.clusterSessionLeaseSeconds or 45) * 1000 + 5000)
        repeat
            local acquired, leaseError = acquireConnectionLease(connection, userId)
            if acquired then return true, nil end
            if not leaseError or (leaseError.code ~= 'LEASE_BUSY' and leaseError.code ~= 'MIGRATION_LEASE_BUSY') then
                return nil, leaseError
            end
            if foundation.monotonicMs() >= deadline then return nil, leaseError end
            deferrals.update(requested > 0 and 'Synex: replacing the existing cluster session...' or 'Synex: waiting for session authority...')
            platform.wait(math.max(250, math.min(config.queueUpdateMs or 1000, 5000)))
        until foundation.monotonicMs() >= deadline
        return nil, foundation.error('DUPLICATE_SESSION_TIMEOUT', 'The existing cluster session did not release authority in time.', { retryable = true })
    end

    function connectionPipeline:handleConnecting(tempSource, playerName, deferrals)
        tempSource = tonumber(tempSource) or tempSource
        local done = false
        local function finish(reason)
            if done then return false end
            done = true
            platform.defer()
            deferrals.done(reason)
            return true
        end
        deferrals.defer()
        platform.defer()
        if not lifecycle.core:canAdmitPlayers() then
            finish('Synex is starting. Please reconnect shortly.')
            return
        end
        local maintenanceBypass = aceAllowed(tempSource, config.maintenanceBypassAce or 'synex.maintenance.bypass')
        if config.maintenanceMode == true and not maintenanceBypass then
            metrics:increment('synex_connections_total', { result = 'maintenance' })
            finish(tostring(config.maintenanceMessage or 'Synex is currently in maintenance mode.'):sub(1, 256))
            return
        end
        local rawIdentifiers = platform.getPlayerIdentifiers(tempSource)
        local identifiers = normalizeIdentifiers(rawIdentifiers)
        local connection = {
            id = foundation.nextId('connection'), sessionId = foundation.nextId('session'),
            tempSource = tempSource, playerName = tostring(playerName or ''):sub(1, 96),
            state = 'CONNECTING', acceptedAt = nil, expiresAt = foundation.monotonicMs() + (config.pendingTtlMs or 120000),
            staff = maintenanceBypass or aceAllowed(tempSource, config.queueStaffAce or 'synex.queue.staff')
        }
        local created, pendingError = players:createPending(tempSource, connection)
        if not created then finish(pendingError.message) return end
        deferrals.update('Synex: authenticating connection...')
        platform.defer()
        local user, authError = userRepository:authenticate(rawIdentifiers)
        if not pendingIsCurrent(connection) then abandonConnection(connection) return end
        if not user then
            players:removePending(tempSource)
            finish(authError and authError.message or 'Connection authentication failed.')
            return
        end
        local allowed, accessError = accessRepository:check(user.id, identifiers)
        if not pendingIsCurrent(connection) then abandonConnection(connection) return end
        if not allowed then
            players:removePending(tempSource)
            finish(accessError and accessError.message or 'Connection access was denied.')
            return
        end
        local policy = duplicatePolicy()
        if policy == 'deny_new' and #players:sessionsByUser(user.id) > 0 then
            players:removePending(tempSource)
            finish('This account already has an active session.')
            return
        end
        connection.userId = user.id
        connection.priority = connectionPriority(connection, user.id)
        local synced, syncError = syncPending(connection)
        if not synced then
            players:removePending(tempSource)
            logger:warn('pending connection state synchronization failed', { code = syncError.code })
            finish('Synex could not maintain the pending connection state.')
            return
        end
        local admitted, queueError = waitForQueue(connection, deferrals)
        if not pendingIsCurrent(connection) then abandonConnection(connection) return end
        if not admitted then
            releaseAdmission(connection)
            players:removePending(tempSource)
            finish(queueError.message)
            return
        end
        if policy == 'deny_new' then
            local leased, leaseError = acquireDuplicateAuthority(connection, user.id, deferrals)
            if not pendingIsCurrent(connection) then abandonConnection(connection) return end
            if not leased then
                releaseAdmission(connection)
                players:removePending(tempSource)
                logger:warn('duplicate session lease denied', {
                    userId = user.id, code = leaseError and leaseError.code or 'UNKNOWN'
                })
                finish('This account already has an active session on the Synex cluster.')
                return
            end
            local leaseSynced, leaseSyncError = syncPending(connection)
            if not leaseSynced then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending cluster authority synchronization failed', { code = leaseSyncError.code })
                finish('Synex could not maintain cluster session authority.')
                return
            end
        end
        connection.state = 'AUTHENTICATING'
        local authenticating, authenticatingError = syncPending(connection)
        if not authenticating then
            abandonConnection(connection)
            players:removePending(tempSource)
            logger:warn('pending authentication state synchronization failed', { code = authenticatingError.code })
            finish('Synex could not maintain the pending authentication state.')
            return
        end
        for _, gate in ipairs(orderedGates()) do
            deferrals.update(('Synex: %s...'):format(gate.name))
            platform.defer()
            local started = foundation.monotonicMs()
            local ok, result, gateError = invokeOwned(gate, gate.run, foundation.readonly({
                connectionId = connection.id, sessionId = connection.sessionId, tempSource = tempSource,
                user = foundation.copy(user), identifiers = foundation.copy(identifiers)
            }))
            local elapsed = foundation.monotonicMs() - started
            if not pendingIsCurrent(connection) then abandonConnection(connection) return end
            if not ok or elapsed > gate.timeoutMs or result ~= true then
                releaseAdmission(connection)
                players:removePending(tempSource)
                releaseConnectionLease(connection)
                logger:warn('connection gate denied or failed', { gate = gate.name, userId = user.id, elapsedMs = elapsed, error = tostring(ok and gateError or result) })
                finish(type(gateError) == 'table' and gateError.message or 'Connection validation failed.')
                return
            end
        end
        if policy == 'kick_old' then
            local replaced, replaceError = replaceLocalSessions(user.id)
            if not pendingIsCurrent(connection) then abandonConnection(connection) return end
            if not replaced then
                releaseAdmission(connection)
                players:removePending(tempSource)
                logger:error('local duplicate session replacement failed', {
                    userId = user.id, code = replaceError and replaceError.code or 'UNKNOWN'
                })
                finish('The existing session could not be replaced safely. Please retry.')
                return
            end
            local leased, leaseError = acquireDuplicateAuthority(connection, user.id, deferrals)
            if not pendingIsCurrent(connection) then abandonConnection(connection) return end
            if not leased then
                releaseAdmission(connection)
                players:removePending(tempSource)
                logger:warn('cluster duplicate session replacement unavailable', {
                    userId = user.id, code = leaseError and leaseError.code or 'UNKNOWN'
                })
                finish('The existing cluster session could not be replaced in time.')
                return
            end
            local leaseSynced, leaseSyncError = syncPending(connection)
            if not leaseSynced then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending replacement authority synchronization failed', { code = leaseSyncError.code })
                finish('Synex could not maintain replacement authority.')
                return
            end
        elseif policy == 'allow' then
            local leased, leaseError = acquireDuplicateAuthority(connection, user.id, deferrals)
            if not pendingIsCurrent(connection) then abandonConnection(connection) return end
            if not leased then
                releaseAdmission(connection)
                players:removePending(tempSource)
                logger:error('parallel session authority failed', {
                    userId = user.id, code = leaseError and leaseError.code or 'UNKNOWN'
                })
                finish('Synex could not establish cluster session authority.')
                return
            end
            local leaseSynced, leaseSyncError = syncPending(connection)
            if not leaseSynced then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending parallel authority synchronization failed', { code = leaseSyncError.code })
                finish('Synex could not maintain parallel session authority.')
                return
            end
        end
        connection.state = 'AUTHENTICATED'
        connection.acceptedAt = foundation.monotonicMs()
        local accepted, acceptanceError = syncPending(connection)
        if not accepted then
            abandonConnection(connection)
            players:removePending(tempSource)
            logger:warn('accepted connection state synchronization failed', { code = acceptanceError.code })
            finish('Synex could not finalize the pending connection.')
            return
        end
        metrics:increment('synex_connections_total', { result = 'accepted' })
        finish()
    end

    function connectionPipeline:handleJoining(finalSource, oldSource)
        finalSource = tonumber(finalSource) or finalSource
        oldSource = tonumber(oldSource) or oldSource
        local pending = players:getPending(oldSource)
        if not pending or pending.state ~= 'AUTHENTICATED' or pending.expiresAt < foundation.monotonicMs() then
            if pending then
                players:removePending(oldSource)
                releaseAdmission(pending)
                releaseConnectionLease(pending)
            end
            platform.dropPlayer(finalSource, 'Synex could not bind this connection. Please reconnect.')
            return nil, foundation.error('PENDING_CONNECTION_NOT_FOUND', 'The accepted connection is missing or expired.')
        end
        local session = {
            id = pending.sessionId, userId = pending.userId, state = 'AUTHENTICATED',
            source = finalSource, sourceGeneration = 0, characterId = nil, version = 1,
            connectedAt = foundation.utcIso()
        }
        session.clusterLease = pending.clusterLease
        local transitioned, transitionError = transition(session, 'SELECTING_CHARACTER')
        if not transitioned then
            players:removePending(oldSource)
            releaseAdmission(pending)
            releaseConnectionLease(pending)
            platform.dropPlayer(finalSource, 'Synex could not initialize the session.')
            return nil, transitionError
        end
        session.persistedVersion = session.version
        local bound, bindError = players:bindJoined(oldSource, finalSource, session)
        if not bound then
            releaseAdmission(pending)
            releaseConnectionLease(pending)
            platform.dropPlayer(finalSource, 'Synex could not establish a session.')
            return nil, bindError
        end
        releaseAdmission(pending)
        local persisted, persistenceError = sessionRepository:create(bound)
        if not persisted then
            players:removeSession(bound.id)
            releaseConnectionLease(bound)
            platform.dropPlayer(finalSource, 'Synex could not persist the session. Please reconnect.')
            return nil, persistenceError
        end
        if not players:isCurrent(bound.id, finalSource, bound.sourceGeneration) then
            local _, closeError = sessionRepository:close(bound, 'disconnected during session creation')
            if closeError then
                logger:error('cancelled session persistence cleanup failed', {
                    sessionId = bound.id, code = closeError.code
                })
            end
            releaseConnectionLease(bound)
            return nil, foundation.error('CONNECTION_CANCELLED', 'The player disconnected while the session was opening.')
        end
        logger:info('session opened', { sessionId = bound.id, userId = bound.userId, source = finalSource, generation = bound.sourceGeneration })
        return bound, nil
    end

    function connectionPipeline:handleDropped(playerSource, reason)
        playerSource = tonumber(playerSource) or playerSource
        local session = players:getBySource(playerSource)
        if not session then
            local pending = players:removePending(playerSource)
            if pending then queueEntries[pending.id] = nil end
            releaseAdmission(pending)
            releaseConnectionLease(pending)
            return
        end
        local failures = {}
        local function capture(step, handler)
            local ok, value, err = foundation.safeCall(handler)
            if not ok or value == nil then
                local failure = ok and err or value
                failures[#failures + 1] = { step = step, code = type(failure) == 'table' and failure.code or 'RUNTIME_ERROR' }
                logger:error('disconnect cleanup step failed', {
                    step = step, sessionId = session.id, userId = session.userId,
                    error = tostring(type(failure) == 'table' and (failure.code or failure.message) or failure)
                })
                return nil
            end
            return value
        end
        if session.state == 'ACTIVE' then
            capture('character_unload', function() return characters:unload(session.id, 'disconnect') end)
        end
        local current = players:getSession(session.id) or session
        if current.state ~= 'DISCONNECTING' and current.state ~= 'CLOSED' then
            capture('session_transition', function() return players:updateSession(current.id, function(candidate)
                if sessionTransitions[candidate.state] and sessionTransitions[candidate.state].DISCONNECTING then transition(candidate, 'DISCONNECTING') end
            end) end)
        end
        current = players:getSession(session.id) or current
        local closed = false
        for attempt = 1, 2 do
            local value = capture('session_close_' .. attempt, function() return sessionRepository:close(current, reason) end)
            if value then closed = true break end
            if attempt == 1 then platform.wait(25) end
        end
        capture('lease_release', function() return releaseConnectionLease(current) end)
        local purged, purgeError = foundation.safeCall(messaging.network.purgeSource,
            messaging.network, playerSource, session.sourceGeneration)
        if not purged then failures[#failures + 1] = { step = 'network_purge', code = 'RUNTIME_ERROR' }; logger:error('disconnect network cleanup failed', { sessionId = session.id, error = tostring(purgeError) }) end
        players:removeSession(session.id)
        recordReconnectGrace(session.userId)
        if #failures > 0 then
            metrics:increment('synex_disconnect_cleanup_total', { result = 'partial' })
            lifecycle.core:setHealth('disconnect-cleanup', 'DEGRADED', ('%d cleanup step(s) failed'):format(#failures))
        else
            metrics:increment('synex_disconnect_cleanup_total', { result = 'complete' })
            lifecycle.core:setHealth('disconnect-cleanup', 'HEALTHY')
        end
        logger:info('session closed', { sessionId = session.id, userId = session.userId, reason = tostring(reason or 'dropped'):sub(1, 128) })
        return { closed = closed, failures = failures }
    end

    function connectionPipeline:purgeExpired()
        local now = foundation.monotonicMs()
        local purged = 0
        for _, entry in ipairs(players:listPending()) do
            if entry.connection.expiresAt and entry.connection.expiresAt <= now then
                local removed = players:removePending(entry.source)
                if removed then queueEntries[removed.id] = nil end
                releaseAdmission(removed)
                releaseConnectionLease(removed)
                purged = purged + 1
            end
        end
        for userId, entry in pairs(reconnectGrace) do
            if entry.expiresAt <= now then reconnectGrace[userId] = nil; reconnectGraceSize = math.max(0, reconnectGraceSize - 1) end
        end
        return purged
    end

    function connectionPipeline:heartbeat()
        self:purgeExpired()
        local sessions = players:snapshot().sessions
        local sessionIds = {}
        for _, session in ipairs(sessions) do
            sessionIds[#sessionIds + 1] = session.id
            if session.clusterLease then
                local renewed, err = leases:renew(session.clusterLease)
                if not renewed then
                    logger:error('cluster session lease lost', { sessionId = session.id, userId = session.userId, code = err.code })
                    if session.source ~= nil then platform.dropPlayer(session.source, 'Synex session authority was lost. Please reconnect.') end
                end
            end
        end
        local touched, touchError = instances:touchSessions(sessionIds)
        if not touched then logger:error('session heartbeat persistence failed', { code = touchError.code }) end
        local cluster, heartbeatError = instances:heartbeat(config.clusterSessionLeaseSeconds or 45)
        if not cluster then logger:error('instance heartbeat failed', { code = heartbeatError.code }) end
        local controls, controlError = instances:pendingLocalControls()
        if not controls then
            logger:error('cluster control polling failed', { code = controlError.code })
        else
            for _, control in ipairs(controls) do
                local target = players:getSession(control.target_session_id)
                if target and target.source ~= nil and control.action == 'kick' then
                    platform.dropPlayer(target.source, tostring(control.reason or 'Session replaced.'):sub(1, 128))
                end
                local completed, completionError = instances:completeControl(control.request_id)
                if not completed and completionError then logger:error('cluster control completion failed', { code = completionError.code }) end
            end
        end
        local healthy = touched and cluster and controls ~= nil
        lifecycle.core:setHealth('cluster', healthy and 'HEALTHY' or 'DEGRADED', healthy and nil or 'cluster heartbeat or control polling failed')
        return healthy, healthy and nil or (touchError or heartbeatError or controlError)
    end

    function connectionPipeline:snapshot()
        local queued, oldestWaitMs = 0, 0
        local now = foundation.monotonicMs()
        for _, entry in pairs(queueEntries) do
            queued = queued + 1
            oldestWaitMs = math.max(oldestWaitMs, math.max(0, (config.queueTimeoutMs or 120000) - (entry.deadline - now)))
        end
        return {
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
