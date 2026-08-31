SynexSecuritySentinel = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local Sentinel = SynexSecuritySentinel

local BOOTSTRAP_CHALLENGE = 'bootstrap'
local TIMER_MODULUS = 4294967296

local REPORT_KEYS = {
    clientEpoch = true, sequence = true, sampledAtMs = true,
    challengeRef = true, sample = true,
}
local REPORT_REQUIRED = {
    clientEpoch = true, sequence = true, sampledAtMs = true,
    challengeRef = true, sample = true,
}
local SAMPLE_KEYS = {
    position = true, velocity = true, camera = true, health = true,
    armor = true, visible = true, alpha = true, model = true,
    weapon = true, movement = true,
}
local SAMPLE_REQUIRED = {
    position = true, velocity = true, camera = true, health = true,
    armor = true, visible = true, alpha = true, model = true,
    weapon = true, movement = true,
}
local MOVEMENT_KEYS = {
    inVehicle = true, ragdoll = true, falling = true, parachute = true,
}

local function timerDelta(current, previous)
    if current >= previous then return current - previous end
    return TIMER_MODULUS - previous + current
end

local function vector3(value, minimum, maximum)
    if Validation.arrayLength(value, 3) ~= 3 then return nil end
    local result = {}
    for index = 1, 3 do
        local coordinate = value[index]
        if not Validation.isFinite(coordinate)
            or coordinate < minimum or coordinate > maximum then return nil end
        result[index] = coordinate + 0.0
    end
    return result
end

local function normalizeSample(value)
    if not Validation.exactObject(value, SAMPLE_KEYS, SAMPLE_REQUIRED)
        or not Validation.exactObject(value.movement, MOVEMENT_KEYS, MOVEMENT_KEYS) then
        return Validation.failure('SECURITY_SENTINEL_INVALID',
            'Sentinel telemetry contains unsupported or missing fields.')
    end
    local position = vector3(value.position, -20000, 20000)
    local velocity = vector3(value.velocity, -1000, 1000)
    local camera = vector3(value.camera, -20000, 20000)
    local movement = value.movement
    if position == nil or velocity == nil or camera == nil
        or not Validation.isInteger(value.health, 0, 1000)
        or not Validation.isInteger(value.armor, 0, 1000)
        or type(value.visible) ~= 'boolean'
        or not Validation.isInteger(value.alpha, 0, 255)
        or not Validation.isInteger(value.model, 0, 4294967295)
        or not Validation.isInteger(value.weapon, 0, 4294967295)
        or type(movement.inVehicle) ~= 'boolean'
        or type(movement.ragdoll) ~= 'boolean'
        or type(movement.falling) ~= 'boolean'
        or not Validation.isInteger(movement.parachute, -1, 3) then
        return Validation.failure('SECURITY_SENTINEL_INVALID',
            'Sentinel telemetry contains an invalid or unbounded value.')
    end
    return {
        position = position,
        velocity = velocity,
        camera = camera,
        health = value.health,
        armor = value.armor,
        visible = value.visible,
        alpha = value.alpha,
        model = value.model,
        weapon = value.weapon,
        movement = {
            inVehicle = movement.inVehicle,
            ragdoll = movement.ragdoll,
            falling = movement.falling,
            parachute = movement.parachute,
        },
    }, nil
end

local function subjectFromSession(session)
    local subject = {
        sessionId = session.id,
        source = session.source,
        sourceGeneration = session.sourceGeneration,
    }
    if Validation.token(session.userId, 3, 96) then subject.userId = session.userId end
    if Validation.token(session.characterId, 3, 96) then
        subject.characterId = session.characterId
    end
    return subject
end

function Sentinel.create(options)
    options = options or {}
    local now = assert(options.now, 'security Sentinel clock is required')
    assert(Validation.isCallable(now), 'security Sentinel clock is invalid')
    local emit = Validation.isCallable(options.emit) and options.emit or nil
    local onSample = Validation.isCallable(options.onSample) and options.onSample or nil
    local isEnabled = Validation.isCallable(options.isEnabled)
        and options.isEnabled or function() return options.enabled ~= false end
    local resolveSession = Validation.isCallable(options.resolveSession)
        and options.resolveSession or nil
    local reportIntervalMs = math.max(1000, math.min(30000,
        tonumber(options.reportIntervalMs) or 3000))
    local missingAfterMs = math.max(reportIntervalMs * 2,
        tonumber(options.missingAfterMs) or reportIntervalMs * 4)
    local maximumClientGapMs = math.max(missingAfterMs,
        tonumber(options.maximumClientGapMs) or 60000)
    local capacity = math.max(16, math.min(4096, tonumber(options.capacity) or 1024))
    local states, count, serial = {}, 0, 0
    local counters = {
        accepted = 0, duplicates = 0, rejected = 0, replays = 0,
        stale = 0, missing = 0, epochsChanged = 0, evicted = 0,
        sampleFailures = 0, consecutiveSampleFailures = 0,
    }
    local api = {}

    local function nextChallenge(timestamp)
        serial = serial + 1
        return ('sec-chal-%08x-%08x'):format(
            math.floor(timestamp) % 4294967296, serial % 4294967296)
    end

    local function stateKey(source, sourceGeneration)
        return tostring(source) .. ':' .. tostring(sourceGeneration)
    end

    local function validSession(session, source, sourceGeneration)
        return type(session) == 'table'
            and Validation.token(session.id, 3, 96)
            and Validation.isInteger(session.source, 1, Limits.maximumPlayerSource)
            and session.source == source
            and Validation.isInteger(session.sourceGeneration, 1,
                Limits.maximumSafeInteger)
            and session.sourceGeneration == sourceGeneration
    end

    local function currentSession(context)
        if type(context) ~= 'table'
            or not Validation.isInteger(context.source, 1, Limits.maximumPlayerSource)
            or not Validation.isInteger(context.sourceGeneration, 1,
                Limits.maximumSafeInteger) then return nil end
        local session = context.session
        if resolveSession ~= nil then
            local resolved, value = pcall(resolveSession, context.source)
            if not resolved then return nil end
            session = value
        end
        if not validSession(session, context.source, context.sourceGeneration) then
            return nil
        end
        return session
    end

    local function remove(key)
        if states[key] ~= nil then states[key], count = nil, count - 1 end
    end

    local function ensureCapacity(timestamp)
        if count < capacity then return end
        local oldestKey, oldestAt = nil, math.huge
        for key, state in pairs(states) do
            if state.lastArrivalAt < oldestAt then
                oldestKey, oldestAt = key, state.lastArrivalAt
            end
        end
        if oldestKey ~= nil then remove(oldestKey); counters.evicted = counters.evicted + 1 end
    end

    local function emitMissing(state, timestamp)
        if emit == nil or state.missingReported then return end
        state.missingReported = true
        counters.missing = counters.missing + 1
        pcall(emit, {
            namespace = 'synex.security',
            category = 'client_integrity',
            detector = 'synex.security.sentinel',
            code = 'SECURITY_SENTINEL_MISSING',
            subject = subjectFromSession(state.session),
            severity = 'LOW',
            confidence = 0.35,
            evidenceClass = 'SERVER_DERIVED',
            correlationKey = 'sentinel-liveness',
            summary = 'Expected advisory client telemetry was not received within the bounded liveness window.',
            evidence = {
                lastArrivalAgeMs = math.max(0, timestamp - state.lastArrivalAt),
                expectedIntervalMs = reportIntervalMs,
                advisoryOnly = true,
            },
        })
    end

    function api.track(session)
        if isEnabled() ~= true then return true, nil end
        if type(session) ~= 'table'
            or not validSession(session, session.source,
                session.sourceGeneration) then
            return Validation.failure('SECURITY_SENTINEL_STALE',
                'The Sentinel tracker received a stale or invalid session.')
        end
        local timestamp = now()
        local key = stateKey(session.source, session.sourceGeneration)
        local state = states[key]
        if state == nil then
            ensureCapacity(timestamp)
            state = {
                session = session,
                clientEpoch = nil,
                sequence = 0,
                challengeRef = BOOTSTRAP_CHALLENGE,
                previousChallengeRef = nil,
                sampledAtMs = nil,
                lastArrivalAt = timestamp,
                missingReported = false,
                awaitingFirstReport = true,
            }
            states[key], count = state, count + 1
        else
            state.session = session
        end
        return true, nil
    end

    function api.report(request, context)
        if isEnabled() ~= true then
            return {
                accepted = true,
                duplicate = false,
                nextChallengeRef = BOOTSTRAP_CHALLENGE,
                nextReportAfterMs = reportIntervalMs,
            }, nil
        end
        local timestamp = now()
        local session = currentSession(context)
        if session == nil then
            counters.rejected, counters.stale = counters.rejected + 1, counters.stale + 1
            return Validation.failure('SECURITY_SENTINEL_STALE',
                'Sentinel telemetry refers to a stale or missing session.')
        end
        if not Validation.exactObject(request, REPORT_KEYS, REPORT_REQUIRED)
            or not Validation.isInteger(request.clientEpoch, 1, Limits.maximumSafeInteger)
            or not Validation.isInteger(request.sequence, 1, Limits.maximumSafeInteger)
            or not Validation.isInteger(request.sampledAtMs, 0, 4294967295)
            or not Validation.token(request.challengeRef, 1, 64) then
            counters.rejected = counters.rejected + 1
            return Validation.failure('SECURITY_SENTINEL_INVALID',
                'Sentinel telemetry envelope is invalid.')
        end
        local sample, sampleError = normalizeSample(request.sample)
        if sample == nil then counters.rejected = counters.rejected + 1; return nil, sampleError end
        local key = stateKey(session.source, session.sourceGeneration)
        local state = states[key]
        if state == nil then
            if request.sequence ~= 1 or request.challengeRef ~= BOOTSTRAP_CHALLENGE then
                counters.rejected, counters.replays = counters.rejected + 1,
                    counters.replays + 1
                return Validation.failure('SECURITY_SENTINEL_REPLAY',
                    'The first Sentinel report did not use the bootstrap sequence.')
            end
            ensureCapacity(timestamp)
            state = {
                session = session,
                clientEpoch = request.clientEpoch,
                sequence = 0,
                challengeRef = BOOTSTRAP_CHALLENGE,
                previousChallengeRef = nil,
                sampledAtMs = request.sampledAtMs,
                lastArrivalAt = timestamp,
                missingReported = false,
            }
            states[key], count = state, count + 1
        elseif state.clientEpoch == nil then
            if request.sequence ~= 1 or request.challengeRef ~= BOOTSTRAP_CHALLENGE then
                counters.rejected, counters.replays = counters.rejected + 1,
                    counters.replays + 1
                return Validation.failure('SECURITY_SENTINEL_REPLAY',
                    'The first Sentinel report did not use the bootstrap sequence.')
            end
            state.clientEpoch = request.clientEpoch
            state.sequence = 0
            state.challengeRef = BOOTSTRAP_CHALLENGE
            state.previousChallengeRef = nil
            state.sampledAtMs = request.sampledAtMs
            state.missingReported = false
            state.awaitingFirstReport = false
        elseif request.clientEpoch ~= state.clientEpoch then
            if request.sequence ~= 1 or request.challengeRef ~= BOOTSTRAP_CHALLENGE then
                counters.rejected, counters.replays = counters.rejected + 1,
                    counters.replays + 1
                return Validation.failure('SECURITY_SENTINEL_REPLAY',
                    'The Sentinel epoch changed without a fresh bootstrap report.')
            end
            state.clientEpoch = request.clientEpoch
            state.sequence = 0
            state.challengeRef = BOOTSTRAP_CHALLENGE
            state.previousChallengeRef = nil
            state.sampledAtMs = request.sampledAtMs
            state.missingReported = false
            state.awaitingFirstReport = false
            counters.epochsChanged = counters.epochsChanged + 1
        end

        if request.sequence == state.sequence
            and request.challengeRef == state.previousChallengeRef then
            counters.duplicates = counters.duplicates + 1
            return {
                accepted = true,
                duplicate = true,
                nextChallengeRef = state.challengeRef,
                nextReportAfterMs = reportIntervalMs,
            }, nil
        end
        if request.sequence ~= state.sequence + 1
            or request.challengeRef ~= state.challengeRef then
            counters.rejected, counters.replays = counters.rejected + 1,
                counters.replays + 1
            return Validation.failure('SECURITY_SENTINEL_REPLAY',
                'Sentinel sequence or challenge continuity is invalid.')
        end
        if state.sequence > 0 then
            local clientGap = timerDelta(request.sampledAtMs, state.sampledAtMs)
            if clientGap > maximumClientGapMs
                or timestamp < state.lastArrivalAt
                or timestamp - state.lastArrivalAt > maximumClientGapMs * 2 then
                counters.rejected, counters.stale = counters.rejected + 1,
                    counters.stale + 1
                return Validation.failure('SECURITY_SENTINEL_STALE',
                    'Sentinel telemetry freshness is outside the bounded window.')
            end
        end

        state.session = session
        state.sequence = request.sequence
        state.sampledAtMs = request.sampledAtMs
        state.lastArrivalAt = timestamp
        state.previousChallengeRef = request.challengeRef
        state.challengeRef = nextChallenge(timestamp)
        state.missingReported = false
        state.lastSample = sample
        counters.accepted = counters.accepted + 1
        if onSample ~= nil then
            local sampled, value = pcall(onSample, session, sample, {
                observedAt = timestamp,
                clientEpoch = request.clientEpoch,
                sequence = request.sequence,
                evidenceClass = 'CLIENT_TELEMETRY',
                advisoryOnly = true,
            })
            if not sampled or value == nil or value == false then
                counters.sampleFailures = math.min(Limits.maximumSafeInteger,
                    counters.sampleFailures + 1)
                counters.consecutiveSampleFailures = math.min(
                    Limits.maximumSafeInteger,
                    counters.consecutiveSampleFailures + 1)
            else
                counters.consecutiveSampleFailures = 0
            end
        end
        return {
            accepted = true,
            duplicate = false,
            nextChallengeRef = state.challengeRef,
            nextReportAfterMs = reportIntervalMs,
        }, nil
    end

    function api.sweep(at)
        if isEnabled() ~= true then return { missing = 0, removed = 0 } end
        local timestamp = at or now()
        local staleKeys = {}
        for key, state in pairs(states) do
            local age = timestamp - state.lastArrivalAt
            if age >= missingAfterMs then emitMissing(state, timestamp) end
            if age >= maximumClientGapMs * 4 then staleKeys[#staleKeys + 1] = key end
        end
        for _, key in ipairs(staleKeys) do remove(key) end
        return { missing = counters.missing, removed = #staleKeys }
    end

    function api.cleanupSource(source, sourceGeneration)
        if not Validation.isInteger(source, 1, Limits.maximumPlayerSource) then return 0 end
        local removed = 0
        for key, state in pairs(states) do
            if state.session.source == source
                and (sourceGeneration == nil
                    or state.session.sourceGeneration == sourceGeneration) then
                remove(key)
                removed = removed + 1
            end
        end
        return removed
    end

    function api.inspect(source, sourceGeneration)
        local state = states[stateKey(source, sourceGeneration)]
        if state == nil then return nil end
        return {
            source = state.session.source,
            sourceGeneration = state.session.sourceGeneration,
            clientEpoch = state.clientEpoch,
            sequence = state.sequence,
            lastArrivalAt = state.lastArrivalAt,
            missing = state.missingReported,
            awaitingFirstReport = state.awaitingFirstReport == true,
        }
    end

    function api.snapshot()
        return {
            active = count,
            capacity = capacity,
            reportIntervalMs = reportIntervalMs,
            missingAfterMs = missingAfterMs,
            accepted = counters.accepted,
            duplicates = counters.duplicates,
            rejected = counters.rejected,
            replays = counters.replays,
            stale = counters.stale,
            missing = counters.missing,
            epochsChanged = counters.epochsChanged,
            sampleFailures = counters.sampleFailures,
            consecutiveSampleFailures = counters.consecutiveSampleFailures,
            evicted = counters.evicted,
            trust = 'advisory',
        }
    end

    return api
end
