local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.state = function(deps)
    local foundation = assert(deps.foundation, 'state requires foundation')
    local contracts = assert(deps.contracts, 'state requires contracts')
    local owners = assert(deps.owners, 'state requires owners')
    local security = assert(deps.security, 'state requires security')
    local coreResource = assert(deps.coreResource, 'state requires core resource')
    local logger = foundation.logger
    local replicationEnabled = deps.replicationEnabled ~= false

    local definitions = {}
    local values = { global = {}, player = {}, entity = {}, character = {} }
    local restoredEpochs = {}

    local function validName(owner, name)
        if type(owner) ~= 'string' or not owner:match('^synex_[a-z0-9_]+$')
            or type(name) ~= 'string' or #name > 128
            or name:sub(1, #owner + 1) ~= owner .. '.' then return false end
        local suffix = name:sub(#owner + 2)
        return suffix:match('^[a-z][a-z0-9_%.]*$') ~= nil
            and suffix:sub(-1) ~= '.' and not suffix:find('..', 1, true)
    end

    local function replicationSubject(scope, subject)
        if scope == 'global' then return nil end
        return subject
    end

    local service = {}
    function service:define(owner, epoch, definition)
        if type(definition) ~= 'table' or not validName(owner, definition.name) then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State names must be namespaced to the owning resource.')
        end
        if definitions[definition.name] then return nil, foundation.error('STATE_EXISTS', 'The state definition already exists.') end
        local allowedScopes = { global = true, player = true, entity = true, character = true }
        local allowedAuthorities = { server = true, owner = true }
        if not allowedScopes[definition.scope] or not allowedAuthorities[definition.authority] then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State scope or authority is invalid.')
        end
        if type(definition.schema) ~= 'table' then return nil, foundation.error('INVALID_STATE_DEFINITION', 'A state schema is required.') end
        if definition.sensitive == true and definition.replicated == true then
            return nil, foundation.error('SENSITIVE_STATE_REPLICATION', 'Sensitive state cannot be replicated.')
        end
        if definition.replicated == true and not replicationEnabled then
            return nil, foundation.error('FEATURE_DISABLED', 'State replication is disabled by configuration.')
        end
        if definition.replicated == true and definition.scope ~= 'global' and definition.scope ~= 'player' then
            return nil, foundation.error('UNSUPPORTED_REPLICATION_SCOPE', 'Core state replication supports only global and player scopes; entity state is owned by synex_entities.')
        end
        for _, field in ipairs({ 'readCapability', 'writeCapability' }) do
            local capability = definition[field]
            if capability ~= nil and (type(capability) ~= 'string' or #capability > 128
                or not capability:match('^[a-z][a-z0-9%._%-]*$')
                or capability:match('[%._%-]$') ~= nil
                or capability:match('[%._%-][%._%-]') ~= nil) then
                return nil, foundation.error('INVALID_STATE_DEFINITION', field .. ' must be a valid capability name.')
            end
        end
        local token = foundation.nextId('state')
        local entry = foundation.copy(definition)
        entry.owner, entry.epoch, entry.token = owner, epoch, token
        definitions[definition.name] = entry
        local _, trackError = owners:track(owner, epoch, 'state_definition', token, function()
            definitions[definition.name] = nil
            for scope, scoped in pairs(values) do
                for subject, subjectValues in pairs(scoped) do
                    if type(subjectValues) == 'table' and subjectValues[definition.name] ~= nil then
                        if entry.replicated and deps.replicate and (scope == 'global' or scope == 'player') then
                            foundation.safeCall(deps.replicate, entry, replicationSubject(scope, subject), {
                                name = entry.name, scope = scope, subject = subject, value = nil,
                                revision = foundation.nextId('state_rev')
                            })
                        end
                        subjectValues[definition.name] = nil
                    end
                    if type(subjectValues) == 'table' and not next(subjectValues) then scoped[subject] = nil end
                end
            end
        end)
        if trackError then definitions[definition.name] = nil return nil, trackError end
        return token, nil
    end

    local function subjectKey(scope, subject)
        if scope == 'global' then return '_global' end
        if type(subject) ~= 'string' and type(subject) ~= 'number' then return nil end
        return tostring(subject)
    end

    local function authorize(caller, epoch, definition, operation)
        if caller ~= coreResource and not owners:isCurrent(caller, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The state caller restarted.', { retryable = true })
        end
        if caller == coreResource or caller == definition.owner then return true, nil end
        local capability = operation == 'read' and definition.readCapability or definition.writeCapability
        if not capability then
            return nil, foundation.error('STATE_PRIVATE', 'The state is private to its owner.')
        end
        return security.capabilities:check(caller, capability, { operation = 'state.' .. operation .. ':' .. definition.name })
    end

    function service:get(caller, epoch, name, subject)
        local definition = definitions[name]
        if not definition then return nil, foundation.error('STATE_NOT_FOUND', 'The state definition does not exist.') end
        local authorized, authorizationError = authorize(caller, epoch, definition, 'read')
        if not authorized then return nil, authorizationError end
        local key = subjectKey(definition.scope, subject)
        if not key then return nil, foundation.error('INVALID_STATE_SUBJECT', 'A state subject is required.') end
        local bucket = values[definition.scope][key]
        if not bucket or bucket[name] == nil then return nil, nil end
        return foundation.copy(bucket[name]), nil
    end

    function service:set(caller, epoch, name, subject, value, context)
        local definition = definitions[name]
        if not definition then return nil, foundation.error('STATE_NOT_FOUND', 'The state definition does not exist.') end
        if not owners:isCurrent(definition.owner, definition.epoch) then return nil, foundation.error('STATE_OWNER_UNAVAILABLE', 'The state owner restarted.') end
        local authorized, authorizationError = authorize(caller, epoch, definition, 'write')
        if not authorized then return nil, authorizationError end
        if definition.authority == 'owner' and caller ~= definition.owner then return nil, foundation.error('STATE_AUTHORITY_DENIED', 'Only the state owner may mutate this value.') end
        local key = subjectKey(definition.scope, subject)
        if not key then return nil, foundation.error('INVALID_STATE_SUBJECT', 'A state subject is required.') end
        local valid, finding = contracts.validate(definition.schema, value)
        if not valid then return nil, foundation.error('VALIDATION_FAILED', 'State value does not match its schema.', { details = finding }) end
        values[definition.scope][key] = values[definition.scope][key] or {}
        local oldValue = values[definition.scope][key][name]
        values[definition.scope][key][name] = foundation.copy(value)
        local snapshot = {
            name = name, scope = definition.scope, subject = key,
            value = foundation.copy(value), revision = foundation.nextId('state_rev')
        }
        if definition.replicated then
            local encodedOk, encoded = pcall(deps.platform.jsonEncode, value)
            if not encodedOk or type(encoded) ~= 'string' then
                values[definition.scope][key][name] = oldValue
                return nil, foundation.error('STATE_ENCODING_FAILED', 'Replicated state could not be encoded.')
            end
            if #encoded > math.min(definition.maximumBytes or 4096, 16384) then
                values[definition.scope][key][name] = oldValue
                return nil, foundation.error('STATE_PAYLOAD_TOO_LARGE', 'Replicated state exceeds its byte limit.')
            end
            if deps.replicate then
                local ok, replicated, replicationError = foundation.safeCall(deps.replicate, definition, subject, snapshot)
                if not ok or replicated ~= true then
                    values[definition.scope][key][name] = oldValue
                    logger:error('state replication failed', { state = name, scope = definition.scope, error = tostring(ok and replicationError or replicated) })
                    return nil, foundation.error('STATE_REPLICATION_FAILED', 'State replication failed.', { retryable = true })
                end
            else
                values[definition.scope][key][name] = oldValue
                return nil, foundation.error('STATE_REPLICATION_UNAVAILABLE', 'State replication is unavailable.', { retryable = true })
            end
        end
        return snapshot, nil
    end

    local function snapshotError(code, message, details)
        return foundation.error(code, message, { details = details })
    end

    local function snapshotLimits(options)
        options = type(options) == 'table' and options or {}
        local maximumBytes = options.maximumBytes or 65536
        local maximumValues = options.maximumValues or 512
        if type(maximumBytes) ~= 'number' or math.type(maximumBytes) ~= 'integer'
            or maximumBytes < 1024 or maximumBytes > 262144
            or type(maximumValues) ~= 'number' or math.type(maximumValues) ~= 'integer'
            or maximumValues < 1 or maximumValues > 4096 then
            return nil, snapshotError('INVALID_ARGUMENT', 'Snapshot limits are outside the supported range.')
        end
        return { maximumBytes = maximumBytes, maximumValues = maximumValues }, nil
    end

    local function encodedSize(value)
        local ok, encoded = pcall(deps.platform.jsonEncode, value)
        if not ok or type(encoded) ~= 'string' then return nil end
        return #encoded
    end

    function service:captureOwner(owner, epoch, options)
        local limits, limitError = snapshotLimits(options)
        if not limits then return nil, limitError end
        if type(owner) ~= 'string' or #owner < 1 or #owner > 64 or not owners:isEpoch(owner, epoch) then
            return nil, snapshotError('STALE_RESOURCE', 'The snapshot owner epoch is no longer present.')
        end
        local entries = {}
        local excludedSensitive = 0
        for name, definition in pairs(definitions) do
            if definition.owner == owner and definition.epoch == epoch and definition.persistent == true then
                if definition.sensitive == true then
                    excludedSensitive = excludedSensitive + 1
                else
                    for subject, bucket in pairs(values[definition.scope]) do
                        local value = nil
                        if type(bucket) == 'table' then value = bucket[name] end
                        if value ~= nil then
                            local valid, finding = contracts.validate(definition.schema, value)
                            local size = valid and encodedSize(value) or nil
                            if not valid or not size then
                                return nil, snapshotError('SNAPSHOT_VALUE_INVALID', 'A reconstructable state value cannot be snapshotted.', {
                                    name = name, subject = tostring(subject), finding = finding
                                })
                            end
                            if #entries >= limits.maximumValues then
                                return nil, snapshotError('SNAPSHOT_TOO_LARGE', 'The snapshot contains too many state values.')
                            end
                            entries[#entries + 1] = {
                                name = name,
                                scope = definition.scope,
                                subject = tostring(subject),
                                value = foundation.copy(value)
                            }
                        end
                    end
                end
            end
        end
        table.sort(entries, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            if a.scope ~= b.scope then return a.scope < b.scope end
            return a.subject < b.subject
        end)
        local snapshot = {
            schemaVersion = 1,
            owner = owner,
            ownerEpoch = epoch,
            capturedAt = foundation.utcIso(),
            values = entries
        }
        local size = encodedSize(snapshot)
        if not size or size > limits.maximumBytes then
            return nil, snapshotError('SNAPSHOT_TOO_LARGE', 'The reconstructable state snapshot exceeds its byte limit.')
        end
        return snapshot, nil, { bytes = size, values = #entries, excludedSensitive = excludedSensitive }
    end

    local function exactKeys(value, required)
        if type(value) ~= 'table' then return false end
        local allowed = {}
        for _, key in ipairs(required) do
            allowed[key] = true
            if value[key] == nil then return false end
        end
        for key in pairs(value) do if not allowed[key] then return false end end
        return true
    end

    local function rollbackRestore(applied)
        for index = #applied, 1, -1 do
            local item = applied[index]
            local bucket = values[item.definition.scope][item.subject]
            if item.hadValue then bucket[item.name] = item.oldValue else bucket[item.name] = nil end
            if not next(bucket) then values[item.definition.scope][item.subject] = nil end
            if item.definition.replicated and deps.replicate then
                local rollbackValue = nil
                if item.hadValue then rollbackValue = foundation.copy(item.oldValue) end
                foundation.safeCall(deps.replicate, item.definition,
                    replicationSubject(item.definition.scope, item.subject), {
                        name = item.name,
                        scope = item.definition.scope,
                        subject = item.subject,
                        value = rollbackValue,
                        revision = foundation.nextId('state_rev')
                    })
            end
        end
    end

    function service:restoreOwner(owner, epoch, snapshot, options)
        local limits, limitError = snapshotLimits(options)
        if not limits then return nil, limitError end
        if type(owner) ~= 'string' or #owner < 1 or #owner > 64 or not owners:isCurrent(owner, epoch) then
            return nil, snapshotError('STALE_RESOURCE', 'The restore target owner epoch is not active.')
        end
        if not exactKeys(snapshot, { 'schemaVersion', 'owner', 'ownerEpoch', 'capturedAt', 'values' })
            or snapshot.schemaVersion ~= 1 or snapshot.owner ~= owner
            or type(snapshot.ownerEpoch) ~= 'number' or math.type(snapshot.ownerEpoch) ~= 'integer'
            or snapshot.ownerEpoch < 1 or snapshot.ownerEpoch + 2 ~= epoch
            or type(snapshot.capturedAt) ~= 'string' or #snapshot.capturedAt < 1 or #snapshot.capturedAt > 64
            or type(snapshot.values) ~= 'table' then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot envelope is invalid or does not precede the target epoch.')
        end
        if restoredEpochs[owner] == epoch then
            return nil, snapshotError('SNAPSHOT_REPLAYED', 'A state handoff was already restored into this owner epoch.')
        end
        local size = encodedSize(snapshot)
        if not size or size > limits.maximumBytes then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot encoding is invalid or exceeds its byte limit.')
        end
        local valueCount = 0
        for key in pairs(snapshot.values) do
            valueCount = valueCount + 1
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 or key > #snapshot.values then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot values must be a dense array.')
            end
        end
        if valueCount ~= #snapshot.values or valueCount > limits.maximumValues then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot values are sparse or exceed their limit.')
        end

        local candidates = {}
        local seen = {}
        for index, item in ipairs(snapshot.values) do
            if not exactKeys(item, { 'name', 'scope', 'subject', 'value' })
                or type(item.name) ~= 'string' or #item.name > 128
                or type(item.scope) ~= 'string'
                or type(item.subject) ~= 'string' or #item.subject < 1 or #item.subject > 128 then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot state entry is malformed.', { index = index })
            end
            local definition = definitions[item.name]
            if not definition or definition.owner ~= owner or definition.epoch ~= epoch
                or definition.scope ~= item.scope or definition.persistent ~= true or definition.sensitive == true then
                return nil, snapshotError('SNAPSHOT_STATE_UNAVAILABLE', 'Snapshot state is not reconstructable in the target epoch.', {
                    index = index, name = item.name
                })
            end
            local restoredSubject = replicationSubject(definition.scope, item.subject)
            if subjectKey(definition.scope, restoredSubject) ~= item.subject then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot state subject does not match its scope.', {
                    index = index, name = item.name
                })
            end
            local identity = item.scope .. ':' .. item.subject .. ':' .. item.name
            if seen[identity] then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot contains a duplicate state value.', { index = index })
            end
            seen[identity] = true
            local valid, finding = contracts.validate(definition.schema, item.value)
            local valueSize = valid and encodedSize(item.value) or nil
            if not valid or not valueSize then
                return nil, snapshotError('SNAPSHOT_VALUE_INVALID', 'Snapshot state value does not match its current schema.', {
                    index = index, name = item.name, finding = finding
                })
            end
            if definition.replicated then
                if not deps.replicate then
                    return nil, snapshotError('STATE_REPLICATION_UNAVAILABLE', 'Replicated snapshot state cannot be restored.')
                end
                if valueSize > math.min(definition.maximumBytes or 4096, 16384) then
                    return nil, snapshotError('STATE_PAYLOAD_TOO_LARGE', 'Replicated snapshot state exceeds its byte limit.', {
                        index = index, name = item.name
                    })
                end
            end
            local copied, copiedValue = foundation.safeCall(foundation.copy, item.value)
            if not copied then
                return nil, snapshotError('SNAPSHOT_VALUE_INVALID', 'Snapshot state value cannot be copied safely.', {
                    index = index, name = item.name
                })
            end
            local currentBucket = values[definition.scope][item.subject]
            local hadValue = currentBucket ~= nil and currentBucket[item.name] ~= nil
            local oldValue = nil
            if hadValue then
                local copiedOld, oldCopy = foundation.safeCall(foundation.copy, currentBucket[item.name])
                if not copiedOld then
                    return nil, snapshotError('SNAPSHOT_RESTORE_FAILED', 'Current state value cannot be copied safely.', {
                        index = index, name = item.name
                    })
                end
                oldValue = oldCopy
            end
            candidates[#candidates + 1] = {
                definition = definition,
                item = item,
                value = copiedValue,
                hadValue = hadValue,
                oldValue = oldValue
            }
        end

        local applied = {}
        for _, candidate in ipairs(candidates) do
            local definition, item = candidate.definition, candidate.item
            values[definition.scope][item.subject] = values[definition.scope][item.subject] or {}
            local bucket = values[definition.scope][item.subject]
            bucket[item.name] = candidate.value
            applied[#applied + 1] = {
                definition = definition,
                name = item.name,
                subject = item.subject,
                hadValue = candidate.hadValue,
                oldValue = candidate.oldValue
            }
            if definition.replicated then
                local replicationSnapshot = {
                    name = item.name,
                    scope = definition.scope,
                    subject = item.subject,
                    value = foundation.copy(item.value),
                    revision = foundation.nextId('state_rev')
                }
                local ok, replicated, replicationError = foundation.safeCall(deps.replicate, definition,
                    replicationSubject(definition.scope, item.subject), replicationSnapshot)
                if not ok or replicated ~= true then
                    rollbackRestore(applied)
                    logger:error('snapshot state replication failed', {
                        state = item.name,
                        scope = definition.scope,
                        error = tostring(ok and replicationError or replicated)
                    })
                    return nil, snapshotError('STATE_REPLICATION_FAILED', 'Snapshot state replication failed.')
                end
            end
        end
        restoredEpochs[owner] = epoch
        return {
            schemaVersion = 1,
            owner = owner,
            fromEpoch = snapshot.ownerEpoch,
            toEpoch = epoch,
            restored = #applied
        }, nil
    end

    function service:snapshot()
        local summary = { definitions = {}, counts = {} }
        for name, definition in pairs(definitions) do
            summary.definitions[name] = {
                owner = definition.owner, scope = definition.scope, authority = definition.authority,
                replicated = definition.replicated == true, persistent = definition.persistent == true,
                sensitive = definition.sensitive == true
            }
        end
        for scope, scoped in pairs(values) do
            local count = 0
            for _ in pairs(scoped) do count = count + 1 end
            summary.counts[scope] = count
        end
        return summary
    end

    return service
end
