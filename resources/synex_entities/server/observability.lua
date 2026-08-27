SynexEntityObservability = {}

function SynexEntityObservability.create(options)
    assert(type(options) == 'table', 'entity observability options are required')
    local coreRef = assert(options.coreRef, 'entity observability coreRef is required')
    local foundation = assert(options.foundation, 'entity observability foundation is required')
    local ports = assert(options.ports, 'entity observability ports are required')
    local resourceName = assert(options.resourceName, 'entity observability resourceName is required')
    local metrics = {}
    local service = {}

    local function markUnavailable()
        if foundation.isCallable(foundation.setHealth) then
            foundation.setHealth('DEGRADED', 'OBSERVABILITY_UNAVAILABLE')
        end
    end

    local function apiSection(name, method)
        local api = coreRef.value
        local section = api and api[name]
        if type(section) ~= 'table' or not foundation.isCallable(section[method]) then return nil end
        return section[method]
    end

    local function safeCall(operation, method, ...)
        if not method then return nil end
        local values = table.pack(foundation.protect(operation, function(...)
            return method(...)
        end, nil, ...))
        if not values[1] then return nil end
        return table.unpack(values, 2, values.n)
    end

    function service.before(name, value, context)
        local run = apiSection('Hooks', 'run')
        if not run then
            return foundation.failure('CORE_UNAVAILABLE', 'The Core hook runtime is unavailable', true, context)
        end
        local ok, result, hookError = foundation.protect('hook.' .. name, function()
            return run(name, value, {
                caller = type(context) == 'table' and context.caller or nil,
                traceId = type(context) == 'table' and context.traceId or nil,
            })
        end, context)
        if not ok or result == nil then
            return nil, type(hookError) == 'table' and hookError or {
                code = 'HOOK_REJECTED',
                message = 'An entity policy hook rejected the operation',
                retryable = false,
            }
        end
        return result
    end

    function service.event(topic, payload, context)
        local publish = apiSection('Events', 'publish')
        if not publish then
            markUnavailable()
            return false
        end
        local ok, published = foundation.protect('event.' .. topic, function()
            return publish(topic, payload, {
                traceId = type(context) == 'table' and context.traceId or nil,
            })
        end, context)
        if not ok or published == nil then
            markUnavailable()
            return false
        end
        return true
    end

    function service.audit(action, targetType, targetId, details, context)
        local append = apiSection('Audit', 'append')
        if not append then
            markUnavailable()
            return false
        end
        local ok, recorded = foundation.protect('audit.' .. action, function()
            return append({
                action = action,
                context = details or {},
                targetId = targetId,
                targetType = targetType,
                traceId = type(context) == 'table' and context.traceId or nil,
            })
        end, context)
        if not ok or recorded == nil then
            markUnavailable()
            return false
        end
        return true
    end

    function service.lifecycle(action, record, reasonCode, context)
        if (action ~= 'deleted' and action ~= 'dematerialized' and action ~= 'orphaned')
            or type(record) ~= 'table' then return false end
        local payload = {
            entityId = record.entityId,
            generation = record.generation,
            reasonCode = reasonCode,
            resourceOwner = record.resourceOwner,
        }
        local published = service.event('synex.entities.' .. action, payload, context)
        local recorded = service.audit('entities.' .. action, 'entity',
            record.entityId, payload, context)
        return published and recorded
    end

    local function metric(method, suffix, labels, value)
        local writer = apiSection('Metrics', method)
        if not writer then
            markUnavailable()
            return false
        end
        local name = resourceName:gsub('[^A-Za-z0-9_]', '_') .. '_' .. suffix
        local ok, result = foundation.protect('metrics.' .. suffix, function()
            return writer(name, labels or {}, value)
        end)
        if not ok or result ~= true then
            markUnavailable()
            return false
        end
        metrics[name] = value
        return true
    end

    function service.increment(suffix, labels, amount)
        return metric('increment', suffix, labels, amount or 1)
    end

    function service.gauge(suffix, labels, value)
        return metric('gauge', suffix, labels, value)
    end

    function service.observe(suffix, labels, value)
        return metric('observe', suffix, labels, value)
    end

    function service.timer()
        local startedAt = ports.getGameTimer()
        return function(suffix, labels)
            local elapsed = ports.getGameTimer() - startedAt
            if elapsed < 0 then elapsed = elapsed + 4294967296 end
            elapsed = math.max(0, elapsed)
            service.observe(suffix, labels, elapsed)
            return elapsed
        end
    end

    function service.snapshot()
        local names = {}
        for name in pairs(metrics) do names[#names + 1] = name end
        table.sort(names)
        local output = {}
        for index, name in ipairs(names) do output[index] = { name = name, lastValue = metrics[name] } end
        return output
    end

    return service
end
