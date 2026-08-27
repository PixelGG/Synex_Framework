local Client = {}

local MAX_PENDING = 8
local MAX_ARGUMENTS = 16
local MAX_PAYLOAD_BYTES = 16384
local MAX_ERROR_BYTES = 4096
local MAX_DEPTH = 6
local MAX_ENTRIES = 192
local MAX_ARRAY_ITEMS = 16
local MAX_STRING_BYTES = 1024
local MAX_KEY_BYTES = 96
local MAX_SAFE_INTEGER = 9007199254740991
local TIMEOUT_MS = 10000

local function isCallable(value)
    if type(value) == 'function' then return true end
    local valueType = type(value)
    if valueType ~= 'table' and valueType ~= 'userdata' then return false end
    local metatable = getmetatable(value)
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetatable = pcall(debug.getmetatable, value)
        if readable then metatable = rawMetatable end
    end
    return type(metatable) == 'table' and type(rawget(metatable, '__call')) == 'function'
end

local function validCallbackName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 96
        and value:match('^[A-Za-z0-9_:%-%.]+$') ~= nil
end

local function validConsumer(value)
    return type(value) == 'string' and #value >= 2 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function readMetatable(value)
    local metadata = getmetatable(value)
    if type(metadata) == 'table' then return metadata end
    if type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable and type(rawMetadata) == 'table' then return rawMetadata end
    end
    return metadata
end

local function containerKind(value)
    local metadata = readMetatable(value)
    if metadata == nil then return nil, false end
    if type(metadata) ~= 'table' then return nil, true end
    local kind = rawget(metadata, '__jsontype')
    if kind ~= 'array' and kind ~= 'object' then return nil, true end
    for key, item in next, metadata do
        if key ~= '__jsontype' and key ~= '__metatable' then return nil, true end
        if key == '__metatable' and type(item) ~= 'string' then return nil, true end
    end
    return kind, false
end

local function copyValue(value, budget, depth, seen)
    local valueType = type(value)
    budget.entries = budget.entries + 1
    budget.bytes = budget.bytes + 8
    if budget.entries > MAX_ENTRIES or budget.bytes > budget.maximumBytes then return nil, false end
    if valueType == 'nil' or valueType == 'boolean' then return value, true end
    if valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge
            or math.abs(value) > MAX_SAFE_INTEGER then return nil, false end
        return value, true
    end
    if valueType == 'string' then
        if #value > MAX_STRING_BYTES or value:find('%z') then return nil, false end
        budget.bytes = budget.bytes + #value
        return value, budget.bytes <= budget.maximumBytes
    end
    if valueType ~= 'table' or depth >= MAX_DEPTH or seen[value] then return nil, false end

    local declaredKind, metadataError = containerKind(value)
    if metadataError then return nil, false end
    local numericCount, maximumIndex, stringCount = 0, 0, 0
    for key in next, value do
        if type(key) == 'number' then
            if math.type(key) ~= 'integer' or key < 1 or key > MAX_ARRAY_ITEMS then
                return nil, false
            end
            numericCount = numericCount + 1
            maximumIndex = math.max(maximumIndex, key)
        elseif type(key) == 'string' then
            if #key > MAX_KEY_BYTES or key:find('[%z\1-\31\127]') then
                return nil, false
            end
            stringCount = stringCount + 1
            budget.bytes = budget.bytes + #key
        else
            return nil, false
        end
    end
    if budget.bytes > budget.maximumBytes then return nil, false end

    local kind = declaredKind
    if kind == nil then
        if numericCount > 0 and stringCount > 0 then return nil, false end
        kind = numericCount > 0 and 'array' or 'object'
    end
    if kind == 'array' then
        if stringCount > 0 or numericCount ~= maximumIndex
            or numericCount > MAX_ARRAY_ITEMS then return nil, false end
    elseif numericCount > 0 or stringCount > MAX_ENTRIES then
        return nil, false
    end

    seen[value] = true
    local result = {}
    if kind == 'array' then
        for index = 1, maximumIndex do
            local copied, valid = copyValue(rawget(value, index), budget, depth + 1, seen)
            if not valid then seen[value] = nil; return nil, false end
            result[index] = copied
        end
        setmetatable(result, { __jsontype = 'array' })
    else
        for key, item in next, value do
            local copied, valid = copyValue(item, budget, depth + 1, seen)
            if not valid then seen[value] = nil; return nil, false end
            result[key] = copied
        end
    end
    seen[value] = nil
    return result, true, kind
end

local function copyDto(value, root, maximumBytes)
    local copied, valid, kind = copyValue(
        value, { entries = 0, bytes = 0, maximumBytes = maximumBytes }, 0, {})
    if not valid then return nil end
    if root == 'array' and kind == 'object' and type(value) == 'table'
        and getmetatable(value) == nil and next(value) == nil then
        setmetatable(copied, { __jsontype = 'array' })
        kind = 'array'
    end
    if kind ~= root then return nil end
    local encoded, payload = pcall(json.encode, copied)
    if not encoded or type(payload) ~= 'string' or #payload > maximumBytes then return nil end
    return copied
end

local function normalizePacked(value)
    if type(value) ~= 'table' then return nil end
    local declaredCount = rawget(value, 'n')
    local count = declaredCount ~= nil and declaredCount or rawlen(value)
    if type(count) ~= 'number' or math.type(count) ~= 'integer'
        or count < 0 or count > MAX_ARGUMENTS then return nil end
    local present = 0
    for key in next, value do
        if key ~= 'n' and (type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > count) then return nil end
        if key ~= 'n' then present = present + 1 end
    end
    if present ~= count then return nil end
    local dense = {}
    for index = 1, count do dense[index] = rawget(value, index) end
    return copyDto(dense, 'array', MAX_PAYLOAD_BYTES)
end

function Client.create(options)
    assert(type(options) == 'table', 'native bridge client options are required')
    local requestEvent = assert(validCallbackName(options.requestEvent)
        and options.requestEvent, 'requestEvent is invalid')
    local responseEvent = assert(validCallbackName(options.responseEvent)
        and options.responseEvent, 'responseEvent is invalid')
    local pending = {}
    local pendingCount = 0
    local sequence = 0
    local stopped = false

    RegisterNetEvent(responseEvent, function(requestId, ok, payload)
        if source ~= 65535 or type(requestId) ~= 'string' then return end
        local entry = pending[requestId]
        if not entry then return end
        local safePayload
        if ok == true then
            safePayload = normalizePacked(payload)
        elseif ok == false then
            safePayload = copyDto(payload, 'object', MAX_ERROR_BYTES)
        end
        if not safePayload then
            ok = false
            safePayload = {
                code = 'CALLBACK_RESPONSE_INVALID',
                message = 'Compatibility callback response was invalid.',
                retryable = false,
            }
        end
        pending[requestId] = nil
        pendingCount = math.max(0, pendingCount - 1)
        entry(ok == true, safePayload)
    end)

    if isCallable(AddEventHandler) and isCallable(GetCurrentResourceName) then
        local named, clientResource = pcall(GetCurrentResourceName)
        if named and type(clientResource) == 'string' then
            AddEventHandler('onClientResourceStop', function(stoppedResource)
                if stoppedResource ~= clientResource then return end
                stopped = true
                pending = {}
                pendingCount = 0
            end)
        end
    end

    local client = {}
    function client:triggerCallback(consumer, name, callback, ...)
        if stopped or not validConsumer(consumer) or not validCallbackName(name)
            or not isCallable(callback)
            or pendingCount >= MAX_PENDING then return false end
        sequence = (sequence + 1) & 0xffffffff
        local requestId = ('%08x_%08x'):format(GetGameTimer() & 0xffffffff, sequence)
        local arguments = normalizePacked(table.pack(...))
        if not arguments then return false end
        pending[requestId] = function(ok, payload)
            if not isCallable(callback) then return false end
            if ok then
                return pcall(function()
                    callback(table.unpack(payload, 1, rawlen(payload)))
                end)
            end
            return pcall(function() callback(nil, payload) end)
        end
        pendingCount = pendingCount + 1
        SetTimeout(TIMEOUT_MS, function()
            local entry = pending[requestId]
            if not entry then return end
            pending[requestId] = nil
            pendingCount = math.max(0, pendingCount - 1)
            entry(false, { code = 'CALLBACK_TIMEOUT', message = 'Compatibility callback timed out.', retryable = true })
        end)
        local sent = pcall(TriggerServerEvent, requestEvent,
            requestId, consumer, name, arguments)
        if not sent then
            pending[requestId] = nil
            pendingCount = math.max(0, pendingCount - 1)
            return false
        end
        return true
    end

    return client
end

SynexBridgeClient = Client

return Client
