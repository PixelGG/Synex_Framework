local API_VERSION = '1.0.0'
local API_RANGE = '^1.0.0'
local UUID_PATTERN = '^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$'

local function domainError(code, message, retryable, details)
    return {
        code = code,
        message = message,
        retryable = retryable == true,
        details = details
    }
end

local uuidSequence = 0
local function uuidV4(random)
    uuidSequence = uuidSequence + 1
    local bytes = {}
    for index = 1, 16 do bytes[index] = random(0, 255) end
    local resourceName = rawget(_G, 'GetCurrentResourceName') and GetCurrentResourceName() or 'synex_groups'
    local entropy = ('%s:%s:%s'):format(resourceName, os.time(), uuidSequence)
    local hash = 0x811c9dc5
    for index = 1, #entropy do hash = ((hash ~ entropy:byte(index)) * 0x01000193) & 0xffffffff end
    for index = 1, 4 do bytes[index] = bytes[index] ~ ((hash >> ((index - 1) * 8)) & 0xff) end
    bytes[7] = (bytes[7] & 0x0f) | 0x40
    bytes[9] = (bytes[9] & 0x3f) | 0x80
    return ('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x'):format(
        table.unpack(bytes))
end

local function isUuid(value)
    return type(value) == 'string' and value:match(UUID_PATTERN) ~= nil
end

local function isSubjectId(value)
    return type(value) == 'string' and #value >= 3 and #value <= 48
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function isPublicId(value)
    return type(value) == 'string' and #value >= 8 and #value <= 48
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function isCallable(value)
    local valueType = type(value)
    if valueType == 'function' then return true end
    if valueType ~= 'table' and valueType ~= 'userdata' then return false end
    local metatable = getmetatable(value)
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetatable = pcall(debug.getmetatable, value)
        if readable then metatable = rawMetatable end
    end
    return type(metatable) == 'table'
        and type(rawget(metatable, '__call')) == 'function'
end

local function characterLength(value)
    if type(value) ~= 'string' then return -1 end
    local length = utf8.len(value)
    return length or -1
end

local function jsonContainerDescriptor(value)
    if type(value) ~= 'table' then return nil, nil end
    local metatable = getmetatable(value)
    if metatable == nil then return 'plain', nil end
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetatable = pcall(debug.getmetatable, value)
        if readable then metatable = rawMetatable end
    end
    if type(metatable) ~= 'table' then return nil, nil end
    local kind = rawget(metatable, '__jsontype')
    if kind ~= 'object' and kind ~= 'array' then return nil, nil end
    -- Cfx's dkjson containers carry only this inert marker. Refuse executable
    -- or otherwise decorated marker lookalikes before preserving the identity.
    for key in next, metatable do
        if key ~= '__jsontype' then return nil, nil end
    end
    return kind, metatable
end

local function jsonContainerKind(value)
    local kind = jsonContainerDescriptor(value)
    return kind
end

local function copyPlain(value, limits)
    limits = limits or {}
    local maximumDepth = limits.maximumDepth or 12
    local maximumKeys = limits.maximumKeys or 512
    local maximumStringBytes = limits.maximumStringBytes or 16384
    local preserveContainerKind = limits.preserveContainerKind == true
    local active, keys = {}, 0
    local function copy(candidate, depth)
        local candidateType = type(candidate)
        if candidateType == 'nil' or candidateType == 'boolean' then return candidate end
        if candidateType == 'number' then
            if candidate ~= candidate or candidate == math.huge or candidate == -math.huge then
                error('JSON numbers must be finite', 0)
            end
            return candidate
        end
        if candidateType == 'string' then
            if #candidate > maximumStringBytes then error('JSON strings exceed the configured bound', 0) end
            return candidate
        end
        local containerKind, containerMetatable = jsonContainerDescriptor(candidate)
        if candidateType ~= 'table' or not containerKind
            or depth > maximumDepth or active[candidate] then
            error('JSON values must be bounded acyclic containers', 0)
        end
        active[candidate] = true
        local result, count, maximumIndex, keyType = {}, 0, 0, nil
        for key, child in next, candidate do
            keys = keys + 1
            if keys > maximumKeys then active[candidate] = nil error('JSON values contain too many keys', 0) end
            local currentType = type(key)
            if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                maximumIndex = math.max(maximumIndex, key)
            elseif currentType ~= 'string' or #key == 0 or #key > 128 then
                active[candidate] = nil
                error('JSON object keys are invalid', 0)
            end
            if keyType and keyType ~= currentType then
                active[candidate] = nil
                error('JSON containers cannot mix array and object keys', 0)
            end
            keyType = currentType
            count = count + 1
            result[key] = copy(child, depth + 1)
        end
        active[candidate] = nil
        if keyType == 'number' and maximumIndex ~= count
            or containerKind == 'object' and keyType == 'number'
            or containerKind == 'array' and keyType == 'string' then
            error('JSON container shape does not match its declared kind', 0)
        end
        if preserveContainerKind and containerMetatable ~= nil then
            setmetatable(result, containerMetatable)
        end
        return result
    end
    return copy(value, 1)
end

local function evaluateCapabilityRules(rules, capability)
    local allowed, denied, matched = false, false, {}
    for _, rule in ipairs(rules) do
        local pattern = rule.capability
        local matches = pattern == capability
        if not matches and type(pattern) == 'string' and pattern:sub(-2) == '.*' then
            local prefix = pattern:sub(1, -3)
            matches = capability:sub(1, #prefix + 1) == prefix .. '.'
        end
        if matches then
            matched[#matched + 1] = { capability = pattern, effect = rule.effect }
            if rule.effect == 'deny' then denied = true elseif rule.effect == 'allow' then allowed = true end
        end
    end
    return allowed and not denied, denied, matched
end

local function validateShape(request, allowed, required)
    if type(request) ~= 'table' then
        return nil, domainError('VALIDATION_FAILED', 'Request must be an object.')
    end
    for key in pairs(request) do
        if type(key) ~= 'string' or not allowed[key] then
            return nil, domainError('VALIDATION_FAILED', 'Request contains an unknown property.', false, { property = tostring(key) })
        end
    end
    for _, key in ipairs(required) do
        if request[key] == nil then
            return nil, domainError('VALIDATION_FAILED', 'Request is missing a required property.', false, { property = key })
        end
    end
    return true, nil
end

local function createCanonicalEncoder(jsonEncode)
    local function encode(value, depth)
        depth = (depth or 0) + 1
        if depth > 8 then error('metadata nesting exceeds eight levels') end
        local valueType = type(value)
        if valueType == 'nil' then return 'null' end
        if valueType == 'boolean' or valueType == 'string' then return jsonEncode(value) end
        if valueType == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then error('metadata number must be finite') end
            return jsonEncode(value)
        end
        if valueType ~= 'table' or not jsonContainerKind(value) then
            error('metadata contains an unsupported value')
        end

        local containerKind = jsonContainerKind(value)
        local count, maximum, array = 0, 0, containerKind ~= 'object'
        for key in pairs(value) do
            count = count + 1
            if count > 64 then error('metadata contains too many properties') end
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
                array = false
            else
                maximum = math.max(maximum, key)
            end
        end
        if containerKind == 'array' and not array then
            error('metadata array contains object properties')
        end
        if containerKind == 'object' and maximum > 0 then
            error('metadata object contains array indexes')
        end
        if array and (count > 0 or containerKind == 'array') then
            if maximum ~= count then error('metadata arrays must be contiguous') end
            local items = {}
            for index = 1, count do items[index] = encode(value[index], depth) end
            return '[' .. table.concat(items, ',') .. ']'
        end

        local keys = {}
        for key in pairs(value) do
            if type(key) ~= 'string' or #key == 0 or #key > 64 then error('metadata object keys are invalid') end
            keys[#keys + 1] = key
        end
        table.sort(keys)
        local properties = {}
        for index, key in ipairs(keys) do
            properties[index] = jsonEncode(key) .. ':' .. encode(value[key], depth)
        end
        return '{' .. table.concat(properties, ',') .. '}'
    end
    return encode
end

local function firstKnownId(request, names, validator)
    if type(request) ~= 'table' then return nil end
    for _, name in ipairs(names) do
        local value = rawget(request, name)
        if validator(value) then return value end
    end
    return nil
end

local function redactedErrorEvent(operation, context, request)
    local traceId = type(context) == 'table' and rawget(context, 'traceId') or nil
    if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 64
        or traceId:match('^[%w%._:%-]+$') == nil then
        traceId = 'unavailable'
    end
    local event = { operation = operation, traceId = traceId }
    event.groupId = firstKnownId(request,
        { 'group_id', 'source_group_id', 'target_group_id' }, isPublicId)
    event.membershipId = firstKnownId(request, {
        'membership_id', 'target_membership_id', 'grantee_membership_id'
    }, isPublicId)
    event.characterId = firstKnownId(request,
        { 'character_id', 'actor_character_id' }, isSubjectId)
    return event
end

local function reportUnexpectedError(errorSink, resourceName, operation, context, request)
    local event = redactedErrorEvent(operation, context, request)
    local sinkOk = pcall(errorSink, event)
    if not sinkOk then
        print(('[%s] error_sink_failed operation=%s traceId=%s'):format(
            resourceName, event.operation, event.traceId))
    end
end

return {
    API_VERSION = API_VERSION,
    API_RANGE = API_RANGE,
    domainError = domainError,
    uuidV4 = uuidV4,
    isUuid = isUuid,
    isSubjectId = isSubjectId,
    isPublicId = isPublicId,
    isCallable = isCallable,
    characterLength = characterLength,
    jsonContainerKind = jsonContainerKind,
    copyPlain = copyPlain,
    evaluateCapabilityRules = evaluateCapabilityRules,
    validateShape = validateShape,
    createCanonicalEncoder = createCanonicalEncoder,
    reportUnexpectedError = reportUnexpectedError
}
