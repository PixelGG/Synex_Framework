SynexSecurityObservability = {}

local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')

function SynexSecurityObservability.create(options)
    options = options or {}
    local coreRef = assert(options.coreRef, 'security observability requires Core reference')
    local now = assert(options.now, 'security observability requires time')
    local ringFactory = assert(options.ringFactory, 'security observability requires ring buffer')
    local counters, gauges, detectorHealth = {}, {}, {}
    local findings = ringFactory(256)
    local observations = {}
    local observability = {}

    local function coreCall(group, method, ...)
        local api = coreRef.value
        local section = type(api) == 'table' and api[group] or nil
        local handler = type(section) == 'table' and section[method] or nil
        if not Validation.isCallable(handler) then return nil end
        local values = table.pack(pcall(handler, ...))
        if not values[1] or values[2] == false then return nil end
        return table.unpack(values, 2, values.n)
    end

    local function labelKey(labels)
        local keys = {}
        for key in pairs(labels or {}) do keys[#keys + 1] = key end
        table.sort(keys)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = tostring(key) .. '=' .. tostring(labels[key])
        end
        return table.concat(parts, ',')
    end

    local function series(name, labels)
        return tostring(name) .. '{' .. labelKey(labels) .. '}'
    end

    function observability.increment(name, labels, amount)
        local delta = Validation.isFinite(amount) and amount or 1
        local key = series(name, labels)
        counters[key] = math.min(9007199254740991, (counters[key] or 0) + delta)
        coreCall('Metrics', 'increment', 'synex_security_' .. name, labels or {}, delta)
        return true
    end

    function observability.gauge(name, labels, value)
        if not Validation.isFinite(value) then return false end
        gauges[series(name, labels)] = value
        coreCall('Metrics', 'gauge', 'synex_security_' .. name, labels or {}, value)
        return true
    end

    function observability.observe(name, labels, value)
        if not Validation.isFinite(value) then return false end
        local key = series(name, labels)
        local record = observations[key] or { count = 0, total = 0, maximum = value }
        record.count = record.count + 1
        record.total = record.total + value
        record.maximum = math.max(record.maximum, value)
        observations[key] = record
        coreCall('Metrics', 'observe', 'synex_security_' .. name, labels or {}, value)
        return true
    end

    function observability.detector(name, mode, state, code)
        if not Validation.semanticKey(name, 64) then return false end
        detectorHealth[name] = {
            name = name,
            mode = tostring(mode or 'DISABLED'):sub(1, 16),
            state = tostring(state or 'UNKNOWN'):sub(1, 16),
            code = code and tostring(code):sub(1, 64) or nil,
            updatedAtMs = now(),
        }
        return true
    end

    function observability.finding(severity, code, summary, context)
        if not Validation.errorCode(code)
            or not Validation.text(summary, 3, 192) then return false end
        findings.push({
            atMs = now(), severity = tostring(severity):sub(1, 16),
            code = code, summary = summary,
            detector = type(context) == 'table' and context.detector or nil,
            scope = type(context) == 'table' and context.scope or nil,
        })
        -- Error codes may be extended by domains. Keep the shared metric on a
        -- fixed-cardinality severity dimension; the bounded finding retains
        -- the exact code for diagnostics.
        observability.increment('findings_total', {
            severity = tostring(severity):lower(),
        }, 1)
        return true
    end

    function observability.audit(action, targetType, targetId, context, traceId)
        if not Validation.text(action, 3, 128)
            or not Validation.text(targetType, 3, 64)
            or not Validation.text(tostring(targetId), 1, 128) then return false end
        return coreCall('Audit', 'append', {
            action = action,
            targetType = targetType,
            targetId = tostring(targetId):sub(1, 128),
            traceId = traceId,
            context = Validation.copy(context or {}, {
                maximumBytes = 8192, maximumEntries = 64,
            }) or {},
        }) ~= nil
    end

    function observability.event(topic, payload, traceId)
        if not Validation.text(topic, 3, 128) then return false end
        return coreCall('Events', 'publish', topic, payload or {}, {
            traceId = traceId,
        }) ~= nil
    end

    function observability.snapshot()
        local detectors = {}
        for _, value in pairs(detectorHealth) do
            detectors[#detectors + 1] = Validation.copy(value)
        end
        table.sort(detectors, function(left, right) return left.name < right.name end)
        return {
            counters = Validation.copy(counters) or {},
            gauges = Validation.copy(gauges) or {},
            observations = Validation.copy(observations) or {},
            detectors = detectors,
            findings = findings.size(),
        }
    end

    function observability.listFindings(limit)
        local maximum = Validation.isInteger(limit, 1, 100) and limit or 50
        local values = findings.list({ limit = maximum, newestFirst = true }) or {}
        local result = {}
        for index = 1, #values do
            result[index] = Validation.copy(values[index])
        end
        local total = findings.size()
        return { items = result, total = total, truncated = total > #result }
    end

    return observability
end
