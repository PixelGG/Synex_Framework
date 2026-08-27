SynexEntityBucketPolicy = {}

local PRESETS = {
    isolated_strict = { lockdown = 'strict', populationEnabled = false },
    session = { lockdown = 'strict', populationEnabled = false },
    character_selection = { lockdown = 'strict', populationEnabled = false },
}

local LOCKDOWN = { inactive = true, relaxed = true, strict = true }

local function leapYear(year)
    return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local function validUtcTimestamp(value)
    if type(value) ~= 'string' then return false end
    local year, month, day, hour, minute, second = value:match(
        '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$'
    )
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if not year or year < 1970 or not month or month < 1 or month > 12
        or not day or not hour or hour > 23 or not minute or minute > 59
        or not second or second > 59 then return false end
    local days = { 31, leapYear(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return day >= 1 and day <= days[month]
end

function SynexEntityBucketPolicy.create(options)
    assert(type(options) == 'table', 'bucket policy options are required')
    local config = assert(options.config, 'bucket policy config is required')
    local foundation = assert(options.foundation, 'bucket policy foundation is required')
    local utcNow = options.utcNow or function() return os.date('!%Y-%m-%dT%H:%M:%SZ') end
    local policy = {}

    local function failure(code, message, context)
        return foundation.failure(code, message, false, context)
    end

    local function validPurpose(value)
        return type(value) == 'string' and #value >= 1 and #value <= 64
            and value:find('[%c]') == nil
    end

    local function capacity(value, context)
        local maximumPlayers = math.min(config.maxBucketPlayers, 2048)
        local maximumEntities = math.min(config.maxBucketEntities, 10000)
        if value == nil then
            return { maxPlayers = maximumPlayers, maxEntities = maximumEntities }
        end
        if type(value) ~= 'table' or getmetatable(value) ~= nil then
            return failure('INVALID_ARGUMENT', 'Bucket capacity must be a plain object', context)
        end
        for key in pairs(value) do
            if key ~= 'maxPlayers' and key ~= 'maxEntities' then
                return failure('INVALID_ARGUMENT', 'Bucket capacity contains an unknown field', context)
            end
        end
        if type(value.maxPlayers) ~= 'number' or value.maxPlayers % 1 ~= 0
            or value.maxPlayers < 1 or value.maxPlayers > 2048
            or type(value.maxEntities) ~= 'number' or value.maxEntities % 1 ~= 0
            or value.maxEntities < 1 or value.maxEntities > 10000 then
            return failure('INVALID_ARGUMENT', 'Bucket capacity is invalid', context)
        end
        if value.maxPlayers > maximumPlayers or value.maxEntities > maximumEntities then
            return failure(
                'BUCKET_CAPACITY_EXCEEDED',
                'Bucket capacity exceeds the server policy',
                context
            )
        end
        return { maxPlayers = value.maxPlayers, maxEntities = value.maxEntities }
    end

    function policy.normalizeCreate(request, context)
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return failure('INVALID_ARGUMENT', 'Bucket request must be a plain object', context)
        end
        local isV1 = type(context) == 'table' and context.version == '1.0.0'
        if context == nil or context.version == nil then isV1 = request.profile == nil end
        local allowed = isV1 and { purpose = true } or {
            capacity = true,
            expiresAt = true,
            lockdown = true,
            populationEnabled = true,
            profile = true,
            purpose = true,
        }
        for key in pairs(request) do
            if not allowed[key] then
                return failure('INVALID_ARGUMENT', 'Bucket request contains an unknown field', context)
            end
        end
        if isV1 then
            if request.purpose ~= nil and not validPurpose(request.purpose) then
                return failure('INVALID_ARGUMENT', 'Bucket purpose is invalid', context)
            end
            return {
                capacity = assert(capacity(nil, context)),
                lockdown = PRESETS.isolated_strict.lockdown,
                populationEnabled = PRESETS.isolated_strict.populationEnabled,
                profile = 'isolated_strict',
                purpose = request.purpose or 'unspecified',
            }
        end

        if not validPurpose(request.purpose) then
            return failure('INVALID_ARGUMENT', 'Bucket purpose is invalid', context)
        end
        if request.profile ~= 'custom' and PRESETS[request.profile] == nil then
            return failure('INVALID_ARGUMENT', 'Bucket profile is invalid', context)
        end
        local preset = PRESETS[request.profile]
        local lockdown, populationEnabled
        if request.profile == 'custom' then
            if not LOCKDOWN[request.lockdown] or type(request.populationEnabled) ~= 'boolean' then
                return failure(
                    'INVALID_ARGUMENT',
                    'Custom buckets require valid lockdown and population settings',
                    context
                )
            end
            lockdown, populationEnabled = request.lockdown, request.populationEnabled
        else
            if request.lockdown ~= nil or request.populationEnabled ~= nil then
                return failure(
                    'INVALID_ARGUMENT',
                    'Preset bucket policy cannot be overridden',
                    context
                )
            end
            lockdown, populationEnabled = preset.lockdown, preset.populationEnabled
        end
        local normalizedCapacity, capacityError = capacity(request.capacity, context)
        if not normalizedCapacity then return nil, capacityError end
        if request.expiresAt ~= nil then
            if not validUtcTimestamp(request.expiresAt) or request.expiresAt <= utcNow() then
                return failure('INVALID_ARGUMENT', 'Bucket expiry must be a future UTC timestamp', context)
            end
        end
        return {
            capacity = normalizedCapacity,
            expiresAt = request.expiresAt,
            lockdown = lockdown,
            populationEnabled = populationEnabled,
            profile = request.profile,
            purpose = request.purpose,
        }
    end

    function policy.snapshot(bucket)
        return {
            bucket = { bucket = bucket.id, generation = bucket.generation },
            capacity = {
                maxEntities = bucket.maxEntities,
                maxPlayers = bucket.maxPlayers,
            },
            createdAt = bucket.createdAt,
            entities = foundation.tableCount(bucket.entities),
            expiresAt = bucket.expiresAt,
            health = bucket.health or 'READY',
            lockdown = bucket.lockdown,
            ownerResource = bucket.resourceOwner,
            players = foundation.tableCount(bucket.players),
            populationEnabled = bucket.populationEnabled,
            profile = bucket.profile,
            purpose = bucket.purpose,
        }
    end

    function policy.isExpired(bucket)
        return type(bucket) == 'table' and bucket.expiresAt ~= nil
            and bucket.expiresAt <= utcNow()
    end

    return policy
end
