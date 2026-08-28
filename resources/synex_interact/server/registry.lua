SynexInteractRegistry = {}

local Registry = SynexInteractRegistry
local V = SynexInteractValidation
local L = SynexInteractLimits

local function entityIndexKey(reference)
    if type(reference) ~= 'table' or type(reference.entityId) ~= 'string'
        or not V.isInteger(reference.generation, 1, 9007199254740991) then return nil end
    return reference.entityId .. ':' .. tostring(reference.generation)
end

function Registry.create()
    local objects, byOwner, byEntity, revision = {}, {}, {}, 0
    local api = {}

    local function normalizeAction(action)
        if type(action) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction action is invalid.')
        end
        local key, keyError = V.key(action.key, 'action.key')
        if not key then return nil, keyError end
        local label, labelError = V.text(action.label, L.maximumLabelLength, true)
        if not label then return nil, labelError end
        local description, descriptionError = V.text(action.description, L.maximumDescriptionLength, false)
        if descriptionError then return nil, descriptionError end
        local icon, iconError = V.text(action.icon, 96, false)
        if iconError then return nil, iconError end
        if action.priority ~= nil and (not V.isFinite(action.priority) or action.priority < -1000 or action.priority > 1000) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction action priority is invalid.')
        end
        if action.maxDistance ~= nil and (not V.isFinite(action.maxDistance) or action.maxDistance <= 0
            or action.maxDistance > L.maximumCandidateRadius) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction action maxDistance is invalid.')
        end
        if action.capability ~= nil and (type(action.capability) ~= 'string' or #action.capability < 3
            or #action.capability > 128 or not action.capability:match('^[a-z][a-z0-9%._%-]*$')) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction capability is invalid.')
        end
        if action.slot ~= nil and (type(action.slot) ~= 'string' or #action.slot < 1 or #action.slot > 64
            or not action.slot:match('^[a-z0-9][a-z0-9_.%-]*$')) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction slot is invalid.')
        end
        if action.leaseSeconds ~= nil and (not V.isInteger(action.leaseSeconds, 1, L.maximumLeaseSeconds)) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction lease duration is invalid.')
        end
        local tags, tagsError = V.tags(action.tags)
        if not tags then return nil, tagsError end
        local graph = nil
        if action.graph ~= nil then
            graph = V.copy(action.graph)
            if type(graph) ~= 'table' then
                return V.failure('INTERACT_GRAPH_INVALID', 'Interaction graph exceeds bounded data limits.')
            end
        end
        local metadata = V.copy(action.metadata or {})
        if type(metadata) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction action metadata is invalid.')
        end
        return {
            key = key,
            label = label,
            description = description,
            icon = icon,
            priority = action.priority or 0,
            maxDistance = action.maxDistance or 2.5,
            capability = action.capability,
            slot = action.slot or 'default',
            leaseSeconds = action.leaseSeconds or L.defaultLeaseSeconds,
            graph = graph,
            tags = tags,
            metadata = metadata,
        }
    end

    local function normalizeDefinition(owner, definition)
        if type(definition) ~= 'table' then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction definition is invalid.')
        end
        local key, keyError = V.key(definition.key)
        if not key then return nil, keyError end
        if objects[key] and objects[key].ownerResource ~= owner then
            return V.failure('INTERACT_DEFINITION_CONFLICT', 'Interaction key is owned by another resource.')
        end
        local actions = definition.actions
        if type(actions) ~= 'table' or #actions < 1 or #actions > L.maximumActionsPerObject then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction actions are invalid.')
        end
        local normalizedActions, actionKeys = {}, {}
        for index, action in ipairs(actions) do
            local normalized, actionError = normalizeAction(action)
            if not normalized then return nil, actionError end
            if actionKeys[normalized.key] then
                return V.failure('INTERACT_INVALID_ARGUMENT', 'Duplicate interaction action key.')
            end
            actionKeys[normalized.key] = true
            normalizedActions[index] = normalized
        end
        local anchor = definition.anchorRef and V.copy(definition.anchorRef) or nil
        local entity = definition.entityRef and V.copy(definition.entityRef) or nil
        local position
        if definition.position then
            position, keyError = V.vector3(definition.position)
            if not position then return nil, keyError end
        end
        if entity and not entityIndexKey(entity) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction EntityRef is invalid.')
        end
        if not anchor and not entity and not position then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction requires anchorRef, entityRef or position.')
        end
        if definition.radius ~= nil and (not V.isFinite(definition.radius)
            or definition.radius <= 0 or definition.radius > L.maximumCandidateRadius) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction radius is invalid.')
        end
        local tags, tagsError = V.tags(definition.tags)
        if not tags then return nil, tagsError end
        return {
            key = key,
            ownerResource = owner,
            anchorRef = anchor,
            entityRef = entity,
            position = position,
            radius = definition.radius or 3.0,
            tags = tags,
            actions = normalizedActions,
            revision = 0,
        }
    end

    local function detachIndex(object)
        local key = object and entityIndexKey(object.entityRef)
        if not key then return end
        local bucket = byEntity[key]
        if not bucket then return end
        bucket[object.key] = nil
        if next(bucket) == nil then byEntity[key] = nil end
    end

    local function attachIndex(object)
        local key = entityIndexKey(object.entityRef)
        if not key then return end
        byEntity[key] = byEntity[key] or {}
        byEntity[key][object.key] = true
    end

    function api.register(owner, definitions)
        local resource, ownerError = V.resourceName(owner)
        if not resource then return nil, ownerError end
        if type(definitions) ~= 'table' or #definitions < 1 or #definitions > L.maximumDefinitionsPerResource then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction definition batch is invalid.')
        end
        local staged, seen = {}, {}
        for _, definition in ipairs(definitions) do
            local normalized, definitionError = normalizeDefinition(resource, definition)
            if not normalized then return nil, definitionError end
            if seen[normalized.key] then
                return V.failure('INTERACT_INVALID_ARGUMENT', 'Duplicate interaction key in batch.')
            end
            seen[normalized.key] = true
            staged[#staged + 1] = normalized
        end
        revision = revision + 1
        byOwner[resource] = byOwner[resource] or {}
        for _, definition in ipairs(staged) do
            local previous = objects[definition.key]
            if previous then detachIndex(previous) end
            definition.revision = revision
            objects[definition.key] = definition
            byOwner[resource][definition.key] = true
            attachIndex(definition)
        end
        return { revision = revision, count = #staged }
    end

    function api.unregisterOwner(owner)
        local owned = byOwner[owner]
        if not owned then return 0 end
        local count = 0
        for key in pairs(owned) do
            detachIndex(objects[key])
            objects[key] = nil
            count = count + 1
        end
        byOwner[owner] = nil
        revision = revision + 1
        return count
    end

    function api.get(key) return objects[key] end

    function api.list()
        local out = {}
        for _, object in pairs(objects) do out[#out + 1] = object end
        table.sort(out, function(a, b) return a.key < b.key end)
        return out
    end

    function api.forEntity(reference)
        local key = entityIndexKey(reference)
        if not key then return {} end
        local out, bucket = {}, byEntity[key]
        if not bucket then return out end
        for objectKey in pairs(bucket) do
            if objects[objectKey] then out[#out + 1] = objects[objectKey] end
        end
        table.sort(out, function(a, b) return a.key < b.key end)
        return out
    end

    function api.findNearby(position, radius, limit)
        radius = math.min(radius or L.maximumCandidateRadius, L.maximumCandidateRadius)
        limit = math.min(limit or L.maximumCandidateResults, L.maximumCandidateResults)
        local radiusSquared, candidates = radius * radius, {}
        for _, object in pairs(objects) do
            if object.position then
                local distanceSquared = V.distanceSquared(position, object.position)
                if distanceSquared <= math.min(radiusSquared, object.radius * object.radius) then
                    candidates[#candidates + 1] = { object = object, distanceSquared = distanceSquared }
                end
            end
        end
        table.sort(candidates, function(a, b)
            if a.distanceSquared == b.distanceSquared then return a.object.key < b.object.key end
            return a.distanceSquared < b.distanceSquared
        end)
        while #candidates > limit do table.remove(candidates) end
        return candidates
    end

    function api.revision() return revision end

    return api
end
