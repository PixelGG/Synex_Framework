local RESOURCE_NAME = GetCurrentResourceName()
local SIGNAL_TRANSPORT_OWNER = 'synex_notify'
local INTERACTION_TRANSPORT_OWNER = 'synex_interact'
local API_VERSION = '1.0.0'
local PROTOCOL_VERSION = 1
local FOCUS_AGENT_VERSION = '1.0.0'
local FOCUS_AGENT_WAKEUP_EVENT = 'synex_ui:focus-agent:wakeup:v1'
local TIMER_MODULUS = 4294967296
local TIMER_HALF_RANGE = 2147483648
local MAXIMUM_SAFE_INTEGER = 9007199254740991

local LIMITS = {
    maximumPayloadBytes = 32768,
    maximumDepth = 8,
    maximumEntries = 256,
    maximumStringBytes = 4096,
    maximumPendingRequests = 64,
    maximumSurfaces = 32,
    maximumOwnerSurfaces = 8,
    maximumFocusLeases = 64,
    maximumOwnerFocusLeases = 16,
    maximumFocusAgents = 64,
    maximumFields = 24,
    maximumOptions = 96,
    maximumSections = 16,
    maximumMenuItems = 96,
    maximumMenuDepth = 3,
    maximumSignals = 8,
    maximumOwnerSignals = 8,
    maximumVisibleSignals = 4,
    maximumSignalActions = 2,
    maximumSignalRevisionFences = 256,
    minimumSignalSoundVolume = 1,
    maximumSignalSoundVolume = 100,
    signalSoundCooldownMs = 50,
    maximumSignalSoundsPerWindow = 8,
    signalSoundWindowMs = 1000,
    maximumInteractionIntents = 6,
    maximumInteractionRevisionFences = 64,
    maximumInteractionDurationMs = 3600000,
    minimumTimeoutMs = 1000,
    maximumTimeoutMs = 120000,
    defaultTimeoutMs = 30000,
}

local FOCUS_MODES = {
    PASSIVE = { keyboard = false, pointer = false },
    KEYBOARD = { keyboard = true, pointer = false },
    POINTER = { keyboard = false, pointer = true },
    EXCLUSIVE = { keyboard = true, pointer = true },
}

local PRIORITY_CLASSES = {
    PASSIVE = 0,
    NORMAL = 10,
    MODAL = 20,
    CRITICAL = 30,
    SYSTEM = 40,
}

local CONFLICT_POLICIES = {
    DENY = true,
    QUEUE = true,
    SUSPEND = true,
}

local LAYERS = {
    base = true,
    passive = true,
    floating = true,
    tooltip = true,
    popover = true,
    menu = true,
    drawer = true,
    modal = true,
    alert = true,
    system = true,
}

local SURFACE_KINDS = {
    alert = { layer = 'alert', mode = 'EXCLUSIVE', priority = 'MODAL', conflict = 'SUSPEND' },
    confirm = { layer = 'modal', mode = 'EXCLUSIVE', priority = 'MODAL', conflict = 'SUSPEND' },
    input = { layer = 'modal', mode = 'EXCLUSIVE', priority = 'MODAL', conflict = 'SUSPEND' },
    form = { layer = 'modal', mode = 'EXCLUSIVE', priority = 'MODAL', conflict = 'SUSPEND' },
    select = { layer = 'popover', mode = 'EXCLUSIVE', priority = 'MODAL', conflict = 'SUSPEND' },
    menu = { layer = 'menu', mode = 'EXCLUSIVE', priority = 'NORMAL', conflict = 'DENY' },
    contextMenu = { layer = 'menu', mode = 'EXCLUSIVE', priority = 'NORMAL', conflict = 'DENY' },
}

local FIELD_TYPES = {
    text = true,
    number = true,
    textarea = true,
    select = true,
    ['multi-select'] = true,
    checkbox = true,
    radio = true,
    switch = true,
    slider = true,
}

local TONES = {
    neutral = true,
    accent = true,
    info = true,
    success = true,
    warning = true,
    danger = true,
}

local SIGNAL_KINDS = {
    toast = true,
    progress = true,
    persistent = true,
    banner = true,
    status = true,
}

local SIGNAL_TONES = {
    neutral = true,
    info = true,
    success = true,
    warning = true,
    danger = true,
}

local SIGNAL_SOUND_TONES = {
    neutral = true,
    info = true,
    success = true,
    warning = true,
    danger = true,
    critical = true,
}

local SIGNAL_PRIORITIES = {
    low = true,
    normal = true,
    high = true,
    critical = true,
}

local SIGNAL_POSITIONS = {
    ['top-right'] = true,
    ['top-left'] = true,
    ['bottom-right'] = true,
    ['bottom-left'] = true,
    ['top-center'] = true,
    ['bottom-center'] = true,
}

local SIGNAL_PROGRESS_STATES = {
    PENDING = true,
    RUNNING = true,
    SUCCESS = true,
    FAILED = true,
    CANCELLED = true,
}

local SIGNAL_PROGRESS_MODES = {
    determinate = true,
    indeterminate = true,
}

local SIGNAL_ACTION_STYLES = {
    default = true,
    primary = true,
    danger = true,
}

local interactionRuntime = {
    modes = {
        cue = true,
        bloom = true,
        progress = true,
    },
    progressModes = {
        determinate = true,
        indeterminate = true,
        timed = true,
    },
    active = nil,
    generation = 0,
    revisions = {},
    revisionOrder = {},
    actionSubscriber = nil,
    actionBindingGeneration = 0,
}

local INPUT_INTENTS = {
    UP = 188,
    DOWN = 187,
    LEFT = 189,
    RIGHT = 190,
    CONFIRM = 201,
    BACK = 202,
    PREVIOUS_TAB = 205,
    NEXT_TAB = 206,
    PAGE_UP = 207,
    PAGE_DOWN = 208,
}

local INPUT_DEVICES = {
    mouse = true,
    keyboard = true,
    gamepad = true,
}

local ICON_KEYS = {
    check = true,
    close = true,
    ['chevron-down'] = true,
    ['chevron-right'] = true,
    ['arrow-left'] = true,
    ['arrow-right'] = true,
    search = true,
    plus = true,
    minus = true,
    more = true,
    copy = true,
    eye = true,
    ['eye-off'] = true,
    info = true,
    warning = true,
    error = true,
    success = true,
    menu = true,
    command = true,
    signal = true,
}

local FORBIDDEN_PAYLOAD_KEYS = {
    html = true,
    svg = true,
    url = true,
    href = true,
    src = true,
    iframe = true,
    script = true,
}

local GAME_MESSAGE_TYPES = {
    ['runtime:sync'] = true,
    ['runtime:shutdown'] = true,
    ['surface:open'] = true,
    ['surface:update'] = true,
    ['surface:close'] = true,
    ['signal:upsert'] = true,
    ['signal:remove'] = true,
    ['signal:sound'] = true,
    ['interaction:upsert'] = true,
    ['interaction:remove'] = true,
    ['input:intent'] = true,
    ['preferences:sync'] = true,
}

local HEALTH_REASONS = {
    NUI_NOT_READY = true,
    FOCUS_DESYNC = true,
    TRANSPORT_DEGRADED = true,
    RUNTIME_RELOAD = true,
    REQUEST_PRESSURE = true,
}

local ERROR_CODES = {
    'UI_NOT_READY',
    'UI_FOCUS_BUSY',
    'UI_FOCUS_DENIED',
    'UI_FOCUS_LEASE_INVALID',
    'UI_SIGNAL_DENIED',
    'UI_INTERACTION_DENIED',
    'UI_OWNER_STOPPED',
    'UI_OWNER_STALE',
    'UI_REQUEST_INVALID',
    'UI_REQUEST_TIMEOUT',
    'UI_REQUEST_CANCELLED',
    'UI_REQUEST_STALE',
    'UI_SURFACE_CONFLICT',
    'UI_PAYLOAD_TOO_LARGE',
    'UI_PROTOCOL_UNSUPPORTED',
}

local ERROR_CODE_SET = {}
for _, code in ipairs(ERROR_CODES) do ERROR_CODE_SET[code] = true end

local ERROR_STAGES = {
    message = true,
    render = true,
}

local SUPPORTED_API_RANGES = {
    ['1'] = true,
    ['v1'] = true,
    ['1.0'] = true,
    ['1.0.0'] = true,
    ['^1.0.0'] = true,
}

local SUPPORTED_FOCUS_AGENT_RANGES = {
    ['1'] = true,
    ['v1'] = true,
    ['1.0'] = true,
    ['1.0.0'] = true,
    ['^1.0.0'] = true,
}

local function focusAgentBootGeneration()
    local words = {}
    local timer = 0
    if GetGameTimer ~= nil then
        local called, value = pcall(GetGameTimer)
        if called and type(value) == 'number' then timer = math.floor(math.abs(value)) end
    end
    words[1] = timer % 2147483647
    for index = 2, 5 do
        local value = nil
        if GetRandomIntInRange ~= nil then
            local called, randomValue = pcall(GetRandomIntInRange, 1, 2147483646)
            if called and type(randomValue) == 'number' then value = math.floor(randomValue) end
        end
        if value == nil then value = math.random(1, 2147483646) end
        words[index] = value % 2147483647
    end
    return ('ui-%08x-%08x-%08x-%08x-%08x'):format(
        words[1], words[2], words[3], words[4], words[5])
end

local FOCUS_AGENT_BOOT_GENERATION = focusAgentBootGeneration()

local DEFAULT_PREFERENCES = {
    schemaVersion = 1,
    quality = 'BALANCED',
    scale = 100,
    density = 'comfortable',
    reducedMotion = false,
    reducedTransparency = false,
    highContrast = false,
    interactionAssist = false,
}

local SIGNAL_STACK_LAYOUT = {
    comfortableHeightPx = 152,
    compactHeightPx = 128,
    narrowHeightBonusPx = 28,
    narrowWidthPx = 360,
    edgeInsetPx = 20,
}

local PREFERENCE_QUALITIES = { LOW = true, BALANCED = true, HIGH = true, ULTRA = true }
local PREFERENCE_SCALES = { [85] = true, [100] = true, [115] = true, [125] = true }
local PREFERENCE_DENSITIES = { compact = true, comfortable = true }
local PREFERENCE_KVP_KEY = 'synex_ui:preferences:v1'

local CALLBACK_POLICIES = {
    ['runtime:ready'] = { capacity = 8, refillPerSecond = 1 },
    ['runtime:respond'] = { capacity = 32, refillPerSecond = 16 },
    ['runtime:close'] = { capacity = 16, refillPerSecond = 8 },
    ['runtime:input'] = { capacity = 48, refillPerSecond = 24 },
    ['runtime:signals:visible'] = { capacity = 32, refillPerSecond = 16 },
    ['runtime:interaction'] = { capacity = 20, refillPerSecond = 10 },
    ['runtime:preferences'] = { capacity = 8, refillPerSecond = 2 },
    ['runtime:error'] = { capacity = 4, refillPerSecond = 0.25 },
}

local metrics = {
    ui_focus_acquire_total = 0,
    ui_focus_denied_total = 0,
    ui_surface_open_total = 0,
    ui_surface_close_total = 0,
    ui_signal_upsert_total = 0,
    ui_signal_remove_total = 0,
    ui_interaction_upsert_total = 0,
    ui_interaction_remove_total = 0,
    ui_interaction_action_total = 0,
    ui_request_total = 0,
    ui_request_timeout_total = 0,
    ui_payload_bytes = 0,
    ui_runtime_errors = 0,
    ui_owner_cleanup_total = 0,
    ui_active_surfaces = 0,
    ui_active_signals = 0,
    ui_active_interactions = 0,
}

local runtimeRunning = true
local nuiReady = false
local browserBootId = nil
local activeInputDevice = 'keyboard'
local rawTimerPrevious = nil
local monotonicTimer = 0
local ownerEpochSerial = 0
local leaseSerial = 0
local surfaceSerial = 0
local requestSerial = 0
local messageSerial = 0
local signalGeneration = 0
local runtimeEpoch = 1
local lastScreenSampleAt = -1000
local lastScreenMetrics = nil
local inputThreadRunning = false
local focusApplied = { keyboard = false, pointer = false, target = 'none' }
local focusDesynchronized = false
local transportFailures = 0
local transientReasons = {}
local preferences = {}
local preferenceRevision = 1
local owners = {}
local focusLeases = {}
local focusStack = {}
local focusQueue = {}
local focusAgents = {}
local focusAgentRevisionSerial = 0
local focusAgentIntentSerial = 0
local surfaces = {}
local surfaceOrder = {}
local signals = {}
local signalOrder = {}
local signalRevisions = {}
local signalRevisionOrder = {}
local browserVisibleSignals = {}
local browserVisibleSignalGeneration = -1
local browserVisibilityRevision = 0
local browserVisibleCapacity = LIMITS.maximumVisibleSignals
local signalCapacitySubscriber = nil
local signalCapacityBindingGeneration = 0
local pendingRequests = {}
local callbackBuckets = {}
local signalSoundRate = { windowStartedAt = -1000, count = 0, lastAt = -1000 }
local finishSurface
local cleanupOwner
local cleanupRuntime
local sendEnvelope
local sendRuntimeSync
local syncFocus
local ensureInputThread
local notifySignalCapacity

local function incrementMetric(name, amount)
    local current = metrics[name] or 0
    metrics[name] = math.min(MAXIMUM_SAFE_INTEGER, current + (amount or 1))
end

local function failure(code, message, details)
    local value = { code = code, message = message }
    if details ~= nil then value.details = details end
    return value
end

local function nowMilliseconds()
    local current = GetGameTimer()
    if type(current) ~= 'number' then return monotonicTimer end
    current = math.floor(current)
    if current < 0 then current = current + TIMER_MODULUS end
    current = current % TIMER_MODULUS
    if rawTimerPrevious == nil then
        rawTimerPrevious = current
        monotonicTimer = current
        return monotonicTimer
    end
    local elapsed = (current - rawTimerPrevious) % TIMER_MODULUS
    if elapsed <= TIMER_HALF_RANGE then
        rawTimerPrevious = current
        monotonicTimer = monotonicTimer + elapsed
    end
    return monotonicTimer
end

local function integerInRange(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge
        and value ~= -math.huge and value % 1 == 0 and value >= minimum and value <= maximum
end

local function boundedText(value, maximum, allowEmpty)
    if type(value) ~= 'string' or #value > maximum or (not allowEmpty and #value == 0) then return false end
    return value:find('[%z\1-\8\11\12\14-\31\127]') == nil
end

local function validIdentifier(value, maximum)
    return boundedText(value, maximum or 96, false)
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function validIconKey(value)
    return boundedText(value, 48, false) and ICON_KEYS[value] == true
end

local function keysAllowed(value, allowed)
    if type(value) ~= 'table' then return false end
    for key in next, value do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

local function arrayLength(value, maximum)
    if type(value) ~= 'table' then return nil end
    local count = 0
    for key in next, value do
        if not integerInRange(key, 1, maximum) then return nil end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then return nil end
    end
    return count
end

local decoderObjectMetatable = { __jsontype = 'object' }
local decoderArrayMetatable = { __jsontype = 'array' }

local function rawMetatable(value)
    if type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, metatable = pcall(debug.getmetatable, value)
        if readable then return metatable end
    end
    local readable, metatable = pcall(getmetatable, value)
    return readable and metatable or nil
end

local function isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metatable = rawMetatable(value)
    return type(metatable) == 'table' and type(rawget(metatable, '__call')) == 'function'
end

local function canonicalContainerKind(value)
    if type(value) ~= 'table' then return nil end
    local metatable = rawMetatable(value)
    if metatable == nil then return 'plain' end
    if rawequal(metatable, decoderObjectMetatable)
        and rawget(metatable, '__jsontype') == 'object' then return 'object' end
    if rawequal(metatable, decoderArrayMetatable)
        and rawget(metatable, '__jsontype') == 'array' then return 'array' end
    return nil
end

local function inertRuntimeContainerKind(value)
    local metatable = rawMetatable(value)
    if type(metatable) ~= 'table' then return nil end
    local kind = rawget(metatable, '__jsontype')
    if kind ~= 'object' and kind ~= 'array' then return nil end
    local entries = 0
    for key in next, metatable do
        entries = entries + 1
        if key ~= '__jsontype' or entries > 1 then return nil end
    end
    return entries == 1 and kind or nil
end

local function cloneJson(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local kind = canonicalContainerKind(value)
    if kind == nil then seen[value] = nil return nil end
    local copied = {}
    for key, child in next, value do copied[key] = cloneJson(child, seen) end
    if kind == 'object' then setmetatable(copied, decoderObjectMetatable)
    elseif kind == 'array' then setmetatable(copied, decoderArrayMetatable) end
    seen[value] = nil
    return copied
end

local function inspectJson(value, depth, seen, stats, allowInertRuntimeContainers)
    local valueType = type(value)
    if valueType == 'nil' or valueType == 'boolean' then return true end
    if valueType == 'number' then
        return value == value and value ~= math.huge and value ~= -math.huge
    end
    if valueType == 'string' then
        if #value > LIMITS.maximumStringBytes then return false, 'string' end
        stats.approximateBytes = stats.approximateBytes + #value
        return true
    end
    if valueType ~= 'table' or depth > LIMITS.maximumDepth or seen[value] then
        return false, valueType == 'table' and 'depth_or_cycle' or 'type'
    end
    local containerKind = canonicalContainerKind(value)
    if containerKind == nil and allowInertRuntimeContainers then
        containerKind = inertRuntimeContainerKind(value)
    end
    if containerKind == nil then return false, 'metatable' end
    seen[value] = true
    local entryCount, maximumIndex = 0, 0
    for key, child in next, value do
        local keyType = type(key)
        if keyType == 'string' then
            if #key > 64 or FORBIDDEN_PAYLOAD_KEYS[key:lower()] then
                seen[value] = nil
                return false, 'key'
            end
            stats.approximateBytes = stats.approximateBytes + #key
        elseif keyType ~= 'number' or not integerInRange(key, 1, LIMITS.maximumEntries) then
            seen[value] = nil
            return false, 'key'
        end
        entryCount = entryCount + 1
        if keyType == 'number' then maximumIndex = math.max(maximumIndex, key) end
        if containerKind == 'object' and keyType ~= 'string' then
            seen[value] = nil
            return false, 'container_shape'
        elseif containerKind == 'array' and keyType ~= 'number' then
            seen[value] = nil
            return false, 'container_shape'
        end
        stats.entries = stats.entries + 1
        if stats.entries > LIMITS.maximumEntries then seen[value] = nil return false, 'entries' end
        local valid, reason = inspectJson(child, depth + 1, seen, stats, allowInertRuntimeContainers)
        if not valid then seen[value] = nil return false, reason end
    end
    if containerKind == 'array' and maximumIndex ~= entryCount then
        seen[value] = nil
        return false, 'container_shape'
    end
    seen[value] = nil
    return true
end

local function boundedJson(value, allowInertRuntimeContainers)
    local stats = { entries = 0, approximateBytes = 0 }
    local valid, reason = inspectJson(value, 0, {}, stats, allowInertRuntimeContainers == true)
    if not valid then return nil, failure('UI_REQUEST_INVALID', 'The JSON value is outside the runtime bounds.', { reason = reason }) end
    if json == nil or type(json.encode) ~= 'function' then
        if stats.approximateBytes > LIMITS.maximumPayloadBytes then
            return nil, failure('UI_PAYLOAD_TOO_LARGE', 'The payload exceeds the runtime byte limit.')
        end
        return stats.approximateBytes
    end
    local encoded, serialized = pcall(json.encode, value)
    if not encoded or type(serialized) ~= 'string' then
        return nil, failure('UI_REQUEST_INVALID', 'The payload is not JSON serializable.')
    end
    if #serialized > LIMITS.maximumPayloadBytes then
        return nil, failure('UI_PAYLOAD_TOO_LARGE', 'The payload exceeds the runtime byte limit.', {
            maximumBytes = LIMITS.maximumPayloadBytes,
        })
    end
    return #serialized
end

local function containsRuntimeContainer(value, seen)
    if type(value) ~= 'table' then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    if canonicalContainerKind(value) == nil and inertRuntimeContainerKind(value) ~= nil then return true end
    for _, child in next, value do
        if containsRuntimeContainer(child, seen) then return true end
    end
    return false
end

local function canonicalizeNuiJson(value)
    if not containsRuntimeContainer(value) then return value end
    if type(json) ~= 'table' or type(json.encode) ~= 'function' or type(json.decode) ~= 'function' then
        return nil, failure('UI_REQUEST_INVALID', 'The Cfx JSON codec is unavailable.')
    end
    local encoded, serialized = pcall(json.encode, value)
    if not encoded or type(serialized) ~= 'string' or #serialized > LIMITS.maximumPayloadBytes then
        return nil, failure('UI_REQUEST_INVALID', 'The NUI request could not be canonicalized safely.')
    end
    local decoded, canonical = pcall(json.decode, serialized, 1, nil,
        decoderObjectMetatable, decoderArrayMetatable)
    if not decoded or type(canonical) ~= 'table' then
        return nil, failure('UI_REQUEST_INVALID', 'The NUI request could not be decoded canonically.')
    end
    local bytes, canonicalError = boundedJson(canonical)
    if not bytes then return nil, canonicalError end
    return canonical
end

local function markReason(reason, durationMs)
    if not HEALTH_REASONS[reason] then return end
    transientReasons[reason] = durationMs and (nowMilliseconds() + durationMs) or MAXIMUM_SAFE_INTEGER
end

local function clearReason(reason)
    transientReasons[reason] = nil
end

local function healthSnapshot()
    local now = nowMilliseconds()
    local reasons = {}
    local present = {}
    local function addReason(reason)
        if not present[reason] then
            present[reason] = true
            reasons[#reasons + 1] = reason
        end
    end
    if not nuiReady then addReason('NUI_NOT_READY') end
    if focusDesynchronized then addReason('FOCUS_DESYNC') end
    if transportFailures >= 3 then addReason('TRANSPORT_DEGRADED') end
    if metrics.ui_active_surfaces >= math.floor(LIMITS.maximumSurfaces * 0.75) then
        addReason('REQUEST_PRESSURE')
    end
    if metrics.ui_active_signals >= math.floor(LIMITS.maximumSignals * 0.75) then
        addReason('REQUEST_PRESSURE')
    end
    for reason, expiresAt in pairs(transientReasons) do
        if expiresAt > now then
            addReason(reason)
        elseif expiresAt <= now then
            transientReasons[reason] = nil
        end
    end
    table.sort(reasons)
    local state = 'READY'
    if not nuiReady or focusDesynchronized then
        state = 'UNHEALTHY'
    elseif #reasons > 0 then
        state = 'DEGRADED'
    end
    return { state = state, reasons = reasons }
end

local function publicLimits()
    return cloneJson(LIMITS)
end

local function resourceState(resource)
    if GetResourceState == nil then return nil end
    local called, state = pcall(GetResourceState, resource)
    return called and type(state) == 'string' and state or nil
end

local function ensureOwner(owner)
    if not validIdentifier(owner, 64) or owner == RESOURCE_NAME then
        return nil, failure('UI_FOCUS_DENIED', 'A valid external owner resource is required.')
    end
    local state = resourceState(owner)
    if state ~= nil and state ~= 'started' and state ~= 'starting' then
        return nil, failure('UI_OWNER_STOPPED', 'The owner resource is not running.')
    end
    local record = owners[owner]
    if record == nil or record.state ~= 'started' then
        ownerEpochSerial = ownerEpochSerial + 1
        record = { epoch = ownerEpochSerial, state = 'started' }
        owners[owner] = record
    end
    return record.epoch
end

local function ownerCurrent(owner, epoch)
    local record = owners[owner]
    if record == nil or record.state ~= 'started' then
        return nil, failure('UI_OWNER_STOPPED', 'The owner resource has stopped.')
    end
    local state = resourceState(owner)
    if state ~= nil and state ~= 'started' and state ~= 'starting' then
        return nil, failure('UI_OWNER_STOPPED', 'The owner resource has stopped.')
    end
    if record.epoch ~= epoch then
        return nil, failure('UI_OWNER_STALE', 'The owner facade belongs to an expired resource epoch.')
    end
    return true
end

local function nextIdentifier(prefix, owner, serial)
    return ('%s:%s:%d:%d'):format(prefix, owner, runtimeEpoch, serial)
end

local function publicLease(lease)
    return {
        leaseId = lease.leaseId,
        ownerResource = lease.ownerResource,
        ownerEpoch = lease.ownerEpoch,
        mode = lease.mode,
        priority = lease.priority,
        reason = lease.reason,
        createdAt = lease.createdAt,
        state = lease.state,
    }
end

local function topFocusLease()
    for index = #focusStack, 1, -1 do
        local lease = focusLeases[focusStack[index]]
        if lease ~= nil then return lease end
    end
    return nil
end

local function applyNativeFocus(keyboard, pointer)
    local target = (keyboard or pointer) and 'shared' or 'none'
    if focusApplied.target == 'owner' then
        return nil, failure('UI_FOCUS_DENIED', 'Owner focus must be released by its resource focus agent.')
    end
    if focusApplied.target == target and focusApplied.keyboard == keyboard
        and focusApplied.pointer == pointer then return true end
    if (keyboard or pointer) and not nuiReady then return false end
    local keepOk = true
    if SetNuiFocusKeepInput ~= nil then keepOk = pcall(SetNuiFocusKeepInput, false) end
    local focusOk = pcall(SetNuiFocus, keyboard, pointer)
    if not keepOk or not focusOk then
        focusDesynchronized = true
        incrementMetric('ui_runtime_errors')
        markReason('FOCUS_DESYNC')
        return nil, failure('UI_FOCUS_DENIED', 'The shared Synex UI native focus call failed.')
    end
    focusApplied = { keyboard = keyboard, pointer = pointer, target = target }
    focusDesynchronized = false
    clearReason('FOCUS_DESYNC')
    return true
end

local function focusAgentCount()
    local count = 0
    for _ in pairs(focusAgents) do count = count + 1 end
    return count
end

local function focusAgentFor(owner, epoch, requireReady)
    local agent = focusAgents[owner]
    if agent == nil or agent.ownerEpoch ~= epoch or agent.bootGeneration ~= FOCUS_AGENT_BOOT_GENERATION
        or agent.version ~= FOCUS_AGENT_VERSION then
        return nil, failure('UI_FOCUS_DENIED',
            'Interactive owner focus requires the compatible Synex UI owner-focus helper.')
    end
    if requireReady and (agent.pendingFocus or agent.acknowledgedRevision ~= agent.revision
        or agent.lastAckApplied ~= true) then
        return nil, failure('UI_FOCUS_DENIED', 'The owner-focus helper has not acknowledged its current state.')
    end
    return agent
end

local function nextFocusAgentRevision()
    if focusAgentRevisionSerial >= MAXIMUM_SAFE_INTEGER then
        return nil, failure('UI_FOCUS_DENIED', 'The focus-agent revision space is exhausted.')
    end
    focusAgentRevisionSerial = focusAgentRevisionSerial + 1
    return focusAgentRevisionSerial
end

local function wakeFocusAgent(agent)
    if TriggerEvent == nil then
        return nil, failure('UI_FOCUS_DENIED', 'The local focus-agent wakeup channel is unavailable.')
    end
    local delivered = pcall(TriggerEvent, FOCUS_AGENT_WAKEUP_EVENT,
        agent.ownerResource, agent.ownerEpoch, agent.bootGeneration,
        agent.revision, agent.pendingIntent and agent.pendingIntent.generation or 0)
    if not delivered then
        return nil, failure('UI_FOCUS_DENIED', 'The owner-focus helper wakeup failed.')
    end
    return true
end

local function requestOwnerFocus(owner, epoch, keyboard, pointer, allowRecovery)
    local agent, agentError = focusAgentFor(owner, epoch, not allowRecovery)
    if not agent then return nil, agentError end
    if not agent.pendingFocus and agent.appliedKeyboard == keyboard and agent.appliedPointer == pointer
        and agent.desiredKeyboard == keyboard and agent.desiredPointer == pointer then return true end
    local revision, revisionError = nextFocusAgentRevision()
    if not revision then return nil, revisionError end
    agent.revision = revision
    agent.desiredKeyboard = keyboard
    agent.desiredPointer = pointer
    agent.pendingFocus = true
    agent.lastAckApplied = nil
    agent.lastError = nil
    local woke, wakeError = wakeFocusAgent(agent)
    if not woke then
        agent.pendingFocus = false
        agent.lastAckApplied = false
        return nil, wakeError
    end
    if agent.pendingFocus or agent.acknowledgedRevision ~= revision or agent.lastAckApplied ~= true
        or agent.appliedKeyboard ~= keyboard or agent.appliedPointer ~= pointer then
        focusDesynchronized = true
        incrementMetric('ui_runtime_errors')
        markReason('FOCUS_DESYNC')
        return nil, failure('UI_FOCUS_DENIED', 'The owner-focus helper did not acknowledge the exact revision.')
    end
    return true
end

local function dispatchOwnerIntent(lease, intent)
    if INPUT_INTENTS[intent] == nil then return false end
    local agent, agentError = focusAgentFor(lease.ownerResource, lease.ownerEpoch, true)
    if not agent or focusApplied.target ~= 'owner'
        or focusApplied.ownerResource ~= lease.ownerResource
        or focusApplied.ownerEpoch ~= lease.ownerEpoch then
        if agentError ~= nil then incrementMetric('ui_runtime_errors') end
        return false
    end
    if focusAgentIntentSerial >= MAXIMUM_SAFE_INTEGER then
        incrementMetric('ui_runtime_errors')
        markReason('TRANSPORT_DEGRADED', 30000)
        return false
    end
    focusAgentIntentSerial = focusAgentIntentSerial + 1
    local generation = focusAgentIntentSerial
    agent.pendingIntent = {
        generation = generation,
        intent = intent,
        device = 'gamepad',
        focusRevision = agent.revision,
    }
    local woke = wakeFocusAgent(agent)
    if not woke or agent.pendingIntent ~= nil or agent.acknowledgedIntentGeneration ~= generation then
        incrementMetric('ui_runtime_errors')
        markReason('TRANSPORT_DEGRADED', 30000)
        return false
    end
    return true
end

local function removeArrayValue(values, target)
    for index = #values, 1, -1 do
        if values[index] == target then
            table.remove(values, index)
            return true
        end
    end
    return false
end

local function promoteQueuedFocus()
    if topFocusLease() ~= nil or #focusQueue == 0 then return end
    local selectedIndex = nil
    local selectedPriority = -1
    for index, leaseId in ipairs(focusQueue) do
        local lease = focusLeases[leaseId]
        if lease ~= nil and lease.priorityValue > selectedPriority then
            selectedIndex = index
            selectedPriority = lease.priorityValue
        end
    end
    if selectedIndex == nil then
        focusQueue = {}
        return
    end
    local leaseId = table.remove(focusQueue, selectedIndex)
    local lease = focusLeases[leaseId]
    if lease ~= nil then
        lease.state = 'active'
        focusStack[#focusStack + 1] = leaseId
    end
end

syncFocus = function()
    local top = topFocusLease()
    local mode = top and FOCUS_MODES[top.mode] or nil
    local keyboard = mode and mode.keyboard or false
    local pointer = mode and mode.pointer or false
    local desiredTarget = 'none'
    if top ~= nil and top.sharedSurfaceLease and (keyboard or pointer) then
        desiredTarget = 'shared'
    elseif top ~= nil and not top.sharedSurfaceLease and (keyboard or pointer) then
        desiredTarget = 'owner'
    end

    if focusApplied.target == 'owner' and (desiredTarget ~= 'owner'
        or focusApplied.ownerResource ~= (top and top.ownerResource or nil)
        or focusApplied.ownerEpoch ~= (top and top.ownerEpoch or nil)
        or focusApplied.keyboard ~= keyboard or focusApplied.pointer ~= pointer) then
        local released, releaseError = requestOwnerFocus(
            focusApplied.ownerResource, focusApplied.ownerEpoch, false, false)
        if not released then return nil, releaseError end
        focusApplied = { keyboard = false, pointer = false, target = 'none' }
    end

    if focusApplied.target == 'shared' and (desiredTarget ~= 'shared'
        or focusApplied.keyboard ~= keyboard or focusApplied.pointer ~= pointer) then
        local released, releaseError = applyNativeFocus(false, false)
        if not released then return nil, releaseError end
    end

    if desiredTarget == 'shared' then
        local applied, applyError = applyNativeFocus(keyboard, pointer)
        if not applied then return nil, applyError end
    elseif desiredTarget == 'owner' then
        local applied, applyError = requestOwnerFocus(top.ownerResource, top.ownerEpoch, keyboard, pointer)
        if not applied then return nil, applyError end
        focusApplied = {
            keyboard = keyboard,
            pointer = pointer,
            target = 'owner',
            ownerResource = top.ownerResource,
            ownerEpoch = top.ownerEpoch,
        }
        focusDesynchronized = false
        clearReason('FOCUS_DESYNC')
    elseif focusApplied.target ~= 'none' then
        local released, releaseError = applyNativeFocus(false, false)
        if not released then return nil, releaseError end
    end
    if top ~= nil then ensureInputThread() end
    return true
end

local function validFocusOptions(options, allowQueue, allowReservedPriority)
    if options == nil then options = {} end
    if not keysAllowed(options, {
        mode = true, priority = true, conflict = true, reason = true,
    }) then return nil, failure('UI_REQUEST_INVALID', 'Focus options contain unsupported fields.') end
    local mode = options.mode or 'EXCLUSIVE'
    local priority = options.priority or 'NORMAL'
    local conflict = options.conflict or 'DENY'
    local reason = options.reason or 'runtime_request'
    if FOCUS_MODES[mode] == nil or PRIORITY_CLASSES[priority] == nil
        or CONFLICT_POLICIES[conflict] == nil or (conflict == 'QUEUE' and not allowQueue)
        or not boundedText(reason, 160, false) then
        return nil, failure('UI_REQUEST_INVALID', 'Focus options are invalid.')
    end
    if not allowReservedPriority and (priority == 'CRITICAL' or priority == 'SYSTEM') then
        return nil, failure('UI_FOCUS_DENIED', 'CRITICAL and SYSTEM priorities are reserved for the Synex UI runtime.')
    end
    if mode == 'PASSIVE' and priority ~= 'PASSIVE' then priority = 'PASSIVE' end
    return { mode = mode, priority = priority, conflict = conflict, reason = reason }
end

local function ownerLeaseCount(owner)
    local count = 0
    for _, lease in pairs(focusLeases) do
        if lease.ownerResource == owner then count = count + 1 end
    end
    return count
end

local function acquireFocusInternal(owner, epoch, options, allowQueue, sharedSurfaceLease)
    local current, ownerError = ownerCurrent(owner, epoch)
    if not current then return nil, ownerError end
    if not nuiReady then return nil, failure('UI_NOT_READY', 'The NUI runtime has not completed its ready handshake.') end
    if ownerLeaseCount(owner) >= LIMITS.maximumOwnerFocusLeases then
        incrementMetric('ui_focus_denied_total')
        return nil, failure('UI_FOCUS_DENIED', 'The owner reached its focus lease limit.')
    end
    local total = 0
    for _ in pairs(focusLeases) do total = total + 1 end
    if total >= LIMITS.maximumFocusLeases then
        incrementMetric('ui_focus_denied_total')
        return nil, failure('UI_FOCUS_DENIED', 'The runtime reached its focus lease limit.')
    end
    local normalized, optionError = validFocusOptions(options, allowQueue)
    if not normalized then
        incrementMetric('ui_focus_denied_total')
        return nil, optionError
    end
    if not sharedSurfaceLease and normalized.mode ~= 'PASSIVE' then
        for _ in pairs(surfaces) do
            incrementMetric('ui_focus_denied_total')
            return nil, failure('UI_FOCUS_BUSY', 'A shared Synex UI surface currently owns interactive focus.')
        end
        local agent, agentError = focusAgentFor(owner, epoch, true)
        if not agent then
            incrementMetric('ui_focus_denied_total')
            return nil, agentError
        end
    end
    leaseSerial = leaseSerial + 1
    local lease = {
        leaseId = nextIdentifier('lease', owner, leaseSerial),
        ownerResource = owner,
        ownerEpoch = epoch,
        mode = normalized.mode,
        priority = normalized.priority,
        priorityValue = PRIORITY_CLASSES[normalized.priority],
        conflict = normalized.conflict,
        reason = normalized.reason,
        createdAt = nowMilliseconds(),
        state = 'active',
        sharedSurfaceLease = sharedSurfaceLease == true,
    }
    local top = topFocusLease()
    if normalized.mode == 'PASSIVE' then
        focusLeases[lease.leaseId] = lease
    elseif top == nil then
        focusLeases[lease.leaseId] = lease
        focusStack[#focusStack + 1] = lease.leaseId
    elseif top.ownerResource == owner then
        top.state = 'suspended'
        focusLeases[lease.leaseId] = lease
        focusStack[#focusStack + 1] = lease.leaseId
    elseif normalized.conflict == 'QUEUE' then
        lease.state = 'queued'
        focusLeases[lease.leaseId] = lease
        focusQueue[#focusQueue + 1] = lease.leaseId
    elseif normalized.conflict == 'SUSPEND' and lease.priorityValue > top.priorityValue then
        top.state = 'suspended'
        focusLeases[lease.leaseId] = lease
        focusStack[#focusStack + 1] = lease.leaseId
    else
        incrementMetric('ui_focus_denied_total')
        return nil, failure(normalized.conflict == 'DENY' and 'UI_FOCUS_BUSY' or 'UI_FOCUS_DENIED',
            'Another owner holds a conflicting focus lease.', {
                activePriority = top.priority,
                activeMode = top.mode,
            })
    end
    incrementMetric('ui_focus_acquire_total')
    local synchronized, syncError = syncFocus()
    if not synchronized then
        removeArrayValue(focusStack, lease.leaseId)
        removeArrayValue(focusQueue, lease.leaseId)
        focusLeases[lease.leaseId] = nil
        local restored = topFocusLease()
        if restored ~= nil then restored.state = 'active' else promoteQueuedFocus() end
        if not sharedSurfaceLease and normalized.mode ~= 'PASSIVE' then
            requestOwnerFocus(owner, epoch, false, false, true)
        end
        syncFocus()
        incrementMetric('ui_focus_denied_total')
        return nil, syncError or failure('UI_FOCUS_DENIED', 'The focus target could not be applied safely.')
    end
    return publicLease(lease)
end

local function releaseFocusInternal(leaseId, expectedOwner, expectedEpoch)
    if not validIdentifier(leaseId, 160) then
        return nil, failure('UI_FOCUS_LEASE_INVALID', 'The focus lease identifier is invalid.')
    end
    local lease = focusLeases[leaseId]
    if lease == nil or (expectedOwner ~= nil and (lease.ownerResource ~= expectedOwner
        or lease.ownerEpoch ~= expectedEpoch)) then
        return nil, failure('UI_FOCUS_LEASE_INVALID', 'The focus lease does not exist for this owner epoch.')
    end
    local wasTop = focusStack[#focusStack] == leaseId
    removeArrayValue(focusStack, leaseId)
    removeArrayValue(focusQueue, leaseId)
    focusLeases[leaseId] = nil
    if wasTop then
        local restored = topFocusLease()
        if restored ~= nil then restored.state = 'active' else promoteQueuedFocus() end
    elseif topFocusLease() == nil then
        promoteQueuedFocus()
    end
    local synchronized = syncFocus()
    if not synchronized then
        local failedTop = topFocusLease()
        if failedTop ~= nil and not failedTop.sharedSurfaceLease then
            removeArrayValue(focusStack, failedTop.leaseId)
            focusLeases[failedTop.leaseId] = nil
            local restored = topFocusLease()
            if restored ~= nil then restored.state = 'active' else promoteQueuedFocus() end
            syncFocus()
        end
    end
    return true
end

local validateOptions

local function validateOption(option, depth, totals)
    if not keysAllowed(option, {
        id = true, label = true, description = true, disabled = true, danger = true,
        icon = true, shortcut = true, metadata = true, options = true,
    }) or not validIdentifier(option.id, 64) or not boundedText(option.label, 160, false)
        or (option.description ~= nil and not boundedText(option.description, 512, true))
        or (option.disabled ~= nil and type(option.disabled) ~= 'boolean')
        or (option.danger ~= nil and type(option.danger) ~= 'boolean')
        or (option.icon ~= nil and not validIconKey(option.icon))
        or (option.shortcut ~= nil and not boundedText(option.shortcut, 48, false))
        or (option.metadata ~= nil and type(option.metadata) ~= 'table') then return false end
    if option.options ~= nil and not validateOptions(option.options, depth + 1, totals) then return false end
    return true
end

validateOptions = function(options, depth, totals)
    depth = depth or 1
    totals = totals or { items = 0, ids = {} }
    totals.ids = totals.ids or {}
    local length = arrayLength(options, LIMITS.maximumOptions)
    if length == nil or length < 1 or depth > LIMITS.maximumMenuDepth then return false end
    local seen = {}
    for index = 1, length do
        local option = options[index]
        totals.items = totals.items + 1
        if totals.items > LIMITS.maximumMenuItems or totals.ids[option.id]
            or not validateOption(option, depth, totals) or seen[option.id] then return false end
        totals.ids[option.id] = true
        seen[option.id] = true
    end
    return true
end

local function optionsAreFlat(options)
    local length = arrayLength(options, LIMITS.maximumOptions)
    if length == nil then return false end
    for index = 1, length do
        if options[index].options ~= nil then return false end
    end
    return true
end

local function validateField(field)
    if not keysAllowed(field, {
        id = true, type = true, label = true, description = true, value = true,
        placeholder = true, required = true, disabled = true, min = true, max = true,
        step = true, minLength = true, maxLength = true, options = true,
    }) or not validIdentifier(field.id, 64) or not FIELD_TYPES[field.type]
        or not boundedText(field.label, 160, false)
        or (field.description ~= nil and not boundedText(field.description, 512, true))
        or (field.placeholder ~= nil and not boundedText(field.placeholder, 256, true))
        or (field.required ~= nil and type(field.required) ~= 'boolean')
        or (field.disabled ~= nil and type(field.disabled) ~= 'boolean') then return false end
    if field.min ~= nil and (type(field.min) ~= 'number' or field.min ~= field.min
        or field.min == math.huge or field.min == -math.huge) then return false end
    if field.max ~= nil and (type(field.max) ~= 'number' or field.max ~= field.max
        or field.max == math.huge or field.max == -math.huge) then return false end
    if field.min ~= nil and field.max ~= nil and field.min > field.max then return false end
    if field.step ~= nil and (type(field.step) ~= 'number' or field.step <= 0
        or field.step ~= field.step or field.step == math.huge) then return false end
    if field.minLength ~= nil and not integerInRange(field.minLength, 0, LIMITS.maximumStringBytes) then return false end
    if field.maxLength ~= nil and not integerInRange(field.maxLength, 1, LIMITS.maximumStringBytes) then return false end
    if field.minLength ~= nil and field.maxLength ~= nil and field.minLength > field.maxLength then return false end
    local requiresOptions = field.type == 'select' or field.type == 'multi-select' or field.type == 'radio'
    if requiresOptions ~= (field.options ~= nil)
        or (field.options ~= nil and (not validateOptions(field.options) or not optionsAreFlat(field.options))) then return false end
    if field.value ~= nil then
        local valueType = type(field.value)
        if field.type == 'number' or field.type == 'slider' then
            if valueType ~= 'number' or field.value ~= field.value
                or field.value == math.huge or field.value == -math.huge then return false end
        elseif field.type == 'checkbox' or field.type == 'switch' then
            if valueType ~= 'boolean' then return false end
        elseif field.type == 'multi-select' then
            local selected = arrayLength(field.value, LIMITS.maximumOptions)
            if selected == nil then return false end
            for index = 1, selected do
                if not validIdentifier(field.value[index], 64) then return false end
            end
        elseif valueType ~= 'string' or not boundedText(field.value, LIMITS.maximumStringBytes, true) then
            return false
        end
    end
    return true
end

local function validateFields(fields, exactOne)
    local length = arrayLength(fields, LIMITS.maximumFields)
    if length == nil or length < 1 or (exactOne and length ~= 1) then return false end
    local seen = {}
    for index = 1, length do
        local field = fields[index]
        if not validateField(field) or seen[field.id] then return false end
        seen[field.id] = true
    end
    return true
end

local function validateSections(sections)
    local length = arrayLength(sections, LIMITS.maximumSections)
    if length == nil or length < 1 then return false end
    local totals = { items = 0, ids = {} }
    local seenSections = {}
    for index = 1, length do
        local section = sections[index]
        if not keysAllowed(section, { id = true, label = true, items = true })
            or not validIdentifier(section.id, 64) or seenSections[section.id]
            or (section.label ~= nil and not boundedText(section.label, 160, true))
            or not validateOptions(section.items, 1, totals) then return false end
        seenSections[section.id] = true
    end
    return true
end

local function normalizeSurfaceRequest(kind, request)
    local definition = SURFACE_KINDS[kind]
    if definition == nil or type(request) ~= 'table' then
        return nil, nil, failure('UI_REQUEST_INVALID', 'The surface request is invalid.')
    end
    local requestBytes, requestBoundsError = boundedJson(request)
    if not requestBytes then return nil, nil, requestBoundsError end
    local commonKeys = {
        surfaceId = true, title = true, description = true, message = true, tone = true,
        dismissible = true, confirmLabel = true, cancelLabel = true, initialFocus = true,
        timeoutMs = true, focus = true,
    }
    local kindKeys = {
        alert = {},
        confirm = { danger = true },
        input = { fields = true },
        form = { fields = true },
        select = { options = true, multiple = true, searchable = true, placeholder = true },
        menu = { sections = true },
        contextMenu = { sections = true, anchor = true },
    }
    local allowed = {}
    for key in pairs(commonKeys) do allowed[key] = true end
    for key in pairs(kindKeys[kind]) do allowed[key] = true end
    if not keysAllowed(request, allowed) or not boundedText(request.title, 160, false)
        or (request.description ~= nil and not boundedText(request.description, 2048, true))
        or (request.message ~= nil and not boundedText(request.message, 2048, true))
        or (request.description ~= nil and request.message ~= nil)
        or (request.tone ~= nil and not TONES[request.tone])
        or (request.dismissible ~= nil and type(request.dismissible) ~= 'boolean')
        or (request.confirmLabel ~= nil and not boundedText(request.confirmLabel, 96, false))
        or (request.cancelLabel ~= nil and not boundedText(request.cancelLabel, 96, false))
        or (request.initialFocus ~= nil and not validIdentifier(request.initialFocus, 64))
        or (request.surfaceId ~= nil and not validIdentifier(request.surfaceId, 96))
        or (request.timeoutMs ~= nil and not integerInRange(request.timeoutMs,
            LIMITS.minimumTimeoutMs, LIMITS.maximumTimeoutMs)) then
        return nil, nil, failure('UI_REQUEST_INVALID', 'The surface request fields are invalid.')
    end
    if kind == 'confirm' and request.danger ~= nil and type(request.danger) ~= 'boolean' then
        return nil, nil, failure('UI_REQUEST_INVALID', 'The confirmation danger flag is invalid.')
    elseif kind == 'input' and not validateFields(request.fields, true) then
        return nil, nil, failure('UI_REQUEST_INVALID', 'An input surface requires exactly one valid field.')
    elseif kind == 'form' and not validateFields(request.fields, false) then
        return nil, nil, failure('UI_REQUEST_INVALID', 'The form fields are invalid.')
    elseif kind == 'select' then
        if not validateOptions(request.options) or not optionsAreFlat(request.options)
            or (request.multiple ~= nil and type(request.multiple) ~= 'boolean')
            or (request.searchable ~= nil and type(request.searchable) ~= 'boolean')
            or (request.placeholder ~= nil and not boundedText(request.placeholder, 256, true)) then
            return nil, nil, failure('UI_REQUEST_INVALID', 'The select options are invalid.')
        end
    elseif (kind == 'menu' or kind == 'contextMenu') and not validateSections(request.sections) then
        return nil, nil, failure('UI_REQUEST_INVALID', 'The menu sections are invalid.')
    elseif kind == 'contextMenu' then
        if not keysAllowed(request.anchor, { x = true, y = true })
            or type(request.anchor.x) ~= 'number' or request.anchor.x < 0 or request.anchor.x > 1
            or type(request.anchor.y) ~= 'number' or request.anchor.y < 0 or request.anchor.y > 1 then
            return nil, nil, failure('UI_REQUEST_INVALID', 'The context menu anchor is invalid.')
        end
    end
    local focusRequest = request.focus or {
        mode = definition.mode,
        priority = definition.priority,
        conflict = definition.conflict,
        reason = kind,
    }
    local focus, focusError = validFocusOptions(focusRequest, false)
    if not focus then return nil, nil, focusError end
    local payload = cloneJson(request)
    payload.focus = nil
    payload.timeoutMs = nil
    payload.description = payload.description or payload.message
    payload.message = nil
    payload.kind = kind
    payload.tone = payload.tone == 'info' and 'accent' or payload.tone or 'neutral'
    if payload.danger then payload.tone = 'danger' end
    payload.danger = nil
    if payload.dismissible == nil then payload.dismissible = true end
    local bytes, payloadError = boundedJson(payload)
    if not bytes then return nil, nil, payloadError end
    return payload, focus
end

local function validatePreferencesPatch(value)
    if not keysAllowed(value, {
        schemaVersion = true, quality = true, scale = true, density = true,
        reducedMotion = true, reducedTransparency = true, highContrast = true,
        interactionAssist = true,
    }) or (value.schemaVersion ~= nil and value.schemaVersion ~= 1)
        or (value.quality ~= nil and not PREFERENCE_QUALITIES[value.quality])
        or (value.scale ~= nil and not PREFERENCE_SCALES[value.scale])
        or (value.density ~= nil and not PREFERENCE_DENSITIES[value.density])
        or (value.reducedMotion ~= nil and type(value.reducedMotion) ~= 'boolean')
        or (value.reducedTransparency ~= nil and type(value.reducedTransparency) ~= 'boolean')
        or (value.highContrast ~= nil and type(value.highContrast) ~= 'boolean')
        or (value.interactionAssist ~= nil and type(value.interactionAssist) ~= 'boolean') then
        return nil, failure('UI_REQUEST_INVALID', 'The preference values are invalid.')
    end
    local merged = cloneJson(preferences)
    for key, child in pairs(value) do merged[key] = child end
    merged.schemaVersion = 1
    return merged
end

local function savePreferences()
    if SetResourceKvp == nil or json == nil or type(json.encode) ~= 'function' then return false end
    local encoded, serialized = pcall(json.encode, preferences)
    if not encoded or type(serialized) ~= 'string' or #serialized > 2048 then return false end
    return pcall(SetResourceKvp, PREFERENCE_KVP_KEY, serialized)
end

local function updatePreferences(value, persist)
    local merged, preferenceError = validatePreferencesPatch(value)
    if not merged then return nil, preferenceError end
    local changed = false
    for key, candidate in pairs(merged) do
        if preferences[key] ~= candidate then changed = true; break end
    end
    preferences = merged
    if changed then
        preferenceRevision = math.min(MAXIMUM_SAFE_INTEGER, preferenceRevision + 1)
    end
    if persist then savePreferences() end
    if nuiReady then sendEnvelope('preferences:sync', RESOURCE_NAME, runtimeEpoch, 0, cloneJson(preferences)) end
    if notifySignalCapacity ~= nil then notifySignalCapacity(false) end
    return cloneJson(preferences)
end

local function loadPreferences()
    preferences = cloneJson(DEFAULT_PREFERENCES)
    if GetResourceKvpString == nil or json == nil or type(json.decode) ~= 'function' then return end
    local read, serialized = pcall(GetResourceKvpString, PREFERENCE_KVP_KEY)
    if not read or type(serialized) ~= 'string' or #serialized == 0 or #serialized > 2048 then return end
    local decoded, value = pcall(json.decode, serialized)
    if not decoded or type(value) ~= 'table' then return end
    local merged = validatePreferencesPatch(value)
    if merged ~= nil then preferences = merged end
end

local function readScreenMetrics()
    local width, height = GetActualScreenResolution()
    if not integerInRange(width, 320, 16384) or not integerInRange(height, 240, 8192) then
        width, height = 1920, 1080
    end
    local safeZone = GetSafeZoneSize()
    if type(safeZone) ~= 'number' or safeZone ~= safeZone then safeZone = 1.0 end
    safeZone = math.max(0.8, math.min(1.0, safeZone))
    local horizontal = width * (1.0 - safeZone) * 0.5
    local vertical = height * (1.0 - safeZone) * 0.5
    return {
        width = width,
        height = height,
        aspectRatio = width / height,
        safeZone = safeZone,
        safeLeft = horizontal,
        safeRight = horizontal,
        safeTop = vertical,
        safeBottom = vertical,
    }
end

local function adaptiveSignalCapacity()
    local screen = lastScreenMetrics or readScreenMetrics()
    local scale = (preferences.scale or 100) / 100
    local horizontalSpace = math.max(0,
        screen.width - screen.safeLeft - screen.safeRight)
    local narrowBonus = horizontalSpace < SIGNAL_STACK_LAYOUT.narrowWidthPx * scale
        and SIGNAL_STACK_LAYOUT.narrowHeightBonusPx or 0
    local surfaceHeight = (preferences.density == 'compact'
        and SIGNAL_STACK_LAYOUT.compactHeightPx
        or SIGNAL_STACK_LAYOUT.comfortableHeightPx) + narrowBonus
    local topInset = math.max(screen.safeTop, SIGNAL_STACK_LAYOUT.edgeInsetPx * scale)
    local bottomInset = math.max(screen.safeBottom, SIGNAL_STACK_LAYOUT.edgeInsetPx * scale)
    local availableHeight = math.max(0, screen.height - topInset - bottomInset)
    return math.max(1, math.min(LIMITS.maximumVisibleSignals,
        math.floor(availableHeight / (surfaceHeight * scale))))
end

notifySignalCapacity = function(force)
    local subscriber = signalCapacitySubscriber
    if subscriber == nil then return false end
    local capacity = adaptiveSignalCapacity()
    local currentPreferenceRevision = preferenceRevision
    if not force and subscriber.capacity == capacity
        and subscriber.preferenceRevision == currentPreferenceRevision then
        subscriber.pendingCapacity = nil
        subscriber.pendingPreferenceRevision = nil
        return true
    end
    if not force and subscriber.pendingCapacity == capacity
        and subscriber.pendingPreferenceRevision == currentPreferenceRevision then return true end
    local current = ownerCurrent(subscriber.ownerResource, subscriber.ownerEpoch)
    if not current or not isCallable(subscriber.callback) then
        signalCapacitySubscriber = nil
        signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
        return false
    end
    if type(SetTimeout) ~= 'function' then
        signalCapacitySubscriber = nil
        signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
        incrementMetric('ui_runtime_errors')
        markReason('TRANSPORT_DEGRADED', 30000)
        return false
    end
    subscriber.pendingCapacity = capacity
    subscriber.pendingPreferenceRevision = currentPreferenceRevision
    if subscriber.dispatchPending then return true end
    subscriber.dispatchPending = true
    local bindingGeneration = subscriber.bindingGeneration
    SetTimeout(0, function()
        local active = signalCapacitySubscriber
        if active ~= subscriber or active.bindingGeneration ~= bindingGeneration
            or active.ownerResource ~= subscriber.ownerResource
            or active.ownerEpoch ~= subscriber.ownerEpoch then return end
        active.dispatchPending = false
        local pendingCapacity = active.pendingCapacity
        local pendingPreferenceRevision = active.pendingPreferenceRevision
        active.pendingCapacity = nil
        active.pendingPreferenceRevision = nil
        if pendingCapacity == nil or pendingPreferenceRevision == nil then return end
        local ownerActive = ownerCurrent(active.ownerResource, active.ownerEpoch)
        if not ownerActive or not isCallable(active.callback) then
            signalCapacitySubscriber = nil
            signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
            return
        end
        local delivered, accepted = pcall(active.callback, {
            ownerResource = active.ownerResource,
            ownerEpoch = active.ownerEpoch,
            capacity = pendingCapacity,
            preferences = cloneJson(preferences),
        })
        if signalCapacitySubscriber ~= active
            or active.bindingGeneration ~= bindingGeneration then return end
        if not delivered or accepted ~= true then
            signalCapacitySubscriber = nil
            signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
            incrementMetric('ui_runtime_errors')
            markReason('TRANSPORT_DEGRADED', 30000)
            return
        end
        active.capacity = pendingCapacity
        active.preferenceRevision = pendingPreferenceRevision
    end)
    return true
end

local function screenMetricsChanged(current, previous)
    if previous == nil then return true end
    return current.width ~= previous.width or current.height ~= previous.height
        or math.abs(current.safeZone - previous.safeZone) > 0.0001
end

sendEnvelope = function(messageType, owner, epoch, revision, payload)
    if not nuiReady then return nil, failure('UI_NOT_READY', 'The NUI runtime is not ready.') end
    if not GAME_MESSAGE_TYPES[messageType] or not validIdentifier(owner, 64)
        or not integerInRange(epoch, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(revision or 0, 0, MAXIMUM_SAFE_INTEGER) then
        return nil, failure('UI_REQUEST_INVALID', 'The transport envelope metadata is invalid.')
    end
    messageSerial = messageSerial + 1
    local envelope = {
        protocolVersion = PROTOCOL_VERSION,
        messageId = nextIdentifier('message', RESOURCE_NAME, messageSerial),
        type = messageType,
        ownerResource = owner,
        ownerEpoch = epoch,
        revision = revision or 0,
        payload = payload or {},
    }
    local bytes, payloadError = boundedJson(envelope)
    if not bytes then
        transportFailures = transportFailures + 1
        incrementMetric('ui_runtime_errors')
        markReason('TRANSPORT_DEGRADED', 30000)
        return nil, payloadError
    end
    local sent = pcall(SendNUIMessage, envelope)
    if not sent then
        transportFailures = transportFailures + 1
        incrementMetric('ui_runtime_errors')
        markReason('TRANSPORT_DEGRADED', 30000)
        return nil, failure('UI_REQUEST_INVALID', 'The NUI transport rejected the envelope.')
    end
    transportFailures = 0
    clearReason('TRANSPORT_DEGRADED')
    incrementMetric('ui_payload_bytes', bytes)
    return true
end

sendRuntimeSync = function(payload)
    return sendEnvelope('runtime:sync', RESOURCE_NAME, runtimeEpoch, 0, payload)
end

local SIGNAL_KEY_SEPARATOR = '\31'

local function signalKey(owner, signalId)
    return owner .. SIGNAL_KEY_SEPARATOR .. signalId
end

local function finiteNumberInRange(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
        and value >= minimum and value <= maximum
end

local function normalizeSignalRequest(request)
    if type(request) ~= 'table' then
        return nil, failure('UI_REQUEST_INVALID', 'The passive signal descriptor is invalid.')
    end
    local requestBytes, requestBoundsError = boundedJson(request)
    if not requestBytes then return nil, requestBoundsError end
    if not keysAllowed(request, {
        signalId = true, revision = true, kind = true, tone = true, priority = true,
        title = true, message = true, iconKey = true, count = true, progress = true,
        actions = true, createdAt = true, expiresAt = true, position = true,
    }) or not validIdentifier(request.signalId, 96)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or not SIGNAL_KINDS[request.kind] or not SIGNAL_TONES[request.tone]
        or not SIGNAL_PRIORITIES[request.priority] or not SIGNAL_POSITIONS[request.position]
        or not boundedText(request.title, 120, false)
        or (request.message ~= nil and not boundedText(request.message, 720, true))
        or (request.iconKey ~= nil and not validIconKey(request.iconKey))
        or (request.count ~= nil and not integerInRange(request.count, 1, 9999))
        or not integerInRange(request.createdAt, 0, MAXIMUM_SAFE_INTEGER)
        or (request.expiresAt ~= nil and (not integerInRange(request.expiresAt, 0, MAXIMUM_SAFE_INTEGER)
            or request.expiresAt <= request.createdAt)) then
        return nil, failure('UI_REQUEST_INVALID', 'The passive signal fields are invalid.')
    end

    if request.progress ~= nil then
        if not keysAllowed(request.progress, { state = true, mode = true, value = true, maximum = true })
            or not SIGNAL_PROGRESS_STATES[request.progress.state]
            or not SIGNAL_PROGRESS_MODES[request.progress.mode] then
            return nil, failure('UI_REQUEST_INVALID', 'The passive signal progress state is invalid.')
        end
        if request.progress.mode == 'determinate' then
            if not finiteNumberInRange(request.progress.maximum, 0, MAXIMUM_SAFE_INTEGER)
                or request.progress.maximum <= 0
                or not finiteNumberInRange(request.progress.value, 0, request.progress.maximum) then
                return nil, failure('UI_REQUEST_INVALID', 'Determinate progress requires a bounded value and maximum.')
            end
        elseif request.progress.value ~= nil or request.progress.maximum ~= nil then
            return nil, failure('UI_REQUEST_INVALID', 'Indeterminate progress cannot include a value or maximum.')
        end
    end

    local actionCount = 0
    if request.actions ~= nil then
        actionCount = arrayLength(request.actions, LIMITS.maximumSignalActions)
        if actionCount == nil then
            return nil, failure('UI_REQUEST_INVALID', 'The passive signal action hints are invalid.')
        end
        local tokens = {}
        for index = 1, actionCount do
            local action = request.actions[index]
            if not keysAllowed(action, { token = true, label = true, hint = true, style = true })
                or not validIdentifier(action.token, 96) or tokens[action.token]
                or not boundedText(action.label, 64, false)
                or (action.hint ~= nil and not boundedText(action.hint, 24, false))
                or (action.style ~= nil and not SIGNAL_ACTION_STYLES[action.style]) then
                return nil, failure('UI_REQUEST_INVALID', 'A passive signal action hint is invalid.')
            end
            tokens[action.token] = true
        end
    end

    local normalized = cloneJson(request)
    if actionCount == 0 then normalized.actions = nil end
    local bytes, normalizedError = boundedJson(normalized)
    if not bytes then return nil, normalizedError end
    return normalized
end

local function signalPayload(signal, includeOwner)
    local payload = {
        signalId = signal.signalId,
        revision = signal.revision,
        kind = signal.kind,
        tone = signal.tone,
        priority = signal.priority,
        title = signal.title,
        createdAt = signal.createdAt,
        position = signal.position,
    }
    if signal.message ~= nil then payload.message = signal.message end
    if signal.iconKey ~= nil then payload.iconKey = signal.iconKey end
    if signal.count ~= nil then payload.count = signal.count end
    if signal.progress ~= nil then payload.progress = cloneJson(signal.progress) end
    if signal.actions ~= nil then payload.actions = cloneJson(signal.actions) end
    if signal.expiresAt ~= nil then payload.expiresAt = signal.expiresAt end
    if includeOwner then
        payload.ownerResource = signal.ownerResource
        payload.ownerEpoch = signal.ownerEpoch
    end
    return payload
end

local function signalSnapshot(owner, includeVisibility)
    local snapshot = setmetatable({}, decoderArrayMetatable)
    for _, key in ipairs(signalOrder) do
        local signal = signals[key]
        if signal ~= nil and (owner == nil or signal.ownerResource == owner) then
            local payload = signalPayload(signal, owner == nil)
            if includeVisibility then
                payload.visible = browserVisibleSignalGeneration == signalGeneration
                    and browserVisibleSignals[key] == signal.revision
            end
            snapshot[#snapshot + 1] = payload
        end
    end
    return snapshot
end

local function activeSignalCount()
    local count = 0
    for _ in pairs(signals) do count = count + 1 end
    return count
end

local function ownerSignalCount(owner)
    local count = 0
    for _, signal in pairs(signals) do
        if signal.ownerResource == owner then count = count + 1 end
    end
    return count
end

local function trackSignalRevision(key, revision)
    if signalRevisions[key] == nil then signalRevisionOrder[#signalRevisionOrder + 1] = key end
    signalRevisions[key] = revision
    while #signalRevisionOrder > LIMITS.maximumSignalRevisionFences do
        local removed = false
        for index, candidate in ipairs(signalRevisionOrder) do
            if signals[candidate] == nil then
                signalRevisions[candidate] = nil
                table.remove(signalRevisionOrder, index)
                removed = true
                break
            end
        end
        if not removed then break end
    end
end

local function nextSignalGeneration()
    if signalGeneration >= MAXIMUM_SAFE_INTEGER then
        return nil, failure('UI_REQUEST_INVALID', 'The passive signal generation is exhausted.')
    end
    signalGeneration = signalGeneration + 1
    return signalGeneration
end

local function upsertSignalInternal(owner, epoch, request)
    local normalized, requestError = normalizeSignalRequest(request)
    if not normalized then return nil, requestError end
    local key = signalKey(owner, normalized.signalId)
    local current = signals[key]
    local previousRevision = signalRevisions[key] or 0
    if normalized.revision <= previousRevision then
        return nil, failure('UI_REQUEST_STALE', 'The passive signal revision is stale.', {
            signalId = normalized.signalId,
            currentRevision = previousRevision,
        })
    end
    if current == nil and (activeSignalCount() >= LIMITS.maximumSignals
        or ownerSignalCount(owner) >= LIMITS.maximumOwnerSignals) then
        markReason('REQUEST_PRESSURE', 5000)
        return nil, failure('UI_SURFACE_CONFLICT', 'The passive signal capacity is exhausted.')
    end
    local generation, generationError = nextSignalGeneration()
    if not generation then return nil, generationError end
    normalized.ownerResource = owner
    normalized.ownerEpoch = epoch
    signals[key] = normalized
    if current == nil then
        signalOrder[#signalOrder + 1] = key
        metrics.ui_active_signals = metrics.ui_active_signals + 1
    end
    trackSignalRevision(key, normalized.revision)
    incrementMetric('ui_signal_upsert_total')
    local delivered = false
    if nuiReady then
        local payload = signalPayload(normalized, false)
        payload.generation = generation
        delivered = sendEnvelope('signal:upsert', owner, epoch,
            normalized.revision, payload) == true
    end
    ensureInputThread()
    return {
        generation = generation,
        signal = signalPayload(normalized, false),
        delivered = delivered,
    }, nil
end

local function removeSignalInternal(owner, epoch, signalId, revision)
    if not validIdentifier(signalId, 96) or not integerInRange(revision, 1, MAXIMUM_SAFE_INTEGER) then
        return nil, failure('UI_REQUEST_INVALID', 'The passive signal removal is invalid.')
    end
    local key = signalKey(owner, signalId)
    local previousRevision = signalRevisions[key] or 0
    if revision <= previousRevision then
        return nil, failure('UI_REQUEST_STALE', 'The passive signal removal revision is stale.', {
            signalId = signalId,
            currentRevision = previousRevision,
        })
    end
    local generation, generationError = nextSignalGeneration()
    if not generation then return nil, generationError end
    local removed = signals[key] ~= nil
    if removed then
        signals[key] = nil
        removeArrayValue(signalOrder, key)
        metrics.ui_active_signals = math.max(0, metrics.ui_active_signals - 1)
    end
    trackSignalRevision(key, revision)
    incrementMetric('ui_signal_remove_total')
    if nuiReady then
        sendEnvelope('signal:remove', owner, epoch, revision, {
            signalId = signalId,
            generation = generation,
        })
    end
    return {
        generation = generation,
        signalId = signalId,
        revision = revision,
        removed = removed,
    }, nil
end

local function clearOwnerSignals(owner, epoch)
    local prefix = owner .. SIGNAL_KEY_SEPARATOR
    local changed = false
    for index = #signalOrder, 1, -1 do
        local key = signalOrder[index]
        local signal = signals[key]
        if signal ~= nil and signal.ownerResource == owner and (epoch == nil or signal.ownerEpoch == epoch) then
            signals[key] = nil
            table.remove(signalOrder, index)
            metrics.ui_active_signals = math.max(0, metrics.ui_active_signals - 1)
            incrementMetric('ui_signal_remove_total')
            changed = true
        end
    end
    for index = #signalRevisionOrder, 1, -1 do
        local key = signalRevisionOrder[index]
        if key:sub(1, #prefix) == prefix then
            signalRevisions[key] = nil
            table.remove(signalRevisionOrder, index)
        end
    end
    if changed then
        local generation = nextSignalGeneration()
        if generation ~= nil and nuiReady then
            sendRuntimeSync({
                signals = signalSnapshot(nil),
                signalGeneration = generation,
            })
        end
    end
    return changed
end

function interactionRuntime.normalizeBinding(value)
    if not keysAllowed(value, { keyboard = true, gamepad = true, mouse = true })
        or not boundedText(value.keyboard, 24, false)
        or not boundedText(value.gamepad, 24, false)
        or (value.mouse ~= nil and not boundedText(value.mouse, 24, false)) then return nil end
    return cloneJson(value)
end

function interactionRuntime.normalizeRequest(request)
    if type(request) ~= 'table' then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction descriptor is invalid.')
    end
    local requestBytes, requestBoundsError = boundedJson(request)
    if not requestBytes then return nil, requestBoundsError end
    if not keysAllowed(request, {
        interactionId = true, revision = true, mode = true, label = true,
        targetLabel = true, projection = true, intents = true, selectedIntentId = true,
        moreCount = true, pointer = true, input = true, progress = true,
        cancellable = true,
    }) or not validIdentifier(request.interactionId, 96)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or not interactionRuntime.modes[request.mode]
        or not boundedText(request.label, 120, false)
        or (request.targetLabel ~= nil and not boundedText(request.targetLabel, 80, false))
        or type(request.pointer) ~= 'boolean' or type(request.cancellable) ~= 'boolean'
        or (request.selectedIntentId ~= nil and not validIdentifier(request.selectedIntentId, 96))
        or (request.moreCount ~= nil and not integerInRange(request.moreCount, 0, 99)) then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction descriptor fields are invalid.')
    end
    if request.projection ~= nil and (not keysAllowed(request.projection, {
        visible = true, behindCamera = true, x = true, y = true,
    }) or type(request.projection.visible) ~= 'boolean'
        or type(request.projection.behindCamera) ~= 'boolean'
        or not finiteNumberInRange(request.projection.x, 0, 1)
        or not finiteNumberInRange(request.projection.y, 0, 1)) then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction projection is invalid.')
    end
    if not keysAllowed(request.input, { primary = true, more = true, cancel = true }) then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction input hints are invalid.')
    end
    local primary = request.input.primary ~= nil and interactionRuntime.normalizeBinding(request.input.primary) or nil
    local more = request.input.more ~= nil and interactionRuntime.normalizeBinding(request.input.more) or nil
    local cancel = request.input.cancel ~= nil and interactionRuntime.normalizeBinding(request.input.cancel) or nil
    if (request.input.primary ~= nil and primary == nil)
        or (request.input.more ~= nil and more == nil)
        or (request.input.cancel ~= nil and cancel == nil) then
        return nil, failure('UI_REQUEST_INVALID', 'An interaction input binding is invalid.')
    end
    local intentCount = arrayLength(request.intents, LIMITS.maximumInteractionIntents)
    if intentCount == nil then
        return nil, failure('UI_REQUEST_INVALID', 'The relevant interaction intents are not bounded.')
    end
    local intentIds, enabledIds = {}, {}
    for index = 1, intentCount do
        local intent = request.intents[index]
        if not keysAllowed(intent, {
            intentId = true, label = true, description = true, iconKey = true, disabled = true,
        }) or not validIdentifier(intent.intentId, 96) or intentIds[intent.intentId]
            or not boundedText(intent.label, 96, false)
            or (intent.description ~= nil and not boundedText(intent.description, 180, false))
            or (intent.iconKey ~= nil and not validIconKey(intent.iconKey))
            or (intent.disabled ~= nil and type(intent.disabled) ~= 'boolean') then
            return nil, failure('UI_REQUEST_INVALID', 'A relevant interaction intent is invalid.')
        end
        intentIds[intent.intentId] = true
        if intent.disabled ~= true then enabledIds[intent.intentId] = true end
    end
    local progress = nil
    if request.progress ~= nil then
        if not keysAllowed(request.progress, {
            mode = true, value = true, maximum = true, elapsedMs = true, durationMs = true,
        }) or not interactionRuntime.progressModes[request.progress.mode] then
            return nil, failure('UI_REQUEST_INVALID', 'The interaction progress is invalid.')
        end
        if request.progress.mode == 'determinate' then
            if request.progress.elapsedMs ~= nil or request.progress.durationMs ~= nil
                or not finiteNumberInRange(request.progress.maximum, 0, MAXIMUM_SAFE_INTEGER)
                or request.progress.maximum <= 0
                or not finiteNumberInRange(request.progress.value, 0, request.progress.maximum) then
                return nil, failure('UI_REQUEST_INVALID', 'Determinate interaction progress is invalid.')
            end
        elseif request.progress.mode == 'timed' then
            if request.progress.value ~= nil or request.progress.maximum ~= nil
                or not integerInRange(request.progress.durationMs, 1, LIMITS.maximumInteractionDurationMs)
                or not integerInRange(request.progress.elapsedMs, 0, request.progress.durationMs) then
                return nil, failure('UI_REQUEST_INVALID', 'Timed interaction progress is invalid.')
            end
        elseif request.progress.value ~= nil or request.progress.maximum ~= nil
            or request.progress.elapsedMs ~= nil or request.progress.durationMs ~= nil then
            return nil, failure('UI_REQUEST_INVALID', 'Indeterminate interaction progress cannot contain values.')
        end
        progress = cloneJson(request.progress)
    end

    local moreCount = request.moreCount or 0
    if request.mode == 'cue' then
        if intentCount ~= 1 or request.pointer or request.cancellable or progress ~= nil
            or primary == nil or cancel ~= nil or (moreCount > 0) ~= (more ~= nil)
            or (request.selectedIntentId ~= nil
                and request.selectedIntentId ~= request.intents[1].intentId) then
            return nil, failure('UI_REQUEST_INVALID', 'The intent cue contract is invalid.')
        end
    elseif request.mode == 'bloom' then
        if intentCount < 2 or request.moreCount ~= nil or progress ~= nil
            or primary == nil or more ~= nil or cancel == nil or not request.cancellable
            or request.selectedIntentId == nil or not enabledIds[request.selectedIntentId] then
            return nil, failure('UI_REQUEST_INVALID', 'The action bloom contract is invalid.')
        end
    elseif intentCount ~= 0 or request.selectedIntentId ~= nil or request.moreCount ~= nil
        or request.pointer or progress == nil or primary ~= nil or more ~= nil
        or request.cancellable ~= (cancel ~= nil) then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction progress contract is invalid.')
    end

    local normalized = cloneJson(request)
    normalized.input = {}
    if primary ~= nil then normalized.input.primary = primary end
    if more ~= nil then normalized.input.more = more end
    if cancel ~= nil then normalized.input.cancel = cancel end
    if progress ~= nil then normalized.progress = progress end
    if request.mode == 'progress' then
        normalized.intents = setmetatable({}, decoderArrayMetatable)
    end
    return normalized
end

function interactionRuntime.payload(value, includeOwner)
    if value == nil then return nil end
    local payload = {
        interactionId = value.interactionId,
        revision = value.revision,
        mode = value.mode,
        label = value.label,
        intents = cloneJson(value.intents),
        pointer = value.pointer,
        input = cloneJson(value.input),
        cancellable = value.cancellable,
    }
    if value.targetLabel ~= nil then payload.targetLabel = value.targetLabel end
    if value.projection ~= nil then payload.projection = cloneJson(value.projection) end
    if value.selectedIntentId ~= nil then payload.selectedIntentId = value.selectedIntentId end
    if value.moreCount ~= nil then payload.moreCount = value.moreCount end
    if value.progress ~= nil then payload.progress = cloneJson(value.progress) end
    if includeOwner then
        payload.ownerResource = value.ownerResource
        payload.ownerEpoch = value.ownerEpoch
    end
    return payload
end

function interactionRuntime.trackRevision(interactionId, revision)
    if interactionRuntime.revisions[interactionId] == nil then
        interactionRuntime.revisionOrder[#interactionRuntime.revisionOrder + 1] = interactionId
    end
    interactionRuntime.revisions[interactionId] = revision
    while #interactionRuntime.revisionOrder > LIMITS.maximumInteractionRevisionFences do
        local candidate = table.remove(interactionRuntime.revisionOrder, 1)
        if interactionRuntime.active == nil or interactionRuntime.active.interactionId ~= candidate then
            interactionRuntime.revisions[candidate] = nil
        else
            interactionRuntime.revisionOrder[#interactionRuntime.revisionOrder + 1] = candidate
        end
    end
end

function interactionRuntime.nextGeneration()
    if interactionRuntime.generation >= MAXIMUM_SAFE_INTEGER then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction generation is exhausted.')
    end
    interactionRuntime.generation = interactionRuntime.generation + 1
    return interactionRuntime.generation
end

function interactionRuntime.upsert(owner, epoch, request)
    local normalized, requestError = interactionRuntime.normalizeRequest(request)
    if not normalized then return nil, requestError end
    local previousRevision = interactionRuntime.revisions[normalized.interactionId] or 0
    if normalized.revision <= previousRevision then
        return nil, failure('UI_REQUEST_STALE', 'The interaction revision is stale.', {
            interactionId = normalized.interactionId,
            currentRevision = previousRevision,
        })
    end

    local previous = interactionRuntime.active
    local reuseFocus = previous ~= nil and previous.ownerResource == owner
        and previous.ownerEpoch == epoch and previous.focusLeaseId ~= nil
        and normalized.mode == 'bloom' and normalized.pointer
    local focusLease = reuseFocus and focusLeases[previous.focusLeaseId] or nil
    if normalized.mode == 'bloom' and normalized.pointer and focusLease == nil then
        local acquired, focusError = acquireFocusInternal(owner, epoch, {
            mode = 'EXCLUSIVE', priority = 'NORMAL', conflict = 'DENY',
            reason = 'interaction_bloom',
        }, false, true)
        if not acquired then return nil, focusError end
        focusLease = acquired
    end
    local generation, generationError = interactionRuntime.nextGeneration()
    if not generation then
        if focusLease ~= nil and not reuseFocus then
            releaseFocusInternal(focusLease.leaseId, owner, epoch)
        end
        return nil, generationError
    end
    normalized.ownerResource = owner
    normalized.ownerEpoch = epoch
    normalized.focusLeaseId = focusLease and focusLease.leaseId or nil
    normalized.actionPending = false
    interactionRuntime.active = normalized
    if previous ~= nil and previous.focusLeaseId ~= nil
        and previous.focusLeaseId ~= normalized.focusLeaseId then
        releaseFocusInternal(previous.focusLeaseId, previous.ownerResource, previous.ownerEpoch)
    end
    interactionRuntime.trackRevision(normalized.interactionId, normalized.revision)
    metrics.ui_active_interactions = 1
    incrementMetric('ui_interaction_upsert_total')
    local delivered = false
    if nuiReady then
        local payload = interactionRuntime.payload(normalized, false)
        payload.generation = generation
        delivered = sendEnvelope('interaction:upsert', owner, epoch,
            normalized.revision, payload) == true
    end
    ensureInputThread()
    return {
        generation = generation,
        interaction = interactionRuntime.payload(normalized, false),
        delivered = delivered,
        focusLeaseId = normalized.focusLeaseId,
    }, nil
end

function interactionRuntime.remove(owner, epoch, interactionId, revision)
    if not validIdentifier(interactionId, 96)
        or not integerInRange(revision, 1, MAXIMUM_SAFE_INTEGER) then
        return nil, failure('UI_REQUEST_INVALID', 'The interaction removal is invalid.')
    end
    local previousRevision = interactionRuntime.revisions[interactionId] or 0
    if revision <= previousRevision then
        return nil, failure('UI_REQUEST_STALE', 'The interaction removal revision is stale.', {
            interactionId = interactionId,
            currentRevision = previousRevision,
        })
    end
    local generation, generationError = interactionRuntime.nextGeneration()
    if not generation then return nil, generationError end
    local removed = interactionRuntime.active ~= nil and interactionRuntime.active.ownerResource == owner
        and interactionRuntime.active.ownerEpoch == epoch
        and interactionRuntime.active.interactionId == interactionId
    if removed then
        local focusLeaseId = interactionRuntime.active.focusLeaseId
        interactionRuntime.active = nil
        metrics.ui_active_interactions = 0
        if focusLeaseId ~= nil then releaseFocusInternal(focusLeaseId, owner, epoch) end
    end
    interactionRuntime.trackRevision(interactionId, revision)
    incrementMetric('ui_interaction_remove_total')
    if nuiReady then
        sendEnvelope('interaction:remove', owner, epoch, revision, {
            interactionId = interactionId,
            generation = generation,
        })
    end
    return {
        generation = generation,
        interactionId = interactionId,
        revision = revision,
        removed = removed,
    }, nil
end

function interactionRuntime.clearOwner(owner, epoch)
    if interactionRuntime.active == nil or interactionRuntime.active.ownerResource ~= owner
        or (epoch ~= nil and interactionRuntime.active.ownerEpoch ~= epoch) then return false end
    local interactionId = interactionRuntime.active.interactionId
    local revision = math.min(MAXIMUM_SAFE_INTEGER, interactionRuntime.active.revision + 1)
    local focusLeaseId = interactionRuntime.active.focusLeaseId
    interactionRuntime.active = nil
    metrics.ui_active_interactions = 0
    if focusLeaseId ~= nil and focusLeases[focusLeaseId] ~= nil then
        releaseFocusInternal(focusLeaseId, owner, epoch)
    end
    local generation = interactionRuntime.nextGeneration()
    if generation ~= nil then
        interactionRuntime.trackRevision(interactionId, revision)
        if nuiReady then
            sendEnvelope('interaction:remove', owner, epoch, revision, {
                interactionId = interactionId,
                generation = generation,
            })
        end
    end
    incrementMetric('ui_interaction_remove_total')
    return true
end

local function activeSurfaceCount()
    local count = 0
    for _ in pairs(surfaces) do count = count + 1 end
    return count
end

local function sampleAndSendScreenMetrics(force)
    local now = nowMilliseconds()
    if not force and now - lastScreenSampleAt < 500 then return end
    lastScreenSampleAt = now
    local current = readScreenMetrics()
    if force or screenMetricsChanged(current, lastScreenMetrics) then
        lastScreenMetrics = current
        sendRuntimeSync({
            screen = cloneJson(current),
        })
        notifySignalCapacity(false)
    end
end

local function setActiveInputDevice(device)
    if not INPUT_DEVICES[device] or activeInputDevice == device then return false end
    activeInputDevice = device
    return true
end

ensureInputThread = function()
    if inputThreadRunning or not runtimeRunning then return end
    local createThread = CreateThread or (Citizen and Citizen.CreateThread)
    local wait = Wait or (Citizen and Citizen.Wait)
    if createThread == nil or wait == nil then return end
    inputThreadRunning = true
    createThread(function()
        while runtimeRunning do
            local top = topFocusLease()
            local surfaceCount = activeSurfaceCount()
            local signalCount = activeSignalCount()
            local interactionCount = interactionRuntime.active ~= nil and 1 or 0
            if top == nil and surfaceCount == 0 and signalCount == 0
                and interactionCount == 0 then break end
            if top ~= nil and top.mode ~= 'PASSIVE' then
                local usingKeyboard = IsUsingKeyboard(0)
                if not usingKeyboard then setActiveInputDevice('gamepad') end
                for intent, control in pairs(INPUT_INTENTS) do
                    DisableControlAction(0, control, true)
                    if IsDisabledControlJustPressed(0, control) then
                        setActiveInputDevice('gamepad')
                        if top.sharedSurfaceLease then
                            sendEnvelope('input:intent', top.ownerResource, top.ownerEpoch, 0, {
                                intent = intent,
                                device = 'gamepad',
                            })
                        else
                            dispatchOwnerIntent(top, intent)
                        end
                    end
                end
                sampleAndSendScreenMetrics(false)
                wait(0)
            else
                if signalCount > 0 or interactionCount > 0 then
                    local detectedDevice = IsUsingKeyboard(0) and 'keyboard' or 'gamepad'
                    if setActiveInputDevice(detectedDevice) and nuiReady then
                        sendRuntimeSync({ inputDevice = activeInputDevice })
                    end
                end
                sampleAndSendScreenMetrics(false)
                wait(250)
            end
        end
        inputThreadRunning = false
        if runtimeRunning and (topFocusLease() ~= nil or activeSurfaceCount() > 0
            or activeSignalCount() > 0 or interactionRuntime.active ~= nil) then
            ensureInputThread()
        end
    end)
end

local function resolveWaiter(waiter, completion)
    if waiter == nil then return end
    local resolved = pcall(function() waiter:resolve(completion) end)
    if not resolved then incrementMetric('ui_runtime_errors') end
end

finishSurface = function(surface, completion, notifyBrowser)
    if surface == nil or surface.state == 'closed' then return false end
    surface.state = 'closed'
    pendingRequests[surface.requestId] = nil
    surfaces[surface.surfaceId] = nil
    removeArrayValue(surfaceOrder, surface.surfaceId)
    metrics.ui_active_surfaces = math.max(0, metrics.ui_active_surfaces - 1)
    incrementMetric('ui_surface_close_total')
    releaseFocusInternal(surface.focusLeaseId, surface.ownerResource, surface.ownerEpoch)
    if notifyBrowser and nuiReady then
        sendEnvelope('surface:close', surface.ownerResource, surface.ownerEpoch,
            surface.revision + 1, {
                requestId = surface.requestId,
                instanceId = surface.instanceId,
                surfaceId = surface.surfaceId,
                reason = completion.status or (completion.error and completion.error.code) or 'cancelled',
            })
    end
    resolveWaiter(surface.waiter, completion)
    return true
end

local function ownerSurfaceCount(owner)
    local count = 0
    for _, surface in pairs(surfaces) do
        if surface.ownerResource == owner then count = count + 1 end
    end
    return count
end

local function openSurfaceAndAwait(owner, epoch, kind, request)
    local current, ownerError = ownerCurrent(owner, epoch)
    if not current then return nil, ownerError end
    if not nuiReady then return nil, failure('UI_NOT_READY', 'The NUI runtime has not completed its ready handshake.') end
    if promise == nil or promise.new == nil or Citizen == nil or Citizen.Await == nil then
        return nil, failure('UI_REQUEST_INVALID', 'The Lua await runtime is unavailable.')
    end
    local pendingCount = 0
    for _ in pairs(pendingRequests) do pendingCount = pendingCount + 1 end
    if pendingCount >= LIMITS.maximumPendingRequests or activeSurfaceCount() >= LIMITS.maximumSurfaces
        or ownerSurfaceCount(owner) >= LIMITS.maximumOwnerSurfaces then
        markReason('REQUEST_PRESSURE', 5000)
        return nil, failure('UI_SURFACE_CONFLICT', 'The runtime surface capacity is exhausted.')
    end
    local payload, focus, requestError = normalizeSurfaceRequest(kind, request)
    if not payload then return nil, requestError end
    surfaceSerial = surfaceSerial + 1
    local surfaceId = payload.surfaceId or nextIdentifier('surface', owner, surfaceSerial)
    if surfaces[surfaceId] ~= nil then
        return nil, failure('UI_SURFACE_CONFLICT', 'The surface identifier is already active.')
    end
    focus.reason = focus.reason or kind
    local lease, focusError = acquireFocusInternal(owner, epoch, focus, false, true)
    if not lease then return nil, focusError end
    requestSerial = requestSerial + 1
    local requestId = nextIdentifier('request', owner, requestSerial)
    local instanceId = nextIdentifier('instance', owner, requestSerial)
    local created, waiter = pcall(promise.new)
    if not created or waiter == nil then
        releaseFocusInternal(lease.leaseId, owner, epoch)
        return nil, failure('UI_REQUEST_INVALID', 'The Lua promise runtime could not create a request waiter.')
    end
    local surface = {
        surfaceId = surfaceId,
        requestId = requestId,
        instanceId = instanceId,
        ownerResource = owner,
        ownerEpoch = epoch,
        kind = kind,
        layer = SURFACE_KINDS[kind].layer,
        focusLeaseId = lease.leaseId,
        revision = 1,
        state = 'open',
        createdAt = nowMilliseconds(),
        waiter = waiter,
    }
    payload.surfaceId = surfaceId
    payload.requestId = requestId
    payload.instanceId = instanceId
    surfaces[surfaceId] = surface
    surfaceOrder[#surfaceOrder + 1] = surfaceId
    pendingRequests[requestId] = surface
    metrics.ui_active_surfaces = metrics.ui_active_surfaces + 1
    incrementMetric('ui_surface_open_total')
    incrementMetric('ui_request_total')
    local sent, sendError = sendEnvelope('surface:open', owner, epoch, surface.revision, payload)
    if not sent then
        finishSurface(surface, { error = sendError }, false)
        return nil, sendError
    end
    ensureInputThread()
    local timeoutMs = request.timeoutMs or LIMITS.defaultTimeoutMs
    SetTimeout(timeoutMs, function()
        local pending = pendingRequests[requestId]
        if pending ~= surface or pending.revision ~= 1 then return end
        incrementMetric('ui_request_timeout_total')
        finishSurface(surface, {
            status = 'timeout',
            error = failure('UI_REQUEST_TIMEOUT', 'The UI request timed out.', { timeoutMs = timeoutMs }),
        }, true)
    end)
    local awaited, completion = pcall(Citizen.Await, waiter)
    if not awaited then
        finishSurface(surface, {
            status = 'cancelled',
            error = failure('UI_REQUEST_CANCELLED', 'The UI request await operation failed safely.'),
        }, true)
        return nil, failure('UI_REQUEST_CANCELLED', 'The UI request await operation failed safely.')
    end
    if type(completion) ~= 'table' then
        if surfaces[surface.surfaceId] == surface then
            finishSurface(surface, {
                status = 'cancelled',
                error = failure('UI_REQUEST_CANCELLED', 'The UI request ended without a completion value.'),
            }, true)
        end
        return nil, failure('UI_REQUEST_CANCELLED', 'The UI request ended without a completion value.')
    end
    if completion.error ~= nil then return nil, completion.error end
    return { status = completion.status, data = completion.data }, nil
end

local function actionStatus(surface, action)
    local actions = {
        alert = { confirmed = 'confirmed', cancelled = 'cancelled' },
        confirm = { confirmed = 'confirmed', cancelled = 'cancelled' },
        input = { confirmed = 'confirmed', cancelled = 'cancelled' },
        form = { confirmed = 'confirmed', cancelled = 'cancelled' },
        select = { selected = 'confirmed', confirmed = 'confirmed', cancelled = 'cancelled' },
        menu = { selected = 'confirmed', cancelled = 'cancelled' },
        contextMenu = { selected = 'confirmed', cancelled = 'cancelled' },
    }
    return actions[surface.kind] and actions[surface.kind][action] or nil
end

local function consumeCallbackToken(route)
    local policy = CALLBACK_POLICIES[route]
    if policy == nil then return false end
    local now = nowMilliseconds()
    local bucket = callbackBuckets[route]
    if bucket == nil then
        bucket = { tokens = policy.capacity, updatedAt = now }
        callbackBuckets[route] = bucket
    else
        local elapsed = math.max(0, now - bucket.updatedAt)
        bucket.tokens = math.min(policy.capacity,
            bucket.tokens + elapsed * policy.refillPerSecond / 1000)
        bucket.updatedAt = now
    end
    if bucket.tokens < 1 then return false end
    bucket.tokens = bucket.tokens - 1
    return true
end

local function success(data)
    return { ok = true, data = data or {} }
end

local function rejected(errorValue)
    return { ok = false, error = errorValue }
end

local function registerNuiRoute(route, handler)
    RegisterNuiCallback(route, function(request, callback)
        local replied = false
        local function reply(response)
            if replied then
                incrementMetric('ui_runtime_errors')
                return
            end
            replied = true
            local delivered = pcall(callback, response)
            if not delivered then incrementMetric('ui_runtime_errors') end
        end
        local bytes, payloadError = boundedJson(request, true)
        if not bytes then
            incrementMetric('ui_runtime_errors')
            reply(rejected(payloadError))
            return
        end
        incrementMetric('ui_payload_bytes', bytes)
        local canonicalRequest, canonicalError = canonicalizeNuiJson(request)
        if canonicalRequest == nil then
            incrementMetric('ui_runtime_errors')
            reply(rejected(canonicalError))
            return
        end
        if not consumeCallbackToken(route) then
            reply(rejected(failure('UI_REQUEST_INVALID', 'The NUI callback rate limit was exceeded.')))
            return
        end
        local invoked, response = pcall(handler, canonicalRequest)
        if not invoked then
            incrementMetric('ui_runtime_errors')
            markReason('TRANSPORT_DEGRADED', 30000)
            reply(rejected(failure('UI_REQUEST_INVALID', 'The NUI callback failed safely.')))
            return
        end
        reply(response or success())
    end)
end

local function resetBrowserRuntime(code)
    local closing = {}
    for _, surfaceId in ipairs(surfaceOrder) do closing[#closing + 1] = surfaceId end
    for _, surfaceId in ipairs(closing) do
        local surface = surfaces[surfaceId]
        if surface ~= nil then
            finishSurface(surface, {
                status = 'cancelled',
                error = failure(code or 'UI_REQUEST_CANCELLED', 'The NUI runtime was reloaded.'),
            }, false)
        end
    end
    focusLeases = {}
    focusStack = {}
    focusQueue = {}
    syncFocus()
    activeInputDevice = 'keyboard'
    interactionRuntime.active = nil
    metrics.ui_active_interactions = 0
end

cleanupOwner = function(owner, epoch, disposition)
    local closing = {}
    for _, surfaceId in ipairs(surfaceOrder) do
        local surface = surfaces[surfaceId]
        if surface ~= nil and surface.ownerResource == owner
            and (epoch == nil or surface.ownerEpoch == epoch) then closing[#closing + 1] = surfaceId end
    end
    local changed = #closing > 0
    for _, surfaceId in ipairs(closing) do
        local surface = surfaces[surfaceId]
        if surface ~= nil then
            if disposition == 'ownerStopped' then
                finishSurface(surface, {
                    status = 'ownerStopped',
                    error = failure('UI_OWNER_STOPPED', 'The owner resource stopped while the UI request was active.'),
                }, true)
            else
                finishSurface(surface, { status = disposition or 'cancelled' }, true)
            end
        end
    end
    local leases = {}
    for leaseId, lease in pairs(focusLeases) do
        if lease.ownerResource == owner and (epoch == nil or lease.ownerEpoch == epoch) then
            leases[#leases + 1] = leaseId
        end
    end
    if #leases > 0 then changed = true end
    for _, leaseId in ipairs(leases) do releaseFocusInternal(leaseId) end
    if clearOwnerSignals(owner, epoch) then changed = true end
    if interactionRuntime.clearOwner(owner, epoch) then changed = true end
    if interactionRuntime.actionSubscriber ~= nil
        and interactionRuntime.actionSubscriber.ownerResource == owner
        and (epoch == nil or interactionRuntime.actionSubscriber.ownerEpoch == epoch) then
        interactionRuntime.actionSubscriber = nil
        interactionRuntime.actionBindingGeneration = interactionRuntime.actionBindingGeneration + 1
        changed = true
    end
    if signalCapacitySubscriber ~= nil
        and signalCapacitySubscriber.ownerResource == owner
        and (epoch == nil or signalCapacitySubscriber.ownerEpoch == epoch) then
        signalCapacitySubscriber = nil
        signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
        changed = true
    end
    if changed then incrementMetric('ui_owner_cleanup_total') end
    return changed
end

cleanupRuntime = function()
    if not runtimeRunning then return end
    if nuiReady then sendEnvelope('runtime:shutdown', RESOURCE_NAME, runtimeEpoch, 0, {}) end
    runtimeRunning = false
    nuiReady = false
    local closing = {}
    for _, surfaceId in ipairs(surfaceOrder) do closing[#closing + 1] = surfaceId end
    for _, surfaceId in ipairs(closing) do
        local surface = surfaces[surfaceId]
        if surface ~= nil then
            finishSurface(surface, {
                status = 'cancelled',
                error = failure('UI_REQUEST_CANCELLED', 'The UI runtime stopped.'),
            }, false)
        end
    end
    focusLeases = {}
    focusStack = {}
    focusQueue = {}
    syncFocus()
    pendingRequests = {}
    surfaces = {}
    surfaceOrder = {}
    signals = {}
    signalOrder = {}
    signalRevisions = {}
    signalRevisionOrder = {}
    browserVisibleSignals = {}
    browserVisibleSignalGeneration = -1
    browserVisibilityRevision = 0
    browserVisibleCapacity = LIMITS.maximumVisibleSignals
    signalCapacitySubscriber = nil
    signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
    focusAgents = {}
    interactionRuntime.active = nil
    interactionRuntime.revisions = {}
    interactionRuntime.revisionOrder = {}
    interactionRuntime.actionSubscriber = nil
    interactionRuntime.actionBindingGeneration = interactionRuntime.actionBindingGeneration + 1
    metrics.ui_active_surfaces = 0
    metrics.ui_active_signals = 0
    metrics.ui_active_interactions = 0
    if SetNuiFocusKeepInput ~= nil then pcall(SetNuiFocusKeepInput, false) end
    pcall(SetNuiFocus, false, false)
    focusApplied = { keyboard = false, pointer = false, target = 'none' }
end

registerNuiRoute('runtime:ready', function(request)
    if not keysAllowed(request, { protocolVersion = true, requestId = true, browserBootId = true })
        or request.protocolVersion ~= PROTOCOL_VERSION
        or not validIdentifier(request.requestId, 96)
        or not validIdentifier(request.browserBootId, 96) then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID',
            'The NUI ready handshake is invalid.'))
    end
    local isSameBrowserBoot = browserBootId == request.browserBootId
    if not isSameBrowserBoot then
        browserVisibleSignals = {}
        browserVisibleSignalGeneration = -1
        browserVisibilityRevision = 0
        browserVisibleCapacity = adaptiveSignalCapacity()
    end
    if browserBootId ~= nil and not isSameBrowserBoot then
        nuiReady = false
        resetBrowserRuntime('UI_REQUEST_CANCELLED')
        markReason('RUNTIME_RELOAD', 30000)
    end
    browserBootId = request.browserBootId
    nuiReady = true
    clearReason('NUI_NOT_READY')
    lastScreenMetrics = readScreenMetrics()
    lastScreenSampleAt = nowMilliseconds()
    notifySignalCapacity(false)
    local syncPayload = {
        preferences = cloneJson(preferences),
        screen = cloneJson(lastScreenMetrics),
        inputDevice = activeInputDevice,
        health = healthSnapshot().state,
        signals = signalSnapshot(nil),
        signalGeneration = signalGeneration,
    }
    if interactionRuntime.active ~= nil then
        syncPayload.interaction = interactionRuntime.payload(interactionRuntime.active, true)
        syncPayload.interactionGeneration = interactionRuntime.generation
    end
    -- A retry from the same browser instance must not clear surfaces that are
    -- still mounted and hold an active native-focus lease. A genuinely new
    -- browser boot is reset above and receives an explicit empty snapshot.
    if not isSameBrowserBoot then syncPayload.surfaces = {} end
    sendRuntimeSync(syncPayload)
    return success({
        requestId = request.requestId,
        protocolVersion = PROTOCOL_VERSION,
        apiVersion = API_VERSION,
        limits = publicLimits(),
    })
end)

registerNuiRoute('runtime:respond', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, instanceId = true, surfaceId = true,
        ownerEpoch = true, revision = true, browserBootId = true, action = true, data = true,
    }) then return rejected(failure('UI_REQUEST_INVALID', 'The NUI response contains unsupported fields.')) end
    if request.protocolVersion ~= PROTOCOL_VERSION then
        return rejected(failure('UI_PROTOCOL_UNSUPPORTED', 'The NUI protocol version is unsupported.'))
    end
    if not validIdentifier(request.requestId, 96) or not validIdentifier(request.instanceId, 96)
        or not validIdentifier(request.surfaceId, 96) or request.browserBootId ~= browserBootId
        or not integerInRange(request.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or not validIdentifier(request.action, 32) then
        return rejected(failure('UI_REQUEST_INVALID', 'The NUI response metadata is invalid.'))
    end
    local surface = pendingRequests[request.requestId]
    if surface == nil or surface.surfaceId ~= request.surfaceId
        or surface.instanceId ~= request.instanceId
        or surface.ownerEpoch ~= request.ownerEpoch or surface.revision ~= request.revision then
        return rejected(failure('UI_REQUEST_STALE', 'The NUI response belongs to a stale request.'))
    end
    local status = actionStatus(surface, request.action)
    if status == nil then return rejected(failure('UI_REQUEST_INVALID', 'The response action is invalid for this surface.')) end
    if request.data ~= nil then
        local dataBytes, dataError = boundedJson(request.data)
        if not dataBytes then return rejected(dataError) end
    end
    local responseData = nil
    if request.data ~= nil then responseData = cloneJson(request.data) end
    finishSurface(surface, {
        status = status,
        data = responseData,
    }, true)
    return success({ requestId = request.requestId, status = status })
end)

registerNuiRoute('runtime:close', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, instanceId = true, surfaceId = true,
        ownerEpoch = true, revision = true, browserBootId = true, reason = true,
    }) or request.protocolVersion ~= PROTOCOL_VERSION
        or not validIdentifier(request.requestId, 96) or not validIdentifier(request.instanceId, 96)
        or not validIdentifier(request.surfaceId, 96) or request.browserBootId ~= browserBootId
        or not integerInRange(request.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or (request.reason ~= nil and not validIdentifier(request.reason, 48)) then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID', 'The close request is invalid.'))
    end
    local surface = pendingRequests[request.requestId]
    if surface == nil or surface.surfaceId ~= request.surfaceId
        or surface.instanceId ~= request.instanceId
        or surface.ownerEpoch ~= request.ownerEpoch or surface.revision ~= request.revision then
        return rejected(failure('UI_REQUEST_STALE', 'The close request belongs to a stale surface.'))
    end
    finishSurface(surface, { status = 'cancelled' }, true)
    return success({ requestId = request.requestId, status = 'cancelled' })
end)

registerNuiRoute('runtime:input', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, browserBootId = true, device = true,
    }) or request.protocolVersion ~= PROTOCOL_VERSION or request.browserBootId ~= browserBootId
        or not validIdentifier(request.requestId, 96)
        or not INPUT_DEVICES[request.device] then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID', 'The input report is invalid.'))
    end
    setActiveInputDevice(request.device)
    return success({ requestId = request.requestId, device = activeInputDevice })
end)

registerNuiRoute('runtime:interaction', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, browserBootId = true,
        interactionId = true, ownerEpoch = true, revision = true,
        action = true, intentId = true, device = true,
    }) or request.protocolVersion ~= PROTOCOL_VERSION
        or request.browserBootId ~= browserBootId
        or not validIdentifier(request.requestId, 96)
        or not validIdentifier(request.interactionId, 96)
        or not integerInRange(request.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or (request.action ~= 'activate' and request.action ~= 'cancel')
        or not INPUT_DEVICES[request.device]
        or (request.intentId ~= nil and not validIdentifier(request.intentId, 96)) then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID',
            'The interaction intent callback is invalid.'))
    end
    local current = interactionRuntime.active
    if current == nil or current.ownerResource ~= INTERACTION_TRANSPORT_OWNER
        or current.interactionId ~= request.interactionId
        or current.ownerEpoch ~= request.ownerEpoch or current.revision ~= request.revision then
        return rejected(failure('UI_REQUEST_STALE',
            'The interaction intent callback belongs to a stale presentation.'))
    end
    local focusLease = current.focusLeaseId and focusLeases[current.focusLeaseId] or nil
    if current.mode ~= 'bloom' or not current.pointer or focusLease == nil
        or topFocusLease() ~= focusLease or not focusLease.sharedSurfaceLease then
        return rejected(failure('UI_INTERACTION_DENIED',
            'The interaction presentation does not own pointer focus.'))
    end
    local selectedIntent = nil
    if request.action == 'activate' then
        if request.intentId == nil then
            return rejected(failure('UI_REQUEST_INVALID',
                'An activated interaction requires an intent identifier.'))
        end
        for index = 1, #current.intents do
            local candidate = current.intents[index]
            if candidate.intentId == request.intentId then selectedIntent = candidate; break end
        end
        if selectedIntent == nil or selectedIntent.disabled == true then
            return rejected(failure('UI_INTERACTION_DENIED',
                'The selected interaction intent is unavailable.'))
        end
    elseif request.intentId ~= nil or not current.cancellable then
        return rejected(failure('UI_REQUEST_INVALID',
            'The interaction cancellation callback is invalid.'))
    end
    local subscriber = interactionRuntime.actionSubscriber
    if subscriber == nil or subscriber.ownerResource ~= current.ownerResource
        or subscriber.ownerEpoch ~= current.ownerEpoch or not isCallable(subscriber.callback) then
        return rejected(failure('UI_INTERACTION_DENIED',
            'The interaction intent subscriber is unavailable.'))
    end
    if current.actionPending then
        return rejected(failure('UI_REQUEST_STALE',
            'An interaction intent is already being handed off.'))
    end
    current.actionPending = true
    setActiveInputDevice(request.device)
    local event = {
        interactionId = current.interactionId,
        revision = current.revision,
        action = request.action,
        device = request.device,
    }
    if selectedIntent ~= nil then event.intentId = selectedIntent.intentId end
    local delivered, accepted = pcall(subscriber.callback, event)
    if not delivered or accepted ~= true then
        current.actionPending = false
        incrementMetric('ui_runtime_errors')
        return rejected(failure('UI_INTERACTION_DENIED',
            'The interaction owner did not accept the user intent.'))
    end
    incrementMetric('ui_interaction_action_total')
    return success({ requestId = request.requestId, accepted = true })
end)

registerNuiRoute('runtime:signals:visible', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, browserBootId = true,
        generation = true, presentationRevision = true, capacity = true,
        signals = true,
    }) or request.protocolVersion ~= PROTOCOL_VERSION
        or request.browserBootId ~= browserBootId
        or not validIdentifier(request.requestId, 96)
        or not integerInRange(request.generation, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.presentationRevision, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.capacity, 1, LIMITS.maximumVisibleSignals)
        or request.capacity ~= adaptiveSignalCapacity() then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID',
            'The passive signal visibility report is invalid.'))
    end
    if request.generation ~= signalGeneration then
        return rejected(failure('UI_REQUEST_STALE',
            'The passive signal visibility report is stale.'))
    end
    if request.presentationRevision <= browserVisibilityRevision then
        return rejected(failure('UI_REQUEST_STALE',
            'The passive signal presentation revision is stale.'))
    end
    local count = arrayLength(request.signals, request.capacity)
    if count == nil then
        return rejected(failure('UI_REQUEST_INVALID',
            'The passive signal visibility report is not bounded.'))
    end
    local confirmed = {}
    for index = 1, count do
        local entry = request.signals[index]
        if not keysAllowed(entry, {
            ownerResource = true, ownerEpoch = true, signalId = true, revision = true,
        }) or not validIdentifier(entry.ownerResource, 64)
            or not validIdentifier(entry.signalId, 96)
            or not integerInRange(entry.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
            or not integerInRange(entry.revision, 1, MAXIMUM_SAFE_INTEGER) then
            return rejected(failure('UI_REQUEST_INVALID',
                'A passive signal visibility entry is invalid.'))
        end
        local key = signalKey(entry.ownerResource, entry.signalId)
        local current = signals[key]
        if confirmed[key] ~= nil or current == nil
            or current.ownerEpoch ~= entry.ownerEpoch
            or current.revision ~= entry.revision then
            return rejected(failure('UI_REQUEST_STALE',
                'A passive signal visibility entry is stale.'))
        end
        confirmed[key] = entry.revision
    end
    browserVisibleSignals = confirmed
    browserVisibleSignalGeneration = request.generation
    browserVisibilityRevision = request.presentationRevision
    browserVisibleCapacity = request.capacity
    return success({ generation = request.generation,
        presentationRevision = request.presentationRevision,
        capacity = request.capacity, visible = count })
end)

registerNuiRoute('runtime:preferences', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, browserBootId = true, preferences = true,
    })
        or request.protocolVersion ~= PROTOCOL_VERSION or request.browserBootId ~= browserBootId
        or not validIdentifier(request.requestId, 96)
        or type(request.preferences) ~= 'table' then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID', 'The preference request is invalid.'))
    end
    local updated, preferenceError = updatePreferences(request.preferences, true)
    if not updated then return rejected(preferenceError) end
    return success({ requestId = request.requestId, preferences = updated })
end)

registerNuiRoute('runtime:error', function(request)
    if not keysAllowed(request, {
        protocolVersion = true, requestId = true, browserBootId = true, code = true, stage = true,
        surfaceRequestId = true, instanceId = true, surfaceId = true,
        ownerEpoch = true, revision = true,
    }) or request.protocolVersion ~= PROTOCOL_VERSION
        or not validIdentifier(request.requestId, 96)
        or (request.browserBootId ~= nil and request.browserBootId ~= browserBootId)
        or not ERROR_CODE_SET[request.code]
        or not ERROR_STAGES[request.stage] then
        return rejected(failure(request.protocolVersion ~= PROTOCOL_VERSION
            and 'UI_PROTOCOL_UNSUPPORTED' or 'UI_REQUEST_INVALID', 'The runtime error report is invalid.'))
    end
    local hasSurfaceContext = request.surfaceRequestId ~= nil or request.instanceId ~= nil
        or request.surfaceId ~= nil or request.ownerEpoch ~= nil or request.revision ~= nil
    if request.stage == 'render' then
        if request.browserBootId ~= browserBootId
            or not validIdentifier(request.surfaceRequestId, 96)
            or not validIdentifier(request.instanceId, 96)
            or not validIdentifier(request.surfaceId, 96)
            or not integerInRange(request.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
            or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER) then
            return rejected(failure('UI_REQUEST_INVALID', 'The render error correlation is invalid.'))
        end
        local surface = pendingRequests[request.surfaceRequestId]
        if surface == nil or surface.instanceId ~= request.instanceId
            or surface.surfaceId ~= request.surfaceId or surface.ownerEpoch ~= request.ownerEpoch
            or surface.revision ~= request.revision then
            return rejected(failure('UI_REQUEST_STALE', 'The render error belongs to a stale surface.'))
        end
        finishSurface(surface, {
            status = 'cancelled',
            error = failure('UI_REQUEST_CANCELLED', 'The UI surface failed to render and was closed safely.'),
        }, true)
    elseif hasSurfaceContext then
        return rejected(failure('UI_REQUEST_INVALID', 'Message-stage telemetry cannot include surface correlation.'))
    end
    incrementMetric('ui_runtime_errors')
    markReason('TRANSPORT_DEGRADED', 30000)
    return success({ requestId = request.requestId })
end)

local function facadeGuard(owner, epoch)
    return ownerCurrent(owner, epoch)
end

local function diagnosticsSnapshot(owner, epoch)
    local activeLeases = {}
    for _, leaseId in ipairs(focusStack) do
        local lease = focusLeases[leaseId]
        if lease ~= nil and lease.ownerResource == owner and lease.ownerEpoch == epoch then
            activeLeases[#activeLeases + 1] = publicLease(lease)
        end
    end
    local queuedLeases = {}
    for _, leaseId in ipairs(focusQueue) do
        local lease = focusLeases[leaseId]
        if lease ~= nil and lease.ownerResource == owner and lease.ownerEpoch == epoch then
            queuedLeases[#queuedLeases + 1] = publicLease(lease)
        end
    end
    local activeSurfaces = {}
    for _, surfaceId in ipairs(surfaceOrder) do
        local surface = surfaces[surfaceId]
        if surface ~= nil and surface.ownerResource == owner
            and surface.ownerEpoch == epoch then
            activeSurfaces[#activeSurfaces + 1] = {
                surfaceId = surface.surfaceId,
                requestId = surface.requestId,
                instanceId = surface.instanceId,
                ownerResource = surface.ownerResource,
                ownerEpoch = surface.ownerEpoch,
                kind = surface.kind,
                layer = surface.layer,
                revision = surface.revision,
                state = surface.state,
                createdAt = surface.createdAt,
            }
        end
    end
    local applied = { keyboard = false, pointer = false, target = 'none' }
    local top = topFocusLease()
    if top ~= nil and top.ownerResource == owner and top.ownerEpoch == epoch then
        applied = cloneJson(focusApplied)
    end
    return {
        apiVersion = API_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        nuiReady = nuiReady,
        health = healthSnapshot(),
        metrics = cloneJson(metrics),
        limits = publicLimits(),
        activeInputDevice = activeInputDevice,
        focus = {
            applied = applied,
            stack = activeLeases,
            queue = queuedLeases,
        },
        surfaces = activeSurfaces,
        signals = signalSnapshot(owner),
        signalGeneration = signalGeneration,
        interaction = interactionRuntime.active ~= nil
            and interactionRuntime.active.ownerResource == owner
            and interactionRuntime.active.ownerEpoch == epoch
            and interactionRuntime.payload(interactionRuntime.active, false) or nil,
        interactionGeneration = interactionRuntime.generation,
        interactionActionBindingGeneration = interactionRuntime.actionSubscriber ~= nil
            and interactionRuntime.actionSubscriber.ownerResource == owner
            and interactionRuntime.actionSubscriber.ownerEpoch == epoch
            and interactionRuntime.actionSubscriber.bindingGeneration or nil,
        signalVisibleCapacity = adaptiveSignalCapacity(),
        signalBrowserVisibleCapacity = browserVisibleCapacity,
        pendingRequests = #activeSurfaces,
        screen = lastScreenMetrics and cloneJson(lastScreenMetrics) or nil,
    }
end

local function invokingOwnerResource()
    local invoked, owner = pcall(GetInvokingResource)
    if not invoked or type(owner) ~= 'string' or owner == '' then
        return nil, failure('UI_FOCUS_DENIED', 'Focus-agent access requires an invoking resource.')
    end
    return owner
end

local function focusAgentSnapshot(agent)
    local intent = nil
    if agent.pendingIntent ~= nil then
        intent = {
            generation = agent.pendingIntent.generation,
            intent = agent.pendingIntent.intent,
            device = agent.pendingIntent.device,
            focusRevision = agent.pendingIntent.focusRevision,
        }
    end
    return {
        version = agent.version,
        protocolVersion = PROTOCOL_VERSION,
        bootGeneration = agent.bootGeneration,
        wakeupEvent = FOCUS_AGENT_WAKEUP_EVENT,
        ownerResource = agent.ownerResource,
        ownerEpoch = agent.ownerEpoch,
        revision = agent.revision,
        acknowledgedRevision = agent.acknowledgedRevision,
        keyboard = agent.desiredKeyboard,
        pointer = agent.desiredPointer,
        pending = agent.pendingFocus,
        intentGeneration = intent and intent.generation or 0,
        acknowledgedIntentGeneration = agent.acknowledgedIntentGeneration,
        intent = intent,
    }
end

local function validateFocusAgentVersion(versionRange)
    if type(versionRange) ~= 'string' or not SUPPORTED_FOCUS_AGENT_RANGES[versionRange] then
        return nil, failure('UI_PROTOCOL_UNSUPPORTED', 'The requested owner-focus agent version is unsupported.', {
            supported = FOCUS_AGENT_VERSION,
        })
    end
    return true
end

exports('RegisterFocusAgent', function(versionRange)
    local compatible, versionError = validateFocusAgentVersion(versionRange)
    if not compatible then return nil, versionError end
    local owner, invokingError = invokingOwnerResource()
    if not owner then return nil, invokingError end
    local epoch, ownerError = ensureOwner(owner)
    if not epoch then return nil, ownerError end
    local existing = focusAgents[owner]
    if existing ~= nil and existing.ownerEpoch == epoch
        and existing.bootGeneration == FOCUS_AGENT_BOOT_GENERATION then
        return focusAgentSnapshot(existing), nil
    end
    if existing == nil and focusAgentCount() >= LIMITS.maximumFocusAgents then
        return nil, failure('UI_FOCUS_DENIED', 'The focus-agent registry reached its bounded capacity.')
    end
    local revision, revisionError = nextFocusAgentRevision()
    if not revision then return nil, revisionError end
    local agent = {
        version = FOCUS_AGENT_VERSION,
        bootGeneration = FOCUS_AGENT_BOOT_GENERATION,
        ownerResource = owner,
        ownerEpoch = epoch,
        revision = revision,
        acknowledgedRevision = 0,
        desiredKeyboard = false,
        desiredPointer = false,
        appliedKeyboard = false,
        appliedPointer = false,
        pendingFocus = true,
        lastAckApplied = nil,
        acknowledgedIntentGeneration = 0,
        pendingIntent = nil,
    }
    focusAgents[owner] = agent
    return focusAgentSnapshot(agent), nil
end)

exports('GetFocusAgentState', function(versionRange)
    local compatible, versionError = validateFocusAgentVersion(versionRange)
    if not compatible then return nil, versionError end
    local owner, invokingError = invokingOwnerResource()
    if not owner then return nil, invokingError end
    local record = owners[owner]
    if record == nil then return nil, failure('UI_OWNER_STOPPED', 'The focus-agent owner is not registered.') end
    local current, ownerError = ownerCurrent(owner, record.epoch)
    if not current then return nil, ownerError end
    local agent, agentError = focusAgentFor(owner, record.epoch, false)
    if not agent then return nil, agentError end
    return focusAgentSnapshot(agent), nil
end)

exports('AcknowledgeFocusAgent', function(request)
    if not keysAllowed(request, {
        version = true, bootGeneration = true, ownerEpoch = true, revision = true,
        keyboard = true, pointer = true, applied = true, errorCode = true,
        intentGeneration = true, intentDelivered = true,
    }) then return nil, failure('UI_REQUEST_INVALID', 'The focus-agent acknowledgement is invalid.') end
    local compatible, versionError = validateFocusAgentVersion(request.version)
    if not compatible then return nil, versionError end
    if not validIdentifier(request.bootGeneration, 96)
        or not integerInRange(request.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(request.revision, 1, MAXIMUM_SAFE_INTEGER)
        or type(request.keyboard) ~= 'boolean' or type(request.pointer) ~= 'boolean'
        or type(request.applied) ~= 'boolean'
        or not integerInRange(request.intentGeneration, 0, MAXIMUM_SAFE_INTEGER)
        or type(request.intentDelivered) ~= 'boolean'
        or (request.errorCode ~= nil and not validIdentifier(request.errorCode, 64)) then
        return nil, failure('UI_REQUEST_INVALID', 'The focus-agent acknowledgement is invalid.')
    end
    local owner, invokingError = invokingOwnerResource()
    if not owner then return nil, invokingError end
    local agent = focusAgents[owner]
    if agent == nil or agent.ownerEpoch ~= request.ownerEpoch
        or agent.bootGeneration ~= request.bootGeneration then
        return nil, failure('UI_OWNER_STALE', 'The focus-agent acknowledgement belongs to an expired owner or boot.')
    end
    if request.revision ~= agent.revision or request.keyboard ~= agent.desiredKeyboard
        or request.pointer ~= agent.desiredPointer then
        return nil, failure('UI_REQUEST_STALE', 'The focus-agent acknowledgement revision is stale.')
    end
    local acknowledgesFocus = agent.pendingFocus == true
    local acknowledgesIntent = agent.pendingIntent ~= nil
        and request.intentGeneration == agent.pendingIntent.generation
        and agent.pendingIntent.focusRevision == request.revision
    if not acknowledgesFocus and not acknowledgesIntent then
        return nil, failure('UI_REQUEST_STALE', 'The focus-agent acknowledgement has no matching pending work.')
    end
    if agent.pendingIntent == nil and request.intentGeneration ~= 0 then
        return nil, failure('UI_REQUEST_STALE', 'The focus-agent intent generation is stale.')
    end
    if agent.pendingIntent ~= nil and not acknowledgesIntent then
        return nil, failure('UI_REQUEST_STALE', 'The focus-agent intent acknowledgement is stale.')
    end

    if acknowledgesFocus then
        agent.pendingFocus = false
        agent.acknowledgedRevision = request.revision
        agent.lastAckApplied = request.applied
        agent.lastError = request.applied and nil or request.errorCode or 'FOCUS_NATIVE_FAILED'
        if request.applied then
            agent.appliedKeyboard = request.keyboard
            agent.appliedPointer = request.pointer
        else
            focusDesynchronized = true
            incrementMetric('ui_runtime_errors')
            markReason('FOCUS_DESYNC')
        end
    end
    if acknowledgesIntent then
        agent.pendingIntent = nil
        if request.applied and request.intentDelivered then
            agent.acknowledgedIntentGeneration = request.intentGeneration
        else
            incrementMetric('ui_runtime_errors')
            markReason('TRANSPORT_DEGRADED', 30000)
        end
    elseif request.intentDelivered then
        return nil, failure('UI_REQUEST_STALE', 'No owner intent is pending for acknowledgement.')
    end
    return true, nil
end)

exports('GetAPI', function(versionRange)
    local requested = versionRange == nil and '^1.0.0' or tostring(versionRange)
    if not SUPPORTED_API_RANGES[requested] then
        return nil, failure('UI_PROTOCOL_UNSUPPORTED', 'The requested Synex UI API version is unsupported.', {
            supported = API_VERSION,
        })
    end
    local invoked, owner = pcall(GetInvokingResource)
    if not invoked or type(owner) ~= 'string' or owner == '' then
        return nil, failure('UI_FOCUS_DENIED', 'External Synex UI API access requires an invoking resource.')
    end
    local epoch, ownerError = ensureOwner(owner)
    if not epoch then return nil, ownerError end
    local api = {
        version = API_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        ownerResource = owner,
        ownerEpoch = epoch,
        focusModes = cloneJson(FOCUS_MODES),
        priorityClasses = cloneJson(PRIORITY_CLASSES),
        layers = cloneJson(LAYERS),
        limits = publicLimits(),
        errorCodes = cloneJson(ERROR_CODES),
        healthReasons = cloneJson(HEALTH_REASONS),
    }
    api.acquireFocus = function(options)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return acquireFocusInternal(owner, epoch, options, true, false)
    end
    api.releaseFocus = function(leaseId)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return releaseFocusInternal(leaseId, owner, epoch)
    end
    api.getFocusLease = function(leaseId)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if not validIdentifier(leaseId, 160) then
            return nil, failure('UI_FOCUS_LEASE_INVALID', 'The focus lease identifier is invalid.')
        end
        local lease = focusLeases[leaseId]
        if lease == nil or lease.ownerResource ~= owner or lease.ownerEpoch ~= epoch then
            return nil, failure('UI_FOCUS_LEASE_INVALID', 'The focus lease does not exist for this owner epoch.')
        end
        return publicLease(lease), nil
    end
    api.alert = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'alert', request)
    end
    api.confirm = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'confirm', request)
    end
    api.input = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'input', request)
    end
    api.form = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'form', request)
    end
    api.select = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'select', request)
    end
    api.menu = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'menu', request)
    end
    api.contextMenu = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return openSurfaceAndAwait(owner, epoch, 'contextMenu', request)
    end
    api.upsertInteraction = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= INTERACTION_TRANSPORT_OWNER then
            return nil, failure('UI_INTERACTION_DENIED',
                'Interaction presentation transport is reserved for synex_interact.')
        end
        return interactionRuntime.upsert(owner, epoch, request)
    end
    api.removeInteraction = function(interactionId, revision)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= INTERACTION_TRANSPORT_OWNER then
            return nil, failure('UI_INTERACTION_DENIED',
                'Interaction presentation transport is reserved for synex_interact.')
        end
        return interactionRuntime.remove(owner, epoch, interactionId, revision)
    end
    api.getInteractionSnapshot = function()
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= INTERACTION_TRANSPORT_OWNER then
            return nil, failure('UI_INTERACTION_DENIED',
                'Interaction presentation transport is reserved for synex_interact.')
        end
        return {
            generation = interactionRuntime.generation,
            interaction = interactionRuntime.active ~= nil
                and interactionRuntime.payload(interactionRuntime.active, false) or nil,
            focusLeaseId = interactionRuntime.active ~= nil
                and interactionRuntime.active.focusLeaseId or nil,
        }, nil
    end
    if owner == INTERACTION_TRANSPORT_OWNER then
        api.bindInteractionActions = function(callback)
            local valid, guardError = facadeGuard(owner, epoch)
            if not valid then return nil, guardError end
            if not isCallable(callback) then
                return nil, failure('UI_REQUEST_INVALID',
                    'The interaction action subscriber must be callable.')
            end
            interactionRuntime.actionBindingGeneration = interactionRuntime.actionBindingGeneration + 1
            interactionRuntime.actionSubscriber = {
                ownerResource = owner,
                ownerEpoch = epoch,
                callback = callback,
                bindingGeneration = interactionRuntime.actionBindingGeneration,
            }
            return { bindingGeneration = interactionRuntime.actionBindingGeneration }, nil
        end
    end
    api.upsertSignal = function(request)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= SIGNAL_TRANSPORT_OWNER then
            return nil, failure('UI_SIGNAL_DENIED',
                'Passive signal transport is reserved for synex_notify.')
        end
        return upsertSignalInternal(owner, epoch, request)
    end
    api.removeSignal = function(signalId, revision)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= SIGNAL_TRANSPORT_OWNER then
            return nil, failure('UI_SIGNAL_DENIED',
                'Passive signal transport is reserved for synex_notify.')
        end
        return removeSignalInternal(owner, epoch, signalId, revision)
    end
    api.getSignalSnapshot = function()
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if owner ~= SIGNAL_TRANSPORT_OWNER then
            return nil, failure('UI_SIGNAL_DENIED',
                'Passive signal transport is reserved for synex_notify.')
        end
        return {
            generation = signalGeneration,
            visibilityGeneration = browserVisibleSignalGeneration,
            visibilityRevision = browserVisibilityRevision,
            visibleCapacity = adaptiveSignalCapacity(),
            visibilityCapacity = browserVisibleCapacity,
            signals = signalSnapshot(owner, true),
        }, nil
    end
    if owner == SIGNAL_TRANSPORT_OWNER then
        api.bindSignalCapacity = function(callback)
            local valid, guardError = facadeGuard(owner, epoch)
            if not valid then return nil, guardError end
            if not isCallable(callback) then
                return nil, failure('UI_REQUEST_INVALID',
                    'The signal-capacity subscriber must be callable.')
            end
            signalCapacityBindingGeneration = signalCapacityBindingGeneration + 1
            signalCapacitySubscriber = {
                ownerResource = owner,
                ownerEpoch = epoch,
                callback = callback,
                capacity = nil,
                preferenceRevision = nil,
                pendingCapacity = nil,
                pendingPreferenceRevision = nil,
                dispatchPending = false,
                bindingGeneration = signalCapacityBindingGeneration,
            }
            local scheduled = notifySignalCapacity(true)
            if not scheduled or signalCapacitySubscriber == nil then
                return nil, failure('UI_REQUEST_INVALID',
                    'The signal-capacity subscriber could not be scheduled.')
            end
            return { capacity = adaptiveSignalCapacity() }
        end
        api.playSignalSound = function(request)
            local valid, guardError = facadeGuard(owner, epoch)
            if not valid then return nil, guardError end
            if not keysAllowed(request, { tone = true, volume = true })
                or SIGNAL_SOUND_TONES[request.tone] ~= true
                or not integerInRange(request.volume, LIMITS.minimumSignalSoundVolume,
                    LIMITS.maximumSignalSoundVolume) then
                return nil, failure('UI_REQUEST_INVALID',
                    'The notification sound request is invalid.')
            end
            local now = nowMilliseconds()
            local sinceLast = now - signalSoundRate.lastAt
            if sinceLast < LIMITS.signalSoundCooldownMs then
                return nil, failure('UI_SIGNAL_DENIED',
                    'The notification sound cooldown is active.', {
                        retryAfterMs = LIMITS.signalSoundCooldownMs - sinceLast,
                    })
            end
            if now - signalSoundRate.windowStartedAt >= LIMITS.signalSoundWindowMs then
                signalSoundRate.windowStartedAt = now
                signalSoundRate.count = 0
            end
            if signalSoundRate.count >= LIMITS.maximumSignalSoundsPerWindow then
                return nil, failure('UI_SIGNAL_DENIED',
                    'The notification sound rate limit is active.', {
                        retryAfterMs = math.max(1,
                            LIMITS.signalSoundWindowMs - (now - signalSoundRate.windowStartedAt)),
                    })
            end
            local delivered, sendError = sendEnvelope('signal:sound', owner, epoch, 0, {
                tone = request.tone,
                volume = request.volume,
                browserBootId = browserBootId,
            })
            if not delivered then return nil, sendError end
            signalSoundRate.lastAt = now
            signalSoundRate.count = signalSoundRate.count + 1
            return { delivered = true }, nil
        end
    end
    if owner == SIGNAL_TRANSPORT_OWNER or owner == INTERACTION_TRANSPORT_OWNER then
        api.reportInputDevice = function(device)
            local valid, guardError = facadeGuard(owner, epoch)
            if not valid then return nil, guardError end
            if device ~= 'keyboard' and device ~= 'gamepad' then
                return nil, failure('UI_REQUEST_INVALID',
                    'The passive input-device report is invalid.')
            end
            local changed = setActiveInputDevice(device)
            if changed and nuiReady then
                local synchronized, syncError = sendRuntimeSync({
                    inputDevice = activeInputDevice,
                })
                if not synchronized then return nil, syncError end
            end
            return { device = activeInputDevice, changed = changed }, nil
        end
    end
    api.closeOwner = function(disposition)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        if disposition ~= nil and disposition ~= 'cancelled' and disposition ~= 'superseded' then
            return nil, failure('UI_REQUEST_INVALID', 'The owner close disposition is invalid.')
        end
        cleanupOwner(owner, epoch, disposition or 'cancelled')
        return true
    end
    api.getPreferences = function()
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return cloneJson(preferences)
    end
    api.setPreferences = function(value)
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return updatePreferences(value, true)
    end
    api.getHealth = function()
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return healthSnapshot()
    end
    api.getDiagnostics = function()
        local valid, guardError = facadeGuard(owner, epoch)
        if not valid then return nil, guardError end
        return diagnosticsSnapshot(owner, epoch)
    end
    return api, nil
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == RESOURCE_NAME then return end
    if not validIdentifier(resource, 64) then return end
    local record = owners[resource]
    if record ~= nil and record.state == 'started' then return end
    focusAgents[resource] = nil
    ownerEpochSerial = ownerEpochSerial + 1
    owners[resource] = { epoch = ownerEpochSerial, state = 'started' }
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == RESOURCE_NAME then
        cleanupRuntime()
        return
    end
    local record = owners[resource]
    if record ~= nil then
        cleanupOwner(resource, record.epoch, 'ownerStopped')
        record.state = 'stopped'
    end
    focusAgents[resource] = nil
end)

loadPreferences()
