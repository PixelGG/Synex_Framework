SynexSecurityMovement = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Movement = SynexSecurityMovement

local function finiteVector(value)
    if type(value) ~= 'table' then return nil end
    local result = {}
    for index, key in ipairs({ 'x', 'y', 'z' }) do
        local coordinate = value[index]
        if coordinate == nil then coordinate = value[key] end
        if not Validation.isFinite(coordinate)
            or coordinate < -20000 or coordinate > 20000 then return nil end
        result[index] = coordinate + 0.0
    end
    return result
end

local function distance(left, right)
    local x, y, z = left[1] - right[1], left[2] - right[2], left[3] - right[3]
    return math.sqrt(x * x + y * y + z * z)
end

local function horizontalDistance(left, right)
    local x, y = left[1] - right[1], left[2] - right[2]
    return math.sqrt(x * x + y * y)
end

local function vectorLength(value)
    return math.sqrt(value[1] * value[1] + value[2] * value[2]
        + value[3] * value[3])
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

function Movement.create(options)
    options = options or {}
    local now = assert(options.now, 'security movement clock is required')
    assert(Validation.isCallable(now), 'security movement clock is invalid')
    local emit = Validation.isCallable(options.emit) and options.emit or nil
    local getPosition = Validation.isCallable(options.getPosition)
        and options.getPosition or nil
    local matchExpectations = Validation.isCallable(options.matchExpectations)
        and options.matchExpectations or nil
    local isEnabled = Validation.isCallable(options.isEnabled)
        and options.isEnabled or function() return options.enabled ~= false end
    local historyCapacity = math.max(4, math.min(64,
        tonumber(options.historyCapacity) or 24))
    local subjectCapacity = math.max(16, math.min(4096,
        tonumber(options.subjectCapacity) or 1024))
    local retentionMs = math.max(30000, math.min(600000,
        tonumber(options.retentionMs) or 120000))
    local states, count = {}, 0
    local counters = {
        samples = 0, teleport = 0, noclip = 0, freecam = 0,
        superJump = 0, expected = 0, filtered = 0, evicted = 0,
    }
    local api = {}

    local function stateKey(session)
        return tostring(session.source) .. ':' .. tostring(session.sourceGeneration)
    end

    local function validSession(session)
        return type(session) == 'table'
            and Validation.token(session.id, 3, 96)
            and Validation.isInteger(session.source, 1, Limits.maximumPlayerSource)
            and Validation.isInteger(session.sourceGeneration, 1,
                Limits.maximumSafeInteger)
    end

    local function remove(key)
        if states[key] ~= nil then states[key], count = nil, count - 1 end
    end

    local function ensureCapacity()
        if count < subjectCapacity then return end
        local oldestKey, oldestAt = nil, math.huge
        for key, state in pairs(states) do
            if state.updatedAt < oldestAt then oldestKey, oldestAt = key, state.updatedAt end
        end
        if oldestKey ~= nil then remove(oldestKey); counters.evicted = counters.evicted + 1 end
    end

    local function expectationMatches(session, definition)
        if matchExpectations == nil then return false end
        local signal = {
            subjectSession = session.id,
            subjectSource = session.source,
            sourceGeneration = session.sourceGeneration,
            subjectUser = session.userId,
            subjectCharacter = session.characterId,
            category = definition.category,
            detector = definition.detector,
            code = definition.code,
            correlationKey = definition.correlationKey,
            evidenceClass = definition.evidenceClass,
            severity = definition.severity,
            worldRef = definition.worldRef,
        }
        local ok, matches = pcall(matchExpectations, signal)
        return ok and type(matches) == 'table' and #matches > 0
    end

    local function report(session, definition)
        if expectationMatches(session, definition) then
            counters.expected = counters.expected + 1
            return false, 'expected'
        end
        if emit ~= nil then
            pcall(emit, {
                namespace = 'synex.security',
                category = definition.category,
                detector = definition.detector,
                code = definition.code,
                subject = subjectFromSession(session),
                severity = definition.severity,
                confidence = definition.confidence,
                evidenceClass = definition.evidenceClass,
                correlationKey = definition.correlationKey,
                worldRef = definition.worldRef,
                summary = definition.summary,
                evidence = definition.evidence,
            })
        end
        return true, nil
    end

    local function worldRef(meta)
        if type(meta) ~= 'table' then return nil end
        if Validation.token(meta.worldKey, 3, 128) then return { key = meta.worldKey } end
        if Validation.isInteger(meta.bucket, 0, 2147483647) then
            return { bucket = meta.bucket }
        end
        return nil
    end

    local function authoritativePosition(session, sample, meta)
        local candidate = type(meta) == 'table' and finiteVector(meta.serverPosition) or nil
        if candidate ~= nil then return candidate, 'SERVER_DERIVED' end
        if getPosition ~= nil then
            local ok, value = pcall(getPosition, session.source)
            candidate = ok and finiteVector(value) or nil
            if candidate ~= nil then return candidate, 'SERVER_DERIVED' end
        end
        return finiteVector(sample.position), 'CLIENT_TELEMETRY'
    end

    function api.observe(session, sample, meta)
        if isEnabled() ~= true then
            return { accepted = true, signals = 0, disabled = true }, nil
        end
        if not validSession(session) or type(sample) ~= 'table'
            or type(sample.movement) ~= 'table' then
            return Validation.failure('SECURITY_MOVEMENT_INVALID',
                'Movement telemetry or session context is invalid.')
        end
        local timestamp = type(meta) == 'table' and meta.observedAt or now()
        local position, evidenceClass = authoritativePosition(session, sample, meta)
        local velocity, camera = finiteVector(sample.velocity), finiteVector(sample.camera)
        if position == nil or velocity == nil or camera == nil
            or not Validation.isInteger(timestamp, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_MOVEMENT_INVALID',
                'Movement telemetry contains an invalid vector or timestamp.')
        end
        local key = stateKey(session)
        local state = states[key]
        if state == nil then
            ensureCapacity()
            state = {
                sessionId = session.id,
                sourceGeneration = session.sourceGeneration,
                history = {},
                noclipStreak = 0,
                freecamStreak = 0,
                jumpStreak = 0,
                updatedAt = timestamp,
            }
            states[key], count = state, count + 1
        elseif state.sessionId ~= session.id
            or state.sourceGeneration ~= session.sourceGeneration then
            remove(key)
            return Validation.failure('SECURITY_MOVEMENT_STALE',
                'Movement telemetry refers to a reused player source.')
        end
        local movement = sample.movement
        local bucket = type(meta) == 'table'
            and Validation.isInteger(meta.bucket, 0, 2147483647)
            and meta.bucket or nil
        local current = {
            at = timestamp,
            position = position,
            velocity = velocity,
            camera = camera,
            inVehicle = movement.inVehicle == true,
            ragdoll = movement.ragdoll == true,
            falling = movement.falling == true,
            parachute = tonumber(movement.parachute) or -1,
            evidenceClass = evidenceClass,
            bucket = bucket,
        }
        local history = state.history
        local previous = history[#history]
        history[#history + 1] = current
        if #history > historyCapacity then table.remove(history, 1) end
        state.updatedAt = timestamp
        counters.samples = counters.samples + 1
        if previous == nil then return { accepted = true, signals = 0 }, nil end

        local elapsedMs = timestamp - previous.at
        local bucketTransition = current.bucket ~= nil and previous.bucket ~= nil
            and current.bucket ~= previous.bucket
        if elapsedMs < 200 or elapsedMs > 15000
            or bucketTransition
            or type(meta) == 'table' and (meta.authorizedTransition == true
                or meta.spawning == true or meta.respawning == true
                or meta.adminTransition == true or meta.instanceTransition == true) then
            state.noclipStreak, state.freecamStreak, state.jumpStreak = 0, 0, 0
            counters.filtered = counters.filtered + 1
            return { accepted = true, signals = 0, filtered = true }, nil
        end

        local elapsed = elapsedMs / 1000
        local travelled = distance(position, previous.position)
        local horizontal = horizontalDistance(position, previous.position)
        local vertical = position[3] - previous.position[3]
        local impliedSpeed = travelled / elapsed
        local measuredSpeed = vectorLength(velocity)
        local inVehicle = current.inVehicle or previous.inVehicle
        local unstable = current.ragdoll or current.falling or current.parachute >= 0
            or previous.ragdoll or previous.falling or previous.parachute >= 0
        local threshold = inVehicle and math.max(450, elapsed * 120)
            or math.max(120, elapsed * 35)
        local emitted = 0
        local reference = worldRef(meta)

        if not unstable and travelled >= threshold
            and impliedSpeed > (inVehicle and 110 or 32) then
            local accepted = report(session, {
                category = 'movement', detector = 'synex.security.movement',
                code = 'MOVEMENT_TELEPORT_ANOMALY', severity = 'MEDIUM',
                confidence = evidenceClass == 'SERVER_DERIVED' and 0.72 or 0.42,
                evidenceClass = evidenceClass,
                correlationKey = 'movement-teleport', worldRef = reference,
                summary = 'A large movement transition had no active server-side transition context.',
                evidence = {
                    distance = math.floor(travelled * 10 + 0.5) / 10,
                    elapsedMs = elapsedMs,
                    impliedSpeed = math.floor(impliedSpeed * 10 + 0.5) / 10,
                    inVehicle = inVehicle,
                    expectationChecked = true,
                },
            })
            if accepted then emitted, counters.teleport = emitted + 1, counters.teleport + 1 end
            state.noclipStreak = 0
        else
            local impossibleTraversal = not inVehicle and not unstable
                and elapsedMs <= 4000
                and (impliedSpeed > 18 and measuredSpeed > 12
                    or math.abs(vertical) > 7 and horizontal > 8)
            state.noclipStreak = impossibleTraversal and state.noclipStreak + 1
                or math.max(0, state.noclipStreak - 1)
            if state.noclipStreak >= 3 then
                local accepted = report(session, {
                    category = 'movement', detector = 'synex.security.movement.noclip',
                    code = 'MOVEMENT_NOCLIP_PATTERN', severity = 'LOW',
                    confidence = 0.38, evidenceClass = 'BEHAVIORAL_HEURISTIC',
                    correlationKey = 'movement-noclip', worldRef = reference,
                    summary = 'Repeated movement continuity anomalies matched an observe-only noclip heuristic.',
                    evidence = {
                        streak = state.noclipStreak,
                        impliedSpeed = math.floor(impliedSpeed * 10 + 0.5) / 10,
                        verticalDelta = math.floor(vertical * 10 + 0.5) / 10,
                        advisoryOnly = true,
                    },
                })
                if accepted then emitted, counters.noclip = emitted + 1, counters.noclip + 1 end
                state.noclipStreak = 0
            end
        end

        local cameraSeparation = distance(camera, position)
        state.freecamStreak = cameraSeparation > 55 and not inVehicle and not unstable
            and state.freecamStreak + 1 or math.max(0, state.freecamStreak - 1)
        if state.freecamStreak >= 2 then
            local accepted = report(session, {
                category = 'movement', detector = 'synex.security.movement.freecam',
                code = 'CAMERA_FREECAM_ANOMALY', severity = 'LOW', confidence = 0.30,
                evidenceClass = 'CLIENT_TELEMETRY', correlationKey = 'camera-freecam',
                worldRef = reference,
                summary = 'Repeated advisory camera-to-player separation exceeded the observation window.',
                evidence = {
                    cameraSeparation = math.floor(cameraSeparation * 10 + 0.5) / 10,
                    streak = state.freecamStreak,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.freecam = emitted + 1, counters.freecam + 1 end
            state.freecamStreak = 0
        end

        local jumpLike = not inVehicle and not unstable and elapsedMs <= 2500
            and vertical > 10 and vertical < 80 and horizontal < 35
        state.jumpStreak = jumpLike and state.jumpStreak + 1
            or math.max(0, state.jumpStreak - 1)
        if state.jumpStreak >= 2 then
            local accepted = report(session, {
                category = 'movement', detector = 'synex.security.movement.super_jump',
                code = 'MOVEMENT_SUPER_JUMP_PATTERN', severity = 'LOW', confidence = 0.32,
                evidenceClass = 'BEHAVIORAL_HEURISTIC', correlationKey = 'movement-super-jump',
                worldRef = reference,
                summary = 'Repeated vertical movement matched an observe-only super-jump heuristic.',
                evidence = {
                    streak = state.jumpStreak,
                    verticalDelta = math.floor(vertical * 10 + 0.5) / 10,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.superJump = emitted + 1,
                counters.superJump + 1 end
            state.jumpStreak = 0
        end
        return { accepted = true, signals = emitted }, nil
    end

    function api.cleanupSource(source, sourceGeneration)
        local removed = 0
        for key, state in pairs(states) do
            local keySource, keyGeneration = key:match('^(%d+):(%d+)$')
            if tonumber(keySource) == source
                and (sourceGeneration == nil or tonumber(keyGeneration) == sourceGeneration) then
                remove(key)
                removed = removed + 1
            end
        end
        return removed
    end

    function api.prune(at)
        local timestamp, keys = at or now(), {}
        for key, state in pairs(states) do
            if timestamp - state.updatedAt >= retentionMs then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do remove(key) end
        return #keys
    end

    function api.inspect(source, sourceGeneration)
        local state = states[tostring(source) .. ':' .. tostring(sourceGeneration)]
        if state == nil then return nil end
        return {
            samples = #state.history,
            updatedAt = state.updatedAt,
            noclipStreak = state.noclipStreak,
            freecamStreak = state.freecamStreak,
            jumpStreak = state.jumpStreak,
        }
    end

    function api.snapshot()
        return {
            subjects = count,
            subjectCapacity = subjectCapacity,
            historyCapacity = historyCapacity,
            retentionMs = retentionMs,
            samples = counters.samples,
            anomalies = counters.teleport + counters.noclip
                + counters.freecam + counters.superJump,
            teleport = counters.teleport,
            noclip = counters.noclip,
            freecam = counters.freecam,
            superJump = counters.superJump,
            expected = counters.expected,
            filtered = counters.filtered,
            evicted = counters.evicted,
        }
    end

    return api
end
