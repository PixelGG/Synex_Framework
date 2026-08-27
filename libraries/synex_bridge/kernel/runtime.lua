assert(SynexBridgeKernel and SynexBridgeKernel.Foundation and SynexBridgeKernel.Catalogs
    and SynexBridgeKernel.Mappings and SynexBridgeKernel.Telemetry
    and SynexBridgeKernel.Resolver,
    'all synex_bridge kernel modules must load before runtime')

local Foundation = SynexBridgeKernel.Foundation
local Runtime = {}

function Runtime.create(options)
    if options ~= nil and type(options) ~= 'table' then
        error('compatibility runtime options are invalid')
    end
    options = options or {}
    local adapters = SynexBridgeKernel.Catalogs.createAdapters(options.adapterLimits)
    local catalogs = SynexBridgeKernel.Catalogs.createCatalogs(options.catalogLimits)
    local mappings = SynexBridgeKernel.Mappings.create({ limits = options.mappingLimits })
    local telemetry = SynexBridgeKernel.Telemetry.create(options.telemetry)
    local catalogTelemetry = SynexBridgeKernel.Telemetry.create(options.catalogTelemetry)
    local resolver = SynexBridgeKernel.Resolver.create({
        adapters = adapters,
        catalogs = catalogs,
        telemetry = telemetry,
        maximumConfigurations = options.maximumConfigurations,
        maximumConsumers = options.maximumConsumers,
    })
    local runtime = {
        foundation = Foundation,
        adapters = adapters,
        catalogs = catalogs,
        mappings = mappings,
        telemetry = telemetry,
        catalogTelemetry = catalogTelemetry,
        resolver = resolver,
    }

    function runtime:cleanup(owner, epoch)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local removed = {}
        local cleanupOrder = {
            { name = 'resolver', target = resolver },
            { name = 'catalogTelemetry', target = catalogTelemetry },
            { name = 'telemetry', target = telemetry },
            { name = 'mappings', target = mappings },
            { name = 'adapters', target = adapters },
            { name = 'catalogs', target = catalogs },
        }
        for _, entry in ipairs(cleanupOrder) do
            local count, cleanupError = entry.target:cleanup(owner, epoch)
            if count == nil then return nil, cleanupError end
            removed[entry.name] = count
        end
        return removed, nil
    end

    return runtime
end

SynexBridgeKernel.Runtime = Runtime
