local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.state = function(deps)
    local foundation = assert(deps.foundation, 'state requires foundation')
    local contracts = assert(deps.contracts, 'state requires contracts')
    local owners = assert(deps.owners, 'state requires owners')
    local security = assert(deps.security, 'state requires security')
    local coreResource = assert(deps.coreResource, 'state requires core resource')
    local players = deps.players
    local logger = foundation.logger
    local replicationEnabled = deps.replicationEnabled ~= false

    local definitions = {}
    local values = { global = {}, player = {}, entity = {}, character = {} }
    local valueMetadata = { global = {}, player = {}, entity = {}, character = {} }
    local playerGenerations = {}
    local restoredEpochs = {}
    local handoffTombstones = {}
    local capturedHandoffTombstones = setmetatable({}, { __mode = 'k' })
    local definitionCount = 0
    local definitionCounts = {}
    local valueCount = 0
    local valueBytes = 0
    local valueCounts = {}
    local valueBytesByOwner = {}
    local replicationCleanupHead = nil
    local replicationCleanupTail = nil
    local replicationCleanupCount = 0
    local replicationRepairHead = nil
    local replicationRepairTail = nil
    local replicationRepairCount = 0
    local replicationRepairBytes = 0
    local replicationRepairsByKey = {}
    local replicationRepairRejected = 0
    local retryRepairFirst = false
    local definitionFields = {
        ['$schema'] = true,
        name = true,
        scope = true,
        authority = true,
        schema = true,
        sensitive = true,
        replicated = true,
        persistent = true,
        maximumBytes = true,
        readCapability = true,
        writeCapability = true
    }
    local maximumSchemaDepth = 24
    local maximumSchemaKeys = 512
    local maximumSchemaBytes = 32768
    local maximumReplicatedStateBytes = 16384
    local function boundedLimit(value, fallback, minimum, maximum)
        if type(value) ~= 'number' or math.type(value) ~= 'integer' then return fallback end
        return math.max(minimum, math.min(value, maximum))
    end
    local maximumDefinitions = boundedLimit(deps.maximumDefinitions, 2048, 1, 8192)
    local maximumDefinitionsPerOwner = boundedLimit(
        deps.maximumDefinitionsPerOwner, 256, 1, 1024)
    local maximumValues = boundedLimit(deps.maximumValues, 32768, 1, 131072)
    local maximumValuesPerOwner = boundedLimit(deps.maximumValuesPerOwner, 8192, 1, 32768)
    local maximumValueBytes = boundedLimit(
        deps.maximumValueBytes, 64 * 1024 * 1024, 64, 256 * 1024 * 1024)
    local maximumValueBytesPerOwner = boundedLimit(
        deps.maximumValueBytesPerOwner, 16 * 1024 * 1024, 64, 64 * 1024 * 1024)
    local maximumReplicationRepairs = boundedLimit(
        deps.maximumReplicationRepairs, 1024, 1, 4096)
    local maximumReplicationRepairBytes = boundedLimit(
        deps.maximumReplicationRepairBytes, 8 * 1024 * 1024, 1024, 32 * 1024 * 1024)
    local maximumHandoffTombstonesPerOwner = boundedLimit(
        deps.maximumHandoffTombstonesPerOwner, 512, 1, 512)

    local function validName(owner, name)
        if type(owner) ~= 'string' or not owner:match('^synex_[a-z0-9_]+$')
            or type(name) ~= 'string' or #name > 128
            or name:sub(1, #owner + 1) ~= owner .. '.' then return false end
        local suffix = name:sub(#owner + 2)
        return suffix:match('^[a-z][a-z0-9_%.]*$') ~= nil
            and suffix:sub(-1) ~= '.' and not suffix:find('..', 1, true)
    end

    local function finding(path, rule, message)
        return { path = path, rule = rule, message = message }
    end

    local function encodedStringBytes(value)
        local size = 2
        for index = 1, #value do
            local byte = value:byte(index)
            if byte == 34 or byte == 92 then
                size = size + 2
            elseif byte < 32 then
                size = size + 6
            else
                size = size + 1
            end
        end
        return size
    end

    local function inspectSchemaValue(value, state, depth, path)
        local kind = type(value)
        if kind == 'string' then
            state.bytes = state.bytes + encodedStringBytes(value)
        elseif kind == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then
                return nil, finding(path, 'finite', 'schema numbers must be finite')
            end
            state.bytes = state.bytes + 24
        elseif kind == 'boolean' then
            state.bytes = state.bytes + 5
        elseif kind ~= 'table' then
            return nil, finding(path, 'jsonType', 'schema values must be JSON-compatible')
        end
        if state.bytes > maximumSchemaBytes then
            return nil, finding(path, 'maximumBytes', 'state schema exceeds its byte limit')
        end
        if kind ~= 'table' then return true, nil end
        if getmetatable(value) ~= nil then
            return nil, finding(path, 'metatable', 'state schemas cannot contain metatables')
        end
        if state.active[value] then
            return nil, finding(path, 'cycle', 'state schemas must be acyclic')
        end
        if depth > maximumSchemaDepth then
            return nil, finding(path, 'maxDepth', 'state schema nesting is too deep')
        end
        state.active[value] = true
        state.bytes = state.bytes + 2
        local keyKind, maximumIndex, count = nil, 0, 0
        for key, item in next, value do
            local currentKind = type(key)
            if currentKind == 'string' then
                state.bytes = state.bytes + encodedStringBytes(key) + 2
            elseif currentKind == 'number' and math.type(key) == 'integer' and key >= 1 then
                maximumIndex = math.max(maximumIndex, key)
                state.bytes = state.bytes + 1
            else
                state.active[value] = nil
                return nil, finding(path, 'propertyName', 'schema table keys must be strings or dense array indexes')
            end
            if keyKind and keyKind ~= currentKind then
                state.active[value] = nil
                return nil, finding(path, 'tableShape', 'schema tables cannot mix object and array keys')
            end
            keyKind = currentKind
            count = count + 1
            state.keys = state.keys + 1
            if state.keys > maximumSchemaKeys then
                state.active[value] = nil
                return nil, finding(path, 'maximumKeys', 'state schema contains too many entries')
            end
            local childPath = currentKind == 'string'
                and (path .. '.' .. key) or ('%s[%d]'):format(path, key)
            local ok, schemaFinding = inspectSchemaValue(item, state, depth + 1, childPath)
            if not ok then state.active[value] = nil return nil, schemaFinding end
        end
        state.active[value] = nil
        if keyKind == 'number' and maximumIndex ~= count then
            return nil, finding(path, 'arrayShape', 'schema arrays must be dense')
        end
        if state.bytes > maximumSchemaBytes then
            return nil, finding(path, 'maximumBytes', 'state schema exceeds its byte limit')
        end
        return true, nil
    end

    local function replicationSubject(scope, subject)
        if scope == 'global' then return nil end
        return subject
    end

    local function positiveInteger(value)
        value = tonumber(value)
        if not value or math.type(value) ~= 'integer' or value < 1 or value > 9007199254740991 then
            return nil
        end
        return value
    end

    local function subjectKey(scope, subject)
        if scope == 'global' then return '_global' end
        if scope == 'player' then
            local source = positiveInteger(subject)
            return source and tostring(source) or nil
        end
        if scope == 'entity' and type(subject) == 'number' then
            local entity = positiveInteger(subject)
            return entity and tostring(entity) or nil
        end
        if type(subject) ~= 'string' then return nil end
        local maximum = scope == 'character' and 36 or 64
        if #subject < 1 or #subject > maximum
            or not subject:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then return nil end
        return subject
    end

    local function handoffIdentity(scope, subject, name)
        return ('%d:%s%d:%s%d:%s'):format(
            #scope, scope, #subject, subject, #name, name)
    end

    local function tombstoneJournal(definition)
        local journal = handoffTombstones[definition.owner]
        if not journal or journal.epoch ~= definition.epoch then
            journal = { epoch = definition.epoch, entries = {}, count = 0 }
            handoffTombstones[definition.owner] = journal
        end
        return journal
    end

    local function reserveHandoffTombstone(definition, subject)
        if definition.persistent ~= true or definition.sensitive == true then
            return { tracked = false }, nil
        end
        local journal = tombstoneJournal(definition)
        local key = handoffIdentity(definition.scope, subject, definition.name)
        local existing = journal.entries[key]
        if existing then
            return { tracked = true, added = false, journal = journal, key = key }, nil
        end
        if journal.count >= maximumHandoffTombstonesPerOwner then
            return nil, foundation.error('STATE_HANDOFF_TOMBSTONE_LIMIT',
                'The resource has reached its bounded state handoff tombstone limit.', {
                    retryable = true
                })
        end
        journal.entries[key] = {
            name = definition.name,
            scope = definition.scope,
            subject = subject
        }
        journal.count = journal.count + 1
        return { tracked = true, added = true, journal = journal, key = key }, nil
    end

    local function rollbackHandoffTombstone(reservation)
        if not reservation or reservation.tracked ~= true or reservation.added ~= true then return end
        local journal = reservation.journal
        if journal and journal.entries[reservation.key] then
            journal.entries[reservation.key] = nil
            journal.count = math.max(0, journal.count - 1)
        end
    end

    local function clearHandoffTombstone(definition, subject)
        local journal = handoffTombstones[definition.owner]
        if not journal or journal.epoch ~= definition.epoch then return end
        local key = handoffIdentity(definition.scope, subject, definition.name)
        if journal.entries[key] then
            journal.entries[key] = nil
            journal.count = math.max(0, journal.count - 1)
        end
        if journal.count == 0 then handoffTombstones[definition.owner] = nil end
    end

    local function hasHandoffTombstone(owner, epoch, scope, subject, name)
        local journal = handoffTombstones[owner]
        if not journal or journal.epoch ~= epoch then return false end
        return journal.entries[handoffIdentity(scope, subject, name)] ~= nil
    end

    local function storedValueSize(value, maximumBytes)
        local state = { active = {}, keys = 0, bytes = 0 }
        local function add(bytes)
            state.bytes = state.bytes + bytes
            return state.bytes <= maximumBytes
        end
        local function inspect(candidate, depth)
            local candidateType = type(candidate)
            if candidateType == 'nil' then return add(4) end
            if candidateType == 'boolean' then return add(candidate and 4 or 5) end
            if candidateType == 'number' then
                return candidate == candidate and candidate ~= math.huge
                    and candidate ~= -math.huge and add(32)
            end
            if candidateType == 'string' then return add(encodedStringBytes(candidate)) end
            local containerKind = candidateType == 'table'
                and foundation.jsonContainerKind(candidate) or nil
            if candidateType ~= 'table' or not containerKind
                or depth > maximumSchemaDepth or state.active[candidate] then return false end
            state.active[candidate] = true
            if not add(2) then state.active[candidate] = nil return false end
            local keyType, count, maximumIndex = nil, 0, 0
            for key, child in next, candidate do
                state.keys = state.keys + 1
                count = count + 1
                if state.keys > maximumSchemaKeys or (count > 1 and not add(1)) then
                    state.active[candidate] = nil
                    return false
                end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType == 'string' then
                    if not add(encodedStringBytes(key) + 1) then
                        state.active[candidate] = nil
                        return false
                    end
                else
                    state.active[candidate] = nil
                    return false
                end
                if keyType and keyType ~= currentType then
                    state.active[candidate] = nil
                    return false
                end
                keyType = currentType
                if not inspect(child, depth + 1) then
                    state.active[candidate] = nil
                    return false
                end
            end
            state.active[candidate] = nil
            if keyType == 'number' and maximumIndex ~= count
                or containerKind == 'object' and keyType == 'number'
                or containerKind == 'array' and keyType == 'string' then return false end
            return true
        end
        if not inspect(value, 1) then return nil end
        return state.bytes
    end

    local function storedPlayerGeneration(subject, name)
        local bucket = playerGenerations[subject]
        return bucket and bucket[name] or nil
    end

    local function setStoredPlayerGeneration(subject, name, generation)
        if generation == nil then
            local bucket = playerGenerations[subject]
            if bucket then
                bucket[name] = nil
                if not next(bucket) then playerGenerations[subject] = nil end
            end
            return
        end
        playerGenerations[subject] = playerGenerations[subject] or {}
        playerGenerations[subject][name] = generation
    end

    local function storedMetadata(scope, subject, name)
        local bucket = valueMetadata[scope][subject]
        return bucket and bucket[name] or nil
    end

    local function unlinkReplicationCleanup(entry)
        if type(entry) ~= 'table' or entry.active ~= true then return false end
        if entry.previous then
            entry.previous.next = entry.next
        else
            replicationCleanupHead = entry.next
        end
        if entry.next then
            entry.next.previous = entry.previous
        else
            replicationCleanupTail = entry.previous
        end
        entry.previous, entry.next, entry.active = nil, nil, false
        replicationCleanupCount = math.max(0, replicationCleanupCount - 1)
        return true
    end

    local function rotateReplicationCleanup(entry)
        if type(entry) ~= 'table' or entry.active ~= true
            or replicationCleanupTail == entry then return end
        if entry.previous then
            entry.previous.next = entry.next
        else
            replicationCleanupHead = entry.next
        end
        if entry.next then entry.next.previous = entry.previous end
        entry.previous = replicationCleanupTail
        entry.next = nil
        replicationCleanupTail.next = entry
        replicationCleanupTail = entry
    end

    local function unlinkReplicationRepair(entry)
        if type(entry) ~= 'table' or entry.active ~= true then return false end
        if entry.previous then
            entry.previous.next = entry.next
        else
            replicationRepairHead = entry.next
        end
        if entry.next then
            entry.next.previous = entry.previous
        else
            replicationRepairTail = entry.previous
        end
        if replicationRepairsByKey[entry.key] == entry then
            replicationRepairsByKey[entry.key] = nil
        end
        replicationRepairBytes = math.max(0, replicationRepairBytes - entry.bytes)
        replicationRepairCount = math.max(0, replicationRepairCount - 1)
        entry.previous, entry.next, entry.active = nil, nil, false
        return true
    end

    local function rotateReplicationRepair(entry)
        if type(entry) ~= 'table' or entry.active ~= true
            or replicationRepairTail == entry then return end
        if entry.previous then
            entry.previous.next = entry.next
        else
            replicationRepairHead = entry.next
        end
        if entry.next then entry.next.previous = entry.previous end
        entry.previous = replicationRepairTail
        entry.next = nil
        replicationRepairTail.next = entry
        replicationRepairTail = entry
    end

    local function storageAvailable(owner, scope, subject, name, bytes)
        local previous = storedMetadata(scope, subject, name)
        local addedValues = previous and 0 or 1
        local ownerAddedValues = previous and previous.owner == owner and 0 or 1
        local previousBytes = previous and previous.bytes or 0
        local previousOwnerBytes = previous and previous.owner == owner and previous.bytes or 0
        if valueCount + addedValues > maximumValues
            or (valueCounts[owner] or 0) + ownerAddedValues > maximumValuesPerOwner
            or valueBytes - previousBytes + bytes > maximumValueBytes
            or (valueBytesByOwner[owner] or 0) - previousOwnerBytes + bytes
                > maximumValueBytesPerOwner then
            return nil, foundation.error('STATE_STORAGE_LIMIT',
                'The in-memory state storage limit has been reached.')
        end
        return true, nil
    end

    local function removeStoredAccounting(scope, subject, name)
        local metadataBucket = valueMetadata[scope][subject]
        local metadata = metadataBucket and metadataBucket[name] or nil
        if not metadata then return end
        if metadata.cleanupPending then
            unlinkReplicationCleanup(metadata.cleanupPending)
            metadata.cleanupPending = nil
        end
        metadataBucket[name] = nil
        if not next(metadataBucket) then valueMetadata[scope][subject] = nil end
        valueCount = math.max(0, valueCount - 1)
        valueBytes = math.max(0, valueBytes - metadata.bytes)
        valueCounts[metadata.owner] = math.max(0, (valueCounts[metadata.owner] or 1) - 1)
        valueBytesByOwner[metadata.owner] = math.max(0,
            (valueBytesByOwner[metadata.owner] or metadata.bytes) - metadata.bytes)
        if valueCounts[metadata.owner] == 0 then valueCounts[metadata.owner] = nil end
        if valueBytesByOwner[metadata.owner] == 0 then valueBytesByOwner[metadata.owner] = nil end
    end

    local function storeValue(owner, scope, subject, name, value, bytes, mutationToken)
        local available, availabilityError = storageAvailable(
            owner, scope, subject, name, bytes)
        if not available then return nil, availabilityError end
        local previous = storedMetadata(scope, subject, name)
        removeStoredAccounting(scope, subject, name)
        values[scope][subject] = values[scope][subject] or {}
        values[scope][subject][name] = value
        valueMetadata[scope][subject] = valueMetadata[scope][subject] or {}
        valueMetadata[scope][subject][name] = {
            owner = owner,
            bytes = bytes,
            mutationToken = mutationToken or foundation.nextId('state_write')
        }
        valueCount = valueCount + 1
        valueBytes = valueBytes + bytes
        valueCounts[owner] = (valueCounts[owner] or 0) + 1
        valueBytesByOwner[owner] = (valueBytesByOwner[owner] or 0) + bytes
        return previous, nil
    end

    local function removeStoredValue(scope, subject, name)
        local bucket = values[scope][subject]
        if bucket then
            bucket[name] = nil
            if not next(bucket) then values[scope][subject] = nil end
        end
        removeStoredAccounting(scope, subject, name)
        if scope == 'player' then setStoredPlayerGeneration(subject, name, nil) end
    end

    local function currentPlayerGeneration(subject)
        local source = positiveInteger(subject)
        if not source or type(players) ~= 'table' or type(players.getBySource) ~= 'function' then return nil end
        local session = players:getBySource(source)
        if not session or session.source ~= source then return nil end
        return positiveInteger(session.sourceGeneration)
    end

    local function currentPlayerContext(subject, context)
        local source = positiveInteger(subject)
        if not source or type(context) ~= 'table' or getmetatable(context) ~= nil
            or type(context.sessionId) ~= 'string' or #context.sessionId < 1
            or #context.sessionId > 64 then
            return nil, foundation.error('INVALID_PLAYER_CONTEXT',
                'Player-scoped state access requires a bounded sessionId and sourceGeneration.')
        end
        local generation = positiveInteger(context.sourceGeneration)
        if not generation or type(players) ~= 'table' or type(players.isCurrent) ~= 'function' then
            return nil, foundation.error('INVALID_PLAYER_CONTEXT',
                'Player-scoped state access requires a bounded sessionId and sourceGeneration.')
        end
        local checked, current = foundation.safeCall(
            players.isCurrent, players, context.sessionId, source, generation)
        if not checked or current ~= true then
            return nil, foundation.error('STALE_PLAYER_SESSION',
                'The player source is no longer bound to the expected session generation.', {
                    retryable = true
                })
        end
        return generation, nil
    end

    local function generationCanReplicate(subject, generation)
        local source = positiveInteger(subject)
        generation = positiveInteger(generation)
        if not source or not generation or type(players) ~= 'table'
            or type(players.getBySource) ~= 'function' then return false end
        local current = players:getBySource(source)
        return current ~= nil and current.source == source
            and positiveInteger(current.sourceGeneration) == generation
    end

    local function clearReplication(definition, subject, generation)
        if not definition.replicated then return 'not_replicated', nil end
        if not deps.replicate then
            return 'failed', foundation.error('STATE_REPLICATION_UNAVAILABLE',
                'State replication is unavailable.', { retryable = true })
        end
        if definition.scope == 'player' and not generationCanReplicate(subject, generation) then
            return 'skipped', nil
        end
        local invoked, replicated, replicationError = foundation.safeCall(
            deps.replicate, definition, replicationSubject(definition.scope, subject), {
                name = definition.name,
                scope = definition.scope,
                subject = subject,
                value = nil,
                revision = foundation.nextId('state_rev')
            })
        if invoked and replicated == true then return 'replicated', nil end
        local failure = invoked and replicationError or replicated
        if definition.scope == 'player' and type(failure) == 'table'
            and failure.code == 'PLAYER_NOT_FOUND' then return 'skipped', nil end
        return 'failed', failure
    end

    local function markReplicationCleanup(definition, subject, generation, replicationError)
        local metadata = storedMetadata(definition.scope, subject, definition.name)
        if not metadata then return false end
        local pending = metadata.cleanupPending
        if not pending then
            pending = {
                definition = {
                    name = definition.name,
                    scope = definition.scope,
                    replicated = true
                },
                subject = subject,
                generation = generation,
                metadata = metadata,
                attempts = 0,
                active = true,
                previous = replicationCleanupTail
            }
            if replicationCleanupTail then
                replicationCleanupTail.next = pending
            else
                replicationCleanupHead = pending
            end
            replicationCleanupTail = pending
            replicationCleanupCount = replicationCleanupCount + 1
            metadata.cleanupPending = pending
        end
        pending.attempts = pending.attempts + 1
        pending.lastFailure = foundation.failureCode(
            replicationError, 'STATE_REPLICATION_FAILED')
        return true
    end

    local function captureReplicationCleanup(metadata)
        local pending = metadata and metadata.cleanupPending or nil
        if not pending or pending.active ~= true then return nil end
        return {
            definition = {
                name = pending.definition.name,
                scope = pending.definition.scope,
                replicated = true
            },
            generation = pending.generation,
            attempts = pending.attempts,
            lastFailure = pending.lastFailure
        }
    end

    local function restoreReplicationCleanup(snapshot, subject)
        if not snapshot then return false end
        if not markReplicationCleanup(snapshot.definition, subject,
            snapshot.generation, { code = snapshot.lastFailure }) then return false end
        local metadata = storedMetadata(
            snapshot.definition.scope, subject, snapshot.definition.name)
        local pending = metadata and metadata.cleanupPending or nil
        if not pending then return false end
        pending.attempts = math.max(pending.attempts, snapshot.attempts or 0)
        pending.lastFailure = snapshot.lastFailure or pending.lastFailure
        return true
    end

    local function prepareReplicationCleanupSupersession(definition, subject, metadata)
        local pending = metadata and metadata.cleanupPending or nil
        if not pending or pending.active ~= true or definition.replicated then
            return true, nil
        end
        local status, replicationError = clearReplication(
            pending.definition, subject, pending.generation)
        local current = storedMetadata(definition.scope, subject, definition.name)
        if current ~= metadata or metadata.cleanupPending ~= pending
            or pending.active ~= true then
            return nil, foundation.error('STATE_WRITE_CONFLICT',
                'The pending replicated cleanup changed while state was being superseded.', {
                    retryable = true
                })
        end
        if status == 'failed' then
            pending.attempts = math.min(2147483647, pending.attempts + 1)
            pending.lastFailure = foundation.failureCode(
                replicationError, 'STATE_REPLICATION_FAILED')
            return nil, foundation.error('STATE_REPLICATION_FAILED',
                'Pending replicated state could not be cleared before local supersession.', {
                    retryable = true,
                    details = { cause = pending.lastFailure }
                })
        end
        return true, nil
    end

    local function replicationRepairKey(definition, subject)
        return definition.scope .. '\0' .. tostring(subject) .. '\0' .. definition.name
    end

    local function queueReplicationRepair(definition, subject, generation,
        expectedGeneration, value, expectedMetadata, replicationError)
        local copiedValue = nil
        local bytes = 0
        if value ~= nil then
            local copied, candidate = foundation.safeCall(foundation.copy, value)
            if not copied then
                replicationRepairRejected = replicationRepairRejected + 1
                return false
            end
            copiedValue = candidate
            bytes = storedValueSize(candidate, maximumReplicatedStateBytes)
            if not bytes then
                replicationRepairRejected = replicationRepairRejected + 1
                return false
            end
        end
        local key = replicationRepairKey(definition, subject)
        local entry = replicationRepairsByKey[key]
        local previousBytes = entry and entry.bytes or 0
        if (not entry and replicationRepairCount >= maximumReplicationRepairs)
            or replicationRepairBytes - previousBytes + bytes > maximumReplicationRepairBytes then
            replicationRepairRejected = replicationRepairRejected + 1
            foundation.safeCall(logger.error, logger, 'state replication repair queue is full', {
                state = definition.name,
                scope = definition.scope,
                code = 'STATE_REPLICATION_REPAIR_LIMIT'
            })
            return false
        end
        if not entry then
            entry = {
                key = key,
                active = true,
                attempts = 0,
                previous = replicationRepairTail
            }
            if replicationRepairTail then
                replicationRepairTail.next = entry
            else
                replicationRepairHead = entry
            end
            replicationRepairTail = entry
            replicationRepairsByKey[key] = entry
            replicationRepairCount = replicationRepairCount + 1
        end
        replicationRepairBytes = replicationRepairBytes - previousBytes + bytes
        entry.definition = {
            name = definition.name,
            scope = definition.scope,
            replicated = true
        }
        entry.subject = subject
        entry.generation = generation
        entry.expectedGeneration = expectedGeneration
        entry.hasValue = value ~= nil
        entry.value = copiedValue
        entry.bytes = bytes
        entry.expectsMetadata = expectedMetadata ~= nil
        entry.expectedMutationToken = expectedMetadata and expectedMetadata.mutationToken or nil
        entry.expectedCleanupPending = expectedMetadata ~= nil
            and expectedMetadata.cleanupPending ~= nil
        entry.repairToken = foundation.nextId('state_repair')
        entry.attempts = math.min(2147483647, entry.attempts + 1)
        entry.lastFailure = foundation.failureCode(
            replicationError, 'STATE_REPLICATION_FAILED')
        return true
    end

    local function replicationRepairStillCurrent(entry)
        local metadata = storedMetadata(
            entry.definition.scope, entry.subject, entry.definition.name)
        if entry.expectsMetadata then
            if not metadata or metadata.mutationToken ~= entry.expectedMutationToken
                or (metadata.cleanupPending ~= nil) ~= entry.expectedCleanupPending then
                return false
            end
        elseif metadata ~= nil then
            return false
        end
        local bucket = values[entry.definition.scope][entry.subject]
        local hasValue = bucket ~= nil and bucket[entry.definition.name] ~= nil
        if hasValue ~= entry.expectsMetadata then return false end
        if entry.definition.scope == 'player' and entry.expectsMetadata
            and storedPlayerGeneration(entry.subject, entry.definition.name)
                ~= entry.expectedGeneration then return false end
        return true
    end

    local function removeDefinition(entry)
        if definitions[entry.name] ~= entry then return false end
        definitions[entry.name] = nil
        definitionCount = math.max(0, definitionCount - 1)
        definitionCounts[entry.owner] = math.max(0,
            (definitionCounts[entry.owner] or 1) - 1)
        if definitionCounts[entry.owner] == 0 then definitionCounts[entry.owner] = nil end
        return true
    end

    local service = {}
    function service:define(owner, epoch, definition)
        if type(definition) ~= 'table' or getmetatable(definition) ~= nil then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State definitions must be plain objects.')
        end
        for field in next, definition do
            if type(field) ~= 'string' or not definitionFields[field] then
                return nil, foundation.error('INVALID_STATE_DEFINITION',
                    'State definitions cannot contain unknown fields.', {
                        details = { path = '$.' .. tostring(field), rule = 'additionalProperties' }
                    })
            end
        end
        if not validName(owner, definition.name) then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State names must be namespaced to the owning resource.')
        end
        local allowedScopes = { global = true, player = true, entity = true, character = true }
        local allowedAuthorities = { server = true, owner = true }
        if not allowedScopes[definition.scope] or not allowedAuthorities[definition.authority] then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State scope or authority is invalid.')
        end
        if definition['$schema'] ~= nil and type(definition['$schema']) ~= 'string' then
            return nil, foundation.error('INVALID_STATE_DEFINITION', '$schema must be a string when provided.')
        end
        for _, field in ipairs({ 'sensitive', 'replicated', 'persistent' }) do
            if definition[field] ~= nil and type(definition[field]) ~= 'boolean' then
                return nil, foundation.error('INVALID_STATE_DEFINITION', field .. ' must be a boolean when provided.')
            end
        end
        if definition.maximumBytes ~= nil and (type(definition.maximumBytes) ~= 'number'
            or math.type(definition.maximumBytes) ~= 'integer' or definition.maximumBytes < 1
            or definition.maximumBytes > maximumReplicatedStateBytes) then
            return nil, foundation.error('INVALID_STATE_DEFINITION',
                ('maximumBytes must be an integer between 1 and %d.'):format(maximumReplicatedStateBytes))
        end
        if type(definition.schema) ~= 'table' then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'A state schema is required.')
        end
        local schemaState = { active = {}, keys = 0, bytes = 0 }
        local inspected, schemaFinding = inspectSchemaValue(definition.schema, schemaState, 1, '$.schema')
        if inspected then
            inspected, schemaFinding = contracts.validateSchemaDefinition(definition.schema, {
                maximumDepth = maximumSchemaDepth,
                maximumKeys = maximumSchemaKeys,
                maximumStringBytes = maximumSchemaBytes
            })
            if not inspected and type(schemaFinding) == 'table' and type(schemaFinding.path) == 'string' then
                schemaFinding.path = '$.schema' .. schemaFinding.path:sub(2)
            end
        end
        if not inspected then
            return nil, foundation.error('INVALID_STATE_DEFINITION', 'State schema is malformed or exceeds its limits.', {
                details = schemaFinding
            })
        end
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
        if definitions[definition.name] then return nil, foundation.error('STATE_EXISTS', 'The state definition already exists.') end
        if definitionCount >= maximumDefinitions
            or (definitionCounts[owner] or 0) >= maximumDefinitionsPerOwner then
            return nil, foundation.error('STATE_DEFINITION_LIMIT',
                'The state definition registry limit has been reached.')
        end
        local token = foundation.nextId('state')
        local entry = foundation.copy(definition)
        entry.owner, entry.epoch, entry.token = owner, epoch, token
        entry.maximumBytes = entry.maximumBytes or 4096
        local stateName = entry.name
        definitions[stateName] = entry
        definitionCount = definitionCount + 1
        definitionCounts[owner] = (definitionCounts[owner] or 0) + 1
        local _, trackError = owners:track(owner, epoch, 'state_definition', token, function()
            removeDefinition(entry)
            for scope, scoped in pairs(values) do
                for subject, subjectValues in pairs(scoped) do
                    if type(subjectValues) == 'table' and subjectValues[stateName] ~= nil then
                        local expectedMetadata = storedMetadata(scope, subject, stateName)
                        local expectedMutationToken = expectedMetadata
                            and expectedMetadata.mutationToken or nil
                        local generation = scope == 'player'
                            and storedPlayerGeneration(subject, stateName) or nil
                        local cleanupFailed = false
                        if entry.replicated and (scope == 'global' or scope == 'player') then
                            local status, replicationError = clearReplication(entry, subject, generation)
                            local currentMetadata = storedMetadata(scope, subject, stateName)
                            local stillCurrent = currentMetadata == expectedMetadata
                                and currentMetadata ~= nil
                                and currentMetadata.mutationToken == expectedMutationToken
                                and (scope ~= 'player'
                                    or storedPlayerGeneration(subject, stateName) == generation)
                            if not stillCurrent then
                                cleanupFailed = true
                            elseif status == 'failed' then
                                cleanupFailed = true
                                markReplicationCleanup(entry, subject, generation, replicationError)
                                foundation.safeCall(logger.error, logger, 'state owner cleanup replication failed', {
                                    state = stateName,
                                    scope = scope,
                                    code = foundation.failureCode(
                                        replicationError, 'STATE_REPLICATION_FAILED')
                                })
                            end
                        end
                        local currentMetadata = storedMetadata(scope, subject, stateName)
                        if not cleanupFailed and currentMetadata == expectedMetadata
                            and currentMetadata ~= nil
                            and currentMetadata.mutationToken == expectedMutationToken
                            and (scope ~= 'player'
                                or storedPlayerGeneration(subject, stateName) == generation) then
                            removeStoredValue(scope, subject, stateName)
                        end
                    end
                end
            end
            local journal = handoffTombstones[entry.owner]
            if definitionCounts[entry.owner] == nil
                and journal and journal.epoch == entry.epoch then
                handoffTombstones[entry.owner] = nil
            end
        end)
        if trackError then removeDefinition(entry) return nil, trackError end
        return token, nil
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

    function service:get(caller, epoch, name, subject, context)
        local definition = definitions[name]
        if not definition then return nil, foundation.error('STATE_NOT_FOUND', 'The state definition does not exist.') end
        local authorized, authorizationError = authorize(caller, epoch, definition, 'read')
        if not authorized then return nil, authorizationError end
        local key = subjectKey(definition.scope, subject)
        if not key then return nil, foundation.error('INVALID_STATE_SUBJECT', 'A state subject is required.') end
        local expectedGeneration = nil
        if definition.scope == 'player' then
            local contextError
            expectedGeneration, contextError = currentPlayerContext(key, context)
            if not expectedGeneration then return nil, contextError end
        end
        local bucket = values[definition.scope][key]
        local metadata = storedMetadata(definition.scope, key, name)
        if not bucket or bucket[name] == nil or (metadata and metadata.cleanupPending) then
            return nil, nil
        end
        if definition.scope == 'player'
            and storedPlayerGeneration(key, name) ~= expectedGeneration then return nil, nil end
        return foundation.copy(bucket[name]), nil
    end

    function service:clear(caller, epoch, name, subject, context)
        local definition = definitions[name]
        if not definition then
            return nil, foundation.error('STATE_NOT_FOUND',
                'The state definition does not exist.')
        end
        if not owners:isCurrent(definition.owner, definition.epoch) then
            return nil, foundation.error('STATE_OWNER_UNAVAILABLE',
                'The state owner restarted.')
        end
        local authorized, authorizationError = authorize(caller, epoch, definition, 'write')
        if not authorized then return nil, authorizationError end
        if definition.authority == 'owner' and caller ~= definition.owner then
            return nil, foundation.error('STATE_AUTHORITY_DENIED',
                'Only the state owner may clear this value.')
        end
        local key = subjectKey(definition.scope, subject)
        if not key then
            return nil, foundation.error('INVALID_STATE_SUBJECT',
                'A state subject is required.')
        end
        local expectedGeneration = nil
        if definition.scope == 'player' then
            local contextError
            expectedGeneration, contextError = currentPlayerContext(key, context)
            if not expectedGeneration then return nil, contextError end
        end
        local tombstone, tombstoneError = reserveHandoffTombstone(definition, key)
        if not tombstone then return nil, tombstoneError end
        local bucket = values[definition.scope][key]
        if not bucket or bucket[name] == nil
            or (definition.scope == 'player'
                and storedPlayerGeneration(key, name) ~= expectedGeneration) then
            return {
                name = name, scope = definition.scope, subject = key,
                cleared = false, revision = foundation.nextId('state_rev')
            }, nil
        end
        if definition.replicated then
            local clearMetadata = storedMetadata(definition.scope, key, name)
            local generation = definition.scope == 'player'
                and storedPlayerGeneration(key, name) or nil
            local status, replicationError = clearReplication(definition, key, generation)
            if status == 'failed' then
                rollbackHandoffTombstone(tombstone)
                return nil, foundation.error('STATE_REPLICATION_FAILED',
                    'State cleanup replication failed.', {
                        retryable = true,
                        details = {
                            cause = foundation.failureCode(
                                replicationError, 'STATE_REPLICATION_FAILED')
                        }
                    })
            end
            if storedMetadata(definition.scope, key, name) ~= clearMetadata then
                rollbackHandoffTombstone(tombstone)
                return nil, foundation.error('STATE_WRITE_CONFLICT',
                    'The state value changed while it was being cleared.', {
                        retryable = true
                    })
            end
        end
        if definition.scope == 'player' then
            local currentGeneration, contextError = currentPlayerContext(key, context)
            if not currentGeneration or currentGeneration ~= expectedGeneration
                or storedPlayerGeneration(key, name) ~= expectedGeneration then
                rollbackHandoffTombstone(tombstone)
                return nil, contextError or foundation.error('STALE_PLAYER_SESSION',
                    'The player session changed while state was being cleared.', {
                        retryable = true
                    })
            end
        end
        removeStoredValue(definition.scope, key, name)
        return {
            name = name, scope = definition.scope, subject = key,
            cleared = true, revision = foundation.nextId('state_rev')
        }, nil
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
        if value == nil then
            return nil, foundation.error('VALIDATION_FAILED',
                'State values cannot be nil; owner cleanup removes stored values.')
        end
        local validationCalled, valid, valueFinding = foundation.safeCall(contracts.validate, definition.schema, value)
        if not validationCalled or not valid then
            return nil, foundation.error('VALIDATION_FAILED', 'State value does not match its schema.', {
                details = validationCalled and valueFinding
                    or finding('$', 'runtimeSafety', 'state value validation could not be completed safely')
            })
        end
        local maximumBytes = math.min(definition.maximumBytes or 4096, maximumReplicatedStateBytes)
        local inspectedBytes = storedValueSize(value, maximumBytes)
        if not inspectedBytes then
            return nil, foundation.error('STATE_PAYLOAD_TOO_LARGE',
                'State value is not bounded plain JSON data or exceeds its byte limit.')
        end
        local copied, storedValue = foundation.safeCall(foundation.copy, value)
        if not copied then
            return nil, foundation.error('VALIDATION_FAILED', 'State value cannot be stored safely.', {
                details = finding('$', 'runtimeSafety', 'state value exceeds the supported copy depth')
            })
        end
        local generation = nil
        if definition.scope == 'player' then
            local contextError
            generation, contextError = currentPlayerContext(key, context)
            if not generation then
                return nil, contextError
            end
        end
        if definition.replicated then
            local encodedOk, encoded = pcall(deps.platform.jsonEncode, storedValue)
            if not encodedOk or type(encoded) ~= 'string' then
                return nil, foundation.error('STATE_ENCODING_FAILED', 'Replicated state could not be encoded.')
            end
            if #encoded > maximumBytes then
                return nil, foundation.error('STATE_PAYLOAD_TOO_LARGE', 'Replicated state exceeds its byte limit.')
            end
            if not deps.replicate then
                return nil, foundation.error('STATE_REPLICATION_UNAVAILABLE',
                    'State replication is unavailable.', { retryable = true })
            end
        end
        local scoped = values[definition.scope]
        local bucket = scoped[key]
        local oldValue = nil
        if bucket then oldValue = bucket[name] end
        local oldMetadata = storedMetadata(definition.scope, key, name)
        local oldCleanup = captureReplicationCleanup(oldMetadata)
        local oldGeneration = definition.scope == 'player' and storedPlayerGeneration(key, name) or nil
        local supersessionReady, supersessionError = prepareReplicationCleanupSupersession(
            definition, key, oldMetadata)
        if not supersessionReady then return nil, supersessionError end
        if definitions[name] ~= definition
            or not owners:isCurrent(definition.owner, definition.epoch) then
            return nil, foundation.error('STATE_WRITE_CONFLICT',
                'The state definition changed while pending replication was being cleared.', {
                    retryable = true
                })
        end
        if definition.scope == 'player' then
            local currentGeneration, contextError = currentPlayerContext(key, context)
            if not currentGeneration or currentGeneration ~= generation then
                return nil, contextError or foundation.error('STALE_PLAYER_SESSION',
                    'The player session changed while pending replication was being cleared.', {
                        retryable = true
                    })
            end
        end
        local mutationToken = foundation.nextId('state_write')
        local accountingBytes = oldMetadata
            and math.max(oldMetadata.bytes, inspectedBytes) or inspectedBytes
        local _, storageError = storeValue(
            definition.owner, definition.scope, key, name, storedValue, accountingBytes,
            mutationToken)
        if storageError then return nil, storageError end
        if definition.scope == 'player' then setStoredPlayerGeneration(key, name, generation) end
        local function rollback()
            local currentMetadata = storedMetadata(definition.scope, key, name)
            if not currentMetadata or currentMetadata.mutationToken ~= mutationToken then
                return false
            end
            removeStoredValue(definition.scope, key, name)
            if oldValue ~= nil and oldMetadata then
                storeValue(oldMetadata.owner, definition.scope, key, name,
                    oldValue, oldMetadata.bytes, oldMetadata.mutationToken)
                restoreReplicationCleanup(oldCleanup, key)
                if definition.scope == 'player' then
                    setStoredPlayerGeneration(key, name, oldGeneration)
                end
            end
            return true
        end
        local snapshot = {
            name = name, scope = definition.scope, subject = key,
            value = foundation.copy(storedValue), revision = foundation.nextId('state_rev')
        }
        if definition.replicated then
            if definition.scope == 'player' then
                local currentGeneration, contextError = currentPlayerContext(key, context)
                if not currentGeneration or currentGeneration ~= generation then
                    rollback()
                    return nil, contextError or foundation.error('STALE_PLAYER_SESSION',
                        'The player session changed before state replication.', {
                            retryable = true
                        })
                end
            end
            local ok, replicated, replicationError = foundation.safeCall(
                deps.replicate, definition, replicationSubject(definition.scope, key), snapshot)
            if not ok or replicated ~= true then
                rollback()
                logger:error('state replication failed', { state = name, scope = definition.scope,
                    code = foundation.failureCode(
                        ok and replicationError or replicated, 'STATE_REPLICATION_FAILED') })
                return nil, foundation.error('STATE_REPLICATION_FAILED',
                    'State replication failed.', { retryable = true })
            end
            local currentMetadata = storedMetadata(definition.scope, key, name)
            if definition.scope == 'player' then
                local currentGeneration, contextError = currentPlayerContext(key, context)
                if not currentGeneration or currentGeneration ~= generation
                    or storedPlayerGeneration(key, name) ~= generation then
                    rollback()
                    return nil, contextError or foundation.error('STALE_PLAYER_SESSION',
                        'The player session changed during state replication.', {
                            retryable = true
                        })
                end
            end
            if not currentMetadata or currentMetadata.mutationToken ~= mutationToken then
                rollback()
                return nil, foundation.error('STATE_WRITE_CONFLICT',
                    'The state value changed during replication.', {
                        retryable = true
                    })
            end
        end
        if accountingBytes ~= inspectedBytes then
            local currentMetadata = storedMetadata(definition.scope, key, name)
            if not currentMetadata or currentMetadata.mutationToken ~= mutationToken then
                rollback()
                return nil, foundation.error('STATE_WRITE_CONFLICT',
                    'The state value changed before storage accounting was finalized.', {
                        retryable = true
                    })
            end
            local _, finalizeError = storeValue(
                definition.owner, definition.scope, key, name, storedValue, inspectedBytes,
                mutationToken)
            if finalizeError then
                rollback()
                return nil, foundation.error('STATE_STORAGE_LIMIT',
                    'State value accounting could not be finalized safely.')
            end
            if definition.scope == 'player' then setStoredPlayerGeneration(key, name, generation) end
        end
        clearHandoffTombstone(definition, key)
        return snapshot, nil
    end

    function service:purgePlayer(source, generation)
        source = positiveInteger(source)
        generation = positiveInteger(generation)
        if not source or not generation then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Player state cleanup requires a valid source and source generation.')
        end
        local key = tostring(source)
        local bucket = values.player[key]
        local report = {
            source = source,
            generation = generation,
            cleared = 0,
            replicated = 0,
            skipped = 0,
            superseded = 0,
            failures = {}
        }
        if not bucket then return report, nil end
        local names = {}
        for name in pairs(bucket) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            if storedPlayerGeneration(key, name) == generation then
                local expectedMetadata = storedMetadata('player', key, name)
                local expectedMutationToken = expectedMetadata
                    and expectedMetadata.mutationToken or nil
                local definition = definitions[name]
                local status, replicationError = 'not_replicated', nil
                if definition and definition.scope == 'player' and definition.replicated then
                    status, replicationError = clearReplication(definition, key, generation)
                end
                local currentMetadata = storedMetadata('player', key, name)
                local stillCurrent = currentMetadata == expectedMetadata
                    and currentMetadata ~= nil
                    and currentMetadata.mutationToken == expectedMutationToken
                    and storedPlayerGeneration(key, name) == generation
                if not stillCurrent then
                    report.superseded = report.superseded + 1
                elseif status == 'replicated' then
                    report.replicated = report.replicated + 1
                    removeStoredValue('player', key, name)
                    report.cleared = report.cleared + 1
                elseif status == 'skipped' then
                    report.skipped = report.skipped + 1
                    removeStoredValue('player', key, name)
                    report.cleared = report.cleared + 1
                elseif status == 'failed' then
                    markReplicationCleanup(definition, key, generation, replicationError)
                    local failure = type(replicationError) == 'table' and replicationError
                        or foundation.error('STATE_REPLICATION_FAILED',
                            'Player state cleanup replication failed.')
                    report.failures[#report.failures + 1] = {
                        state = name,
                        code = failure.code or 'STATE_REPLICATION_FAILED'
                    }
                else
                    removeStoredValue('player', key, name)
                    report.cleared = report.cleared + 1
                end
            end
        end
        return report, nil
    end

    function service:retryReplicationCleanup(maximum)
        maximum = maximum or 64
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 256 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'State replication cleanup batches must contain between 1 and 256 entries.')
        end
        local report = {
            inspected = 0,
            cleared = 0,
            repaired = 0,
            superseded = 0,
            failures = {},
            remaining = replicationCleanupCount + replicationRepairCount,
            cleanupRemaining = replicationCleanupCount,
            repairRemaining = replicationRepairCount
        }
        local cleanupBudget = replicationCleanupCount
        local repairBudget = replicationRepairCount
        local preferRepair = retryRepairFirst
        retryRepairFirst = not retryRepairFirst
        while report.inspected < maximum
            and (cleanupBudget > 0 or repairBudget > 0) do
            local inspectRepair = repairBudget > 0
                and (cleanupBudget == 0 or preferRepair)
            preferRepair = not preferRepair
            report.inspected = report.inspected + 1
            if inspectRepair then
                repairBudget = repairBudget - 1
                local pending = replicationRepairHead
                if pending then
                    local repairToken = pending.repairToken
                    local current = replicationRepairStillCurrent(pending)
                    local generationCurrent = pending.definition.scope ~= 'player'
                        or generationCanReplicate(pending.subject, pending.generation)
                    if not current or not generationCurrent then
                        report.superseded = report.superseded + 1
                        unlinkReplicationRepair(pending)
                    else
                        local repairValue = nil
                        if pending.hasValue then
                            repairValue = foundation.copy(pending.value)
                        end
                        local invoked, replicated, replicationError = foundation.safeCall(
                            deps.replicate, pending.definition,
                            replicationSubject(pending.definition.scope, pending.subject), {
                                name = pending.definition.name,
                                scope = pending.definition.scope,
                                subject = pending.subject,
                                value = repairValue,
                                revision = foundation.nextId('state_rev')
                            })
                        current = pending.active == true
                            and replicationRepairStillCurrent(pending)
                        generationCurrent = pending.definition.scope ~= 'player'
                            or generationCanReplicate(pending.subject, pending.generation)
                        if pending.active == true
                            and pending.repairToken ~= repairToken then
                            report.superseded = report.superseded + 1
                            rotateReplicationRepair(pending)
                        elseif not current or not generationCurrent then
                            report.superseded = report.superseded + 1
                            if pending.active == true then unlinkReplicationRepair(pending) end
                        elseif not invoked or replicated ~= true then
                            local failure = invoked and replicationError or replicated
                            pending.attempts = math.min(2147483647, pending.attempts + 1)
                            pending.lastFailure = foundation.failureCode(
                                failure, 'STATE_REPLICATION_FAILED')
                            report.failures[#report.failures + 1] = {
                                state = pending.definition.name,
                                scope = pending.definition.scope,
                                operation = 'repair',
                                code = pending.lastFailure
                            }
                            rotateReplicationRepair(pending)
                        else
                            unlinkReplicationRepair(pending)
                            report.repaired = report.repaired + 1
                        end
                    end
                end
            else
                cleanupBudget = cleanupBudget - 1
                local pending = replicationCleanupHead
                if pending then
                    local status, replicationError = clearReplication(
                        pending.definition, pending.subject, pending.generation)
                    local current = storedMetadata(
                        pending.definition.scope, pending.subject, pending.definition.name)
                    if pending.active ~= true or current ~= pending.metadata
                        or current.mutationToken ~= pending.metadata.mutationToken then
                        report.superseded = report.superseded + 1
                        if pending.active == true then unlinkReplicationCleanup(pending) end
                    elseif status == 'failed' then
                        pending.attempts = math.min(2147483647, pending.attempts + 1)
                        pending.lastFailure = foundation.failureCode(
                            replicationError, 'STATE_REPLICATION_FAILED')
                        report.failures[#report.failures + 1] = {
                            state = pending.definition.name,
                            scope = pending.definition.scope,
                            operation = 'cleanup',
                            code = pending.lastFailure
                        }
                        rotateReplicationCleanup(pending)
                    else
                        removeStoredValue(
                            pending.definition.scope, pending.subject, pending.definition.name)
                        report.cleared = report.cleared + 1
                    end
                end
            end
        end
        report.cleanupRemaining = replicationCleanupCount
        report.repairRemaining = replicationRepairCount
        report.remaining = replicationCleanupCount + replicationRepairCount
        return report, nil
    end

    function service:purgeSubject(scope, subject)
        if scope ~= 'entity' and scope ~= 'character' then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Subject cleanup supports only entity and character state scopes.')
        end
        local key = subjectKey(scope, subject)
        if not key then
            return nil, foundation.error('INVALID_STATE_SUBJECT',
                'State subject cleanup requires a valid bounded subject.')
        end
        local bucket = values[scope][key]
        local report = { scope = scope, subject = key, cleared = 0 }
        if not bucket then return report, nil end
        local names = {}
        for name in pairs(bucket) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            removeStoredValue(scope, key, name)
            report.cleared = report.cleared + 1
        end
        return report, nil
    end

    function service:purgeAllPlayers()
        local targets = {}
        for subject, bucket in pairs(playerGenerations) do
            local source = positiveInteger(subject)
            if source and type(bucket) == 'table' then
                for _, generation in pairs(bucket) do
                    generation = positiveInteger(generation)
                    if generation then targets[tostring(source) .. ':' .. tostring(generation)] = {
                        source = source, generation = generation
                    } end
                end
            end
        end
        local ordered = {}
        for _, target in pairs(targets) do ordered[#ordered + 1] = target end
        table.sort(ordered, function(left, right)
            if left.source == right.source then return left.generation < right.generation end
            return left.source < right.source
        end)
        local report = {
            players = #ordered,
            cleared = 0,
            replicated = 0,
            skipped = 0,
            superseded = 0,
            failures = {}
        }
        for _, target in ipairs(ordered) do
            local playerReport, purgeError = self:purgePlayer(target.source, target.generation)
            if not playerReport then
                report.failures[#report.failures + 1] = {
                    source = target.source,
                    generation = target.generation,
                    code = purgeError and purgeError.code or 'PLAYER_STATE_PURGE_FAILED'
                }
            else
                report.cleared = report.cleared + playerReport.cleared
                report.replicated = report.replicated + playerReport.replicated
                report.skipped = report.skipped + playerReport.skipped
                report.superseded = report.superseded + (playerReport.superseded or 0)
                for _, failure in ipairs(playerReport.failures) do
                    report.failures[#report.failures + 1] = failure
                end
            end
        end
        return report, nil
    end

    local function snapshotError(code, message, details)
        return foundation.error(code, message, { details = details })
    end

    local function snapshotLimits(options)
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, snapshotError('INVALID_ARGUMENT', 'Snapshot limits must be a plain object.')
        end
        for key in next, options do
            if key ~= 'maximumBytes' and key ~= 'maximumValues' then
                return nil, snapshotError('INVALID_ARGUMENT', 'Snapshot limits contain an unknown property.')
            end
        end
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
        local excludedStalePlayers = 0
        for name, definition in pairs(definitions) do
            if definition.owner == owner and definition.epoch == epoch and definition.persistent == true then
                if definition.sensitive == true then
                    excludedSensitive = excludedSensitive + 1
                else
                    for subject, bucket in pairs(values[definition.scope]) do
                        local value = nil
                        if type(bucket) == 'table' then value = bucket[name] end
                        local metadata = storedMetadata(definition.scope, subject, name)
                        if value ~= nil and not (metadata and metadata.cleanupPending) then
                            local sourceGeneration = nil
                            local include = true
                            if definition.scope == 'player' then
                                sourceGeneration = storedPlayerGeneration(subject, name)
                                include = sourceGeneration ~= nil
                                    and sourceGeneration == currentPlayerGeneration(subject)
                                if not include then excludedStalePlayers = excludedStalePlayers + 1 end
                            end
                            local valid, finding = contracts.validate(definition.schema, value)
                            local size = valid and encodedSize(value) or nil
                            if not valid or not size then
                                return nil, snapshotError('SNAPSHOT_VALUE_INVALID', 'A reconstructable state value cannot be snapshotted.', {
                                    name = name, subject = tostring(subject), finding = finding
                                })
                            end
                            if include and #entries >= limits.maximumValues then
                                return nil, snapshotError('SNAPSHOT_TOO_LARGE', 'The snapshot contains too many state values.')
                            end
                            if include then
                                local snapshotValue = {
                                    name = name,
                                    scope = definition.scope,
                                    subject = tostring(subject),
                                    value = foundation.copy(value)
                                }
                                if definition.scope == 'player' then
                                    snapshotValue.sourceGeneration = sourceGeneration
                                end
                                entries[#entries + 1] = snapshotValue
                            end
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
        local tombstones = {}
        local journal = handoffTombstones[owner]
        if journal and journal.epoch == epoch then
            for _, entry in pairs(journal.entries) do
                tombstones[#tombstones + 1] = foundation.copy(entry)
            end
            table.sort(tombstones, function(left, right)
                if left.name ~= right.name then return left.name < right.name end
                if left.scope ~= right.scope then return left.scope < right.scope end
                return left.subject < right.subject
            end)
            handoffTombstones[owner] = nil
        end
        capturedHandoffTombstones[snapshot] = {
            owner = owner,
            epoch = epoch,
            entries = tombstones
        }
        return snapshot, nil, {
            bytes = size,
            values = #entries,
            excludedSensitive = excludedSensitive,
            excludedStalePlayers = excludedStalePlayers
        }
    end

    function service:consumeOwnerCaptureTombstones(owner, epoch, snapshot)
        local captured = type(snapshot) == 'table'
            and capturedHandoffTombstones[snapshot] or nil
        if not captured or captured.owner ~= owner or captured.epoch ~= epoch then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT',
                'State handoff tombstones are unavailable for this capture.')
        end
        capturedHandoffTombstones[snapshot] = nil
        return foundation.copy(captured.entries), nil
    end

    local function exactKeys(value, required)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then return false end
        local allowed = {}
        for _, key in ipairs(required) do
            allowed[key] = true
            if rawget(value, key) == nil then return false end
        end
        for key in next, value do if type(key) ~= 'string' or not allowed[key] then return false end end
        return true
    end

    local function rollbackRestore(applied)
        for index = #applied, 1, -1 do
            local item = applied[index]
            local currentMetadata = storedMetadata(
                item.definition.scope, item.subject, item.name)
            local rollbackCurrent = currentMetadata ~= nil
                and currentMetadata.mutationToken == item.mutationToken
                and (item.definition.scope ~= 'player'
                    or storedPlayerGeneration(item.subject, item.name) == item.sourceGeneration)
            if rollbackCurrent then
                removeStoredValue(item.definition.scope, item.subject, item.name)
                if item.hadValue and item.oldMetadata then
                    storeValue(item.oldMetadata.owner, item.definition.scope,
                        item.subject, item.name, item.oldValue, item.oldMetadata.bytes,
                        item.oldMetadata.mutationToken)
                    restoreReplicationCleanup(item.oldCleanup, item.subject)
                    if item.definition.scope == 'player' then
                        setStoredPlayerGeneration(item.subject, item.name, item.oldGeneration)
                    end
                end
            end
            local replicationCurrent = item.definition.scope ~= 'player'
                or generationCanReplicate(item.subject, item.sourceGeneration)
            if rollbackCurrent and replicationCurrent and item.definition.replicated and deps.replicate then
                local rollbackValue = nil
                local oldValueBelongsToTarget = item.definition.scope ~= 'player'
                    or item.oldGeneration == item.sourceGeneration
                if item.hadValue and not item.oldCleanup and oldValueBelongsToTarget then
                    rollbackValue = foundation.copy(item.oldValue)
                end
                local invoked, replicated, replicationError = foundation.safeCall(
                    deps.replicate, item.definition,
                    replicationSubject(item.definition.scope, item.subject), {
                        name = item.name,
                        scope = item.definition.scope,
                        subject = item.subject,
                        value = rollbackValue,
                        revision = foundation.nextId('state_rev')
                    })
                if not invoked or replicated ~= true then
                    local expectedMetadata = storedMetadata(
                        item.definition.scope, item.subject, item.name)
                    queueReplicationRepair(item.definition, item.subject,
                        item.sourceGeneration,
                        item.definition.scope == 'player'
                            and storedPlayerGeneration(item.subject, item.name) or nil,
                        rollbackValue, expectedMetadata,
                        invoked and replicationError or replicated)
                end
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
        if getmetatable(snapshot.values) ~= nil then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot values must be a plain dense array.')
        end
        local snapshotValueCount = 0
        for key in next, snapshot.values do
            snapshotValueCount = snapshotValueCount + 1
            if snapshotValueCount > limits.maximumValues
                or type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > #snapshot.values then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot values must be a dense array.')
            end
        end
        if snapshotValueCount ~= #snapshot.values then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT', 'Snapshot values are sparse or exceed their limit.')
        end

        local candidates = {}
        local seen = {}
        local estimatedSnapshotBytes = encodedSize({
            schemaVersion = snapshot.schemaVersion,
            owner = snapshot.owner,
            ownerEpoch = snapshot.ownerEpoch,
            capturedAt = snapshot.capturedAt,
            values = {}
        })
        if not estimatedSnapshotBytes then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT',
                'Snapshot envelope could not be encoded safely.')
        end
        local tombstoned = 0
        for index, item in ipairs(snapshot.values) do
            local requiredKeys = type(item) == 'table' and item.scope == 'player'
                and { 'name', 'scope', 'subject', 'value', 'sourceGeneration' }
                or { 'name', 'scope', 'subject', 'value' }
            if not exactKeys(item, requiredKeys)
                or type(item.name) ~= 'string' or #item.name > 128
                or type(item.scope) ~= 'string'
                or type(item.subject) ~= 'string' or #item.subject < 1 or #item.subject > 128
                or (item.scope == 'player' and positiveInteger(item.sourceGeneration) == nil) then
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
            if hasHandoffTombstone(
                owner, epoch, item.scope, item.subject, item.name) then
                tombstoned = tombstoned + 1
                goto continue_snapshot_value
            end
            do
            local validationCalled, valid, valueFinding = foundation.safeCall(
                contracts.validate, definition.schema, item.value)
            local valueLimit = math.min(
                definition.maximumBytes or 4096, maximumReplicatedStateBytes)
            local valueSize = validationCalled and valid
                and storedValueSize(item.value, valueLimit) or nil
            if not validationCalled or not valid or not valueSize then
                return nil, snapshotError('SNAPSHOT_VALUE_INVALID', 'Snapshot state value does not match its current schema.', {
                    index = index,
                    name = item.name,
                    finding = validationCalled and valueFinding
                        or finding('$', 'runtimeSafety', 'snapshot value validation could not be completed safely')
                })
            end
            local itemSize = encodedSize(item)
            if not itemSize then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT',
                    'Snapshot state entry could not be encoded safely.', { index = index })
            end
            estimatedSnapshotBytes = estimatedSnapshotBytes + itemSize
                + (index > 1 and 1 or 0)
            if estimatedSnapshotBytes > limits.maximumBytes then
                return nil, snapshotError('INVALID_STATE_SNAPSHOT',
                    'Snapshot values exceed the configured byte limit.')
            end
            if definition.replicated then
                if not deps.replicate then
                    return nil, snapshotError('STATE_REPLICATION_UNAVAILABLE', 'Replicated snapshot state cannot be restored.')
                end
                local encodedValueSize = encodedSize(item.value)
                if not encodedValueSize or encodedValueSize > valueLimit then
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
            local oldGeneration = definition.scope == 'player'
                and storedPlayerGeneration(item.subject, item.name) or nil
            local oldMetadata = storedMetadata(definition.scope, item.subject, item.name)
            local oldCleanup = captureReplicationCleanup(oldMetadata)
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
                oldValue = oldValue,
                oldGeneration = oldGeneration,
                oldMetadata = oldMetadata,
                oldCleanup = oldCleanup,
                valueBytes = valueSize,
                accountingBytes = oldMetadata
                    and math.max(oldMetadata.bytes, valueSize) or valueSize,
                sourceGeneration = definition.scope == 'player'
                    and positiveInteger(item.sourceGeneration) or nil
            }
            end
            ::continue_snapshot_value::
        end
        local size = encodedSize(snapshot)
        if not size or size > limits.maximumBytes then
            return nil, snapshotError('INVALID_STATE_SNAPSHOT',
                'Snapshot encoding is invalid or exceeds its byte limit.')
        end

        local applied = {}
        local skipped = tombstoned
        for _, candidate in ipairs(candidates) do
            local definition, item = candidate.definition, candidate.item
            local generationCurrent = definition.scope ~= 'player'
                or candidate.sourceGeneration == currentPlayerGeneration(item.subject)
            if not generationCurrent then
                skipped = skipped + 1
            else
                local currentMetadata = storedMetadata(
                    definition.scope, item.subject, item.name)
                local expectedMutationToken = candidate.oldMetadata
                    and candidate.oldMetadata.mutationToken or nil
                if (currentMetadata and currentMetadata.mutationToken or nil)
                    ~= expectedMutationToken then
                    rollbackRestore(applied)
                    return nil, snapshotError('STATE_WRITE_CONFLICT',
                        'State changed before snapshot restoration could be applied.')
                end
                local supersessionReady, supersessionError =
                    prepareReplicationCleanupSupersession(
                        definition, item.subject, currentMetadata)
                if not supersessionReady then
                    rollbackRestore(applied)
                    return nil, supersessionError
                end
                if definitions[item.name] ~= definition
                    or not owners:isCurrent(definition.owner, definition.epoch) then
                    rollbackRestore(applied)
                    return nil, snapshotError('STATE_WRITE_CONFLICT',
                        'The state definition changed while pending replication was being cleared.')
                end
                local mutationToken = foundation.nextId('state_restore')
                local _, storageError = storeValue(definition.owner, definition.scope,
                    item.subject, item.name, candidate.value, candidate.accountingBytes,
                    mutationToken)
                if storageError then
                    rollbackRestore(applied)
                    return nil, storageError
                end
                if definition.scope == 'player' then
                    setStoredPlayerGeneration(item.subject, item.name, candidate.sourceGeneration)
                end
                applied[#applied + 1] = {
                    definition = definition,
                    name = item.name,
                    subject = item.subject,
                    hadValue = candidate.hadValue,
                    oldValue = candidate.oldValue,
                    oldGeneration = candidate.oldGeneration,
                    oldMetadata = candidate.oldMetadata,
                    oldCleanup = candidate.oldCleanup,
                    value = candidate.value,
                    valueBytes = candidate.valueBytes,
                    accountingBytes = candidate.accountingBytes,
                    sourceGeneration = candidate.sourceGeneration,
                    mutationToken = mutationToken
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
                            code = foundation.failureCode(
                                ok and replicationError or replicated, 'STATE_REPLICATION_FAILED')
                        })
                        return nil, snapshotError('STATE_REPLICATION_FAILED', 'Snapshot state replication failed.')
                    end
                    local replicatedMetadata = storedMetadata(
                        definition.scope, item.subject, item.name)
                    if not replicatedMetadata
                        or replicatedMetadata.mutationToken ~= mutationToken then
                        rollbackRestore(applied)
                        return nil, snapshotError('STATE_WRITE_CONFLICT',
                            'State changed while snapshot restoration was being replicated.')
                    end
                end
            end
        end
        for _, item in ipairs(applied) do
            local currentMetadata = storedMetadata(
                item.definition.scope, item.subject, item.name)
            if not currentMetadata
                or currentMetadata.mutationToken ~= item.mutationToken then
                rollbackRestore(applied)
                return nil, snapshotError('STATE_WRITE_CONFLICT',
                    'State changed before snapshot restoration was finalized.')
            end
            if item.accountingBytes ~= item.valueBytes then
                local _, finalizeError = storeValue(item.definition.owner,
                    item.definition.scope, item.subject, item.name,
                    item.value, item.valueBytes, item.mutationToken)
                if finalizeError then
                    rollbackRestore(applied)
                    return nil, snapshotError('SNAPSHOT_RESTORE_FAILED',
                        'Snapshot state accounting could not be finalized safely.')
                end
                if item.definition.scope == 'player' then
                    setStoredPlayerGeneration(item.subject, item.name, item.sourceGeneration)
                end
            end
        end
        restoredEpochs[owner] = epoch
        return {
            schemaVersion = 1,
            owner = owner,
            fromEpoch = snapshot.ownerEpoch,
            toEpoch = epoch,
            restored = #applied,
            skipped = skipped
        }, nil
    end

    function service:snapshot()
        local summary = {
            definitions = {},
            counts = {},
            storage = {
                definitions = definitionCount,
                values = valueCount,
                bytes = valueBytes,
                replicationCleanupPending = replicationCleanupCount,
                replicationRepairPending = replicationRepairCount,
                replicationRepairBytes = replicationRepairBytes,
                replicationRepairRejected = replicationRepairRejected,
                limits = {
                    definitions = maximumDefinitions,
                    definitionsPerOwner = maximumDefinitionsPerOwner,
                    values = maximumValues,
                    valuesPerOwner = maximumValuesPerOwner,
                    bytes = maximumValueBytes,
                    bytesPerOwner = maximumValueBytesPerOwner,
                    replicationRepairs = maximumReplicationRepairs,
                    replicationRepairBytes = maximumReplicationRepairBytes
                }
            }
        }
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
