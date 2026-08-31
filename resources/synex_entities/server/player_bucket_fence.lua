SynexEntityPlayerBucketFence = {}

function SynexEntityPlayerBucketFence.create(options)
    assert(type(options) == 'table', 'player bucket fence options are required')
    local coreRef = assert(options.coreRef, 'player bucket fence coreRef is required')
    local foundation = assert(options.foundation,
        'player bucket fence foundation is required')
    local ports = assert(options.ports, 'player bucket fence ports are required')
    local state = assert(options.state, 'player bucket fence state is required')
    local validation = assert(options.validation,
        'player bucket fence validation is required')
    local fields = { sessionId = true, source = true, sourceGeneration = true }
    local fence = {}

    local function bucketReference(request, actualBucket, context)
        local membership = state.playerMemberships[request.source]
        if actualBucket == 0 then
            if membership ~= nil then
                return foundation.failure('STALE_BUCKET',
                    'The player bucket membership is stale', true, context)
            end
            return { bucket = 0, generation = 0 }, nil
        end
        local bucket = state.buckets[actualBucket]
        if not membership or membership.bucket ~= actualBucket
            or membership.sessionId ~= request.sessionId
            or membership.sourceGeneration ~= request.sourceGeneration
            or not bucket or bucket.destroying == true
            or type(bucket.players) ~= 'table'
            or bucket.players[request.source] ~= true
            or membership.generation ~= bucket.generation then
            return foundation.failure('STALE_BUCKET',
                'The managed player bucket fence is stale', true, context)
        end
        return { bucket = actualBucket, generation = bucket.generation }, nil
    end

    local function currentSession(request, context)
        local api = coreRef.value
        if type(api) ~= 'table' or type(api.Players) ~= 'table'
            or not foundation.isCallable(api.Players.getBySource) then
            return foundation.failure('CORE_UNAVAILABLE',
                'Player session authority is unavailable', true, context)
        end
        local invoked, session, sessionError = foundation.protect(
            'core.players.get_by_source',
            function() return api.Players.getBySource(request.source) end,
            context
        )
        if not invoked then
            return foundation.failure('CORE_UNAVAILABLE',
                'Player session authority failed', true, context)
        end
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or session.id ~= request.sessionId or session.source ~= request.source
            or session.sourceGeneration ~= request.sourceGeneration then
            return foundation.failure('STALE_RESOURCE',
                'The player session changed during bucket resolution', true,
                type(sessionError) == 'table'
                    and { traceId = context and context.traceId } or context)
        end
        return session, nil
    end

    function fence.resolve(request, context)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, callerError end
        local allowed, rateError = foundation.takeRateLimit(caller, 1, context, true)
        if not allowed then return nil, rateError end
        if not validation.isPlainTable(request) then
            return foundation.failure('INVALID_ARGUMENT',
                'Player bucket fence request must be an object', false, context)
        end
        for key in pairs(request) do
            if type(key) ~= 'string' or not fields[key] then
                return foundation.failure('INVALID_ARGUMENT',
                    'Player bucket fence request contains an unknown field', false, context)
            end
        end
        if not validation.isInteger(request.source, 1, 65535)
            or not validation.isInteger(request.sourceGeneration, 1)
            or not validation.token(request.sessionId, 8, 64) then
            return foundation.failure('INVALID_ARGUMENT',
                'Player bucket fence request is invalid', false, context)
        end
        local session, sessionError = currentSession(request, context)
        if not session then return nil, sessionError end
        local actualBucket = ports.getPlayerRoutingBucket(request.source)
        if not validation.isInteger(actualBucket, 0, 2147483647) then
            return foundation.failure('STALE_BUCKET',
                'The player routing bucket is unavailable', true, context)
        end
        local bucketValue, bucketError = bucketReference(request, actualBucket, context)
        if not bucketValue then return nil, bucketError end
        session, sessionError = currentSession(request, context)
        if not session then return nil, sessionError end
        local currentBucket = ports.getPlayerRoutingBucket(request.source)
        if currentBucket ~= bucketValue.bucket then
            return foundation.failure('STALE_BUCKET',
                'The player routing bucket changed during resolution', true, context)
        end
        local currentReference, currentBucketError = bucketReference(
            request, currentBucket, context)
        if not currentReference then return nil, currentBucketError end
        if currentReference.generation ~= bucketValue.generation then
            return foundation.failure('STALE_BUCKET',
                'The player bucket generation changed during resolution', true, context)
        end
        return { source = request.source, sessionId = request.sessionId,
            sourceGeneration = request.sourceGeneration, bucket = currentReference }
    end

    return fence
end
