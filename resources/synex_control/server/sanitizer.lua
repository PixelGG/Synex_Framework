SynexControlSanitizer = {}

local sanitizer = SynexControlSanitizer

local secretKeys = {
    apikey = true,
    authorization = true,
    bearer = true,
    clientsecret = true,
    connectionstring = true,
    connectionuri = true,
    cookie = true,
    credential = true,
    credentials = true,
    cfxkey = true,
    databasepassword = true,
    databaseuri = true,
    databaseurl = true,
    dburl = true,
    dsn = true,
    licensekey = true,
    license = true,
    mysqluri = true,
    mysqlurl = true,
    oauthsecret = true,
    passphrase = true,
    password = true,
    privatekey = true,
    refreshtoken = true,
    secret = true,
    sessioncookie = true,
    serverkey = true,
    steamwebapikey = true,
    token = true,
    accesstoken = true,
    webhook = true,
    webhookurl = true,
}

local identifierKeys = {
    accountid = true,
    aggregateid = true,
    actorid = true,
    actorref = true,
    applicationid = true,
    assignmentid = true,
    bindingid = true,
    bindingref = true,
    characterid = true,
    callerprincipalref = true,
    citizenid = true,
    entryid = true,
    entityid = true,
    eventid = true,
    findingid = true,
    gradeid = true,
    grantid = true,
    groupid = true,
    holdid = true,
    id = true,
    idempotencykey = true,
    identifier = true,
    identifiers = true,
    instanceid = true,
    license2 = true,
    membershipid = true,
    outboxid = true,
    originaltransactionid = true,
    ownerid = true,
    ownerref = true,
    principalref = true,
    proposalid = true,
    publicid = true,
    reference = true,
    referenceid = true,
    relationshipid = true,
    roleid = true,
    runid = true,
    refundtransactionid = true,
    sessionid = true,
    serverinstanceid = true,
    playersource = true,
    subjectid = true,
    subjectref = true,
    targetid = true,
    transactionid = true,
    userid = true,
    workflowid = true,
}

local identifierFragments = {
    'account', 'aggregate', 'actor', 'application', 'assignment', 'binding',
    'bucket', 'character', 'citizen', 'component', 'definition', 'delegation',
    'entry', 'entity', 'event', 'finding', 'grade', 'grant', 'group', 'hold',
    'invitation', 'membership', 'outbox', 'owner', 'policy', 'principal',
    'proposal', 'recovery', 'reference', 'refund', 'relationship', 'role', 'run',
    'session', 'subject', 'target', 'transaction', 'user', 'workflow',
}

local providerMetadataNavigationPaths = {
    ['data.providers[].views[].id'] = true,
    ['data.providers[].views[].search.kinds[].id'] = true,
}

local function normalizeKey(key)
    return type(key) == 'string' and key:lower():gsub('[^a-z0-9]', '') or ''
end

local UTF8_REPLACEMENT = '\239\191\189'

local function utf8SequenceLength(value, index)
    local first = value:byte(index)
    if not first then return nil end
    if first <= 0x7f then return 1 end
    local second, third, fourth = value:byte(index + 1, index + 3)
    local function continuation(byte) return byte ~= nil and byte >= 0x80 and byte <= 0xbf end
    if first >= 0xc2 and first <= 0xdf and continuation(second) then return 2 end
    if first == 0xe0 and second and second >= 0xa0 and second <= 0xbf
        and continuation(third) then return 3 end
    if ((first >= 0xe1 and first <= 0xec) or (first >= 0xee and first <= 0xef))
        and continuation(second) and continuation(third) then return 3 end
    if first == 0xed and second and second >= 0x80 and second <= 0x9f
        and continuation(third) then return 3 end
    if first == 0xf0 and second and second >= 0x90 and second <= 0xbf
        and continuation(third) and continuation(fourth) then return 4 end
    if first >= 0xf1 and first <= 0xf3 and continuation(second)
        and continuation(third) and continuation(fourth) then return 4 end
    if first == 0xf4 and second and second >= 0x80 and second <= 0x8f
        and continuation(third) and continuation(fourth) then return 4 end
    return nil
end

local function boundedString(value, maximum)
    value = tostring(value)
    local chunks, used, replacements, index = {}, 0, 0, 1
    local truncated = false
    while index <= #value do
        local sequenceLength = utf8SequenceLength(value, index)
        local chunk
        if sequenceLength then
            chunk = value:sub(index, index + sequenceLength - 1)
            index = index + sequenceLength
        else
            chunk = UTF8_REPLACEMENT
            replacements = replacements + 1
            index = index + 1
        end
        if used + #chunk > maximum then
            truncated = true
            break
        end
        chunks[#chunks + 1] = chunk
        used = used + #chunk
    end
    truncated = truncated or index <= #value
    if truncated and maximum >= 3 then
        while #chunks > 0 and used > maximum - 3 do
            used = used - #chunks[#chunks]
            chunks[#chunks] = nil
        end
        chunks[#chunks + 1] = '...'
    end
    return table.concat(chunks), truncated, replacements
end

local function finite(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function callable(value)
    local kind = type(value)
    if kind == 'function' then return true end
    if kind ~= 'table' and kind ~= 'userdata' then return false end
    local meta = getmetatable(value)
    if type(meta) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMeta = pcall(debug.getmetatable, value)
        if readable then meta = rawMeta end
    end
    return type(meta) == 'table' and type(rawget(meta, '__call')) == 'function'
end

local function secretKey(key)
    local normalized = normalizeKey(key)
    return secretKeys[normalized] == true
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

local function identifierKey(key, path, navigationPaths)
    local normalized = normalizeKey(key)
    if normalized == 'id' and type(path) == 'string'
        and type(navigationPaths) == 'table' and navigationPaths[path] == true then
        return false
    end
    if (normalized == 'from' or normalized == 'to') and type(path) == 'string'
        and path:match('edges%[%]%.[a-z0-9]+$') then return true end
    if identifierKeys[normalized] == true
        or normalized:match('identifier$') ~= nil
        or normalized:match('identifiers$') ~= nil then return true end
    if normalized:match('id$') == nil and normalized:match('ref$') == nil then return false end
    for _, prefix in ipairs(identifierFragments) do
        if normalized:find(prefix, 1, true) ~= nil then return true end
    end
    return false
end

local function mask(value)
    if type(value) ~= 'string' then return '[MASKED]' end
    local normalized, _, replacements = boundedString(value, 512)
    if #normalized <= 8 then return '****', replacements end
    local chunks, index = {}, 1
    while index <= #normalized do
        local sequenceLength = utf8SequenceLength(normalized, index) or 1
        chunks[#chunks + 1] = normalized:sub(index, index + sequenceLength - 1)
        index = index + sequenceLength
    end
    local prefix, prefixBytes = {}, 0
    for _, chunk in ipairs(chunks) do
        if prefixBytes + #chunk > 4 then break end
        prefix[#prefix + 1] = chunk
        prefixBytes = prefixBytes + #chunk
    end
    local suffix, suffixBytes = {}, 0
    for chunkIndex = #chunks, 1, -1 do
        local chunk = chunks[chunkIndex]
        if suffixBytes + #chunk > 4 then break end
        table.insert(suffix, 1, chunk)
        suffixBytes = suffixBytes + #chunk
    end
    return table.concat(prefix) .. '...' .. table.concat(suffix), replacements
end

local function secretValue(value)
    if type(value) ~= 'string' then return false end
    local candidate = value:sub(1, 8192)
    local normalized = candidate:lower()
    local github = normalized:match('github_pat_([a-z0-9_%-]+)')
    local compactToken = normalized:match('gh[pousr]_([a-z0-9_%-]+)')
    local cfx = normalized:match('cfxk_([a-z0-9_%-]+)')
    local aws = candidate:match('AKIA([A-Z0-9]+)')
    return normalized:match('bearer%s+[%w%._~+/=%-]+') ~= nil
        or normalized:find('mysql://', 1, true) ~= nil
        or normalized:find('mariadb://', 1, true) ~= nil
        or normalized:find('://', 1, true) ~= nil
            and normalized:match('[a-z][a-z0-9+.-]*://[^/%s:]+:[^@/%s]+@') ~= nil
        or normalized:find('discord.com/api/webhooks/', 1, true) ~= nil
        or normalized:find('discordapp.com/api/webhooks/', 1, true) ~= nil
        or normalized:find('-----begin ', 1, true) ~= nil
            and normalized:find('private key-----', 1, true) ~= nil
        or github ~= nil and #github >= 20
        or compactToken ~= nil and #compactToken >= 20
        or cfx ~= nil and #cfx >= 20
        or aws ~= nil and #aws >= 16
        or normalized:match('[?&]access[_%-]?token=[^&#%s]+') ~= nil
        or normalized:match('[?&]api[_%-]?key=[^&#%s]+') ~= nil
        or normalized:match('[?&]secret=[^&#%s]+') ~= nil
        or normalized:match('[?&]signature=[^&#%s]+') ~= nil
        or normalized:match('[?&]token=[^&#%s]+') ~= nil
end

local function denseArray(value, maximumEntries)
    local count, maximum = 0, 0
    for key in next, value do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
            return false, 0
        end
        count = count + 1
        maximum = math.max(maximum, key)
        if count > maximumEntries then break end
    end
    return maximum == count, count
end

local function sanitizeValue(value, state, depth, parentKey, path)
    if secretKey(parentKey) then
        state.redactions = state.redactions + 1
        return '[REDACTED]'
    end
    if type(value) == 'string' and secretValue(value) then
        state.redactions = state.redactions + 1
        return '[REDACTED]'
    end
    if identifierKey(parentKey, path, state.navigationPaths)
        and not state.revealIdentifiers then
        state.masked = state.masked + 1
        local masked, replacements = mask(value)
        state.replacements = state.replacements + (replacements or 0)
        return masked
    end

    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' then return value end
    if kind == 'number' then
        if finite(value) then return value end
        state.replacements = state.replacements + 1
        return '[NON_FINITE]'
    end
    if kind == 'string' then
        local bounded, truncated, replacements = boundedString(value, state.maximumStringBytes)
        if truncated then state.truncated = true end
        state.replacements = state.replacements + replacements
        return bounded
    end
    if callable(value) then
        state.replacements = state.replacements + 1
        return '[CALLABLE]'
    end
    if kind ~= 'table' then
        state.replacements = state.replacements + 1
        return ('[%s]'):format(kind:upper())
    end
    if depth >= state.maximumDepth then
        state.truncated = true
        return '[DEPTH_LIMIT]'
    end
    if state.seen[value] then
        state.replacements = state.replacements + 1
        return '[CYCLE]'
    end

    state.seen[value] = true
    local output = {}
    local array, count = denseArray(value, state.maximumEntries)
    if array then
        for index = 1, count do
            if state.remaining <= 0 then
                output[#output + 1] = '[ENTRY_LIMIT]'
                state.truncated = true
                break
            end
            state.remaining = state.remaining - 1
            output[#output + 1] = sanitizeValue(value[index], state, depth + 1, nil,
                (path or '') .. '[]')
        end
    else
        local keys = {}
        for key in next, value do
            if type(key) == 'string' or type(key) == 'number' then
                keys[#keys + 1] = key
            else
                state.replacements = state.replacements + 1
            end
            if #keys > state.maximumEntries then break end
        end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        for _, key in ipairs(keys) do
            if state.remaining <= 0 then
                output.__truncated = true
                state.truncated = true
                break
            end
            state.remaining = state.remaining - 1
            local safeKey, keyTruncated, keyReplacements = boundedString(key, state.maximumKeyBytes)
            if keyTruncated then state.truncated = true end
            state.replacements = state.replacements + keyReplacements
            local normalizedKey = normalizeKey(key)
            local childPath = path and path ~= '' and (path .. '.' .. normalizedKey)
                or normalizedKey
            if secretKey(key) then
                state.redactions = state.redactions + 1
                output[safeKey] = '[REDACTED]'
            elseif type(value[key]) == 'string' and secretValue(value[key]) then
                state.redactions = state.redactions + 1
                output[safeKey] = '[REDACTED]'
            elseif identifierKey(key, childPath, state.navigationPaths)
                and not state.revealIdentifiers then
                state.masked = state.masked + 1
                local masked, replacements = mask(value[key])
                state.replacements = state.replacements + (replacements or 0)
                output[safeKey] = masked
            else
                output[safeKey] = sanitizeValue(value[key], state, depth + 1, key, childPath)
            end
        end
        if #keys > state.maximumEntries then
            output.__truncated = true
            state.truncated = true
        end
    end
    state.seen[value] = nil
    return output
end

local function sanitize(value, options, navigationPaths)
    options = type(options) == 'table' and options or {}
    local state = {
        masked = 0,
        maximumDepth = options.maximumDepth or SynexControlLimits.maximumDepth,
        maximumEntries = options.maximumEntries or SynexControlLimits.maximumEntriesPerResponse,
        maximumKeyBytes = options.maximumKeyBytes or SynexControlLimits.maximumKeyBytes,
        maximumStringBytes = options.maximumStringBytes or SynexControlLimits.maximumStringBytes,
        redactions = 0,
        remaining = options.maximumEntries or SynexControlLimits.maximumEntriesPerResponse,
        replacements = 0,
        revealIdentifiers = options.revealIdentifiers == true,
        navigationPaths = navigationPaths,
        seen = {},
        truncated = false,
    }
    local sanitized = sanitizeValue(value, state, 0, nil, '')
    return sanitized, {
        masked = state.masked,
        redactions = state.redactions,
        replacements = state.replacements,
        truncated = state.truncated,
    }
end

function sanitizer.sanitize(value, options)
    return sanitize(value, options, nil)
end

local function encode(value, options, navigationPaths)
    local sanitized, report = sanitize(value, options, navigationPaths)
    local encoded, payload = pcall(json.encode, sanitized)
    if not encoded or type(payload) ~= 'string' then
        return nil, report, 'ENCODE_FAILED'
    end
    local maximumBytes = type(options) == 'table' and options.maximumBytes
        or SynexControlLimits.maximumResponseBytes
    if #payload > maximumBytes then return nil, report, 'PAYLOAD_TOO_LARGE' end
    return sanitized, report, nil, #payload
end

function sanitizer.encode(value, options)
    return encode(value, options, nil)
end

function sanitizer.encodeProviderMetadataEnvelope(value, options)
    return encode(value, options, providerMetadataNavigationPaths)
end

function sanitizer.isSecretKey(key)
    return secretKey(key)
end

function sanitizer.isIdentifierKey(key)
    return identifierKey(key, nil, nil)
end
