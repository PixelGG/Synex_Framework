SynexSecurityValidation = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = SynexSecurityValidation
local INVALID = {}
local CONTROL_PATTERN = '[%z\1-\8\11\12\14-\31\127]'
local SENSITIVE_KEYS = {
    accesstoken = true, apikey = true, authorization = true, bearer = true,
    cfxkey = true, connectionstring = true, connectionuri = true,
    cookie = true, credential = true, credentials = true,
    databasepassword = true, databaseuri = true, databaseurl = true,
    dburl = true, dsn = true, licensekey = true, mysqluri = true,
    mysqlurl = true, passphrase = true, password = true, privatekey = true,
    rawip = true, refreshtoken = true, remoteaddress = true,
    secret = true, serverkey = true, sessioncookie = true,
    steamwebapikey = true, token = true, webhook = true, webhookurl = true,
    ipaddress = true,
}

local function normalizedKey(value)
    return type(value) == 'string' and value:lower():gsub('[^a-z0-9]', '') or ''
end

local function sensitiveKey(value)
    local normalized = normalizedKey(value)
    return SENSITIVE_KEYS[normalized] == true
        or normalized:find('password', 1, true) ~= nil
        or normalized:find('passphrase', 1, true) ~= nil
        or normalized:find('secret', 1, true) ~= nil
        or normalized:find('credential', 1, true) ~= nil
        or normalized:find('webhook', 1, true) ~= nil
        or normalized:find('privatekey', 1, true) ~= nil
        or normalized:find('apikey', 1, true) ~= nil
        or normalized:find('accesstoken', 1, true) ~= nil
        or normalized:find('refreshtoken', 1, true) ~= nil
        or normalized:find('connectionstring', 1, true) ~= nil
        or normalized:match('token$') ~= nil
end

local function containsIpv4(value)
    for candidate in value:gmatch('%d+%.%d+%.%d+%.%d+') do
        local parts, valid = 0, true
        for part in candidate:gmatch('%d+') do
            parts = parts + 1
            local number = tonumber(part)
            if number == nil or number > 255 then valid = false; break end
        end
        if valid and parts == 4 then return true end
    end
    return false
end

local function containsIpv6(value)
    for candidate in value:gmatch('[%x:]+') do
        local _, colons = candidate:gsub(':', '')
        if #candidate >= 4 and colons >= 3
            and candidate:match('%x') ~= nil then return true end
    end
    return false
end

local function sensitiveText(value)
    if type(value) ~= 'string' then return false end
    local normalized = value:lower()
    if normalized:match('bearer%s+[%w%._~+/=%-]+') ~= nil
        or normalized:find('mysql://', 1, true) ~= nil
        or normalized:find('mariadb://', 1, true) ~= nil
        or normalized:find('discord.com/api/webhooks/', 1, true) ~= nil
        or normalized:find('discordapp.com/api/webhooks/', 1, true) ~= nil
        or normalized:find('-----begin ', 1, true) ~= nil
            and normalized:find('private key-----', 1, true) ~= nil
        or normalized:match('[a-z][a-z0-9+.-]*://[^/%s:]+:[^@/%s]+@') ~= nil
        or normalized:match('cfxk_[%w_%-]+') ~= nil
        or normalized:match('gh[pousr]_[%w_%-]+') ~= nil
        or normalized:match('[?&]access[_%-]?token=[^&#%s]+') ~= nil
        or normalized:match('[?&]api[_%-]?key=[^&#%s]+') ~= nil
        or normalized:match('[?&]secret=[^&#%s]+') ~= nil
        or normalized:match('[?&]signature=[^&#%s]+') ~= nil
        or normalized:match('[?&]token=[^&#%s]+') ~= nil then return true end
    return containsIpv4(normalized) or containsIpv6(normalized)
end

local function containerKind(value)
    if type(value) ~= 'table' then return nil end
    local metadata = getmetatable(value)
    if metadata == nil then return 'plain' end
    if type(metadata) ~= 'table'
        or metadata.__jsontype ~= 'object' and metadata.__jsontype ~= 'array' then
        return nil
    end
    for key in next, metadata do
        if key ~= '__jsontype' then return nil end
    end
    return metadata.__jsontype
end

local function encodedBytes(value, depth, seen)
    local valueType = type(value)
    if value == nil then return 4 end
    if valueType == 'boolean' then return value and 4 or 5 end
    if valueType == 'number' then
        if not Validation.isFinite(value) then return nil end
        return #tostring(value)
    end
    if valueType == 'string' then return 2 + #value * 6 end
    if valueType ~= 'table' or depth > Limits.maximumEvidenceDepth
        or seen[value] or containerKind(value) == nil then return nil end
    seen[value] = true
    local bytes, count = 2, 0
    for key, child in next, value do
        count = count + 1
        if count > Limits.maximumEvidenceEntries then seen[value] = nil; return nil end
        if type(key) == 'string' then bytes = bytes + 2 + #key * 6
        elseif Validation.isInteger(key, 1, Limits.maximumEvidenceEntries) then
            bytes = bytes + #tostring(key)
        else
            seen[value] = nil
            return nil
        end
        local childBytes = encodedBytes(child, depth + 1, seen)
        if childBytes == nil then seen[value] = nil; return nil end
        bytes = bytes + childBytes + 2
    end
    seen[value] = nil
    return bytes
end

function Validation.failure(code, message, retryable, details)
    local value = {
        code = tostring(code or 'SECURITY_UNAVAILABLE'),
        message = tostring(message or 'The security runtime is unavailable.'),
        retryable = retryable == true,
    }
    if type(details) == 'table' then value.details = details end
    return nil, value
end

function Validation.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local ok, metadata = pcall(getmetatable, value)
    if not ok then return false end
    if type(metadata) == 'table' and type(metadata.__call) == 'function' then return true end
    if metadata == 'locked' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local resolved, actual = pcall(debug.getmetatable, value)
        return resolved and type(actual) == 'table' and type(actual.__call) == 'function'
    end
    return false
end

function Validation.isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

function Validation.isInteger(value, minimum, maximum)
    return Validation.isFinite(value) and value == math.floor(value)
        and value >= (minimum or -Limits.maximumSafeInteger)
        and value <= (maximum or Limits.maximumSafeInteger)
end

function Validation.text(value, minimum, maximum)
    return type(value) == 'string' and #value >= (minimum or 0)
        and #value <= (maximum or Limits.maximumEvidenceStringBytes)
        and value:find(CONTROL_PATTERN) == nil
end

function Validation.token(value, minimum, maximum)
    return Validation.text(value, minimum or 1, maximum or Limits.maximumIdentifierBytes)
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

function Validation.semanticKey(value, maximum)
    return Validation.text(value, 3, maximum or Limits.maximumIdentifierBytes)
        and value:match('^[a-z][a-z0-9]*[a-z0-9_.%-]*$') ~= nil
        and value:match('[._%-]$') == nil
        and value:match('[._%-][._%-]') == nil
end

function Validation.namespace(value)
    return Validation.semanticKey(value, Limits.maximumNamespaceBytes)
end

function Validation.resourceName(value)
    return Validation.text(value, 3, Limits.maximumResourceNameBytes)
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

function Validation.errorCode(value)
    return Validation.text(value, 3, Limits.maximumCodeBytes)
        and value:match('^[A-Z][A-Z0-9_]*$') ~= nil
end

function Validation.safeText(value, minimum, maximum)
    return Validation.text(value, minimum, maximum) and not sensitiveText(value)
end

function Validation.sensitiveFree(value)
    local seen, entries = {}, 0
    local function inspect(candidate, depth)
        local valueType = type(candidate)
        if candidate == nil or valueType == 'boolean' then return true end
        if valueType == 'number' then return Validation.isFinite(candidate) end
        if valueType == 'string' then return not sensitiveText(candidate) end
        if valueType ~= 'table' or depth > Limits.maximumEvidenceDepth
            or seen[candidate] then return false end
        seen[candidate] = true
        for key, child in next, candidate do
            entries = entries + 1
            if entries > Limits.maximumEvidenceEntries
                or type(key) == 'string' and sensitiveKey(key)
                or not inspect(child, depth + 1) then
                seen[candidate] = nil
                return false
            end
        end
        seen[candidate] = nil
        return true
    end
    return inspect(value, 0)
end

function Validation.exactObject(value, allowed, required)
    local kind = containerKind(value)
    if kind == nil or kind == 'array' then return false end
    for key in next, value do
        if type(key) ~= 'string' or not allowed[key] then return false end
    end
    for key in pairs(required or {}) do
        if rawget(value, key) == nil then return false end
    end
    return true
end

function Validation.arrayLength(value, maximum)
    local kind = containerKind(value)
    if kind == nil or kind == 'object' then return nil end
    local count = 0
    for key in next, value do
        if not Validation.isInteger(key, 1, maximum) then return nil end
        count = count + 1
        if count > maximum then return nil end
    end
    for index = 1, count do
        if rawget(value, index) == nil then return nil end
    end
    return count
end

function Validation.payloadBytes(value, maximum)
    local bytes = encodedBytes(value, 0, {})
    if bytes == nil then
        return Validation.failure('SECURITY_VALUE_INVALID',
            'The security value is not canonically serializable.')
    end
    if bytes > (maximum or Limits.maximumSignalBytes) then
        return Validation.failure('SECURITY_PAYLOAD_TOO_LARGE',
            'The security value exceeds its canonical byte limit.')
    end
    return bytes, nil
end

function Validation.copy(value, options)
    options = options or {}
    local maximumDepth = options.maximumDepth or Limits.maximumEvidenceDepth
    local maximumEntries = options.maximumEntries or Limits.maximumEvidenceEntries
    local maximumStringBytes = options.maximumStringBytes
        or Limits.maximumEvidenceStringBytes
    local entries, seen = 0, {}
    local function clone(candidate, depth)
        local valueType = type(candidate)
        if candidate == nil or valueType == 'boolean' then return candidate end
        if valueType == 'number' then
            if not Validation.isFinite(candidate) then return INVALID end
            return candidate
        end
        if valueType == 'string' then
            if not Validation.text(candidate, 0, maximumStringBytes) then return INVALID end
            return candidate
        end
        local kind = containerKind(candidate)
        if valueType ~= 'table' or kind == nil or depth > maximumDepth
            or seen[candidate] then return INVALID end
        seen[candidate] = true
        local result = {}
        for key, child in next, candidate do
            entries = entries + 1
            if entries > maximumEntries
                or type(key) ~= 'string'
                    and not Validation.isInteger(key, 1, maximumEntries) then
                seen[candidate] = nil
                return INVALID
            end
            if type(key) == 'string' and not Validation.text(key, 1, 96) then
                seen[candidate] = nil
                return INVALID
            end
            local copied = clone(child, depth + 1)
            if copied == INVALID then seen[candidate] = nil; return INVALID end
            result[key] = copied
        end
        seen[candidate] = nil
        if kind == 'object' or kind == 'array' then
            setmetatable(result, { __jsontype = kind })
        end
        return result
    end
    local copied = clone(value, 0)
    if copied == INVALID then
        return Validation.failure('SECURITY_VALUE_INVALID',
            'The security value contains an unsupported or unbounded value.')
    end
    local _, sizeError = Validation.payloadBytes(copied,
        options.maximumBytes or Limits.maximumEvidenceBytes)
    if sizeError then return nil, sizeError end
    return copied, nil
end

function Validation.stringArray(value, maximum, validator)
    if value == nil then return nil, nil end
    local count = Validation.arrayLength(value, maximum)
    if count == nil then
        return Validation.failure('SECURITY_VALUE_INVALID',
            'The security selector must be a bounded dense array.')
    end
    local result, seen = {}, {}
    for index = 1, count do
        local item = value[index]
        if not validator(item) or seen[item] then
            return Validation.failure('SECURITY_VALUE_INVALID',
                'The security selector contains an invalid or duplicate value.')
        end
        seen[item], result[index] = true, item
    end
    return result, nil
end

function Validation.subject(value)
    if not Validation.exactObject(value, {
        source = true, sessionId = true, sourceGeneration = true, userId = true,
        characterId = true, resourceName = true,
    }) then
        return Validation.failure('SECURITY_SUBJECT_INVALID',
            'The security subject contains unsupported fields.')
    end
    local hasIdentity = value.sessionId ~= nil or value.userId ~= nil
        or value.characterId ~= nil or value.resourceName ~= nil
    if not hasIdentity
        or value.sessionId ~= nil and (not Validation.token(value.sessionId, 3, 96)
            or not Validation.safeText(value.sessionId, 3, 96))
        or value.sessionId ~= nil and not Validation.isInteger(
            value.sourceGeneration, 1, Limits.maximumSafeInteger)
        or value.sessionId == nil and value.sourceGeneration ~= nil
        or value.source ~= nil and value.sessionId == nil
        or value.source ~= nil and not Validation.isInteger(
            value.source, 1, Limits.maximumPlayerSource)
        or value.userId ~= nil and (not Validation.token(value.userId, 3, 96)
            or not Validation.safeText(value.userId, 3, 96))
        or value.characterId ~= nil and (not Validation.token(value.characterId, 3, 96)
            or not Validation.safeText(value.characterId, 3, 96))
        or value.resourceName ~= nil and (not Validation.resourceName(value.resourceName)
            or not Validation.safeText(value.resourceName, 3,
                Limits.maximumResourceNameBytes)) then
        return Validation.failure('SECURITY_SUBJECT_INVALID',
            'The security subject identity is invalid or stale.')
    end
    return {
        source = value.source,
        sessionId = value.sessionId,
        sourceGeneration = value.sourceGeneration,
        userId = value.userId,
        characterId = value.characterId,
        resourceName = value.resourceName,
    }, nil
end

function Validation.subjectKey(value)
    local subject = value.subject or value
    if type(subject) ~= 'table' then return nil end
    if subject.sessionId ~= nil then
        return 'session:' .. subject.sessionId .. ':' .. tostring(subject.sourceGeneration)
    end
    if subject.userId ~= nil then return 'user:' .. subject.userId end
    if subject.characterId ~= nil then return 'character:' .. subject.characterId end
    if subject.resourceName ~= nil then return 'resource:' .. subject.resourceName end
    return nil
end

function Validation.namespaceOwned(ownerResource, namespace)
    if not Validation.resourceName(ownerResource) or not Validation.namespace(namespace) then
        return false
    end
    local root = ownerResource:lower():gsub('_', '.')
    return namespace == root or namespace:sub(1, #root + 1) == root .. '.'
end
