local adapter = assert(SynexBridgeNative, 'synex_bridge native server library is unavailable').create({
    framework = 'qbx',
    capabilityPrefix = 'synex.compat.qbx',
    requestEvent = 'synex_bridge_qbx:server:callback',
    responseEvent = 'synex_bridge_qbx:client:callback',
    counterpartyConvars = {
        cash = 'synex_bridge_qbx_cash_counterparty',
        bank = 'synex_bridge_qbx_bank_counterparty',
    },
})

local function readMoney(snapshot, moneyType)
    if moneyType ~= 'cash' and moneyType ~= 'bank' then
        return nil, { code = 'UNSUPPORTED_MONEY_TYPE', message = 'Only cash and bank are mapped.' }
    end
    return snapshot.money[moneyType] or 0, nil
end

local function groupMaps(snapshot)
    local groups = {}
    local details = {}
    for _, membership in ipairs(snapshot.groups or {}) do
        groups[membership.group_key] = membership.rank_value
        details[membership.group_key] = {
            name = membership.group_key,
            label = membership.group_display_name,
            type = membership.group_type,
            grade = { name = membership.grade_key, level = membership.rank_value },
            primary = membership.is_primary,
        }
    end
    return groups, details
end

local function playerData(snapshot)
    local groups, details = groupMaps(snapshot)
    local job = { name = 'unemployed', label = 'Unemployed', grade = { name = 'none', level = 0 }, onduty = false, isboss = false }
    local gang = { name = 'none', label = 'None', grade = { name = 'none', level = 0 }, isboss = false }
    for _, membership in ipairs(snapshot.groups or {}) do
        local projection = details[membership.group_key]
        if membership.group_type == 'job' and job.name == 'unemployed' then
            job = projection
            job.onduty, job.isboss, job.type, job.primary = false, false, nil, nil
        elseif (membership.group_type == 'gang' or membership.group_type == 'group') and gang.name == 'none' then
            gang = projection
            gang.isboss, gang.type, gang.primary = false, nil, nil
        end
    end
    return {
        source = snapshot.source,
        citizenid = snapshot.character.id,
        cid = snapshot.character.slot,
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

local function playerFor(consumer, snapshot)
    local player = { PlayerData = playerData(snapshot) }
    player.Functions = {
        GetMoney = function(moneyType)
            local current, currentError = adapter:readPlayer(consumer, snapshot.source)
            if not current then return nil, currentError end
            return readMoney(current, moneyType)
        end,
        AddMoney = function(moneyType, amount, reason)
            return adapter:changeMoney(consumer, snapshot.source, moneyType, 'add', amount, reason)
        end,
        RemoveMoney = function(moneyType, amount, reason)
            return adapter:changeMoney(consumer, snapshot.source, moneyType, 'remove', amount, reason)
        end,
        SetMoney = function(moneyType, amount, reason)
            return adapter:setMoney(consumer, snapshot.source, moneyType, amount, reason)
        end,
    }
    return player
end

local function readForCaller(playerSource)
    local consumer = GetInvokingResource()
    local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    return snapshot, nil, consumer
end

exports('GetPlayer', function(playerSource)
    local snapshot, snapshotError, consumer = readForCaller(playerSource)
    if not snapshot then return nil, snapshotError end
    return playerFor(consumer, snapshot), nil
end)

exports('GetMoney', function(playerSource, moneyType)
    local snapshot, snapshotError = readForCaller(playerSource)
    if not snapshot then return nil, snapshotError end
    return readMoney(snapshot, moneyType)
end)

exports('AddMoney', function(playerSource, moneyType, amount, reason)
    return adapter:changeMoney(GetInvokingResource(), playerSource, moneyType, 'add', amount, reason)
end)

exports('RemoveMoney', function(playerSource, moneyType, amount, reason)
    return adapter:changeMoney(GetInvokingResource(), playerSource, moneyType, 'remove', amount, reason)
end)

exports('SetMoney', function(playerSource, moneyType, amount, reason)
    return adapter:setMoney(GetInvokingResource(), playerSource, moneyType, amount, reason)
end)

exports('GetGroups', function(playerSource)
    local snapshot, snapshotError = readForCaller(playerSource)
    if not snapshot then return nil, snapshotError end
    local groups = groupMaps(snapshot)
    return groups, nil
end)

exports('GetGroup', function(playerSource, groupName)
    local snapshot, snapshotError = readForCaller(playerSource)
    if not snapshot then return nil, snapshotError end
    local groups = groupMaps(snapshot)
    return groups[groupName], nil
end)

exports('GetCoreObject', function()
    local consumer = GetInvokingResource()
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'core_object.read')
    if not allowed then return nil, authorizationError end
    return {
        Compatibility = { framework = 'qbx', status = 'partial', deprecated = true },
        Functions = {
            GetPlayer = function(playerSource)
                local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
                if not snapshot then return nil, snapshotError end
                return playerFor(consumer, snapshot), nil
            end,
            CreateCallback = function(name, handler)
                return adapter:registerCallback(consumer, name, handler)
            end,
        },
    }, nil
end)

exports('CreateCallback', function(name, handler)
    return adapter:registerCallback(GetInvokingResource(), name, handler)
end)

exports('GetCompatibilityUsage', function()
    local consumer = GetInvokingResource()
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'telemetry.read')
    if not allowed then return nil, authorizationError end
    return adapter:usageSnapshot(consumer), nil
end)

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    clientLoaded = 'QBCore:Client:OnPlayerLoaded',
    serverLoaded = 'QBCore:Server:PlayerLoaded',
    clientUnloaded = 'QBCore:Client:OnPlayerUnload',
    serverUnloaded = 'QBCore:Server:OnPlayerUnload',
})
if not lifecycleToken then
    error(('Qbox bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'
    ))
end
