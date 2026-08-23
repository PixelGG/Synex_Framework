local adapter = assert(SynexBridgeNative, 'synex_bridge native server library is unavailable').create({
    framework = 'esx',
    capabilityPrefix = 'synex.compat.esx',
    requestEvent = 'synex_bridge_esx:server:callback',
    responseEvent = 'synex_bridge_esx:client:callback',
    counterpartyConvars = {
        cash = 'synex_bridge_esx_cash_counterparty',
        bank = 'synex_bridge_esx_bank_counterparty',
    },
})

local function moneyType(accountName)
    if accountName == 'money' or accountName == 'cash' then return 'cash' end
    if accountName == 'bank' then return 'bank' end
    return nil
end

local function primaryJob(snapshot)
    for _, membership in ipairs(snapshot.groups or {}) do
        if membership.group_type == 'job' then
            return {
                id = membership.group_id,
                name = membership.group_key,
                label = membership.group_display_name,
                grade = membership.rank_value,
                grade_name = membership.grade_key,
                grade_label = membership.grade_display_name,
                onDuty = false,
            }
        end
    end
    return {
        name = 'unemployed', label = 'Unemployed', grade = 0,
        grade_name = 'none', grade_label = 'None', onDuty = false,
    }
end

local function playerData(snapshot)
    local accounts = {
        { name = 'money', label = 'Cash', money = snapshot.money.cash or 0, round = true },
        { name = 'bank', label = 'Bank', money = snapshot.money.bank or 0, round = true },
    }
    return {
        source = snapshot.source,
        identifier = 'synex:' .. snapshot.character.id,
        name = ('%s %s'):format(snapshot.character.firstName, snapshot.character.lastName),
        accounts = accounts,
        job = primaryJob(snapshot),
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

local function xPlayerFor(consumer, snapshot)
    local player = {
        source = snapshot.source,
        identifier = 'synex:' .. snapshot.character.id,
        variables = {},
    }
    local function refresh()
        local current, currentError = adapter:readPlayer(consumer, snapshot.source)
        if not current then return nil, currentError end
        snapshot = current
        player.identifier = 'synex:' .. current.character.id
        return current, nil
    end
    player.getIdentifier = function() return player.identifier end
    player.getName = function()
        return ('%s %s'):format(snapshot.character.firstName, snapshot.character.lastName)
    end
    player.getJob = function() return primaryJob(snapshot) end
    player.getGroup = function()
        return nil, {
            code = 'UNSUPPORTED',
            message = 'Legacy ESX permission groups are not inferred from Synex memberships.',
        }
    end
    player.getMoney = function()
        local current, currentError = refresh()
        return current and (current.money.cash or 0) or nil, currentError
    end
    player.getAccount = function(accountName)
        local mapped = moneyType(accountName)
        if not mapped then return nil end
        local current, currentError = refresh()
        if not current then return nil, currentError end
        return {
            name = accountName == 'cash' and 'money' or accountName,
            label = mapped == 'cash' and 'Cash' or 'Bank',
            money = current.money[mapped] or 0,
            round = true,
        }, nil
    end
    player.getAccounts = function(minimal)
        local current, currentError = refresh()
        if not current then return nil, currentError end
        if minimal == true then
            return { money = current.money.cash or 0, bank = current.money.bank or 0 }, nil
        end
        return playerData(current).accounts, nil
    end
    player.addMoney = function(amount, reason)
        return adapter:changeMoney(consumer, snapshot.source, 'cash', 'add', amount, reason)
    end
    player.removeMoney = function(amount, reason)
        return adapter:changeMoney(consumer, snapshot.source, 'cash', 'remove', amount, reason)
    end
    player.setMoney = function(amount, reason)
        return adapter:setMoney(consumer, snapshot.source, 'cash', amount, reason)
    end
    player.addAccountMoney = function(accountName, amount, reason)
        local mapped = moneyType(accountName)
        if not mapped then return false, { code = 'UNSUPPORTED_ACCOUNT', message = 'Only money/cash and bank are mapped.' } end
        return adapter:changeMoney(consumer, snapshot.source, mapped, 'add', amount, reason)
    end
    player.removeAccountMoney = function(accountName, amount, reason)
        local mapped = moneyType(accountName)
        if not mapped then return false, { code = 'UNSUPPORTED_ACCOUNT', message = 'Only money/cash and bank are mapped.' } end
        return adapter:changeMoney(consumer, snapshot.source, mapped, 'remove', amount, reason)
    end
    player.setAccountMoney = function(accountName, amount, reason)
        local mapped = moneyType(accountName)
        if not mapped then return false, { code = 'UNSUPPORTED_ACCOUNT', message = 'Only money/cash and bank are mapped.' } end
        return adapter:setMoney(consumer, snapshot.source, mapped, amount, reason)
    end
    player.setJob = function()
        return false, { code = 'UNSUPPORTED', message = 'Use the native Synex Groups API for job membership changes.' }
    end
    return player
end

local function sharedObjectFor(consumer)
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'shared_object.read')
    if not allowed then return nil, authorizationError end
    return {
        Compatibility = { framework = 'esx', status = 'partial', deprecated = true },
        GetPlayerFromId = function(playerSource)
            local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
            if not snapshot then return nil, snapshotError end
            return xPlayerFor(consumer, snapshot), nil
        end,
        RegisterServerCallback = function(name, handler)
            return adapter:registerCallback(consumer, name, handler)
        end,
    }, nil
end

exports('getSharedObject', function()
    return sharedObjectFor(GetInvokingResource())
end)

exports('GetPlayerFromId', function(playerSource)
    local consumer = GetInvokingResource()
    local snapshot, snapshotError = adapter:readPlayer(consumer, playerSource)
    if not snapshot then return nil, snapshotError end
    return xPlayerFor(consumer, snapshot), nil
end)

exports('RegisterServerCallback', function(name, handler)
    return adapter:registerCallback(GetInvokingResource(), name, handler)
end)

exports('GetCompatibilityUsage', function()
    local consumer = GetInvokingResource()
    local allowed, authorizationError = adapter:authorize(consumer, 'read', 'telemetry.read')
    if not allowed then return nil, authorizationError end
    return adapter:usageSnapshot(consumer), nil
end)

AddEventHandler('esx:getSharedObject', function(callback)
    local consumer = GetInvokingResource()
    if not SynexBridgeNative.isCallable(callback) or type(consumer) ~= 'string' then return end
    local object = sharedObjectFor(consumer)
    if object then pcall(function() callback(object) end) end
end)

local lifecycleToken, lifecycleError = adapter:registerLifecycle(playerData, {
    clientLoaded = 'esx:playerLoaded',
    serverLoaded = 'esx:playerLoaded',
    clientUnloaded = 'esx:onPlayerLogout',
    serverUnloaded = 'esx:playerLogout',
})
if not lifecycleToken then
    error(('ESX bridge lifecycle registration failed: %s'):format(
        type(lifecycleError) == 'table' and lifecycleError.code or 'UNKNOWN'
    ))
end
