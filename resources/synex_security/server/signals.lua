SynexSecuritySignals = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local RingBuffer = assert(SynexSecurityRingBuffer, 'security ring buffer must be loaded first')
local Signals = SynexSecuritySignals

local REQUEST_KEYS = {
    namespace = true, category = true, detector = true, code = true, subject = true,
    severity = true, confidence = true, evidenceClass = true, correlationKey = true,
    worldRef = true, entityRef = true, traceId = true, rootEventId = true,
    requestId = true, summary = true, evidence = true,
}

local REQUIRED_REQUEST_KEYS = {
    namespace = true, category = true, detector = true, code = true, subject = true,
    severity = true, confidence = true, evidenceClass = true, correlationKey = true,
    summary = true,
}

function Signals.create(options)
    options = options or {}
    local now = assert(options.now, 'security signal clock is required')
    assert(Validation.isCallable(now), 'security signal clock is invalid')
    local utcNow = Validation.isCallable(options.utcNow) and options.utcNow or nil
    local serial = 0
    local nextId = Validation.isCallable(options.nextId) and options.nextId or function()
        serial = serial + 1
        return ('security:signal:%012d'):format(serial)
    end
    local authorizeNamespace = Validation.isCallable(options.authorizeNamespace)
        and options.authorizeNamespace or Validation.namespaceOwned
    local isOwnerCurrent = Validation.isCallable(options.isOwnerCurrent)
        and options.isOwnerCurrent or nil
    local isSessionCurrent = Validation.isCallable(options.isSessionCurrent)
        and options.isSessionCurrent or nil
    local onAccepted = Validation.isCallable(options.onAccepted) and options.onAccepted or nil
    local onDuplicate = Validation.isCallable(options.onDuplicate)
        and options.onDuplicate or nil
    local byId, dedupe, dedupeKeys, subjectCounts, categoryCounts = {}, {}, {}, {}, {}
    local pipelinePending, pipelinePendingCount = {}, 0
    local pipelineDeliveryFailures, pipelineRetries = 0, 0
    local accepted, duplicates, rejected, evicted = 0, 0, 0, 0
    local store = RingBuffer.create({
        capacity = options.capacity or Limits.maximumSignalBuffer,
        retentionMs = options.retentionMs or Limits.signalRetentionMs,
        now = now,
        keyOf = function(signal) return signal.signalId end,
        timestampOf = function(signal) return signal.observedAt end,
        onEvict = function(signal)
            if pipelinePending[signal.signalId] ~= nil then
                pipelinePending[signal.signalId] = nil
                pipelinePendingCount = math.max(0, pipelinePendingCount - 1)
            end
            if byId[signal.signalId] == signal then byId[signal.signalId] = nil end
            local key = dedupeKeys[signal.signalId]
            if key ~= nil and dedupe[key] == signal then
                dedupe[key] = nil
            end
            dedupeKeys[signal.signalId] = nil
            local subjectKey = Foundation.subjectKey(signal)
            subjectCounts[subjectKey] = math.max(0, (subjectCounts[subjectKey] or 1) - 1)
            if subjectCounts[subjectKey] == 0 then subjectCounts[subjectKey] = nil end
            categoryCounts[signal.category] = math.max(0,
                (categoryCounts[signal.category] or 1) - 1)
            if categoryCounts[signal.category] == 0 then
                categoryCounts[signal.category] = nil
            end
            evicted = evicted + 1
        end,
    })
    local api = {}

    local function copySignal(signal)
        return Validation.copy(signal, {
            maximumDepth = Limits.maximumEvidenceDepth + 2,
            maximumEntries = Limits.maximumEvidenceEntries + 64,
            maximumStringBytes = Limits.maximumSummaryBytes,
            maximumBytes = Limits.maximumSignalBytes,
        })
    end

    local function deliver(signal, retry)
        if onAccepted == nil then return true, nil end
        if retry then pipelineRetries = pipelineRetries + 1 end
        local ok, acceptedValue, operationError = pcall(onAccepted,
            copySignal(signal))
        if ok and acceptedValue ~= nil and acceptedValue ~= false then
            if pipelinePending[signal.signalId] ~= nil then
                pipelinePending[signal.signalId] = nil
                pipelinePendingCount = math.max(0, pipelinePendingCount - 1)
            end
            return true, nil
        end
        pipelineDeliveryFailures = pipelineDeliveryFailures + 1
        if pipelinePending[signal.signalId] == nil then
            pipelinePending[signal.signalId] = true
            pipelinePendingCount = pipelinePendingCount + 1
        end
        if ok and type(operationError) == 'table' then return nil, operationError end
        local _, failure = Validation.failure('SECURITY_SIGNAL_PIPELINE_FAILED',
            'The accepted signal is waiting for bounded pipeline retry.', true)
        return nil, failure
    end

    function api.emit(request, context)
        context = context or {}
        if not Validation.exactObject(request, REQUEST_KEYS, REQUIRED_REQUEST_KEYS) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal contains unsupported or missing fields.')
        end
        if not Validation.resourceName(context.ownerResource)
            or not Validation.isInteger(context.ownerEpoch, 1, Limits.maximumSafeInteger)
            or isOwnerCurrent ~= nil
                and not isOwnerCurrent(context.ownerResource, context.ownerEpoch) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security signal owner is invalid or stale.')
        end
        if not Validation.namespace(request.namespace)
            or not authorizeNamespace(context.ownerResource, request.namespace) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_NAMESPACE_DENIED',
                'The resource does not own the requested security namespace.')
        end
        if not Validation.semanticKey(request.detector)
            or request.detector ~= request.namespace
                and request.detector:sub(1, #request.namespace + 1)
                    ~= request.namespace .. '.'
            or not Validation.errorCode(request.code)
            or not Limits.categories[request.category]
            or not Limits.severities[request.severity]
            or not Limits.evidenceClasses[request.evidenceClass]
            or not Validation.isFinite(request.confidence)
            or request.confidence < 0 or request.confidence > 1
            or not Validation.safeText(request.summary, 1, Limits.maximumSummaryBytes) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal classification is invalid.')
        end
        local subject, subjectError = Validation.subject(request.subject)
        if not subject then rejected = rejected + 1; return nil, subjectError end
        if isSessionCurrent ~= nil and subject.sessionId ~= nil
            and not isSessionCurrent(subject.sessionId, subject.sourceGeneration, subject) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_SUBJECT_STALE',
                'The security signal refers to a stale player session.')
        end
        if request.correlationKey ~= nil
            and (not Validation.token(request.correlationKey, 3, 128)
                or not Validation.safeText(request.correlationKey, 3, 128))
            or request.traceId ~= nil
                and (not Validation.token(request.traceId, 3, 96)
                    or not Validation.safeText(request.traceId, 3, 96))
            or request.rootEventId ~= nil
                and (not Validation.token(request.rootEventId, 3, 96)
                    or not Validation.safeText(request.rootEventId, 3, 96))
            or request.requestId ~= nil
                and (not Validation.token(request.requestId, 3, 96)
                    or not Validation.safeText(request.requestId, 3, 96)) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal correlation references are invalid.')
        end
        local evidence, evidenceError = nil, nil
        if request.evidence ~= nil then
            evidence, evidenceError = Validation.copy(request.evidence, {
                maximumBytes = Limits.maximumEvidenceBytes,
                maximumDepth = Limits.maximumEvidenceDepth,
                maximumEntries = Limits.maximumEvidenceEntries,
                maximumStringBytes = Limits.maximumEvidenceStringBytes,
            })
            if not evidence then rejected = rejected + 1; return nil, evidenceError end
            if not Validation.sensitiveFree(evidence) then
                rejected = rejected + 1
                return Validation.failure('SECURITY_SIGNAL_INVALID',
                    'Security evidence contains prohibited sensitive data.')
            end
        end
        local worldRef, worldError = nil, nil
        if request.worldRef ~= nil then
            worldRef, worldError = Validation.copy(request.worldRef, {
                maximumBytes = 1024, maximumDepth = 3, maximumEntries = 16,
                maximumStringBytes = 128,
            })
            if not worldRef then rejected = rejected + 1; return nil, worldError end
            if not Validation.sensitiveFree(worldRef) then
                rejected = rejected + 1
                return Validation.failure('SECURITY_SIGNAL_INVALID',
                    'The security world reference contains prohibited sensitive data.')
            end
        end
        local entityRef, entityError = nil, nil
        if request.entityRef ~= nil then
            entityRef, entityError = Validation.copy(request.entityRef, {
                maximumBytes = 1024, maximumDepth = 3, maximumEntries = 16,
                maximumStringBytes = 128,
            })
            if not entityRef then rejected = rejected + 1; return nil, entityError end
            if not Validation.sensitiveFree(entityRef) then
                rejected = rejected + 1
                return Validation.failure('SECURITY_SIGNAL_INVALID',
                    'The security entity reference contains prohibited sensitive data.')
            end
        end
        local observedAt = now()
        if not Validation.isInteger(observedAt, 0, Limits.maximumSafeInteger) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_CLOCK_INVALID',
                'The security signal clock returned an invalid timestamp.', true)
        end
        local observedAtUtc = utcNow ~= nil and utcNow() or nil
        if utcNow ~= nil and (not Validation.text(observedAtUtc, 20, 32)
            or observedAtUtc:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d')
                == nil) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_CLOCK_INVALID',
                'The security UTC clock returned an invalid timestamp.', true)
        end
        local subjectKey = Validation.subjectKey(subject)
        local root = request.rootEventId or request.requestId or request.traceId
            or request.correlationKey or '-'
        local dedupeKey = table.concat({ subjectKey, context.ownerResource,
            request.detector, request.code, root }, '|')
        local previous = dedupe[dedupeKey]
        if previous ~= nil
            and observedAt - previous.observedAt <= Limits.signalDedupeWindowMs then
            duplicates = duplicates + 1
            if pipelinePending[previous.signalId] ~= nil then
                local delivered, deliveryError = deliver(previous, true)
                if not delivered then
                    return nil, deliveryError, {
                        duplicate = true, signalId = previous.signalId,
                        pipelinePending = true,
                    }
                end
            end
            if onDuplicate ~= nil then pcall(onDuplicate, previous) end
            local copied = copySignal(previous)
            return copied, nil, { duplicate = true, signalId = previous.signalId }
        end
        local signalId = nextId('security.signal')
        if not Validation.token(signalId, 8, Limits.maximumIdentifierBytes) then
            rejected = rejected + 1
            return Validation.failure('SECURITY_ID_INVALID',
                'The security signal identifier provider returned an invalid value.', true)
        end
        local signal = {
            schemaVersion = Limits.schemaVersion,
            signalId = signalId,
            ownerResource = context.ownerResource,
            ownerEpoch = context.ownerEpoch,
            namespace = request.namespace,
            category = request.category,
            detector = request.detector,
            code = request.code,
            subjectSession = subject.sessionId,
            subjectSource = subject.source,
            subjectUser = subject.userId,
            subjectCharacter = subject.characterId,
            subjectResource = subject.resourceName,
            sourceGeneration = subject.sourceGeneration,
            severity = request.severity,
            confidence = Foundation.round(request.confidence),
            evidenceClass = request.evidenceClass,
            observedAt = observedAt,
            summary = request.summary,
        }
        if observedAtUtc ~= nil then signal.observedAtUtc = observedAtUtc end
        if request.correlationKey ~= nil then signal.correlationKey = request.correlationKey end
        if request.traceId ~= nil then signal.traceId = request.traceId end
        if request.rootEventId ~= nil then signal.rootEventId = request.rootEventId end
        if request.requestId ~= nil then signal.requestId = request.requestId end
        if worldRef ~= nil then signal.worldRef = worldRef end
        if entityRef ~= nil then signal.entityRef = entityRef end
        if evidence ~= nil then signal.evidence = evidence end
        local _, payloadError = Validation.payloadBytes(signal, Limits.maximumSignalBytes)
        if payloadError then rejected = rejected + 1; return nil, payloadError end
        if (subjectCounts[subjectKey] or 0) >= Limits.maximumSubjectSignals then
            local oldest = assert(store.list({ limit = 1, newestFirst = false,
                predicate = function(value)
                    return Foundation.subjectKey(value) == subjectKey
                end }))
            if oldest[1] ~= nil then store.remove(oldest[1].signalId, 'subject_capacity') end
        end
        local stored, storeError = store.push(signal)
        if not stored then rejected = rejected + 1; return nil, storeError end
        byId[signalId], dedupe[dedupeKey], dedupeKeys[signalId] = signal, signal, dedupeKey
        subjectCounts[subjectKey] = (subjectCounts[subjectKey] or 0) + 1
        categoryCounts[signal.category] = (categoryCounts[signal.category] or 0) + 1
        accepted = accepted + 1
        local delivered, deliveryError = deliver(signal, false)
        if not delivered then
            return nil, deliveryError, {
                duplicate = false, signalId = signalId, pipelinePending = true,
            }
        end
        return copySignal(signal), nil, { duplicate = false, signalId = signalId }
    end

    function api.get(signalId)
        if not Validation.token(signalId, 8, Limits.maximumIdentifierBytes) then
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal identifier is invalid.')
        end
        store.prune(now())
        local signal = byId[signalId]
        if signal == nil then
            return Validation.failure('SECURITY_SIGNAL_NOT_FOUND',
                'The security signal was not found.')
        end
        return copySignal(signal)
    end

    function api.list(request)
        request = request or {}
        local limit = request.limit or 64
        if not Validation.isInteger(limit, 1, math.min(256,
            options.capacity or Limits.maximumSignalBuffer))
            or request.subjectKey ~= nil
                and not Validation.token(request.subjectKey, 3, 256)
            or request.category ~= nil and not Limits.categories[request.category]
            or request.since ~= nil and not Validation.isInteger(
                request.since, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal page request is invalid.')
        end
        local values = assert(store.list({ limit = limit, predicate = function(signal)
            return (request.subjectKey == nil
                    or Foundation.subjectKey(signal) == request.subjectKey)
                and (request.category == nil or signal.category == request.category)
                and (request.since == nil or signal.observedAt >= request.since)
        end }))
        local result = {}
        for index, signal in ipairs(values) do result[index] = copySignal(signal) end
        return result, nil
    end

    function api.purge(at)
        return store.prune(at or now())
    end

    function api.retry(limit)
        local maximum = Validation.isInteger(limit, 1, 256) and limit or 64
        local values = assert(store.list({
            limit = maximum,
            newestFirst = false,
            predicate = function(signal)
                return pipelinePending[signal.signalId] ~= nil
            end,
        }))
        local delivered = 0
        for _, signal in ipairs(values) do
            local acceptedValue = deliver(signal, true)
            if acceptedValue then delivered = delivered + 1 end
        end
        return {
            attempted = #values,
            delivered = delivered,
            pending = pipelinePendingCount,
        }, nil
    end

    function api.snapshot()
        local buffer = store.snapshot()
        local categories = {}
        for category, count in pairs(categoryCounts) do categories[category] = count end
        return {
            accepted = accepted,
            duplicates = duplicates,
            rejected = rejected,
            evicted = evicted,
            active = buffer.count,
            capacity = buffer.capacity,
            retentionMs = buffer.retentionMs,
            subjects = #Foundation.sortedKeys(subjectCounts),
            categories = categories,
            pipelinePending = pipelinePendingCount,
            pipelineDeliveryFailures = pipelineDeliveryFailures,
            pipelineRetries = pipelineRetries,
        }
    end

    return api
end
