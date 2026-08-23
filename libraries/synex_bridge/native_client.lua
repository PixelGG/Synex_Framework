local Client = {}

local MAX_PENDING = 32
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

function Client.create(options)
    assert(type(options) == 'table', 'native bridge client options are required')
    local requestEvent = assert(options.requestEvent, 'requestEvent is required')
    local responseEvent = assert(options.responseEvent, 'responseEvent is required')
    local pending = {}
    local pendingCount = 0
    local sequence = 0

    RegisterNetEvent(responseEvent, function(requestId, ok, payload)
        if source ~= 65535 or type(requestId) ~= 'string' then return end
        local entry = pending[requestId]
        if not entry then return end
        pending[requestId] = nil
        pendingCount = math.max(0, pendingCount - 1)
        entry(ok == true, payload)
    end)

    local client = {}
    function client:triggerCallback(name, callback, ...)
        if type(name) ~= 'string' or #name < 1 or #name > 96 or not isCallable(callback)
            or pendingCount >= MAX_PENDING then return false end
        sequence = (sequence + 1) & 0xffffffff
        local requestId = ('%08x_%08x'):format(GetGameTimer() & 0xffffffff, sequence)
        local arguments = table.pack(...)
        pending[requestId] = function(ok, payload)
            if not isCallable(callback) then return false end
            if ok and type(payload) == 'table' then
                return pcall(function()
                    callback(table.unpack(payload, 1, payload.n or #payload))
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
        TriggerServerEvent(requestEvent, requestId, name, arguments)
        return true
    end

    return client
end

SynexBridgeClient = Client

return Client
