local adapter = assert(SynexBridgeNative,
    'synex_bridge native server library is unavailable').create({
    framework = 'qbx',
    capabilityPrefix = 'synex.compat.qbx',
    requestEvent = 'synex_bridge_qbx:server:callback',
    responseEvent = 'synex_bridge_qbx:client:callback',
    historicalResource = 'qbx_core',
    moneyAliases = { 'cash', 'bank' },
})

local FACADE_RESOURCE = 'qbx_core'
local MAX_GROUP_FILTER_ITEMS = 32
local MAX_GROUP_FILTER_KEY_BYTES = 128

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

local function boundedGroupFilterKey(value)
    return type(value) == 'string' and #value >= 1
        and #value <= MAX_GROUP_FILTER_KEY_BYTES
        and value:find('[%z\1-\31\127]') == nil
end

local function boundedGroupName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:find('[%z\1-\31\127]') == nil
end

local function boundedGrade(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.type(value) == 'integer' and value >= 0 and value <= 65535
end

local function invalidGroupFilter()
    return nil, bridgeError('COMPAT_DTO_INVALID',
        'Qbox group filters must be a bounded string, dense string array, or name-to-grade map.')
end

local function normalizeGroupFilter(filter)
    if boundedGroupFilterKey(filter) then
        return { kind = 'single', value = filter }, nil
    end
    if type(filter) ~= 'table' or getmetatable(filter) ~= nil then
        return invalidGroupFilter()
    end

    local numericCount, stringCount, maximumIndex = 0, 0, 0
    local arrayValues, mapValues = {}, {}
    for key, value in pairs(filter) do
        if type(key) == 'number' and math.type(key) == 'integer' then
            numericCount = numericCount + 1
            if numericCount > MAX_GROUP_FILTER_ITEMS or key < 1
                or key > MAX_GROUP_FILTER_ITEMS
                or not boundedGroupFilterKey(value) then
                return invalidGroupFilter()
            end
            if key > maximumIndex then maximumIndex = key end
            arrayValues[key] = value
        elseif type(key) == 'string' then
            stringCount = stringCount + 1
            if stringCount > MAX_GROUP_FILTER_ITEMS
                or not boundedGroupFilterKey(key) or not boundedGrade(value) then
                return invalidGroupFilter()
            end
            mapValues[key] = value
        else
            return invalidGroupFilter()
        end
    end

    if numericCount > 0 and stringCount > 0 then return invalidGroupFilter() end
    if numericCount > 0 then
        if numericCount ~= maximumIndex then return invalidGroupFilter() end
        for index = 1, maximumIndex do
            if arrayValues[index] == nil then return invalidGroupFilter() end
        end
        return { kind = 'array', values = arrayValues }, nil
    end
    return { kind = 'map', values = mapValues }, nil
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

local function groupMaps(snapshot)
    local groups, details, jobs, gangs = {}, {}, {}, {}
    for _, membership in ipairs(groupItems(snapshot)) do
        local group = type(membership.group) == 'table' and membership.group or {}
        local grade = type(membership.grade) == 'table' and membership.grade or {}
        if type(group.key) == 'string' and #group.key <= 64
            and type(grade.rank) == 'number' then
            groups[group.key] = grade.rank
            if group.type == 'job' then
                jobs[group.key] = grade.rank
            elseif group.type == 'gang' or group.type == 'group' then
                gangs[group.key] = grade.rank
            end
            details[group.key] = {
                name = group.key,
                label = type(group.label) == 'string' and group.label
                    or type(group.name) == 'string' and group.name or group.key,
                type = group.type,
                grade = {
                    name = type(grade.key) == 'string' and grade.key or 'none',
                    level = grade.rank,
                    label = type(grade.name) == 'string' and grade.name or 'None',
                },
                onduty = type(membership.duty) == 'table'
                    and membership.duty.counts_as_on_duty == true or false,
                isboss = membership.compatibility_is_boss == true,
                primary = membership.is_primary == true,
            }
        end
    end
    return groups, details, jobs, gangs
end

local function playerData(snapshot)
    local groups, details, jobs, gangs = groupMaps(snapshot)
    local job = {
        name = 'unemployed', label = 'Unemployed',
        grade = { name = 'none', level = 0, label = 'None' },
        onduty = false, isboss = false,
    }
    local gang = {
        name = 'none', label = 'None',
        grade = { name = 'none', level = 0, label = 'None' }, isboss = false,
    }
    for _, membership in ipairs(groupItems(snapshot)) do
        local group = type(membership.group) == 'table' and membership.group or {}
        local projected = details[group.key]
        if projected and group.type == 'job' then
            if projected.primary then job = copy(projected) end
        elseif projected and (group.type == 'gang' or group.type == 'group') then
            projected = copy(projected)
            projected.onduty = nil
            if projected.primary then gang = projected end
        end
    end
    job.primary, gang.primary = nil, nil
    local character = snapshot.character or {}
    return {
        source = snapshot.source,
        citizenid = snapshot.identity and snapshot.identity.identifier or nil,
        cid = character.slot,
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
        groups = groups,
        jobs = jobs,
        gangs = gangs,
        metadata = copy(snapshot.metadata or {}),
    }
end

local function playerFor(consumer, snapshot)
    local fence, playerSource = copy(snapshot.fence), snapshot.source
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
        GetMoney = function(moneyType)
            if moneyType ~= 'cash' and moneyType ~= 'bank' then return false end
            local current, currentError = refreshMoney()
            if not current then return false, currentError end
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

-- Lifecycle events are global broadcasts. Their payload must never carry a
-- facade whose closures are bound to one compatibility consumer's authority.
local function lifecyclePlayer(playerDataValue)
    return {
        PlayerData = copy(playerDataValue),
        Offline = false,
    }
end

local function offlinePlayerFor(snapshot)
    local player = { PlayerData = playerData(snapshot), Offline = true }
    local function offlineMutation()
        return false, bridgeError('COMPAT_OFFLINE_MUTATION_UNSUPPORTED',
            'Offline Qbox player mutations are not supported by this read-only projection.')
    end
    player.Functions = {
        GetMoney = function(moneyType)
            if moneyType ~= 'cash' and moneyType ~= 'bank' then return false end
            return snapshot.money and snapshot.money[moneyType] or 0
        end,
        GetMetaData = function(key)
            return copy(snapshot.metadata and snapshot.metadata[key] or nil)
        end,
        AddMoney = offlineMutation,
        RemoveMoney = offlineMutation,
        SetMoney = offlineMutation,
        SetMetaData = offlineMutation,
        SetJob = offlineMutation,
        SetGang = offlineMutation,
        SetJobDuty = offlineMutation,
    }
    return player
end

local function getPlayerByCitizenId(consumer, citizenId)
    if type(adapter.readPlayerByIdentifier) ~= 'function' then
        return adapter:unsupported(consumer,
            'qbx.server.identifier_player_lookup',
            'Online citizen identifier lookup is unavailable.')
    end
    local snapshot, snapshotError = adapter:readPlayerByIdentifier(
        consumer, citizenId)
    if snapshot == false then return nil, nil end
    if not snapshot then return nil, snapshotError end
    return playerFor(consumer, snapshot), nil
end

local function getOfflinePlayer(consumer, citizenId)
    if type(adapter.readOfflinePlayerByIdentifier) ~= 'function' then
        return adapter:unsupported(consumer,
            'qbx.server.offline_player_lookup',
            'Read-only offline player lookup is unavailable.')
    end
    local snapshot, snapshotError = adapter:readOfflinePlayerByIdentifier(
        consumer, citizenId)
    if snapshot == false then return nil, nil end
    if not snapshot then return nil, snapshotError end
    return offlinePlayerFor(snapshot), nil
end

local function groupRanks(snapshot, primaryOnly)
    local ranks = {}
    for _, membership in ipairs(groupItems(snapshot)) do
        local group = type(membership) == 'table'
            and type(membership.group) == 'table' and membership.group or nil
        local grade = type(membership) == 'table'
            and type(membership.grade) == 'table' and membership.grade or nil
        if group and grade and boundedGroupFilterKey(group.key)
            and boundedGrade(grade.rank)
            and (not primaryOnly or membership.is_primary == true) then
            local current = ranks[group.key]
            if current == nil or grade.rank > current then
                ranks[group.key] = grade.rank
            end
        end
    end
    return ranks
end

local function groupFilterMatches(snapshot, filter, primaryOnly)
    local normalized, filterError = normalizeGroupFilter(filter)
    if not normalized then return false, filterError end
    local identifier = type(snapshot.identity) == 'table'
        and snapshot.identity.identifier or nil
    local ranks = groupRanks(snapshot, primaryOnly)
    local function matches(name, minimumGrade)
        if identifier ~= nil and name == identifier then return true end
        local rank = ranks[name]
        return rank ~= nil and (minimumGrade == nil or rank >= minimumGrade)
    end

    if normalized.kind == 'single' then
        return matches(normalized.value), nil
    end
    if normalized.kind == 'array' then
        for _, name in ipairs(normalized.values) do
            if matches(name) then return true, nil end
        end
        return false, nil
    end
    for name, minimumGrade in pairs(normalized.values) do
        if matches(name, minimumGrade) then return true, nil end
    end
    return false, nil
end

local function hasGroup(consumer, playerSource, filter, primaryOnly)
    local snapshot, snapshotError = adapter:readGroups(consumer, playerSource)
    if not snapshot then return false, snapshotError end
    return groupFilterMatches(snapshot, filter, primaryOnly)
end

local function setPrimaryGroup(consumer, citizenId, legacyType, legacyName)
    if not boundedGroupName(legacyName)
        or not legacyName:match('^[a-z][a-z0-9_%-]*$') then
        return false, bridgeError('COMPAT_INVALID_ARGUMENT',
            'The Qbox primary group name is invalid.')
    end
    if type(adapter.setPrimaryGroup) ~= 'function' then
        return adapter:unsupported(consumer,
            'qbx.server.primary_group_mutation',
            'Primary group mutation requires online citizen identifier lookup.')
    end
    local changed, changeError = adapter:setPrimaryGroup(
        consumer, citizenId, legacyType, legacyName)
    return changed == true, changeError
end

local function readPlayer(consumer, playerSource)
    if type(playerSource) == 'number' then
        local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
        if not snapshot then return nil, snapshotError end
        return snapshot, nil
    end
    if type(playerSource) ~= 'string' or #playerSource < 1
        or #playerSource > 191 or playerSource:find('[%z\1-\31\127]') then
        return nil, bridgeError('COMPAT_DTO_INVALID',
            'Qbox player identifiers must be a source or bounded citizen identifier.')
    end
    local snapshot, snapshotError = adapter:readPlayerByIdentifier(
        consumer, playerSource)
    if snapshot == false then return false, nil end
    if not snapshot then return nil, snapshotError end
    return snapshot, nil
end

local function getPlayer(consumer, playerSource)
    local snapshot, snapshotError = readPlayer(consumer, playerSource)
    if snapshot == false then return nil, nil end
    if not snapshot then return nil, snapshotError end
    return playerFor(consumer, snapshot), nil
end

local function money(consumer, playerSource, moneyType)
    if moneyType ~= 'cash' and moneyType ~= 'bank' then return false end
    local snapshot, snapshotError = adapter:readMoney(consumer, playerSource)
    if snapshot == false then return false, nil end
    if not snapshot then return false, snapshotError end
    return snapshot.money[moneyType] or 0
end

local function groups(consumer, playerSource)
    local snapshot, snapshotError = adapter:readGroups(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    local mapped, details = groupMaps(snapshot)
    return mapped, details
end

local function metadata(consumer, playerSource, key)
    local snapshot, snapshotError = adapter:readMetadata(consumer, playerSource)
    if snapshot == false then return nil, nil end
    if not snapshot then return nil, snapshotError end
    return snapshot.metadata and snapshot.metadata[key] or nil
end

local function mutateMoney(consumer, playerSource, moneyType, direction, amount, reason)
    local changed, changeError = adapter:changeMoney(
        consumer, playerSource, moneyType, direction, amount, reason, nil)
    return changed == true, changeError
end

local function setMoney(consumer, playerSource, moneyType, amount, reason)
    local changed, changeError = adapter:setMoney(
        consumer, playerSource, moneyType, amount, reason, nil)
    return changed == true, changeError
end

local function setMetadata(consumer, playerSource, key, value)
    local changed, changeError = adapter:setMetadata(
        consumer, playerSource, key, value, nil, nil)
    return changed ~= nil, changeError
end

local function setGroup(consumer, identifier, legacyType, name, grade)
    local changed, changeError = adapter:setGroup(
        consumer, identifier, legacyType, name, grade,
        legacyType == 'job' and 'compatibility_set_job'
            or 'compatibility_set_gang', nil)
    return changed == true, changeError
end

local function setJobDuty(consumer, identifier, onDuty)
    local changed, changeError = adapter:setDuty(
        consumer, identifier, onDuty, 'compatibility_set_job_duty', nil)
    return changed == true, changeError
end

local function facadeCall(consumer, operation)
    local authenticated, consumerError = facadeConsumer(consumer)
    if not authenticated then return nil, consumerError end
    return operation(authenticated)
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

exports('GetPlayer', function(playerSource) return getPlayer(GetInvokingResource(), playerSource) end)
exports('GetPlayerByCitizenId', function(citizenId)
    return getPlayerByCitizenId(GetInvokingResource(), citizenId)
end)
exports('GetOfflinePlayer', function(citizenId)
    return getOfflinePlayer(GetInvokingResource(), citizenId)
end)
exports('GetMoney', function(playerSource, moneyType)
    return money(GetInvokingResource(), playerSource, moneyType)
end)
exports('AddMoney', function(playerSource, moneyType, amount, reason)
    return mutateMoney(GetInvokingResource(), playerSource, moneyType, 'add', amount, reason)
end)
exports('RemoveMoney', function(playerSource, moneyType, amount, reason)
    return mutateMoney(GetInvokingResource(), playerSource, moneyType, 'remove', amount, reason)
end)
exports('SetMoney', function(playerSource, moneyType, amount, reason)
    return setMoney(GetInvokingResource(), playerSource, moneyType, amount, reason)
end)
exports('GetMetadata', function(playerSource, key)
    return metadata(GetInvokingResource(), playerSource, key)
end)
exports('SetMetadata', function(playerSource, key, value)
    return setMetadata(GetInvokingResource(), playerSource, key, value)
end)
exports('GetGroups', function(playerSource)
    return groups(GetInvokingResource(), playerSource)
end)
exports('HasGroup', function(playerSource, filter)
    return hasGroup(GetInvokingResource(), playerSource, filter, false)
end)
exports('HasPrimaryGroup', function(playerSource, filter)
    return hasGroup(GetInvokingResource(), playerSource, filter, true)
end)
exports('SetPlayerPrimaryJob', function(citizenId, jobName)
    return setPrimaryGroup(GetInvokingResource(), citizenId, 'job', jobName)
end)
exports('SetPlayerPrimaryGang', function(citizenId, gangName)
    return setPrimaryGroup(GetInvokingResource(), citizenId, 'gang', gangName)
end)
exports('SetJob', function(identifier, jobName, grade)
    return setGroup(GetInvokingResource(), identifier, 'job', jobName, grade)
end)
exports('SetGang', function(identifier, gangName, grade)
    return setGroup(GetInvokingResource(), identifier, 'gang', gangName, grade)
end)
exports('SetJobDuty', function(identifier, onDuty)
    return setJobDuty(GetInvokingResource(), identifier, onDuty)
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

exports('GetPlayerForConsumer', function(consumer, playerSource)
    return facadeCall(consumer, function(authenticated)
        return getPlayer(authenticated, playerSource)
    end)
end)
exports('GetPlayerByCitizenIdForConsumer', function(consumer, citizenId)
    return facadeCall(consumer, function(authenticated)
        return getPlayerByCitizenId(authenticated, citizenId)
    end)
end)
exports('GetOfflinePlayerForConsumer', function(consumer, citizenId)
    return facadeCall(consumer, function(authenticated)
        return getOfflinePlayer(authenticated, citizenId)
    end)
end)
exports('GetMoneyForConsumer', function(consumer, playerSource, moneyType)
    return facadeCall(consumer, function(authenticated)
        return money(authenticated, playerSource, moneyType)
    end)
end)
exports('AddMoneyForConsumer', function(consumer, playerSource, moneyType, amount, reason)
    return facadeCall(consumer, function(authenticated)
        return mutateMoney(authenticated, playerSource, moneyType, 'add', amount, reason)
    end)
end)
exports('RemoveMoneyForConsumer', function(consumer, playerSource, moneyType, amount, reason)
    return facadeCall(consumer, function(authenticated)
        return mutateMoney(authenticated, playerSource, moneyType, 'remove', amount, reason)
    end)
end)
exports('SetMoneyForConsumer', function(consumer, playerSource, moneyType, amount, reason)
    return facadeCall(consumer, function(authenticated)
        return setMoney(authenticated, playerSource, moneyType, amount, reason)
    end)
end)
exports('GetMetadataForConsumer', function(consumer, playerSource, key)
    return facadeCall(consumer, function(authenticated)
        return metadata(authenticated, playerSource, key)
    end)
end)
exports('SetMetadataForConsumer', function(consumer, playerSource, key, value)
    return facadeCall(consumer, function(authenticated)
        return setMetadata(authenticated, playerSource, key, value)
    end)
end)
exports('GetGroupsForConsumer', function(consumer, playerSource)
    return facadeCall(consumer, function(authenticated)
        return groups(authenticated, playerSource)
    end)
end)
exports('HasGroupForConsumer', function(consumer, playerSource, filter)
    return facadeCall(consumer, function(authenticated)
        return hasGroup(authenticated, playerSource, filter, false)
    end)
end)
exports('HasPrimaryGroupForConsumer', function(consumer, playerSource, filter)
    return facadeCall(consumer, function(authenticated)
        return hasGroup(authenticated, playerSource, filter, true)
    end)
end)
exports('SetPlayerPrimaryJobForConsumer', function(consumer, citizenId, jobName)
    return facadeCall(consumer, function(authenticated)
        return setPrimaryGroup(authenticated, citizenId, 'job', jobName)
    end)
end)
exports('SetPlayerPrimaryGangForConsumer', function(consumer, citizenId, gangName)
    return facadeCall(consumer, function(authenticated)
        return setPrimaryGroup(authenticated, citizenId, 'gang', gangName)
    end)
end)
exports('SetJobForConsumer', function(consumer, identifier, jobName, grade)
    return facadeCall(consumer, function(authenticated)
        return setGroup(authenticated, identifier, 'job', jobName, grade)
    end)
end)
exports('SetGangForConsumer', function(consumer, identifier, gangName, grade)
    return facadeCall(consumer, function(authenticated)
        return setGroup(authenticated, identifier, 'gang', gangName, grade)
    end)
end)
exports('SetJobDutyForConsumer', function(consumer, identifier, onDuty)
    return facadeCall(consumer, function(authenticated)
        return setJobDuty(authenticated, identifier, onDuty)
    end)
end)
exports('InvokeCompatibilityAdapterForConsumer', function(consumer, request)
    return facadeCall(consumer, function(authenticated)
        return invokeCompatibilityAdapter(authenticated, request)
    end)
end)
exports('ResolveCompatibilityCatalogForConsumer', function(consumer, request)
    return facadeCall(consumer, function(authenticated)
        return compatibilityCatalog('resolve', authenticated, request)
    end)
end)
exports('InvokeCompatibilityCatalogForConsumer', function(consumer, request)
    return facadeCall(consumer, function(authenticated)
        return compatibilityCatalog('invoke', authenticated, request)
    end)
end)
exports('GetCompatibilityUsage', function()
    local consumer = GetInvokingResource()
    local authorization, authorizationError = adapter:authorize(
        consumer, 'read', 'telemetry.read')
    if not authorization then return nil, authorizationError end
    return adapter:trace(authorization, consumer, 'GetCompatibilityUsage',
        function() return copy(adapter:usageSnapshot(consumer)), nil end)
end)

local CLIENT_PROJECTION_EVENT = 'synex_bridge_qbx:client:projection'

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

local function ownsFamily(context, family)
    return type(context.publication) == 'table'
        and type(context.publication.families) == 'table'
        and context.publication.families[family] == true
end

local function publishesSurface(context, surface)
    return type(context.publication) == 'table'
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

local function publishQbxGroupChanges(playerSource, previous, current)
    for _, field in ipairs({ 'jobs', 'gangs' }) do
        local before = type(previous[field]) == 'table' and previous[field] or {}
        local after = type(current[field]) == 'table' and current[field] or {}
        local names = {}
        for name in pairs(before) do names[name] = true end
        for name in pairs(after) do names[name] = true end
        local ordered = {}
        for name in pairs(names) do ordered[#ordered + 1] = name end
        table.sort(ordered)
        for _, name in ipairs(ordered) do
            if before[name] ~= after[name] then
                TriggerEvent('qbx_core:server:onGroupUpdate', playerSource,
                    name, after[name])
                TriggerClientEvent('qbx_core:client:onGroupUpdate', playerSource,
                    name, after[name])
            end
        end
    end
end

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    loaded = function(context)
        publishClientProjection(context, context.playerData)
        if context.resync == true then return true end
        if not ownsFamily(context, 'qbc') then return true end
        TriggerEvent('QBCore:Player:SetPlayerData', copy(context.playerData))
        TriggerClientEvent('QBCore:Player:SetPlayerData', context.source,
            copy(context.playerData))
        TriggerEvent('QBCore:Server:PlayerLoaded',
            lifecyclePlayer(context.playerData))
        TriggerClientEvent('QBCore:Client:OnPlayerLoaded', context.source)
        return true
    end,
    updated = function(context)
        local previous, current = context.previousPlayerData, context.playerData
        publishClientProjection(context, current)
        local ownsQbc = ownsFamily(context, 'qbc')
        local jobChanged = not sameValue(previous.job, current.job)
        local previousJob = type(previous.job) == 'table' and previous.job or {}
        local currentJob = type(current.job) == 'table' and current.job or {}
        local dutyOnly = jobChanged and previousJob.onduty ~= currentJob.onduty
            and previousJob.name == currentJob.name
            and sameValue(previousJob.grade, currentJob.grade)
        if dutyOnly and (ownsQbc or ownsFamily(context, 'qbx'))
            and publishesSurface(context, 'qbx.shared.duty_update_events') then
            TriggerEvent('QBCore:Server:SetDuty', context.source,
                currentJob.onduty == true)
            TriggerClientEvent('QBCore:Client:SetDuty', context.source,
                currentJob.onduty == true)
        end
        if ownsQbc then
            TriggerEvent('QBCore:Player:SetPlayerData', copy(current))
            TriggerClientEvent('QBCore:Player:SetPlayerData', context.source,
                copy(current))
        end
        if ownsFamily(context, 'qbx')
            and publishesSurface(context, 'qbx.shared.group_update_events') then
            publishQbxGroupChanges(context.source, previous, current)
        end
        if not ownsQbc then return true end
        if jobChanged and not dutyOnly
            and publishesSurface(context, 'qbx.shared.group_update_events') then
            TriggerEvent('QBCore:Server:OnJobUpdate', context.source,
                copy(current.job))
            TriggerClientEvent('QBCore:Client:OnJobUpdate', context.source,
                copy(current.job))
        end
        if not sameValue(previous.gang, current.gang)
            and publishesSurface(context, 'qbx.shared.group_update_events') then
            TriggerEvent('QBCore:Server:OnGangUpdate', context.source,
                copy(current.gang))
            TriggerClientEvent('QBCore:Client:OnGangUpdate', context.source,
                copy(current.gang))
        end
        if publishesSurface(context, 'qbx.shared.money_update_events') then
            publishMoneyChanges(context.source, previous, current)
        end
        return true
    end,
    unloaded = function(context)
        TriggerClientEvent(CLIENT_PROJECTION_EVENT, context.source, 'clear')
        if ownsFamily(context, 'qbc') then
            TriggerClientEvent('QBCore:Client:OnPlayerUnload', context.source)
            TriggerEvent('QBCore:Server:OnPlayerUnload', context.source)
        end
        if ownsFamily(context, 'qbx') then
            TriggerClientEvent('qbx_core:client:playerLoggedOut', context.source)
            TriggerEvent('qbx_core:server:playerLoggedOut', context.source)
        end
        return true
    end,
})
if not lifecycleToken then
    error(('Qbox bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'))
end
