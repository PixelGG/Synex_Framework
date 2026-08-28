SynexInteractValidation = {}

local V = SynexInteractValidation
local L = SynexInteractLimits

function V.failure(code, message, retryable, details)
    return nil, { code = code, message = message, retryable = retryable == true, details = details }
end

function V.isInteger(value, minimum, maximum)
    return type(value) == 'number' and value % 1 == 0
        and (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
end

function V.isFinite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function V.plain(value)
    return type(value) == 'table'
end

function V.resourceName(value)
    if type(value) ~= 'string' or #value < 1 or #value > 96 or not value:match('^[%w_%-%.]+$') then
        return V.failure('INTERACT_INVALID_OWNER', 'Interaction owner resource is invalid.')
    end
    return value
end

function V.key(value, field)
    field = field or 'key'
    if type(value) ~= 'string' or #value < 3 or #value > 128
        or not value:match('^[a-z0-9_%-%.]+:[a-z0-9_%-%.]+$') then
        return V.failure('INTERACT_INVALID_ARGUMENT', field .. ' must be a namespaced key.')
    end
    return value
end

function V.text(value, maximum, required)
    if value == nil and not required then return nil end
    if type(value) ~= 'string' or (required and #value == 0) or #value > maximum then
        return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction text value is invalid.')
    end
    return value
end

function V.vector3(value)
    if type(value) ~= 'table' or not V.isFinite(value.x) or not V.isFinite(value.y) or not V.isFinite(value.z) then
        return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction position is invalid.')
    end
    return { x = value.x, y = value.y, z = value.z }
end

function V.tags(value)
    if value == nil then return {} end
    if type(value) ~= 'table' or #value > L.maximumTags then
        return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction tags are invalid.')
    end
    local out, seen = {}, {}
    for _, tag in ipairs(value) do
        if type(tag) ~= 'string' or #tag < 1 or #tag > L.maximumTagLength
            or not tag:match('^[a-z0-9_%-%.:]+$') then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction tag is invalid.')
        end
        if not seen[tag] then seen[tag] = true; out[#out + 1] = tag end
    end
    table.sort(out)
    return out
end

function V.copy(value, depth, seen)
    if type(value) ~= 'table' then return value end
    depth, seen = depth or 0, seen or {}
    if depth >= L.maximumPayloadDepth or seen[value] then return nil end
    seen[value] = true
    local out, count = {}, 0
    for k, v in pairs(value) do
        count = count + 1
        if count > L.maximumPayloadEntries then break end
        if type(k) == 'string' or type(k) == 'number' then
            if type(v) == 'string' and #v > L.maximumStringLength then
                out[k] = v:sub(1, L.maximumStringLength)
            else
                out[k] = V.copy(v, depth + 1, seen)
            end
        end
    end
    seen[value] = nil
    return out
end

function V.distanceSquared(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function V.clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end
