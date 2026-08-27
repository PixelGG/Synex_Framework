return function(Foundation)
local MAXIMUM_CATALOG_BYTES = 524288
local MAXIMUM_CATALOG_KEYS = 16384
local COPY_FAILURE_CODES = {
    ['JSON numbers must be finite'] = 'non_finite_number',
    ['JSON strings exceed the configured bound'] = 'string_bound',
    ['JSON values must be bounded acyclic containers'] = 'container_or_depth',
    ['JSON values contain too many keys'] = 'key_bound',
    ['JSON object keys are invalid'] = 'object_key',
    ['JSON containers cannot mix array and object keys'] = 'mixed_container',
    ['JSON container shape does not match its declared kind'] = 'container_shape'
}

local function classifyUnsupportedValue(value)
    local active, visited = {}, 0
    local function inspect(candidate, depth)
        local candidateType = type(candidate)
        if candidateType == 'nil' or candidateType == 'boolean'
            or candidateType == 'number' or candidateType == 'string' then
            return nil
        end
        if candidateType ~= 'table' then return 'unsupported_' .. candidateType end
        if Foundation.jsonContainerKind(candidate) == nil then
            return 'container_metadata'
        end
        if active[candidate] then return 'container_cycle' end
        if depth > 25 then return 'container_depth' end
        visited = visited + 1
        if visited > MAXIMUM_CATALOG_KEYS then return 'container_count' end
        active[candidate] = true
        for _, child in next, candidate do
            local reason = inspect(child, depth + 1)
            if reason then active[candidate] = nil return reason end
        end
        active[candidate] = nil
        return nil
    end
    return inspect(value, 1) or 'unknown'
end

local function loadDefinitions(rawCatalog, decode)
    if type(rawCatalog) ~= 'string' or #rawCatalog < 2
        or #rawCatalog > MAXIMUM_CATALOG_BYTES then
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID', 'The Groups contract catalog is missing or exceeds its bound.')
    end
    if type(decode) ~= 'function' then
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID', 'A JSON decoder is required for the Groups contract catalog.')
    end
    local decodedOk, decoded = pcall(decode, rawCatalog)
    if not decodedOk then
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID', 'The Groups contract catalog is not valid JSON.')
    end
    local copiedOk, catalog = pcall(Foundation.copyPlain, decoded, {
        maximumDepth = 25,
        maximumKeys = MAXIMUM_CATALOG_KEYS,
        maximumStringBytes = 32768
    })
    if not copiedOk then
        local reason = COPY_FAILURE_CODES[tostring(catalog)]
        if reason == nil or reason == 'container_or_depth' then
            reason = classifyUnsupportedValue(decoded)
        end
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID',
            ('The Groups contract catalog contains an unsupported JSON value (%s).')
                :format(reason), false,
            { stage = 'bounded_copy', reason = reason })
    end
    if type(catalog) ~= 'table' or catalog.schema ~= 1
        or catalog.domain ~= 'synex.groups' then
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID',
            'The Groups contract catalog has invalid identity metadata.', false,
            { stage = 'identity' })
    end
    if type(catalog.contracts) ~= 'table'
        or #catalog.contracts < 1 or #catalog.contracts > 128 then
        return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID',
            'The Groups contract catalog has an invalid contract collection.', false,
            { stage = 'contracts' })
    end

    local definitions, names = {}, {}
    for index, contract in ipairs(catalog.contracts) do
        local networkAllowed = type(contract) == 'table' and (
            contract.network == 'none'
            or contract.name == 'synex.groups.self.snapshot'
                and contract.network == 'client-to-server')
        if type(contract) ~= 'table' or type(contract.name) ~= 'string'
            or contract.name:sub(1, 13) ~= 'synex.groups.'
            or contract.provider ~= 'synex_groups' or contract.kind ~= 'rpc'
            or not networkAllowed or names[contract.name]
            or type(contract.input) ~= 'table' or type(contract.output) ~= 'table'
            or type(contract.errors) ~= 'table' then
            return nil, Foundation.domainError('CONTRACT_CATALOG_INVALID',
                'The Groups contract catalog contains an invalid contract.', false, { index = index })
        end
        names[contract.name] = true
        contract.domain = catalog.domain
        definitions[#definitions + 1] = contract
    end
    table.sort(definitions, function(left, right)
        if left.name == right.name then return left.version < right.version end
        return left.name < right.name
    end)
    return definitions, nil
end

return loadDefinitions
end
