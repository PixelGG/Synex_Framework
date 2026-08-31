local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded before client runtime')
local SensorFactory = assert(SynexInteractSensor,
    'interact sensor must be loaded before client runtime')
local IntentFactory = assert(SynexInteractIntent,
    'interact intent engine must be loaded before client runtime')
local Cancellation = assert(SynexInteractCancellation,
    'interact cancellation policy must be loaded before client runtime')
local TraceFactory = assert(SynexInteractClientTrace,
    'interact client diagnostics must be loaded before client runtime')

local RESOURCE_NAME = GetCurrentResourceName()
local GRAPH_EVENT = 'synex_interact:client:graph'
local API_RANGES = {
    ['1'] = true, ['1.0'] = true, ['1.0.0'] = true, ['v1'] = true,
    ['^1.0.0'] = true,
}
local INTERACTION_ID = 'synex_interact:primary'
local UI_RETRY_DELAYS_MS = { 0, 50, 150, 400, 1000, 2000, 4000 }
local UI_RETRY_STEADY_MS = 5000
local UI_PREFERENCE_INTERVAL_MS = 1000
local INPUT_HINT_INTERVAL_MS = 1000
local DISCOVERY_INTERVAL_MS = 4000
local DISCOVERY_RETRY_MS = 1000
local DISCOVERY_TRANSFER_TIMEOUT_MS = 10000
local ENTITY_DISCOVERY_RETRY_MS = 1000
local CONTRACT_TIMEOUT_MS = 3000
local PRESENTATION_TYPES = {
    faceTarget = true, moveToSlot = true, animation = true, scenario = true,
    progress = true, sound = true, interactionCue = true, stopAnimation = true,
}
local SAFE_UI_ICONS = {
    check = true, close = true, ['chevron-down'] = true,
    ['chevron-right'] = true, ['arrow-left'] = true, ['arrow-right'] = true,
    search = true, plus = true, minus = true, more = true, copy = true,
    eye = true, ['eye-off'] = true, info = true, warning = true,
    error = true, success = true, menu = true, command = true, signal = true,
}
local BLOOM_INPUT_HINTS = {
    primary = { keyboard = 'Enter', gamepad = 'Confirm', mouse = 'Left click' },
    cancel = { keyboard = 'Esc', gamepad = 'Back', mouse = 'Right click' },
}
local INPUT_MAPPINGS = {
    { action = 'primary', keyboard = 'E', gamepad = 'RDOWN_INDEX',
        mouse = 'MOUSE_LEFT' },
    { action = 'more', keyboard = 'G', gamepad = 'LRIGHT_INDEX' },
    { action = 'cancel', keyboard = 'X', gamepad = 'RRIGHT_INDEX',
        mouse = 'MOUSE_RIGHT' },
}
local INPUT_FALLBACKS = {
    primary = { keyboard = 'Primary', gamepad = 'Primary', mouse = 'Primary' },
    more = { keyboard = 'More', gamepad = 'More' },
    cancel = { keyboard = 'Cancel', gamepad = 'Cancel', mouse = 'Cancel' },
}
local INSTRUCTIONAL_ALIASES = {
    RETURN = 'Enter', ESC = 'Esc', ESCAPE = 'Esc', SPACE = 'Space',
    LCONTROL = 'Left Ctrl', RCONTROL = 'Right Ctrl',
    LSHIFT = 'Left Shift', RSHIFT = 'Right Shift',
    LMENU = 'Left Alt', RMENU = 'Right Alt',
}

local runtimeActive = true
local previousRawTimer, monotonicElapsed = nil, 0
local uiApi, uiBindingGeneration, uiRetryGeneration = nil, 0, 0
local uiRevision, uiFingerprint, uiVisible, bloomOpen = 0, nil, false, false
local uiPreferenceReadAt = -UI_PREFERENCE_INTERVAL_MS
local inputHintReadAt, inputHintRevision = -INPUT_HINT_INTERVAL_MS, 0
local inputHints = Validation.copy(INPUT_FALLBACKS)
local uiPreferences = {
    interactionAssist = false, reducedMotion = false, highContrast = false,
}
local discoveryBusy, discoveryGeneration = false, 0
local entityDiscoveryBusy, entityDiscoveryGeneration = false, 0
local actionGeneration, actionInFlight = 0, false
local activeLease, activeSession = nil, nil
local graphSequences, graphCommands, graphGeneration = {}, {}, 0
local ownedAnimation, ownedScenario, ownedTask = nil, nil, nil
local lastContext, lastPrimary, lastAlternatives = nil, nil, {}
local inputDevice = 'keyboard'
local owners, ownerEpochSerial = {}, 0
local metricSequence, metricGeneration = 0, 0
local clientEpoch = nil
local clientCounters = {
    sensorTicks = 0, candidatesSeen = 0, expensiveChecks = 0,
    intentChanges = 0, promptsShown = 0, bloomOpened = 0,
    leaseRequests = 0, transportFailures = 0, providerTimeouts = 0,
}
local clientGauges = {
    candidateCount = 0, sensorIntervalMs = Limits.sensorIdleIntervalMs,
    expensiveCandidateCount = 0, sensorDurationMs = 0,
    providerDurationMs = 0, intentScoringDurationMs = 0,
}
local localDurations = {
    sensorDurationMs = 0, sensorDurationSamples = 0,
    providerDurationMs = 0, providerDurationSamples = 0,
    intentScoringDurationMs = 0, intentScoringDurationSamples = 0,
}
local traceFingerprints = {}

local function monotonicNow()
    local ok, raw = pcall(GetGameTimer)
    if not ok or type(raw) ~= 'number' then return monotonicElapsed end
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

local function callable(value)
    return Validation.isCallable(value)
end

local function inputCommand(action, device)
    local suffix = device == 'gamepad' and '-pad'
        or device == 'mouse' and '-mouse' or ''
    return 'synex-interact-' .. action .. suffix
end

local function instructionalLabel(command, fallback)
    if not callable(GetHashKey) or not callable(GetControlInstructionalButton) then
        return fallback
    end
    local hashed, control = pcall(GetHashKey, command)
    if not hashed or type(control) ~= 'number' then return fallback end
    control = math.floor(control) | 0x80000000
    if control > 2147483647 then control = control - 4294967296 end
    local resolved, token = pcall(GetControlInstructionalButton, 2, control, true)
    if not resolved or type(token) ~= 'string' then return fallback end
    local value = token:match('^[tT]_(.+)$')
    if not value or #value < 1 or #value > 24
        or value:find('[^%w_ %+%-%.]') then return fallback end
    value = INSTRUCTIONAL_ALIASES[value:upper()] or value:gsub('_', ' ')
    return #value <= 24 and value or fallback
end

local function refreshInputHints(force)
    local timestamp = monotonicNow()
    if not force and timestamp - inputHintReadAt < INPUT_HINT_INTERVAL_MS then return false end
    inputHintReadAt = timestamp
    local nextHints = {}
    for _, mapping in ipairs(INPUT_MAPPINGS) do
        local action, fallback = mapping.action, INPUT_FALLBACKS[mapping.action]
        nextHints[action] = {
            keyboard = instructionalLabel(inputCommand(action, 'keyboard'), fallback.keyboard),
            gamepad = instructionalLabel(inputCommand(action, 'gamepad'), fallback.gamepad),
        }
        if mapping.mouse then
            nextHints[action].mouse = instructionalLabel(
                inputCommand(action, 'mouse'), fallback.mouse)
        end
    end
    local changed = false
    for action, hint in pairs(nextHints) do
        local previous = inputHints[action] or {}
        if previous.keyboard ~= hint.keyboard or previous.gamepad ~= hint.gamepad
            or previous.mouse ~= hint.mouse then changed = true; break end
    end
    if changed then
        inputHints = nextHints
        inputHintRevision = math.min(Limits.maximumSafeInteger, inputHintRevision + 1)
    end
    return changed
end

local function clientError(code, message, retryable)
    local _, value = Validation.failure(code, message, retryable)
    return value
end

local function incrementCounter(name, amount)
    if clientCounters[name] == nil then return end
    local delta = math.max(0, math.floor(tonumber(amount) or 1))
    clientCounters[name] = math.min(1000000000000, clientCounters[name] + delta)
end

local function observe(name, value)
    if name == 'intentChanges' then incrementCounter('intentChanges', value); return end
    if name == 'providerTimeouts' then incrementCounter('providerTimeouts', value); return end
    local sampleKey = name:gsub('Ms$', 'Samples')
    if localDurations[name] ~= nil and localDurations[sampleKey] ~= nil then
        localDurations[name] = localDurations[name] + math.max(0, tonumber(value) or 0)
        localDurations[sampleKey] = localDurations[sampleKey] + 1
    end
end

local function durationAverage(totalKey, sampleKey)
    local samples = localDurations[sampleKey] or 0
    if samples <= 0 then return 0 end
    return math.min(60000, math.max(0,
        (localDurations[totalKey] or 0) / samples))
end

local function coreCall(name, payload, options)
    if not runtimeActive then return nil, clientError('INTERACT_RESOURCE_STOPPED',
        'The interaction client runtime has stopped.') end
    local invoked, value, operationError = pcall(function()
        return exports.synex_core:Call(name, '1.0.0', payload, options or {
            timeoutMs = CONTRACT_TIMEOUT_MS,
        })
    end)
    if not invoked or value == false or value == nil or operationError ~= nil then
        incrementCounter('transportFailures')
        return nil, type(operationError) == 'table' and operationError or clientError(
            'INTERACT_UNAVAILABLE', 'The Synex client transport is unavailable.', true)
    end
    return value, nil
end

local function uiCall(method, ...)
    local handler = type(uiApi) == 'table' and uiApi[method] or nil
    if not callable(handler) then return nil, clientError('UI_INTERACTION_DENIED',
        'The Synex UI interaction transport is unavailable.', true) end
    local invoked, value, operationError = pcall(handler, ...)
    if not invoked or value == false or value == nil or operationError ~= nil then
        incrementCounter('transportFailures')
        return nil, type(operationError) == 'table' and operationError or clientError(
            'UI_INTERACTION_DENIED', 'The Synex UI rejected the interaction update.', true)
    end
    return value, nil
end

local function worldContext()
    local invoked, value = pcall(function() return exports.synex_world:GetContext() end)
    return invoked and type(value) == 'table' and value or {}
end

local function nearbyWorldAnchors(options)
    local invoked, value = pcall(function()
        return exports.synex_world:NearbyAnchors(options)
    end)
    return invoked and type(value) == 'table' and value or {}
end

local function nearbyWorldObjects(kind, options)
    local invoked, value = pcall(function()
        return exports.synex_world:NearbyObjects(kind, options)
    end)
    return invoked and type(value) == 'table' and value or nil
end

local ports = {
    playerPed = function() return PlayerPedId() end,
    entityExists = function(entity) return DoesEntityExist(entity) end,
    entityCoords = function(entity) return GetEntityCoords(entity) end,
    entityVelocity = function(entity) return GetEntityVelocity(entity) end,
    entityHeading = function(entity) return GetEntityHeading(entity) end,
    entityHealth = function(entity) return GetEntityHealth(entity) end,
    vehicleForPed = function(ped) return GetVehiclePedIsIn(ped, false) end,
    pedDead = function(ped) return IsPedDeadOrDying(ped, true) end,
    pedRagdoll = function(ped) return IsPedRagdoll(ped) end,
    pedArmed = function(ped) return IsPedArmed(ped, 7) end,
    cameraPosition = function()
        if callable(GetFinalRenderedCamCoord) then return GetFinalRenderedCamCoord() end
        return GetGameplayCamCoord()
    end,
    cameraRotation = function(order)
        if callable(GetFinalRenderedCamRot) then return GetFinalRenderedCamRot(order) end
        return GetGameplayCamRot(order)
    end,
    startLosProbe = function(...)
        return StartShapeTestLosProbe(...)
    end,
    shapeTestResult = function(handle) return GetShapeTestResult(handle) end,
    entityModel = function(entity) return GetEntityModel(entity) end,
    networkId = function(entity)
        if not NetworkGetEntityIsNetworked(entity) then return 0 end
        return NetworkGetNetworkIdFromEntity(entity)
    end,
    entityFromNetworkId = function(netId)
        return NetworkGetEntityFromNetworkId(netId)
    end,
    boneIndex = function(entity, name) return GetEntityBoneIndexByName(entity, name) end,
    bonePosition = function(entity, index)
        return GetWorldPositionOfEntityBone(entity, index)
    end,
}

local sensor = SensorFactory.create({
    now = monotonicNow,
    spawn = CreateThread,
    ports = ports,
    world = { getContext = worldContext, nearbyAnchors = nearbyWorldAnchors,
        nearbyObjects = nearbyWorldObjects },
    observe = observe,
})
local intentEngine = IntentFactory.create({
    now = monotonicNow,
    spawn = CreateThread,
    observe = observe,
})
local traceEnabled = false
if callable(GetConvarInt) then
    local invoked, value = pcall(GetConvarInt, 'synex_interact_trace', 0)
    traceEnabled = invoked and value == 1
end
local clientTrace = TraceFactory.create({ now = monotonicNow, enabled = traceEnabled })

local function recordTrace(phase, data)
    clientTrace.record(phase, data)
end

local function recordTraceChanged(channel, phase, data, fingerprint)
    if traceFingerprints[channel] == fingerprint then return end
    traceFingerprints[channel] = fingerprint
    recordTrace(phase, data)
end

local function traceFailureCode(value)
    local code = type(value) == 'table' and value.code or value
    if type(code) ~= 'string' then return nil end
    code = code:sub(1, 64)
    if code:match('^[A-Z][A-Z0-9_]*$') == nil then return 'INTERACT_ERROR' end
    return code
end

local function traceBucket(value, precision)
    local number = tonumber(value)
    if not Validation.isFinite(number) then return 0 end
    local multiplier = math.max(1, math.floor(tonumber(precision) or 1))
    return math.floor(number * multiplier + 0.5) / multiplier
end

local function applyUiPreferences(value)
    uiPreferences = {
        interactionAssist = value and value.interactionAssist == true or false,
        reducedMotion = value and value.reducedMotion == true or false,
        highContrast = value and value.highContrast == true or false,
    }
    sensor.setInteractionAssist(uiPreferences.interactionAssist)
    intentEngine.setInteractionAssist(uiPreferences.interactionAssist)
end

local function normalizedUiPreferences(value)
    if not Validation.exactObject(value, {
        'schemaVersion', 'quality', 'scale', 'density', 'reducedMotion',
        'reducedTransparency', 'highContrast', 'interactionAssist',
    }) or value.schemaVersion ~= 1
        or ({ LOW = true, BALANCED = true, HIGH = true, ULTRA = true })[
            value.quality] ~= true
        or ({ [85] = true, [100] = true, [115] = true, [125] = true })[
            value.scale] ~= true
        or (value.density ~= 'compact' and value.density ~= 'comfortable')
        or type(value.reducedMotion) ~= 'boolean'
        or type(value.reducedTransparency) ~= 'boolean'
        or type(value.highContrast) ~= 'boolean'
        or type(value.interactionAssist) ~= 'boolean' then return nil end
    return {
        interactionAssist = value.interactionAssist,
        reducedMotion = value.reducedMotion,
        highContrast = value.highContrast,
    }
end

local function refreshUiPreferences(force)
    local timestamp = monotonicNow()
    if not force and timestamp - uiPreferenceReadAt < UI_PREFERENCE_INTERVAL_MS then
        return true
    end
    uiPreferenceReadAt = timestamp
    if uiApi == nil then applyUiPreferences(nil); return false end
    local value = uiCall('getPreferences')
    local normalized = normalizedUiPreferences(value)
    if not normalized then applyUiPreferences(nil); return false end
    applyUiPreferences(normalized)
    return true
end

local function boundedText(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= maximum
        and value:find('[%z\1-\8\11\12\14-\31\127]') == nil
end

local function nextUiRevision()
    if uiRevision >= Limits.maximumSafeInteger then return nil end
    uiRevision = uiRevision + 1
    return uiRevision
end

local function removeInteraction()
    uiFingerprint, bloomOpen = nil, false
    if not uiVisible then return true end
    local revision = nextUiRevision()
    if not revision then return false end
    local removed = uiCall('removeInteraction', INTERACTION_ID, revision)
    if removed ~= nil then uiVisible = false; return true end
    return false
end

local function uiIntent(value)
    local projected = { intentId = value.key, label = value.label }
    if SAFE_UI_ICONS[value.icon] then projected.iconKey = value.icon end
    local description = value.verb ~= value.label and value.verb or nil
    if boundedText(description, 180) then projected.description = description end
    return projected
end

local function uniqueVisibleIntents(primary, alternatives)
    local values, seen = { uiIntent(primary) }, { [primary.key] = true }
    for _, alternative in ipairs(alternatives or {}) do
        if not seen[alternative.key] then
            seen[alternative.key] = true
            values[#values + 1] = uiIntent(alternative)
            if #values >= Limits.maximumVisibleIntents then break end
        end
    end
    return values
end

local function targetLabel(primary)
    local presentation = primary and primary.objectPresentation
    local value = type(presentation) == 'table'
        and (presentation.targetLabel or presentation.label) or nil
    return boundedText(value, 80) and value or nil
end

local function targetProjection(primary)
    local position = primary and Validation.vector3(primary.position)
    local camera = type(lastContext) == 'table' and lastContext.camera or nil
    local cameraPosition = type(camera) == 'table'
        and Validation.vector3(camera.position) or nil
    local cameraDirection = type(camera) == 'table'
        and Validation.vector3(camera.direction) or nil
    if not position or not cameraPosition or not cameraDirection
        or not callable(GetScreenCoordFromWorldCoord) then return nil end
    local relative = {
        x = position.x - cameraPosition.x,
        y = position.y - cameraPosition.y,
        z = position.z - cameraPosition.z,
    }
    local behindCamera = relative.x * cameraDirection.x
        + relative.y * cameraDirection.y + relative.z * cameraDirection.z <= 0
    local ok, visible, screenX, screenY = pcall(GetScreenCoordFromWorldCoord,
        position.x, position.y, position.z)
    if not ok then return nil end
    screenX = Validation.isFinite(screenX) and math.max(0, math.min(1, screenX)) or 0.5
    screenY = Validation.isFinite(screenY) and math.max(0, math.min(1, screenY)) or 0.62
    -- Quantization avoids sending a new NUI descriptor for sub-pixel camera jitter.
    screenX = math.floor(screenX * 400 + 0.5) / 400
    screenY = math.floor(screenY * 400 + 0.5) / 400
    return { visible = visible == true and not behindCamera,
        behindCamera = behindCamera, x = screenX, y = screenY }
end

local function syncCue(primary, alternatives, force)
    lastPrimary, lastAlternatives = primary, alternatives or {}
    if activeSession ~= nil or activeLease ~= nil or actionInFlight then return end
    if uiApi == nil then return end
    if primary == nil then removeInteraction(); return end
    refreshInputHints(false)
    local intents = uniqueVisibleIntents(primary, alternatives)
    local mode = bloomOpen and #intents >= 2 and 'bloom' or 'cue'
    if mode == 'cue' then bloomOpen = false end
    local projection = targetProjection(primary)
    local parts = { mode, primary.key, tostring(primary.revision),
        primary.candidateId, inputDevice, tostring(inputHintRevision) }
    if projection then
        parts[#parts + 1] = projection.visible and 'visible' or 'hidden'
        parts[#parts + 1] = tostring(projection.x)
        parts[#parts + 1] = tostring(projection.y)
    end
    for _, item in ipairs(intents) do parts[#parts + 1] = item.intentId end
    local fingerprint = table.concat(parts, '|')
    if not force and fingerprint == uiFingerprint then return end
    local revision = nextUiRevision()
    if not revision then return end
    local request = {
        interactionId = INTERACTION_ID,
        revision = revision,
        mode = mode,
        label = mode == 'bloom' and 'Available actions' or primary.label,
        targetLabel = targetLabel(primary),
        projection = projection,
        intents = mode == 'cue' and { intents[1] } or intents,
        selectedIntentId = primary.key,
        pointer = mode == 'bloom',
        input = mode == 'bloom'
            and Validation.copy(BLOOM_INPUT_HINTS)
            or { primary = Validation.copy(inputHints.primary),
                more = #intents > 1 and Validation.copy(inputHints.more) or nil },
        cancellable = mode == 'bloom',
    }
    if mode == 'cue' and #intents > 1 then request.moreCount = #intents - 1 end
    local result = uiCall('upsertInteraction', request)
    if result ~= nil then
        if not uiVisible then incrementCounter('promptsShown') end
        uiVisible, uiFingerprint = true, fingerprint
    end
end

local function showProgress(label, progress, cancellable, fingerprint)
    if uiApi == nil then return false end
    refreshInputHints(false)
    local revision = nextUiRevision()
    if not revision then return false end
    local request = {
        interactionId = INTERACTION_ID,
        revision = revision,
        mode = 'progress',
        label = boundedText(label, 120) and label or 'Interaction in progress',
        intents = {}, pointer = false,
        input = cancellable and { cancel = Validation.copy(inputHints.cancel) } or {},
        progress = progress or { mode = 'indeterminate' },
        cancellable = cancellable == true,
    }
    local result = uiCall('upsertInteraction', request)
    if result == nil then return false end
    uiVisible, uiFingerprint = true, fingerprint or ('progress|' .. revision)
    return true
end

local function cleanupOwnedPresentation()
    if ownedAnimation ~= nil then
        pcall(StopAnimTask, ownedAnimation.ped, ownedAnimation.dictionary,
            ownedAnimation.name, 2.0)
        if callable(RemoveAnimDict) then pcall(RemoveAnimDict, ownedAnimation.dictionary) end
        ownedAnimation = nil
    end
    if ownedScenario ~= nil then
        pcall(ClearPedTasks, ownedScenario.ped)
        ownedScenario = nil
    end
    if ownedTask ~= nil then
        pcall(ClearPedTasks, ownedTask.ped)
        ownedTask = nil
    end
end

local function bestEffortCancel(sessionId, reason)
    if not Validation.token(sessionId, 8, 96) then return end
    pcall(function()
        exports.synex_core:Call('synex.interact.session.cancel', '1.0.0', {
            sessionId = sessionId,
            reason = reason,
        }, { timeoutMs = CONTRACT_TIMEOUT_MS })
    end)
end

local function clearInteractionState(reason, cancelServer)
    recordTrace('cancel', {
        reason = traceFailureCode(reason) or 'INTERACT_CANCELLED',
        activeSession = activeSession ~= nil, activeLease = activeLease ~= nil,
        inFlight = actionInFlight,
    })
    actionGeneration = actionGeneration + 1
    actionInFlight = false
    local sessionId = activeSession and activeSession.sessionId
        or activeLease and activeLease.sessionId
    activeLease, activeSession = nil, nil
    graphGeneration = graphGeneration + 1
    graphSequences, graphCommands = {}, {}
    cleanupOwnedPresentation()
    if cancelServer and sessionId then
        CreateThread(function() bestEffortCancel(sessionId, reason or 'USER_CANCELLED') end)
    end
    removeInteraction()
end

local function validLease(value)
    return type(value) == 'table' and Validation.token(value.leaseId, 8, 96)
        and Validation.token(value.nonce, 8, 96)
        and Validation.token(value.sessionId, 8, 96)
        and (value.state == 'ISSUED' or value.state == 'WAITING')
end

local function observedActor(context)
    local actor = type(context) == 'table' and Validation.copy(context.actor) or nil
    if not actor then return nil end
    local invoked, health = pcall(ports.entityHealth, actor.ped)
    if invoked and Validation.isFinite(health) then actor.health = health end
    return actor
end

local function beginIntent(selected)
    if not runtimeActive or actionInFlight or activeLease or activeSession
        or type(selected) ~= 'table' or not Validation.identifier(selected.key)
        or not Validation.isInteger(selected.revision, 1)
        or not Validation.isInteger(selected.objectRevision, 1)
        or not Validation.text(selected.candidateId, 3, 512) then return false end
    local discoveryRevision = sensor.snapshot().revision
    if discoveryRevision < 1 then return false end
    actionGeneration = actionGeneration + 1
    local generation = actionGeneration
    actionInFlight = true
    incrementCounter('leaseRequests')
    bloomOpen = false
    showProgress('Requesting interaction', { mode = 'indeterminate' }, true,
        'lease|' .. selected.key)
    local request = {
        intent = { key = selected.key, revision = selected.revision },
        target = Validation.copy(selected.target),
        clientRevision = discoveryRevision,
    }
    if selected.slotKey ~= nil then request.slotKey = selected.slotKey end
    recordTrace('lease_request', {
        stage = 'request', intentKey = selected.key,
        objectKey = selected.objectKey, slotKey = selected.slotKey,
    })
    local lease, leaseError = coreCall('synex.interact.lease.request', request,
        { timeoutMs = Limits.leaseRequestTtlMs })
    recordTrace('lease_result', {
        stage = 'request', outcome = validLease(lease) and 'granted' or 'denied',
        state = type(lease) == 'table' and lease.state or nil,
        code = traceFailureCode(leaseError)
            or (validLease(lease) and nil or 'INTERACT_LEASE_INVALID'),
    })
    if not runtimeActive or generation ~= actionGeneration then
        if validLease(lease) then bestEffortCancel(lease.sessionId, 'TARGET_STATE_CHANGED') end
        return false
    end
    if not validLease(lease) or sensor.snapshot().revision ~= discoveryRevision then
        if validLease(lease) then bestEffortCancel(lease.sessionId, 'TARGET_STATE_CHANGED') end
        actionInFlight = false
        uiFingerprint = nil
        syncCue(lastPrimary, lastAlternatives, true)
        return false
    end
    activeLease = {
        leaseId = lease.leaseId, nonce = lease.nonce, sessionId = lease.sessionId,
        state = lease.state, intent = Validation.copy(selected),
        discoveryRevision = discoveryRevision, acquiredAt = monotonicNow(),
        lastValidAt = monotonicNow(),
        worldInstance = lastContext and Validation.copy(lastContext.worldInstance) or nil,
    }
    recordTrace('lease_request', {
        stage = 'activation', intentKey = selected.key,
        objectKey = selected.objectKey, slotKey = selected.slotKey,
    })
    local activated, activationError = coreCall('synex.interact.lease.activate', {
        leaseId = lease.leaseId, nonce = lease.nonce,
    }, { timeoutMs = Limits.leaseActivationTtlMs })
    local activationAccepted = type(activated) == 'table'
        and activated.accepted == true
    recordTrace('lease_result', {
        stage = 'activation', outcome = activationAccepted and 'accepted' or 'denied',
        state = type(activated) == 'table' and activated.state or nil,
        code = traceFailureCode(activationError)
            or (activationAccepted and nil or 'INTERACT_ACTIVATION_INVALID'),
    })
    if not runtimeActive or generation ~= actionGeneration then
        bestEffortCancel(lease.sessionId, 'USER_CANCELLED')
        return false
    end
    if type(activated) ~= 'table' or activated.accepted ~= true
        or activated.leaseId ~= lease.leaseId or activated.sessionId ~= lease.sessionId
        or (activated.state ~= 'READY' and activated.state ~= 'RUNNING'
            and activated.state ~= 'WAITING') then
        activeLease, actionInFlight = nil, false
        bestEffortCancel(lease.sessionId, 'TARGET_STATE_CHANGED')
        uiFingerprint = nil
        syncCue(lastPrimary, lastAlternatives, true)
        return false
    end
    local timestamp = monotonicNow()
    local cancellation = Cancellation.create(selected.cancelPolicy, {
        actor = observedActor(lastContext) or {},
        targetPosition = Validation.copy(selected.position),
        worldInstance = lastContext and Validation.copy(lastContext.worldInstance) or nil,
    }, timestamp)
    if not cancellation then
        activeLease, actionInFlight = nil, false
        bestEffortCancel(lease.sessionId, 'TARGET_STATE_CHANGED')
        uiFingerprint = nil
        syncCue(lastPrimary, lastAlternatives, true)
        return false
    end
    activeSession = {
        sessionId = lease.sessionId, leaseId = lease.leaseId,
        intent = Validation.copy(selected), state = activated.state,
        startedAt = timestamp, cancellation = cancellation,
    }
    activeLease, actionInFlight = nil, false
    showProgress(selected.label, { mode = 'indeterminate' }, true,
        'session|' .. lease.sessionId)
    return true
end

local function requestCancel(reason)
    if activeSession == nil and activeLease == nil and not actionInFlight then
        if bloomOpen then bloomOpen = false; uiFingerprint = nil
            syncCue(lastPrimary, lastAlternatives, true) end
        return
    end
    clearInteractionState(reason or 'USER_CANCELLED', true)
end

local function handleInput(action, device, selectedIntent, fromUi)
    if not runtimeActive then return end
    inputDevice = device == 'gamepad' and 'gamepad'
        or device == 'mouse' and 'mouse' or 'keyboard'
    recordTrace('input', {
        action = action, device = inputDevice,
        selectedIntentKey = type(selectedIntent) == 'table' and selectedIntent.key
            or lastPrimary and lastPrimary.key or nil,
    })
    sensor.setInteractionState(lastPrimary and lastPrimary.target,
        lastPrimary and lastPrimary.key, inputDevice,
        uiPreferences.interactionAssist)
    if inputDevice == 'mouse' and bloomOpen and fromUi ~= true
        and (action == 'primary' or action == 'cancel') then return end
    if action == 'cancel' then requestCancel('USER_CANCELLED'); return end
    if activeSession or activeLease or actionInFlight then return end
    if action == 'more' then
        if lastPrimary and #lastAlternatives > 0 then
            bloomOpen = not bloomOpen
            if bloomOpen then incrementCounter('bloomOpened') end
            uiFingerprint = nil
            syncCue(lastPrimary, lastAlternatives, true)
        end
        return
    end
    local selected = selectedIntent or lastPrimary
    if action == 'primary' and selected then
        CreateThread(function() beginIntent(selected) end)
    end
end

local function bindUi()
    if not runtimeActive then return false end
    uiBindingGeneration = uiBindingGeneration + 1
    local invoked, candidate, bindError = pcall(function()
        return exports.synex_ui:GetAPI('^1.0.0')
    end)
    if not invoked or type(candidate) ~= 'table' or bindError ~= nil
        or candidate.ownerResource ~= RESOURCE_NAME
        or not Validation.isInteger(candidate.ownerEpoch, 1)
        or not callable(candidate.upsertInteraction)
        or not callable(candidate.removeInteraction)
        or not callable(candidate.getInteractionSnapshot)
        or not callable(candidate.bindInteractionActions)
        or not callable(candidate.getPreferences) then uiApi = nil; return false end
    local bindingGeneration = uiBindingGeneration
    uiApi = candidate
    if not refreshUiPreferences(true) then uiApi = nil; return false end
    local bound = uiCall('bindInteractionActions', function(event)
        if not runtimeActive or bindingGeneration ~= uiBindingGeneration
            or uiApi ~= candidate
            or not Validation.exactObject(event,
                { 'interactionId', 'revision', 'action', 'device' }, { 'intentId' })
            or event.interactionId ~= INTERACTION_ID or event.revision ~= uiRevision
            or (event.action ~= 'activate' and event.action ~= 'cancel')
            or (event.device ~= 'keyboard' and event.device ~= 'gamepad'
                and event.device ~= 'mouse') then return false end
        if event.action == 'cancel' then
            CreateThread(function() handleInput('cancel', event.device, nil, true) end)
            return true
        end
        if not Validation.identifier(event.intentId) then return false end
        local selected = intentEngine.resolve(event.intentId)
        if not selected then return false end
        CreateThread(function() handleInput('primary', event.device, selected, true) end)
        return true
    end)
    if bound == nil then uiApi = nil; return false end
    local snapshot = uiCall('getInteractionSnapshot')
    if snapshot == nil then uiApi = nil; return false end
    if type(snapshot.interaction) == 'table'
        and Validation.isInteger(snapshot.interaction.revision, 1) then
        uiRevision = math.max(uiRevision, snapshot.interaction.revision)
    end
    uiVisible, uiFingerprint = false, nil
    if activeSession then
        showProgress(activeSession.intent.label, { mode = 'indeterminate' }, true,
            'session|' .. activeSession.sessionId)
    else syncCue(lastPrimary, lastAlternatives, true) end
    return true
end

local function startUiRebind()
    if not runtimeActive then return end
    uiRetryGeneration = uiRetryGeneration + 1
    local generation, attempt = uiRetryGeneration, 0
    local retry
    retry = function()
        if not runtimeActive or generation ~= uiRetryGeneration then return end
        attempt = attempt + 1
        if bindUi() then return end
        SetTimeout(UI_RETRY_DELAYS_MS[attempt + 1] or UI_RETRY_STEADY_MS, retry)
    end
    SetTimeout(UI_RETRY_DELAYS_MS[1], retry)
end

local requestEntityDiscovery

local function requestDiscovery()
    if discoveryBusy or not runtimeActive then return false end
    discoveryBusy = true
    discoveryGeneration = discoveryGeneration + 1
    local generation, startedAt = discoveryGeneration, monotonicNow()
    local knownRevision = sensor.snapshot().revision
    local expectedRevision, expectedPageCount = nil, nil
    local expectedObjectCount, expectedTotalBytes = nil, nil
    local stagedChunks, stagedBytes, completeSnapshot, failed = {}, 0, nil, false
    for page = 1, Limits.maximumDiscoveryPages do
        if monotonicNow() - startedAt > DISCOVERY_TRANSFER_TIMEOUT_MS then
            failed = true
            break
        end
        local snapshot = coreCall('synex.interact.discovery.snapshot', {
            knownRevision = knownRevision,
            snapshotRevision = expectedRevision or 0,
            page = page,
        }, { timeoutMs = CONTRACT_TIMEOUT_MS })
        if not runtimeActive or generation ~= discoveryGeneration
            or not Validation.exactObject(snapshot, {
                'schemaVersion', 'revision', 'unchanged', 'page',
                'pageCount', 'complete', 'objectCount', 'totalBytes', 'payload',
            }) or snapshot.schemaVersion ~= 1
            or not Validation.isInteger(snapshot.revision, 1, Limits.maximumSafeInteger)
            or type(snapshot.unchanged) ~= 'boolean'
            or not Validation.isInteger(snapshot.page, 1, Limits.maximumDiscoveryPages)
            or snapshot.page ~= page
            or not Validation.isInteger(snapshot.pageCount,
                1, Limits.maximumDiscoveryPages)
            or page > snapshot.pageCount
            or type(snapshot.complete) ~= 'boolean'
            or snapshot.complete ~= (page == snapshot.pageCount)
            or not Validation.isInteger(snapshot.objectCount,
                0, Limits.maximumDiscoveryObjects)
            or not Validation.isInteger(snapshot.totalBytes,
                0, Limits.maximumDiscoveryPayloadBytes)
            or type(snapshot.payload) ~= 'string'
            or #snapshot.payload > Limits.maximumDiscoveryChunkBytes then
            failed = true
            break
        end
        if snapshot.unchanged then
            if page ~= 1 or snapshot.revision ~= knownRevision
                or snapshot.pageCount ~= 1 or not snapshot.complete
                or snapshot.objectCount ~= 0 or snapshot.totalBytes ~= 0
                or snapshot.payload ~= '' then failed = true
            else
                completeSnapshot = { schemaVersion = 1,
                    revision = snapshot.revision, unchanged = true, objects = {} }
            end
            break
        end
        if page == 1 then
            if snapshot.revision == knownRevision then failed = true; break end
            expectedRevision, expectedPageCount = snapshot.revision, snapshot.pageCount
            expectedObjectCount, expectedTotalBytes =
                snapshot.objectCount, snapshot.totalBytes
        elseif snapshot.revision ~= expectedRevision
            or snapshot.pageCount ~= expectedPageCount
            or snapshot.objectCount ~= expectedObjectCount
            or snapshot.totalBytes ~= expectedTotalBytes then
            failed = true
            break
        end
        if snapshot.totalBytes < 2 or snapshot.payload == ''
            or stagedBytes + #snapshot.payload > snapshot.totalBytes then
            failed = true
            break
        end
        stagedChunks[#stagedChunks + 1] = snapshot.payload
        stagedBytes = stagedBytes + #snapshot.payload
        if snapshot.complete then
            if stagedBytes ~= expectedTotalBytes then failed = true; break end
            local codec = type(json) == 'table' and json.decode or nil
            local decoded, decodedOk = nil, false
            if Validation.isCallable(codec) then
                decodedOk, decoded = pcall(codec, table.concat(stagedChunks))
            end
            local objects = decodedOk and Validation.array(decoded,
                Limits.maximumDiscoveryObjects) or nil
            if not objects or #objects ~= expectedObjectCount then
                failed = true
                break
            end
            completeSnapshot = { schemaVersion = 1, revision = expectedRevision,
                unchanged = false, objects = objects }
            break
        end
    end
    discoveryBusy = false
    if failed or not runtimeActive or generation ~= discoveryGeneration
        or completeSnapshot == nil then
        return false
    end
    local applied = sensor.replaceDiscovery(completeSnapshot)
    if applied == nil then return false end
    if applied.unchanged ~= true then
        intentEngine.reset('discovery_changed')
        lastPrimary, lastAlternatives = nil, {}
        bloomOpen, uiFingerprint = false, nil
        CreateThread(requestEntityDiscovery)
    end
    return true
end

requestEntityDiscovery = function()
    if entityDiscoveryBusy or not runtimeActive then return false end
    local discoveryRevision = sensor.snapshot().revision
    if discoveryRevision < 1 then return false end
    entityDiscoveryBusy = true
    entityDiscoveryGeneration = entityDiscoveryGeneration + 1
    local generation = entityDiscoveryGeneration
    local snapshot, operationError = coreCall('synex.interact.discovery.entities', {
        discoveryRevision = discoveryRevision,
    }, { timeoutMs = CONTRACT_TIMEOUT_MS })
    entityDiscoveryBusy = false
    if not runtimeActive or generation ~= entityDiscoveryGeneration
        or type(snapshot) ~= 'table' then
        if type(operationError) == 'table'
            and operationError.code == 'INTERACT_DISCOVERY_STALE' then
            CreateThread(requestDiscovery)
        end
        return false
    end
    return sensor.replaceEntityProjection(snapshot) ~= nil
end

local function startDiscoveryPolling()
    CreateThread(function()
        while runtimeActive do
            local succeeded = requestDiscovery()
            Wait(succeeded and DISCOVERY_INTERVAL_MS or DISCOVERY_RETRY_MS)
        end
    end)
end

local function startEntityDiscoveryPolling()
    CreateThread(function()
        while runtimeActive do
            local succeeded = requestEntityDiscovery()
            Wait(succeeded and Limits.entityProjectionIntervalMs
                or ENTITY_DISCOVERY_RETRY_MS)
        end
    end)
end

local function maintainSession(context)
    if activeSession == nil then return end
    local selected = intentEngine.resolve(activeSession.intent.key,
        activeSession.intent.candidateId, activeSession.intent.revision)
    local observed = {
        actor = observedActor(context) or {},
        worldInstance = Validation.copy(context.worldInstance),
    }
    local reason = Cancellation.evaluate(activeSession.cancellation,
        observed, selected, monotonicNow())
    if reason then requestCancel(reason) end
end

local function startSensorLoop()
    CreateThread(function()
        while runtimeActive do
            refreshUiPreferences(false)
            local ok, context, candidates, metadata = pcall(function()
                return sensor.sample()
            end)
            local primary, alternatives = nil, {}
            if ok and context ~= nil then
                lastContext = context
                incrementCounter('sensorTicks')
                incrementCounter('candidatesSeen', #candidates)
                incrementCounter('expensiveChecks', metadata.expensiveCandidateCount)
                clientGauges.candidateCount = #candidates
                clientGauges.expensiveCandidateCount = metadata.expensiveCandidateCount
                primary, alternatives = intentEngine.arbitrate(context, candidates)
                if traceEnabled then
                    local sensorInspection = sensor.snapshot()
                    local actor = type(context.actor) == 'table' and context.actor or {}
                    local contextFrame = {
                        movementState = actor.movementState,
                        vehicleState = actor.vehicleState,
                        weaponState = actor.weaponState,
                        dead = actor.dead == true, ragdoll = actor.ragdoll == true,
                        speedBucket = traceBucket(actor.speed, 2),
                        inputDevice = context.inputDevice,
                        focused = context.focusedTarget ~= nil,
                        world = context.worldInstance ~= nil,
                        discoveryRevision = context.discoveryRevision,
                    }
                    local contextFingerprint = table.concat({
                        tostring(contextFrame.movementState),
                        tostring(contextFrame.vehicleState),
                        tostring(contextFrame.weaponState),
                        tostring(contextFrame.dead), tostring(contextFrame.ragdoll),
                        tostring(contextFrame.speedBucket), tostring(contextFrame.inputDevice),
                        tostring(contextFrame.focused), tostring(contextFrame.world),
                        tostring(contextFrame.discoveryRevision),
                    }, '|')
                    recordTraceChanged('context', 'context', contextFrame, contextFingerprint)

                    local candidateItems, candidateFingerprintParts = {}, {
                        tostring(#candidates),
                        tostring(metadata.expensiveCandidateCount),
                        tostring(metadata.pendingRay == true),
                    }
                    for index, candidate in ipairs(sensorInspection.topCandidates or {}) do
                        if index > Limits.maximumVisibleIntents then break end
                        local item = {
                            objectKey = candidate.objectKey, slotKey = candidate.slotKey,
                            provider = candidate.source, targetKind = candidate.targetKind,
                            distanceBucket = traceBucket(candidate.distance, 4),
                            gazeBucket = traceBucket(candidate.gaze, 20),
                            exactRay = candidate.exactRay == true,
                            occluded = candidate.occluded,
                        }
                        candidateItems[#candidateItems + 1] = item
                        candidateFingerprintParts[#candidateFingerprintParts + 1] = table.concat({
                            tostring(item.objectKey), tostring(item.slotKey),
                            tostring(item.provider), tostring(item.targetKind),
                            tostring(item.exactRay), tostring(item.occluded),
                        }, ':')
                    end
                    recordTraceChanged('candidates', 'candidates', {
                        count = #candidates,
                        expensiveCount = metadata.expensiveCandidateCount,
                        pendingRay = metadata.pendingRay == true,
                        items = candidateItems,
                    }, table.concat(candidateFingerprintParts, '|'))

                    local intentInspection = intentEngine.snapshot()
                    local scoreItems, scoreFingerprintParts = {}, {}
                    for index, item in ipairs(intentInspection.ranked or {}) do
                        if index > Limits.maximumVisibleIntents then break end
                        local score = traceBucket(item.score, 100)
                        scoreItems[#scoreItems + 1] = {
                            intentKey = item.key, objectKey = item.objectKey,
                            slotKey = item.slotKey, score = score,
                            breakdown = item.breakdown,
                            unknownConditions = item.unknownConditions,
                        }
                        scoreFingerprintParts[#scoreFingerprintParts + 1] = table.concat({
                            tostring(item.key), tostring(item.objectKey), tostring(item.slotKey),
                            tostring(score),
                        }, ':')
                    end
                    local decision = intentInspection.decision or {}
                    for _, reason in ipairs(decision.rejectionReasons or {}) do
                        scoreFingerprintParts[#scoreFingerprintParts + 1] =
                            tostring(reason.code) .. ':' .. tostring(reason.count)
                    end
                    for _, advisory in ipairs(decision.advisories or {}) do
                        scoreFingerprintParts[#scoreFingerprintParts + 1] =
                            tostring(advisory.code) .. ':' .. tostring(advisory.count)
                    end
                    recordTraceChanged('score', 'score', {
                        items = scoreItems, decision = decision,
                    },
                        table.concat(scoreFingerprintParts, '|'))

                    local primaryFrame = primary and {
                        present = true, intentKey = primary.key,
                        objectKey = primary.objectKey, slotKey = primary.slotKey,
                        provider = primary.source, score = traceBucket(primary.score, 100),
                    } or { present = false }
                    local primaryFingerprint = primary and table.concat({
                        tostring(primary.key), tostring(primary.objectKey),
                        tostring(primary.slotKey), tostring(primary.source),
                    }, '|') or 'none'
                    recordTraceChanged('primary', 'primary', primaryFrame, primaryFingerprint)
                end
                lastPrimary, lastAlternatives = primary, alternatives or {}
                sensor.setInteractionState(primary and primary.target,
                    primary and primary.key, inputDevice,
                    uiPreferences.interactionAssist)
                maintainSession(context)
                if activeSession == nil and activeLease == nil and not actionInFlight then
                    syncCue(primary, alternatives, false)
                end
            else
                lastContext, lastPrimary, lastAlternatives = nil, nil, {}
                intentEngine.reset('context_unavailable')
                if traceEnabled then
                    recordTraceChanged('context', 'context', {
                        movementState = 'UNAVAILABLE', focused = false, world = false,
                    }, 'unavailable')
                    recordTraceChanged('candidates', 'candidates', {
                        count = 0, expensiveCount = 0, pendingRay = false, items = {},
                    }, 'unavailable')
                    recordTraceChanged('score', 'score', { items = {} }, 'unavailable')
                    recordTraceChanged('primary', 'primary', { present = false }, 'none')
                end
                if activeSession == nil and activeLease == nil and not actionInFlight then
                    removeInteraction()
                end
            end
            local interval = sensor.nextInterval(primary ~= nil or activeSession ~= nil)
            clientGauges.sensorIntervalMs = interval
            Wait(interval)
        end
    end)
end

local function startMetricsReporting()
    metricGeneration = metricGeneration + 1
    local generation = metricGeneration
    local function report()
        if not runtimeActive or generation ~= metricGeneration then return end
        metricSequence = metricSequence + 1
        clientEpoch = clientEpoch or math.max(1, math.floor(monotonicNow()))
        clientGauges.sensorDurationMs = durationAverage(
            'sensorDurationMs', 'sensorDurationSamples')
        clientGauges.providerDurationMs = durationAverage(
            'providerDurationMs', 'providerDurationSamples')
        clientGauges.intentScoringDurationMs = durationAverage(
            'intentScoringDurationMs', 'intentScoringDurationSamples')
        local counters, gauges = Validation.copy(clientCounters),
            Validation.copy(clientGauges)
        local result = coreCall('synex.interact.metrics.report', {
            clientEpoch = clientEpoch, sequence = metricSequence,
            counters = counters, gauges = gauges,
        }, { timeoutMs = CONTRACT_TIMEOUT_MS })
        local delay = type(result) == 'table'
            and Validation.isInteger(result.nextReportAfterMs, 5000, 60000)
            and result.nextReportAfterMs or Limits.metricsReportIntervalMs
        SetTimeout(delay, report)
    end
    SetTimeout(Limits.metricsReportIntervalMs, report)
end

local function graphTargetPosition(command)
    local presentation = command.presentation
    local candidate = type(presentation) == 'table' and presentation.position or nil
    if candidate == nil and type(command.target) == 'table' then
        candidate = command.target.position
    end
    return Validation.vector3(candidate)
end

local function validGraphCommand(command)
    if not Validation.exactObject(command, {
        'schemaVersion', 'sessionId', 'executionId', 'nodeKey', 'sequence',
        'type', 'presentation', 'target', 'serverDurationMs',
    }) or command.schemaVersion ~= 1
        or not Validation.token(command.sessionId, 8, 96)
        or not Validation.token(command.executionId, 8, 96)
        or not Validation.text(command.nodeKey, 1, 64)
        or not Validation.isInteger(command.sequence, 1)
        or not PRESENTATION_TYPES[command.type]
        or not Validation.isPlainTable(command.presentation)
        or not Validation.isInteger(command.serverDurationMs, 0, 60000) then return false end
    local target = Validation.target(command.target)
    return target ~= nil
end

local function graphCommandCurrent(command, token)
    local commands = graphCommands[command.executionId]
    return runtimeActive and token.generation == graphGeneration
        and type(commands) == 'table' and commands[command.sequence] == token
end

local function ackGraph(command, token, result, code)
    if not graphCommandCurrent(command, token) then return end
    recordTrace('graph', {
        stage = 'ack', nodeKey = command.nodeKey, commandType = command.type,
        sequence = command.sequence, result = result,
        code = traceFailureCode(code),
    })
    local payload = {
        sessionId = command.sessionId, executionId = command.executionId,
        nodeKey = command.nodeKey, sequence = command.sequence, result = result,
    }
    if code ~= nil then payload.code = tostring(code):sub(1, 64) end
    coreCall('synex.interact.graph.ack', payload, { timeoutMs = CONTRACT_TIMEOUT_MS })
    local commands = graphCommands[command.executionId]
    if type(commands) == 'table' and commands[command.sequence] == token then
        commands[command.sequence] = nil
        if next(commands) == nil then graphCommands[command.executionId] = nil end
    end
end

local function applyAnimation(command, token)
    local presentation = command.presentation
    local dictionary = presentation.dictionary or presentation.dict
    local name = presentation.name or presentation.animation
    if not boundedText(dictionary, 96) or not boundedText(name, 96) then
        return false, 'INTERACT_PRESENTATION_INVALID'
    end
    RequestAnimDict(dictionary)
    local function releaseDictionary()
        if callable(RemoveAnimDict) then pcall(RemoveAnimDict, dictionary) end
    end
    local deadline = monotonicNow() + math.min(3000,
        math.max(250, command.serverDurationMs))
    while graphCommandCurrent(command, token)
        and not HasAnimDictLoaded(dictionary) and monotonicNow() < deadline do Wait(25) end
    if not graphCommandCurrent(command, token) then
        releaseDictionary()
        return false, 'INTERACT_CANCELLED'
    end
    if not HasAnimDictLoaded(dictionary) then
        releaseDictionary()
        return false, 'INTERACT_PRESENTATION_TIMEOUT'
    end
    local ped = PlayerPedId()
    if ped <= 0 or not DoesEntityExist(ped) then
        releaseDictionary()
        return false, 'INTERACT_CONTEXT_INVALID'
    end
    local blendIn = presentation.blendIn == nil and 4.0 or presentation.blendIn
    local blendOut = presentation.blendOut == nil and -4.0 or presentation.blendOut
    local flags = presentation.flags == nil and 0 or presentation.flags
    local playbackRate = presentation.playbackRate == nil and 0.0
        or presentation.playbackRate
    if not Validation.isFinite(blendIn) or math.abs(blendIn) > 32
        or not Validation.isFinite(blendOut) or math.abs(blendOut) > 32
        or not Validation.isInteger(flags, 0, 2147483647)
        or not Validation.isFinite(playbackRate)
        or playbackRate < 0 or playbackRate > 1 then
        releaseDictionary()
        return false, 'INTERACT_PRESENTATION_INVALID'
    end
    cleanupOwnedPresentation()
    TaskPlayAnim(ped, dictionary, name,
        blendIn, blendOut,
        command.serverDurationMs > 0 and command.serverDurationMs or -1,
        flags, playbackRate, false, false, false)
    ownedAnimation = { ped = ped, dictionary = dictionary, name = name }
    return true
end

local function applyGraphPresentation(command, token)
    local ped = PlayerPedId()
    if ped <= 0 or not DoesEntityExist(ped) then
        return false, 'INTERACT_CONTEXT_INVALID'
    end
    if command.type == 'faceTarget' then
        local position = graphTargetPosition(command)
        if not position then return false, 'INTERACT_PRESENTATION_INVALID' end
        cleanupOwnedPresentation()
        TaskTurnPedToFaceCoord(ped, position.x, position.y, position.z,
            command.serverDurationMs > 0 and command.serverDurationMs or 500)
        ownedTask = { ped = ped, kind = command.type }
    elseif command.type == 'moveToSlot' then
        local position = graphTargetPosition(command)
        if not position then return false, 'INTERACT_PRESENTATION_INVALID' end
        local speed = command.presentation.speed == nil and 1.0
            or command.presentation.speed
        local heading = command.presentation.heading == nil and GetEntityHeading(ped)
            or command.presentation.heading
        if not Validation.isFinite(speed) or speed < 0.05 or speed > 10
            or not Validation.isFinite(heading) then
            return false, 'INTERACT_PRESENTATION_INVALID'
        end
        cleanupOwnedPresentation()
        TaskGoStraightToCoord(ped, position.x, position.y, position.z,
            speed,
            command.serverDurationMs > 0 and command.serverDurationMs or 5000,
            heading % 360.0, 0.25)
        ownedTask = { ped = ped, kind = command.type }
    elseif command.type == 'animation' then
        return applyAnimation(command, token)
    elseif command.type == 'scenario' then
        local scenario = command.presentation.scenario
        if not boundedText(scenario, 96) then return false, 'INTERACT_PRESENTATION_INVALID' end
        cleanupOwnedPresentation()
        TaskStartScenarioInPlace(ped, scenario, 0, true)
        ownedScenario = { ped = ped, scenario = scenario }
    elseif command.type == 'progress' or command.type == 'interactionCue' then
        local label = command.presentation.label or command.presentation.text
        local mode = command.presentation.mode
        local progress
        if mode == 'determinate' then
            local value, maximum = command.presentation.value, command.presentation.maximum
            if not Validation.isFinite(value) or not Validation.isFinite(maximum)
                or maximum <= 0 or maximum > Limits.maximumSafeInteger
                or value < 0 or value > maximum then
                return false, 'INTERACT_PRESENTATION_INVALID'
            end
            progress = { mode = 'determinate', value = value, maximum = maximum }
        elseif mode == 'timed' or mode == nil and command.serverDurationMs > 0 then
            if command.serverDurationMs < 1 then
                return false, 'INTERACT_PRESENTATION_INVALID'
            end
            progress = { mode = 'timed', elapsedMs = 0,
                durationMs = command.serverDurationMs }
        elseif mode == nil or mode == 'indeterminate' then
            progress = { mode = 'indeterminate' }
        else
            return false, 'INTERACT_PRESENTATION_INVALID'
        end
        if not showProgress(label, progress,
                command.presentation.cancellable ~= false,
                command.executionId .. '|' .. command.sequence) then
            return false, 'INTERACT_PRESENTATION_FAILED'
        end
    elseif command.type == 'sound' then
        local name, soundSet = command.presentation.name, command.presentation.soundSet
        if not boundedText(name, 64) or not boundedText(soundSet, 64) then
            return false, 'INTERACT_PRESENTATION_INVALID'
        end
        PlaySoundFrontend(-1, name, soundSet, true)
    elseif command.type == 'stopAnimation' then cleanupOwnedPresentation()
    end
    return true
end

RegisterNetEvent(GRAPH_EVENT, function(command)
    if source ~= 65535 or not runtimeActive or type(command) ~= 'table' then return end
    if command.type == 'cleanup' then
        if not Validation.exactObject(command,
            { 'schemaVersion', 'type', 'sessionId', 'executionId', 'reason' },
            { 'committed' })
            or command.schemaVersion ~= 1
            or not Validation.token(command.sessionId, 8, 96)
            or not Validation.token(command.executionId, 8, 96)
            or not Validation.text(command.reason, 1, 64)
            or command.committed ~= nil and type(command.committed) ~= 'boolean'
            or (activeSession == nil or activeSession.sessionId ~= command.sessionId)
            and (activeLease == nil or activeLease.sessionId ~= command.sessionId) then return end
        recordTrace('graph', {
            stage = 'cleanup', result = command.committed and 'COMMITTED' or 'CANCELLED',
            code = traceFailureCode(command.reason),
        })
        clearInteractionState(command.reason, false)
        return
    end
    if not validGraphCommand(command)
        or (activeSession == nil or activeSession.sessionId ~= command.sessionId)
        and (activeLease == nil or activeLease.sessionId ~= command.sessionId) then return end
    local previous = graphSequences[command.executionId] or 0
    if command.sequence <= previous then return end
    graphSequences[command.executionId] = command.sequence
    recordTrace('graph', {
        stage = 'command', nodeKey = command.nodeKey, commandType = command.type,
        sequence = command.sequence,
    })
    local commands = graphCommands[command.executionId]
    if commands == nil then commands = {}; graphCommands[command.executionId] = commands end
    local token = { generation = graphGeneration }
    commands[command.sequence] = token
    CreateThread(function()
        local delivered, applied, code = pcall(applyGraphPresentation, command, token)
        if not delivered then applied, code = false, 'INTERACT_PRESENTATION_FAILED' end
        if not graphCommandCurrent(command, token) then return end
        ackGraph(command, token, applied and 'COMPLETED' or 'FAILED', code)
    end)
end)

local function ensureOwner(owner)
    if not Validation.resourceName(owner) then return nil end
    local state = GetResourceState(owner)
    if state ~= 'started' and state ~= 'starting' then return nil end
    local record = owners[owner]
    if not record or record.state ~= 'started' then
        ownerEpochSerial = ownerEpochSerial + 1
        record = { epoch = ownerEpochSerial, state = 'started' }
        owners[owner] = record
    end
    return record.epoch
end

exports('GetAPI', function(versionRange)
    local requested = versionRange == nil and '^1.0.0' or tostring(versionRange)
    if not API_RANGES[requested] then return nil, clientError(
        'INTERACT_VERSION_UNSUPPORTED', 'The requested Interact client API is unsupported.') end
    local invoked, owner = pcall(GetInvokingResource)
    if not invoked or not Validation.resourceName(owner) or owner == RESOURCE_NAME then
        return nil, clientError('INTERACT_OWNER_INVALID',
            'External Interact client API access requires an active resource.')
    end
    local epoch = ensureOwner(owner)
    if not epoch then return nil, clientError('INTERACT_OWNER_STALE',
        'The Interact client API owner is not active.') end
    local api = { version = '1.0.0', ownerResource = owner, ownerEpoch = epoch }
    local function guard()
        local current = owners[owner]
        if not runtimeActive or not current or current.state ~= 'started'
            or current.epoch ~= epoch then return nil, clientError(
                'INTERACT_OWNER_STALE', 'The Interact client API owner restarted.') end
        return true
    end
    api.registerCandidateProvider = function(definition, handler)
        local valid, guardError = guard()
        if not valid then return nil, guardError end
        return sensor.registerProvider(owner, epoch, definition, handler)
    end
    api.registerConditionEvaluator = function(definition, handler)
        local valid, guardError = guard()
        if not valid then return nil, guardError end
        return intentEngine.registerEvaluator(owner, epoch, definition, handler)
    end
    api.getDiagnostics = function()
        local valid, guardError = guard()
        if not valid then return nil, guardError end
        return {
            sensor = sensor.snapshot(), intent = intentEngine.diagnostics(),
            ui = { bound = uiApi ~= nil, revision = uiRevision,
                visible = uiVisible, bloomOpen = bloomOpen,
                preferences = Validation.copy(uiPreferences) },
            session = activeSession and {
                state = activeSession.state, startedAt = activeSession.startedAt,
            } or nil,
            counters = Validation.copy(clientCounters),
            gauges = Validation.copy(clientGauges),
            durations = Validation.copy(localDurations),
            trace = clientTrace.snapshot(),
        }, nil
    end
    return api, nil
end)

for _, mapping in ipairs(INPUT_MAPPINGS) do
    local action = mapping.action
    local keyboardCommand = inputCommand(action, 'keyboard')
    local gamepadCommand = inputCommand(action, 'gamepad')
    RegisterCommand(keyboardCommand, function()
        handleInput(action, 'keyboard')
    end, false)
    RegisterCommand(gamepadCommand, function()
        handleInput(action, 'gamepad')
    end, false)
    RegisterKeyMapping(keyboardCommand,
        ('Synex interaction %s'):format(action), 'KEYBOARD', mapping.keyboard)
    RegisterKeyMapping(gamepadCommand,
        ('Synex interaction %s (gamepad)'):format(action),
        'PAD_DIGITALBUTTON', mapping.gamepad)
    if mapping.mouse then
        local mouseCommand = inputCommand(action, 'mouse')
        RegisterCommand(mouseCommand, function()
            handleInput(action, 'mouse')
        end, false)
        RegisterKeyMapping(mouseCommand,
            ('Synex interaction %s (mouse)'):format(action),
            'MOUSE_BUTTON', mapping.mouse)
    end
end
refreshInputHints(true)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'synex_ui' then startUiRebind(); return end
    if resource == 'synex_core' then
        discoveryGeneration = discoveryGeneration + 1
        discoveryBusy = false
        entityDiscoveryGeneration = entityDiscoveryGeneration + 1
        entityDiscoveryBusy = false
        CreateThread(requestDiscovery)
        CreateThread(requestEntityDiscovery)
        return
    end
    if resource == RESOURCE_NAME or not Validation.resourceName(resource) then return end
    local current = owners[resource]
    if current and current.state == 'started' then return end
    ownerEpochSerial = ownerEpochSerial + 1
    owners[resource] = { epoch = ownerEpochSerial, state = 'started' }
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == RESOURCE_NAME then
        runtimeActive = false
        uiRetryGeneration = uiRetryGeneration + 1
        discoveryGeneration = discoveryGeneration + 1
        entityDiscoveryGeneration = entityDiscoveryGeneration + 1
        metricGeneration = metricGeneration + 1
        actionGeneration = actionGeneration + 1
        graphGeneration = graphGeneration + 1
        cleanupOwnedPresentation()
        if uiApi ~= nil and uiVisible then removeInteraction() end
        uiApi = nil
        applyUiPreferences(nil)
        sensor.cleanup()
        intentEngine.cleanup()
        clientTrace.cleanup()
        traceFingerprints = {}
        activeLease, activeSession = nil, nil
        return
    end
    if resource == 'synex_ui' then
        uiApi, uiVisible, uiFingerprint = nil, false, nil
        applyUiPreferences(nil)
        uiBindingGeneration = uiBindingGeneration + 1
        uiRetryGeneration = uiRetryGeneration + 1
        return
    end
    if resource == 'synex_core' then
        clearInteractionState('INTERACT_RESOURCE_STOPPED', false)
        discoveryGeneration = discoveryGeneration + 1
        discoveryBusy = false
        entityDiscoveryGeneration = entityDiscoveryGeneration + 1
        entityDiscoveryBusy = false
        return
    end
    local record = owners[resource]
    if record then
        sensor.cleanupOwner(resource, record.epoch)
        intentEngine.cleanupOwner(resource, record.epoch)
        record.state = 'stopped'
    end
end)

startUiRebind()
startDiscoveryPolling()
startEntityDiscoveryPolling()
startSensorLoop()
startMetricsReporting()
