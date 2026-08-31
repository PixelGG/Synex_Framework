SynexSecurityDetectors = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Detectors = SynexSecurityDetectors

local DEFAULT_MODES = {
    transport = 'MITIGATE',
    sentinel = 'OBSERVE',
    player_integrity = 'OBSERVE',
    movement = 'OBSERVE',
    entity_guard = 'MITIGATE',
    game_events = 'MITIGATE',
    weapon_integrity = 'OBSERVE',
    combat_analytics = 'OBSERVE',
    domain_abuse = 'OBSERVE',
}

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

function Detectors.create(options)
    options = options or {}
    local now = assert(options.now, 'security detector clock is required')
    assert(Validation.isCallable(now), 'security detector clock is invalid')
    local emit = Validation.isCallable(options.emit) and options.emit or nil
    local matchExpectations = Validation.isCallable(options.matchExpectations)
        and options.matchExpectations or nil
    local expectedPlayerState = Validation.isCallable(options.expectedPlayerState)
        and options.expectedPlayerState or nil
    local isWeaponAuthorized = Validation.isCallable(options.isWeaponAuthorized)
        and options.isWeaponAuthorized or nil
    local validateDamage = Validation.isCallable(options.validateDamage)
        and options.validateDamage or nil
    local movement = type(options.movement) == 'table' and options.movement or nil
    local retentionMs = math.max(30000, math.min(900000,
        tonumber(options.retentionMs) or 180000))
    local capacity = math.max(16, math.min(4096, tonumber(options.capacity) or 1024))
    local modes, states, count = {}, {}, 0
    local counters = {
        emitted = 0, expected = 0, visibility = 0, model = 0,
        health = 0, armor = 0, damageImmunity = 0, weapon = 0,
        combat = 0, filtered = 0, evicted = 0,
    }
    local api = {}

    for name, fallback in pairs(DEFAULT_MODES) do
        local configured = type(options.modes) == 'table' and options.modes[name] or nil
        modes[name] = Limits.detectorModes[configured] and configured or fallback
    end

    local function validSession(session)
        return type(session) == 'table'
            and Validation.token(session.id, 3, 96)
            and Validation.isInteger(session.source, 1, Limits.maximumPlayerSource)
            and Validation.isInteger(session.sourceGeneration, 1,
                Limits.maximumSafeInteger)
    end

    local function stateKey(session)
        return tostring(session.source) .. ':' .. tostring(session.sourceGeneration)
    end

    local function remove(key)
        if states[key] ~= nil then states[key], count = nil, count - 1 end
    end

    local function ensureCapacity()
        if count < capacity then return end
        local oldestKey, oldestAt = nil, math.huge
        for key, state in pairs(states) do
            if state.updatedAt < oldestAt then oldestKey, oldestAt = key, state.updatedAt end
        end
        if oldestKey ~= nil then remove(oldestKey); counters.evicted = counters.evicted + 1 end
    end

    local function getState(session, timestamp)
        local key = stateKey(session)
        local state = states[key]
        if state == nil then
            ensureCapacity()
            state = {
                sessionId = session.id,
                sourceGeneration = session.sourceGeneration,
                updatedAt = timestamp,
                invisibleStreak = 0,
                modelStreak = 0,
                healthStreak = 0,
                armorStreak = 0,
                weaponStreak = 0,
                damageObservations = {},
                combat = { samples = 0, anomalyTypes = {}, lastSignalAt = 0 },
            }
            states[key], count = state, count + 1
        elseif state.sessionId ~= session.id
            or state.sourceGeneration ~= session.sourceGeneration then
            remove(key)
            return nil
        end
        state.updatedAt = timestamp
        return state
    end

    local function expected(session, definition)
        if matchExpectations == nil then return false end
        local ok, matches = pcall(matchExpectations, {
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
        })
        return ok and type(matches) == 'table' and #matches > 0
    end

    local function report(session, detectorName, definition)
        if modes[detectorName] == 'DISABLED' then return false, 'disabled' end
        if expected(session, definition) then
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
                rootEventId = definition.rootEventId,
                summary = definition.summary,
                evidence = definition.evidence,
            })
        end
        counters.emitted = counters.emitted + 1
        return true, nil
    end

    function api.mode(name)
        return modes[name]
    end

    function api.configure(name, mode)
        if DEFAULT_MODES[name] == nil or not Limits.detectorModes[mode] then
            return Validation.failure('SECURITY_DETECTOR_INVALID',
                'Security detector name or mode is invalid.')
        end
        modes[name] = mode
        return true, nil
    end

    function api.observeSentinel(session, sample, meta)
        if not validSession(session) or type(sample) ~= 'table'
            or type(sample.movement) ~= 'table'
            or not Validation.isInteger(sample.health, 0, 1000)
            or not Validation.isInteger(sample.armor, 0, 1000)
            or type(sample.visible) ~= 'boolean'
            or not Validation.isInteger(sample.alpha, 0, 255)
            or not Validation.isInteger(sample.model, 0, 4294967295)
            or not Validation.isInteger(sample.weapon, 0, 4294967295) then
            return Validation.failure('SECURITY_DETECTOR_INVALID',
                'Player integrity telemetry or session is invalid.')
        end
        local playerIntegrityEnabled = modes.player_integrity ~= 'DISABLED'
        local weaponIntegrityEnabled = modes.weapon_integrity ~= 'DISABLED'
        local movementEnabled = modes.movement ~= 'DISABLED'
        if not playerIntegrityEnabled and not weaponIntegrityEnabled
            and not movementEnabled then
            return { accepted = true, signals = 0, disabled = true }, nil
        end
        local timestamp = type(meta) == 'table' and meta.observedAt or now()
        local state = getState(session, timestamp)
        if state == nil then
            return Validation.failure('SECURITY_SUBJECT_STALE',
                'Player integrity telemetry refers to a reused source.')
        end
        local expectedState = {}
        if (playerIntegrityEnabled or weaponIntegrityEnabled)
            and expectedPlayerState ~= nil then
            local ok, value = pcall(expectedPlayerState, session)
            if ok and type(value) == 'table' then expectedState = value end
        end
        local emitted = 0
        local visibleExpected = expectedState.visible ~= false
        local invisible = sample.visible == false or tonumber(sample.alpha) < 80
        state.invisibleStreak = playerIntegrityEnabled and visibleExpected and invisible
            and state.invisibleStreak + 1 or 0
        if state.invisibleStreak >= 2 then
            local accepted = report(session, 'player_integrity', {
                category = 'player_integrity',
                detector = 'synex.security.player_integrity.visibility',
                code = 'VISIBILITY_STATE_MISMATCH', severity = 'LOW',
                confidence = 0.32, evidenceClass = 'CLIENT_TELEMETRY',
                correlationKey = 'player-visibility',
                summary = 'Repeated advisory visibility state differed from the server expectation.',
                evidence = {
                    visible = sample.visible == true,
                    alpha = math.max(0, math.min(255, tonumber(sample.alpha) or 0)),
                    streak = state.invisibleStreak,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.visibility = emitted + 1,
                counters.visibility + 1 end
            state.invisibleStreak = 0
        end

        local expectedModel = tonumber(expectedState.model)
        local observedModel = tonumber(sample.model)
        state.modelStreak = playerIntegrityEnabled and expectedModel ~= nil
            and observedModel ~= expectedModel
            and state.modelStreak + 1 or 0
        if state.modelStreak >= 2 then
            local accepted = report(session, 'player_integrity', {
                category = 'player_integrity',
                detector = 'synex.security.player_integrity.model',
                code = 'PLAYER_MODEL_MISMATCH', severity = 'LOW', confidence = 0.38,
                evidenceClass = 'CLIENT_TELEMETRY', correlationKey = 'player-model',
                summary = 'Repeated advisory ped model state differed from the character expectation.',
                evidence = {
                    expectedModel = expectedModel % 4294967296,
                    observedModel = observedModel % 4294967296,
                    streak = state.modelStreak,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.model = emitted + 1, counters.model + 1 end
            state.modelStreak = 0
        end

        local maximumHealth = tonumber(expectedState.maximumHealth)
        state.healthStreak = playerIntegrityEnabled and maximumHealth ~= nil
            and sample.health > maximumHealth
            and state.healthStreak + 1 or 0
        if state.healthStreak >= 2 then
            local accepted = report(session, 'player_integrity', {
                category = 'player_integrity',
                detector = 'synex.security.player_integrity.health',
                code = 'PLAYER_HEALTH_LIMIT_MISMATCH', severity = 'LOW', confidence = 0.36,
                evidenceClass = 'CLIENT_TELEMETRY', correlationKey = 'player-health',
                summary = 'Repeated advisory health exceeded an explicit server-owned health limit.',
                evidence = {
                    expectedMaximum = maximumHealth,
                    observed = sample.health,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.health = emitted + 1, counters.health + 1 end
            state.healthStreak = 0
        end

        local maximumArmor = tonumber(expectedState.maximumArmor)
        state.armorStreak = playerIntegrityEnabled and maximumArmor ~= nil
            and sample.armor > maximumArmor
            and state.armorStreak + 1 or 0
        if state.armorStreak >= 2 then
            local accepted = report(session, 'player_integrity', {
                category = 'player_integrity',
                detector = 'synex.security.player_integrity.armor',
                code = 'PLAYER_ARMOR_LIMIT_MISMATCH', severity = 'LOW', confidence = 0.36,
                evidenceClass = 'CLIENT_TELEMETRY', correlationKey = 'player-armor',
                summary = 'Repeated advisory armor exceeded an explicit server-owned armor limit.',
                evidence = {
                    expectedMaximum = maximumArmor,
                    observed = sample.armor,
                    advisoryOnly = true,
                },
            })
            if accepted then emitted, counters.armor = emitted + 1, counters.armor + 1 end
            state.armorStreak = 0
        end

        if weaponIntegrityEnabled and isWeaponAuthorized ~= nil then
            local ok, allowed = pcall(isWeaponAuthorized, session, sample.weapon)
            state.weaponStreak = ok and allowed == false and state.weaponStreak + 1 or 0
            if state.weaponStreak >= 2 then
                local accepted = report(session, 'weapon_integrity', {
                    category = 'weapon',
                    detector = 'synex.security.weapon.integrity',
                    code = 'WEAPON_STATE_UNAUTHORIZED', severity = 'LOW', confidence = 0.40,
                    evidenceClass = 'CLIENT_TELEMETRY', correlationKey = 'weapon-state',
                    summary = 'Repeated advisory weapon state was explicitly denied by the weapon authority.',
                    evidence = { weapon = sample.weapon, advisoryOnly = true },
                })
                if accepted then emitted, counters.weapon = emitted + 1,
                    counters.weapon + 1 end
                state.weaponStreak = 0
            end
        end

        if playerIntegrityEnabled then
        for damageClass, observation in pairs(state.damageObservations) do
            if timestamp - observation.lastAt > 15000 then
                state.damageObservations[damageClass] = nil
            elseif observation.count >= 3 and expectedState.invulnerable ~= true
                and sample.health + sample.armor
                    >= observation.baselineHealth + observation.baselineArmor then
                local accepted = report(session, 'player_integrity', {
                    category = 'player_integrity',
                    detector = 'synex.security.player_integrity.damage',
                    code = 'PLAYER_DAMAGE_IMMUNITY_PATTERN', severity = 'MEDIUM',
                    confidence = 0.48, evidenceClass = 'BEHAVIORAL_HEURISTIC',
                    correlationKey = 'damage-immunity-' .. damageClass,
                    summary = 'Independent damage observations and advisory health formed an immunity pattern.',
                    evidence = {
                        damageClass = damageClass,
                        observations = observation.count,
                        baselineHealth = observation.baselineHealth,
                        baselineArmor = observation.baselineArmor,
                        observedHealth = sample.health,
                        observedArmor = sample.armor,
                        mixedEvidence = true,
                    },
                })
                if accepted then emitted, counters.damageImmunity = emitted + 1,
                    counters.damageImmunity + 1 end
                state.damageObservations[damageClass] = nil
            end
        end
        end

        state.lastHealth, state.lastArmor = sample.health, sample.armor
        if movementEnabled and movement ~= nil
            and Validation.isCallable(movement.observe) then
            pcall(movement.observe, session, sample, meta)
        end
        return { accepted = true, signals = emitted }, nil
    end

    function api.observeDamageTaken(session, descriptor)
        if modes.player_integrity == 'DISABLED' then
            return { accepted = true, disabled = true }, nil
        end
        if not validSession(session) or type(descriptor) ~= 'table'
            or not Validation.semanticKey(descriptor.damageClass or '')
            or not Validation.isInteger(descriptor.observedAt or now(), 0,
                Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_DETECTOR_INVALID',
                'Damage observation is invalid.')
        end
        local timestamp = descriptor.observedAt or now()
        local state = getState(session, timestamp)
        if state == nil then
            return Validation.failure('SECURITY_SUBJECT_STALE',
                'Damage observation refers to a reused source.')
        end
        local baselineHealth = tonumber(descriptor.baselineHealth)
            or state.lastHealth
        local baselineArmor = tonumber(descriptor.baselineArmor)
            or state.lastArmor
        if not Validation.isInteger(baselineHealth, 0, 1000)
            or not Validation.isInteger(baselineArmor, 0, 1000) then
            return { accepted = true, tracked = false,
                reason = 'baseline_unavailable' }, nil
        end
        local damageClass = descriptor.damageClass
        local observation = state.damageObservations[damageClass]
        if observation == nil or timestamp - observation.lastAt > 15000 then
            observation = {
                count = 0,
                lastAt = timestamp,
                baselineHealth = baselineHealth,
                baselineArmor = baselineArmor,
            }
            state.damageObservations[damageClass] = observation
        end
        observation.count = math.min(16, observation.count + 1)
        observation.lastAt = timestamp
        return { accepted = true, count = observation.count }, nil
    end

    function api.observeDamage(session, data, meta)
        if modes.weapon_integrity == 'DISABLED' then
            return { accepted = true, disabled = true }, nil
        end
        if not validSession(session) or type(data) ~= 'table' then
            return Validation.failure('SECURITY_DETECTOR_INVALID',
                'Weapon damage observation is invalid.')
        end
        local rootEventId = type(meta) == 'table' and meta.rootEventId or nil
        if isWeaponAuthorized ~= nil and Validation.isInteger(data.weaponType, 0, 4294967295) then
            local ok, allowed = pcall(isWeaponAuthorized, session, data.weaponType)
            if ok and allowed == false then
                local accepted = report(session, 'weapon_integrity', {
                    category = 'weapon', detector = 'synex.security.weapon.damage',
                    code = 'WEAPON_DAMAGE_UNAUTHORIZED', severity = 'MEDIUM',
                    confidence = 0.78, evidenceClass = 'CFX_SERVER_EVENT',
                    correlationKey = 'weapon-damage', rootEventId = rootEventId,
                    summary = 'A server-observed damage event used a weapon explicitly denied by weapon authority.',
                    evidence = { weapon = data.weaponType, willKill = data.willKill == true },
                })
                if accepted then counters.weapon = counters.weapon + 1 end
            end
        end
        if validateDamage ~= nil then
            local ok, valid, reason = pcall(validateDamage, session, data)
            if ok and valid == false then
                local accepted = report(session, 'weapon_integrity', {
                    category = 'combat', detector = 'synex.security.combat.damage',
                    code = 'COMBAT_DAMAGE_POLICY_MISMATCH', severity = 'MEDIUM',
                    confidence = 0.80, evidenceClass = 'SERVER_DERIVED',
                    correlationKey = 'combat-damage-policy', rootEventId = rootEventId,
                    summary = 'A server-observed damage event violated an explicit domain damage policy.',
                    evidence = { reason = Validation.text(reason, 1, 128)
                        and reason or 'domain_policy_rejected' },
                })
                if accepted then counters.combat = counters.combat + 1 end
            end
        end
        return true, nil
    end

    function api.observeCombat(session, descriptor)
        if modes.combat_analytics == 'DISABLED' then
            return { accepted = true, disabled = true }, nil
        end
        if not validSession(session) or type(descriptor) ~= 'table' then
            return Validation.failure('SECURITY_DETECTOR_INVALID',
                'Combat behavior observation is invalid.')
        end
        local timestamp = now()
        local state = getState(session, timestamp)
        if state == nil then
            return Validation.failure('SECURITY_SUBJECT_STALE',
                'Combat behavior observation refers to a reused source.')
        end
        local combat = state.combat
        combat.samples = math.min(128, combat.samples + 1)
        for _, name in ipairs({ 'impossibleReaction', 'trajectoryMismatch',
            'targetMismatch' }) do
            if descriptor[name] == true then combat.anomalyTypes[name] = true end
        end
        local independent = 0
        for _ in pairs(combat.anomalyTypes) do independent = independent + 1 end
        if combat.samples >= 4 and independent >= 2
            and (combat.lastSignalAt == 0
                or timestamp - combat.lastSignalAt >= 30000) then
            local accepted = report(session, 'combat_analytics', {
                category = 'combat', detector = 'synex.security.combat.analytics',
                code = 'COMBAT_BEHAVIOR_CORRELATION', severity = 'LOW', confidence = 0.38,
                evidenceClass = 'BEHAVIORAL_HEURISTIC', correlationKey = 'combat-behavior',
                summary = 'Multiple server-derived combat anomaly classes formed an observe-only pattern.',
                evidence = {
                    samples = combat.samples,
                    independentAnomalyClasses = independent,
                    headshotRateAloneIgnored = true,
                    advisoryOnly = true,
                },
            })
            combat.lastSignalAt = timestamp
            combat.samples, combat.anomalyTypes = 0, {}
            if accepted then counters.combat = counters.combat + 1 end
        end
        return { accepted = true, independentAnomalyClasses = independent }, nil
    end

    function api.cleanupSource(source, sourceGeneration)
        local removed = 0
        for key in pairs(states) do
            local keySource, keyGeneration = key:match('^(%d+):(%d+)$')
            if tonumber(keySource) == source
                and (sourceGeneration == nil or tonumber(keyGeneration) == sourceGeneration) then
                remove(key)
                removed = removed + 1
            end
        end
        if movement ~= nil and Validation.isCallable(movement.cleanupSource) then
            pcall(movement.cleanupSource, source, sourceGeneration)
        end
        return removed
    end

    function api.prune(at)
        local timestamp, keys = at or now(), {}
        for key, state in pairs(states) do
            if timestamp - state.updatedAt >= retentionMs then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do remove(key) end
        if movement ~= nil and Validation.isCallable(movement.prune) then
            pcall(movement.prune, timestamp)
        end
        return #keys
    end

    function api.list()
        local result = {}
        for name in pairs(DEFAULT_MODES) do
            result[#result + 1] = {
                name = name,
                mode = modes[name],
                health = 'READY',
                heuristic = name == 'movement' or name == 'combat_analytics'
                    or name == 'player_integrity' or name == 'weapon_integrity',
            }
        end
        table.sort(result, function(left, right) return left.name < right.name end)
        return result
    end

    function api.snapshot()
        return {
            subjects = count,
            capacity = capacity,
            emitted = counters.emitted,
            expected = counters.expected,
            visibility = counters.visibility,
            model = counters.model,
            health = counters.health,
            armor = counters.armor,
            damageImmunity = counters.damageImmunity,
            weapon = counters.weapon,
            combat = counters.combat,
            filtered = counters.filtered,
            evicted = counters.evicted,
            modes = api.list(),
        }
    end

    return api
end
