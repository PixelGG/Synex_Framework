local registry = assert(SynexLuaGeneratedContracts, 'load generated/contracts.lua before the Synex Lua SDK')

local sdk = {}

local function sdkError(code, message)
    return nil, { code = code, message = message, retryable = false }
end

local function invoke(descriptor, request, options)
    if type(descriptor) ~= 'table' then
        return sdkError('CONTRACT_NOT_FOUND', 'The requested generated contract is unavailable.')
    end
    if type(request) ~= 'table' then
        return sdkError('INVALID_ARGUMENT', 'Contract requests must be objects.')
    end
    local value, invokeError = exports.synex_core:Invoke(
        descriptor.name, descriptor.version, request, options or {})
    if value == false and invokeError ~= nil then return nil, invokeError end
    return value, invokeError
end

function sdk.connect(versionRange)
    local api, apiError = exports.synex_core:GetAPI(versionRange or '^1.0.0')
    if not api then return nil, apiError end

    local client = {
        api = api,
        sourceHash = registry.sourceHash
    }

    function client:request(name, request, options)
        if type(name) ~= 'string' then
            return sdkError('INVALID_ARGUMENT', 'Contract name must be a string.')
        end
        return invoke(registry.latest[name], request, options)
    end

    function client:requestVersion(name, version, request, options)
        if type(name) ~= 'string' or type(version) ~= 'string' then
            return sdkError('INVALID_ARGUMENT', 'Contract name and version must be strings.')
        end
        return invoke(registry.versions[name .. '@' .. version], request, options)
    end

    return client, nil
end

SynexLuaSDK = sdk
return sdk
