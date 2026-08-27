local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.reliability = function(deps)
    local foundation = assert(deps.foundation, 'reliability requires foundation')
    local database = assert(deps.database, 'reliability requires database')
    local platform = assert(deps.platform, 'reliability requires platform')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local workerId = deps.instanceId .. ':outbox'
    local features = deps.features or {}
    local diagnosticBatchMaximum = type(deps.diagnosticBatchMaximum) == 'number'
        and math.type(deps.diagnosticBatchMaximum) == 'integer'
        and math.max(1, math.min(deps.diagnosticBatchMaximum, 1000)) or 250
    local idempotencyCapacityHighWatermarks = {
        global = 0, owner = 0, namespace = 0
    }

    local function requireFeature(enabled, name)
        if enabled ~= false then return true, nil end
        return nil, foundation.error('FEATURE_DISABLED', ('The %s feature is disabled by configuration.'):format(name))
    end

    local function validResourceOwner(owner)
        return type(owner) == 'string' and #owner <= 64
            and owner:match('^synex_[a-z0-9_]+$') ~= nil
    end

    local function validJsonValue(value, maximumBytes)
        local active, keys, bytes = {}, 0, 0
        local function spend(amount)
            bytes = bytes + amount
            return bytes <= maximumBytes
        end
        local function stringBytes(value)
            local encoded = 2
            for index = 1, #value do
                local byte = value:byte(index)
                if byte == 34 or byte == 92 then encoded = encoded + 2
                elseif byte < 32 then encoded = encoded + 6
                else encoded = encoded + 1 end
                if bytes + encoded > maximumBytes then return nil end
            end
            return encoded
        end
        local function inspect(candidate, depth)
            local candidateType = type(candidate)
            if candidateType == 'nil' then return spend(4) and true or nil, 'size' end
            if candidateType == 'boolean' then
                return spend(candidate and 4 or 5) and true or nil, 'size'
            end
            if candidateType == 'string' then
                if #candidate > 16384 then return nil, 'invalid' end
                local encoded = stringBytes(candidate)
                return encoded and spend(encoded) and true or nil, 'size'
            end
            if candidateType == 'number' then
                if candidate ~= candidate or candidate == math.huge or candidate == -math.huge then
                    return nil, 'invalid'
                end
                return spend(#tostring(candidate)) and true or nil, 'size'
            end
            local containerKind = candidateType == 'table'
                and foundation.jsonContainerKind(candidate) or nil
            if candidateType ~= 'table' or not containerKind
                or depth > 12 or active[candidate] then return nil, 'invalid' end
            active[candidate] = true
            local keyType, count, maximumIndex = nil, 0, 0
            if not spend(2) then active[candidate] = nil return nil, 'size' end
            for key, child in next, candidate do
                keys = keys + 1
                if keys > 512 then active[candidate] = nil return nil, 'invalid' end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType == 'string' and #key <= 16384 then
                    local encoded = stringBytes(key)
                    if not encoded or not spend(encoded + 1) then
                        active[candidate] = nil
                        return nil, 'size'
                    end
                else
                    active[candidate] = nil
                    return nil, 'invalid'
                end
                if keyType and keyType ~= currentType then
                    active[candidate] = nil
                    return nil, 'invalid'
                end
                keyType = currentType
                count = count + 1
                if count > 1 and not spend(1) then active[candidate] = nil return nil, 'size' end
                local inspected, inspectError = inspect(child, depth + 1)
                if not inspected then active[candidate] = nil return nil, inspectError end
            end
            active[candidate] = nil
            if keyType == 'number' and maximumIndex ~= count
                or containerKind == 'object' and keyType == 'number'
                or containerKind == 'array' and keyType == 'string' then
                return nil, 'invalid'
            end
            return true, nil
        end
        return inspect(value, 1)
    end

    local function boundedJson(value, maximumBytes)
        local valid, validationError = validJsonValue(value, maximumBytes)
        if not valid then
            if validationError == 'size' then
                return nil, foundation.error('PAYLOAD_TOO_LARGE',
                    'The encoded value exceeds its byte limit.')
            end
            return nil, foundation.error('INVALID_JSON_VALUE',
                'The value must be bounded plain JSON data.')
        end
        local ok, encoded = pcall(platform.jsonEncode, value)
        if not ok or type(encoded) ~= 'string' then
            return nil, foundation.error('JSON_ENCODING_FAILED', 'The value cannot be encoded as JSON.')
        end
        if #encoded > maximumBytes then return nil, foundation.error('PAYLOAD_TOO_LARGE', 'The encoded value exceeds its byte limit.') end
        return encoded, nil
    end

    local function affectedRows(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end

    local function capacityInteger(value, minimum)
        local parsed = tonumber(value)
        if not parsed or math.type(parsed) ~= 'integer'
            or parsed < minimum or parsed > 4294967295 then return nil end
        return parsed
    end

    local idempotency = {}
    function idempotency:run(owner, operation, key, request, handler, options)
        options = options or {}
        if type(options) ~= 'table' or getmetatable(options) ~= nil then
            return nil, foundation.error('INVALID_IDEMPOTENCY_OPTIONS',
                'Idempotency options must be a plain object.')
        end
        local allowedOptions = {
            lockSeconds = true, ttlSeconds = true,
            maximumRequestBytes = true, maximumResponseBytes = true
        }
        for option in pairs(options) do
            if type(option) ~= 'string' or not allowedOptions[option] then
                return nil, foundation.error('INVALID_IDEMPOTENCY_OPTIONS',
                    'Idempotency options contain an unknown property.')
            end
        end
        local lockSeconds = options.lockSeconds == nil and 30 or options.lockSeconds
        local ttlSeconds = options.ttlSeconds == nil and 86400 or options.ttlSeconds
        local maximumRequestBytes = options.maximumRequestBytes == nil
            and 32768 or options.maximumRequestBytes
        local maximumResponseBytes = options.maximumResponseBytes == nil
            and 65536 or options.maximumResponseBytes
        if type(lockSeconds) ~= 'number' or math.type(lockSeconds) ~= 'integer'
            or lockSeconds < 5 or lockSeconds > 300
            or type(ttlSeconds) ~= 'number' or math.type(ttlSeconds) ~= 'integer'
            or ttlSeconds < lockSeconds or ttlSeconds > 604800
            or type(maximumRequestBytes) ~= 'number' or math.type(maximumRequestBytes) ~= 'integer'
            or maximumRequestBytes < 1 or maximumRequestBytes > 65536
            or type(maximumResponseBytes) ~= 'number' or math.type(maximumResponseBytes) ~= 'integer'
            or maximumResponseBytes < 1 or maximumResponseBytes > 65536 then
            return nil, foundation.error('INVALID_IDEMPOTENCY_OPTIONS',
                'Idempotency option values are outside their supported bounds.')
        end
        if not validResourceOwner(owner)
            or type(operation) ~= 'string' or #operation < 1 or #operation > 64
            or not operation:match('^[a-z][a-z0-9_.%-]*$')
            or operation:match('[._%-]$') or operation:match('[._%-][._%-]')
            or type(key) ~= 'string' or #key < 8 or #key > 36
            or not key:match('^[A-Za-z0-9_.:%-]+$') or not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_IDEMPOTENCY_INPUT', 'Operation, key, and handler are invalid.')
        end
        local namespace = owner .. ':' .. operation
        if #namespace > 96 then return nil, foundation.error('INVALID_IDEMPOTENCY_INPUT', 'Idempotency namespace is too long.') end
        local requestJson, encodeError = boundedJson(request, maximumRequestBytes)
        if not requestJson then return nil, encodeError end
        local requestHash = deps.sha256(requestJson)
        local ownerToken = foundation.nextId('idem')
        local ownsClaim, claimRecord, claimError, capacitySnapshot = false, nil, nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            ownsClaim, claimRecord, claimError, capacitySnapshot = false, nil, nil, nil
            local globalRows = query([[SELECT `entry_count`, `global_limit`, `owner_limit`,
                    `namespace_limit`
                FROM `synex_idempotency_capacity`
                WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
            local global = globalRows[1]
            local globalCount = global and capacityInteger(global.entry_count, 0) or nil
            local globalLimit = global and capacityInteger(global.global_limit, 1) or nil
            local ownerLimit = global and capacityInteger(global.owner_limit, 1) or nil
            local namespaceLimit = global and capacityInteger(global.namespace_limit, 1) or nil
            if #globalRows ~= 1 or not globalCount or not globalLimit or not ownerLimit
                or not namespaceLimit or namespaceLimit > ownerLimit
                or ownerLimit > globalLimit then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency capacity authority is missing or invalid.')
                return false
            end

            local ownerInserted = query([[INSERT IGNORE INTO `synex_idempotency_owner_capacity`
                (`owner_resource`, `entry_count`) VALUES (?, 0)]], { owner })
            local ownerCreated = affectedRows(ownerInserted)
            if ownerCreated ~= 0 and ownerCreated ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency owner counter could not be initialized safely.')
                return false
            end
            local ownerRows = query([[SELECT `entry_count`
                FROM `synex_idempotency_owner_capacity`
                WHERE `owner_resource` = ? FOR UPDATE]], { owner }) or {}
            local ownerCount = ownerRows[1] and capacityInteger(ownerRows[1].entry_count, 0) or nil
            if #ownerRows ~= 1 or not ownerCount then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency owner counter is missing or invalid.')
                return false
            end

            local namespaceInserted = query([[INSERT IGNORE INTO `synex_idempotency_namespace_capacity`
                (`namespace`, `owner_resource`, `entry_count`) VALUES (?, ?, 0)]],
                { namespace, owner })
            local namespaceCreated = affectedRows(namespaceInserted)
            if namespaceCreated ~= 0 and namespaceCreated ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency namespace counter could not be initialized safely.')
                return false
            end
            local namespaceRows = query([[SELECT `owner_resource`, `entry_count`
                FROM `synex_idempotency_namespace_capacity`
                WHERE `namespace` = ? FOR UPDATE]], { namespace }) or {}
            local namespaceCounter = namespaceRows[1]
            local namespaceCount = namespaceCounter
                and capacityInteger(namespaceCounter.entry_count, 0) or nil
            if #namespaceRows ~= 1 or not namespaceCount
                or namespaceCounter.owner_resource ~= owner
                or globalCount < ownerCount or ownerCount < namespaceCount then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency counters are structurally inconsistent.')
                return false
            end

            local records = query([[SELECT `request_hash`, `state`, `response_json`,
                    (`locked_until` < CURRENT_TIMESTAMP(6)) AS `lock_expired`,
                    (`expires_at` < CURRENT_TIMESTAMP(6)) AS `record_expired`
                FROM `synex_idempotency_keys`
                WHERE `namespace` = ? AND `idempotency_key` = ?
                LIMIT 1 FOR UPDATE]], { namespace, key }) or {}
            if #records > 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency key lookup returned an invalid result.')
                return false
            end
            claimRecord = records[1]
            capacitySnapshot = {
                global = globalCount, owner = ownerCount, namespace = namespaceCount,
                globalLimit = globalLimit, ownerLimit = ownerLimit,
                namespaceLimit = namespaceLimit
            }
            if claimRecord then
                if ownerCreated ~= 0 or namespaceCreated ~= 0
                    or globalCount < 1 or ownerCount < 1 or namespaceCount < 1 then
                    claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'An existing idempotency key is not represented by every persistent counter.')
                    return false
                end
                return true
            end
            if (ownerCreated == 1 and ownerCount ~= 0)
                or (ownerCreated == 0 and ownerCount < 1)
                or (namespaceCreated == 1 and namespaceCount ~= 0)
                or (namespaceCreated == 0 and namespaceCount < 1)
                or (ownerCreated == 1 and namespaceCreated == 0) then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent idempotency counters do not match the absent key.')
                return false
            end

            local deniedScope = globalCount >= globalLimit and 'global'
                or ownerCount >= ownerLimit and 'owner'
                or namespaceCount >= namespaceLimit and 'namespace' or nil
            if deniedScope then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_EXCEEDED',
                    'Persistent idempotency capacity is exhausted for this scope.', {
                        details = { scope = deniedScope }
                    })
                return false
            end

            local globalUpdated = query([[UPDATE `synex_idempotency_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `singleton_id` = 1 AND `entry_count` = ?
                    AND `entry_count` < `global_limit` AND `entry_count` < 4294967295]],
                { globalCount })
            if affectedRows(globalUpdated) ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent global idempotency counter changed unexpectedly.')
                return false
            end
            local ownerUpdated = query([[UPDATE `synex_idempotency_owner_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `owner_resource` = ? AND `entry_count` = ?
                    AND `entry_count` < 4294967295]], { owner, ownerCount })
            if affectedRows(ownerUpdated) ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent owner idempotency counter changed unexpectedly.')
                return false
            end
            local namespaceUpdated = query([[UPDATE `synex_idempotency_namespace_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `namespace` = ? AND `owner_resource` = ? AND `entry_count` = ?
                    AND `entry_count` < 4294967295]], { namespace, owner, namespaceCount })
            if affectedRows(namespaceUpdated) ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The persistent namespace idempotency counter changed unexpectedly.')
                return false
            end
            local inserted = query([[INSERT INTO `synex_idempotency_keys`
                (`namespace`, `idempotency_key`, `request_hash`, `state`, `response_json`,
                    `owner_token`, `locked_until`, `expires_at`)
                VALUES (?, ?, ?, 'pending', NULL, ?,
                    TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                    TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
                { namespace, key, requestHash, ownerToken, lockSeconds, ttlSeconds })
            if affectedRows(inserted) ~= 1 then
                claimError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'The idempotency key insert did not produce exactly one durable claim.')
                return false
            end
            ownsClaim = true
            capacitySnapshot.global = globalCount + 1
            capacitySnapshot.owner = ownerCount + 1
            capacitySnapshot.namespace = namespaceCount + 1
            return true
        end)
        if capacitySnapshot then
            for _, scope in ipairs({ 'global', 'owner', 'namespace' }) do
                metrics:gauge('synex_idempotency_capacity_entries', { scope = scope },
                    capacitySnapshot[scope])
                local limit = capacitySnapshot[scope .. 'Limit']
                metrics:gauge('synex_idempotency_capacity_limit', { scope = scope }, limit)
                local utilization = capacitySnapshot[scope] / limit
                metrics:gauge('synex_idempotency_capacity_utilization', { scope = scope },
                    utilization)
                idempotencyCapacityHighWatermarks[scope] = math.max(
                    idempotencyCapacityHighWatermarks[scope], utilization)
                metrics:gauge('synex_idempotency_capacity_utilization_high_watermark',
                    { scope = scope }, idempotencyCapacityHighWatermarks[scope])
            end
        end
        if not committed then
            if claimError and claimError.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED' then
                metrics:increment('synex_idempotency_capacity_denials_total', {
                    scope = claimError.details.scope
                })
            elseif claimError and claimError.code == 'IDEMPOTENCY_CAPACITY_INVALID' then
                metrics:increment('synex_idempotency_capacity_denials_total', {
                    scope = 'integrity'
                })
            end
            return nil, claimError or transactionError
        end
        if not ownsClaim then
            local record = claimRecord
            if not record then return nil, foundation.error('IDEMPOTENCY_RACE', 'The idempotency claim disappeared.', { retryable = true }) end
            if record.request_hash ~= requestHash then return nil, foundation.error('IDEMPOTENCY_CONFLICT', 'The idempotency key was used with a different request.') end
            if record.state == 'completed' then
                if tonumber(record.record_expired) == 1 then
                    return nil, foundation.error('IDEMPOTENCY_EXPIRED',
                        'The durable idempotency tombstone has expired and cannot replay its response.')
                end
                local ok, response = pcall(platform.jsonDecode, record.response_json or 'null')
                if not ok then return nil, foundation.error('IDEMPOTENCY_RESPONSE_CORRUPT', 'The stored idempotent response is invalid.') end
                metrics:increment('synex_idempotency_total', { result = 'replay' })
                return foundation.copy(response), nil, { replayed = true }
            end
            if record.state == 'failed' then
                return nil, foundation.error('IDEMPOTENCY_FAILED',
                    'The previous execution reached a terminal failure and cannot be replayed safely.')
            end
            if record.state ~= 'pending' then
                return nil, foundation.error('IDEMPOTENCY_STATE_INVALID',
                    'The stored idempotency state is invalid.')
            end
            if tonumber(record.lock_expired) ~= 1 and tonumber(record.record_expired) ~= 1 then
                return nil, foundation.error('IDEMPOTENCY_IN_PROGRESS', 'The idempotent operation is already in progress.', { retryable = true })
            end
            return nil, foundation.error('IDEMPOTENCY_INDETERMINATE',
                'The previous execution expired without a durable result and requires reconciliation.')
        end

        local ok, value, operationError = foundation.safeCall(handler)
        if not ok or operationError then
            local terminal, cleanupError = database:update([[UPDATE `synex_idempotency_keys` SET `state` = 'failed', `locked_until` = CURRENT_TIMESTAMP(6)
                WHERE `namespace` = ? AND `idempotency_key` = ? AND `owner_token` = ?
                    AND `state` = 'pending']],
                { namespace, key, ownerToken })
            local terminalCount = affectedRows(terminal)
            if cleanupError or terminalCount ~= 1 then
                logger:error('idempotency failure state cleanup failed', {
                    owner = owner,
                    operation = operation,
                    code = cleanupError and cleanupError.code or 'IDEMPOTENCY_CLAIM_LOST'
                })
                metrics:increment('synex_idempotency_total', { result = 'indeterminate' })
                return nil, foundation.error('IDEMPOTENCY_INDETERMINATE',
                    'The failed operation could not be fenced to a durable terminal state.')
            end
            metrics:increment('synex_idempotency_total', { result = 'failed' })
            if type(operationError) == 'table' then return nil, operationError end
            logger:error('idempotent handler failed', { owner = owner, operation = operation })
            return nil, foundation.error('IDEMPOTENCY_INDETERMINATE',
                'The idempotent execution failed without a safely replayable result.')
        end
        local responseJson, responseError = boundedJson(value, maximumResponseBytes)
        if not responseJson then
            local terminal, terminalError = database:update([[UPDATE `synex_idempotency_keys`
                SET `state` = 'failed', `locked_until` = CURRENT_TIMESTAMP(6)
                WHERE `namespace` = ? AND `idempotency_key` = ? AND `owner_token` = ?
                    AND `state` = 'pending']], { namespace, key, ownerToken })
            if terminalError or affectedRows(terminal) ~= 1 then
                logger:error('idempotency response failure state cleanup failed', {
                    owner = owner, operation = operation,
                    code = terminalError and terminalError.code or 'IDEMPOTENCY_CLAIM_LOST'
                })
            end
            metrics:increment('synex_idempotency_total', { result = 'indeterminate' })
            return nil, foundation.error('IDEMPOTENCY_INDETERMINATE',
                'The operation ran, but its response could not be persisted safely.', {
                    details = { cause = responseError.code }
                })
        end
        local completed, completeError = database:update([[UPDATE `synex_idempotency_keys`
            SET `state` = 'completed', `response_json` = ?, `completed_at` = CURRENT_TIMESTAMP(6),
                `locked_until` = CURRENT_TIMESTAMP(6), `response_compaction_at` = NULL
            WHERE `namespace` = ? AND `idempotency_key` = ? AND `owner_token` = ? AND `state` = 'pending']],
            { responseJson, namespace, key, ownerToken })
        if completeError or affectedRows(completed) ~= 1 then
            metrics:increment('synex_idempotency_total', { result = 'indeterminate' })
            return nil, foundation.error('IDEMPOTENCY_INDETERMINATE',
                'The operation ran, but its durable idempotency result is unknown.')
        end
        metrics:increment('synex_idempotency_total', { result = 'completed' })
        return foundation.copy(value), nil, { replayed = false }
    end

    function idempotency:compactExpired(maximum)
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 1000 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Idempotency compaction requires a batch size between 1 and 1000.')
        end
        local compacted, compactError = database:update([[UPDATE `synex_idempotency_keys`
            FORCE INDEX (`idx_idempotency_response_compaction`)
            SET `response_json` = NULL, `response_compaction_at` = CURRENT_TIMESTAMP(6)
            WHERE `state` = 'completed' AND `response_compaction_at` IS NULL
                AND `expires_at` < CURRENT_TIMESTAMP(6)
            ORDER BY `response_compaction_at` ASC, `expires_at` ASC,
                `namespace` ASC, `idempotency_key` ASC
            LIMIT ?]], { maximum })
        if compactError then return nil, compactError end
        local count = affectedRows(compacted)
        if count == nil or count < 0 or count > maximum
            or math.type(count) ~= 'integer' then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Idempotency compaction returned an invalid affected-row count.')
        end
        metrics:increment('synex_idempotency_compaction_total', { result = 'completed' }, count)
        return { compacted = count }, nil
    end

    local function validEventTopic(topic)
        if type(topic) ~= 'string' or #topic < 3 or #topic > 96
            or topic:find('[%z\1-\31\127]') or topic:find('*', 1, true)
            or topic:sub(-1) == '.' or topic:find('..', 1, true)
            or not topic:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') then return false end
        for segment in topic:gmatch('[^.]+') do
            if not segment:match('^[a-z][a-z0-9_]*$') then return false end
        end
        return true
    end

    local outbox = {}
    local outboxCompactionTurn = 1
    local outboxStates = { pending = true, publishing = true, published = true, dead = true }
    local function boundedDiagnosticInteger(value)
        if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
        local canonical = tostring(value)
        if not canonical:match('^%d+$') or #canonical > 16 then return nil end
        local numeric = tonumber(canonical)
        if not numeric or math.type(numeric) ~= 'integer'
            or numeric < 0 or numeric > 9007199254740991 then return nil end
        return numeric
    end
    function outbox:enqueue(owner, event)
        local enabled, featureError = requireFeature(features.durableEvents, 'durable events')
        if not enabled then return nil, featureError end
        if not validResourceOwner(owner) or type(event) ~= 'table' or getmetatable(event) ~= nil then
            return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event identity is invalid.')
        end
        local allowed = {
            aggregateType = true, aggregateId = true, eventType = true, schemaVersion = true,
            payload = true, headers = true, eventId = true
        }
        for key in pairs(event) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error('INVALID_OUTBOX_EVENT',
                    'Outbox event contains an unknown property.')
            end
        end
        if type(event.aggregateType) ~= 'string' or #event.aggregateType < 1 or #event.aggregateType > 64
            or not event.aggregateType:match('^[a-z][a-z0-9_.%-]*$')
            or event.aggregateType:find('[%z\1-\31\127]')
            or type(event.aggregateId) ~= 'string' or #event.aggregateId < 1 or #event.aggregateId > 128
            or event.aggregateId:find('[%z\1-\31\127]') or not validEventTopic(event.eventType)
            or (event.eventId ~= nil and (type(event.eventId) ~= 'string' or #event.eventId < 8
                or #event.eventId > 36 or not event.eventId:match('^[A-Za-z0-9_.:%-]+$')))
            or (event.schemaVersion ~= nil and (type(event.schemaVersion) ~= 'number'
                or math.type(event.schemaVersion) ~= 'integer'
                or event.schemaVersion < 1 or event.schemaVersion > 65535)) then
            return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event identity is invalid.')
        end
        local payload, payloadError = boundedJson(event.payload or {}, 65536)
        if not payload then return nil, payloadError end
        local headers, headersError = boundedJson(event.headers or {}, 8192)
        if not headers then return nil, headersError end
        local eventId = event.eventId or foundation.nextId('event')
        local inserted, insertError = database:insert([[INSERT INTO `synex_outbox`
            (`event_id`, `producer_resource`, `aggregate_type`, `aggregate_id`, `event_type`, `schema_version`,
                `payload_json`, `headers_json`, `state`, `attempts`, `available_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, CURRENT_TIMESTAMP(6))]], {
            eventId, owner, event.aggregateType, event.aggregateId, event.eventType,
            math.max(1, math.min(tonumber(event.schemaVersion) or 1, 65535)), payload, headers
        })
        if insertError then return nil, insertError end
        return { id = inserted, eventId = eventId }, nil
    end

    function outbox:snapshot(options)
        if features.durableEvents == false then
            return {
                status = 'DISABLED', enabled = false,
                states = {
                    pending = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
                    publishing = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
                    published = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
                    dead = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 }
                },
                total = 0, backlog = 0, retried = 0, oldestBacklogAgeMs = 0,
                items = {}, nextCursor = nil, hasMore = false, truncated = false,
                payloadsExposed = false, headersExposed = false
            }, nil
        end
        options = options or {}
        if type(options) ~= 'table' then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Outbox diagnostics require a bounded options object.')
        end
        for key in pairs(options) do
            if key ~= 'cursor' and key ~= 'limit' then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Outbox diagnostics contain an unknown option.')
            end
        end
        local cursor = options.cursor
        local limit = options.limit or 25
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 50 then
            return nil, foundation.error('INVALID_LIMIT',
                'Outbox diagnostics limit must be an integer from 1 through 50.')
        end
        if cursor ~= nil and (type(cursor) ~= 'string' or #cursor < 1
            or #cursor > 20 or not cursor:match('^[1-9]%d*$')) then
            return nil, foundation.error('INVALID_CURSOR',
                'Outbox diagnostics cursor is invalid.')
        end
        local totals, totalsError = database:query([[SELECT `state`,
                CAST(COUNT(*) AS CHAR) AS `total`,
                CAST(COALESCE(SUM(`attempts` > 0), 0) AS CHAR) AS `retried`,
                CAST(COALESCE(SUM(`attempts`), 0) AS CHAR) AS `attempts`,
                CAST(COALESCE(MAX(`attempts`), 0) AS CHAR) AS `maximum_attempts`,
                CAST(COALESCE(MAX(GREATEST(0,
                    TIMESTAMPDIFF(MICROSECOND, `created_at`, CURRENT_TIMESTAMP(6)) DIV 1000)), 0)
                    AS CHAR) AS `oldest_age_ms`
            FROM `synex_outbox` GROUP BY `state` ORDER BY `state` ASC]], {})
        if totalsError then return nil, totalsError end
        totals = totals or {}
        if #totals > 4 then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Outbox diagnostics returned more states than the schema permits.', {
                    retryable = true
                })
        end
        local states = {
            pending = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
            publishing = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
            published = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 },
            dead = { total = 0, retried = 0, attempts = 0, maximumAttempts = 0, oldestAgeMs = 0 }
        }
        local observedStates = {}
        for _, row in ipairs(totals) do
            local state = row.state
            local total = boundedDiagnosticInteger(row.total)
            local retried = boundedDiagnosticInteger(row.retried)
            local attempts = boundedDiagnosticInteger(row.attempts)
            local maximumAttempts = boundedDiagnosticInteger(row.maximum_attempts)
            local oldestAgeMs = boundedDiagnosticInteger(row.oldest_age_ms)
            if not outboxStates[state] or observedStates[state] or total == nil
                or retried == nil or attempts == nil or maximumAttempts == nil
                or oldestAgeMs == nil or retried > total then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Outbox diagnostics returned an invalid state aggregate.', {
                        retryable = true
                    })
            end
            observedStates[state] = true
            states[state] = {
                total = total,
                retried = retried,
                attempts = attempts,
                maximumAttempts = maximumAttempts,
                oldestAgeMs = oldestAgeMs
            }
        end
        local cursorClause = ''
        local parameters = {}
        if cursor ~= nil then
            cursorClause = ' WHERE `id` < CAST(? AS UNSIGNED)'
            parameters[#parameters + 1] = cursor
        end
        parameters[#parameters + 1] = limit + 1
        local rows, readError = database:query([[SELECT CAST(`id` AS CHAR) AS `cursor_id`,
                `event_id`, `producer_resource`, `aggregate_type`, `event_type`, `schema_version`,
                `state`, `attempts`, `last_error_code`,
                DATE_FORMAT(`available_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `available_at`,
                DATE_FORMAT(`locked_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `locked_until`,
                DATE_FORMAT(`published_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `published_at`,
                DATE_FORMAT(`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
                DATE_FORMAT(`payload_compacted_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `payload_compacted_at`,
                CAST(GREATEST(0, TIMESTAMPDIFF(MICROSECOND, `created_at`,
                    CURRENT_TIMESTAMP(6)) DIV 1000) AS CHAR) AS `age_ms`
            FROM `synex_outbox`]] .. cursorClause .. [[ ORDER BY `id` DESC LIMIT ?]], parameters)
        if readError then return nil, readError end
        rows = rows or {}
        if #rows > limit + 1 then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Outbox diagnostics exceeded the bounded page.', { retryable = true })
        end
        local hasMore = #rows > limit
        local items = {}
        for index = 1, math.min(#rows, limit) do
            local row = rows[index]
            local cursorId = type(row.cursor_id) == 'string' and row.cursor_id or nil
            local attempts = boundedDiagnosticInteger(row.attempts)
            local ageMs = boundedDiagnosticInteger(row.age_ms)
            if not cursorId or not cursorId:match('^[1-9]%d*$')
                or not outboxStates[row.state] or attempts == nil or ageMs == nil then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Outbox diagnostics returned an invalid row.', { retryable = true })
            end
            items[index] = {
                cursor = cursorId,
                eventId = row.event_id,
                producerResource = row.producer_resource,
                aggregateType = row.aggregate_type,
                eventType = row.event_type,
                schemaVersion = tonumber(row.schema_version),
                state = row.state,
                attempts = attempts,
                lastErrorCode = row.last_error_code,
                availableAt = row.available_at,
                lockedUntil = row.locked_until,
                publishedAt = row.published_at,
                createdAt = row.created_at,
                payloadCompactedAt = row.payload_compacted_at,
                ageMs = ageMs
            }
        end
        local total = states.pending.total + states.publishing.total
            + states.published.total + states.dead.total
        local backlog = states.pending.total + states.publishing.total + states.dead.total
        local retried = states.pending.retried + states.publishing.retried
            + states.published.retried + states.dead.retried
        return {
            status = 'AVAILABLE',
            enabled = true,
            health = states.dead.total > 0 and 'ERROR'
                or states.pending.maximumAttempts > 1 and 'WARNING' or 'HEALTHY',
            states = states,
            total = total,
            backlog = backlog,
            retried = retried,
            oldestBacklogAgeMs = math.max(states.pending.oldestAgeMs,
                states.publishing.oldestAgeMs, states.dead.oldestAgeMs),
            items = items,
            nextCursor = hasMore and items[#items] and items[#items].cursor or nil,
            hasMore = hasMore,
            truncated = hasMore,
            payloadsExposed = false,
            headersExposed = false
        }, nil
    end

    function outbox:dispatchBatch(handler, maximum)
        local enabled, featureError = requireFeature(features.durableEvents, 'durable events')
        if not enabled then return nil, featureError end
        if type(handler) ~= 'function' then return nil, foundation.error('INVALID_ARGUMENT', 'An outbox dispatch handler is required.') end
        maximum = math.max(1, math.min(tonumber(maximum) or 25, 100))
        local reset, resetError = database:update([[UPDATE `synex_outbox`
            SET `state` = 'pending', `locked_by` = NULL, `locked_until` = NULL
            WHERE `state` = 'publishing' AND `locked_until` < CURRENT_TIMESTAMP(6)
            ORDER BY `locked_until` ASC, `id` ASC LIMIT ?]], { maximum })
        if resetError then return nil, resetError end
        local resetCount = affectedRows(reset)
        if not resetCount or math.type(resetCount) ~= 'integer'
            or resetCount < 0 or resetCount > maximum then
            return nil, foundation.error('OUTBOX_RECOVERY_INVALID',
                'The outbox recovery result exceeded its bounded batch.', {
                    retryable = true
                })
        end
        local claimToken = workerId .. ':' .. foundation.nextId('claim')
        local _, claimError = database:update([[UPDATE `synex_outbox`
            SET `state` = 'publishing', `locked_by` = ?, `locked_until` = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
                `attempts` = `attempts` + 1
            WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `id` ASC LIMIT ?]], { claimToken, maximum })
        if claimError then return nil, claimError end
        local rows, readError = database:query([[SELECT `id`, `event_id`, `producer_resource`, `aggregate_type`, `aggregate_id`, `event_type`,
            `schema_version`, `payload_json`, `headers_json`, `attempts`
            FROM `synex_outbox` WHERE `state` = 'publishing' AND `locked_by` = ? ORDER BY `id` ASC]], { claimToken })
        if readError then return nil, readError end
        local report = { claimed = #(rows or {}), published = 0, retried = 0, dead = 0 }
        for _, row in ipairs(rows or {}) do
            local payloadOk, payload = pcall(platform.jsonDecode, row.payload_json)
            local headersOk, headers = pcall(platform.jsonDecode, row.headers_json)
            local callOk, result, handlerError = false, nil, nil
            if payloadOk and headersOk then
                callOk, result, handlerError = foundation.safeCall(handler, {
                    eventId = row.event_id, aggregateType = row.aggregate_type, aggregateId = row.aggregate_id,
                    eventType = row.event_type, producerResource = row.producer_resource,
                    schemaVersion = tonumber(row.schema_version),
                    payload = payload, headers = headers
                })
            else handlerError = 'invalid persisted JSON' end
            if callOk and handlerError == nil and result ~= false then
                local published, publishError = database:update([[UPDATE `synex_outbox` SET `state` = 'published',
                    `published_at` = CURRENT_TIMESTAMP(6), `last_error_code` = NULL,
                    `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]], { row.id, claimToken })
                if publishError then return nil, publishError end
                if affectedRows(published) ~= 1 then
                    metrics:increment('synex_outbox_dispatch_total', { result = 'claim_lost' })
                    return nil, foundation.error('OUTBOX_CLAIM_LOST',
                        'The outbox claim expired before publication could be finalized.', { retryable = true })
                end
                report.published = report.published + 1
            else
                local attempts = tonumber(row.attempts) or 1
                local dead = attempts >= 10
                local delay = math.min(300, 2 ^ math.min(attempts, 8))
                local failureCode = (not payloadOk or not headersOk) and 'OUTBOX_INVALID_JSON'
                    or not callOk and 'OUTBOX_HANDLER_EXCEPTION'
                    or handlerError ~= nil
                        and foundation.failureCode(handlerError, 'OUTBOX_HANDLER_ERROR')
                    or result == false and 'OUTBOX_HANDLER_REJECTED'
                    or 'OUTBOX_DISPATCH_FAILED'
                local finalized, retryError = database:update([[UPDATE `synex_outbox`
                    SET `state` = ?, `available_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                        `last_error_code` = ?, `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]],
                    { dead and 'dead' or 'pending', delay, failureCode, row.id, claimToken })
                if retryError then return nil, retryError end
                if affectedRows(finalized) ~= 1 then
                    metrics:increment('synex_outbox_dispatch_total', { result = 'claim_lost' })
                    return nil, foundation.error('OUTBOX_CLAIM_LOST',
                        'The outbox claim expired before failure handling could be finalized.', { retryable = true })
                end
                if dead then report.dead = report.dead + 1 else report.retried = report.retried + 1 end
                logger:warn('outbox dispatch failed', {
                    eventId = row.event_id, attempts = attempts, dead = dead, code = failureCode
                })
            end
        end
        metrics:increment('synex_outbox_dispatch_total', { result = 'published' }, report.published)
        metrics:increment('synex_outbox_dispatch_total', { result = 'retried' }, report.retried)
        metrics:increment('synex_outbox_dispatch_total', { result = 'dead' }, report.dead)
        return report, nil
    end

    function outbox:compactTerminal(maximum, policy)
        local enabled, featureError = requireFeature(features.durableEvents, 'durable events')
        if not enabled then return nil, featureError end
        local policyKind = type(policy) == 'table'
            and foundation.jsonContainerKind(policy) or nil
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 1000
            or (policyKind ~= 'plain' and policyKind ~= 'object') then
            return nil, foundation.error('INVALID_OUTBOX_RETENTION',
                'Outbox compaction requires a bounded batch and validated object retention policy.')
        end
        local allowedPolicy = { publishedPayloadAfterDays = true, deadPayloadAfterDays = true }
        for key in pairs(policy) do
            if type(key) ~= 'string' or not allowedPolicy[key] then
                return nil, foundation.error('INVALID_OUTBOX_RETENTION',
                    'Outbox retention contains an unknown property.')
            end
        end
        local publishedDays = rawget(policy, 'publishedPayloadAfterDays')
        local deadDays = rawget(policy, 'deadPayloadAfterDays')
        if type(publishedDays) ~= 'number' or math.type(publishedDays) ~= 'integer'
            or publishedDays < 1 or publishedDays > 36500
            or type(deadDays) ~= 'number' or math.type(deadDays) ~= 'integer'
            or deadDays < 1 or deadDays > 36500 then
            return nil, foundation.error('INVALID_OUTBOX_RETENTION',
                'Outbox retention ages must be integers from 1 through 36500 days.')
        end
        local branches = {
            {
                name = 'published', days = publishedDays,
                sql = [[UPDATE `synex_outbox`
                    FORCE INDEX (`idx_outbox_compact_published`)
                    SET `payload_json` = '{}', `headers_json` = '{}',
                        `payload_compacted_at` = CURRENT_TIMESTAMP(6)
                    WHERE `state` = 'published' AND `payload_compacted_at` IS NULL
                        AND `published_at` < TIMESTAMPADD(DAY, -?, CURRENT_TIMESTAMP(6))
                    ORDER BY `payload_compacted_at` ASC, `published_at` ASC, `id` ASC
                    LIMIT ?]]
            },
            {
                name = 'dead', days = deadDays,
                sql = [[UPDATE `synex_outbox`
                    FORCE INDEX (`idx_outbox_compact_dead`)
                    SET `payload_json` = '{}', `headers_json` = '{}',
                        `payload_compacted_at` = CURRENT_TIMESTAMP(6)
                    WHERE `state` = 'dead' AND `payload_compacted_at` IS NULL
                        AND `available_at` < TIMESTAMPADD(DAY, -?, CURRENT_TIMESTAMP(6))
                    ORDER BY `payload_compacted_at` ASC, `available_at` ASC, `id` ASC
                    LIMIT ?]]
            }
        }
        local start = outboxCompactionTurn
        outboxCompactionTurn = outboxCompactionTurn == 1 and 2 or 1
        local report = { compacted = 0, published = 0, dead = 0 }
        for offset = 0, 1 do
            local remaining = maximum - report.compacted
            if remaining == 0 then break end
            local branch = branches[((start + offset - 1) % 2) + 1]
            local compacted, compactError = database:update(branch.sql, { branch.days, remaining })
            if compactError then return nil, compactError end
            local count = affectedRows(compacted)
            if count == nil or count < 0 or count > remaining
                or math.type(count) ~= 'integer' then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Outbox compaction returned an invalid affected-row count.')
            end
            report[branch.name] = count
            report.compacted = report.compacted + count
        end
        metrics:increment('synex_outbox_compaction_total',
            { result = 'completed' }, report.compacted)
        return report, nil
    end

    local sagas = {}
    local function validSagaOwner(owner)
        return validResourceOwner(owner)
    end
    local sagaStates = {
        pending = true, running = true, compensating = true,
        completed = true, failed = true, cancelled = true
    }
    local sagaEvents = { started = true, succeeded = true, failed = true, compensated = true }
    local terminalSagaStates = { completed = true, failed = true, cancelled = true }
    local sagaCandidateStates = { 'pending', 'running', 'compensating' }
    local sagaCandidateCycles = {}
    local sagaCandidateTurn = 1
    local sagaCandidateScanMaximum = 50
    local function retireSagaLease(query, publicId, lease)
        local updated
        if lease ~= nil then
            updated = query([[UPDATE `synex_cluster_leases`
                SET `owner_id` = 'terminal',
                    `fencing_token` = CASE
                        WHEN `fencing_token` < 18446744073709551615
                            THEN `fencing_token` + 1
                        ELSE `fencing_token`
                    END,
                    `expires_at` = CURRENT_TIMESTAMP(6),
                    `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?
                    AND `expires_at` > CURRENT_TIMESTAMP(6)
                    AND `terminal_compaction_at` IS NULL]], {
                'saga:' .. publicId, lease.owner, lease.fencingToken
            })
            if affectedRows(updated) ~= 1 then
                return nil, foundation.error('SAGA_LEASE_LOST',
                    'The saga execution lease changed before terminal commit.', {
                        retryable = true
                    })
            end
            return true, nil
        end
        updated = query([[UPDATE `synex_cluster_leases`
            SET `owner_id` = 'terminal',
                `fencing_token` = CASE
                    WHEN `fencing_token` < 18446744073709551615
                        THEN `fencing_token` + 1
                    ELSE `fencing_token`
                END,
                `expires_at` = CURRENT_TIMESTAMP(6),
                `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
            WHERE `lease_name` = ? AND `terminal_compaction_at` IS NULL]], {
            'saga:' .. publicId
        })
        local count = affectedRows(updated)
        if count == nil or count < 0 or count > 1 then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Saga lease retirement returned an invalid affected-row count.')
        end
        return true, nil
    end

    function sagas:start(owner, sagaType, correlationId, context, options)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        options = options or {}
        local contextValue = context or {}
        local contextKind = type(contextValue) == 'table'
            and foundation.jsonContainerKind(contextValue) or nil
        if not validSagaOwner(owner)
            or type(sagaType) ~= 'string' or #sagaType < 1 or #sagaType > 96
            or not sagaType:match('^[a-z][a-z0-9_.%-]*$')
            or type(correlationId) ~= 'string' or #correlationId < 1 or #correlationId > 128
            or correlationId:find('[%z\1-\31\127]') or not contextKind
            or type(options) ~= 'table' or getmetatable(options) ~= nil
            or (options.deadlineAt ~= nil and (type(options.deadlineAt) ~= 'string' or #options.deadlineAt < 19
                or #options.deadlineAt > 32 or not options.deadlineAt:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d'))) then
            return nil, foundation.error('INVALID_SAGA', 'Saga type or correlation ID is invalid.')
        end
        local contextJson, contextError = boundedJson(contextValue, 65536)
        if not contextJson then return nil, contextError end
        local publicId = foundation.nextId('saga')
        local inserted, insertError = database:insert([[INSERT INTO `synex_sagas`
            (`public_id`, `owner_resource`, `saga_type`, `correlation_id`, `state`, `current_step`,
                `version`, `context_json`, `deadline_at`)
            VALUES (?, ?, ?, ?, 'pending', 0, 1, ?, ?)]],
            { publicId, owner, sagaType, correlationId, contextJson, options.deadlineAt })
        if insertError then
            local existing, readError = database:query([[SELECT `public_id`, `state`, `current_step`, `version`
                FROM `synex_sagas` WHERE `owner_resource` = ? AND `saga_type` = ?
                    AND `correlation_id` = ? LIMIT 1]], { owner, sagaType, correlationId })
            if readError then return nil, readError end
            if existing and existing[1] then return existing[1], nil end
            return nil, insertError
        end
        return { id = inserted, publicId = publicId, state = 'pending', currentStep = 0, version = 1 }, nil
    end

    function sagas:record(owner, publicId, expectedVersion, stepName, eventType, payload, errorValue)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        local allowedEvents = { started = true, succeeded = true, failed = true, compensated = true }
        if not validSagaOwner(owner)
            or type(publicId) ~= 'string' or #publicId < 1 or #publicId > 36
            or type(expectedVersion) ~= 'number' or math.type(expectedVersion) ~= 'integer' or expectedVersion < 1
            or type(stepName) ~= 'string' or #stepName < 1 or #stepName > 96
            or not stepName:match('^[a-z][a-z0-9_.%-]*$') or not allowedEvents[eventType] then
            return nil, foundation.error('INVALID_SAGA_STEP', 'Saga step input is invalid.')
        end
        local payloadJson, payloadError = boundedJson(payload or {}, 32768)
        if not payloadJson then return nil, payloadError end
        local errorJson = nil
        if errorValue ~= nil then errorJson, payloadError = boundedJson(errorValue, 8192); if not errorJson then return nil, payloadError end end
        local nextState = eventType == 'failed' and 'failed' or (eventType == 'compensated' and 'compensating' or 'running')
        local result, domainError = nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            local rows = query([[SELECT `id`, `state`, `current_step`, `version`
                FROM `synex_sagas` WHERE `public_id` = ? AND `owner_resource` = ? FOR UPDATE]],
                { publicId, owner }) or {}
            local saga = rows[1]
            if not saga then
                domainError = foundation.error('SAGA_NOT_FOUND', 'The saga does not exist.')
                return false
            end
            if saga.state == 'completed' or saga.state == 'failed' or saga.state == 'cancelled' then
                domainError = foundation.error('SAGA_TERMINAL',
                    'A terminal saga cannot accept another event.')
                return false
            end
            if saga.state ~= 'pending' and saga.state ~= 'running'
                and saga.state ~= 'compensating' then
                domainError = foundation.error('SAGA_DATA_INVALID',
                    'The persisted saga state is invalid.')
                return false
            end
            local version, currentStep = tonumber(saga.version), tonumber(saga.current_step)
            if not version or math.type(version) ~= 'integer' or version ~= expectedVersion
                or not currentStep or math.type(currentStep) ~= 'integer'
                or currentStep < 0 then
                domainError = foundation.error('SAGA_CONFLICT',
                    'The saga changed concurrently.', { retryable = true })
                return false
            end
            if currentStep >= 2048 then
                domainError = foundation.error('SAGA_HISTORY_LIMIT',
                    'The saga reached the maximum persisted step history.')
                return false
            end
            local sequence = currentStep + 1
            query([[INSERT INTO `synex_saga_steps`
                (`saga_id`, `sequence_no`, `step_name`, `event_type`, `attempt`, `payload_json`, `error_json`)
                VALUES (?, ?, ?, ?, 1, ?, ?)]],
                { saga.id, sequence, stepName, eventType, payloadJson, errorJson })
            local updated = query([[UPDATE `synex_sagas`
                SET `state` = ?, `current_step` = ?, `version` = `version` + 1,
                    `last_error_json` = ?,
                    `completed_at` = CASE WHEN ? = 'failed'
                        THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
                    `updated_at` = CURRENT_TIMESTAMP(6)
                WHERE `id` = ? AND `version` = ? AND `owner_resource` = ?
                    AND `state` IN ('pending', 'running', 'compensating')]],
                { nextState, sequence, errorJson, nextState, saga.id, expectedVersion, owner })
            if affectedRows(updated) ~= 1 then
                domainError = foundation.error('SAGA_CONFLICT',
                    'The saga changed during event persistence.', { retryable = true })
                return false
            end
            if nextState == 'failed' then
                local retired
                retired, domainError = retireSagaLease(query, publicId, nil)
                if not retired then return false end
            end
            result = {
                publicId = publicId, state = nextState,
                currentStep = sequence, version = expectedVersion + 1
            }
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return result, nil
    end

    function sagas:candidates(maximum, selectors)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        maximum = maximum == nil and 10 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer' or maximum < 1 or maximum > 50 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Saga dispatch batch size must be an integer from 1 through 50.')
        end
        local selectorLookup = nil
        if selectors ~= nil then
            if type(selectors) ~= 'table' or getmetatable(selectors) ~= nil
                or #selectors > 512 then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Saga candidate selectors are invalid.')
            end
            local selectorCount = 0
            for key in pairs(selectors) do
                if type(key) ~= 'number' or math.type(key) ~= 'integer'
                    or key < 1 or key > #selectors then
                    return nil, foundation.error('INVALID_ARGUMENT',
                        'Saga candidate selectors are invalid.')
                end
                selectorCount = selectorCount + 1
            end
            if selectorCount ~= #selectors then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Saga candidate selectors are invalid.')
            end
            selectorLookup = {}
            for index, selector in ipairs(selectors) do
                if type(selector) ~= 'table' or getmetatable(selector) ~= nil
                    or type(selector.ownerResource) ~= 'string'
                    or not validSagaOwner(selector.ownerResource)
                    or type(selector.sagaType) ~= 'string' or #selector.sagaType < 1
                    or #selector.sagaType > 96
                    or not selector.sagaType:match('^[a-z][a-z0-9_.%-]*$') then
                    return nil, foundation.error('INVALID_ARGUMENT',
                        ('Saga candidate selector %d is invalid.'):format(index))
                end
                for key in pairs(selector) do
                    if key ~= 'ownerResource' and key ~= 'sagaType' then
                        return nil, foundation.error('INVALID_ARGUMENT',
                            ('Saga candidate selector %d contains unknown fields.'):format(index))
                    end
                end
                selectorLookup[selector.ownerResource .. '\0' .. selector.sagaType] = true
            end
            if selectorCount == 0 then return {}, nil end
        end

        local function boundedRowCount(rows, limit)
            if type(rows) ~= 'table' then return nil end
            local count = 0
            for key in pairs(rows) do
                if type(key) ~= 'number' or math.type(key) ~= 'integer'
                    or key < 1 or key > limit then return nil end
                count = count + 1
            end
            if count ~= #rows or count > limit then return nil end
            return count
        end

        local function validCursorRow(row, state)
            local validId = type(row) == 'table' and (
                (type(row.id) == 'number' and math.type(row.id) == 'integer' and row.id > 0)
                or (type(row.id) == 'string' and #row.id <= 20
                    and row.id:match('^[1-9][0-9]*$') ~= nil)
            )
            local updatedAt = validId and row.updated_at_cursor or nil
            return validId and type(updatedAt) == 'string' and #updatedAt == 26
                and updatedAt:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d%d%d%d$') ~= nil
                and row.state == state
        end

        local function databaseIdBefore(left, right)
            if type(left) == 'number' and type(right) == 'number' then return left < right end
            left, right = tostring(left), tostring(right)
            if #left ~= #right then return #left < #right end
            return left < right
        end

        local function cursorBefore(left, right)
            if left.updatedAt ~= right.updatedAt then return left.updatedAt < right.updatedAt end
            return databaseIdBefore(left.id, right.id)
        end

        local function loadHighWatermark(state)
            local rows, queryError = database:query([[SELECT `id`, `state`,
                    DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s.%f') AS `updated_at_cursor`
                FROM `synex_sagas` FORCE INDEX (`idx_sagas_state_updated`)
                WHERE `state` = ?
                ORDER BY `updated_at` DESC, `id` DESC LIMIT 1]], { state })
            if queryError then return nil, queryError end
            if boundedRowCount(rows, 1) == nil then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Saga candidate high-watermark returned an invalid bounded result.')
            end
            local row = rows[1]
            if row == nil then return false, nil end
            if not validCursorRow(row, state) then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Saga candidate high-watermark has an invalid cursor.')
            end
            return { updatedAt = row.updated_at_cursor, id = row.id }, nil
        end

        local function queryWindow(state, cycle)
            local sql
            local parameters
            if cycle.cursor then
                sql = [[SELECT `id`, `public_id`, `owner_resource`, `saga_type`, `state`, `version`,
                        DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s.%f') AS `updated_at_cursor`,
                        (`deadline_at` IS NOT NULL AND `deadline_at` <= CURRENT_TIMESTAMP(6)) AS `deadline_expired`,
                        TIMESTAMPDIFF(MICROSECOND, `updated_at`, CURRENT_TIMESTAMP(6)) DIV 1000 AS `age_ms`
                    FROM `synex_sagas` FORCE INDEX (`idx_sagas_state_updated`)
                    WHERE `state` = ? AND (`updated_at` > ?
                        OR (`updated_at` = ? AND `id` > ?))
                        AND (`updated_at` < ?
                            OR (`updated_at` = ? AND `id` <= ?))
                    ORDER BY `updated_at` ASC, `id` ASC LIMIT ?]]
                parameters = {
                    state, cycle.cursor.updatedAt, cycle.cursor.updatedAt, cycle.cursor.id,
                    cycle.highWatermark.updatedAt, cycle.highWatermark.updatedAt,
                    cycle.highWatermark.id, sagaCandidateScanMaximum
                }
            else
                sql = [[SELECT `id`, `public_id`, `owner_resource`, `saga_type`, `state`, `version`,
                        DATE_FORMAT(`updated_at`, '%Y-%m-%d %H:%i:%s.%f') AS `updated_at_cursor`,
                        (`deadline_at` IS NOT NULL AND `deadline_at` <= CURRENT_TIMESTAMP(6)) AS `deadline_expired`,
                        TIMESTAMPDIFF(MICROSECOND, `updated_at`, CURRENT_TIMESTAMP(6)) DIV 1000 AS `age_ms`
                    FROM `synex_sagas` FORCE INDEX (`idx_sagas_state_updated`)
                    WHERE `state` = ? AND (`updated_at` < ?
                        OR (`updated_at` = ? AND `id` <= ?))
                    ORDER BY `updated_at` ASC, `id` ASC LIMIT ?]]
                parameters = {
                    state, cycle.highWatermark.updatedAt, cycle.highWatermark.updatedAt,
                    cycle.highWatermark.id, sagaCandidateScanMaximum
                }
            end
            local rows, queryError = database:query(sql, parameters)
            if queryError then return nil, queryError end
            if boundedRowCount(rows, sagaCandidateScanMaximum) == nil then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'Saga candidate scan returned an invalid bounded result.')
            end
            local previous = cycle.cursor
            for index, row in ipairs(rows) do
                if not validCursorRow(row, state) then
                    return nil, foundation.error('DATABASE_RESULT_INVALID',
                        ('Saga candidate scan row %d has an invalid cursor.'):format(index))
                end
                local current = { updatedAt = row.updated_at_cursor, id = row.id }
                if (previous and not cursorBefore(previous, current))
                    or cursorBefore(cycle.highWatermark, current) then
                    return nil, foundation.error('DATABASE_RESULT_INVALID',
                        ('Saga candidate scan row %d is outside its ordered cursor range.'):format(index))
                end
                previous = current
            end
            return rows, nil
        end

        local candidates = {}
        local start = sagaCandidateTurn
        sagaCandidateTurn = (sagaCandidateTurn % #sagaCandidateStates) + 1
        for offset = 0, #sagaCandidateStates - 1 do
            if #candidates >= maximum then break end
            local state = sagaCandidateStates[((start + offset - 1) % #sagaCandidateStates) + 1]
            local cycle = sagaCandidateCycles[state]
            if cycle == nil then
                cycle = { cursor = nil, highWatermark = nil }
                sagaCandidateCycles[state] = cycle
            end
            local cycleHasRows = true
            if cycle.highWatermark == nil then
                local highWatermark, highWatermarkError = loadHighWatermark(state)
                if highWatermark == nil then return nil, highWatermarkError end
                if highWatermark == false then
                    cycleHasRows = false
                else
                    cycle.highWatermark = highWatermark
                end
            end
            if cycleHasRows then
                local rows, queryError = queryWindow(state, cycle)
                if not rows then return nil, queryError end
                if #rows == 0 then
                    cycle.cursor = nil
                    cycle.highWatermark = nil
                else
                    local lastTraversed = nil
                    for _, row in ipairs(rows) do
                        lastTraversed = row
                        local owner = row.owner_resource
                        local sagaType = row.saga_type
                        local selected = type(owner) == 'string' and type(sagaType) == 'string'
                            and (selectorLookup == nil
                                or selectorLookup[owner .. '\0' .. sagaType] == true)
                        local version = tonumber(row.version)
                        if selected and validSagaOwner(owner)
                            and #sagaType >= 1 and #sagaType <= 96
                            and sagaType:match('^[a-z][a-z0-9_.%-]*$')
                            and type(row.public_id) == 'string' and #row.public_id >= 1
                            and #row.public_id <= 36
                            and version and math.type(version) == 'integer' and version >= 1 then
                            candidates[#candidates + 1] = {
                                publicId = row.public_id,
                                ownerResource = owner,
                                sagaType = sagaType,
                                state = row.state,
                                version = version,
                                deadlineExpired = tonumber(row.deadline_expired) == 1,
                                ageMs = math.max(0, tonumber(row.age_ms) or 0)
                            }
                        end
                        if #candidates >= maximum then break end
                    end
                    if lastTraversed.updated_at_cursor == cycle.highWatermark.updatedAt
                        and tostring(lastTraversed.id) == tostring(cycle.highWatermark.id) then
                        cycle.cursor = nil
                        cycle.highWatermark = nil
                    else
                        cycle.cursor = {
                            updatedAt = lastTraversed.updated_at_cursor,
                            id = lastTraversed.id
                        }
                    end
                end
            end
        end
        return candidates, nil
    end

    function sagas:load(publicId, owner)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        if type(publicId) ~= 'string' or #publicId < 1 or #publicId > 36
            or not validSagaOwner(owner) then
            return nil, foundation.error('INVALID_SAGA', 'Saga ID is invalid.')
        end
        local rows, err = database:query([[SELECT `id`, `public_id`, `owner_resource`, `saga_type`,
                `correlation_id`, `state`,
                `current_step`, `version`, `context_json`, `last_error_json`, `deadline_at`,
                (`deadline_at` IS NOT NULL AND `deadline_at` <= CURRENT_TIMESTAMP(6)) AS `deadline_expired`,
                TIMESTAMPDIFF(MICROSECOND, `updated_at`, CURRENT_TIMESTAMP(6)) DIV 1000 AS `age_ms`
            FROM `synex_sagas` WHERE `public_id` = ? AND `owner_resource` = ? LIMIT 1]],
            { publicId, owner })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, foundation.error('SAGA_NOT_FOUND', 'The saga does not exist.') end
        local contextOk, context = pcall(platform.jsonDecode, row.context_json)
        if not contextOk or type(context) ~= 'table' then
            return nil, foundation.error('SAGA_DATA_INVALID', 'Saga context is not valid JSON object data.')
        end
        local stepRows, stepError = database:query([[SELECT `sequence_no`, `step_name`, `event_type`, `attempt`,
                `payload_json`, `error_json`, `occurred_at`
            FROM `synex_saga_steps` WHERE `saga_id` = ? ORDER BY `sequence_no` ASC LIMIT 2049]], { row.id })
        if stepError then return nil, stepError end
        if #(stepRows or {}) > 2048 then return nil, foundation.error('SAGA_HISTORY_TOO_LARGE', 'Saga history exceeds the safe processing limit.') end
        local steps = {}
        for index, step in ipairs(stepRows or {}) do
            local payloadOk, payload = pcall(platform.jsonDecode, step.payload_json)
            local errorOk, decodedError = true, nil
            if step.error_json ~= nil then errorOk, decodedError = pcall(platform.jsonDecode, step.error_json) end
            if not payloadOk or not errorOk then return nil, foundation.error('SAGA_DATA_INVALID', 'Saga step history contains invalid JSON.') end
            steps[index] = {
                sequence = tonumber(step.sequence_no), name = step.step_name, event = step.event_type,
                attempt = tonumber(step.attempt) or 1, payload = payload, error = decodedError,
                occurredAt = tostring(step.occurred_at)
            }
        end
        local lastError = nil
        if row.last_error_json ~= nil then
            local lastErrorOk
            lastErrorOk, lastError = pcall(platform.jsonDecode, row.last_error_json)
            if not lastErrorOk then return nil, foundation.error('SAGA_DATA_INVALID', 'Saga error data is invalid JSON.') end
        end
        return {
            databaseId = row.id, publicId = row.public_id, ownerResource = row.owner_resource,
            sagaType = row.saga_type,
            correlationId = row.correlation_id, state = row.state,
            currentStep = tonumber(row.current_step) or 0, version = tonumber(row.version) or 0,
            context = context, lastError = lastError, deadlineAt = row.deadline_at,
            deadlineExpired = tonumber(row.deadline_expired) == 1,
            ageMs = math.max(0, tonumber(row.age_ms) or 0), steps = steps
        }, nil
    end

    function sagas:appendRuntimeEvent(command)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        local nextStateTerminal = type(command) == 'table'
            and terminalSagaStates[command.nextState] == true or false
        local lease = type(command) == 'table' and command.lease or nil
        if type(command) ~= 'table' or not validSagaOwner(command.ownerResource)
            or type(command.publicId) ~= 'string' or #command.publicId < 1 or #command.publicId > 36
            or type(command.expectedVersion) ~= 'number' or math.type(command.expectedVersion) ~= 'integer'
            or type(command.stepName) ~= 'string' or #command.stepName < 1 or #command.stepName > 96
            or not sagaEvents[command.eventType] or not sagaStates[command.nextState]
            or type(command.attempt) ~= 'number' or math.type(command.attempt) ~= 'integer'
            or command.attempt < 1 or command.attempt > 65535
            or (command.terminal == true) ~= nextStateTerminal
            or (nextStateTerminal and (type(lease) ~= 'table'
                or lease.name ~= 'saga:' .. command.publicId
                or type(lease.owner) ~= 'string' or #lease.owner < 1 or #lease.owner > 96
                or type(lease.fencingToken) ~= 'number'
                or math.type(lease.fencingToken) ~= 'integer'
                or lease.fencingToken < 1)) then
            return nil, foundation.error('INVALID_SAGA_EVENT', 'Runtime saga event input is invalid.')
        end
        local payloadJson, payloadError = boundedJson(command.payload or {}, 32768)
        if not payloadJson then return nil, payloadError end
        local contextJson, contextError = boundedJson(command.context or {}, 65536)
        if not contextJson then return nil, contextError end
        local errorJson = nil
        if command.error ~= nil then
            errorJson, payloadError = boundedJson(foundation.redact(command.error), 8192)
            if not errorJson then return nil, payloadError end
        end
        local result, domainError = nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            local locked = query([[SELECT `id`, `state`, `current_step`, `version` FROM `synex_sagas`
                WHERE `public_id` = ? AND `owner_resource` = ? FOR UPDATE]],
                { command.publicId, command.ownerResource })
            local saga = locked and locked[1]
            if not saga then domainError = foundation.error('SAGA_NOT_FOUND', 'The saga does not exist.') return false end
            if tonumber(saga.version) ~= command.expectedVersion then
                domainError = foundation.error('SAGA_CONFLICT', 'The saga changed concurrently.', { retryable = true })
                return false
            end
            if saga.state == 'completed' or saga.state == 'failed' or saga.state == 'cancelled' then
                domainError = foundation.error('SAGA_TERMINAL', 'The saga is already terminal.')
                return false
            end
            local currentStep = tonumber(saga.current_step)
            if not currentStep or math.type(currentStep) ~= 'integer' or currentStep < 0 then
                domainError = foundation.error('SAGA_DATA_INVALID',
                    'The persisted saga step position is invalid.')
                return false
            end
            if currentStep >= 2048 then
                domainError = foundation.error('SAGA_HISTORY_LIMIT',
                    'The saga reached the maximum persisted step history.')
                return false
            end
            local sequence = currentStep + 1
            query([[INSERT INTO `synex_saga_steps`
                (`saga_id`, `sequence_no`, `step_name`, `event_type`, `attempt`, `payload_json`, `error_json`)
                VALUES (?, ?, ?, ?, ?, ?, ?)]], {
                saga.id, sequence, command.stepName, command.eventType, command.attempt, payloadJson, errorJson
            })
            local updated = query([[UPDATE `synex_sagas` SET `state` = ?, `current_step` = ?,
                    `version` = `version` + 1, `context_json` = ?,
                    `last_error_json` = CASE WHEN ? = 1 THEN NULL ELSE COALESCE(?, `last_error_json`) END,
                    `completed_at` = CASE WHEN ? = 1 THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
                    `updated_at` = CURRENT_TIMESTAMP(6)
                WHERE `id` = ? AND `version` = ? AND `owner_resource` = ?]], {
                command.nextState, sequence, contextJson, command.clearError == true and 1 or 0,
                errorJson, command.terminal == true and 1 or 0, saga.id,
                command.expectedVersion, command.ownerResource
            })
            local affected = type(updated) == 'table' and tonumber(updated.affectedRows) or tonumber(updated)
            if affected ~= 1 then
                domainError = foundation.error('SAGA_CONFLICT', 'The saga changed during event persistence.', { retryable = true })
                return false
            end
            if nextStateTerminal then
                local retired
                retired, domainError = retireSagaLease(query, command.publicId, lease)
                if not retired then return false end
            end
            result = {
                publicId = command.publicId, state = command.nextState,
                currentStep = sequence, version = command.expectedVersion + 1
            }
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return result, nil
    end

    function sagas:snapshot()
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then
            return { enabled = false, states = {}, truncated = false, stateTruncation = {} }, nil
        end
        local probeLimit = diagnosticBatchMaximum + 1
        local rows, err = database:query([[
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'pending' ORDER BY `deadline_at`, `id` LIMIT ?)
            UNION ALL
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'running' ORDER BY `deadline_at`, `id` LIMIT ?)
            UNION ALL
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'compensating' ORDER BY `deadline_at`, `id` LIMIT ?)
            UNION ALL
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'completed' ORDER BY `deadline_at`, `id` LIMIT ?)
            UNION ALL
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'failed' ORDER BY `deadline_at`, `id` LIMIT ?)
            UNION ALL
            (SELECT `state` FROM `synex_sagas` FORCE INDEX (`idx_sagas_dispatch`)
                WHERE `state` = 'cancelled' ORDER BY `deadline_at`, `id` LIMIT ?)]], {
            probeLimit, probeLimit, probeLimit, probeLimit, probeLimit, probeLimit
        })
        if err then return nil, err end
        local allowedStates = {
            pending = true, running = true, compensating = true,
            completed = true, failed = true, cancelled = true
        }
        if type(rows) ~= 'table' or #rows > probeLimit * 6 then
            return nil, foundation.error('SAGA_SUMMARY_INVALID',
                'The bounded saga summary is invalid.', { retryable = true })
        end
        local observed = {}
        for _, row in ipairs(rows or {}) do
            if type(row) ~= 'table' or not allowedStates[row.state] then
                return nil, foundation.error('SAGA_SUMMARY_INVALID',
                    'The bounded saga summary contains an invalid state.', { retryable = true })
            end
            observed[row.state] = (observed[row.state] or 0) + 1
        end
        local states, stateTruncation, total, truncated = {}, {}, 0, false
        for state in pairs(allowedStates) do
            local count = observed[state] or 0
            stateTruncation[state] = count > diagnosticBatchMaximum
            states[state] = math.min(count, diagnosticBatchMaximum)
            total = total + states[state]
            truncated = truncated or stateTruncation[state]
        end
        return {
            enabled = true,
            total = total,
            states = states,
            truncated = truncated,
            stateTruncation = stateTruncation
        }, nil
    end

    local audit = {}
    function audit:append(entry)
        if type(entry) ~= 'table' or type(entry.action) ~= 'string' or #entry.action > 96
            or type(entry.targetType) ~= 'string' or #entry.targetType > 64
            or type(entry.targetId) ~= 'string' or #entry.targetId > 128 then
            return nil, foundation.error('INVALID_AUDIT_ENTRY', 'Audit action and target are invalid.')
        end
        local beforeJson, beforeError = nil, nil
        if entry.before ~= nil then beforeJson, beforeError = boundedJson(foundation.redact(entry.before), 32768) end
        if beforeError then return nil, beforeError end
        local afterJson, afterError = nil, nil
        if entry.after ~= nil then afterJson, afterError = boundedJson(foundation.redact(entry.after), 32768) end
        if afterError then return nil, afterError end
        local contextJson, contextError = boundedJson(foundation.redact(entry.context or {}), 16384)
        if not contextJson then return nil, contextError end
        local eventId = foundation.nextId('audit')
        local inserted, insertError = database:insert([[INSERT INTO `synex_audit_log`
            (`event_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`, `trace_id`,
                `before_json`, `after_json`, `context_json`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
            eventId, tostring(entry.actorType or 'resource'):sub(1, 32), entry.actorId,
            entry.action, entry.targetType, entry.targetId, entry.traceId,
            beforeJson, afterJson, contextJson
        })
        if insertError then return nil, insertError end
        return { id = inserted, eventId = eventId }, nil
    end

    local auditSearchKinds = {
        trace = {
            maximumLength = 64,
            clause = '`trace_id` = ?',
            parameters = function(value) return { value } end
        },
        character = {
            maximumLength = 36,
            clause = "`target_type` = 'character' AND `target_id` = ?",
            parameters = function(value) return { value } end
        },
        transaction = {
            maximumLength = 64,
            clause = "`target_type` = 'transaction' AND `target_id` = ?",
            parameters = function(value) return { value } end
        },
        resource = {
            maximumLength = 64,
            clause = "((`actor_type` = 'resource' AND `actor_id` = ?) OR (`target_type` = 'resource' AND `target_id` = ?))",
            parameters = function(value) return { value, value } end
        }
    }
    local safeAuditReferences = {
        capability = true,
        character = true,
        resource = true,
        saga = true,
        system = true,
        transaction = true
    }

    function audit:search(request)
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return nil, foundation.error('INVALID_AUDIT_SEARCH', 'Audit search requires a plain request object.')
        end
        local allowedKeys = { kind = true, value = true, limit = true, cursor = true }
        for key in pairs(request) do
            if type(key) ~= 'string' or not allowedKeys[key] then
                return nil, foundation.error('INVALID_AUDIT_SEARCH', 'Audit search contains an unknown property.')
            end
        end
        local kind = request.kind
        local definition = auditSearchKinds[kind]
        local value = request.value
        if not definition or type(value) ~= 'string' or #value < 1 or #value > definition.maximumLength
            or not value:match('^[A-Za-z0-9_.:%-]+$') then
            return nil, foundation.error('INVALID_AUDIT_SEARCH', 'Audit search kind or value is invalid.')
        end
        local limit = request.limit == nil and 25 or request.limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer' or limit < 1 or limit > 64 then
            return nil, foundation.error('INVALID_AUDIT_SEARCH', 'Audit search limit must be an integer from 1 through 64.')
        end
        local cursor = request.cursor
        if cursor ~= nil and (type(cursor) ~= 'string' or #cursor < 1 or #cursor > 20
            or not cursor:match('^[1-9]%d*$')) then
            return nil, foundation.error('INVALID_AUDIT_SEARCH',
                'Audit search cursor must be a positive decimal row identifier.')
        end
        local parameters = definition.parameters(value)
        local cursorClause = ''
        if cursor then
            cursorClause = ' AND `id` < CAST(? AS UNSIGNED)'
            parameters[#parameters + 1] = cursor
        end
        parameters[#parameters + 1] = limit + 1
        local rows, queryError = database:query([[SELECT CAST(`id` AS CHAR) AS `cursor_id`,
                `event_id`, `occurred_at`, `actor_type`, `actor_id`,
                `action`, `target_type`, `target_id`, `trace_id`
            FROM `synex_audit_log` WHERE ]] .. definition.clause .. cursorClause .. [[
            ORDER BY `id` DESC LIMIT ?]], parameters)
        if queryError then return nil, queryError end
        rows = rows or {}
        local hasMore = #rows > limit
        local entries = {}
        for index = 1, math.min(#rows, limit) do
            local row = rows[index]
            local actorSafe = row.actor_id == nil or safeAuditReferences[row.actor_type] == true
            local targetSafe = safeAuditReferences[row.target_type] == true
            entries[index] = {
                eventId = row.event_id,
                occurredAt = tostring(row.occurred_at),
                action = row.action,
                traceId = row.trace_id,
                actor = {
                    type = row.actor_type,
                    reference = actorSafe and row.actor_id or '[redacted]'
                },
                target = {
                    type = row.target_type,
                    reference = targetSafe and row.target_id or '[redacted]'
                },
                masked = not actorSafe or not targetSafe
            }
        end
        metrics:increment('synex_audit_search_total', { kind = kind })
        local last = hasMore and rows[limit] or nil
        local nextCursor = last and last.cursor_id or nil
        if nextCursor ~= nil and not nextCursor:match('^[1-9]%d*$') then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Audit search returned an invalid pagination marker.', { retryable = true })
        end
        return {
            kind = kind,
            limit = limit,
            entries = entries,
            nextCursor = nextCursor,
            hasMore = hasMore,
            truncated = hasMore
        }, nil
    end

    return { idempotency = idempotency, outbox = outbox, sagas = sagas, audit = audit }
end
