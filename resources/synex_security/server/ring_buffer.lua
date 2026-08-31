SynexSecurityRingBuffer = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local RingBuffer = SynexSecurityRingBuffer

function RingBuffer.create(options)
    options = options or {}
    local capacity = options.capacity or Limits.maximumSignalBuffer
    assert(Validation.isInteger(capacity, 1, Limits.maximumCorrelationBuffer),
        'security ring buffer capacity is invalid')
    local now = Validation.isCallable(options.now) and options.now or function() return 0 end
    local keyOf = Validation.isCallable(options.keyOf) and options.keyOf or nil
    local timestampOf = Validation.isCallable(options.timestampOf)
        and options.timestampOf or function(item)
            return item.observedAt or item.updatedAt or item.issuedAt or item.at
        end
    local retentionMs = options.retentionMs
    assert(retentionMs == nil or Validation.isInteger(retentionMs, 1,
        Limits.maximumSafeInteger), 'security ring buffer retention is invalid')
    local onEvict = Validation.isCallable(options.onEvict) and options.onEvict or nil
    local entries, byKey, head, count = {}, {}, 1, 0
    local api = {}

    local function evictOldest(reason)
        if count == 0 then return nil end
        local item = entries[head]
        entries[head] = nil
        if keyOf ~= nil then
            local key = keyOf(item)
            if key ~= nil and byKey[key] == item then byKey[key] = nil end
        end
        head = head % capacity + 1
        count = count - 1
        if onEvict ~= nil then pcall(onEvict, item, reason) end
        return item
    end

    function api.prune(at)
        if retentionMs == nil then return 0 end
        local timestamp, removed = at or now(), 0
        while count > 0 do
            local item = entries[head]
            local observedAt = timestampOf(item)
            if not Validation.isInteger(observedAt, 0, Limits.maximumSafeInteger)
                or timestamp - observedAt <= retentionMs then break end
            evictOldest('expired')
            removed = removed + 1
        end
        return removed
    end

    function api.push(item)
        if item == nil then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'A security ring buffer cannot store nil.')
        end
        api.prune(now())
        local key = keyOf ~= nil and keyOf(item) or nil
        if key ~= nil and byKey[key] ~= nil then
            return Validation.failure('SECURITY_DUPLICATE',
                'A security ring buffer key is already present.')
        end
        if count == capacity then evictOldest('capacity') end
        local index = (head + count - 1) % capacity + 1
        entries[index], count = item, count + 1
        if key ~= nil then byKey[key] = item end
        return item, nil
    end

    function api.get(key)
        api.prune(now())
        return byKey[key]
    end

    function api.remove(key, reason)
        if keyOf == nil then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'This security ring buffer does not expose keyed removal.')
        end
        api.prune(now())
        local item = byKey[key]
        if item == nil then return nil, nil end
        local found = nil
        for offset = 0, count - 1 do
            local index = (head + offset - 1) % capacity + 1
            if entries[index] == item then found = offset; break end
        end
        if found == nil then byKey[key] = nil; return nil, nil end
        for offset = found, count - 2 do
            local current = (head + offset - 1) % capacity + 1
            local following = (head + offset) % capacity + 1
            entries[current] = entries[following]
        end
        entries[(head + count - 2) % capacity + 1] = nil
        byKey[key], count = nil, count - 1
        if onEvict ~= nil then pcall(onEvict, item, reason or 'removed') end
        return item, nil
    end

    function api.list(request)
        request = request or {}
        api.prune(request.now or now())
        local limit = request.limit or count
        if not Validation.isInteger(limit, 0, capacity) then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'The security ring buffer page limit is invalid.')
        end
        local newestFirst = request.newestFirst ~= false
        local predicate = Validation.isCallable(request.predicate) and request.predicate or nil
        local values = {}
        for offset = 0, count - 1 do
            local logical = newestFirst and count - 1 - offset or offset
            local item = entries[(head + logical - 1) % capacity + 1]
            if predicate == nil or predicate(item) then
                values[#values + 1] = item
                if #values >= limit then break end
            end
        end
        return values, nil
    end

    function api.values()
        return api.list({ limit = count, newestFirst = false })
    end

    function api.clear(reason)
        local removed = count
        while count > 0 do evictOldest(reason or 'cleared') end
        head = 1
        return removed
    end

    function api.size()
        api.prune(now())
        return count
    end

    function api.snapshot()
        api.prune(now())
        local oldest, newest = nil, nil
        if count > 0 then
            oldest = timestampOf(entries[head])
            newest = timestampOf(entries[(head + count - 2) % capacity + 1])
        end
        return {
            count = count,
            capacity = capacity,
            retentionMs = retentionMs,
            oldestAt = oldest,
            newestAt = newest,
        }
    end

    return api
end
