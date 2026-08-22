local api, apiError = exports.synex_core:GetAPI('^1.0.0')
if not api then
    error(('Synex API unavailable: %s'):format(apiError and apiError.code or 'UNKNOWN'))
end

local function echo(request)
    return {
        message = request.message,
        provider = 'synex_example'
    }, nil
end

local contract = {
    name = 'synex.example.echo',
    version = '1.0.0',
    kind = 'service',
    stability = 'experimental',
    network = 'none',
    capability = nil,
    input = {
        type = 'object',
        additionalProperties = false,
        required = { 'message' },
        properties = {
            message = { type = 'string', minLength = 1, maxLength = 128 }
        }
    },
    output = {
        type = 'object',
        additionalProperties = false,
        required = { 'message', 'provider' },
        properties = {
            message = { type = 'string', maxLength = 128 },
            provider = { const = 'synex_example' }
        }
    },
    errors = { 'INVALID_ARGUMENT', 'NOT_READY', 'PROVIDER_UNAVAILABLE' },
    idempotent = true
}

local handlerToken, handlerError = api.RPC.registerServer(contract, echo)
if not handlerToken then
    error(('Unable to register example contract: %s'):format(handlerError and handlerError.code or 'UNKNOWN'))
end

local serviceToken, serviceError = api.Services.provide({
    name = 'synex.example',
    version = '1.0.0',
    methods = { echo = echo }
})
if not serviceToken then
    error(('Unable to register example service: %s'):format(serviceError and serviceError.code or 'UNKNOWN'))
end
