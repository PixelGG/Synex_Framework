SynexInteractObservability = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

local allowedClientCounters = {
    sensorTicks = true, candidatesSeen = true, expensiveChecks = true,
    intentChanges = true, promptsShown = true, bloomOpened = true,
    leaseRequests = true, transportFailures = true, providerTimeouts = true,
}
local allowedClientGauges = {
    candidateCount = true, sensorIntervalMs = true, expensiveCandidateCount = true,
    sensorDurationMs = true, providerDurationMs = true,
    intentScoringDurationMs = true,
}
local clientCounterMetrics = {
    sensorTicks = 'sensor_ticks', candidatesSeen = 'candidates_seen_total',
    expensiveChecks = 'los_test_total', intentChanges = 'intent_switch_total',
    promptsShown = 'prompt_shown_total', bloomOpened = 'bloom_opened_total',
    leaseRequests = 'lease_requested_total',
    transportFailures = 'client_transport_failure_total',
    providerTimeouts = 'client_provider_timeout_total',
}
local clientGaugeMetrics = {
    candidateCount = 'candidate_count',
    sensorIntervalMs = 'sensor_interval_ms',
    expensiveCandidateCount = 'expensive_candidate_count',
    sensorDurationMs = 'sensor_duration_ms',
    providerDurationMs = 'client_provider_duration_ms',
    intentScoringDurationMs = 'intent_scoring_duration_ms',
}
local allowedMetricLabels = {
    operation = true, outcome = true, reason = true,
    node_category = true, provider_kind = true,
}

function SynexInteractObservability.create(options)
    options = options or {}
    local coreRef = assert(options.coreRef, 'interact observability requires Core reference')
    local foundation = assert(options.foundation, 'interact observability requires foundation')
    local now = assert(options.now, 'interact observability requires monotonic time')
    local counters, counterSeries, gauges, observations, denials = {}, {}, {}, {}, {}
    local reports, reportCount = {}, 0
    local recorderEnabled = options.traceEnabled == true
    local traceEntries, traceHead, traceCount, traceSequence = {}, 1, 0, 0
    local recentSignals, recentClientSignals = {}, {}
    local observability = {}

    local function coreCall(group, method, ...)
        local api = coreRef.value
        local namespace = type(api) == 'table' and api[group] or nil
        local handler = type(namespace) == 'table' and namespace[method] or nil
        if not foundation.isCallable(handler) then return nil end
        local ok, value = pcall(handler, ...)
        return ok and value or nil
    end

    local function metricName(name)
        return type(name) == 'string' and #name >= 1 and #name <= 64
            and name:match('^[a-z][a-z0-9_]*$') and name or nil
    end

    local function metricLabels(labels)
        if labels == nil then return {} end
        if not Validation.isPlainTable(labels) then return nil end
        local values, count = {}, 0
        for key, value in pairs(labels) do
            count = count + 1
            if count > 4 or not allowedMetricLabels[key]
                or type(value) ~= 'string' or #value < 1 or #value > 64
                or value:find('[%z\1-\31\127]') then return nil end
            values[key] = value
        end
        return values
    end

    local function seriesKey(name, labels)
        local parts = { name }
        for key, value in pairs(labels) do parts[#parts + 1] = key .. '=' .. value end
        table.sort(parts)
        return table.concat(parts, '|')
    end

    local function traceIndex(offset)
        return ((traceHead + offset - 2) % Limits.maximumTraceFrames) + 1
    end

    local function dropOldestTrace()
        if traceCount == 0 then return end
        traceEntries[traceHead] = nil
        traceHead = traceIndex(2)
        traceCount = traceCount - 1
        if traceCount == 0 then traceHead = 1 end
    end

    local function pruneTraces(timestamp)
        while traceCount > 0 do
            local entry = traceEntries[traceHead]
            if not entry or timestamp - entry.at <= Limits.traceRetentionMs then break end
            dropOldestTrace()
        end
    end

    local function recordSignal(name)
        recentSignals[name] = now()
    end

    local function recordClientSignal(name)
        recentClientSignals[name] = now()
    end

    local function retainedSignals(signals)
        local timestamp, values = now(), {}
        for name, at in pairs(signals) do
            if timestamp - at <= Limits.traceRetentionMs then values[name] = true
            else signals[name] = nil end
        end
        return values
    end

    function observability.increment(name, labels, amount)
        name, labels = metricName(name), metricLabels(labels)
        if not name or not labels then return false end
        local candidate = amount == nil and 1 or tonumber(amount)
        if not Validation.isFinite(candidate) then return false end
        local delta = math.max(0, math.floor(candidate))
        counters[name] = math.min(Limits.maximumSafeInteger, (counters[name] or 0) + delta)
        local key = seriesKey(name, labels)
        counterSeries[key] = math.min(Limits.maximumSafeInteger,
            (counterSeries[key] or 0) + delta)
        if name == 'cleanup_failure_total' then recordSignal('graphExecutorFailure') end
        local result = coreCall('Metrics', 'increment', 'synex_interact_' .. name, labels, delta)
        if name == 'lease_total' and labels.outcome == 'issued' then
            observability.increment('lease_granted_total', {}, delta)
        end
        return result
    end

    function observability.gauge(name, labels, value)
        name, labels = metricName(name), metricLabels(labels)
        value = tonumber(value)
        if not name or not labels or not Validation.isFinite(value) then return false end
        gauges[seriesKey(name, labels)] = value
        return coreCall('Metrics', 'gauge', 'synex_interact_' .. name, labels, value)
    end

    function observability.observe(name, labels, value)
        name, labels = metricName(name), metricLabels(labels)
        value = math.max(0, tonumber(value) or 0)
        if not name or not labels or not Validation.isFinite(value) then return false end
        local key = seriesKey(name, labels)
        local record = observations[key]
        if not record then
            record = { name = name, labels = Validation.copy(labels),
                count = 0, total = 0, maximum = 0, latest = 0 }
            observations[key] = record
        end
        record.count = math.min(Limits.maximumSafeInteger, record.count + 1)
        record.total = math.min(Limits.maximumSafeInteger, record.total + value)
        record.maximum, record.latest = math.max(record.maximum, value), value
        if name == 'evaluator_duration_ms' and value > Limits.evaluatorTimeoutMs then
            observability.increment('slow_evaluator_total', {
                provider_kind = labels.provider_kind or 'condition',
                outcome = labels.outcome or 'slow',
            }, 1)
            recordSignal('slowEvaluator')
        elseif name == 'provider_duration_ms' and value > Limits.providerTimeoutMs then
            observability.increment('slow_provider_total', {
                provider_kind = labels.provider_kind or 'dynamic',
                outcome = labels.outcome or 'slow',
            }, 1)
            recordSignal('providerFailure')
        end
        if labels.outcome == 'failure' then recordSignal('providerFailure') end
        return coreCall('Metrics', 'observe', 'synex_interact_' .. name, labels, value)
    end

    function observability.denied(operation, operationError, context)
        local code = type(operationError) == 'table' and operationError.code
            or 'INTERACT_UNAVAILABLE'
        local record = { at = now(), operation = tostring(operation):sub(1, 64),
            code = tostring(code):sub(1, 64) }
        denials[#denials + 1] = record
        if #denials > Limits.maximumDenialRecords then table.remove(denials, 1) end
        observability.increment('denied_total', {
            operation = record.operation, outcome = record.code,
        }, 1)
        if record.operation == 'lease.request' then
            observability.increment('lease_denied_total', { outcome = record.code }, 1)
            if record.code == 'INTERACT_SLOT_BUSY' then
                observability.increment('slot_busy_total', {}, 1)
            end
        end
        local session = type(context) == 'table' and context.session or nil
        if type(session) == 'table' and Validation.token(session.id, 3, 96)
            and Validation.isInteger(context.source, 1, 65535)
            and Validation.isInteger(context.sourceGeneration, 1) then
            -- Reporting is deliberately fail-open. Interaction already rejected
            -- the operation and never delegates correctness to Security.
            coreCall('Services', 'call', 'synex.security', '^1.0.0',
                'reportSignal', {
                    namespace = 'synex.interact',
                    category = 'interaction',
                    detector = 'synex.interact.domain',
                    code = record.code,
                    subject = {
                        sessionId = session.id,
                        source = context.source,
                        sourceGeneration = context.sourceGeneration,
                        userId = session.userId,
                        characterId = session.characterId,
                    },
                    severity = record.code:find('REPLAY', 1, true) and 'MEDIUM' or 'LOW',
                    confidence = 0.55,
                    evidenceClass = 'DOMAIN_AUTHORITATIVE',
                    correlationKey = 'interaction:' .. record.code:lower(),
                    traceId = context.traceId,
                    summary = 'Interaction authority rejected a client operation.',
                    evidenceJson = json.encode({ operation = record.operation }),
                }, { traceId = context.traceId, timeoutMs = 1000 })
        end
    end

    function observability.trace(traceId, frame)
        if not recorderEnabled or not Validation.token(traceId, 8, 64)
            or not Validation.isPlainTable(frame) then return false end
        local copied = Validation.copy(frame)
        if not copied then return false end
        local timestamp = now()
        pruneTraces(timestamp)
        copied.at = timestamp
        copied.traceId = nil
        traceSequence = traceSequence + 1
        copied.recordSequence = traceSequence
        local entry = { traceId = traceId, frame = copied,
            at = timestamp, sequence = traceSequence }
        if traceCount == Limits.maximumTraceFrames then
            traceEntries[traceHead] = entry
            traceHead = traceIndex(2)
        else
            traceCount = traceCount + 1
            traceEntries[traceIndex(traceCount)] = entry
        end
        return true
    end

    function observability.setTraceEnabled(enabled)
        recorderEnabled = enabled == true
        if not recorderEnabled then
            traceEntries, traceHead, traceCount = {}, 1, 0
        end
        return recorderEnabled
    end

    function observability.replay(traceId, limit)
        if not Validation.token(traceId, 8, 64) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction trace ID is invalid.')
        end
        local maximum = Validation.isInteger(limit, 1, 100) and limit or 50
        pruneTraces(now())
        local values, total = {}, 0
        for offset = 1, traceCount do
            local entry = traceEntries[traceIndex(offset)]
            if entry and entry.traceId == traceId then
                total = total + 1
                if #values < maximum then values[#values + 1] = Validation.copy(entry.frame) end
            end
        end
        return { traceId = traceId, frames = values, total = total,
            retained = #values, hasMore = total > #values,
            truncated = total > #values }, nil
    end

    function observability.reportClient(request, context)
        if not Validation.exactObject(request,
            { 'clientEpoch', 'sequence', 'counters', 'gauges' })
            or not Validation.isInteger(request.clientEpoch, 1)
            or not Validation.isInteger(request.sequence, 1)
            or not Validation.isPlainTable(request.counters)
            or not Validation.isPlainTable(request.gauges) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Client interaction telemetry is invalid.')
        end
        local counterCount, gaugeCount = 0, 0
        for key, value in pairs(request.counters) do
            counterCount = counterCount + 1
            if counterCount > 16 or not allowedClientCounters[key]
                or not Validation.isInteger(value, 0, 1000000000000) then
                return Validation.failure('INTERACT_INVALID_REQUEST',
                    'Client interaction telemetry counters are invalid.')
            end
        end
        for key, value in pairs(request.gauges) do
            gaugeCount = gaugeCount + 1
            if gaugeCount > 8 or not allowedClientGauges[key]
                or not Validation.isFinite(value) or value < 0 or value > 1000000000 then
                return Validation.failure('INTERACT_INVALID_REQUEST',
                    'Client interaction telemetry gauges are invalid.')
            end
        end
        local session, source, sourceGeneration = context and context.session,
            context and context.source, context and context.sourceGeneration
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or session.source ~= source or session.sourceGeneration ~= sourceGeneration then
            return Validation.failure('INTERACT_LEASE_STALE',
                'Client interaction telemetry session is stale.')
        end
        local key = session.id .. ':' .. tostring(sourceGeneration)
        local previous = reports[key]
        if previous and request.clientEpoch == previous.epoch
            and request.sequence <= previous.sequence then
            return { accepted = true, duplicate = true,
                nextReportAfterMs = Limits.metricsReportIntervalMs }, nil
        end
        if previous and request.clientEpoch < previous.epoch then
            return Validation.failure('INTERACT_LEASE_STALE',
                'Client interaction telemetry generation is stale.')
        end
        if previous and now() - previous.at < 5000 then
            return Validation.failure('INTERACT_RATE_LIMITED',
                'Client interaction telemetry is rate limited.', true)
        end
        if not previous and reportCount >= Limits.maximumClientMetricSources then
            return Validation.failure('INTERACT_RATE_LIMITED',
                'Client interaction telemetry capacity is exhausted.', true)
        end
        if not previous then reportCount = reportCount + 1 end
        local baseline = previous == nil or request.clientEpoch > previous.epoch
        local counterDeltas = {}
        for name, value in pairs(request.counters) do
            local previousValue = not baseline and previous
                and previous.counters[name] or 0
            if value < previousValue then
                return Validation.failure('INTERACT_INVALID_REQUEST',
                    'Client interaction telemetry counters must be monotonic.')
            end
            local delta = value - previousValue
            if not baseline and delta > Limits.maximumClientCounterDelta then
                return Validation.failure('INTERACT_INVALID_REQUEST',
                    'Client interaction telemetry counter delta is implausible.')
            end
            counterDeltas[name] = baseline and 0 or delta
        end
        reports[key] = { epoch = request.clientEpoch, sequence = request.sequence,
            at = now(), counters = Validation.copy(request.counters),
            gauges = Validation.copy(request.gauges),
            source = source, sourceGeneration = sourceGeneration }
        for name, value in pairs(counterDeltas) do
            if value > 0 then observability.increment(clientCounterMetrics[name], {}, value) end
            if name == 'transportFailures' and value > 0 then
                recordClientSignal('sensorDegraded')
            elseif name == 'providerTimeouts' and value > 0 then
                recordClientSignal('providerFailure')
            end
        end
        for name, value in pairs(request.gauges) do
            observability.gauge(clientGaugeMetrics[name], {}, value)
        end
        observability.increment('client_reports_total', {
            outcome = baseline and 'baseline' or 'accepted' }, 1)
        return { accepted = true, duplicate = false,
            nextReportAfterMs = Limits.metricsReportIntervalMs }, nil
    end

    function observability.playerDropped(source, sourceGeneration)
        local removed = 0
        for key, report in pairs(reports) do
            if report.source == source
                and (sourceGeneration == nil or report.sourceGeneration == sourceGeneration) then
                reports[key], reportCount, removed = nil, reportCount - 1, removed + 1
            end
        end
        return removed
    end

    function observability.audit(action, targetType, targetId, data, context)
        return coreCall('Audit', 'append', {
            action = tostring(action):sub(1, 128),
            targetType = tostring(targetType):sub(1, 64),
            targetId = tostring(targetId):sub(1, 128),
            traceId = context and context.traceId,
            context = Validation.copy(data or {}) or {},
        })
    end

    function observability.event(topic, payload, context)
        return coreCall('Events', 'publish', topic, payload,
            { traceId = context and context.traceId })
    end

    function observability.denials(cursor, limit)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#denials, start + size - 1) do
            items[#items + 1] = Validation.copy(denials[index])
        end
        local hasMore = start + #items - 1 < #denials
        return { items = items, nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end

    function observability.healthSignals()
        return retainedSignals(recentSignals)
    end

    function observability.clientAdvisorySignals()
        return retainedSignals(recentClientSignals)
    end

    function observability.snapshot()
        pruneTraces(now())
        local clientGaugeSummary = {}
        for _, report in pairs(reports) do
            for name, value in pairs(report.gauges or {}) do
                local summary = clientGaugeSummary[name]
                if not summary then
                    summary = { samples = 0, total = 0, maximum = 0 }
                    clientGaugeSummary[name] = summary
                end
                summary.samples = summary.samples + 1
                summary.total = summary.total + value
                summary.maximum = math.max(summary.maximum, value)
            end
        end
        for _, summary in pairs(clientGaugeSummary) do
            summary.average = summary.samples > 0 and summary.total / summary.samples or 0
            summary.total = nil
        end
        return { counters = Validation.copy(counters),
            counterSeries = Validation.copy(counterSeries),
            gauges = Validation.copy(gauges), observations = Validation.copy(observations),
            clientGauges = clientGaugeSummary, denialRecords = #denials,
            traceEnabled = recorderEnabled, traceFrames = traceCount,
            traceCapacity = Limits.maximumTraceFrames,
            traceRetentionMs = Limits.traceRetentionMs,
            clientMetricSources = reportCount,
            signals = observability.healthSignals(),
            clientSignals = observability.clientAdvisorySignals() }
    end

    return observability
end
