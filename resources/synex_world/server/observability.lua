SynexWorldObservability = {}

local Foundation = assert(SynexWorldFoundation, 'world foundation must be loaded first')

function SynexWorldObservability.create(options)
    local coreRef = assert(options.coreRef, 'world observability requires Core reference')
    local foundation = assert(options.foundation, 'world observability requires foundation')
    local resourceName = assert(options.resourceName, 'world observability requires resource name')
    local observability = {}

    local function apiGroup(name)
        local api = coreRef.value
        return type(api) == 'table' and type(api[name]) == 'table' and api[name] or nil
    end
    local function call(group, method, ...)
        local api = apiGroup(group)
        local handler = api and api[method]
        if not Foundation.isCallable(handler) then return nil end
        local ok, value = pcall(handler, ...)
        return ok and value or nil
    end
    function observability.increment(name, labels, amount)
        return call('Metrics', 'increment', resourceName .. '_' .. name, labels or {}, amount or 1)
    end
    function observability.gauge(name, labels, value)
        return call('Metrics', 'gauge', resourceName .. '_' .. name, labels or {}, value)
    end
    function observability.observe(name, labels, value)
        return call('Metrics', 'observe', resourceName .. '_' .. name, labels or {}, value)
    end
    function observability.audit(action, targetType, targetId, payload, context)
        return call('Audit', 'append', { action = action, targetType = targetType,
            targetId = tostring(targetId):sub(1, 128), traceId = context and context.traceId,
            context = payload or {} })
    end
    function observability.event(topic, payload, context)
        return call('Events', 'publish', topic, payload, {
            traceId = context and context.traceId,
        })
    end
    function observability.publishOutbox(topic, payload, metadata)
        return call('Events', 'publishOutbox', topic, payload, metadata)
    end
    function observability.runtimeGauges(registry, instances, slices)
        observability.gauge('bundle_count', {}, registry.bundleCount())
        observability.gauge('location_count', {}, registry.countByKind('location'))
        observability.gauge('zone_count', {}, registry.countByKind('zone'))
        observability.gauge('anchor_count', {}, registry.countByKind('anchor'))
        observability.gauge('door_count', {}, registry.countByKind('door'))
        local instanceSummary = instances.summary()
        observability.gauge('instance_count', {}, instanceSummary.live or instanceSummary.total)
        observability.gauge('instance_bucket_recovery_pending', {},
            instanceSummary.pendingBucketRecoveries or 0)
        observability.gauge('client_slice_bytes', {}, slices.summary().bytes)
    end
    return observability
end
