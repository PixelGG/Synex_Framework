local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.contracts = function(deps)
    local foundation = assert(deps.foundation, 'contracts require foundation')
    local protocol = deps.protocol or SynexProtocol

    local function valueType(value)
        local kind = type(value)
        if kind == 'number' and math.type(value) == 'integer' then return 'integer' end
        if kind == 'table' then return 'object' end
        return kind
    end

    local function arrayLength(value)
        local maximum = 0
        local count = 0
        for key in pairs(value) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
            maximum = math.max(maximum, key)
            count = count + 1
        end
        if maximum ~= count then return nil end
        return count
    end

    local function equals(left, right)
        if type(left) ~= type(right) then return false end
        if type(left) ~= 'table' then return left == right end
        for key, value in pairs(left) do if not equals(value, right[key]) then return false end end
        for key in pairs(right) do if left[key] == nil then return false end end
        return true
    end

    local function validate(schema, value, path, state)
        schema = schema or {}
        path = path or '$'
        state = state or { depth = 0, keys = 0 }
        state.depth = state.depth + 1
        if state.depth > (protocol.limits.tableDepth or 12) then
            state.depth = state.depth - 1
            return nil, { path = path, rule = 'maxDepth', message = 'maximum nesting depth exceeded' }
        end

        if schema.const ~= nil and not equals(schema.const, value) then
            state.depth = state.depth - 1
            return nil, { path = path, rule = 'const', message = 'value does not equal the required constant' }
        end
        if type(schema.enum) == 'table' then
            local found = false
            for _, candidate in ipairs(schema.enum) do if equals(candidate, value) then found = true break end end
            if not found then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'enum', message = 'value is not an allowed enum member' }
            end
        end
        if type(schema.oneOf) == 'table' or type(schema.anyOf) == 'table' then
            local choices = schema.oneOf or schema.anyOf
            local matches = 0
            for _, candidate in ipairs(choices) do
                local candidateState = { depth = state.depth - 1, keys = state.keys }
                if validate(candidate, value, path, candidateState) then matches = matches + 1 end
            end
            if matches == 0 or (schema.oneOf and matches ~= 1) then
                state.depth = state.depth - 1
                return nil, { path = path, rule = schema.oneOf and 'oneOf' or 'anyOf', message = 'value does not match the alternatives' }
            end
        end

        local expected = schema.type
        if type(expected) == 'table' then
            local matched = false
            for _, candidate in ipairs(expected) do
                if candidate == valueType(value) or (candidate == 'number' and type(value) == 'number') then matched = true break end
            end
            if not matched then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'type', message = 'value has the wrong type' }
            end
        elseif expected then
            local actual = valueType(value)
            local matched = actual == expected or (expected == 'number' and type(value) == 'number')
            if expected == 'array' then matched = type(value) == 'table' and arrayLength(value) ~= nil end
            if expected == 'object' then matched = type(value) == 'table' end
            if not matched then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'type', message = ('expected %s, received %s'):format(expected, actual) }
            end
        end

        if type(value) == 'string' then
            local length = #value
            if length > (protocol.limits.stringBytes or 16384) then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'payloadLimit', message = 'string exceeds the protocol byte limit' }
            end
            if schema.minLength and length < schema.minLength then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'minLength', message = 'string is too short' }
            end
            if schema.maxLength and length > schema.maxLength then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'maxLength', message = 'string is too long' }
            end
            if schema.pattern and not value:match(schema.pattern) then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'pattern', message = 'string does not match the required pattern' }
            end
        elseif type(value) == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'finite', message = 'number must be finite' }
            end
            if schema.minimum and value < schema.minimum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'minimum', message = 'number is below the minimum' }
            end
            if schema.maximum and value > schema.maximum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'maximum', message = 'number exceeds the maximum' }
            end
            if schema.exclusiveMinimum and value <= schema.exclusiveMinimum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'exclusiveMinimum', message = 'number must be greater than the minimum' }
            end
            if schema.exclusiveMaximum and value >= schema.exclusiveMaximum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'exclusiveMaximum', message = 'number must be less than the maximum' }
            end
        elseif type(value) == 'table' then
            local length = arrayLength(value)
            if expected == 'array' or (length ~= nil and schema.items) then
                length = length or 0
                if schema.minItems and length < schema.minItems then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'minItems', message = 'array is too short' }
                end
                if schema.maxItems and length > schema.maxItems then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'maxItems', message = 'array is too long' }
                end
                for index = 1, length do
                    local ok, err = validate(schema.items or {}, value[index], ('%s[%d]'):format(path, index), state)
                    if not ok then state.depth = state.depth - 1 return nil, err end
                end
            else
                local required = {}
                for _, key in ipairs(schema.required or {}) do required[key] = true end
                for key in pairs(required) do
                    if value[key] == nil then
                        state.depth = state.depth - 1
                        return nil, { path = path .. '.' .. key, rule = 'required', message = 'required property is missing' }
                    end
                end
                for key, item in pairs(value) do
                    state.keys = state.keys + 1
                    if state.keys > (protocol.limits.tableKeys or 512) then
                        state.depth = state.depth - 1
                        return nil, { path = path, rule = 'payloadLimit', message = 'object contains too many properties' }
                    end
                    if type(key) ~= 'string' then
                        state.depth = state.depth - 1
                        return nil, { path = path, rule = 'propertyName', message = 'object properties must be strings' }
                    end
                    local propertySchema = schema.properties and schema.properties[key]
                    if not propertySchema and schema.additionalProperties == false then
                        state.depth = state.depth - 1
                        return nil, { path = path .. '.' .. key, rule = 'additionalProperties', message = 'unknown property is not allowed' }
                    end
                    if propertySchema then
                        local ok, err = validate(propertySchema, item, path .. '.' .. key, state)
                        if not ok then state.depth = state.depth - 1 return nil, err end
                    end
                end
            end
        end
        state.depth = state.depth - 1
        return true, nil
    end

    local contractsByName = {}
    local registry = {}

    local function validateDefinition(contract)
        if type(contract) ~= 'table' or type(contract.name) ~= 'string' or type(contract.version) ~= 'string' then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract name and version are required.')
        end
        local version = foundation.semver(contract.version)
        if not version then return nil, foundation.error('INVALID_CONTRACT_VERSION', 'Contract version must be semantic.') end
        if type(contract.input) ~= 'table' or type(contract.output) ~= 'table' then
            return nil, foundation.error('INVALID_CONTRACT', 'Input and output schemas are required.')
        end
        if contract.network ~= 'none' and contract.network ~= 'client-to-server' and contract.network ~= 'server-to-client' then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract network exposure is invalid.')
        end
        return version, nil
    end

    function registry:register(contract)
        local version, err = validateDefinition(contract)
        if not version then return nil, err end
        contractsByName[contract.name] = contractsByName[contract.name] or {}
        local versions = contractsByName[contract.name]
        if versions[contract.version] then return nil, foundation.error('CONTRACT_EXISTS', 'The contract version is already registered.') end
        local stored = foundation.copy(contract)
        stored.major = version.major
        versions[contract.version] = stored
        return foundation.copy(stored), nil
    end

    function registry:resolve(name, requestedVersion)
        local versions = contractsByName[name]
        if not versions then return nil, foundation.error('CONTRACT_NOT_FOUND', 'The requested contract does not exist.') end
        if versions[requestedVersion] then return foundation.copy(versions[requestedVersion]), nil end
        local best = nil
        for version, contract in pairs(versions) do
            if foundation.semverSatisfies(version, requestedVersion) then
                local candidateVersion = foundation.semver(version)
                local bestVersion = best and foundation.semver(best.version) or nil
                if not bestVersion or candidateVersion.major > bestVersion.major
                    or (candidateVersion.major == bestVersion.major and candidateVersion.minor > bestVersion.minor)
                    or (candidateVersion.major == bestVersion.major and candidateVersion.minor == bestVersion.minor
                        and candidateVersion.patch > bestVersion.patch) then
                    best = contract
                end
            end
        end
        if not best then return nil, foundation.error('CONTRACT_VERSION_UNAVAILABLE', 'No compatible contract version is registered.') end
        return foundation.copy(best), nil
    end

    function registry:validateInput(contract, value)
        local ok, finding = validate(contract.input, value)
        if not ok then
            return nil, foundation.error('VALIDATION_FAILED', 'The request does not match its contract.', { details = finding })
        end
        return true, nil
    end
    function registry:validateOutput(contract, value)
        local ok, finding = validate(contract.output, value)
        if not ok then
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE', 'The provider returned an invalid response.', { details = finding })
        end
        return true, nil
    end
    function registry:list()
        local result = {}
        for _, versions in pairs(contractsByName) do
            for _, contract in pairs(versions) do result[#result + 1] = foundation.copy(contract) end
        end
        table.sort(result, function(a, b)
            if a.name == b.name then return a.version < b.version end
            return a.name < b.name
        end)
        return result
    end

    for _, contract in ipairs((deps.generated and deps.generated.contracts) or {}) do
        local registered, err = registry:register(contract)
        if not registered then error(('generated contract rejected: %s'):format(err.message)) end
    end

    return { registry = registry, validate = validate }
end
