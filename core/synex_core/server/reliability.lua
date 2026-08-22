local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.reliability = function(deps)
    local foundation = assert(deps.foundation, 'reliability requires foundation')
    local database = assert(deps.database, 'reliability requires database')
    local platform = assert(deps.platform, 'reliability requires platform')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local workerId = deps.instanceId .. ':outbox'
    local features = deps.features or {}

    local function requireFeature(enabled, name)
        if enabled ~= false then return true, nil end
        return nil, foundation.error('FEATURE_DISABLED', ('The %s feature is disabled by configuration.'):format(name))
    end

    local function boundedJson(value, maximumBytes)
        local ok, encoded = pcall(platform.jsonEncode, value)
        if not ok then return nil, foundation.error('JSON_ENCODING_FAILED', 'The value cannot be encoded as JSON.') end
        if #encoded > maximumBytes then return nil, foundation.error('PAYLOAD_TOO_LARGE', 'The encoded value exceeds its byte limit.') end
        return encoded, nil
    end

    local idempotency = {}
    function idempotency:run(owner, operation, key, request, handler, options)
        options = options or {}
        if type(operation) ~= 'string' or #operation < 1 or #operation > 64
            or type(key) ~= 'string' or #key < 8 or #key > 36 or type(handler) ~= 'function' then
            return nil, foundation.error('INVALID_IDEMPOTENCY_INPUT', 'Operation, key, and handler are invalid.')
        end
        local namespace = owner .. ':' .. operation
        if #namespace > 96 then return nil, foundation.error('INVALID_IDEMPOTENCY_INPUT', 'Idempotency namespace is too long.') end
        local requestJson, encodeError = boundedJson(request, options.maximumRequestBytes or 32768)
        if not requestJson then return nil, encodeError end
        local requestHash = deps.sha256(requestJson)
        local ownerToken = foundation.nextId('idem')
        local lockSeconds = math.max(5, math.min(options.lockSeconds or 30, 300))
        local ttlSeconds = math.max(lockSeconds, math.min(options.ttlSeconds or 86400, 604800))
        local inserted, insertError = database:update([[INSERT IGNORE INTO `synex_idempotency_keys`
            (`namespace`, `idempotency_key`, `request_hash`, `state`, `response_json`, `owner_token`, `locked_until`, `expires_at`)
            VALUES (?, ?, ?, 'pending', NULL, ?, TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
            { namespace, key, requestHash, ownerToken, lockSeconds, ttlSeconds })
        if insertError then return nil, insertError end
        local ownsClaim = tonumber(inserted) == 1
        if not ownsClaim then
            local rows, readError = database:query([[SELECT `request_hash`, `state`, `response_json`,
                (`locked_until` < CURRENT_TIMESTAMP(6)) AS `lock_expired`,
                (`expires_at` < CURRENT_TIMESTAMP(6)) AS `record_expired`
                FROM `synex_idempotency_keys` WHERE `namespace` = ? AND `idempotency_key` = ? LIMIT 1]],
                { namespace, key })
            if readError then return nil, readError end
            local record = rows and rows[1]
            if not record then return nil, foundation.error('IDEMPOTENCY_RACE', 'The idempotency claim disappeared.', { retryable = true }) end
            if record.request_hash ~= requestHash then return nil, foundation.error('IDEMPOTENCY_CONFLICT', 'The idempotency key was used with a different request.') end
            if record.state == 'completed' and tonumber(record.record_expired) ~= 1 then
                local ok, response = pcall(platform.jsonDecode, record.response_json or 'null')
                if not ok then return nil, foundation.error('IDEMPOTENCY_RESPONSE_CORRUPT', 'The stored idempotent response is invalid.') end
                metrics:increment('synex_idempotency_total', { result = 'replay' })
                return foundation.copy(response), nil, { replayed = true }
            end
            if tonumber(record.lock_expired) ~= 1 and tonumber(record.record_expired) ~= 1 then
                return nil, foundation.error('IDEMPOTENCY_IN_PROGRESS', 'The idempotent operation is already in progress.', { retryable = true })
            end
            local claimed, claimError = database:update([[UPDATE `synex_idempotency_keys`
                SET `state` = 'pending', `owner_token` = ?,
                    `locked_until` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                    `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)), `response_json` = NULL
                WHERE `namespace` = ? AND `idempotency_key` = ? AND `request_hash` = ?
                    AND (`locked_until` < CURRENT_TIMESTAMP(6) OR `expires_at` < CURRENT_TIMESTAMP(6))]],
                { ownerToken, lockSeconds, ttlSeconds, namespace, key, requestHash })
            if claimError then return nil, claimError end
            if tonumber(claimed) ~= 1 then return nil, foundation.error('IDEMPOTENCY_IN_PROGRESS', 'Another worker reclaimed the operation.', { retryable = true }) end
        end

        local ok, value, operationError = foundation.safeCall(handler)
        if not ok or operationError then
            local _, cleanupError = database:update([[UPDATE `synex_idempotency_keys` SET `state` = 'failed', `locked_until` = CURRENT_TIMESTAMP(6)
                WHERE `namespace` = ? AND `idempotency_key` = ? AND `owner_token` = ?]],
                { namespace, key, ownerToken })
            if cleanupError then
                logger:error('idempotency failure state cleanup failed', {
                    owner = owner,
                    operation = operation,
                    code = cleanupError.code
                })
            end
            metrics:increment('synex_idempotency_total', { result = 'failed' })
            if type(operationError) == 'table' then return nil, operationError end
            logger:error('idempotent handler failed', { owner = owner, operation = operation, error = tostring(ok and operationError or value) })
            return nil, foundation.error('OPERATION_FAILED', 'The idempotent operation failed.', { retryable = true })
        end
        local responseJson, responseError = boundedJson(value, options.maximumResponseBytes or 65536)
        if not responseJson then return nil, responseError end
        local completed, completeError = database:update([[UPDATE `synex_idempotency_keys`
            SET `state` = 'completed', `response_json` = ?, `completed_at` = CURRENT_TIMESTAMP(6),
                `locked_until` = CURRENT_TIMESTAMP(6)
            WHERE `namespace` = ? AND `idempotency_key` = ? AND `owner_token` = ? AND `state` = 'pending']],
            { responseJson, namespace, key, ownerToken })
        if completeError then return nil, completeError end
        if tonumber(completed) ~= 1 then return nil, foundation.error('IDEMPOTENCY_LEASE_LOST', 'The idempotency claim expired before completion.', { retryable = true }) end
        metrics:increment('synex_idempotency_total', { result = 'completed' })
        return foundation.copy(value), nil, { replayed = false }
    end

    local outbox = {}
    function outbox:enqueue(event)
        local enabled, featureError = requireFeature(features.durableEvents, 'durable events')
        if not enabled then return nil, featureError end
        if type(event) ~= 'table' or type(event.aggregateType) ~= 'string' or type(event.aggregateId) ~= 'string'
            or type(event.eventType) ~= 'string' or #event.aggregateType > 64 or #event.aggregateId > 128 or #event.eventType > 96 then
            return nil, foundation.error('INVALID_OUTBOX_EVENT', 'Outbox event identity is invalid.')
        end
        local payload, payloadError = boundedJson(event.payload or {}, 65536)
        if not payload then return nil, payloadError end
        local headers, headersError = boundedJson(event.headers or {}, 8192)
        if not headers then return nil, headersError end
        local eventId = event.eventId or foundation.nextId('event')
        local inserted, insertError = database:insert([[INSERT INTO `synex_outbox`
            (`event_id`, `aggregate_type`, `aggregate_id`, `event_type`, `schema_version`,
                `payload_json`, `headers_json`, `state`, `attempts`, `available_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, CURRENT_TIMESTAMP(6))]], {
            eventId, event.aggregateType, event.aggregateId, event.eventType,
            math.max(1, math.min(tonumber(event.schemaVersion) or 1, 65535)), payload, headers
        })
        if insertError then return nil, insertError end
        return { id = inserted, eventId = eventId }, nil
    end

    function outbox:dispatchBatch(handler, maximum)
        local enabled, featureError = requireFeature(features.durableEvents, 'durable events')
        if not enabled then return nil, featureError end
        if type(handler) ~= 'function' then return nil, foundation.error('INVALID_ARGUMENT', 'An outbox dispatch handler is required.') end
        maximum = math.max(1, math.min(tonumber(maximum) or 25, 100))
        local _, resetError = database:update([[UPDATE `synex_outbox` SET `state` = 'pending', `locked_by` = NULL, `locked_until` = NULL
            WHERE `state` = 'publishing' AND `locked_until` < CURRENT_TIMESTAMP(6)]], {})
        if resetError then return nil, resetError end
        local claimToken = workerId .. ':' .. foundation.nextId('claim')
        local _, claimError = database:update([[UPDATE `synex_outbox`
            SET `state` = 'publishing', `locked_by` = ?, `locked_until` = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
                `attempts` = `attempts` + 1
            WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `id` ASC LIMIT ?]], { claimToken, maximum })
        if claimError then return nil, claimError end
        local rows, readError = database:query([[SELECT `id`, `event_id`, `aggregate_type`, `aggregate_id`, `event_type`,
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
                    eventType = row.event_type, schemaVersion = tonumber(row.schema_version),
                    payload = payload, headers = headers
                })
            else handlerError = 'invalid persisted JSON' end
            if callOk and handlerError == nil and result ~= false then
                local _, publishError = database:update([[UPDATE `synex_outbox` SET `state` = 'published',
                    `published_at` = CURRENT_TIMESTAMP(6), `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]], { row.id, claimToken })
                if publishError then return nil, publishError end
                report.published = report.published + 1
            else
                local attempts = tonumber(row.attempts) or 1
                local dead = attempts >= 10
                local delay = math.min(300, 2 ^ math.min(attempts, 8))
                local _, retryError = database:update([[UPDATE `synex_outbox`
                    SET `state` = ?, `available_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                        `locked_by` = NULL, `locked_until` = NULL
                    WHERE `id` = ? AND `state` = 'publishing' AND `locked_by` = ?]],
                    { dead and 'dead' or 'pending', delay, row.id, claimToken })
                if retryError then return nil, retryError end
                if dead then report.dead = report.dead + 1 else report.retried = report.retried + 1 end
                logger:warn('outbox dispatch failed', { eventId = row.event_id, attempts = attempts, dead = dead, error = tostring(handlerError or result) })
            end
        end
        metrics:increment('synex_outbox_dispatch_total', { result = 'published' }, report.published)
        metrics:increment('synex_outbox_dispatch_total', { result = 'retried' }, report.retried)
        metrics:increment('synex_outbox_dispatch_total', { result = 'dead' }, report.dead)
        return report, nil
    end

    local sagas = {}
    function sagas:start(sagaType, correlationId, context, options)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        options = options or {}
        if type(sagaType) ~= 'string' or #sagaType < 1 or #sagaType > 96
            or not sagaType:match('^[a-z][a-z0-9_.%-]*$')
            or type(correlationId) ~= 'string' or #correlationId < 1 or #correlationId > 128
            or correlationId:find('[%z\1-\31\127]') or type(context or {}) ~= 'table'
            or getmetatable(context or {}) ~= nil or type(options) ~= 'table' or getmetatable(options) ~= nil
            or (options.deadlineAt ~= nil and (type(options.deadlineAt) ~= 'string' or #options.deadlineAt < 19
                or #options.deadlineAt > 32 or not options.deadlineAt:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d'))) then
            return nil, foundation.error('INVALID_SAGA', 'Saga type or correlation ID is invalid.')
        end
        local contextJson, contextError = boundedJson(context or {}, 65536)
        if not contextJson then return nil, contextError end
        local publicId = foundation.nextId('saga')
        local inserted, insertError = database:insert([[INSERT INTO `synex_sagas`
            (`public_id`, `saga_type`, `correlation_id`, `state`, `current_step`, `version`, `context_json`, `deadline_at`)
            VALUES (?, ?, ?, 'pending', 0, 1, ?, ?)]],
            { publicId, sagaType, correlationId, contextJson, options.deadlineAt })
        if insertError then
            local existing, readError = database:query([[SELECT `public_id`, `state`, `current_step`, `version`
                FROM `synex_sagas` WHERE `saga_type` = ? AND `correlation_id` = ? LIMIT 1]], { sagaType, correlationId })
            if readError then return nil, readError end
            if existing and existing[1] then return existing[1], nil end
            return nil, insertError
        end
        return { id = inserted, publicId = publicId, state = 'pending', currentStep = 0, version = 1 }, nil
    end

    function sagas:record(publicId, expectedVersion, stepName, eventType, payload, errorValue)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        local allowedEvents = { started = true, succeeded = true, failed = true, compensated = true }
        if type(publicId) ~= 'string' or #publicId < 1 or #publicId > 36
            or type(expectedVersion) ~= 'number' or math.type(expectedVersion) ~= 'integer' or expectedVersion < 1
            or type(stepName) ~= 'string' or #stepName < 1 or #stepName > 96
            or not stepName:match('^[a-z][a-z0-9_.%-]*$') or not allowedEvents[eventType] then
            return nil, foundation.error('INVALID_SAGA_STEP', 'Saga step input is invalid.')
        end
        local rows, readError = database:query([[SELECT `id`, `state`, `current_step`, `version`
            FROM `synex_sagas` WHERE `public_id` = ? LIMIT 1]], { publicId })
        if readError then return nil, readError end
        local saga = rows and rows[1]
        if not saga then return nil, foundation.error('SAGA_NOT_FOUND', 'The saga does not exist.') end
        if tonumber(saga.version) ~= tonumber(expectedVersion) then return nil, foundation.error('SAGA_CONFLICT', 'The saga changed concurrently.', { retryable = true }) end
        local sequence = tonumber(saga.current_step) + 1
        local payloadJson, payloadError = boundedJson(payload or {}, 32768)
        if not payloadJson then return nil, payloadError end
        local errorJson = nil
        if errorValue ~= nil then errorJson, payloadError = boundedJson(errorValue, 8192); if not errorJson then return nil, payloadError end end
        local nextState = eventType == 'failed' and 'failed' or (eventType == 'compensated' and 'compensating' or 'running')
        local committed, transactionError = database:transaction({
            {
                query = [[INSERT INTO `synex_saga_steps`
                    (`saga_id`, `sequence_no`, `step_name`, `event_type`, `attempt`, `payload_json`, `error_json`)
                    VALUES (?, ?, ?, ?, 1, ?, ?)]],
                values = { saga.id, sequence, stepName, eventType, payloadJson, errorJson }
            },
            {
                query = [[UPDATE `synex_sagas` SET `state` = ?, `current_step` = ?, `version` = `version` + 1,
                    `last_error_json` = ?, `updated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `id` = ? AND `version` = ?]],
                values = { nextState, sequence, errorJson, saga.id, expectedVersion }
            }
        })
        if not committed then return nil, transactionError end
        return { publicId = publicId, state = nextState, currentStep = sequence, version = expectedVersion + 1 }, nil
    end

    local sagaStates = {
        pending = true, running = true, compensating = true,
        completed = true, failed = true, cancelled = true
    }
    local sagaEvents = { started = true, succeeded = true, failed = true, compensated = true }

    function sagas:candidates(maximum)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        maximum = maximum == nil and 10 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer' or maximum < 1 or maximum > 50 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Saga dispatch batch size must be an integer from 1 through 50.')
        end
        local rows, err = database:query([[SELECT `public_id`, `saga_type`, `state`, `version`,
                (`deadline_at` IS NOT NULL AND `deadline_at` <= CURRENT_TIMESTAMP(6)) AS `deadline_expired`,
                TIMESTAMPDIFF(MICROSECOND, `updated_at`, CURRENT_TIMESTAMP(6)) DIV 1000 AS `age_ms`
            FROM `synex_sagas` WHERE `state` IN ('pending', 'running', 'compensating')
            ORDER BY `id` ASC LIMIT ?]], { maximum })
        if err then return nil, err end
        local candidates = {}
        for index, row in ipairs(rows or {}) do
            candidates[index] = {
                publicId = row.public_id,
                sagaType = row.saga_type,
                state = row.state,
                version = tonumber(row.version) or 0,
                deadlineExpired = tonumber(row.deadline_expired) == 1,
                ageMs = math.max(0, tonumber(row.age_ms) or 0)
            }
        end
        return candidates, nil
    end

    function sagas:load(publicId)
        local enabled, featureError = requireFeature(features.sagas, 'sagas')
        if not enabled then return nil, featureError end
        if type(publicId) ~= 'string' or #publicId < 1 or #publicId > 36 then
            return nil, foundation.error('INVALID_SAGA', 'Saga ID is invalid.')
        end
        local rows, err = database:query([[SELECT `id`, `public_id`, `saga_type`, `correlation_id`, `state`,
                `current_step`, `version`, `context_json`, `last_error_json`, `deadline_at`,
                (`deadline_at` IS NOT NULL AND `deadline_at` <= CURRENT_TIMESTAMP(6)) AS `deadline_expired`,
                TIMESTAMPDIFF(MICROSECOND, `updated_at`, CURRENT_TIMESTAMP(6)) DIV 1000 AS `age_ms`
            FROM `synex_sagas` WHERE `public_id` = ? LIMIT 1]], { publicId })
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
            databaseId = row.id, publicId = row.public_id, sagaType = row.saga_type,
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
        if type(command) ~= 'table' or type(command.publicId) ~= 'string' or #command.publicId < 1 or #command.publicId > 36
            or type(command.expectedVersion) ~= 'number' or math.type(command.expectedVersion) ~= 'integer'
            or type(command.stepName) ~= 'string' or #command.stepName < 1 or #command.stepName > 96
            or not sagaEvents[command.eventType] or not sagaStates[command.nextState]
            or type(command.attempt) ~= 'number' or math.type(command.attempt) ~= 'integer'
            or command.attempt < 1 or command.attempt > 65535 then
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
                WHERE `public_id` = ? FOR UPDATE]], { command.publicId })
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
            local sequence = (tonumber(saga.current_step) or 0) + 1
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
                WHERE `id` = ? AND `version` = ?]], {
                command.nextState, sequence, contextJson, command.clearError == true and 1 or 0,
                errorJson, command.terminal == true and 1 or 0, saga.id, command.expectedVersion
            })
            local affected = type(updated) == 'table' and tonumber(updated.affectedRows) or tonumber(updated)
            if affected ~= 1 then
                domainError = foundation.error('SAGA_CONFLICT', 'The saga changed during event persistence.', { retryable = true })
                return false
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
        if not enabled then return { enabled = false, states = {} }, nil end
        local rows, err = database:query([[SELECT `state`, COUNT(*) AS `state_count`
            FROM `synex_sagas` GROUP BY `state` ORDER BY `state`]], {})
        if err then return nil, err end
        local states, total = {}, 0
        for _, row in ipairs(rows or {}) do
            local count = tonumber(row.state_count) or 0
            states[row.state] = count
            total = total + count
        end
        return { enabled = true, total = total, states = states }, nil
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
        local allowedKeys = { kind = true, value = true, limit = true }
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
        local parameters = definition.parameters(value)
        parameters[#parameters + 1] = limit + 1
        local rows, queryError = database:query([[SELECT `event_id`, `occurred_at`, `actor_type`, `actor_id`,
                `action`, `target_type`, `target_id`, `trace_id`
            FROM `synex_audit_log` WHERE ]] .. definition.clause .. [[
            ORDER BY `id` DESC LIMIT ?]], parameters)
        if queryError then return nil, queryError end
        rows = rows or {}
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
        return {
            kind = kind,
            limit = limit,
            entries = entries,
            truncated = #rows > limit
        }, nil
    end

    return { idempotency = idempotency, outbox = outbox, sagas = sagas, audit = audit }
end
