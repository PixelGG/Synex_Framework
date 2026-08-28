local OWNER_RESOURCE = GetCurrentResourceName()
local AGENT_VERSION = '1.0.0'
local PROTOCOL_VERSION = 1
local WAKEUP_EVENT = 'synex_ui:focus-agent:wakeup:v1'
local MAXIMUM_SAFE_INTEGER = 9007199254740991

if OWNER_RESOURCE == 'synex_ui' then return end

local ALLOWED_INTENTS = {
    UP = true,
    DOWN = true,
    LEFT = true,
    RIGHT = true,
    CONFIRM = true,
    BACK = true,
    PREVIOUS_TAB = true,
    NEXT_TAB = true,
    PAGE_UP = true,
    PAGE_DOWN = true,
}

local registeredBootGeneration = nil
local registeredOwnerEpoch = nil
local lastAppliedRevision = 0
local lastAppliedKeyboard = false
local lastAppliedPointer = false
local lastIntentGeneration = 0
local reconciling = false

local function integerInRange(value, minimum, maximum)
    return type(value) == 'number' and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function boundedIdentifier(value, maximum)
    return type(value) == 'string' and #value >= 1 and #value <= maximum
        and value:match('^[%w_:%-%.]+$') ~= nil
end

local function keysAllowed(value, allowed)
    if type(value) ~= 'table' then return false end
    for key in pairs(value) do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

local function validIntent(value, stateRevision)
    if value == nil then return true end
    return keysAllowed(value, {
        generation = true, intent = true, device = true, focusRevision = true,
    }) and integerInRange(value.generation, 1, MAXIMUM_SAFE_INTEGER)
        and ALLOWED_INTENTS[value.intent] == true and value.device == 'gamepad'
        and value.focusRevision == stateRevision
end

local function validState(state)
    return keysAllowed(state, {
        version = true, protocolVersion = true, bootGeneration = true, wakeupEvent = true,
        ownerResource = true, ownerEpoch = true, revision = true, acknowledgedRevision = true,
        keyboard = true, pointer = true, pending = true, intentGeneration = true,
        acknowledgedIntentGeneration = true, intent = true,
    }) and state.version == AGENT_VERSION and state.protocolVersion == PROTOCOL_VERSION
        and state.wakeupEvent == WAKEUP_EVENT and state.ownerResource == OWNER_RESOURCE
        and boundedIdentifier(state.bootGeneration, 96)
        and integerInRange(state.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        and integerInRange(state.revision, 1, MAXIMUM_SAFE_INTEGER)
        and integerInRange(state.acknowledgedRevision, 0, state.revision)
        and type(state.keyboard) == 'boolean' and type(state.pointer) == 'boolean'
        and type(state.pending) == 'boolean'
        and integerInRange(state.intentGeneration, 0, MAXIMUM_SAFE_INTEGER)
        and integerInRange(state.acknowledgedIntentGeneration, 0, MAXIMUM_SAFE_INTEGER)
        and validIntent(state.intent, state.revision)
        and ((state.intent == nil and state.intentGeneration == 0)
            or (state.intent ~= nil and state.intentGeneration == state.intent.generation))
end

local function failSafeRelease()
    if SetNuiFocusKeepInput ~= nil then pcall(SetNuiFocusKeepInput, false) end
    if SetNuiFocus ~= nil then pcall(SetNuiFocus, false, false) end
    lastAppliedKeyboard = false
    lastAppliedPointer = false
end

local function pullState()
    local called, state, stateError = pcall(function()
        return exports.synex_ui:GetFocusAgentState(AGENT_VERSION)
    end)
    if not called or state == nil or stateError ~= nil or not validState(state) then return nil end
    return state
end

local function acknowledge(state, applied, errorCode, intentGeneration, intentDelivered)
    local called, acknowledged, acknowledgeError = pcall(function()
        return exports.synex_ui:AcknowledgeFocusAgent({
            version = AGENT_VERSION,
            bootGeneration = state.bootGeneration,
            ownerEpoch = state.ownerEpoch,
            revision = state.revision,
            keyboard = state.keyboard,
            pointer = state.pointer,
            applied = applied,
            errorCode = errorCode,
            intentGeneration = intentGeneration,
            intentDelivered = intentDelivered,
        })
    end)
    return called and acknowledged == true and acknowledgeError == nil
end

local function applyNativeState(state)
    local keepInputApplied = true
    if SetNuiFocusKeepInput ~= nil then
        keepInputApplied = pcall(SetNuiFocusKeepInput, false)
    end
    local focusApplied = SetNuiFocus ~= nil and pcall(SetNuiFocus, state.keyboard, state.pointer)
    return keepInputApplied and focusApplied
end

local function deliverIntent(state)
    local intent = state.intent
    if intent == nil or intent.generation <= lastIntentGeneration then return true, 0 end
    local sent = SendNUIMessage ~= nil and pcall(SendNUIMessage, {
        protocolVersion = PROTOCOL_VERSION,
        messageId = ('focus-intent-%d'):format(intent.generation),
        type = 'input:intent',
        ownerResource = OWNER_RESOURCE,
        ownerEpoch = state.ownerEpoch,
        revision = state.revision,
        payload = {
            intent = intent.intent,
            device = 'gamepad',
            generation = intent.generation,
        },
    })
    return sent, intent.generation
end

local function reconcile()
    if reconciling then return false end
    reconciling = true
    local completed = false
    for _ = 1, 3 do
        local state = pullState()
        if state == nil then break end
        if registeredBootGeneration ~= nil and registeredBootGeneration ~= state.bootGeneration then
            failSafeRelease()
            lastAppliedRevision = 0
            lastIntentGeneration = 0
        end
        registeredBootGeneration = state.bootGeneration
        registeredOwnerEpoch = state.ownerEpoch
        if state.revision < lastAppliedRevision then break end

        local needsFocusApply = state.pending or state.revision > lastAppliedRevision
            or state.keyboard ~= lastAppliedKeyboard or state.pointer ~= lastAppliedPointer
        local applied = true
        if needsFocusApply then applied = applyNativeState(state) end
        if not applied then failSafeRelease() end
        local intentDelivered = false
        local intentGeneration = state.intent and state.intent.generation or 0
        if applied and state.intent ~= nil and state.intent.generation > lastIntentGeneration then
            intentDelivered, intentGeneration = deliverIntent(state)
        elseif state.intent ~= nil and state.intent.generation <= lastIntentGeneration then
            intentDelivered = true
        end

        local needsAcknowledgement = state.pending or state.intent ~= nil
        if not needsAcknowledgement then
            completed = true
            break
        end
        local errorCode = nil
        if not applied then errorCode = 'FOCUS_NATIVE_FAILED'
        elseif state.intent ~= nil and not intentDelivered then errorCode = 'OWNER_INTENT_DELIVERY_FAILED' end
        if acknowledge(state, applied, errorCode, intentGeneration, intentDelivered) then
            if applied then
                lastAppliedRevision = state.revision
                lastAppliedKeyboard = state.keyboard
                lastAppliedPointer = state.pointer
            end
            if intentDelivered and intentGeneration > 0 then lastIntentGeneration = intentGeneration end
            completed = applied and (state.intent == nil or intentDelivered)
            break
        end
    end
    reconciling = false
    return completed
end

local function registerAgent()
    local called, registration, registrationError = pcall(function()
        return exports.synex_ui:RegisterFocusAgent(AGENT_VERSION)
    end)
    if not called or registration == nil or registrationError ~= nil or not validState(registration) then
        registeredBootGeneration = nil
        registeredOwnerEpoch = nil
        failSafeRelease()
        return false
    end
    if registeredBootGeneration ~= nil and registeredBootGeneration ~= registration.bootGeneration then
        failSafeRelease()
        lastAppliedRevision = 0
        lastIntentGeneration = 0
    end
    registeredBootGeneration = registration.bootGeneration
    registeredOwnerEpoch = registration.ownerEpoch
    return reconcile()
end

AddEventHandler(WAKEUP_EVENT, function(ownerResource, ownerEpoch, bootGeneration, revision, intentGeneration)
    if ownerResource ~= OWNER_RESOURCE or not integerInRange(ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not boundedIdentifier(bootGeneration, 96)
        or not integerInRange(revision, 1, MAXIMUM_SAFE_INTEGER)
        or not integerInRange(intentGeneration, 0, MAXIMUM_SAFE_INTEGER) then return end
    if registeredBootGeneration == nil or registeredOwnerEpoch ~= ownerEpoch then
        registerAgent()
        return
    end
    reconcile()
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'synex_ui' then registerAgent() end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= 'synex_ui' and resource ~= OWNER_RESOURCE then return end
    failSafeRelease()
    registeredBootGeneration = nil
    registeredOwnerEpoch = nil
    lastAppliedRevision = 0
    lastIntentGeneration = 0
end)

registerAgent()
