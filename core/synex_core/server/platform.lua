local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.platform = function(overrides)
    overrides = overrides or {}

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
        nowGame = overrides.nowGame or GetGameTimer,
        jsonDecode = overrides.jsonDecode or function(value) return json.decode(value) end,
        jsonEncode = overrides.jsonEncode or function(value) return json.encode(value) end,
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
