local adapter = assert(SynexBridgeNative,
    'synex_bridge native server library is unavailable').create({
    framework = 'qb',
    capabilityPrefix = 'synex.compat.qb',
    requestEvent = 'synex_bridge_qb:server:callback',
    responseEvent = 'synex_bridge_qb:client:callback',
    historicalResource = 'qb-core',
    moneyAliases = { 'cash', 'bank' },
})

local FACADE_RESOURCE = 'qb-core'

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

local function filterCoreObject(object, filters)
    if filters == nil then return object, nil end
    if type(filters) ~= 'table' or #filters > 8 then
        return nil, bridgeError('COMPAT_DTO_INVALID',
            'QBCore object filters must be a bounded dense array.')
    end
    local count, seen = 0, {}
    for key, value in pairs(filters) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > #filters or type(value) ~= 'string'
            or #value < 1 or #value > 32 or seen[value] then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'QBCore object filters are invalid.')
        end
        count, seen[value] = count + 1, true
    end
    if count ~= #filters then
        return nil, bridgeError('COMPAT_DTO_INVALID',
            'QBCore object filters must be dense.')
    end
    local filtered = {}
    for _, name in ipairs(filters) do
        if object[name] ~= nil then filtered[name] = object[name] end
    end
    return filtered, nil
end

local function facadeConsumer(value)
    if GetInvokingResource() ~= FACADE_RESOURCE or not validConsumer(value) then
        return nil, bridgeError('COMPAT_CONSUMER_DENIED',
            'The compatibility facade did not provide an authenticated consumer.')
    end
    return value, nil
end

local function groupItems(snapshot)
    return type(snapshot.groups) == 'table' and type(snapshot.groups.items) == 'table'
        and snapshot.groups.items or {}
end

local function gradeFor(membership)
    local grade = type(membership.grade) == 'table' and membership.grade or {}
    return {
        name = type(grade.key) == 'string' and grade.key or 'none',
        level = type(grade.rank) == 'number' and grade.rank or 0,
        label = type(grade.name) == 'string' and grade.name or 'None',
    }
end

local function groupFor(membership, duty)
    local group = type(membership.group) == 'table' and membership.group or {}
    return {
        name = type(group.key) == 'string' and group.key or 'none',
        label = type(group.label) == 'string' and group.label
            or type(group.name) == 'string' and group.name or 'None',
        grade = gradeFor(membership),
        onduty = duty == true and type(membership.duty) == 'table'
            and membership.duty.counts_as_on_duty == true or false,
        isboss = membership.compatibility_is_boss == true,
    }
end

local function connectedPlayerName(playerSource)
    if type(GetPlayerName) ~= 'function' then return nil end
    local read, name = pcall(GetPlayerName, tostring(playerSource))
    if not read or type(name) ~= 'string' or #name < 1 or #name > 128
        or name:find('[%z\1-\31\127]') then return nil end
    return name
end

local function playerData(snapshot)
    local job = {
        name = 'unemployed', label = 'Unemployed', grade = gradeFor({}),
        onduty = false, isboss = false,
    }
    local gang = {
        name = 'none', label = 'None', grade = gradeFor({}), isboss = false,
    }
    for _, membership in ipairs(groupItems(snapshot)) do
        local group = type(membership.group) == 'table' and membership.group or {}
        if group.type == 'job' then
            local projected = groupFor(membership, true)
            if membership.is_primary == true then job = projected end
        elseif group.type == 'gang' or group.type == 'group' then
            local projected = groupFor(membership, false)
            projected.onduty = nil
            if membership.is_primary == true then gang = projected end
        end
    end
    local character = snapshot.character or {}
    return {
        source = snapshot.source,
        citizenid = snapshot.identity and snapshot.identity.identifier or nil,
        cid = character.slot,
        name = connectedPlayerName(snapshot.source),
        charinfo = {
            firstname = character.firstName or '',
            lastname = character.lastName or '',
            birthdate = character.dateOfBirth,
        },
        money = {
            cash = snapshot.money and snapshot.money.cash or 0,
            bank = snapshot.money and snapshot.money.bank or 0,
        },
        job = job,
        gang = gang,
        metadata = copy(snapshot.metadata or {}),
    }
end

local function makePlayer(consumer, snapshot)
    local fence = copy(snapshot.fence)
    local playerSource = snapshot.source
    local player = { PlayerData = playerData(snapshot), Offline = false }

    local function refresh()
        local current, currentError = adapter:readPlayerFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot = current
        player.PlayerData = playerData(current)
        return current, nil
    end

    local function refreshMoney()
        local current, currentError = adapter:readMoneyFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.money = copy(current.money or {})
        player.PlayerData.money = copy(current.money or {})
        return current, nil
    end

    local function refreshGroups()
        local current, currentError = adapter:readGroupsFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.groups = copy(current.groups)
        snapshot.identity = copy(current.identity)
        snapshot.fence = copy(current.fence)
        snapshot.revision = current.revision
        player.PlayerData = playerData(snapshot)
        return current, nil
    end

    local function refreshMetadata()
        local current, currentError = adapter:readMetadataFenced(
            consumer, playerSource, fence)
        if not current then return nil, currentError end
        snapshot.metadata = copy(current.metadata or {})
        snapshot.metadataVersions = copy(current.metadataVersions or {})
        player.PlayerData.metadata = copy(current.metadata or {})
        return current, nil
    end

    player.Functions = {
        GetPlayerData = function()
            local current, currentError = refresh()
            if not current then return nil, currentError end
            return copy(player.PlayerData), nil
        end,
        GetName = function()
            local current, currentError = refresh()
            if not current then return nil, currentError end
            return ('%s %s'):format(
                player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname)
        end,
        GetMoney = function(moneyType)
            if moneyType ~= 'cash' and moneyType ~= 'bank' then return false end
            local current, currentError = refreshMoney()
            if not current then return nil, currentError end
            return current.money[moneyType] or 0
        end,
        AddMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:changeMoney(
                consumer, playerSource, moneyType, 'add', amount, reason, fence)
            if changed then refreshMoney() end
            return changed == true, changeError
        end,
        RemoveMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:changeMoney(
                consumer, playerSource, moneyType, 'remove', amount, reason, fence)
            if changed then refreshMoney() end
            return changed == true, changeError
        end,
        SetMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:setMoney(
                consumer, playerSource, moneyType, amount, reason, fence)
            if changed then refreshMoney() end
            return changed == true, changeError
        end,
        GetMetaData = function(key)
            local current, currentError = refreshMetadata()
            if not current then return nil, currentError end
            return current.metadata and current.metadata[key] or nil
        end,
        SetMetaData = function(key, value)
            local expectedVersion = snapshot.metadataVersions
                and snapshot.metadataVersions[key] or nil
            local changed, changeError = adapter:setMetadata(
                consumer, playerSource, key, value, fence, expectedVersion)
            if changed then refreshMetadata() end
            return changed ~= nil, changeError
        end,
        UpdatePlayerData = function()
            local current, currentError = refresh()
            return current ~= nil, currentError
        end,
        SetJob = function(name, grade)
            local changed, changeError = adapter:setGroup(
                consumer, playerSource, 'job', name, grade,
                'compatibility_mapping', fence)
            if changed then refreshGroups() end
            return changed == true, changeError
        end,
        SetGang = function(name, grade)
            local changed, changeError = adapter:setGroup(
                consumer, playerSource, 'gang', name, grade,
                'compatibility_mapping', fence)
            if changed then refreshGroups() end
            return changed == true, changeError
        end,
        SetJobDuty = function(onDuty)
            local changed, changeError = adapter:setDuty(
                consumer, playerSource, onDuty, 'compatibility_duty', fence)
            if changed then refreshGroups() end
            return changed == true, changeError
        end,
    }
    return player
end

-- Global server events cannot authenticate the resource that receives their
-- payload. Never attach consumer-bound functions to a broadcast value: doing
-- so would let an unrelated listener reuse the selected consumer's grants.
local function lifecyclePlayer(playerDataValue)
    return {
        PlayerData = copy(playerDataValue),
        Offline = false,
    }
end

local function playerByCitizenIdFor(consumer, citizenId)
    if type(adapter.readPlayerByIdentifier) ~= 'function' then
        return adapter:unsupported(consumer,
            'qb.server.identifier_player_lookup',
            'Online citizen identifier lookup is unavailable.')
    end
    local snapshot, snapshotError = adapter:readPlayerByIdentifier(
        consumer, citizenId)
    if snapshot == false then return nil, nil end
    if not snapshot then return nil, snapshotError end
    return makePlayer(consumer, snapshot), nil
end

local function playerSourcesFor(consumer)
    if type(adapter.listPlayerSources) ~= 'function' then
        return adapter:unsupported(consumer, 'qb.server.player_enumeration',
            'Online player enumeration is unavailable.')
    end
    local sources, sourcesError = adapter:listPlayerSources(consumer)
    if not sources then return nil, sourcesError end
    return copy(sources), nil
end

local function qbPlayersFor(consumer)
    local sources, sourcesError = playerSourcesFor(consumer)
    if not sources then return nil, sourcesError end
    local players = {}
    for _, playerSource in ipairs(sources) do
        local snapshot, snapshotError = adapter:readPlayer(
            consumer, playerSource)
        if not snapshot then return nil, snapshotError end
        players[playerSource] = makePlayer(consumer, snapshot)
    end
    return players, nil
end

local function permissionProjectionFor(consumer, playerSource)
    if type(adapter.readPermissionGroups) ~= 'function' then
        return adapter:unsupported(consumer, 'qb.server.permission_view',
            'The explicit Synex permission projection is unavailable.')
    end
    local projected, projectionError = adapter:readPermissionGroups(
        consumer, playerSource)
    if not projected then return nil, projectionError end
    if type(projected.groups) ~= 'table' or getmetatable(projected.groups) ~= nil
        or type(projected.fallback) ~= 'string'
        or #projected.fallback < 1 or #projected.fallback > 64
        or not projected.fallback:match('^[a-z][a-z0-9_.%-]*$')
        or type(projected.primary) ~= 'string'
        or #projected.primary < 1 or #projected.primary > 64
        or not projected.primary:match('^[a-z][a-z0-9_.%-]*$')
        or #projected.groups > 128 then
        return nil, bridgeError('COMPAT_PERMISSION_MAPPING_INVALID',
            'The compatibility permission projection is invalid.')
    end
    local groups, seen = {}, {}
    for key, value in pairs(projected.groups) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > #projected.groups or type(value) ~= 'string'
            or #value < 1 or #value > 64 or seen[value] then
            return nil, bridgeError('COMPAT_PERMISSION_MAPPING_INVALID',
                'The compatibility permission projection is invalid.')
        end
        seen[value], groups[value] = true, true
    end
    if #projected.groups ~= 0 then
        local count = 0
        for _ in pairs(seen) do count = count + 1 end
        if count ~= #projected.groups then
            return nil, bridgeError('COMPAT_PERMISSION_MAPPING_INVALID',
                'The compatibility permission projection must be dense.')
        end
    end
    groups[projected.fallback] = true
    return groups, nil
end

local function permissionNames(value)
    if type(value) == 'string' then
        if #value < 1 or #value > 64
            or not value:match('^[a-z][a-z0-9_.%-]*$') then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'The QBCore permission name is invalid.')
        end
        return { value }, nil
    end
    if type(value) ~= 'table' or getmetatable(value) ~= nil or #value > 32 then
        return nil, bridgeError('COMPAT_DTO_INVALID',
            'QBCore permission filters must be a bounded dense array.')
    end
    local names, seen, count = {}, {}, 0
    for key, name in pairs(value) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer'
            or key < 1 or key > #value or type(name) ~= 'string'
            or #name < 1 or #name > 64
            or not name:match('^[a-z][a-z0-9_.%-]*$') or seen[name] then
            return nil, bridgeError('COMPAT_DTO_INVALID',
                'QBCore permission filters are invalid.')
        end
        count, seen[name], names[key] = count + 1, true, name
    end
    if count ~= #value or count < 1 then
        return nil, bridgeError('COMPAT_DTO_INVALID',
            'QBCore permission filters must be a non-empty dense array.')
    end
    return names, nil
end

local function coreObjectFor(consumer, filters)
    local authorization, authorizationError = adapter:authorize(
        consumer, 'read', 'core_object.read')
    if not authorization then return nil, authorizationError end
    if filters ~= nil then
        authorization, authorizationError = adapter:authorize(
            consumer, 'read', 'core_object.filter')
        if not authorization then return nil, authorizationError end
    end
    return adapter:trace(authorization, consumer, 'GetCoreObject', function()
        local object = {
            Functions = {
                GetPlayer = function(playerSource)
                    local snapshot, snapshotError = adapter:readPlayer(
                        consumer, playerSource)
                    if not snapshot then return nil, snapshotError end
                    return makePlayer(consumer, snapshot)
                end,
                GetPlayerByCitizenId = function(citizenId)
                    return playerByCitizenIdFor(consumer, citizenId)
                end,
                GetPlayers = function()
                    return playerSourcesFor(consumer)
                end,
                GetQBPlayers = function()
                    return qbPlayersFor(consumer)
                end,
                HasPermission = function(playerSource, permission)
                    local names, namesError = permissionNames(permission)
                    if not names then return false, namesError end
                    local projected, projectionError = permissionProjectionFor(
                        consumer, playerSource)
                    if not projected then return false, projectionError end
                    for _, name in ipairs(names) do
                        if projected[name] == true then return true, nil end
                    end
                    return false, nil
                end,
                GetPermission = function(playerSource)
                    local projected, projectionError = permissionProjectionFor(
                        consumer, playerSource)
                    if not projected then return nil, projectionError end
                    return copy(projected), nil
                end,
                CreateCallback = function(name, handler)
                    return adapter:registerCallback(consumer, name, handler)
                end,
            },
        }
        return filterCoreObject(object, filters)
    end)
end

local function playerFor(consumer, playerSource)
    local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    return makePlayer(consumer, snapshot), nil
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

exports('GetCoreObject', function(filters)
    return coreObjectFor(GetInvokingResource(), filters)
end)
exports('GetPlayer', function(playerSource)
    return playerFor(GetInvokingResource(), playerSource)
end)
exports('GetPlayerByCitizenId', function(citizenId)
    return playerByCitizenIdFor(GetInvokingResource(), citizenId)
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
exports('GetCoreObjectForConsumer', function(consumer, filters)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return coreObjectFor(authenticated, filters)
end)
exports('GetPlayerForConsumer', function(consumer, playerSource)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return playerFor(authenticated, playerSource)
end)
exports('GetPlayerByCitizenIdForConsumer', function(consumer, citizenId)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return playerByCitizenIdFor(authenticated, citizenId)
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

local CLIENT_PROJECTION_EVENT = 'synex_bridge_qb:client:projection'

local function publishClientProjection(context, playerDataValue)
    local access = type(context.publication) == 'table'
        and context.publication.clientAccess or nil
    local playerDataConsumers = type(access) == 'table' and access.playerData or nil
    if type(playerDataConsumers) == 'table' and next(playerDataConsumers) ~= nil then
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

local function ownsQbFamily(context)
    return type(context.publication) == 'table'
        and type(context.publication.families) == 'table'
        and context.publication.families.qbc == true
end

local function publishesSurface(context, surface)
    return ownsQbFamily(context)
        and type(context.publication.surfaces) == 'table'
        and context.publication.surfaces[surface] == true
end

local function publishMoneyChanges(playerSource, previous, current)
    local previousMoney = type(previous.money) == 'table' and previous.money or {}
    local currentMoney = type(current.money) == 'table' and current.money or {}
    for _, moneyType in ipairs({ 'bank', 'cash' }) do
        local oldValue, newValue = previousMoney[moneyType], currentMoney[moneyType]
        if type(oldValue) == 'number' and type(newValue) == 'number'
            and oldValue ~= newValue then
            local action = newValue > oldValue and 'add' or 'remove'
            local amount = math.abs(newValue - oldValue)
            TriggerClientEvent('QBCore:Client:OnMoneyChange', playerSource,
                moneyType, amount, action, 'synex_projection')
            TriggerEvent('QBCore:Server:OnMoneyChange', playerSource,
                moneyType, amount, action, 'synex_projection')
        end
    end
end

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    loaded = function(context)
        publishClientProjection(context, context.playerData)
        if context.resync == true then return true end
        if not ownsQbFamily(context) then return true end
        TriggerEvent('QBCore:Server:PlayerLoaded',
            lifecyclePlayer(context.playerData))
        TriggerEvent('QBCore:Player:SetPlayerData', copy(context.playerData))
        TriggerEvent('QBCore:Server:OnPlayerUpdated', context.source,
            'all', copy(context.playerData))
        TriggerClientEvent('QBCore:Client:OnPlayerUpdated', context.source,
            'all', copy(context.playerData))
        TriggerClientEvent('QBCore:Client:OnPlayerLoaded', context.source)
        return true
    end,
    updated = function(context)
        local previous, current = context.previousPlayerData, context.playerData
        publishClientProjection(context, current)
        if not ownsQbFamily(context) then return true end
        local jobChanged = not sameValue(previous.job, current.job)
        local previousJob = type(previous.job) == 'table' and previous.job or {}
        local currentJob = type(current.job) == 'table' and current.job or {}
        local dutyOnly = jobChanged and previousJob.onduty ~= currentJob.onduty
            and previousJob.name == currentJob.name
            and sameValue(previousJob.grade, currentJob.grade)
        local jobSurface = dutyOnly and 'qb.shared.duty_update_events'
            or 'qb.shared.job_update_events'
        if jobChanged and publishesSurface(context, jobSurface) then
            TriggerEvent('QBCore:Server:OnPlayerUpdated', context.source,
                'job', copy(current.job))
            TriggerClientEvent('QBCore:Client:OnPlayerUpdated', context.source,
                'job', copy(current.job))
            TriggerEvent('QBCore:Server:OnJobUpdate', context.source,
                copy(current.job))
            TriggerClientEvent('QBCore:Client:OnJobUpdate', context.source,
                copy(current.job))
        end
        if not sameValue(previous.gang, current.gang)
            and publishesSurface(context, 'qb.shared.gang_update_events') then
            TriggerEvent('QBCore:Server:OnPlayerUpdated', context.source,
                'gang', copy(current.gang))
            TriggerClientEvent('QBCore:Client:OnPlayerUpdated', context.source,
                'gang', copy(current.gang))
            TriggerEvent('QBCore:Server:OnGangUpdate', context.source,
                copy(current.gang))
            TriggerClientEvent('QBCore:Client:OnGangUpdate', context.source,
                copy(current.gang))
        end
        local moneyChanged = not sameValue(previous.money, current.money)
        if moneyChanged
            and publishesSurface(context, 'qb.shared.money_update_events') then
            TriggerEvent('QBCore:Server:OnPlayerUpdated', context.source,
                'money', copy(current.money))
            TriggerClientEvent('QBCore:Client:OnPlayerUpdated', context.source,
                'money', copy(current.money))
        end
        if moneyChanged
            and publishesSurface(context, 'qb.shared.money_update_events') then
            publishMoneyChanges(context.source, previous, current)
        end
        return true
    end,
    unloaded = function(context)
        TriggerClientEvent(CLIENT_PROJECTION_EVENT, context.source, 'clear')
        if not ownsQbFamily(context) then return true end
        TriggerClientEvent('QBCore:Client:OnPlayerUnload', context.source)
        TriggerEvent('QBCore:Server:OnPlayerUnload', context.source)
        return true
    end,
})
if not lifecycleToken then
    error(('QBCore bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'))
end
