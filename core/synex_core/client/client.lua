local protocol = assert(SynexProtocol, 'Synex protocol is unavailable')
local pending = {}
local sequence = 0

local function requestId()
    sequence = sequence + 1
    return ('client_%08x_%06x'):format(GetGameTimer() & 0xffffffff, sequence & 0xffffff)
end

local function countPending()
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
end

local function call(name, version, payload, options)
    options = options or {}
    if type(name) ~= 'string' or type(version) ~= 'string' or type(payload) ~= 'table' then
        return nil, { code = 'INVALID_ARGUMENT', message = 'Contract name, version, and object payload are required.', retryable = false }
    end
    if countPending() >= 16 then
        return nil, { code = 'CLIENT_BACKPRESSURE', message = 'Too many client RPC requests are pending.', retryable = true }
    end
    local id = requestId()
    local timeoutMs = math.max(100, math.min(tonumber(options.timeoutMs) or 5000, 15000))
    local deferred = promise.new()
    pending[id] = { deferred = deferred, settled = false }
    TriggerServerEvent(protocol.events.request, {
        wire = protocol.wire,
        requestId = id,
        procedure = name,
        version = version,
        payload = payload,
        traceId = options.traceId,
        deadlineMs = timeoutMs,
        idempotencyKey = options.idempotencyKey
    })
    SetTimeout(timeoutMs, function()
        local entry = pending[id]
        if not entry or entry.settled then return end
        entry.settled = true
        pending[id] = nil
        TriggerServerEvent(protocol.events.cancel, id)
        entry.deferred:resolve({ ok = false, error = {
            code = 'TIMEOUT', message = 'The RPC request timed out.', retryable = true
        } })
    end)
    local response = Citizen.Await(deferred)
    if response.ok then return response.value, nil end
    return nil, response.error
end

RegisterNetEvent(protocol.events.response, function(response)
    if source ~= 65535 then return end
    if type(response) ~= 'table' or response.wire ~= protocol.wire or type(response.requestId) ~= 'string' then return end
    local entry = pending[response.requestId]
    if not entry or entry.settled then return end
    entry.settled = true
    pending[response.requestId] = nil
    if response.ok ~= true then
        local err = type(response.error) == 'table' and response.error or {
            code = 'INVALID_RESPONSE', message = 'The server returned an invalid RPC response.', retryable = false
        }
        entry.deferred:resolve({ ok = false, error = err })
        return
    end
    entry.deferred:resolve({ ok = true, value = response.value })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for id, entry in pairs(pending) do
        if not entry.settled then
            entry.settled = true
            entry.deferred:resolve({ ok = false, error = {
                code = 'RESOURCE_STOPPED', message = 'The Synex client transport stopped.', retryable = true
            } })
        end
        pending[id] = nil
    end
end)

exports('Call', call)
