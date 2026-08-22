local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.foundation = function(deps)
    deps = deps or {}
    local platform = assert(deps.platform, 'foundation requires platform')

    local function deepCopy(value, seen, depth)
        if type(value) ~= 'table' then return value end
        depth = (depth or 0) + 1
        if depth > 32 then error('copy depth exceeded') end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local copy = {}
        seen[value] = copy
        for key, item in pairs(value) do
            copy[deepCopy(key, seen, depth)] = deepCopy(item, seen, depth)
        end
        return copy
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

    local function safeCall(handler, ...)
        local arguments = table.pack(...)
        local ok, first, second = xpcall(function()
            return handler(table.unpack(arguments, 1, arguments.n))
        end, debug.traceback)
        if ok then return true, first, second end
        return false, first
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
        local now = os.time() * 1000 + ((platform.nowGame and platform.nowGame() or 0) % 1000)
        return ('%s_%011x_%08x_%08x'):format(namespace, now & 0x7ffffffffff, idNode, sequence & 0xffffffff)
    end

    local function monotonicMs()
        return platform.nowGame()
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
        if type(value) ~= 'string' then return nil end
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

    local function redact(value, depth)
        if type(value) ~= 'table' then return value end
        depth = (depth or 0) + 1
        if depth > 8 then return '[DEPTH_LIMIT]' end
        local output = {}
        for key, item in pairs(value) do
            local normalized = type(key) == 'string' and key:lower() or ''
            if redactedKeys[normalized] or normalized:find('password', 1, true) or normalized:find('secret', 1, true) then
                output[key] = '[REDACTED]'
            else
                output[key] = redact(item, depth)
            end
        end
        return output
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
        if type(handler) ~= 'function' then error('execution context handler must be a function', 2) end
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
        local record = {
            timestamp = utcIso(),
            level = level,
            component = 'synex_core',
            message = tostring(message),
            traceId = context and context.traceId or nil,
            caller = context and context.caller or nil,
            operation = context and (context.contract or context.service or context.hook) or nil,
            fields = redact(fields or {})
        }
        local ok, encoded = pcall(platform.jsonEncode, record)
        platform.print(ok and encoded or ('[synex_core] %s: %s'):format(level, tostring(message)))
    end
    for _, level in ipairs({ 'trace', 'debug', 'info', 'warn', 'error', 'fatal' }) do
        logger[level] = function(self, message, fields) return self:write(level, message, fields) end
    end

    local metricValues = {}
    local metricHistograms = {}
    local metrics = {}
    local function metricKey(name, labels)
        local parts = {}
        for key, value in pairs(labels or {}) do parts[#parts + 1] = tostring(key) .. '=' .. tostring(value) end
        table.sort(parts)
        return name .. ':' .. table.concat(parts, ',')
    end
    function metrics:increment(name, labels, amount)
        local key = metricKey(name, labels)
        metricValues[key] = (metricValues[key] or 0) + (amount or 1)
    end
    function metrics:gauge(name, labels, value)
        local key = metricKey(name, labels)
        metricValues[key] = value
    end
    function metrics:observe(name, labels, value)
        if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return false end
        local key = metricKey(name, labels)
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
        return { values = deepCopy(metricValues), histograms = histograms }
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
        safeCall = safeCall,
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
