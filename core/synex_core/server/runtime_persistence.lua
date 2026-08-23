local factories = assert(SynexCoreFactories, 'factories must be loaded first')

local attachInstances = assert(factories.runtimePersistenceInstances,
    'runtime persistence instances must be loaded first')
local attachControl = assert(factories.runtimePersistenceControl,
    'runtime persistence control must be loaded first')
local attachControlRetention = assert(factories.runtimePersistenceControlRetention,
    'runtime persistence control retention must be loaded first')
local createRbac = assert(factories.runtimePersistenceRbac,
    'runtime persistence RBAC must be loaded first')

factories.runtimePersistence = function(deps)
    local foundation = assert(deps.foundation, 'runtime persistence requires foundation')
    local database = assert(deps.database, 'runtime persistence requires database')
    local platform = assert(deps.platform, 'runtime persistence requires platform')
    local instanceId = assert(deps.instanceId, 'runtime persistence requires an instance ID')
    local metrics = foundation.metrics
    local maintenanceBatchMaximum = type(deps.maintenanceBatchMaximum) == 'number'
        and math.type(deps.maintenanceBatchMaximum) == 'integer'
        and math.max(1, math.min(deps.maintenanceBatchMaximum, 1000)) or 250
    local maximumLocalSessions = type(deps.maximumLocalSessions) == 'number'
        and math.type(deps.maximumLocalSessions) == 'integer'
        and math.max(1, math.min(deps.maximumLocalSessions, 20000)) or 20000
    local sessionControlRetentionDays = type(deps.sessionControlRetentionDays) == 'number'
        and math.type(deps.sessionControlRetentionDays) == 'integer'
        and math.max(1, math.min(deps.sessionControlRetentionDays, 36500)) or 30
    local context = {
        foundation = foundation,
        database = database,
        platform = platform,
        instanceId = instanceId,
        metrics = metrics,
        maintenanceBatchMaximum = maintenanceBatchMaximum,
        maximumLocalSessions = maximumLocalSessions,
        sessionControlRetentionDays = sessionControlRetentionDays,
        bootId = nil,
        bootRegistered = false,
        controlAuditCursor = '',
        controlCompactionState = 'completed',
        controlCapacityHighWatermarks = { global = 0, requester = 0 }
    }

    context.affectedRows = function(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end

    context.capacityInteger = function(value, minimum)
        local parsed = tonumber(value)
        if not parsed or math.type(parsed) ~= 'integer'
            or parsed < minimum or parsed > 4294967295 then return nil end
        return parsed
    end

    context.emitControlCapacityMetrics = function(snapshot)
        if type(snapshot) ~= 'table' then return end
        for _, scope in ipairs({ 'global', 'requester' }) do
            local count = snapshot[scope]
            local limit = snapshot[scope .. 'Limit']
            if type(count) == 'number' and type(limit) == 'number' and limit > 0 then
                local utilization = count / limit
                context.metrics:gauge('synex_session_control_capacity_entries', { scope = scope }, count)
                context.metrics:gauge('synex_session_control_capacity_limit', { scope = scope }, limit)
                context.metrics:gauge('synex_session_control_capacity_utilization',
                    { scope = scope }, utilization)
                context.controlCapacityHighWatermarks[scope] = math.max(
                    context.controlCapacityHighWatermarks[scope], utilization)
                context.metrics:gauge('synex_session_control_capacity_utilization_high_watermark',
                    { scope = scope }, context.controlCapacityHighWatermarks[scope])
            end
        end
    end

    context.validateMaintenanceBatch = function(value, operation)
        local count = context.affectedRows(value)
        if not count or math.type(count) ~= 'integer'
            or count < 0 or count > context.maintenanceBatchMaximum then
            return nil, foundation.error('MAINTENANCE_BATCH_INVALID',
                'Runtime maintenance exceeded its bounded batch.', {
                    retryable = true,
                    details = { operation = operation }
                })
        end
        return count, nil
    end

    context.validateBoundedMutation = function(value, maximum, operation)
        local count = context.affectedRows(value)
        if not count or math.type(count) ~= 'integer' or count < 0 or count > maximum then
            return nil, foundation.error('RUNTIME_MUTATION_BOUND_INVALID',
                'Runtime persistence exceeded a configured mutation bound.', {
                    retryable = true,
                    details = { operation = operation }
                })
        end
        return count, nil
    end

    context.requireBootAuthority = function()
        if not context.bootRegistered then
            return nil, foundation.error('INSTANCE_BOOT_NOT_REGISTERED',
                'The runtime boot generation is not registered.')
        end
        return context.bootId, nil
    end

    context.instanceSnapshot = {
        localInstanceId = context.instanceId,
        status = 'starting',
        healthy = 0,
        stale = 0,
        total = 0,
        pendingControlRequests = 0,
        instanceSummaryTruncated = false,
        pendingControlRequestsTruncated = false,
        refreshedAt = nil
    }
    context.instances = {}

    attachInstances(context)
    attachControl(context)
    attachControlRetention(context)
    local rbac = createRbac(context)
    return { instances = context.instances, rbac = rbac }
end
