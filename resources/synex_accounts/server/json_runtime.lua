return function(runtimeJson)
    if type(runtimeJson) ~= 'table' then
        error('synex_accounts requires the Cfx JSON runtime', 2)
    end

    local runtimeDecode = rawget(runtimeJson, 'decode')
    local runtimeEncode = rawget(runtimeJson, 'encode')
    if type(runtimeDecode) ~= 'function' or type(runtimeEncode) ~= 'function' then
        error('synex_accounts requires Cfx JSON encode and decode functions', 2)
    end

    -- Cfx's dkjson decoder can otherwise create a fresh metatable for every
    -- decoded object and array. Supplying private, inert markers gives the
    -- Accounts boundary identities it can validate without trusting arbitrary
    -- executable metatables.
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
