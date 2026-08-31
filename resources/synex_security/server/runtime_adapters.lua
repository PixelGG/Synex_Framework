SynexSecurityRuntimeAdapters = {}

local Validation = assert(SynexSecurityValidation,
    'security validation must be loaded first')
local Adapters = SynexSecurityRuntimeAdapters

local ENTITY_TYPES = { ped = 1, vehicle = 2, object = 3 }

local function hash(value)
    value = tonumber(value)
    if not Validation.isInteger(value, -2147483648, 4294967295) then return nil end
    return value % 4294967296
end

function Adapters.create(options)
    options = options or {}
    local now = assert(options.now, 'security adapter clock is required')
    local ports = options.ports or {}
    local intentTtlMs = math.max(250, math.min(5000,
        tonumber(options.intentTtlMs) or 2000))
    local maximumIntents = math.max(16, math.min(512,
        tonumber(options.maximumIntents) or 128))
    local maximumBuckets = math.max(32, math.min(256,
        tonumber(options.maximumBuckets) or 128))
    local intents, lifecycle, buckets = {}, {}, {}
    local api = {}

    local function safe(handler, ...)
        if not Validation.isCallable(handler) then return nil end
        local ok, value = pcall(handler, ...)
        if not ok then return nil end
        return value
    end

    local function pedState(source)
        local ped = tonumber(safe(ports.getPlayerPed, source))
        if not Validation.isInteger(ped, 1, 2147483647)
            or safe(ports.doesEntityExist, ped) ~= true then return nil end
        return {
            ped = ped,
            dead = safe(ports.isEntityDead, ped) == true,
            model = hash(safe(ports.getEntityModel, ped)),
            maximumHealth = tonumber(safe(ports.getEntityMaxHealth, ped)),
        }
    end

    local function sessionKey(session)
        if type(session) ~= 'table'
            or not Validation.isInteger(session.source, 1, 65535)
            or not Validation.isInteger(session.sourceGeneration, 1,
                9007199254740991) then return nil end
        return tostring(session.source) .. ':' .. tostring(session.sourceGeneration)
    end

    function api.expectedPlayerState(session)
        local state = pedState(session and session.source)
        if state == nil then return {} end
        local result = {}
        if state.model ~= nil then result.model = state.model end
        if Validation.isInteger(state.maximumHealth, 1, 100000) then
            result.maximumHealth = state.maximumHealth
        end
        return result
    end

    function api.movementContext(session, bucket)
        local key = sessionKey(session)
        if key == nil then return {} end
        local current = pedState(session.source)
        local previous = lifecycle[key]
        local result = {
            spawning = previous == nil or current == nil,
            respawning = false,
            instanceTransition = previous ~= nil and bucket ~= nil
                and previous.bucket ~= nil and previous.bucket ~= bucket,
        }
        if previous ~= nil and current ~= nil then
            result.respawning = previous.ped ~= current.ped
                or previous.dead == true and current.dead == false
        end
        lifecycle[key] = {
            ped = current and current.ped or nil,
            dead = current and current.dead or true,
            bucket = bucket,
            updatedAt = now(),
        }
        return result
    end

    function api.cleanupSource(source, generation)
        if not Validation.isInteger(source, 1, 65535) then return false end
        if generation ~= nil then
            lifecycle[tostring(source) .. ':' .. tostring(generation)] = nil
        else
            local prefix = tostring(source) .. ':'
            for key in pairs(lifecycle) do
                if key:sub(1, #prefix) == prefix then lifecycle[key] = nil end
            end
        end
        return true
    end

    local function pruneIntents(timestamp)
        while intents[1] ~= nil and intents[1].expiresAt <= timestamp do
            table.remove(intents, 1)
        end
        while #intents > maximumIntents do table.remove(intents, 1) end
    end

    function api.recordSpawnIntent(value)
        if type(value) ~= 'table' or type(value.request) ~= 'table'
            or not Validation.resourceName(value.caller) then return false end
        local request = value.request
        local model = hash(request.model)
        local entityType = ENTITY_TYPES[request.entityType]
        local bucket = request.bucket == nil and 0 or tonumber(request.bucket)
        if model == nil or entityType == nil
            or not Validation.isInteger(bucket, 0, 2147483647) then return false end
        local timestamp = now()
        pruneIntents(timestamp)
        intents[#intents + 1] = {
            resource = value.caller, model = model, entityType = entityType,
            bucket = bucket, expiresAt = timestamp + intentTtlMs,
        }
        pruneIntents(timestamp)
        return true
    end

    function api.authorizeEntity(observation)
        if type(observation) ~= 'table' or observation.creator ~= 0 then return nil end
        local timestamp = now()
        pruneIntents(timestamp)
        local model, entityType = hash(observation.model), tonumber(observation.entityType)
        for index, intent in ipairs(intents) do
            if intent.model == model and intent.entityType == entityType then
                table.remove(intents, index)
                return {
                    allowed = true, deterministic = true, policy = 'managed',
                    -- Cfx fires entityCreating before synex_entities applies the
                    -- requested routing bucket. Keep the target as provenance
                    -- evidence only; lifecycle events validate the final bucket.
                    targetBucket = intent.bucket,
                    authorityResource = intent.resource,
                    provenanceMatched = true,
                }
            end
        end
        return nil
    end

    function api.observeBucket(id, metadata)
        if not Validation.isInteger(id, 0, 2147483647) then return false end
        metadata = type(metadata) == 'table' and metadata or {}
        local current = buckets[id] or { id = id, mode = 'unknown', controlled = false }
        local mode = type(metadata.mode) == 'string' and metadata.mode:lower() or nil
        if mode == 'strict' or mode == 'relaxed' or mode == 'inactive'
            or mode == 'full' or mode == 'no_dummy' then current.mode = mode end
        if metadata.controlled == true then current.controlled = true end
        current.updatedAt = now()
        buckets[id] = current
        local count = 0
        for _ in pairs(buckets) do count = count + 1 end
        while count > maximumBuckets do
            local oldestId, oldestAt = nil, nil
            for candidateId, candidate in pairs(buckets) do
                if oldestAt == nil or candidate.updatedAt < oldestAt
                    or candidate.updatedAt == oldestAt and candidateId < oldestId then
                    oldestId, oldestAt = candidateId, candidate.updatedAt
                end
            end
            buckets[oldestId] = nil
            count = count - 1
        end
        return true
    end

    function api.observeDomainEvent(payload)
        if type(payload) ~= 'table' then return false end
        local bucket = payload.bucket
        local id = type(bucket) == 'table' and (bucket.id or bucket.bucket) or bucket
        local metadata = type(bucket) == 'table' and {
            mode = bucket.entityLockdown or bucket.lockdown or bucket.mode,
            controlled = bucket.managed == true or bucket.controlled == true,
        } or nil
        return api.observeBucket(tonumber(id), metadata)
    end

    function api.buckets()
        local result = {}
        for _, bucket in pairs(buckets) do
            result[#result + 1] = {
                id = bucket.id, mode = bucket.mode, controlled = bucket.controlled,
            }
        end
        table.sort(result, function(left, right) return left.id < right.id end)
        while #result > 32 do table.remove(result) end
        return result
    end

    return api
end
