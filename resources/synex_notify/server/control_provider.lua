SynexNotifyControlProvider = {}

local Validation = assert(SynexNotifyValidation, 'notify validation must be loaded first')
local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded first')

local VIEWS = {
    { id = 'overview', label = 'Notify overview', operation = 'summary',
        presentation = 'key-value', order = 10,
        description = 'Bounded delivery, owner, progress, action, and server admission totals.',
        accessClass = 'general' },
    { id = 'health', label = 'Notify health', operation = 'health',
        presentation = 'key-value', order = 20,
        description = 'Current Core, UI runtime, transport, and capacity health.',
        accessClass = 'general' },
    { id = 'owners', label = 'Owners', operation = 'list',
        presentation = 'table', order = 30,
        description = 'Bounded per-resource activity aggregates without message or player data.',
        accessClass = 'general' },
    { id = 'budgets', label = 'Budgets', operation = 'list',
        presentation = 'table', order = 40,
        description = 'Configured visible, queue, action, history, and target-list bounds.',
        accessClass = 'general' },
    { id = 'rate_limits', label = 'Rate limits', operation = 'list',
        presentation = 'table', order = 50,
        description = 'Configured resource, kind, high, critical, and global token budgets.',
        accessClass = 'general' },
    { id = 'activity', label = 'Lifecycle activity', operation = 'metrics',
        presentation = 'metrics', order = 60,
        description = 'Created, wake-dispatched, admission, and action totals measured by the server.',
        accessClass = 'general' },
    { id = 'queue', label = 'Queue and capacity', operation = 'metrics',
        presentation = 'metrics', order = 61,
        description = 'Retained delivery pressure against the bounded server registry.',
        accessClass = 'general' },
    { id = 'deduplication', label = 'Deduplication', operation = 'metrics',
        presentation = 'metrics', order = 62,
        description = 'Fresh, client-reported deduplication totals without content or identity labels.',
        accessClass = 'general' },
    { id = 'grouping', label = 'Grouping', operation = 'metrics',
        presentation = 'metrics', order = 63,
        description = 'Fresh, client-reported grouping totals without content or identity labels.',
        accessClass = 'general' },
    { id = 'suppression', label = 'Suppression', operation = 'metrics',
        presentation = 'metrics', order = 64,
        description = 'Client-reported presentation suppression and separate server admission denials.',
        accessClass = 'general' },
    { id = 'progress', label = 'Progress', operation = 'metrics',
        presentation = 'metrics', order = 65,
        description = 'Current non-terminal progress count.',
        accessClass = 'general' },
    { id = 'actions', label = 'Actions', operation = 'metrics',
        presentation = 'metrics', order = 66,
        description = 'Bounded action backlog, invocation, expiry, and replay totals.',
        accessClass = 'general' },
    { id = 'performance', label = 'Performance', operation = 'metrics',
        presentation = 'metrics', order = 67,
        description = 'Server wake latency plus fresh client-reported render and queue latency.',
        accessClass = 'general' },
    { id = 'findings', label = 'Findings', operation = 'findings',
        presentation = 'findings', order = 70,
        description = 'Bounded queue pressure, action backlog, spam, priority, and orphan findings.',
        accessClass = 'general' },
    { id = 'policy', label = 'Presentation policy simulator', operation = 'simulate',
        presentation = 'detail', order = 80,
        description = 'Validate and explain a notification shape without sending it.',
        accessClass = 'general' },
}

function SynexNotifyControlProvider.create(options)
    local registry = assert(options.registry, 'notify control provider requires registry')
    local getResourceState = options.getResourceState or GetResourceState
    local now = assert(options.now, 'notify control provider requires monotonic time')
    local provider = {}

    local function page(items, limit)
        local truncated = limit ~= nil and #items > limit
        while limit ~= nil and #items > limit do items[#items] = nil end
        return { items = items, hasMore = truncated, truncated = truncated }
    end

    local function exact(value, allowed, required)
        if not Validation.exactObject(value, allowed) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification control request is invalid.')
        end
        for _, key in ipairs(required or {}) do
            if value[key] == nil then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'The notification control request is incomplete.')
            end
        end
        return value
    end

    local function presentationMetrics(snapshot)
        local metrics = type(snapshot) == 'table' and snapshot.metrics or nil
        local client = type(metrics) == 'table' and metrics.clientPresentation or nil
        if type(client) == 'table' then return client end
        return {
            aggregation = 'client-reported',
            trust = 'presentation-telemetry-only',
            available = false,
            reportingSessions = 0,
            freshSessions = 0,
            staleSessions = 0,
            reportsAccepted = 0,
            reportsRejected = 0,
            freshnessMs = Limits.metricsFreshnessMs or 30000,
            counters = {}, gauges = { visible = 0, queued = 0,
                pendingVisibilityAcks = 0 },
            averages = { queueWaitMs = 0, renderDispatchMs = 0,
                renderAckMs = 0 },
        }
    end

    local operations = {}
    operations.summary = function(request)
        local value, valueError = exact(request, { view = true }, { 'view' })
        if not value or value.view ~= 'overview' then
            return nil, valueError or { code = 'NOTIFY_INVALID_REQUEST',
                message = 'The Notify overview view is invalid.', retryable = false }
        end
        local snapshot = registry.snapshot()
        local client = presentationMetrics(snapshot)
        return {
            state = 'ephemeral', persistence = 'none',
            activeDeliveries = snapshot.active,
            activeProgress = snapshot.progressActive,
            actionTokens = snapshot.actionTokens,
            pendingCommands = snapshot.pendingCommands,
            owners = snapshot.ownerCount,
            maximumDeliveries = snapshot.maximumRecords,
            maximumPendingCommands = snapshot.maximumPendingCommands,
            created = snapshot.metrics.created,
            wakeDispatched = snapshot.metrics.wakeDispatched,
            clientPresentationMetrics = {
                aggregation = client.aggregation,
                trust = client.trust,
                available = client.available,
                freshSessions = client.freshSessions,
                staleSessions = client.staleSessions,
                reportsAccepted = client.reportsAccepted,
                reportsRejected = client.reportsRejected,
                freshnessMs = client.freshnessMs,
                lastReportAgeMs = client.lastReportAgeMs,
            },
            rateLimited = snapshot.metrics.rateLimited,
            capabilityDenied = snapshot.metrics.capabilityDenied,
        }, nil
    end
    operations.health = function(request)
        local value, valueError = exact(request, { view = true }, { 'view' })
        if not value or value.view ~= 'health' then
            return nil, valueError or { code = 'NOTIFY_INVALID_REQUEST',
                message = 'The Notify health view is invalid.', retryable = false }
        end
        local doctor = registry.doctor(50)
        local uiState = getResourceState('synex_ui')
        local state = doctor.status
        local reasons = {}
        if uiState ~= 'started' then
            state = 'DEGRADED'
            reasons[#reasons + 1] = 'UI_RUNTIME_UNAVAILABLE'
        end
        if doctor.status ~= 'READY' then reasons[#reasons + 1] = 'DOCTOR_FINDINGS' end
        return { state = state, uiRuntime = uiState, reasons = reasons,
            findings = #doctor.findings }, nil
    end
    operations.list = function(request)
        local value, valueError = exact(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' })
        if not value then return nil, valueError end
        if value.cursor ~= nil or value.filters ~= nil or value.sort ~= nil then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Notify aggregate lists do not accept cursors, filters, or sorting.')
        end
        local limit = value.limit or 50
        if not Validation.isInteger(limit, 1, 100) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The Notify list limit is invalid.')
        end
        if value.view == 'owners' then
            local owners = registry.snapshot().owners
            return page(owners, limit)
        end
        if value.view == 'budgets' then
            return page({
                { scope = 'visible', maximum = Limits.maximumVisible or 4 },
                { scope = 'client_queue', maximum = Limits.maximumQueue or 128 },
                { scope = 'server_registry', maximum = Limits.maximumServerNotifications or 512 },
                { scope = 'owner_registry', maximum = Limits.maximumOwnerNotifications or 64 },
                { scope = 'history', maximum = Limits.maximumHistory or 128 },
                { scope = 'action_tokens', maximum = Limits.maximumActionTokens or 512 },
                { scope = 'pending_commands', maximum = Limits.maximumPendingCommands or 1024,
                    perSource = Limits.maximumPendingCommandsPerSource or 128,
                    ttlMs = Limits.pendingCommandTtlMs or 10000 },
                { scope = 'send_many', maximum = Limits.maximumSendMany or 32 },
                { scope = 'broadcast', maximum = Limits.maximumBroadcastTargets or 256 },
            }, limit)
        end
        if value.view == 'rate_limits' then
            local rates = Limits.rateLimits or {}
            local items = {}
            for scope, policy in pairs(rates) do
                items[#items + 1] = {
                    scope = scope,
                    capacity = policy.capacity,
                    refillPerSecond = policy.refillPerSecond,
                }
            end
            table.sort(items, function(left, right) return left.scope < right.scope end)
            return page(items, limit)
        end
        return Validation.failure('NOTIFY_INVALID_REQUEST',
            'The Notify aggregate list view is invalid.')
    end
    operations.metrics = function(request)
        local value, valueError = exact(request, { view = true }, { 'view' })
        local supported = {
            activity = true, queue = true, deduplication = true, grouping = true,
            suppression = true, progress = true, actions = true, performance = true,
        }
        if not value or not supported[value.view] then
            return nil, valueError or { code = 'NOTIFY_INVALID_REQUEST',
                message = 'The Notify metrics view is invalid.', retryable = false }
        end
        local snapshot = registry.snapshot()
        local client = presentationMetrics(snapshot)
        if value.view == 'queue' then
            return {
                retainedDeliveries = snapshot.active,
                activePresentations = snapshot.presenting,
                dormantRetained = snapshot.retained,
                maximumRetainedDeliveries = snapshot.maximumRecords,
                pendingCommands = snapshot.pendingCommands,
                maximumPendingCommands = snapshot.maximumPendingCommands,
                pendingCommandUtilization = snapshot.maximumPendingCommands > 0
                    and snapshot.pendingCommands / snapshot.maximumPendingCommands or 0,
                utilization = snapshot.maximumRecords > 0
                    and snapshot.active / snapshot.maximumRecords or 0,
                clientReported = {
                    aggregation = client.aggregation,
                    trust = client.trust,
                    available = client.available,
                    freshSessions = client.freshSessions,
                    visible = client.gauges.visible,
                    queued = client.gauges.queued,
                    pendingVisibilityAcks = client.gauges.pendingVisibilityAcks,
                    promotions = client.counters.queuePromotions or 0,
                    evictions = client.counters.queueEvictions or 0,
                    averageWaitMs = client.averages.queueWaitMs,
                },
            }, nil
        end
        if value.view == 'deduplication' then
            return {
                aggregation = client.aggregation,
                trust = client.trust,
                available = client.available,
                deduplicated = client.counters.deduplicated or 0,
                reportsAccepted = client.reportsAccepted,
            }, nil
        end
        if value.view == 'grouping' then
            return {
                aggregation = client.aggregation,
                trust = client.trust,
                available = client.available,
                grouped = client.counters.grouped or 0,
                reportsAccepted = client.reportsAccepted,
            }, nil
        end
        if value.view == 'suppression' then
            return {
                aggregation = client.aggregation,
                trust = client.trust,
                available = client.available,
                suppressed = client.counters.suppressed or 0,
                quietDeferred = client.counters.quietDeferred or 0,
                rateLimited = snapshot.metrics.rateLimited,
                capabilityDenied = snapshot.metrics.capabilityDenied,
            }, nil
        end
        if value.view == 'progress' then
            return { active = snapshot.progressActive }, nil
        end
        if value.view == 'actions' then
            return {
                activeTokens = snapshot.actionTokens,
                invoked = snapshot.metrics.actions,
                expired = snapshot.metrics.actionExpired,
                replayed = snapshot.metrics.actionReplayed,
            }, nil
        end
        if value.view == 'performance' then
            return {
                wakeDispatchSamples = snapshot.metrics.wakeDispatchSamples,
                averageWakeDispatchLatencyMs = snapshot.metrics.averageWakeDispatchLatencyMs,
                validationSamples = snapshot.metrics.validationSamples,
                averageValidationLatencyMs = snapshot.metrics
                    .averageValidationLatencyMs,
                transportFailures = snapshot.metrics.transportFailures,
                clientReported = {
                    aggregation = client.aggregation,
                    trust = client.trust,
                    available = client.available,
                    renderDispatchSamples = client.counters.renderDispatchSamples or 0,
                    averageRenderDispatchLatencyMs = client.averages.renderDispatchMs,
                    renderAckSamples = client.counters.renderAckSamples or 0,
                    averageRenderAckLatencyMs = client.averages.renderAckMs,
                    transportFailures = client.counters.transportFailures or 0,
                    coalesced = client.counters.coalesced or 0,
                },
            }, nil
        end
        return {
            counters = snapshot.metrics,
            active = snapshot.active,
            progressActive = snapshot.progressActive,
            actionTokens = snapshot.actionTokens,
        }, nil
    end
    operations.findings = function(request)
        local value, valueError = exact(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' })
        if not value or value.view ~= 'findings' or value.cursor ~= nil
            or value.filters ~= nil or value.sort ~= nil then
            return nil, valueError or { code = 'NOTIFY_INVALID_REQUEST',
                message = 'The Notify findings view is invalid.', retryable = false }
        end
        return registry.doctor(value.limit)
    end
    operations.simulate = function(request)
        local value, valueError = exact(request, { view = true, input = true }, { 'view', 'input' })
        if not value or value.view ~= 'policy' then
            return nil, valueError or { code = 'NOTIFY_INVALID_REQUEST',
                message = 'The Notify policy simulation is invalid.', retryable = false }
        end
        local canonical, canonicalError = Validation.canonicalNotification(value.input, {
            authority = 'SERVER', ownerResource = 'synex_control', now = now(),
        })
        if not canonical then return nil, canonicalError end
        return {
            valid = true,
            kind = canonical.kind,
            tone = canonical.tone,
            priority = canonical.priority,
            position = canonical.position,
            durationMs = canonical.durationMs,
            maximumLifetimeMs = canonical.maxLifetimeMs,
            actionCount = #(canonical.actions or {}),
            history = canonical.history,
            sends = false,
        }, nil
    end

    local bounded = {}
    for name, handler in pairs(operations) do
        bounded[name] = function(...)
            local ok, result, operationError = pcall(handler, ...)
            if not ok then
                return nil, { code = 'NOTIFY_UNAVAILABLE',
                    message = 'The Notify control read is unavailable.', retryable = true }
            end
            return result, operationError
        end
    end

    function provider.register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not SynexNotifyFoundation.isCallable(register) then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The Core control-provider registry is unavailable.', true)
        end
        return register({
            schemaVersion = 1,
            namespace = 'notify',
            label = 'Notify',
            category = 'foundation',
            version = '1.0.0',
            operations = bounded,
            views = VIEWS,
        })
    end

    provider.views = VIEWS
    provider.operations = operations
    return provider
end
