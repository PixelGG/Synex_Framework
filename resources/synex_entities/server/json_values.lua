SynexEntityJsonValues = {}

function SynexEntityJsonValues.create(options)
    assert(type(options) == 'table', 'entity JSON options are required')
    local foundation = assert(options.foundation, 'entity JSON foundation is required')
    local ports = assert(options.ports, 'entity JSON ports are required')
    local maximumBytes = options.maximumBytes or 16384
    local maximumDepth = options.maximumDepth or 8
    local maximumNodes = options.maximumNodes or 256
    local service = {}

    local function failure(code, message)
        return nil, { code = code, message = message, retryable = false }
    end

    local function finite(value)
        return type(value) == 'number' and value == value
            and value ~= math.huge and value ~= -math.huge
    end

    local function copyValue(value, expectedType)
        local active, nodes = {}, 0
        local function visit(candidate, depth, expected)
            nodes = nodes + 1
            if nodes > maximumNodes or depth > maximumDepth then
                error('bounds', 0)
            end
            local candidateType = type(candidate)
            if candidateType == 'nil' or candidateType == 'boolean'
                or candidateType == 'string' then return candidate end
            if candidateType == 'number' then
                if not finite(candidate) then error('number', 0) end
                return candidate
            end
            if candidateType ~= 'table' or active[candidate] then error('container', 0) end
            active[candidate] = true
            local count, maximumIndex, numeric = 0, 0, true
            for key in pairs(candidate) do
                count = count + 1
                if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
                    numeric = false
                else
                    maximumIndex = math.max(maximumIndex, key)
                end
                if type(key) == 'string' and (#key < 1 or #key > 128) then
                    active[candidate] = nil
                    error('key', 0)
                end
                if type(key) ~= 'string' and type(key) ~= 'number' then
                    active[candidate] = nil
                    error('key', 0)
                end
            end
            local array = expected == 'array' or expected ~= 'object' and numeric and count > 0
            local result = {}
            if array then
                if not numeric or maximumIndex ~= count then
                    active[candidate] = nil
                    error('array', 0)
                end
                for index = 1, count do result[index] = visit(candidate[index], depth + 1) end
            else
                if numeric and count > 0 then
                    active[candidate] = nil
                    error('object', 0)
                end
                for key, item in pairs(candidate) do
                    result[key] = visit(item, depth + 1)
                end
            end
            active[candidate] = nil
            return result
        end
        local ok, result = pcall(visit, value, 1, expectedType)
        if not ok then return failure('INVALID_JSON_VALUE', 'The value must be bounded JSON data') end
        return result
    end

    local function typeMatches(schemaType, value)
        if schemaType == nil then return true end
        if schemaType == 'integer' then
            return type(value) == 'number' and finite(value) and value % 1 == 0
        end
        if schemaType == 'number' then return finite(value) end
        if schemaType == 'array' or schemaType == 'object' then return type(value) == 'table' end
        return type(value) == schemaType
    end

    local function validateSchema(schema, value, depth)
        if type(schema) ~= 'table' or depth > maximumDepth then return false end
        if not typeMatches(schema.type, value) then return false end
        if type(schema.enum) == 'table' then
            local found = false
            for _, candidate in ipairs(schema.enum) do
                if candidate == value then found = true break end
            end
            if not found then return false end
        end
        if type(value) == 'string' then
            if schema.minLength and #value < schema.minLength
                or schema.maxLength and #value > schema.maxLength
                or schema.pattern and value:match(schema.pattern) == nil then return false end
        elseif type(value) == 'number' then
            if schema.minimum and value < schema.minimum
                or schema.maximum and value > schema.maximum then return false end
        elseif type(value) == 'table' then
            if schema.type == 'array' then
                if schema.maxItems and #value > schema.maxItems
                    or schema.minItems and #value < schema.minItems then return false end
                if schema.items then
                    for _, item in ipairs(value) do
                        if not validateSchema(schema.items, item, depth + 1) then return false end
                    end
                end
            else
                local properties = type(schema.properties) == 'table' and schema.properties or {}
                for key, item in pairs(value) do
                    local propertySchema = properties[key]
                    if not propertySchema and schema.additionalProperties == false then return false end
                    if propertySchema and not validateSchema(propertySchema, item, depth + 1) then
                        return false
                    end
                end
                for _, required in ipairs(schema.required or {}) do
                    if value[required] == nil then return false end
                end
            end
        end
        return true
    end

    function service.copy(value, expectedType)
        return copyValue(value, expectedType)
    end

    function service.validate(schema, value, code)
        local copied, copyError = copyValue(value, type(schema) == 'table' and schema.type or nil)
        if not copied and copyError then
            copyError.code = code or copyError.code
            return nil, copyError
        end
        if not validateSchema(schema, copied, 1) then
            return failure(code or 'SCHEMA_INVALID', 'The value does not satisfy its registered schema')
        end
        local encodedOk, encoded = foundation.protect('entity.json.encode', function()
            return ports.jsonEncode(copied)
        end)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > maximumBytes then
            return failure(code or 'SCHEMA_INVALID', 'The encoded value exceeds its supported bounds')
        end
        return copied, nil, encoded
    end

    function service.decode(encoded, expectedType)
        if type(encoded) ~= 'string' or #encoded > maximumBytes then
            return failure('INVALID_JSON_VALUE', 'The encoded value is outside its supported bounds')
        end
        local decodedOk, value = foundation.protect('entity.json.decode', function()
            return ports.jsonDecode(encoded)
        end)
        if not decodedOk then
            return failure('INVALID_JSON_VALUE', 'The encoded value is invalid')
        end
        return copyValue(value, expectedType)
    end

    return service
end
