SynexEntityExtensionSchema = {}

local TYPES = {
    array = true, boolean = true, integer = true, number = true,
    object = true, string = true,
}
local KEYS = {
    additionalProperties = true, enum = true, items = true, maximum = true,
    maxItems = true, maxLength = true, minimum = true, minItems = true,
    minLength = true, pattern = true, properties = true, required = true, type = true,
}

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= minimum and value <= maximum
end

function SynexEntityExtensionSchema.validToken(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

function SynexEntityExtensionSchema.denseArray(value, maximum)
    if type(value) ~= 'table' or getmetatable(value) ~= nil or #value > maximum then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #value then return false end
        count = count + 1
    end
    return count == #value
end

function SynexEntityExtensionSchema.validateDefinition(schema, maximumDepth)
    local nodes = 0
    local function visit(node, depth)
        nodes = nodes + 1
        if nodes > 256 or depth > math.min(maximumDepth + 2, 18)
            or type(node) ~= 'table' or getmetatable(node) ~= nil then return false end
        for key in pairs(node) do
            if type(key) ~= 'string' or not KEYS[key] then return false end
        end
        if node.type ~= nil and not TYPES[node.type] then return false end
        for _, key in ipairs({ 'minimum', 'maximum' }) do
            local value = node[key]
            if value ~= nil and (type(value) ~= 'number' or value ~= value
                or value == math.huge or value == -math.huge) then return false end
        end
        if node.minimum ~= nil and node.maximum ~= nil
            and node.minimum > node.maximum then return false end
        for _, key in ipairs({ 'minLength', 'maxLength', 'minItems', 'maxItems' }) do
            if node[key] ~= nil and not integer(node[key], 0, 32768) then return false end
        end
        if node.minLength and node.maxLength and node.minLength > node.maxLength
            or node.minItems and node.maxItems and node.minItems > node.maxItems then return false end
        if node.pattern ~= nil then
            if type(node.pattern) ~= 'string' or #node.pattern > 128
                or not pcall(string.match, '', node.pattern) then return false end
        end
        if node.additionalProperties ~= nil
            and type(node.additionalProperties) ~= 'boolean' then return false end
        if node.enum ~= nil then
            if type(node.enum) ~= 'table' or getmetatable(node.enum) ~= nil
                or #node.enum < 1 or #node.enum > 64 then return false end
            local seen = {}
            for index, candidate in ipairs(node.enum) do
                local kind = type(candidate)
                if kind ~= 'boolean' and kind ~= 'number' and kind ~= 'string' then return false end
                local identity = kind .. ':' .. tostring(candidate)
                if seen[identity] or node.enum[index] == nil then return false end
                seen[identity] = true
            end
        end
        if node.required ~= nil then
            if type(node.required) ~= 'table' or getmetatable(node.required) ~= nil
                or #node.required > 64 then return false end
            local seen = {}
            for index, key in ipairs(node.required) do
                if type(key) ~= 'string' or #key < 1 or #key > 128 or seen[key]
                    or node.required[index] == nil then return false end
                seen[key] = true
            end
        end
        if node.properties ~= nil then
            if type(node.properties) ~= 'table'
                or getmetatable(node.properties) ~= nil then return false end
            local count = 0
            for key, child in pairs(node.properties) do
                count = count + 1
                if count > 128 or type(key) ~= 'string' or #key < 1 or #key > 128
                    or not visit(child, depth + 1) then return false end
            end
        end
        return node.items == nil or visit(node.items, depth + 1)
    end
    return visit(schema, 1)
end

function SynexEntityExtensionSchema.boundedDepth(value, maximumDepth)
    local active = {}
    local function visit(item, depth)
        if depth > maximumDepth then return false end
        if type(item) ~= 'table' then return true end
        if active[item] then return false end
        active[item] = true
        for _, child in pairs(item) do
            if not visit(child, depth + 1) then active[item] = nil return false end
        end
        active[item] = nil
        return true
    end
    return visit(value, 1)
end
