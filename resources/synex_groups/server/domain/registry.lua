local Registry = {}

local DEFAULT_MAXIMUM_ENTRIES = 1024
local DEFAULT_MAXIMUM_PER_OWNER = 128

local function domainError(code, message, details)
    return { code = code, message = message, retryable = false, details = details }
end

local function validOwner(value)
    return type(value) == 'string' and #value >= 3 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
end

local function validEpoch(value)
    return type(value) == 'number' and math.type(value) == 'integer' and value >= 1
end

local function validKey(value)
    return type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[a-z][a-z0-9_.:%-]*$') ~= nil
end

function Registry.create(options)
    options = options or {}
    if type(options) ~= 'table' or getmetatable(options) ~= nil then
        error('registry options must be a plain object', 2)
    end
    for key in pairs(options) do
        if key ~= 'maximumEntries' and key ~= 'maximumPerOwner' then
            error('registry options contain an unknown property', 2)
        end
    end
    local maximumEntries = options.maximumEntries or DEFAULT_MAXIMUM_ENTRIES
    local maximumPerOwner = options.maximumPerOwner or DEFAULT_MAXIMUM_PER_OWNER
    if type(maximumEntries) ~= 'number' or math.type(maximumEntries) ~= 'integer'
        or maximumEntries < 1 or maximumEntries > 16384
        or type(maximumPerOwner) ~= 'number' or math.type(maximumPerOwner) ~= 'integer'
        or maximumPerOwner < 1 or maximumPerOwner > maximumEntries then
        error('registry limits are outside supported bounds', 2)
    end

    local entries, ownerEntries, ownerStates, size, tokenSequence = {}, {}, {}, 0, 0
    local registry = {}

    local function ownerKey(owner, epoch)
        return owner .. ':' .. tostring(epoch)
    end

    function registry:register(owner, epoch, key, value)
        if not validOwner(owner) or not validEpoch(epoch) or not validKey(key) or value == nil then
            return nil, domainError('REGISTRY_ENTRY_INVALID', 'Registry owner, epoch, key, or value is invalid.')
        end
        local existing = entries[key]
        if existing then
            return nil, domainError('REGISTRY_KEY_EXISTS', 'Registry key is already owned.', {
                key = key, owner = existing.owner
            })
        end
        if size >= maximumEntries then
            return nil, domainError('REGISTRY_CAPACITY_EXCEEDED', 'Registry capacity is exhausted.')
        end
        local ownershipKey = ownerKey(owner, epoch)
        local owned = ownerEntries[ownershipKey]
        if not owned then
            owned = { count = 0, keys = {} }
            ownerEntries[ownershipKey] = owned
        end
        if owned.count >= maximumPerOwner then
            return nil, domainError('REGISTRY_OWNER_CAPACITY_EXCEEDED', 'Registry owner capacity is exhausted.', {
                owner = owner, epoch = epoch
            })
        end
        tokenSequence = tokenSequence + 1
        local entry = {
            key = key, value = value, owner = owner, epoch = epoch, token = tokenSequence
        }
        entries[key] = entry
        owned.keys[key] = true
        owned.count = owned.count + 1
        size = size + 1
        return { key = key, owner = owner, epoch = epoch, token = entry.token }, nil
    end

    function registry:replace(owner, epoch, key, value)
        if not validOwner(owner) or not validEpoch(epoch) or not validKey(key) or value == nil then
            return nil, domainError('REGISTRY_ENTRY_INVALID',
                'Registry owner, epoch, key, or value is invalid.')
        end
        local existing = entries[key]
        if existing and existing.owner ~= owner then
            return nil, domainError('REGISTRY_OWNER_MISMATCH',
                'Registry entry belongs to another owner.', {
                    key = key, owner = existing.owner
                })
        end
        if not existing and size >= maximumEntries then
            return nil, domainError('REGISTRY_CAPACITY_EXCEEDED',
                'Registry capacity is exhausted.')
        end
        local ownershipKey = ownerKey(owner, epoch)
        local owned = ownerEntries[ownershipKey]
        local alreadyInEpoch = existing ~= nil and existing.epoch == epoch
        if not alreadyInEpoch and owned and owned.count >= maximumPerOwner then
            return nil, domainError('REGISTRY_OWNER_CAPACITY_EXCEEDED',
                'Registry owner capacity is exhausted.', { owner = owner, epoch = epoch })
        end

        if existing then
            local previousOwnershipKey = ownerKey(existing.owner, existing.epoch)
            local previousOwned = ownerEntries[previousOwnershipKey]
            if previousOwned then
                previousOwned.keys[key] = nil
                previousOwned.count = previousOwned.count - 1
                if previousOwned.count == 0 then ownerEntries[previousOwnershipKey] = nil end
            end
        else
            size = size + 1
        end
        owned = ownerEntries[ownershipKey]
        if not owned then
            owned = { count = 0, keys = {} }
            ownerEntries[ownershipKey] = owned
        end
        if not owned.keys[key] then
            owned.keys[key] = true
            owned.count = owned.count + 1
        end
        tokenSequence = tokenSequence + 1
        entries[key] = {
            key = key, value = value, owner = owner, epoch = epoch, token = tokenSequence
        }
        return { key = key, owner = owner, epoch = epoch, token = tokenSequence }, nil
    end

    function registry:get(key)
        if not validKey(key) then
            return nil, domainError('REGISTRY_KEY_INVALID', 'Registry key is invalid.')
        end
        local entry = entries[key]
        if not entry then return nil, domainError('REGISTRY_KEY_NOT_FOUND', 'Registry key is not registered.') end
        if ownerStates[ownerKey(entry.owner, entry.epoch)] == false then
            return nil, domainError('REGISTRY_KEY_NOT_FOUND',
                'Registry key is not registered.')
        end
        return entry.value, nil, {
            key = entry.key, owner = entry.owner, epoch = entry.epoch, token = entry.token
        }
    end

    function registry:setOwnerActive(owner, epoch, active)
        if not validOwner(owner) or not validEpoch(epoch) or type(active) ~= 'boolean' then
            return nil, domainError('REGISTRY_OWNER_INVALID',
                'Registry owner state is invalid.')
        end
        ownerStates[ownerKey(owner, epoch)] = active
        return true, nil
    end

    function registry:remove(owner, epoch, key, token)
        if not validOwner(owner) or not validEpoch(epoch) or not validKey(key)
            or (token ~= nil and (type(token) ~= 'number' or math.type(token) ~= 'integer' or token < 1)) then
            return nil, domainError('REGISTRY_ENTRY_INVALID', 'Registry removal identity is invalid.')
        end
        local entry = entries[key]
        if not entry then return nil, domainError('REGISTRY_KEY_NOT_FOUND', 'Registry key is not registered.') end
        if entry.owner ~= owner or entry.epoch ~= epoch or (token ~= nil and entry.token ~= token) then
            return nil, domainError('REGISTRY_OWNER_MISMATCH', 'Registry entry belongs to another owner epoch.')
        end
        entries[key] = nil
        local ownershipKey = ownerKey(owner, epoch)
        local owned = ownerEntries[ownershipKey]
        if owned then
            owned.keys[key] = nil
            owned.count = owned.count - 1
            if owned.count == 0 then ownerEntries[ownershipKey] = nil end
        end
        size = size - 1
        return true, nil
    end

    function registry:listOwner(owner, epoch)
        if not validOwner(owner) or not validEpoch(epoch) then
            return nil, domainError('REGISTRY_OWNER_INVALID', 'Registry owner identity is invalid.')
        end
        local owned = ownerEntries[ownerKey(owner, epoch)]
        local keys = {}
        if owned then
            for key in pairs(owned.keys) do keys[#keys + 1] = key end
            table.sort(keys)
        end
        local result = {}
        for _, key in ipairs(keys) do
            local entry = entries[key]
            result[#result + 1] = {
                key = key, owner = entry.owner, epoch = entry.epoch, token = entry.token
            }
        end
        return result, nil
    end

    function registry:latestEpoch(owner)
        if not validOwner(owner) then
            return nil, domainError('REGISTRY_OWNER_INVALID', 'Registry owner identity is invalid.')
        end
        local prefix, latest = owner .. ':', nil
        for key in pairs(ownerEntries) do
            if key:sub(1, #prefix) == prefix then
                local epoch = tonumber(key:sub(#prefix + 1))
                if epoch and (latest == nil or epoch > latest) then latest = epoch end
            end
        end
        return latest, nil
    end

    function registry:cleanupOwner(owner, epoch)
        if not validOwner(owner) or (epoch ~= nil and not validEpoch(epoch)) then
            return nil, domainError('REGISTRY_OWNER_INVALID', 'Registry owner identity is invalid.')
        end
        local ownershipKeys = {}
        if epoch ~= nil then
            ownershipKeys[1] = ownerKey(owner, epoch)
        else
            local prefix = owner .. ':'
            for key in pairs(ownerEntries) do
                if key:sub(1, #prefix) == prefix then ownershipKeys[#ownershipKeys + 1] = key end
            end
            table.sort(ownershipKeys)
        end
        local removed = 0
        for _, ownershipKey in ipairs(ownershipKeys) do
            local owned = ownerEntries[ownershipKey]
            if owned then
                local keys = {}
                for key in pairs(owned.keys) do keys[#keys + 1] = key end
                for _, key in ipairs(keys) do
                    if entries[key] then
                        entries[key] = nil
                        size = size - 1
                        removed = removed + 1
                    end
                end
                ownerEntries[ownershipKey] = nil
            end
        end
        return removed, nil
    end

    function registry:cleanupOwnerExcept(owner, epoch)
        if not validOwner(owner) or not validEpoch(epoch) then
            return nil, domainError('REGISTRY_OWNER_INVALID', 'Registry owner identity is invalid.')
        end
        local prefix, ownershipKeys = owner .. ':', {}
        for key in pairs(ownerEntries) do
            if key:sub(1, #prefix) == prefix and key ~= ownerKey(owner, epoch) then
                ownershipKeys[#ownershipKeys + 1] = key
            end
        end
        table.sort(ownershipKeys)
        local removed = 0
        for _, ownershipKey in ipairs(ownershipKeys) do
            local owned = ownerEntries[ownershipKey]
            if owned then
                local keys = {}
                for key in pairs(owned.keys) do keys[#keys + 1] = key end
                for _, key in ipairs(keys) do
                    if entries[key] then
                        entries[key] = nil
                        size = size - 1
                        removed = removed + 1
                    end
                end
                ownerEntries[ownershipKey] = nil
            end
        end
        return removed, nil
    end

    function registry:stats()
        local ownerEpochs = 0
        for _ in pairs(ownerEntries) do ownerEpochs = ownerEpochs + 1 end
        return {
            entries = size,
            ownerEpochs = ownerEpochs,
            maximumEntries = maximumEntries,
            maximumPerOwner = maximumPerOwner
        }
    end

    return registry
end

return Registry
