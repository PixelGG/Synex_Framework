SynexNotifyObservability = {}

local Validation = assert(SynexNotifyValidation, 'notify validation must be loaded first')
local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded first')

local CLIENT_COUNTER_FIELDS = {
    created = 'created',
    displayed = 'displayed',
    removed = 'removed',
    deduplicated = 'deduplicated',
    grouped = 'grouped',
    suppressed = 'suppressed',
    coalesced = 'coalesced',
    queuePromotions = 'queue_promotions',
    queueEvictions = 'queue_evictions',
    queueWaitTotalMs = 'queue_wait_ms',
    renderDispatchSamples = 'render_dispatch_samples',
    renderDispatchTotalMs = 'render_dispatch_time_ms',
    renderAckSamples = 'render_ack_samples',
    renderAckTotalMs = 'render_ack_time_ms',
    transportFailures = 'transport_failures',
    nativeFallbacks = 'native_fallbacks',
    presentationExpired = 'presentation_expired',
    quietDeferred = 'quiet_deferred',
}
local CLIENT_CANONICAL_METRICS = {
    displayed = 'synex_notify_displayed_total',
    deduplicated = 'synex_notify_deduplicated_total',
    grouped = 'synex_notify_grouped_total',
    suppressed = 'synex_notify_suppressed_total',
    coalesced = 'synex_notify_coalesced_total',
}
local CLIENT_DURATION_FIELDS = {
    queueWaitTotalMs = true,
    renderDispatchTotalMs = true,
    renderAckTotalMs = true,
}

function SynexNotifyObservability.create(options)
    local foundation = assert(options.foundation, 'notify observability requires foundation')
    local coreRef = assert(options.coreRef, 'notify observability requires Core reference')
    local now = options.now or function() return 0 end
    local counters = {
        created = 0, wakeDispatched = 0,
        rateLimited = 0, actions = 0, actionExpired = 0,
        actionReplayed = 0, ownerCleanup = 0, transportFailures = 0,
        payloadRejected = 0, capabilityDenied = 0,
    }
    local observations = {
        wakeDispatches = 0,
        wakeDispatchLatencyTotal = 0,
        validations = 0,
        validationLatencyTotal = 0,
    }
    local metricNames = {
        created = 'created', wakeDispatched = 'wake_dispatched',
        rateLimited = 'rate_limited',
        actions = 'action', actionExpired = 'action_expired',
        actionReplayed = 'action_replayed', ownerCleanup = 'owner_cleanup',
        transportFailures = 'transport_failure', payloadRejected = 'payload_rejected',
        capabilityDenied = 'capability_denied',
    }
    local clientTotals, clientSessions, clientSources = {}, {}, {}
    local clientSessionCount = 0
    local clientReportsAccepted, clientReportsRejected, lastClientReportAt = 0, 0, nil
    for publicName in pairs(CLIENT_COUNTER_FIELDS) do clientTotals[publicName] = 0 end
    local observability = {}

    local function coreMethod(group, method, ...)
        local api = coreRef.value
        local namespace = type(api) == 'table' and api[group] or nil
        local handler = type(namespace) == 'table' and namespace[method] or nil
        if not foundation.isCallable(handler) then return nil end
        return handler(...)
    end

    local function removeClientSession(key)
        local record = clientSessions[key]
        if record == nil then return false end
        if clientSources[record.source] == key then clientSources[record.source] = nil end
        clientSessions[key] = nil
        clientSessionCount = math.max(0, clientSessionCount - 1)
        return true
    end

    local function clientSnapshot(current)
        current = current or now()
        local fresh, stale, visible, queued, pendingVisibilityAcks = 0, 0, 0, 0, 0
        local reportingSessions = 0
        for _, record in pairs(clientSessions) do
            reportingSessions = reportingSessions + 1
            if current - record.lastAcceptedAt <= (Limits.metricsFreshnessMs or 30000) then
                fresh = fresh + 1
                visible = visible + record.gauges.visible
                queued = queued + record.gauges.queued
                pendingVisibilityAcks = pendingVisibilityAcks
                    + record.gauges.pendingVisibilityAcks
            else
                stale = stale + 1
            end
        end
        local queueSamples = clientTotals.queuePromotions or 0
        local dispatchSamples = clientTotals.renderDispatchSamples or 0
        local ackSamples = clientTotals.renderAckSamples or 0
        return {
            aggregation = 'client-reported',
            trust = 'presentation-telemetry-only',
            available = fresh > 0,
            reportingSessions = reportingSessions,
            maximumReportingSessions = Limits.maximumClientMetricSessions or 512,
            freshSessions = fresh,
            staleSessions = stale,
            reportsAccepted = clientReportsAccepted,
            reportsRejected = clientReportsRejected,
            lastReportAgeMs = lastClientReportAt ~= nil
                and math.max(0, current - lastClientReportAt) or nil,
            freshnessMs = Limits.metricsFreshnessMs or 30000,
            counters = foundation.copy(clientTotals),
            gauges = {
                visible = visible,
                queued = queued,
                pendingVisibilityAcks = pendingVisibilityAcks,
            },
            averages = {
                queueWaitMs = queueSamples > 0
                    and (clientTotals.queueWaitTotalMs or 0) / queueSamples or 0,
                renderDispatchMs = dispatchSamples > 0
                    and (clientTotals.renderDispatchTotalMs or 0) / dispatchSamples or 0,
                renderAckMs = ackSamples > 0
                    and (clientTotals.renderAckTotalMs or 0) / ackSamples or 0,
            },
        }
    end

    local function updateClientGauges()
        local snapshot = clientSnapshot(now())
        coreMethod('Metrics', 'gauge', 'synex_notify_client_visible', {},
            snapshot.gauges.visible)
        coreMethod('Metrics', 'gauge', 'synex_notify_client_queued', {},
            snapshot.gauges.queued)
        coreMethod('Metrics', 'gauge', 'synex_notify_queue_depth', {},
            snapshot.gauges.queued)
        coreMethod('Metrics', 'gauge', 'synex_notify_client_pending_visibility_acks', {},
            snapshot.gauges.pendingVisibilityAcks)
        coreMethod('Metrics', 'gauge', 'synex_notify_client_reporting_sessions', {},
            snapshot.freshSessions)
        return snapshot
    end

    function observability.increment(name, amount)
        if counters[name] ~= nil then
            counters[name] = math.min(9007199254740991,
                counters[name] + math.max(0, math.floor(tonumber(amount) or 1)))
        end
        coreMethod('Metrics', 'increment',
            'synex_notify_' .. (metricNames[name] or name) .. '_total', {}, amount or 1)
    end

    function observability.gauge(name, value)
        coreMethod('Metrics', 'gauge', 'synex_notify_' .. name, {}, value)
    end

    function observability.observeWakeDispatch(milliseconds)
        local value = math.max(0, tonumber(milliseconds) or 0)
        observations.wakeDispatches = observations.wakeDispatches + 1
        observations.wakeDispatchLatencyTotal = observations.wakeDispatchLatencyTotal + value
        coreMethod('Metrics', 'observe', 'synex_notify_wake_dispatch_latency', {}, value)
    end

    function observability.observeValidation(milliseconds)
        local value = math.max(0, tonumber(milliseconds) or 0)
        observations.validations = observations.validations + 1
        observations.validationLatencyTotal = observations.validationLatencyTotal + value
        coreMethod('Metrics', 'observe', 'synex_notify_validation_latency', {}, value)
    end

    function observability.reportClient(request, context)
        local allowedCounters = {}
        for name in pairs(CLIENT_COUNTER_FIELDS) do allowedCounters[name] = true end
        if not Validation.exactObject(request, {
            clientEpoch = true, sequence = true, counters = true, gauges = true,
        }) or not Validation.isInteger(request.clientEpoch, 1, Limits.maximumSafeInteger)
            or not Validation.isInteger(request.sequence, 1, Limits.maximumSafeInteger)
            or not Validation.exactObject(request.counters, allowedCounters)
            or not Validation.exactObject(request.gauges, {
                visible = true, queued = true, pendingVisibilityAcks = true,
            }) then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The client presentation metric report is invalid.')
        end
        for name in pairs(CLIENT_COUNTER_FIELDS) do
            if not Validation.isInteger(request.counters[name], 0,
                Limits.metricsMaximumCounter or 1000000000000) then
                clientReportsRejected = math.min(Limits.maximumSafeInteger,
                    clientReportsRejected + 1)
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'A client presentation metric counter is invalid.')
            end
        end
        if not Validation.isInteger(request.gauges.visible, 0, Limits.maximumVisible)
            or not Validation.isInteger(request.gauges.queued, 0, Limits.maximumQueue)
            or not Validation.isInteger(request.gauges.pendingVisibilityAcks, 0,
                Limits.maximumQueue) then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'A client presentation metric gauge is invalid.')
        end
        local session = type(context) == 'table' and context.session or nil
        local source = type(context) == 'table' and context.source or nil
        local sourceGeneration = type(context) == 'table'
            and context.sourceGeneration or nil
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or type(session.id) ~= 'string' or #session.id < 8
            or #session.id > Limits.maximumSessionIdBytes
            or not Validation.isInteger(source, 1, Limits.maximumPlayerSource)
            or not Validation.isInteger(sourceGeneration, 1, Limits.maximumSafeInteger)
            or session.source ~= source or session.sourceGeneration ~= sourceGeneration then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The client presentation metric session is stale.')
        end

        local current = now()
        local key = session.id .. ':' .. tostring(sourceGeneration)
        local previousKey = clientSources[source]
        local record = nil
        if previousKey == nil or previousKey == key then record = clientSessions[key] end
        if record ~= nil and request.clientEpoch == record.clientEpoch
            and request.sequence <= record.sequence then
            return {
                accepted = true, duplicate = true,
                nextReportAfterMs = Limits.metricsReportIntervalMs or 10000,
            }
        end
        if record ~= nil and request.clientEpoch < record.clientEpoch then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The client presentation metric generation is stale.')
        end
        if record ~= nil and current - record.lastAcceptedAt
            < (Limits.metricsMinimumReportIntervalMs or 5000) then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The client presentation metric report rate is limited.', true)
        end

        local sameEpoch = record ~= nil and record.clientEpoch == request.clientEpoch
        local deltas = {}
        for publicName in pairs(CLIENT_COUNTER_FIELDS) do
            local previous = sameEpoch and record.counters[publicName] or 0
            local candidate = request.counters[publicName]
            local delta = candidate - previous
            local maximumDelta = CLIENT_DURATION_FIELDS[publicName]
                and (Limits.metricsMaximumCounterDelta or 512)
                    * (Limits.maximumLifetimeMs or 120000)
                or (Limits.metricsMaximumCounterDelta or 512)
            if candidate < previous or sameEpoch and delta > maximumDelta then
                clientReportsRejected = math.min(Limits.maximumSafeInteger,
                    clientReportsRejected + 1)
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'A client presentation metric counter delta is invalid.')
            end
            deltas[publicName] = sameEpoch and delta or 0
        end
        if sameEpoch and (deltas.queueWaitTotalMs
                > deltas.queuePromotions * (Limits.maximumLifetimeMs or 120000)
            or deltas.renderDispatchTotalMs
                > deltas.renderDispatchSamples * (Limits.maximumDurationMs or 30000)
            or deltas.renderAckTotalMs
                > deltas.renderAckSamples * (Limits.maximumLifetimeMs or 120000)) then
            clientReportsRejected = math.min(Limits.maximumSafeInteger,
                clientReportsRejected + 1)
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'A client presentation latency aggregate is invalid.')
        end
        local epochWindowStartedAt = record and record.epochWindowStartedAt or current
        local epochAdvances = record and record.epochAdvances or 0
        if record ~= nil and not sameEpoch then
            if current - epochWindowStartedAt
                >= (Limits.metricsEpochAdvanceWindowMs or 60000) then
                epochWindowStartedAt, epochAdvances = current, 0
            end
            if epochAdvances >= (Limits.metricsMaximumEpochAdvances or 3)
                or request.sequence > (Limits.metricsMaximumEpochAdvances or 3) + 1 then
                clientReportsRejected = math.min(Limits.maximumSafeInteger,
                    clientReportsRejected + 1)
                return Validation.failure('NOTIFY_RATE_LIMITED',
                    'The client presentation metric generation rate is limited.', true)
            end
            epochAdvances = epochAdvances + 1
        end

        if previousKey ~= nil and previousKey ~= key then
            removeClientSession(previousKey)
        end
        if clientSessions[key] == nil
            and clientSessionCount >= (Limits.maximumClientMetricSessions or 512) then
            local oldestKey, oldestAt = nil, nil
            for candidateKey, candidate in pairs(clientSessions) do
                if oldestAt == nil or candidate.lastAcceptedAt < oldestAt
                    or candidate.lastAcceptedAt == oldestAt
                        and candidateKey < oldestKey then
                    oldestKey, oldestAt = candidateKey, candidate.lastAcceptedAt
                end
            end
            if oldestKey == nil or current - oldestAt
                <= (Limits.metricsFreshnessMs or 30000) then
                clientReportsRejected = math.min(Limits.maximumSafeInteger,
                    clientReportsRejected + 1)
                return Validation.failure('NOTIFY_QUEUE_FULL',
                    'The client presentation metric registry is at capacity.', true)
            end
            removeClientSession(oldestKey)
        end
        if clientSessions[key] == nil then clientSessionCount = clientSessionCount + 1 end
        clientSessions[key] = {
            source = source,
            sourceGeneration = sourceGeneration,
            clientEpoch = request.clientEpoch,
            sequence = request.sequence,
            counters = foundation.copy(request.counters),
            gauges = foundation.copy(request.gauges),
            lastAcceptedAt = current,
            epochWindowStartedAt = epochWindowStartedAt,
            epochAdvances = epochAdvances,
        }
        clientSources[source] = key
        clientReportsAccepted = math.min(Limits.maximumSafeInteger,
            clientReportsAccepted + 1)
        lastClientReportAt = current
        for publicName, metricName in pairs(CLIENT_COUNTER_FIELDS) do
            local delta = deltas[publicName]
            if delta > 0 then
                clientTotals[publicName] = math.min(Limits.maximumSafeInteger,
                    clientTotals[publicName] + delta)
                coreMethod('Metrics', 'increment',
                    'synex_notify_client_' .. metricName .. '_total', {}, delta)
                local canonical = CLIENT_CANONICAL_METRICS[publicName]
                if canonical ~= nil then
                    coreMethod('Metrics', 'increment', canonical, {}, delta)
                end
            end
        end
        if deltas.queuePromotions > 0 then
            coreMethod('Metrics', 'observe', 'synex_notify_queue_wait', {},
                deltas.queueWaitTotalMs / deltas.queuePromotions)
        end
        if deltas.renderAckSamples > 0 then
            coreMethod('Metrics', 'observe', 'synex_notify_render_latency', {},
                deltas.renderAckTotalMs / deltas.renderAckSamples)
        end
        updateClientGauges()
        return {
            accepted = true, duplicate = false,
            nextReportAfterMs = Limits.metricsReportIntervalMs or 10000,
        }
    end

    function observability.playerDropped(source)
        local key = clientSources[source]
        if key == nil then return false end
        removeClientSession(key)
        updateClientGauges()
        return true
    end

    function observability.refreshClientGauges()
        return updateClientGauges()
    end

    function observability.audit(action, targetType, targetId, data, traceId)
        local entry = {
            action = action,
            targetType = targetType,
            targetId = targetId,
            context = type(data) == 'table' and data or {},
        }
        if type(traceId) == 'string' then entry.traceId = traceId end
        return coreMethod('Audit', 'append', entry)
    end

    function observability.event(topic, payload, context)
        return coreMethod('Events', 'publish', topic, payload, {
            traceId = context and context.traceId,
        })
    end

    function observability.snapshot()
        local result = foundation.copy(counters)
        result.wakeDispatchSamples = observations.wakeDispatches
        result.averageWakeDispatchLatencyMs = observations.wakeDispatches > 0
            and observations.wakeDispatchLatencyTotal / observations.wakeDispatches or 0
        result.validationSamples = observations.validations
        result.averageValidationLatencyMs = observations.validations > 0
            and observations.validationLatencyTotal / observations.validations or 0
        result.clientPresentation = clientSnapshot(now())
        return result
    end

    return observability
end
