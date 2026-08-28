SynexWorldRepository = {}

local Repository = SynexWorldRepository
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local MAXIMUM_SAFE_INTEGER = 9007199254740991
local MAXIMUM_OUTBOX_BYTES = 32 * 1024
local validValueTypes = {
    boolean = true, integer = true, number = true,
    string = true, enum = true, structured = true,
}
local validActorTypes = {
    resource = true, system = true, user = true, character = true, entity = true,
}
local validScopes = {
    global = true, region = true, location = true,
    interior = true, room = true, instance = true,
}
local transactionCodes = { state = 'ws', door = 'wd' }
local base36Digits = '0123456789abcdefghijklmnopqrstuvwxyz'

local function encodeTransactionCaller(caller)
    local digits = {}
    for index = 7, #caller do
        local byte = caller:byte(index)
        if byte >= 97 and byte <= 122 then
            digits[#digits + 1] = byte - 96
        elseif byte >= 48 and byte <= 57 then
            digits[#digits + 1] = byte - 21
        elseif byte == 95 then
            digits[#digits + 1] = 37
        else
            return nil
        end
    end
    if #digits < 1 or #digits > 58 then return nil end
    local encoded = {}
    while #digits > 0 do
        local quotient, carry = {}, 0
        for _, digit in ipairs(digits) do
            local current = carry * 38 + digit
            local divided = math.floor(current / 36)
            carry = current - divided * 36
            if #quotient > 0 or divided > 0 then
                quotient[#quotient + 1] = divided
            end
        end
        encoded[#encoded + 1] = base36Digits:sub(carry + 1, carry + 1)
        digits = quotient
    end
    if #encoded > 59 then return nil end
    local reversed = {}
    for index = #encoded, 1, -1 do reversed[#reversed + 1] = encoded[index] end
    return table.concat(reversed)
end

local function transactionOperation(kind, caller)
    local code, encoded = transactionCodes[kind], encodeTransactionCaller(caller)
    local operation = code and encoded and code .. '.' .. encoded or nil
    return operation and #operation <= 64 and operation or nil
end

local function callable(value)
    if type(value) == 'function' then return true end
    local ok, metatable = pcall(getmetatable, value)
    return ok and type(metatable) == 'table' and type(metatable.__call) == 'function'
end

local function errorValue(code, message, retryable, details)
    local _, candidate = Validation.failure(code, message, retryable, details)
    return candidate
end

local function raise(code, message, retryable, details)
    error(errorValue(code, message, retryable, details), 0)
end

local function validReference(value, minimum, maximum)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function numericInteger(value, minimum, maximum)
    local converted = tonumber(value)
    if not converted or converted ~= math.floor(converted)
        or converted < minimum or converted > maximum then return nil end
    return converted
end

local function normalizeTimestamp(value)
    if type(value) == 'string' and #value >= 19 and #value <= 64 then return value end
    if Validation.isFinite(value) and value >= 0 then return value end
    return nil
end

local function copyDecoded(value, depth, active, budget)
    local valueType = type(value)
    if valueType == 'nil' or valueType == 'boolean' or valueType == 'string' then return value end
    if valueType == 'number' then
        if not Validation.isFinite(value) then error('invalid numeric JSON value', 0) end
        return value
    end
    if valueType ~= 'table' or depth > Limits.maximumStructuredStateDepth then
        error('invalid JSON container', 0)
    end
    if not Validation.isJsonTable(value) then error('untrusted JSON container', 0) end
    local containerKind = Validation.jsonContainerKind(value)
    active = active or {}
    budget = budget or { entries = 0 }
    if active[value] then error('cyclic JSON container', 0) end
    active[value] = true
    local copied, key, maximumIndex, count, keyKind = {}, nil, 0, 0, nil
    while true do
        key = next(value, key)
        if key == nil then break end
        count, budget.entries = count + 1, budget.entries + 1
        if budget.entries > Limits.maximumStructuredStateItems then
            error('JSON container exceeds item limit', 0)
        end
        local candidateKind = type(key)
        if candidateKind == 'number' then
            if math.type(key) ~= 'integer' or key < 1 then error('invalid JSON array key', 0) end
            maximumIndex = math.max(maximumIndex, key)
        elseif candidateKind == 'string' then
            if #key < 1 or #key > Limits.maximumKeyLength or key:find('[%z\1-\31]') then
                error('invalid JSON object key', 0)
            end
        else
            error('invalid JSON key type', 0)
        end
        if keyKind and keyKind ~= candidateKind then error('mixed JSON container', 0) end
        keyKind = candidateKind
        copied[key] = copyDecoded(rawget(value, key), depth + 1, active, budget)
    end
    if keyKind == 'number' and maximumIndex ~= count then error('sparse JSON array', 0) end
    if containerKind == 'object' and keyKind == 'number'
        or containerKind == 'array' and keyKind == 'string' then
        error('invalid JSON container kind', 0)
    end
    active[value] = nil
    if containerKind then assert(Validation.markJsonContainer(copied, containerKind)) end
    return copied
end

function Repository.create(options)
    options = type(options) == 'table' and options or {}
    local database = options.database
    local jsonEncode, jsonDecode = options.jsonEncode, options.jsonDecode
    if type(database) ~= 'table' or not callable(database.read)
        or not callable(database.transaction) or not callable(jsonEncode)
        or not callable(jsonDecode) then
        error('world repository requires a database adapter and JSON codec', 0)
    end

    local function encode(value, maximumBytes, code)
        local called, encoded = pcall(jsonEncode, value)
        if not called or type(encoded) ~= 'string' or #encoded < 1
            or #encoded > maximumBytes then
            return nil, errorValue(code or 'WORLD_STATE_VALUE_INVALID',
                'World state could not be encoded within its bounded schema.')
        end
        return encoded
    end

    local function decode(value)
        if type(value) ~= 'string' or #value < 1 or #value > Limits.maximumStateBytes then
            return nil, errorValue('DATABASE_RESULT_INVALID',
                'World persistence returned an invalid encoded state.')
        end
        local called, decoded = pcall(jsonDecode, value)
        if not called then
            return nil, errorValue('DATABASE_RESULT_INVALID',
                'World persistence returned invalid JSON state.')
        end
        called, decoded = pcall(copyDecoded, decoded, 0)
        if not called then
            return nil, errorValue('DATABASE_RESULT_INVALID',
                'World persistence returned invalid structured state.')
        end
        return decoded
    end

    local function validateIdentity(candidate)
        if type(candidate) ~= 'table' or not validActorTypes[candidate.actorType]
            or not validReference(candidate.actorRef, 1, 128) then
            return nil, errorValue('INVALID_ARGUMENT', 'World mutation actor provenance is invalid.')
        end
        local source, sourceError = Validation.resourceName(candidate.sourceResource)
        if not source then return nil, sourceError end
        local reason, reasonError = Validation.reasonCode(candidate.reasonCode)
        if not reason then return nil, reasonError end
        if not validReference(candidate.traceId, 8, 64)
            or type(candidate.timestamp) ~= 'string' or #candidate.timestamp < 20
            or #candidate.timestamp > 32
            or candidate.timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d') == nil then
            return nil, errorValue('INVALID_ARGUMENT', 'World mutation trace provenance is invalid.')
        end
        return {
            actorType = candidate.actorType,
            actorRef = candidate.actorRef,
            sourceResource = source,
            reasonCode = reason,
            traceId = candidate.traceId,
            timestamp = candidate.timestamp,
        }
    end

    local function validateMutation(command, door)
        if type(command) ~= 'table' or not validReference(command.idempotencyKey, 8, 128)
            or not validReference(command.eventId, 8, 36)
            or not Validation.isInteger(command.expectedVersion, 0, MAXIMUM_SAFE_INTEGER)
            or not Validation.isInteger(command.schemaVersion, 1, 2147483647) then
            return nil, errorValue('INVALID_ARGUMENT', 'World persistence mutation identity is invalid.')
        end
        local key, keyError = Validation.namespacedKey(door and command.doorKey or command.stateKey)
        if not key then return nil, keyError end
        if door then
            if command.state ~= 'LOCKED' and command.state ~= 'UNLOCKED'
                and command.state ~= 'DISABLED' then
                return nil, errorValue('DOOR_STATE_INVALID', 'World door state is invalid.')
            end
        elseif not validScopes[command.scopeType]
            or not validReference(command.scopeRef, 3, Limits.maximumKeyLength)
            or not validValueTypes[command.valueType] then
            return nil, errorValue('INVALID_ARGUMENT', 'World state persistence scope is invalid.')
        end
        local provenance, provenanceError = validateIdentity(command.provenance)
        if not provenance then return nil, provenanceError end
        return { key = key, provenance = provenance }
    end

    local function appendOutbox(transaction, eventId, aggregateId, eventType,
        schemaVersion, payloadJson, traceId)
        local affected = transaction.affected([[INSERT INTO `synex_world_outbox`
            (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`, `trace_id`)
            VALUES (?, ?, ?, ?, ?, ?)]], {
            eventId, aggregateId, eventType, schemaVersion, payloadJson, traceId,
        })
        if affected ~= 1 then
            raise('OUTBOX_WRITE_FAILED', 'The World event was not persisted atomically.', true)
        end
    end

    local function concurrencyFailure(transaction, tableName, keyColumns, parameters,
        expectedSchemaVersion)
        local row = transaction.one(('SELECT `schema_version`, `version` FROM `%s` WHERE %s LIMIT 1')
            :format(tableName, keyColumns), parameters)
        if row and numericInteger(row.schema_version, 1, 2147483647) ~= expectedSchemaVersion then
            raise('STATE_SCHEMA_MISMATCH',
                'Persisted World state is incompatible with the active definition schema.')
        end
        raise('CONCURRENT_MODIFICATION',
            'World state changed before the requested mutation could be committed.', true)
    end

    local repository = {}

    function repository:getState(stateKey, scopeType, scopeRef)
        local key, keyError = Validation.namespacedKey(stateKey)
        if not key then return nil, keyError end
        if not validScopes[scopeType] or not validReference(scopeRef, 3, Limits.maximumKeyLength) then
            return Validation.failure('INVALID_ARGUMENT', 'World state lookup scope is invalid.')
        end
        local rows, readError = database:read([[SELECT `state_key`, `scope_type`, `scope_ref`,
                `schema_version`, `value_type`, `value_json`, `version`, `updated_by_type`,
                `updated_by_ref`, `source_resource`, `reason_code`, `trace_id`, `updated_at`
            FROM `synex_world_state`
            WHERE `state_key` = ? AND `scope_type` = ? AND `scope_ref` = ? LIMIT 1]],
            { key, scopeType, scopeRef }, { maximumRows = 1, maximumResultBytes = 65536 })
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > 1 then
            return Validation.failure('DATABASE_RESULT_INVALID',
                'World persistence returned an invalid state result.')
        end
        if #rows == 0 then return nil, nil end
        local row, schemaVersion, version = rows[1],
            numericInteger(rows[1].schema_version, 1, 2147483647),
            numericInteger(rows[1].version, 1, MAXIMUM_SAFE_INTEGER)
        local value, decodeError = decode(row.value_json)
        local updatedAt = normalizeTimestamp(row.updated_at)
        local sourceResource = select(1, Validation.resourceName(row.source_resource))
        local reasonCode = select(1, Validation.reasonCode(row.reason_code))
        if not schemaVersion or not version or not value and decodeError
            or row.state_key ~= key or row.scope_type ~= scopeType or row.scope_ref ~= scopeRef
            or not validValueTypes[row.value_type] or not validActorTypes[row.updated_by_type]
            or not validReference(row.updated_by_ref, 1, 128)
            or not sourceResource or not reasonCode
            or not validReference(row.trace_id, 8, 64) or not updatedAt then
            return nil, decodeError or errorValue('DATABASE_RESULT_INVALID',
                'World persistence returned a malformed state record.')
        end
        return {
            key = key,
            scope = { type = scopeType, ref = scopeRef },
            schemaVersion = schemaVersion,
            valueType = row.value_type,
            value = value,
            version = version,
            persistent = true,
            provenance = {
                actor = { type = row.updated_by_type, ref = row.updated_by_ref },
                sourceResource = sourceResource,
                reasonCode = reasonCode,
                traceId = row.trace_id,
                timestamp = updatedAt,
            },
        }, nil
    end

    function repository:setState(command)
        local validated, validationError = validateMutation(command, false)
        if not validated then return nil, validationError end
        local operation = transactionOperation('state', validated.provenance.sourceResource)
        if not operation then
            return Validation.failure('INVALID_ARGUMENT',
                'World state transaction caller identity is invalid.')
        end
        local valueJson, encodeError = encode(command.value, Limits.maximumStateBytes)
        if not valueJson then return nil, encodeError end
        local nextVersion = command.expectedVersion + 1
        local eventPayload = {
            eventId = command.eventId,
            key = validated.key,
            scope = { type = command.scopeType, ref = command.scopeRef },
            schemaVersion = command.schemaVersion,
            valueType = command.valueType,
            value = Validation.copy(command.value),
            previousVersion = command.expectedVersion,
            version = nextVersion,
            provenance = {
                actor = { type = validated.provenance.actorType,
                    ref = validated.provenance.actorRef },
                sourceResource = validated.provenance.sourceResource,
                reasonCode = validated.provenance.reasonCode,
                traceId = validated.provenance.traceId,
                timestamp = validated.provenance.timestamp,
            },
        }
        local payloadJson, payloadError = encode(eventPayload, MAXIMUM_OUTBOX_BYTES,
            'OUTBOX_WRITE_FAILED')
        if not payloadJson then return nil, payloadError end
        local result, operationError, metadata = database:transaction({
            operation = operation,
            idempotencyKey = command.idempotencyKey,
            request = {
                key = validated.key, scopeType = command.scopeType, scopeRef = command.scopeRef,
                schemaVersion = command.schemaVersion, valueType = command.valueType,
                value = command.value, expectedVersion = command.expectedVersion,
                actorType = validated.provenance.actorType,
                actorRef = validated.provenance.actorRef,
                sourceResource = validated.provenance.sourceResource,
                reasonCode = validated.provenance.reasonCode,
            },
            maximumRows = 2,
            maximumStatements = 4,
            maximumRequestBytes = 65536,
            maximumResponseBytes = 65536,
        }, function(transaction)
            local affected
            if command.expectedVersion == 0 then
                affected = transaction.affected([[INSERT IGNORE INTO `synex_world_state`
                    (`state_key`, `scope_type`, `scope_ref`, `schema_version`, `value_type`,
                        `value_json`, `version`, `updated_by_type`, `updated_by_ref`,
                        `source_resource`, `reason_code`, `trace_id`)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)]], {
                    validated.key, command.scopeType, command.scopeRef, command.schemaVersion,
                    command.valueType, valueJson, validated.provenance.actorType,
                    validated.provenance.actorRef, validated.provenance.sourceResource,
                    validated.provenance.reasonCode, validated.provenance.traceId,
                })
            else
                affected = transaction.affected([[UPDATE `synex_world_state`
                    SET `schema_version` = ?, `value_type` = ?, `value_json` = ?,
                        `version` = `version` + 1, `updated_by_type` = ?, `updated_by_ref` = ?,
                        `source_resource` = ?, `reason_code` = ?, `trace_id` = ?
                    WHERE `state_key` = ? AND `scope_type` = ? AND `scope_ref` = ?
                        AND `schema_version` = ? AND `version` = ?]], {
                    command.schemaVersion, command.valueType, valueJson,
                    validated.provenance.actorType, validated.provenance.actorRef,
                    validated.provenance.sourceResource, validated.provenance.reasonCode,
                    validated.provenance.traceId, validated.key, command.scopeType,
                    command.scopeRef, command.schemaVersion, command.expectedVersion,
                })
            end
            if affected ~= 1 then
                concurrencyFailure(transaction, 'synex_world_state',
                    '`state_key` = ? AND `scope_type` = ? AND `scope_ref` = ?',
                    { validated.key, command.scopeType, command.scopeRef }, command.schemaVersion)
            end
            appendOutbox(transaction, command.eventId, validated.key,
                'synex.world.state.changed', 1, payloadJson, validated.provenance.traceId)
            return eventPayload, nil
        end)
        if not result then return nil, operationError end
        result.eventId = result.eventId or command.eventId
        result.persistent = true
        result.replayed = type(metadata) == 'table' and metadata.replayed == true
        return result, nil
    end

    function repository:purgeStateScope(scopeType, scopeRef)
        if not validScopes[scopeType]
            or not validReference(scopeRef, 3, Limits.maximumKeyLength) then
            return Validation.failure('INVALID_ARGUMENT',
                'World state cleanup scope is invalid.')
        end
        if not callable(database.write) then
            return Validation.failure('CORE_UNAVAILABLE',
                'The World state cleanup port is unavailable.', true)
        end
        local result, writeError = database:write([[DELETE FROM `synex_world_state`
            WHERE `scope_type` = ? AND `scope_ref` = ?]], { scopeType, scopeRef }, {
            timeoutMs = 15000,
        })
        if not result then return nil, writeError end
        local affected = type(result) == 'table' and tonumber(result.affectedRows)
            or tonumber(result)
        if not affected or math.type(affected) ~= 'integer' or affected < 0
            or affected > MAXIMUM_SAFE_INTEGER then
            return Validation.failure('DATABASE_RESULT_INVALID',
                'World state cleanup returned an invalid affected-row count.')
        end
        return { scope = { type = scopeType, ref = scopeRef }, removed = affected }
    end

    function repository:getDoorState(doorKey)
        local key, keyError = Validation.namespacedKey(doorKey)
        if not key then return nil, keyError end
        local rows, readError = database:read([[SELECT `door_key`, `schema_version`, `state`,
                `version`, `updated_by_type`, `updated_by_ref`, `source_resource`,
                `reason_code`, `trace_id`, `updated_at`
            FROM `synex_world_door_states` WHERE `door_key` = ? LIMIT 1]],
            { key }, { maximumRows = 1, maximumResultBytes = 32768 })
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > 1 then
            return Validation.failure('DATABASE_RESULT_INVALID',
                'World persistence returned an invalid door state result.')
        end
        if #rows == 0 then return nil, nil end
        local row, schemaVersion, version, updatedAt = rows[1],
            numericInteger(rows[1].schema_version, 1, 2147483647),
            numericInteger(rows[1].version, 1, MAXIMUM_SAFE_INTEGER),
            normalizeTimestamp(rows[1].updated_at)
        local sourceResource = select(1, Validation.resourceName(row.source_resource))
        local reasonCode = select(1, Validation.reasonCode(row.reason_code))
        if not schemaVersion or not version or not updatedAt or row.door_key ~= key
            or row.state ~= 'LOCKED' and row.state ~= 'UNLOCKED' and row.state ~= 'DISABLED'
            or not validActorTypes[row.updated_by_type]
            or not validReference(row.updated_by_ref, 1, 128)
            or not sourceResource or not reasonCode
            or not validReference(row.trace_id, 8, 64) then
            return Validation.failure('DATABASE_RESULT_INVALID',
                'World persistence returned a malformed door state record.')
        end
        return {
            key = key,
            schemaVersion = schemaVersion,
            state = row.state,
            version = version,
            persistent = true,
            provenance = {
                actor = { type = row.updated_by_type, ref = row.updated_by_ref },
                sourceResource = sourceResource,
                reasonCode = reasonCode,
                traceId = row.trace_id,
                timestamp = updatedAt,
            },
        }, nil
    end

    function repository:setDoorState(command)
        local validated, validationError = validateMutation(command, true)
        if not validated then return nil, validationError end
        local operation = transactionOperation('door', validated.provenance.sourceResource)
        if not operation then
            return Validation.failure('INVALID_ARGUMENT',
                'World door transaction caller identity is invalid.')
        end
        local nextVersion = command.expectedVersion + 1
        local eventPayload = {
            eventId = command.eventId,
            key = validated.key,
            schemaVersion = command.schemaVersion,
            state = command.state,
            previousVersion = command.expectedVersion,
            version = nextVersion,
            provenance = {
                actor = { type = validated.provenance.actorType,
                    ref = validated.provenance.actorRef },
                sourceResource = validated.provenance.sourceResource,
                reasonCode = validated.provenance.reasonCode,
                traceId = validated.provenance.traceId,
                timestamp = validated.provenance.timestamp,
            },
        }
        local payloadJson, payloadError = encode(eventPayload, MAXIMUM_OUTBOX_BYTES,
            'OUTBOX_WRITE_FAILED')
        if not payloadJson then return nil, payloadError end
        local result, operationError, metadata = database:transaction({
            operation = operation,
            idempotencyKey = command.idempotencyKey,
            request = {
                key = validated.key, schemaVersion = command.schemaVersion,
                state = command.state, expectedVersion = command.expectedVersion,
                actorType = validated.provenance.actorType,
                actorRef = validated.provenance.actorRef,
                sourceResource = validated.provenance.sourceResource,
                reasonCode = validated.provenance.reasonCode,
            },
            maximumRows = 2,
            maximumStatements = 4,
            maximumRequestBytes = 32768,
            maximumResponseBytes = 32768,
        }, function(transaction)
            local affected
            if command.expectedVersion == 0 then
                affected = transaction.affected([[INSERT IGNORE INTO `synex_world_door_states`
                    (`door_key`, `schema_version`, `state`, `version`, `updated_by_type`,
                        `updated_by_ref`, `source_resource`, `reason_code`, `trace_id`)
                    VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)]], {
                    validated.key, command.schemaVersion, command.state,
                    validated.provenance.actorType, validated.provenance.actorRef,
                    validated.provenance.sourceResource, validated.provenance.reasonCode,
                    validated.provenance.traceId,
                })
            else
                affected = transaction.affected([[UPDATE `synex_world_door_states`
                    SET `schema_version` = ?, `state` = ?, `version` = `version` + 1,
                        `updated_by_type` = ?, `updated_by_ref` = ?, `source_resource` = ?,
                        `reason_code` = ?, `trace_id` = ?
                    WHERE `door_key` = ? AND `schema_version` = ? AND `version` = ?]], {
                    command.schemaVersion, command.state, validated.provenance.actorType,
                    validated.provenance.actorRef, validated.provenance.sourceResource,
                    validated.provenance.reasonCode, validated.provenance.traceId,
                    validated.key, command.schemaVersion, command.expectedVersion,
                })
            end
            if affected ~= 1 then
                concurrencyFailure(transaction, 'synex_world_door_states', '`door_key` = ?',
                    { validated.key }, command.schemaVersion)
            end
            appendOutbox(transaction, command.eventId, validated.key,
                'synex.world.door.state_changed', 1, payloadJson, validated.provenance.traceId)
            return eventPayload, nil
        end)
        if not result then return nil, operationError end
        result.eventId = result.eventId or command.eventId
        result.persistent = true
        result.replayed = type(metadata) == 'table' and metadata.replayed == true
        return result, nil
    end

    return repository
end
