SynexEntitySpawnAdmission = {}

local ENTITY_TYPES = { object = true, ped = true, vehicle = true }

local function finiteInteger(value, minimum)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= minimum and value ~= math.huge and value ~= -math.huge
end

local function keyFor(...)
    local values = { ... }
    for index = 1, #values do values[index] = tostring(values[index]) end
    return table.concat(values, '\31')
end

function SynexEntitySpawnAdmission.create(options)
    assert(type(options) == 'table', 'entity spawn admission options are required')
    local config = assert(options.config, 'entity spawn admission config is required')
    local observability = assert(options.observability,
        'entity spawn admission observability is required')
    local ports = assert(options.ports, 'entity spawn admission ports are required')
    local registry = assert(options.registry, 'entity spawn admission registry is required')
    local state = assert(options.state, 'entity spawn admission state is required')
    assert(type(config.maxTypeEntities) == 'table', 'entity type quotas are required')
    assert(type(config.spawnRateLimits) == 'table', 'entity spawn rate limits are required')
    assert(finiteInteger(config.maxEntities, 1)
        and finiteInteger(config.maxOwnerEntities, 1)
        and finiteInteger(config.maxLogicalOwnerEntities, 1)
        and finiteInteger(config.maxBucketEntities, 1)
        and finiteInteger(config.maxPersistentEntities, 1)
        and finiteInteger(config.maxBuckets, 1)
        and finiteInteger(config.maxOwnerBuckets, 1)
        and finiteInteger(config.maxBucketPlayers, 1),
        'entity quotas are invalid')
    assert(finiteInteger(config.spawnRateWindowMs, 1000)
        and finiteInteger(config.spawnRateMaxEntries, 1)
        and finiteInteger(config.spawnRateMaxScopes, 1),
        'entity spawn rate bounds are invalid')
    for entityType in pairs(ENTITY_TYPES) do
        assert(finiteInteger(config.maxTypeEntities[entityType], 1)
            and finiteInteger(config.spawnRateLimits[entityType], 1),
            'entity type admission limits are invalid')
    end

    local pending = {
        bucket = {}, logicalOwner = {}, persistent = 0,
        resource = {}, total = 0, type = {},
    }
    local rateScopes = {}
    local rateEntryCount = 0
    local rateScopeCount = 0
    local lastTimer
    local service = {}

    local function countValues(values)
        local total = 0
        for _ in pairs(values or {}) do total = total + 1 end
        return total
    end

    local function percentage(value, limit)
        return math.floor((value * 10000 / limit) + 0.5) / 100
    end

    local function quotaValues(current, reserved, limit)
        local effective = current + reserved
        return {
            current = current,
            limit = limit,
            pending = reserved,
            remaining = math.max(0, limit - effective),
            usagePercent = percentage(effective, limit),
        }
    end

    local function boundedPage(values, limit, compare, project)
        local keys = {}
        for key in pairs(values) do keys[#keys + 1] = key end
        table.sort(keys, compare)
        local items = {}
        for index = 1, math.min(#keys, limit) do
            items[index] = project(keys[index], values[keys[index]])
        end
        return {
            items = items,
            returned = #items,
            total = #keys,
            truncated = #keys > limit,
        }
    end

    local function denied(code, message, scope, limit, context, entityType)
        if code == 'SPAWN_RATE_LIMITED' or code == 'ENTITY_QUOTA_EXCEEDED' then
            local metric = code == 'SPAWN_RATE_LIMITED'
                and 'spawn_rate_denials' or 'quota_denials'
            local labels = { scope = scope }
            if code == 'SPAWN_RATE_LIMITED' then labels.entityType = entityType end
            observability.increment(metric, labels, 1)
            observability.increment(metric .. '_total', labels, 1)
            local target = type(context) == 'table' and context.caller or 'unknown'
            observability.audit('entities.quota_denied', 'resource', target, {
                code = code, entityType = entityType, limit = limit, scope = scope,
            }, context)
        end
        return nil, {
            code = code,
            details = { limit = limit, scope = scope },
            message = message,
            retryable = true,
        }
    end

    local function currentTypeCounts()
        local counts = { object = 0, ped = 0, persistent = 0, vehicle = 0 }
        for _, record in ipairs(registry.all()) do
            if ENTITY_TYPES[record.entityType] then
                counts[record.entityType] = counts[record.entityType] + 1
            end
            if record.persistent == true then counts.persistent = counts.persistent + 1 end
        end
        return counts
    end

    local function quota(caller, candidate, createsPersistent, context)
        local logicalKey = keyFor(candidate.owner.type, candidate.owner.id)
        local typeCounts = currentTypeCounts()
        local bucket = state.buckets[candidate.bucket]
        if bucket and bucket.destroying then
            return denied('STALE_BUCKET',
                'The target routing bucket is being destroyed',
                'bucket_lifecycle', 0, context, candidate.entityType)
        end
        local bucketLimit = config.maxBucketEntities
        if bucket and finiteInteger(bucket.maxEntities, 1) then
            bucketLimit = math.min(bucketLimit, bucket.maxEntities)
        end
        local checks = {
            { 'global_live', registry.count() + pending.total, config.maxEntities },
            { 'resource_live', #registry.forResource(caller)
                + (pending.resource[caller] or 0), config.maxOwnerEntities },
            { 'logical_owner_live', #registry.forLogicalOwner(
                candidate.owner.type, candidate.owner.id)
                + (pending.logicalOwner[logicalKey] or 0),
                config.maxLogicalOwnerEntities },
            { 'bucket_live', #registry.forBucket(candidate.bucket)
                + (pending.bucket[candidate.bucket] or 0), bucketLimit },
            { 'entity_type_live', typeCounts[candidate.entityType]
                + (pending.type[candidate.entityType] or 0),
                config.maxTypeEntities[candidate.entityType] },
        }
        if createsPersistent then
            checks[#checks + 1] = { 'persistent_total', typeCounts.persistent
                + pending.persistent, config.maxPersistentEntities }
        end
        for _, check in ipairs(checks) do
            if check[2] >= check[3] then
                return denied('ENTITY_QUOTA_EXCEEDED',
                    'The managed entity quota has been reached',
                    check[1], check[3], context, candidate.entityType)
            end
        end
        return logicalKey
    end

    local function pruneWindow(window, now)
        local times = window.times
        local previousHead = window.head
        while window.head <= #times
            and now - times[window.head] >= config.spawnRateWindowMs do
            window.head = window.head + 1
        end
        rateEntryCount = math.max(0, rateEntryCount - (window.head - previousHead))
        local active = #times - window.head + 1
        if active == 0 then
            window.times, window.head = {}, 1
            return 0
        end
        if window.head > 64 and window.head > #times / 2 then
            local compacted = {}
            for index = window.head, #times do
                compacted[#compacted + 1] = times[index]
            end
            window.times, window.head = compacted, 1
        end
        return active
    end

    local function pruneRateScopes(now)
        for scopeKey, window in pairs(rateScopes) do
            if pruneWindow(window, now) == 0 then
                rateScopes[scopeKey] = nil
                rateScopeCount = rateScopeCount - 1
            end
        end
    end

    local function takeRate(caller, candidate, context)
        local now = tonumber(ports.getGameTimer())
        if not now or now ~= now or now == math.huge or now == -math.huge then now = 0 end
        if lastTimer and now < lastTimer then
            rateScopes, rateEntryCount, rateScopeCount = {}, 0, 0
        end
        lastTimer = now
        local scopeKey = keyFor(caller, candidate.entityType, candidate.bucket)
        local window = rateScopes[scopeKey]
        if not window then
            if rateScopeCount >= config.spawnRateMaxScopes then pruneRateScopes(now) end
            if rateScopeCount >= config.spawnRateMaxScopes then
                return denied('SPAWN_RATE_LIMITED',
                    'The bounded spawn-rate scope budget has been reached',
                    'tracked_spawn_scopes', config.spawnRateMaxScopes,
                    context, candidate.entityType)
            end
            window = { head = 1, times = {} }
            rateScopes[scopeKey] = window
            rateScopeCount = rateScopeCount + 1
        end
        local active = pruneWindow(window, now)
        local limit = config.spawnRateLimits[candidate.entityType]
        if active >= limit then
            return denied('SPAWN_RATE_LIMITED',
                'The resource exceeded its bounded entity spawn budget',
                'resource_type_bucket_window', limit, context, candidate.entityType)
        end
        if rateEntryCount >= config.spawnRateMaxEntries then pruneRateScopes(now) end
        if rateEntryCount >= config.spawnRateMaxEntries then
            return denied('SPAWN_RATE_LIMITED',
                'The bounded spawn-rate entry budget has been reached',
                'tracked_spawn_entries', config.spawnRateMaxEntries,
                context, candidate.entityType)
        end
        window.times[#window.times + 1] = now
        rateEntryCount = rateEntryCount + 1
        return true
    end

    local function reserve(caller, candidate, logicalKey, createsPersistent)
        pending.total = pending.total + 1
        pending.resource[caller] = (pending.resource[caller] or 0) + 1
        pending.logicalOwner[logicalKey] = (pending.logicalOwner[logicalKey] or 0) + 1
        pending.bucket[candidate.bucket] = (pending.bucket[candidate.bucket] or 0) + 1
        pending.type[candidate.entityType] = (pending.type[candidate.entityType] or 0) + 1
        local bucket = state.buckets[candidate.bucket]
        if bucket then bucket.pendingSpawns = (bucket.pendingSpawns or 0) + 1 end
        if createsPersistent then pending.persistent = pending.persistent + 1 end
    end

    local function release(caller, candidate, logicalKey, createsPersistent)
        pending.total = math.max(0, pending.total - 1)
        local dimensions = {
            { pending.resource, caller },
            { pending.logicalOwner, logicalKey },
            { pending.bucket, candidate.bucket },
            { pending.type, candidate.entityType },
        }
        for _, dimension in ipairs(dimensions) do
            local values, key = dimension[1], dimension[2]
            values[key] = math.max(0, (values[key] or 1) - 1)
            if values[key] == 0 then values[key] = nil end
        end
        if createsPersistent then
            pending.persistent = math.max(0, pending.persistent - 1)
        end
        local bucket = state.buckets[candidate.bucket]
        if bucket then bucket.pendingSpawns = math.max(0, (bucket.pendingSpawns or 1) - 1) end
    end

    function service.withReservation(caller, candidate, context, handler, createsPersistent)
        assert(type(caller) == 'string' and caller ~= '', 'spawn admission caller is invalid')
        assert(type(candidate) == 'table' and type(candidate.owner) == 'table'
            and ENTITY_TYPES[candidate.entityType]
            and finiteInteger(candidate.bucket, 0), 'spawn admission candidate is invalid')
        assert(type(handler) == 'function', 'spawn admission handler is required')
        createsPersistent = createsPersistent == true
        local logicalKey, quotaError = quota(caller, candidate, createsPersistent, context)
        if not logicalKey then return nil, quotaError end
        local allowed, rateError = takeRate(caller, candidate, context)
        if not allowed then return nil, rateError end
        reserve(caller, candidate, logicalKey, createsPersistent)
        local values = table.pack(xpcall(handler, debug.traceback))
        release(caller, candidate, logicalKey, createsPersistent)
        if not values[1] then error(values[2], 0) end
        return table.unpack(values, 2, values.n)
    end

    function service.quotaSnapshot(limit)
        assert(finiteInteger(limit, 1) and limit <= 100,
            'entity quota snapshot limit is invalid')
        local live = {
            logicalOwner = {}, persistent = 0, resource = {}, total = registry.count(),
            type = { object = 0, ped = 0, vehicle = 0 }, bucket = {},
        }
        local logicalMetadata = {}
        for _, record in ipairs(registry.all()) do
            if ENTITY_TYPES[record.entityType] then
                live.type[record.entityType] = live.type[record.entityType] + 1
            end
            if record.persistent == true then live.persistent = live.persistent + 1 end
            live.resource[record.resourceOwner] = (live.resource[record.resourceOwner] or 0) + 1
            live.bucket[record.bucket] = (live.bucket[record.bucket] or 0) + 1
            if record.owner then
                local logicalKey = keyFor(record.owner.type, record.owner.id)
                live.logicalOwner[logicalKey] = (live.logicalOwner[logicalKey] or 0) + 1
                logicalMetadata[logicalKey] = {
                    ownerId = record.owner.id, ownerType = record.owner.type,
                }
            end
        end

        for logicalKey in pairs(pending.logicalOwner) do
            if not logicalMetadata[logicalKey] then
                local ownerType, ownerId = logicalKey:match('^(.-)\31(.*)$')
                logicalMetadata[logicalKey] = { ownerId = ownerId, ownerType = ownerType }
            end
        end
        for resourceOwner in pairs(pending.resource) do
            if live.resource[resourceOwner] == nil then live.resource[resourceOwner] = 0 end
        end
        for bucketId in pairs(pending.bucket) do
            if live.bucket[bucketId] == nil then live.bucket[bucketId] = 0 end
        end
        for logicalKey in pairs(pending.logicalOwner) do
            if live.logicalOwner[logicalKey] == nil then live.logicalOwner[logicalKey] = 0 end
        end

        local bucketsByResource = {}
        for _, bucket in pairs(state.buckets) do
            bucketsByResource[bucket.resourceOwner] =
                (bucketsByResource[bucket.resourceOwner] or 0) + 1
            if live.resource[bucket.resourceOwner] == nil then
                live.resource[bucket.resourceOwner] = 0
            end
            if live.bucket[bucket.id] == nil then live.bucket[bucket.id] = 0 end
        end

        local resources = boundedPage(live.resource, limit, nil,
            function(resourceOwner, current)
                local value = quotaValues(current, pending.resource[resourceOwner] or 0,
                    config.maxOwnerEntities)
                value.resourceOwner = resourceOwner
                value.managedBuckets = bucketsByResource[resourceOwner] or 0
                value.managedBucketLimit = config.maxOwnerBuckets
                value.managedBucketUsagePercent = percentage(
                    value.managedBuckets, config.maxOwnerBuckets)
                return value
            end)
        local logicalOwners = boundedPage(live.logicalOwner, limit, nil,
            function(logicalKey, current)
                local value = quotaValues(current, pending.logicalOwner[logicalKey] or 0,
                    config.maxLogicalOwnerEntities)
                value.ownerId = logicalMetadata[logicalKey].ownerId
                value.ownerType = logicalMetadata[logicalKey].ownerType
                return value
            end)
        local routingBuckets = boundedPage(live.bucket, limit,
            function(left, right) return left < right end,
            function(bucketId, current)
                local bucket = state.buckets[bucketId]
                local bucketLimit = config.maxBucketEntities
                if bucket and finiteInteger(bucket.maxEntities, 1) then
                    bucketLimit = math.min(bucketLimit, bucket.maxEntities)
                end
                local value = quotaValues(current, pending.bucket[bucketId] or 0, bucketLimit)
                value.bucket = bucketId
                value.managed = bucket ~= nil
                if bucket then
                    value.destroying = bucket.destroying == true
                    value.players = countValues(bucket.players)
                    value.playerLimit = config.maxBucketPlayers
                    if finiteInteger(bucket.maxPlayers, 1) then
                        value.playerLimit = math.min(value.playerLimit, bucket.maxPlayers)
                    end
                    value.playerUsagePercent = percentage(value.players, value.playerLimit)
                end
                return value
            end)
        local entityTypes = {}
        for _, entityType in ipairs({ 'object', 'ped', 'vehicle' }) do
            local value = quotaValues(live.type[entityType], pending.type[entityType] or 0,
                config.maxTypeEntities[entityType])
            value.entityType = entityType
            entityTypes[#entityTypes + 1] = value
        end
        local managedBucketCount = countValues(state.buckets)
        return {
            entityTypes = entityTypes,
            global = quotaValues(live.total, pending.total, config.maxEntities),
            logicalOwners = logicalOwners,
            managedBuckets = {
                current = managedBucketCount,
                limit = config.maxBuckets,
                remaining = math.max(0, config.maxBuckets - managedBucketCount),
                usagePercent = percentage(managedBucketCount, config.maxBuckets),
            },
            persistent = quotaValues(live.persistent, pending.persistent,
                config.maxPersistentEntities),
            reservations = {
                pending = pending.total,
                pendingPersistent = pending.persistent,
                trackedRateEntries = rateEntryCount,
                trackedRateScopes = rateScopeCount,
            },
            resources = resources,
            routingBuckets = routingBuckets,
        }
    end

    function service.snapshot()
        return {
            pending = pending.total,
            pendingPersistent = pending.persistent,
            trackedRateEntries = rateEntryCount,
            trackedRateScopes = rateScopeCount,
        }
    end

    return service
end
