local adapter = assert(SynexBridgeNative,
    'synex_bridge native server library is unavailable').create({
    framework = 'esx',
    capabilityPrefix = 'synex.compat.esx',
    requestEvent = 'synex_bridge_esx:server:callback',
    responseEvent = 'synex_bridge_esx:client:callback',
    historicalResource = 'es_extended',
    discoverAccountMappings = true,
})

local FACADE_RESOURCE = 'es_extended'
local MAX_EXTENDED_PLAYER_FILTERS = 32

local function bridgeError(code, message)
    return { code = code, message = message, retryable = false }
end

local function validConsumer(value)
    return type(value) == 'string' and #value >= 2 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

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

local function facadeConsumer(value)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(value) then
        return nil, bridgeError('COMPAT_CONSUMER_DENIED',
            'The compatibility facade did not provide an authenticated consumer.')
    end
    return value, nil
end

local function moneyType(accountName, snapshot)
    if type(accountName) ~= 'string' or #accountName < 1 or #accountName > 32 then
        return nil
    end
    local requested = accountName:lower()
    if not requested:match('^[a-z][a-z0-9_]*$') then return nil end
    local definitions = type(snapshot) == 'table'
        and type(snapshot.accountDefinitions) == 'table'
        and snapshot.accountDefinitions or {}
    local matched
    for alias, definition in pairs(definitions) do
        if type(alias) == 'string' and alias:match('^[a-z][a-z0-9_]*$')
            and type(definition) == 'table' then
            local legacyName = type(definition.legacyName) == 'string'
                and definition.legacyName or definition.name
            local aliasMatch = alias:lower() == requested
            local legacyMatch = type(legacyName) == 'string'
                and legacyName:lower() == requested
            if aliasMatch or legacyMatch then
                if matched ~= nil and matched ~= alias then
                    return nil, bridgeError('COMPAT_MAPPING_AMBIGUOUS',
                        'More than one reviewed ESX account mapping uses this legacy name.')
                end
                matched = alias
            end
        end
    end
    return matched, nil
end

local function primaryJob(snapshot)
    local memberships = type(snapshot.groups) == 'table'
        and type(snapshot.groups.items) == 'table' and snapshot.groups.items or {}
    for _, membership in ipairs(memberships) do
        local group = type(membership.group) == 'table' and membership.group or {}
        local grade = type(membership.grade) == 'table' and membership.grade or {}
        if group.type == 'job' and type(group.key) == 'string' then
            local projected = {
                name = group.key,
                label = type(group.label) == 'string' and group.label
                    or type(group.name) == 'string' and group.name or group.key,
                grade = type(grade.rank) == 'number' and grade.rank or 0,
                grade_name = type(grade.key) == 'string' and grade.key or 'none',
                grade_label = type(grade.name) == 'string' and grade.name or 'None',
                onDuty = type(membership.duty) == 'table'
                    and membership.duty.counts_as_on_duty == true or false,
            }
            if membership.is_primary == true then return projected end
        end
    end
    return {
        name = 'unemployed', label = 'Unemployed', grade = 0,
        grade_name = 'none', grade_label = 'None', onDuty = false,
    }
end

local function accounts(snapshot)
    local result = {}
    local money = type(snapshot.money) == 'table' and snapshot.money or {}
    local definitions = type(snapshot.accountDefinitions) == 'table'
        and snapshot.accountDefinitions or {}
    for alias, definition in pairs(definitions) do
        if type(alias) == 'string' and alias:match('^[a-z][a-z0-9_]*$')
            and type(definition) == 'table'
            and type(definition.name) == 'string'
            and type(definition.label) == 'string'
            and type(definition.round) == 'boolean'
            and type(money[alias]) == 'number' then
            result[#result + 1] = {
                name = definition.name,
                label = definition.label,
                money = money[alias],
                round = definition.round,
            }
        end
    end
    table.sort(result, function(left, right) return left.name < right.name end)
    return result
end

local function playerData(snapshot)
    local character = snapshot.character or {}
    return {
        source = snapshot.source,
        identifier = snapshot.identity and snapshot.identity.identifier or nil,
        name = ('%s %s'):format(character.firstName or '', character.lastName or ''),
        accounts = accounts(snapshot),
        job = primaryJob(snapshot),
        metadata = copy(snapshot.metadata or {}),
    }
end

local function xPlayerFor(consumer, snapshot)
    local fence, playerSource = copy(snapshot.fence), snapshot.source
    local player = {
        source = playerSource,
        identifier = snapshot.identity and snapshot.identity.identifier or nil,
        variables = {},
    }

    local function refresh()
        local current, currentError = adapter:readPlayerFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot = current
        player.identifier = current.identity and current.identity.identifier or nil
        return current, nil
    end

    local function refreshMoney()
        local current, currentError = adapter:readMoneyFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.money = current.money
        snapshot.accountDefinitions = current.accountDefinitions
        return snapshot, nil
    end

    local function refreshCustomAccounts()
        if type(adapter.readCustomAccountsFenced) ~= 'function' then
            return nil, bridgeError('COMPAT_API_UNSUPPORTED',
                'The reviewed ESX custom-account projection is unavailable.')
        end
        local current, currentError = adapter:readCustomAccountsFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.money = current.money
        snapshot.accountDefinitions = current.accountDefinitions
        return snapshot, nil
    end

    local function refreshMetadata()
        local current, currentError = adapter:readMetadataFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.metadata = copy(current.metadata or {})
        snapshot.metadataVersions = copy(current.metadataVersions or {})
        return snapshot, nil
    end

    local function unsupported(operation, message)
        local _, operationError = adapter:unsupported(consumer, operation, message)
        return operationError or bridgeError('COMPAT_API_UNSUPPORTED', message)
    end

    player.getIdentifier = function()
        local current, currentError = refresh()
        if not current then return nil, currentError end
        return player.identifier
    end
    player.getName = function()
        local current, currentError = refresh()
        if not current then return nil, currentError end
        local character = current.character or {}
        return ('%s %s'):format(character.firstName or '', character.lastName or '')
    end
    player.getJob = function()
        local current, currentError = adapter:readGroupsFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.groups = current.groups
        return primaryJob(snapshot)
    end
    player.getGroup = function()
        if type(adapter.readPermissionGroups) ~= 'function' then
            local operationError = unsupported('permissions.get_group',
                'The explicit Synex permission projection is unavailable.')
            return nil, operationError
        end
        local projected, projectionError = adapter:readPermissionGroups(
            consumer, playerSource, fence)
        if not projected then return nil, projectionError end
        return projected.primary, nil
    end
    player.getMoney = function()
        local current, currentError = refreshMoney()
        return current and (current.money.cash or 0) or nil, currentError
    end
    player.getAccount = function(accountName)
        local current, currentError = refreshCustomAccounts()
        if not current then return nil, currentError end
        local mapped, mappingError = moneyType(accountName, current)
        if not mapped then
            if mappingError then return nil, mappingError end
            local operationError = unsupported('accounts.custom',
                'No reviewed ESX account mapping exists for this account name.')
            return nil, operationError
        end
        local definition = current.accountDefinitions[mapped]
        return {
            name = definition.name,
            label = definition.label,
            money = current.money[mapped],
            round = definition.round,
        }
    end
    player.getAccounts = function(minimal)
        local current, currentError = refreshCustomAccounts()
        if not current then return nil, currentError end
        local projected = accounts(current)
        if minimal == true then
            local result = {}
            for _, account in ipairs(projected) do
                result[account.name] = account.money
            end
            return result
        end
        return projected
    end
    player.addMoney = function(amount, reason)
        return adapter:changeMoney(
            consumer, playerSource, 'cash', 'add', amount, reason, fence)
    end
    player.removeMoney = function(amount, reason)
        return adapter:changeMoney(
            consumer, playerSource, 'cash', 'remove', amount, reason, fence)
    end
    player.setMoney = function(amount, reason)
        return adapter:setMoney(consumer, playerSource, 'cash', amount, reason, fence)
    end
    player.addAccountMoney = function(accountName, amount, reason)
        local mapped, mappingError = moneyType(accountName, snapshot)
        if not mapped then
            if mappingError then return false, mappingError end
            local operationError = unsupported('accounts.custom',
                'No reviewed ESX account mapping exists for this account name.')
            return false, operationError
        end
        return adapter:changeMoney(
            consumer, playerSource, mapped, 'add', amount, reason, fence)
    end
    player.removeAccountMoney = function(accountName, amount, reason)
        local mapped, mappingError = moneyType(accountName, snapshot)
        if not mapped then
            if mappingError then return false, mappingError end
            local operationError = unsupported('accounts.custom',
                'No reviewed ESX account mapping exists for this account name.')
            return false, operationError
        end
        return adapter:changeMoney(
            consumer, playerSource, mapped, 'remove', amount, reason, fence)
    end
    player.setAccountMoney = function(accountName, amount, reason)
        local mapped, mappingError = moneyType(accountName, snapshot)
        if not mapped then
            if mappingError then return false, mappingError end
            local operationError = unsupported('accounts.custom',
                'No reviewed ESX account mapping exists for this account name.')
            return false, operationError
        end
        return adapter:setMoney(consumer, playerSource, mapped, amount, reason, fence)
    end
    player.getMeta = function(key)
        local current, currentError = refreshMetadata()
        if not current then return nil, currentError end
        return current.metadata and current.metadata[key] or nil
    end
    player.setMeta = function(key, value)
        local expectedVersion = snapshot.metadataVersions
            and snapshot.metadataVersions[key] or nil
        return adapter:setMetadata(
            consumer, playerSource, key, value, fence, expectedVersion)
    end
    player.setJob = function(name, grade, onDuty)
        if onDuty ~= nil then
            local operationError = unsupported('job.set_with_duty',
                'Combined ESX job and duty mutation has no atomic Synex primitive.')
            return false, operationError
        end
        local changed, changeError = adapter:setGroup(
            consumer, playerSource, 'job', name, grade,
            'compatibility_mapping', fence)
        return changed == true, changeError
    end
    return player
end

-- A global lifecycle event has no per-listener caller identity. Publish only
-- detached data here; privileged xPlayer functions stay behind authenticated
-- exports where the immediate invoking resource can be checked.
local function lifecyclePlayer(playerDataValue)
    local projected = copy(playerDataValue)
    projected.variables = {}
    return projected
end

local function getPlayer(consumer, playerSource)
    local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    return xPlayerFor(consumer, snapshot), nil
end

local function getPlayerByIdentifier(consumer, identifier)
    local snapshot, snapshotError = adapter:readPlayerByIdentifier(
        consumer, identifier)
    if not snapshot then return nil, snapshotError end
    return xPlayerFor(consumer, snapshot), nil
end

local function getPlayerIdByIdentifier(consumer, identifier)
    local snapshot, snapshotError = adapter:readPlayerByIdentifier(
        consumer, identifier)
    if not snapshot then return nil, snapshotError end
    return snapshot.source, nil
end

local function getPlayers(consumer)
    return adapter:listPlayerSources(consumer)
end

local function validFilterValue(key, value)
    if type(value) ~= 'string' or #value < 1 then return false end
    if key == 'identifier' then
        return #value <= 191 and value:find('%c') == nil
    end
    return #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function normalizeExtendedFilter(key, value)
    if key ~= 'identifier' and key ~= 'job' then
        return nil, bridgeError('COMPAT_API_UNSUPPORTED',
            'ESX extended-player enumeration supports only identifier or job filters.')
    end
    if type(value) == 'string' then
        if not validFilterValue(key, value) then
            return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
                'The ESX extended-player filter value is invalid.')
        end
        return { values = { value }, grouped = false }, nil
    end
    if type(value) ~= 'table' or getmetatable(value) ~= nil then
        return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
            'The ESX extended-player filter must be a string or dense string array.')
    end
    local count, highest = 0, 0
    for index in pairs(value) do
        if type(index) ~= 'number' or index % 1 ~= 0 or index < 1
            or index > MAX_EXTENDED_PLAYER_FILTERS then
            return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
                'The ESX extended-player filter must be a bounded dense array.')
        end
        count = count + 1
        if index > highest then highest = index end
    end
    if count < 1 or count > MAX_EXTENDED_PLAYER_FILTERS or highest ~= count then
        return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
            'The ESX extended-player filter must contain 1 through 32 values.')
    end
    local values, seen = {}, {}
    for index = 1, count do
        local item = value[index]
        if not validFilterValue(key, item) or seen[item] then
            return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
                'The ESX extended-player filter contains an invalid or duplicate value.')
        end
        seen[item] = true
        values[index] = item
    end
    return { values = values, grouped = true }, nil
end

local function getExtendedPlayers(consumer, key, value, minimal)
    if minimal ~= nil and type(minimal) ~= 'boolean' then
        return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
            'The ESX extended-player minimal flag must be boolean.')
    end
    local filter
    if key ~= nil then
        local filterError
        filter, filterError = normalizeExtendedFilter(key, value)
        if not filter then return nil, filterError end
    elseif value ~= nil then
        return nil, bridgeError('COMPAT_ARGUMENT_INVALID',
            'An ESX extended-player filter value requires a filter key.')
    end

    local sources, sourcesError = adapter:listPlayerSources(consumer)
    if not sources then return nil, sourcesError end
    if not filter and minimal == true then return sources, nil end

    local result = {}
    if filter and filter.grouped then
        for _, expected in ipairs(filter.values) do result[expected] = {} end
    end
    local expected = {}
    if filter then
        for _, item in ipairs(filter.values) do expected[item] = true end
    end

    for _, playerSource in ipairs(sources) do
        local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
        if not snapshot then return nil, snapshotError end
        local matched
        if not filter then
            matched = true
        elseif key == 'identifier' then
            local identifier = type(snapshot.identity) == 'table'
                and snapshot.identity.identifier or nil
            matched = expected[identifier] and identifier or nil
        else
            local job = primaryJob(snapshot).name
            matched = expected[job] and job or nil
        end
        if matched then
            local projected = minimal == true and playerSource
                or xPlayerFor(consumer, snapshot)
            if filter and filter.grouped then
                local bucket = result[matched]
                bucket[#bucket + 1] = projected
            else
                result[#result + 1] = projected
            end
        end
    end
    return result, nil
end

local function sharedObjectFor(consumer)
    local authorization, authorizationError = adapter:authorize(
        consumer, 'read', 'shared_object.read')
    if not authorization then return nil, authorizationError end
    return adapter:trace(authorization, consumer, 'getSharedObject', function()
        return {
            GetPlayerFromId = function(playerSource)
                return getPlayer(consumer, playerSource)
            end,
            GetPlayerFromIdentifier = function(identifier)
                return getPlayerByIdentifier(consumer, identifier)
            end,
            GetPlayerIdFromIdentifier = function(identifier)
                return getPlayerIdByIdentifier(consumer, identifier)
            end,
            GetPlayers = function()
                return getPlayers(consumer)
            end,
            GetExtendedPlayers = function(key, value, minimal)
                return getExtendedPlayers(consumer, key, value, minimal)
            end,
            RegisterServerCallback = function(name, handler)
                return adapter:registerCallback(consumer, name, handler)
            end,
        }, nil
    end)
end

local function invokeCompatibilityAdapter(consumer, request)
    return adapter:invokeCompatibilityAdapter(consumer, request)
end

local function compatibilityCatalog(action, consumer, request)
    local called, value, operationError = pcall(function()
        if action == 'resolve' then
            return exports.synex_bridge:ResolveCompatibilityCatalog(consumer, request)
        end
        return exports.synex_bridge:InvokeCompatibilityCatalog(consumer, request)
    end)
    if not called then
        return nil, bridgeError('COMPAT_BRIDGE_UNAVAILABLE',
            'The compatibility catalog service is unavailable.')
    end
    if value == false or value == nil then
        if type(operationError) == 'table' then return nil, operationError end
        return nil, bridgeError('COMPAT_RESOLUTION_FAILED',
            'The compatibility catalog operation did not return a result.')
    end
    return value, operationError
end

exports('getSharedObject', function() return sharedObjectFor(GetInvokingResource()) end)
exports('GetPlayerFromId', function(playerSource)
    return getPlayer(GetInvokingResource(), playerSource)
end)
exports('GetPlayerFromIdentifier', function(identifier)
    return getPlayerByIdentifier(GetInvokingResource(), identifier)
end)
exports('GetPlayerIdFromIdentifier', function(identifier)
    return getPlayerIdByIdentifier(GetInvokingResource(), identifier)
end)
exports('GetPlayers', function()
    return getPlayers(GetInvokingResource())
end)
exports('GetExtendedPlayers', function(key, value, minimal)
    return getExtendedPlayers(GetInvokingResource(), key, value, minimal)
end)
exports('RegisterServerCallback', function(name, handler)
    return adapter:registerCallback(GetInvokingResource(), name, handler)
end)
exports('InvokeCompatibilityAdapter', function(request)
    return invokeCompatibilityAdapter(GetInvokingResource(), request)
end)
exports('ResolveCompatibilityCatalog', function(request)
    return compatibilityCatalog('resolve', GetInvokingResource(), request)
end)
exports('InvokeCompatibilityCatalog', function(request)
    return compatibilityCatalog('invoke', GetInvokingResource(), request)
end)
exports('GetSharedObjectForConsumer', function(consumer)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return sharedObjectFor(authenticated)
end)
exports('GetPlayerFromIdForConsumer', function(consumer, playerSource)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return getPlayer(authenticated, playerSource)
end)
exports('GetPlayerFromIdentifierForConsumer', function(consumer, identifier)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return getPlayerByIdentifier(authenticated, identifier)
end)
exports('GetPlayerIdFromIdentifierForConsumer', function(consumer, identifier)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return getPlayerIdByIdentifier(authenticated, identifier)
end)
exports('GetPlayersForConsumer', function(consumer)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return getPlayers(authenticated)
end)
exports('GetExtendedPlayersForConsumer', function(consumer, key, value, minimal)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return getExtendedPlayers(authenticated, key, value, minimal)
end)
exports('RegisterServerCallbackForConsumer', function(consumer, name, handler)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return adapter:registerCallback(authenticated, name, handler)
end)
exports('InvokeCompatibilityAdapterForConsumer', function(consumer, request)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return invokeCompatibilityAdapter(authenticated, request)
end)
exports('ResolveCompatibilityCatalogForConsumer', function(consumer, request)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return compatibilityCatalog('resolve', authenticated, request)
end)
exports('InvokeCompatibilityCatalogForConsumer', function(consumer, request)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return compatibilityCatalog('invoke', authenticated, request)
end)
exports('GetCompatibilityUsage', function()
    local consumer = GetInvokingResource()
    local authorization, authorizationError = adapter:authorize(
        consumer, 'read', 'telemetry.read')
    if not authorization then return nil, authorizationError end
    return adapter:trace(authorization, consumer, 'GetCompatibilityUsage',
        function() return copy(adapter:usageSnapshot(consumer)), nil end)
end)

local CLIENT_PROJECTION_EVENT = 'synex_bridge_esx:client:projection'

local function publishClientProjection(context, playerDataValue)
    local access = type(context.publication) == 'table'
        and context.publication.clientAccess or nil
    local playerDataConsumers = type(access) == 'table' and access.playerData or nil
    local notificationConsumers = type(access) == 'table'
        and access.notifications or nil
    if notificationConsumers == nil then notificationConsumers = {} end
    if type(playerDataConsumers) == 'table'
        and type(notificationConsumers) == 'table'
        and (next(playerDataConsumers) ~= nil
            or next(notificationConsumers) ~= nil) then
        TriggerClientEvent(CLIENT_PROJECTION_EVENT, context.source,
            'replace', copy(playerDataValue), copy(access))
    else
        TriggerClientEvent(CLIENT_PROJECTION_EVENT, context.source, 'clear')
    end
end

local function sameValue(left, right, seen)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not sameValue(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function ownsEsxFamily(context)
    return type(context.publication) == 'table'
        and type(context.publication.families) == 'table'
        and context.publication.families.esx == true
end

local function publishesSurface(context, surface)
    return ownsEsxFamily(context)
        and type(context.publication.surfaces) == 'table'
        and context.publication.surfaces[surface] == true
end

local function accountsByName(player)
    local mapped = {}
    for _, account in ipairs(type(player.accounts) == 'table' and player.accounts or {}) do
        if type(account) == 'table' and type(account.name) == 'string'
            and type(account.money) == 'number' then
            mapped[account.name] = account
        end
    end
    return mapped
end

local function publishAccountChanges(playerSource, previous, current)
    local before, after = accountsByName(previous), accountsByName(current)
    local names = {}
    for name in pairs(before) do names[name] = true end
    for name in pairs(after) do names[name] = true end
    local ordered = {}
    for name in pairs(names) do ordered[#ordered + 1] = name end
    table.sort(ordered)
    for _, name in ipairs(ordered) do
        local oldAccount, newAccount = before[name], after[name]
        if oldAccount and newAccount and oldAccount.money ~= newAccount.money then
            local delta = newAccount.money - oldAccount.money
            TriggerClientEvent('esx:setAccountMoney', playerSource, copy(newAccount))
            if delta > 0 then
                TriggerEvent('esx:addAccountMoney', playerSource, name,
                    delta, 'synex_projection')
            else
                TriggerEvent('esx:removeAccountMoney', playerSource, name,
                    math.abs(delta), 'synex_projection')
            end
        end
    end
end

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    loaded = function(context)
        publishClientProjection(context, context.playerData)
        if context.resync == true then return true end
        if not ownsEsxFamily(context) then return true end
        -- Synex cannot truthfully infer whether the authoritative character was
        -- just created, so the compatibility lifecycle takes the conservative
        -- existing-character branch (`isNew = false`) and provides no fake skin.
        TriggerEvent('esx:playerLoaded', context.source,
            lifecyclePlayer(context.playerData), false)
        TriggerClientEvent('esx:playerLoaded', context.source,
            copy(context.playerData), false, nil)
        return true
    end,
    updated = function(context)
        local previous, current = context.previousPlayerData, context.playerData
        publishClientProjection(context, current)
        if not ownsEsxFamily(context) then return true end
        if not sameValue(previous.job, current.job)
            and publishesSurface(context, 'esx.shared.job_update_events') then
            TriggerEvent('esx:setJob', context.source,
                copy(current.job), copy(previous.job))
            TriggerClientEvent('esx:setJob', context.source,
                copy(current.job), copy(previous.job))
        end
        if publishesSurface(context, 'esx.shared.account_update_events') then
            publishAccountChanges(context.source, previous, current)
        end
        return true
    end,
    unloaded = function(context)
        TriggerClientEvent(CLIENT_PROJECTION_EVENT, context.source, 'clear')
        if not ownsEsxFamily(context) then return true end
        TriggerEvent('esx:playerLogout', context.source, function() end)
        TriggerClientEvent('esx:onPlayerLogout', context.source)
        return true
    end,
})
if not lifecycleToken then
    error(('ESX bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'))
end
