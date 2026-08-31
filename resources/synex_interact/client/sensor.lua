SynexInteractSensor = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded first')
local Cancellation = assert(SynexInteractCancellation,
    'interact cancellation policy must be loaded before the sensor')

local RAY_FLAGS = 511
local RAY_OPTIONS = 7
local GRID_SIZE = 20.0
local LOS_CACHE_TTL_MS = 400
local RAY_OBSERVATION_TTL_MS = 500
local RAY_PENDING_TIMEOUT_MS = 1000
local SOFT_CONE_DEGREES = 13.0
local ASSIST_CONE_DEGREES = 18.0
local MAXIMUM_CLIENT_PROVIDERS = Limits.maximumProviders
local MAXIMUM_INSPECTOR_CONTEXT_ENTRIES = 32
local MAXIMUM_INSPECTOR_DEPTH = 3
local MAXIMUM_INSPECTOR_STRING_BYTES = 128
local MAXIMUM_INSPECTOR_CANDIDATES = 8
local ENTITY_TYPES = { object = true, ped = true, vehicle = true }
local WORLD_KINDS = { anchor = true, door = true, portal = true }
local WORLD_KIND_ORDER = { 'anchor', 'door', 'portal' }
local DECLARATIVE_OPERATORS = {
    eq = true, ne = true, lt = true, lte = true, gt = true,
    gte = true, truthy = true, falsy = true, contains = true,
}

local function failure(code, message, retryable)
    local _, value = Validation.failure(code, message, retryable)
    return value
end

local function callable(value)
    return Validation.isCallable(value)
end

local function safeCall(handler, ...)
    if not callable(handler) then return nil end
    local ok, first, second, third, fourth, fifth = pcall(handler, ...)
    if not ok then return nil end
    return first, second, third, fourth, fifth
end

local function vector(value)
    if value == nil then return nil end
    local ok, x, y, z = pcall(function()
        return tonumber(value.x or value[1]), tonumber(value.y or value[2]),
            tonumber(value.z or value[3])
    end)
    if not ok or not Validation.isFinite(x) or not Validation.isFinite(y)
        or not Validation.isFinite(z) or math.abs(x) > 20000
        or math.abs(y) > 20000 or math.abs(z) > 20000 then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

local function add(left, right)
    return { x = left.x + right.x, y = left.y + right.y, z = left.z + right.z }
end

local function subtract(left, right)
    return { x = left.x - right.x, y = left.y - right.y, z = left.z - right.z }
end

local function scale(value, factor)
    return { x = value.x * factor, y = value.y * factor, z = value.z * factor }
end

local function length(value)
    return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function normalize(value)
    local magnitude = length(value)
    if magnitude <= 0.000001 then return { x = 0.0, y = 1.0, z = 0.0 } end
    return scale(value, 1.0 / magnitude)
end

local function dot(left, right)
    return left.x * right.x + left.y * right.y + left.z * right.z
end

local function cameraDirection(rotation)
    local pitch = math.rad(rotation.x)
    local yaw = math.rad(rotation.z)
    local horizontal = math.abs(math.cos(pitch))
    return normalize({
        x = -math.sin(yaw) * horizontal,
        y = math.cos(yaw) * horizontal,
        z = math.sin(pitch),
    })
end

local function headingDirection(heading)
    local radians = math.rad(tonumber(heading) or 0.0)
    return { x = -math.sin(radians), y = math.cos(radians), z = 0.0 }
end

local function rotatedOffset(offset, heading)
    local radians = math.rad(heading or 0.0)
    local cosine, sine = math.cos(radians), math.sin(radians)
    return {
        x = offset.x * cosine - offset.y * sine,
        y = offset.x * sine + offset.y * cosine,
        z = offset.z,
    }
end

local function cellKey(x, y)
    return ('%d:%d'):format(math.floor(x / GRID_SIZE), math.floor(y / GRID_SIZE))
end

local function worldIndexKey(kind, key)
    return tostring(kind) .. '\0' .. tostring(key)
end

local function sortedKeys(value)
    local result = {}
    for key in pairs(value) do result[#result + 1] = key end
    table.sort(result)
    return result
end

local function semanticKey(value, maximum)
    if callable(Validation.semanticKey) then
        local accepted = Validation.semanticKey(value, maximum or 64)
        return accepted ~= nil and accepted ~= false
    end
    return Validation.identifier(value, maximum or 64)
end

local function normalizedSlot(value)
    if not Validation.exactObject(value, { 'key', 'localTransform',
        'interactionRadius', 'facingTolerance', 'tags', 'initialState' })
        or not Validation.text(value.key, 1, 64)
        or not Validation.isFinite(value.interactionRadius)
        or value.interactionRadius < 0.25
        or value.interactionRadius > Limits.maximumAuthorityDistance
        or not Validation.isFinite(value.facingTolerance)
        or value.facingTolerance < 0 or value.facingTolerance > 180
        or not Validation.exactObject(value.localTransform, { 'position' }, { 'heading' })
        or not Validation.vector3(value.localTransform.position)
        or value.localTransform.heading ~= nil
            and not Validation.isFinite(value.localTransform.heading) then return nil end
    local tags = Validation.array(value.tags, 16, function(tag)
        return semanticKey(tag, 64)
    end)
    if not tags then return nil end
    return {
        key = value.key,
        localTransform = Validation.copy(value.localTransform),
        interactionRadius = value.interactionRadius + 0.0,
        facingTolerance = value.facingTolerance + 0.0,
        tags = tags,
        initialState = value.initialState,
    }
end

local function normalizedCondition(value)
    if not Validation.isPlainTable(value) then return nil end
    local copied
    if value.kind == 'declarative' then
        if not Validation.exactObject(value, { 'kind', 'path', 'operator' }, {
            'value', 'arguments',
        }) or not Validation.text(value.path, 3, 128)
            or not DECLARATIVE_OPERATORS[value.operator]
            or value.arguments ~= nil
                and not Validation.isPlainTable(value.arguments) then return nil end
        copied = Validation.copy(value)
    elseif value.kind == 'evaluator' then
        if not Validation.exactObject(value, { 'kind', 'evaluator' }, { 'arguments' })
            or not Validation.identifier(value.evaluator)
            or value.arguments ~= nil
                and not Validation.isPlainTable(value.arguments) then return nil end
        copied = Validation.copy(value)
    else return nil end
    return copied
end

local function normalizedIntent(value, objectKey, revision)
    if not Validation.exactObject(value, {
        'key', 'revision', 'verb', 'label', 'basePriority', 'specificity',
        'trigger', 'visibilityConditions', 'presentation',
    }, { 'icon', 'slotSelector', 'cancelPolicy' })
        or not Validation.identifier(value.key)
        or value.revision ~= revision
        or not Validation.text(value.verb, 1, 48)
        or not Validation.text(value.label, 1, 96)
        or not Validation.isFinite(value.basePriority)
        or value.basePriority < -100 or value.basePriority > 100
        or not Validation.isFinite(value.specificity)
        or value.specificity < -100 or value.specificity > 100
        or (value.trigger ~= 'primary' and value.trigger ~= 'secondary'
            and value.trigger ~= 'automatic')
        or value.slotSelector ~= nil and not Validation.text(value.slotSelector, 1, 64)
        then return nil end
    local rawConditions = Validation.array(value.visibilityConditions,
        Limits.maximumConditionsPerIntent)
    if not rawConditions then return nil end
    local conditions = {}
    for index, condition in ipairs(rawConditions) do
        conditions[index] = normalizedCondition(condition)
        if conditions[index] == nil then return nil end
    end
    local cancelPolicy = Cancellation.normalize(value.cancelPolicy)
    if not cancelPolicy then return nil end
    local copied = Validation.copy(value)
    if not copied then return nil end
    copied.visibilityConditions = conditions
    copied.cancelPolicy = cancelPolicy
    copied.smartObjectKey = objectKey
    return copied
end

local function normalizedBinding(value)
    if not Validation.exactObject(value, { 'type' }, {
        'key', 'entityId', 'generation', 'archetype', 'model', 'bone',
        'position', 'heading', 'provider', 'bindingKey', 'tags', 'kind',
    }) then return nil end
    if value.type == 'worldAnchor' then
        if not Validation.identifier(value.key) then return nil end
    elseif value.type == 'worldRef' then
        if not WORLD_KINDS[value.kind] or not Validation.identifier(value.key) then return nil end
    elseif value.type == 'entityRef' then
        if not Validation.token(value.entityId, 8, 64)
            or not Validation.isInteger(value.generation, 1) then return nil end
    elseif value.type == 'entityArchetype' or value.type == 'entityBone' then
        if value.archetype == nil and value.model == nil
            or value.archetype ~= nil and not semanticKey(value.archetype, 128)
            or value.model ~= nil and not Validation.isInteger(value.model, 0, 4294967295)
            or value.type == 'entityBone' and not Validation.text(value.bone, 1, 64)
        then return nil end
    elseif value.type == 'staticTransform' then
        if not Validation.vector3(value.position)
            or value.heading ~= nil and not Validation.isFinite(value.heading) then return nil end
    elseif value.type == 'dynamic' then
        if not Validation.identifier(value.provider)
            or not Validation.token(value.bindingKey, 3, 128) then return nil end
    else return nil end
    return Validation.copy(value)
end

local function normalizedObject(value)
    if not Validation.exactObject(value, {
        'key', 'revision', 'binding', 'tags', 'slots', 'intents', 'presentation',
    }) or not Validation.identifier(value.key)
        or not Validation.isInteger(value.revision, 1) then return nil end
    local binding = normalizedBinding(value.binding)
    local tags = Validation.array(value.tags, 32, function(tag)
        return semanticKey(tag, 64)
    end)
    local rawSlots = Validation.array(value.slots, Limits.maximumSlotsPerObject)
    local rawIntents = Validation.array(value.intents, Limits.maximumActivitiesPerObject)
    if not binding or not tags or not rawSlots or #rawSlots == 0
        or not rawIntents or #rawIntents == 0 then return nil end
    local slots, slotKeys = {}, {}
    for _, raw in ipairs(rawSlots) do
        local slot = normalizedSlot(raw)
        if not slot or slots[slot.key] then return nil end
        slots[slot.key], slotKeys[#slotKeys + 1] = slot, slot.key
    end
    table.sort(slotKeys)
    local intents = {}
    for _, raw in ipairs(rawIntents) do
        local intent = normalizedIntent(raw, value.key, value.revision)
        if not intent then return nil end
        if intent.slotSelector ~= nil and slots[intent.slotSelector] == nil then return nil end
        intents[#intents + 1] = intent
    end
    table.sort(intents, function(left, right) return left.key < right.key end)
    return {
        key = value.key, revision = value.revision, binding = binding,
        tags = tags, slots = slots, slotKeys = slotKeys, intents = intents,
        presentation = Validation.copy(value.presentation) or {},
    }
end

local function normalizedManagedEntity(value, bucket)
    if not Validation.exactObject(value, {
        'entityRef', 'netId', 'entityType', 'model', 'bucket', 'position', 'heading',
    }, { 'archetype' })
        or not Validation.exactObject(value.entityRef, { 'entityId', 'generation' })
        or not Validation.token(value.entityRef.entityId, 8, 64)
        or not Validation.isInteger(value.entityRef.generation, 1)
        or not Validation.isInteger(value.netId, 1, 65535)
        or not ENTITY_TYPES[value.entityType]
        or not Validation.isInteger(value.model, 0, 4294967295)
        or value.archetype ~= nil and not semanticKey(value.archetype, 128)
        or not Validation.isInteger(value.bucket, 0, 2147483647)
        or value.bucket ~= bucket
        or not Validation.vector3(value.position)
        or not Validation.isFinite(value.heading) then return nil end
    return Validation.copy(value)
end

function SynexInteractSensor.create(options)
    options = options or {}
    local ports = assert(options.ports, 'interact sensor requires native ports')
    local now = assert(options.now, 'interact sensor requires monotonic time')
    local spawn = options.spawn or function(handler) handler() end
    local world = options.world or {}
    local observe = options.observe or function() end
    local discoveryRevision = 0
    local objects, objectOrder = {}, {}
    local staticGrid, worldIndex, modelIndex, archetypeIndex, entityRefIndex,
        dynamicIndex = {}, {}, {}, {}, {}, {}
    local managedEntities, managedEntityOrder, managedByNetId = {}, {}, {}
    local entityProjectionRevision, entityProjectionAt = 0, 0
    local entityProjectionSourceGeneration, entityProjectionBucket = nil, nil
    local providerOrder, providers, providerCursor = {}, {}, 1
    local ray = { pending = nil, lastMode = 'candidate', observation = nil,
        los = {}, serial = 0 }
    local previousFocus, previousIntent, inputDevice = nil, nil, 'keyboard'
    local assistEnabled = false
    local active = true
    local lastCandidateCount, lastExpensiveCount = 0, 0
    local lastContextInspector, lastCandidateSummaries = nil, {}

    local function clearIndexes()
        objects, objectOrder = {}, {}
        staticGrid, worldIndex, modelIndex, archetypeIndex, entityRefIndex,
            dynamicIndex = {}, {}, {}, {}, {}, {}
        managedEntities, managedEntityOrder, managedByNetId = {}, {}, {}
        entityProjectionRevision, entityProjectionAt = 0, 0
        entityProjectionSourceGeneration, entityProjectionBucket = nil, nil
        ray.pending, ray.observation, ray.los = nil, nil, {}
        lastContextInspector, lastCandidateSummaries = nil, {}
    end

    local function boundedInspectorValue(value)
        local entries, activeValues = 0, {}
        local function clone(candidate, depth)
            local kind = type(candidate)
            if kind == 'nil' or kind == 'boolean' then return candidate end
            if kind == 'number' then
                return Validation.isFinite(candidate) and candidate or nil
            end
            if kind == 'string' then
                return candidate:sub(1, MAXIMUM_INSPECTOR_STRING_BYTES)
            end
            if kind ~= 'table' or depth > MAXIMUM_INSPECTOR_DEPTH
                or activeValues[candidate] then return nil end
            activeValues[candidate] = true
            local result, keys = {}, {}
            for key in pairs(candidate) do
                if type(key) == 'string' or Validation.isInteger(key, 1) then
                    keys[#keys + 1] = key
                    if #keys >= MAXIMUM_INSPECTOR_CONTEXT_ENTRIES then break end
                end
            end
            table.sort(keys, function(left, right)
                if type(left) ~= type(right) then
                    return type(left) < type(right)
                end
                return left < right
            end)
            for _, key in ipairs(keys) do
                if entries >= MAXIMUM_INSPECTOR_CONTEXT_ENTRIES then break end
                local copied = clone(candidate[key], depth + 1)
                if copied ~= nil then
                    entries = entries + 1
                    result[key] = copied
                end
            end
            activeValues[candidate] = nil
            return result
        end
        return clone(value, 1)
    end

    local function inspectorContext(context)
        local actor = context.actor
        return {
            actor = {
                position = Validation.copy(actor.position),
                velocity = Validation.copy(actor.velocity),
                speed = actor.speed, heading = actor.heading,
                movementState = actor.movementState,
                vehicleState = actor.vehicleState,
                weaponState = actor.weaponState,
                dead = actor.dead, ragdoll = actor.ragdoll,
            },
            cameraRay = {
                origin = Validation.copy(context.camera.position),
                direction = Validation.copy(context.camera.direction),
            },
            worldContext = boundedInspectorValue(context.worldContext) or {},
            worldInstance = boundedInspectorValue(context.worldInstance),
            focusedTarget = boundedInspectorValue(context.focusedTarget),
        }
    end

    local function inspectorCandidates(candidates)
        local result = {}
        for index = 1, math.min(#candidates, MAXIMUM_INSPECTOR_CANDIDATES) do
            local candidate = candidates[index]
            result[index] = {
                id = tostring(candidate.id):sub(1, MAXIMUM_INSPECTOR_STRING_BYTES),
                objectKey = tostring(candidate.objectKey):sub(
                    1, MAXIMUM_INSPECTOR_STRING_BYTES),
                slotKey = tostring(candidate.slotKey):sub(
                    1, MAXIMUM_INSPECTOR_STRING_BYTES),
                source = tostring(candidate.source):sub(
                    1, MAXIMUM_INSPECTOR_STRING_BYTES),
                targetKind = type(candidate.target) == 'table'
                    and candidate.target.kind or nil,
                distance = candidate.distance,
                gaze = candidate.gaze,
                exactRay = candidate.exactRay == true,
                expensive = candidate.expensive == true,
                occluded = candidate.occluded,
            }
        end
        return result
    end

    local function appendIndex(index, key, object)
        local values = index[key]
        if values == nil then values = {}; index[key] = values end
        values[#values + 1] = object
    end

    local function rebuild(snapshotObjects)
        local nextObjects, nextObjectOrder = {}, {}
        local nextStaticGrid, nextWorldIndex, nextModelIndex,
            nextArchetypeIndex, nextEntityRefIndex, nextDynamicIndex =
            {}, {}, {}, {}, {}, {}
        for _, raw in ipairs(snapshotObjects) do
            local object = normalizedObject(raw)
            if not object or nextObjects[object.key] then return false end
            nextObjects[object.key] = object
            nextObjectOrder[#nextObjectOrder + 1] = object.key
        end
        table.sort(nextObjectOrder)
        for _, key in ipairs(nextObjectOrder) do
            local object, binding = nextObjects[key], nextObjects[key].binding
            if binding.type == 'staticTransform' then
                appendIndex(nextStaticGrid,
                    cellKey(binding.position.x, binding.position.y), object)
            elseif binding.type == 'worldAnchor' then
                appendIndex(nextWorldIndex,
                    worldIndexKey('anchor', binding.key), object)
            elseif binding.type == 'worldRef' then
                appendIndex(nextWorldIndex,
                    worldIndexKey(binding.kind, binding.key), object)
            elseif binding.type == 'entityArchetype' or binding.type == 'entityBone' then
                if binding.model ~= nil then
                    appendIndex(nextModelIndex, binding.model, object)
                end
                if binding.archetype ~= nil then
                    appendIndex(nextArchetypeIndex, binding.archetype, object)
                end
            elseif binding.type == 'entityRef' then
                appendIndex(nextEntityRefIndex, binding.entityId .. '\0'
                    .. tostring(binding.generation), object)
            elseif binding.type == 'dynamic' then
                nextDynamicIndex[binding.provider] = nextDynamicIndex[binding.provider] or {}
                appendIndex(nextDynamicIndex[binding.provider], binding.bindingKey, object)
            end
        end
        objects, objectOrder = nextObjects, nextObjectOrder
        staticGrid, worldIndex, modelIndex, archetypeIndex, entityRefIndex,
            dynamicIndex = nextStaticGrid, nextWorldIndex, nextModelIndex,
            nextArchetypeIndex, nextEntityRefIndex, nextDynamicIndex
        managedEntities, managedEntityOrder, managedByNetId = {}, {}, {}
        entityProjectionRevision, entityProjectionAt = 0, 0
        entityProjectionSourceGeneration, entityProjectionBucket = nil, nil
        ray.pending, ray.observation, ray.los = nil, nil, {}
        lastContextInspector, lastCandidateSummaries = nil, {}
        return true
    end

    local sensor = {}

    function sensor.replaceDiscovery(snapshot)
        if not active or not Validation.exactObject(snapshot,
            { 'schemaVersion', 'revision', 'unchanged', 'objects' })
            or snapshot.schemaVersion ~= 1
            or not Validation.isInteger(snapshot.revision, 1)
            or type(snapshot.unchanged) ~= 'boolean'
            or not Validation.array(snapshot.objects, Limits.maximumDiscoveryObjects) then
            return nil, failure('INTERACT_DISCOVERY_INVALID',
                'The interaction discovery snapshot is invalid.')
        end
        if snapshot.revision < discoveryRevision
            or snapshot.unchanged and snapshot.revision ~= discoveryRevision
            or snapshot.unchanged and #snapshot.objects ~= 0
            or not snapshot.unchanged and snapshot.revision == discoveryRevision then
            return nil, failure('INTERACT_DISCOVERY_STALE',
                'The interaction discovery snapshot is stale.')
        end
        if snapshot.unchanged then return { revision = discoveryRevision, unchanged = true } end
        local copied = Validation.copy(snapshot.objects)
        if not copied or not rebuild(copied) then
            return nil, failure('INTERACT_DISCOVERY_INVALID',
                'The interaction discovery objects are invalid.')
        end
        discoveryRevision = snapshot.revision
        previousFocus, previousIntent = nil, nil
        return { revision = discoveryRevision, unchanged = false,
            objects = #objectOrder }, nil
    end

    function sensor.replaceEntityProjection(snapshot)
        if not active or not Validation.exactObject(snapshot, {
            'schemaVersion', 'discoveryRevision', 'projectionRevision',
            'sourceGeneration', 'bucket', 'truncated', 'entities',
        }) or snapshot.schemaVersion ~= 1
            or snapshot.discoveryRevision ~= discoveryRevision
            or not Validation.isInteger(snapshot.projectionRevision, 1)
            or not Validation.isInteger(snapshot.sourceGeneration, 1)
            or not Validation.isInteger(snapshot.bucket, 0, 2147483647)
            or type(snapshot.truncated) ~= 'boolean'
            or not Validation.array(snapshot.entities,
                Limits.maximumEntityProjection) then
            return nil, failure('INTERACT_DISCOVERY_INVALID',
                'The managed entity projection is invalid.')
        end
        if snapshot.sourceGeneration == entityProjectionSourceGeneration
            and snapshot.projectionRevision <= entityProjectionRevision then
            return nil, failure('INTERACT_DISCOVERY_STALE',
                'The managed entity projection is stale.')
        end
        local nextEntities, nextOrder, nextByNetId = {}, {}, {}
        for _, raw in ipairs(snapshot.entities) do
            local entity = normalizedManagedEntity(raw, snapshot.bucket)
            if not entity then return nil, failure('INTERACT_DISCOVERY_INVALID',
                'A managed entity projection entry is invalid.') end
            local identity = entity.entityRef.entityId .. '\0'
                .. tostring(entity.entityRef.generation)
            if nextEntities[identity] or nextByNetId[entity.netId] then
                return nil, failure('INTERACT_DISCOVERY_INVALID',
                    'The managed entity projection contains duplicates.')
            end
            nextEntities[identity], nextByNetId[entity.netId] = entity, entity
            nextOrder[#nextOrder + 1] = identity
        end
        table.sort(nextOrder)
        managedEntities, managedEntityOrder, managedByNetId =
            nextEntities, nextOrder, nextByNetId
        entityProjectionRevision = snapshot.projectionRevision
        entityProjectionSourceGeneration = snapshot.sourceGeneration
        entityProjectionBucket = snapshot.bucket
        entityProjectionAt = now()
        return { revision = entityProjectionRevision,
            entities = #managedEntityOrder, truncated = snapshot.truncated }, nil
    end

    function sensor.registerProvider(owner, epoch, definition, handler)
        if not active or not Validation.resourceName(owner)
            or not Validation.isInteger(epoch, 1)
            or not Validation.exactObject(definition, { 'key' }, {
                'priority', 'kind', 'timeoutMs', 'intervalMs', 'cacheTtlMs',
            })
            or not Validation.identifier(definition.key)
            or definition.key:sub(1, #owner + 1) ~= owner .. ':'
            or definition.priority ~= nil and not Validation.isInteger(
                definition.priority, -100, 100)
            or definition.kind ~= nil and definition.kind ~= 'dynamic'
                and definition.kind ~= 'ephemeral' and definition.kind ~= 'actor'
            or definition.timeoutMs ~= nil and not Validation.isInteger(
                definition.timeoutMs, 1, 1000)
            or definition.intervalMs ~= nil and not Validation.isInteger(
                definition.intervalMs, 33, 5000)
            or definition.cacheTtlMs ~= nil and not Validation.isInteger(
                definition.cacheTtlMs, 0, 5000)
            or not callable(handler) or providers[definition.key]
            or #providerOrder >= MAXIMUM_CLIENT_PROVIDERS then
            return nil, failure('INTERACT_PROVIDER_INVALID',
                'The client candidate provider registration is invalid.')
        end
        local record = {
            key = definition.key, owner = owner, epoch = epoch,
            priority = definition.priority or 0, kind = definition.kind or 'dynamic',
            timeoutMs = definition.timeoutMs or Limits.providerTimeoutMs,
            intervalMs = definition.intervalMs or Limits.providerIntervalMs,
            cacheTtlMs = definition.cacheTtlMs or Limits.providerResultTtlMs,
            handler = handler, generation = 0, running = false,
            timedOut = false, result = nil, resultAt = 0, nextRunAt = 0,
        }
        providers[record.key], providerOrder[#providerOrder + 1] = record, record.key
        table.sort(providerOrder, function(leftKey, rightKey)
            local left, right = providers[leftKey], providers[rightKey]
            if left.priority ~= right.priority then return left.priority > right.priority end
            return left.key < right.key
        end)
        providerCursor = 1
        return {
            key = record.key,
            unregister = function()
                if providers[record.key] ~= record then return false end
                providers[record.key] = nil
                for index, key in ipairs(providerOrder) do
                    if key == record.key then table.remove(providerOrder, index); break end
                end
                providerCursor = 1
                return true
            end,
        }, nil
    end

    function sensor.cleanupOwner(owner, epoch)
        local removed = 0
        for index = #providerOrder, 1, -1 do
            local record = providers[providerOrder[index]]
            if record and record.owner == owner and (epoch == nil or record.epoch == epoch) then
                providers[record.key] = nil
                table.remove(providerOrder, index)
                removed = removed + 1
            end
        end
        providerCursor = 1
        return removed
    end

    function sensor.setInteractionState(focus, intent, device, assist)
        previousFocus = Validation.copy(focus)
        previousIntent = type(intent) == 'string' and intent or nil
        if device == 'keyboard' or device == 'gamepad' or device == 'mouse' then
            inputDevice = device
        end
        assistEnabled = assist == true
    end

    function sensor.setInteractionAssist(enabled)
        if type(enabled) ~= 'boolean' then
            return nil, failure('INTERACT_CONTEXT_INVALID',
                'Interaction Assist must be a boolean preference.')
        end
        assistEnabled = enabled
        return true, nil
    end

    local function readActor()
        local ped = tonumber(safeCall(ports.playerPed)) or 0
        if ped <= 0 or safeCall(ports.entityExists, ped) ~= true then return nil end
        local position = vector(safeCall(ports.entityCoords, ped))
        local velocity = vector(safeCall(ports.entityVelocity, ped))
            or { x = 0.0, y = 0.0, z = 0.0 }
        if not position then return nil end
        local vehicle = tonumber(safeCall(ports.vehicleForPed, ped)) or 0
        local dead = safeCall(ports.pedDead, ped) == true
        local ragdoll = safeCall(ports.pedRagdoll, ped) == true
        return {
            ped = ped, position = position, velocity = velocity,
            speed = length(velocity), heading = tonumber(safeCall(ports.entityHeading, ped)) or 0.0,
            movementState = dead and 'DEAD' or ragdoll and 'RAGDOLL'
                or length(velocity) > 0.25 and 'MOVING' or 'IDLE',
            vehicleState = vehicle > 0 and 'IN_VEHICLE' or 'ON_FOOT',
            vehicle = vehicle > 0 and vehicle or nil,
            weaponState = safeCall(ports.pedArmed, ped) == true and 'ARMED' or 'UNARMED',
            dead = dead, ragdoll = ragdoll,
        }
    end

    local function readCamera()
        local position = vector(safeCall(ports.cameraPosition))
        local rotation = vector(safeCall(ports.cameraRotation, 2))
        if not position or not rotation then return nil end
        return { position = position, rotation = rotation,
            direction = cameraDirection(rotation) }
    end

    local function pollRay(currentTime)
        local pending = ray.pending
        if pending == nil then return end
        if pending.discoveryRevision ~= discoveryRevision
            or currentTime - pending.startedAt > RAY_PENDING_TIMEOUT_MS then
            ray.pending = nil
            return
        end
        local status, hit, endpoint, normal, entity = safeCall(
            ports.shapeTestResult, pending.handle)
        status = tonumber(status)
        if status == 1 then return end
        ray.pending = nil
        if status ~= 2 then return end
        endpoint = vector(endpoint)
        normal = vector(normal)
        entity = tonumber(entity) or 0
        if pending.mode == 'gaze' then
            ray.observation = {
                at = currentTime, hit = hit == true or hit == 1,
                endpoint = endpoint, normal = normal,
                entity = entity > 0 and entity or nil,
            }
            return
        end
        local visible = hit ~= true and hit ~= 1
        if not visible and pending.entity and entity == pending.entity then visible = true end
        if not visible and endpoint and pending.endpoint
            and Validation.distance(endpoint, pending.endpoint) <= 0.8 then visible = true end
        ray.los[pending.candidateId] = { at = currentTime, visible = visible }
    end

    local function startRay(mode, context, candidate)
        if ray.pending ~= nil then return false end
        local endpoint, candidateId, entity
        if mode == 'candidate' and candidate ~= nil then
            endpoint, candidateId, entity = candidate.position, candidate.id, candidate._entity
        else
            mode = 'gaze'
            endpoint = add(context.camera.position,
                scale(context.camera.direction, Limits.maximumRayDistance))
        end
        local handle = tonumber(safeCall(ports.startLosProbe,
            context.camera.position.x, context.camera.position.y, context.camera.position.z,
            endpoint.x, endpoint.y, endpoint.z, RAY_FLAGS, context.actor.ped, RAY_OPTIONS))
        if not handle or handle <= 0 then return false end
        ray.serial = ray.serial + 1
        ray.pending = { handle = handle, mode = mode, candidateId = candidateId,
            endpoint = Validation.copy(endpoint), entity = entity, serial = ray.serial,
            discoveryRevision = discoveryRevision, startedAt = context.now }
        ray.lastMode = mode
        return true
    end

    local function targetFor(object, origin, entry)
        local binding = object.binding
        if binding.type == 'worldAnchor' then
            return { kind = 'world', worldRef = {
                kind = 'anchor', key = entry.key, revision = entry.revision,
            } }
        elseif binding.type == 'worldRef' then
            return { kind = 'world', worldRef = {
                kind = binding.kind, key = entry.key, revision = entry.revision,
            } }
        elseif binding.type == 'entityRef' then
            return { kind = 'entity', entityRef = {
                entityId = binding.entityId, generation = binding.generation,
            } }
        elseif binding.type == 'entityArchetype' or binding.type == 'entityBone' then
            if type(entry.entityRef) == 'table' then
                local value = { kind = 'entity', entityRef =
                    Validation.copy(entry.entityRef) }
                if binding.type == 'entityBone' then value.bone = binding.bone end
                return value
            end
            if not entry.netId or not entry.model then return nil end
            local value = { kind = 'ambient', netId = entry.netId, model = entry.model }
            if binding.type == 'entityBone' then value.bone = binding.bone end
            return value
        elseif binding.type == 'staticTransform' then
            return { kind = 'static', bindingKey = object.key,
                position = Validation.copy(origin) }
        elseif binding.type == 'dynamic' then
            return { kind = 'dynamic', bindingKey = binding.bindingKey,
                position = Validation.copy(origin) }
        end
    end

    local function appendCandidates(context, result, seen, object, origin, entry, sourceName,
        exactRay, entity)
        if #result >= Limits.maximumCandidateBatch then return end
        local target = targetFor(object, origin, entry)
        if not target then return end
        for _, slotKey in ipairs(object.slotKeys) do
            if #result >= Limits.maximumCandidateBatch then break end
            local slot = object.slots[slotKey]
            if slot.initialState ~= 'DISABLED' then
                local localPosition = slot.localTransform.position
                local position = add(origin, rotatedOffset(localPosition,
                    tonumber(entry.heading) or 0.0))
                local distance = Validation.distance(context.actor.position, position)
                local toCandidate = normalize(subtract(position, context.camera.position))
                local gaze = math.max(-1.0, math.min(1.0,
                    dot(context.camera.direction, toCandidate)))
                local actorToCandidate = normalize(subtract(position,
                    context.actor.position))
                local facingDot = math.max(-1.0, math.min(1.0,
                    dot(headingDirection(context.actor.heading), actorToCandidate)))
                local facingDelta = math.deg(math.acos(facingDot))
                local tolerance = slot.facingTolerance
                local slotAlignment = tolerance <= 0.0001
                    and (facingDelta <= 0.5 and 1.0 or 0.0)
                    or math.max(0.0, 1.0 - facingDelta / tolerance)
                local cone = math.cos(math.rad(assistEnabled
                    and ASSIST_CONE_DEGREES or SOFT_CONE_DEGREES))
                if distance <= Limits.maximumDiscoveryRadius and (gaze >= cone or exactRay) then
                    local id = object.key .. '@' .. tostring(object.revision)
                        .. '|' .. slotKey .. '|'
                        .. tostring(target.kind) .. '|' .. tostring(entry.key
                            or type(entry.entityRef) == 'table'
                                and entry.entityRef.entityId or entry.netId
                            or object.binding.bindingKey or object.key)
                    if not seen[id] then
                        seen[id] = true
                        result[#result + 1] = {
                            id = id, objectKey = object.key,
                            objectRevision = object.revision, slotKey = slotKey,
                            slot = Validation.copy(slot), intents = Validation.copy(object.intents),
                            target = target, position = position, distance = distance,
                            gaze = (gaze + 1.0) / 2.0, exactRay = exactRay == true,
                            slotAlignment = slotAlignment, facingDelta = facingDelta,
                            source = sourceName, objectTags = Validation.copy(object.tags),
                            presentation = Validation.copy(object.presentation),
                            _entity = entity,
                        }
                    end
                end
            end
        end
    end

    local function collectStatic(context, candidates, seen)
        local radius = Limits.maximumDiscoveryRadius
        local minimumX = math.floor((context.actor.position.x - radius) / GRID_SIZE)
        local maximumX = math.floor((context.actor.position.x + radius) / GRID_SIZE)
        local minimumY = math.floor((context.actor.position.y - radius) / GRID_SIZE)
        local maximumY = math.floor((context.actor.position.y + radius) / GRID_SIZE)
        for x = minimumX, maximumX do
            for y = minimumY, maximumY do
                for _, object in ipairs(staticGrid[('%d:%d'):format(x, y)] or {}) do
                    if #candidates >= Limits.maximumCandidateBatch then return end
                    local binding = object.binding
                    appendCandidates(context, candidates, seen, object, binding.position,
                        { heading = binding.heading }, 'spatial', false, nil)
                end
            end
        end
    end

    local function collectWorld(context, candidates, seen)
        for _, kind in ipairs(WORLD_KIND_ORDER) do
            local definitions = safeCall(world.nearbyObjects, kind, {
                limit = Limits.maximumCandidateBatch,
                maxDistance = Limits.maximumDiscoveryRadius,
            })
            if kind == 'anchor' and type(definitions) ~= 'table' then
                definitions = safeCall(world.nearbyAnchors, {
                    limit = Limits.maximumCandidateBatch,
                    maxDistance = Limits.maximumDiscoveryRadius,
                })
            end
            for index = 1, math.min(type(definitions) == 'table' and #definitions or 0,
                Limits.maximumCandidateBatch) do
                if #candidates >= Limits.maximumCandidateBatch then return end
                local definition = definitions[index]
                local position = type(definition) == 'table' and vector(definition.position) or nil
                if not position and kind == 'door' and type(definition.leaves) == 'table' then
                    local nearestDistance
                    for _, leaf in ipairs(definition.leaves) do
                        local candidate = type(leaf) == 'table' and vector(leaf.position) or nil
                        if candidate then
                            local distance = Validation.distance(context.actor.position, candidate)
                            if nearestDistance == nil or distance < nearestDistance then
                                position, nearestDistance = candidate, distance
                            end
                        end
                    end
                elseif not position and kind == 'portal' and type(definition.source) == 'table' then
                    position = vector(definition.source.position)
                end
                local projectedKind = definition.kind or kind == 'anchor' and 'anchor' or nil
                if position and projectedKind == kind and Validation.identifier(definition.key)
                    and Validation.isInteger(definition.revision, 1) then
                    for _, object in ipairs(worldIndex[
                        worldIndexKey(kind, definition.key)] or {}) do
                        if #candidates >= Limits.maximumCandidateBatch then return end
                        appendCandidates(context, candidates, seen, object, position, definition,
                            'world', false, nil)
                    end
                end
            end
        end
    end

    local function managedMatches(entry)
        local matches, matched = {}, {}
        local identity = entry.entityRef.entityId .. '\0'
            .. tostring(entry.entityRef.generation)
        for _, collection in ipairs({ entityRefIndex[identity] or {},
            entry.archetype and archetypeIndex[entry.archetype] or {},
            modelIndex[entry.model] or {} }) do
            for _, object in ipairs(collection) do
                local binding = object.binding
                local accepted = binding.type == 'entityRef'
                    or (binding.type == 'entityArchetype'
                        or binding.type == 'entityBone')
                        and (binding.archetype == nil
                            or binding.archetype == entry.archetype)
                        and (binding.model == nil or binding.model == entry.model)
                if accepted and not matched[object.key] then
                    matched[object.key], matches[#matches + 1] = true, object
                end
            end
        end
        table.sort(matches, function(left, right) return left.key < right.key end)
        return matches
    end

    local function collectManaged(context, candidates, seen, currentTime)
        if entityProjectionRevision < 1
            or currentTime - entityProjectionAt > Limits.entityProjectionTtlMs then return end
        local observation = ray.observation
        for _, identity in ipairs(managedEntityOrder) do
            if #candidates >= Limits.maximumCandidateBatch then return end
            local entry = managedEntities[identity]
            local entity = tonumber(safeCall(ports.entityFromNetworkId, entry.netId)) or 0
            if entity > 0 and safeCall(ports.entityExists, entity) == true
                and tonumber(safeCall(ports.networkId, entity)) == entry.netId then
                local model = tonumber(safeCall(ports.entityModel, entity))
                if model and model < 0 then model = model + 4294967296 end
                if model == entry.model then
                    for _, object in ipairs(managedMatches(entry)) do
                        if #candidates >= Limits.maximumCandidateBatch then return end
                        local base = vector(safeCall(ports.entityCoords, entity))
                        if object.binding.type == 'entityBone' then
                            local bone = tonumber(safeCall(
                                ports.boneIndex, entity, object.binding.bone))
                            if bone and bone >= 0 then
                                base = vector(safeCall(ports.bonePosition, entity, bone))
                            else base = nil end
                        end
                        if base then
                            appendCandidates(context, candidates, seen, object, base, entry,
                                'managed', observation ~= nil
                                    and currentTime - observation.at <= RAY_OBSERVATION_TTL_MS
                                    and observation.entity == entity, entity)
                        end
                    end
                end
            end
        end
    end

    local function collectRayEntity(context, candidates, seen, currentTime)
        local observation = ray.observation
        if not observation or currentTime - observation.at > RAY_OBSERVATION_TTL_MS
            or not observation.entity or safeCall(ports.entityExists, observation.entity) ~= true then return end
        local entity, model = observation.entity,
            tonumber(safeCall(ports.entityModel, observation.entity))
        local netId = tonumber(safeCall(ports.networkId, entity))
        if model and model < 0 then model = model + 4294967296 end
        if not model or model < 0 or model > 4294967295
            or not netId or netId < 1 or netId > 65535 then return end
        local projected = managedByNetId[netId]
        local rayObjects = projected and managedMatches(projected) or modelIndex[model] or {}
        for _, object in ipairs(rayObjects) do
            if #candidates >= Limits.maximumCandidateBatch then return end
            local base = vector(safeCall(ports.entityCoords, entity))
            if object.binding.type == 'entityBone' then
                local bone = tonumber(safeCall(ports.boneIndex, entity, object.binding.bone))
                if bone and bone >= 0 then base = vector(safeCall(ports.bonePosition, entity, bone))
                else base = nil end
            end
            if base then
                local entry = projected or { netId = netId, model = model,
                    heading = tonumber(safeCall(ports.entityHeading, entity)) or 0.0 }
                appendCandidates(context, candidates, seen, object, base, entry,
                    'entity', true, entity)
            end
        end
    end

    local function collectProviders(context, candidates, seen)
        local currentTime = context.now
        local providerContext = {
            schemaVersion = 1, authority = 'OBSERVED', now = context.now,
            actor = Validation.copy(context.actor), camera = Validation.copy(context.camera),
            worldContext = Validation.copy(context.worldContext),
            worldInstance = Validation.copy(context.worldInstance),
            discoveryRevision = discoveryRevision,
        }
        local function appendProviderResult(record)
            local raw = record and record.result or nil
            if type(raw) ~= 'table' then return end
            for index = 1, math.min(#raw, Limits.maximumCandidateBatch) do
                if #candidates >= Limits.maximumCandidateBatch then break end
                local item = raw[index]
                if Validation.exactObject(item, { 'bindingKey', 'position' }, {
                    'heading', 'netId', 'model',
                }) and Validation.token(item.bindingKey, 3, 128) then
                    local position = Validation.vector3(item.position)
                    if position then
                        local matches = dynamicIndex[record.key]
                            and dynamicIndex[record.key][item.bindingKey] or {}
                        for _, object in ipairs(matches) do
                            if #candidates >= Limits.maximumCandidateBatch then break end
                            appendCandidates(context, candidates, seen, object, position, item,
                                record.kind, false, nil)
                        end
                    end
                end
            end
        end
        local runningProviders = 0
        for _, key in ipairs(providerOrder) do
            local record = providers[key]
            if record and record.running and not record.timedOut
                and currentTime >= record.deadlineAt then
                record.timedOut, record.result = true, nil
                observe('providerTimeouts', 1)
            end
            if record and record.running then runningProviders = runningProviders + 1 end
            if record and record.result ~= nil
                and currentTime - record.resultAt > record.cacheTtlMs then
                record.result = nil
            end
        end
        for _, key in ipairs(providerOrder) do
            if #candidates >= Limits.maximumCandidateBatch then break end
            appendProviderResult(providers[key])
        end

        local scanned, started, providerCount = 0, 0, #providerOrder
        while #candidates < Limits.maximumCandidateBatch
            and scanned < providerCount
            and started < Limits.maximumProviderStartsPerSample
            and runningProviders < Limits.maximumConcurrentProviders do
            if providerCursor > providerCount then providerCursor = 1 end
            local key = providerOrder[providerCursor]
            providerCursor = providerCursor % providerCount + 1
            scanned = scanned + 1
            local record = providers[key]
            if record and dynamicIndex[record.key] ~= nil
                and not record.running and currentTime >= record.nextRunAt then
                record.generation = record.generation + 1
                local generation, invocationStarted = record.generation, currentTime
                record.running, record.timedOut = true, false
                record.deadlineAt = invocationStarted + record.timeoutMs
                record.nextRunAt = invocationStarted + record.intervalMs
                local invocationContext = Validation.copy(providerContext)
                spawn(function()
                    local raw = safeCall(record.handler, invocationContext)
                    local finishedAt = now()
                    local duration = math.max(0, finishedAt - invocationStarted)
                    if providers[key] ~= record or record.generation ~= generation then return end
                    record.running = false
                    observe('providerDurationMs', duration)
                    if not record.timedOut and duration <= record.timeoutMs
                        and type(raw) == 'table' then
                        record.result = Validation.copy(raw)
                        record.resultAt = finishedAt
                    else
                        if duration > record.timeoutMs and not record.timedOut then
                            observe('providerTimeouts', 1)
                        end
                        record.result = nil
                    end
                end)
                started = started + 1
                runningProviders = runningProviders + 1
                appendProviderResult(record)
            end
        end
    end

    local function cheapOrder(left, right)
        local leftScore = left.gaze * 2.0 - left.distance / Limits.maximumDiscoveryRadius
            + (left.exactRay and 1.0 or 0.0)
        local rightScore = right.gaze * 2.0 - right.distance / Limits.maximumDiscoveryRadius
            + (right.exactRay and 1.0 or 0.0)
        if leftScore ~= rightScore then return leftScore > rightScore end
        return left.id < right.id
    end

    local function applyExpensive(candidates, currentTime)
        table.sort(candidates, cheapOrder)
        local maximum = math.min(#candidates, Limits.maximumExpensiveCandidates)
        local nextCandidate
        for index, candidate in ipairs(candidates) do
            candidate.expensive = index <= maximum
            local cached = ray.los[candidate.id]
            if cached and currentTime - cached.at <= LOS_CACHE_TTL_MS then
                candidate.occluded = cached.visible ~= true
            elseif index <= maximum then
                candidate.occluded = nil
                if not nextCandidate then nextCandidate = candidate end
            else candidate.occluded = nil end
        end
        for id, cached in pairs(ray.los) do
            if currentTime - cached.at > LOS_CACHE_TTL_MS * 4 then ray.los[id] = nil end
        end
        return maximum, nextCandidate
    end

    function sensor.sample()
        if not active then return nil, failure('INTERACT_RESOURCE_STOPPED',
            'The interaction client sensor has stopped.') end
        local started = now()
        pollRay(started)
        local actor, camera = readActor(), readCamera()
        if not actor or not camera then
            lastCandidateCount, lastExpensiveCount = 0, 0
            return nil, failure('INTERACT_CONTEXT_INVALID',
                'The observed actor or camera context is unavailable.', true)
        end
        local worldContext = safeCall(world.getContext)
        if type(worldContext) ~= 'table' then worldContext = {} end
        local context = {
            schemaVersion = 1, authority = 'OBSERVED', now = started,
            actor = actor, camera = camera, worldContext = Validation.copy(worldContext) or {},
            worldInstance = type(worldContext.instance) == 'table'
                and Validation.copy(worldContext.instance) or nil,
            inputDevice = inputDevice, focusedTarget = Validation.copy(previousFocus),
            previousIntent = previousIntent, discoveryRevision = discoveryRevision,
        }
        local candidates, seen = {}, {}
        collectStatic(context, candidates, seen)
        collectWorld(context, candidates, seen)
        collectManaged(context, candidates, seen, started)
        collectRayEntity(context, candidates, seen, started)
        collectProviders(context, candidates, seen)
        local expensive, nextCandidate = applyExpensive(candidates, started)
        if ray.pending == nil then
            if ray.lastMode == 'gaze' and nextCandidate then
                startRay('candidate', context, nextCandidate)
            else startRay('gaze', context, nil) end
        end
        lastCandidateCount, lastExpensiveCount = #candidates, expensive
        lastContextInspector = inspectorContext(context)
        lastCandidateSummaries = inspectorCandidates(candidates)
        observe('sensorDurationMs', math.max(0, now() - started))
        return context, candidates, {
            revision = discoveryRevision, candidateCount = #candidates,
            expensiveCandidateCount = expensive,
            pendingRay = ray.pending ~= nil,
        }
    end

    function sensor.nextInterval(focused)
        if not active then return Limits.sensorIdleIntervalMs end
        if focused then return Limits.sensorFocusedIntervalMs end
        if lastCandidateCount > 0 then return Limits.sensorNearIntervalMs end
        if #objectOrder > 0 then return Limits.sensorFarIntervalMs end
        return Limits.sensorIdleIntervalMs
    end

    function sensor.snapshot()
        local runningProviders, timedOutProviders = 0, 0
        for _, record in pairs(providers) do
            if record.running then runningProviders = runningProviders + 1 end
            if record.timedOut then timedOutProviders = timedOutProviders + 1 end
        end
        return {
            active = active, revision = discoveryRevision, objects = #objectOrder,
            providers = #providerOrder, candidates = lastCandidateCount,
            projectedEntities = #managedEntityOrder,
            entityProjectionRevision = entityProjectionRevision,
            entityProjectionSourceGeneration = entityProjectionSourceGeneration,
            entityProjectionBucket = entityProjectionBucket,
            expensiveCandidates = lastExpensiveCount,
            pendingRay = ray.pending ~= nil, raySerial = ray.serial,
            inputDevice = inputDevice, interactionAssist = assistEnabled,
            runningProviders = runningProviders,
            timedOutProviders = timedOutProviders,
            providerStartBudget = Limits.maximumProviderStartsPerSample,
            providerConcurrency = Limits.maximumConcurrentProviders,
            context = boundedInspectorValue(lastContextInspector),
            topCandidates = boundedInspectorValue(lastCandidateSummaries) or {},
        }
    end

    function sensor.cleanup()
        active = false
        clearIndexes()
        providers, providerOrder = {}, {}
        providerCursor = 1
        ray.pending = nil
        previousFocus, previousIntent = nil, nil
    end

    return sensor
end
