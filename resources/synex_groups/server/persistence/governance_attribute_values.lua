return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local ATTRIBUTE_TYPES = Shared.ATTRIBUTE_TYPES
local arrayLength = Shared.arrayLength
local closedObject = Shared.closedObject
local copyJson = Shared.copyJson
local canonical = Shared.canonical
local scalarEquals = Shared.scalarEquals

local function enumValueAllowed(values, candidate)
    if values == nil then return true end
    for _, item in ipairs(values) do
        if scalarEquals(item, candidate) then return true end
    end
    return false
end

local function storableDecimal(value)
    if type(value) ~= 'number' or value ~= value
        or value == math.huge or value == -math.huge
        or value <= -100000000000000 or value >= 100000000000000 then
        return false
    end
    -- The persistence columns are DECIMAL(20, 6). Reject lossy inputs instead
    -- of allowing MariaDB to round a schema default or member value silently.
    local normalized = tonumber(string.format('%.6f', value))
    return normalized ~= nil and normalized == value
end

local function validateAttributeRules(valueKind, value)
    if value == nil then return {}, nil end
    local rules, copyError = copyJson(value, {
        maximumDepth = 3,
        maximumKeys = 64,
        maximumStringBytes = 1024,
        preserveContainerKind = false
    })
    if not rules then return nil, copyError end
    local valid, validationError = closedObject(rules, {
        required = true,
        min_length = true,
        max_length = true,
        minimum = true,
        maximum = true,
        enum = true
    }, 'Attribute validation')
    if not valid then return nil, validationError end
    if rules.required ~= nil and type(rules.required) ~= 'boolean' then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Attribute validation required must be boolean.')
    end
    if rules.min_length ~= nil or rules.max_length ~= nil then
        if valueKind ~= 'string'
            or rules.min_length ~= nil and (type(rules.min_length) ~= 'number'
                or math.type(rules.min_length) ~= 'integer'
                or rules.min_length < 0 or rules.min_length > 512)
            or rules.max_length ~= nil and (type(rules.max_length) ~= 'number'
                or math.type(rules.max_length) ~= 'integer'
                or rules.max_length < 0 or rules.max_length > 512)
            or rules.min_length ~= nil and rules.max_length ~= nil
                and rules.min_length > rules.max_length then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Attribute string length validation is invalid.')
        end
    end
    if rules.minimum ~= nil or rules.maximum ~= nil then
        if valueKind ~= 'integer' and valueKind ~= 'decimal'
            or rules.minimum ~= nil and (type(rules.minimum) ~= 'number'
                or rules.minimum ~= rules.minimum or rules.minimum == math.huge
                or rules.minimum == -math.huge)
            or rules.maximum ~= nil and (type(rules.maximum) ~= 'number'
                or rules.maximum ~= rules.maximum or rules.maximum == math.huge
                or rules.maximum == -math.huge)
            or rules.minimum ~= nil and rules.maximum ~= nil
                and rules.minimum > rules.maximum then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Attribute numeric validation is invalid.')
        end
    end
    if rules.enum ~= nil then
        local count = arrayLength(rules.enum, 32)
        if count == nil or count == 0 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Attribute enum must be a bounded non-empty dense array.')
        end
        for index = 1, count do
            local candidate = rules.enum[index]
            local candidateType = type(candidate)
            local expected = valueKind
            if valueKind == 'integer' or valueKind == 'decimal' then expected = 'number' end
            if valueKind == 'datetime' then expected = 'string' end
            if valueKind == 'json' or candidateType ~= expected
                or valueKind == 'integer' and math.type(candidate) ~= 'integer'
                or valueKind == 'integer'
                    and (candidate < -9007199254740991
                        or candidate > 9007199254740991)
                or valueKind == 'decimal' and not storableDecimal(candidate)
                or candidateType == 'number' and (candidate ~= candidate
                    or candidate == math.huge or candidate == -math.huge) then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'Attribute enum contains a value of the wrong type.')
            end
        end
    end
    return rules, nil
end

local function storedAttributeValue(runtime, valueKind, row, prefix)
    prefix = prefix or ''
    if valueKind == 'string' then
        local value = row[prefix .. 'value_string']
        return type(value) == 'string' and value or nil
    end
    if valueKind == 'integer' then
        local value = tonumber(row[prefix .. 'value_integer'])
        return value and math.type(value) == 'integer' and value or nil
    end
    if valueKind == 'decimal' then
        local value = tonumber(row[prefix .. 'value_decimal'])
        return value and value == value and value ~= math.huge and value ~= -math.huge
            and value or nil
    end
    if valueKind == 'boolean' then
        local value = tonumber(row[prefix .. 'value_boolean'])
        if value == 0 then return false end
        if value == 1 then return true end
        return nil
    end
    if valueKind == 'datetime' then
        local value = row[prefix .. 'value_datetime']
        return value ~= nil and tostring(value) or nil
    end
    if valueKind == 'json' then
        local encoded = row[prefix .. 'value_json']
        if type(encoded) ~= 'string' or #encoded > 32768 then return nil end
        local decodedOk, decoded = pcall(runtime.jsonDecode, encoded)
        if decodedOk and decoded ~= nil then return decoded end
    end
    return nil
end

local function typedAttributeValue(tx, runtime, valueKind, rules, value)
    local result = {
        value_string = nil,
        value_integer = nil,
        value_decimal = nil,
        value_boolean = nil,
        value_datetime = nil,
        value_json = nil
    }
    if valueKind == 'string' then
        local length = Foundation.characterLength(value)
        if length < 0 or length > 512
            or rules.min_length ~= nil and length < rules.min_length
            or rules.max_length ~= nil and length > rules.max_length
            or not enumValueAllowed(rules.enum, value) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute string does not satisfy its schema.')
        end
        result.value_string = value
    elseif valueKind == 'integer' then
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < -9007199254740991 or value > 9007199254740991
            or rules.minimum ~= nil and value < rules.minimum
            or rules.maximum ~= nil and value > rules.maximum
            or not enumValueAllowed(rules.enum, value) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute integer does not satisfy its schema.')
        end
        result.value_integer = value
    elseif valueKind == 'decimal' then
        if not storableDecimal(value)
            or rules.minimum ~= nil and value < rules.minimum
            or rules.maximum ~= nil and value > rules.maximum
            or not enumValueAllowed(rules.enum, value) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute decimal does not satisfy its schema.')
        end
        result.value_decimal = value
    elseif valueKind == 'boolean' then
        if type(value) ~= 'boolean' or not enumValueAllowed(rules.enum, value) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute boolean does not satisfy its schema.')
        end
        result.value_boolean = value and 1 or 0
    elseif valueKind == 'datetime' then
        if type(value) ~= 'string' or #value < 19 or #value > 32
            or not value:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d')
            or not enumValueAllowed(rules.enum, value) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute datetime does not satisfy its schema.')
        end
        local normalized = tx.one([[SELECT DATE_FORMAT(CAST(? AS DATETIME(6)),
            '%Y-%m-%d %H:%i:%s.%f') AS normalized]], { value })
        if not normalized or type(normalized.normalized) ~= 'string' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute datetime is invalid.')
        end
        result.value_datetime = normalized.normalized
    elseif valueKind == 'json' then
        local copied, copyError = copyJson(value, {
            maximumDepth = 8,
            maximumKeys = 256,
            maximumStringBytes = 4096,
            preserveContainerKind = false
        })
        if copied == nil then return nil, copyError end
        local encoded, encodeError = canonical(runtime, copied)
        if not encoded then return nil, encodeError end
        if #encoded > 32768 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The attribute JSON value exceeds 32 KiB.')
        end
        result.value_json = encoded
    else
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute value kind is invalid.', true)
    end
    return result, nil
end

local function decodeStoredRules(runtime, schema)
    if type(schema.validation_json) ~= 'string' or #schema.validation_json > 32768 then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute validation is invalid.', true)
    end
    local decodedOk, decoded = pcall(runtime.jsonDecode, schema.validation_json)
    if not decodedOk then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute validation is invalid.', true)
    end
    local rules = validateAttributeRules(schema.value_kind, decoded)
    if not rules then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute validation is invalid.', true)
    end
    return rules, nil
end

return {
    ATTRIBUTE_TYPES = ATTRIBUTE_TYPES,
    validateAttributeRules = validateAttributeRules,
    storedAttributeValue = storedAttributeValue,
    typedAttributeValue = typedAttributeValue,
    decodeStoredRules = decodeStoredRules
}
end
