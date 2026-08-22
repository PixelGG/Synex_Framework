local MATRIX = {
    apiVersion = '1.0.0',
    deprecated = true,
    preferredPath = 'native-synex-contracts',
    isolation = 'consumer-bound-capability-delegation',
    qb = {
        coreObject = 'partial', playerLookup = 'online-only', playerData = 'detached-snapshot',
        money = 'cash-bank-counterparty-transfer', groups = 'read-only-job-gang-projection',
        callbacks = 'bounded-bridge-transport', events = 'character-lifecycle-only',
    },
    qbx = {
        exports = 'partial', playerLookup = 'online-only', playerData = 'detached-snapshot',
        money = 'cash-bank-counterparty-transfer', groups = 'read-only-native-export-projection',
        callbacks = 'bounded-bridge-transport', events = 'character-lifecycle-only',
    },
    esx = {
        sharedObject = 'partial', xPlayer = 'detached-facade', accounts = 'money-bank-counterparty-transfer',
        jobs = 'read-only-group-projection', callbacks = 'bounded-bridge-transport',
        events = 'character-lifecycle-only',
    },
    unsupported = {
        'public-mutable-player-state', 'direct-sql', 'offline-player-mutation',
        'inventory', 'vehicles', 'items', 'arbitrary-account-types', 'authorization-equivalence',
    },
}

local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item, seen) end
    seen[value] = nil
    return result
end

exports('GetCompatibilityMatrix', function()
    return copy(MATRIX)
end)
