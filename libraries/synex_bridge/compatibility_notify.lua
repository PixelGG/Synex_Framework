local Notify = {}

local MINIMUM_DURATION_MS = 1500
local MAXIMUM_DURATION_MS = 30000
local MAXIMUM_TITLE_BYTES = 120
local MAXIMUM_MESSAGE_BYTES = 720

local TONES = {
    primary = 'info',
    info = 'info',
    inform = 'info',
    success = 'success',
    warning = 'warning',
    warn = 'warning',
    error = 'danger',
    danger = 'danger',
    neutral = 'neutral',
}

local function callable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metadata = getmetatable(value)
    if type(metadata) ~= 'table' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable then metadata = rawMetadata end
    end
    return type(metadata) == 'table'
        and type(rawget(metadata, '__call')) == 'function'
end

local function plainText(value, maximum)
    if type(value) ~= 'string' or #value < 1 or #value > maximum
        or value:find('[%z\1-\8\11\12\14-\31\127]')
        or value:find('[<>]') then
        return nil
    end
    if type(utf8) == 'table' and type(utf8.len) == 'function' then
        local readable, length = pcall(utf8.len, value)
        if not readable or length == nil then return nil end
    end
    local normalized = value:gsub('~[%w_]+~', ''):gsub('%^[0-9]', '')
        :gsub('%s+', ' '):match('^%s*(.-)%s*$')
    if type(normalized) ~= 'string' or #normalized < 1 or #normalized > maximum then
        return nil
    end
    return normalized
end

local function duration(value)
    if value == nil then return nil, true end
    if type(value) ~= 'number' or value ~= value
        or value == math.huge or value == -math.huge or value < 0 then
        return nil, false
    end
    return math.max(MINIMUM_DURATION_MS,
        math.min(MAXIMUM_DURATION_MS, math.floor(value))), true
end

local function tone(value)
    if value == nil then return 'info', true end
    if type(value) ~= 'string' or #value < 1 or #value > 32
        or value:find('[%z\1-\31\127]') then
        return nil, false
    end
    return TONES[value:lower()] or 'neutral', true
end

local function request(message, title, notifyType, durationMs)
    local safeMessage = plainText(message, MAXIMUM_MESSAGE_BYTES)
    local safeTitle = title == nil and 'Notification'
        or plainText(title, MAXIMUM_TITLE_BYTES)
    local safeTone, toneValid = tone(notifyType)
    local safeDuration, durationValid = duration(durationMs)
    if not safeMessage or not safeTitle or not toneValid or not durationValid then
        return nil
    end
    local normalized = {
        kind = 'toast',
        tone = safeTone,
        priority = 'normal',
        title = safeTitle,
        message = safeMessage,
    }
    if safeDuration ~= nil then normalized.durationMs = safeDuration end
    return normalized
end

local function dispatch(provider, consumer, normalized)
    if type(consumer) ~= 'string' or #consumer < 2 or #consumer > 64
        or consumer:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') == nil
        or type(normalized) ~= 'table' then
        return nil
    end
    local state = GetResourceState('synex_notify')
    if state ~= 'started' and state ~= 'starting' then return nil end
    local resolved, api = pcall(function()
        return exports.synex_notify:GetCompatibilityAPI(consumer, provider)
    end)
    if not resolved or type(api) ~= 'table' then return nil end
    local notify = rawget(api, 'notify') or rawget(api, 'Notify')
    if not callable(notify) then return nil end
    local invoked, result, operationError = pcall(notify, normalized)
    if not invoked or result == false or result == nil then return nil, operationError end
    return result, operationError
end

function Notify.qb(consumer, text, notifyType, durationMs)
    local message, title
    if type(text) == 'table' then
        if getmetatable(text) ~= nil then return nil end
        for key in next, text do
            if key ~= 'text' and key ~= 'caption' then return nil end
        end
        message = rawget(text, 'text')
        title = rawget(text, 'caption')
    else
        message = text
    end
    local normalized = request(message, title, notifyType, durationMs)
    if not normalized then return nil end
    return dispatch('qb', consumer, normalized)
end

function Notify.qbx(consumer, text, notifyType, durationMs, subTitle)
    local normalized = request(text, subTitle, notifyType, durationMs)
    if not normalized then return nil end
    return dispatch('qbx', consumer, normalized)
end

function Notify.esx(consumer, message, notifyType, durationMs, title)
    local normalized = request(message, title, notifyType, durationMs)
    if not normalized then return nil end
    return dispatch('esx', consumer, normalized)
end

function Notify.esxAdvanced(consumer, sender, subject, message)
    local safeSender = plainText(sender, MAXIMUM_TITLE_BYTES)
    local safeSubject = plainText(subject, MAXIMUM_TITLE_BYTES)
    if not safeSender or not safeSubject then return nil end
    local title = safeSender .. ' - ' .. safeSubject
    if #title > MAXIMUM_TITLE_BYTES then title = safeSubject end
    local normalized = request(message, title, 'info', nil)
    if not normalized then return nil end
    return dispatch('esx', consumer, normalized)
end

SynexBridgeNotify = Notify
