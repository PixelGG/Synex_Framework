SynexSecurityCfxGuards = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local CfxGuards = SynexSecurityCfxGuards

local EVENT_DEFINITIONS = {
    entityCreating = { detector = 'entity_guard', documented = true, cancelable = true },
    weaponDamageEvent = { detector = 'game_events', documented = true, cancelable = true },
    explosionEvent = { detector = 'game_events', documented = true, cancelable = true },
    startProjectileEvent = {
        detector = 'game_events', documented = false, artifactConfirmed = true,
        cancelable = 'live-gated',
    },
    ptFxEvent = { detector = 'game_events', documented = false,
        artifactConfirmed = true, cancelable = 'live-gated' },
}

local function safeCall(handler, fallback, ...)
    if not Validation.isCallable(handler) then return fallback end
    local ok, value = pcall(handler, ...)
    if not ok or value == nil then return fallback end
    return value
end

local function boundedNumber(value, minimum, maximum)
    if not Validation.isFinite(value) or value < minimum or value > maximum then return nil end
    return value
end

local function hashValue(value)
    if not Validation.isInteger(value, -2147483648, 4294967295) then return nil end
    return value % 4294967296
end

function CfxGuards.create(options)
    options = options or {}
    local now = assert(options.now, 'security Cfx guard clock is required')
    assert(Validation.isCallable(now), 'security Cfx guard clock is invalid')
    local ports = options.ports or {}
    assert(Validation.isCallable(ports.addEventHandler),
        'security Cfx event registration port is required')
    local emit = Validation.isCallable(options.emit) and options.emit or nil
    local matchExpectations = Validation.isCallable(options.matchExpectations)
        and options.matchExpectations or nil
    local resolveSession = Validation.isCallable(options.resolveSession)
        and options.resolveSession or nil
    local authorizeEntity = Validation.isCallable(options.authorizeEntity)
        and options.authorizeEntity or nil
    local detectors = type(options.detectors) == 'table' and options.detectors or nil
    local deniedModels = type(options.deniedModels) == 'table' and options.deniedModels or {}
    local deniedExplosions = type(options.deniedExplosions) == 'table'
        and options.deniedExplosions or {}
    local deniedProjectiles = type(options.deniedProjectiles) == 'table'
        and options.deniedProjectiles or {}
    local deniedPtFx = type(options.deniedPtFx) == 'table' and options.deniedPtFx or {}
    local supportsCancellation = type(options.supportsCancellation) == 'table'
        and options.supportsCancellation or {}
    local liveVerified = type(options.liveVerified) == 'table' and options.liveVerified or {}
    local handlers, windows, serial, installed = {}, {}, 0, false
    local counters = {
        observed = 0, signaled = 0, canceled = 0, expected = 0,
        malformed = 0, bursts = 0, entity = 0, damage = 0,
        explosion = 0, projectile = 0, ptfx = 0,
        canceledByEvent = {},
    }
    local api = {}

    local function mode(name)
        if Validation.isCallable(options.modeFor) then
            local resolved = safeCall(options.modeFor, nil, name)
            if Limits.detectorModes[resolved] then return resolved end
        end
        if detectors ~= nil and Validation.isCallable(detectors.mode) then
            local resolved = safeCall(detectors.mode, nil, name)
            if Limits.detectorModes[resolved] then return resolved end
        end
        return (name == 'entity_guard' or name == 'game_events')
            and 'MITIGATE' or 'OBSERVE'
    end

    local function canMitigate(name)
        local detectorMode = mode(name)
        return detectorMode == 'MITIGATE' or detectorMode == 'ENFORCE'
    end

    local function enabled(name)
        return mode(name) ~= 'DISABLED'
    end

    local function cancellationVerified(eventName)
        local definition = EVENT_DEFINITIONS[eventName]
        if type(definition) ~= 'table' then return false end
        if definition.cancelable == true then return true end
        return definition.cancelable == 'live-gated'
            and supportsCancellation[eventName] == true
            and liveVerified[eventName] == true
    end

    local function subjectForSource(source)
        if resolveSession ~= nil and Validation.isInteger(source, 1,
            Limits.maximumPlayerSource) then
            local session = safeCall(resolveSession, nil, source)
            if type(session) == 'table' and Validation.token(session.id, 3, 96)
                and Validation.isInteger(session.sourceGeneration, 1,
                    Limits.maximumSafeInteger) then
                local subject = {
                    sessionId = session.id,
                    source = session.source or source,
                    sourceGeneration = session.sourceGeneration,
                }
                if Validation.token(session.userId, 3, 96) then
                    subject.userId = session.userId
                end
                if Validation.token(session.characterId, 3, 96) then
                    subject.characterId = session.characterId
                end
                return subject, session
            end
        end
        return { resourceName = 'synex_security' }, nil
    end

    local function expectationMatches(subject, definition)
        if matchExpectations == nil then return false end
        local ok, matches = pcall(matchExpectations, {
            subjectSession = subject.sessionId,
            subjectSource = subject.source,
            sourceGeneration = subject.sourceGeneration,
            subjectUser = subject.userId,
            subjectCharacter = subject.characterId,
            subjectResource = subject.resourceName,
            category = definition.category,
            detector = definition.detector,
            code = definition.code,
            correlationKey = definition.correlationKey,
            evidenceClass = definition.evidenceClass,
            severity = definition.severity,
            worldRef = definition.worldRef,
            entityRef = definition.entityRef,
        })
        return ok and type(matches) == 'table' and #matches > 0
    end

    local function report(source, definition)
        local subject = definition.subject or select(1, subjectForSource(source))
        if expectationMatches(subject, definition) then
            counters.expected = counters.expected + 1
            return false, 'expected', subject
        end
        if emit ~= nil then
            pcall(emit, {
                namespace = 'synex.security',
                category = definition.category,
                detector = definition.detector,
                code = definition.code,
                subject = subject,
                severity = definition.severity,
                confidence = definition.confidence,
                evidenceClass = definition.evidenceClass,
                correlationKey = definition.correlationKey,
                rootEventId = definition.rootEventId,
                worldRef = definition.worldRef,
                entityRef = definition.entityRef,
                summary = definition.summary,
                evidence = definition.evidence,
            })
        end
        counters.signaled = counters.signaled + 1
        return true, nil, subject
    end

    local function cancel(modeName, eventName)
        if not canMitigate(modeName) or not cancellationVerified(eventName)
            or not Validation.isCallable(ports.cancelEvent) then
            return false
        end
        local ok = pcall(ports.cancelEvent)
        if ok then
            counters.canceled = counters.canceled + 1
            counters.canceledByEvent[eventName] =
                (counters.canceledByEvent[eventName] or 0) + 1
        end
        return ok
    end

    local function rootEventId(eventName, source)
        serial = serial + 1
        return ('cfx:%s:%d:%d'):format(eventName,
            Validation.isInteger(source, 0, Limits.maximumPlayerSource) and source or 0,
            serial)
    end

    local function rate(eventName, source, windowMs, limit)
        local timestamp = now()
        local key = eventName .. ':' .. tostring(source)
        local values = windows[key] or {}
        local first = 1
        while first <= #values and timestamp - values[first] > windowMs do first = first + 1 end
        if first > 1 then
            local compacted = {}
            for index = first, #values do compacted[#compacted + 1] = values[index] end
            values = compacted
        end
        values[#values + 1] = timestamp
        if #values > limit + 4 then table.remove(values, 1) end
        windows[key] = values
        return #values, #values > limit
    end

    local function configured(set, value)
        return set[value] == true or set[tostring(value)] == true
    end

    local function entityHandler(entity)
        if not enabled('entity_guard') then return end
        counters.observed, counters.entity = counters.observed + 1, counters.entity + 1
        local creator = tonumber(safeCall(ports.getEntityOwner, 0, entity)) or 0
        local model = hashValue(tonumber(safeCall(ports.getEntityModel, 0, entity))) or 0
        local entityType = tonumber(safeCall(ports.getEntityType, 0, entity)) or 0
        local bucket = tonumber(safeCall(ports.getEntityBucket, 0, entity)) or 0
        -- Cfx reports server-created entities with creator 0 and does not expose
        -- the originating resource here. A global creator-0 quota would let one
        -- server resource cancel unrelated authoritative spawns, so burst policy
        -- is applied only to attributable player creators.
        local countInWindow, burst = 0, false
        if creator > 0 then
            countInWindow, burst = rate('entityCreating', creator, 2000,
                tonumber(options.entityBurstLimit) or 18)
        end
        local authority = nil
        if authorizeEntity ~= nil then
            authority = safeCall(authorizeEntity, nil, {
                entity = entity,
                creator = creator,
                model = model,
                entityType = entityType,
                bucket = bucket,
            })
        end
        if type(authority) ~= 'table' then
            authority = { allowed = authority ~= false, policy = 'legacy_allowed',
                deterministic = authority == false }
        end
        local policy = authority.policy
        if policy ~= 'managed' and policy ~= 'legacy_allowed' and policy ~= 'strict' then
            policy = 'legacy_allowed'
        end
        local deniedModel = configured(deniedModels, model)
        local wrongBucket = Validation.isInteger(authority.expectedBucket, 0, 2147483647)
            and authority.expectedBucket ~= bucket
        local unauthorized = authority.allowed == false and authority.deterministic == true
        local burstViolation = burst and (policy == 'strict' or policy == 'managed')
        if not deniedModel and not wrongBucket and not unauthorized and not burstViolation then
            return
        end
        local code = deniedModel and 'ENTITY_MODEL_DENIED'
            or wrongBucket and 'ENTITY_BUCKET_VIOLATION'
            or unauthorized and 'ENTITY_UNAUTHORIZED_CREATE'
            or 'ENTITY_SPAWN_BURST'
        if burstViolation then counters.bursts = counters.bursts + 1 end
        local accepted, why = report(creator, {
            category = 'entity', detector = 'synex.security.entity_guard',
            code = code,
            severity = (deniedModel or unauthorized) and 'HIGH' or 'MEDIUM',
            confidence = (deniedModel or unauthorized) and 0.95 or 0.82,
            evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'entity-create',
            rootEventId = rootEventId('entityCreating', creator),
            worldRef = { bucket = bucket },
            entityRef = { handle = tonumber(entity) or 0, model = model,
                entityType = entityType },
            summary = 'A server-observed entity creation violated a deterministic spawn guard policy.',
            evidence = {
                creator = creator,
                model = model % 4294967296,
                entityType = entityType,
                bucket = bucket,
                policy = policy,
                windowCount = countInWindow,
                deterministic = deniedModel or wrongBucket or unauthorized,
                authorityResource = Validation.resourceName(authority.authorityResource)
                    and authority.authorityResource or nil,
                provenanceMatched = authority.provenanceMatched == true,
            },
        })
        if accepted and why == nil and (deniedModel or wrongBucket or unauthorized
            or burstViolation and options.entityBurstMitigation == true) then
            cancel('entity_guard', 'entityCreating')
        end
    end

    local function malformedGameEvent(eventName, sender)
        counters.malformed = counters.malformed + 1
        report(sender, {
            category = 'combat', detector = 'synex.security.game_events',
            code = 'CFX_GAME_EVENT_INVALID', severity = 'MEDIUM', confidence = 0.92,
            evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'game-event-invalid',
            rootEventId = rootEventId(eventName, sender),
            summary = 'A Cfx game event had an invalid server-side envelope.',
            evidence = { event = eventName },
        })
        cancel('game_events', eventName)
    end

    local function weaponDamageHandler(sender, data)
        if not enabled('game_events') then return end
        counters.observed, counters.damage = counters.observed + 1, counters.damage + 1
        if not Validation.isInteger(sender, 1, Limits.maximumPlayerSource)
            or type(data) ~= 'table' then
            malformedGameEvent('weaponDamageEvent', tonumber(sender) or 0)
            return
        end
        local countInWindow, burst = rate('weaponDamageEvent', sender, 2000,
            tonumber(options.damageBurstLimit) or 120)
        local weaponType = hashValue(data.weaponType)
        local sanitized = {
            weaponType = weaponType,
            damageType = boundedNumber(data.damageType, 0, 255),
            hitGlobalId = boundedNumber(data.hitGlobalId, 0, 2147483647),
            willKill = data.willKill == true,
        }
        local eventRoot = rootEventId('weaponDamageEvent', sender)
        if detectors ~= nil and Validation.isCallable(detectors.observeDamage) then
            local _, session = subjectForSource(sender)
            if session ~= nil then
                pcall(detectors.observeDamage, session, sanitized, {
                    rootEventId = eventRoot,
                })
            end
        end
        if detectors ~= nil and Validation.isCallable(detectors.observeDamageTaken)
            and Validation.isInteger(sanitized.hitGlobalId, 1, 2147483647)
            and Validation.isCallable(ports.getEntityFromNetworkId) then
            local target = safeCall(ports.getEntityFromNetworkId, 0,
                sanitized.hitGlobalId)
            local victimSource = tonumber(safeCall(ports.getEntityOwner, 0, target)) or 0
            local playerPed = Validation.isCallable(ports.getPlayerPed)
                and safeCall(ports.getPlayerPed, 0, victimSource) or 0
            if target ~= 0 and target == playerPed then
                local _, victimSession = subjectForSource(victimSource)
                if victimSession ~= nil then
                    local damageClass = ('damage_type_%d'):format(
                        sanitized.damageType or 0)
                    pcall(detectors.observeDamageTaken, victimSession, {
                        damageClass = damageClass,
                        observedAt = now(),
                        rootEventId = eventRoot,
                    })
                end
            end
        end
        if burst then
            counters.bursts = counters.bursts + 1
            local accepted = report(sender, {
                category = 'combat', detector = 'synex.security.game_events.damage',
                code = 'WEAPON_DAMAGE_EVENT_BURST', severity = 'MEDIUM', confidence = 0.86,
                evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'damage-event-burst',
                rootEventId = eventRoot,
                summary = 'Weapon damage event volume exceeded the bounded server event window.',
                evidence = { windowMs = 2000, count = countInWindow,
                    weaponType = weaponType },
            })
            if accepted and options.damageBurstMitigation == true then
                cancel('game_events', 'weaponDamageEvent')
            end
        end
    end

    local function explosionHandler(sender, data)
        if not enabled('game_events') then return end
        counters.observed, counters.explosion = counters.observed + 1,
            counters.explosion + 1
        if not Validation.isInteger(sender, 1, Limits.maximumPlayerSource)
            or type(data) ~= 'table'
            or not Validation.isInteger(data.explosionType, 0, 255) then
            malformedGameEvent('explosionEvent', tonumber(sender) or 0)
            return
        end
        local countInWindow, burst = rate('explosionEvent', sender, 2500,
            tonumber(options.explosionBurstLimit) or 18)
        local denied = configured(deniedExplosions, data.explosionType)
        if not denied and not burst then return end
        if burst then counters.bursts = counters.bursts + 1 end
        local accepted = report(sender, {
            category = 'combat', detector = 'synex.security.game_events.explosion',
            code = denied and 'EXPLOSION_TYPE_DENIED' or 'EXPLOSION_EVENT_BURST',
            severity = denied and 'HIGH' or 'MEDIUM',
            confidence = denied and 0.96 or 0.84,
            evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'explosion-event',
            rootEventId = rootEventId('explosionEvent', sender),
            summary = denied
                and 'A server-observed explosion used an explicitly denied type.'
                or 'Explosion event volume exceeded the bounded server event window.',
            evidence = {
                explosionType = data.explosionType,
                windowMs = 2500,
                count = countInWindow,
                position = {
                    boundedNumber(data.posX, -20000, 20000) or 0,
                    boundedNumber(data.posY, -20000, 20000) or 0,
                    boundedNumber(data.posZ, -20000, 20000) or 0,
                },
            },
        })
        if accepted and (denied or options.explosionBurstMitigation == true) then
            cancel('game_events', 'explosionEvent')
        end
    end

    local function projectileHandler(sender, data)
        if not enabled('game_events') then return end
        counters.observed, counters.projectile = counters.observed + 1,
            counters.projectile + 1
        if not Validation.isInteger(sender, 1, Limits.maximumPlayerSource)
            or type(data) ~= 'table' then
            malformedGameEvent('startProjectileEvent', tonumber(sender) or 0)
            return
        end
        local projectile = hashValue(data.projectileHash)
        local countInWindow, burst = rate('startProjectileEvent', sender, 2000,
            tonumber(options.projectileBurstLimit) or 16)
        local denied = projectile ~= nil and configured(deniedProjectiles, projectile)
        if not denied and not burst then return end
        if burst then counters.bursts = counters.bursts + 1 end
        local accepted = report(sender, {
            category = 'weapon', detector = 'synex.security.game_events.projectile',
            code = denied and 'PROJECTILE_TYPE_DENIED' or 'PROJECTILE_EVENT_BURST',
            severity = denied and 'HIGH' or 'MEDIUM',
            confidence = denied and 0.94 or 0.82,
            evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'projectile-event',
            rootEventId = rootEventId('startProjectileEvent', sender),
            summary = denied
                and 'A server-observed projectile used an explicitly denied type.'
                or 'Projectile event volume exceeded the bounded server event window.',
            evidence = { projectile = projectile or 0, windowMs = 2000,
                count = countInWindow, cancellationLiveGated = true },
        })
        if accepted and cancellationVerified('startProjectileEvent')
            and (denied or options.projectileBurstMitigation == true) then
            cancel('game_events', 'startProjectileEvent')
        end
    end

    local function ptFxHandler(sender, data)
        if not enabled('game_events') then return end
        counters.observed, counters.ptfx = counters.observed + 1, counters.ptfx + 1
        if not Validation.isInteger(sender, 1, Limits.maximumPlayerSource)
            or type(data) ~= 'table' then
            malformedGameEvent('ptFxEvent', tonumber(sender) or 0)
            return
        end
        local effect = hashValue(data.effectHash)
        local countInWindow, burst = rate('ptFxEvent', sender, 2000,
            tonumber(options.ptFxBurstLimit) or 40)
        local denied = effect ~= nil and configured(deniedPtFx, effect)
        if not denied and not burst then return end
        if burst then counters.bursts = counters.bursts + 1 end
        local accepted = report(sender, {
            category = 'world', detector = 'synex.security.game_events.ptfx',
            code = denied and 'PTFX_TYPE_DENIED' or 'PTFX_EVENT_BURST',
            severity = denied and 'MEDIUM' or 'LOW',
            confidence = denied and 0.92 or 0.78,
            evidenceClass = 'CFX_SERVER_EVENT', correlationKey = 'ptfx-event',
            rootEventId = rootEventId('ptFxEvent', sender),
            summary = denied
                and 'A server-observed particle effect used an explicitly denied type.'
                or 'Particle effect event volume exceeded the bounded server event window.',
            evidence = { effect = effect or 0, windowMs = 2000,
                count = countInWindow, cancellationLiveGated = true },
        })
        if accepted and cancellationVerified('ptFxEvent')
            and (denied or options.ptFxBurstMitigation == true) then
            cancel('game_events', 'ptFxEvent')
        end
    end

    function api.install()
        if installed then return true, nil end
        local callbacks = {
            entityCreating = entityHandler,
            weaponDamageEvent = weaponDamageHandler,
            explosionEvent = explosionHandler,
            startProjectileEvent = projectileHandler,
            ptFxEvent = ptFxHandler,
        }
        for eventName, handler in pairs(callbacks) do
            local ok, token = pcall(ports.addEventHandler, eventName, handler)
            if not ok then
                api.uninstall()
                return Validation.failure('SECURITY_CFX_HOOK_FAILED',
                    'A required Cfx security event hook could not be installed.', true,
                    { event = eventName })
            end
            handlers[eventName] = token == nil and true or token
        end
        installed = true
        return true, nil
    end

    function api.uninstall()
        if Validation.isCallable(ports.removeEventHandler) then
            for _, token in pairs(handlers) do
                if token ~= true then pcall(ports.removeEventHandler, token) end
            end
        end
        handlers, installed = {}, false
        return true
    end

    function api.cleanupSource(source)
        local suffix = ':' .. tostring(source)
        for key in pairs(windows) do
            if key:sub(-#suffix) == suffix then windows[key] = nil end
        end
        return true
    end

    function api.snapshot()
        local hooks = {}
        for eventName, definition in pairs(EVENT_DEFINITIONS) do
            hooks[#hooks + 1] = {
                event = eventName,
                installed = handlers[eventName] ~= nil,
                documented = definition.documented,
                artifactConfirmed = definition.artifactConfirmed == true,
                cancelable = definition.cancelable,
                cancellationEnabled = cancellationVerified(eventName),
                liveVerified = definition.cancelable == true
                    or liveVerified[eventName] == true,
            }
        end
        table.sort(hooks, function(left, right) return left.event < right.event end)
        local canceledByEvent = {}
        for eventName, count in pairs(counters.canceledByEvent) do
            canceledByEvent[eventName] = count
        end
        return {
            installed = installed,
            hooks = hooks,
            observed = counters.observed,
            signaled = counters.signaled,
            canceled = counters.canceled,
            expected = counters.expected,
            malformed = counters.malformed,
            bursts = counters.bursts,
            entity = counters.entity,
            damage = counters.damage,
            explosion = counters.explosion,
            projectile = counters.projectile,
            ptfx = counters.ptfx,
            canceledByEvent = canceledByEvent,
        }
    end

    return api
end
