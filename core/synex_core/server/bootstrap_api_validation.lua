local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapApiValidation = function(deps)
    local foundation = assert(deps.foundation, 'bootstrap API validation requires foundation')
    local defaultConfig = assert(deps.defaultConfig,
        'bootstrap API validation requires effective configuration')
    local reliability = assert(deps.reliability,
        'bootstrap API validation requires reliability services')

    local function publicSession(session)
        if not session then return nil end
        return {
            id = session.id,
            userId = session.userId,
            characterId = session.characterId,
            source = session.source,
            sourceGeneration = session.sourceGeneration,
            state = session.state,
            connectedAt = session.connectedAt,
            version = session.version
        }
    end

    local function mutateAccess(caller, operation, request, traceId, handler)
        if type(request) ~= 'table' or getmetatable(request) ~= nil
            or type(request.idempotencyKey) ~= 'string' then
            return nil, foundation.error('INVALID_ACCESS_REQUEST',
                'Access mutations require a plain request and idempotencyKey.', {
                    traceId = traceId
                })
        end
        local candidate = foundation.copy(request)
        local idempotencyKey = candidate.idempotencyKey
        candidate.idempotencyKey = nil
        return reliability.idempotency:run(caller, operation, idempotencyKey,
            candidate, function()
                return handler(candidate, {
                    actor = caller, actorType = 'resource', traceId = traceId
                })
            end, { maximumRequestBytes = 4096, maximumResponseBytes = 4096 })
    end

    local function rpcCallOptions(options)
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_RPC_OPTIONS',
                'RPC call options must be a plain object.')
        end
        local allowed = { timeoutMs = true, traceId = true, idempotencyKey = true }
        for key in pairs(options) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error('INVALID_RPC_OPTIONS',
                    'RPC call options contain an unknown property.')
            end
        end
        local rpcConfig = defaultConfig.rpc or {}
        local maximumTimeoutMs = math.max(100,
            math.min(tonumber(rpcConfig.maximumTimeoutMs) or 15000, 15000))
        local timeoutMs = options.timeoutMs == nil and (rpcConfig.timeoutMs or 5000)
            or options.timeoutMs
        if type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < 100 or timeoutMs > maximumTimeoutMs then
            return nil, foundation.error('INVALID_RPC_OPTIONS',
                'RPC timeoutMs is outside the configured range.')
        end
        if options.traceId ~= nil and (type(options.traceId) ~= 'string'
            or #options.traceId < 8 or #options.traceId > 64
            or not options.traceId:match('^[A-Za-z0-9_.:%-]+$')) then
            return nil, foundation.error('INVALID_RPC_OPTIONS', 'RPC traceId is invalid.')
        end
        if options.idempotencyKey ~= nil and (type(options.idempotencyKey) ~= 'string'
            or #options.idempotencyKey < 8 or #options.idempotencyKey > 128
            or not options.idempotencyKey:match('^[A-Za-z0-9_.:%-]+$')) then
            return nil, foundation.error('INVALID_RPC_OPTIONS',
                'RPC idempotencyKey is invalid.')
        end
        return {
            traceId = options.traceId,
            idempotencyKey = options.idempotencyKey,
            deadlineAt = foundation.monotonicMs() + timeoutMs
        }, nil
    end

    local function permissionMutationOptions(options, allowExpiry, traceId)
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT',
                'Permission mutations require a plain options object.', { traceId = traceId })
        end
        local allowed = { reason = true }
        if allowExpiry then allowed.expiresAt = true end
        for key in pairs(options) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error('INVALID_AUDIT_CONTEXT',
                    'Permission mutation options contain an unknown property.', { traceId = traceId })
            end
        end
        if type(options.reason) ~= 'string' or #options.reason < 1 or #options.reason > 256
            or options.reason:find('[%z\1-\31\127]') then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT',
                'Permission mutations require a bounded printable reason.', { traceId = traceId })
        end
        if allowExpiry and options.expiresAt ~= nil
            and (type(options.expiresAt) ~= 'string' or #options.expiresAt < 19
                or #options.expiresAt > 32
                or not options.expiresAt:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d')) then
            return nil, foundation.error('INVALID_EXPIRY',
                'Permission assignment expiry must be an ISO-like timestamp.', { traceId = traceId })
        end
        return foundation.copy(options), nil
    end

    return {
        mutateAccess = mutateAccess,
        permissionMutationOptions = permissionMutationOptions,
        publicSession = publicSession,
        rpcCallOptions = rpcCallOptions
    }
end
