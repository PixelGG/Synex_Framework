local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.platform = function(overrides)
    overrides = overrides or {}

    local runtimeJson = type(json) == 'table' and json or nil
    local runtimeJsonDecode = runtimeJson and rawget(runtimeJson, 'decode') or nil
    local decoderObjectMetatable = { __jsontype = 'object' }
    local decoderArrayMetatable = { __jsontype = 'array' }

    local function rawMetatable(value)
        if type(debug) ~= 'table' or type(debug.getmetatable) ~= 'function' then
            return nil, false
        end
        local readable, metatable = pcall(debug.getmetatable, value)
        if not readable then return nil, false end
        return metatable, true
    end

    local function sharedJsonMetatable(factoryName, expectedKind)
        local factory = runtimeJson and rawget(runtimeJson, factoryName) or nil
        if type(factory) ~= 'function' then return nil end
        local created, sample = pcall(factory)
        if not created or type(sample) ~= 'table' then return nil end
        local metatable, readable = rawMetatable(sample)
        if not readable or type(metatable) ~= 'table'
            or rawget(metatable, '__jsontype') ~= expectedKind then return nil end
        return metatable
    end

    -- Cfx runtimes either honor the dkjson decoder metatable arguments, expose
    -- shared constructor metatables, or do both. Trust only these exact private
    -- decoder identities and the complete, distinct constructor pair.
    local sharedObjectMetatable = sharedJsonMetatable('object', 'object')
    local sharedArrayMetatable = sharedJsonMetatable('array', 'array')
    if sharedObjectMetatable == nil or sharedArrayMetatable == nil
        or rawequal(sharedObjectMetatable, sharedArrayMetatable) then
        sharedObjectMetatable, sharedArrayMetatable = nil, nil
    end

    local function jsonMetatableKind(metatable)
        if type(metatable) ~= 'table' then return nil end
        if (rawequal(metatable, decoderObjectMetatable)
                or (sharedObjectMetatable ~= nil and rawequal(metatable, sharedObjectMetatable)))
            and rawget(metatable, '__jsontype') == 'object' then
            return 'object'
        end
        if (rawequal(metatable, decoderArrayMetatable)
                or (sharedArrayMetatable ~= nil and rawequal(metatable, sharedArrayMetatable)))
            and rawget(metatable, '__jsontype') == 'array' then
            return 'array'
        end
        return nil
    end

    local function jsonContainerKind(value)
        if type(value) ~= 'table' then return nil end
        if getmetatable(value) == nil then return 'plain' end
        local metatable, readable = rawMetatable(value)
        if not readable then return nil end
        return jsonMetatableKind(metatable)
    end

    local function copyJsonContainerMetadata(source, target)
        if type(target) ~= 'table' or getmetatable(target) ~= nil then return nil end
        local kind = jsonContainerKind(source)
        if kind == 'object' or kind == 'array' then
            local metatable, readable = rawMetatable(source)
            if not readable or jsonMetatableKind(metatable) ~= kind then return nil end
            return setmetatable(target, metatable)
        end
        return target
    end

    local function decodeJson(value)
        if type(runtimeJsonDecode) ~= 'function' then
            error('Cfx JSON decoder is unavailable in this environment', 2)
        end
        return runtimeJsonDecode(value, 1, nil, decoderObjectMetatable, decoderArrayMetatable)
    end

    local function fallback(name)
        return function()
            error(('Cfx function %s is unavailable in this environment'):format(name), 2)
        end
    end

    local platform = {
        currentResource = overrides.currentResource or GetCurrentResourceName,
        invokingResource = overrides.invokingResource or GetInvokingResource,
        resourceState = overrides.resourceState or GetResourceState,
        resourceMetadata = overrides.resourceMetadata or GetResourceMetadata,
        numResources = overrides.numResources or GetNumResources,
        resourceByIndex = overrides.resourceByIndex or GetResourceByFindIndex,
        loadResourceFile = overrides.loadResourceFile or LoadResourceFile,
        addEventHandler = overrides.addEventHandler or AddEventHandler,
        registerNetEvent = overrides.registerNetEvent or RegisterNetEvent,
        removeEventHandler = overrides.removeEventHandler or RemoveEventHandler,
        triggerClientEvent = overrides.triggerClientEvent or TriggerClientEvent,
        triggerEvent = overrides.triggerEvent or TriggerEvent,
        registerCommand = overrides.registerCommand or RegisterCommand,
        getConvar = overrides.getConvar or GetConvar,
        getConvarInt = overrides.getConvarInt or GetConvarInt,
        getPlayerIdentifiers = overrides.getPlayerIdentifiers or GetPlayerIdentifiers,
        getPlayerName = overrides.getPlayerName or GetPlayerName,
        getPlayers = overrides.getPlayers or GetPlayers,
        isPlayerAceAllowed = overrides.isPlayerAceAllowed or IsPlayerAceAllowed,
        dropPlayer = overrides.dropPlayer or DropPlayer,
        cancelEvent = overrides.cancelEvent or CancelEvent or fallback('CancelEvent'),
        wait = overrides.wait or Wait,
        setTimeout = overrides.setTimeout or SetTimeout,
        createThread = overrides.createThread or (Citizen and Citizen.CreateThread or nil),
        nowGame = overrides.nowGame or GetGameTimer,
        jsonDecode = overrides.jsonDecode or decodeJson,
        jsonEncode = overrides.jsonEncode or function(value) return json.encode(value) end,
        jsonContainerKind = overrides.jsonContainerKind or jsonContainerKind,
        copyJsonContainerMetadata = overrides.copyJsonContainerMetadata
            or copyJsonContainerMetadata,
        print = overrides.print or print,
        random = overrides.random or math.random
    }

    platform.defer = overrides.defer or function()
        if Citizen and Citizen.Await and promise then
            local pending = promise.new()
            SetTimeout(0, function() pending:resolve(true) end)
            return Citizen.Await(pending)
        end
        return platform.wait(0)
    end

    platform.export = overrides.export or function(name, handler)
        if exports == nil then
            return fallback(('exports.%s'):format(name))()
        end
        exports(name, handler)
    end

    platform.onNet = overrides.onNet or function(name, handler)
        platform.registerNetEvent(name)
        return platform.addEventHandler(name, handler)
    end

    return platform
end
