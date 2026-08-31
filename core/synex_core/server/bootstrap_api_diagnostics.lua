local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapApiDiagnostics = function(deps)
    local runtime = assert(deps.runtime, 'bootstrap API diagnostics require runtime')
    local reliability = assert(deps.reliability,
        'bootstrap API diagnostics require reliability services')
    local security = assert(deps.security, 'bootstrap API diagnostics require security')
    local guarded = assert(deps.guarded, 'bootstrap API diagnostics require guard')
    local caller = assert(deps.caller, 'bootstrap API diagnostics require caller')
    local epoch = assert(deps.epoch, 'bootstrap API diagnostics require owner epoch')

    return {
        run = function()
            return guarded(caller, epoch, 'synex.runtime.read', 'Diagnostics.run', function()
                return runtime:doctor()
            end)
        end,
        getControlSnapshot = function()
            return guarded(caller, epoch, 'synex.runtime.read',
                'Diagnostics.getControlSnapshot', function()
                    return runtime:controlSnapshot()
                end)
        end,
        search = function(request)
            return guarded(caller, epoch, 'synex.audit.summary', 'Diagnostics.search', function()
                return reliability.audit:search(request)
            end)
        end,
        getSecurityFindings = function(request)
            return guarded(caller, epoch, 'synex.security.diagnostics.read',
                'Diagnostics.getSecurityFindings', function()
                    return security.diagnostics:page(request)
                end)
        end,
    }
end
