SynexSecurityDiagnostics = {}

local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')

function SynexSecurityDiagnostics.create(options)
    options = options or {}
    local summaryProvider = assert(options.summary, 'security diagnostics requires summary')
    local healthProvider = assert(options.health, 'security diagnostics requires health')
    local listCases = assert(options.listCases, 'security diagnostics requires case list')
    local getCase = assert(options.getCase, 'security diagnostics requires case inspector')
    local getAssessment = assert(options.getAssessment,
        'security diagnostics requires assessment inspector')
    local listExpectations = assert(options.listExpectations,
        'security diagnostics requires expectation list')
    local listDetectors = assert(options.listDetectors,
        'security diagnostics requires detector list')
    local inspectSubject = assert(options.inspectSubject,
        'security diagnostics requires subject inspector')
    local observability = assert(options.observability,
        'security diagnostics requires observability')
    local hardening = assert(options.hardening, 'security diagnostics requires hardening advisor')
    local checksProvider = assert(options.checks,
        'security diagnostics requires doctor checks')
    local diagnostics = {}

    function diagnostics.summary()
        return summaryProvider()
    end

    function diagnostics.health()
        return healthProvider()
    end

    function diagnostics.list(kind, cursor, limit)
        if kind == 'cases' then return listCases(cursor, limit) end
        if kind == 'detectors' then return listDetectors(cursor, limit) end
        return Validation.failure('SECURITY_INVALID_REQUEST',
            'Security diagnostic list kind is invalid.')
    end

    function diagnostics.inspect(kind, id)
        if not Validation.text(id, 3, 128) then
            return Validation.failure('SECURITY_INVALID_REQUEST',
                'Security diagnostic inspector identity is invalid.')
        end
        if kind == 'case' then return getCase(id) end
        if kind == 'player' then
            local assessment, assessmentError = getAssessment(id)
            if not assessment then return nil, assessmentError end
            local expectations = listExpectations(id, 50)
            local related, relatedError = inspectSubject(id)
            if not related then return nil, relatedError end
            return {
                subject = id,
                assessment = assessment,
                expectations = expectations and expectations.items or {},
                expectationCount = expectations and expectations.total or 0,
                recentSignalCategories = related.recentSignalCategories or {},
                cases = related.cases,
                caseCount = related.caseCount,
                enforcements = related.enforcements,
                enforcementCount = related.enforcementCount,
                truncated = related.truncated,
                identifierFieldsSanitizedByControl = true,
                rawClientTelemetryExposed = false,
            }, nil
        end
        return Validation.failure('SECURITY_INVALID_REQUEST',
            'Security diagnostic inspector kind is invalid.')
    end

    function diagnostics.metrics()
        return observability.snapshot(), nil
    end

    function diagnostics.hardening()
        return hardening.inspect(), nil
    end

    function diagnostics.doctor(limit)
        local maximum = Validation.isInteger(limit, 1, 100) and limit or 50
        local health = healthProvider()
        local retained = observability.listFindings(maximum)
        local hardeningReport = hardening.inspect()
        local rawChecks = checksProvider()
        local checks = Validation.copy(rawChecks or {}, {
            maximumBytes = 16384,
            maximumDepth = 4,
            maximumEntries = 128,
            maximumStringBytes = 192,
        })
        if checks == nil or Validation.arrayLength(checks, 16) == nil then
            checks = {{
                id = 'doctor_checks', status = 'FAIL',
                code = 'SECURITY_DOCTOR_CHECKS_UNAVAILABLE',
                summary = 'Security doctor checks could not be evaluated safely.',
            }}
        end
        local items, checkFailureCount = {}, 0
        for _, check in ipairs(checks) do
            if check.status ~= 'PASS' then
                checkFailureCount = checkFailureCount + 1
                if #items < maximum then
                    items[#items + 1] = {
                        severity = check.status == 'FAIL' and 'CRITICAL' or 'HIGH',
                        code = check.code,
                        summary = check.summary,
                        scope = check.id,
                    }
                end
            end
        end
        local activeReasonSummaries = {
            CORE_SIGNAL_SOURCE_UNAVAILABLE = 'Core defensive findings are not being ingested.',
            SENTINEL_TRANSPORT_DEGRADED = 'Sentinel transport sampling is degraded.',
            ENTITY_GUARD_UNAVAILABLE = 'Required Cfx security hooks are unavailable.',
            DETECTOR_FAILURE = 'A detector path has consecutive runtime failures.',
            CORRELATION_BACKLOG = 'Canonical signals are waiting for successful correlation.',
            CASE_STORE_UNAVAILABLE = 'Security case persistence is unavailable.',
            ACCESS_ENFORCEMENT_UNAVAILABLE = 'Configured Access enforcement is unavailable.',
            ENFORCEMENT_RECONCILIATION_REQUIRED =
                'One or more enforcement outcomes require explicit manual reconciliation.',
            AUDIT_PIPELINE_DEGRADED = 'A privileged case lifecycle audit is incomplete.',
        }
        local activeReasons = {}
        for _, code in pairs(health.reasons or {}) do
            if code ~= nil and code ~= 'READY' and activeReasonSummaries[code] ~= nil then
                activeReasons[code] = true
            end
        end
        local orderedReasonCodes = {}
        for code in pairs(activeReasons) do orderedReasonCodes[#orderedReasonCodes + 1] = code end
        table.sort(orderedReasonCodes)
        for _, code in ipairs(orderedReasonCodes) do
            if #items >= maximum then break end
            items[#items + 1] = {
                severity = health.state == 'UNHEALTHY' and 'CRITICAL' or 'HIGH',
                code = code,
                summary = activeReasonSummaries[code],
                scope = 'runtime',
            }
        end
        for _, finding in ipairs(retained.items or {}) do
            if #items >= maximum then break end
            items[#items + 1] = finding
        end
        local hardeningFindings = {}
        for _, finding in ipairs(hardeningReport.items or {}) do
            if finding.status ~= 'OK' then
                hardeningFindings[#hardeningFindings + 1] = finding
            end
        end
        for _, finding in ipairs(hardeningFindings) do
            if #items >= maximum then break end
            items[#items + 1] = finding
        end
        local total = checkFailureCount + #orderedReasonCodes + (retained.total or 0)
            + #hardeningFindings
        return {
            status = health.state == 'READY' and (#items == 0 and 'PASS' or 'ADVISORY')
                or health.state,
            items = items,
            total = total,
            hasMore = total > #items,
            truncated = total > #items,
            health = health,
            checks = checks,
        }, nil
    end

    return diagnostics
end
