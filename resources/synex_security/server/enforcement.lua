SynexSecurityEnforcement = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local RingBuffer = assert(SynexSecurityRingBuffer, 'security ring buffer must be loaded first')
local Enforcement = SynexSecurityEnforcement

local POLICY_KEYS = { policyId = true, mode = true, rules = true }
local POLICY_REQUIRED = { policyId = true, mode = true, rules = true }
local RULE_KEYS = {
    action = true, minimumConfidence = true, minimumSeverity = true,
    minimumIndependentEvidence = true, requiredEvidenceClasses = true,
    minimumEvidenceClasses = true, reason = true, durationMs = true,
}
local RULE_REQUIRED = {
    action = true, minimumConfidence = true, minimumSeverity = true,
    minimumIndependentEvidence = true, reason = true,
}

function Enforcement.create(options)
    options = options or {}
    local now = assert(options.now, 'security enforcement clock is required')
    assert(Validation.isCallable(now), 'security enforcement clock is invalid')
    local serial = 0
    local nextId = Validation.isCallable(options.nextId) and options.nextId or function()
        serial = serial + 1
        return ('security:enforcement:%012d'):format(serial)
    end
    local accessBan = Validation.isCallable(options.accessBan) and options.accessBan or nil
    local validateSubject = Validation.isCallable(options.validateSubject)
        and options.validateSubject or nil
    local handlers = type(options.handlers) == 'table' and options.handlers or {}
    local onApplied = Validation.isCallable(options.onApplied) and options.onApplied or nil
    local persistDecision = Validation.isCallable(options.persistDecision)
        and options.persistDecision or nil
    local durableDecisionsRequired = options.requireDurableDecisions == true
        or onApplied ~= nil
    local utcNow = Validation.isCallable(options.utcNow) and options.utcNow or function()
        return os.time() * 1000
    end
    local formatExpiry = Validation.isCallable(options.formatExpiry)
        and options.formatExpiry or function(milliseconds)
            return os.date('!%Y-%m-%d %H:%M:%S', math.floor(milliseconds / 1000))
        end
    local completed, completedCount = {}, 0
    local inFlight = {}
    local decisions, applied, failures, duplicates = 0, 0, 0, 0
    local history = RingBuffer.create({
        capacity = options.historyCapacity or Limits.maximumEnforcementHistory,
        retentionMs = options.idempotencyRetentionMs
            or Limits.enforcementIdempotencyRetentionMs,
        now = now,
        timestampOf = function(record) return record.appliedAt end,
    })
    local api = {}

    local function decisionMaterial(caseValue, policyId, action, reason, includeRevision)
        local sessionBound = includeRevision or action ~= 'BAN'
            and action ~= 'MANUAL_REVIEW' and action ~= 'OBSERVE'
        local values = {
            tostring(caseValue.caseId),
            includeRevision and tostring(caseValue.revision) or '-',
            tostring(policyId),
            tostring(action), tostring(reason),
            tostring(caseValue.subjectUser or caseValue.subjectKey or '-'),
            sessionBound and tostring(caseValue.subjectSession or '-') or '-',
            sessionBound and tostring(caseValue.subjectSource or '-') or '-',
            sessionBound and tostring(caseValue.sourceGeneration or '-') or '-',
        }
        local parts = {}
        for index = 1, #values do
            local text = values[index]
            parts[index] = tostring(#text) .. ':' .. text
        end
        return table.concat(parts, '|')
    end

    local function provenanceMaterial(caseValue, policyId, action, reason)
        return decisionMaterial(caseValue, policyId, action, reason, true)
    end

    local function idempotencyMaterial(caseValue, policyId, action, reason)
        -- Case revisions record new evidence and lifecycle changes. They cannot
        -- make an otherwise identical policy action executable again while the
        -- first result is retained.
        return decisionMaterial(caseValue, policyId, action, reason, false)
    end

    local function purgeCompleted(at)
        local removed = 0
        for key, record in pairs(completed) do
            if at - record.appliedAt > (options.idempotencyRetentionMs
                or Limits.enforcementIdempotencyRetentionMs) then
                completed[key] = nil
                completedCount, removed = completedCount - 1, removed + 1
            end
        end
        history.prune(at)
        return removed
    end

    local function normalizePolicy(policy)
        if not Validation.exactObject(policy, POLICY_KEYS, POLICY_REQUIRED)
            or not Validation.token(policy.policyId, 3, 96)
            or not Limits.detectorModes[policy.mode] then
            return Validation.failure('SECURITY_POLICY_INVALID',
                'The security enforcement policy is invalid.')
        end
        local length = Validation.arrayLength(policy.rules, 16)
        if length == nil then
            return Validation.failure('SECURITY_POLICY_INVALID',
                'The security enforcement rules must be a bounded dense array.')
        end
        local rules = {}
        for index = 1, length do
            local rule = policy.rules[index]
            if not Validation.exactObject(rule, RULE_KEYS, RULE_REQUIRED)
                or not Limits.enforcementActions[rule.action]
                or not Validation.isFinite(rule.minimumConfidence)
                or rule.minimumConfidence < 0 or rule.minimumConfidence > 1
                or not Limits.severities[rule.minimumSeverity]
                or not Validation.isInteger(rule.minimumIndependentEvidence, 1, 32)
                or rule.minimumEvidenceClasses ~= nil and not Validation.isInteger(
                    rule.minimumEvidenceClasses, 1, Limits.maximumCaseEvidenceClasses)
                or not Validation.text(rule.reason, 1, Limits.maximumReasonBytes)
                or rule.reason:find('[%z\1-\31\127]') ~= nil
                or rule.durationMs ~= nil and not Validation.isInteger(
                    rule.durationMs, 1000, 31536000000)
                or rule.action == 'BAN' and rule.durationMs ~= nil
                    and rule.durationMs < Limits.minimumTemporaryBanDurationMs then
                return Validation.failure('SECURITY_POLICY_INVALID',
                    'A security enforcement rule is invalid.')
            end
            local classes, classError = Validation.stringArray(
                rule.requiredEvidenceClasses, Limits.maximumCaseEvidenceClasses,
                function(value) return Limits.evidenceClasses[value] == true end)
            if classError then return nil, classError end
            rules[index] = {
                action = rule.action,
                minimumConfidence = rule.minimumConfidence,
                minimumSeverity = rule.minimumSeverity,
                minimumIndependentEvidence = rule.minimumIndependentEvidence,
                minimumEvidenceClasses = rule.minimumEvidenceClasses or 1,
                requiredEvidenceClasses = classes or {},
                reason = rule.reason,
                durationMs = rule.durationMs,
            }
        end
        table.sort(rules, function(left, right)
            local leftRank = Limits.enforcementRanks[left.action] or 0
            local rightRank = Limits.enforcementRanks[right.action] or 0
            if leftRank == rightRank then
                return left.minimumConfidence > right.minimumConfidence
            end
            return leftRank > rightRank
        end)
        return { policyId = policy.policyId, mode = policy.mode, rules = rules }, nil
    end

    function api.decide(caseValue, policy)
        purgeCompleted(now())
        if type(caseValue) ~= 'table'
            or not Validation.token(caseValue.caseId, 8, Limits.maximumIdentifierBytes)
            or not Validation.isInteger(caseValue.revision, 1, Limits.maximumSafeInteger)
            or not Validation.isFinite(caseValue.confidence)
            or not Limits.severities[caseValue.severity]
            or type(caseValue.evidenceSummary) ~= 'table'
            or not Validation.isInteger(caseValue.evidenceSummary.independentEvidence, 0, 256)
            or type(caseValue.evidenceSummary.evidenceClasses) ~= 'table' then
            return Validation.failure('SECURITY_CASE_INVALID',
                'The enforcement engine received an invalid security case.')
        end
        local normalized, policyError = normalizePolicy(policy)
        if not normalized then return nil, policyError end
        local action, selectedReason, durationMs = 'OBSERVE',
            'The detector policy is observation-only.', nil
        if normalized.mode ~= 'DISABLED' and normalized.mode ~= 'OBSERVE' then
            local presentClasses = {}
            local presentClassCount = 0
            for _, evidenceClass in ipairs(caseValue.evidenceSummary.evidenceClasses) do
                if not presentClasses[evidenceClass] then
                    presentClasses[evidenceClass] = true
                    presentClassCount = presentClassCount + 1
                end
            end
            for _, rule in ipairs(normalized.rules) do
                local requiredPresent = true
                for _, evidenceClass in ipairs(rule.requiredEvidenceClasses) do
                    if not presentClasses[evidenceClass] then requiredPresent = false; break end
                end
                local permittedByMode = normalized.mode == 'ENFORCE'
                    or rule.action == 'OBSERVE' or rule.action == 'CORRECT'
                    or rule.action == 'MITIGATE' or rule.action == 'MANUAL_REVIEW'
                if permittedByMode and requiredPresent
                    and presentClassCount >= rule.minimumEvidenceClasses
                    and caseValue.confidence >= rule.minimumConfidence
                    and Limits.severityRanks[caseValue.severity]
                        >= Limits.severityRanks[rule.minimumSeverity]
                    and caseValue.evidenceSummary.independentEvidence
                        >= rule.minimumIndependentEvidence then
                    action, selectedReason, durationMs = rule.action, rule.reason, rule.durationMs
                    break
                end
            end
        end
        if caseValue.evidenceSummary.weakEvidenceOnly == true
            and (action == 'RESTRICT' or action == 'KICK' or action == 'BAN') then
            action = 'MANUAL_REVIEW'
            selectedReason = 'Only client telemetry or behavioral heuristics support this case.'
            durationMs = nil
        end
        if action == 'BAN' and not Validation.token(caseValue.subjectUser,
            Limits.minimumCoreAccessIdBytes, Limits.maximumCoreAccessIdBytes)
            or action == 'KICK' and not Validation.isInteger(caseValue.subjectSource,
                1, Limits.maximumPlayerSource) then
            action = 'MANUAL_REVIEW'
            selectedReason = 'The authoritative subject required for enforcement is unavailable.'
            durationMs = nil
        end
        local decidedAt, decidedAtUtc = now(), utcNow()
        if not Validation.isInteger(decidedAt, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(decidedAtUtc, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_ENFORCEMENT_CLOCK_INVALID',
                'The security enforcement clocks are invalid.', true)
        end
        local provenance = provenanceMaterial(caseValue, normalized.policyId,
            action, selectedReason)
        local material = idempotencyMaterial(caseValue, normalized.policyId,
            action, selectedReason)
        -- Core Access and Idempotency accept keys up to 36 bytes. Keep the
        -- durable Security key inside that public cross-resource contract.
        local idempotencyKey = 'security.enforce:'
            .. Foundation.stableDigest(material)
        local enforcementId = nextId('security.enforcement')
        if not Validation.token(enforcementId, 8, Limits.maximumIdentifierBytes) then
            return Validation.failure('SECURITY_ID_INVALID',
                'The security enforcement identifier is invalid.', true)
        end
        local decision = {
            schemaVersion = Limits.schemaVersion,
            enforcementId = enforcementId,
            caseId = caseValue.caseId,
            caseRevision = caseValue.revision,
            policyId = normalized.policyId,
            mode = normalized.mode,
            action = action,
            reason = selectedReason,
            decidedAt = decidedAt,
            decidedAtUtc = decidedAtUtc,
            idempotencyKey = idempotencyKey,
            provenanceDigest = Foundation.stableDigest('provenance|' .. provenance),
        }
        if durationMs ~= nil then decision.expiresAt = decidedAtUtc + durationMs end
        decisions = decisions + 1
        return decision, nil
    end

    local function applyLeader(decision, caseValue)
        purgeCompleted(now())
        if type(decision) ~= 'table' or type(caseValue) ~= 'table'
            or decision.caseId ~= caseValue.caseId
            or decision.caseRevision ~= caseValue.revision
            or not Limits.enforcementActions[decision.action]
            or not Validation.token(decision.enforcementId, 8,
                Limits.maximumIdentifierBytes)
            or not Validation.token(decision.policyId, 3, 96)
            or not Validation.token(decision.idempotencyKey, 8, 64)
            or not Validation.token(decision.provenanceDigest, 16, 16)
            or not Validation.text(decision.reason, 1, Limits.maximumReasonBytes)
            or not Validation.isInteger(decision.decidedAt, 0,
                Limits.maximumSafeInteger)
            or not Validation.isInteger(decision.decidedAtUtc, 0,
                Limits.maximumSafeInteger)
            or decision.expiresAt ~= nil and not Validation.isInteger(
                decision.expiresAt, decision.decidedAtUtc + 1000,
                Limits.maximumSafeInteger)
            or decision.provenanceDigest ~= Foundation.stableDigest(
                'provenance|' .. provenanceMaterial(caseValue, decision.policyId,
                    decision.action, decision.reason)) then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_INVALID',
                'The security enforcement decision is invalid.')
        end
        local previous = completed[decision.idempotencyKey]
        if previous ~= nil then
            duplicates = duplicates + 1
            if previous.persistenceState == 'FAILED' then
                local notified, committed, commitError = pcall(
                    onApplied, previous, caseValue)
                if not notified or committed == nil or committed == false then
                    failures = failures + 1
                    return Validation.failure(
                        'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                        'The applied security action still lacks durable evidence.',
                        true, type(commitError) == 'table'
                            and { code = commitError.code } or nil)
                end
                previous.persistenceState = 'APPLIED'
                applied = applied + 1
                return Validation.copy(previous, { maximumBytes = 8192,
                    maximumEntries = 128,
                    maximumStringBytes = Limits.maximumReasonBytes }),
                    nil, { duplicate = true, finalized = true }
            end
            return Validation.copy(previous, { maximumBytes = 8192,
                maximumEntries = 128, maximumStringBytes = Limits.maximumReasonBytes }),
                nil, { duplicate = true }
        end
        if completedCount >= (options.idempotencyCapacity
            or Limits.maximumEnforcementHistory) then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_LIMIT',
                'The bounded enforcement idempotency registry is full.', true)
        end
        local effectiveEnforcementId = decision.enforcementId
        local effectiveExpiresAt = decision.expiresAt
        local effectiveCaseRevision = decision.caseRevision
        local effectiveProvenanceDigest = decision.provenanceDigest
        local irreversible = decision.action == 'KICK' or decision.action == 'BAN'
        local actionHandler
        if irreversible and durableDecisionsRequired and persistDecision == nil then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_PERSISTENCE_UNAVAILABLE',
                'Irreversible enforcement requires durable decision persistence.', true)
        end
        if decision.action ~= 'OBSERVE' and decision.action ~= 'MANUAL_REVIEW'
            and validateSubject == nil then
            failures = failures + 1
            return Validation.failure('SECURITY_SUBJECT_VALIDATION_UNAVAILABLE',
                'The authoritative enforcement subject validator is unavailable.', true)
        end
        if decision.action ~= 'OBSERVE' and decision.action ~= 'MANUAL_REVIEW' then
            if decision.action == 'BAN' then
                if accessBan == nil then
                    failures = failures + 1
                    return Validation.failure('SECURITY_ACCESS_UNAVAILABLE',
                        'The Core Access ban service is unavailable.', true)
                end
            else
                actionHandler = handlers[decision.action]
                    or handlers[decision.action:lower()]
                if not Validation.isCallable(actionHandler) then
                    failures = failures + 1
                    return Validation.failure('SECURITY_ACTION_UNAVAILABLE',
                        'The requested security enforcement action is unavailable.', true)
                end
            end
        end
        if persistDecision ~= nil and decision.action ~= 'OBSERVE'
            and decision.action ~= 'MANUAL_REVIEW' then
            local persistenceAttemptId = nextId('security.enforcement.persistence')
            if not Validation.token(persistenceAttemptId, 8,
                Limits.maximumIdentifierBytes) then
                failures = failures + 1
                return Validation.failure('SECURITY_ID_INVALID',
                    'The enforcement persistence attempt identifier is invalid.', true)
            end
            local reserved, reservation, reservationError = pcall(persistDecision, {
                enforcementId = decision.enforcementId,
                persistenceAttemptId = persistenceAttemptId,
                caseId = decision.caseId,
                action = decision.action,
                policy = decision.policyId,
                idempotencyKey = decision.idempotencyKey,
                outcome = 'DECIDED',
                summary = {
                    caseRevision = decision.caseRevision,
                    reason = decision.reason,
                    decidedAtUtc = decision.decidedAtUtc,
                    expiresAt = decision.expiresAt,
                    provenanceDigest = decision.provenanceDigest,
                },
            }, caseValue)
            if not reserved or reservation == nil or reservation == false then
                failures = failures + 1
                return Validation.failure('SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                    'The security decision could not be persisted before action.', true,
                    type(reservationError) == 'table'
                        and { code = reservationError.code } or nil)
            end
            if type(reservation) == 'table' then
                if not Validation.token(reservation.enforcementId, 8,
                    Limits.maximumIdentifierBytes)
                    or reservation.outcome ~= 'DECIDED'
                        and reservation.outcome ~= 'APPLIED'
                        and reservation.outcome ~= 'FAILED'
                        and reservation.outcome ~= 'INDETERMINATE' then
                    failures = failures + 1
                    return Validation.failure('SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                        'The persisted security decision is invalid.', true)
                end
                effectiveEnforcementId = reservation.enforcementId
                if type(reservation.summary) ~= 'table'
                    or not Validation.isInteger(reservation.summary.caseRevision,
                        1, Limits.maximumSafeInteger)
                    or not Validation.token(reservation.summary.provenanceDigest,
                        16, 16) then
                    failures = failures + 1
                    return Validation.failure(
                        'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                        'The persisted enforcement provenance is invalid.', true)
                end
                effectiveCaseRevision = reservation.summary.caseRevision
                effectiveProvenanceDigest = reservation.summary.provenanceDigest
                if reservation.summary.expiresAt ~= nil then
                    if not Validation.isInteger(reservation.summary.expiresAt,
                        0, Limits.maximumSafeInteger) then
                        failures = failures + 1
                        return Validation.failure('SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                            'The persisted enforcement expiry is invalid.', true)
                    end
                    effectiveExpiresAt = reservation.summary.expiresAt
                end
                if reservation.outcome == 'FAILED'
                    or reservation.outcome == 'INDETERMINATE' then
                    failures = failures + 1
                    return Validation.failure(
                        'SECURITY_ENFORCEMENT_REVIEW_REQUIRED',
                        'A prior enforcement attempt requires explicit manual reconciliation.',
                        false, { outcome = reservation.outcome })
                end
                if reservation.outcome == 'DECIDED'
                    and reservation.duplicate == true then
                    failures = failures + 1
                    return Validation.failure(
                        'SECURITY_ENFORCEMENT_REVIEW_REQUIRED',
                        'A prior durable decision has no conclusive action outcome.',
                        false, { outcome = reservation.outcome })
                end
                if reservation.outcome == 'APPLIED' then
                    local restoredAt, restoredAtUtc = now(), utcNow()
                    if not Validation.isInteger(restoredAt, 0,
                        Limits.maximumSafeInteger)
                        or not Validation.isInteger(restoredAtUtc, 0,
                            Limits.maximumSafeInteger) then
                        failures = failures + 1
                        return Validation.failure('SECURITY_ENFORCEMENT_CLOCK_INVALID',
                            'The security enforcement clocks are invalid.', true)
                    end
                    local restored = {
                        schemaVersion = Limits.schemaVersion,
                        enforcementId = effectiveEnforcementId,
                        caseId = caseValue.caseId,
                        caseRevision = effectiveCaseRevision,
                        policyId = decision.policyId,
                        action = decision.action,
                        reason = decision.reason,
                        idempotencyKey = decision.idempotencyKey,
                        provenanceDigest = effectiveProvenanceDigest,
                        appliedAt = restoredAt,
                        appliedAtUtc = restoredAtUtc,
                        persistenceState = 'APPLIED',
                    }
                    if effectiveExpiresAt ~= nil then
                        restored.expiresAt = effectiveExpiresAt
                    end
                    completed[decision.idempotencyKey] = restored
                    completedCount, duplicates = completedCount + 1, duplicates + 1
                    history.push(restored)
                    return Validation.copy(restored, { maximumBytes = 8192,
                        maximumEntries = 128,
                        maximumStringBytes = Limits.maximumReasonBytes }),
                        nil, { duplicate = true }
                end
            end
        end
        if decision.action ~= 'OBSERVE' and decision.action ~= 'MANUAL_REVIEW' then
            local checked, current = pcall(validateSubject, caseValue, decision)
            if not checked or current ~= true then
                failures = failures + 1
                return Validation.failure('SECURITY_SUBJECT_STALE',
                    'The enforcement subject is no longer current.', true)
            end
        end
        local result, actionError = true, nil
        if decision.action == 'BAN' then
            local request = {
                idempotencyKey = decision.idempotencyKey,
                id = 'sec-ban:' .. Foundation.stableDigest(caseValue.caseId),
                userId = caseValue.subjectUser,
                reason = (('Security case %s; policy %s; %s'):format(
                    caseValue.caseId, decision.policyId, decision.reason))
                    :sub(1, Limits.maximumReasonBytes),
            }
            if effectiveExpiresAt ~= nil then
                local actionUtc = utcNow()
                if not Validation.isInteger(actionUtc, 0,
                    Limits.maximumSafeInteger)
                    or effectiveExpiresAt - actionUtc
                        < Limits.minimumTemporaryBanRemainingMs then
                    failures = failures + 1
                    return Validation.failure('SECURITY_EXPIRY_INVALID',
                        'The temporary ban expiry no longer has a safe application window.',
                        false)
                end
                local formatted, expiry = pcall(formatExpiry, effectiveExpiresAt)
                if not formatted or not Validation.text(expiry, 19, 19)
                    or expiry:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$') == nil then
                    failures = failures + 1
                    return Validation.failure('SECURITY_EXPIRY_INVALID',
                        'The temporary ban expiry could not be represented safely.', true)
                end
                request.expiresAt = expiry
            end
            local called, first, second = pcall(accessBan, request)
            if not called or first == nil or first == false then
                result, actionError = nil, second
            end
        elseif decision.action ~= 'OBSERVE' and decision.action ~= 'MANUAL_REVIEW' then
            local called, first, second = pcall(actionHandler, caseValue, decision)
            if not called or first == nil or first == false then
                result, actionError = nil, second
            end
        end
        if result == nil then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_FAILED',
                'The security enforcement action failed.', true,
                type(actionError) == 'table' and { code = actionError.code } or nil)
        end
        local appliedAt, appliedAtUtc = now(), utcNow()
        if not Validation.isInteger(appliedAt, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(appliedAtUtc, 0, Limits.maximumSafeInteger) then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_CLOCK_INVALID',
                'The security enforcement clocks are invalid.', true)
        end
        local record = {
            schemaVersion = Limits.schemaVersion,
            enforcementId = effectiveEnforcementId,
            caseId = caseValue.caseId,
            caseRevision = effectiveCaseRevision,
            policyId = decision.policyId,
            action = decision.action,
            reason = decision.reason,
            idempotencyKey = decision.idempotencyKey,
            provenanceDigest = effectiveProvenanceDigest,
            decidedAtUtc = decision.decidedAtUtc,
            appliedAt = appliedAt,
            appliedAtUtc = appliedAtUtc,
            persistenceState = 'APPLIED',
        }
        if effectiveExpiresAt ~= nil then record.expiresAt = effectiveExpiresAt end
        if onApplied ~= nil then
            local notified, committed, commitError = pcall(onApplied, record, caseValue)
            if not notified or committed == nil or committed == false then
                record.persistenceState = 'FAILED'
                completed[decision.idempotencyKey] = record
                completedCount = completedCount + 1
                history.push(record)
                failures = failures + 1
                return Validation.failure('SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                    'The applied security action could not be committed durably.', true,
                    type(commitError) == 'table' and { code = commitError.code } or nil)
            end
        end
        completed[decision.idempotencyKey] = record
        completedCount, applied = completedCount + 1, applied + 1
        history.push(record)
        return Validation.copy(record, { maximumBytes = 8192,
            maximumEntries = 128, maximumStringBytes = Limits.maximumReasonBytes }),
            nil, { duplicate = false }
    end

    function api.apply(decision, caseValue)
        local key = type(decision) == 'table' and decision.idempotencyKey or nil
        if not Validation.token(key, 8, 64) then
            return applyLeader(decision, caseValue)
        end
        if inFlight[key] then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_IN_PROGRESS',
                'The same security action is already being processed.', true)
        end
        inFlight[key] = true
        local ok, value, operationError, metadata = pcall(
            applyLeader, decision, caseValue)
        inFlight[key] = nil
        if not ok then
            failures = failures + 1
            return Validation.failure('SECURITY_ENFORCEMENT_FAILED',
                'The security enforcement operation failed safely.', true)
        end
        return value, operationError, metadata
    end

    function api.evaluate(caseValue, policy)
        local decision, decisionError = api.decide(caseValue, policy)
        if not decision then return nil, decisionError end
        return api.apply(decision, caseValue)
    end

    function api.list(request)
        request = request or {}
        local limit = request.limit or 64
        if not Validation.isInteger(limit, 1, 256)
            or request.caseId ~= nil
                and not Validation.token(request.caseId, 8, Limits.maximumIdentifierBytes) then
            return Validation.failure('SECURITY_ENFORCEMENT_INVALID',
                'The security enforcement page request is invalid.')
        end
        local values = assert(history.list({ limit = limit,
            predicate = function(record)
                return request.caseId == nil or record.caseId == request.caseId
            end }))
        local result = {}
        for index, value in ipairs(values) do
            result[index] = Validation.copy(value, { maximumBytes = 8192,
                maximumEntries = 128, maximumStringBytes = Limits.maximumReasonBytes })
        end
        return result, nil
    end

    function api.purge(at)
        return purgeCompleted(at or now())
    end

    function api.snapshot()
        return {
            decisions = decisions,
            applied = applied,
            failures = failures,
            duplicates = duplicates,
            idempotencyEntries = completedCount,
            idempotencyCapacity = options.idempotencyCapacity
                or Limits.maximumEnforcementHistory,
            history = history.size(),
        }
    end

    return api
end
