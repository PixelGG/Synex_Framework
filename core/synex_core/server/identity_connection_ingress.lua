local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionIngress = function(deps)
    local platform = assert(deps.platform, 'connection ingress requires platform')
    local foundation = assert(deps.foundation, 'connection ingress requires foundation')
    local rateLimiter = assert(deps.rateLimiter, 'connection ingress requires rate limiter')
    local sha256 = assert(deps.sha256, 'connection ingress requires SHA-256')
    local metrics = foundation.metrics
    local logger = foundation.logger
    local config = deps.config or {}
    local reservations = {}
    local bySource = {}
    local reservationCount = 0
    local reservationGeneration = 0
    local quiesced = false
    local salt = foundation.nextId('connection_ingress_salt')
    local maximum = math.max(1,
        math.min(math.floor(tonumber(config.maximumConcurrentConnections) or 256), 10000))
    local rate = math.max(0.01, math.min(tonumber(config.connectionRate) or 0.5, 1000))
    local burst = math.max(1,
        math.min(math.floor(tonumber(config.connectionBurst) or 6), 1000))
    local stats = { admitted = 0, rateLimited = 0, capacityRejected = 0 }
    local ingress = {}

    function ingress:logStage(connection, stage, code, level)
        foundation.safeCall(function()
            local elapsedMs = math.max(0,
                foundation.monotonicMs() - (connection.receivedAt or foundation.monotonicMs()))
            local fields = {
                correlationId = connection.id,
                stage = stage,
                elapsedMs = elapsedMs,
                code = code
            }
            foundation.safeCall(metrics.increment, metrics,
                'synex_connection_stage_total', { stage = stage })
            foundation.safeCall(metrics.observe, metrics,
                'synex_connection_stage_elapsed_ms', { stage = stage }, elapsedMs)
            foundation.safeCall(logger[level or 'info'], logger, 'connection stage', fields)
        end)
    end

    function ingress:identityFingerprint(identifiers)
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

    function ingress:release(connection)
        local connectionId = type(connection) == 'table' and connection.id or connection
        if type(connectionId) ~= 'string' then return false end
        local reservation = reservations[connectionId]
        if not reservation then return false end
        reservations[connectionId] = nil
        reservationCount = math.max(0, reservationCount - 1)
        local sourceReservations = bySource[reservation.source]
        if sourceReservations then
            sourceReservations[connectionId] = nil
            if next(sourceReservations) == nil then bySource[reservation.source] = nil end
        end
        return true
    end

    function ingress:isCurrent(connection)
        if type(connection) ~= 'table' or type(connection.id) ~= 'string'
            or type(connection.ingressGeneration) ~= 'number' then return false end
        local reservation = reservations[connection.id]
        return reservation ~= nil
            and reservation.source == connection.tempSource
            and reservation.generation == connection.ingressGeneration
            and bySource[reservation.source] ~= nil
            and bySource[reservation.source][connection.id] == reservation.generation
    end

    function ingress:releaseSource(playerSource)
        local sourceReservations = bySource[playerSource]
        if not sourceReservations then return 0 end
        local released = 0
        for connectionId in pairs(sourceReservations) do
            if reservations[connectionId] then
                reservations[connectionId] = nil
                reservationCount = math.max(0, reservationCount - 1)
                released = released + 1
            end
        end
        bySource[playerSource] = nil
        return released
    end

    function ingress:acquire(connection, rawIdentifiers)
        if quiesced then
            return nil, foundation.error('CORE_STOPPING',
                'The Synex runtime is stopping and cannot admit another connection.')
        end
        if reservations[connection.id] then
            if self:isCurrent(connection) then return true, nil end
            return nil, foundation.error('CONNECTION_CANCELLED',
                'The connection reservation is no longer current.')
        end
        if reservationCount >= maximum then
            stats.capacityRejected = stats.capacityRejected + 1
            foundation.safeCall(metrics.increment, metrics,
                'synex_connection_ingress_total', { result = 'capacity_rejected' })
            return nil, foundation.error('CONNECTION_CAPACITY_REACHED',
                'The concurrent connection limit has been reached.', { retryable = true })
        end

        local identifiersByType = {}
        if type(rawIdentifiers) == 'table' and getmetatable(rawIdentifiers) == nil then
            for index = 1, math.min(#rawIdentifiers, 32) do
                local raw = rawIdentifiers[index]
                if type(raw) == 'string' and #raw <= 256 then
                    local kind, value = raw:match('^([a-z0-9_]+):(.+)$')
                    if kind and #value >= 2 and #value <= 192
                        and (kind == 'license' or kind == 'license2' or kind == 'fivem'
                            or kind == 'ip' or kind == 'steam' or kind == 'discord'
                            or kind == 'xbl' or kind == 'live') then
                        local normalized = value:lower()
                        if not identifiersByType[kind] or normalized < identifiersByType[kind] then
                            identifiersByType[kind] = normalized
                        end
                    end
                end
            end
        end
        local identityMaterial = nil
        for _, kind in ipairs({ 'license', 'license2', 'fivem', 'ip', 'steam', 'discord', 'xbl', 'live' }) do
            if identifiersByType[kind] then
                identityMaterial = kind .. ':' .. identifiersByType[kind]
                break
            end
        end
        identityMaterial = identityMaterial or 'anonymous'
        local hashed, digest = foundation.safeCall(sha256,
            'synex-connection-ingress-v1\0' .. salt .. '\0' .. identityMaterial)
        if not hashed or type(digest) ~= 'string' or #digest ~= 64
            or not digest:match('^[0-9a-f]+$') then
            return nil, foundation.error('CONNECTION_FINGERPRINT_FAILED',
                'The connection rate-limit identity could not be derived.')
        end
        local rateInvoked, rateAllowed, rateError = foundation.safeCall(
            rateLimiter.consume, rateLimiter,
            'connection_ingress:' .. digest, burst, rate, 1)
        if not rateInvoked or not rateAllowed then
            stats.rateLimited = stats.rateLimited + 1
            foundation.safeCall(metrics.increment, metrics,
                'synex_connection_ingress_total', { result = 'rate_limited' })
            return nil, foundation.error('CONNECTION_RATE_LIMITED',
                'Too many connection attempts were received.', {
                    retryable = true,
                    details = rateInvoked and type(rateError) == 'table'
                        and foundation.copy(rateError.details) or nil
                })
        end

        reservationGeneration = reservationGeneration >= 9007199254740990
            and 1 or reservationGeneration + 1
        connection.ingressGeneration = reservationGeneration
        reservations[connection.id] = {
            source = connection.tempSource,
            generation = reservationGeneration
        }
        bySource[connection.tempSource] = bySource[connection.tempSource] or {}
        bySource[connection.tempSource][connection.id] = reservationGeneration
        reservationCount = reservationCount + 1
        stats.admitted = stats.admitted + 1
        foundation.safeCall(metrics.increment, metrics,
            'synex_connection_ingress_total', { result = 'admitted' })
        return true, nil
    end

    function ingress:begin(connection, deferrals, checkpoint)
        checkpoint = type(checkpoint) == 'function' and checkpoint or function() end
        checkpoint('ingress_deferral')
        deferrals.defer()
        checkpoint('ingress_identifiers')
        local identifiersRead, rawIdentifiers = foundation.safeCall(
            platform.getPlayerIdentifiers, connection.tempSource)
        if not identifiersRead or type(rawIdentifiers) ~= 'table' then rawIdentifiers = {} end
        checkpoint('ingress_reservation')
        local allowed, ingressError = self:acquire(connection, rawIdentifiers)
        if allowed then return rawIdentifiers, nil end

        checkpoint('ingress_rejection_tick')
        platform.defer()
        local rejectionCode = type(ingressError) == 'table'
            and ingressError.code or 'CONNECTION_BUSY'
        if rejectionCode ~= 'CONNECTION_RATE_LIMITED'
            and rejectionCode ~= 'CONNECTION_CAPACITY_REACHED'
            and rejectionCode ~= 'CORE_STOPPING' then
            rejectionCode = 'CONNECTION_BUSY'
        end
        local rejectionReason = rejectionCode == 'CONNECTION_RATE_LIMITED'
            and 'Too many connection attempts were received. Please wait and reconnect.'
            or (rejectionCode == 'CORE_STOPPING'
                and 'The Synex runtime is stopping. Please reconnect shortly.'
                or 'The server is processing the maximum number of connections. Please reconnect shortly.')
        checkpoint('ingress_rejection_terminal')
        local rejected = foundation.safeCall(deferrals.done,
            ('Synex [%s]: %s'):format(rejectionCode, rejectionReason):sub(1, 256))
        self:logStage(connection, 'rejected', rejectionCode, 'warn')
        if not rejected then error('connection ingress rejection terminal failed') end
        return nil, ingressError
    end

    function ingress:quiesce()
        quiesced = true
        local released = reservationCount
        reservations = {}
        bySource = {}
        reservationCount = 0
        return released
    end

    function ingress:snapshot()
        return {
            active = reservationCount,
            maximum = maximum,
            rate = rate,
            burst = burst,
            quiesced = quiesced,
            admitted = stats.admitted,
            rateLimited = stats.rateLimited,
            capacityRejected = stats.capacityRejected
        }
    end

    return ingress
end
