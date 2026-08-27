return function(runtimeJson)
    if type(runtimeJson) ~= 'table' then
        error('synex_groups requires the Cfx JSON runtime', 2)
    end

    local runtimeDecode = rawget(runtimeJson, 'decode')
    local runtimeEncode = rawget(runtimeJson, 'encode')
    if type(runtimeDecode) ~= 'function' or type(runtimeEncode) ~= 'function' then
        error('synex_groups requires Cfx JSON encode and decode functions', 2)
    end

    -- Cfx's dkjson decoder can attach caller-owned, inert metatables to every
    -- decoded object and array. Supplying the pair avoids trusting the fresh
    -- metatable identities created by the runtime's default decode path.
    local objectMetatable = { __jsontype = 'object' }
    local arrayMetatable = { __jsontype = 'array' }

    return {
        decode = function(value)
            return runtimeDecode(value, 1, nil, objectMetatable, arrayMetatable)
        end,
        encode = function(value)
            return runtimeEncode(value)
        end
    }
end
