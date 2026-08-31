SynexSecurityService = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')

function SynexSecurityService.create(options)
    options = options or {}
    local signals = assert(options.signals, 'security service requires signals')
    local expectations = assert(options.expectations, 'security service requires expectations')
    local correlation = assert(options.correlation, 'security service requires correlation')
    local cases = assert(options.cases, 'security service requires cases')
    local getCase = Validation.isCallable(options.getCase)
        and options.getCase or cases.get
    local sentinel = assert(options.sentinel, 'security service requires Sentinel')
    local diagnostics = assert(options.diagnostics, 'security service requires diagnostics')
    local detectors = assert(options.detectors, 'security service requires detectors')
    local decode = assert(options.decode, 'security service requires JSON decoding')
    local encode = assert(options.encode, 'security service requires JSON encoding')
    local caseForSignal = Validation.isCallable(options.caseForSignal)
        and options.caseForSignal or function() return nil end
    local activateOwner = Validation.isCallable(options.activateOwner)
        and options.activateOwner or nil
    local onCaseLifecycle = Validation.isCallable(options.onCaseLifecycle)
        and options.onCaseLifecycle or nil
    local now = Validation.isCallable(options.now) and options.now
        or function() return math.floor(os.clock() * 1000) end
    local rateBuckets, rateBucketCount, rateOperations = {}, 0, 0
    local service = {}

    local function rateKey(context, operation)
        if context == nil then return nil end
        if type(context) ~= 'table' or not Validation.resourceName(context.caller)
            or not Validation.isInteger(context.callerEpoch, 1,
                Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security caller incarnation is unavailable.', true)
        end
        return table.concat({ context.caller, context.callerEpoch, operation }, ':'), nil
    end

    local function consumeRate(context, operation, capacity, refillPerSecond)
        local key, keyError = rateKey(context, operation)
        if key == nil then return context == nil and true or nil, keyError end
        local timestamp = now()
        if not Validation.isInteger(timestamp, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'The security service clock is unavailable.', true)
        end
        rateOperations = rateOperations + 1
        if rateOperations % 128 == 0 then
            for candidate, bucket in pairs(rateBuckets) do
                if timestamp - bucket.lastAt > 300000 then
                    rateBuckets[candidate], rateBucketCount = nil, rateBucketCount - 1
                end
            end
        end
        local bucket = rateBuckets[key]
        if bucket == nil then
            if rateBucketCount >= 1024 then
                local oldestKey, oldestAt = nil, math.huge
                for candidate, value in pairs(rateBuckets) do
                    if value.lastAt < oldestAt then
                        oldestKey, oldestAt = candidate, value.lastAt
                    end
                end
                if oldestKey ~= nil then
                    rateBuckets[oldestKey], rateBucketCount = nil, rateBucketCount - 1
                end
            end
            bucket = { tokens = capacity, lastAt = timestamp }
            rateBuckets[key], rateBucketCount = bucket, rateBucketCount + 1
        end
        local elapsed = math.max(0, timestamp - bucket.lastAt)
        bucket.tokens = math.min(capacity,
            bucket.tokens + elapsed / 1000 * refillPerSecond)
        bucket.lastAt = timestamp
        if bucket.tokens < 1 then
            return Validation.failure('SECURITY_RATE_LIMITED',
                'The security operation exceeded its bounded owner rate.', true)
        end
        bucket.tokens = bucket.tokens - 1
        return true, nil
    end

    local function ownerContext(context)
        if type(context) ~= 'table'
            or not Validation.resourceName(context.caller)
            or not Validation.isInteger(context.callerEpoch, 1,
                Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security caller incarnation is unavailable.', true)
        end
        if activateOwner ~= nil then
            local ok, active, activationError = pcall(
                activateOwner, context.caller, context.callerEpoch)
            if not ok or active ~= true then
                return nil, type(activationError) == 'table' and activationError or {
                    code = 'SECURITY_OWNER_STALE',
                    message = 'The security caller incarnation is stale.',
                    retryable = true,
                }
            end
        end
        return { ownerResource = context.caller, ownerEpoch = context.callerEpoch }, nil
    end

    local function decodeBounded(value, maximumBytes)
        if not Validation.text(value, 2, maximumBytes) then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'A bounded JSON value is invalid.')
        end
        local ok, decoded = pcall(decode, value)
        if not ok or type(decoded) ~= 'table' then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'A bounded JSON value could not be decoded.')
        end
        return Validation.copy(decoded, {
            maximumBytes = maximumBytes,
            maximumDepth = Limits.maximumEvidenceDepth,
            maximumEntries = Limits.maximumEvidenceEntries,
            maximumStringBytes = Limits.maximumEvidenceStringBytes,
        })
    end

    local function encodeBounded(value, maximumBytes)
        local copied, copyError = Validation.copy(value or {}, {
            maximumBytes = maximumBytes,
            maximumDepth = 8,
            maximumEntries = 512,
            maximumStringBytes = Limits.maximumReasonBytes,
        })
        if not copied then return nil, copyError end
        local ok, encoded = pcall(encode, copied)
        if not ok or not Validation.text(encoded, 2, maximumBytes) then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'A security response could not be encoded safely.')
        end
        return encoded, nil
    end

    local function decodedField(request, objectKey, jsonKey, maximumBytes)
        if request[objectKey] ~= nil and request[jsonKey] ~= nil then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'A security request supplied two representations of one value.')
        end
        if request[jsonKey] ~= nil then
            return decodeBounded(request[jsonKey], maximumBytes)
        end
        if request[objectKey] == nil then return nil, nil end
        return Validation.copy(request[objectKey], {
            maximumBytes = maximumBytes,
            maximumDepth = Limits.maximumEvidenceDepth,
            maximumEntries = Limits.maximumEvidenceEntries,
            maximumStringBytes = Limits.maximumEvidenceStringBytes,
        })
    end

    function service.reportSignal(request, context)
        if not Validation.exactObject(request, {
            namespace = true, category = true, detector = true, code = true,
            subject = true, severity = true, confidence = true,
            evidenceClass = true, correlationKey = true, summary = true,
            traceId = true, requestId = true, rootEventId = true,
            worldRef = true, worldRefJson = true, entityRef = true,
            entityRefJson = true, evidence = true, evidenceJson = true,
        }, {
            namespace = true, category = true, detector = true, code = true,
            subject = true, severity = true, confidence = true,
            evidenceClass = true, correlationKey = true, summary = true,
        }) then
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'The security signal request contains unsupported fields.')
        end
        local owner, ownerError = ownerContext(context)
        if not owner then return nil, ownerError end
        if request.evidenceClass ~= 'DOMAIN_AUTHORITATIVE' then
            return Validation.failure('SECURITY_SIGNAL_INVALID',
                'Domain signal evidence provenance is assigned by Security.')
        end
        local permitted, permitError = consumeRate(context, 'signal.report', 40, 10)
        if not permitted then return nil, permitError end
        local candidate = {
            namespace = request.namespace, category = request.category,
            detector = request.detector, code = request.code,
            subject = request.subject, severity = request.severity,
            confidence = request.confidence, evidenceClass = 'DOMAIN_AUTHORITATIVE',
            correlationKey = request.correlationKey, summary = request.summary,
            traceId = request.traceId or context.traceId,
            requestId = request.requestId, rootEventId = request.rootEventId,
        }
        local fieldError
        candidate.evidence, fieldError = decodedField(
            request, 'evidence', 'evidenceJson', Limits.maximumEvidenceBytes)
        if fieldError then return nil, fieldError end
        candidate.worldRef, fieldError = decodedField(
            request, 'worldRef', 'worldRefJson', 1024)
        if fieldError then return nil, fieldError end
        candidate.entityRef, fieldError = decodedField(
            request, 'entityRef', 'entityRefJson', 1024)
        if fieldError then return nil, fieldError end
        local signal, signalError, metadata = signals.emit(candidate, owner)
        if not signal then return nil, signalError end
        local caseId = caseForSignal(signal.signalId)
        return {
            signalId = signal.signalId,
            accepted = true,
            deduplicated = type(metadata) == 'table' and metadata.duplicate == true,
            caseId = caseId,
        }, nil
    end

    function service.registerExpectation(request, context)
        if not Validation.exactObject(request, {
            expectationId = true, namespace = true, kind = true, subject = true,
            constraints = true, constraintsJson = true, reason = true,
            ttlMs = true, traceId = true,
        }) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation request contains unsupported fields.')
        end
        local owner, ownerError = ownerContext(context)
        if not owner then return nil, ownerError end
        local permitted, permitError = consumeRate(
            context, 'expectation.register', 24, 6)
        if not permitted then return nil, permitError end
        local constraints, constraintError = decodedField(
            request, 'constraints', 'constraintsJson', 4096)
        if not constraints then return nil, constraintError or {
            code = 'SECURITY_EXPECTATION_INVALID',
            message = 'Security expectation constraints are required.',
            retryable = false,
        } end
        local value, operationError = expectations.register({
            expectationId = request.expectationId,
            namespace = request.namespace,
            kind = request.kind,
            subject = request.subject,
            constraints = constraints,
            reason = request.reason,
            ttlMs = request.ttlMs,
        }, owner)
        if not value then return nil, operationError end
        return {
            expectationId = value.expectationId,
            kind = value.kind,
            ownerResource = value.ownerResource,
            ownerEpoch = value.ownerEpoch,
            revision = value.revision,
            expiresAtMs = value.expiresAt,
        }, nil
    end

    function service.revokeExpectation(request, context)
        if not Validation.exactObject(request, {
            expectationId = true, revision = true, reason = true,
        }, { expectationId = true, revision = true }) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation handle is invalid.')
        end
        local owner, ownerError = ownerContext(context)
        if not owner then return nil, ownerError end
        local permitted, permitError = consumeRate(
            context, 'expectation.revoke', 24, 6)
        if not permitted then return nil, permitError end
        local revoked, operationError = expectations.revoke({
            expectationId = request.expectationId,
            revision = request.revision,
        }, owner)
        if not revoked then return nil, operationError end
        return { expectationId = request.expectationId, revoked = true }, nil
    end

    function service.getExpectations(request, context)
        if not Validation.exactObject(request, {
            subjectKey = true, ownerResource = true, limit = true, cursor = true,
        }) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'The security expectation page request is invalid.')
        end
        local permitted, permitError = consumeRate(
            context, 'expectation.list', 20, 5)
        if not permitted then return nil, permitError end
        local offset = Validation.isInteger(request.cursor, 0,
            Limits.maximumExpectations) and request.cursor or 0
        local maximum = Validation.isInteger(request.limit, 1, 50)
            and request.limit or 50
        local values, operationError, metadata = expectations.list({
            subjectKey = request.subjectKey,
            ownerResource = request.ownerResource,
            offset = offset,
            limit = maximum + 1,
        })
        if not values then return nil, operationError end
        local hasMore = #values > maximum
        if hasMore then values[#values] = nil end
        local encoded, encodeError = encodeBounded(values, 16384)
        while encoded == nil and #values > 1 do
            values[#values] = nil
            hasMore = true
            encoded, encodeError = encodeBounded(values, 16384)
        end
        if not encoded then return nil, encodeError end
        return {
            itemsJson = encoded,
            total = type(metadata) == 'table' and metadata.total or #values,
            truncated = hasMore,
            nextCursor = hasMore and offset + #values or nil,
        }, nil
    end

    local function assessmentStatus(value)
        if type(value.hypotheses) ~= 'table' or #value.hypotheses == 0 then return 'CLEAR' end
        if value.confidence >= 0.80
            and (value.severity == 'HIGH' or value.severity == 'CRITICAL') then
            return 'ACTION'
        end
        if value.confidence >= Limits.minimumReviewConfidence then return 'REVIEW' end
        return 'OBSERVE'
    end

    local function projectCaseDetail(value)
        local maximum = 4
        local function boundedItems(candidate)
            if candidate == nil then return {}, false end
            local count = Validation.arrayLength(candidate, 64)
            if count == nil then
                return Validation.failure('SECURITY_VALUE_INVALID',
                    'Security case detail contains an invalid collection.')
            end
            local result = {}
            for index = 1, math.min(count, maximum) do result[index] = candidate[index] end
            return result, count > maximum
        end
        local timeline, timelineOverflow = boundedItems(value.timeline)
        if not timeline then return nil, timelineOverflow end
        local enforcements, enforcementOverflow = boundedItems(value.enforcements)
        if not enforcements then return nil, enforcementOverflow end
        local expectations, expectationOverflow = boundedItems(value.expectations)
        if not expectations then return nil, expectationOverflow end
        return {
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
            timelineTruncated = timelineOverflow or value.timelineTruncated == true,
            enforcements = enforcements,
            enforcementsTruncated = enforcementOverflow
                or value.enforcementsTruncated == true,
            expectations = expectations,
            expectationCount = math.min(value.expectationCount or #expectations, maximum),
            expectationsTruncated = expectationOverflow
                or value.expectationsTruncated == true,
            correlation = value.correlation,
            rawClientTelemetryExposed = false,
        }, nil
    end

    function service.getAssessment(request, context)
        if not Validation.exactObject(request, { subjectKey = true },
            { subjectKey = true })
            or not Validation.token(request.subjectKey, 3, 160) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'The security assessment request is invalid.')
        end
        local permitted, permitError = consumeRate(
            context, 'assessment.get', 20, 5)
        if not permitted then return nil, permitError end
        local value, operationError = correlation.assess(request.subjectKey)
        if not value then return nil, operationError end
        local encoded, encodeError = encodeBounded(value.hypotheses, 16384)
        if not encoded then return nil, encodeError end
        return {
            subjectKey = value.subjectKey,
            severity = value.severity,
            confidence = value.confidence,
            status = assessmentStatus(value),
            activeExpectations = value.activeExpectations or 0,
            hypothesesJson = encoded,
        }, nil
    end

    function service.getCase(request, context)
        if not Validation.exactObject(request, { caseId = true },
            { caseId = true }) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'The security case request is invalid.')
        end
        local permitted, permitError = consumeRate(context, 'case.get', 20, 5)
        if not permitted then return nil, permitError end
        local value, operationError = getCase(request.caseId)
        if not value then return nil, operationError end
        local detail, detailError = projectCaseDetail(value)
        if not detail then return nil, detailError end
        local encoded, encodeError = encodeBounded(detail, 16384)
        if not encoded then return nil, encodeError end
        return {
            caseId = value.caseId,
            status = value.status,
            category = value.category,
            severity = value.severity,
            confidence = value.confidence,
            signalCount = value.signalSummary and value.signalSummary.count or 0,
            enforcementCount = value.enforcementSummary
                and value.enforcementSummary.count or 0,
            openedAt = value.openedAt,
            updatedAt = value.updatedAt,
            detailJson = encoded,
        }, nil
    end

    function service.getHealth(request, context)
        if not Validation.exactObject(request or {}, {}) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security health accepts an empty request.')
        end
        local permitted, permitError = consumeRate(context, 'health.get', 10, 2)
        if not permitted then return nil, permitError end
        local value = diagnostics.health()
        local reasonsJson, encodeError = encodeBounded(value.reasons or {}, 2048)
        if not reasonsJson then return nil, encodeError end
        return {
            state = value.state,
            detectors = value.detectors,
            openCases = value.openCases,
            activeExpectations = value.activeExpectations,
            sentinelSources = value.sentinelSources,
            persistenceBacklog = value.persistenceBacklog,
            reasonsJson = reasonsJson,
        }, nil
    end

    function service.getControlSummary(request, context)
        if not Validation.exactObject(request or {}, {}) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security summary accepts an empty request.')
        end
        local permitted, permitError = consumeRate(context, 'summary.get', 10, 2)
        if not permitted then return nil, permitError end
        return diagnostics.summary(), nil
    end

    function service.listDetectors(request, context)
        if not Validation.exactObject(request or {}, { cursor = true, limit = true }) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security detector listing is invalid.')
        end
        local permitted, permitError = consumeRate(context, 'detectors.list', 10, 2)
        if not permitted then return nil, permitError end
        return diagnostics.list('detectors', request and request.cursor,
            request and request.limit)
    end

    function service.doctor(request, context)
        if not Validation.exactObject(request or {}, { limit = true }) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security doctor request is invalid.')
        end
        local permitted, permitError = consumeRate(context, 'doctor.get', 10, 2)
        if not permitted then return nil, permitError end
        return diagnostics.doctor(request and request.limit)
    end

    function service.transitionCase(request, context)
        if not Validation.exactObject(request, {
            caseId = true, targetStatus = true, expectedRevision = true,
            reason = true,
        }, {
            caseId = true, targetStatus = true, expectedRevision = true,
            reason = true,
        }) then
            return Validation.failure('SECURITY_CASE_INVALID',
                'The security case transition request is invalid.')
        end
        local permitted, permitError = consumeRate(
            context, 'case.transition', 8, 1)
        if not permitted then return nil, permitError end
        if onCaseLifecycle ~= nil then
            local audited, accepted = pcall(onCaseLifecycle,
                'INTENT', 'transition', nil, request, context)
            if not audited or accepted ~= true then
                return Validation.failure('SECURITY_AUDIT_UNAVAILABLE',
                    'The privileged case transition was not audited.', true)
            end
        end
        local value, operationError = cases.transition(
            request.caseId, request.targetStatus, {
                expectedRevision = request.expectedRevision,
                reason = request.reason,
            })
        if not value then return nil, operationError end
        if onCaseLifecycle ~= nil then
            pcall(onCaseLifecycle, 'APPLIED', 'transition', value, request, context)
        end
        return value, nil
    end

    function service.reopenCase(request, context)
        if not Validation.exactObject(request, {
            caseId = true, expectedRevision = true, reason = true,
        }, {
            caseId = true, expectedRevision = true, reason = true,
        }) then
            return Validation.failure('SECURITY_CASE_INVALID',
                'The security case reopen request is invalid.')
        end
        local permitted, permitError = consumeRate(context, 'case.reopen', 4, 0.5)
        if not permitted then return nil, permitError end
        if onCaseLifecycle ~= nil then
            local audited, accepted = pcall(onCaseLifecycle,
                'INTENT', 'reopen', nil, request, context)
            if not audited or accepted ~= true then
                return Validation.failure('SECURITY_AUDIT_UNAVAILABLE',
                    'The privileged case reopen was not audited.', true)
            end
        end
        local value, operationError = cases.reopen(request.caseId, {
            expectedRevision = request.expectedRevision,
            reason = request.reason,
        })
        if not value then return nil, operationError end
        if onCaseLifecycle ~= nil then
            pcall(onCaseLifecycle, 'APPLIED', 'reopen', value, request, context)
        end
        return value, nil
    end

    function service.sentinelReport(request, context)
        return sentinel.report(request, context)
    end

    function service.serviceDefinition()
        return {
            name = 'synex.security',
            version = '1.0.0',
            stability = 'experimental',
            capabilities = {
                reportSignal = 'synex.security.signal.emit',
                registerExpectation = 'synex.security.expectation.manage',
                revokeExpectation = 'synex.security.expectation.manage',
                getExpectations = 'synex.security.case.read',
                getAssessment = 'synex.security.case.read',
                getCase = 'synex.security.case.read',
                getHealth = 'synex.security.diagnostics.read',
                getControlSummary = 'synex.security.diagnostics.read',
                listDetectors = 'synex.security.diagnostics.read',
                doctor = 'synex.security.diagnostics.read',
                transitionCase = 'synex.security.enforce',
                reopenCase = 'synex.security.enforce',
            },
            methods = {
                reportSignal = service.reportSignal,
                registerExpectation = service.registerExpectation,
                revokeExpectation = service.revokeExpectation,
                getExpectations = service.getExpectations,
                getAssessment = service.getAssessment,
                getCase = service.getCase,
                getHealth = service.getHealth,
                getControlSummary = service.getControlSummary,
                listDetectors = service.listDetectors,
                doctor = service.doctor,
                transitionCase = service.transitionCase,
                reopenCase = service.reopenCase,
            },
        }
    end

    function service.contractHandler(definition)
        local handlers = {
            ['synex.security.signal.report'] = service.reportSignal,
            ['synex.security.expectation.register'] = service.registerExpectation,
            ['synex.security.expectation.revoke'] = service.revokeExpectation,
            ['synex.security.expectation.list'] = service.getExpectations,
            ['synex.security.assessment.get'] = service.getAssessment,
            ['synex.security.case.get'] = service.getCase,
            ['synex.security.health.get'] = service.getHealth,
            ['synex.security.sentinel.report'] = service.sentinelReport,
        }
        local handler = type(definition) == 'table' and handlers[definition.name] or nil
        if not Validation.isCallable(handler) then
            return Validation.failure('SECURITY_UNAVAILABLE',
                'A security contract handler is unavailable.')
        end
        local allowedErrors = {}
        for _, code in ipairs(definition.errors or {}) do allowedErrors[code] = true end
        return function(request, context)
            local value, operationError = Foundation.protect(handler, request, context)
            if value ~= nil then return value, nil end
            local public = Foundation.publicError(operationError)
            if not allowedErrors[public.code] then
                public = {
                    code = 'SECURITY_UNAVAILABLE',
                    message = 'The security operation was rejected.',
                    retryable = public.retryable == true,
                }
            end
            return nil, public
        end, nil
    end

    return service
end
