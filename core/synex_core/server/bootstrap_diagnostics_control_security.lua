local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.createBootstrapControlSecurityOperation = function(deps, shared, control)
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local selectedMetrics = assert(shared.selectedMetrics)
    local requestKeysAllowed = assert(shared.requestKeysAllowed)
    local validCoreLimit = assert(control.validCoreLimit)
    local emptyControlFilters = assert(control.emptyControlFilters)
    local unavailableSection = assert(control.unavailableSection)

    local securityFindingLimit = 256
    local securityFindingSeverities = {
        INFO = true, WARNING = true, ERROR = true, CRITICAL = true
    }

    local function unsafeSecurityFindingText(value)
        if type(value) ~= 'string' then return false end
        local candidate = value:sub(1, 512)
        local normalized = candidate:lower()
        local github = normalized:match('github_pat_([a-z0-9_%-]+)')
        local compactToken = normalized:match('gh[pousr]_([a-z0-9_%-]+)')
        local cfx = normalized:match('cfxk_([a-z0-9_%-]+)')
        local aws = candidate:match('AKIA([A-Z0-9]+)')
        return normalized:match('bearer%s+[%w%._~+/=%-]+') ~= nil
            or normalized:find('mysql://', 1, true) ~= nil
            or normalized:find('mariadb://', 1, true) ~= nil
            or normalized:find('discord.com/api/webhooks/', 1, true) ~= nil
            or normalized:find('discordapp.com/api/webhooks/', 1, true) ~= nil
            or normalized:find('-----begin ', 1, true) ~= nil
                and normalized:find('private key-----', 1, true) ~= nil
            or github ~= nil and #github >= 20
            or compactToken ~= nil and #compactToken >= 20
            or cfx ~= nil and #cfx >= 20
            or aws ~= nil and #aws >= 16
            or normalized:match('[?&]access[_%-]?token=[^&#%s]+') ~= nil
            or normalized:match('[?&]api[_%-]?key=[^&#%s]+') ~= nil
            or normalized:match('[?&]secret=[^&#%s]+') ~= nil
            or normalized:match('[?&]signature=[^&#%s]+') ~= nil
            or normalized:match('[?&]token=[^&#%s]+') ~= nil
            or normalized:find('://', 1, true) ~= nil
                and normalized:match('[a-z][a-z0-9+.-]*://[^/%s:]+:[^@/%s]+@') ~= nil
    end

    local function validSecurityFindingToken(value, maximum)
        return type(value) == 'string' and #value >= 1 and #value <= maximum
            and value:match('^[A-Za-z0-9_%.:%-]+$') ~= nil
            and not unsafeSecurityFindingText(value)
    end

    local function validSecurityFindingCursor(value)
        return type(value) == 'string' and #value >= 1 and #value <= 20
            and value:match('^[1-9]%d*$') ~= nil
    end

    local function securityFindingFailureCode(value, fallback)
        local code = type(value) == 'table' and getmetatable(value) == nil
            and rawget(value, 'code') or nil
        return type(code) == 'string' and #code <= 64
            and code:match('^[A-Z][A-Z0-9_]*$') and code or fallback
    end

    local function securityFindingUnavailable(reason)
        return {
            status = 'UNAVAILABLE',
            reason = reason,
            payloadsExposed = false,
            identifiersExposed = false
        }
    end

    local function projectRuntimeSecurityPage(page, limit)
        if type(page) ~= 'table' or getmetatable(page) ~= nil
            or type(page.items) ~= 'table' or getmetatable(page.items) ~= nil
            or #page.items > limit then return nil end
        local projected, cursors = {}, {}
        for index, finding in ipairs(page.items) do
            if type(finding) ~= 'table' or getmetatable(finding) ~= nil
                or type(finding.category) ~= 'string' or #finding.category < 1
                or #finding.category > 32
                or not finding.category:match('^[a-z][a-z0-9_]*$')
                or not securityFindingSeverities[finding.severity]
                or type(finding.code) ~= 'string' or #finding.code < 1
                or #finding.code > 64 or not finding.code:match('^[A-Z][A-Z0-9_]*$')
                or finding.resource ~= nil
                    and not validSecurityFindingToken(finding.resource, 128)
                or finding.scope ~= nil and not validSecurityFindingToken(finding.scope, 128)
                or finding.resource == nil and finding.scope == nil
                or not validSecurityFindingToken(finding.operation, 128)
                or type(finding.summary) ~= 'string' or #finding.summary < 1
                or #finding.summary > 192
                or finding.summary:find('[%z\1-\31\127-\255]')
                or unsafeSecurityFindingText(finding.summary)
                or not validSecurityFindingCursor(finding.cursor) then
                return nil
            end
            if finding.timestamp ~= nil and (type(finding.timestamp) ~= 'string'
                or #finding.timestamp < 20 or #finding.timestamp > 40
                or finding.timestamp:find('[%z\1-\31\127-\255]')
                or unsafeSecurityFindingText(finding.timestamp)) then return nil end
            if finding.timestampMs ~= nil and (type(finding.timestampMs) ~= 'number'
                or math.type(finding.timestampMs) ~= 'integer'
                or finding.timestampMs < 0) then return nil end
            projected[index] = {
                origin = 'runtime',
                timestamp = finding.timestamp,
                timestampMs = finding.timestampMs,
                category = finding.category,
                severity = finding.severity,
                code = finding.code,
                resource = finding.resource,
                scope = finding.scope,
                operation = finding.operation,
                summary = finding.summary
            }
            cursors[index] = finding.cursor
        end
        local hasMore = page.hasMore == true
        if hasMore and (#projected == 0 or not validSecurityFindingCursor(page.nextCursor)) then
            return nil
        end
        local function boundedCount(value)
            return type(value) == 'number' and math.type(value) == 'integer'
                and value >= 0 and value or nil
        end
        return {
            items = projected,
            cursors = cursors,
            hasMore = hasMore,
            nextCursor = hasMore and page.nextCursor or nil,
            retained = boundedCount(page.retained),
            maximumRetained = boundedCount(page.maximumRetained),
            dropped = boundedCount(page.dropped),
            retentionTruncated = page.retentionTruncated == true,
            payloadsExposed = false,
            identifiersExposed = false
        }
    end

    local function runtimeSecurityPage(cursor, limit)
        local diagnostics = type(security) == 'table'
            and rawget(security, 'diagnostics') or nil
        local pageMethod = type(diagnostics) == 'table'
            and rawget(diagnostics, 'page') or nil
        if not foundation.isCallable(pageMethod) then
            return nil, nil, securityFindingUnavailable(
                'SECURITY_DIAGNOSTICS_API_UNAVAILABLE')
        end
        local method, argument = pageMethod, { cursor = cursor, limit = limit }
        if cursor == nil then
            local snapshotMethod = rawget(diagnostics, 'snapshot')
            if foundation.isCallable(snapshotMethod) then
                method, argument = snapshotMethod, limit
            end
        end
        local invoked, page, pageError = foundation.safeCall(
            method, diagnostics, argument)
        if not invoked then
            return nil, nil, securityFindingUnavailable(
                'SECURITY_DIAGNOSTICS_API_EXCEPTION')
        end
        if not page then
            local code = securityFindingFailureCode(pageError,
                'SECURITY_DIAGNOSTICS_API_FAILED')
            if code == 'INVALID_CURSOR' then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Core security finding cursor is invalid.'), nil
            end
            return nil, nil, securityFindingUnavailable(code)
        end
        local projected = projectRuntimeSecurityPage(page, limit)
        if not projected then
            return nil, nil, securityFindingUnavailable(
                'INVALID_SECURITY_DIAGNOSTICS_PAGE')
        end
        projected.status = 'AVAILABLE'
        return projected, nil, projected
    end

    local function derivedSecurityFindings()
        local findings, truncated = {}, false
        local staleSessionCoverage = {
            status = 'UNAVAILABLE',
            reason = 'STALE_SESSION_ANALYZER_UNAVAILABLE',
            rawIdentifiersExposed = false
        }
        local function append(finding)
            if #findings >= securityFindingLimit then
                truncated = true
                return false
            end
            finding.origin = 'current'
            findings[#findings + 1] = finding
            return true
        end

        if foundation.isCallable(registries.players.staleSessions) then
            local invoked, staleSessions, staleError = foundation.safeCall(
                registries.players.staleSessions, registries.players, {
                    limit = 50, scanLimit = 512
                })
            if invoked and staleSessions then
                staleSessionCoverage = {
                    status = 'AVAILABLE',
                    scope = 'BOUNDED_KEYSET_SCAN',
                    scanned = tonumber(staleSessions.scanned) or 0,
                    matched = tonumber(staleSessions.matched) or 0,
                    complete = staleSessions.complete == true,
                    truncated = staleSessions.truncated == true,
                    rawIdentifiersExposed = false
                }
                local staleBuckets = {}
                for _, staleSession in ipairs(type(staleSessions.items) == 'table'
                    and staleSessions.items or {}) do
                    local state = validSecurityFindingToken(staleSession.state, 32)
                        and staleSession.state or 'UNKNOWN'
                    local reasons = {}
                    for _, reason in ipairs(type(staleSession.reasons) == 'table'
                        and staleSession.reasons or {}) do
                        if type(reason) == 'string' and #reason <= 64
                            and reason:match('^[A-Z][A-Z0-9_]*$') then
                            reasons[#reasons + 1] = reason
                        end
                        if #reasons >= 16 then break end
                    end
                    table.sort(reasons)
                    if #reasons == 0 then reasons[1] = 'UNSPECIFIED' end
                    local key = state .. '|' .. table.concat(reasons, ',')
                    local bucket = staleBuckets[key]
                    if not bucket then
                        bucket = { state = state, reasons = reasons, occurrences = 0 }
                        staleBuckets[key] = bucket
                    end
                    bucket.occurrences = bucket.occurrences + 1
                end
                local staleKeys = {}
                for key in pairs(staleBuckets) do staleKeys[#staleKeys + 1] = key end
                table.sort(staleKeys)
                for _, key in ipairs(staleKeys) do
                    local bucket = staleBuckets[key]
                    append({
                        category = 'session_authority',
                        severity = 'ERROR',
                        code = 'STALE_SESSION_AUTHORITY',
                        scope = 'session_authority',
                        operation = 'session.authority.inspect',
                        summary = 'Stale session authority detected.',
                        state = bucket.state,
                        reasons = bucket.reasons,
                        occurrences = bucket.occurrences
                    })
                end
                if staleSessions.truncated == true then truncated = true end
            else
                staleSessionCoverage.reason = invoked
                    and securityFindingFailureCode(staleError,
                        'STALE_SESSION_ANALYZER_FAILED')
                    or 'STALE_SESSION_ANALYZER_EXCEPTION'
            end
        end

        for _, hook in ipairs(messaging.hooks:snapshot()) do
            for _, handler in ipairs(hook.handlerDetails or {}) do
                if handler.slow and validSecurityFindingToken(handler.owner, 128)
                    and validSecurityFindingToken(hook.name, 128) then
                    append({
                        category = 'runtime_performance',
                        severity = 'WARNING',
                        code = 'SLOW_HOOK_HANDLER',
                        resource = handler.owner,
                        scope = hook.name,
                        hook = hook.name,
                        operation = 'hook.handler.inspect',
                        summary = 'Slow hook handler detected.',
                        percentile95DurationMs = handler.percentile95DurationMs,
                        timeoutMs = handler.timeoutMs
                    })
                end
            end
        end

        local resources = {}
        for resource in pairs(security.capabilities:snapshot()) do
            if validSecurityFindingToken(resource, 128) then
                resources[#resources + 1] = resource
            end
        end
        table.sort(resources)
        for _, resource in ipairs(resources) do
            for _, finding in ipairs(security.capabilities:preflight(resource)) do
                if validSecurityFindingToken(finding.resource, 128)
                    and validSecurityFindingToken(finding.capability, 128) then
                    local reason = type(finding.reason) == 'string'
                        and #finding.reason <= 64
                        and finding.reason:match('^[a-z][a-z0-9_]*$')
                        and finding.reason or 'unknown'
                    append({
                        category = 'capability_preflight',
                        severity = 'WARNING',
                        code = 'CAPABILITY_PREFLIGHT_DENIAL',
                        resource = finding.resource,
                        scope = finding.capability,
                        operation = 'capability.preflight',
                        summary = 'Capability preflight validation rejected.',
                        capability = finding.capability,
                        reason = reason
                    })
                end
            end
        end

        local severityOrder = { CRITICAL = 1, ERROR = 2, WARNING = 3, INFO = 4 }
        table.sort(findings, function(left, right)
            local leftSeverity = severityOrder[left.severity] or 9
            local rightSeverity = severityOrder[right.severity] or 9
            if leftSeverity ~= rightSeverity then return leftSeverity < rightSeverity end
            local leftKey = table.concat({ left.category or '', left.code or '',
                left.resource or '', left.scope or '', left.state or '',
                left.reason or '' }, '|')
            local rightKey = table.concat({ right.category or '', right.code or '',
                right.resource or '', right.scope or '', right.state or '',
                right.reason or '' }, '|')
            return leftKey < rightKey
        end)
        return findings, staleSessionCoverage, truncated
    end

    return function(request)
        if not requestKeysAllowed(request, {
            view = true,
            limit = true,
            cursor = true,
            filters = true,
            sort = true
        }) or request.view ~= 'security'
            or not validCoreLimit(request.limit, 50) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core findings supports only the security view.')
        end
        if request.cursor ~= nil and not validSecurityFindingCursor(request.cursor) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core security finding cursor is invalid.')
        end
        if not emptyControlFilters(request.filters) or request.sort ~= nil then
            return unavailableSection(request.view,
                'CORE_FINDING_FILTERING_UNAVAILABLE')
        end
        local limit = request.limit or 25
        local runtimePage, runtimeRequestError, runtimeHistory =
            runtimeSecurityPage(request.cursor, limit)
        if runtimeRequestError then return nil, runtimeRequestError end
        local derived, staleSessionCoverage, derivedSourceTruncated =
            derivedSecurityFindings()
        local items, derivedSlots, runtimeSlots = {}, 0, limit
        if request.cursor == nil then
            derivedSlots = math.min(#derived, limit)
            if runtimePage and #runtimePage.items > 0 then
                derivedSlots = math.min(#derived, math.max(0, limit - 1))
            end
            runtimeSlots = limit - derivedSlots
            for index = 1, derivedSlots do
                items[#items + 1] = foundation.copy(derived[index])
            end
        end
        local runtimeUsed = 0
        if runtimePage then
            runtimeUsed = math.min(runtimeSlots, #runtimePage.items)
            for index = 1, runtimeUsed do
                items[#items + 1] = foundation.copy(runtimePage.items[index])
            end
        end
        local runtimeHasMore = runtimePage ~= nil and runtimeUsed > 0
            and (runtimeUsed < #runtimePage.items or runtimePage.hasMore)
        local nextCursor = runtimeHasMore
            and runtimePage.cursors[runtimeUsed] or nil
        local currentFindingsTruncated = request.cursor == nil
            and (#derived > derivedSlots or derivedSourceTruncated)
        local runtimeAvailable = runtimePage ~= nil
        local runtimeReason = nil
        if not runtimeAvailable then
            runtimeReason = runtimeHistory.reason
                or 'SECURITY_DIAGNOSTICS_API_UNAVAILABLE'
        end
        local function runtimeCoverage(category)
            if runtimeAvailable then
                return { status = 'AVAILABLE', category = category }
            end
            return { status = 'UNAVAILABLE', reason = runtimeReason }
        end
        local status = 'INFO'
        for _, finding in ipairs(items) do
            if finding.severity == 'CRITICAL' or finding.severity == 'ERROR' then
                status = 'ERROR'
                break
            elseif finding.severity == 'WARNING' then
                status = 'WARNING'
            end
        end
        return {
            view = 'security',
            status = status,
            rbac = security.rbac:snapshot(),
            items = items,
            nextCursor = nextCursor,
            hasMore = runtimeHasMore,
            truncated = currentFindingsTruncated or runtimeHasMore
                or runtimeHistory.retentionTruncated == true,
            pagination = {
                status = runtimeAvailable and 'AVAILABLE' or 'UNAVAILABLE',
                kind = 'keyset',
                currentFindingsFirstPageOnly = true
            },
            currentFindings = {
                status = 'AVAILABLE',
                total = #derived,
                included = request.cursor == nil and derivedSlots or 0,
                firstPageOnly = true,
                truncated = currentFindingsTruncated,
                identifiersExposed = false
            },
            runtimeHistory = {
                status = runtimeAvailable and 'AVAILABLE' or 'UNAVAILABLE',
                reason = runtimeReason,
                retained = runtimeAvailable and runtimePage.retained or nil,
                maximumRetained = runtimeAvailable
                    and runtimePage.maximumRetained or nil,
                dropped = runtimeAvailable and runtimePage.dropped or nil,
                retentionTruncated = runtimeAvailable
                    and runtimePage.retentionTruncated == true or false,
                payloadsExposed = false,
                identifiersExposed = false
            },
            coverage = {
                capabilityPolicy = {
                    status = 'AVAILABLE',
                    runtimeHistory = runtimeAvailable
                        and 'AVAILABLE' or 'UNAVAILABLE',
                    category = 'capability_denial'
                },
                capabilityDenials = runtimeCoverage('capability_denial'),
                contractValidation = runtimeCoverage('contract_validation'),
                rpcRateLimits = runtimeCoverage('rate_limit_rejection'),
                eventAuthorization = runtimeCoverage('event_authorization'),
                hookAuthorization = runtimeCoverage('hook_authorization'),
                staleSessions = staleSessionCoverage,
                entityReferences = {
                    status = 'PROVIDER_OWNED',
                    reason = 'USE_ENTITIES_FINDINGS_VIEW'
                },
                foreignCalls = runtimeAvailable and {
                    status = 'AVAILABLE',
                    categories = { 'event_authorization', 'hook_authorization' }
                } or { status = 'UNAVAILABLE', reason = runtimeReason },
                fuzzing = {
                    status = 'NOT_RUNTIME',
                    reason = 'REPOSITORY_TEST_GATE'
                },
                staticAnalyzer = {
                    status = 'NOT_RUNTIME',
                    reason = 'REPOSITORY_TEST_GATE'
                }
            },
            metrics = selectedMetrics({
                'synex_capability_',
                'synex_rate_limit_',
                'synex_rbac_'
            }, 128),
            payloadsExposed = false,
            identifiersExposed = false,
            crossDomainDataExposed = false
        }, nil
    end
end
