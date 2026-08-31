SynexSecurityCorrelation = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local RingBuffer = assert(SynexSecurityRingBuffer, 'security ring buffer must be loaded first')
local Correlation = SynexSecurityCorrelation

function Correlation.create(options)
    options = options or {}
    local now = assert(options.now, 'security correlation clock is required')
    assert(Validation.isCallable(now), 'security correlation clock is invalid')
    local expectations = options.expectations
    local byId, expectedBy, subjectCounts = {}, {}, {}
    local ingested, duplicate, rejected, expected = 0, 0, 0, 0
    local store = RingBuffer.create({
        capacity = options.capacity or Limits.maximumCorrelationBuffer,
        retentionMs = options.retentionMs or Limits.signalRetentionMs,
        now = now,
        keyOf = function(signal) return signal.signalId end,
        timestampOf = function(signal) return signal.observedAt end,
        onEvict = function(signal)
            if byId[signal.signalId] == signal then byId[signal.signalId] = nil end
            expectedBy[signal.signalId] = nil
            local key = Foundation.subjectKey(signal)
            subjectCounts[key] = math.max(0, (subjectCounts[key] or 1) - 1)
            if subjectCounts[key] == 0 then subjectCounts[key] = nil end
        end,
    })
    local api = {}

    local function copyAssessment(value)
        return Validation.copy(value, {
            maximumDepth = 8,
            maximumEntries = 512,
            maximumStringBytes = Limits.maximumSummaryBytes,
            maximumBytes = 32768,
        })
    end

    function api.ingest(signal)
        if type(signal) ~= 'table'
            or not Validation.token(signal.signalId, 8, Limits.maximumIdentifierBytes)
            or not Limits.categories[signal.category]
            or not Validation.semanticKey(signal.detector)
            or not Validation.errorCode(signal.code)
            or not Limits.severities[signal.severity]
            or not Limits.evidenceClasses[signal.evidenceClass]
            or not Validation.isFinite(signal.confidence)
            or signal.confidence < 0 or signal.confidence > 1
            or not Validation.isInteger(signal.observedAt, 0, Limits.maximumSafeInteger)
            or not Foundation.subjectKey(signal) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The correlation engine received an invalid security signal.')
        end
        if byId[signal.signalId] ~= nil then
            duplicate = duplicate + 1
            return true, nil, { duplicate = true }
        end
        local copied, copyError = Validation.copy(signal, {
            maximumDepth = Limits.maximumEvidenceDepth + 2,
            maximumEntries = Limits.maximumEvidenceEntries + 64,
            maximumStringBytes = Limits.maximumSummaryBytes,
            maximumBytes = Limits.maximumSignalBytes,
        })
        if not copied then rejected = rejected + 1; return nil, copyError end
        local expectationIds = {}
        if type(expectations) == 'table' and Validation.isCallable(expectations.match) then
            local matches = expectations.match(copied)
            if type(matches) == 'table' then
                for index = 1, math.min(#matches, Limits.maximumExpectationSelectors) do
                    expectationIds[index] = matches[index].expectationId
                end
            end
        end
        if #expectationIds > 0 then expected = expected + 1 end
        local subjectKey = Foundation.subjectKey(copied)
        if (subjectCounts[subjectKey] or 0) >= Limits.maximumSubjectSignals then
            local oldest = assert(store.list({ limit = 1, newestFirst = false,
                predicate = function(value)
                    return Foundation.subjectKey(value) == subjectKey
                end }))
            if oldest[1] ~= nil then store.remove(oldest[1].signalId, 'subject_capacity') end
        end
        local stored, storeError = store.push(copied)
        if not stored then rejected = rejected + 1; return nil, storeError end
        byId[copied.signalId] = copied
        expectedBy[copied.signalId] = expectationIds
        subjectCounts[subjectKey] = (subjectCounts[subjectKey] or 0) + 1
        ingested = ingested + 1
        return true, nil, { duplicate = false, expected = #expectationIds > 0 }
    end

    function api.assess(subject)
        local normalized, subjectError
        if type(subject) == 'string' then
            if not Validation.token(subject, 3, 256) then
                return Validation.failure('SECURITY_SUBJECT_INVALID',
                    'The correlation subject key is invalid.')
            end
        else
            normalized, subjectError = Validation.subject(subject)
            if not normalized then return nil, subjectError end
        end
        local subjectKey = type(subject) == 'string' and subject
            or Validation.subjectKey(normalized)
        local timestamp = now()
        local signalValues = assert(store.list({
            limit = Limits.maximumCorrelationSignals,
            predicate = function(signal)
                return Foundation.subjectKey(signal) == subjectKey
            end,
        }))
        local groups, expectedSignalCount, recentSignalCount = {}, 0, 0
        local subjectValue = normalized
        for _, signal in ipairs(signalValues) do
            subjectValue = subjectValue or Foundation.subjectFromSignal(signal)
            local windowMs = Limits.categoryWindowsMs[signal.category]
                or Limits.signalRetentionMs
            local ageMs = math.max(0, timestamp - signal.observedAt)
            if ageMs <= windowMs then
                recentSignalCount = recentSignalCount + 1
                if type(expectedBy[signal.signalId]) == 'table'
                    and #expectedBy[signal.signalId] > 0 then
                    expectedSignalCount = expectedSignalCount + 1
                else
                    local key = Foundation.hypothesisKey(signal)
                    local group = groups[key]
                    if group == nil then
                        group = {
                            key = key,
                            category = signal.category,
                            correlationKey = signal.correlationKey,
                            detector = signal.detector,
                            roots = {},
                            evidenceClasses = {},
                            codes = {},
                            signalCount = 0,
                            latestAt = signal.observedAt,
                            oldestAt = signal.observedAt,
                            severity = signal.severity,
                        }
                        groups[key] = group
                    end
                    group.signalCount = group.signalCount + 1
                    group.latestAt = math.max(group.latestAt, signal.observedAt)
                    group.oldestAt = math.min(group.oldestAt, signal.observedAt)
                    group.severity = Foundation.maximumSeverity(group.severity, signal.severity)
                    group.evidenceClasses[signal.evidenceClass] = true
                    group.codes[signal.code] = true
                    local contribution = (Limits.evidenceWeights[signal.evidenceClass] or 0)
                        * (Limits.severityWeights[signal.severity] or 0)
                        * signal.confidence
                    contribution = Foundation.decay(contribution, ageMs, windowMs / 2)
                    local independenceKey = Foundation.independenceKey(signal)
                    local root = group.roots[independenceKey]
                    if root == nil or contribution > root.contribution then
                        group.roots[independenceKey] = {
                            contribution = contribution,
                            evidenceClass = signal.evidenceClass,
                            signalId = signal.signalId,
                        }
                    end
                end
            end
        end
        -- One originating event may fan out into several detector hypotheses. Pick
        -- exactly one hypothesis owner for every root so the same request/event can
        -- never become independent evidence twice across categories.
        local rootOwners = {}
        for groupKey, group in pairs(groups) do
            for rootKey, root in pairs(group.roots) do
                local owner = rootOwners[rootKey]
                if owner == nil or root.contribution > owner.contribution
                    or root.contribution == owner.contribution
                        and groupKey < owner.groupKey then
                    rootOwners[rootKey] = {
                        groupKey = groupKey,
                        contribution = root.contribution,
                    }
                end
            end
        end
        local hypotheses, overallConfidence, overallSeverity = {}, 0, 'INFO'
        for _, group in pairs(groups) do
            local remaining, independentEvidence, weakOnly = 1, 0, true
            for rootKey, root in pairs(group.roots) do
                local owner = rootOwners[rootKey]
                if owner ~= nil and owner.groupKey == group.key then
                independentEvidence = independentEvidence + 1
                remaining = remaining * (1 - math.min(0.95,
                    math.max(0, root.contribution)))
                if not Limits.weakEvidenceClasses[root.evidenceClass] then weakOnly = false end
                end
            end
            local classes = Foundation.sortedKeys(group.evidenceClasses)
            local confidence = (1 - remaining)
                * math.min(1, 0.85 + #classes * 0.05)
            if independentEvidence > 1 then
                confidence = confidence + (1 - confidence)
                    * math.min(0.12, (independentEvidence - 1) * 0.03)
            end
            if weakOnly then confidence = math.min(confidence, 0.64) end
            confidence = Foundation.round(confidence)
            local codes = Foundation.sortedKeys(group.codes)
            while #codes > 16 do table.remove(codes) end
            hypotheses[#hypotheses + 1] = {
                key = group.key,
                category = group.category,
                correlationKey = group.correlationKey,
                detector = group.detector,
                confidence = confidence,
                severity = group.severity,
                signalCount = group.signalCount,
                independentEvidence = independentEvidence,
                evidenceClasses = classes,
                weakEvidenceOnly = weakOnly,
                codes = codes,
                oldestAt = group.oldestAt,
                latestAt = group.latestAt,
            }
            if confidence > overallConfidence then overallConfidence = confidence end
            overallSeverity = Foundation.maximumSeverity(overallSeverity, group.severity)
        end
        table.sort(hypotheses, function(left, right)
            if left.confidence == right.confidence then return left.key < right.key end
            return left.confidence > right.confidence
        end)
        while #hypotheses > Limits.maximumHypotheses do table.remove(hypotheses) end
        local activeExpectations = 0
        if type(expectations) == 'table' and Validation.isCallable(expectations.list) then
            local current = expectations.list({ subjectKey = subjectKey, limit = 256 })
            if type(current) == 'table' then activeExpectations = #current end
        end
        local result = {
            schemaVersion = Limits.schemaVersion,
            subject = subjectValue,
            subjectKey = subjectKey,
            assessedAt = timestamp,
            confidence = overallConfidence,
            severity = overallSeverity,
            recentSignalCount = recentSignalCount,
            expectedSignalCount = expectedSignalCount,
            activeExpectations = activeExpectations,
            hypotheses = hypotheses,
        }
        return copyAssessment(result), nil
    end

    function api.assessSignal(signal)
        return api.assess(Foundation.subjectFromSignal(signal))
    end

    function api.contributors(signal, limit)
        local maximum = limit or Limits.maximumCaseSignals
        if type(signal) ~= 'table'
            or not Validation.token(signal.signalId, 8, Limits.maximumIdentifierBytes)
            or not Limits.categories[signal.category]
            or not Validation.semanticKey(signal.detector)
            or not Validation.isInteger(maximum, 1, Limits.maximumCaseSignals) then
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The correlation contributor request is invalid.')
        end
        local subjectKey = Foundation.subjectKey(signal)
        local hypothesisKey = Foundation.hypothesisKey(signal)
        local timestamp = now()
        local values = assert(store.list({
            limit = maximum,
            predicate = function(candidate)
                local windowMs = Limits.categoryWindowsMs[candidate.category]
                    or Limits.signalRetentionMs
                return Foundation.subjectKey(candidate) == subjectKey
                    and Foundation.hypothesisKey(candidate) == hypothesisKey
                    and timestamp - candidate.observedAt <= windowMs
                    and type(expectedBy[candidate.signalId]) == 'table'
                    and #expectedBy[candidate.signalId] == 0
            end,
        }))
        local result = {}
        for index, candidate in ipairs(values) do
            result[index] = Validation.copy(candidate, {
                maximumDepth = Limits.maximumEvidenceDepth + 2,
                maximumEntries = Limits.maximumEvidenceEntries + 64,
                maximumStringBytes = Limits.maximumSummaryBytes,
                maximumBytes = Limits.maximumSignalBytes,
            })
        end
        return result, nil
    end

    function api.purge(at)
        return store.prune(at or now())
    end

    function api.snapshot()
        local buffer = store.snapshot()
        return {
            ingested = ingested,
            duplicates = duplicate,
            rejected = rejected,
            expectationFiltered = expected,
            activeSignals = buffer.count,
            subjects = #Foundation.sortedKeys(subjectCounts),
            capacity = buffer.capacity,
        }
    end

    return api
end
