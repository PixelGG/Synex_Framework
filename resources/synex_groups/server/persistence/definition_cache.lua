return function(Foundation)
local function create(options)
    options = options or {}
    if type(options) ~= 'table' or getmetatable(options) ~= nil then
        error('groups definition cache options are invalid', 2)
    end
    local maximum = tonumber(options.maximum) or 256
    if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
        or maximum < 16 or maximum > 2048 then
        error('groups definition cache options are invalid', 2)
    end

    local entries, size, sequence = {}, 0, 0
    local counters = {
        hits = 0,
        misses = 0,
        writes = 0,
        invalidations = 0,
        evictions = 0,
        clears = 0
    }

    local function validSegment(value, maximumLength)
        return type(value) == 'string' and #value >= 1 and #value <= maximumLength
            and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
    end

    local function validRevision(value)
        return type(value) == 'number' and math.type(value) == 'integer'
            and value >= 1 and value <= 9007199254740991
    end

    local function keyFor(namespace, identity, revision)
        if not validSegment(namespace, 32) or not validSegment(identity, 256)
            or not validRevision(revision) then
            return nil
        end
        return namespace .. ':' .. identity .. ':' .. tostring(revision)
    end

    local function remove(key, invalidation)
        if entries[key] == nil then return false end
        entries[key] = nil
        size = size - 1
        if invalidation then
            counters.invalidations = counters.invalidations + 1
        end
        return true
    end

    local function evictOldest()
        local oldestKey, oldestSequence
        for key, entry in pairs(entries) do
            if oldestSequence == nil or entry.sequence < oldestSequence then
                oldestKey, oldestSequence = key, entry.sequence
            end
        end
        if oldestKey ~= nil then
            remove(oldestKey, false)
            counters.evictions = counters.evictions + 1
        end
    end

    local cache = {}

    function cache:get(namespace, identity, revision)
        local key = keyFor(namespace, identity, revision)
        if key == nil then
            counters.misses = counters.misses + 1
            return nil
        end
        local entry = entries[key]
        if entry == nil then
            counters.misses = counters.misses + 1
            return nil
        end
        counters.hits = counters.hits + 1
        local copied, value = pcall(Foundation.copyPlain, entry.value, {
            maximumDepth = 12,
            maximumKeys = 4096,
            maximumStringBytes = 16384,
            preserveContainerKind = false
        })
        if not copied then
            remove(key, true)
            return nil
        end
        return value
    end

    function cache:put(namespace, identity, revision, value)
        local key = keyFor(namespace, identity, revision)
        if key == nil then
            return nil, Foundation.domainError('INVALID_CACHE_KEY',
                'Definition cache identity or revision is invalid.')
        end
        if type(value) ~= 'table' then
            return nil, Foundation.domainError('INVALID_CACHE_VALUE',
                'Definition cache values must be bounded plain data.')
        end
        local copied, bounded = pcall(Foundation.copyPlain, value, {
            maximumDepth = 12,
            maximumKeys = 4096,
            maximumStringBytes = 16384,
            preserveContainerKind = false
        })
        if not copied then
            return nil, Foundation.domainError('INVALID_CACHE_VALUE',
                'Definition cache values must be bounded plain data.')
        end
        if entries[key] == nil then
            if size >= maximum then evictOldest() end
            size = size + 1
        end
        sequence = sequence + 1
        entries[key] = { value = bounded, sequence = sequence }
        counters.writes = counters.writes + 1
        return true, nil
    end

    function cache:invalidate(namespace, identity)
        if identity ~= nil and namespace == nil
            or (namespace ~= nil and not validSegment(namespace, 32))
            or (identity ~= nil and not validSegment(identity, 256)) then
            return 0
        end
        local prefix
        if namespace ~= nil then
            prefix = namespace .. ':'
            if identity ~= nil then prefix = prefix .. identity .. ':' end
        end
        local keys = {}
        for key in pairs(entries) do
            if prefix == nil or key:sub(1, #prefix) == prefix then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do remove(key, true) end
        return #keys
    end

    function cache:invalidateGroup(groupId)
        if not Foundation.isPublicId(groupId) then return 0 end
        local identity = groupId
        local removed = 0
        for _, namespace in ipairs({ 'group_defaults', 'grade_rules', 'role_sources', 'policy_rules' }) do
            removed = removed + self:invalidate(namespace, identity)
        end
        return removed
    end

    function cache:clear()
        local removed = size
        entries, size = {}, 0
        counters.invalidations = counters.invalidations + removed
        counters.clears = counters.clears + 1
        return removed
    end

    function cache:snapshot()
        return {
            size = size,
            maximum = maximum,
            hits = counters.hits,
            misses = counters.misses,
            writes = counters.writes,
            invalidations = counters.invalidations,
            evictions = counters.evictions,
            clears = counters.clears
        }
    end

    return cache
end

return create
end
