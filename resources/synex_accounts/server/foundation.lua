local API_VERSION = '1.0.0'
local API_RANGE = '^1.0.0'
local MAX_MINOR = 9007199254740991
local ACCOUNT_ACCESS_PERMISSIONS = {
    view = true, deposit = true, withdraw = true, transfer = true,
    history = true, manage = true, close = true
}
local UUID_PATTERN = '^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$'

local function domainError(code, message, retryable, details)
    return { code = code, message = message, retryable = retryable == true, details = details }
end

local uuidSequence = 0
local function uuidV4(random)
    uuidSequence = uuidSequence + 1
    local bytes = {}
    for index = 1, 16 do bytes[index] = random(0, 255) end
    local resourceName = rawget(_G, 'GetCurrentResourceName') and GetCurrentResourceName() or 'synex_accounts'
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

-- Core user and character identifiers are opaque, bounded identifiers rather
-- than UUIDs. Domain-owned public IDs remain UUIDs; subject references accept
-- both formats so ownership can be linked without re-keying either domain.
local function isSubjectId(value)
    return type(value) == 'string' and #value >= 1 and #value <= 36
        and value:match('^[a-z0-9][a-z0-9_%-]*$') ~= nil
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
    return utf8.len(value) or -1
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
        if valueType ~= 'table' or getmetatable(value) ~= nil then error('metadata contains an unsupported value') end

        local count, maximum, array = 0, 0, true
        for key in pairs(value) do
            count = count + 1
            if count > 64 then error('metadata contains too many properties') end
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then array = false
            else maximum = math.max(maximum, key) end
        end
        if array and count > 0 then
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
        for index, key in ipairs(keys) do properties[index] = jsonEncode(key) .. ':' .. encode(value[key], depth) end
        return '{' .. table.concat(properties, ',') .. '}'
    end
    return encode
end

local function redactedErrorEvent(operation, context)
    local traceId = type(context) == 'table' and rawget(context, 'traceId') or nil
    if type(traceId) ~= 'string' or #traceId < 1 or #traceId > 128
        or traceId:match('^[%w%._:%-]+$') == nil then
        traceId = 'unavailable'
    end
    return { operation = operation, traceId = traceId }
end

local function reportUnexpectedError(errorSink, resourceName, operation, context)
    local event = redactedErrorEvent(operation, context)
    local sinkOk = pcall(errorSink, event)
    if not sinkOk then
        print(('[%s] error_sink_failed operation=%s traceId=%s'):format(
            resourceName, event.operation, event.traceId))
    end
end

return {
    API_VERSION = API_VERSION,
    API_RANGE = API_RANGE,
    MAX_MINOR = MAX_MINOR,
    ACCOUNT_ACCESS_PERMISSIONS = ACCOUNT_ACCESS_PERMISSIONS,
    domainError = domainError,
    uuidV4 = uuidV4,
    isUuid = isUuid,
    isSubjectId = isSubjectId,
    isCallable = isCallable,
    characterLength = characterLength,
    validateShape = validateShape,
    createCanonicalEncoder = createCanonicalEncoder,
    reportUnexpectedError = reportUnexpectedError
}
