local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionConnecting = function(deps)
    local platform = assert(deps.platform, 'connection pipeline requires platform')
    local foundation = assert(deps.foundation, 'connection pipeline requires foundation')
    local players = assert(deps.players, 'connection pipeline requires player registry')
    local lifecycle = assert(deps.lifecycle, 'connection pipeline requires lifecycle')
    local config = deps.config or {}
    local ingress = assert(deps.ingress, 'connection pipeline requires ingress')
    local terminals = assert(deps.terminals, 'connection pipeline requires terminals')
    local authority = assert(deps.authority, 'connection pipeline requires authority')
    local normalizeIdentifiers = assert(deps.normalizeIdentifiers,
        'connection pipeline requires identifier normalization')
    local identifierFingerprint = assert(deps.identifierFingerprint,
        'connection pipeline requires identifier fingerprinting')
    local userRepository = assert(deps.userRepository,
        'connection pipeline requires user repository')
    local accessRepository = assert(deps.accessRepository,
        'connection pipeline requires access repository')
    local connectionPriority = assert(deps.connectionPriority,
        'connection pipeline requires priority calculation')
    local syncPending = assert(deps.syncPending,
        'connection pipeline requires pending synchronization')
    local waitForQueue = assert(deps.waitForQueue, 'connection pipeline requires queue admission')
    local releaseAdmission = assert(deps.releaseAdmission,
        'connection pipeline requires admission release')
    local abandonConnection = assert(deps.abandonConnection,
        'connection pipeline requires abandonment cleanup')
    local orderedGates = assert(deps.orderedGates, 'connection pipeline requires ordered gates')
    local invokeOwned = assert(deps.invokeOwned, 'connection pipeline requires owned invocation')
    local releaseUncapturedConnectionLease = assert(deps.releaseConnectionLease,
        'connection pipeline requires lease release')
    local replacements = assert(deps.replacements, 'connection pipeline requires replacement policy')
    local duplicatePolicy = assert(deps.duplicatePolicy,
        'connection pipeline requires duplicate policy')
    local logConnectionStage = assert(deps.logConnectionStage,
        'connection pipeline requires stage telemetry')
    local pendingIsCurrent = assert(deps.pendingIsCurrent,
        'connection pipeline requires pending authority')
    local aceAllowed = assert(deps.aceAllowed, 'connection pipeline requires ACE evaluation')
    local logger = foundation.logger

    return function(tempSource, playerName, deferrals)
        tempSource = tonumber(tempSource) or tempSource
        local receivedAt = foundation.monotonicMs()
        local connection = {
            id = foundation.nextId('connection'), sessionId = foundation.nextId('session'),
            tempSource = tempSource, playerName = tostring(playerName or ''):sub(1, 96),
            state = 'CONNECTING', receivedAt = receivedAt, acceptedAt = nil,
            expiresAt = receivedAt + (config.pendingTtlMs or 120000), staff = false
        }
        local terminal = nil
        local pipelineError = nil
        local failureStage = 'connection_created'
        local function checkpoint(stage) failureStage = stage end
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
            checkpoint('ingress_begin')
            local rawIdentifiers = ingress:begin(connection, deferrals, checkpoint)
            if not rawIdentifiers then return end
            checkpoint('terminal_open')
            local openedTerminal, terminalError = terminals:open(connection, deferrals)
            if not openedTerminal then
                pipelineError = terminalError or foundation.error('INVALID_CONNECTION_TERMINAL',
                    'The Cfx connection deferral terminal could not be opened.')
                abandonConnection(connection)
                checkpoint('terminal_open_rejection_tick')
                platform.defer()
                checkpoint('terminal_open_rejection')
                local rejectionCode = foundation.failureCode(
                    pipelineError, 'INVALID_CONNECTION_TERMINAL'):sub(1, 48)
                local rejected = foundation.safeCall(function()
                    deferrals.done(('Synex [%s]: The connection terminal could not be initialized. '
                        .. 'Please reconnect.'):format(rejectionCode):sub(1, 256))
                end)
                if not rejected then
                    pipelineError = foundation.error('DEFERRAL_TERMINATION_FAILED',
                        'The invalid Cfx connection deferral could not be finalized.')
                end
                return
            end
            terminal = openedTerminal
            checkpoint('initial_tick')
            platform.defer()
            checkpoint('initial_authority')
            if not ingress:isCurrent(connection) then
                terminal:finish('The connection attempt was cancelled. Please reconnect.',
                    'CONNECTION_CANCELLED')
                terminal:arm()
                return
            end
            checkpoint('terminal_arm')
            terminal:arm()
            if terminal.state ~= 'open' then return end
            logConnectionStage(connection, 'received')
            checkpoint('pre_auth_policy')
            if authority:isQuiesced() then
                finish('The Synex runtime is stopping. Please reconnect shortly.', 'CORE_STOPPING', true)
                return
            end
            if not lifecycle.core:canAdmitPlayers() then
                finish('The Synex runtime is not ready to admit players. Please reconnect shortly.', 'CORE_NOT_READY')
                return
            end
            checkpoint('maintenance_ace')
            local maintenanceBypass = aceAllowed(tempSource, config.maintenanceBypassAce or 'synex.maintenance.bypass')
            if config.maintenanceMode == true and not maintenanceBypass then
                finish(tostring(config.maintenanceMessage or 'Synex is currently in maintenance mode.'), 'MAINTENANCE')
                return
            end
            checkpoint('identifier_normalization')
            local identifiers = normalizeIdentifiers(rawIdentifiers)
            checkpoint('identifier_fingerprint')
            connection.identityFingerprint = identifierFingerprint(identifiers)
            checkpoint('queue_staff_ace')
            connection.staff = maintenanceBypass or aceAllowed(tempSource, config.queueStaffAce or 'synex.queue.staff')
            checkpoint('pending_registration')
            local created = players:createPending(tempSource, connection)
            if not created then
                finish('A previous connection attempt is still being cleaned up. Please wait a moment and reconnect.',
                    'PENDING_CONNECTION_EXISTS')
                return
            end
            checkpoint('deferral_authentication_update')
            terminal:update('Synex: authenticating connection...')
            checkpoint('authentication_tick')
            platform.defer()
            terminal:afterTick()
            if terminal.state ~= 'open' then return end
            checkpoint('pending_authority')
            if not continuationIsCurrent() then return end
            checkpoint('identity_authentication')
            local user, authError = userRepository:authenticate(rawIdentifiers)
            checkpoint('pending_authority')
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
            checkpoint('access_check')
            local allowed, accessError = accessRepository:check(user.id, identifiers)
            checkpoint('pending_authority')
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
            connection.userId = user.id
            checkpoint('connection_priority')
            connection.priority = connectionPriority(connection, user.id)
            checkpoint('pending_sync_connecting')
            local synced, syncError = syncPending(connection)
            if not synced then
                players:removePending(tempSource)
                logger:warn('pending connection state synchronization failed', {
                    correlationId = connection.id, code = syncError.code
                })
                finish('Synex could not maintain the pending connection state.', 'PENDING_STATE_FAILED')
                return
            end
            checkpoint('queue_admission')
            local admitted, queueError = waitForQueue(connection, terminal)
            checkpoint('pending_authority')
            if not continuationIsCurrent() then return end
            if not admitted then
                releaseAdmission(connection)
                players:removePending(tempSource)
                finish(queueError.message, queueError.code or 'QUEUE_REJECTED')
                return
            end
            connection.state = 'AUTHENTICATING'
            checkpoint('pending_sync_authenticating')
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
            checkpoint('connection_gates')
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
            checkpoint('admission_gate')
            local gated, gateError = authority:acquireAdmissionGate(connection, user.id, terminal)
            checkpoint('pending_authority')
            if not continuationIsCurrent() then return end
            if not gated then
                releaseAdmission(connection)
                players:removePending(tempSource)
                releaseUncapturedConnectionLease(connection)
                logger:warn('cluster admission gate unavailable', {
                    correlationId = connection.id,
                    code = gateError and gateError.code or 'UNKNOWN'
                })
                finish('Synex could not serialize this account admission. Please retry.',
                    'ADMISSION_GATE_UNAVAILABLE')
                return
            end
            checkpoint('pending_sync_admission')
            local gateSynced, gateSyncError = syncPending(connection)
            if not gateSynced then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending admission gate synchronization failed', {
                    correlationId = connection.id, code = gateSyncError.code
                })
                finish('Synex could not maintain account admission authority.', 'LEASE_STATE_FAILED')
                return
            end
            checkpoint('duplicate_policy')
            local policy = duplicatePolicy()
            if policy == 'kick_old' then
                checkpoint('duplicate_replacement')
                local replaced, replaceError = replacements:replace(user.id)
                checkpoint('pending_authority')
                if not continuationIsCurrent() then return end
                if not replaced then
                    releaseAdmission(connection)
                    players:removePending(tempSource)
                    releaseUncapturedConnectionLease(connection)
                    logger:error('local duplicate session replacement failed', {
                        correlationId = connection.id, code = replaceError and replaceError.code or 'UNKNOWN'
                    })
                    finish('The existing session could not be replaced safely. Please retry.', 'SESSION_REPLACE_FAILED')
                    return
                end
            end
            checkpoint('duplicate_lease')
            local leased, leaseError = authority:acquireDuplicate(connection, user.id, terminal, policy)
            checkpoint('pending_authority')
            if not continuationIsCurrent() then return end
            if not leased then
                releaseAdmission(connection)
                players:removePending(tempSource)
                releaseUncapturedConnectionLease(connection)
                local duplicate = leaseError and (leaseError.code == 'DUPLICATE_SESSION'
                    or leaseError.code == 'LEASE_BUSY')
                logger:warn('cluster duplicate policy admission failed', {
                    correlationId = connection.id, policy = policy,
                    code = leaseError and leaseError.code or 'UNKNOWN'
                })
                if policy == 'kick_old' then
                    finish('The existing cluster session could not be replaced in time.',
                        'SESSION_REPLACE_TIMEOUT')
                elseif policy == 'deny_new' or duplicate then
                    finish('This account already has an active session on the Synex cluster.',
                        'DUPLICATE_SESSION')
                else
                    finish('Synex could not establish cluster session authority.',
                        'LEASE_ACQUIRE_FAILED')
                end
                return
            end
            logConnectionStage(connection, 'lease_acquired')
            checkpoint('pending_sync_lease')
            local leaseSynced, leaseSyncError = syncPending(connection)
            if not leaseSynced then
                abandonConnection(connection)
                players:removePending(tempSource)
                logger:warn('pending connection authority synchronization failed', {
                    correlationId = connection.id, code = leaseSyncError.code
                })
                finish('Synex could not maintain cluster admission authority.', 'LEASE_STATE_FAILED')
                return
            end
            connection.state = 'AUTHENTICATED'
            connection.acceptedAt = foundation.monotonicMs()
            connection.expiresAt = connection.acceptedAt + (config.pendingTtlMs or 120000)
            checkpoint('pending_sync_accepted')
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
            checkpoint('deferral_acceptance')
            finish()
        end)
        if not ok then
            foundation.safeCall(logger.error, logger, 'connection pipeline failed', {
                correlationId = connection.id, code = 'CONNECTION_PIPELINE_FAILED',
                stage = failureStage, failureType = type(runtimeError)
            })
            if not (terminal and terminal.attempted and terminal.acceptance) then
                local pending = players:getPending(tempSource)
                if pending and pending.id == connection.id then
                    pending = players:removePending(tempSource)
                else
                    pending = nil
                end
                abandonConnection(pending or connection)
            end
            if terminal and not terminal.attempted then
                foundation.safeCall(finish,
                    'An internal connection error occurred. Please retry. If it persists, contact the server team.',
                    'CONNECTION_PIPELINE_FAILED')
            end
            return nil, foundation.error('CONNECTION_PIPELINE_FAILED', 'The connection pipeline raised an exception.', {
                details = { stage = failureStage, runtimeType = type(runtimeError) }
            })
        end
        if pipelineError then return nil, pipelineError end
        if terminal and terminal.state == 'failed' then
            return nil, foundation.error('DEFERRAL_TERMINATION_FAILED',
                'The Cfx connection deferral could not be finalized.')
        end
        return true, nil
    end

end
