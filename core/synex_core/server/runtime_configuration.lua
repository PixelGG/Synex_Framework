local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimeConfiguration = function(deps)
    local platform = assert(deps.platform, 'runtime configuration requires platform')
    local configuration = assert(deps.configuration, 'runtime configuration requires validator')
    local policies = { deny_new = true, kick_old = true, allow = true, replace_old = true }
    local runtimeConfiguration = {}

    local function readInteger(name, fallback)
        local raw = platform.getConvar(name, tostring(fallback))
        if type(raw) ~= 'string' or not raw:match('^%-?%d+$') then
            return nil, ('%s must be an integer without whitespace or decimal notation'):format(name)
        end
        local value = tonumber(raw)
        if value == nil or math.type(value) ~= 'integer' then
            return nil, ('%s must be a supported integer'):format(name)
        end
        return value, nil
    end

    function runtimeConfiguration:apply(config)
        local connections = config.connections
        connections.duplicatePolicy = platform.getConvar('synex_duplicate_policy', connections.duplicatePolicy)
        if not policies[connections.duplicatePolicy] then
            return nil, 'synex_duplicate_policy must be deny_new, kick_old, allow, or replace_old'
        end
        local integerOverrides = {
            { 'queueReservedSlots', 'synex_queue_reserved_slots' },
            { 'queueStaffPriority', 'synex_queue_staff_priority' },
            { 'queueReconnectPriority', 'synex_queue_reconnect_priority' },
            { 'queueReconnectGraceMs', 'synex_queue_reconnect_grace_ms' }
        }
        for _, override in ipairs(integerOverrides) do
            local value, valueError = readInteger(override[2], connections[override[1]])
            if value == nil then return nil, valueError end
            connections[override[1]] = value
        end
        connections.queueStaffAce = platform.getConvar('synex_queue_staff_ace', connections.queueStaffAce)
        local maintenance, maintenanceError = readInteger(
            'synex_maintenance', connections.maintenanceMode and 1 or 0)
        if maintenance == nil then return nil, maintenanceError end
        if maintenance ~= 0 and maintenance ~= 1 then return nil, 'synex_maintenance must be 0 or 1' end
        connections.maintenanceMode = maintenance == 1
        connections.maintenanceBypassAce = platform.getConvar(
            'synex_maintenance_bypass_ace', connections.maintenanceBypassAce)
        connections.maintenanceMessage = platform.getConvar(
            'synex_maintenance_message', connections.maintenanceMessage)
        local valid, validationError = configuration:validateRuntime(config)
        if not valid then
            return nil, ('invalid effective runtime configuration at %s: %s'):format(
                validationError.details and validationError.details.path or '$', validationError.message)
        end
        config.instanceName = platform.getConvar('synex_instance_name', config.instanceId)
        if #config.instanceName < 1 or #config.instanceName > 96
            or config.instanceName:find('[%z\1-\31\127]') then return nil, 'synex_instance_name is invalid' end
        return config, nil
    end

    return runtimeConfiguration
end
