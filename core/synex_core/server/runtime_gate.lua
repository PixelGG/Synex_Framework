local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimeGate = function(deps)
    local foundation = assert(deps.foundation, 'runtime gate requires foundation')
    local state = 'booting'
    local gate = {}
    function gate:beginBoot() state = 'booting' end
    function gate:open() state = 'available' end
    function gate:fail() state = 'failed' end
    function gate:stop() state = 'stopping' end
    function gate:requireAvailable()
        if state == 'available' then return true, nil end
        local failed = state == 'failed'
        return nil, foundation.error(failed and 'CORE_FAILED' or 'CORE_NOT_READY',
            failed and 'The Synex runtime failed to start.' or 'The Synex runtime is not ready.', {
                retryable = not failed
            })
    end
    return gate
end
