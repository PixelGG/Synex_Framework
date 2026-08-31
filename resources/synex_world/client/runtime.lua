local Limits = assert(SynexWorldLimits, 'world limits must be loaded before client runtime')
local Validation = assert(SynexWorldValidation,
    'world validation must be loaded before client runtime')
local SCHEMA_VERSION = Limits.schemaVersion
local RECONCILE_INTERVAL_MS = 250
local IPL_RETRY_MS = 2000
local TRANSITION_RETRY_MS = Limits.transitionGrantTtlMs
local MAX_SLICE_BYTES = Limits.maximumSliceBytes
local MAX_MESSAGE_BYTES = 16384
local MAX_VALUE_DEPTH = 8
local MAX_VALUE_ENTRIES = 8192
local MAX_VALUE_STRING_BYTES = Limits.maximumStateBytes
local MAX_WORLD_KEY_BYTES = Limits.maximumKeyLength
local MAX_TAG_BYTES = Limits.maximumTagLength
local MAX_COORDINATE = Limits.coordinateMaximum
local MAX_ANCHOR_RESULTS = Limits.maximumQueryResults
local MAX_RECENT_GRANTS = 64

local definitionLimits = {
    regions = 64,
    locations = 64,
    interiors = 64,
    rooms = 128,
    zones = 256,
    anchors = 512,
    doors = 256,
    portals = 128,
}

local definitionKinds = {
    regions = 'region',
    locations = 'location',
    interiors = 'interior',
    rooms = 'room',
    zones = 'zone',
    anchors = 'anchor',
    doors = 'door',
    portals = 'portal',
}

local sliceKeys = {
    schemaVersion = true,
    revision = true,
    context = true,
    bundleRevisions = true,
    state = true,
    regions = true,
    locations = true,
    interiors = true,
    rooms = true,
    zones = true,
    anchors = true,
    doors = true,
    portals = true,
    ipls = true,
    interiorSets = true,
}

local doorStates = {
    DISABLED = 1,
    LOCKED = 1,
    UNLOCKED = 0,
}

local currentSlice = {
    context = { authority = 'OBSERVED' },
    bundleRevisions = {},
    state = {},
}
local currentRevision = 0
local cachedByKind = {}
local doorRuntime = {}
local iplRuntime = {}
local interiorRuntime = {}
local recentGrants = {}
local recentGrantOrder = {}
local pendingTransition = nil
local runtimeActive = true
local monotonicNow = Validation.monotonicClock(function()
    return type(GetGameTimer) == 'function' and GetGameTimer() or 0
end)

local function finiteNumber(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integerInRange(value, minimum, maximum)
    return finiteNumber(value) and value == math.floor(value)
        and value >= minimum and value <= maximum
end

local function uint32(value)
    if not integerInRange(value, -2147483648, 4294967295) then return nil end
    if value < 0 then value = value + 4294967296 end
    return value
end

local function boundedString(value, maximum, pattern)
    return type(value) == 'string' and #value >= 1 and #value <= maximum
        and not value:find('%c') and (pattern == nil or value:match(pattern) ~= nil)
end

local function validWorldKey(value)
    return boundedString(value, MAX_WORLD_KEY_BYTES,
        '^[a-z][a-z0-9_]*:[a-z0-9][a-z0-9_.%-]*$')
end

local function contiguousCount(value, maximum)
    if type(value) ~= 'table' then return nil end
    local count = 0
    for key in next, value do
        if not integerInRange(key, 1, maximum) then return nil end
        count = count + 1
        if count > maximum then return nil end
    end
    for index = 1, count do
        if rawget(value, index) == nil then return nil end
    end
    return count
end

local function validPosition(value, allowHeading)
    if type(value) ~= 'table' then return false end
    for key in next, value do
        if key ~= 'x' and key ~= 'y' and key ~= 'z'
            and (not allowHeading or key ~= 'heading') then return false end
    end
    return finiteNumber(rawget(value, 'x')) and finiteNumber(rawget(value, 'y'))
        and finiteNumber(rawget(value, 'z'))
        and rawget(value, 'x') >= Limits.coordinateMinimum
        and rawget(value, 'x') <= MAX_COORDINATE
        and rawget(value, 'y') >= Limits.coordinateMinimum
        and rawget(value, 'y') <= MAX_COORDINATE
        and rawget(value, 'z') >= Limits.coordinateMinimum
        and rawget(value, 'z') <= MAX_COORDINATE
end

local function validBoundedValue(value, depth, budget, seen)
    local valueType = type(value)
    if valueType == 'nil' or valueType == 'boolean' then return true end
    if valueType == 'number' then return finiteNumber(value) end
    if valueType == 'string' then
        if #value > MAX_VALUE_STRING_BYTES or value:find('%c') then return false end
        budget.stringBytes = budget.stringBytes + #value
        return budget.stringBytes <= MAX_SLICE_BYTES
    end
    if valueType ~= 'table' or depth >= MAX_VALUE_DEPTH or seen[value] then return false end
    seen[value] = true
    for key, nested in next, value do
        local keyType = type(key)
        if keyType == 'string' then
            if #key < 1 or #key > MAX_WORLD_KEY_BYTES or key:find('%c') then
                seen[value] = nil
                return false
            end
            budget.stringBytes = budget.stringBytes + #key
        elseif keyType ~= 'number' or not integerInRange(key, 1, MAX_VALUE_ENTRIES) then
            seen[value] = nil
            return false
        end
        budget.entries = budget.entries + 1
        if budget.entries > MAX_VALUE_ENTRIES or budget.stringBytes > MAX_SLICE_BYTES
            or not validBoundedValue(nested, depth + 1, budget, seen) then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

local function encodedWithin(value, maximum)
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then return false end
    local ok, encoded = pcall(json.encode, value)
    return ok and type(encoded) == 'string' and #encoded <= maximum
end

local function copyValue(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return nil end
    local copied = {}
    seen[value] = copied
    for key, nested in next, value do
        copied[key] = copyValue(nested, seen)
    end
    seen[value] = nil
    return copied
end

local function validateDefinitionList(list, pluralKind)
    local count = contiguousCount(list, definitionLimits[pluralKind])
    if count == nil then return nil end
    local seenKeys = {}
    for index = 1, count do
        local definition = rawget(list, index)
        if type(definition) ~= 'table' or not validWorldKey(rawget(definition, 'key'))
            or seenKeys[rawget(definition, 'key')]
            or (rawget(definition, 'kind') ~= nil
                and rawget(definition, 'kind') ~= definitionKinds[pluralKind])
            or (rawget(definition, 'revision') ~= nil
                and not integerInRange(rawget(definition, 'revision'), 1, 2147483647))
            or (rawget(definition, 'position') ~= nil
                and not validPosition(rawget(definition, 'position'))) then return nil end
        local tags = rawget(definition, 'tags')
        if tags ~= nil then
            local tagCount = contiguousCount(tags, Limits.maximumTags)
            if tagCount == nil then return nil end
            for tagIndex = 1, tagCount do
                if not boundedString(rawget(tags, tagIndex), MAX_TAG_BYTES,
                    '^[a-z][a-z0-9_.%-]*$') then return nil end
            end
        end
        seenKeys[rawget(definition, 'key')] = true
    end
    return count
end

local function cleanupDoor(entry)
    if not entry.registeredHere then return end
    local registered = false
    if type(IsDoorRegisteredWithSystem) == 'function' then
        local ok, result = pcall(IsDoorRegisteredWithSystem, entry.doorHash)
        registered = ok and result == true
    end
    if registered and type(DoorSystemGetIsPhysicsLoaded) == 'function'
        and type(DoorSystemSetDoorState) == 'function' then
        local ok, loaded = pcall(DoorSystemGetIsPhysicsLoaded, entry.doorHash)
        if ok and loaded == true then
            pcall(DoorSystemSetDoorState, entry.doorHash, 0, false, true)
        end
    end
    if registered and type(RemoveDoorFromSystem) == 'function' then
        pcall(RemoveDoorFromSystem, entry.doorHash)
    end
end

local function clearRuntime()
    for _, entry in pairs(doorRuntime) do cleanupDoor(entry) end
    for name, entry in pairs(iplRuntime) do
        if entry.requestedHere and type(RemoveIpl) == 'function' then
            pcall(RemoveIpl, name)
        end
    end
    for _, entry in pairs(interiorRuntime) do
        if entry.activatedHere and type(IsValidInterior) == 'function'
            and type(DeactivateInteriorEntitySet) == 'function' then
            local ok, valid = pcall(IsValidInterior, entry.interiorId)
            if ok and valid == true then
                pcall(DeactivateInteriorEntitySet, entry.interiorId, entry.name)
                if type(RefreshInterior) == 'function' then
                    pcall(RefreshInterior, entry.interiorId)
                end
            end
        end
    end
    doorRuntime = {}
    iplRuntime = {}
    interiorRuntime = {}
end

local function reconcileRuntime()
    for _, entry in pairs(doorRuntime) do
        local registered = false
        if type(IsDoorRegisteredWithSystem) == 'function' then
            local ok, result = pcall(IsDoorRegisteredWithSystem, entry.doorHash)
            registered = ok and result == true
        end
        if not registered and type(AddDoorToSystem) == 'function' then
            local ok = pcall(AddDoorToSystem, entry.doorHash, entry.modelHash,
                entry.position.x, entry.position.y, entry.position.z, false, false, false)
            if ok then
                entry.registeredHere = true
                registered = true
                entry.appliedRevision = nil
            end
        end
        if registered and type(DoorSystemGetIsPhysicsLoaded) == 'function'
            and type(DoorSystemSetDoorState) == 'function' then
            local ok, loaded = pcall(DoorSystemGetIsPhysicsLoaded, entry.doorHash)
            if ok and loaded == true and entry.appliedRevision ~= entry.revision then
                local applied = pcall(DoorSystemSetDoorState, entry.doorHash,
                    doorStates[entry.state], false, true)
                if applied and entry.openRatio ~= nil
                    and type(DoorSystemSetOpenRatio) == 'function' then
                    applied = pcall(DoorSystemSetOpenRatio, entry.doorHash,
                        entry.openRatio, false, true)
                end
                if applied and entry.automaticDistance ~= nil
                    and type(DoorSystemSetAutomaticDistance) == 'function' then
                    applied = pcall(DoorSystemSetAutomaticDistance, entry.doorHash,
                        entry.automaticDistance, false, true)
                end
                if applied then entry.appliedRevision = entry.revision end
            end
        end
    end

    local now = monotonicNow()
    for name, entry in pairs(iplRuntime) do
        if entry.refCount <= 0 then
            if entry.requestedHere and type(RemoveIpl) == 'function' then
                pcall(RemoveIpl, name)
            end
            iplRuntime[name] = nil
        else
            local active = false
            if type(IsIplActive) == 'function' then
                local ok, result = pcall(IsIplActive, name)
                active = ok and result == true
            end
            if not active and (entry.lastRequestAt == nil
                or now - entry.lastRequestAt >= IPL_RETRY_MS)
                and type(RequestIpl) == 'function' then
                if pcall(RequestIpl, name) then
                    entry.lastRequestAt = now
                    entry.requestedHere = true
                end
            end
        end
    end

    for key, entry in pairs(interiorRuntime) do
        if entry.refCount <= 0 then
            if entry.activatedHere and type(IsValidInterior) == 'function'
                and type(DeactivateInteriorEntitySet) == 'function' then
                local ok, valid = pcall(IsValidInterior, entry.interiorId)
                if ok and valid == true then
                    pcall(DeactivateInteriorEntitySet, entry.interiorId, entry.name)
                    if type(RefreshInterior) == 'function' then
                        pcall(RefreshInterior, entry.interiorId)
                    end
                end
            end
            interiorRuntime[key] = nil
        elseif type(IsValidInterior) == 'function' then
            local ok, valid = pcall(IsValidInterior, entry.interiorId)
            if ok and valid == true then
                local active = false
                if type(IsInteriorEntitySetActive) == 'function' then
                    local stateOk, state = pcall(IsInteriorEntitySetActive,
                        entry.interiorId, entry.name)
                    active = stateOk and state == true
                end
                local changed = false
                if not active and type(ActivateInteriorEntitySet) == 'function' then
                    changed = pcall(ActivateInteriorEntitySet, entry.interiorId, entry.name)
                    if changed then entry.activatedHere = true end
                end
                if entry.color ~= nil and entry.appliedColor ~= entry.color
                    and type(SetInteriorEntitySetColor) == 'function' then
                    if pcall(SetInteriorEntitySetColor, entry.interiorId,
                        entry.name, entry.color) then
                        entry.appliedColor = entry.color
                        changed = true
                    end
                end
                if changed and type(RefreshInterior) == 'function' then
                    pcall(RefreshInterior, entry.interiorId)
                end
            end
        end
    end
end

local function applyPendingTransition()
    if pendingTransition == nil then return end
    local now = monotonicNow()
    if now > pendingTransition.deadline then
        pendingTransition = nil
        return
    end
    if type(PlayerPedId) ~= 'function' or type(SetEntityCoordsNoOffset) ~= 'function' then return end
    local ped = PlayerPedId()
    if not integerInRange(ped, 1, 2147483647) then return end
    local destination = pendingTransition.destination
    SetEntityCoordsNoOffset(ped, destination.x, destination.y, destination.z,
        true, true, true)
    if destination.heading ~= nil and type(SetEntityHeading) == 'function' then
        SetEntityHeading(ped, destination.heading)
    end
    recentGrants[pendingTransition.grantId] = true
    recentGrantOrder[#recentGrantOrder + 1] = pendingTransition.grantId
    if #recentGrantOrder > MAX_RECENT_GRANTS then
        recentGrants[table.remove(recentGrantOrder, 1)] = nil
    end
    pendingTransition = nil
end

RegisterNetEvent('synex_world:client:replace_slice', function(message)
    if source ~= 65535 or type(message) ~= 'table' or message.schemaVersion ~= SCHEMA_VERSION
        or not integerInRange(message.revision, 1, 2147483647)
        or message.revision <= currentRevision then return end
    for key in next, message do
        if not sliceKeys[key] then return end
    end
    if type(message.context) ~= 'table' or type(message.bundleRevisions or {}) ~= 'table'
        or type(message.state or {}) ~= 'table'
        or not validBoundedValue(message, 0,
            { entries = 0, stringBytes = 0 }, {})
        or not encodedWithin(message, MAX_SLICE_BYTES) then return end

    local counts = {}
    for pluralKind in pairs(definitionKinds) do
        local list = message[pluralKind] or {}
        counts[pluralKind] = validateDefinitionList(list, pluralKind)
        if counts[pluralKind] == nil then return end
    end
    local totalDefinitions = 0
    for _, count in pairs(counts) do totalDefinitions = totalDefinitions + count end
    if totalDefinitions > Limits.maximumSliceObjects then return end

    local desiredDoors = {}
    local seenDoorHashes = {}
    local doors = message.doors or {}
    for doorIndex = 1, counts.doors do
        local door = doors[doorIndex]
        if doorStates[door.state] == nil
            or not integerInRange(door.revision or message.revision, 1, 2147483647) then return end
        local leafCount = contiguousCount(door.leaves, 8)
        if leafCount == nil or leafCount < 1 then return end
        for leafIndex = 1, leafCount do
            local leaf = door.leaves[leafIndex]
            local doorHash = type(leaf) == 'table' and uint32(leaf.doorHash) or nil
            if type(leaf) ~= 'table' or doorHash == nil
                or not integerInRange(leaf.modelHash, -2147483648, 4294967295)
                or not validPosition(leaf.position)
                or seenDoorHashes[doorHash]
                or (leaf.openRatio ~= nil and (not finiteNumber(leaf.openRatio)
                    or leaf.openRatio < -1.0 or leaf.openRatio > 1.0))
                or (leaf.automaticDistance ~= nil
                    and (not finiteNumber(leaf.automaticDistance)
                        or leaf.automaticDistance < 0.0
                        or leaf.automaticDistance > 100.0)) then return end
            seenDoorHashes[doorHash] = true
            desiredDoors[doorHash] = {
                doorHash = doorHash,
                modelHash = leaf.modelHash,
                position = copyValue(leaf.position),
                doorKey = door.key,
                state = door.state,
                revision = door.stateVersion or 0,
                definitionRevision = door.revision,
                openRatio = leaf.openRatio,
                automaticDistance = leaf.automaticDistance,
                registeredHere = false,
                appliedRevision = nil,
            }
        end
    end

    local desiredIpls = {}
    local ipls = message.ipls or {}
    local iplCount = contiguousCount(ipls, Limits.maximumClientIpls)
    if iplCount == nil then return end
    for index = 1, iplCount do
        local entry = ipls[index]
        local name = type(entry) == 'string' and entry or type(entry) == 'table' and entry.name
        local refCount = type(entry) == 'table' and (entry.refCount or 1) or 1
        if not boundedString(name, 96)
            or not integerInRange(refCount, 1, Limits.maximumClientRequirementRefCount)
            or desiredIpls[name] ~= nil then return end
        desiredIpls[name] = refCount
    end

    local desiredInteriorSets = {}
    local interiorSets = message.interiorSets or {}
    local interiorCount = contiguousCount(interiorSets, Limits.maximumClientInteriorSets)
    if interiorCount == nil then return end
    for index = 1, interiorCount do
        local entry = interiorSets[index]
        if type(entry) ~= 'table' or not integerInRange(entry.interiorId, 0, 2147483647)
            or not boundedString(entry.name, 64)
            or not integerInRange(entry.refCount or 1, 1,
                Limits.maximumClientRequirementRefCount)
            or (entry.color ~= nil and not integerInRange(entry.color, 0, 255)) then return end
        local key = tostring(entry.interiorId) .. ':' .. entry.name
        if desiredInteriorSets[key] ~= nil then return end
        desiredInteriorSets[key] = {
            interiorId = entry.interiorId,
            name = entry.name,
            refCount = entry.refCount or 1,
            color = entry.color,
        }
    end

    for doorHash, existing in pairs(doorRuntime) do
        local desired = desiredDoors[doorHash]
        if desired == nil or desired.modelHash ~= existing.modelHash
            or desired.position.x ~= existing.position.x
            or desired.position.y ~= existing.position.y
            or desired.position.z ~= existing.position.z then
            cleanupDoor(existing)
            doorRuntime[doorHash] = nil
        end
    end
    for doorHash, desired in pairs(desiredDoors) do
        local existing = doorRuntime[doorHash]
        if existing ~= nil then
            desired.registeredHere = existing.registeredHere
            if existing.state == desired.state and existing.openRatio == desired.openRatio
                and existing.automaticDistance == desired.automaticDistance then
                desired.appliedRevision = existing.appliedRevision
            end
        end
        doorRuntime[doorHash] = desired
    end

    for name, existing in pairs(iplRuntime) do
        existing.refCount = desiredIpls[name] or 0
        desiredIpls[name] = nil
    end
    for name, refCount in pairs(desiredIpls) do
        iplRuntime[name] = { refCount = refCount }
    end

    for key, existing in pairs(interiorRuntime) do
        local desired = desiredInteriorSets[key]
        if desired == nil then
            existing.refCount = 0
        else
            existing.refCount = desired.refCount
            existing.color = desired.color
            desiredInteriorSets[key] = nil
        end
    end
    for key, desired in pairs(desiredInteriorSets) do
        interiorRuntime[key] = desired
    end

    local previousContext = copyValue(currentSlice.context or {})
    local nextContext = copyValue(message.context)
    nextContext.authority = 'OBSERVED'
    local previousFingerprint = encodedWithin(previousContext, MAX_MESSAGE_BYTES)
        and json.encode(previousContext) or ''
    local nextFingerprint = encodedWithin(nextContext, MAX_MESSAGE_BYTES)
        and json.encode(nextContext) or ''

    currentSlice = copyValue(message)
    currentSlice.context = copyValue(nextContext)
    currentSlice.bundleRevisions = currentSlice.bundleRevisions or {}
    currentSlice.state = currentSlice.state or {}
    currentRevision = message.revision
    cachedByKind = {}
    for pluralKind, kind in pairs(definitionKinds) do
        local index = {}
        local list = currentSlice[pluralKind] or {}
        for itemIndex = 1, #list do index[list[itemIndex].key] = list[itemIndex] end
        cachedByKind[kind] = index
    end

    if previousFingerprint ~= nextFingerprint then
        TriggerEvent('world:contextChanged', copyValue(nextContext),
            previousContext, currentRevision)
    end
    local fields = {
        { name = 'location', event = 'world:locationChanged' },
        { name = 'room', event = 'world:roomChanged' },
        { name = 'instance', event = 'world:instanceChanged' },
    }
    for _, field in ipairs(fields) do
        local previous = previousContext[field.name]
        local nextValue = nextContext[field.name]
        local previousValue = type(previous) == 'table'
            and (previous.key or previous.instanceId or previous.id) or previous
        local nextIdentity = type(nextValue) == 'table'
            and (nextValue.key or nextValue.instanceId or nextValue.id) or nextValue
        if previousValue ~= nextIdentity then
            TriggerEvent(field.event, copyValue(nextValue), copyValue(previous), currentRevision)
        end
    end
    reconcileRuntime()
end)

RegisterNetEvent('synex_world:client:door_state', function(message)
    if source ~= 65535 or type(message) ~= 'table' or message.schemaVersion ~= SCHEMA_VERSION
        or not validWorldKey(message.key) or doorStates[message.state] == nil
        or not integerInRange(message.revision, 1, 2147483647)
        or not integerInRange(message.stateVersion, 1, 9007199254740991)
        or not integerInRange(message.definitionRevision, 1, 2147483647)
        or not encodedWithin(message, MAX_MESSAGE_BYTES) then return end
    for key in next, message do
        if key ~= 'schemaVersion' and key ~= 'key' and key ~= 'state'
            and key ~= 'stateVersion' and key ~= 'definitionRevision'
            and key ~= 'revision' then return end
    end
    local door = cachedByKind.door and cachedByKind.door[message.key]
    if door == nil or message.definitionRevision ~= door.revision
        or message.stateVersion <= (door.stateVersion or 0) then return end
    door.state = message.state
    door.stateVersion = message.stateVersion
    currentRevision = math.max(currentRevision, message.revision)
    for _, entry in pairs(doorRuntime) do
        if entry.doorKey == message.key then
            entry.state = message.state
            entry.revision = message.stateVersion
            entry.appliedRevision = nil
        end
    end
    reconcileRuntime()
end)

RegisterNetEvent('synex_world:client:apply_transition', function(message)
    if source ~= 65535 or type(message) ~= 'table' or message.schemaVersion ~= SCHEMA_VERSION
        or not integerInRange(message.revision, 1, 2147483647)
        or not boundedString(message.grantId, 36, '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
        or recentGrants[message.grantId] or (pendingTransition ~= nil
            and pendingTransition.grantId == message.grantId)
        or type(message.destination) ~= 'table'
        or not validPosition(message.destination, true)
        or (message.destination.heading ~= nil
            and (not finiteNumber(message.destination.heading)
                or math.abs(message.destination.heading) > Limits.maximumHeadingMagnitude))
        or not encodedWithin(message, MAX_MESSAGE_BYTES) then return end
    for key in next, message do
        if key ~= 'schemaVersion' and key ~= 'revision' and key ~= 'grantId'
            and key ~= 'destination' then return end
    end
    for key in next, message.destination do
        if key ~= 'x' and key ~= 'y' and key ~= 'z' and key ~= 'heading' then return end
    end
    local now = monotonicNow()
    pendingTransition = {
        grantId = message.grantId,
        destination = copyValue(message.destination),
        deadline = now + TRANSITION_RETRY_MS,
    }
    applyPendingTransition()
end)

exports('GetContext', function()
    local result = copyValue(currentSlice.context or {})
    result.authority = 'OBSERVED'
    result.revision = currentRevision
    return result
end)

exports('CurrentLocation', function()
    return copyValue(currentSlice.context and currentSlice.context.location)
end)

exports('CurrentRoom', function()
    return copyValue(currentSlice.context and currentSlice.context.room)
end)

exports('NearbyAnchors', function(options)
    local limit = MAX_ANCHOR_RESULTS
    local tag = nil
    local maxDistance = nil
    if type(options) == 'number' then
        if not integerInRange(options, 1, MAX_ANCHOR_RESULTS) then return {} end
        limit = options
    elseif options ~= nil then
        if type(options) ~= 'table' then return {} end
        for key in next, options do
            if key ~= 'limit' and key ~= 'tag' and key ~= 'maxDistance' then return {} end
        end
        if options.limit ~= nil then
            if not integerInRange(options.limit, 1, MAX_ANCHOR_RESULTS) then return {} end
            limit = options.limit
        end
        if options.tag ~= nil then
            if not boundedString(options.tag, MAX_TAG_BYTES,
                '^[a-z][a-z0-9_.%-]*$') then return {} end
            tag = options.tag
        end
        if options.maxDistance ~= nil then
            if not finiteNumber(options.maxDistance) or options.maxDistance < 0.0
                or options.maxDistance > 1000.0 then return {} end
            maxDistance = options.maxDistance
        end
    end
    local result = {}
    for _, anchor in ipairs(currentSlice.anchors or {}) do
        local distanceAccepted = maxDistance == nil
            or (finiteNumber(anchor.distance) and anchor.distance <= maxDistance)
        local tagAccepted = tag == nil
        if tag ~= nil and type(anchor.tags) == 'table' then
            for _, candidate in ipairs(anchor.tags) do
                if candidate == tag then tagAccepted = true break end
            end
        end
        if distanceAccepted and tagAccepted then
            result[#result + 1] = copyValue(anchor)
            if #result >= limit then break end
        end
    end
    return result
end)

local nearbyWorldKinds = {
    anchor = 'anchors',
    door = 'doors',
    portal = 'portals',
}

exports('NearbyObjects', function(kind, options)
    local listKey = nearbyWorldKinds[kind]
    if listKey == nil or options ~= nil and type(options) ~= 'table' then return {} end
    options = options or {}
    for key in next, options do
        if key ~= 'limit' and key ~= 'tag' and key ~= 'maxDistance' then return {} end
    end
    local limit = options.limit or MAX_ANCHOR_RESULTS
    if not integerInRange(limit, 1, MAX_ANCHOR_RESULTS) then return {} end
    local tag = options.tag
    if tag ~= nil and not boundedString(tag, MAX_TAG_BYTES,
        '^[a-z][a-z0-9_.%-]*$') then return {} end
    local maxDistance = options.maxDistance
    if maxDistance ~= nil and (not finiteNumber(maxDistance) or maxDistance < 0.0
        or maxDistance > 1000.0) then return {} end

    local result = {}
    for _, object in ipairs(currentSlice[listKey] or {}) do
        local distanceAccepted = maxDistance == nil
            or finiteNumber(object.distance) and object.distance <= maxDistance
        local tagAccepted = tag == nil
        if tag ~= nil and type(object.tags) == 'table' then
            for _, candidate in ipairs(object.tags) do
                if candidate == tag then tagAccepted = true break end
            end
        end
        if distanceAccepted and tagAccepted then
            result[#result + 1] = copyValue(object)
            if #result >= limit then break end
        end
    end
    return result
end)

exports('ResolveCached', function(kind, key)
    if type(kind) ~= 'string' or not validWorldKey(key) then return nil end
    local index = cachedByKind[kind]
    if index == nil then return nil end
    return copyValue(index[key])
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    runtimeActive = true
    reconcileRuntime()
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    runtimeActive = false
    pendingTransition = nil
    clearRuntime()
    currentSlice = { context = { authority = 'OBSERVED' },
        bundleRevisions = {}, state = {} }
    currentRevision = 0
    cachedByKind = {}
    recentGrants = {}
    recentGrantOrder = {}
end)

CreateThread(function()
    while runtimeActive do
        Wait(RECONCILE_INTERVAL_MS)
        if runtimeActive then
            reconcileRuntime()
            applyPendingTransition()
        end
    end
end)
