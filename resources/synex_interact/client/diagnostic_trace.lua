SynexInteractClientTrace = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded before client diagnostics')

local CAPACITY = math.min(64, Limits.maximumTraceFrames)
local MAXIMUM_FIELDS = 96
local MAXIMUM_DEPTH = 4
local MAXIMUM_STRING_BYTES = 96
local PHASES = {
    context = true, candidates = true, score = true, primary = true,
    input = true, lease_request = true, lease_result = true,
    graph = true, cancel = true,
}
local SAFE_FIELDS = {
    movementState = true, vehicleState = true, weaponState = true,
    dead = true, ragdoll = true, speedBucket = true, inputDevice = true,
    focused = true, world = true, discoveryRevision = true,
    count = true, expensiveCount = true, pendingRay = true, items = true,
    objectKey = true, slotKey = true, provider = true, targetKind = true,
    distanceBucket = true, gazeBucket = true, exactRay = true, occluded = true,
    intentKey = true, score = true, breakdown = true,
    unknownConditions = true, base = true, specificity = true, gaze = true,
    distance = true, slot = true, continuity = true, history = true,
    movementPenalty = true, unknownConditionPenalty = true,
    ambiguityPenalty = true, present = true, action = true, device = true,
    selectedIntentKey = true, stage = true, outcome = true, code = true,
    state = true, nodeKey = true, commandType = true, sequence = true,
    result = true, reason = true, activeSession = true, activeLease = true,
    inFlight = true, decision = true, evaluated = true, accepted = true,
    rejected = true, viablePrimaryCount = true, ambiguous = true,
    rejectionReasons = true, advisories = true,
}

function SynexInteractClientTrace.create(options)
    options = options or {}
    local now = assert(options.now, 'client diagnostics require monotonic time')
    local enabled = options.enabled == true
    local frames, head, count, serial = {}, 1, 0, 0
    local trace = {}

    local function prune(timestamp)
        while count > 0 do
            local frame = frames[head]
            if frame and timestamp - frame.at <= Limits.traceRetentionMs then break end
            frames[head] = nil
            head = head % CAPACITY + 1
            count = count - 1
        end
    end

    local function sanitized(value)
        local entries, active = 0, {}
        local function clone(candidate, depth)
            local kind = type(candidate)
            if kind == 'boolean' then return candidate end
            if kind == 'number' then
                return Validation.isFinite(candidate) and candidate or nil
            end
            if kind == 'string' then return candidate:sub(1, MAXIMUM_STRING_BYTES) end
            if kind ~= 'table' or depth > MAXIMUM_DEPTH
                or not Validation.isPlainTable(candidate) or active[candidate] then return nil end
            active[candidate] = true
            local copied = {}
            local length = rawlen(candidate)
            if length > 0 then
                for index = 1, math.min(length, Limits.maximumVisibleIntents) do
                    if entries >= MAXIMUM_FIELDS then break end
                    local item = clone(rawget(candidate, index), depth + 1)
                    if item ~= nil then
                        entries = entries + 1
                        copied[#copied + 1] = item
                    end
                end
            else
                local keys = {}
                for key in pairs(candidate) do
                    if type(key) == 'string' and SAFE_FIELDS[key] then
                        keys[#keys + 1] = key
                    end
                end
                table.sort(keys)
                for _, key in ipairs(keys) do
                    if entries >= MAXIMUM_FIELDS then break end
                    local item = clone(rawget(candidate, key), depth + 1)
                    if item ~= nil then
                        entries = entries + 1
                        copied[key] = item
                    end
                end
            end
            active[candidate] = nil
            return copied
        end
        return clone(value, 1) or {}
    end

    function trace.record(phase, data)
        if not enabled or not PHASES[phase] or not Validation.isPlainTable(data) then
            return false
        end
        local timestamp = math.max(0, math.floor(tonumber(now()) or 0))
        prune(timestamp)
        serial = serial + 1
        if count == CAPACITY then
            frames[head] = nil
            head = head % CAPACITY + 1
            count = count - 1
        end
        local index = ((head + count - 1) % CAPACITY) + 1
        frames[index] = {
            sequence = serial, at = timestamp, phase = phase,
            data = sanitized(data),
        }
        count = count + 1
        return true
    end

    function trace.snapshot()
        local timestamp = math.max(0, math.floor(tonumber(now()) or 0))
        prune(timestamp)
        local copied = {}
        for offset = 1, count do
            local index = ((head + offset - 2) % CAPACITY) + 1
            copied[offset] = Validation.copy(frames[index])
        end
        return {
            enabled = enabled, capacity = CAPACITY,
            retentionMs = Limits.traceRetentionMs,
            count = count, frames = copied,
        }
    end

    function trace.cleanup()
        frames, head, count = {}, 1, 0
    end

    return trace
end
