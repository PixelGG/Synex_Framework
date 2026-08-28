SynexWorldStateEngine = {}

local StateEngine = SynexWorldStateEngine
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local MAXIMUM_SAFE_INTEGER = 9007199254740991
local stateTypes = {
    boolean = true, integer = true, number = true,
    string = true, enum = true, structured = true,
}
local scopes = {
    global = true, region = true, location = true,
    interior = true, room = true, instance = true,
}
local actorTypes = {
    resource = true, system = true, user = true, character = true, entity = true,
}

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function validReference(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function stateFailure(code, message, retryable, details)
    return Validation.failure(code, message, retryable, details)
end

local function structuredPropertyName(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:match('^[A-Za-z][A-Za-z0-9_.%-]*$') ~= nil
end

local function validStructuredSchema(schema)
    if not Validation.isPlainTable(schema)
        or (schema.type ~= 'object' and schema.type ~= 'array')
        or not Validation.isInteger(schema.maximumBytes, 1, Limits.maximumStateBytes)
        or not Validation.isInteger(schema.maximumDepth, 1,
            Limits.maximumStructuredStateDepth)
        or not Validation.isInteger(schema.maximumEntries, 1,
            Limits.maximumStructuredStateItems) then
        return false
    end
    local allowed = { type = true, maximumBytes = true, maximumDepth = true,
        maximumEntries = true }
    if schema.type == 'object' then
        allowed.properties, allowed.required, allowed.additionalProperties = true, true, true
    else
        allowed.items, allowed.maximumItems = true, true
    end
    if not Validation.exactObject(schema, allowed) then return false end

    local nodes = 0
    local function visit(node, depth)
        if not Validation.isPlainTable(node) or type(node.type) ~= 'string' then return false end
        nodes = nodes + 1
        if nodes > Limits.maximumStructuredStateSchemaNodes then return false end
        if node.type == 'boolean' then
            return Validation.exactObject(node, { type = true })
        end
        if node.type == 'integer' or node.type == 'number' then
            return Validation.exactObject(node, { type = true, minimum = true, maximum = true })
                and (node.minimum == nil or Validation.isFinite(node.minimum)
                    and math.abs(node.minimum) <= MAXIMUM_SAFE_INTEGER)
                and (node.maximum == nil or Validation.isFinite(node.maximum)
                    and math.abs(node.maximum) <= MAXIMUM_SAFE_INTEGER)
                and (node.minimum == nil or node.maximum == nil or node.minimum <= node.maximum)
        end
        if node.type == 'string' then
            return Validation.exactObject(node, { type = true, maxLength = true })
                and Validation.isInteger(node.maxLength, 1, 4096)
        end
        if node.type == 'enum' then
            if not Validation.exactObject(node, { type = true, allowed = true })
                or not Validation.isDenseArray(node.allowed, 64) or #node.allowed < 1 then
                return false
            end
            local seen = {}
            for _, item in ipairs(node.allowed) do
                if type(item) ~= 'string' or #item < 1 or #item > 128
                    or item:find('[%z\1-\31\127]') or seen[item] then return false end
                seen[item] = true
            end
            return true
        end
        if node.type == 'object' then
            if depth > schema.maximumDepth or not Validation.exactObject(node, {
                    type = true, properties = true, required = true,
                    additionalProperties = true,
                }) or not Validation.isPlainTable(node.properties)
                or node.additionalProperties ~= false
                or not Validation.isDenseArray(node.required,
                    Limits.maximumStructuredStateProperties) then return false end
            local propertyCount = 0
            for key, child in pairs(node.properties) do
                propertyCount = propertyCount + 1
                if propertyCount > Limits.maximumStructuredStateProperties
                    or not structuredPropertyName(key) or not visit(child, depth + 1) then
                    return false
                end
            end
            local required = {}
            for _, key in ipairs(node.required) do
                if not structuredPropertyName(key) or node.properties[key] == nil
                    or required[key] then return false end
                required[key] = true
            end
            return true
        end
        if node.type == 'array' then
            return depth <= schema.maximumDepth
                and Validation.exactObject(node,
                    { type = true, items = true, maximumItems = true })
                and Validation.isInteger(node.maximumItems, 1,
                    Limits.maximumStructuredStateArrayItems)
                and visit(node.items, depth + 1)
        end
        return false
    end
    local root
    if schema.type == 'object' then
        root = { type = schema.type, properties = schema.properties,
            required = schema.required, additionalProperties = schema.additionalProperties }
    else
        root = { type = schema.type, items = schema.items,
            maximumItems = schema.maximumItems }
    end
    return visit(root, 1)
end

local function structuredCopy(value, schema, jsonEncode)
    if not validStructuredSchema(schema) then
        return stateFailure('WORLD_STATE_SCHEMA_INVALID',
            'Structured World state schema is invalid.')
    end
    local entries, active = 0, {}
    local function copy(candidate, node, depth)
        if node.type == 'boolean' then
            if type(candidate) ~= 'boolean' then error('invalid boolean', 0) end
            return candidate
        end
        if node.type == 'integer' then
            if not Validation.isInteger(candidate, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER)
                or node.minimum ~= nil and candidate < node.minimum
                or node.maximum ~= nil and candidate > node.maximum then
                error('invalid integer', 0)
            end
            return candidate
        end
        if node.type == 'number' then
            if not Validation.isFinite(candidate) or math.abs(candidate) > MAXIMUM_SAFE_INTEGER
                or node.minimum ~= nil and candidate < node.minimum
                or node.maximum ~= nil and candidate > node.maximum then
                error('invalid number', 0)
            end
            return candidate + 0.0
        end
        if node.type == 'string' then
            if type(candidate) ~= 'string' or #candidate > node.maxLength
                or candidate:find('[%z\1-\31\127]') then error('invalid string', 0) end
            return candidate
        end
        if node.type == 'enum' then
            if type(candidate) ~= 'string' then error('invalid enum', 0) end
            for _, allowed in ipairs(node.allowed) do
                if candidate == allowed then return candidate end
            end
            error('invalid enum', 0)
        end
        if type(candidate) ~= 'table' or not Validation.isJsonTable(candidate)
            or depth > schema.maximumDepth or active[candidate] then
            error('invalid structured container', 0)
        end
        local containerKind = Validation.jsonContainerKind(candidate)
        if node.type == 'array' and containerKind == 'object'
            or node.type == 'object' and containerKind == 'array' then
            error('structured container kind mismatch', 0)
        end
        active[candidate] = true
        local copied = {}
        if node.type == 'array' then
            if not Validation.isDenseArray(candidate, node.maximumItems) then
                error('invalid array', 0)
            end
            for index, item in ipairs(candidate) do
                entries = entries + 1
                if entries > schema.maximumEntries then error('structured item limit', 0) end
                copied[index] = copy(item, node.items, depth + 1)
            end
        else
            local seen = {}
            for key, item in pairs(candidate) do
                local child = type(key) == 'string' and node.properties[key] or nil
                if not child then error('undeclared object property', 0) end
                entries, seen[key] = entries + 1, true
                if entries > schema.maximumEntries then error('structured item limit', 0) end
                copied[key] = copy(item, child, depth + 1)
            end
            for _, key in ipairs(node.required) do
                if not seen[key] then error('missing required property', 0) end
            end
        end
        active[candidate] = nil
        assert(Validation.markJsonContainer(copied, node.type))
        return copied
    end
    local copiedOk, copied = pcall(copy, value, schema, 1)
    if not copiedOk then
        return stateFailure('WORLD_STATE_VALUE_INVALID',
            'Structured World state does not satisfy its bounded schema.')
    end
    local encodedOk, encoded = pcall(jsonEncode, copied)
    if not encodedOk or type(encoded) ~= 'string' or #encoded > schema.maximumBytes then
        return stateFailure('WORLD_STATE_VALUE_INVALID',
            'Structured World state exceeds its encoded size limit.')
    end
    return copied
end

local function scalarCopy(definition, value, jsonEncode)
    local stateType = definition.stateType
    if stateType == 'boolean' then
        if type(value) ~= 'boolean' then
            return stateFailure('WORLD_STATE_VALUE_INVALID', 'World state must be boolean.')
        end
        return value
    end
    if stateType == 'integer' then
        if not Validation.isInteger(value, -MAXIMUM_SAFE_INTEGER, MAXIMUM_SAFE_INTEGER)
            or definition.minimum ~= nil and value < definition.minimum
            or definition.maximum ~= nil and value > definition.maximum then
            return stateFailure('WORLD_STATE_VALUE_INVALID', 'World state integer is outside its schema.')
        end
        return value
    end
    if stateType == 'number' then
        if not Validation.isFinite(value) or math.abs(value) > MAXIMUM_SAFE_INTEGER
            or definition.minimum ~= nil and value < definition.minimum
            or definition.maximum ~= nil and value > definition.maximum then
            return stateFailure('WORLD_STATE_VALUE_INVALID', 'World state number is outside its schema.')
        end
        return value + 0.0
    end
    if stateType == 'string' then
        local maximum = definition.maxLength or 4096
        if type(value) ~= 'string' or #value > maximum or #value > Limits.maximumStateBytes
            or Validation.hasControl(value) then
            return stateFailure('WORLD_STATE_VALUE_INVALID', 'World state string is outside its schema.')
        end
        return value
    end
    if stateType == 'enum' then
        if type(value) ~= 'string' or not Validation.isDenseArray(definition.allowed, 64) then
            return stateFailure('WORLD_STATE_SCHEMA_INVALID', 'World enum state schema is invalid.')
        end
        for _, allowed in ipairs(definition.allowed) do
            if value == allowed then return value end
        end
        return stateFailure('WORLD_STATE_VALUE_INVALID', 'World enum state value is not allowed.')
    end
    if stateType == 'structured' then
        return structuredCopy(value, definition.structuredSchema, jsonEncode)
    end
    return stateFailure('WORLD_STATE_SCHEMA_INVALID', 'World state type is unsupported.')
end

function StateEngine.create(options)
    options = type(options) == 'table' and options or {}
    local repository, resolveDefinition = options.repository, options.resolveDefinition
    local resolveScope = options.resolveScope
    local jsonEncode, newId, nowIso = options.jsonEncode, options.newId, options.nowIso
    local onChanged = options.onChanged
    if type(repository) ~= 'table' or not callable(repository.getState)
        or not callable(repository.setState) or not callable(resolveDefinition)
        or not callable(jsonEncode) or not callable(newId) or not callable(nowIso)
        or resolveScope ~= nil and not callable(resolveScope)
        or onChanged ~= nil and not callable(onChanged) then
        error('world state engine dependencies are incomplete', 0)
    end
    local runtimeState, persistentCache = {}, {}
    local cacheHead, cacheTail, cacheCount = nil, nil, 0
    local engine = {}

    local function unlinkCache(node)
        if node.previous then node.previous.next = node.next else cacheHead = node.next end
        if node.next then node.next.previous = node.previous else cacheTail = node.previous end
        persistentCache[node.key], cacheCount = nil, cacheCount - 1
    end

    local function cachePut(key, record)
        local previous = persistentCache[key]
        if previous and previous.present and record ~= nil
            and type(previous.record) == 'table'
            and Validation.isInteger(previous.record.version, 0, MAXIMUM_SAFE_INTEGER)
            and Validation.isInteger(record.version, 0, MAXIMUM_SAFE_INTEGER)
            and record.version < previous.record.version then
            return false
        end
        if previous then unlinkCache(previous) end
        local node = { key = key, present = record ~= nil,
            record = record and Validation.copy(record) or nil, previous = cacheTail }
        if cacheTail then cacheTail.next = node else cacheHead = node end
        cacheTail, persistentCache[key], cacheCount = node, node, cacheCount + 1
        while cacheCount > Limits.maximumPersistentStateCacheEntries do
            unlinkCache(cacheHead)
        end
        return true
    end

    local function cacheRemoveWhere(predicate)
        local node = cacheHead
        while node do
            local nextNode = node.next
            if predicate(node.key) then unlinkCache(node) end
            node = nextNode
        end
    end

    local function resolve(key)
        local normalized, keyError = Validation.namespacedKey(key)
        if not normalized then return nil, keyError end
        local called, definition, resolveError = pcall(resolveDefinition, normalized)
        if not called then
            return stateFailure('WORLD_NOT_FOUND', 'World state definition is unavailable.', true)
        end
        if not definition then return nil, resolveError or select(2, stateFailure(
            'WORLD_NOT_FOUND', 'World state definition does not exist.')) end
        if type(definition) ~= 'table' or definition.kind ~= 'world_state_definition'
            or definition.key ~= normalized or not stateTypes[definition.stateType]
            or not scopes[definition.scope]
            or definition.persistence ~= 'runtime' and definition.persistence ~= 'persistent'
            or not Validation.isInteger(definition.schemaVersion, 1, 2147483647)
            or not Validation.isInteger(definition.revision, 1, MAXIMUM_SAFE_INTEGER) then
            return stateFailure('WORLD_STATE_SCHEMA_INVALID',
                'World state definition is invalid or stale.')
        end
        return definition
    end

    local function scopeFor(definition, scopeRef)
        if definition.scope == 'global' then
            if scopeRef ~= nil and scopeRef ~= 'global' then
                return stateFailure('WORLD_REFERENCE_INVALID',
                    'Global World state cannot use a scoped reference.')
            end
            return 'global'
        end
        local normalized, scopeError
        if definition.scope == 'instance' then
            if not validReference(scopeRef, 8, 64) then
                return stateFailure('WORLD_REFERENCE_INVALID',
                    'Instance-scoped World state requires a valid instance identifier.')
            end
            normalized = scopeRef
        else
            normalized, scopeError = Validation.namespacedKey(scopeRef)
            if not normalized then return nil, scopeError end
        end
        if resolveScope then
            local called, resolved, resolveError = pcall(
                resolveScope, definition, normalized)
            if not called or not resolved then
                if type(resolveError) == 'table' and resolveError.code == 'STALE_RESOURCE' then
                    return nil, resolveError
                end
                return stateFailure('WORLD_REFERENCE_INVALID',
                    'World state scope does not exist or has the wrong type.')
            end
        end
        return normalized
    end

    local function validatedValue(definition, value, schemaMismatch)
        local copied, valueError = scalarCopy(definition, value, jsonEncode)
        if copied == nil and valueError then
            if schemaMismatch then
                return stateFailure('STATE_SCHEMA_MISMATCH',
                    'Persisted World state is incompatible with its active definition.')
            end
            return nil, valueError
        end
        return copied
    end

    local function defaultSnapshot(definition, scopeRef)
        if rawget(definition, 'default') == nil then
            return stateFailure('WORLD_STATE_NOT_FOUND', 'World state has no stored or default value.')
        end
        local value, valueError = validatedValue(definition, definition.default, false)
        if value == nil and valueError then return nil, valueError end
        return {
            key = definition.key,
            scope = { type = definition.scope, ref = scopeRef },
            schemaVersion = definition.schemaVersion,
            definitionRevision = definition.revision,
            valueType = definition.stateType,
            value = value,
            version = 0,
            persistent = definition.persistence == 'persistent',
            defaulted = true,
        }
    end

    local function runtimeKey(key, scopeType, scopeRef)
        return table.concat({ key, scopeType, scopeRef }, '\0')
    end

    local function contextProvenance(request, context)
        if type(context) ~= 'table' then
            return stateFailure('INVALID_ARGUMENT', 'World mutation caller context is required.')
        end
        local caller, callerError = Validation.resourceName(context.caller)
        if not caller then return nil, callerError end
        local traceId = context.traceId
        if not validReference(traceId, 8, 64) then
            return stateFailure('INVALID_ARGUMENT', 'World mutation trace identifier is invalid.')
        end
        local actorType, actorRef = 'resource', caller
        local actor = context.actor
        if actor ~= nil then
            if not Validation.exactObject(actor, { type = true, ref = true }) then
                return stateFailure('INVALID_ARGUMENT', 'World mutation actor is invalid.')
            end
            actorType, actorRef = actor.type, actor.ref
        elseif context.principalKind ~= nil or context.principalRef ~= nil then
            actorType, actorRef = context.principalKind, context.principalRef
        end
        if not actorTypes[actorType] or not validReference(actorRef, 1, 128)
            or actorType == 'resource' and actorRef ~= caller
            or actorType == 'system' and (caller ~= 'synex_core' or actorRef ~= caller) then
            return stateFailure('INVALID_ARGUMENT', 'World mutation actor provenance is invalid.')
        end
        local reason, reasonError = Validation.reasonCode(request.reasonCode)
        if not reason then return nil, reasonError end
        local called, timestamp = pcall(nowIso)
        if not called or type(timestamp) ~= 'string' or #timestamp < 20 or #timestamp > 32 then
            return stateFailure('CORE_UNAVAILABLE', 'World mutation timestamp is unavailable.', true)
        end
        return {
            actorType = actorType,
            actorRef = actorRef,
            sourceResource = caller,
            reasonCode = reason,
            traceId = traceId,
            timestamp = timestamp,
        }
    end

    local function eventId()
        local called, value, idError = pcall(newId, 'world_event')
        if not called or not validReference(value, 8, 36) then
            return stateFailure('CORE_UNAVAILABLE', 'World event identifier is unavailable.', true,
                type(idError) == 'table' and { code = idError.code } or nil)
        end
        return value
    end

    function engine:get(request)
        if not Validation.exactObject(request or {}, { key = true, scopeRef = true }) then
            return stateFailure('INVALID_ARGUMENT', 'World state lookup request is invalid.')
        end
        local definition, definitionError = resolve(request.key)
        if not definition then return nil, definitionError end
        local scopeRef, scopeError = scopeFor(definition, request.scopeRef)
        if not scopeRef then return nil, scopeError end
        local record, readError
        if definition.persistence == 'persistent' then
            local key = runtimeKey(definition.key, definition.scope, scopeRef)
            local cached = persistentCache[key]
            if cached then
                record = cached.present and Validation.copy(cached.record) or nil
            else
                record, readError = repository:getState(
                    definition.key, definition.scope, scopeRef)
                if not readError then cachePut(key, record) end
            end
        else
            record = runtimeState[runtimeKey(definition.key, definition.scope, scopeRef)]
        end
        if not record then
            if readError then return nil, readError end
            return defaultSnapshot(definition, scopeRef)
        end
        if record.schemaVersion ~= definition.schemaVersion
            or record.valueType ~= definition.stateType then
            return stateFailure('STATE_SCHEMA_MISMATCH',
                'Persisted World state is incompatible with its active definition.')
        end
        local value, valueError = validatedValue(definition, record.value, true)
        if value == nil and valueError then return nil, valueError end
        local snapshot = Validation.copy(record)
        snapshot.value = value
        snapshot.definitionRevision = definition.revision
        return snapshot
    end

    function engine:set(request, context)
        if not Validation.exactObject(request or {}, {
                key = true, scopeRef = true, value = true, expectedVersion = true,
                idempotencyKey = true, reasonCode = true,
            }) or not Validation.isInteger(request.expectedVersion, 0, MAXIMUM_SAFE_INTEGER)
            or not validReference(request.idempotencyKey, 8, 36) then
            return stateFailure('INVALID_ARGUMENT', 'World state mutation request is invalid.')
        end
        local definition, definitionError = resolve(request.key)
        if not definition then return nil, definitionError end
        local scopeRef, scopeError = scopeFor(definition, request.scopeRef)
        if not scopeRef then return nil, scopeError end
        local value, valueError = validatedValue(definition, request.value, false)
        if value == nil and valueError then return nil, valueError end
        local provenance, provenanceError = contextProvenance(request, context)
        if not provenance then return nil, provenanceError end
        local id, idError = eventId()
        if not id then return nil, idError end

        if definition.persistence == 'persistent' then
            local result, persistError = repository:setState({
                stateKey = definition.key,
                scopeType = definition.scope,
                scopeRef = scopeRef,
                schemaVersion = definition.schemaVersion,
                valueType = definition.stateType,
                value = value,
                expectedVersion = request.expectedVersion,
                idempotencyKey = request.idempotencyKey,
                eventId = id,
                provenance = provenance,
            })
            if not result then return nil, persistError end
            result.definitionRevision = definition.revision
            cachePut(runtimeKey(definition.key, definition.scope, scopeRef), result)
            if onChanged and result.replayed ~= true then
                pcall(onChanged, Validation.copy(result))
            end
            return result
        end

        local key = runtimeKey(definition.key, definition.scope, scopeRef)
        local current = runtimeState[key]
        local currentVersion = current and current.version or 0
        if current and current.schemaVersion ~= definition.schemaVersion then
            return stateFailure('STATE_SCHEMA_MISMATCH',
                'Runtime World state is incompatible with its active definition.')
        end
        if currentVersion ~= request.expectedVersion then
            return stateFailure('CONCURRENT_MODIFICATION',
                'World state changed before the requested mutation could be applied.', true,
                { expectedVersion = request.expectedVersion, currentVersion = currentVersion })
        end
        local record = {
            key = definition.key,
            scope = { type = definition.scope, ref = scopeRef },
            schemaVersion = definition.schemaVersion,
            definitionRevision = definition.revision,
            valueType = definition.stateType,
            value = value,
            version = currentVersion + 1,
            persistent = false,
            defaulted = false,
            eventId = id,
            provenance = {
                actor = { type = provenance.actorType, ref = provenance.actorRef },
                sourceResource = provenance.sourceResource,
                reasonCode = provenance.reasonCode,
                traceId = provenance.traceId,
                timestamp = provenance.timestamp,
            },
        }
        runtimeState[key] = Validation.copy(record)
        if onChanged then pcall(onChanged, Validation.copy(record)) end
        return record
    end

    function engine:purgeRuntime(definitionKey)
        local normalized, keyError = Validation.namespacedKey(definitionKey)
        if not normalized then return nil, keyError end
        local prefix, removed = normalized .. '\0', 0
        for key in pairs(runtimeState) do
            if key:sub(1, #prefix) == prefix then runtimeState[key], removed = nil, removed + 1 end
        end
        cacheRemoveWhere(function(key) return key:sub(1, #prefix) == prefix end)
        return { removed = removed, persistentPreserved = true }
    end

    function engine:purgeScope(scopeType, scopeRef)
        if not scopes[scopeType] or scopeType == 'global'
            or not validReference(scopeRef, 3, Limits.maximumKeyLength) then
            return stateFailure('INVALID_ARGUMENT', 'World state cleanup scope is invalid.')
        end
        local suffix, runtimeRemoved = '\0' .. scopeType .. '\0' .. scopeRef, 0
        for key in pairs(runtimeState) do
            if key:sub(-#suffix) == suffix then
                runtimeState[key], runtimeRemoved = nil, runtimeRemoved + 1
            end
        end
        cacheRemoveWhere(function(key) return key:sub(-#suffix) == suffix end)
        if not callable(repository.purgeStateScope) then
            return stateFailure('CORE_UNAVAILABLE',
                'The World persistent state cleanup path is unavailable.', true,
                { runtimeRemoved = runtimeRemoved })
        end
        local persistent, persistentError = repository:purgeStateScope(scopeType, scopeRef)
        if not persistent then return nil, persistentError end
        return {
            scope = { type = scopeType, ref = scopeRef },
            runtimeRemoved = runtimeRemoved,
            persistentRemoved = persistent.removed,
        }
    end

    return engine
end
