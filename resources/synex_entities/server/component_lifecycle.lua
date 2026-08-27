SynexEntityComponentLifecycle = {}

local CLEANUP_MODES = {
    activation_failed = true,
    delete = true,
    dematerialize = true,
    entity_removed = true,
    network_reuse = true,
    resource_stop = true,
    spawn_rollback = true,
}

function SynexEntityComponentLifecycle.create(options)
    assert(type(options) == 'table', 'entity component lifecycle options are required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity component lifecycle extension registry is required')
    local foundation = assert(options.foundation,
        'entity component lifecycle foundation is required')
    local jsonValues = assert(options.jsonValues,
        'entity component lifecycle JSON service is required')
    local ports = assert(options.ports, 'entity component lifecycle ports are required')
    local repository = assert(options.repository,
        'entity component lifecycle repository is required')
    local schemaRules = assert(SynexEntityExtensionSchema,
        'entity component lifecycle schema rules are required')
    local validation = assert(options.validation,
        'entity component lifecycle validation is required')
    local runtimeComponents = {}
    local runtimeCount = 0
    local lifecycle = {}

    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end

    local function validatePayload(encoded, definition, code, context)
        if type(encoded) ~= 'string' or #encoded < 1
            or #encoded > definition.maximumBytes then
            return failure(code, 'The persisted extension payload is outside its bounds', false, context)
        end
        local value, decodeError = jsonValues.decode(
            encoded,
            definition.schema and definition.schema.type or nil
        )
        if value == nil then
            return failure(code, type(decodeError) == 'table' and decodeError.message
                or 'The persisted extension payload is invalid', false, context)
        end
        if not schemaRules.boundedDepth(value, definition.maximumDepth or 8) then
            return failure(code, 'The persisted extension payload exceeds its depth limit', false, context)
        end
        local validated, schemaError = jsonValues.validate(definition.schema, value, code)
        if validated == nil then
            if type(schemaError) == 'table' then schemaError.traceId = context and context.traceId end
            return nil, schemaError
        end
        return validated
    end

    function lifecycle.getRuntime(entityId, generation, namespace)
        local components = runtimeComponents[entityId]
        local component = components and components[namespace] or nil
        if not component or component.generation ~= generation then return nil end
        return component
    end

    function lifecycle.putRuntime(entityId, namespace, component)
        runtimeComponents[entityId] = runtimeComponents[entityId] or {}
        if runtimeComponents[entityId][namespace] == nil then
            runtimeCount = runtimeCount + 1
        end
        runtimeComponents[entityId][namespace] = component
        return component
    end

    function lifecycle.removeRuntime(entityId, generation, namespace)
        local components = runtimeComponents[entityId]
        local component = components and components[namespace] or nil
        if not component or component.generation ~= generation then return false end
        components[namespace] = nil
        runtimeCount = math.max(0, runtimeCount - 1)
        if next(components) == nil then runtimeComponents[entityId] = nil end
        return true
    end

    function lifecycle.countRuntime()
        return runtimeCount
    end

    function lifecycle.cleanupOwner(ownerResource, ownerEpoch)
        local removed = 0
        for entityId, components in pairs(runtimeComponents) do
            for namespace, component in pairs(components) do
                if component.ownerResource == ownerResource
                    and (ownerEpoch == nil or component.ownerEpoch == ownerEpoch) then
                    components[namespace] = nil
                    removed = removed + 1
                    runtimeCount = math.max(0, runtimeCount - 1)
                end
            end
            if next(components) == nil then runtimeComponents[entityId] = nil end
        end
        return removed
    end

    function lifecycle.cleanupEntity(entityId, generation, mode, context)
        local normalizedId, idError = validation.validateEntityId(entityId)
        if not normalizedId then
            if type(idError) == 'table' then idError.traceId = context and context.traceId end
            return nil, idError
        end
        local normalizedGeneration, generationError = validation.validateGeneration(generation)
        if not normalizedGeneration then
            if type(generationError) == 'table' then
                generationError.traceId = context and context.traceId
            end
            return nil, generationError
        end
        if not CLEANUP_MODES[mode] then
            return failure('INVALID_ARGUMENT', 'The component cleanup mode is invalid', false, context)
        end
        local components = runtimeComponents[normalizedId]
        local removed = 0
        if components then
            for namespace, component in pairs(components) do
                if component.generation == normalizedGeneration then
                    components[namespace] = nil
                    removed = removed + 1
                    runtimeCount = math.max(0, runtimeCount - 1)
                end
            end
            if next(components) == nil then runtimeComponents[normalizedId] = nil end
        end
        return { mode = mode, runtimeRemoved = removed }
    end

    function lifecycle.hydrate(record, context)
        if type(record) ~= 'table' or getmetatable(record) ~= nil
            or type(record.handle) ~= 'number' or record.handle ~= record.handle
            or record.handle % 1 ~= 0 or record.handle < 1
            or record.handle > 2147483647 then
            return failure('INVALID_ARGUMENT', 'The entity hydration record is invalid', false, context)
        end
        local entityId, idError = validation.validateEntityId(record.entityId)
        if not entityId then
            if type(idError) == 'table' then idError.traceId = context and context.traceId end
            return nil, idError
        end
        local generation, generationError = validation.validateGeneration(record.generation)
        if not generation then
            if type(generationError) == 'table' then
                generationError.traceId = context and context.traceId
            end
            return nil, generationError
        end
        if not foundation.isCallable(ports.setEntityState) then
            return failure('UNAVAILABLE', 'Entity state-bag hydration is unavailable', true, context)
        end
        local snapshot, snapshotError = repository.getHydrationSnapshot(
            entityId,
            generation,
            context
        )
        if not snapshot then return nil, snapshotError end
        if type(snapshot) ~= 'table' or type(snapshot.components) ~= 'table'
            or type(snapshot.states) ~= 'table' or #snapshot.components > 64
            or #snapshot.states > 64 then
            return failure('PERSISTENCE_UNAVAILABLE',
                'The entity hydration snapshot is invalid', true, context)
        end

        local projections = {}
        for _, row in ipairs(snapshot.components) do
            local definition = extensionRegistry.getComponentSchema(row.namespace)
            if not definition then
                return failure('COMPONENT_SCHEMA_NOT_FOUND',
                    'A replicated component schema is not registered', true, context)
            end
            if row.ownerResource ~= definition.ownerResource
                or row.schemaVersion ~= definition.schemaVersion
                or row.persistenceMode ~= 'replicated'
                or definition.persistenceMode ~= 'replicated' then
                return failure('COMPONENT_SCHEMA_MISMATCH',
                    'A replicated component does not match its registered schema', false, context)
            end
            local value, valueError = validatePayload(
                row.payloadJson,
                definition,
                'COMPONENT_SCHEMA_MISMATCH',
                context
            )
            if value == nil then return nil, valueError end
            projections[#projections + 1] = {
                key = 'synex:component:' .. row.namespace,
                value = value,
            }
        end
        for _, row in ipairs(snapshot.states) do
            local definition = extensionRegistry.getStateSchema(row.key)
            if not definition then
                return failure('STATE_SCHEMA_NOT_FOUND',
                    'A scoped entity-state schema is not registered', true, context)
            end
            if row.ownerResource ~= definition.ownerResource
                or row.schemaVersion ~= definition.schemaVersion
                or row.authority ~= definition.authority
                or row.replication ~= 'scoped'
                or definition.replication ~= 'scoped' then
                return failure('STATE_SCHEMA_MISMATCH',
                    'A scoped entity state does not match its registered schema', false, context)
            end
            local value, valueError = validatePayload(
                row.valueJson,
                definition,
                'STATE_SCHEMA_MISMATCH',
                context
            )
            if value == nil then return nil, valueError end
            projections[#projections + 1] = { key = row.key, value = value }
        end

        local projected = 0
        for _, projection in ipairs(projections) do
            local ok, result = foundation.protect('entity.state_bag.hydrate', function()
                return ports.setEntityState(record.handle, projection.key, projection.value, true)
            end, context)
            if not ok or result == false then
                for index = projected, 1, -1 do
                    foundation.protect('entity.state_bag.hydrate_rollback', function()
                        ports.setEntityState(record.handle, projections[index].key, nil, true)
                    end, context)
                end
                return failure('UNAVAILABLE', 'Entity state-bag hydration failed', true, context)
            end
            projected = projected + 1
        end
        return {
            components = #snapshot.components,
            projected = projected,
            states = #snapshot.states,
        }
    end

    return lifecycle
end
