local adapter = assert(SynexBridgeNative, 'synex_bridge native server library is unavailable').create({
    framework = 'qb',
    capabilityPrefix = 'synex.compat.qb',
    requestEvent = 'synex_bridge_qb:server:callback',
    responseEvent = 'synex_bridge_qb:client:callback',
    counterpartyConvars = {
        cash = 'synex_bridge_qb_cash_counterparty',
        bank = 'synex_bridge_qb_bank_counterparty',
    },
})

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

local function emptyGrade()
    return { name = 'none', level = 0 }
end

local function readMoney(snapshot, moneyType)
    if moneyType ~= 'cash' and moneyType ~= 'bank' then
        return nil, { code = 'UNSUPPORTED_MONEY_TYPE', message = 'Only cash and bank are mapped.' }
    end
    return snapshot.money[moneyType] or 0, nil
end

local function groupProjection(membership)
    return {
        name = membership.group_key,
        label = membership.group_display_name,
        grade = { name = membership.grade_key, level = membership.rank_value },
        onduty = false,
        isboss = false,
    }
end

local function playerData(snapshot)
    local job = { name = 'unemployed', label = 'Unemployed', grade = emptyGrade(), onduty = false, isboss = false }
    local gang = { name = 'none', label = 'None', grade = emptyGrade(), isboss = false }
    local groups = {}
    for _, membership in ipairs(snapshot.groups or {}) do
        groups[membership.group_key] = membership.rank_value
        if membership.group_type == 'job' and job.name == 'unemployed' then
            job = groupProjection(membership)
        elseif (membership.group_type == 'gang' or membership.group_type == 'group') and gang.name == 'none' then
            gang = groupProjection(membership)
            gang.onduty = nil
        end
    end
    return {
        source = snapshot.source,
        citizenid = snapshot.character.id,
        cid = snapshot.character.slot,
        name = ('%s %s'):format(snapshot.character.firstName, snapshot.character.lastName),
        charinfo = {
            firstname = snapshot.character.firstName,
            lastname = snapshot.character.lastName,
            birthdate = snapshot.character.dateOfBirth,
        },
        money = { cash = snapshot.money.cash or 0, bank = snapshot.money.bank or 0 },
        job = job,
        gang = gang,
        groups = groups,
        metadata = {
            synex = {
                session_id = snapshot.session.id,
                user_id = snapshot.session.userId,
                character_id = snapshot.character.id,
                source_generation = snapshot.session.sourceGeneration,
                groups_truncated = snapshot.groupsTruncated,
            },
        },
    }
end

local function makePlayer(consumer, snapshot)
    local player = { PlayerData = playerData(snapshot) }
    local function refresh()
        local current, currentError = adapter:readPlayer(consumer, snapshot.source)
        if not current then return nil, currentError end
        snapshot = current
        player.PlayerData = playerData(current)
        return current, nil
    end
    player.Functions = {
        GetName = function()
            return ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname)
        end,
        GetMoney = function(moneyType)
            local current, currentError = refresh()
            if not current then return nil, currentError end
            return readMoney(current, moneyType)
        end,
        AddMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:changeMoney(consumer, snapshot.source, moneyType, 'add', amount, reason)
            if changed then refresh() end
            return changed == true, changeError
        end,
        RemoveMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:changeMoney(consumer, snapshot.source, moneyType, 'remove', amount, reason)
            if changed then refresh() end
            return changed == true, changeError
        end,
        SetMoney = function(moneyType, amount, reason)
            local changed, changeError = adapter:setMoney(consumer, snapshot.source, moneyType, amount, reason)
            if changed then refresh() end
            return changed == true, changeError
        end,
        SetJob = function()
            return false, { code = 'UNSUPPORTED', message = 'Use the native Synex Groups API for job membership changes.' }
        end,
        SetGang = function()
            return false, { code = 'UNSUPPORTED', message = 'Use the native Synex Groups API for group membership changes.' }
        end,
    }
    return player
end

local function coreObjectFor(consumer)
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'core_object.read')
    if not allowed then return nil, authorizationError end
    return {
        Compatibility = {
            framework = 'qb', status = 'partial', deprecated = true,
            mutablePlayerData = false, directSql = false,
        },
        Functions = {
            GetPlayer = function(playerSource)
                local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
                if not snapshot then return nil, snapshotError end
                return makePlayer(consumer, snapshot), nil
            end,
            GetPlayerByCitizenId = function()
                return nil, { code = 'UNSUPPORTED', message = 'Offline and cross-player legacy lookup is not exposed.' }
            end,
            CreateCallback = function(name, handler)
                return adapter:registerCallback(consumer, name, handler)
            end,
        },
    }, nil
end

exports('GetCoreObject', function()
    return coreObjectFor(GetInvokingResource())
end)

exports('GetPlayer', function(playerSource)
    local consumer = GetInvokingResource()
    local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    return makePlayer(consumer, snapshot), nil
end)

exports('GetCompatibilityUsage', function()
    local consumer = GetInvokingResource()
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'telemetry.read')
    if not allowed then return nil, authorizationError end
    return copy(adapter:usageSnapshot(consumer)), nil
end)

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    clientLoaded = 'QBCore:Client:OnPlayerLoaded',
    serverLoaded = 'QBCore:Server:PlayerLoaded',
    clientUnloaded = 'QBCore:Client:OnPlayerUnload',
    serverUnloaded = 'QBCore:Server:OnPlayerUnload',
})
if not lifecycleToken then
    error(('QBCore bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'
    ))
end
