SynexWorldValidation = {}

local Validation = SynexWorldValidation
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')
local jsonObjectMetatable = { __jsontype = 'object' }
local jsonArrayMetatable = { __jsontype = 'array' }
local trustedJsonMetatables = setmetatable({
    [jsonObjectMetatable] = 'object',
    [jsonArrayMetatable] = 'array',
}, { __mode = 'k' })

local function failure(code, message, retryable, details)
    return nil, {
        code = code,
        message = message,
        retryable = retryable == true,
        details = details,
    }
end

function Validation.failure(code, message, retryable, details)
    return failure(code, message, retryable, details)
end

function Validation.isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

function Validation.isInteger(value, minimum, maximum)
    return Validation.isFinite(value) and math.type(value) == 'integer'
        and (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
end

function Validation.monotonicClock(readRaw)
    if type(readRaw) ~= 'function' then
        error('world monotonic clock requires a raw timer', 2)
    end
    local modulo, halfRange = 0x100000000, 0x80000000
    local previous, elapsedTotal = nil, 0
    return function()
        local raw = readRaw()
        if not Validation.isInteger(raw) then
            error('world raw timer must be an integer', 2)
        end
        local current = raw % modulo
        if previous == nil then
            previous, elapsedTotal = current, current
            return elapsedTotal
        end
        local elapsed = (current - previous) % modulo
        if elapsed <= halfRange then
            previous, elapsedTotal = current, elapsedTotal + elapsed
        end
        return elapsedTotal
    end
end

function Validation.uint32(value)
    if not Validation.isInteger(value, -2147483648, 4294967295) then return nil end
    if value < 0 then value = value + 4294967296 end
    return value & 0xffffffff
end

function Validation.doorHash(doorKey, leafId)
    if type(doorKey) ~= 'string' or type(leafId) ~= 'string' then return nil end
    local accumulator = 2166136261
    local source = doorKey .. ':' .. leafId
    for index = 1, #source do
        accumulator = ((accumulator ~ source:byte(index)) * 16777619) & 0xffffffff
    end
    return accumulator
end

function Validation.hasControl(value)
    return type(value) == 'string' and value:find('[%z\1-\31\127]') ~= nil
end

function Validation.jsonContainerKind(value)
    if type(value) ~= 'table' then return nil end
    local metatable = getmetatable(value)
    return type(metatable) == 'table' and trustedJsonMetatables[metatable] or nil
end

function Validation.isJsonTable(value)
    if type(value) ~= 'table' then return false end
    local metatable = getmetatable(value)
    return metatable == nil
        or type(metatable) == 'table' and trustedJsonMetatables[metatable] ~= nil
end

function Validation.markJsonContainer(value, kind)
    if type(value) ~= 'table' or kind ~= 'object' and kind ~= 'array'
        or not Validation.isJsonTable(value) then return nil end
    local current = Validation.jsonContainerKind(value)
    if current ~= nil and current ~= kind then return nil end
    return setmetatable(value, kind == 'object' and jsonObjectMetatable or jsonArrayMetatable)
end

function Validation.isPlainTable(value)
    return Validation.isJsonTable(value) and Validation.jsonContainerKind(value) ~= 'array'
end

function Validation.isDenseArray(value, maximum)
    if not Validation.isJsonTable(value)
        or Validation.jsonContainerKind(value) == 'object' then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
            return false
        end
        count = count + 1
        if maximum and count > maximum then return false end
    end
    return count == #value
end

function Validation.exactObject(value, allowed)
    if not Validation.isPlainTable(value) then return false end
    for key in pairs(value) do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

function Validation.copy(value, depth, seen)
    depth = depth or 0
    if depth > 16 then error('world value exceeds maximum copy depth', 0) end
    local valueType = type(value)
    if valueType ~= 'table' then return value end
    if not Validation.isJsonTable(value) then
        error('world values cannot have untrusted metatables', 0)
    end
    local containerKind = Validation.jsonContainerKind(value)
    seen = seen or {}
    if seen[value] then error('world values cannot contain cycles', 0) end
    seen[value] = true
    local copied = {}
    for key, item in pairs(value) do
        if type(key) ~= 'string' and type(key) ~= 'number' then
            error('world values contain an unsupported key', 0)
        end
        copied[key] = Validation.copy(item, depth + 1, seen)
    end
    seen[value] = nil
    if containerKind then assert(Validation.markJsonContainer(copied, containerKind)) end
    return copied
end

function Validation.createJsonDecoder(runtimeJson)
    local decode = type(runtimeJson) == 'table' and runtimeJson.decode or nil
    if type(decode) ~= 'function' then error('world JSON decoder is unavailable', 0) end
    return function(encoded)
        if type(encoded) ~= 'string' then error('world JSON input must be a string', 0) end
        local decoded = decode(encoded, 1, nil, jsonObjectMetatable, jsonArrayMetatable)
        local active, entries = {}, 0
        local function normalize(value, depth)
            if depth > 32 then error('world JSON exceeds maximum depth', 0) end
            if type(value) ~= 'table' then return value end
            local metatable = getmetatable(value)
            local containerKind = type(metatable) == 'table'
                and trustedJsonMetatables[metatable] or nil
            if metatable ~= nil and containerKind == nil then
                error('world JSON contains an untrusted container', 0)
            end
            if active[value] then error('world JSON contains a cycle', 0) end
            active[value] = true
            local copied, count, maximumIndex, keyKind = {}, 0, 0, nil
            for key, nested in pairs(value) do
                entries, count = entries + 1, count + 1
                if entries > Limits.maximumBundleObjects * 32 then
                    error('world JSON exceeds maximum entries', 0)
                end
                local currentKind = type(key)
                if currentKind == 'number' then
                    if math.type(key) ~= 'integer' or key < 1 then
                        error('world JSON array key is invalid', 0)
                    end
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentKind ~= 'string' or #key < 1 or #key > 256
                    or key:find('[%z\1-\31\127]') then
                    error('world JSON object key is invalid', 0)
                end
                if keyKind ~= nil and keyKind ~= currentKind then
                    error('world JSON container mixes key types', 0)
                end
                keyKind = currentKind
                copied[key] = normalize(nested, depth + 1)
            end
            if keyKind == 'number' and maximumIndex ~= count then
                error('world JSON array is sparse', 0)
            end
            if containerKind == 'object' and keyKind == 'number'
                or containerKind == 'array' and keyKind == 'string' then
                error('world JSON container kind is invalid', 0)
            end
            active[value] = nil
            if containerKind then
                assert(Validation.markJsonContainer(copied, containerKind))
            end
            return copied
        end
        return normalize(decoded, 0)
    end
end

function Validation.resourceName(value)
    if type(value) ~= 'string' or #value < 7 or #value > 64
        or value:match('^synex_[a-z0-9_]+$') == nil then
        return failure('INVALID_ARGUMENT', 'World owner resource is invalid.')
    end
    return value
end

function Validation.namespacedKey(value, ownerResource)
    if type(value) ~= 'string' or #value < 3 or #value > Limits.maximumKeyLength
        or value:match('^[a-z][a-z0-9_]*:[a-z0-9][a-z0-9_.-]*$') == nil then
        return failure('WORLD_REFERENCE_INVALID', 'World key is not a valid namespaced key.')
    end
    if ownerResource and value:sub(1, #ownerResource + 1) ~= ownerResource .. ':' then
        return failure('WORLD_BUNDLE_CONFLICT', 'World key namespace does not match its owner resource.')
    end
    return value
end

function Validation.tag(value)
    if type(value) ~= 'string' or #value < 3 or #value > Limits.maximumTagLength
        or value:match('^[a-z][a-z0-9_.-]+$') == nil then
        return failure('INVALID_ARGUMENT', 'World tag is invalid.')
    end
    return value
end

function Validation.tags(value)
    if value == nil then return {} end
    if not Validation.isDenseArray(value, Limits.maximumTags) then
        return failure('INVALID_ARGUMENT', 'World tags must be a bounded array.')
    end
    local normalized, seen = {}, {}
    for index, candidate in ipairs(value) do
        local tag, tagError = Validation.tag(candidate)
        if not tag then return nil, tagError end
        if seen[tag] then return failure('INVALID_ARGUMENT', 'World tags must be unique.') end
        seen[tag] = true
        normalized[index] = tag
    end
    table.sort(normalized)
    return normalized
end

function Validation.vector3(value, code)
    if not Validation.exactObject(value, { x = true, y = true, z = true })
        or not Validation.isFinite(value.x) or not Validation.isFinite(value.y)
        or not Validation.isFinite(value.z)
        or value.x < Limits.coordinateMinimum or value.x > Limits.coordinateMaximum
        or value.y < Limits.coordinateMinimum or value.y > Limits.coordinateMaximum
        or value.z < Limits.coordinateMinimum or value.z > Limits.coordinateMaximum then
        return failure(code or 'WORLD_GEOMETRY_INVALID', 'World coordinate is invalid.')
    end
    return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
end

function Validation.worldRef(value, expectedKind)
    if not Validation.exactObject(value, { kind = true, key = true, revision = true })
        or type(value.kind) ~= 'string'
        or (expectedKind and value.kind ~= expectedKind)
        or not Validation.isInteger(value.revision, 1, Limits.maximumRevision) then
        return failure('WORLD_REFERENCE_INVALID', 'World reference is invalid.')
    end
    local key, keyError = Validation.namespacedKey(value.key)
    if not key then return nil, keyError end
    return { kind = value.kind, key = key, revision = value.revision }
end

function Validation.reasonCode(value)
    if type(value) ~= 'string' or #value < 3 or #value > 128
        or value:match('^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$') == nil then
        return failure('INVALID_ARGUMENT', 'World reason code is invalid.')
    end
    return value
end

function Validation.objectLabel(value)
    if value == nil then return nil end
    if type(value) ~= 'string' or #value < 1 or #value > Limits.maximumLabelLength
        or Validation.hasControl(value) then
        return failure('INVALID_ARGUMENT', 'World label is invalid.')
    end
    return value
end

function Validation.cursor(value)
    if value == nil or value == '' then return '' end
    if type(value) ~= 'string' or #value > Limits.maximumKeyLength
        or value:match('^[a-z0-9_:.%-]+$') == nil then
        return failure('INVALID_ARGUMENT', 'World cursor is invalid.')
    end
    return value
end

function Validation.limit(value, defaultValue, maximum)
    value = value == nil and defaultValue or value
    if not Validation.isInteger(value, 1, maximum) then
        return failure('INVALID_ARGUMENT', 'World result limit is invalid.')
    end
    return value
end
