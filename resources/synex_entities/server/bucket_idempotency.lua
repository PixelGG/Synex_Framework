SynexEntityBucketIdempotency = {}

local operationCodes = {
    ['bucket.create'] = 'bc',
    ['bucket.destroy'] = 'bd',
    ['bucket.move-player'] = 'bm',
}
local base36Digits = '0123456789abcdefghijklmnopqrstuvwxyz'

local function encodeCaller(caller)
    if type(caller) ~= 'string' or #caller < 7 or #caller > 64
        or caller:match('^synex_[a-z0-9_]+$') == nil then return nil end
    local digits = {}
    for index = 7, #caller do
        local byte = caller:byte(index)
        if byte >= 97 and byte <= 122 then
            digits[#digits + 1] = byte - 96
        elseif byte >= 48 and byte <= 57 then
            digits[#digits + 1] = byte - 21
        else
            digits[#digits + 1] = 37
        end
    end

    -- Resource suffixes are base-38 digits 1..37. Arbitrary-precision long
    -- division preserves the complete caller identity in Core-safe base 36.
    local encoded = {}
    while #digits > 0 do
        local quotient, carry = {}, 0
        for _, digit in ipairs(digits) do
            local current = carry * 38 + digit
            local divided = math.floor(current / 36)
            carry = current - divided * 36
            if #quotient > 0 or divided > 0 then
                quotient[#quotient + 1] = divided
            end
        end
        encoded[#encoded + 1] = base36Digits:sub(carry + 1, carry + 1)
        digits = quotient
    end
    if #encoded > 59 then return nil end
    local reversed = {}
    for index = #encoded, 1, -1 do reversed[#reversed + 1] = encoded[index] end
    return table.concat(reversed)
end

function SynexEntityBucketIdempotency.operation(operation, caller)
    local operationCode = operationCodes[operation]
    local encodedCaller = encodeCaller(caller)
    if not operationCode or not encodedCaller then return nil end
    local scoped = operationCode .. '.' .. encodedCaller
    return #scoped <= 64 and scoped or nil
end
