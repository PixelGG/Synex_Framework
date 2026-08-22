local Native = {}

local API_RANGE = '^1.0.0'
local SERVICE_RANGE = '^1.0.0'
local UUID_PATTERN = '^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[1-5][0-9a-f][0-9a-f][0-9a-f]%-[89ab][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$'

local LIMITS = {
    callbackArguments = 16,
    callbackBytes = 16384,
    callbackPendingPerSource = 8,
    callbackTimeoutMs = 10000,
    callbackRate = 8,
    callbackBurst = 16,
    maximumDepth = 6,
    maximumEntries = 192,
    maximumStringBytes = 1024,
    maximumUsageEntries = 512,
    warningIntervalMs = 600000,
}

local function bridgeError(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
end

local function finiteInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
        and math.type(value) == 'integer' and value >= minimum and value <= maximum
end

local function boundedString(value, maximum)
    if type(value) ~= 'string' or value == '' or #value > maximum
        or value:find('[%z\1-\31\127]') then return nil end
    return value
end

local function copyBounded(value, budget, depth, seen)
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' then return value end
    if kind == 'number' then
        if value == value and value ~= math.huge and value ~= -math.huge then return value end
        return nil
    end
    if kind == 'string' then return value:sub(1, LIMITS.maximumStringBytes) end
    if kind ~= 'table' or depth >= LIMITS.maximumDepth or seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if budget.remaining <= 0 then break end
        if type(key) == 'number' or type(key) == 'string' then
            budget.remaining = budget.remaining - 1
            local safeKey = type(key) == 'string' and key:sub(1, 96) or key
            local safeValue = copyBounded(item, budget, depth + 1, seen)
            if safeValue ~= nil then result[safeKey] = safeValue end
        end
    end
    seen[value] = nil
    return result
end

local function safeCopy(value)
    return copyBounded(value, { remaining = LIMITS.maximumEntries }, 0, {})
end

local uuidCounter = 0
local uuidEpoch = ((os.time() & 0xffffffff) ~ (GetGameTimer() & 0xffffffff)) & 0xffffffff
local function uuidV4()
    uuidCounter = (uuidCounter + 1) & 0xffffffff
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return template:gsub('[xy]', function(symbol)
        local value = (math.random(0, 15) ~ (uuidCounter & 0xf) ~ (uuidEpoch & 0xf)) & 0xf
        if symbol == 'y' then value = (value & 0x3) | 0x8 end
        uuidCounter = ((uuidCounter << 1) | (uuidCounter >> 31)) & 0xffffffff
        uuidEpoch = ((uuidEpoch << 3) | (uuidEpoch >> 29)) & 0xffffffff
        return ('%x'):format(value)
    end)
end

local function validUuid(value)
    return type(value) == 'string' and value:match(UUID_PATTERN) ~= nil
end

local function validCallbackName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 96
        and value:match('^[A-Za-z0-9_:%-%.]+$') ~= nil
end

function Native.create(options)
    assert(type(options) == 'table', 'native bridge options are required')
    local framework = assert(boundedString(options.framework, 16), 'framework is invalid')
    local capabilityPrefix = assert(boundedString(options.capabilityPrefix, 64), 'capabilityPrefix is invalid')
    local requestEvent = assert(boundedString(options.requestEvent, 96), 'requestEvent is invalid')
    local responseEvent = assert(boundedString(options.responseEvent, 96), 'responseEvent is invalid')
    local resourceName = GetCurrentResourceName()
    local api
    local callbacks = {}
    local pending = {}
    local pendingBySource = {}
    local buckets = {}
    local usage = {}
    local usageSize = 0
    local warningTimes = {}

    local function getApi()
        if api then return api, nil end
        local ok, resolved, resolveError = pcall(function()
            return exports.synex_core:GetAPI(API_RANGE)
        end)
        if not ok or type(resolved) ~= 'table' then
            return nil, type(resolveError) == 'table' and resolveError
                or bridgeError('SYNEX_UNAVAILABLE', 'The Synex API is unavailable.', true)
        end
        api = resolved
        return api, nil
    end

    local function consumerIsActive(consumer)
        if type(consumer) ~= 'string' or consumer == '' or consumer == resourceName or consumer == 'synex_core' then
            return false
        end
        local state = GetResourceState(consumer)
        return state == 'started' or state == 'starting'
    end

    local function recordUsage(consumer, operation)
        local key = consumer .. ':' .. operation
        local now = GetGameTimer()
        local entry = usage[key]
        if not entry then
            if usageSize >= LIMITS.maximumUsageEntries then return end
            entry = { resource = consumer, operation = operation, calls = 0, firstSeenMs = now }
            usage[key] = entry
            usageSize = usageSize + 1
        end
        entry.calls = entry.calls + 1
        entry.lastSeenMs = now
        local previous = warningTimes[key]
        if not previous or now < previous or now - previous >= LIMITS.warningIntervalMs then
            warningTimes[key] = now
            print(json.encode({
                level = 'warn', event = 'deprecated_compatibility_api_used', framework = framework,
                resource = consumer, operation = operation,
            }))
        end
    end

    local function authorize(consumer, suffix, operation)
        if not consumerIsActive(consumer) then
            return nil, bridgeError('CALLER_INVALID', 'The compatibility consumer is not active.')
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local allowed, authorizationError = resolved.Capabilities.checkResource(
            consumer, capabilityPrefix .. '.' .. suffix, framework .. '.' .. operation
        )
        if not allowed then return nil, authorizationError end
        recordUsage(consumer, operation)
        return true, nil
    end

    local function validateSource(playerSource)
        return finiteInteger(playerSource, 1, 65534) and GetPlayerName(tostring(playerSource)) ~= nil
    end

    local function readPlayerInternal(playerSource)
        if not validateSource(playerSource) then
            return nil, bridgeError('INVALID_SOURCE', 'source must identify a connected player.')
        end
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local session, sessionError = resolved.Players.getBySource(playerSource)
        if not session then return nil, sessionError or bridgeError('SESSION_NOT_FOUND', 'The Synex session is unavailable.') end
        if session.state ~= 'ACTIVE' or type(session.characterId) ~= 'string' then
            return nil, bridgeError('CHARACTER_NOT_ACTIVE', 'The player has no active Synex character.')
        end
        local character, characterError = resolved.Characters.getActive(playerSource)
        if not character then return nil, characterError end
        local accounts, accountError = resolved.Services.call(
            'synex.accounts', SERVICE_RANGE, 'list_owner_accounts',
            { owner_kind = 'character', owner_ref = character.id },
            { operation = framework .. '.player.accounts' }
        )
        if not accounts then return nil, accountError end
        if accounts.truncated == true then
            return nil, bridgeError(
                'ACCOUNT_PROJECTION_TRUNCATED',
                'The compatible account projection is incomplete; money lookup is fail-closed.'
            )
        end
        local memberships, membershipError = resolved.Services.call(
            'synex.groups', SERVICE_RANGE, 'list_subject_memberships',
            { subject_kind = 'character', subject_id = character.id },
            { operation = framework .. '.player.groups' }
        )
        if not memberships then return nil, membershipError end

        local money = {}
        local accountIds = {}
        for _, account in ipairs(accounts.accounts or {}) do
            local currency = account.currency_code
            if currency == 'cash' or currency == 'bank' then
                if accountIds[currency] ~= nil then
                    return nil, bridgeError(
                        'AMBIGUOUS_MONEY_ACCOUNT',
                        ('The character owns multiple active %s accounts; compatibility is fail-closed.'):format(currency)
                    )
                end
                if tonumber(account.minor_unit) ~= 0 then
                    return nil, bridgeError(
                        'UNSUPPORTED_MONEY_SCALE',
                        ('The %s currency must use minor_unit 0 for legacy compatibility.'):format(currency)
                    )
                end
                if not finiteInteger(account.booked_minor, -9007199254740991, 9007199254740991)
                    or not validUuid(account.account_id) then
                    return nil, bridgeError('INVALID_ACCOUNT_SNAPSHOT', 'Synex returned an invalid account projection.')
                end
                money[currency] = account.booked_minor
                accountIds[currency] = account.account_id
            end
        end
        return {
            source = playerSource,
            session = safeCopy(session),
            character = safeCopy(character),
            money = money,
            accountIds = accountIds,
            groups = safeCopy(memberships.memberships or {}),
            groupsTruncated = memberships.truncated == true,
        }, nil
    end

    local adapter = {}

    function adapter:authorize(consumer, suffix, operation)
        return authorize(consumer, suffix, operation)
    end

    function adapter:readPlayer(consumer, playerSource)
        local allowed, authorizationError = authorize(consumer, 'read', 'player.read')
        if not allowed then return nil, authorizationError end
        return readPlayerInternal(playerSource)
    end

    function adapter:readPlayerInternal(playerSource)
        return readPlayerInternal(playerSource)
    end

    function adapter:changeMoney(consumer, playerSource, moneyType, direction, amount, reason)
        local allowed, authorizationError = authorize(consumer, 'write', 'money.' .. tostring(direction))
        if not allowed then return nil, authorizationError end
        if (moneyType ~= 'cash' and moneyType ~= 'bank') or (direction ~= 'add' and direction ~= 'remove')
            or not finiteInteger(amount, 1, 9007199254740991) then
            return nil, bridgeError('INVALID_MONEY_OPERATION', 'Money type, direction, or integer amount is invalid.')
        end
        local snapshot, snapshotError = readPlayerInternal(playerSource)
        if not snapshot then return nil, snapshotError end
        local playerAccount = snapshot.accountIds[moneyType]
        if not playerAccount then
            return nil, bridgeError('MONEY_ACCOUNT_NOT_FOUND', ('No active %s account is mapped.'):format(moneyType))
        end
        local convarName = options.counterpartyConvars and options.counterpartyConvars[moneyType]
        local counterparty = type(convarName) == 'string' and GetConvar(convarName, '') or ''
        if not validUuid(counterparty) then
            return nil, bridgeError(
                'MONEY_COUNTERPARTY_NOT_CONFIGURED',
                ('A reviewed %s counterparty account must be configured before legacy mutations are enabled.'):format(moneyType)
            )
        end
        local sourceAccount = direction == 'add' and counterparty or playerAccount
        local destinationAccount = direction == 'add' and playerAccount or counterparty
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        local result, transferError = resolved.RPC.call('synex.accounts.transfer', '1.0.0', {
            idempotency_key = uuidV4(),
            source_account_id = sourceAccount,
            destination_account_id = destinationAccount,
            amount_minor = amount,
            reference = type(reason) == 'string' and reason:sub(1, 128) or 'legacy_bridge',
            actor_ref = ('resource:%s'):format(consumer):sub(1, 128),
            metadata_json = json.encode({ framework = framework, compatibility = true }),
        }, { timeoutMs = 5000 })
        if not result then return nil, transferError end
        return true, nil
    end

    function adapter:setMoney(consumer, playerSource, moneyType, targetAmount, reason)
        if not finiteInteger(targetAmount, 0, 9007199254740991) then
            return nil, bridgeError('INVALID_MONEY_OPERATION', 'The target amount must be a non-negative safe integer.')
        end
        local snapshot, snapshotError = self:readPlayer(consumer, playerSource)
        if not snapshot then return nil, snapshotError end
        local current = snapshot.money[moneyType]
        if not finiteInteger(current, 0, 9007199254740991) then
            return nil, bridgeError('MONEY_ACCOUNT_NOT_FOUND', 'The requested balance is unavailable.')
        end
        if current == targetAmount then return true, nil end
        local direction = targetAmount > current and 'add' or 'remove'
        return self:changeMoney(consumer, playerSource, moneyType, direction, math.abs(targetAmount - current), reason)
    end

    function adapter:registerCallback(consumer, name, handler)
        local allowed, authorizationError = authorize(consumer, 'callbacks', 'callback.register')
        if not allowed then return nil, authorizationError end
        if not validCallbackName(name) or type(handler) ~= 'function' then
            return nil, bridgeError('INVALID_CALLBACK', 'Callback name or handler is invalid.')
        end
        local previous = callbacks[name]
        if previous and previous.owner ~= consumer then
            return nil, bridgeError('CALLBACK_NAME_CONFLICT', 'Another resource already owns this callback name.')
        end
        callbacks[name] = { owner = consumer, handler = handler }
        return true, nil
    end

    function adapter:usageSnapshot(consumer)
        local result = {}
        for _, entry in pairs(usage) do
            if consumer == nil or entry.resource == consumer then result[#result + 1] = safeCopy(entry) end
        end
        table.sort(result, function(left, right)
            if left.resource == right.resource then return left.operation < right.operation end
            return left.resource < right.resource
        end)
        return { framework = framework, deprecated = true, entries = result, truncated = usageSize >= LIMITS.maximumUsageEntries }
    end

    local function takeCallbackToken(playerSource)
        local now = GetGameTimer()
        local bucket = buckets[playerSource]
        if not bucket or now < bucket.updatedAt then
            bucket = { tokens = LIMITS.callbackBurst, updatedAt = now }
            buckets[playerSource] = bucket
        end
        local elapsed = math.max(0, now - bucket.updatedAt) / 1000
        bucket.tokens = math.min(LIMITS.callbackBurst, bucket.tokens + elapsed * LIMITS.callbackRate)
        bucket.updatedAt = now
        if bucket.tokens < 1 then return false end
        bucket.tokens = bucket.tokens - 1
        return true
    end

    local function sessionMatches(playerSource, sessionId, generation)
        local resolved = getApi()
        if not resolved then return false end
        local session = resolved.Players.getBySource(playerSource)
        return type(session) == 'table' and session.id == sessionId
            and session.sourceGeneration == generation and session.state == 'ACTIVE'
    end

    RegisterNetEvent(requestEvent, function(requestId, callbackName, arguments)
        local playerSource = source
        if not validateSource(playerSource) or not takeCallbackToken(playerSource)
            or not boundedString(requestId, 64) or #requestId < 8 or not requestId:match('^[A-Za-z0-9_-]+$')
            or not validCallbackName(callbackName) or type(arguments) ~= 'table'
            or not finiteInteger(arguments.n or #arguments, 0, LIMITS.callbackArguments) then return end
        local encodedOk, encoded = pcall(json.encode, arguments)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > LIMITS.callbackBytes then return end
        local entry = callbacks[callbackName]
        if not entry then
            TriggerClientEvent(responseEvent, playerSource, requestId, false, bridgeError('CALLBACK_NOT_FOUND', 'Callback is not registered.'))
            return
        end
        local allowed = authorize(entry.owner, 'callbacks', 'callback.invoke')
        if not allowed then
            TriggerClientEvent(responseEvent, playerSource, requestId, false, bridgeError('CALLBACK_DENIED', 'Callback owner is not authorized.'))
            return
        end
        local resolved = getApi()
        if not resolved then return end
        local session = resolved.Players.getBySource(playerSource)
        if type(session) ~= 'table' or session.state ~= 'ACTIVE' then return end
        local pendingCount = pendingBySource[playerSource] or 0
        if pendingCount >= LIMITS.callbackPendingPerSource then return end
        local pendingKey = ('%d:%s:%s'):format(playerSource, tostring(session.sourceGeneration), requestId)
        if pending[pendingKey] then return end
        pending[pendingKey] = true
        pendingBySource[playerSource] = pendingCount + 1
        local completed = false
        local function complete(ok, payload)
            if completed or not pending[pendingKey] then return end
            completed = true
            pending[pendingKey] = nil
            pendingBySource[playerSource] = math.max(0, (pendingBySource[playerSource] or 1) - 1)
            local safePayload = safeCopy(payload)
            local payloadOk, payloadJson = pcall(json.encode, safePayload)
            if not payloadOk or #payloadJson > LIMITS.callbackBytes then
                ok, safePayload = false, bridgeError('CALLBACK_RESPONSE_INVALID', 'Callback response exceeded bridge limits.')
            end
            if sessionMatches(playerSource, session.id, session.sourceGeneration) then
                TriggerClientEvent(responseEvent, playerSource, requestId, ok == true, safePayload)
            end
        end
        SetTimeout(LIMITS.callbackTimeoutMs, function()
            complete(false, bridgeError('CALLBACK_TIMEOUT', 'Compatibility callback timed out.', true))
        end)
        local response = function(...)
            local packed = table.pack(...)
            complete(true, packed)
        end
        local ok = xpcall(function()
            entry.handler(playerSource, response, table.unpack(arguments, 1, arguments.n or #arguments))
        end, debug.traceback)
        if not ok then complete(false, bridgeError('CALLBACK_FAILED', 'Compatibility callback failed.')) end
    end)

    function adapter:registerLifecycle(toLegacyPlayerData, events)
        assert(type(toLegacyPlayerData) == 'function' and type(events) == 'table', 'lifecycle mapping is invalid')
        local resolved, resolveError = getApi()
        if not resolved then return nil, resolveError end
        return resolved.Characters.registerLifecycleParticipant({
            name = resourceName,
            priority = -100,
            required = false,
            prepare = function(context)
                return { source = context and context.session and context.session.source }
            end,
            commit = function(prepared)
                local playerSource = prepared and prepared.source
                local snapshot = readPlayerInternal(playerSource)
                if not snapshot then return true end
                local playerData = safeCopy(toLegacyPlayerData(snapshot))
                if events.clientLoaded then TriggerClientEvent(events.clientLoaded, playerSource, playerData) end
                if events.serverLoaded then TriggerEvent(events.serverLoaded, playerSource, playerData) end
                return true
            end,
            rollback = function() return true end,
            unload = function(context)
                local playerSource = context and context.session and context.session.source
                if validateSource(playerSource) then
                    if events.clientUnloaded then TriggerClientEvent(events.clientUnloaded, playerSource) end
                    if events.serverUnloaded then TriggerEvent(events.serverUnloaded, playerSource) end
                end
                return true
            end,
        })
    end

    AddEventHandler('playerDropped', function()
        buckets[source] = nil
        pendingBySource[source] = nil
        local prefix = tostring(source) .. ':'
        for key in pairs(pending) do
            if key:sub(1, #prefix) == prefix then pending[key] = nil end
        end
    end)

    AddEventHandler('onResourceStop', function(stoppedResource)
        if stoppedResource == resourceName then return end
        for name, entry in pairs(callbacks) do
            if entry.owner == stoppedResource then callbacks[name] = nil end
        end
        local prefix = stoppedResource .. ':'
        for key in pairs(usage) do
            if key:sub(1, #prefix) == prefix then usage[key] = nil; usageSize = math.max(0, usageSize - 1) end
        end
        for key in pairs(warningTimes) do
            if key:sub(1, #prefix) == prefix then warningTimes[key] = nil end
        end
    end)

    return adapter
end

SynexBridgeNative = Native

return Native
