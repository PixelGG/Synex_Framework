SynexEntityLifecyclePolicy = {}

function SynexEntityLifecyclePolicy.create(options)
    assert(type(options) == 'table', 'entity lifecycle policy options are required')
    local repository = assert(options.authorityRepository,
        'entity lifecycle policy repository is required')
    local entityRuntime = assert(options.entityRuntime,
        'entity lifecycle policy runtime is required')
    local foundation = assert(options.foundation,
        'entity lifecycle policy foundation is required')
    local observability = assert(options.observability,
        'entity lifecycle policy observability is required')
    local ports = assert(options.ports, 'entity lifecycle policy ports are required')
    local registry = assert(options.registry, 'entity lifecycle policy registry is required')
    local resourceName = assert(options.resourceName,
        'entity lifecycle policy resource name is required')
    local config = assert(options.config, 'entity lifecycle policy config is required')
    local policy = {}

    local function traceContext(value, fallback)
        local traceId = type(value) == 'table' and value.traceId or nil
        if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 128
            or traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            traceId = fallback
        end
        return { traceId = traceId }
    end

    local function validOwnerId(value)
        return type(value) == 'string' and #value >= 1 and #value <= 64
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function deleteRuntime(ownerType, ownerId, filter, reasonCode, context)
        local deadline = ports.getGameTimer()
            + math.max(1000, math.min(config.lifecycleCleanupTimeoutMs or 15000, 60000))
        local removed = 0
        for _, record in ipairs(registry.forLogicalOwner(ownerType, ownerId)) do
            if filter == nil or filter(record) then
                if ports.getGameTimer() >= deadline then
                    foundation.setHealth('DEGRADED', 'ENTITY_RESOURCE_LEAK')
                    return foundation.failure(
                        'DELETE_FAILED',
                        'Entity owner cleanup exceeded its bounded deadline',
                        true,
                        context
                    )
                end
                local deleted, deleteError = entityRuntime.delete(record, deadline)
                if not deleted then
                    foundation.setHealth('DEGRADED', 'ENTITY_RESOURCE_LEAK')
                    observability.increment('entity_delete_failures', {
                        lifecycle = ownerType,
                    }, 1)
                    observability.increment('entity_delete_failures_total', {
                        lifecycle = ownerType,
                    }, 1)
                    return nil, deleteError
                end
                removed = removed + 1
                observability.lifecycle('deleted', record, reasonCode, context)
                observability.increment('entity_delete_total', {
                    lifecycle = ownerType,
                }, 1)
                observability.gauge('entity_live_total', {}, registry.count())
            end
        end
        return removed
    end

    local function summary(ownerType, ownerId, context)
        if not validOwnerId(ownerId) then
            return foundation.failure(
                'INVALID_LOGICAL_OWNER',
                'The lifecycle owner identity is invalid',
                false,
                context
            )
        end
        return repository.getOwnerDeletionSummary(ownerType, ownerId, context)
    end

    local function deleteOwner(ownerType, ownerId, reasonCode, context)
        local current, summaryError = summary(ownerType, ownerId, context)
        if not current then return nil, summaryError end
        if current.persistent > 0 then
            return foundation.failure(
                ownerType == 'group' and 'GROUP_DELETE_BLOCKED' or 'CHARACTER_DELETE_BLOCKED',
                'Persistent entities must be transferred or deleted explicitly first',
                false,
                context
            )
        end

        local removed, runtimeError = deleteRuntime(
            ownerType, ownerId, nil, reasonCode, context)
        if removed == nil then return nil, runtimeError end
        local affected = 0
        local maximumBatches = math.max(1, math.ceil((config.maxOwnerEntities or 1024) / 64) + 1)
        for _ = 1, maximumBatches do
            local result, deleteError = repository.applyOwnerDeletion(
                ownerType,
                ownerId,
                'delete',
                nil,
                reasonCode,
                64,
                context
            )
            if not result then return nil, deleteError end
            affected = affected + result.affected
            if result.complete then
                observability.audit('entities.owner_lifecycle_deleted', ownerType, ownerId, {
                    definitions = affected,
                    runtimeEntities = removed,
                }, context)
                return {
                    completed = true,
                    definitions = affected,
                    runtimeEntities = removed,
                }
            end
        end
        foundation.setHealth('DEGRADED', 'ENTITY_OWNER_CLEANUP_BACKLOG')
        return foundation.failure(
            'CONCURRENT_MODIFICATION',
            'Entity owner cleanup exceeded its bounded batch count',
            true,
            context
        )
    end

    function policy.characterParticipant()
        return {
            name = resourceName,
            priority = 60,
            required = true,
            prepare = function(context)
                local characterId = context and context.character and context.character.id
                return summary('character', characterId,
                    traceContext(context, 'entity_character_prepare'))
            end,
            rollback = function() return true end,
            unload = function(context)
                local characterId = context and (
                    context.character and context.character.id
                    or context.session and context.session.characterId
                )
                if not validOwnerId(characterId) then
                    return foundation.failure('INVALID_CHARACTER',
                        'Character unload context is invalid', false)
                end
                local removed, cleanupError = deleteRuntime(
                    'character',
                    characterId,
                    function(record)
                        return record.persistencePolicy == 'temporary'
                            or record.persistencePolicy == 'session'
                    end,
                    'synex.entities.character_unloaded',
                    traceContext(context, 'entity_character_unload')
                )
                if removed == nil then return nil, cleanupError end
                return { removed = removed }
            end,
            deletePreflight = function(context)
                local characterId = context and context.character and context.character.id
                local lifecycleContext = traceContext(context, 'entity_character_preflight')
                local current, summaryError = summary(
                    'character', characterId, lifecycleContext
                )
                if not current then return nil, summaryError end
                if current.persistent > 0 then
                    return {
                        action = 'block',
                        code = 'CHARACTER_DELETE_BLOCKED',
                        message = 'Persistent entities must be transferred or deleted explicitly first',
                    }
                end
                return {
                    action = current.total > 0 and 'delete' or 'allow',
                    metadata = {
                        expected = current.total,
                        ownerLifetime = current.ownerLifetime,
                        session = current.session,
                        temporary = current.temporary,
                    },
                }
            end,
            deleteCommit = function(context)
                local plan = context and context.plan
                if type(plan) ~= 'table' or not validOwnerId(plan.characterId) then
                    return foundation.failure('INVALID_DELETE_PLAN',
                        'Character deletion plan is invalid', false)
                end
                local selected
                for _, action in ipairs(plan.actions or {}) do
                    if action.owner == resourceName then selected = action break end
                end
                if not selected or (selected.action ~= 'delete' and selected.action ~= 'allow') then
                    return foundation.failure('INVALID_DELETE_PLAN',
                        'Character entity lifecycle action is invalid', false)
                end
                if selected.action == 'allow' then return true end
                return deleteOwner(
                    'character',
                    plan.characterId,
                    'synex.entities.character_deleted',
                    traceContext(context, 'entity_character_commit')
                )
            end,
        }
    end

    function policy.groupDeletionProvider()
        return {
            domain = 'group',
            name = 'entity_ownership',
            schemaVersion = 1,
            preflight = function(request)
                local context = traceContext(request and request.context,
                    'entity_group_preflight')
                if type(request) ~= 'table' or request.domain ~= 'group'
                    or not validOwnerId(request.subjectId) then
                    return foundation.failure('INVALID_DELETION_REQUEST',
                        'The group entity deletion request is invalid', false, context)
                end
                local current, summaryError = summary('group', request.subjectId, context)
                if not current then return nil, summaryError end
                if current.persistent > 0 then
                    return {
                        decision = 'block',
                        reason = 'Persistent group entities require explicit transfer or deletion.',
                        metadata = { persistent = current.persistent, total = current.total },
                    }
                end
                if current.total == 0 then
                    return { decision = 'allow', metadata = {} }
                end
                return {
                    decision = 'delete',
                    metadata = {
                        expected = current.total,
                        ownerLifetime = current.ownerLifetime,
                        session = current.session,
                        temporary = current.temporary,
                    },
                }
            end,
            execute = function(request)
                local context = traceContext(request and request.context,
                    'entity_group_execute')
                if type(request) ~= 'table' or request.domain ~= 'group'
                    or request.decision ~= 'delete' or not validOwnerId(request.subjectId) then
                    return foundation.failure('INVALID_DELETION_REQUEST',
                        'The group entity deletion action is invalid', false, context)
                end
                return deleteOwner(
                    'group',
                    request.subjectId,
                    'synex.entities.group_deleted',
                    context
                )
            end,
        }
    end

    return policy
end
