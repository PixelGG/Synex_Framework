local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.foundation = function(deps)
    deps = deps or {}
    local platform = assert(deps.platform, 'foundation requires platform')

    local jsonContainerKinds = { plain = true, object = true, array = true }
    local function jsonContainerKind(value)
        if type(value) ~= 'table' then return nil end
        if type(platform.jsonContainerKind) ~= 'function' then
            return getmetatable(value) == nil and 'plain' or nil
        end
        local inspected, kind = pcall(platform.jsonContainerKind, value)
        if not inspected or not jsonContainerKinds[kind] then return nil end
        return kind
    end

    local function preserveJsonContainerMetadata(source, target)
        local kind = jsonContainerKind(source)
        if kind ~= 'object' and kind ~= 'array' then return target end
        if type(platform.copyJsonContainerMetadata) ~= 'function' then
            error('platform cannot preserve Cfx JSON container metadata', 2)
        end
        local copied, result = pcall(platform.copyJsonContainerMetadata, source, target)
        if not copied or result ~= target then
            error('platform failed to preserve Cfx JSON container metadata', 2)
        end
        return target
    end

    local function deepCopy(value, seen, depth)
        if type(value) ~= 'table' then return value end
        depth = (depth or 0) + 1
        if depth > 32 then error('copy depth exceeded') end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local copy = {}
        seen[value] = copy
        for key, item in next, value do
            copy[deepCopy(key, seen, depth)] = deepCopy(item, seen, depth)
        end
        return preserveJsonContainerMetadata(value, copy)
    end

    local function readonly(value, cache)
        if type(value) ~= 'table' then return value end
        cache = cache or setmetatable({}, { __mode = 'k' })
        if cache[value] then return cache[value] end
        local proxy = {}
        cache[value] = proxy
        return setmetatable(proxy, {
            __index = function(_, key) return readonly(value[key], cache) end,
            __newindex = function() error('attempt to mutate a Synex snapshot', 2) end,
            __pairs = function()
                local function iterator(_, key)
                    local nextKey, nextValue = next(value, key)
                    return nextKey, readonly(nextValue, cache)
                end
                return iterator, proxy, nil
            end,
            __len = function() return #value end,
            __metatable = false
        })
    end

    local function errorResult(code, message, options)
        options = options or {}
        return {
            code = code,
            message = message,
            traceId = options.traceId,
            retryable = options.retryable == true,
            details = options.details
        }
    end

    local function failureCode(value, fallback)
        local code = type(value) == 'table' and rawget(value, 'code') or nil
        if type(code) == 'string' and #code >= 2 and #code <= 64
            and code:match('^[A-Z][A-Z0-9_]+$') then return code end
        if type(fallback) == 'string' and #fallback >= 2 and #fallback <= 64
            and fallback:match('^[A-Z][A-Z0-9_]+$') then return fallback end
        return 'RUNTIME_ERROR'
    end

    local function safeCall(handler, ...)
        local arguments = table.pack(...)
        -- Successful handlers may expose metadata after their canonical error
        -- slot. Preserve the complete tuple so later public boundaries can make
        -- any interior nil transport-safe without losing trailing values.
        local results = table.pack(xpcall(function()
            return handler(table.unpack(arguments, 1, arguments.n))
        end, debug.traceback))
        if results[1] then return table.unpack(results, 1, results.n) end
        return false, results[2]
    end

    -- Cfx serializes cross-resource functions as callable table/userdata proxies.
    local function isCallable(value)
        local valueType = type(value)
        if valueType == 'function' then return true end
        if valueType ~= 'table' and valueType ~= 'userdata' then return false end
        local metatable = getmetatable(value)
        if type(metatable) ~= 'table'
            and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
            local readable, rawMetatable = safeCall(debug.getmetatable, value)
            if readable then metatable = rawMetatable end
        end
        return type(metatable) == 'table'
            and type(rawget(metatable, '__call')) == 'function'
    end

    -- Cfx captures function-reference returns in an array configured with
    -- `without_hole`. Any nil before the final return slot turns the tuple into
    -- a map and the receiver's table.unpack then loses values. Keep internal
    -- APIs on the canonical nil convention, but use false for absent public
    -- cross-resource slots so errors and trailing metadata survive intact.
    local function cfxResult(handler, ...)
        if not isCallable(handler) then
            error('Cfx result transport requires a callable handler', 2)
        end
        local values = table.pack(handler(...))
        local finalValue = values.n
        while finalValue > 0 and values[finalValue] == nil do
            finalValue = finalValue - 1
        end
        for index = 1, finalValue do
            if values[index] == nil then values[index] = false end
        end
        return table.unpack(values, 1, values.n)
    end

    local gameTimerModulo = 0x100000000
    local gameTimerHalfRange = 0x80000000
    local previousGameTimer = nil
    local monotonicGameTimer = 0
    local function monotonicMs()
        local raw = platform.nowGame()
        if type(raw) ~= 'number' or math.type(raw) ~= 'integer' then
            error('the Cfx game timer returned a non-integer value', 2)
        end
        local current = raw % gameTimerModulo
        if previousGameTimer == nil then
            previousGameTimer = current
            monotonicGameTimer = current
            return monotonicGameTimer
        end
        local elapsed = (current - previousGameTimer) % gameTimerModulo
        if elapsed <= gameTimerHalfRange then
            previousGameTimer = current
            monotonicGameTimer = monotonicGameTimer + elapsed
        end
        return monotonicGameTimer
    end

    local sequence = 0
    local idNode = platform.random and platform.random(0, 0xffffffff) or 0
    local function configureIds(instanceId)
        local hash = 0x811c9dc5
        for index = 1, #tostring(instanceId or '') do
            hash = ((hash ~ tostring(instanceId):byte(index)) * 0x01000193) & 0xffffffff
        end
        idNode = (hash ~ idNode) & 0xffffffff
    end
    local function nextId(prefix)
        sequence = sequence + 1
        local namespace = tostring(prefix or 'id'):lower():gsub('[^a-z0-9]', ''):sub(1, 5)
        if namespace == '' then namespace = 'id' end
        local now = os.time() * 1000 + (monotonicMs() % 1000)
        return ('%s_%011x_%08x_%08x'):format(namespace, now & 0x7ffffffffff, idNode, sequence & 0xffffffff)
    end

    local function utcIso()
        return os.date('!%Y-%m-%dT%H:%M:%SZ')
    end

    local function wildcardMatch(pattern, value)
        if pattern == value or pattern == '*' then return true end
        if pattern:sub(-2) == '.*' then
            local prefix = pattern:sub(1, -3)
            return value:sub(1, #prefix) == prefix and value:sub(#prefix + 1, #prefix + 1) == '.'
        end
        return false
    end

    local function semver(value)
        if type(value) ~= 'string' or #value < 1 or #value > 128 then return nil end
        local major, minor, patch, suffix = value:match('^(%d+)%.(%d+)%.(%d+)(.*)$')
        if not major
            or (#major > 1 and major:sub(1, 1) == '0')
            or (#minor > 1 and minor:sub(1, 1) == '0')
            or (#patch > 1 and patch:sub(1, 1) == '0') then return nil end
        local prerelease = nil
        if suffix ~= '' then
            if suffix:sub(1, 1) ~= '-' then return nil end
            prerelease = suffix:sub(2)
            if prerelease == '' or prerelease:sub(1, 1) == '.' or prerelease:sub(-1) == '.'
                or prerelease:find('..', 1, true) then return nil end
            for identifier in prerelease:gmatch('[^%.]+') do
                if not identifier:match('^[0-9A-Za-z%-]+$')
                    or (identifier:match('^%d+$') and #identifier > 1 and identifier:sub(1, 1) == '0') then
                    return nil
                end
            end
        end
        return {
            major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch),
            prerelease = prerelease, raw = value
        }
    end

    local function semverCompare(left, right)
        for _, key in ipairs({ 'major', 'minor', 'patch' }) do
            if left[key] ~= right[key] then return left[key] < right[key] and -1 or 1 end
        end
        if left.prerelease == right.prerelease then return 0 end
        if left.prerelease == nil then return 1 end
        if right.prerelease == nil then return -1 end
        local leftIdentifiers, rightIdentifiers = {}, {}
        for identifier in left.prerelease:gmatch('[^%.]+') do leftIdentifiers[#leftIdentifiers + 1] = identifier end
        for identifier in right.prerelease:gmatch('[^%.]+') do rightIdentifiers[#rightIdentifiers + 1] = identifier end
        for index = 1, math.max(#leftIdentifiers, #rightIdentifiers) do
            local leftIdentifier, rightIdentifier = leftIdentifiers[index], rightIdentifiers[index]
            if leftIdentifier == nil then return -1 end
            if rightIdentifier == nil then return 1 end
            if leftIdentifier ~= rightIdentifier then
                local leftNumeric = leftIdentifier:match('^%d+$') ~= nil
                local rightNumeric = rightIdentifier:match('^%d+$') ~= nil
                if leftNumeric and rightNumeric then
                    if #leftIdentifier ~= #rightIdentifier then return #leftIdentifier < #rightIdentifier and -1 or 1 end
                    return leftIdentifier < rightIdentifier and -1 or 1
                end
                if leftNumeric ~= rightNumeric then return leftNumeric and -1 or 1 end
                return leftIdentifier < rightIdentifier and -1 or 1
            end
        end
        return 0
    end

    local function semverSatisfies(version, range)
        local parsed = semver(version)
        if not parsed then return false end
        if range == nil or range == '' or range == '*' then return true end
        if type(range) ~= 'string' or #range > 256 then return false end
        if parsed.prerelease ~= nil then return false end
        local matched = false
        for token in range:gmatch('%S+') do
            matched = true
            local operator, target = token:match('^([%^~<>=]*)(%d+%.%d+%.%d+)$')
            local wanted = target and semver(target) or nil
            if not wanted then return false end
            local order = semverCompare(parsed, wanted)
            local accepted = false
            if operator == '^' then
                if wanted.major > 0 then accepted = parsed.major == wanted.major and order >= 0
                elseif wanted.minor > 0 then accepted = parsed.major == 0 and parsed.minor == wanted.minor and order >= 0
                else accepted = parsed.major == 0 and parsed.minor == 0 and parsed.patch == wanted.patch end
            elseif operator == '~' then accepted = parsed.major == wanted.major and parsed.minor == wanted.minor and order >= 0
            elseif operator == '>=' then accepted = order >= 0
            elseif operator == '<=' then accepted = order <= 0
            elseif operator == '>' then accepted = order > 0
            elseif operator == '<' then accepted = order < 0
            elseif operator == '=' or operator == '' then accepted = order == 0
            end
            if not accepted then return false end
        end
        return matched
    end

    local redactedKeys = {
        password = true, token = true, secret = true, authorization = true,
        license = true, license2 = true, discord = true, fivem = true,
        identifier = true, identifiers = true, webhook = true
    }

    local function redact(value, depth, seen)
        local valueType = type(value)
        if valueType == 'string' then
            if #value > 4096 then return value:sub(1, 4096) .. '[TRUNCATED]' end
            return value
        end
        if valueType == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then return '[NON_FINITE]' end
            return value
        end
        if valueType == 'nil' or valueType == 'boolean' then return value end
        if valueType ~= 'table' then return '[UNSUPPORTED_TYPE]' end
        local containerKind = jsonContainerKind(value)
        if not containerKind then return '[UNSAFE_TABLE]' end
        depth = (depth or 0) + 1
        if depth > 8 then return '[DEPTH_LIMIT]' end
        seen = seen or {}
        if seen[value] then return '[CYCLE]' end
        seen[value] = true
        local output = {}
        local keyType, count, maximumIndex, truncated = nil, 0, 0, false
        for key in next, value do
            count = count + 1
            if count > 128 then
                truncated = true
                break
            end
            local currentType = type(key)
            if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                maximumIndex = math.max(maximumIndex, key)
            elseif currentType ~= 'string' or #key < 1 or #key > 128 then
                seen[value] = nil
                return '[UNSAFE_TABLE]'
            end
            if keyType and keyType ~= currentType then
                seen[value] = nil
                return '[UNSAFE_TABLE]'
            end
            keyType = currentType
        end
        if not truncated and keyType == 'number' and maximumIndex ~= count
            or containerKind == 'object' and keyType == 'number'
            or containerKind == 'array' and keyType == 'string' then
            seen[value] = nil
            return '[UNSAFE_TABLE]'
        end
        if keyType == 'number' then
            if truncated then
                output[1] = '[TRUNCATED_ITEMS]'
            else
                for index = 1, count do output[index] = '[REDACTED]' end
            end
        else
            local copied = 0
            for key, item in next, value do
                copied = copied + 1
                if copied > 128 then
                    output['[TRUNCATED_FIELDS]'] = true
                    break
                end
                local normalized = key:lower()
                if redactedKeys[normalized] or normalized:find('password', 1, true)
                    or normalized:find('secret', 1, true) then
                    output[key] = '[REDACTED]'
                else
                    output[key] = redact(item, depth, seen)
                end
            end
            if truncated then output['[TRUNCATED_FIELDS]'] = true end
        end
        seen[value] = nil
        return preserveJsonContainerMetadata(value, output)
    end

    local mainExecutionKey = {}
    local executionContexts = setmetatable({}, { __mode = 'k' })
    local function executionKey()
        local running, isMain = coroutine.running()
        if running == nil or isMain == true then return mainExecutionKey end
        return running
    end
    local function currentContext()
        return executionContexts[executionKey()]
    end
    local function withContext(context, handler, ...)
        if not isCallable(handler) then error('execution context handler must be callable', 2) end
        local key = executionKey()
        local previous = executionContexts[key]
        executionContexts[key] = type(context) == 'table' and deepCopy(context) or {}
        local arguments = table.pack(...)
        local results = table.pack(xpcall(function()
            return handler(table.unpack(arguments, 1, arguments.n))
        end, debug.traceback))
        executionContexts[key] = previous
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end

    local logger = {}
    local levelOrder = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, fatal = 6 }
    local configuredLevel = deps.logLevel or 'info'
    function logger:configure(level)
        if type(level) ~= 'string' or levelOrder[level] == nil then
            return nil, errorResult('INVALID_LOG_LEVEL', 'Log level must be one of trace, debug, info, warn, error, or fatal.')
        end
        configuredLevel = level
        return true, nil
    end
    function logger:write(level, message, fields)
        if (levelOrder[level] or 3) < (levelOrder[configuredLevel] or 3) then return end
        local context = currentContext()
        local safeMessage = type(message) == 'string' and message or 'Log message unavailable.'
        if #safeMessage > 1024 then safeMessage = safeMessage:sub(1, 1024) .. '[TRUNCATED]' end
        local record = {
            timestamp = utcIso(),
            level = level,
            component = 'synex_core',
            message = safeMessage,
            traceId = context and context.traceId or nil,
            caller = context and context.caller or nil,
            operation = context and (context.contract or context.service or context.hook) or nil,
            fields = redact(fields or {})
        }
        local ok, encoded = pcall(platform.jsonEncode, record)
        platform.print(ok and encoded or ('[synex_core] %s: %s'):format(level, safeMessage))
    end
    for _, level in ipairs({ 'trace', 'debug', 'info', 'warn', 'error', 'fatal' }) do
        logger[level] = function(self, message, fields) return self:write(level, message, fields) end
    end

    local metricValues = {}
    local metricHistograms = {}
    local metricSeries = {}
    local metricSeriesCount = 0
    local metricSeriesMaximum = math.max(8, math.min(
        math.floor(tonumber(deps.maximumMetricSeries) or 2048), 16384))
    local droppedMetricSamples = 0
    local invalidMetricSamples = 0
    local metrics = {}
    local function metricKey(name, labels)
        if type(name) ~= 'string' or #name < 1 or #name > 128
            or not name:match('^[A-Za-z_:][A-Za-z0-9_:]*$') then return nil end
        if labels ~= nil and (type(labels) ~= 'table' or getmetatable(labels) ~= nil) then return nil end
        local parts = {}
        for key, value in pairs(labels or {}) do
            if type(key) ~= 'string' or #key < 1 or #key > 64
                or not key:match('^[A-Za-z_][A-Za-z0-9_]*$')
                or (#parts + 1) > 12 then return nil end
            local valueType = type(value)
            if valueType == 'number' and (value ~= value or value == math.huge or value == -math.huge) then
                return nil
            end
            if valueType ~= 'string' and valueType ~= 'number' and valueType ~= 'boolean' then return nil end
            local encoded = tostring(value)
            if #encoded > 128 then return nil end
            parts[#parts + 1] = ('%d:%s=%s:%d:%s'):format(
                #key, key, valueType, #encoded, encoded)
        end
        table.sort(parts)
        local key = name .. ':' .. table.concat(parts, ',')
        if #key > 2048 then return nil end
        return key
    end
    local function reserveMetricSeries(key)
        if metricSeries[key] then return true end
        if metricSeriesCount >= metricSeriesMaximum then
            droppedMetricSamples = droppedMetricSamples + 1
            return false
        end
        metricSeries[key] = true
        metricSeriesCount = metricSeriesCount + 1
        return true
    end
    function metrics:increment(name, labels, amount)
        local key = metricKey(name, labels)
        amount = amount == nil and 1 or amount
        if not key or type(amount) ~= 'number' or amount ~= amount
            or amount == math.huge or amount == -math.huge then
            invalidMetricSamples = invalidMetricSamples + 1
            return false
        end
        if not reserveMetricSeries(key) then return false end
        metricValues[key] = (metricValues[key] or 0) + amount
        return true
    end
    function metrics:gauge(name, labels, value)
        local key = metricKey(name, labels)
        if not key or type(value) ~= 'number' or value ~= value
            or value == math.huge or value == -math.huge then
            invalidMetricSamples = invalidMetricSamples + 1
            return false
        end
        if not reserveMetricSeries(key) then return false end
        metricValues[key] = value
        return true
    end
    function metrics:observe(name, labels, value)
        local key = metricKey(name, labels)
        if not key or type(value) ~= 'number' or value ~= value
            or value == math.huge or value == -math.huge then
            invalidMetricSamples = invalidMetricSamples + 1
            return false
        end
        if not reserveMetricSeries(key) then return false end
        local samples = metricHistograms[key] or {}
        samples[#samples + 1] = value
        if #samples > 512 then table.remove(samples, 1) end
        metricHistograms[key] = samples
        return true
    end
    function metrics:snapshot()
        local histograms = {}
        for key, samples in pairs(metricHistograms) do
            local sorted = deepCopy(samples)
            table.sort(sorted)
            local function percentile(value)
                if #sorted == 0 then return 0 end
                return sorted[math.max(1, math.ceil(#sorted * value))]
            end
            histograms[key] = {
                count = #sorted,
                minimum = sorted[1] or 0,
                maximum = sorted[#sorted] or 0,
                p50 = percentile(0.50),
                p95 = percentile(0.95),
                p99 = percentile(0.99)
            }
        end
        return {
            values = deepCopy(metricValues),
            histograms = histograms,
            cardinality = {
                series = metricSeriesCount,
                maximumSeries = metricSeriesMaximum,
                droppedSamples = droppedMetricSamples,
                invalidSamples = invalidMetricSamples
            }
        }
    end

    local function loadJson(resource, path, fallback)
        local raw = platform.loadResourceFile(resource, path)
        if not raw or raw == '' then return deepCopy(fallback), 'file not found' end
        local ok, decoded = pcall(platform.jsonDecode, raw)
        if not ok or type(decoded) ~= 'table' then return deepCopy(fallback), 'invalid JSON' end
        return decoded, nil
    end

    return {
        copy = deepCopy,
        readonly = readonly,
        error = errorResult,
        failureCode = failureCode,
        safeCall = safeCall,
        isCallable = isCallable,
        cfxResult = cfxResult,
        jsonContainerKind = jsonContainerKind,
        nextId = deps.nextId or nextId,
        configureIds = configureIds,
        monotonicMs = deps.monotonicMs or monotonicMs,
        utcIso = deps.utcIso or utcIso,
        wildcardMatch = wildcardMatch,
        semver = semver,
        semverCompare = semverCompare,
        semverSatisfies = semverSatisfies,
        redact = redact,
        currentContext = currentContext,
        withContext = withContext,
        logger = deps.logger or logger,
        metrics = deps.metrics or metrics,
        loadJson = loadJson
    }
end
