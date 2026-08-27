SynexEntityExtensions = {}
local COMPONENT_MODES = { persistent = true, replicated = true, runtime = true }
local STATE_AUTHORITIES = { client_observed = true, server = true }
local STATE_REPLICATION = { none = true, scoped = true }
local STATE_TYPES = {
    boolean = true, integer = true, json = true, number = true, string = true,
}
local function isInteger(value, minimum, maximum)
    return type(value) == 'number' and value == value and value % 1 == 0
        and value >= minimum and value <= maximum
end
local function exactObject(value, keys)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then return false end
    for key in pairs(value) do
        if type(key) ~= 'string' or not keys[key] then return false end
    end
    for key in pairs(keys) do
        if rawget(value, key) == nil then return false end
    end
    return true
end
local function ownsNamespace(owner, namespace)
    return namespace == owner
        or namespace:sub(1, #owner + 1) == owner .. '.'
        or namespace:sub(1, #owner + 1) == owner .. ':'
end
function SynexEntityExtensions.create(options)
    assert(type(options) == 'table', 'entity extension service options are required')
    local coreRef = assert(options.coreRef, 'entity extension Core reference is required')
    local currentAuthority = assert(options.currentAuthority,
        'entity extension authority reader is required')
    local archetypes = assert(options.archetypes, 'entity archetype service is required')
    local extensionRegistry = assert(options.extensionRegistry,
        'entity extension definition registry is required')
    local foundation = assert(options.foundation, 'entity extension foundation is required')
    local jsonValues = assert(options.jsonValues, 'entity extension JSON service is required')
    local ports = assert(options.ports, 'entity extension ports are required')
    local registry = assert(options.registry, 'entity extension entity registry is required')
    local repository = assert(options.repository, 'entity extension repository is required')
    local schemaRules = assert(SynexEntityExtensionSchema,
        'entity extension schema rules are required')
    local validation = assert(options.validation, 'entity extension validation is required')
    local componentLifecycle = options.componentLifecycle
        or SynexEntityComponentLifecycle.create({
            extensionRegistry = extensionRegistry,
            foundation = foundation,
            jsonValues = jsonValues,
            ports = ports,
            repository = repository,
            validation = validation,
        })
    local observedEpochs = {}
    local service = {}
    local function fail(code, message, retryable, context)
        return foundation.failure(code, message, retryable, context)
    end

    local function mapError(operationError, replacements, context)
        if type(operationError) ~= 'table' then
            return fail('UNAVAILABLE', 'The entity extension operation failed', true, context)
        end
        local code = replacements[operationError.code] or operationError.code
        if type(code) ~= 'string' then code = 'UNAVAILABLE' end
        if code == 'CORE_UNAVAILABLE' or code == 'PERSISTENCE_UNAVAILABLE'
            or code == 'REGISTRY_LIMIT' then code = 'UNAVAILABLE' end
        if code == 'FOREIGN_NAMESPACE' then code = 'FORBIDDEN' end
        if code == 'INVALID_DEFINITION' or code == 'DEFINITION_TOO_LARGE' then code = 'INVALID_ARGUMENT' end
        if code:match('^IDEMPOTENCY_') then code = 'CONFLICT' end
        return nil, {
            code = code,
            message = operationError.message or 'The entity extension operation failed',
            retryable = operationError.retryable == true,
            traceId = type(context) == 'table' and context.traceId or nil,
        }
    end

    local function requireCapability(caller, capability, operation, context)
        local api = coreRef.value
        if not api or type(api.Capabilities) ~= 'table'
            or not foundation.isCallable(api.Capabilities.checkResource) then
            return fail('UNAVAILABLE', 'The delegated capability gateway is unavailable', true, context)
        end
        local invoked, allowed, capabilityError = foundation.protect(
            'core.capabilities.' .. operation,
            function() return api.Capabilities.checkResource(caller, capability, operation) end,
            context
        )
        if invoked and allowed == true then return true end
        return nil, type(capabilityError) == 'table' and capabilityError or {
            code = 'FORBIDDEN', message = 'The resource lacks the required capability',
            retryable = false, traceId = context and context.traceId or nil,
        }
    end

    local function callerContext(context, capability, operation, cost, readOnly)
        local caller, callerError = foundation.getCaller(context)
        if not caller then return nil, nil, callerError end
        local epoch = type(context) == 'table' and context.callerEpoch or nil
        if not isInteger(epoch, 1, 9007199254740991)
            or not foundation.isResourceActive(caller) then
            local _, staleError = fail('STALE_RESOURCE',
                'The invoking resource epoch is absent or stale', true, context)
            return nil, nil, staleError
        end
        local limited, limitError = foundation.takeRateLimit(caller, cost, context, readOnly)
        if not limited then return nil, nil, limitError end
        local allowed, capabilityError = requireCapability(
            caller, capability, operation, context)
        if not allowed then return nil, nil, capabilityError end
        return caller, epoch
    end

    local function validateReason(reasonCode, caller, context)
        local reason, reasonError = validation.validateReasonCode(reasonCode)
        if not reason then reasonError.traceId = context.traceId return nil, reasonError end
        if not ownsNamespace(caller, reason) then
            return fail('FORBIDDEN', 'The reason code belongs to another namespace', false, context)
        end
        return reason
    end

    local function validateNamespace(value, caller, context)
        local namespace, namespaceError = validation.validateNamespace(value)
        if not namespace then namespaceError.traceId = context.traceId return nil, namespaceError end
        if caller and not ownsNamespace(caller, namespace) then
            return fail('FORBIDDEN', 'The namespace belongs to another resource', false, context)
        end
        return namespace
    end

    local function validateStateKey(value, caller, context)
        if type(value) ~= 'string' or #value < 3 or #value > 128
            or value ~= value:lower() or value:match('^[a-z][a-z0-9_.:%-]+$') == nil then
            return fail('INVALID_ARGUMENT', 'The state key is invalid', false, context)
        end
        if caller and not ownsNamespace(caller, value) then
            return fail('FORBIDDEN', 'The state key belongs to another resource', false, context)
        end
        return value
    end

    local function validateRef(reference, caller, context)
        if not exactObject(reference, { entityId = true, generation = true }) then
            return fail('INVALID_ARGUMENT', 'EntityRef is invalid', false, context)
        end
        local entityId, idError = validation.validateEntityId(reference.entityId)
        if not entityId then idError.traceId = context.traceId return nil, idError end
        local generation, generationError = validation.validateGeneration(reference.generation)
        if not generation then generationError.traceId = context.traceId return nil, generationError end
        return registry.resolve(entityId, generation, caller)
    end

    local function decodeObject(encoded, code, context)
        local decoded, decodeError = jsonValues.decode(encoded, 'object')
        if decoded == nil then
            return fail(code, decodeError and decodeError.message or 'JSON is invalid', false, context)
        end
        return decoded
    end

    local function ensureOwner(caller, epoch, context)
        local begun, beginError = extensionRegistry.beginOwner(caller, epoch)
        if not begun then return mapError(beginError, {}, context) end
        observedEpochs[caller] = epoch
        if begun.replaced > 0 then
            componentLifecycle.cleanupOwner(caller)
        end
        return true
    end

    local function registrationResult(kind, namespace, caller, epoch, definition, context)
        local current = extensionRegistry.get(kind, namespace)
        if current then return current end
        local registered, registerError = extensionRegistry.register(
            kind, caller, epoch, definition)
        if not registered then return mapError(registerError, {}, context) end
        return registered
    end

    local function persistentContext(context, caller, request)
        return {
            traceId = context.traceId,
            idempotencyKey = request.idempotencyKey,
            idempotencyRequest = { caller = caller, request = request },
        }
    end

    local function authorityFence(record, context)
        local current = currentAuthority()
        if type(current) ~= 'table'
            or not isInteger(record.authorityLeaseGeneration, 1, 9007199254740991) then
            return fail('UNAVAILABLE', 'The entity authority lease is unavailable', true, context)
        end
        return current, record.authorityLeaseGeneration
    end

    local function getDefinition(kind, namespace, caller, epoch, ownershipCode, context)
        local definition, definitionError = extensionRegistry.get(kind, namespace)
        if not definition then
            local missingCode = kind == 'component' and 'COMPONENT_SCHEMA_NOT_FOUND'
                or 'STATE_SCHEMA_NOT_FOUND'
            return fail(missingCode, 'The registered schema does not exist', false, context)
        end
        if caller and (definition.ownerResource ~= caller or definition.ownerEpoch ~= epoch) then
            return fail(ownershipCode, 'The registered schema belongs to another resource epoch', false, context)
        end
        return definition
    end

    local function project(record, key, value, context)
        if not record.handle or not foundation.isCallable(ports.setEntityState) then
            return fail('UNAVAILABLE', 'Entity state-bag projection is unavailable', true, context)
        end
        local ok = foundation.protect('entity.state_bag.project', function()
            return ports.setEntityState(record.handle, key, value, true)
        end, context)
        if not ok then
            return fail('UNAVAILABLE', 'Entity state-bag projection failed', true, context)
        end
        return true
    end

    function service.registerArchetype(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.archetype.register', 'entities.archetype.register', 4, false)
        if not caller then return nil, callerError end
        return foundation.withOwnerMutation(caller, context, function()
            local ready, readyError = ensureOwner(caller, epoch, context)
            if not ready then return nil, readyError end
            return archetypes.registerOwned(request, caller, epoch, context)
        end)
    end

    function service.registerComponentSchema(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.component.schema.register', 'entities.component.schema.register', 4, false)
        if not caller then return nil, callerError end
        local keys = { maximumBytes = true, maximumDepth = true, namespace = true,
            persistenceMode = true, reasonCode = true, schemaJson = true,
            schemaVersion = true }
        if not exactObject(request, keys) then
            return fail('INVALID_ARGUMENT', 'Component schema registration is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            local ready, readyError = ensureOwner(caller, epoch, context)
            if not ready then return nil, readyError end
            local namespace, namespaceError = validateNamespace(request.namespace, caller, context)
            if not namespace then return nil, namespaceError end
            if not validateReason(request.reasonCode, caller, context)
                or not isInteger(request.schemaVersion, 1, 9007199254740991)
                or not isInteger(request.maximumBytes, 1, 32768)
                or not isInteger(request.maximumDepth, 1, 16)
                or not COMPONENT_MODES[request.persistenceMode] then
                return fail('COMPONENT_SCHEMA_INVALID', 'The component schema is invalid', false, context)
            end
            local schema, schemaError = decodeObject(
                request.schemaJson, 'COMPONENT_SCHEMA_INVALID', context)
            if not schema then return nil, schemaError end
            if not schemaRules.validateDefinition(schema, request.maximumDepth) then
                return fail('COMPONENT_SCHEMA_INVALID', 'The component schema is unsupported', false, context)
            end
            local existing = extensionRegistry.getComponentSchema(namespace)
            if existing then
                if existing.ownerResource == caller and existing.ownerEpoch == epoch
                    and existing.schemaVersion == request.schemaVersion
                    and existing.maximumBytes == request.maximumBytes
                    and existing.maximumDepth == request.maximumDepth
                    and existing.persistenceMode == request.persistenceMode
                    and existing.schemaJson == request.schemaJson then
                    return { namespace = namespace, ownerResource = caller,
                        registered = true, schemaVersion = request.schemaVersion }
                end
                return fail('SCHEMA_VERSION_CONFLICT',
                    'The component schema namespace is already registered', false, context)
            end
            local registered, registerError = registrationResult('component', namespace,
                caller, epoch, { maximumBytes = request.maximumBytes,
                    maximumDepth = request.maximumDepth, namespace = namespace,
                    persistenceMode = request.persistenceMode, schema = schema,
                    schemaJson = request.schemaJson, schemaVersion = request.schemaVersion }, context)
            if not registered then return nil, registerError end
            return { namespace = namespace, ownerResource = caller,
                registered = true, schemaVersion = request.schemaVersion }
        end)
    end

    function service.getComponent(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.component.read', 'entities.component.get', 1, true)
        if not caller then return nil, callerError end
        if not exactObject(request, { entity = true, namespace = true }) then
            return fail('INVALID_ARGUMENT', 'Component query is invalid', false, context)
        end
        local namespace, namespaceError = validateNamespace(request.namespace, nil, context)
        if not namespace then return nil, namespaceError end
        local record, entityError = validateRef(request.entity, nil, context)
        if not record then return nil, entityError end
        local definition, definitionError = getDefinition(
            'component', namespace, nil, epoch, 'COMPONENT_OWNERSHIP_DENIED', context)
        if not definition then return nil, definitionError end
        if definition.persistenceMode == 'runtime' then
            local component = componentLifecycle.getRuntime(
                record.entityId, record.generation, namespace)
            if not component then
                return fail('COMPONENT_NOT_FOUND', 'The runtime component does not exist', false, context)
            end
            return { entity = request.entity, namespace = namespace,
                payloadJson = component.payloadJson,
                persistenceMode = 'runtime', schemaVersion = component.schemaVersion,
                version = component.version }
        end
        local component, componentError = repository.getComponent(record.entityId, namespace, context)
        if not component then return mapError(componentError, {}, context) end
        return { entity = request.entity, namespace = namespace,
            payloadJson = component.payloadJson, persistenceMode = component.persistenceMode,
            schemaVersion = component.schemaVersion, version = component.version }
    end

    local function validateExtensionPayload(encoded, definition, code, context)
        if type(encoded) ~= 'string' or #encoded < 1 or #encoded > definition.maximumBytes then
            return fail(code, 'The encoded extension value exceeds its schema limit', false, context)
        end
        local value, decodeError = jsonValues.decode(encoded,
            definition.schema and definition.schema.type or nil)
        if value == nil then return fail(code,
            decodeError and decodeError.message or 'The extension value is invalid', false, context) end
        if not schemaRules.boundedDepth(value, definition.maximumDepth or 8) then
            return fail(code, 'The extension value exceeds its depth limit', false, context)
        end
        local validated, validationError, canonical = jsonValues.validate(
            definition.schema, value, code)
        if validated == nil then validationError.traceId = context.traceId return nil, validationError end
        if #canonical > definition.maximumBytes then
            return fail(code, 'The encoded extension value exceeds its schema limit', false, context)
        end
        return validated, nil, canonical
    end

    function service.setComponent(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.component.write', 'entities.component.set', 2, false)
        if not caller then return nil, callerError end
        local keys = { entity = true, expectedVersion = true, idempotencyKey = true,
            namespace = true, payloadJson = true, reasonCode = true, schemaVersion = true }
        if not exactObject(request, keys) or not isInteger(request.expectedVersion, 0, 9007199254740991)
            or not schemaRules.validToken(request.idempotencyKey, 8, 128) then
            return fail('INVALID_ARGUMENT', 'Component mutation is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            local namespace, namespaceError = validateNamespace(request.namespace, caller, context)
            if not namespace then return nil, namespaceError end
            if not validateReason(request.reasonCode, caller, context) then
                return fail('FORBIDDEN', 'The component reason code is invalid', false, context)
            end
            local record, entityError = validateRef(request.entity, caller, context)
            if not record then return nil, entityError end
            local definition, definitionError = getDefinition('component', namespace,
                caller, epoch, 'COMPONENT_OWNERSHIP_DENIED', context)
            if not definition then return nil, definitionError end
            if request.schemaVersion ~= definition.schemaVersion then
                return fail('COMPONENT_SCHEMA_MISMATCH', 'The component schema version is stale', false, context)
            end
            local value, valueError, canonical = validateExtensionPayload(
                request.payloadJson, definition, 'COMPONENT_SCHEMA_MISMATCH', context)
            if value == nil then return nil, valueError end
            local version
            if definition.persistenceMode == 'runtime' then
                local current = componentLifecycle.getRuntime(
                    record.entityId, record.generation, namespace)
                local currentVersion = current and current.version or 0
                if currentVersion ~= request.expectedVersion then
                    return fail('CONFLICT', 'The runtime component version is stale', true, context)
                end
                version = currentVersion + 1
                componentLifecycle.putRuntime(record.entityId, namespace, {
                    generation = record.generation, ownerEpoch = epoch,
                    ownerResource = caller, payloadJson = canonical,
                    schemaVersion = definition.schemaVersion, version = version,
                })
            else
                local current, leaseGeneration, authorityError = authorityFence(record, context)
                if not current then return nil, authorityError end
                local stored, storeError = repository.setComponent(record.entityId,
                    record.generation, caller, definition, canonical,
                    request.expectedVersion, current, leaseGeneration,
                    persistentContext(context, caller, request))
                if not stored then return mapError(storeError, {
                    FOREIGN_RESOURCE_OWNER = 'COMPONENT_OWNERSHIP_DENIED' }, context) end
                version = stored.version
                if definition.persistenceMode == 'replicated' then
                    local projected, projectionError = project(record,
                        'synex:component:' .. namespace, value, context)
                    if not projected then return nil, projectionError end
                end
            end
            return { entity = request.entity, namespace = namespace,
                schemaVersion = definition.schemaVersion, stored = true, version = version }
        end)
    end

    function service.removeComponent(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.component.write', 'entities.component.remove', 2, false)
        if not caller then return nil, callerError end
        local keys = { entity = true, expectedVersion = true, idempotencyKey = true,
            namespace = true, reasonCode = true }
        if not exactObject(request, keys) or not isInteger(request.expectedVersion, 1, 9007199254740991)
            or not schemaRules.validToken(request.idempotencyKey, 8, 128) then
            return fail('INVALID_ARGUMENT', 'Component removal is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            local namespace, namespaceError = validateNamespace(request.namespace, caller, context)
            if not namespace then return nil, namespaceError end
            if not validateReason(request.reasonCode, caller, context) then
                return fail('FORBIDDEN', 'The component reason code is invalid', false, context)
            end
            local record, entityError = validateRef(request.entity, caller, context)
            if not record then return nil, entityError end
            local definition, definitionError = getDefinition('component', namespace,
                caller, epoch, 'COMPONENT_OWNERSHIP_DENIED', context)
            if not definition then return nil, definitionError end
            if definition.persistenceMode == 'runtime' then
                local current = componentLifecycle.getRuntime(
                    record.entityId, record.generation, namespace)
                if not current then return fail('COMPONENT_NOT_FOUND',
                    'The runtime component does not exist', false, context) end
                if current.ownerResource ~= caller or current.ownerEpoch ~= epoch then
                    return fail('COMPONENT_OWNERSHIP_DENIED',
                        'The runtime component belongs to another resource epoch', false, context)
                end
                if current.version ~= request.expectedVersion then
                    return fail('CONFLICT', 'The runtime component version is stale', true, context)
                end
                componentLifecycle.removeRuntime(record.entityId, record.generation, namespace)
            else
                local current, leaseGeneration, authorityError = authorityFence(record, context)
                if not current then return nil, authorityError end
                local removed, removeError = repository.removeComponent(record.entityId,
                    record.generation, caller, namespace, request.expectedVersion,
                    current, leaseGeneration,
                    persistentContext(context, caller, request))
                if not removed then return mapError(removeError, {
                    FOREIGN_RESOURCE_OWNER = 'COMPONENT_OWNERSHIP_DENIED' }, context) end
                if definition.persistenceMode == 'replicated' then
                    local projected, projectionError = project(record,
                        'synex:component:' .. namespace, nil, context)
                    if not projected then return nil, projectionError end
                end
            end
            return { entity = request.entity, namespace = namespace, removed = true }
        end)
    end

    function service.registerStateSchema(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.state.schema.register', 'entities.state.schema.register', 4, false)
        if not caller then return nil, callerError end
        local keys = { authority = true, constraintsJson = true, key = true,
            maximumBytes = true, reasonCode = true, replication = true,
            schemaVersion = true, valueType = true }
        if not exactObject(request, keys) then
            return fail('INVALID_ARGUMENT', 'State schema registration is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            local ready, readyError = ensureOwner(caller, epoch, context)
            if not ready then return nil, readyError end
            local key, keyError = validateStateKey(request.key, caller, context)
            if not key then return nil, keyError end
            if not validateReason(request.reasonCode, caller, context)
                or not isInteger(request.schemaVersion, 1, 9007199254740991)
                or not isInteger(request.maximumBytes, 1, 8192)
                or not STATE_TYPES[request.valueType]
                or not STATE_AUTHORITIES[request.authority]
                or not STATE_REPLICATION[request.replication]
                or (request.authority == 'client_observed'
                    and request.replication ~= 'scoped') then
                return fail('STATE_SCHEMA_INVALID', 'The state schema is invalid', false, context)
            end
            local schema, schemaError = decodeObject(
                request.constraintsJson, 'STATE_SCHEMA_INVALID', context)
            if not schema then return nil, schemaError end
            if request.valueType ~= 'json' then
                if schema.type ~= nil and schema.type ~= request.valueType then
                    return fail('STATE_SCHEMA_INVALID', 'The state value type conflicts with its constraints', false, context)
                end
                schema.type = request.valueType
            end
            if not schemaRules.validateDefinition(schema, 8) then
                return fail('STATE_SCHEMA_INVALID', 'The state constraints are unsupported', false, context)
            end
            local existing = extensionRegistry.getStateSchema(key)
            if existing then
                if existing.ownerResource == caller and existing.ownerEpoch == epoch
                    and existing.schemaVersion == request.schemaVersion
                    and existing.maximumBytes == request.maximumBytes
                    and existing.valueType == request.valueType
                    and existing.authority == request.authority
                    and existing.replication == request.replication
                    and existing.constraintsJson == request.constraintsJson then
                    return { key = key, ownerResource = caller,
                        registered = true, schemaVersion = request.schemaVersion }
                end
                return fail('SCHEMA_VERSION_CONFLICT',
                    'The state schema key is already registered', false, context)
            end
            local registered, registerError = registrationResult('state', key, caller, epoch, {
                authority = request.authority, constraintsJson = request.constraintsJson,
                key = key, maximumBytes = request.maximumBytes, namespace = key,
                replication = request.replication, schema = schema,
                schemaVersion = request.schemaVersion, valueType = request.valueType,
            }, context)
            if not registered then return nil, registerError end
            return { key = key, ownerResource = caller,
                registered = true, schemaVersion = request.schemaVersion }
        end)
    end

    function service.getState(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.state.read', 'entities.state.get', 1, true)
        if not caller then return nil, callerError end
        if not exactObject(request, { entity = true, key = true }) then
            return fail('INVALID_ARGUMENT', 'State query is invalid', false, context)
        end
        local key, keyError = validateStateKey(request.key, nil, context)
        if not key then return nil, keyError end
        local record, entityError = validateRef(request.entity, nil, context)
        if not record then return nil, entityError end
        local definition, definitionError = getDefinition(
            'state', key, nil, epoch, 'STATE_AUTHORITY_DENIED', context)
        if not definition then return nil, definitionError end
        local state, stateError = repository.getState(record.entityId, key, context)
        if not state then return mapError(stateError, {}, context) end
        return { entity = request.entity, key = key, schemaVersion = state.schemaVersion,
            valueJson = state.valueJson, version = state.version }
    end

    function service.setState(request, context)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.state.write', 'entities.state.set', 2, false)
        if not caller then return nil, callerError end
        local keys = { entity = true, expectedVersion = true, idempotencyKey = true,
            key = true, reasonCode = true, schemaVersion = true, valueJson = true }
        if not exactObject(request, keys) or not isInteger(request.expectedVersion, 0, 9007199254740991)
            or not schemaRules.validToken(request.idempotencyKey, 8, 128) then
            return fail('INVALID_ARGUMENT', 'State mutation is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            local key, keyError = validateStateKey(request.key, caller, context)
            if not key then return nil, keyError end
            if not validateReason(request.reasonCode, caller, context) then
                return fail('FORBIDDEN', 'The state reason code is invalid', false, context)
            end
            local record, entityError = validateRef(request.entity, caller, context)
            if not record then return nil, entityError end
            local definition, definitionError = getDefinition('state', key,
                caller, epoch, 'STATE_AUTHORITY_DENIED', context)
            if not definition then return nil, definitionError end
            if request.schemaVersion ~= definition.schemaVersion then
                return fail('STATE_SCHEMA_MISMATCH', 'The state schema version is stale', false, context)
            end
            local value, valueError, canonical = validateExtensionPayload(
                request.valueJson, definition, 'STATE_SCHEMA_MISMATCH', context)
            if value == nil then return nil, valueError end
            local current, leaseGeneration, authorityError = authorityFence(record, context)
            if not current then return nil, authorityError end
            local stored, storeError = repository.setState(record.entityId,
                record.generation, caller, { authority = definition.authority,
                    key = key, replication = definition.replication,
                    schemaVersion = definition.schemaVersion }, canonical,
                request.expectedVersion, current, leaseGeneration,
                persistentContext(context, caller, request))
            if not stored then return mapError(storeError,
                { FOREIGN_RESOURCE_OWNER = 'STATE_AUTHORITY_DENIED' }, context) end
            if definition.replication == 'scoped' then
                local projected, projectionError = project(record, key, value, context)
                if not projected then return nil, projectionError end
            end
            return { entity = request.entity, key = key,
                schemaVersion = definition.schemaVersion, stored = true,
                version = stored.version }
        end)
    end

    local function mutateTags(request, context, mode)
        local caller, epoch, callerError = callerContext(context,
            'synex.entities.tags.write', 'entities.tags.' .. mode, 2, false)
        if not caller then return nil, callerError end
        local keys = { entity = true, idempotencyKey = true, reasonCode = true, tags = true }
        if not exactObject(request, keys) or not schemaRules.denseArray(request.tags, 32)
            or not schemaRules.validToken(request.idempotencyKey, 8, 128) then
            return fail('INVALID_ARGUMENT', 'Tag mutation is invalid', false, context)
        end
        return foundation.withOwnerMutation(caller, context, function()
            if not validateReason(request.reasonCode, caller, context) then
                return fail('FORBIDDEN', 'The tag reason code is invalid', false, context)
            end
            local record, entityError = validateRef(request.entity, caller, context)
            if not record then return nil, entityError end
            local tags, seen = {}, {}
            for index, value in ipairs(request.tags) do
                local tag, tagError = validateNamespace(value, caller, context)
                if not tag then return nil, tagError end
                if seen[tag] then return fail('INVALID_ARGUMENT',
                    'Tags must be unique', false, context) end
                seen[tag], tags[index] = true, tag
            end
            local current, leaseGeneration, authorityError = authorityFence(record, context)
            if not current then return nil, authorityError end
            local changed, mutationError = repository.mutateTags(record.entityId,
                record.generation, caller, tags, mode,
                current, leaseGeneration,
                persistentContext(context, caller, request))
            if not changed then return mapError(mutationError,
                { FOREIGN_RESOURCE_OWNER = 'TAG_OWNERSHIP_DENIED' }, context) end
            local updated, updateError = registry.update(
                record.entityId, record.generation, { tags = changed.tags })
            if not updated then
                foundation.setHealth('DEGRADED', 'ENTITY_TAG_INDEX_DRIFT')
                return fail('UNAVAILABLE',
                    'The durable tag mutation could not update the runtime index', true, context)
            end
            return { changed = changed.changed, entity = request.entity, tags = tags }
        end)
    end

    function service.addTags(request, context)
        return mutateTags(request, context, 'add')
    end

    function service.removeTags(request, context)
        return mutateTags(request, context, 'remove')
    end

    function service.cleanupOwner(ownerResource, ownerEpoch)
        ownerEpoch = ownerEpoch or observedEpochs[ownerResource]
        if not ownerEpoch then return 0 end
        local removed = extensionRegistry.cleanup(ownerResource, ownerEpoch)
        componentLifecycle.cleanupOwner(ownerResource, ownerEpoch)
        if observedEpochs[ownerResource] == ownerEpoch then observedEpochs[ownerResource] = nil end
        return removed
    end

    function service.componentCount(context)
        local persisted, countError = repository.countComponents(context)
        if persisted == nil then return nil, countError end
        return persisted + componentLifecycle.countRuntime()
    end

    function service.cleanupEntity(entityId, generation, mode, context)
        return componentLifecycle.cleanupEntity(entityId, generation, mode, context)
    end

    function service.hydrate(record, context)
        return componentLifecycle.hydrate(record, context)
    end

    function service.ownerEpoch(ownerResource)
        return observedEpochs[ownerResource]
    end

    function service.handlers()
        return {
            ['synex.entities.archetype.register'] = service.registerArchetype,
            ['synex.entities.component.get'] = service.getComponent,
            ['synex.entities.component.remove'] = service.removeComponent,
            ['synex.entities.component.schema.register'] = service.registerComponentSchema,
            ['synex.entities.component.set'] = service.setComponent,
            ['synex.entities.state.get'] = service.getState,
            ['synex.entities.state.schema.register'] = service.registerStateSchema,
            ['synex.entities.state.set'] = service.setState,
            ['synex.entities.tags.add'] = service.addTags,
            ['synex.entities.tags.remove'] = service.removeTags,
        }
    end

    return service
end
