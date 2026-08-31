SynexInteractTargetSelector = {}

local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded before target selectors')

local ENTITY_TYPES = { object = true, ped = true, vehicle = true }

local function entityKind(target)
    return type(target) == 'table'
        and (target.kind == 'entity' or target.kind == 'ambient')
end

function SynexInteractTargetSelector.matchesTarget(binding, objectKey, target)
    if type(binding) ~= 'table' or type(target) ~= 'table' then return false end
    if binding.type == 'worldAnchor' then
        return target.kind == 'world' and type(target.worldRef) == 'table'
            and target.worldRef.key == binding.key
            and (target.worldRef.kind == nil or target.worldRef.kind == 'anchor')
    elseif binding.type == 'worldRef' then
        return target.kind == 'world' and type(target.worldRef) == 'table'
            and target.worldRef.kind == binding.kind
            and target.worldRef.key == binding.key
    elseif binding.type == 'entityRef' then
        return target.kind == 'entity' and type(target.entityRef) == 'table'
            and target.entityRef.entityId == binding.entityId
            and target.entityRef.generation == binding.generation
            and target.bone == nil
    elseif binding.type == 'entityArchetype' then
        return entityKind(target) and target.bone == nil
    elseif binding.type == 'entityBone' then
        return entityKind(target) and target.bone == binding.bone
    elseif binding.type == 'staticTransform' then
        return target.kind == 'static' and target.bindingKey == objectKey
    elseif binding.type == 'dynamic' then
        return target.kind == 'dynamic' and target.bindingKey == binding.bindingKey
    end
    return false
end

function SynexInteractTargetSelector.matchesManaged(binding, target, entity)
    if not SynexInteractTargetSelector.matchesTarget(binding, nil, target)
        or target.kind ~= 'entity' or type(target.entityRef) ~= 'table'
        or not Validation.isPlainTable(entity) or entity.materialized ~= true
        or entity.entityId ~= target.entityRef.entityId
        or entity.generation ~= target.entityRef.generation
        or not ENTITY_TYPES[entity.entityType]
        or not Validation.isInteger(entity.model, 0, 4294967295)
        or not Validation.isInteger(entity.bucket, 0, 2147483647)
        or not Validation.isInteger(entity.netId, 1, 65535)
        or entity.archetype ~= nil and not Validation.semanticKey(entity.archetype, 128) then
        return false
    end
    if binding.model ~= nil and entity.model ~= binding.model then return false end
    if binding.archetype ~= nil and entity.archetype ~= binding.archetype then return false end
    return true
end

function SynexInteractTargetSelector.matchesAmbient(binding, target, actual)
    if not SynexInteractTargetSelector.matchesTarget(binding, nil, target)
        or target.kind ~= 'ambient' or not Validation.isPlainTable(actual)
        or not ENTITY_TYPES[actual.entityType]
        or not Validation.isInteger(actual.model, 0, 4294967295) then
        return false
    end
    -- Ambient Cfx entities have no canonical Synex archetype fact. Selectors
    -- containing an archetype therefore remain managed-only and fail closed.
    if binding.archetype ~= nil or binding.model == nil then return false end
    return actual.model == target.model and actual.model == binding.model
end
