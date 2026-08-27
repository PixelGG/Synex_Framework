return function(Foundation)
local module = {}

local VALUE_TYPES = {
    string = true,
    integer = true,
    number = true,
    boolean = true
}

local function rejected(message, field)
    return nil, Foundation.domainError('VALIDATION_FAILED', message, false,
        field and { field = field } or nil)
end

local function object(value)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'array' then
        return false
    end
    for key in next, value do
        if type(key) ~= 'string' then return false end
    end
    return true
end

local function denseArray(value, maximum)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'object' then
        return nil
    end
    local count, largest = 0, 0
    for key in next, value do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
            return nil
        end
        count = count + 1
        largest = math.max(largest, key)
    end
    if count ~= largest or count > maximum then return nil end
    return count
end

local function boundedInteger(value, minimum, maximum)
    return type(value) == 'number' and math.type(value) == 'integer'
        and value >= minimum and value <= maximum
end

local function finiteNumber(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function scalarMatches(value, kind)
    if kind == 'string' then return type(value) == 'string' end
    if kind == 'integer' then
        return type(value) == 'number' and math.type(value) == 'integer'
    end
    if kind == 'number' then return finiteNumber(value) end
    if kind == 'boolean' then return type(value) == 'boolean' end
    return false
end

local function scalarIdentity(value)
    return type(value) .. ':' .. tostring(value)
end

local function validateProperty(key, definition)
    if type(key) ~= 'string' or #key < 1 or #key > 64
        or not key:match('^[a-z][a-z0-9_]*$') then
        return rejected('Application schema property names must be bounded lowercase keys.',
            'application_schema.properties')
    end
    if not object(definition) then
        return rejected('Application schema properties must be objects.',
            'application_schema.properties.' .. key)
    end
    local allowed = {
        type = true, min_length = true, max_length = true,
        minimum = true, maximum = true, enum = true
    }
    for field in pairs(definition) do
        if not allowed[field] then
            return rejected('Application schema property contains an unsupported constraint.',
                'application_schema.properties.' .. key .. '.' .. tostring(field))
        end
    end
    local kind = definition.type
    if not VALUE_TYPES[kind] then
        return rejected('Application schema property type is unsupported.',
            'application_schema.properties.' .. key .. '.type')
    end
    if definition.min_length ~= nil or definition.max_length ~= nil then
        if kind ~= 'string'
            or definition.min_length ~= nil
                and not boundedInteger(definition.min_length, 0, 4096)
            or definition.max_length ~= nil
                and not boundedInteger(definition.max_length, 0, 4096)
            or (definition.min_length or 0) > (definition.max_length or 4096) then
            return rejected('String length constraints in an application schema are invalid.',
                'application_schema.properties.' .. key)
        end
    end
    if definition.minimum ~= nil or definition.maximum ~= nil then
        if (kind ~= 'integer' and kind ~= 'number')
            or definition.minimum ~= nil and not finiteNumber(definition.minimum)
            or definition.maximum ~= nil and not finiteNumber(definition.maximum)
            or definition.minimum ~= nil and definition.maximum ~= nil
                and definition.minimum > definition.maximum then
            return rejected('Numeric constraints in an application schema are invalid.',
                'application_schema.properties.' .. key)
        end
    end
    if definition.enum ~= nil then
        local length = denseArray(definition.enum, 32)
        if not length or length < 1 then
            return rejected('Application schema enum constraints must be bounded dense arrays.',
                'application_schema.properties.' .. key .. '.enum')
        end
        local seen = {}
        for index = 1, length do
            local value = definition.enum[index]
            if not scalarMatches(value, kind) then
                return rejected('Application schema enum values must match their property type.',
                    'application_schema.properties.' .. key .. '.enum')
            end
            local identity = scalarIdentity(value)
            if seen[identity] then
                return rejected('Application schema enum values must be unique.',
                    'application_schema.properties.' .. key .. '.enum')
            end
            seen[identity] = true
        end
    end
    return true, nil
end

function module.validateSchema(value)
    local copiedOk, schema = pcall(Foundation.copyPlain, value, {
        maximumDepth = 5,
        maximumKeys = 256,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not copiedOk or not object(schema) then
        return rejected('application_schema must be a bounded JSON object.',
            'application_schema')
    end
    for key in pairs(schema) do
        if key ~= 'properties' and key ~= 'required'
            and key ~= 'additional_properties' then
            return rejected('application_schema contains an unsupported property.',
                'application_schema.' .. tostring(key))
        end
    end
    if not object(schema.properties) then
        return rejected('application_schema.properties must be an object.',
            'application_schema.properties')
    end
    if schema.additional_properties ~= nil and schema.additional_properties ~= false then
        return rejected('Application schemas must reject undeclared properties.',
            'application_schema.additional_properties')
    end
    schema.additional_properties = false
    local propertyCount = 0
    for key, definition in pairs(schema.properties) do
        propertyCount = propertyCount + 1
        if propertyCount > 32 then
            return rejected('Application schemas support at most 32 properties.',
                'application_schema.properties')
        end
        local valid, propertyError = validateProperty(key, definition)
        if not valid then return nil, propertyError end
    end
    local requiredCount = denseArray(schema.required or {}, 32)
    if requiredCount == nil then
        return rejected('application_schema.required must be a bounded dense array.',
            'application_schema.required')
    end
    local required, seen = {}, {}
    for index = 1, requiredCount do
        local key = schema.required[index]
        if type(key) ~= 'string' or schema.properties[key] == nil or seen[key] then
            return rejected('Application schema required fields must be unique declared properties.',
                'application_schema.required')
        end
        required[index], seen[key] = key, true
    end
    schema.required = required
    return schema, nil
end

local function enumContains(values, candidate)
    if values == nil then return true end
    local length = denseArray(values, 32)
    for index = 1, length do
        if values[index] == candidate and type(values[index]) == type(candidate) then
            return true
        end
    end
    return false
end

function module.validateData(schemaValue, dataValue)
    local schema, schemaError = module.validateSchema(schemaValue)
    if not schema then return nil, schemaError end
    local copiedOk, data = pcall(Foundation.copyPlain, dataValue, {
        maximumDepth = 3,
        maximumKeys = 64,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not copiedOk or not object(data) then
        return rejected('Application data must be a bounded JSON object.', 'data')
    end
    for key, value in pairs(data) do
        local definition = schema.properties[key]
        if definition == nil then
            return rejected('Application data contains an undeclared property.', 'data.' .. key)
        end
        if not scalarMatches(value, definition.type) then
            return rejected('Application data does not match the registered property type.',
                'data.' .. key)
        end
        if definition.type == 'string' then
            local length = Foundation.characterLength(value)
            if length < (definition.min_length or 0)
                or length > (definition.max_length or 4096)
                or value:find('[%z\1-\8\11\12\14-\31\127]') then
                return rejected('Application string data is outside the registered bounds.',
                    'data.' .. key)
            end
        elseif definition.type == 'integer' or definition.type == 'number' then
            if definition.minimum ~= nil and value < definition.minimum
                or definition.maximum ~= nil and value > definition.maximum then
                return rejected('Application numeric data is outside the registered bounds.',
                    'data.' .. key)
            end
        end
        if not enumContains(definition.enum, value) then
            return rejected('Application data is not an allowed enum value.', 'data.' .. key)
        end
    end
    for _, key in ipairs(schema.required) do
        if data[key] == nil then
            return rejected('Application data is missing a required property.', 'data.' .. key)
        end
    end
    return data, nil
end

return module
end
