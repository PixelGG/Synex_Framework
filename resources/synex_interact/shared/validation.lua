SynexInteractValidation = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = SynexInteractValidation

function Validation.failure(code, message, retryable, details)
    local value = {
        code = tostring(code or 'INTERACT_UNAVAILABLE'),
        message = tostring(message or 'The interaction runtime is unavailable.'),
        retryable = retryable == true,
    }
    if type(details) == 'table' then value.details = details end
    return nil, value
end

function Validation.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local ok, metadata = pcall(getmetatable, value)
    if not ok then return false end
    if type(metadata) == 'table' and type(metadata.__call) == 'function' then return true end
    if metadata == 'locked' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local resolved, actual = pcall(debug.getmetatable, value)
        return resolved and type(actual) == 'table' and type(actual.__call) == 'function'
    end
    return false
end

function Validation.isPlainTable(value)
    if type(value) ~= 'table' then return false end
    local metadata = getmetatable(value)
    if metadata == nil then return true end
    if type(metadata) ~= 'table'
        or (metadata.__jsontype ~= 'object' and metadata.__jsontype ~= 'array') then
        return false
    end
    for key in next, metadata do if key ~= '__jsontype' then return false end end
    return true
end

function Validation.isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

function Validation.isInteger(value, minimum, maximum)
    return Validation.isFinite(value) and math.type(value) == 'integer'
        and value >= (minimum or -Limits.maximumSafeInteger)
        and value <= (maximum or Limits.maximumSafeInteger)
end

function Validation.identifier(value, maximum)
    return type(value) == 'string' and #value >= 3 and #value <= (maximum or 128)
        and value:match('^[a-z][a-z0-9_]*:[a-z0-9][a-z0-9_.%-]*$') ~= nil
end

function Validation.semanticKey(value, maximum)
    return type(value) == 'string' and #value >= 3 and #value <= (maximum or 128)
        and value:match('^[a-z][a-z0-9]*[a-z0-9_.%-]*$') ~= nil
        and value:match('[%._%-]$') == nil
        and value:match('[%._%-][%._%-]') == nil
end

function Validation.permission(value)
    return type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[a-z][a-z0-9_.%-]*$') ~= nil
        and value:match('[%._%-]$') == nil
        and value:match('[%._%-][%._%-]') == nil
end

function Validation.resourceName(value)
    return type(value) == 'string' and #value >= 3 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

function Validation.apiName(value)
    if type(value) ~= 'string' or #value < 3 or #value > 128 then return false end
    local base, major = value:match('^([^@]+)@([1-9][0-9]*)$')
    if not base then
        if value:find('@', 1, true) then return false end
        base = value
    elseif not major then return false end
    return base:match('^[a-z][a-z0-9_.%-]*$') ~= nil
        and base:match('[._%-]$') == nil
        and base:match('[._%-][._%-]') == nil
end

function Validation.methodName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') ~= nil
end

function Validation.errorCode(value)
    return type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[A-Z][A-Z0-9_]*$') ~= nil
end

function Validation.token(value, minimum, maximum)
    return type(value) == 'string' and #value >= (minimum or 8)
        and #value <= (maximum or 96)
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

function Validation.actorKey(value)
    if type(value) ~= 'string' or #value < 3 or #value > 32 then return false end
    local source, generation = value:match('^([1-9][0-9]*):([1-9][0-9]*)$')
    source, generation = tonumber(source), tonumber(generation)
    return Validation.isInteger(source, 1, 65535)
        and Validation.isInteger(generation, 1)
end

function Validation.text(value, minimum, maximum)
    return type(value) == 'string' and #value >= (minimum or 0)
        and #value <= (maximum or Limits.maximumStringBytes)
        and value:find('[%z\1-\8\11\12\14-\31\127]') == nil
end

function Validation.exactObject(value, required, optional)
    if not Validation.isPlainTable(value) then return false end
    local allowed = {}
    for _, key in ipairs(required or {}) do
        allowed[key] = true
        if rawget(value, key) == nil then return false end
    end
    for _, key in ipairs(optional or {}) do allowed[key] = true end
    for key in pairs(value) do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    return true
end

function Validation.vector3(value)
    if not Validation.exactObject(value, { 'x', 'y', 'z' })
        or not Validation.isFinite(value.x) or not Validation.isFinite(value.y)
        or not Validation.isFinite(value.z) or math.abs(value.x) > 20000
        or math.abs(value.y) > 20000 or math.abs(value.z) > 20000 then return nil end
    return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
end

function Validation.distance(left, right)
    local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Validation.array(value, maximum, validator)
    if not Validation.isPlainTable(value) then return nil end
    local length = #value
    if length > (maximum or Limits.maximumEntries) then return nil end
    local result = {}
    for index = 1, length do
        local item = value[index]
        if item == nil or validator and not validator(item, index) then return nil end
        result[index] = item
    end
    for key in pairs(value) do
        if not Validation.isInteger(key, 1, length) then return nil end
    end
    return result
end

function Validation.copy(value)
    local active, entries = {}, 0
    local function clone(candidate, depth)
        local kind = type(candidate)
        if kind == 'nil' or kind == 'boolean' or kind == 'string' then return candidate end
        if kind == 'number' then
            if not Validation.isFinite(candidate) then error('non-finite number', 0) end
            return candidate
        end
        if not Validation.isPlainTable(candidate) or depth > Limits.maximumDepth
            or active[candidate] then error('invalid container', 0) end
        active[candidate] = true
        local result = {}
        for key, child in pairs(candidate) do
            entries = entries + 1
            if entries > Limits.maximumEntries
                or type(key) ~= 'string' and not Validation.isInteger(key, 1) then
                active[candidate] = nil
                error('container bound exceeded', 0)
            end
            result[key] = clone(child, depth + 1)
        end
        active[candidate] = nil
        return result
    end
    local ok, copied = pcall(clone, value, 1)
    return ok and copied or nil
end

function Validation.target(value)
    if not Validation.exactObject(value, { 'kind' }, {
        'worldRef', 'entityRef', 'netId', 'bindingKey', 'position', 'model', 'bone',
    }) then return Validation.failure('INTERACT_TARGET_INVALID', 'The target reference is invalid.') end
    if value.kind == 'world' then
        local ref = value.worldRef
        if not Validation.exactObject(ref, { 'key', 'revision' }, { 'kind' })
            or not Validation.identifier(ref.key)
            or not Validation.isInteger(ref.revision, 1)
            or ref.kind ~= nil and ref.kind ~= 'anchor'
                and ref.kind ~= 'door' and ref.kind ~= 'portal' then
            return Validation.failure('INTERACT_TARGET_INVALID', 'The WorldRef is invalid.')
        end
    elseif value.kind == 'entity' then
        local ref = value.entityRef
        if not Validation.exactObject(ref, { 'entityId', 'generation' })
            or not Validation.token(ref.entityId, 8, 64)
            or not Validation.isInteger(ref.generation, 1) then
            return Validation.failure('INTERACT_TARGET_INVALID', 'The EntityRef is invalid.')
        end
    elseif value.kind == 'ambient' then
        if not Validation.isInteger(value.netId, 1, 65535)
            or not Validation.isInteger(value.model, 0, 4294967295) then
            return Validation.failure('INTERACT_TARGET_INVALID', 'The ambient entity reference is invalid.')
        end
    elseif value.kind == 'static' or value.kind == 'dynamic' then
        if not Validation.token(value.bindingKey, 3, 128) then
            return Validation.failure('INTERACT_TARGET_INVALID', 'The runtime binding is invalid.')
        end
        if value.position ~= nil and not Validation.vector3(value.position) then
            return Validation.failure('INTERACT_TARGET_INVALID', 'The runtime target position is invalid.')
        end
    else
        return Validation.failure('INTERACT_TARGET_INVALID', 'The target kind is unsupported.')
    end
    return Validation.copy(value), nil
end
