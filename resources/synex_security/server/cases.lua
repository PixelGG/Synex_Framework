SynexSecurityCases = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local Cases = SynexSecurityCases

local TRANSITIONS = {
    OPEN = { MONITORING = true, REVIEW = true, ENFORCED = true, CLOSED = true },
    MONITORING = { OPEN = true, REVIEW = true, ENFORCED = true, CLOSED = true },
    REVIEW = { MONITORING = true, ENFORCED = true, CLOSED = true },
    ENFORCED = { REVIEW = true, CLOSED = true },
    CLOSED = {},
}

function Cases.create(options)
    options = options or {}
    local now = assert(options.now, 'security case clock is required')
    assert(Validation.isCallable(now), 'security case clock is invalid')
    local nowIso = Validation.isCallable(options.nowIso) and options.nowIso or nil
    local serial = 0
    local nextId = Validation.isCallable(options.nextId) and options.nextId or function()
        serial = serial + 1
        return ('security:case:%012d'):format(serial)
    end
    local saveCase = Validation.isCallable(options.saveCase) and options.saveCase or nil
    local capacity = Validation.isInteger(options.capacity, 1, Limits.maximumCases)
        and options.capacity or Limits.maximumCases
    local closedArchiveCapacity = Validation.isInteger(options.closedArchiveCapacity,
        0, capacity) and options.closedArchiveCapacity
        or math.min(Limits.maximumClosedCaseArchive, capacity)
    local values, archived, archiveOrder, activeByHypothesis = {}, {}, {}, {}
    local closedByHypothesis = {}
    local count, archiveCount, restoreAttempted = 0, 0, false
    local created, updated, closed, enforced = 0, 0, 0, 0
    local api = {}

    local function timestampPair()
        local milliseconds = now()
        local iso = nowIso ~= nil and nowIso(milliseconds) or nil
        if not Validation.text(iso, 20, 32) then
            local seconds = math.floor(milliseconds / 1000)
            iso = os.date('!%Y-%m-%dT%H:%M:%SZ', seconds)
        end
        return milliseconds, iso
    end

    local function copyCase(value)
        return Validation.copy(value, {
            maximumDepth = 8,
            maximumEntries = 256,
            maximumStringBytes = Limits.maximumReasonBytes,
            maximumBytes = 16384,
        })
    end

    local function persist(proposed)
        if saveCase == nil then return true, nil end
        local ok, result, saveError = pcall(saveCase, copyCase(proposed))
        if not ok or result == nil or result == false then
            return Validation.failure('SECURITY_CASE_PERSISTENCE_FAILED',
                'The security case could not be persisted.', true,
                type(saveError) == 'table' and { code = saveError.code } or nil)
        end
        return true, nil
    end

    local function removeArchived(caseId)
        local archivedValue = archived[caseId]
        if archivedValue == nil then return end
        local identity = archivedValue.subjectUser ~= nil
            and 'user:' .. archivedValue.subjectUser or archivedValue.subjectKey
        local activeKey = identity .. '|' .. archivedValue.hypothesisKey
        if closedByHypothesis[activeKey] == caseId then
            closedByHypothesis[activeKey] = nil
        end
        archived[caseId] = nil
        archiveCount = archiveCount - 1
        for index, archivedId in ipairs(archiveOrder) do
            if archivedId == caseId then table.remove(archiveOrder, index); break end
        end
    end

    local function archiveCase(value)
        removeArchived(value.caseId)
        if closedArchiveCapacity == 0 then return end
        archived[value.caseId] = value
        local identity = value.subjectUser ~= nil and 'user:' .. value.subjectUser
            or value.subjectKey
        closedByHypothesis[identity .. '|' .. value.hypothesisKey] = value.caseId
        archiveOrder[#archiveOrder + 1] = value.caseId
        archiveCount = archiveCount + 1
        while archiveCount > closedArchiveCapacity do
            local evictedId = archiveOrder[1]
            if evictedId ~= nil and archived[evictedId] ~= nil then
                removeArchived(evictedId)
            else
                table.remove(archiveOrder, 1)
            end
        end
    end

    local function identityKey(subject, subjectKey)
        if subject.userId ~= nil then return 'user:' .. subject.userId end
        return subjectKey
    end

    local function hypothesisFrom(assessment, hypothesisKey)
        if type(assessment) ~= 'table' or type(assessment.hypotheses) ~= 'table' then
            return nil
        end
        if hypothesisKey == nil then return assessment.hypotheses[1] end
        for _, hypothesis in ipairs(assessment.hypotheses) do
            if hypothesis.key == hypothesisKey then return hypothesis end
        end
        return nil
    end

    local function summaries(assessment, hypothesis)
        local codes = {}
        for index = 1, math.min(#(hypothesis.codes or {}), 16) do
            codes[index] = hypothesis.codes[index]
        end
        local classes = {}
        for index = 1, math.min(#(hypothesis.evidenceClasses or {}),
            Limits.maximumCaseEvidenceClasses) do
            classes[index] = hypothesis.evidenceClasses[index]
        end
        return {
            count = hypothesis.signalCount,
            codes = codes,
            firstAt = hypothesis.oldestAt,
            lastAt = hypothesis.latestAt,
        }, {
            independentEvidence = hypothesis.independentEvidence,
            evidenceClasses = classes,
            weakEvidenceOnly = hypothesis.weakEvidenceOnly == true,
            expectationFiltered = assessment.expectedSignalCount or 0,
        }
    end

    local function arraysEqual(left, right)
        if type(left) ~= 'table' or type(right) ~= 'table'
            or #left ~= #right then return false end
        for index = 1, #left do
            if left[index] ~= right[index] then return false end
        end
        return true
    end

    local function assessmentUnchanged(value, assessment, hypothesis,
        signalSummary, evidenceSummary)
        local currentSignals = value.signalSummary or {}
        local currentEvidence = value.evidenceSummary or {}
        return value.subjectSession == assessment.subject.sessionId
            and value.subjectSource == assessment.subject.source
            and value.subjectCharacter == assessment.subject.characterId
            and value.sourceGeneration == assessment.subject.sourceGeneration
            and value.subjectKey == assessment.subjectKey
            and value.severity == Foundation.maximumSeverity(
                value.severity, hypothesis.severity)
            and value.confidence == hypothesis.confidence
            and currentSignals.count == signalSummary.count
            and currentSignals.firstAt == signalSummary.firstAt
            and currentSignals.lastAt == signalSummary.lastAt
            and arraysEqual(currentSignals.codes or {}, signalSummary.codes or {})
            and currentEvidence.independentEvidence
                == evidenceSummary.independentEvidence
            and currentEvidence.weakEvidenceOnly
                == evidenceSummary.weakEvidenceOnly
            and currentEvidence.expectationFiltered
                == evidenceSummary.expectationFiltered
            and arraysEqual(currentEvidence.evidenceClasses or {},
                evidenceSummary.evidenceClasses or {})
    end

    local mutationLocks = {}
    local function valueMutationKey(value)
        if type(value) ~= 'table' or type(value.hypothesisKey) ~= 'string' then
            return nil
        end
        local identity = value.subjectUser ~= nil and 'user:' .. value.subjectUser
            or value.subjectKey
        return type(identity) == 'string' and identity .. '|' .. value.hypothesisKey
            or nil
    end

    local function assessmentMutationKey(assessment, hypothesisKey)
        if type(assessment) ~= 'table' or type(assessment.subject) ~= 'table' then
            return nil
        end
        local hypothesis = hypothesisFrom(assessment, hypothesisKey)
        if hypothesis == nil or type(hypothesis.key) ~= 'string'
            or not Validation.subjectKey(assessment.subject) then return nil end
        return identityKey(assessment.subject, assessment.subjectKey)
            .. '|' .. hypothesis.key
    end

    local function withMutation(key, operation)
        if key == nil then return operation() end
        if mutationLocks[key] then
            return Validation.failure('SECURITY_CASE_IN_PROGRESS',
                'The same security case is already being updated.', true)
        end
        mutationLocks[key] = true
        local ok, value, operationError, metadata = pcall(operation)
        mutationLocks[key] = nil
        if not ok then
            return Validation.failure('SECURITY_CASE_PERSISTENCE_FAILED',
                'The security case mutation failed safely.', true)
        end
        return value, operationError, metadata
    end

    local updateFromAssessmentLeader
    local function openFromAssessmentLeader(assessment, hypothesisKey)
        local hypothesis = hypothesisFrom(assessment, hypothesisKey)
        if hypothesis == nil or not Validation.subjectKey(assessment.subject)
            or not Validation.isFinite(hypothesis.confidence)
            or hypothesis.confidence < (options.minimumConfidence
                or Limits.minimumCaseConfidence)
            or not Limits.severities[hypothesis.severity]
            or not Limits.categories[hypothesis.category] then
            return Validation.failure('SECURITY_CASE_THRESHOLD',
                'The security assessment does not justify opening a case.')
        end
        local identity = identityKey(assessment.subject, assessment.subjectKey)
        local activeKey = identity .. '|' .. hypothesis.key
        local existingId = activeByHypothesis[activeKey]
        if existingId ~= nil and values[existingId] ~= nil
            and values[existingId].status ~= 'CLOSED' then
            return updateFromAssessmentLeader(existingId, assessment, hypothesis.key)
        end
        if closedByHypothesis[activeKey] ~= nil then
            return Validation.failure('SECURITY_CASE_REOPEN_REQUIRED',
                'A closed case already owns this active hypothesis; explicit reopen is required.',
                true)
        end
        if count >= capacity then
            return Validation.failure('SECURITY_CASE_LIMIT',
                'The bounded security case registry is full.', true)
        end
        local caseId = nextId('security.case')
        if not Validation.token(caseId, 8, Limits.maximumIdentifierBytes) then
            return Validation.failure('SECURITY_ID_INVALID',
                'The security case identifier is invalid.', true)
        end
        local timestamp, timestampIso = timestampPair()
        local signalSummary, evidenceSummary = summaries(assessment, hypothesis)
        local value = {
            schemaVersion = Limits.schemaVersion,
            caseId = caseId,
            subjectUser = assessment.subject.userId,
            subjectSource = assessment.subject.source,
            subjectSession = assessment.subject.sessionId,
            subjectCharacter = assessment.subject.characterId,
            subjectResource = assessment.subject.resourceName,
            sourceGeneration = assessment.subject.sourceGeneration,
            subjectKey = assessment.subjectKey,
            hypothesisKey = hypothesis.key,
            correlationKey = hypothesis.correlationKey,
            category = hypothesis.category,
            severity = hypothesis.severity,
            confidence = hypothesis.confidence,
            peakConfidence = hypothesis.confidence,
            openedAtMs = timestamp,
            openedAt = timestampIso,
            updatedAtMs = timestamp,
            updatedAt = timestampIso,
            status = 'OPEN',
            revision = 1,
            signalSummary = signalSummary,
            evidenceSummary = evidenceSummary,
            enforcementSummary = { count = 0 },
        }
        local persisted, persistError = persist(value)
        if not persisted then return nil, persistError end
        values[caseId], activeByHypothesis[activeKey] = value, caseId
        count, created = count + 1, created + 1
        return copyCase(value), nil, { created = true }
    end

    updateFromAssessmentLeader = function(caseId, assessment, hypothesisKey)
        local value = values[caseId]
        if value == nil then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case was not found.')
        end
        if value.status == 'CLOSED' then
            return Validation.failure('SECURITY_CASE_CLOSED',
                'A closed security case requires an explicit reopen policy.')
        end
        local hypothesis = hypothesisFrom(assessment, hypothesisKey or value.hypothesisKey)
        if hypothesis == nil or not Validation.subjectKey(assessment.subject) then
            return Validation.failure('SECURITY_CASE_INVALID',
                'The security case assessment is invalid.')
        end
        local expectedIdentity = value.subjectUser ~= nil and 'user:' .. value.subjectUser
            or value.subjectKey
        if identityKey(assessment.subject, assessment.subjectKey) ~= expectedIdentity then
            return Validation.failure('SECURITY_CASE_SUBJECT_MISMATCH',
                'The security assessment belongs to another subject.')
        end
        local signalSummary, evidenceSummary = summaries(assessment, hypothesis)
        if assessmentUnchanged(value, assessment, hypothesis,
            signalSummary, evidenceSummary) then
            return copyCase(value), nil, { created = false, unchanged = true }
        end
        local proposed = copyCase(value)
        proposed.subjectSession = assessment.subject.sessionId
        proposed.subjectSource = assessment.subject.source
        proposed.subjectCharacter = assessment.subject.characterId
        proposed.sourceGeneration = assessment.subject.sourceGeneration
        proposed.subjectKey = assessment.subjectKey
        proposed.severity = Foundation.maximumSeverity(value.severity, hypothesis.severity)
        proposed.confidence = hypothesis.confidence
        proposed.peakConfidence = math.max(value.peakConfidence, hypothesis.confidence)
        proposed.updatedAtMs, proposed.updatedAt = timestampPair()
        proposed.revision = value.revision + 1
        proposed.signalSummary = signalSummary
        proposed.evidenceSummary = evidenceSummary
        if proposed.status == 'OPEN' then proposed.status = 'MONITORING' end
        local persisted, persistError = persist(proposed)
        if not persisted then return nil, persistError end
        values[caseId] = proposed
        updated = updated + 1
        return copyCase(proposed), nil, { created = false }
    end

    local function transitionLeader(caseId, targetStatus, context)
        context = context or {}
        local value = values[caseId]
        if value == nil then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case was not found.')
        end
        if not Limits.caseStates[targetStatus]
            or not Validation.isInteger(context.expectedRevision, 1,
                Limits.maximumSafeInteger)
            or context.expectedRevision ~= value.revision
            or not Validation.text(context.reason, 1, Limits.maximumReasonBytes) then
            return Validation.failure('SECURITY_CASE_STALE',
                'The security case transition or revision is invalid.', true)
        end
        if not TRANSITIONS[value.status][targetStatus] then
            return Validation.failure('SECURITY_CASE_TRANSITION_DENIED',
                'The requested security case transition is not allowed.')
        end
        local proposed = copyCase(value)
        proposed.status = targetStatus
        proposed.statusReason = context.reason
        proposed.updatedAtMs, proposed.updatedAt = timestampPair()
        if targetStatus == 'CLOSED' then
            proposed.closedAtMs, proposed.closedAt = proposed.updatedAtMs, proposed.updatedAt
        end
        proposed.revision = value.revision + 1
        local persisted, persistError = persist(proposed)
        if not persisted then return nil, persistError end
        if targetStatus == 'CLOSED' then
            local identity = value.subjectUser ~= nil and 'user:' .. value.subjectUser
                or value.subjectKey
            activeByHypothesis[identity .. '|' .. value.hypothesisKey] = nil
            values[caseId] = nil
            count = count - 1
            archiveCase(proposed)
            closed = closed + 1
        else
            values[caseId] = proposed
            if targetStatus == 'ENFORCED' then enforced = enforced + 1 end
        end
        return copyCase(proposed), nil
    end

    local function reopenLeader(caseId, context)
        context = context or {}
        local value = archived[caseId]
        if value == nil then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case was not found.')
        end
        if value.status ~= 'CLOSED'
            or context.expectedRevision ~= value.revision
            or not Validation.text(context.reason, 1, Limits.maximumReasonBytes) then
            return Validation.failure('SECURITY_CASE_REOPEN_DENIED',
                'Only a current closed security case can be reopened explicitly.')
        end
        local proposed = copyCase(value)
        proposed.status = 'OPEN'
        proposed.statusReason = context.reason
        proposed.updatedAtMs, proposed.updatedAt = timestampPair()
        proposed.closedAtMs, proposed.closedAt = nil, nil
        proposed.revision = value.revision + 1
        local identity = value.subjectUser ~= nil and 'user:' .. value.subjectUser
            or value.subjectKey
        local activeKey = identity .. '|' .. value.hypothesisKey
        if activeByHypothesis[activeKey] ~= nil then
            return Validation.failure('SECURITY_CASE_CONFLICT',
                'Another active case already tracks this hypothesis.')
        end
        if count >= capacity then
            return Validation.failure('SECURITY_CASE_LIMIT',
                'The bounded security case registry is full.', true)
        end
        local persisted, persistError = persist(proposed)
        if not persisted then return nil, persistError end
        removeArchived(caseId)
        values[caseId], activeByHypothesis[activeKey] = proposed, caseId
        count = count + 1
        return copyCase(proposed), nil
    end

    local function attachEnforcementLeader(caseId, record)
        local value = values[caseId] or archived[caseId]
        if value == nil then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case was not found.')
        end
        if type(record) ~= 'table'
            or not Validation.token(record.enforcementId, 8, Limits.maximumIdentifierBytes)
            or not Limits.enforcementActions[record.action]
            or not Validation.isInteger(record.appliedAt, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_ENFORCEMENT_INVALID',
                'The security enforcement summary is invalid.')
        end
        if type(value.enforcementSummary) == 'table'
            and value.enforcementSummary.lastEnforcementId
                == record.enforcementId then
            return copyCase(value), nil, { duplicate = true }
        end
        if value.status == 'CLOSED' then
            return Validation.failure('SECURITY_CASE_CLOSED',
                'A closed security case cannot receive enforcement.')
        end
        local proposed = copyCase(value)
        proposed.enforcementSummary = {
            count = (value.enforcementSummary.count or 0) + 1,
            lastAction = record.action,
            lastAt = record.appliedAt,
            lastEnforcementId = record.enforcementId,
        }
        if record.action == 'MANUAL_REVIEW' then proposed.status = 'REVIEW'
        elseif record.action ~= 'OBSERVE' then proposed.status = 'ENFORCED' end
        proposed.updatedAtMs, proposed.updatedAt = timestampPair()
        proposed.revision = value.revision + 1
        local persisted, persistError = persist(proposed)
        if not persisted then return nil, persistError end
        values[caseId] = proposed
        if proposed.status == 'ENFORCED' then enforced = enforced + 1 end
        return copyCase(proposed), nil
    end

    function api.openFromAssessment(assessment, hypothesisKey)
        local key = assessmentMutationKey(assessment, hypothesisKey)
        return withMutation(key, function()
            return openFromAssessmentLeader(assessment, hypothesisKey)
        end)
    end

    function api.updateFromAssessment(caseId, assessment, hypothesisKey)
        local key = valueMutationKey(values[caseId])
            or assessmentMutationKey(assessment, hypothesisKey)
        return withMutation(key, function()
            return updateFromAssessmentLeader(caseId, assessment, hypothesisKey)
        end)
    end

    function api.transition(caseId, targetStatus, context)
        local key = valueMutationKey(values[caseId] or archived[caseId])
        return withMutation(key, function()
            return transitionLeader(caseId, targetStatus, context)
        end)
    end

    function api.reopen(caseId, context)
        local key = valueMutationKey(archived[caseId] or values[caseId])
        return withMutation(key, function()
            return reopenLeader(caseId, context)
        end)
    end

    function api.attachEnforcement(caseId, record)
        local key = valueMutationKey(values[caseId] or archived[caseId])
        return withMutation(key, function()
            return attachEnforcementLeader(caseId, record)
        end)
    end

    function api.get(caseId)
        local value = values[caseId] or archived[caseId]
        if value == nil then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case was not found.')
        end
        return copyCase(value), nil
    end

    function api.list(request)
        request = request or {}
        local limit = request.limit or 64
        local offset = request.offset or 0
        if not Validation.isInteger(limit, 1, 256)
            or not Validation.isInteger(offset, 0,
                capacity + closedArchiveCapacity)
            or request.status ~= nil and not Limits.caseStates[request.status]
            or request.subjectUser ~= nil
                and not Validation.token(request.subjectUser, 3, 96)
            or request.subjectKey ~= nil
                and not Validation.token(request.subjectKey, 3, 256) then
            return Validation.failure('SECURITY_CASE_INVALID',
                'The security case page request is invalid.')
        end
        local ordered = {}
        for _, value in pairs(values) do
            if (request.status == nil or value.status == request.status)
                and (request.subjectUser == nil
                    or value.subjectUser == request.subjectUser)
                and (request.subjectKey == nil
                    or value.subjectKey == request.subjectKey) then
                ordered[#ordered + 1] = value
            end
        end
        for _, value in pairs(archived) do
            if (request.status == nil or value.status == request.status)
                and (request.subjectUser == nil
                    or value.subjectUser == request.subjectUser)
                and (request.subjectKey == nil
                    or value.subjectKey == request.subjectKey) then
                ordered[#ordered + 1] = value
            end
        end
        table.sort(ordered, function(left, right)
            if left.updatedAtMs == right.updatedAtMs then return left.caseId < right.caseId end
            return left.updatedAtMs > right.updatedAtMs
        end)
        local result = {}
        for index = offset + 1, math.min(offset + limit, #ordered) do
            result[#result + 1] = copyCase(ordered[index])
        end
        return result, nil
    end

    function api.restore(records)
        local length = Validation.arrayLength(records, capacity + closedArchiveCapacity)
        if length == nil or count ~= 0 or archiveCount ~= 0 or restoreAttempted then
            return Validation.failure('SECURITY_CASE_RESTORE_INVALID',
                'Security cases can only be restored once from a bounded array.')
        end
        restoreAttempted = true
        local staged, stagedActive, ordered = {}, {}, {}
        local activeCount = 0
        for index = 1, length do
            local value = records[index]
            if type(value) ~= 'table'
                or not Validation.token(value.caseId, 8, Limits.maximumIdentifierBytes)
                or not Limits.caseStates[value.status]
                or not Limits.categories[value.category]
                or not Limits.severities[value.severity]
                or not Validation.isFinite(value.confidence)
                or value.confidence < 0 or value.confidence > 1
                or not Validation.isInteger(value.openedAtMs, 0, Limits.maximumSafeInteger)
                or not Validation.isInteger(value.updatedAtMs, 0, Limits.maximumSafeInteger)
                or not Validation.text(value.openedAt, 20, 32)
                or not Validation.text(value.updatedAt, 20, 32)
                or not Validation.token(value.subjectKey, 3, 256)
                or not Validation.token(value.hypothesisKey, 3, 256)
                or value.subjectUser ~= nil
                    and not Validation.token(value.subjectUser, 3, 96)
                or value.subjectSession ~= nil
                    and not Validation.token(value.subjectSession, 3, 96)
                or value.subjectCharacter ~= nil
                    and not Validation.token(value.subjectCharacter, 3, 96)
                or value.subjectResource ~= nil
                    and not Validation.resourceName(value.subjectResource)
                or not Validation.isInteger(value.revision, 1,
                    Limits.maximumSafeInteger)
                or staged[value.caseId] ~= nil then
                return Validation.failure('SECURITY_CASE_RESTORE_INVALID',
                    'A persisted security case is invalid.')
            end
            local copied, copyError = copyCase(value)
            if not copied then return nil, copyError end
            if copied.status ~= 'CLOSED' then
                local identity = copied.subjectUser ~= nil and 'user:' .. copied.subjectUser
                    or copied.subjectKey
                local activeKey = identity .. '|' .. copied.hypothesisKey
                if stagedActive[activeKey] ~= nil then
                    return Validation.failure('SECURITY_CASE_RESTORE_INVALID',
                        'Persisted security cases contain an active hypothesis conflict.')
                end
                stagedActive[activeKey] = copied.caseId
                activeCount = activeCount + 1
            end
            staged[copied.caseId] = copied
            ordered[#ordered + 1] = copied
        end
        if activeCount > capacity then
            return Validation.failure('SECURITY_CASE_RESTORE_INVALID',
                'Persisted active security cases exceed the bounded registry.')
        end
        table.sort(ordered, function(left, right)
            if left.updatedAtMs == right.updatedAtMs then
                if left.updatedAt == right.updatedAt then return left.caseId < right.caseId end
                return left.updatedAt < right.updatedAt
            end
            return left.updatedAtMs < right.updatedAtMs
        end)
        local baseline = now()
        if not Validation.isInteger(baseline, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_CASE_RESTORE_INVALID',
                'The security case restore clock is invalid.')
        end
        values, activeByHypothesis, count = {}, stagedActive, activeCount
        for index, copied in ipairs(ordered) do
            local rebased = math.max(0, baseline - (#ordered - index))
            copied.openedAtMs = math.max(0, rebased - 1)
            copied.updatedAtMs = rebased
            if type(copied.signalSummary) == 'table' then
                if copied.signalSummary.firstAt ~= nil then
                    copied.signalSummary.firstAt = copied.openedAtMs
                end
                if copied.signalSummary.lastAt ~= nil then
                    copied.signalSummary.lastAt = rebased
                end
            end
            if type(copied.enforcementSummary) == 'table'
                and copied.enforcementSummary.lastAt ~= nil then
                copied.enforcementSummary.lastAt = rebased
            end
            if copied.status == 'CLOSED' then
                copied.closedAtMs = rebased
                archiveCase(copied)
            else
                copied.closedAtMs = nil
                values[copied.caseId] = copied
            end
        end
        return count + archiveCount, nil
    end

    function api.snapshot()
        local states = {}
        for _, value in pairs(values) do states[value.status] = (states[value.status] or 0) + 1 end
        for _, value in pairs(archived) do
            states[value.status] = (states[value.status] or 0) + 1
        end
        return {
            total = count + archiveCount,
            active = count,
            archived = archiveCount,
            capacity = capacity,
            archiveCapacity = closedArchiveCapacity,
            created = created,
            updated = updated,
            closed = closed,
            enforced = enforced,
            states = states,
        }
    end

    function api.audit()
        local orphaned, indexEntries = {}, 0
        local indexed = {}
        for caseId, value in pairs(values) do
            local expectedSubjectKey = Validation.subjectKey({
                source = value.subjectSource,
                sessionId = value.subjectSession,
                sourceGeneration = value.sourceGeneration,
                userId = value.subjectUser,
                characterId = value.subjectCharacter,
                resourceName = value.subjectResource,
            })
            local identity = value.subjectUser ~= nil
                and 'user:' .. value.subjectUser or value.subjectKey
            local activeKey = identity .. '|' .. value.hypothesisKey
            indexed[activeKey] = caseId
            if expectedSubjectKey == nil or expectedSubjectKey ~= value.subjectKey
                or activeByHypothesis[activeKey] ~= caseId then
                orphaned['case:' .. caseId] = true
            end
        end
        for activeKey, caseId in pairs(activeByHypothesis) do
            indexEntries = indexEntries + 1
            if values[caseId] == nil or indexed[activeKey] ~= caseId then
                orphaned['index:' .. activeKey] = true
            end
        end
        local orphanCases = 0
        for _ in pairs(orphaned) do orphanCases = orphanCases + 1 end
        return {
            activeCases = count,
            indexEntries = indexEntries,
            orphanCases = orphanCases,
        }, nil
    end

    return api
end
