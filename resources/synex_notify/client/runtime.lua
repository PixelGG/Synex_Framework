local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded before client runtime')
local Validation = assert(SynexNotifyValidation,
    'notify validation must be loaded before client runtime')
local EngineFactory = assert(SynexNotifyEngine,
    'notify client engine must be loaded before client runtime')
local RESOURCE_NAME = GetCurrentResourceName()
local EVENT_NAME = 'synex_notify:client:command:v1'
local SUPPORTED_API_RANGES = {
    ['1'] = true, ['1.0'] = true, ['1.0.0'] = true, ['v1'] = true,
    ['^1.0.0'] = true,
}
local COMPATIBILITY_PROVIDERS = {
    qb = 'synex_bridge_qb',
    qbx = 'synex_bridge_qbx',
    esx = 'synex_bridge_esx',
}
local ACTION_COMMANDS = {
    { index = 1, keyboard = 'F9', gamepad = 'LLEFT_INDEX' },
    { index = 2, keyboard = 'F10', gamepad = 'LRIGHT_INDEX' },
}
local UI_RETRY_DELAYS_MS = { 0, 50, 150, 400, 1000, 2000, 4000 }
local UI_RETRY_STEADY_MS = 5000
local owners, ownerEpochSerial = {}, 0
local uiApi, uiBindingGeneration = nil, 0
local timerGeneration, timerArmed, timerDeadline, runtimeActive = 0, false, nil, true
local uiRetryGeneration, uiRetryAttempt = 0, 0
local visibilitySyncGeneration = 0
local metricsReportGeneration, metricsReportSequence, metricsClientEpoch = 0, 0, nil
local sessionRef, seenCommands, commandOrder = nil, {}, {}
local wakeQueue, queuedWakeIds = {}, {}
local wakeHead, wakeTail, wakeCount, wakeProcessing = 1, 0, 0, false
local wakePullTokens = Limits.commandPullBudgetCapacity or 32
local wakePullUpdatedAt = nil
local previousRawTimer, monotonicElapsed = nil, 0
local engine
local scheduleVisibilitySync
local CLIENT_METRIC_NAMES = {
    created = true, displayed = true, render_dispatches = true,
    transport_failures = true, native_fallbacks = true, removed = true,
    queue_wait_ms = true, queue_promotions = true, queue_evictions = true,
    rate_limited = true, burst_rejected = true, coalesced = true, deduplicated = true,
    suppressed = true, grouped = true, actions = true, action_replayed = true,
    action_expired = true, owner_cleanup = true, quiet_deferred = true,
    context_updates = true, ui_rebind_attempts = true,
    ui_rebind_successes = true, ui_rebind_failures = true,
    server_command_rejected = true,
    presentation_expired = true,
    validation_samples = true, validation_time_ms = true,
    render_dispatch_samples = true, render_dispatch_time_ms = true,
    render_ack_samples = true, render_ack_time_ms = true,
}
local CLIENT_REPORT_COUNTERS = {
    created = 'created', displayed = 'displayed', removed = 'removed',
    deduplicated = 'deduplicated', grouped = 'grouped', suppressed = 'suppressed',
    coalesced = 'coalesced', queuePromotions = 'queue_promotions',
    queueEvictions = 'queue_evictions', queueWaitTotalMs = 'queue_wait_ms',
    renderDispatchSamples = 'render_dispatch_samples',
    renderDispatchTotalMs = 'render_dispatch_time_ms',
    renderAckSamples = 'render_ack_samples',
    renderAckTotalMs = 'render_ack_time_ms',
    transportFailures = 'transport_failures', nativeFallbacks = 'native_fallbacks',
    presentationExpired = 'presentation_expired', quietDeferred = 'quiet_deferred',
}
local clientMetrics = {}

local function observeClientMetric(name, amount)
    if not CLIENT_METRIC_NAMES[name] then return end
    local value = tonumber(amount) or 1
    if value ~= value or value < 0 then return end
    clientMetrics[name] = math.min(Limits.maximumSafeInteger,
        (clientMetrics[name] or 0) + value)
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local readable, metadata = pcall(getmetatable, value)
    return readable and type(metadata) == 'table' and type(metadata.__call) == 'function'
end

local function monotonicNow()
    local read, raw = pcall(GetGameTimer)
    if not read or type(raw) ~= 'number' then return monotonicElapsed end
    local current = math.floor(raw) % 4294967296
    if previousRawTimer == nil then
        previousRawTimer, monotonicElapsed = current, current
        return monotonicElapsed
    end
    local delta = (current - previousRawTimer) % 4294967296
    if delta <= 2147483648 then
        previousRawTimer = current
        monotonicElapsed = math.min(Limits.maximumSafeInteger, monotonicElapsed + delta)
    end
    return monotonicElapsed
end

local function observeValidation(startedAt)
    observeClientMetric('validation_samples')
    observeClientMetric('validation_time_ms', math.max(0, monotonicNow() - startedAt))
end

local function uiCall(method, ...)
    local handler = type(uiApi) == 'table' and uiApi[method] or nil
    if not isCallable(handler) then
        return Validation.failure('NOTIFY_UI_UNAVAILABLE',
            'The Synex UI signal runtime is unavailable.', true)
    end
    local invoked, result, callError = pcall(handler, ...)
    if not invoked or result == nil or result == false or callError ~= nil then
        return nil, type(callError) == 'table' and callError or {
            code = 'NOTIFY_UI_UNAVAILABLE',
            message = 'The Synex UI signal runtime rejected the request.',
            retryable = true,
        }
    end
    return result, nil
end

local function nativeCriticalFallback(descriptor)
    if descriptor.priority ~= 'critical' then return false end
    local text = descriptor.title
    if descriptor.message ~= nil and descriptor.message ~= '' then
        text = text .. ': ' .. descriptor.message
    end
    text = text:gsub('~', '-'):gsub('[\r\n\t]', ' ')
    if #text > 99 then
        text = text:sub(1, 99)
        if type(utf8) == 'table' and type(utf8.len) == 'function' then
            while #text > 0 and utf8.len(text) == nil do text = text:sub(1, -2) end
        end
    end
    local shown = pcall(function()
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(text)
        EndTextCommandThefeedPostTicker(true, true)
    end)
    return shown
end

engine = EngineFactory.create({
    now = monotonicNow,
    upsertSignal = function(descriptor)
        local result, callError = uiCall('upsertSignal', descriptor)
        if result ~= nil and scheduleVisibilitySync then scheduleVisibilitySync() end
        return result, callError
    end,
    removeSignal = function(signalId, revision)
        local result, callError = uiCall('removeSignal', signalId, revision)
        if result ~= nil and scheduleVisibilitySync then scheduleVisibilitySync() end
        return result, callError
    end,
    nativeFallback = nativeCriticalFallback,
    invokeServerAction = function(token, notificationId, revision)
        local invoked, result, callError = pcall(function()
            return exports.synex_core:Call('synex.notify.action.invoke', '1.0.0', {
                token = token,
                notificationId = notificationId,
                revision = revision,
            })
        end)
        if not invoked or result == false or result == nil then
            return nil, type(callError) == 'table' and callError or {
                code = 'NOTIFY_UNAVAILABLE',
                message = 'The notification action service is unavailable.',
                retryable = true,
            }
        end
        return result, callError
    end,
    playSound = function(tone, volume)
        local result, soundError = uiCall('playSignalSound', {
            tone = tone,
            volume = volume,
        })
        return result ~= nil, soundError
    end,
    observe = observeClientMetric,
})

local function armTimer()
    if not runtimeActive then return end
    local deadline = engine.nextDeadline()
    if deadline == nil then
        if timerArmed then timerGeneration = timerGeneration + 1 end
        timerArmed, timerDeadline = false, nil
        return
    end
    if timerArmed and timerDeadline ~= nil and timerDeadline <= deadline then return end
    timerArmed = true
    timerDeadline = deadline
    timerGeneration = timerGeneration + 1
    local generation = timerGeneration
    local delay = math.max(0, math.min(Limits.timerMaximumDelayMs,
        math.ceil(deadline - monotonicNow())))
    SetTimeout(delay, function()
        if not runtimeActive or generation ~= timerGeneration then return end
        timerArmed, timerDeadline = false, nil
        engine.tick()
        armTimer()
    end)
end

scheduleVisibilitySync = function()
    if not runtimeActive or uiApi == nil then return end
    visibilitySyncGeneration = visibilitySyncGeneration + 1
    local generation, attempt = visibilitySyncGeneration, 0
    local retryDelays = { 0, 25, 75, 150, 300, 500 }
    local poll
    poll = function()
        if not runtimeActive or generation ~= visibilitySyncGeneration
            or uiApi == nil then return end
        attempt = attempt + 1
        local snapshot = uiCall('getSignalSnapshot')
        if snapshot ~= nil then engine.confirmVisibility(snapshot) end
        armTimer()
        if generation ~= visibilitySyncGeneration then return end
        local state = engine.snapshot()
        if state.actionTokens <= 0 and state.pendingVisibilityAcks <= 0 then return end
        local delay = retryDelays[attempt + 1]
            or (engine.visibilityReady() and 1000 or 500)
        SetTimeout(delay, poll)
    end
    SetTimeout(retryDelays[1], poll)
end

local function rebindUi()
    if not runtimeActive then return false end
    observeClientMetric('ui_rebind_attempts')
    uiBindingGeneration = uiBindingGeneration + 1
    local invoked, candidate, bindError = pcall(function()
        return exports.synex_ui:GetAPI('^1.0.0')
    end)
    if not invoked or type(candidate) ~= 'table' or bindError ~= nil
        or candidate.ownerResource ~= RESOURCE_NAME
        or not Validation.isInteger(candidate.ownerEpoch, 1, Limits.maximumSafeInteger)
        or not isCallable(candidate.upsertSignal) or not isCallable(candidate.removeSignal)
        or not isCallable(candidate.getSignalSnapshot)
        or not isCallable(candidate.bindSignalCapacity)
        or not isCallable(candidate.reportInputDevice) then
        uiApi = nil
        observeClientMetric('ui_rebind_failures')
        return false
    end
    uiApi = candidate
    local bindingGeneration = uiBindingGeneration
    local capacityBinding = uiCall('bindSignalCapacity', function(update)
        if not runtimeActive or bindingGeneration ~= uiBindingGeneration
            or uiApi ~= candidate then return false end
        if not Validation.exactObject(update, {
            ownerResource = true, ownerEpoch = true, capacity = true,
            preferences = true,
        }) or update.ownerResource ~= RESOURCE_NAME
            or update.ownerEpoch ~= candidate.ownerEpoch then return false end
        local appliedPreferences = engine.setUiPreferences(update.preferences)
        if not appliedPreferences then return false end
        local configured = engine.setVisibleCapacity(update.capacity)
        if not configured then return false end
        armTimer()
        return true
    end)
    if capacityBinding == nil then
        uiApi = nil
        observeClientMetric('ui_rebind_failures')
        return false
    end
    engine.resetUiVisibility()
    local snapshot = uiCall('getSignalSnapshot')
    if snapshot == nil then
        uiApi = nil
        observeClientMetric('ui_rebind_failures')
        return false
    end
    engine.reconcile(snapshot)
    engine.confirmVisibility(snapshot)
    if isCallable(candidate.getPreferences) then
        local preferences = uiCall('getPreferences')
        if preferences ~= nil then engine.setUiPreferences(preferences) end
    end
    observeClientMetric('ui_rebind_successes')
    armTimer()
    scheduleVisibilitySync()
    return true
end

local function startUiRebind()
    if not runtimeActive then return end
    uiRetryGeneration = uiRetryGeneration + 1
    local generation = uiRetryGeneration
    uiRetryAttempt = 0
    local attempt
    attempt = function()
        if not runtimeActive or generation ~= uiRetryGeneration then return end
        uiRetryAttempt = uiRetryAttempt + 1
        if rebindUi() then return end
        local nextDelay = UI_RETRY_DELAYS_MS[uiRetryAttempt + 1]
            or UI_RETRY_STEADY_MS
        SetTimeout(nextDelay, attempt)
    end
    SetTimeout(UI_RETRY_DELAYS_MS[1], attempt)
end

local function ensureOwner(owner)
    local resource, resourceError = Validation.resourceName(owner)
    if not resource then return nil, resourceError end
    local record = owners[resource]
    if record == nil or record.state ~= 'started' then
        ownerEpochSerial = ownerEpochSerial + 1
        record = { epoch = ownerEpochSerial, state = 'started' }
        owners[resource] = record
    end
    return record.epoch
end

local function facadeGuard(owner, epoch)
    local record = owners[owner]
    if not runtimeActive or record == nil or record.state ~= 'started'
        or record.epoch ~= epoch then
        return Validation.failure('NOTIFY_OWNER_STALE',
            'The notification owner incarnation is stale.')
    end
    return true
end

local function decorateHandle(owner, epoch, value)
    local facade = {
        notificationId = value.notificationId,
        ownerResource = owner,
        ownerEpoch = epoch,
        revision = value.revision,
    }
    local function currentHandle()
        return {
            notificationId = facade.notificationId,
            ownerResource = facade.ownerResource,
            ownerEpoch = facade.ownerEpoch,
            revision = facade.revision,
        }
    end
    local function synchronize(result, operationError)
        if result == nil then return nil, operationError end
        if type(result) == 'table' and Validation.isInteger(result.revision, 1,
            Limits.maximumSafeInteger) then facade.revision = result.revision end
        armTimer()
        return facade, nil
    end
    facade.update = function(first, second)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local patchValue = first == facade and second or first
        local patch, patchError = Validation.notificationPatch(patchValue, {
            authority = 'CLIENT',
        })
        if not patch then return nil, patchError end
        return synchronize(engine.update(currentHandle(), patch))
    end
    facade.success = function(first, second)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local message = first == facade and second or first
        if message ~= nil and (type(message) ~= 'string'
            or #message > Limits.maximumMessageBytes) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The progress success message is invalid.')
        end
        return synchronize(engine.complete(currentHandle(), 'SUCCESS', message))
    end
    facade.fail = function(first, second)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local message = first == facade and second or first
        if message ~= nil and (type(message) ~= 'string'
            or #message > Limits.maximumMessageBytes) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The progress failure message is invalid.')
        end
        return synchronize(engine.complete(currentHandle(), 'FAILED', message))
    end
    facade.cancel = function(first, second)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local message = first == facade and second or first
        if message ~= nil and (type(message) ~= 'string'
            or #message > Limits.maximumMessageBytes) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The progress cancellation message is invalid.')
        end
        return synchronize(engine.complete(currentHandle(), 'CANCELLED', message))
    end
    facade.dismiss = function(first, second)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local reason = first == facade and second or first
        local result, dismissError = engine.dismiss(currentHandle(), reason)
        if not result then return nil, dismissError end
        facade.revision = facade.revision + 1
        armTimer()
        return result, nil
    end
    facade.onAction = function(first, second, third)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local actionId, callback
        if first == facade then actionId, callback = second, third
        else actionId, callback = first, second end
        return engine.onAction(currentHandle(), actionId, callback)
    end
    return facade
end

local function rememberCommand(commandId)
    if seenCommands[commandId] then return false end
    seenCommands[commandId] = true
    commandOrder[#commandOrder + 1] = commandId
    if #commandOrder > Limits.maximumRecentCommands then
        local expired = table.remove(commandOrder, 1)
        seenCommands[expired] = nil
    end
    return true
end

local function acceptTarget(target)
    local localSource = GetPlayerServerId(PlayerId())
    if target.source ~= localSource then return false end
    if sessionRef == nil then
        sessionRef = Validation.copy(target)
        return true
    end
    if target.sourceGeneration < sessionRef.sourceGeneration then return false end
    if target.sourceGeneration == sessionRef.sourceGeneration then
        return target.sessionId == sessionRef.sessionId and target.source == sessionRef.source
    end
    engine.resetServerSession()
    sessionRef = Validation.copy(target)
    seenCommands, commandOrder = {}, {}
    return true
end

exports('GetAPI', function(versionRange)
    local requested = versionRange == nil and '^1.0.0' or tostring(versionRange)
    if not SUPPORTED_API_RANGES[requested] then
        return Validation.failure('NOTIFY_PROTOCOL_UNSUPPORTED',
            'The requested Synex Notify API version is unsupported.')
    end
    local invoked, owner = pcall(GetInvokingResource)
    if not invoked or type(owner) ~= 'string' or owner == '' then
        return Validation.failure('NOTIFY_OWNER_INVALID',
            'External Notify API access requires an invoking resource.')
    end
    local epoch, ownerError = ensureOwner(owner)
    if not epoch then return nil, ownerError end
    local api = {
        version = Limits.apiVersion,
        ownerResource = owner,
        ownerEpoch = epoch,
        limits = Validation.copy(Limits),
    }
    api.show = function(request)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local validationStartedAt = monotonicNow()
        local canonical, requestError = Validation.canonicalNotification(request, {
            authority = 'CLIENT', ownerResource = owner, now = monotonicNow(),
        })
        observeValidation(validationStartedAt)
        if not canonical then return nil, requestError end
        local handle, showError = engine.show(owner, epoch, canonical)
        if not handle then return nil, showError end
        armTimer()
        return decorateHandle(owner, epoch, handle), nil
    end
    api.notify = api.show
    api.progress = function(request)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local validationStartedAt = monotonicNow()
        local canonical, requestError = Validation.canonicalNotification(request, {
            authority = 'CLIENT', ownerResource = owner, now = monotonicNow(),
            kind = 'progress',
        })
        observeValidation(validationStartedAt)
        if not canonical then return nil, requestError end
        if canonical.kind ~= 'progress' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The progress facade only creates progress notifications.')
        end
        local handle, showError = engine.show(owner, epoch, canonical)
        if not handle then return nil, showError end
        armTimer()
        return decorateHandle(owner, epoch, handle), nil
    end
    api.getHistory = function(limit)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        if limit ~= nil and not Validation.isInteger(limit, 1, Limits.maximumHistory) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification history limit is invalid.')
        end
        return engine.history(owner, limit), nil
    end
    api.setPresentationContext = function(request)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local context, contextError = engine.setPresentationContext(owner, epoch, request)
        if not context then return nil, contextError end
        armTimer()
        return context, nil
    end
    api.clearPresentationContext = function(contextId)
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local result, contextError = engine.clearPresentationContext(owner, epoch, contextId)
        if not result then return nil, contextError end
        armTimer()
        return result, nil
    end
    api.getPresentationSnapshot = function()
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        return engine.presentationSnapshot(), nil
    end
    api.getDiagnostics = function()
        local allowed, guardError = facadeGuard(owner, epoch)
        if not allowed then return nil, guardError end
        local diagnostics = engine.snapshot()
        diagnostics.metrics = Validation.copy(clientMetrics)
        local samples = clientMetrics.queue_promotions or 0
        diagnostics.queueWaitAverageMs = samples > 0
            and (clientMetrics.queue_wait_ms or 0) / samples or 0
        local validationSamples = clientMetrics.validation_samples or 0
        diagnostics.validationAverageMs = validationSamples > 0
            and (clientMetrics.validation_time_ms or 0) / validationSamples or 0
        local dispatchSamples = clientMetrics.render_dispatch_samples or 0
        diagnostics.renderDispatchAverageMs = dispatchSamples > 0
            and (clientMetrics.render_dispatch_time_ms or 0) / dispatchSamples or 0
        local ackSamples = clientMetrics.render_ack_samples or 0
        diagnostics.renderAckAverageMs = ackSamples > 0
            and (clientMetrics.render_ack_time_ms or 0) / ackSamples or 0
        diagnostics.ui = {
            bound = uiApi ~= nil,
            bindingGeneration = uiBindingGeneration,
            retryAttempt = uiRetryAttempt,
        }
        return diagnostics, nil
    end
    return api, nil
end)

exports('GetCompatibilityAPI', function(consumerValue, providerValue)
    local invoked, caller = pcall(GetInvokingResource)
    local provider = type(providerValue) == 'string' and providerValue or nil
    if not invoked or COMPATIBILITY_PROVIDERS[provider] ~= caller then
        return Validation.failure('NOTIFY_OWNER_INVALID',
            'Compatibility Notify access is restricted to a reviewed provider.')
    end
    local consumer, consumerError = Validation.resourceName(consumerValue)
    if not consumer then return nil, consumerError end
    if consumer == RESOURCE_NAME or consumer == caller or consumer == 'synex_core' then
        return Validation.failure('NOTIFY_OWNER_INVALID',
            'The compatibility notification consumer is invalid.')
    end
    local stateRead, state = pcall(GetResourceState, consumer)
    if not stateRead or state ~= 'started' and state ~= 'starting' then
        return Validation.failure('NOTIFY_OWNER_STOPPED',
            'The compatibility notification consumer is not active.')
    end
    local epoch, ownerError = ensureOwner(consumer)
    if not epoch then return nil, ownerError end
    local api = {
        version = Limits.apiVersion,
        ownerResource = consumer,
        ownerEpoch = epoch,
        provider = provider,
    }
    local function notify(first, second)
        local allowed, guardError = facadeGuard(consumer, epoch)
        if not allowed then return nil, guardError end
        local request = first == api and second or first
        local validationStartedAt = monotonicNow()
        local canonical, requestError = Validation.canonicalNotification(request, {
            authority = 'CLIENT', ownerResource = consumer, now = monotonicNow(),
        })
        observeValidation(validationStartedAt)
        if not canonical then return nil, requestError end
        if canonical.kind == 'banner' or canonical.priority == 'high'
            or canonical.priority == 'critical' or canonical.origin ~= 'LOCAL' then
            return Validation.failure('NOTIFY_PRIORITY_DENIED',
                'Compatibility notifications cannot request privileged presentation.')
        end
        local handle, showError = engine.show(consumer, epoch, canonical)
        if not handle then return nil, showError end
        armTimer()
        return decorateHandle(consumer, epoch, handle), nil
    end
    api.show = notify
    api.notify = notify
    api.Notify = notify
    return api, nil
end)

local function consumeWakePullBudget()
    local current = monotonicNow()
    local capacity = Limits.commandPullBudgetCapacity or 32
    local refill = Limits.commandPullBudgetRefillPerSecond or 16
    if wakePullUpdatedAt == nil then wakePullUpdatedAt = current end
    local elapsed = math.max(0, current - wakePullUpdatedAt)
    wakePullTokens = math.min(capacity, wakePullTokens + elapsed * refill / 1000)
    wakePullUpdatedAt = current
    if wakePullTokens < 1 then
        return false, math.max(1, math.ceil((1 - wakePullTokens) * 1000 / refill))
    end
    wakePullTokens = wakePullTokens - 1
    return true, 0
end

local function applyPulledCommand(envelope, expectedCommandId)
    if not Validation.exactObject(envelope, {
        schemaVersion = true, command = true, commandId = true,
        ownerResource = true, ownerEpoch = true, notificationId = true,
        revision = true, target = true, payload = true,
    }) or envelope.schemaVersion ~= Limits.schemaVersion
        or envelope.commandId ~= expectedCommandId
        or not Validation.identifier(envelope.commandId, 16, 96)
        or not Validation.isInteger(envelope.ownerEpoch, 1, Limits.maximumSafeInteger) then
        return false
    end
    local owner = Validation.resourceName(envelope.ownerResource)
    local target = Validation.targetRef(envelope.target)
    if not owner or not target then return false end
    local presentation = nil
    local commandHandle = Validation.handle({
        notificationId = envelope.notificationId,
        ownerResource = owner,
        ownerEpoch = envelope.ownerEpoch,
        revision = envelope.revision,
    })
    if envelope.command == 'show' or envelope.command == 'update' then
        local validationStartedAt = monotonicNow()
        local transportAuthority = type(envelope.payload) == 'table'
            and envelope.payload.origin or nil
        if transportAuthority == 'SERVER' or transportAuthority == 'SYSTEM' then
            presentation = Validation.canonicalPresentation(envelope.payload, {
                authority = transportAuthority, ownerResource = owner,
            })
        end
        observeValidation(validationStartedAt)
        if not commandHandle or not presentation
            or presentation.notificationId ~= envelope.notificationId
            or presentation.revision ~= envelope.revision then return false end
    elseif envelope.command == 'dismiss' then
        if not commandHandle
            or not Validation.exactObject(envelope.payload, { reason = true })
            or not Limits.dismissReasons[envelope.payload.reason] then return false end
    elseif envelope.command == 'owner_stop' then
        if not commandHandle or envelope.payload ~= nil then return false end
    else
        return false
    end
    if not acceptTarget(target) or not rememberCommand(envelope.commandId) then return false end
    if envelope.command == 'show' or envelope.command == 'update' then
        engine.applyServer(owner, envelope.ownerEpoch, presentation, envelope.command)
    elseif envelope.command == 'dismiss' then
        engine.dismissServer(owner, envelope.ownerEpoch, envelope.notificationId,
            envelope.revision, envelope.payload.reason)
    else
        engine.ownerStop(owner, envelope.ownerEpoch, 'SERVER')
    end
    armTimer()
    return true
end

local function processWakeQueue()
    if not runtimeActive or not wakeProcessing then return end
    if wakeCount <= 0 then
        wakeQueue, wakeHead, wakeTail = {}, 1, 0
        wakeProcessing = false
        return
    end
    local budgetAvailable, budgetDelay = consumeWakePullBudget()
    if not budgetAvailable then
        SetTimeout(budgetDelay, processWakeQueue)
        return
    end
    local entry = wakeQueue[wakeHead]
    local commandId = entry.commandId
    local accepted = false
    local invoked, command, pullError = pcall(function()
        return exports.synex_core:Call('synex.notify.command.pull', '1.0.0', {
            commandId = commandId,
        }, { timeoutMs = Limits.commandPullTimeoutMs or 3000 })
    end)
    if invoked and command ~= false and command ~= nil and pullError == nil then
        accepted = applyPulledCommand(command, commandId)
    elseif (not invoked or type(pullError) == 'table' and pullError.retryable == true)
        and entry.attempts + 1 < (Limits.maximumCommandPullAttempts or 3) then
        entry.attempts = entry.attempts + 1
        SetTimeout(Limits.commandPullRetryDelayMs or 250, processWakeQueue)
        return
    end
    wakeQueue[wakeHead] = nil
    wakeHead = wakeHead + 1
    wakeCount = wakeCount - 1
    queuedWakeIds[commandId] = nil
    if not accepted then observeClientMetric('server_command_rejected') end
    SetTimeout(0, processWakeQueue)
end

local function startMetricsReporting()
    metricsReportGeneration = metricsReportGeneration + 1
    local generation = metricsReportGeneration
    local baselineCounters = nil
    local baselineConfirmed = false
    local baselineRetryCount = 0
    local function report()
        if not runtimeActive or generation ~= metricsReportGeneration then return end
        metricsReportSequence = metricsReportSequence + 1
        if metricsClientEpoch == nil then
            metricsClientEpoch = math.max(1, math.floor(monotonicNow()))
        end
        local counters = {}
        for publicName, localName in pairs(CLIENT_REPORT_COUNTERS) do
            counters[publicName] = math.floor(math.min(
                Limits.metricsMaximumCounter or 1000000000000,
                math.max(0, tonumber(clientMetrics[localName]) or 0)))
        end
        if not baselineConfirmed then
            baselineCounters = baselineCounters or counters
            counters = baselineCounters
        end
        local snapshot = engine.snapshot()
        local delay = Limits.metricsReportIntervalMs or 10000
        local invoked, result = pcall(function()
            return exports.synex_core:Call('synex.notify.metrics.report', '1.0.0', {
                clientEpoch = metricsClientEpoch,
                sequence = metricsReportSequence,
                counters = counters,
                gauges = {
                    visible = snapshot.visible,
                    queued = snapshot.queued,
                    pendingVisibilityAcks = snapshot.pendingVisibilityAcks,
                },
            }, { timeoutMs = Limits.metricsReportTimeoutMs or 3000 })
        end)
        local accepted = invoked and type(result) == 'table' and result.accepted == true
        if accepted then
            if not baselineConfirmed then
                baselineConfirmed = true
                baselineCounters = nil
                baselineRetryCount = 0
            end
            if Validation.isInteger(result.nextReportAfterMs,
                Limits.metricsMinimumReportIntervalMs or 5000, 60000) then
                delay = result.nextReportAfterMs
            end
        elseif not baselineConfirmed then
            baselineRetryCount = baselineRetryCount + 1
            if baselineRetryCount <= (Limits.maximumMetricsBaselineRetries or 5) then
                delay = Limits.metricsBaselineRetryDelayMs or 1000
            end
        end
        SetTimeout(delay, report)
    end
    SetTimeout(Limits.metricsInitialReportDelayMs or 0, report)
end

RegisterNetEvent(EVENT_NAME, function(wake)
    if source ~= 65535 or not runtimeActive
        or not Validation.exactObject(wake, {
            schemaVersion = true, commandId = true,
        }) or wake.schemaVersion ~= Limits.schemaVersion
        or not Validation.identifier(wake.commandId, 16, 96)
        or seenCommands[wake.commandId] or queuedWakeIds[wake.commandId]
        or wakeCount >= (Limits.maximumPendingWakes or 64) then
        observeClientMetric('server_command_rejected')
        return
    end
    wakeTail = wakeTail + 1
    wakeQueue[wakeTail] = { commandId = wake.commandId, attempts = 0 }
    queuedWakeIds[wake.commandId] = true
    wakeCount = wakeCount + 1
    if wakeProcessing then return end
    wakeProcessing = true
    SetTimeout(0, processWakeQueue)
end)

for _, mapping in ipairs(ACTION_COMMANDS) do
    local index = mapping.index
    RegisterCommand(('synex-notify-action-%d'):format(index), function()
        if runtimeActive then
            uiCall('reportInputDevice', 'keyboard')
            local snapshot = uiCall('getSignalSnapshot')
            local confirmed = engine.confirmVisibility(snapshot)
            if confirmed then engine.invokeVisibleAction(index) end
            scheduleVisibilitySync()
            armTimer()
        end
    end, false)
    RegisterCommand(('synex-notify-action-%d-pad'):format(index), function()
        if runtimeActive then
            uiCall('reportInputDevice', 'gamepad')
            local snapshot = uiCall('getSignalSnapshot')
            local confirmed = engine.confirmVisibility(snapshot)
            if confirmed then engine.invokeVisibleAction(index) end
            scheduleVisibilitySync()
            armTimer()
        end
    end, false)
    RegisterKeyMapping(('synex-notify-action-%d'):format(index),
        ('Synex notification action %d'):format(index), 'keyboard', mapping.keyboard)
    RegisterKeyMapping(('synex-notify-action-%d-pad'):format(index),
        ('Synex notification action %d (gamepad)'):format(index),
        'pad_digitalbutton', mapping.gamepad)
end

RegisterCommand('synex-notify-sound', function(_, arguments)
    local requested = type(arguments) == 'table' and arguments[1] or nil
    local current = engine.snapshot().soundEnabled
    if requested == 'on' then engine.setSoundEnabled(true)
    elseif requested == 'off' then engine.setSoundEnabled(false)
    elseif requested == nil or requested == 'toggle' then engine.setSoundEnabled(not current) end
    if requested == 'volume' then
        engine.setPresentationPreferences({ soundVolume = tonumber(arguments[2]) })
    elseif requested == 'critical-only' then
        local currentPreference = engine.presentationSnapshot().preferences
            .muteNonCriticalSounds
        local mode = arguments[2]
        if mode == 'on' then currentPreference = true
        elseif mode == 'off' then currentPreference = false
        elseif mode == nil or mode == 'toggle' then currentPreference = not currentPreference
        elseif mode ~= nil and mode ~= 'toggle' then return end
        engine.setPresentationPreferences({
            muteNonCriticalSounds = not not currentPreference,
        })
    end
end, false)

RegisterCommand('synex-notify-position', function(_, arguments)
    if type(arguments) ~= 'table' or type(arguments[1]) ~= 'string' then return end
    engine.setPresentationPreferences({ position = arguments[1] })
end, false)

RegisterCommand('synex-notify-duration-scale', function(_, arguments)
    if type(arguments) ~= 'table' then return end
    engine.setPresentationPreferences({ durationScale = tonumber(arguments[1]) })
end, false)

RegisterCommand('synex-notify-history', function(_, arguments)
    local mode = type(arguments) == 'table' and arguments[1] or nil
    local current = engine.presentationSnapshot().preferences.history
    if mode == 'on' then current = true
    elseif mode == 'off' then current = false
    elseif mode == nil or mode == 'toggle' then current = not current
    elseif mode ~= nil and mode ~= 'toggle' then return end
    engine.setPresentationPreferences({ history = not not current })
end, false)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'synex_ui' then
        startUiRebind()
        return
    end
    if resource == RESOURCE_NAME then return end
    local valid = Validation.resourceName(resource)
    if not valid then return end
    local record = owners[resource]
    if record and record.state == 'started' then return end
    ownerEpochSerial = ownerEpochSerial + 1
    owners[resource] = { epoch = ownerEpochSerial, state = 'started' }
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == RESOURCE_NAME then
        runtimeActive = false
        timerGeneration = timerGeneration + 1
        timerArmed, timerDeadline = false, nil
        wakeQueue, queuedWakeIds = {}, {}
        wakeHead, wakeTail, wakeCount, wakeProcessing = 1, 0, 0, false
        uiRetryGeneration = uiRetryGeneration + 1
        visibilitySyncGeneration = visibilitySyncGeneration + 1
        metricsReportGeneration = metricsReportGeneration + 1
        engine.shutdown()
        uiApi = nil
        return
    end
    if resource == 'synex_ui' then
        engine.resetUiVisibility()
        armTimer()
        uiApi = nil
        uiBindingGeneration = uiBindingGeneration + 1
        uiRetryGeneration = uiRetryGeneration + 1
        visibilitySyncGeneration = visibilitySyncGeneration + 1
        return
    end
    local record = owners[resource]
    if record then
        engine.ownerStop(resource, record.epoch, 'LOCAL')
        record.state = 'stopped'
        armTimer()
    end
end)

startUiRebind()
startMetricsReporting()
