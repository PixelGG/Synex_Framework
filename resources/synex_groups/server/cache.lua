return function(Foundation)
local valueCopyLimits = { maximumDepth = 12, maximumKeys = 4096, maximumStringBytes = 16384 }
local function createCache(options)
    options = options or {}
    local maximum = math.max(16, math.min(tonumber(options.maximum) or 512, 4096))
    local ttlMs = math.max(250, math.min(tonumber(options.ttlMs) or 5000, 60000))
    local now = options.now or function() return os.time() * 1000 end
    local entries, size = {}, 0
    local counters = { hits = 0, misses = 0, rebuilds = 0, invalidations = 0, evictions = 0 }

    local function validKey(key)
        return type(key) == 'string' and #key >= 1 and #key <= 192
            and key:find('[%z\1-\31\127]') == nil
    end

    local function remove(key, invalidation)
        if entries[key] == nil then return false end
        entries[key] = nil
        size = math.max(0, size - 1)
        if invalidation then counters.invalidations = counters.invalidations + 1 end
        return true
    end

    local function evictOldest()
        local oldestKey, oldestTouched
        for key, entry in pairs(entries) do
            if oldestTouched == nil or entry.touchedAt < oldestTouched then
                oldestKey, oldestTouched = key, entry.touchedAt
            end
        end
        if oldestKey then
            remove(oldestKey, false)
            counters.evictions = counters.evictions + 1
        end
    end

    local cache = {}
    function cache:get(key)
        if not validKey(key) then return nil end
        local entry = entries[key]
        local current = now()
        if not entry or entry.expiresAt <= current then
            if entry then remove(key, false) end
            counters.misses = counters.misses + 1
            return nil
        end
        entry.touchedAt = current
        counters.hits = counters.hits + 1
        return Foundation.copyPlain(entry.value, valueCopyLimits)
    end

    function cache:put(key, value, lifetimeMs)
        if not validKey(key) then
            return nil, Foundation.domainError('INVALID_CACHE_KEY', 'Cache keys must be bounded printable strings.')
        end
        local copiedOk, copied = pcall(Foundation.copyPlain, value, valueCopyLimits)
        if not copiedOk then
            return nil, Foundation.domainError('INVALID_CACHE_VALUE', 'Cache values must be bounded plain JSON data.')
        end
        local lifetime = lifetimeMs == nil and ttlMs or tonumber(lifetimeMs)
        if not lifetime or math.type(lifetime) ~= 'integer' or lifetime < 0 or lifetime > 60000 then
            return nil, Foundation.domainError('INVALID_CACHE_TTL', 'Cache TTL must be an integer from 0 through 60000 milliseconds.')
        end
        if entries[key] == nil then
            if size >= maximum then evictOldest() end
            size = size + 1
        end
        local current = now()
        entries[key] = { value = copied, expiresAt = current + lifetime, touchedAt = current }
        counters.rebuilds = counters.rebuilds + 1
        return true, nil
    end

    function cache:invalidate(key)
        if key == nil then
            local removed = size
            entries, size = {}, 0
            counters.invalidations = counters.invalidations + removed
            return removed
        end
        return remove(key, true) and 1 or 0
    end

    function cache:invalidatePrefix(prefix)
        if not validKey(prefix) then return 0 end
        local keys = {}
        for key in pairs(entries) do
            if key:sub(1, #prefix) == prefix then keys[#keys + 1] = key end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do remove(key, true) end
        return #keys
    end

    function cache:snapshot()
        return {
            size = size,
            maximum = maximum,
            ttlMs = ttlMs,
            hits = counters.hits,
            misses = counters.misses,
            rebuilds = counters.rebuilds,
            invalidations = counters.invalidations,
            evictions = counters.evictions
        }
    end

    return cache
end

return createCache
end
