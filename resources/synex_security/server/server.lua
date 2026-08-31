local RESOURCE_NAME = GetCurrentResourceName()
local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'

local TIMER_MODULUS = 4294967296
local previousTimer, timerEpoch, lastNow = nil, 0, 0
local function now()
    local raw = math.floor(tonumber(GetGameTimer()) or 0) % TIMER_MODULUS
    if previousTimer ~= nil and raw < previousTimer
        and previousTimer - raw > TIMER_MODULUS / 2 then
        timerEpoch = timerEpoch + TIMER_MODULUS
    end
    previousTimer = raw
    local value = timerEpoch + raw
    if value < lastNow then value = lastNow end
    lastNow = value
    return value
end

local function utc()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function sqlTimestamp(value)
    if not SynexSecurityValidation.text(value, 20, 32) then return nil end
    local normalized = value:gsub('T', ' '):gsub('Z$', '')
    return normalized:sub(1, 23)
end

local function readConfiguration()
    local raw = LoadResourceFile(RESOURCE_NAME, 'config/default.json')
    if not SynexSecurityValidation.text(raw, 2, 32768) then
        error('synex_security configuration is unavailable', 0)
    end
    local decoded, candidate = pcall(json.decode, raw)
    if not decoded or type(candidate) ~= 'table' then
        error('synex_security configuration is invalid', 0)
    end
    local copied, copyError = SynexSecurityValidation.copy(candidate, {
        maximumBytes = 32768,
        maximumDepth = 8,
        maximumEntries = 128,
        maximumStringBytes = 128,
    })
    if not copied then
        error(type(copyError) == 'table' and copyError.message
            or 'synex_security configuration is unbounded', 0)
    end
    local allowed = {
        schemaVersion = true, profile = true, retentionDays = true,
        closedCaseRetentionDays = true, sentinelIntervalMs = true,
        detectors = true, enforcement = true, cfxPolicy = true,
    }
    if not SynexSecurityValidation.exactObject(copied, allowed, allowed)
        or copied.schemaVersion ~= 1
        or copied.profile ~= 'conservative'
            and copied.profile ~= 'balanced'
            and copied.profile ~= 'strict'
            and copied.profile ~= 'development'
        or not SynexSecurityValidation.isInteger(copied.retentionDays, 7, 3650)
        or not SynexSecurityValidation.isInteger(
            copied.closedCaseRetentionDays, 1, copied.retentionDays)
        or not SynexSecurityValidation.isInteger(copied.sentinelIntervalMs, 1000, 30000)
        or type(copied.detectors) ~= 'table'
        or type(copied.cfxPolicy) ~= 'table'
        or type(copied.enforcement) ~= 'table' then
        error('synex_security configuration failed validation', 0)
    end
    local detectorNames = {
        transport = true, sentinel = true, player_integrity = true,
        movement = true, entity_guard = true, game_events = true,
        weapon_integrity = true, combat_analytics = true,
        domain_abuse = true,
    }
    if not SynexSecurityValidation.exactObject(
        copied.detectors, detectorNames, detectorNames) then
        error('synex_security detector configuration is invalid', 0)
    end
    local policyKeys = {
        deniedModels = true, deniedExplosions = true, deniedProjectiles = true,
        deniedPtFx = true, burstMitigation = true, cancellation = true,
    }
    local burstKeys = { entity = true, damage = true, explosion = true,
        projectile = true, ptFx = true }
    local cancellationKeys = { startProjectileEvent = true, ptFxEvent = true }
    local gateKeys = { supported = true, liveVerified = true }
    if not SynexSecurityValidation.exactObject(copied.cfxPolicy, policyKeys, policyKeys)
        or not SynexSecurityValidation.exactObject(
            copied.cfxPolicy.burstMitigation, burstKeys, burstKeys)
        or not SynexSecurityValidation.exactObject(
            copied.cfxPolicy.cancellation, cancellationKeys, cancellationKeys) then
        error('synex_security Cfx policy is invalid', 0)
    end
    for key in pairs(burstKeys) do
        if type(copied.cfxPolicy.burstMitigation[key]) ~= 'boolean' then
            error('synex_security Cfx burst policy is invalid', 0)
        end
    end
    for key in pairs(cancellationKeys) do
        local gate = copied.cfxPolicy.cancellation[key]
        if not SynexSecurityValidation.exactObject(gate, gateKeys, gateKeys)
            or type(gate.supported) ~= 'boolean'
            or type(gate.liveVerified) ~= 'boolean' then
            error('synex_security Cfx cancellation policy is invalid', 0)
        end
    end
    local function validateSet(name, minimum, maximum)
        local values, seen = copied.cfxPolicy[name], {}
        if type(values) ~= 'table' or getmetatable(values) ~= nil or #values > 128 then
            error('synex_security Cfx deny policy is invalid', 0)
        end
        for index = 1, #values do
            local value = values[index]
            if not SynexSecurityValidation.isInteger(value, minimum, maximum)
                or seen[tostring(value)] then
                error('synex_security Cfx deny policy is invalid', 0)
            end
            seen[tostring(value)] = true
        end
        for key in pairs(values) do
            if not SynexSecurityValidation.isInteger(key, 1, #values) then
                error('synex_security Cfx deny policy is invalid', 0)
            end
        end
        local set = {}
        for _, value in ipairs(values) do set[value % 4294967296] = true end
        copied.cfxPolicy[name] = set
    end
    validateSet('deniedModels', -2147483648, 4294967295)
    validateSet('deniedExplosions', 0, 255)
    validateSet('deniedProjectiles', -2147483648, 4294967295)
    validateSet('deniedPtFx', -2147483648, 4294967295)
    for name, mode in pairs(copied.detectors) do
        if not detectorNames[name] or not SynexSecurityLimits.detectorModes[mode] then
            error('synex_security detector mode is invalid', 0)
        end
    end
    local enforcementKeys = {
        automaticKick = true, automaticBan = true,
        minimumKickEvidenceClasses = true,
        minimumBanEvidenceClasses = true,
    }
    if not SynexSecurityValidation.exactObject(
        copied.enforcement, enforcementKeys, enforcementKeys)
        or type(copied.enforcement.automaticKick) ~= 'boolean'
        or type(copied.enforcement.automaticBan) ~= 'boolean'
        or not SynexSecurityValidation.isInteger(
            copied.enforcement.minimumKickEvidenceClasses, 2, 8)
        or not SynexSecurityValidation.isInteger(
            copied.enforcement.minimumBanEvidenceClasses, 2, 8) then
        error('synex_security enforcement configuration is invalid', 0)
    end
    if copied.profile == 'development' then
        for detector in pairs(copied.detectors) do copied.detectors[detector] = 'OBSERVE' end
        copied.enforcement.automaticKick = false
        copied.enforcement.automaticBan = false
    end
    return copied
end

local config = readConfiguration()
local coreRef, ownerEpochs = {}, {}
local application

local function coreMethod(group, method, ...)
    local api = coreRef.value
    local namespace = type(api) == 'table' and api[group] or nil
    local handler = type(namespace) == 'table' and namespace[method] or nil
    if not SynexSecurityValidation.isCallable(handler) then
        return SynexSecurityValidation.failure('SECURITY_UNAVAILABLE',
            'Synex Core is unavailable.', true)
    end
    return handler(...)
end

local function nextId(namespace)
    local normalized = tostring(namespace or 'security')
        :lower():gsub('[^a-z0-9_]', '_'):sub(1, 32)
    if not normalized:match('^[a-z]') then normalized = 'security_' .. normalized end
    return coreMethod('Ids', 'next', normalized:sub(1, 32))
end

local function currentSession(source)
    if not SynexSecurityValidation.isInteger(
        source, 1, SynexSecurityLimits.maximumPlayerSource) then return nil end
    local session = coreMethod('Players', 'getBySource', source)
    if type(session) ~= 'table' or session.state ~= 'ACTIVE'
        or not SynexSecurityValidation.token(session.id, 3, 96)
        or session.source ~= source
        or not SynexSecurityValidation.isInteger(session.sourceGeneration, 1,
            SynexSecurityLimits.maximumSafeInteger) then return nil end
    return session
end

local function sessionCurrent(sessionId, sourceGeneration, subject)
    if not SynexSecurityValidation.token(sessionId, 3, 96)
        or not SynexSecurityValidation.isInteger(sourceGeneration, 1,
            SynexSecurityLimits.maximumSafeInteger)
        or type(subject) ~= 'table'
        or not SynexSecurityValidation.isInteger(subject.source, 1,
            SynexSecurityLimits.maximumPlayerSource) then return false end
    local session = currentSession(subject.source)
    return type(session) == 'table' and session.id == sessionId
        and session.sourceGeneration == sourceGeneration
        and (subject.userId == nil or subject.userId == session.userId)
        and (subject.characterId == nil or subject.characterId == session.characterId)
end

local function ownerCurrent(owner, epoch)
    if owner == RESOURCE_NAME then
        return type(coreRef.value) == 'table'
            and coreRef.value.ownerEpoch == epoch
            and GetResourceState(RESOURCE_NAME) == 'started'
    end
    return application ~= nil and application.ownerCurrent(owner, epoch) == true
end

local database = SynexSecurityDatabase.create({ coreRef = coreRef })
local repository = SynexSecurityRepository.create({
    database = database,
    encode = json.encode,
    decode = json.decode,
})

local observability = SynexSecurityObservability.create({
    coreRef = coreRef,
    now = now,
    ringFactory = function(capacity)
        return SynexSecurityRingBuffer.create({ capacity = capacity, now = now })
    end,
})

local persistence = {
    state = 'STARTING', failures = 0, lastCode = nil,
    consecutiveFailures = 0, restored = false, lastRetentionAt = 0,
    quarantinedEnforcements = 0, indeterminateEnforcements = 0,
}

local function persistenceFailure(operationError, fallback)
    persistence.state = 'DEGRADED'
    persistence.failures = math.min(SynexSecurityLimits.maximumSafeInteger,
        persistence.failures + 1)
    persistence.consecutiveFailures = math.min(
        SynexSecurityLimits.maximumSafeInteger,
        persistence.consecutiveFailures + 1)
    persistence.lastCode = type(operationError) == 'table'
        and operationError.code or fallback
    observability.finding('HIGH', 'SECURITY_CASE_PERSISTENCE_FAILED',
        'Security case persistence is degraded.', { scope = 'persistence' })
end

local function persistenceSuccess()
    if persistence.restored then
        persistence.state = 'READY'
        persistence.lastCode = nil
        persistence.consecutiveFailures = 0
    end
end

local expectations = SynexSecurityExpectations.create({
    now = now,
    nextId = nextId,
    isOwnerCurrent = ownerCurrent,
})

local processSignal
local signalPipelineFailures, signalPipelineConsecutiveFailures = 0, 0
local lifecycleAuditFailures, lifecycleAuditConsecutiveFailures = 0, 0
local signals = SynexSecuritySignals.create({
    now = now,
    utcNow = utc,
    nextId = nextId,
    isOwnerCurrent = ownerCurrent,
    isSessionCurrent = sessionCurrent,
    onDuplicate = function()
        observability.increment('signals_deduplicated_total', {}, 1)
    end,
    onAccepted = function(signal)
        if processSignal == nil then return true end
        local ok, value, operationError = pcall(processSignal, signal)
        if not ok or value == nil or value == false then
            signalPipelineFailures = math.min(SynexSecurityLimits.maximumSafeInteger,
                signalPipelineFailures + 1)
            signalPipelineConsecutiveFailures = math.min(
                SynexSecurityLimits.maximumSafeInteger,
                signalPipelineConsecutiveFailures + 1)
            observability.finding('HIGH', 'SECURITY_SIGNAL_PIPELINE_FAILED',
                'A canonical signal failed during correlation or case processing.', {
                    detector = signal.detector,
                    scope = signal.category,
                    code = type(operationError) == 'table' and operationError.code or nil,
                })
            if type(operationError) == 'table' then return nil, operationError end
            return SynexSecurityValidation.failure('SECURITY_SIGNAL_PIPELINE_FAILED',
                'Signal pipeline processing failed.', true)
        end
        signalPipelineConsecutiveFailures = 0
        return true
    end,
})

local correlation = SynexSecurityCorrelation.create({
    now = now,
    expectations = expectations,
})

local function caseRecord(value)
    local subjectKind, subjectRef = 'resource', value.subjectResource
    if value.subjectUser ~= nil then subjectKind, subjectRef = 'user', value.subjectUser
    elseif value.subjectSession ~= nil then
        subjectKind, subjectRef = 'session', value.subjectSession
    elseif value.subjectCharacter ~= nil then
        subjectKind, subjectRef = 'character', value.subjectCharacter
    end
    return {
        caseId = value.caseId,
        subjectKind = subjectKind,
        subjectRef = subjectRef or RESOURCE_NAME,
        userId = value.subjectUser,
        sessionId = value.subjectSession,
        category = value.category,
        severity = value.severity,
        confidence = value.confidence,
        status = value.status,
        signalCount = value.signalSummary and value.signalSummary.count or 0,
        enforcementCount = value.enforcementSummary
            and value.enforcementSummary.count or 0,
        summary = value,
        openedAt = sqlTimestamp(value.openedAt),
        updatedAt = sqlTimestamp(value.updatedAt),
        closedAt = value.closedAt and sqlTimestamp(value.closedAt) or nil,
        revision = value.revision,
    }
end

local pendingCaseSignalBatches = {}
local pendingCaseEnforcementBatches = {}
local function coroutineKey()
    local thread = coroutine.running()
    return thread or 'main'
end

local cases = SynexSecurityCases.create({
    now = now,
    nowIso = function() return utc() end,
    nextId = nextId,
    saveCase = function(value)
        local key = coroutineKey()
        local signalBatch = pendingCaseSignalBatches[key]
        local enforcementBatch = pendingCaseEnforcementBatches[key]
        local stored, storeError
        if signalBatch ~= nil then
            stored, storeError = repository.saveCaseWithSignals(
                caseRecord(value), signalBatch)
        elseif enforcementBatch ~= nil then
            stored, storeError = repository.saveCaseWithEnforcement(
                caseRecord(value), enforcementBatch)
        else
            stored, storeError = repository.saveCase(caseRecord(value))
        end
        if not stored then persistenceFailure(storeError,
            'SECURITY_CASE_PERSISTENCE_FAILED')
        else persistenceSuccess() end
        return stored, storeError
    end,
})

local function activeSubject(caseValue)
    if not SynexSecurityValidation.isInteger(caseValue.subjectSource, 1,
        SynexSecurityLimits.maximumPlayerSource)
        or not SynexSecurityValidation.isInteger(caseValue.sourceGeneration, 1,
            SynexSecurityLimits.maximumSafeInteger) then return false end
    local session = currentSession(caseValue.subjectSource)
    return type(session) == 'table'
        and session.id == caseValue.subjectSession
        and session.sourceGeneration == caseValue.sourceGeneration
        and (caseValue.subjectUser == nil or session.userId == caseValue.subjectUser)
end

local enforcement
enforcement = SynexSecurityEnforcement.create({
    now = now,
    utcNow = function() return os.time() * 1000 end,
    nextId = nextId,
    accessBan = function(request) return coreMethod('Access', 'ban', request) end,
    validateSubject = function(caseValue) return activeSubject(caseValue) end,
    requireDurableDecisions = true,
    persistDecision = function(record)
        local stored, storeError = repository.reserveEnforcement(record)
        if not stored then
            persistenceFailure(storeError,
                'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED')
        else
            persistenceSuccess()
        end
        return stored, storeError
    end,
    handlers = {
        KICK = function(caseValue, decision)
            if not activeSubject(caseValue) then return false end
            DropPlayer(caseValue.subjectSource,
                ('Synex security case %s: %s'):format(
                    caseValue.caseId, decision.reason):sub(1, 256))
            return true
        end,
    },
    onApplied = function(record, caseValue)
        local enforcementRecord = {
            enforcementId = record.enforcementId,
            caseId = record.caseId,
            action = record.action,
            policy = record.policyId,
            idempotencyKey = record.idempotencyKey,
            outcome = 'APPLIED',
            summary = {
                caseRevision = record.caseRevision,
                reason = record.reason,
                expiresAt = record.expiresAt,
                provenanceDigest = record.provenanceDigest,
                decidedAtUtc = record.decidedAtUtc,
                appliedAtUtc = record.appliedAtUtc,
            },
        }
        local persistenceKey = coroutineKey()
        pendingCaseEnforcementBatches[persistenceKey] = enforcementRecord
        local updated, updateError = cases.attachEnforcement(record.caseId, record)
        pendingCaseEnforcementBatches[persistenceKey] = nil
        if not updated then
            persistenceFailure(updateError,
                'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED')
            return nil, updateError
        end
        persistenceSuccess()
        observability.increment('enforcements_total', {
            action = record.action:lower(),
        }, 1)
        if record.action == 'KICK' then
            observability.increment('kicks_total', {}, 1)
        elseif record.action == 'BAN' then
            observability.increment('bans_total', {}, 1)
        elseif record.action == 'CORRECT' or record.action == 'MITIGATE'
            or record.action == 'RESTRICT' then
            observability.increment('mitigations_total', {
                action = record.action:lower(),
            }, 1)
        end
        observability.audit('security.enforcement_applied', 'security_case',
            record.caseId, {
                action = record.action,
                policy = record.policyId,
                enforcementId = record.enforcementId,
            })
        observability.event('synex.security.enforcement.applied', {
            caseId = record.caseId,
            enforcementId = record.enforcementId,
            action = record.action,
            policy = record.policyId,
        })
        return true
    end,
})

local caseBySignal, signalOrder, signalOrderHead = {}, {}, 1
local function rememberSignalCase(signalId, caseId)
    if caseBySignal[signalId] == nil then
        signalOrder[#signalOrder + 1] = signalId
    end
    caseBySignal[signalId] = caseId
    while #signalOrder - signalOrderHead + 1 > 4096 do
        caseBySignal[signalOrder[signalOrderHead]] = nil
        signalOrder[signalOrderHead] = nil
        signalOrderHead = signalOrderHead + 1
    end
    if signalOrderHead > 1024 then
        local compacted = {}
        for index = signalOrderHead, #signalOrder do
            compacted[#compacted + 1] = signalOrder[index]
        end
        signalOrder, signalOrderHead = compacted, 1
    end
end

local function detectorModeFor(signal)
    local detector = signal.detector or ''
    if detector:find('sentinel', 1, true) then return config.detectors.sentinel end
    if detector:find('entity_guard', 1, true) then return config.detectors.entity_guard end
    if detector:find('game_events', 1, true) then return config.detectors.game_events end
    if signal.category == 'transport' then return config.detectors.transport end
    if signal.category == 'movement' then return config.detectors.movement end
    if signal.category == 'player_integrity'
        or signal.category == 'client_integrity' then
        return config.detectors.player_integrity
    end
    if signal.category == 'weapon' then return config.detectors.weapon_integrity end
    if signal.category == 'combat' then return config.detectors.combat_analytics end
    return config.detectors.domain_abuse
end

local function policyFor(signal)
    local rules = {
        {
            action = 'MANUAL_REVIEW', minimumConfidence = 0.78,
            minimumSeverity = 'HIGH', minimumIndependentEvidence = 2,
            requiredEvidenceClasses = {},
            reason = 'Independent bounded evidence requires staff review.',
        },
    }
    if config.enforcement.automaticKick then
        rules[#rules + 1] = {
            action = 'KICK', minimumConfidence = 0.96,
            minimumSeverity = 'CRITICAL',
            minimumIndependentEvidence = config.enforcement.minimumKickEvidenceClasses,
            minimumEvidenceClasses = config.enforcement.minimumKickEvidenceClasses,
            requiredEvidenceClasses = { 'SERVER_AUTHORITATIVE' },
            reason = 'Multiple authoritative findings justify immediate disconnect.',
        }
    end
    if config.enforcement.automaticBan then
        rules[#rules + 1] = {
            action = 'BAN', minimumConfidence = 0.995,
            minimumSeverity = 'CRITICAL',
            minimumIndependentEvidence = config.enforcement.minimumBanEvidenceClasses,
            minimumEvidenceClasses = config.enforcement.minimumBanEvidenceClasses,
            requiredEvidenceClasses = {
                'SERVER_AUTHORITATIVE', 'DOMAIN_AUTHORITATIVE',
            },
            reason = 'Independent authoritative findings satisfy the configured ban policy.',
        }
    end
    return {
        policyId = 'security.default.v1',
        mode = detectorModeFor(signal),
        rules = rules,
    }
end

processSignal = function(signal)
    if detectorModeFor(signal) == 'DISABLED' then return true end
    local ingested, ingestError, ingestMetadata = correlation.ingest(signal)
    if not ingested then
        observability.finding('HIGH', 'SECURITY_CORRELATION_FAILED',
            'A canonical signal could not enter correlation.', {
                detector = signal.detector, scope = signal.category,
            })
        return nil, ingestError
    end
    if type(ingestMetadata) ~= 'table' or ingestMetadata.duplicate ~= true then
        observability.increment('signals_total', {
            category = signal.category,
            evidence = signal.evidenceClass:lower(),
        }, 1)
        if signal.category == 'transport' then
            observability.increment('transport_abuse_total', {}, 1)
        elseif signal.category == 'movement' then
            observability.increment('movement_anomalies_total', {}, 1)
        elseif signal.category == 'combat' then
            observability.increment('combat_anomalies_total', {}, 1)
        elseif signal.category == 'player_integrity' then
            observability.increment('player_integrity_anomalies_total', {}, 1)
        end
        if signal.code == 'SECURITY_SENTINEL_MISSING' then
            observability.increment('sentinel_missing_total', {}, 1)
        end
    end
    local assessment, assessmentError = correlation.assessSignal(signal)
    if not assessment then return nil, assessmentError end
    -- Assessments are confidence-sorted and may contain unrelated hypotheses for
    -- the same subject. Only the hypothesis produced by this signal may own its
    -- persistence and enforcement policy.
    local hypothesis = SynexSecurityFoundation.hypothesisForSignal(
        assessment, signal)
    if type(hypothesis) ~= 'table'
        or hypothesis.confidence < SynexSecurityLimits.minimumCaseConfidence then
        return true
    end
    local contributors, contributorError = correlation.contributors(
        signal, SynexSecurityLimits.maximumCaseSignals)
    if not contributors then return nil, contributorError end
    local persistenceKey = coroutineKey()
    pendingCaseSignalBatches[persistenceKey] = contributors
    local caseValue, caseError, metadata = cases.openFromAssessment(
        assessment, hypothesis.key)
    pendingCaseSignalBatches[persistenceKey] = nil
    if not caseValue then
        if type(caseError) ~= 'table' or caseError.code ~= 'SECURITY_CASE_THRESHOLD' then
            observability.finding('HIGH', 'SECURITY_CASE_PIPELINE_FAILED',
                'A correlated finding could not be materialized as a case.', {
                    detector = signal.detector, scope = signal.category,
                })
        end
        return nil, caseError
    end
    for _, contributor in ipairs(contributors) do
        if caseBySignal[contributor.signalId] ~= caseValue.caseId then
            rememberSignalCase(contributor.signalId, caseValue.caseId)
        end
    end
    persistenceSuccess()
    if type(metadata) == 'table' and metadata.created == true then
        observability.increment('cases_created_total', {
            category = caseValue.category,
        }, 1)
        observability.event('synex.security.case.opened', {
            caseId = caseValue.caseId,
            category = caseValue.category,
            severity = caseValue.severity,
        }, signal.traceId)
    end
    local decision, decisionError = enforcement.decide(caseValue, policyFor(signal))
    if not decision then return nil, decisionError end
    if decision.action ~= 'OBSERVE' then
        local applied, applyError = enforcement.apply(decision, caseValue)
        if not applied then
            observability.finding('HIGH', 'SECURITY_ENFORCEMENT_FAILED',
                'A justified security action could not be applied.', {
                    detector = signal.detector, scope = signal.category,
                })
            return nil, applyError
        end
    end
    return true
end

local function internalEmit(request)
    local api = coreRef.value
    if type(api) ~= 'table' then
        return SynexSecurityValidation.failure('SECURITY_UNAVAILABLE',
            'Security is not bound to Core.', true)
    end
    return signals.emit(request, {
        ownerResource = RESOURCE_NAME,
        ownerEpoch = api.ownerEpoch,
    })
end

local function playerPosition(source)
    local ped = GetPlayerPed(source)
    if type(ped) ~= 'number' or ped <= 0 or not DoesEntityExist(ped) then return nil end
    local value = GetEntityCoords(ped)
    local ok, x, y, z = pcall(function()
        return tonumber(value.x or value[1]), tonumber(value.y or value[2]),
            tonumber(value.z or value[3])
    end)
    if not ok or not SynexSecurityValidation.isFinite(x)
        or not SynexSecurityValidation.isFinite(y)
        or not SynexSecurityValidation.isFinite(z) then return nil end
    return { x, y, z }
end

local runtimeAdapters = SynexSecurityRuntimeAdapters.create({
    now = now,
    ports = {
        getPlayerPed = GetPlayerPed,
        doesEntityExist = DoesEntityExist,
        isEntityDead = IsEntityDead,
        getEntityModel = GetEntityModel,
        getEntityMaxHealth = GetEntityMaxHealth,
    },
})

local movement = SynexSecurityMovement.create({
    now = now,
    emit = internalEmit,
    getPosition = playerPosition,
    matchExpectations = expectations.match,
    isEnabled = function() return config.detectors.movement ~= 'DISABLED' end,
})

local detectors = SynexSecurityDetectors.create({
    now = now,
    emit = internalEmit,
    movement = movement,
    matchExpectations = expectations.match,
    modes = config.detectors,
    expectedPlayerState = runtimeAdapters.expectedPlayerState,
})

local sentinel = SynexSecuritySentinel.create({
    now = now,
    emit = internalEmit,
    resolveSession = currentSession,
    reportIntervalMs = config.sentinelIntervalMs,
    isEnabled = function() return config.detectors.sentinel ~= 'DISABLED' end,
    onSample = function(session, sample, metadata)
        metadata.serverPosition = playerPosition(session.source)
        local bucketOk, bucket = pcall(GetPlayerRoutingBucket, session.source)
        if bucketOk and SynexSecurityValidation.isInteger(bucket, 0, 2147483647) then
            metadata.bucket = bucket
            runtimeAdapters.observeBucket(bucket)
        end
        local lifecycle = runtimeAdapters.movementContext(session, metadata.bucket)
        metadata.spawning = lifecycle.spawning
        metadata.respawning = lifecycle.respawning
        metadata.instanceTransition = lifecycle.instanceTransition
        return detectors.observeSentinel(session, sample, metadata)
    end,
})

local cfxGuards = SynexSecurityCfxGuards.create({
    now = now,
    emit = internalEmit,
    detectors = detectors,
    matchExpectations = expectations.match,
    resolveSession = currentSession,
    modeFor = detectors.mode,
    authorizeEntity = function(observation)
        -- entityCreating is synchronous. Do not yield into a domain service here.
        -- Server-created entities are attributable. The strict profile also enforces
        -- the documented OneSync server-created-entity boundary; other profiles keep
        -- legacy client creation observe-only until a domain supplies synchronous
        -- authority metadata.
        local serverCreated = observation.creator == 0
        local attributed = runtimeAdapters.authorizeEntity(observation)
        if attributed ~= nil then return attributed end
        local strictClientBoundary = config.profile == 'strict' and not serverCreated
        return {
            allowed = not strictClientBoundary,
            deterministic = strictClientBoundary,
            policy = serverCreated and 'managed'
                or strictClientBoundary and 'strict' or 'legacy_allowed',
        }
    end,
    supportsCancellation = {
        startProjectileEvent = config.cfxPolicy.cancellation.startProjectileEvent.supported,
        ptFxEvent = config.cfxPolicy.cancellation.ptFxEvent.supported,
    },
    liveVerified = {
        startProjectileEvent = config.cfxPolicy.cancellation.startProjectileEvent.liveVerified,
        ptFxEvent = config.cfxPolicy.cancellation.ptFxEvent.liveVerified,
    },
    deniedModels = config.cfxPolicy.deniedModels,
    deniedExplosions = config.cfxPolicy.deniedExplosions,
    deniedProjectiles = config.cfxPolicy.deniedProjectiles,
    deniedPtFx = config.cfxPolicy.deniedPtFx,
    entityBurstMitigation = config.cfxPolicy.burstMitigation.entity,
    damageBurstMitigation = config.cfxPolicy.burstMitigation.damage,
    explosionBurstMitigation = config.cfxPolicy.burstMitigation.explosion,
    projectileBurstMitigation = config.cfxPolicy.burstMitigation.projectile,
    ptFxBurstMitigation = config.cfxPolicy.burstMitigation.ptFx,
    ports = {
        addEventHandler = AddEventHandler,
        removeEventHandler = RemoveEventHandler,
        cancelEvent = CancelEvent,
        getEntityOwner = NetworkGetEntityOwner,
        getEntityModel = GetEntityModel,
        getEntityType = GetEntityType,
        getEntityBucket = GetEntityRoutingBucket,
        getEntityFromNetworkId = NetworkGetEntityFromNetworkId,
        getPlayerPed = GetPlayerPed,
    },
})

local hardening = SynexSecurityHardening.create({
    getConvar = GetConvar,
    getBuckets = runtimeAdapters.buckets,
})

local domainProjection = {
    entities = {}, order = {}, head = 1, capacity = 4096,
    received = 0, invalid = 0, worldTransitions = 0,
}

local function entityReference(payload)
    if type(payload) ~= 'table' then return nil end
    local value = type(payload.entity) == 'table' and payload.entity or payload
    if not SynexSecurityValidation.token(value.entityId, 3, 96)
        or not SynexSecurityValidation.isInteger(value.generation, 1,
            SynexSecurityLimits.maximumSafeInteger) then return nil end
    return value.entityId, value.generation
end

local function rememberEntity(topic, payload)
    local entityId, generation = entityReference(payload)
    if not entityId then domainProjection.invalid = domainProjection.invalid + 1; return false end
    local key = entityId .. ':' .. tostring(generation)
    if topic == 'synex.entities.deleted' then
        domainProjection.entities[key] = nil
        return true
    end
    local record = domainProjection.entities[key]
    if record == nil then
        record = { entityId = entityId, generation = generation }
        domainProjection.entities[key] = record
        domainProjection.order[#domainProjection.order + 1] = key
    end
    record.lastTopic, record.updatedAt = topic, now()
    if SynexSecurityValidation.resourceName(payload.resourceOwner) then
        record.resourceOwner = payload.resourceOwner
    end
    local bucket = type(payload.bucket) == 'table' and payload.bucket.id or payload.bucket
    if SynexSecurityValidation.isInteger(bucket, 0, 2147483647) then record.bucket = bucket end
    while #domainProjection.order - domainProjection.head + 1
        > domainProjection.capacity do
        local oldest = domainProjection.order[domainProjection.head]
        domainProjection.order[domainProjection.head] = nil
        domainProjection.head = domainProjection.head + 1
        domainProjection.entities[oldest] = nil
    end
    return true
end

local function domainEvent(topic, payload)
    domainProjection.received = domainProjection.received + 1
    runtimeAdapters.observeDomainEvent(payload)
    if topic == 'synex.world.portal.transitioned' then
        domainProjection.worldTransitions = domainProjection.worldTransitions + 1
        return true
    end
    return rememberEntity(topic, payload)
end

local coreIngestion = {
    failures = 0,
    consecutiveFailures = 0,
    lastCode = nil,
}
local function diagnosticCode(value)
    local code = tostring(value or 'SECURITY_CORE_DENIAL'):upper()
        :gsub('[^A-Z0-9_]', '_'):sub(1, SynexSecurityLimits.maximumCodeBytes)
    if not SynexSecurityValidation.errorCode(code) then return 'SECURITY_CORE_DENIAL' end
    return code
end

local CORE_DIAGNOSTIC_CHECKPOINT_KEY =
    'synex_security.core_diagnostics.cursor.v1'
local coreDiagnosticsCursor = SynexSecurityCoreDiagnosticsCursor.create({
    getCheckpoint = function()
        return GetResourceKvpString(CORE_DIAGNOSTIC_CHECKPOINT_KEY)
    end,
    setCheckpoint = function(value)
        SetResourceKvp(CORE_DIAGNOSTIC_CHECKPOINT_KEY, value)
        return true
    end,
    deleteCheckpoint = function()
        DeleteResourceKvp(CORE_DIAGNOSTIC_CHECKPOINT_KEY)
        return true
    end,
    onGap = function(reason, details)
        local retentionGap = reason == 'RETENTION_GAP'
        observability.finding(retentionGap and 'HIGH' or 'WARNING',
            retentionGap and 'SECURITY_CORE_DIAGNOSTIC_RETENTION_GAP'
                or 'SECURITY_CORE_DIAGNOSTIC_CHECKPOINT_INVALID',
            retentionGap
                and 'Core security diagnostics exceeded retained restart coverage.'
                or 'The Core diagnostic checkpoint was reset safely.', {
                scope = 'core_diagnostics',
                reason = reason,
                checkpoint = type(details) == 'table' and details.checkpoint or nil,
                oldest = type(details) == 'table' and details.oldest or nil,
                latest = type(details) == 'table' and details.latest or nil,
            })
    end,
})

local function emitCoreDiagnostic(finding, streamId)
    local subjectResource = SynexSecurityValidation.resourceName(finding.resource)
        and finding.resource or CORE_RESOURCE
    local subject = { resourceName = subjectResource }
    if SynexSecurityValidation.token(finding.sessionId, 3, 96)
        and SynexSecurityValidation.isInteger(finding.source, 1,
            SynexSecurityLimits.maximumPlayerSource)
        and SynexSecurityValidation.isInteger(finding.sourceGeneration, 1,
            SynexSecurityLimits.maximumSafeInteger) then
        subject = {
            sessionId = finding.sessionId,
            source = finding.source,
            sourceGeneration = finding.sourceGeneration,
            userId = SynexSecurityValidation.token(finding.userId, 3, 96)
                and finding.userId or nil,
            characterId = SynexSecurityValidation.token(finding.characterId, 3, 96)
                and finding.characterId or nil,
        }
    end
    return internalEmit({
        namespace = 'synex.security',
        category = 'transport',
        detector = 'synex.security.core_denial',
        code = diagnosticCode(finding.code),
        subject = subject,
        severity = finding.severity == 'CRITICAL' and 'CRITICAL'
            or finding.severity == 'ERROR' and 'HIGH'
            or finding.severity == 'WARNING' and 'MEDIUM' or 'LOW',
        confidence = 0.90,
        evidenceClass = 'SERVER_AUTHORITATIVE',
        correlationKey = 'core-denial:'
            .. tostring(finding.category or 'unknown'),
        rootEventId = ('corediag:%s:%d'):format(streamId, finding.id),
        summary = 'Synex Core rejected a security-sensitive operation before state mutation.',
        evidence = {
            category = tostring(finding.category or 'unknown'):sub(1, 32),
            operation = tostring(finding.operation or 'unknown'):sub(1, 128),
            scope = tostring(finding.scope or 'unknown'):sub(1, 64),
        },
    })
end

local function ingestCoreDiagnostics(api)
    return coreDiagnosticsCursor.drain(api, emitCoreDiagnostic)
end

local function restoreCases()
    if persistence.restored then return true end
    local records, loadError = repository.loadOpenCases(
        SynexSecurityLimits.maximumCases)
    if not records then return nil, loadError end
    local closedRecords, closedLoadError = repository.loadClosedCases(
        SynexSecurityLimits.maximumClosedCaseArchive)
    if not closedRecords then return nil, closedLoadError end
    for _, record in ipairs(closedRecords) do records[#records + 1] = record end
    local restored = {}
    for _, record in ipairs(records) do
        if type(record.summary) ~= 'table' then
            return SynexSecurityValidation.failure('SECURITY_CASE_RESTORE_INVALID',
                'A persisted security case summary is invalid.', false)
        end
        local value = record.summary
        if value.caseId ~= record.caseId then
            return SynexSecurityValidation.failure('SECURITY_CASE_RESTORE_INVALID',
                'A persisted security case identity is inconsistent.', false)
        end
        restored[#restored + 1] = value
    end
    local count, restoreError = cases.restore(restored)
    if count == nil then return nil, restoreError end
    persistence.restored = true
    persistence.state = 'READY'
    persistence.lastCode = nil
    persistence.consecutiveFailures = 0
    return true
end

local function reconcileEnforcements()
    local recovery, recoveryError = repository.reconcilePendingEnforcements(
        SynexSecurityLimits.maximumEnforcementHistory)
    if not recovery then return nil, recoveryError end
    persistence.quarantinedEnforcements = math.min(
        SynexSecurityLimits.maximumSafeInteger,
        persistence.quarantinedEnforcements + recovery.quarantined)
    persistence.indeterminateEnforcements = recovery.indeterminate
    if recovery.quarantined > 0 then
        observability.finding('CRITICAL',
            'SECURITY_ENFORCEMENT_INDETERMINATE',
            'A persisted enforcement decision has an unknown action outcome and requires manual review.', {
                scope = 'enforcement_recovery',
                count = recovery.quarantined,
            })
        observability.event('synex.security.enforcement.indeterminate', {
            count = recovery.quarantined,
            requiresManualReview = true,
        })
    end
    return true
end

local diagnostics
local function healthSnapshot()
    local signalSnapshot = signals.snapshot()
    local caseSnapshot = cases.snapshot()
    local expectationSnapshot = expectations.snapshot()
    local sentinelSnapshot = sentinel.snapshot()
    local detectorList = detectors.list()
    local guardSnapshot = cfxGuards.snapshot()
    local api = coreRef.value
    local accessAvailable = type(api) == 'table' and type(api.Access) == 'table'
        and SynexSecurityValidation.isCallable(api.Access.ban)
    local detectorHealthy = signalPipelineConsecutiveFailures == 0
        and (signalSnapshot.pipelinePending or 0) == 0
        and (sentinelSnapshot.consecutiveSampleFailures or 0) == 0
        and coreIngestion.consecutiveFailures == 0
        and lifecycleAuditConsecutiveFailures == 0
    local enforcementHealthy = config.enforcement.automaticBan ~= true
        or accessAvailable
    local recoveryHealthy = persistence.indeterminateEnforcements == 0
    local state = application ~= nil and application.ready()
        and persistence.state == 'READY' and guardSnapshot.installed
        and detectorHealthy and enforcementHealthy and recoveryHealthy
        and 'READY' or coreRef.value == nil and 'UNHEALTHY' or 'DEGRADED'
    return {
        state = state,
        detectors = #detectorList,
        openCases = (caseSnapshot.states.OPEN or 0)
            + (caseSnapshot.states.MONITORING or 0)
            + (caseSnapshot.states.REVIEW or 0)
            + (caseSnapshot.states.ENFORCED or 0),
        activeExpectations = expectationSnapshot.active,
        sentinelSources = sentinelSnapshot.active,
        persistenceBacklog = (persistence.state == 'READY' and 0 or 1)
            + persistence.indeterminateEnforcements
            + (signalSnapshot.pipelinePending or 0)
            + coreIngestion.consecutiveFailures
            + lifecycleAuditConsecutiveFailures,
        reasons = {
            persistence = persistence.state == 'READY'
                and 'READY' or 'CASE_STORE_UNAVAILABLE',
            core = coreRef.value ~= nil and 'READY' or 'CORE_SIGNAL_SOURCE_UNAVAILABLE',
            cfx = guardSnapshot.installed and 'READY' or 'ENTITY_GUARD_UNAVAILABLE',
            sentinel = (sentinelSnapshot.consecutiveSampleFailures or 0) == 0
                and 'READY' or 'SENTINEL_TRANSPORT_DEGRADED',
            detector = (sentinelSnapshot.consecutiveSampleFailures or 0) == 0
                and 'READY' or 'DETECTOR_FAILURE',
            pipeline = signalPipelineConsecutiveFailures == 0
                and (signalSnapshot.pipelinePending or 0) == 0
                and 'READY' or 'CORRELATION_BACKLOG',
            coreSignals = coreIngestion.consecutiveFailures == 0
                and 'READY' or 'CORE_SIGNAL_SOURCE_UNAVAILABLE',
            access = enforcementHealthy and 'READY'
                or 'ACCESS_ENFORCEMENT_UNAVAILABLE',
            enforcementRecovery = recoveryHealthy and 'READY'
                or 'ENFORCEMENT_RECONCILIATION_REQUIRED',
            audit = lifecycleAuditConsecutiveFailures == 0
                and 'READY' or 'AUDIT_PIPELINE_DEGRADED',
        },
    }
end

local function doctorChecks()
    local health = healthSnapshot()
    local expectationAudit = expectations.audit(now())
    local caseAudit = cases.audit()
    local guard = cfxGuards.snapshot()
    local detectorList = detectors.list()
    local hooks = {}
    for _, hook in ipairs(guard.hooks or {}) do
        hooks[hook.event] = hook.installed == true
    end
    local detectorHealthy = true
    for _, detector in ipairs(detectorList) do
        if detector.health ~= 'READY' then detectorHealthy = false; break end
    end
    local gameHooksHealthy = true
    for _, eventName in ipairs({
        'weaponDamageEvent', 'explosionEvent', 'startProjectileEvent', 'ptFxEvent',
    }) do
        if hooks[eventName] ~= true then gameHooksHealthy = false; break end
    end
    local api = coreRef.value
    local accessAvailable = type(api) == 'table' and type(api.Access) == 'table'
        and SynexSecurityValidation.isCallable(api.Access.ban)
    local staleCount = type(expectationAudit) == 'table'
        and (expectationAudit.expiredActive or 0)
            + (expectationAudit.staleOwners or 0) or -1
    local orphanCount = type(caseAudit) == 'table'
        and (caseAudit.orphanCases or 0) or -1
    local function check(id, passed, code, summary, advisory)
        return {
            id = id,
            status = passed and 'PASS' or advisory and 'ADVISORY' or 'FAIL',
            code = passed and 'SECURITY_CHECK_PASSED' or code,
            summary = summary,
        }
    end
    return {
        check('service_availability', application ~= nil and application.ready()
            and coreRef.value ~= nil and persistence.state == 'READY',
            'SECURITY_SERVICE_UNAVAILABLE',
            'Security service, Core binding, or persistence is unavailable.'),
        check('detector_status', detectorHealthy,
            'SECURITY_DETECTOR_UNHEALTHY',
            'One or more configured detector engines are unhealthy.'),
        check('sentinel_transport', health.reasons.sentinel == 'READY',
            'SECURITY_SENTINEL_TRANSPORT_DEGRADED',
            'Sentinel transport has consecutive sampling failures.'),
        check('stale_expectations', staleCount == 0,
            'SECURITY_STALE_EXPECTATIONS', staleCount < 0
                and 'Expectation integrity could not be evaluated.'
                or ('Security retains %d stale or expired expectations.'):format(staleCount),
            staleCount > 0),
        check('orphan_cases', orphanCount == 0,
            'SECURITY_ORPHAN_CASES', orphanCount < 0
                and 'Case integrity could not be evaluated.'
                or ('Security retains %d orphaned active case references.'):format(orphanCount)),
        check('correlation_backlog', health.reasons.pipeline == 'READY',
            'SECURITY_CORRELATION_BACKLOG',
            'Canonical signals are waiting for successful correlation.'),
        check('entity_guard_hooks',
            config.detectors.entity_guard == 'DISABLED' or hooks.entityCreating == true,
            'SECURITY_ENTITY_GUARD_UNAVAILABLE',
            'The configured entity guard hook is unavailable.'),
        check('game_event_hooks',
            config.detectors.game_events == 'DISABLED' or gameHooksHealthy,
            'SECURITY_GAME_EVENT_HOOKS_UNAVAILABLE',
            'One or more configured Cfx game-event hooks are unavailable.'),
        check('core_signal_integration', coreRef.value ~= nil
            and health.reasons.coreSignals == 'READY',
            'SECURITY_CORE_SIGNAL_SOURCE_UNAVAILABLE',
            'Core defensive findings are not being ingested.'),
        check('access_integration', accessAvailable,
            'SECURITY_ACCESS_ENFORCEMENT_UNAVAILABLE',
            config.enforcement.automaticBan == true
                and 'Automatic ban is enabled but Core Access is unavailable.'
                or 'Core Access is unavailable; automatic ban remains disabled.',
            config.enforcement.automaticBan ~= true),
        check('enforcement_recovery',
            persistence.indeterminateEnforcements == 0,
            'SECURITY_ENFORCEMENT_INDETERMINATE',
            ('Security retains %d indeterminate enforcement decisions requiring manual review.')
                :format(persistence.indeterminateEnforcements)),
        check('case_lifecycle_audit', health.reasons.audit == 'READY',
            'SECURITY_AUDIT_PIPELINE_DEGRADED',
            'A privileged case lifecycle audit could not be appended.'),
    }
end

local function listPage(values, cursor, limit)
    local offset = SynexSecurityValidation.isInteger(cursor, 0, 1000000)
        and cursor or 0
    local maximum = SynexSecurityValidation.isInteger(limit, 1, 100) and limit or 50
    local items = {}
    for index = offset + 1, math.min(#values, offset + maximum) do
        items[#items + 1] = values[index]
    end
    local nextCursor = offset + #items < #values and offset + #items or nil
    return {
        items = items,
        total = #values,
        nextCursor = nextCursor,
        hasMore = nextCursor ~= nil,
        truncated = nextCursor ~= nil,
    }, nil
end

local CASE_INSPECT_LIMIT = 4
local function caseDetail(caseId)
    local value, caseError = cases.get(caseId)
    if not value and type(caseError) == 'table'
        and caseError.code == 'SECURITY_CASE_NOT_FOUND' then
        local persisted, persistedError = repository.getCase(caseId)
        if not persisted then return nil, persistedError end
        if type(persisted.summary) ~= 'table'
            or persisted.summary.caseId ~= persisted.caseId then
            return SynexSecurityValidation.failure('SECURITY_PERSISTENCE_INVALID',
                'The persisted security case summary is inconsistent.', true)
        end
        value = persisted.summary
    elseif not value then
        return nil, caseError
    end
    local storedTimeline, timelineError = repository.loadCaseSignals(
        caseId, CASE_INSPECT_LIMIT + 1)
    if not storedTimeline then return nil, timelineError end
    local timeline = {}
    for index = 1, math.min(#storedTimeline, CASE_INSPECT_LIMIT) do
        local signal = storedTimeline[index]
        timeline[#timeline + 1] = {
            signalId = signal.signalId,
            category = signal.category,
            detector = signal.detector,
            code = signal.code,
            evidenceClass = signal.evidenceClass,
            severity = signal.severity,
            confidence = signal.confidence,
            observedAt = signal.observedAt,
            traceId = signal.traceId,
            rootEventId = signal.rootEventId,
            correlationKey = signal.correlationKey,
            requestId = signal.requestId,
            summary = signal.summary,
        }
    end
    local storedEnforcements, enforcementError = repository.loadCaseEnforcements(
        caseId, CASE_INSPECT_LIMIT + 1)
    if not storedEnforcements then return nil, enforcementError end
    local enforcements = {}
    for index = 1, math.min(#storedEnforcements, CASE_INSPECT_LIMIT) do
        enforcements[#enforcements + 1] = storedEnforcements[index]
    end
    local expectationKeys, expectationValues = {}, {}
    local expectationsTruncated = false
    if SynexSecurityValidation.token(value.subjectKey, 3, 256) then
        expectationKeys[value.subjectKey] = true
    end
    if SynexSecurityValidation.token(value.subjectUser, 3, 96) then
        expectationKeys['user:' .. value.subjectUser] = true
    end
    for subjectKey in pairs(expectationKeys) do
        local remaining = CASE_INSPECT_LIMIT - #expectationValues
        if remaining <= 0 then break end
        local current, expectationError = expectations.list({
            subjectKey = subjectKey,
            limit = remaining + 1,
        })
        if not current then return nil, expectationError end
        if #current > remaining then expectationsTruncated = true end
        for index = 1, math.min(#current, remaining) do
            local expectation = current[index]
            local selectorCount = 0
            for _, selector in pairs(expectation.constraints or {}) do
                if type(selector) == 'table' then selectorCount = selectorCount + #selector end
            end
            expectationValues[#expectationValues + 1] = {
                expectationId = expectation.expectationId,
                namespace = expectation.namespace,
                kind = expectation.kind,
                ownerResource = expectation.ownerResource,
                reason = expectation.reason,
                issuedAt = expectation.issuedAt,
                expiresAt = expectation.expiresAt,
                revision = expectation.revision,
                selectorCount = selectorCount,
                maximumSeverity = expectation.constraints
                    and expectation.constraints.maximumSeverity or nil,
            }
        end
    end
    local detail = {
        schemaVersion = value.schemaVersion,
        caseId = value.caseId,
        category = value.category,
        severity = value.severity,
        confidence = value.confidence,
        peakConfidence = value.peakConfidence,
        status = value.status,
        revision = value.revision,
        openedAt = value.openedAt,
        updatedAt = value.updatedAt,
        closedAt = value.closedAt,
        transitionReason = value.transitionReason,
        signalSummary = value.signalSummary,
        evidenceSummary = value.evidenceSummary,
        enforcementSummary = value.enforcementSummary,
        timeline = timeline,
        timelineTruncated = #storedTimeline > #timeline
            or type(value.signalSummary) == 'table'
                and (value.signalSummary.count or 0) > #timeline,
        enforcements = enforcements,
        enforcementsTruncated = #storedEnforcements > #enforcements
            or type(value.enforcementSummary) == 'table'
                and (value.enforcementSummary.count or 0) > #enforcements,
        expectations = expectationValues,
        expectationCount = #expectationValues,
        expectationsTruncated = expectationsTruncated,
        correlation = {
        hypothesisKey = value.hypothesisKey,
        correlationKey = value.correlationKey,
        confidence = value.confidence,
        peakConfidence = value.peakConfidence,
        evidence = value.evidenceSummary,
        },
        rawClientTelemetryExposed = false,
    }
    return detail, nil
end

local function subjectDetail(subjectKey)
    if not SynexSecurityValidation.token(subjectKey, 3, 256) then
        return SynexSecurityValidation.failure('SECURITY_INVALID_REQUEST',
            'The security subject inspector key is invalid.')
    end
    local userId = subjectKey:match('^user:(.+)$')
    local values, seen = {}, {}
    local truncated = false
    for _, status in ipairs({ 'OPEN', 'MONITORING', 'REVIEW', 'ENFORCED' }) do
        local current, listError = cases.list({
            subjectUser = userId,
            subjectKey = userId == nil and subjectKey or nil,
            status = status,
            limit = 9,
        })
        if not current then return nil, listError end
        if #current > 8 then truncated = true end
        for index = 1, math.min(#current, 8) do
            if seen[current[index].caseId] == nil then
                seen[current[index].caseId] = true
                values[#values + 1] = current[index]
            end
        end
    end
    table.sort(values, function(left, right)
        if left.updatedAtMs == right.updatedAtMs then return left.caseId < right.caseId end
        return left.updatedAtMs > right.updatedAtMs
    end)
    while #values > 8 do table.remove(values); truncated = true end
    local summaries, enforcements, categories = {}, {}, {}
    for _, value in ipairs(values) do
        categories[value.category] = math.min(
            SynexSecurityLimits.maximumSafeInteger,
            (categories[value.category] or 0)
                + (value.signalSummary and value.signalSummary.count or 0))
        summaries[#summaries + 1] = {
            caseId = value.caseId,
            category = value.category,
            severity = value.severity,
            confidence = value.confidence,
            status = value.status,
            signalCount = value.signalSummary and value.signalSummary.count or 0,
            evidenceClasses = value.evidenceSummary
                and value.evidenceSummary.evidenceClasses or {},
            updatedAt = value.updatedAt,
        }
        local remaining = 32 - #enforcements
        if remaining > 0 then
            local records, recordError = repository.loadCaseEnforcements(
                value.caseId, math.min(8, remaining))
            if not records then return nil, recordError end
            for _, record in ipairs(records) do enforcements[#enforcements + 1] = record end
        else
            truncated = true
        end
    end
    local recentSignalCategories = {}
    for category, count in pairs(categories) do
        recentSignalCategories[#recentSignalCategories + 1] = {
            category = category,
            count = count,
        }
    end
    table.sort(recentSignalCategories, function(left, right)
        return left.category < right.category
    end)
    return {
        cases = summaries,
        caseCount = #summaries,
        recentSignalCategories = recentSignalCategories,
        enforcements = enforcements,
        enforcementCount = #enforcements,
        truncated = truncated,
    }, nil
end

diagnostics = SynexSecurityDiagnostics.create({
    summary = function()
        local signalSnapshot = signals.snapshot()
        local caseSnapshot = cases.snapshot()
        local guardSnapshot = cfxGuards.snapshot()
        local movementSnapshot = movement.snapshot()
        local detectorSnapshot = detectors.snapshot()
        local enforcementSnapshot = enforcement.snapshot()
        return {
            profile = config.profile,
            state = healthSnapshot().state,
            signalsRecent = signalSnapshot.active,
            signalsAccepted = signalSnapshot.accepted,
            signalsDeduplicated = signalSnapshot.duplicates,
            openCases = (caseSnapshot.states.OPEN or 0)
                + (caseSnapshot.states.MONITORING or 0)
                + (caseSnapshot.states.REVIEW or 0)
                + (caseSnapshot.states.ENFORCED or 0),
            mitigatedEvents = guardSnapshot.canceled,
            entityEventsBlocked = guardSnapshot.canceledByEvent.entityCreating or 0,
            movementAnomalies = movementSnapshot.anomalies,
            combatAnomalies = detectorSnapshot.combat,
            transportAbuse = signalSnapshot.categories.transport or 0,
            enforcements = enforcementSnapshot.applied,
            indeterminateEnforcements = persistence.indeterminateEnforcements,
            quarantinedEnforcements = persistence.quarantinedEnforcements,
            expectations = expectations.snapshot().active,
            domainEvents = domainProjection.received,
            persistence = persistence.state,
            signalPipelineFailures = signalPipelineFailures,
            sentinelSampleFailures = sentinel.snapshot().sampleFailures,
        }
    end,
    health = healthSnapshot,
    listCases = function(cursor, limit)
        local offset = SynexSecurityValidation.isInteger(cursor, 0, 1000000)
            and cursor or 0
        local maximum = SynexSecurityValidation.isInteger(limit, 1, 100)
            and limit or 50
        local values, listError = cases.list({
            offset = offset,
            limit = math.min(256, maximum + 1),
        })
        if not values then return nil, listError end
        local hasMore = #values > maximum
        if hasMore then values[#values] = nil end
        return {
            items = values,
            total = cases.snapshot().total,
            nextCursor = hasMore and offset + #values or nil,
            hasMore = hasMore,
            truncated = hasMore,
        }, nil
    end,
    getCase = caseDetail,
    getAssessment = function(subjectKey) return correlation.assess(subjectKey) end,
    inspectSubject = subjectDetail,
    listExpectations = function(subjectKey, limit)
        local values, listError = expectations.list({
            subjectKey = subjectKey, limit = limit,
        })
        if not values then return nil, listError end
        return { items = values, total = #values, truncated = false }, nil
    end,
    listDetectors = function(cursor, limit)
        return listPage(detectors.list(), cursor, limit)
    end,
    observability = observability,
    hardening = hardening,
    checks = doctorChecks,
})

local service = SynexSecurityService.create({
    now = now,
    signals = signals,
    expectations = expectations,
    correlation = correlation,
    cases = cases,
    getCase = caseDetail,
    sentinel = sentinel,
    diagnostics = diagnostics,
    detectors = detectors,
    decode = json.decode,
    encode = json.encode,
    caseForSignal = function(signalId) return caseBySignal[signalId] end,
    activateOwner = function(owner, epoch)
        if application == nil then
            return SynexSecurityValidation.failure('SECURITY_UNAVAILABLE',
                'Security owner authority is unavailable.', true)
        end
        return application.activateOwner(owner, epoch)
    end,
    onCaseLifecycle = function(phase, operation, value, request, context)
        local targetId = value and value.caseId or request.caseId
        local audited = observability.audit('security.case_' .. operation
            .. '_' .. phase:lower(), 'security_case', targetId, {
                caller = type(context) == 'table' and context.caller or nil,
                status = value and value.status or nil,
                revision = value and value.revision or request.expectedRevision,
                reason = request.reason,
            }, type(context) == 'table' and context.traceId or nil)
        if not audited then
            lifecycleAuditFailures = math.min(
                SynexSecurityLimits.maximumSafeInteger,
                lifecycleAuditFailures + 1)
            lifecycleAuditConsecutiveFailures = math.min(
                SynexSecurityLimits.maximumSafeInteger,
                lifecycleAuditConsecutiveFailures + 1)
            observability.finding(phase == 'INTENT' and 'CRITICAL' or 'HIGH',
                'SECURITY_CASE_AUDIT_FAILED',
                'A privileged security case mutation could not be audited.', {
                    scope = 'case_lifecycle',
                })
            return false
        end
        lifecycleAuditConsecutiveFailures = 0
        if phase == 'APPLIED' then
            observability.event('synex.security.case.' .. operation, {
                caseId = value.caseId,
                status = value.status,
                revision = value.revision,
            }, type(context) == 'table' and context.traceId or nil)
        end
        return true
    end,
})

local controlProvider = SynexSecurityControlProvider.create({
    diagnostics = diagnostics,
})

local tickCount = 0
local exportedGuardTotals = { canceled = 0, entity = 0 }
local spawnIntentHookEpoch
application = SynexSecurityApplication.create({
    resourceName = RESOURCE_NAME,
    coreResource = CORE_RESOURCE,
    coreRange = CORE_RANGE,
    coreRef = coreRef,
    ownerEpochs = ownerEpochs,
    service = service,
    controlProvider = controlProvider,
    expectations = expectations,
    acquireCore = function(range) return exports[CORE_RESOURCE]:GetAPI(range) end,
    decode = json.decode,
    onCoreReady = function(api)
        local activated, activationError = expectations.activateOwner(
            RESOURCE_NAME, api.ownerEpoch)
        if not activated then return nil, activationError end
        if spawnIntentHookEpoch ~= api.ownerEpoch and type(api.Hooks) == 'table'
            and SynexSecurityValidation.isCallable(api.Hooks.register) then
            local hookToken, hookError = api.Hooks.register(
                'synex.entities.before_entity_spawn', function(value)
                    runtimeAdapters.recordSpawnIntent(value)
                    return { action = 'allow' }
                end, { priority = -100, required = false, timeoutMs = 250 })
            if hookError and hookError.code ~= 'HOOK_REGISTER_UNDECLARED' then
                return nil, hookError
            end
            if hookToken ~= nil then spawnIntentHookEpoch = api.ownerEpoch end
        end
        local reconciled, reconciliationError = reconcileEnforcements()
        if not reconciled then
            persistenceFailure(reconciliationError,
                'SECURITY_ENFORCEMENT_RECONCILIATION_FAILED')
            return nil, reconciliationError
        end
        local restored, restoreError = restoreCases()
        if not restored then
            persistenceFailure(restoreError, 'SECURITY_CASE_STORE_UNAVAILABLE')
            return nil, restoreError
        end
        local installed, installError = cfxGuards.install()
        if not installed then return nil, installError end
        for _, detector in ipairs(detectors.list()) do
            observability.detector(detector.name, detector.mode, detector.health)
        end
        local ingested, ingestError = ingestCoreDiagnostics(api)
        if ingested == nil then return nil, ingestError end
        return true
    end,
    onCoreUnavailable = function()
        cfxGuards.uninstall()
        coreDiagnosticsCursor.resetMemory()
        return true
    end,
    onDomainEvent = domainEvent,
    onTick = function(api)
        tickCount = tickCount + 1
        local timestamp = now()
        local tracked = 0
        for _, rawSource in ipairs(GetPlayers()) do
            if tracked >= 4096 then break end
            local playerSource = tonumber(rawSource)
            local session = currentSession(playerSource)
            if session ~= nil then
                sentinel.track(session)
                tracked = tracked + 1
            end
        end
        expectations.prune(timestamp)
        signals.purge(timestamp)
        signals.retry(64)
        correlation.purge(timestamp)
        detectors.prune(timestamp)
        sentinel.sweep(timestamp)
        enforcement.purge(timestamp)
        local _, diagnosticError = ingestCoreDiagnostics(api)
        if diagnosticError then
            coreIngestion.failures = math.min(SynexSecurityLimits.maximumSafeInteger,
                coreIngestion.failures + 1)
            coreIngestion.consecutiveFailures = math.min(
                SynexSecurityLimits.maximumSafeInteger,
                coreIngestion.consecutiveFailures + 1)
            coreIngestion.lastCode = type(diagnosticError) == 'table'
                and diagnosticError.code or 'SECURITY_CORE_SIGNAL_UNAVAILABLE'
            observability.finding('MEDIUM', 'SECURITY_CORE_SIGNAL_UNAVAILABLE',
                'Core security diagnostics could not be ingested.', {
                    scope = 'core',
                })
        else
            coreIngestion.consecutiveFailures = 0
            coreIngestion.lastCode = nil
        end
        if timestamp - persistence.lastRetentionAt >= 3600000 then
            local purged, purgeError = repository.purge(
                config.retentionDays, config.closedCaseRetentionDays)
            persistence.lastRetentionAt = timestamp
            if not purged then persistenceFailure(purgeError,
                'SECURITY_RETENTION_FAILED')
            else persistenceSuccess() end
        end
        if tickCount % 5 == 0 then
            local snapshot = healthSnapshot()
            local signalSnapshot = signals.snapshot()
            local sentinelSnapshot = sentinel.snapshot()
            local movementSnapshot = movement.snapshot()
            local detectorSnapshot = detectors.snapshot()
            local guardSnapshot = cfxGuards.snapshot()
            local canceledDelta = math.max(0,
                (guardSnapshot.canceled or 0) - exportedGuardTotals.canceled)
            local entityCanceled = guardSnapshot.canceledByEvent.entityCreating or 0
            local entityDelta = math.max(0, entityCanceled - exportedGuardTotals.entity)
            if canceledDelta > 0 then
                observability.increment('mitigations_total', { action = 'cfx_cancel' },
                    canceledDelta)
            end
            if entityDelta > 0 then
                observability.increment('entity_events_blocked_total', {}, entityDelta)
            end
            exportedGuardTotals.canceled = guardSnapshot.canceled or 0
            exportedGuardTotals.entity = entityCanceled
            observability.gauge('cases_open', {}, snapshot.openCases)
            observability.gauge('expectations_active', {}, snapshot.activeExpectations)
            observability.gauge('sentinel_sources', {}, snapshot.sentinelSources)
            observability.gauge('persistence_backlog', {}, snapshot.persistenceBacklog)
            observability.gauge('signal_pipeline_backlog', {},
                signalSnapshot.pipelinePending or 0)
            observability.gauge('signals_deduplicated', {},
                signalSnapshot.duplicates or 0)
            observability.gauge('sentinel_missing', {}, sentinelSnapshot.missing or 0)
            observability.gauge('player_integrity_findings', {},
                (detectorSnapshot.visibility or 0) + (detectorSnapshot.model or 0)
                    + (detectorSnapshot.health or 0) + (detectorSnapshot.armor or 0)
                    + (detectorSnapshot.damageImmunity or 0))
            observability.gauge('entity_events_blocked', {},
                guardSnapshot.canceledByEvent.entityCreating or 0)
            observability.gauge('transport_abuse', {},
                signalSnapshot.categories.transport or 0)
            observability.gauge('movement_anomalies', {},
                movementSnapshot.anomalies or 0)
            observability.gauge('combat_anomalies', {},
                detectorSnapshot.combat or 0)
            for _, detector in ipairs(detectors.list()) do
                local detectorState, detectorCode = detector.mode == 'DISABLED'
                    and 'DISABLED' or 'READY', nil
                if signalPipelineConsecutiveFailures > 0
                    or (signalSnapshot.pipelinePending or 0) > 0 then
                    detectorState, detectorCode = 'DEGRADED', 'CORRELATION_BACKLOG'
                elseif (detector.name == 'sentinel'
                    or detector.name == 'player_integrity'
                    or detector.name == 'movement')
                    and (sentinelSnapshot.consecutiveSampleFailures or 0) > 0 then
                    detectorState, detectorCode = 'DEGRADED', 'DETECTOR_FAILURE'
                elseif (detector.name == 'entity_guard'
                    or detector.name == 'game_events')
                    and guardSnapshot.installed ~= true then
                    detectorState, detectorCode = 'DEGRADED', 'ENTITY_GUARD_UNAVAILABLE'
                end
                observability.detector(detector.name, detector.mode,
                    detectorState, detectorCode)
            end
            api.Services.setHealth('synex.security', '1.0.0',
                snapshot.state == 'READY' and 'HEALTHY'
                    or snapshot.state == 'UNHEALTHY' and 'UNHEALTHY' or 'DEGRADED')
        end
        return true
    end,
})

CreateThread(function()
    local started, startError = SynexSecurityFoundation.protect(application.start)
    if not started then
        print(('[%s] Security bootstrap failed: %s'):format(RESOURCE_NAME,
            type(startError) == 'table' and startError.code or 'SECURITY_UNAVAILABLE'))
    end
end)

AddEventHandler('playerDropped', function()
    local playerSource = tonumber(source)
    local session = currentSession(playerSource)
    local generation = session and session.sourceGeneration or nil
    sentinel.cleanupSource(playerSource, generation)
    detectors.cleanupSource(playerSource, generation)
    cfxGuards.cleanupSource(playerSource)
    runtimeAdapters.cleanupSource(playerSource, generation)
end)

AddEventHandler('onResourceStart', function(resource)
    application.resourceStarted(resource)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE_NAME then cfxGuards.uninstall() end
    application.resourceStopped(resource)
end)
