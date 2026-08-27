local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapDiagnostics = function(deps)
    local runtime = assert(deps.runtime, 'bootstrap diagnostics requires runtime')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local reliability = deps.reliability
    local controlProviders = deps.controlProviders
    local coreResource = deps.coreResource
    local shared = factories.createBootstrapDiagnosticsShared(deps)
    factories.bootstrapDiagnosticsRuntime(deps, shared)
    local control = factories.createBootstrapControlShared(deps, shared)
    local operations = factories.createBootstrapControlQueryOperations(
        deps, shared, control)
    operations.inspect = factories.createBootstrapControlInspectOperation(
        deps, shared, control)
    operations.findings = factories.createBootstrapControlSecurityOperation(
        deps, shared, control)
    local requiredInspectInput = assert(control.requiredInspectInput)
    local coreProviderDefinition = {
        schemaVersion = 1,
        namespace = 'core',
        label = 'Synex Core',
        category = 'foundation',
        version = SynexProtocol.api,
        operations = operations,
        views = {
            { id = 'overview', label = 'Overview', operation = 'summary', presentation = 'key-value', order = 10 },
            { id = 'runtime', label = 'Runtime', operation = 'inspect', presentation = 'key-value', order = 20 },
            { id = 'resources', label = 'Resources', operation = 'list', presentation = 'table', order = 30 },
            { id = 'dependencies', label = 'Dependencies', operation = 'list', presentation = 'graph', order = 40 },
            { id = 'contracts', label = 'Contracts', operation = 'list', presentation = 'table', order = 50 },
            { id = 'capabilities', label = 'Capabilities', operation = 'list', presentation = 'table', order = 60 },
            { id = 'rpc', label = 'RPC', operation = 'inspect', presentation = 'metrics', order = 70 },
            { id = 'hooks', label = 'Hooks', operation = 'list', presentation = 'table', order = 80 },
            { id = 'services', label = 'Services', operation = 'list', presentation = 'table', order = 90 },
            { id = 'database', label = 'Database', operation = 'inspect', presentation = 'metrics', order = 100 },
            { id = 'slow_queries', label = 'Slow Queries', operation = 'list', presentation = 'table', order = 105,
                description = 'Cursor-paged sanitized slow database operation history.' },
            { id = 'migrations', label = 'Migrations', operation = 'list', presentation = 'table', order = 110,
                description = 'Cursor-paged migration state, timings, checksums and manifest drift findings.' },
            { id = 'sessions', label = 'Sessions', operation = 'list', presentation = 'table', order = 120,
                description = 'Bounded keyset page of active session authority projections.' },
            { id = 'characters', label = 'Characters', operation = 'inspect', presentation = 'table', order = 130 },
            { id = 'audit', label = 'Audit', operation = 'search', presentation = 'timeline', order = 140 },
            { id = 'tracing', label = 'Tracing', operation = 'list', presentation = 'timeline', order = 150,
                description = 'Cursor-paged in-process Core spans without arguments or payloads.' },
            { id = 'performance', label = 'Performance', operation = 'metrics', presentation = 'metrics', order = 160 },
            { id = 'security', label = 'Security', operation = 'findings', presentation = 'findings', order = 170 },
            { id = 'compatibility', label = 'Compatibility', operation = 'inspect', presentation = 'table', order = 180 },
            { id = 'instances', label = 'Instances', operation = 'inspect', presentation = 'key-value', order = 190,
                description = 'Current instance and bounded cluster summary.' },
            { id = 'health_timeline', label = 'Health Timeline', operation = 'inspect', presentation = 'timeline', order = 200,
                description = 'Recent real Core lifecycle transitions and active health reasons.' },
            { id = 'resource', label = 'Resource Inspector', operation = 'inspect', presentation = 'key-value', order = 210,
                description = 'Exact resource metadata, contracts, capabilities and dependency impact.',
                input = requiredInspectInput('Resource name', 'resource', 2, 64) },
            { id = 'dependency_impact', label = 'Dependency Impact', operation = 'inspect', presentation = 'graph', order = 220,
                description = 'Direct providers and consumers derived from the live dependency graph.',
                input = requiredInspectInput('Resource name', 'resource', 2, 64) },
            { id = 'contract', label = 'Contract Inspector', operation = 'inspect', presentation = 'key-value', order = 230,
                description = 'Exact contract metadata and bounded schema summaries.',
                input = requiredInspectInput('Contract name or name@version', 'lookup', 1, 128) },
            { id = 'capability', label = 'Capability Inspector', operation = 'inspect', presentation = 'table', order = 240,
                description = 'Exact capability classification and effective requester decisions.',
                input = { fields = {
                    { key = 'id', label = 'Capability name', source = 'id', type = 'string',
                        format = 'capability', required = true, minLength = 1, maxLength = 128 },
                    { key = 'resource', label = 'Resource', source = 'filter', type = 'string',
                        format = 'resource', required = false, minLength = 2, maxLength = 64 }
                } } },
            { id = 'session', label = 'Session Inspector', operation = 'inspect', presentation = 'key-value', order = 250,
                description = 'Exact active session state without raw platform identifiers.',
                input = requiredInspectInput('Session ID', 'identifier', 1, 128) },
            { id = 'character', label = 'Character Inspector', operation = 'inspect', presentation = 'key-value', order = 260,
                description = 'Exact character lifecycle metadata with bounded provider-owned relation counts.',
                input = requiredInspectInput('Character ID', 'identifier', 1, 128) },
            { id = 'rpc_detail', label = 'RPC Inspector', operation = 'inspect', presentation = 'key-value', order = 270,
                description = 'Registered RPC owner, contract metadata, outcomes and bounded latency samples.',
                input = requiredInspectInput('RPC contract name', 'lookup', 1, 128) },
            { id = 'hook_detail', label = 'Hook Inspector', operation = 'inspect', presentation = 'key-value', order = 280,
                description = 'Registered hook handlers, policy metadata, outcomes and bounded latency samples.',
                input = requiredInspectInput('Hook name', 'lookup', 1, 128) },
            { id = 'service_detail', label = 'Service Inspector', operation = 'inspect', presentation = 'table', order = 290,
                description = 'Exact bounded service-provider health and circuit metadata.',
                input = requiredInspectInput('Service name or name@major', 'lookup', 1, 128) },
            { id = 'incident_window', label = 'Incident Window', operation = 'inspect', presentation = 'timeline', order = 300,
                description = 'Recent lifecycle transitions, active reasons and unhealthy workers.' },
            { id = 'trace_detail', label = 'Trace Inspector', operation = 'list', presentation = 'timeline', order = 310,
                description = 'Exact cursor-paged trace tree with operation outcomes and error codes.',
                input = { fields = {{
                    key = 'trace_id', label = 'Trace ID', source = 'filter', type = 'string',
                    format = 'identifier', required = true, minLength = 1, maxLength = 128
                }} } }
        }
    }
    local coreViewAccess = {
        overview = 'general', runtime = 'general', resources = 'general',
        dependencies = 'general', contracts = 'general', capabilities = 'security',
        rpc = 'general', hooks = 'general', services = 'general', database = 'general',
        slow_queries = 'general',
        migrations = 'general', sessions = 'general', characters = 'general',
        audit = 'general', tracing = 'audit', performance = 'general', security = 'security',
        compatibility = 'general', instances = 'general', health_timeline = 'general',
        resource = 'general', dependency_impact = 'general', contract = 'general',
        capability = 'security', session = 'general', character = 'general',
        rpc_detail = 'general', hook_detail = 'general', service_detail = 'general',
        incident_window = 'general', trace_detail = 'audit'
    }
    for _, view in ipairs(coreProviderDefinition.views) do
        view.accessClass = assert(coreViewAccess[view.id],
            ('missing Core Control access class for %s'):format(view.id))
        if view.id == 'audit' then
            view.search = {
                kinds = {
                    { id = 'trace', modes = { 'exact' }, accessClass = 'audit' },
                    { id = 'resource', modes = { 'exact', 'prefix' }, accessClass = 'general' },
                    { id = 'user', modes = { 'exact' }, accessClass = 'identifiers' },
                    { id = 'session', modes = { 'exact' }, accessClass = 'general' },
                    { id = 'character', modes = { 'exact' }, accessClass = 'general' },
                    { id = 'contract', modes = { 'exact', 'prefix' }, accessClass = 'general' },
                    { id = 'capability', modes = { 'exact', 'prefix' }, accessClass = 'security' }
                }
            }
        end
    end
    if controlProviders then
        assert(reliability and reliability.audit,
            'built-in Core control provider requires audit reliability')
        assert(type(coreResource) == 'string' and coreResource ~= '',
            'built-in Core control provider requires core resource')
        local _, coreProviderError = controlProviders:register(coreResource,
            registries.owners:epoch(coreResource), coreProviderDefinition)
        if coreProviderError then
            error(('unable to register built-in Core control provider: %s'):format(
                coreProviderError.message))
        end
    end

    return runtime
end
