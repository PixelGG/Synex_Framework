local factories = assert(SynexCoreFactories, 'synex_core factories were not loaded')
local platform = factories.platform()

local function replicateState(definition, subject, snapshot)
    if definition.scope == 'global' then
        if type(GlobalState) ~= 'table' then
            return nil, { code = 'STATE_BAG_UNAVAILABLE', message = 'GlobalState is unavailable.' }
        end
        GlobalState[snapshot.name] = snapshot.value
        return true
    end
    if definition.scope == 'player' then
        local playerSource = tonumber(subject)
        if not playerSource or playerSource < 1 or playerSource % 1 ~= 0 or GetPlayerName(playerSource) == nil then
            return nil, { code = 'PLAYER_NOT_FOUND', message = 'The player state-bag target is unavailable.' }
        end
        local player = Player(playerSource)
        if not player or not player.state or type(player.state.set) ~= 'function' then
            return nil, { code = 'STATE_BAG_UNAVAILABLE', message = 'The player state bag is unavailable.' }
        end
        player.state:set(snapshot.name, snapshot.value, true)
        return true
    end
    return nil, { code = 'UNSUPPORTED_REPLICATION_SCOPE', message = 'The state scope is not replicated by synex_core.' }
end

local runtime = factories.bootstrap({ platform = platform, replicateState = replicateState })

local bound, bindError = runtime:bind()
if not bound then error(bindError and bindError.message or 'Synex Core could not bind runtime handlers.') end
local started, startError = runtime:start()
if not started then error(startError and startError.message or 'Synex Core failed to start.') end

SynexCoreFactories = nil
