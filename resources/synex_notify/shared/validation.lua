SynexNotifyValidation = {}

local Validation = SynexNotifyValidation
local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded first')
local MAXIMUM_SAFE_INTEGER = Limits.maximumSafeInteger
local identifierPattern = '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'
local resourcePattern = '^[A-Za-z0-9][A-Za-z0-9_.%-]*$'

local notificationKeys = {
    kind = true, tone = true, priority = true, title = true, message = true,
    iconKey = true, dedupeKey = true, dedupePolicy = true, groupKey = true,
    maxRefreshCount = true,
    durationMs = true, maxLifetimeMs = true, history = true, position = true,
    progress = true, actions = true, sound = true,
}

local presentationKeys = {
    notificationId = true, kind = true, tone = true, priority = true, title = true,
    message = true, iconKey = true, count = true, progress = true, actions = true,
    createdAt = true, expiresAt = true, position = true, revision = true,
    dedupeKey = true, dedupePolicy = true, groupKey = true, durationMs = true,
    maxLifetimeMs = true, maxRefreshCount = true, history = true, origin = true,
    sound = true,
}

local clientPatchKeys = {
    title = true, message = true, tone = true, iconKey = true, count = true,
    durationMs = true, progress = true, actions = true, position = true,
    sound = true,
}

local serverPatchKeys = {
    title = true, message = true, tone = true, durationMs = true,
    progress = true, actions = true,
}

local function failure(code, message, retryable)
    return nil, {
        code = code,
        message = message,
        retryable = retryable == true,
    }
end

local function finiteNumber(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function boundedText(value, minimum, maximum, allowEmpty)
    if type(value) ~= 'string' or #value > maximum
        or (not allowEmpty and #value < minimum)
        or value:find('[%z\1-\8\11\12\14-\31\127]') then
        return nil
    end
    if type(utf8) == 'table' and type(utf8.len) == 'function' then
        local readable, length = pcall(utf8.len, value)
        if not readable or length == nil then return nil end
    end
    return value
end

local function boundedIdentifier(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match(identifierPattern) ~= nil
end

local containerKind

local function jsonStringBytes(value)
    local bytes = 2
    for index = 1, #value do
        local byte = value:byte(index)
        if byte == 34 or byte == 92 or byte == 8 or byte == 9
            or byte == 10 or byte == 12 or byte == 13 then
            bytes = bytes + 2
        elseif byte < 32 then
            bytes = bytes + 6
        else
            bytes = bytes + 1
        end
    end
    return bytes
end

local function encodedJsonBytes(value, depth, seen)
    local valueType = type(value)
    if valueType == 'nil' then return 4 end
    if valueType == 'boolean' then return value and 4 or 5 end
    if valueType == 'number' then
        if not finiteNumber(value) then return nil end
        return #tostring(value)
    end
    if valueType == 'string' then return jsonStringBytes(value) end
    if valueType ~= 'table' or depth > 8 or seen[value] then return nil end
    local kind = containerKind(value)
    if kind == nil then return nil end
    seen[value] = true
    local entries, maximumIndex, numeric, textual = 0, 0, true, true
    for key in next, value do
        entries = entries + 1
        if type(key) == 'number' and Validation.isInteger(key, 1,
            MAXIMUM_SAFE_INTEGER) then
            maximumIndex = math.max(maximumIndex, key)
            textual = false
        elseif type(key) == 'string' then
            numeric = false
        else
            seen[value] = nil
            return nil
        end
    end
    local array = kind == 'array' or kind == 'plain'
        and entries > 0 and numeric and maximumIndex == entries
    if kind == 'array' and (not numeric or maximumIndex ~= entries)
        or kind == 'object' and not textual
        or kind == 'plain' and not array and not textual then
        seen[value] = nil
        return nil
    end
    local bytes = 2
    if array then
        for index = 1, entries do
            local childBytes = encodedJsonBytes(rawget(value, index), depth + 1, seen)
            if childBytes == nil then seen[value] = nil return nil end
            bytes = bytes + childBytes + (index > 1 and 1 or 0)
        end
    else
        local index = 0
        for key, child in next, value do
            index = index + 1
            local childBytes = encodedJsonBytes(child, depth + 1, seen)
            if childBytes == nil then seen[value] = nil return nil end
            bytes = bytes + jsonStringBytes(key) + 1 + childBytes
                + (index > 1 and 1 or 0)
        end
    end
    seen[value] = nil
    return bytes
end

containerKind = function(value)
    if type(value) ~= 'table' then return nil end
    local readable, metadata = pcall(getmetatable, value)
    if not readable then return nil end
    if metadata == nil then return 'plain' end
    if type(metadata) ~= 'table' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        readable, metadata = pcall(debug.getmetatable, value)
        if not readable then return nil end
    end
    if type(metadata) ~= 'table' then return nil end
    local kind = rawget(metadata, '__jsontype')
    if kind ~= 'object' and kind ~= 'array' then return nil end
    local entries = 0
    for key in next, metadata do
        entries = entries + 1
        if key ~= '__jsontype' or entries > 1 then return nil end
    end
    return entries == 1 and kind or nil
end

local function denseArray(value, maximum)
    local kind = containerKind(value)
    if kind == nil or kind == 'object' then return nil end
    local count = 0
    for key in next, value do
        if not Validation.isInteger(key, 1, maximum) then return nil end
        count = count + 1
        if count > maximum then return nil end
    end
    for index = 1, count do
        if rawget(value, index) == nil then return nil end
    end
    return count
end

local INVALID_COPY = {}

local function copy(value, depth, seen)
    local valueType = type(value)
    if valueType ~= 'table' then
        if value == nil or valueType == 'string' or valueType == 'boolean' then
            return value
        end
        if valueType == 'number' and finiteNumber(value) then return value end
        return INVALID_COPY
    end
    depth, seen = depth or 0, seen or {}
    local kind = containerKind(value)
    if depth > 6 or seen[value] or kind == nil then return INVALID_COPY end
    seen[value] = true
    local result = {}
    for key, child in next, value do
        if type(key) ~= 'string' and type(key) ~= 'number' then
            seen[value] = nil
            return INVALID_COPY
        end
        if type(key) == 'number' and not Validation.isInteger(key, 1,
            MAXIMUM_SAFE_INTEGER) then
            seen[value] = nil
            return INVALID_COPY
        end
        local copied = copy(child, depth + 1, seen)
        if copied == INVALID_COPY then seen[value] = nil; return INVALID_COPY end
        result[key] = copied
    end
    seen[value] = nil
    if kind == 'object' or kind == 'array' then
        setmetatable(result, { __jsontype = kind })
    end
    return result
end

local function progress(value)
    if not Validation.exactObject(value, {
        state = true, mode = true, value = true, maximum = true,
    }) or not Limits.progressStates[value.state]
        or not Limits.progressModes[value.mode] then
        return failure('NOTIFY_INVALID_REQUEST', 'The notification progress value is invalid.')
    end
    if value.mode == 'indeterminate' then
        if value.value ~= nil or value.maximum ~= nil then
            return failure('NOTIFY_INVALID_REQUEST',
                'Indeterminate progress cannot include a value or maximum.')
        end
        return { state = value.state, mode = value.mode }
    end
    if not finiteNumber(value.value) or not finiteNumber(value.maximum)
        or value.value < 0 or value.maximum <= 0 or value.maximum > 1000000000
        or value.value > value.maximum then
        return failure('NOTIFY_INVALID_REQUEST',
            'Determinate progress requires a bounded value and maximum.')
    end
    return {
        state = value.state,
        mode = value.mode,
        value = value.value + 0.0,
        maximum = value.maximum + 0.0,
    }
end

local function actions(value, authority, transport)
    if value == nil then return {} end
    local count = denseArray(value, Limits.maximumActions)
    if count == nil then
        return failure('NOTIFY_INVALID_REQUEST',
            'Notification actions must be a bounded dense array.')
    end
    local normalized, seen = {}, {}
    for index = 1, count do
        local candidate = value[index]
        local allowed = transport and {
            token = true, label = true, hint = true, style = true, ttlMs = true,
        } or {
            id = true, token = true, label = true, hint = true, style = true,
            ttlMs = true,
        }
        if not Validation.exactObject(candidate, allowed)
            or not boundedText(candidate.label, 1, Limits.maximumActionLabelBytes, false)
            or (candidate.hint ~= nil and not boundedText(candidate.hint, 1,
                Limits.maximumActionHintBytes, false))
            or (candidate.style ~= nil and not Limits.actionStyles[candidate.style]
                and not (transport and Limits.uiActionStyles[candidate.style]))
            or (candidate.ttlMs ~= nil and not Validation.isInteger(candidate.ttlMs,
                Limits.minimumActionTtlMs, Limits.maximumActionTtlMs)) then
            return failure('NOTIFY_INVALID_REQUEST', 'A notification action is invalid.')
        end
        local actionId, token = candidate.id, candidate.token
        if transport then
            if not boundedIdentifier(token, 8, Limits.maximumActionTokenBytes) then
                return failure('NOTIFY_INVALID_REQUEST',
                    'A transported notification action token is invalid.')
            end
        elseif authority == 'SERVER' or authority == 'SYSTEM' then
            if not boundedIdentifier(actionId, 1, Limits.maximumActionIdBytes)
                or token ~= nil then
                return failure('NOTIFY_INVALID_REQUEST',
                    'Server action definitions require an id and cannot supply a token.')
            end
        else
            if not boundedIdentifier(actionId, 1, Limits.maximumActionIdBytes)
                or token ~= nil then
                return failure('NOTIFY_INVALID_REQUEST',
                    'Client action definitions require an id and cannot supply a token.')
            end
        end
        local unique = transport and token or actionId
        if seen[unique] then
            return failure('NOTIFY_INVALID_REQUEST', 'Notification actions must be unique.')
        end
        seen[unique] = true
        normalized[index] = {
            label = candidate.label,
            style = candidate.style or (transport and 'default' or 'quiet'),
            ttlMs = candidate.ttlMs or Limits.defaultActionTtlMs,
        }
        if candidate.hint ~= nil then normalized[index].hint = candidate.hint end
        if transport then normalized[index].token = token else normalized[index].id = actionId end
    end
    return normalized
end

local function normalizeNotification(value, options)
    options = options or {}
    local transport = options.transport == true
    local allowed = transport and presentationKeys or notificationKeys
    if not Validation.exactObject(value, allowed) then
        return failure('NOTIFY_INVALID_REQUEST',
            'The notification contains unsupported fields.')
    end
    local authority = options.authority or 'CLIENT'
    if authority ~= 'CLIENT' and authority ~= 'SERVER' and authority ~= 'SYSTEM' then
        return failure('NOTIFY_INVALID_REQUEST', 'The notification authority is invalid.')
    end
    local canonicalOrigin = authority == 'SYSTEM' and 'SYSTEM'
        or authority == 'SERVER' and 'SERVER' or 'LOCAL'
    local kind = value.kind or options.kind or 'toast'
    local tone = value.tone or 'neutral'
    local priority = value.priority or 'normal'
    local position = value.position or 'top-right'
    if not Limits.kinds[kind] or not Limits.tones[tone]
        or not Limits.priorities[priority] or not Limits.positions[position]
        or not boundedText(value.title, 1, Limits.maximumTitleBytes, false)
        or (value.message ~= nil and not boundedText(value.message, 0,
            Limits.maximumMessageBytes, true))
        or (value.iconKey ~= nil and not Limits.iconKeys[value.iconKey])
        or (value.history ~= nil and type(value.history) ~= 'boolean')
        or (value.sound ~= nil and type(value.sound) ~= 'boolean') then
        return failure('NOTIFY_INVALID_REQUEST', 'The notification presentation is invalid.')
    end
    if authority == 'CLIENT' and (kind == 'banner'
        or priority == 'high' or priority == 'critical') then
        return failure('NOTIFY_PRIORITY_DENIED',
            'Client notifications cannot request banners or privileged priority.')
    end
    if value.dedupeKey ~= nil and not boundedIdentifier(value.dedupeKey, 1,
        Limits.maximumDedupeKeyBytes) or value.groupKey ~= nil
        and not boundedIdentifier(value.groupKey, 1, Limits.maximumGroupKeyBytes)
        or value.dedupePolicy ~= nil and not Limits.dedupePolicies[value.dedupePolicy]
        or value.dedupePolicy ~= nil and value.dedupeKey == nil then
        return failure('NOTIFY_INVALID_REQUEST', 'Notification deduplication is invalid.')
    end
    local maxRefreshCount = nil
    if value.dedupePolicy == 'refresh' then
        maxRefreshCount = value.maxRefreshCount or Limits.defaultMaxRefreshCount
    end
    if value.maxRefreshCount ~= nil and value.dedupePolicy ~= 'refresh'
        or maxRefreshCount ~= nil and not Validation.isInteger(maxRefreshCount, 1,
            Limits.maximumRefreshCount) then
        return failure('NOTIFY_INVALID_REQUEST',
            'Notification refresh count requires the refresh deduplication policy.')
    end
    local duration = value.durationMs
    if duration ~= nil and not Validation.isInteger(duration,
        Limits.minimumDurationMs, Limits.maximumDurationMs) then
        return failure('NOTIFY_INVALID_REQUEST', 'Notification duration is invalid.')
    end
    local lifetime = value.maxLifetimeMs or Limits.maximumLifetimeMs
    if not Validation.isInteger(lifetime, Limits.minimumLifetimeMs,
        Limits.maximumLifetimeMs) or duration ~= nil and lifetime < duration then
        return failure('NOTIFY_INVALID_REQUEST', 'Notification maximum lifetime is invalid.')
    end
    local normalizedProgress = nil
    if value.progress ~= nil then
        local progressError
        normalizedProgress, progressError = progress(value.progress)
        if not normalizedProgress then return nil, progressError end
    end
    if kind == 'progress' and normalizedProgress == nil then
        normalizedProgress = { state = 'RUNNING', mode = 'indeterminate' }
    elseif kind ~= 'progress' and normalizedProgress ~= nil then
        return failure('NOTIFY_INVALID_REQUEST',
            'Progress data is valid only for progress notifications.')
    end
    if kind == 'progress' and (value.dedupeKey ~= nil or value.groupKey ~= nil) then
        return failure('NOTIFY_INVALID_REQUEST',
            'Progress notifications require one explicit handle and cannot be compacted.')
    end
    local normalizedActions, actionError = actions(value.actions, authority, transport)
    if not normalizedActions then return nil, actionError end
    local result = {
        kind = kind,
        tone = tone,
        priority = priority,
        title = value.title,
        position = position,
        maxLifetimeMs = lifetime,
        history = value.history ~= false,
        actions = normalizedActions,
        sound = value.sound == true,
        origin = canonicalOrigin,
    }
    if value.message ~= nil then result.message = value.message end
    if value.iconKey ~= nil then result.iconKey = value.iconKey end
    if value.dedupeKey ~= nil then
        result.dedupeKey = value.dedupeKey
        result.dedupePolicy = value.dedupePolicy or 'suppress'
    end
    if maxRefreshCount ~= nil then result.maxRefreshCount = maxRefreshCount end
    if value.groupKey ~= nil then result.groupKey = value.groupKey end
    if duration ~= nil then result.durationMs = duration
    elseif kind ~= 'persistent' and kind ~= 'progress' then
        local content = value.title .. (value.message or '')
        local characters = #content
        if type(utf8) == 'table' and type(utf8.len) == 'function' then
            characters = utf8.len(content) or characters
        end
        result.durationMs = math.min(lifetime, math.max(Limits.minimumDurationMs,
            math.min(Limits.maximumDurationMs,
                (Limits.durationBaseMs or Limits.defaultDurationMs)
                + characters * (Limits.durationPerCharacterMs or 0)
                + ((Limits.durationPriorityBonusMs or {})[priority] or 0)
                + ((Limits.durationKindBonusMs or {})[kind] or 0))))
    end
    if normalizedProgress ~= nil then result.progress = normalizedProgress end
    if transport then
        if not boundedIdentifier(value.notificationId, 8,
            Limits.maximumNotificationIdBytes)
            or not Validation.isInteger(value.revision, 1, MAXIMUM_SAFE_INTEGER)
            or not Validation.isInteger(value.createdAt, 0, MAXIMUM_SAFE_INTEGER)
            or (value.expiresAt ~= nil and (not Validation.isInteger(value.expiresAt,
                0, MAXIMUM_SAFE_INTEGER) or value.expiresAt <= value.createdAt))
            or value.origin ~= canonicalOrigin then
            return failure('NOTIFY_INVALID_REQUEST',
                'The notification transport presentation is invalid.')
        end
        result.notificationId = value.notificationId
        result.revision = value.revision
        result.createdAt = value.createdAt
        result.origin = value.origin
        if value.expiresAt ~= nil then result.expiresAt = value.expiresAt end
        if value.count ~= nil then
            if not Validation.isInteger(value.count, 1, Limits.maximumCount) then
                return failure('NOTIFY_INVALID_REQUEST', 'Notification count is invalid.')
            end
            result.count = value.count
        end
    end
    local payloadBytes, payloadError = Validation.payloadBytes(result)
    if payloadBytes == nil then return nil, payloadError end
    return result
end

function Validation.failure(code, message, retryable)
    return failure(code, message, retryable)
end

function Validation.isInteger(value, minimum, maximum)
    return finiteNumber(value) and value == math.floor(value)
        and (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
end

function Validation.arrayLength(value, maximum)
    return denseArray(value, maximum)
end

function Validation.identifier(value, minimum, maximum)
    return boundedIdentifier(value, minimum or 1, maximum or MAXIMUM_SAFE_INTEGER)
end

function Validation.payloadBytes(value)
    local bytes = encodedJsonBytes(value, 0, {})
    if bytes == nil then
        return failure('NOTIFY_INVALID_REQUEST',
            'The notification payload is not canonically serializable.')
    end
    if bytes > (Limits.maximumPayloadBytes or 4096) then
        return failure('NOTIFY_PAYLOAD_TOO_LARGE',
            'The notification payload exceeds the canonical byte limit.')
    end
    return bytes
end

function Validation.exactObject(value, allowed)
    local kind = containerKind(value)
    if kind == nil or kind == 'array' then return false end
    for key in next, value do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

function Validation.resourceName(value)
    if type(value) ~= 'string' or #value < 3
        or #value > Limits.maximumResourceNameBytes
        or value:match(resourcePattern) == nil then
        return failure('NOTIFY_OWNER_INVALID', 'The notification owner resource is invalid.')
    end
    return value
end

function Validation.targetRef(value)
    if not Validation.exactObject(value, {
        source = true, sessionId = true, sourceGeneration = true,
    }) or not Validation.isInteger(value.source, 1, Limits.maximumPlayerSource)
        or not boundedIdentifier(value.sessionId, 8, Limits.maximumSessionIdBytes)
        or not Validation.isInteger(value.sourceGeneration, 1, MAXIMUM_SAFE_INTEGER) then
        return failure('NOTIFY_TARGET_STALE', 'The notification target session is invalid.')
    end
    return {
        source = value.source,
        sessionId = value.sessionId,
        sourceGeneration = value.sourceGeneration,
    }
end

function Validation.handle(value)
    if not Validation.exactObject(value, {
        notificationId = true, ownerResource = true, ownerEpoch = true, revision = true,
    }) or not boundedIdentifier(value.notificationId, 8,
        Limits.maximumNotificationIdBytes)
        or not Validation.isInteger(value.ownerEpoch, 1, MAXIMUM_SAFE_INTEGER)
        or not Validation.isInteger(value.revision, 1, MAXIMUM_SAFE_INTEGER) then
        return failure('NOTIFY_INVALID_REQUEST', 'The notification handle is invalid.')
    end
    local owner, ownerError = Validation.resourceName(value.ownerResource)
    if not owner then return nil, ownerError end
    return {
        notificationId = value.notificationId,
        ownerResource = owner,
        ownerEpoch = value.ownerEpoch,
        revision = value.revision,
    }
end

function Validation.canonicalNotification(value, options)
    return normalizeNotification(value, options)
end

function Validation.canonicalPresentation(value, options)
    options = options or {}
    return normalizeNotification(value, {
        authority = options.authority,
        ownerResource = options.ownerResource,
        now = options.now,
        kind = options.kind,
        transport = true,
    })
end

function Validation.notificationPatch(value, options)
    options = options or {}
    local authority = options.authority or 'CLIENT'
    local allowed = (authority == 'SERVER' or authority == 'SYSTEM')
        and serverPatchKeys or clientPatchKeys
    if not Validation.exactObject(value, allowed) or next(value) == nil then
        return failure('NOTIFY_INVALID_REQUEST',
            'The notification update contains unsupported or no fields.')
    end
    local result = {}
    if value.title ~= nil then
        if not boundedText(value.title, 1, Limits.maximumTitleBytes, false) then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification title is invalid.')
        end
        result.title = value.title
    end
    if value.message ~= nil then
        if not boundedText(value.message, 0, Limits.maximumMessageBytes, true) then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification message is invalid.')
        end
        result.message = value.message
    end
    if value.tone ~= nil then
        if not Limits.tones[value.tone] then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification tone is invalid.')
        end
        result.tone = value.tone
    end
    if value.iconKey ~= nil then
        if not Limits.iconKeys[value.iconKey] then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification icon is invalid.')
        end
        result.iconKey = value.iconKey
    end
    if value.count ~= nil then
        if not Validation.isInteger(value.count, 1, Limits.maximumCount) then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification count is invalid.')
        end
        result.count = value.count
    end
    if value.durationMs ~= nil then
        if not Validation.isInteger(value.durationMs, Limits.minimumDurationMs,
            Limits.maximumDurationMs) then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification duration is invalid.')
        end
        result.durationMs = value.durationMs
    end
    if value.position ~= nil then
        if not Limits.positions[value.position] then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification position is invalid.')
        end
        result.position = value.position
    end
    if value.sound ~= nil then
        if type(value.sound) ~= 'boolean' then
            return failure('NOTIFY_INVALID_REQUEST', 'The notification sound preference is invalid.')
        end
        result.sound = value.sound
    end
    if value.progress ~= nil then
        if options.kind ~= nil and options.kind ~= 'progress' then
            return failure('NOTIFY_INVALID_REQUEST',
                'Progress data is valid only for progress notifications.')
        end
        local normalized, progressError = progress(value.progress)
        if not normalized then return nil, progressError end
        result.progress = normalized
    end
    if value.actions ~= nil then
        local normalized, actionError = actions(value.actions, authority, false)
        if not normalized then return nil, actionError end
        result.actions = normalized
    end
    local payloadBytes, payloadError = Validation.payloadBytes(result)
    if payloadBytes == nil then return nil, payloadError end
    return result
end

function Validation.copy(value)
    local copied = copy(value)
    if copied == INVALID_COPY then return nil end
    return copied
end
