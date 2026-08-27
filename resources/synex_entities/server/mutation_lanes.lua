SynexEntityMutationLanes = {}

function SynexEntityMutationLanes.create(options)
    assert(type(options) == 'table', 'entity mutation lane options are required')
    local foundation = assert(options.foundation, 'entity mutation lane foundation is required')
    local ports = assert(options.ports, 'entity mutation lane ports are required')
    local maximumLanes = options.maximumLanes or 8192
    local timeoutMs = options.timeoutMs or 15000
    local lanes = {}
    local laneCount = 0
    local service = {}

    local function validKey(value)
        return type(value) == 'string' and #value >= 1 and #value <= 256
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function now()
        local value = ports.getGameTimer()
        if type(value) ~= 'number' or value ~= value then return 0 end
        return value
    end

    function service.with(key, operation, context, handler)
        if not validKey(key) or type(operation) ~= 'string' or #operation < 1
            or #operation > 96 or not foundation.isCallable(handler) then
            return foundation.failure(
                'INVALID_ARGUMENT',
                'The entity mutation lane request is invalid',
                false,
                context
            )
        end
        local active = lanes[key]
        if active then
            return foundation.failure(
                'CONCURRENT_MODIFICATION',
                'Another mutation for this entity identity is in progress',
                true,
                context
            )
        end
        if laneCount >= maximumLanes then
            return foundation.failure(
                'ENTITY_QUOTA_EXCEEDED',
                'The entity mutation lane capacity has been reached',
                true,
                context
            )
        end

        local token = {}
        local startedAt = now()
        lanes[key] = {
            caller = type(context) == 'table' and context.caller or nil,
            operation = operation,
            startedAt = startedAt,
            token = token,
            traceId = type(context) == 'table' and context.traceId or nil,
        }
        laneCount = laneCount + 1
        local values = table.pack(xpcall(handler, debug.traceback))
        if lanes[key] and lanes[key].token == token then
            lanes[key] = nil
            laneCount = math.max(0, laneCount - 1)
        end
        if not values[1] then error(values[2], 0) end
        if now() - startedAt > timeoutMs then
            return foundation.failure(
                'OPERATION_TIMEOUT',
                'The entity mutation exceeded its bounded execution window',
                true,
                context
            )
        end
        return table.unpack(values, 2, values.n)
    end

    function service.bindingKey(namespace, reference)
        if not validKey(namespace) or not validKey(reference) then return nil end
        return 'binding:' .. namespace .. ':' .. reference
    end

    function service.entityKey(entityId)
        if not validKey(entityId) then return nil end
        return 'entity:' .. entityId
    end

    function service.snapshot(limit)
        limit = type(limit) == 'number' and math.max(1, math.min(math.floor(limit), 100)) or 50
        local keys = {}
        for key in pairs(lanes) do keys[#keys + 1] = key end
        table.sort(keys)
        local items = {}
        for index = 1, math.min(#keys, limit) do
            local lane = lanes[keys[index]]
            items[index] = {
                caller = lane.caller,
                key = keys[index],
                operation = lane.operation,
                runningMs = math.max(0, now() - lane.startedAt),
                traceId = lane.traceId,
            }
        end
        return { count = laneCount, items = items, truncated = #keys > limit }
    end

    return service
end
