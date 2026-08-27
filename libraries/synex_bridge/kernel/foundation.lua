SynexBridgeKernel = SynexBridgeKernel or {}

local Foundation = {}

local MAX_SAFE_INTEGER = 9007199254740991
local PROVIDERS = { qb = true, qbx = true, esx = true }
local STATUSES = {
    CERTIFIED = true,
    COMPATIBLE = true,
    PARTIAL = true,
    UNSUPPORTED = true,
    UNKNOWN = true,
}
local MODES = { strict = true, compat = true, silent = true }
local FAILURE_POLICIES = { warn = true, disable = true, fail_start = true }
local OUTCOMES = {
    success = true,
    denied = true,
    unsupported = true,
    deprecated = true,
    error = true,
    timeout = true,
    rate_limited = true,
}
local ERROR_CATALOG = {
    COMPAT_PROVIDER_DISABLED = { 'The selected compatibility provider is disabled.', false },
    COMPAT_API_UNSUPPORTED = { 'The requested compatibility API is unsupported.', false },
    COMPAT_API_DEPRECATED = { 'The requested compatibility API is deprecated.', false },
    COMPAT_MAPPING_MISSING = { 'A required compatibility mapping is missing.', false },
    COMPAT_MAPPING_AMBIGUOUS = { 'The compatibility mapping is ambiguous.', false },
    COMPAT_ADAPTER_MISSING = { 'A required compatibility adapter is unavailable.', true },
    COMPAT_CATALOG_UNAVAILABLE = { 'A required compatibility catalog is unavailable.', true },
    COMPAT_CONSUMER_DENIED = { 'The compatibility consumer is not configured or allowed.', false },
    COMPAT_STALE_SESSION = { 'The compatibility request belongs to a stale session.', false },
    COMPAT_CALLBACK_TIMEOUT = { 'The compatibility callback timed out.', true },
    COMPAT_CALLBACK_LIMIT = { 'The compatibility callback limit was reached.', true },
    COMPAT_PROJECTION_UNAVAILABLE = { 'The compatibility projection is unavailable.', true },
    COMPAT_FRAMEWORK_CONFLICT = { 'The compatibility provider conflicts with another framework surface.', false },
    COMPAT_IDENTITY_CONFLICT = { 'The compatibility identity mapping conflicts with an existing mapping.', false },
    COMPAT_PROFILE_INCOMPLETE = { 'The compatibility profile is incomplete.', false },
    COMPAT_INVALID_ARGUMENT = { 'The compatibility request contains an invalid argument.', false },
    COMPAT_DTO_INVALID = { 'The compatibility value is not a canonical bounded DTO.', false },
    COMPAT_DTO_LIMIT = { 'The compatibility value exceeds a DTO limit.', false },
    COMPAT_DTO_CYCLE = { 'The compatibility value contains a cycle.', false },
    COMPAT_REGISTRY_LIMIT = { 'The compatibility registry capacity was reached.', true },
    COMPAT_OWNER_CONFLICT = { 'The compatibility definition is owned by another resource.', false },
    COMPAT_VERSION_CONFLICT = { 'The compatibility definition version or owner epoch is stale.', false },
    COMPAT_STATUS_INVALID = { 'The compatibility status is invalid.', false },
    COMPAT_MODE_INVALID = { 'The compatibility mode is invalid.', false },
    COMPAT_FAILURE_POLICY_INVALID = { 'The compatibility failure policy is invalid.', false },
    COMPAT_METADATA_FORBIDDEN = { 'The metadata field is reserved by Synex.', false },
    COMPAT_METADATA_UNSUPPORTED = { 'The metadata field has no compatibility mapping.', false },
    COMPAT_RESOLUTION_FAILED = { 'The compatibility request could not be resolved safely.', false },
    COMPAT_INTERNAL = { 'The compatibility kernel rejected an internal failure.', true },
}
local DTO_DEFAULTS = {
    maximumDepth = 8,
    maximumEntries = 256,
    maximumBytes = 65536,
    maximumStringBytes = 4096,
    maximumKeyBytes = 96,
    maximumArrayItems = 128,
    maximumObjectProperties = 128,
    root = 'any',
}
local DTO_OPTION_LIMITS = {
    maximumDepth = { 1, 16 },
    maximumEntries = { 1, 2048 },
    maximumBytes = { 64, 262144 },
    maximumStringBytes = { 1, 65536 },
    maximumKeyBytes = { 1, 256 },
    maximumArrayItems = { 1, 1024 },
    maximumObjectProperties = { 1, 1024 },
}

local function finiteInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.type(value) == 'integer' and value >= minimum and value <= maximum
end

local function boundedString(value, minimum, maximum, pattern)
    if type(value) ~= 'string' or #value < minimum or #value > maximum
        or value:find('[%z\1-\31\127]') then
        return false
    end
    return pattern == nil or value:match(pattern) ~= nil
end

local function readMetatable(value)
    local metadata = getmetatable(value)
    if type(metadata) == 'table' then return metadata end
    if type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable and type(rawMetadata) == 'table' then return rawMetadata end
    end
    return metadata
end

local function containerKind(value)
    local metadata = readMetatable(value)
    if metadata == nil then return nil, nil end
    if type(metadata) ~= 'table' then return nil, 'invalid' end
    local kind = rawget(metadata, '__jsontype')
    if kind == 'object' or kind == 'array' then
        for key, item in next, metadata do
            if key ~= '__jsontype' and key ~= '__metatable' then return nil, 'invalid' end
            if key == '__metatable' and type(item) ~= 'string' then return nil, 'invalid' end
        end
        return kind, nil
    end
    return nil, 'invalid'
end

local function copyValue(value, limits, budget, depth, seen)
    local valueType = type(value)
    budget.entries = budget.entries + 1
    budget.bytes = budget.bytes + 8
    if budget.entries > limits.maximumEntries or budget.bytes > limits.maximumBytes then
        return nil, 'COMPAT_DTO_LIMIT'
    end
    if valueType == 'nil' or valueType == 'boolean' then return value, nil, valueType end
    if valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge
            or math.abs(value) > MAX_SAFE_INTEGER then
            return nil, 'COMPAT_DTO_INVALID'
        end
        return value, nil, 'number'
    end
    if valueType == 'string' then
        if #value > limits.maximumStringBytes or value:find('%z') then
            return nil, #value > limits.maximumStringBytes and 'COMPAT_DTO_LIMIT' or 'COMPAT_DTO_INVALID'
        end
        budget.bytes = budget.bytes + #value
        if budget.bytes > limits.maximumBytes then return nil, 'COMPAT_DTO_LIMIT' end
        return value, nil, 'string'
    end
    if valueType ~= 'table' then return nil, 'COMPAT_DTO_INVALID' end
    if depth >= limits.maximumDepth then return nil, 'COMPAT_DTO_LIMIT' end
    if seen[value] then return nil, 'COMPAT_DTO_CYCLE' end

    local declaredKind, metadataError = containerKind(value)
    if metadataError then return nil, 'COMPAT_DTO_INVALID' end
    local numericCount, maximumIndex, stringCount = 0, 0, 0
    for key in next, value do
        if type(key) == 'number' then
            if not finiteInteger(key, 1, limits.maximumArrayItems) then
                return nil, 'COMPAT_DTO_INVALID'
            end
            numericCount = numericCount + 1
            maximumIndex = math.max(maximumIndex, key)
        elseif type(key) == 'string' then
            if #key > limits.maximumKeyBytes or key:find('[%z\1-\31\127]') then
                return nil, #key > limits.maximumKeyBytes and 'COMPAT_DTO_LIMIT' or 'COMPAT_DTO_INVALID'
            end
            stringCount = stringCount + 1
            budget.bytes = budget.bytes + #key
        else
            return nil, 'COMPAT_DTO_INVALID'
        end
    end
    if budget.bytes > limits.maximumBytes then return nil, 'COMPAT_DTO_LIMIT' end

    local kind = declaredKind
    if kind == nil then
        if numericCount > 0 and stringCount > 0 then return nil, 'COMPAT_DTO_INVALID' end
        kind = numericCount > 0 and 'array' or 'object'
    end
    if kind == 'array' then
        if stringCount > 0 or numericCount ~= maximumIndex
            or numericCount > limits.maximumArrayItems then
            return nil, 'COMPAT_DTO_INVALID'
        end
    elseif numericCount > 0 or stringCount > limits.maximumObjectProperties then
        return nil, numericCount > 0 and 'COMPAT_DTO_INVALID' or 'COMPAT_DTO_LIMIT'
    end

    seen[value] = true
    local result = {}
    if kind == 'array' then
        for index = 1, maximumIndex do
            local copied, copyError = copyValue(value[index], limits, budget, depth + 1, seen)
            if copyError then seen[value] = nil; return nil, copyError end
            result[index] = copied
        end
        setmetatable(result, { __jsontype = 'array' })
    else
        for key, item in next, value do
            local copied, copyError = copyValue(item, limits, budget, depth + 1, seen)
            if copyError then seen[value] = nil; return nil, copyError end
            result[key] = copied
        end
    end
    seen[value] = nil
    return result, nil, kind
end

function Foundation.error(code)
    local definition = ERROR_CATALOG[code] or ERROR_CATALOG.COMPAT_INTERNAL
    return { code = ERROR_CATALOG[code] and code or 'COMPAT_INTERNAL', message = definition[1], retryable = definition[2] }
end

function Foundation.errorCatalog()
    local result = {}
    for code, definition in pairs(ERROR_CATALOG) do
        result[code] = { message = definition[1], retryable = definition[2] }
    end
    return result
end

function Foundation.copyDto(value, options)
    if options ~= nil and (type(options) ~= 'table' or getmetatable(options) ~= nil) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local limits = {}
    for key, default in pairs(DTO_DEFAULTS) do limits[key] = default end
    for key, candidate in next, options or {} do
        if key == 'root' then
            if candidate ~= 'any' and candidate ~= 'object' and candidate ~= 'array' then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            limits.root = candidate
        else
            local range = DTO_OPTION_LIMITS[key]
            if not range or not finiteInteger(candidate, range[1], range[2]) then
                return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
            end
            limits[key] = candidate
        end
    end
    if limits.maximumStringBytes > limits.maximumBytes
        or limits.maximumKeyBytes > limits.maximumBytes then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local copied, copyError, kind = copyValue(value, limits, { entries = 0, bytes = 0 }, 0, {})
    if copyError then return nil, Foundation.error(copyError) end
    -- A plain empty Lua table has no intrinsic object/array identity.  When a
    -- caller explicitly requires an array root, preserve that closed contract
    -- instead of treating a valid zero-element argument list as an object.
    if limits.root == 'array' and kind == 'object' and type(value) == 'table'
        and getmetatable(value) == nil and next(value) == nil then
        setmetatable(copied, { __jsontype = 'array' })
        kind = 'array'
    end
    if limits.root ~= 'any' and kind ~= limits.root then
        return nil, Foundation.error('COMPAT_DTO_INVALID')
    end
    return copied, nil
end

function Foundation.copyClosedObject(value, allowed, required, options)
    if type(allowed) ~= 'table' or getmetatable(allowed) ~= nil
        or (required ~= nil and (type(required) ~= 'table' or getmetatable(required) ~= nil))
        or (options ~= nil and (type(options) ~= 'table' or getmetatable(options) ~= nil)) then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    local copyOptions = {}
    for key, option in next, options or {} do copyOptions[key] = option end
    if copyOptions.root ~= nil and copyOptions.root ~= 'object' then
        return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
    end
    copyOptions.root = 'object'
    local copied, copyError = Foundation.copyDto(value, copyOptions)
    if not copied then return nil, copyError end
    for key in pairs(copied) do
        if allowed[key] ~= true then return nil, Foundation.error('COMPAT_DTO_INVALID') end
    end
    for _, key in ipairs(required or {}) do
        if copied[key] == nil then return nil, Foundation.error('COMPAT_DTO_INVALID') end
    end
    return copied, nil
end

function Foundation.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metadata = readMetatable(value)
    return type(metadata) == 'table' and type(rawget(metadata, '__call')) == 'function'
end

function Foundation.isProvider(value) return PROVIDERS[value] == true end
function Foundation.isStatus(value) return STATUSES[value] == true end
function Foundation.isMode(value) return MODES[value] == true end
function Foundation.isFailurePolicy(value) return FAILURE_POLICIES[value] == true end
function Foundation.isOutcome(value) return OUTCOMES[value] == true end
function Foundation.isSafeInteger(value, minimum, maximum)
    return finiteInteger(value, minimum or -MAX_SAFE_INTEGER, maximum or MAX_SAFE_INTEGER)
end
function Foundation.isBoundedString(value, minimum, maximum, pattern)
    return boundedString(value, minimum or 0, maximum or 4096, pattern)
end
function Foundation.isResourceName(value)
    return boundedString(value, 2, 64, '^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
end
function Foundation.isIdentifier(value)
    return boundedString(value, 1, 128, '^[a-z][a-z0-9_.:%-]*$')
end
function Foundation.isDefinitionName(value)
    return boundedString(value, 1, 128, '^[A-Za-z][A-Za-z0-9_.:%-]*$')
end
function Foundation.semver(value)
    if type(value) ~= 'string' or #value < 5 or #value > 64 then return nil end
    local major, minor, patch, suffix = value:match('^(%d+)%.(%d+)%.(%d+)(.*)$')
    if not major
        or (#major > 1 and major:sub(1, 1) == '0')
        or (#minor > 1 and minor:sub(1, 1) == '0')
        or (#patch > 1 and patch:sub(1, 1) == '0') then return nil end
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    if not finiteInteger(major, 0, 65535) or not finiteInteger(minor, 0, 65535)
        or not finiteInteger(patch, 0, 65535) then return nil end
    local prerelease
    if suffix ~= '' then
        if suffix:sub(1, 1) ~= '-' then return nil end
        prerelease = suffix:sub(2)
        if prerelease == '' or prerelease:sub(1, 1) == '.'
            or prerelease:sub(-1) == '.' or prerelease:find('..', 1, true) then
            return nil
        end
        for identifier in prerelease:gmatch('[^%.]+') do
            if not identifier:match('^[0-9A-Za-z%-]+$')
                or (identifier:match('^%d+$') and #identifier > 1
                    and identifier:sub(1, 1) == '0') then return nil end
        end
    end
    return {
        major = major, minor = minor, patch = patch,
        prerelease = prerelease, raw = value,
    }
end

function Foundation.isSemver(value) return Foundation.semver(value) ~= nil end

local function compareParsedSemver(leftVersion, rightVersion)
    for _, key in ipairs({ 'major', 'minor', 'patch' }) do
        if leftVersion[key] < rightVersion[key] then return -1 end
        if leftVersion[key] > rightVersion[key] then return 1 end
    end
    if leftVersion.prerelease == rightVersion.prerelease then return 0 end
    if leftVersion.prerelease == nil then return 1 end
    if rightVersion.prerelease == nil then return -1 end
    local leftIdentifiers, rightIdentifiers = {}, {}
    for identifier in leftVersion.prerelease:gmatch('[^%.]+') do
        leftIdentifiers[#leftIdentifiers + 1] = identifier
    end
    for identifier in rightVersion.prerelease:gmatch('[^%.]+') do
        rightIdentifiers[#rightIdentifiers + 1] = identifier
    end
    for index = 1, math.max(#leftIdentifiers, #rightIdentifiers) do
        local leftIdentifier, rightIdentifier =
            leftIdentifiers[index], rightIdentifiers[index]
        if leftIdentifier == nil then return -1 end
        if rightIdentifier == nil then return 1 end
        if leftIdentifier ~= rightIdentifier then
            local leftNumeric = leftIdentifier:match('^%d+$') ~= nil
            local rightNumeric = rightIdentifier:match('^%d+$') ~= nil
            if leftNumeric and rightNumeric then
                if #leftIdentifier ~= #rightIdentifier then
                    return #leftIdentifier < #rightIdentifier and -1 or 1
                end
                return leftIdentifier < rightIdentifier and -1 or 1
            end
            if leftNumeric ~= rightNumeric then return leftNumeric and -1 or 1 end
            return leftIdentifier < rightIdentifier and -1 or 1
        end
    end
    return 0
end

function Foundation.compareSemver(left, right)
    local leftVersion, rightVersion = Foundation.semver(left), Foundation.semver(right)
    if not leftVersion or not rightVersion then return nil end
    return compareParsedSemver(leftVersion, rightVersion)
end

local function parseSemverRange(range)
    if range == nil or range == '*' then return { { any = true } } end
    if type(range) ~= 'string' or #range < 1 or #range > 64
        or not range:match('^[0-9A-Za-z%*<>=~%^| %.%-]+$') then return nil end
    local alternatives, cursor = {}, 1
    while cursor <= #range + 1 do
        local separator = range:find('||', cursor, true)
        local group = range:sub(cursor, separator and separator - 1 or #range)
        group = group:match('^%s*(.-)%s*$')
        if group == '' then return nil end
        local comparators = {}
        if group == '*' then
            comparators[1] = { any = true }
        else
            for token in group:gmatch('%S+') do
                local operator, target = token:match('^([%^~<>=]*)(.+)$')
                if not operator or (operator ~= '' and operator ~= '='
                    and operator ~= '^' and operator ~= '~' and operator ~= '>='
                    and operator ~= '<=' and operator ~= '>' and operator ~= '<') then
                    return nil
                end
                local parsed = Foundation.semver(target)
                if not parsed then return nil end
                comparators[#comparators + 1] = {
                    operator = operator == '' and '=' or operator,
                    target = parsed,
                }
            end
            if #comparators < 1 then return nil end
        end
        alternatives[#alternatives + 1] = comparators
        if not separator then break end
        cursor = separator + 2
    end
    return alternatives
end

function Foundation.isSemverRange(range) return parseSemverRange(range) ~= nil end

function Foundation.semverSatisfies(version, range)
    local parsed, alternatives = Foundation.semver(version), parseSemverRange(range)
    if not parsed or not alternatives then return false end
    for _, comparators in ipairs(alternatives) do
        local accepted = true
        for _, comparator in ipairs(comparators) do
            if not comparator.any then
                local target = comparator.target
                local order = compareParsedSemver(parsed, target)
                local operator = comparator.operator
                local matches = false
                if parsed.prerelease ~= nil and operator ~= '=' then
                    matches = false
                elseif operator == '^' then
                    if target.major > 0 then
                        matches = parsed.major == target.major and order >= 0
                    elseif target.minor > 0 then
                        matches = parsed.major == 0 and parsed.minor == target.minor
                            and order >= 0
                    else
                        matches = parsed.major == 0 and parsed.minor == 0
                            and parsed.patch == target.patch
                    end
                elseif operator == '~' then
                    matches = parsed.major == target.major
                        and parsed.minor == target.minor and order >= 0
                elseif operator == '>=' then matches = order >= 0
                elseif operator == '<=' then matches = order <= 0
                elseif operator == '>' then matches = order > 0
                elseif operator == '<' then matches = order < 0
                elseif operator == '=' then matches = order == 0 end
                if not matches then accepted = false; break end
            end
        end
        if accepted then return true end
    end
    return false
end

local function rotateRight32(value, amount)
    return ((value >> amount) | (value << (32 - amount))) & 0xffffffff
end

local SHA256_CONSTANTS = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function Foundation.sha256(input)
    if type(input) ~= 'string' then return nil end
    local bytes = { input:byte(1, #input) }
    local bitLength = #bytes * 8
    bytes[#bytes + 1] = 0x80
    while (#bytes % 64) ~= 56 do bytes[#bytes + 1] = 0 end
    local high = math.floor(bitLength / 0x100000000)
    local low = bitLength & 0xffffffff
    for shift = 24, 0, -8 do bytes[#bytes + 1] = (high >> shift) & 0xff end
    for shift = 24, 0, -8 do bytes[#bytes + 1] = (low >> shift) & 0xff end

    local hash = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    for offset = 1, #bytes, 64 do
        local words = {}
        for index = 0, 15 do
            local position = offset + index * 4
            words[index] = ((bytes[position] << 24)
                | (bytes[position + 1] << 16)
                | (bytes[position + 2] << 8)
                | bytes[position + 3]) & 0xffffffff
        end
        for index = 16, 63 do
            local a, b = words[index - 15], words[index - 2]
            local s0 = rotateRight32(a, 7) ~ rotateRight32(a, 18) ~ (a >> 3)
            local s1 = rotateRight32(b, 17) ~ rotateRight32(b, 19) ~ (b >> 10)
            words[index] = (words[index - 16] + s0 + words[index - 7] + s1)
                & 0xffffffff
        end
        local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
        local e, f, g, h = hash[5], hash[6], hash[7], hash[8]
        for index = 0, 63 do
            local s1 = rotateRight32(e, 6) ~ rotateRight32(e, 11)
                ~ rotateRight32(e, 25)
            local choice = (e & f) ~ ((~e) & g)
            local temporary1 = (h + s1 + choice + SHA256_CONSTANTS[index + 1]
                + words[index]) & 0xffffffff
            local s0 = rotateRight32(a, 2) ~ rotateRight32(a, 13)
                ~ rotateRight32(a, 22)
            local majority = (a & b) ~ (a & c) ~ (b & c)
            local temporary2 = (s0 + majority) & 0xffffffff
            h, g, f, e, d, c, b, a = g, f, e,
                (d + temporary1) & 0xffffffff, c, b, a,
                (temporary1 + temporary2) & 0xffffffff
        end
        hash[1], hash[2], hash[3], hash[4] =
            (hash[1] + a) & 0xffffffff, (hash[2] + b) & 0xffffffff,
            (hash[3] + c) & 0xffffffff, (hash[4] + d) & 0xffffffff
        hash[5], hash[6], hash[7], hash[8] =
            (hash[5] + e) & 0xffffffff, (hash[6] + f) & 0xffffffff,
            (hash[7] + g) & 0xffffffff, (hash[8] + h) & 0xffffffff
    end
    local output = {}
    for index = 1, 8 do output[index] = ('%08x'):format(hash[index]) end
    return table.concat(output)
end

function Foundation.saturatingAdd(value, increment)
    if not finiteInteger(value, 0, MAX_SAFE_INTEGER)
        or not finiteInteger(increment, 0, MAX_SAFE_INTEGER) then return nil end
    if increment > MAX_SAFE_INTEGER - value then return MAX_SAFE_INTEGER end
    return value + increment
end

Foundation.MAX_SAFE_INTEGER = MAX_SAFE_INTEGER
SynexBridgeKernel.Foundation = Foundation
