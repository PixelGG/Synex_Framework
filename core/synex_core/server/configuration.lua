local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.configuration = function(deps)
    local foundation = assert(deps.foundation, 'configuration requires foundation')

    local function invalid(path, message)
        return nil, foundation.error('INVALID_CONFIGURATION', message, { details = { path = path } })
    end

    local function exactObject(value, path, required, optional)
        if type(value) ~= 'table' then return invalid(path, 'Configuration value must be an object.') end
        local allowed = {}
        for _, key in ipairs(required) do
            allowed[key] = true
            if value[key] == nil then return invalid(path .. '.' .. key, 'Required configuration value is missing.') end
        end
        for _, key in ipairs(optional or {}) do allowed[key] = true end
        for key in pairs(value) do
            if type(key) ~= 'string' or not allowed[key] then
                return invalid(path .. '.' .. tostring(key), 'Unknown configuration value is not allowed.')
            end
        end
        return true, nil
    end

    local function integer(value, minimum, maximum, path)
        if type(value) ~= 'number' or math.type(value) ~= 'integer' or value < minimum or value > maximum then
            return invalid(path, ('Value must be an integer between %d and %d.'):format(minimum, maximum))
        end
        return true, nil
    end

    local function number(value, minimumExclusive, maximum, path)
        if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge
            or value <= minimumExclusive or value > maximum then
            return invalid(path, ('Value must be finite, greater than %s, and at most %s.'):format(minimumExclusive, maximum))
        end
        return true, nil
    end

    local function boolean(value, path)
        if type(value) ~= 'boolean' then return invalid(path, 'Value must be boolean.') end
        return true, nil
    end

    local function oneOf(value, values, path)
        for _, candidate in ipairs(values) do if value == candidate then return true, nil end end
        return invalid(path, 'Value is not an allowed enum member.')
    end

    local function boundedString(value, minimum, maximum, path, pattern)
        if type(value) ~= 'string' or #value < minimum or #value > maximum or (pattern and not value:match(pattern)) then
            return invalid(path, 'Value is not a valid bounded string.')
        end
        return true, nil
    end

    local function run(checks)
        for _, check in ipairs(checks) do
            local ok, err = check()
            if not ok then return nil, err end
        end
        return true, nil
    end

    local configuration = {}

    function configuration:validateRuntime(config)
        local ok, err = exactObject(config, '$', {
            'environment', 'strict', 'instanceId', 'database', 'connections',
            'rpc', 'events', 'logging', 'privacy', 'retention', 'features'
        }, { '$schema' })
        if not ok then return nil, err end
        if config['$schema'] ~= nil then
            ok, err = boundedString(config['$schema'], 1, 256, '$.$schema')
            if not ok then return nil, err end
        end
        ok, err = run({
            function() return oneOf(config.environment, { 'development', 'staging', 'production' }, '$.environment') end,
            function() return boolean(config.strict, '$.strict') end,
            function()
                if config.instanceId == '' then return true, nil end
                return boundedString(config.instanceId, 1, 36, '$.instanceId', '^[A-Za-z0-9_-]+$')
            end,
            function() return exactObject(config.database, '$.database', {
                'minimumOxmysqlVersion', 'queryWarnMs', 'queryTimeoutMs', 'deadlockRetries', 'migrationLeaseSeconds'
            }) end,
            function()
                local parsed = foundation.semver(config.database.minimumOxmysqlVersion)
                if not parsed or parsed.prerelease ~= nil then
                    return invalid('$.database.minimumOxmysqlVersion', 'Minimum oxmysql version must be a canonical release version.')
                end
                return true, nil
            end,
            function() return integer(config.database.queryWarnMs, 1, 60000, '$.database.queryWarnMs') end,
            function() return integer(config.database.queryTimeoutMs, 100, 60000, '$.database.queryTimeoutMs') end,
            function() return integer(config.database.deadlockRetries, 0, 5, '$.database.deadlockRetries') end,
            function() return integer(config.database.migrationLeaseSeconds, 10, 300, '$.database.migrationLeaseSeconds') end,
            function() return exactObject(config.connections, '$.connections', {
                'pendingTtlMs', 'gateTimeoutMs', 'duplicatePolicy', 'allowlistRequired',
                'clusterSessionLeaseSeconds', 'clusterHeartbeatMs', 'queueEnabled', 'queueUpdateMs',
                'queueTimeoutMs', 'maximumQueued', 'maximumActiveSessions', 'queueReservedSlots',
                'queueStaffPriority', 'queueReconnectPriority', 'queueReconnectGraceMs', 'queueStaffAce',
                'maintenanceMode', 'maintenanceMessage', 'maintenanceBypassAce'
            }) end,
            function() return integer(config.connections.pendingTtlMs, 1000, 600000, '$.connections.pendingTtlMs') end,
            function() return integer(config.connections.gateTimeoutMs, 100, 60000, '$.connections.gateTimeoutMs') end,
            function() return oneOf(config.connections.duplicatePolicy, { 'deny_new', 'kick_old', 'allow', 'replace_old' }, '$.connections.duplicatePolicy') end,
            function() return boolean(config.connections.allowlistRequired, '$.connections.allowlistRequired') end,
            function() return integer(config.connections.clusterSessionLeaseSeconds, 10, 300, '$.connections.clusterSessionLeaseSeconds') end,
            function() return integer(config.connections.clusterHeartbeatMs, 1000, 60000, '$.connections.clusterHeartbeatMs') end,
            function() return boolean(config.connections.queueEnabled, '$.connections.queueEnabled') end,
            function() return integer(config.connections.queueUpdateMs, 250, 30000, '$.connections.queueUpdateMs') end,
            function() return integer(config.connections.queueTimeoutMs, 1000, 1800000, '$.connections.queueTimeoutMs') end,
            function() return integer(config.connections.maximumQueued, 1, 10000, '$.connections.maximumQueued') end,
            function() return integer(config.connections.maximumActiveSessions, 1, 10000, '$.connections.maximumActiveSessions') end,
            function() return integer(config.connections.queueReservedSlots, 0, 9999, '$.connections.queueReservedSlots') end,
            function() return integer(config.connections.queueStaffPriority, 1, 100000, '$.connections.queueStaffPriority') end,
            function() return integer(config.connections.queueReconnectPriority, 1, 100000, '$.connections.queueReconnectPriority') end,
            function() return integer(config.connections.queueReconnectGraceMs, 0, 600000, '$.connections.queueReconnectGraceMs') end,
            function() return boundedString(config.connections.queueStaffAce, 1, 128,
                '$.connections.queueStaffAce', '^[A-Za-z0-9_.%-]+$') end,
            function() return boolean(config.connections.maintenanceMode, '$.connections.maintenanceMode') end,
            function() return boundedString(config.connections.maintenanceMessage, 1, 256,
                '$.connections.maintenanceMessage', '^[^%z\1-\31\127]+$') end,
            function() return boundedString(config.connections.maintenanceBypassAce, 1, 128,
                '$.connections.maintenanceBypassAce', '^[A-Za-z0-9_.%-]+$') end,
            function() return exactObject(config.rpc, '$.rpc', {
                'timeoutMs', 'maximumTimeoutMs', 'maximumPendingPerSource', 'maximumPayloadBytes', 'rate', 'burst'
            }) end,
            function() return integer(config.rpc.timeoutMs, 100, 15000, '$.rpc.timeoutMs') end,
            function() return integer(config.rpc.maximumTimeoutMs, 100, 15000, '$.rpc.maximumTimeoutMs') end,
            function() return integer(config.rpc.maximumPendingPerSource, 1, 128, '$.rpc.maximumPendingPerSource') end,
            function() return integer(config.rpc.maximumPayloadBytes, 1024, 262144, '$.rpc.maximumPayloadBytes') end,
            function() return number(config.rpc.rate, 0, 10000, '$.rpc.rate') end,
            function() return number(config.rpc.burst, 0, 10000, '$.rpc.burst') end,
            function() return exactObject(config.events, '$.events', { 'maximumQueueDepth' }) end,
            function() return integer(config.events.maximumQueueDepth, 1, 100000, '$.events.maximumQueueDepth') end,
            function() return exactObject(config.logging, '$.logging', { 'level', 'pretty' }) end,
            function() return oneOf(config.logging.level, { 'trace', 'debug', 'info', 'warn', 'error', 'fatal' }, '$.logging.level') end,
            function()
                if config.logging.pretty ~= false then return invalid('$.logging.pretty', 'Structured JSON logging cannot be disabled.') end
                return true, nil
            end,
            function() return exactObject(config.privacy, '$.privacy', { 'identifierSaltConvar', 'diagnosticIdentifierPrefix' }) end,
            function() return boundedString(config.privacy.identifierSaltConvar, 1, 64, '$.privacy.identifierSaltConvar', '^[A-Za-z][A-Za-z0-9_]*$') end,
            function() return integer(config.privacy.diagnosticIdentifierPrefix, 4, 16, '$.privacy.diagnosticIdentifierPrefix') end,
            function() return exactObject(config.retention, '$.retention', {
                'workerIntervalMs', 'batchSize', 'audit', 'financial'
            }) end,
            function() return integer(config.retention.workerIntervalMs, 60000, 86400000, '$.retention.workerIntervalMs') end,
            function() return integer(config.retention.batchSize, 1, 1000, '$.retention.batchSize') end,
            function() return exactObject(config.retention.audit, '$.retention.audit', { 'mode', 'archiveAfterDays' }) end,
            function() return oneOf(config.retention.audit.mode, { 'retain_forever', 'archive' }, '$.retention.audit.mode') end,
            function() return integer(config.retention.audit.archiveAfterDays, 1, 36500, '$.retention.audit.archiveAfterDays') end,
            function() return exactObject(config.retention.financial, '$.retention.financial', { 'mode', 'archiveAfterDays' }) end,
            function() return oneOf(config.retention.financial.mode, { 'retain_forever', 'archive' }, '$.retention.financial.mode') end,
            function() return integer(config.retention.financial.archiveAfterDays, 1, 36500, '$.retention.financial.archiveAfterDays') end,
            function() return exactObject(config.features, '$.features', { 'durableEvents', 'sagas', 'stateReplication' }) end,
            function() return boolean(config.features.durableEvents, '$.features.durableEvents') end,
            function() return boolean(config.features.sagas, '$.features.sagas') end,
            function() return boolean(config.features.stateReplication, '$.features.stateReplication') end
        })
        if not ok then return nil, err end
        if config.database.queryWarnMs > config.database.queryTimeoutMs then
            return invalid('$.database.queryWarnMs', 'Slow-query threshold cannot exceed the query timeout.')
        end
        if config.rpc.timeoutMs > config.rpc.maximumTimeoutMs then
            return invalid('$.rpc.timeoutMs', 'Default RPC timeout cannot exceed the maximum timeout.')
        end
        if config.connections.clusterHeartbeatMs >= config.connections.clusterSessionLeaseSeconds * 1000 then
            return invalid('$.connections.clusterHeartbeatMs', 'Cluster heartbeat must be shorter than the session lease.')
        end
        if config.connections.queueUpdateMs > config.connections.queueTimeoutMs then
            return invalid('$.connections.queueUpdateMs', 'Queue update interval cannot exceed the queue timeout.')
        end
        if config.connections.queueReservedSlots >= config.connections.maximumActiveSessions then
            return invalid('$.connections.queueReservedSlots', 'Reserved slots must be lower than the active-session limit.')
        end
        return true, nil
    end

    local function validCapability(value)
        if value == '*' then return true end
        if type(value) ~= 'string' or #value < 1 or #value > 128
            or not value:match('^[a-z][a-z0-9%._%-%*]*$') then return false end
        local wildcard = value:find('*', 1, true)
        local base = value
        if wildcard ~= nil then
            if value:sub(-2) ~= '.*' or wildcard ~= #value then return false end
            base = value:sub(1, -3)
        end
        return base:match('^[a-z][a-z0-9%._%-]*$') ~= nil
            and not base:match('[%._%-]$')
            and not base:match('[%._%-][%._%-]')
    end

    local function validateGrantSet(value, path)
        local ok, err = exactObject(value, path, { 'allow', 'deny' })
        if not ok then return nil, err end
        for _, key in ipairs({ 'allow', 'deny' }) do
            local list = value[key]
            if type(list) ~= 'table' or #list > 512 then return invalid(path .. '.' .. key, 'Capability list is invalid or too large.') end
            local seen = {}
            for index, capability in ipairs(list) do
                if not validCapability(capability) or seen[capability] then
                    return invalid(('%s.%s[%d]'):format(path, key, index), 'Capability pattern is invalid or duplicated.')
                end
                seen[capability] = true
            end
            local count = 0
            for entryKey in pairs(list) do
                count = count + 1
                if type(entryKey) ~= 'number' or math.type(entryKey) ~= 'integer' or entryKey < 1 then
                    return invalid(path .. '.' .. key, 'Capability list must be a dense array.')
                end
            end
            if count ~= #list then return invalid(path .. '.' .. key, 'Capability list must be a dense array.') end
        end
        return true, nil
    end

    function configuration:validateCapabilityPolicy(policy)
        local ok, err = exactObject(policy, '$', { 'default', 'resources' }, { '$schema' })
        if not ok then return nil, err end
        if policy['$schema'] ~= nil then
            ok, err = boundedString(policy['$schema'], 1, 256, '$.$schema')
            if not ok then return nil, err end
        end
        ok, err = validateGrantSet(policy.default, '$.default')
        if not ok then return nil, err end
        if type(policy.resources) ~= 'table' then return invalid('$.resources', 'Resource policies must be an object.') end
        local count = 0
        for resource, grants in pairs(policy.resources) do
            count = count + 1
            if count > 1024 or type(resource) ~= 'string' or #resource < 7 or #resource > 64
                or not resource:match('^synex_[a-z0-9_]+$') then
                return invalid('$.resources.' .. tostring(resource), 'Resource policy name is invalid.')
            end
            ok, err = validateGrantSet(grants, '$.resources.' .. resource)
            if not ok then return nil, err end
        end
        return true, nil
    end

    return configuration
end
